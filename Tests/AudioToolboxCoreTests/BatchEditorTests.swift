import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("BatchEditorTests")
struct BatchEditorTests {
    @Test("迁移请求和结果保留原始路径、最终路径与移动统计")
    func migrationModelsPreservePathsAndCountMoves() {
        let source = URL(fileURLWithPath: "/tmp/audio-toolbox-model-source.mp3")
        let destinationDirectory = URL(
            fileURLWithPath: "/tmp/audio-toolbox-model-destination"
        )
        let destination = destinationDirectory.appendingPathComponent(
            source.lastPathComponent
        )
        let baseRequest = request(files: [source])
        let migration = BatchMigrationConfiguration(
            destinationDirectory: destinationDirectory
        )

        let migrationRequest = BatchEditRequest(
            operations: baseRequest.operations,
            migration: migration
        )
        let defaultResult = BatchFileResult(
            url: source,
            status: .succeeded,
            message: nil
        )
        let movedResult = BatchFileResult(
            url: source,
            status: .succeeded,
            message: nil,
            finalURL: destination,
            migrationStatus: .moved
        )

        #expect(migrationRequest.migration == migration)
        #expect(defaultResult.finalURL == source)
        #expect(defaultResult.migrationStatus == .notRequested)
        #expect(movedResult.url == source)
        #expect(movedResult.finalURL == destination)
        #expect(BatchEditSummary(results: [defaultResult, movedResult]).movedCount == 1)
    }

    @Test("单文件失败不会阻止后续文件，并保留输入顺序")
    func failureDoesNotStopLaterFiles() async {
        let files = testURLs(count: 3, prefix: "failure-isolation")
        let writer = StubBatchWriter(statuses: [.succeeded, .failed, .succeeded])
        let editor = BatchEditor(writer: writer)

        let summary = await editor.run(request(files: files), onProgress: { _ in })

        #expect(summary.succeededCount == 2)
        #expect(summary.failedCount == 1)
        #expect(summary.notProcessedCount == 0)
        #expect(summary.results.map(\.url) == files)
        #expect(await writer.appliedURLs() == files)
    }

    @Test("每个文件使用自己的有效补丁并保持输入顺序")
    func eachOperationUsesItsOwnPatch() async {
        let files = testURLs(count: 2, prefix: "per-operation-patch")
        let targets = files.enumerated().map { index, url in
            BatchEditTarget(
                url: url,
                fileIdentity: FileIdentity(rawValue: "operation-\(index)"),
                fileSize: Int64(index + 1),
                modificationDate: Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            )
        }
        let patches = [
            MetadataPatch(artist: "只改作者", album: nil),
            MetadataPatch(artist: nil, album: "只改专辑"),
        ]
        let request = BatchEditRequest(operations: [
            BatchEditOperation(target: targets[0], patch: patches[0]),
            BatchEditOperation(target: targets[1], patch: patches[1]),
        ])
        let writer = StubBatchWriter(statuses: [.succeeded, .succeeded])
        let editor = BatchEditor(writer: writer)

        let summary = await editor.run(request, onProgress: { _ in })

        #expect(summary.results.map(\.url) == files)
        #expect(await writer.appliedURLs() == files)
        #expect(await writer.appliedPatches() == patches)
    }

    @Test("成功结果中的非空消息会单列为警告并保留恢复路径")
    func successfulWarningsAreCountedSeparately() {
        let recoveryURL = URL(fileURLWithPath: "/tmp/audio-toolbox-recovery/work.mp3")
        let summary = BatchEditSummary(results: [
            BatchFileResult(
                url: URL(fileURLWithPath: "/tmp/original.mp3"),
                status: .succeeded,
                message: "修改已提交，但清理失败",
                recoveryURL: recoveryURL
            ),
            BatchFileResult(
                url: URL(fileURLWithPath: "/tmp/clean.mp3"),
                status: .succeeded,
                message: nil
            ),
        ])

        #expect(summary.succeededCount == 2)
        #expect(summary.cleanSucceededCount == 1)
        #expect(summary.succeededWithWarningCount == 1)
        #expect(summary.succeededWithWarnings.map(\.recoveryURL) == [recoveryURL])
    }

