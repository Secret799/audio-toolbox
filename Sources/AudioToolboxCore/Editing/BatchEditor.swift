import Foundation

public enum BatchProgressPhase: Equatable, Sendable {
    case preparing
    case editing
    case moving
    case completed
}

/// A progress snapshot for one batch, emitted in input order.
public struct BatchProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let currentURL: URL?
    public let phase: BatchProgressPhase

    public init(
        completed: Int,
        total: Int,
        currentURL: URL?,
        phase: BatchProgressPhase = .completed
    ) {
        self.completed = completed
        self.total = total
        self.currentURL = currentURL
        self.phase = phase
    }
}

public protocol BatchEditing: Sendable {
    /// Runs one batch. An overlapping run on the same editor is rejected with
    /// one failed result per requested target instead of sharing stop state.
    func run(
        _ request: BatchEditRequest,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchEditSummary

    /// Prevents files that have not started from reaching the writer.
    /// The writer call already in progress is allowed to finish.
    func requestStop() async
}

public actor BatchEditor: BatchEditing {
    private static let stoppedMessage = "批量编辑已停止，未处理"
    private static let concurrentRunMessage = "已有批量编辑正在执行"

    private let writer: any SafeMetadataWriting
    private let mover: any FileMoving
    private var isRunning = false
    private var stopRequested = false

    public init(
        writer: any SafeMetadataWriting,
        mover: any FileMoving = FoundationFileMover()
    ) {
        self.writer = writer
        self.mover = mover
    }

    public func run(
        _ request: BatchEditRequest,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchEditSummary {
        guard !isRunning else {
            return await rejectedSummary(for: request, onProgress: onProgress)
        }

        isRunning = true
        stopRequested = false
        defer {
            stopRequested = false
            isRunning = false
        }

        let total = request.operations.count
        var results: [BatchFileResult] = []
        results.reserveCapacity(total)

        await report(
            BatchProgress(
                completed: 0,
                total: total,
                currentURL: nil,
                phase: .preparing
            ),
            to: onProgress
        )

        for (index, operation) in request.operations.enumerated() {
            let target = operation.target
            let url = target.url
            if stopRequested {
                for remainingOperation in request.operations[index...] {
                    let remainingURL = remainingOperation.target.url
                    results.append(
                        BatchFileResult(
                            url: remainingURL,
                            status: .notProcessed,
                            message: Self.stoppedMessage
                        )
                    )
                    await reportCompletion(
                        of: remainingURL,
                        completed: results.count,
                        total: total,
                        to: onProgress
                    )
                }
                break
            }

            await report(
                BatchProgress(
                    completed: results.count,
                    total: total,
                    currentURL: url,
                    phase: .editing
                ),
                to: onProgress
            )
            let writeResult = await writer.apply(to: target, patch: operation.patch)
            let result: BatchFileResult
            if writeResult.status == .succeeded,
               let migration = request.migration {
                await report(
                    BatchProgress(
                        completed: results.count,
                        total: total,
                        currentURL: url,
                        phase: .moving
                    ),
                    to: onProgress
                )
                result = await migrate(
                    writeResult,
                    to: migration.destinationDirectory
                )
            } else {
                result = writeResult
            }
            results.append(result)
            await reportCompletion(
                of: result.finalURL,
                completed: results.count,
                total: total,
                to: onProgress
            )
        }

        return BatchEditSummary(results: results)
    }

    public func requestStop() async {
        guard isRunning else { return }
        stopRequested = true
    }

    private func rejectedSummary(
        for request: BatchEditRequest,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchEditSummary {
        let total = request.operations.count
        var results: [BatchFileResult] = []
        results.reserveCapacity(total)

        await report(
            BatchProgress(
                completed: 0,
                total: total,
                currentURL: nil,
                phase: .preparing
            ),
            to: onProgress
        )

        for operation in request.operations {
            let url = operation.target.url
            results.append(
                BatchFileResult(
                    url: url,
                    status: .failed,
                    message: Self.concurrentRunMessage
                )
            )
            await reportCompletion(
                of: url,
                completed: results.count,
                total: total,
                to: onProgress
            )
        }

        return BatchEditSummary(results: results)
    }

    private func reportCompletion(
        of url: URL,
        completed: Int,
        total: Int,
        to onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async {
        await report(
            BatchProgress(
                completed: completed,
                total: total,
                currentURL: url,
                phase: .completed
            ),
            to: onProgress
        )
    }

    private func migrate(
        _ writeResult: BatchFileResult,
        to destinationDirectory: URL
    ) async -> BatchFileResult {
        do {
            let outcome = try await mover.move(
                writeResult.finalURL,
                to: destinationDirectory
            )
            switch outcome {
            case let .moved(destinationURL):
                return replacingMigration(
                    in: writeResult,
                    finalURL: destinationURL,
                    status: .moved,
                    warning: nil
                )
            case let .alreadyAtDestination(url):
                return replacingMigration(
                    in: writeResult,
                    finalURL: url,
                    status: .alreadyAtDestination,
                    warning: nil
                )
            }
        } catch let error as FileMoveError {
            let migrationStatus: BatchMigrationStatus
            if case .destinationExists = error {
                migrationStatus = .skippedConflict
            } else {
                migrationStatus = .failed
            }
            return replacingMigration(
                in: writeResult,
                finalURL: writeResult.finalURL,
                status: migrationStatus,
                warning: error.localizedDescription
            )
        } catch {
            return replacingMigration(
                in: writeResult,
                finalURL: writeResult.finalURL,
                status: .failed,
                warning: "无法移动文件：\(error.localizedDescription)"
            )
        }
    }

    private func replacingMigration(
        in result: BatchFileResult,
        finalURL: URL,
        status: BatchMigrationStatus,
        warning: String?
    ) -> BatchFileResult {
        BatchFileResult(
            url: result.url,
            status: result.status,
            message: combinedMessage(result.message, warning),
            recoveryURL: result.recoveryURL,
            finalURL: finalURL,
            migrationStatus: status
        )
    }

    private func combinedMessage(_ messages: String?...) -> String? {
        let values = messages.compactMap { $0?.trimmedNonEmpty }
        return values.isEmpty ? nil : values.joined(separator: "；")
    }

    private func report(
        _ progress: BatchProgress,
        to onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async {
        await Task.detached {
            onProgress(progress)
        }.value
    }
}
