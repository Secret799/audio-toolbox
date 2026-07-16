import Combine
import Foundation
import Testing
@testable import AudioToolboxCore
@testable import AudioToolboxUI

@Suite("LibraryViewModelTests", .serialized)
struct LibraryViewModelTests {
    private let firstRoot = URL(fileURLWithPath: "/virtual/library-one", isDirectory: true)
    private let secondRoot = URL(fileURLWithPath: "/virtual/library-two", isDirectory: true)

    @Test("取消悬挂 load 调用后释放 ViewModel 会终止 producer 和 lease")
    @MainActor
    func cancellingCallerThenReleasingViewModelCleansUpScanAndLease() async {
        let scanner = TerminationTrackingScanner()
        let accessLog = AccessLog()
        var viewModel: LibraryViewModel? = makeViewModel(
            scanner: scanner,
            accessLog: accessLog
        )
        let weakViewModel = WeakBox(viewModel)
        var loadReturned = false
        let loadTask = Task { [weak viewModel] in
            await viewModel?.loadDirectory(firstRoot)
            loadReturned = true
        }
        await scanner.waitUntilStarted()

        #expect(!loadReturned)
        loadTask.cancel()
        await loadTask.value
        #expect(loadReturned)
        viewModel = nil

        await waitUntil { weakViewModel.value == nil }
        await waitUntil { scanner.cancelledTerminationCount == 1 }
        #expect(weakViewModel.value == nil)
        #expect(scanner.cancelledTerminationCount == 1)
        #expect(accessLog.events == [.start(firstRoot), .stop(firstRoot)])
    }

    @Test("loadDirectory 等待扫描完成后才返回")
    @MainActor
    func loadDirectoryWaitsForScanCompletion() async {
        let scanner = ControllableScanner()
        let viewModel = makeViewModel(scanner: scanner)
        var loadReturned = false
        let loadTask = Task {
            await viewModel.loadDirectory(firstRoot)
            loadReturned = true
        }
        await scanner.waitForScanCount(1)
        scanner.yield(.loaded(Self.firstTrack), toScan: 0)
        await waitUntil { viewModel.tracks == [Self.firstTrack] }

        #expect(!loadReturned)

        scanner.finish(scan: 0)
        await loadTask.value

        #expect(loadReturned)
        #expect(viewModel.scanState == .loaded(failures: []))
    }

    @Test("restoreLastDirectory 等待恢复目录扫描完成后才返回")
    @MainActor
    func restoreLastDirectoryWaitsForScanCompletion() async throws {
        let scanner = ControllableScanner()
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        try store.save(url: firstRoot)
        let viewModel = LibraryViewModel(
            scanner: scanner,
            batchEditor: FakeBatchEditor(summary: BatchEditSummary(results: [])),
            bookmarkStore: store,
            makeAccessLease: {
                SecurityScopedAccessLease(url: $0, accessor: NoopAccessor())
            }
        )
        var restoreReturned = false
        let restoreTask = Task {
            await viewModel.restoreLastDirectory()
            restoreReturned = true
        }
        await scanner.waitForScanCount(1)
        scanner.yield(.loaded(Self.firstTrack), toScan: 0)
        await waitUntil { viewModel.tracks == [Self.firstTrack] }

        #expect(!restoreReturned)

        scanner.finish(scan: 0)
        await restoreTask.value

        #expect(restoreReturned)
        #expect(viewModel.scanState == .loaded(failures: []))
    }