    @Test("只有元数据修改成功的文件会被移动并记录最终路径")
    func onlySuccessfulEditsAreMoved() async {
        let files = testURLs(count: 2, prefix: "move-success-only")
        let destinationDirectory = URL(fileURLWithPath: "/tmp/move-success-target")
        let destination = destinationDirectory.appendingPathComponent(
            files[0].lastPathComponent
        )
        let writer = StubBatchWriter(statuses: [.succeeded, .failed])
        let mover = RecordingFileMover(outcomes: [.success(.moved(destination))])
        let editor = BatchEditor(writer: writer, mover: mover)
        let batchRequest = request(
            files: files,
            migration: BatchMigrationConfiguration(
                destinationDirectory: destinationDirectory
            )
        )

        let summary = await editor.run(batchRequest, onProgress: { _ in })

        #expect(await mover.sourceURLs == [files[0]])
        #expect(summary.results.map(\.status) == [.succeeded, .failed])
        #expect(summary.results[0].finalURL == destination)
        #expect(summary.results[0].migrationStatus == .moved)
        #expect(summary.results[1].finalURL == files[1])
        #expect(summary.results[1].migrationStatus == .notRequested)
        #expect(summary.movedCount == 1)
    }

    @Test("同名冲突保留元数据成功和已有警告并跳过移动")
    func destinationConflictPreservesWriterWarning() async {
        let source = testURLs(count: 1, prefix: "move-conflict")[0]
        let destinationDirectory = URL(fileURLWithPath: "/tmp/move-conflict-target")
        let destination = destinationDirectory.appendingPathComponent(
            source.lastPathComponent
        )
        let writer = StubResultBatchWriter(results: [
            BatchFileResult(
                url: source,
                status: .succeeded,
                message: "修改成功，但保留了恢复文件"
            ),
        ])
        let mover = RecordingFileMover(outcomes: [
            .failure(.destinationExists(destination)),
        ])
        let editor = BatchEditor(writer: writer, mover: mover)
        let batchRequest = request(
            files: [source],
            migration: BatchMigrationConfiguration(
                destinationDirectory: destinationDirectory
            )
        )

        let summary = await editor.run(batchRequest, onProgress: { _ in })
        let result = summary.results[0]

        #expect(result.status == .succeeded)
        #expect(result.finalURL == source)
        #expect(result.migrationStatus == .skippedConflict)
        #expect(result.message?.contains("保留了恢复文件") == true)
        #expect(result.message?.contains("已存在同名文件") == true)
        #expect(summary.succeededWithWarningCount == 1)
    }

    @Test("迁移失败保留成功状态并继续后续文件")
    func moveFailureWarnsAndContinues() async {
        let files = testURLs(count: 2, prefix: "move-failure")
        let destinationDirectory = URL(fileURLWithPath: "/tmp/move-failure-target")
        let secondDestination = destinationDirectory.appendingPathComponent(
            files[1].lastPathComponent
        )
        let writer = StubBatchWriter(statuses: [.succeeded, .succeeded])
        let mover = RecordingFileMover(outcomes: [
            .failure(.moveFailed(
                source: files[0],
                destination: destinationDirectory.appendingPathComponent(
                    files[0].lastPathComponent
                ),
                reason: "没有权限"
            )),
            .success(.moved(secondDestination)),
        ])
        let editor = BatchEditor(writer: writer, mover: mover)

        let summary = await editor.run(
            request(
                files: files,
                migration: BatchMigrationConfiguration(
                    destinationDirectory: destinationDirectory
                )
            ),
            onProgress: { _ in }
        )

        #expect(summary.results.map(\.status) == [.succeeded, .succeeded])
        #expect(summary.results[0].migrationStatus == .failed)
        #expect(summary.results[0].finalURL == files[0])
        #expect(summary.results[0].message?.contains("没有权限") == true)
        #expect(summary.results[1].migrationStatus == .moved)
        #expect(summary.results[1].finalURL == secondDestination)
    }

