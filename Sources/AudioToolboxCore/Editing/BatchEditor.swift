import Foundation

/// A progress snapshot for one batch, emitted in input order.
///
/// A run first emits `completed == 0` with `currentURL == nil`. It then emits
/// one snapshot after every input target receives a result, including URLs marked
/// `notProcessed` after a stop request. `currentURL` is the URL just completed.
public struct BatchProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let currentURL: URL?

    public init(completed: Int, total: Int, currentURL: URL?) {
        self.completed = completed
        self.total = total
        self.currentURL = currentURL
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
    private var isRunning = false
    private var stopRequested = false

    public init(writer: any SafeMetadataWriting) {
        self.writer = writer
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

        let total = request.targets.count
        var results: [BatchFileResult] = []
        results.reserveCapacity(total)

        await report(
            BatchProgress(completed: 0, total: total, currentURL: nil),
            to: onProgress
        )

        for (index, target) in request.targets.enumerated() {
            let url = target.url
            if stopRequested {
                for remainingTarget in request.targets[index...] {
                    let remainingURL = remainingTarget.url
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

            let result = await writer.apply(to: target, patch: request.patch)
            results.append(result)
            await reportCompletion(
                of: url,
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
        let total = request.targets.count
        var results: [BatchFileResult] = []
        results.reserveCapacity(total)

        await report(
            BatchProgress(completed: 0, total: total, currentURL: nil),
            to: onProgress
        )

        for target in request.targets {
            let url = target.url
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
            BatchProgress(completed: completed, total: total, currentURL: url),
            to: onProgress
        )
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
