import Foundation
import Testing
@testable import AudioToolboxCore
@testable import AudioToolboxUI

@Suite("LibraryViewModelTests", .serialized)
struct LibraryViewModelTests {
    private let firstRoot = URL(fileURLWithPath: "/virtual/library-one", isDirectory: true)
    private let secondRoot = URL(fileURLWithPath: "/virtual/library-two", isDirectory: true)

    @Test("扫描事件增量更新曲目、分组和进度")
    @MainActor
    func scanEventsUpdateLibraryIncrementally() async {
        let scanner = ControllableScanner()
        let viewModel = makeViewModel(scanner: scanner)
        let load = Task { await viewModel.loadDirectory(firstRoot) }

        await scanner.waitForScanCount(1)
        scanner.yield(.discovered(2), toScan: 0)
        scanner.yield(.loaded(Self.firstTrack), toScan: 0)
        await waitUntil { viewModel.tracks == [Self.firstTrack] }

        #expect(viewModel.groups.map(\.displayName) == ["Artist One"])
        #expect(viewModel.selectedGroupID == "artist:Artist One")
        #expect(viewModel.scanState == .scanning(discovered: 2, loaded: 1, failures: []))

        scanner.yield(.loaded(Self.secondTrack), toScan: 0)
        scanner.finish(scan: 0)
        await load.value

        #expect(viewModel.tracks == LibraryProjection.sortedTracks([Self.firstTrack, Self.secondTrack]))
        #expect(viewModel.groups.map(\.displayName) == ["Artist One", "Artist Two"])
        #expect(viewModel.scanState == .loaded(failures: []))
    }