    @Test("迁移进度按准备、修改、移动和完成阶段发布")
    func migrationReportsProgressPhases() async {
        let source = testURLs(count: 1, prefix: "move-progress")[0]
        let destinationDirectory = URL(fileURLWithPath: "/tmp/move-progress-target")
        let destination = destinationDirectory.appendingPathComponent(
            source.lastPathComponent
        )
        let writer = StubBatchWriter(statuses: [.succeeded])
        let mover = RecordingFileMover(outcomes: [.success(.moved(destination))])
        let editor = BatchEditor(writer: writer, mover: mover)
        let recordedProgress = LockedBatchProgress()

        _ = await editor.run(
            request(
                files: [source],
                migration: BatchMigrationConfiguration(
                    destinationDirectory: destinationDirectory
                )
            )
        ) { recordedProgress.append($0) }

        #expect(recordedProgress.values == [
            BatchProgress(
                completed: 0,
                total: 1,
                currentURL: nil,
                phase: .preparing
            ),
            BatchProgress(
                completed: 0,
                total: 1,
                currentURL: source,
                phase: .editing
            ),
            BatchProgress(
                completed: 0,
                total: 1,
                currentURL: source,
                phase: .moving
            ),
            BatchProgress(
                completed: 1,
                total: 1,
                currentURL: destination,
                phase: .completed
            ),
        ])
    }

    @Test("进度从初始状态开始，并在每个文件产生结果后递增")
    func progressStartsAtZeroAndAdvancesAfterEveryFile() async {
        let files = testURLs(count: 3, prefix: "progress")
        let writer = StubBatchWriter(statuses: [.succeeded, .failed, .succeeded])
        let editor = BatchEditor(writer: writer)
        let recordedProgress = LockedBatchProgress()

        _ = await editor.run(request(files: files)) { progress in
            recordedProgress.append(progress)
        }

        #expect(recordedProgress.values == [
            BatchProgress(
                completed: 0,
                total: 3,
                currentURL: nil,
                phase: .preparing
            ),
            BatchProgress(
                completed: 0,
                total: 3,
                currentURL: files[0],
                phase: .editing
            ),
            BatchProgress(completed: 1, total: 3, currentURL: files[0]),
            BatchProgress(
                completed: 1,
                total: 3,
                currentURL: files[1],
                phase: .editing
            ),
            BatchProgress(completed: 2, total: 3, currentURL: files[1]),
            BatchProgress(
                completed: 2,
                total: 3,
                currentURL: files[2],
                phase: .editing
            ),
            BatchProgress(completed: 3, total: 3, currentURL: files[2]),
        ])
    }

    @Test("停止会等待当前文件完成，并将剩余文件依次标记为未处理")
    func stopFinishesCurrentFileAndMarksRemainingFilesNotProcessed() async {
        let files = testURLs(count: 3, prefix: "stop")
        let writer = SuspendedBatchWriter()
        let editor = BatchEditor(writer: writer)
        let recordedProgress = LockedBatchProgress()

        let runTask = Task {
            await editor.run(request(files: files)) { progress in
                recordedProgress.append(progress)
            }
        }

        await writer.waitUntilFirstFileStarted()
        await editor.requestStop()
        await writer.finishFirstFile(with: .succeeded)
        let summary = await runTask.value

        #expect(summary.succeededCount == 1)
        #expect(summary.failedCount == 0)
        #expect(summary.notProcessedCount == 2)
        #expect(summary.results.map(\.url) == files)
        #expect(summary.results.map(\.status) == [.succeeded, .notProcessed, .notProcessed])
        #expect(await writer.appliedURLs() == [files[0]])
        #expect(recordedProgress.values == [
            BatchProgress(
                completed: 0,
                total: 3,
                currentURL: nil,
                phase: .preparing
            ),
            BatchProgress(
                completed: 0,
                total: 3,
                currentURL: files[0],
                phase: .editing
            ),
            BatchProgress(completed: 1, total: 3, currentURL: files[0]),
            BatchProgress(completed: 2, total: 3, currentURL: files[1]),
            BatchProgress(completed: 3, total: 3, currentURL: files[2]),
        ])
    }

    @Test("停止状态会在批次结束后重置")
    func nextRunResetsStopState() async {
        let firstFiles = testURLs(count: 2, prefix: "first-run")
        let secondFiles = testURLs(count: 2, prefix: "second-run")
        let writer = SuspendedThenImmediateBatchWriter()
        let editor = BatchEditor(writer: writer)

        let firstTask = Task {
            await editor.run(request(files: firstFiles), onProgress: { _ in })
        }
        await writer.waitUntilFirstFileStarted()
        await editor.requestStop()
        await writer.finishFirstFile()
        let firstSummary = await firstTask.value

        let secondSummary = await editor.run(
            request(files: secondFiles),
            onProgress: { _ in }
        )

        #expect(firstSummary.results.map(\.status) == [.succeeded, .notProcessed])
        #expect(secondSummary.results.map(\.status) == [.succeeded, .succeeded])
        #expect(await writer.appliedURLs() == [firstFiles[0]] + secondFiles)
    }

    @Test("同一 editor 的并发第二批会明确失败且不会扰动活动批次")
    func concurrentRunIsRejectedWithoutChangingActiveRun() async {
        let activeFiles = testURLs(count: 2, prefix: "active")
        let rejectedFiles = testURLs(count: 2, prefix: "rejected")
        let writer = SuspendedBatchWriter()
        let editor = BatchEditor(writer: writer)

        let activeTask = Task {
            await editor.run(request(files: activeFiles), onProgress: { _ in })
        }
        await writer.waitUntilFirstFileStarted()

        let rejectedSummary = await editor.run(
            request(files: rejectedFiles),
            onProgress: { _ in }
        )

        await writer.finishFirstFile(with: .succeeded)
        await writer.waitUntilSecondFileStarted()
        await writer.finishSecondFile(with: .succeeded)
        let activeSummary = await activeTask.value

        #expect(rejectedSummary.results.map(\.url) == rejectedFiles)
        #expect(rejectedSummary.results.allSatisfy { $0.status == .failed })
        #expect(rejectedSummary.results.allSatisfy { $0.message == "已有批量编辑正在执行" })
        #expect(activeSummary.results.map(\.status) == [.succeeded, .succeeded])
        #expect(await writer.appliedURLs() == activeFiles)
    }

    @Test("进度回调可重入 editor 而不会在 actor 内死锁")
    func progressCallbackCanReenterEditorWithoutDeadlock() async {
        let files = testURLs(count: 1, prefix: "reentrant-progress")
        let writer = StubBatchWriter(statuses: [.succeeded])
        let editor = BatchEditor(writer: writer)
        let callbackResult = LockedBoolean(false)

        let summary = await editor.run(request(files: files)) { progress in
            guard progress.completed == 0 else { return }

            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await editor.requestStop()
                semaphore.signal()
            }
            callbackResult.value = semaphore.wait(timeout: .now() + 2) == .success
        }

        #expect(callbackResult.value)
        #expect(summary.results.map(\.status) == [.notProcessed])
        #expect(await writer.appliedURLs().isEmpty)
    }

    @Test("空列表只报告一次初始进度并返回空摘要")
    func emptyListReportsInitialProgressAndDoesNoWork() async {
        let writer = StubBatchWriter(statuses: [])
        let editor = BatchEditor(writer: writer)
        let recordedProgress = LockedBatchProgress()

        let summary = await editor.run(request(files: [])) { progress in
            recordedProgress.append(progress)
        }

        #expect(summary.results.isEmpty)
        #expect(recordedProgress.values == [
            BatchProgress(
                completed: 0,
                total: 0,
                currentURL: nil,
                phase: .preparing
            ),
        ])
        #expect(await writer.appliedURLs().isEmpty)
    }
}

