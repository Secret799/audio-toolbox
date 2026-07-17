import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("BatchEditorTests")
struct BatchEditorTests {
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
            BatchProgress(completed: 0, total: 3, currentURL: nil),
            BatchProgress(completed: 1, total: 3, currentURL: files[0]),
            BatchProgress(completed: 2, total: 3, currentURL: files[1]),
            BatchProgress(completed: 3, total: 3, currentURL: files[2])
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
            BatchProgress(completed: 0, total: 3, currentURL: nil),
            BatchProgress(completed: 1, total: 3, currentURL: files[0]),
            BatchProgress(completed: 2, total: 3, currentURL: files[1]),
            BatchProgress(completed: 3, total: 3, currentURL: files[2])
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
            BatchProgress(completed: 0, total: 0, currentURL: nil)
        ])
        #expect(await writer.appliedURLs().isEmpty)
    }
}

private func request(files: [URL]) -> BatchEditRequest {
    BatchEditRequest(
        targets: files.enumerated().map { index, url in
            BatchEditTarget(
                url: url,
                fileIdentity: FileIdentity(rawValue: "test-\(index)-\(url.lastPathComponent)"),
                fileSize: Int64(index + 1),
                modificationDate: Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            )
        },
        patch: MetadataPatch(artist: "新作者", album: "新专辑")
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