    @Test("切换作者和专辑分组时保留跨组选择")
    @MainActor
    func changingGroupingModePreservesSelection() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.groupingMode = .album

        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        #expect(viewModel.selectedCount == 1)
        #expect(viewModel.groups.map(\.displayName) == ["Album Two", "Special Album"])
        #expect(viewModel.selectedGroupID == "album:Album Two")
    }

    @Test("切换根目录先建立新 lease、取消旧扫描、清空选择并拒绝旧事件")
    @MainActor
    func changingRootReplacesGenerationAndClearsSelection() async {
        let scanner = ControllableScanner()
        let accessLog = AccessLog()
        let viewModel = makeViewModel(scanner: scanner, accessLog: accessLog)
        let firstLoad = Task { await viewModel.loadDirectory(firstRoot) }

        await scanner.waitForScanCount(1)
        scanner.yield(.loaded(Self.firstTrack), toScan: 0)
        await waitUntil { viewModel.tracks == [Self.firstTrack] }
        viewModel.toggleSelection(Self.firstTrack.id)

        let secondLoad = Task { await viewModel.loadDirectory(secondRoot) }
        await scanner.waitForScanCount(2)
        scanner.yield(.loaded(Self.secondTrack), toScan: 1)
        scanner.finish(scan: 1)
        await secondLoad.value

        scanner.yield(.loaded(Self.lateTrack), toScan: 0)
        scanner.finish(scan: 0)
        await firstLoad.value

        #expect(viewModel.currentDirectoryURL == secondRoot)
        #expect(viewModel.tracks == [Self.secondTrack])
        #expect(viewModel.selectedTrackIDs.isEmpty)
        #expect(accessLog.events.prefix(3) == [
            .start(firstRoot),
            .start(secondRoot),
            .stop(firstRoot),
        ])
    }

    @Test("同目录刷新只保留仍存在曲目的选择")
    @MainActor
    func refreshingSameRootRetainsOnlyExistingSelection() async {
        let scanner = ScriptedScanner(scripts: [
            [.loaded(Self.firstTrack), .loaded(Self.secondTrack), .finished],
            [.loaded(Self.secondTrack), .finished],
        ])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.toggleSelection(Self.secondTrack.id)
        await viewModel.loadDirectory(firstRoot)

        #expect(viewModel.selectedTrackIDs == [Self.secondTrack.id])
    }

    @Test("当前分组在首次加载时合理默认，并在分组消失后修复")
    @MainActor
    func selectedGroupDefaultsAndRepairsWhenGroupDisappears() async {
        let scanner = ScriptedScanner(scripts: [
            [.loaded(Self.firstTrack), .loaded(Self.secondTrack), .finished],
            [.loaded(Self.secondTrack), .finished],
        ])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:Artist One"
        await viewModel.loadDirectory(firstRoot)

        #expect(viewModel.selectedGroupID == "artist:Artist Two")
    }

    @Test("搜索匹配标题、文件名、作者和专辑且限定当前组")
    @MainActor
    func searchMatchesSupportedTrackFields() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.sameArtistTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:Artist One"

        for query in ["first title", "filename-match", "special album"] {
            viewModel.searchText = query
            #expect(viewModel.filteredTracks.map(\.id) == [Self.firstTrack.id])
        }

        viewModel.searchText = "artist one"
        #expect(viewModel.filteredTracks.map(\.id) == [Self.firstTrack.id, Self.sameArtistTrack.id])

        viewModel.searchText = "artist two"
        #expect(viewModel.filteredTracks.isEmpty)
    }

    @Test("扫描失败会保留可展示的文件和原因")
    @MainActor
    func scanFailureIsPresented() async {
        let failedURL = firstRoot.appendingPathComponent("broken.mp3")
        let failure = LibraryScanFailure(url: failedURL, message: "标签损坏")
        let scanner = ScriptedScanner(scripts: [[
            .discovered(2),
            .loaded(Self.firstTrack),
            .failed(failedURL, "标签损坏"),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)

        #expect(viewModel.scanState == .loaded(failures: [failure]))
        #expect(viewModel.scanFailures == [failure])
        #expect(viewModel.scanFailureMessage == "broken.mp3：标签损坏")
    }

    @Test("打开、执行批量编辑会发布进度和结果，完成后刷新目录")
    @MainActor
    func batchEditPublishesProgressAndRefreshes() async {
        let scanner = ScriptedScanner(scripts: [
            [.loaded(Self.firstTrack), .finished],
            [.loaded(Self.editedFirstTrack), .finished],
        ])
        let summary = BatchEditSummary(results: [
            BatchFileResult(url: Self.firstTrack.url, status: .succeeded, message: nil),
        ])
        let editor = FakeBatchEditor(summary: summary, progress: [
            BatchProgress(completed: 0, total: 1, currentURL: nil),
            BatchProgress(completed: 1, total: 1, currentURL: Self.firstTrack.url),
        ])
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)

        viewModel.openBatchEditor()
        #expect(viewModel.batchState == .editing)

        await viewModel.runBatchEdit(patch: MetadataPatch(artist: "Edited Artist", album: nil))

        #expect(await editor.requests.count == 1)
        #expect(viewModel.batchState == .completed(summary))
        #expect(viewModel.tracks == [Self.editedFirstTrack])
        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        #expect(scanner.scanCount == 2)
    }

    @Test("批量完成后的刷新结束前拒绝重新打开编辑器")
    @MainActor
    func postBatchRefreshPreventsEditorReentry() async {
        let scanner = ControllableScanner()
        let summary = BatchEditSummary(results: [
            BatchFileResult(url: Self.firstTrack.url, status: .succeeded, message: nil),
        ])
        let editor = FakeBatchEditor(summary: summary)
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)

        let initialLoad = Task { await viewModel.loadDirectory(firstRoot) }
        await scanner.waitForScanCount(1)
        scanner.yield(.loaded(Self.firstTrack), toScan: 0)
        scanner.finish(scan: 0)
        await initialLoad.value
        viewModel.toggleSelection(Self.firstTrack.id)

        let batch = Task {
            await viewModel.runBatchEdit(
                patch: MetadataPatch(artist: "Edited", album: nil)
            )
        }
        await scanner.waitForScanCount(2)
        #expect(viewModel.batchState == .completed(summary))

        viewModel.openBatchEditor()

        #expect(viewModel.batchState == .completed(summary))
        scanner.yield(.loaded(Self.editedFirstTrack), toScan: 1)
        scanner.finish(scan: 1)
        await batch.value
    }

    @Test("停止批量编辑请求会进入停止状态并转发给 editor")
    @MainActor
    func stoppingBatchEditRequestsStop() async {
        let scanner = ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]])
        let editor = SuspendedBatchEditor()
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()
        let run = Task {
            await viewModel.runBatchEdit(patch: MetadataPatch(artist: "Stopped", album: nil))
        }

        await editor.waitUntilRunning()
        await viewModel.stopBatchEdit()

        #expect(await editor.stopRequestCount == 1)
        #expect(viewModel.batchState == .stopping(BatchProgress(completed: 0, total: 1, currentURL: nil)))

        await editor.complete()
        await run.value
    }

    @Test("恢复 bookmark 抛错时进入失败状态")
    @MainActor
    func bookmarkRestoreFailureUpdatesState() async {
        let defaults = makeDefaults()
        defaults.set(Data("saved".utf8), forKey: "audioToolbox.lastDirectoryBookmark")
        let store = SecurityScopedDirectoryStore(
            defaults: defaults,
            resolver: ThrowingRefreshBookmarkResolver(url: firstRoot)
        )
        let viewModel = LibraryViewModel(
            scanner: ScriptedScanner(scripts: []),
            batchEditor: FakeBatchEditor(summary: BatchEditSummary(results: [])),
            bookmarkStore: store,
            makeAccessLease: { SecurityScopedAccessLease(url: $0, accessor: NoopAccessor()) }
        )

        await viewModel.restoreLastDirectory()

        guard case let .failed(message) = viewModel.scanState else {
            Issue.record("Expected bookmark restore failure state")
            return
        }
        #expect(message.contains("恢复"))
        #expect(viewModel.currentDirectoryURL == nil)
    }

    @MainActor
    private func makeViewModel(
        scanner: any DirectoryScanning,
        batchEditor: any BatchEditing = FakeBatchEditor(summary: BatchEditSummary(results: [])),
        accessLog: AccessLog? = nil
    ) -> LibraryViewModel {
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(defaults: defaults, resolver: IdentityBookmarkResolver())
        let accessor: any SecurityScopedResourceAccessing = accessLog ?? NoopAccessor()
        return LibraryViewModel(
            scanner: scanner,
            batchEditor: batchEditor,
            bookmarkStore: store,
            makeAccessLease: { SecurityScopedAccessLease(url: $0, accessor: accessor) }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "LibraryViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 1_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for condition")
    }

    private static let firstTrack = track(
        id: "first",
        fileName: "filename-match.mp3",
        title: "First Title",
        artist: "Artist One",
        album: "Special Album"
    )

    private static let sameArtistTrack = track(
        id: "same-artist",
        fileName: "other.mp3",
        title: "Other Song",
        artist: "Artist One",
        album: "Different Album"
    )

    private static let secondTrack = track(
        id: "second",
        fileName: "second.flac",
        title: "Second Title",
        artist: "Artist Two",
        album: "Album Two",
        format: .flac
    )

    private static let lateTrack = track(
        id: "late",
        fileName: "late.mp3",
        title: "Late Event",
        artist: "Old Root",
        album: "Old Root"
    )

    private static let editedFirstTrack = track(
        id: "first",
        fileName: "filename-match.mp3",
        title: "First Title",
        artist: "Edited Artist",
        album: "Special Album"
    )

    private static func track(
        id: String,
        fileName: String,
        title: String,
        artist: String,
        album: String,
        format: AudioFormat = .mp3
    ) -> AudioTrack {
        AudioTrack(
            id: FileIdentity(rawValue: id),
            url: URL(fileURLWithPath: "/virtual/\(fileName)"),
            format: format,
            metadata: AudioMetadata(
                title: title,
                artists: [artist],
                albums: [album],
                duration: 120
            ),
            fileSize: 1_024,
            isWritable: true,
            issue: nil
        )
    }
}