private func request(
    files: [URL],
    migration: BatchMigrationConfiguration? = nil
) -> BatchEditRequest {
    BatchEditRequest(
        targets: files.enumerated().map { index, url in
            BatchEditTarget(
                url: url,
                fileIdentity: FileIdentity(rawValue: "test-\(index)-\(url.lastPathComponent)"),
                fileSize: Int64(index + 1),
                modificationDate: Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            )
        },
        patch: MetadataPatch(artist: "新作者", album: "新专辑"),
        migration: migration
    )
}

private func testURLs(count: Int, prefix: String) -> [URL] {
    (0..<count).map { index in
        URL(fileURLWithPath: "/tmp/\(prefix)-\(index).mp3")
    }
}

private actor StubBatchWriter: SafeMetadataWriting {
    private var statuses: [BatchFileStatus]
    private var urls: [URL] = []
    private var patches: [MetadataPatch] = []

    init(statuses: [BatchFileStatus]) {
        self.statuses = statuses
    }

    func apply(to target: BatchEditTarget, patch: MetadataPatch) async -> BatchFileResult {
        let url = target.url
        urls.append(url)
        patches.append(patch)
        let status = statuses.removeFirst()
        return BatchFileResult(url: url, status: status, message: nil)
    }

    func appliedURLs() -> [URL] {
        urls
    }

    func appliedPatches() -> [MetadataPatch] {
        patches
    }
}