    @Test("restore latch 只允许多窗口触发一次恢复")
    @MainActor
    func restoreLastDirectoryIfNeededRunsOnce() async throws {
        let scanner = ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]])
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        try store.save(url: firstRoot)
        let viewModel = LibraryViewModel(
            scanner: scanner,
            batchEditor: FakeBatchEditor(summary: BatchEditSummary(results: [])),
            bookmarkStore: store,
            makeAccessLease: {
                SecurityScopedAccessLease(url: $0, accessor: NoopAccessor())
            }
        )

        async let first: Void = viewModel.restoreLastDirectoryIfNeeded()
        async let second: Void = viewModel.restoreLastDirectoryIfNeeded()
        _ = await (first, second)

        #expect(scanner.scanCount == 1)
        #expect(viewModel.scanState == .loaded(failures: []))
    }

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
        #expect(viewModel.scanState == .scanning(discovered: 2, processed: 1, loaded: 1, failures: []))

        scanner.yield(.loaded(Self.secondTrack), toScan: 0)
        scanner.finish(scan: 0)
        await load.value
        await waitUntil { viewModel.scanState == .loaded(failures: []) }

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
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.groupingMode = .album

        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        #expect(viewModel.selectedCount == 1)
        #expect(viewModel.groups.map(\.displayName) == ["Album Two", "Special Album"])
        #expect(viewModel.selectedGroupID == "album:Album Two")
    }

    @Test("主窗口派生批量入口和当前组全选三态")
    @MainActor
    func mainWindowDerivesBatchAvailabilityAndGroupSelectionState() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.sameArtistTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:Artist One"

        #expect(viewModel.currentGroup?.displayName == "Artist One")
        #expect(viewModel.currentGroupSelectionState == .none)
        #expect(!viewModel.canOpenBatchEditor)

        viewModel.toggleSelection(Self.firstTrack.id)
        #expect(viewModel.currentGroupSelectionState == .mixed)
        #expect(viewModel.canOpenBatchEditor)

        viewModel.setCurrentGroupSelected(true)
        #expect(viewModel.currentGroupSelectionState == .all)
        #expect(viewModel.selectedCount == 2)

        viewModel.setCurrentGroupSelected(false)
        #expect(viewModel.currentGroupSelectionState == .none)
        #expect(!viewModel.canOpenBatchEditor)
    }

    @Test("空目录派生用户文案")
    @MainActor
    func emptyDirectoryDerivesUserMessage() async {
        let scanner = ScriptedScanner(scripts: [[.finished]])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)

        #expect(viewModel.scanState == .empty(failures: []))
        #expect(viewModel.currentGroup == nil)
        #expect(viewModel.filteredTracks.isEmpty)
        #expect(viewModel.emptyDirectoryMessage == "library-one 中没有支持的音频文件")
    }

    @Test("空目录会区分无支持文件和全部读取失败")
    @MainActor
    func emptyDirectoryDistinguishesReadFailures() async {
        let failedURL = firstRoot.appendingPathComponent("broken.mp3")
        let failure = LibraryScanFailure(url: failedURL, message: "标签损坏")
        let scanner = ScriptedScanner(scripts: [[
            .failed(failedURL, "标签损坏"),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)

        #expect(viewModel.scanState == .empty(failures: [failure]))
        #expect(viewModel.emptyDirectoryMessage == "library-one 中没有成功载入的音频文件（1 个文件读取失败）")
    }

    @Test("bookmark 保存错误独立于旧扫描并在成功重试时清除")
    @MainActor
    func bookmarkSaveErrorSurvivesOldScanAndClearsOnRetry() async throws {
        let scanner = TerminationTrackingScanner()
        let accessLog = AccessLog()
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(
            defaults: defaults,
            resolver: FailingSecondSaveBookmarkResolver()
        )
        let viewModel = LibraryViewModel(
            scanner: scanner,
            batchEditor: FakeBatchEditor(summary: BatchEditSummary(results: [])),
            bookmarkStore: store,
            makeAccessLease: {
                SecurityScopedAccessLease(url: $0, accessor: accessLog)
            }
        )
        let firstLoad = Task { await viewModel.loadDirectory(firstRoot) }
        await scanner.waitForScanCount(1)
        scanner.yield(.loaded(Self.firstTrack))
        await waitUntil { viewModel.tracks == [Self.firstTrack] }
        viewModel.toggleSelection(Self.firstTrack.id)
        let previousTracks = viewModel.tracks
        let previousGroups = viewModel.groups
        let previousSelection = viewModel.selectedTrackIDs
        let previousGroupID = viewModel.selectedGroupID
        let previousScanState = viewModel.scanState

        await viewModel.loadDirectory(secondRoot)

        #expect(viewModel.currentDirectoryURL == firstRoot)
        #expect(viewModel.tracks == previousTracks)
        #expect(viewModel.groups == previousGroups)
        #expect(viewModel.selectedTrackIDs == previousSelection)
        #expect(viewModel.selectedGroupID == previousGroupID)
        #expect(viewModel.scanState == previousScanState)
        #expect(scanner.scanCount == 1)
        #expect(scanner.cancelledTerminationCount == 0)
        #expect(accessLog.events == [
            .start(firstRoot),
            .start(secondRoot),
            .stop(secondRoot),
        ])
        let saveError = try #require(viewModel.directoryOperationError)
        #expect(saveError.contains("保存"))

        scanner.yield(.discovered(2))
        scanner.yield(.loaded(Self.secondTrack))
        scanner.finish()
        await firstLoad.value

        #expect(viewModel.scanState == .loaded(failures: []))
        #expect(viewModel.tracks == LibraryProjection.sortedTracks([Self.firstTrack, Self.secondTrack]))
        #expect(viewModel.directoryOperationError == saveError)

        let retry = Task { await viewModel.loadDirectory(secondRoot) }
        await scanner.waitForScanCount(2)
        #expect(viewModel.directoryOperationError == nil)
        scanner.yield(.loaded(Self.secondTrack))
        scanner.finish()
        await retry.value

        #expect(viewModel.currentDirectoryURL == secondRoot)
        #expect(viewModel.directoryOperationError == nil)
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
        await waitUntil {
            viewModel.currentDirectoryURL == secondRoot
                && viewModel.scanState == .loaded(failures: [])
        }

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
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.toggleSelection(Self.secondTrack.id)
        await viewModel.loadDirectory(firstRoot)
        await waitUntil { scanner.scanCount == 2 && viewModel.scanState == .loaded(failures: []) }

        #expect(viewModel.selectedTrackIDs == [Self.secondTrack.id])
    }

    @Test("同目录刷新时即使原分组较晚出现也保留 selectedGroupID")
    @MainActor
    func sameRootRefreshPreservesSelectedGroupWhenItStillExists() async {
        let scanner = ScriptedScanner(scripts: [
            [.loaded(Self.firstTrack), .loaded(Self.secondTrack), .finished],
            [.loaded(Self.firstTrack), .loaded(Self.secondTrack), .finished],
        ])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        viewModel.selectedGroupID = "artist:Artist Two"

        await viewModel.loadDirectory(firstRoot)
        await waitUntil { scanner.scanCount == 2 && viewModel.scanState == .loaded(failures: []) }

        #expect(viewModel.selectedGroupID == "artist:Artist Two")
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
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        viewModel.selectedGroupID = "artist:Artist One"
        await viewModel.loadDirectory(firstRoot)
        await waitUntil { scanner.scanCount == 2 && viewModel.scanState == .loaded(failures: []) }

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
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
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

    @Test("搜索后全选仍选择当前完整分组")
    @MainActor
    func selectingGroupAfterSearchSelectsEntireGroup() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.sameArtistTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:Artist One"
        viewModel.searchText = "first title"

        #expect(viewModel.filteredTracks.map(\.id) == [Self.firstTrack.id])

        viewModel.setCurrentGroupSelected(true)

        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id, Self.sameArtistTrack.id])
        #expect(viewModel.currentGroupSelectionState == .all)
    }

    @Test("批量表单校验空 patch、首尾空格和无备份确认")
    @MainActor
    func batchFormValidatesPatchAndAcknowledgement() async {
        let scanner = ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()

        #expect(!viewModel.canAdvanceBatchEdit)
        #expect(!viewModel.canExecuteBatchEdit)

        viewModel.batchArtist = "   "
        viewModel.batchAlbum = "\n"
        #expect(viewModel.validatedBatchPatch == nil)
        #expect(!viewModel.canAdvanceBatchEdit)

        viewModel.batchArtist = "  Edited Artist  "
        #expect(viewModel.validatedBatchPatch == MetadataPatch(artist: "Edited Artist", album: nil))
        #expect(viewModel.canAdvanceBatchEdit)
        #expect(!viewModel.canExecuteBatchEdit)

        viewModel.batchAcknowledgedNoBackup = true
        #expect(viewModel.canExecuteBatchEdit)

        viewModel.batchAlbum = "  Edited Album  "
        #expect(!viewModel.batchAcknowledgedNoBackup)
        #expect(viewModel.validatedBatchPatch == MetadataPatch(artist: "Edited Artist", album: "Edited Album"))
    }

    @Test("打开批量编辑后冻结文件快照并拒绝目录与选择变化")
    @MainActor
    func batchEditorFreezesTrackSnapshotAndLibraryInteraction() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let editor = FakeBatchEditor(summary: BatchEditSummary(results: []))
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()

        #expect(viewModel.batchEditTracks.map(\.id) == [Self.firstTrack.id])
        #expect(viewModel.isLibraryInteractionLocked)

        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.toggleSelection(Self.secondTrack.id)
        await viewModel.loadDirectory(secondRoot)

        #expect(viewModel.currentDirectoryURL == firstRoot)
        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        #expect(viewModel.batchEditTracks.map(\.id) == [Self.firstTrack.id])
        #expect(scanner.scanCount == 1)

        viewModel.batchArtist = "Frozen"
        viewModel.batchAcknowledgedNoBackup = true
        #expect(viewModel.canExecuteBatchEdit)
        await viewModel.runBatchEdit()

        #expect(await editor.requests.first?.targets == [
            BatchEditTarget(
                url: Self.firstTrack.url,
                fileIdentity: Self.firstTrack.id,
                fileSize: Self.firstTrack.fileSize,
                modificationDate: Self.firstTrack.modificationDate
            )
        ])
    }

    @Test("批量执行前拒绝扫描中变为不可编辑的快照曲目")
    @MainActor
    func batchRejectsSnapshotThatBecomesUnreadable() async {
        let scanner = ControllableScanner()
        let editor = FakeBatchEditor(summary: BatchEditSummary(results: []))
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)

        let load = Task { await viewModel.loadDirectory(firstRoot) }
        await scanner.waitForScanCount(1)
        scanner.yield(.loaded(Self.firstTrack), toScan: 0)
        await waitUntil { viewModel.tracks == [Self.firstTrack] }

        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()
        viewModel.batchArtist = "Should Not Run"
        viewModel.batchAcknowledgedNoBackup = true
        #expect(viewModel.canExecuteBatchEdit)

        scanner.yield(
            .unreadable(Self.firstTrackUnreadable, "标签后来变得不可读"),
            toScan: 0
        )
        scanner.finish(scan: 0)
        await load.value

        #expect(!viewModel.canExecuteBatchEdit)
        await viewModel.runBatchEdit()
        #expect(await editor.requests.isEmpty)
        #expect(viewModel.batchState == .editing)
    }

    @Test("未确认不能执行，执行中禁止重复提交")
    @MainActor
    func batchExecutionRequiresAcknowledgementAndRejectsDuplicateRun() async {
        let scanner = ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]])
        let editor = SuspendedBatchEditor()
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()
        viewModel.batchArtist = "  Edited Artist  "

        await viewModel.runBatchEdit()
        #expect(await editor.requests.count == 0)
        #expect(viewModel.batchState == .editing)

        viewModel.batchAcknowledgedNoBackup = true
        let firstRun = Task { await viewModel.runBatchEdit() }
        await editor.waitUntilRunning()
        await viewModel.runBatchEdit()

        #expect(await editor.requests.count == 1)
        #expect(await editor.requests.first?.patch == MetadataPatch(artist: "Edited Artist", album: nil))

        await editor.complete()
        await firstRun.value
    }

    @Test("默认过滤不可读候选，关闭过滤后显示且始终不可选择")
    @MainActor
    func invalidAudioFilteringDefaultsOnAndCanBeDisabled() async {
        let unreadableFailure = LibraryScanFailure(
            url: Self.unreadableTrack.url,
            message: "标签损坏"
        )
        let unsupportedFailure = LibraryScanFailure(
            url: Self.unsupportedTrack.url,
            message: "标签结构不支持"
        )
        let scanner = ScriptedScanner(scripts: [[
            .discovered(4),
            .unreadable(Self.unreadableTrack, "标签损坏"),
            .unreadable(Self.unsupportedTrack, "标签结构不支持"),
            .loaded(Self.readOnlyTrack),
            .loaded(Self.untaggedWritableTrack),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)
        await waitUntil {
            viewModel.scanState == .loaded(failures: [unreadableFailure, unsupportedFailure])
        }

        #expect(viewModel.tracks == LibraryProjection.sortedTracks([
            Self.unreadableTrack, Self.unsupportedTrack, Self.readOnlyTrack,
            Self.untaggedWritableTrack,
        ]))
        #expect(viewModel.filtersInvalidAudioFiles)
        #expect(viewModel.visibleTrackCount == 2)
        #expect(viewModel.hiddenInvalidTrackCount == 2)
        #expect(viewModel.groups.map(\.displayName) == ["未知作者"])
        #expect(viewModel.filteredTracks == LibraryProjection.sortedTracks([
            Self.readOnlyTrack, Self.untaggedWritableTrack,
        ]))
        #expect(viewModel.filteredTracks.contains(Self.untaggedWritableTrack))
        #expect(viewModel.scanFailureCount == 2)
        #expect(viewModel.scanFailureMessage == "broken.mp3：标签损坏\nunsupported.ogg：标签结构不支持")
        #expect(Self.unreadableTrack.issue == .unreadable("标签损坏"))
        #expect(Self.unsupportedTrack.issue == .unsupportedTag("标签结构不支持"))

        viewModel.filtersInvalidAudioFiles = false
        #expect(viewModel.visibleTrackCount == 4)
        #expect(viewModel.hiddenInvalidTrackCount == 0)
        #expect(viewModel.filteredTracks.count == 4)

        viewModel.searchText = "broken"
        #expect(viewModel.filteredTracks == [Self.unreadableTrack])
        viewModel.searchText = ""

        viewModel.toggleSelection(Self.unreadableTrack.id)
        viewModel.toggleSelection(Self.readOnlyTrack.id)
        #expect(viewModel.selectedTrackIDs.isEmpty)
        #expect(viewModel.currentGroupSelectionState == .none)
        #expect(!viewModel.canOpenBatchEditor)

        viewModel.setCurrentGroupSelected(true)
        #expect(viewModel.selectedTrackIDs == [Self.untaggedWritableTrack.id])
        #expect(viewModel.currentGroupSelectionState == .all)
        #expect(viewModel.canOpenBatchEditor)

        viewModel.toggleSelection(Self.unreadableTrack.id)
        viewModel.openBatchEditor()
        #expect(viewModel.batchEditTracks == [Self.untaggedWritableTrack])
    }

    @Test("只有无效文件时默认显示空状态，关闭过滤后恢复文件列表")
    @MainActor
    func onlyInvalidAudioTracksFollowFilterState() async {
        let failure = LibraryScanFailure(url: Self.unreadableTrack.url, message: "标签损坏")
        let scanner = ScriptedScanner(scripts: [[
            .discovered(1),
            .unreadable(Self.unreadableTrack, "标签损坏"),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        await viewModel.loadDirectory(firstRoot)

        #expect(viewModel.scanState == .empty(failures: [failure]))
        #expect(viewModel.visibleTrackCount == 0)
        #expect(viewModel.hiddenInvalidTrackCount == 1)
        #expect(viewModel.groups.isEmpty)

        viewModel.filtersInvalidAudioFiles = false

        #expect(viewModel.scanState == .loaded(failures: [failure]))
        #expect(viewModel.visibleTrackCount == 1)
        #expect(viewModel.groups.map(\.displayName) == ["未知作者"])
        #expect(viewModel.filteredTracks == [Self.unreadableTrack])
        #expect(!viewModel.currentGroupHasEditableTracks)
    }

    @Test("大量扫描事件会节流曲目发布并准确统计已处理进度")
    @MainActor
    func largeScanBatchesTrackPublicationsAndExcludesTraversalFailuresFromProcessedCount() async {
        let validTracks = (0..<2_000).map { index in
            Self.track(
                id: "bulk-\(index)",
                fileName: "bulk-\(index).mp3",
                title: "Bulk \(index)",
                artist: "Artist \(index % 20)",
                album: "Album \(index % 30)"
            )
        }
        let events = [ScanEvent.discovered(validTracks.count)]
            + validTracks.map(ScanEvent.loaded)
            + [.failed(firstRoot.appendingPathComponent("inaccessible-subdirectory"), "无法访问目录")]
        let scanner = ControllableScanner()
        let viewModel = makeViewModel(scanner: scanner)
        var trackPublicationCount = 0
        let cancellable = viewModel.$tracks.dropFirst().sink { _ in
            trackPublicationCount += 1
        }
        let load = Task { await viewModel.loadDirectory(firstRoot) }

        await scanner.waitForScanCount(1)
        for event in events {
            scanner.yield(event, toScan: 0)
        }
        await waitUntil(attempts: 5_000) {
            if case let .scanning(discovered, processed, loaded, failures) = viewModel.scanState {
                return discovered == 2_000
                    && processed == 2_000
                    && loaded == 2_000
                    && failures.count == 1
            }
            return false
        }
        scanner.finish(scan: 0)
        await load.value
        withExtendedLifetime(cancellable) {}

        #expect(viewModel.tracks.count == 2_000)
        #expect(trackPublicationCount < 80)
        #expect(viewModel.scanState == .loaded(failures: [
            LibraryScanFailure(
                url: firstRoot.appendingPathComponent("inaccessible-subdirectory"),
                message: "无法访问目录"
            ),
        ]))
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
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        viewModel.toggleSelection(Self.firstTrack.id)

        viewModel.openBatchEditor()
        #expect(viewModel.batchState == .editing)
        #expect(viewModel.isBatchSheetPresented)
        viewModel.closeBatchEditor()
        #expect(viewModel.batchState == .closed)
        #expect(!viewModel.isBatchSheetPresented)
        #expect(viewModel.batchEditTracks.isEmpty)
        viewModel.openBatchEditor()
        #expect(viewModel.batchState == .editing)

        viewModel.batchArtist = "Edited Artist"
        viewModel.batchAcknowledgedNoBackup = true
        await viewModel.runBatchEdit()

        #expect(await editor.requests.count == 1)
        #expect(viewModel.batchState == .completed(summary))
        #expect(viewModel.isBatchSheetPresented)
        #expect(!viewModel.isBatchExecutionActive)
        #expect(viewModel.batchResultCounts == BatchResultCounts(succeeded: 1, failed: 0, notProcessed: 0))
        #expect(viewModel.tracks == [Self.editedFirstTrack])
        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        #expect(scanner.scanCount == 2)
    }

    @Test("批量结果计数区分成功、失败和未处理")
    @MainActor
    func batchResultCountsAllStatuses() async {
        let scanner = ScriptedScanner(scripts: [
            [.loaded(Self.firstTrack), .finished],
            [.loaded(Self.firstTrack), .finished],
        ])
        let summary = BatchEditSummary(results: [
            BatchFileResult(url: Self.firstTrack.url, status: .succeeded, message: nil),
            BatchFileResult(
                url: Self.untaggedWritableTrack.url,
                status: .succeeded,
                message: "修改成功，但保留了恢复文件",
                recoveryURL: URL(fileURLWithPath: "/tmp/recovery.flac")
            ),
            BatchFileResult(url: Self.sameArtistTrack.url, status: .failed, message: "写入失败"),
            BatchFileResult(url: Self.secondTrack.url, status: .notProcessed, message: "已停止"),
        ])
        let editor = FakeBatchEditor(summary: summary)
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()
        viewModel.batchAlbum = "Edited Album"
        viewModel.batchAcknowledgedNoBackup = true

        await viewModel.runBatchEdit()

        #expect(viewModel.batchResultCounts == BatchResultCounts(
            succeeded: 2,
            warnings: 1,
            failed: 1,
            notProcessed: 1
        ))
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
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        viewModel.toggleSelection(Self.firstTrack.id)

        viewModel.openBatchEditor()
        viewModel.batchArtist = "Edited"
        viewModel.batchAcknowledgedNoBackup = true
        let batch = Task {
            await viewModel.runBatchEdit()
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
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()
        viewModel.batchArtist = "Stopped"
        viewModel.batchAcknowledgedNoBackup = true
        let run = Task {
            await viewModel.runBatchEdit()
        }

        await editor.waitUntilRunning()
        await viewModel.stopBatchEdit()
        viewModel.closeBatchEditor()
        await viewModel.stopBatchEdit()

        #expect(await editor.stopRequestCount == 1)
        #expect(viewModel.batchState == .stopping(BatchProgress(completed: 0, total: 1, currentURL: nil)))
        #expect(viewModel.isBatchSheetPresented)
        #expect(viewModel.isBatchExecutionActive)

        await editor.complete()
        await run.value
        #expect(viewModel.isBatchSheetPresented)
        viewModel.closeBatchEditor()
        #expect(viewModel.batchState == .closed)
        #expect(!viewModel.isBatchSheetPresented)
    }

    @Test("恢复 bookmark 但安全作用域启动失败时清除授权并要求重新选择")
    @MainActor
    func bookmarkSecurityScopeFailureClearsAuthorizationWithoutScanning() async throws {
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        try store.save(url: firstRoot)
        let scanner = ScriptedScanner(scripts: [])
        let accessLog = AccessLog(startResult: false)
        let viewModel = LibraryViewModel(
            scanner: scanner,
            batchEditor: FakeBatchEditor(summary: BatchEditSummary(results: [])),
            bookmarkStore: store,
            makeAccessLease: {
                SecurityScopedAccessLease(url: $0, accessor: accessLog)
            }
        )

        await viewModel.restoreLastDirectory()

        #expect(scanner.scanCount == 0)
        #expect(defaults.data(forKey: "audioToolbox.lastDirectoryBookmark") == nil)
        #expect(viewModel.currentDirectoryURL == nil)
        let accessEvents = accessLog.events
        guard accessEvents.count == 1,
              case let .start(startedURL) = accessEvents[0] else {
            Issue.record("Expected exactly one security-scope start attempt")
            return
        }
        #expect(startedURL.path == firstRoot.path)
        guard case let .failed(message) = viewModel.scanState else {
            Issue.record("Expected authorization failure state")
            return
        }
        #expect(message.contains("授权已失效"))
        #expect(message.contains("重新选择"))
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

    private static let readOnlyTrack = AudioTrack(
        id: FileIdentity(rawValue: "read-only"),
        url: URL(fileURLWithPath: "/virtual/read-only.wav"),
        format: .wav,
        metadata: AudioMetadata(title: nil, artists: [], albums: [], duration: 120),
        fileSize: 896,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
        isWritable: false,
        issue: nil
    )

    private static let untaggedWritableTrack = AudioTrack(
        id: FileIdentity(rawValue: "untagged-writable"),
        url: URL(fileURLWithPath: "/virtual/untagged.flac"),
        format: .flac,
        metadata: AudioMetadata(title: nil, artists: [], albums: [], duration: 120),
        fileSize: 1_024,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
        isWritable: true,
        issue: nil
    )

    private static let firstTrackUnreadable = AudioTrack(
        id: firstTrack.id,
        url: firstTrack.url,
        format: firstTrack.format,
        metadata: AudioMetadata(title: nil, artists: [], albums: [], duration: nil),
        fileSize: firstTrack.fileSize,
        modificationDate: firstTrack.modificationDate,
        isWritable: false,
        issue: .unreadable("标签后来变得不可读")
    )

    private static let unreadableTrack = AudioTrack(
        id: FileIdentity(rawValue: "broken"),
        url: URL(fileURLWithPath: "/virtual/broken.mp3"),
        format: .mp3,
        metadata: AudioMetadata(title: nil, artists: [], albums: [], duration: nil),
        fileSize: 512,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
        isWritable: false,
        issue: .unreadable("标签损坏")
    )

    private static let unsupportedTrack = AudioTrack(
        id: FileIdentity(rawValue: "unsupported"),
        url: URL(fileURLWithPath: "/virtual/unsupported.ogg"),
        format: .ogg,
        metadata: AudioMetadata(title: nil, artists: [], albums: [], duration: nil),
        fileSize: 768,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
        isWritable: false,
        issue: .unsupportedTag("标签结构不支持")
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
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isWritable: true,
            issue: nil
        )
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class TerminationTrackingScanner: DirectoryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ScanEvent>.Continuation?
    private var storedCancelledTerminationCount = 0
    private var storedScanCount = 0

    var scanCount: Int {
        lock.withLock { storedScanCount }
    }

    var cancelledTerminationCount: Int {
        lock.withLock { storedCancelledTerminationCount }
    }

    func scan(root: URL) -> AsyncStream<ScanEvent> {
        lock.withLock { storedScanCount += 1 }
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.lock.withLock {
                    self?.storedCancelledTerminationCount += 1
                    self?.continuation = nil
                }
            }
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func yield(_ event: ScanEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }

    func waitForScanCount(_ count: Int) async {
        for _ in 0..<1_000 {
            if scanCount >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for scan \(count)")
    }

    func waitUntilStarted() async {
        for _ in 0..<1_000 {
            if lock.withLock({ continuation != nil }) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for suspended scan")
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
    private(set) var requests: [BatchEditRequest] = []
    private var completionContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopRequestCount = 0

    func run(
        _ request: BatchEditRequest,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchEditSummary {
        requests.append(request)
        onProgress(BatchProgress(completed: 0, total: request.targets.count, currentURL: nil))
        let waiters = runningContinuations
        runningContinuations.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
        return BatchEditSummary(results: request.targets.map {
            BatchFileResult(url: $0.url, status: .notProcessed, message: "stopped")
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
    private let startResult: Bool
    private var storedEvents: [AccessEvent] = []

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    var events: [AccessEvent] {
        lock.withLock { storedEvents }
    }

    func start(_ url: URL) -> Bool {
        lock.withLock { storedEvents.append(.start(url)) }
        return startResult
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
    case saveFailed
}

private final class FailingSecondSaveBookmarkResolver: DirectoryBookmarkResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var saveCount = 0

    func bookmarkData(for url: URL) throws -> Data {
        try lock.withLock {
            saveCount += 1
            if saveCount == 2 {
                throw BookmarkTestError.saveFailed
            }
            return Data(url.path.utf8)
        }
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
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