private final class ScriptedScanner: DirectoryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[ScanEvent]]
    private var storedScanCount = 0

    init(scripts: [[ScanEvent]]) {
        self.scripts = scripts
    }

    var scanCount: Int {
        lock.withLock { storedScanCount }
    }

    func scan(root: URL) -> AsyncStream<ScanEvent> {
        let events = lock.withLock { () -> [ScanEvent] in
            storedScanCount += 1
            return scripts.isEmpty ? [.finished] : scripts.removeFirst()
        }
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private final class ControllableScanner: DirectoryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<ScanEvent>.Continuation] = []

    func scan(root: URL) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
    }

    func waitForScanCount(_ count: Int) async {
        for _ in 0..<1_000 {
            if lock.withLock({ continuations.count >= count }) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for scan \(count)")
    }

    func yield(_ event: ScanEvent, toScan index: Int) {
        continuation(at: index)?.yield(event)
    }

    func finish(scan index: Int) {
        continuation(at: index)?.finish()
    }

    private func continuation(at index: Int) -> AsyncStream<ScanEvent>.Continuation? {
        lock.withLock {
            guard continuations.indices.contains(index) else { return nil }
            return continuations[index]
        }
    }
}

private actor FakeBatchEditor: BatchEditing {
    let summary: BatchEditSummary
    let progress: [BatchProgress]
    private(set) var requests: [BatchEditRequest] = []
    private(set) var stopRequestCount = 0

    init(summary: BatchEditSummary, progress: [BatchProgress] = []) {
        self.summary = summary
        self.progress = progress
    }

    func run(
        _ request: BatchEditRequest,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchEditSummary {
        requests.append(request)
        for value in progress {
            onProgress(value)
        }
        return summary
    }

    func requestStop() async {
        stopRequestCount += 1
    }
}

private actor SuspendedBatchEditor: BatchEditing {
    private var runningContinuations: [CheckedContinuation<Void, Never>] = []
    private var completionContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopRequestCount = 0

    func run(
        _ request: BatchEditRequest,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchEditSummary {
        onProgress(BatchProgress(completed: 0, total: request.files.count, currentURL: nil))
        let waiters = runningContinuations
        runningContinuations.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
        return BatchEditSummary(results: request.files.map {
            BatchFileResult(url: $0, status: .notProcessed, message: "stopped")
        })
    }

    func requestStop() async {
        stopRequestCount += 1
    }

    func waitUntilRunning() async {
        if completionContinuation != nil { return }
        await withCheckedContinuation { continuation in
            runningContinuations.append(continuation)
        }
    }

    func complete() {
        completionContinuation?.resume()
        completionContinuation = nil
    }
}

private enum AccessEvent: Equatable {
    case start(URL)
    case stop(URL)
}

private final class AccessLog: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [AccessEvent] = []

    var events: [AccessEvent] {
        lock.withLock { storedEvents }
    }

    func start(_ url: URL) -> Bool {
        lock.withLock { storedEvents.append(.start(url)) }
        return true
    }

    func stop(_ url: URL) {
        lock.withLock { storedEvents.append(.stop(url)) }
    }
}

private struct NoopAccessor: SecurityScopedResourceAccessing {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
}

private struct IdentityBookmarkResolver: DirectoryBookmarkResolving {
    func bookmarkData(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
}

private enum BookmarkTestError: Error {
    case refreshFailed
}

private struct ThrowingRefreshBookmarkResolver: DirectoryBookmarkResolving {
    let url: URL

    func bookmarkData(for url: URL) throws -> Data {
        throw BookmarkTestError.refreshFailed
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (url, true)
    }
}