private actor StubResultBatchWriter: SafeMetadataWriting {
    private var results: [BatchFileResult]

    init(results: [BatchFileResult]) {
        self.results = results
    }

    func apply(to target: BatchEditTarget, patch: MetadataPatch) async -> BatchFileResult {
        results.removeFirst()
    }
}

private actor RecordingFileMover: FileMoving {
    private var outcomes: [Result<FileMoveOutcome, FileMoveError>]
    private(set) var sourceURLs: [URL] = []

    init(outcomes: [Result<FileMoveOutcome, FileMoveError>]) {
        self.outcomes = outcomes
    }

    func move(
        _ sourceURL: URL,
        to destinationDirectory: URL
    ) async throws -> FileMoveOutcome {
        sourceURLs.append(sourceURL)
        return try outcomes.removeFirst().get()
    }
}

private actor SuspendedBatchWriter: SafeMetadataWriting {
    private var urls: [URL] = []
    private var firstStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstStarted = false
    private var firstFinishContinuation: CheckedContinuation<BatchFileStatus, Never>?
    private var secondStartedContinuation: CheckedContinuation<Void, Never>?
    private var secondStarted = false
    private var secondFinishContinuation: CheckedContinuation<BatchFileStatus, Never>?

    func apply(to target: BatchEditTarget, patch: MetadataPatch) async -> BatchFileResult {
        let url = target.url
        urls.append(url)
        switch urls.count {
        case 1:
            firstStarted = true
            firstStartedContinuation?.resume()
            firstStartedContinuation = nil
            let status = await withCheckedContinuation { continuation in
                firstFinishContinuation = continuation
            }
            return BatchFileResult(url: url, status: status, message: nil)
        case 2:
            secondStarted = true
            secondStartedContinuation?.resume()
            secondStartedContinuation = nil
            let status = await withCheckedContinuation { continuation in
                secondFinishContinuation = continuation
            }
            return BatchFileResult(url: url, status: status, message: nil)
        default:
            return BatchFileResult(url: url, status: .succeeded, message: nil)
        }
    }

    func waitUntilFirstFileStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuation = continuation
        }
    }

    func finishFirstFile(with status: BatchFileStatus) {
        firstFinishContinuation?.resume(returning: status)
        firstFinishContinuation = nil
    }

    func waitUntilSecondFileStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { continuation in
            secondStartedContinuation = continuation
        }
    }

    func finishSecondFile(with status: BatchFileStatus) {
        secondFinishContinuation?.resume(returning: status)
        secondFinishContinuation = nil
    }

    func appliedURLs() -> [URL] {
        urls
    }
}

private actor SuspendedThenImmediateBatchWriter: SafeMetadataWriting {
    private var urls: [URL] = []
    private var firstStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstStarted = false
    private var firstFinishContinuation: CheckedContinuation<Void, Never>?

    func apply(to target: BatchEditTarget, patch: MetadataPatch) async -> BatchFileResult {
        let url = target.url
        urls.append(url)
        if urls.count == 1 {
            firstStarted = true
            firstStartedContinuation?.resume()
            firstStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstFinishContinuation = continuation
            }
        }
        return BatchFileResult(url: url, status: .succeeded, message: nil)
    }

    func waitUntilFirstFileStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuation = continuation
        }
    }

    func finishFirstFile() {
        firstFinishContinuation?.resume()
        firstFinishContinuation = nil
    }

    func appliedURLs() -> [URL] {
        urls
    }
}

private final class LockedBatchProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [BatchProgress] = []

    var values: [BatchProgress] {
        lock.withLock { storedValues }
    }

    func append(_ progress: BatchProgress) {
        lock.withLock { storedValues.append(progress) }
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
