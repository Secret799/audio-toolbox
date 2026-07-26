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

    @Test("同目录刷新且左侧搜索生效时立即选择首个可见分组")
    @MainActor
    func activeSidebarSearchDoesNotPreserveMissingGroupDuringRefresh() async {
        let scanner = ControllableScanner()
        let viewModel = makeViewModel(scanner: scanner)
        let initialLoad = Task { await viewModel.loadDirectory(firstRoot) }
        await scanner.waitForScanCount(1)
        scanner.yield(.loaded(Self.firstTrack), toScan: 0)
        scanner.yield(.loaded(Self.secondTrack), toScan: 0)
        scanner.finish(scan: 0)
        await initialLoad.value
        viewModel.selectedGroupID = "artist:Artist Two"
        viewModel.groupSearchText = "Artist"

        let refresh = Task { await viewModel.loadDirectory(firstRoot) }
        await scanner.waitForScanCount(2)
        scanner.yield(.loaded(Self.firstTrack), toScan: 1)
        await waitUntil { viewModel.groups.map(\.displayName) == ["Artist One"] }

        #expect(viewModel.filteredGroups.map(\.displayName) == ["Artist One"])
        #expect(viewModel.selectedGroupID == "artist:Artist One")

        scanner.finish(scan: 1)
        await refresh.value
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

    @Test("左侧搜索按当前分组名称过滤并修复分组选择")
    @MainActor
    func sidebarSearchFiltersGroupNamesAndRepairsSelection() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)

        viewModel.groupSearchText = "ARTIST two"

        #expect(viewModel.filteredGroups.map(\.displayName) == ["Artist Two"])
        #expect(viewModel.selectedGroupID == "artist:Artist Two")
        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        #expect(viewModel.groupSearchPrompt == "搜索作者")

        viewModel.groupSearchText = "missing"

        #expect(viewModel.filteredGroups.isEmpty)
        #expect(viewModel.selectedGroupID == nil)
        #expect(viewModel.groupSearchEmptyMessage == "没有匹配的作者")

        viewModel.groupSearchText = ""

        #expect(viewModel.filteredGroups == viewModel.groups)
        #expect(viewModel.selectedGroupID == "artist:Artist One")
        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
    }

    @Test("切换专辑分组后左侧搜索自动匹配专辑名称")
    @MainActor
    func sidebarSearchAdaptsToAlbumGrouping() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)

        viewModel.groupingMode = .album
        viewModel.groupSearchText = "special"

        #expect(viewModel.groupSearchPrompt == "搜索专辑")
        #expect(viewModel.groupSearchEmptyMessage == "没有匹配的专辑")
        #expect(viewModel.filteredGroups.map(\.displayName) == ["Special Album"])
        #expect(viewModel.selectedGroupID == "album:Special Album")
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

    @Test("标题排序支持升序和降序并在当前组内稳定生效")
    @MainActor
    func titleSortOrderControlsFilteredTracks() async {
        let alpha = Self.suspectedDuplicateTrack(
            id: "alpha",
            fileName: "alpha.mp3",
            title: "Alpha",
            artist: "排序作者",
            duration: 100
        )
        let zulu = Self.suspectedDuplicateTrack(
            id: "zulu",
            fileName: "zulu.mp3",
            title: "Zulu",
            artist: "排序作者",
            duration: 100
        )
        let scanner = ScriptedScanner(scripts: [[.loaded(zulu), .loaded(alpha), .finished]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:排序作者"

        #expect(viewModel.filteredTracks.map(\.id) == [alpha.id, zulu.id])

        viewModel.titleSortOrder = [AudioTrackTitleComparator(order: .reverse)]

        #expect(viewModel.filteredTracks.map(\.id) == [zulu.id, alpha.id])
    }

    @Test("疑似重复开关只显示当前分组重复文件且保留已有选择")
    @MainActor
    func suspectedDuplicateFilterPreservesSelection() async throws {
        let original = Self.suspectedDuplicateTrack(
            id: "duplicate-original",
            fileName: "故事.mp3",
            title: "故事",
            artist: "重复作者",
            duration: 300
        )
        let copy = Self.suspectedDuplicateTrack(
            id: "duplicate-copy",
            fileName: "故事 copy.mp3",
            title: "故事 copy",
            artist: "重复作者",
            duration: 301
        )
        let other = Self.suspectedDuplicateTrack(
            id: "other",
            fileName: "其他.mp3",
            title: "其他",
            artist: "重复作者",
            duration: 300
        )
        let scanner = ScriptedScanner(scripts: [[
            .loaded(original), .loaded(copy), .loaded(other), .finished,
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:重复作者"
        viewModel.toggleSelection(other.id)

        let originalMembership = try #require(viewModel.suspectedDuplicateMembership(for: original.id))
        let copyMembership = try #require(viewModel.suspectedDuplicateMembership(for: copy.id))
        #expect(originalMembership.groupNumber == copyMembership.groupNumber)
        #expect(viewModel.suspectedDuplicateTrackCount == 2)
        #expect(viewModel.suspectedDuplicateStatusText(for: original.id)
            == "疑似重复 1 · 100% · 相差 1.0 秒")

        viewModel.showsSuspectedDuplicatesOnly = true

        #expect(viewModel.filteredTracks.map(\.id) == [original.id, copy.id])
        #expect(viewModel.selectedTrackIDs == [other.id])
    }

    @Test("疑似重复检测不跨作者分组")
    @MainActor
    func suspectedDuplicateDetectionDoesNotCrossGroups() async {
        let first = Self.suspectedDuplicateTrack(
            id: "group-a",
            fileName: "同名.mp3",
            title: "同名",
            artist: "作者 A",
            duration: 100
        )
        let second = Self.suspectedDuplicateTrack(
            id: "group-b",
            fileName: "同名 copy.mp3",
            title: "同名 copy",
            artist: "作者 B",
            duration: 100
        )
        let scanner = ScriptedScanner(scripts: [[.loaded(first), .loaded(second), .finished]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)

        viewModel.selectedGroupID = "artist:作者 A"
        #expect(viewModel.suspectedDuplicateTrackCount == 0)
        #expect(viewModel.suspectedDuplicateMembership(for: first.id) == nil)

        viewModel.selectedGroupID = "artist:作者 B"
        #expect(viewModel.suspectedDuplicateTrackCount == 0)
        #expect(viewModel.suspectedDuplicateMembership(for: second.id) == nil)
    }

    @Test("搜索与疑似重复筛选取交集")
    @MainActor
    func searchIntersectsSuspectedDuplicateFilter() async {
        let first = Self.suspectedDuplicateTrack(
            id: "search-a",
            fileName: "故事.mp3",
            title: "故事",
            artist: "交集作者",
            duration: 100
        )
        let second = Self.suspectedDuplicateTrack(
            id: "search-b",
            fileName: "故事 copy.mp3",
            title: "故事 copy",
            artist: "交集作者",
            duration: 101
        )
        let scanner = ScriptedScanner(scripts: [[.loaded(first), .loaded(second), .finished]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:交集作者"
        viewModel.showsSuspectedDuplicatesOnly = true
        viewModel.searchText = "copy"

        #expect(viewModel.filteredTracks.map(\.id) == [second.id])
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

    @Test("批量表单回填单文件原作者和原专辑且未变化时不可执行")
    @MainActor
    func batchFormPrefillsSingleTrackAndRequiresEffectiveChange() async {
        let scanner = ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)

        viewModel.openBatchEditor()

        #expect(viewModel.batchArtist == "Artist One")
        #expect(viewModel.batchAlbum == "Special Album")
        #expect(viewModel.batchArtistPrompt == "原作者")
        #expect(viewModel.batchAlbumPrompt == "原专辑")
        #expect(viewModel.batchActualModificationCount == 0)
        #expect(viewModel.validatedBatchPatch == nil)
        #expect(!viewModel.canAdvanceBatchEdit)

        viewModel.batchArtist = "  Edited Artist  "

        #expect(viewModel.batchActualModificationCount == 1)
        #expect(viewModel.effectiveBatchPatch(for: Self.firstTrack)
            == MetadataPatch(artist: "Edited Artist", album: nil))
        #expect(viewModel.validatedBatchPatch
            == MetadataPatch(artist: "Edited Artist", album: nil))
        #expect(viewModel.canAdvanceBatchEdit)

        viewModel.batchArtist = "Artist One"
        #expect(viewModel.batchActualModificationCount == 0)
        #expect(!viewModel.canAdvanceBatchEdit)

        viewModel.batchArtist = ""
        #expect(viewModel.batchActualModificationCount == 0)
        #expect(!viewModel.canAdvanceBatchEdit)
    }

    @Test("共同值回填且混合值留空，只为实际不同的文件生成补丁")
    @MainActor
    func batchFormHandlesCommonAndMixedValuesPerTrack() async {
        let scanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.sameArtistTrack),
            .finished,
        ]])
        let editor = FakeBatchEditor(summary: BatchEditSummary(results: []))
        let viewModel = makeViewModel(scanner: scanner, batchEditor: editor)
        await viewModel.loadDirectory(firstRoot)
        viewModel.selectedGroupID = "artist:Artist One"
        viewModel.setCurrentGroupSelected(true)

        viewModel.openBatchEditor()

        #expect(viewModel.batchArtist == "Artist One")
        #expect(viewModel.batchArtistPrompt == "原作者")
        #expect(viewModel.batchAlbum.isEmpty)
        #expect(viewModel.batchAlbumPrompt == "多个不同专辑")
        #expect(viewModel.batchActualModificationCount == 0)

        viewModel.batchAlbum = "Special Album"

        #expect(viewModel.effectiveBatchPatch(for: Self.firstTrack) == nil)
        #expect(viewModel.effectiveBatchPatch(for: Self.sameArtistTrack)
            == MetadataPatch(artist: nil, album: "Special Album"))
        #expect(viewModel.batchActualModificationCount == 1)
        #expect(viewModel.validatedBatchPatch
            == MetadataPatch(artist: nil, album: "Special Album"))

        viewModel.batchAcknowledgedNoBackup = true
        await viewModel.runBatchEdit()

        let operations = await editor.requests.first?.operations
        #expect(operations?.map(\.target.url) == [Self.sameArtistTrack.url])
        #expect(operations?.map(\.patch) == [
            MetadataPatch(artist: nil, album: "Special Album"),
        ])
    }

    @Test("混合作者和空元数据使用对应输入提示")
    @MainActor
    func batchFormPromptsForMixedAndEmptyMetadata() async {
        let mixedScanner = ScriptedScanner(scripts: [[
            .loaded(Self.firstTrack),
            .loaded(Self.secondTrack),
            .finished,
        ]])
        let mixedViewModel = makeViewModel(scanner: mixedScanner)
        await mixedViewModel.loadDirectory(firstRoot)
        mixedViewModel.toggleSelection(Self.firstTrack.id)
        mixedViewModel.toggleSelection(Self.secondTrack.id)

        mixedViewModel.openBatchEditor()

        #expect(mixedViewModel.batchArtist.isEmpty)
        #expect(mixedViewModel.batchAlbum.isEmpty)
        #expect(mixedViewModel.batchArtistPrompt == "多个不同作者")
        #expect(mixedViewModel.batchAlbumPrompt == "多个不同专辑")

        let emptyScanner = ScriptedScanner(scripts: [[
            .loaded(Self.untaggedWritableTrack),
            .finished,
        ]])
        let emptyViewModel = makeViewModel(scanner: emptyScanner)
        await emptyViewModel.loadDirectory(firstRoot)
        emptyViewModel.toggleSelection(Self.untaggedWritableTrack.id)

        emptyViewModel.openBatchEditor()

        #expect(emptyViewModel.batchArtist.isEmpty)
        #expect(emptyViewModel.batchAlbum.isEmpty)
        #expect(emptyViewModel.batchArtistPrompt == "原值为空")
        #expect(emptyViewModel.batchAlbumPrompt == "原值为空")
        #expect(!emptyViewModel.canAdvanceBatchEdit)
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

    @Test("选择迁移目录会保存授权并在批量请求中携带目标目录")
    @MainActor
    func choosingMigrationDirectoryPersistsAndBuildsRequest() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-toolbox-view-model-migration", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        let scanner = ScriptedScanner(scripts: [
            [.loaded(Self.firstTrack), .finished],
            [.loaded(Self.firstTrack), .finished],
        ])
        let editor = FakeBatchEditor(summary: BatchEditSummary(results: []))
        let defaults = makeDefaults()
        let scanStore = SecurityScopedDirectoryStore(
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        let migrationStore = SecurityScopedDirectoryStore(
            storageKey: "audioToolbox.migrationDirectoryBookmark",
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        let viewModel = LibraryViewModel(
            scanner: scanner,
            batchEditor: editor,
            bookmarkStore: scanStore,
            migrationBookmarkStore: migrationStore,
            makeAccessLease: {
                SecurityScopedAccessLease(url: $0, accessor: NoopAccessor())
            }
        )
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()
        viewModel.batchArtist = "Edited Artist"
        viewModel.batchAcknowledgedNoBackup = true

        viewModel.chooseMigrationDirectory(destination)

        #expect(viewModel.migrationDirectoryURL == destination)
        #expect(viewModel.movesSuccessfulFiles)
        #expect(viewModel.migrationDirectoryError == nil)
        #expect(!viewModel.batchAcknowledgedNoBackup)
        #expect(try migrationStore.restore() == destination)

        viewModel.batchAcknowledgedNoBackup = true
        #expect(viewModel.canExecuteBatchEdit)
        await viewModel.runBatchEdit()

        #expect(await editor.requests.first?.migration
            == BatchMigrationConfiguration(destinationDirectory: destination))

        viewModel.closeBatchEditor()
        viewModel.openBatchEditor()
        #expect(viewModel.migrationDirectoryURL == destination)
        #expect(viewModel.movesSuccessfulFiles)
    }

    @Test("启用迁移但没有有效目录时禁止执行且不能只迁移")
    @MainActor
    func migrationRequiresValidDirectoryAndMetadataChange() async {
        let scanner = ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]])
        let viewModel = makeViewModel(scanner: scanner)
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()

        viewModel.movesSuccessfulFiles = true
        viewModel.batchAcknowledgedNoBackup = true
        #expect(!viewModel.canAdvanceBatchEdit)
        #expect(!viewModel.canExecuteBatchEdit)

        viewModel.batchArtist = "Edited Artist"
        viewModel.batchAcknowledgedNoBackup = true
        #expect(viewModel.canAdvanceBatchEdit)
        #expect(!viewModel.canExecuteBatchEdit)

        viewModel.movesSuccessfulFiles = false
        viewModel.batchAcknowledgedNoBackup = true
        #expect(viewModel.canExecuteBatchEdit)
    }

    @Test("迁移目录书签恢复时权限失败会清除授权")
    @MainActor
    func migrationBookmarkRestoreRequiresSecurityScope() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-toolbox-migration-restore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        let defaults = makeDefaults()
        let migrationStore = SecurityScopedDirectoryStore(
            storageKey: "audioToolbox.migrationDirectoryBookmark",
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        try migrationStore.save(url: destination)
        let viewModel = LibraryViewModel(
            scanner: ScriptedScanner(scripts: []),
            batchEditor: FakeBatchEditor(summary: BatchEditSummary(results: [])),
            bookmarkStore: SecurityScopedDirectoryStore(
                defaults: defaults,
                resolver: IdentityBookmarkResolver()
            ),
            migrationBookmarkStore: migrationStore,
            makeAccessLease: {
                SecurityScopedAccessLease(
                    url: $0,
                    accessor: AccessLog(startResult: false)
                )
            }
        )

        await viewModel.restoreMigrationDirectoryIfNeeded()

        #expect(viewModel.migrationDirectoryURL == nil)
        #expect(!viewModel.movesSuccessfulFiles)
        #expect(viewModel.migrationDirectoryError?.contains("授权已失效") == true)
        #expect(try migrationStore.restore() == nil)
    }

    @Test("有效迁移书签恢复后在新批次中默认启用")
    @MainActor
    func validMigrationBookmarkDefaultsOnForNewBatch() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-toolbox-migration-valid", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        let defaults = makeDefaults()
        let migrationStore = SecurityScopedDirectoryStore(
            storageKey: "audioToolbox.migrationDirectoryBookmark",
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        try migrationStore.save(url: destination)
        let viewModel = LibraryViewModel(
            scanner: ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]]),
            batchEditor: FakeBatchEditor(summary: BatchEditSummary(results: [])),
            bookmarkStore: SecurityScopedDirectoryStore(
                defaults: defaults,
                resolver: IdentityBookmarkResolver()
            ),
            migrationBookmarkStore: migrationStore,
            makeAccessLease: {
                SecurityScopedAccessLease(url: $0, accessor: NoopAccessor())
            }
        )

        await viewModel.restoreMigrationDirectoryIfNeeded()
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()

        #expect(viewModel.migrationDirectoryURL == destination)
        #expect(viewModel.isMigrationDirectoryValid)
        #expect(viewModel.movesSuccessfulFiles)
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
        #expect(await editor.requests.first?.operations.map(\.patch) == [
            MetadataPatch(artist: "Edited Artist", album: nil),
        ])

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

    @Test("打开、执行批量编辑会发布进度和结果，完成后只增量重载成功文件")
    @MainActor
    func batchEditPublishesProgressAndRefreshes() async {
        let scanner = ScriptedScanner(scripts: [
            [.loaded(Self.firstTrack), .finished],
        ])
        let summary = BatchEditSummary(results: [
            BatchFileResult(url: Self.firstTrack.url, status: .succeeded, message: nil),
        ])
        let editor = FakeBatchEditor(summary: summary, progress: [
            BatchProgress(completed: 0, total: 1, currentURL: nil),
            BatchProgress(completed: 1, total: 1, currentURL: Self.firstTrack.url),
        ])
        let reloader = RecordingTrackReloader(results: [
            .success(Self.editedFirstTrack),
        ])
        let viewModel = makeViewModel(
            scanner: scanner,
            batchEditor: editor,
            trackReloader: reloader
        )
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
        #expect(viewModel.groups.map(\.displayName) == ["Edited Artist"])
        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        #expect(await reloader.urls == [Self.firstTrack.url])
        #expect(scanner.scanCount == 1)
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
                recoveryURL: URL(fileURLWithPath: "/tmp/recovery.flac"),
                finalURL: URL(fileURLWithPath: "/tmp/migrated.flac"),
                migrationStatus: .moved
            ),
            BatchFileResult(url: Self.sameArtistTrack.url, status: .failed, message: "写入失败"),
            BatchFileResult(url: Self.secondTrack.url, status: .notProcessed, message: "已停止"),
        ])
        let editor = FakeBatchEditor(summary: summary)
        let viewModel = makeViewModel(
            scanner: scanner,
            batchEditor: editor,
            trackReloader: RecordingTrackReloader(results: [
                .success(Self.editedFirstTrack),
            ])
        )
        await viewModel.loadDirectory(firstRoot)
        viewModel.toggleSelection(Self.firstTrack.id)
        viewModel.openBatchEditor()
        viewModel.batchAlbum = "Edited Album"
        viewModel.batchAcknowledgedNoBackup = true

        await viewModel.runBatchEdit()

        #expect(viewModel.batchResultCounts == BatchResultCounts(
            succeeded: 2,
            warnings: 1,
            moved: 1,
            failed: 1,
            notProcessed: 1
        ))
    }

    @Test("批量完成后的增量重载结束前拒绝重新打开编辑器")
    @MainActor
    func postBatchRefreshPreventsEditorReentry() async {
        let scanner = ControllableScanner()
        let summary = BatchEditSummary(results: [
            BatchFileResult(url: Self.firstTrack.url, status: .succeeded, message: nil),
        ])
        let editor = FakeBatchEditor(summary: summary)
        let reloader = SuspendedTrackReloader(result: Self.editedFirstTrack)
        let viewModel = makeViewModel(
            scanner: scanner,
            batchEditor: editor,
            trackReloader: reloader
        )

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
        await reloader.waitUntilStarted()
        #expect(viewModel.isBatchExecutionActive)

        viewModel.openBatchEditor()

        #expect(viewModel.isBatchExecutionActive)
        await reloader.complete()
        await batch.value
        #expect(viewModel.batchState == .completed(summary))
    }

    @Test("迁移到扫描目录外会移除曲目和选择且不重载")
    @MainActor
    func movedOutsideRootRemovesTrackWithoutReloading() async {
        let destination = URL(fileURLWithPath: "/outside/filename-match.mp3")
        let summary = BatchEditSummary(results: [
            BatchFileResult(
                url: Self.firstTrack.url,
                status: .succeeded,
                message: nil,
                finalURL: destination,
                migrationStatus: .moved
            ),
        ])
        let reloader = RecordingTrackReloader(results: [])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]]),
            batchEditor: FakeBatchEditor(summary: summary),
            trackReloader: reloader
        )

        await runBatchEdit(viewModel, selecting: [Self.firstTrack.id])

        #expect(viewModel.tracks.isEmpty)
        #expect(viewModel.selectedTrackIDs.isEmpty)
        #expect(await reloader.urls.isEmpty)
    }

    @Test("迁移到扫描目录内会按最终路径重载并映射新身份选择")
    @MainActor
    func movedInsideRootReloadsFinalPathAndMapsSelection() async {
        let destination = firstRoot
            .appendingPathComponent("migrated", isDirectory: true)
            .appendingPathComponent("filename-match.mp3")
        let movedTrack = Self.track(
            id: "migrated-first",
            url: destination,
            title: "First Title",
            artist: "Edited Artist",
            album: "Special Album"
        )
        let summary = BatchEditSummary(results: [
            BatchFileResult(
                url: Self.firstTrack.url,
                status: .succeeded,
                message: nil,
                finalURL: destination,
                migrationStatus: .moved
            ),
        ])
        let reloader = RecordingTrackReloader(results: [.success(movedTrack)])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]]),
            batchEditor: FakeBatchEditor(summary: summary),
            trackReloader: reloader
        )

        await runBatchEdit(viewModel, selecting: [Self.firstTrack.id])

        #expect(viewModel.tracks == [movedTrack])
        #expect(viewModel.selectedTrackIDs == [movedTrack.id])
        #expect(await reloader.urls == [destination])
    }

    @Test("迁移冲突和移动失败会重载修改后的原路径")
    @MainActor
    func migrationWarningsReloadOriginalPaths() async {
        let editedFirst = Self.track(
            id: Self.firstTrack.id.rawValue,
            url: Self.firstTrack.url,
            title: "First Title",
            artist: "Edited Artist",
            album: "Special Album"
        )
        let editedOther = Self.track(
            id: Self.sameArtistTrack.id.rawValue,
            url: Self.sameArtistTrack.url,
            title: "Other Song",
            artist: "Edited Artist",
            album: "Different Album"
        )
        let summary = BatchEditSummary(results: [
            BatchFileResult(
                url: Self.firstTrack.url,
                status: .succeeded,
                message: "目标文件已存在",
                migrationStatus: .skippedConflict
            ),
            BatchFileResult(
                url: Self.sameArtistTrack.url,
                status: .succeeded,
                message: "无法移动文件",
                migrationStatus: .failed
            ),
        ])
        let reloader = RecordingTrackReloader(results: [
            .success(editedFirst),
            .success(editedOther),
        ])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[
                .loaded(Self.firstTrack),
                .loaded(Self.sameArtistTrack),
                .finished,
            ]]),
            batchEditor: FakeBatchEditor(summary: summary),
            trackReloader: reloader
        )

        await runBatchEdit(
            viewModel,
            selecting: [Self.firstTrack.id, Self.sameArtistTrack.id]
        )

        #expect(await reloader.urls == [Self.firstTrack.url, Self.sameArtistTrack.url])
        #expect(viewModel.tracks.count == 2)
        #expect(viewModel.tracks.contains(editedFirst))
        #expect(viewModel.tracks.contains(editedOther))
    }

    @Test("未移动文件重载失败会保留旧记录并追加手动刷新警告")
    @MainActor
    func reloadFailureRetainsOriginalTrackAndResultDetails() async {
        let recoveryURL = URL(fileURLWithPath: "/tmp/recovery.mp3")
        let originalResult = BatchFileResult(
            url: Self.firstTrack.url,
            status: .succeeded,
            message: "修改成功，但保留了恢复文件",
            recoveryURL: recoveryURL,
            migrationStatus: .notRequested
        )
        let reloader = RecordingTrackReloader(results: [
            .failure(TrackReloadTestError.reloadFailed),
        ])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]]),
            batchEditor: FakeBatchEditor(
                summary: BatchEditSummary(results: [originalResult])
            ),
            trackReloader: reloader
        )

        await runBatchEdit(viewModel, selecting: [Self.firstTrack.id])

        #expect(viewModel.tracks == [Self.firstTrack])
        #expect(viewModel.selectedTrackIDs == [Self.firstTrack.id])
        guard case let .completed(summary) = viewModel.batchState,
              let result = summary.results.first else {
            Issue.record("Expected completed batch summary")
            return
        }
        #expect(result.status == .succeeded)
        #expect(result.url == originalResult.url)
        #expect(result.finalURL == originalResult.finalURL)
        #expect(result.recoveryURL == recoveryURL)
        #expect(result.migrationStatus == .notRequested)
        #expect(result.message?.contains("修改成功，但保留了恢复文件") == true)
        #expect(result.message?.contains("列表更新失败，请手动刷新") == true)
        #expect(result.message?.contains("测试重载失败") == true)
    }

    @Test("移入扫描目录的文件重载失败会移除失效旧记录")
    @MainActor
    func movedInsideRootReloadFailureRemovesStaleTrack() async {
        let destination = firstRoot.appendingPathComponent("migrated/filename-match.mp3")
        let originalResult = BatchFileResult(
            url: Self.firstTrack.url,
            status: .succeeded,
            message: nil,
            finalURL: destination,
            migrationStatus: .moved
        )
        let reloader = RecordingTrackReloader(results: [
            .failure(TrackReloadTestError.reloadFailed),
        ])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]]),
            batchEditor: FakeBatchEditor(
                summary: BatchEditSummary(results: [originalResult])
            ),
            trackReloader: reloader
        )

        await runBatchEdit(viewModel, selecting: [Self.firstTrack.id])

        #expect(viewModel.tracks.isEmpty)
        #expect(viewModel.selectedTrackIDs.isEmpty)
        guard case let .completed(summary) = viewModel.batchState else {
            Issue.record("Expected completed batch summary")
            return
        }
        #expect(summary.results[0].message?.contains("列表更新失败，请手动刷新") == true)
    }

    @Test("一个文件重载失败不会阻止后续成功文件更新")
    @MainActor
    func reloadFailureDoesNotStopFollowingUpdates() async {
        let editedOther = Self.track(
            id: Self.sameArtistTrack.id.rawValue,
            url: Self.sameArtistTrack.url,
            title: "Other Song",
            artist: "Edited Artist",
            album: "Different Album"
        )
        let summary = BatchEditSummary(results: [
            BatchFileResult(url: Self.firstTrack.url, status: .succeeded, message: nil),
            BatchFileResult(url: Self.sameArtistTrack.url, status: .succeeded, message: nil),
        ])
        let reloader = RecordingTrackReloader(results: [
            .failure(TrackReloadTestError.reloadFailed),
            .success(editedOther),
        ])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[
                .loaded(Self.firstTrack),
                .loaded(Self.sameArtistTrack),
                .finished,
            ]]),
            batchEditor: FakeBatchEditor(summary: summary),
            trackReloader: reloader
        )

        await runBatchEdit(
            viewModel,
            selecting: [Self.firstTrack.id, Self.sameArtistTrack.id]
        )

        #expect(viewModel.tracks.count == 2)
        #expect(viewModel.tracks.contains(Self.firstTrack))
        #expect(viewModel.tracks.contains(editedOther))
        guard case let .completed(reconciledSummary) = viewModel.batchState else {
            Issue.record("Expected completed batch summary")
            return
        }
        #expect(reconciledSummary.results[0].message?.contains("列表更新失败，请手动刷新") == true)
        #expect(reconciledSummary.results[1].message == nil)
    }

    @Test("目录字符串前缀相同但路径组件不同的迁移目标仍视为目录外")
    @MainActor
    func similarStringPrefixIsOutsideRoot() async {
        let destination = URL(
            fileURLWithPath: "/virtual/library-one-old/filename-match.mp3"
        )
        let summary = BatchEditSummary(results: [
            BatchFileResult(
                url: Self.firstTrack.url,
                status: .succeeded,
                message: nil,
                finalURL: destination,
                migrationStatus: .moved
            ),
        ])
        let reloader = RecordingTrackReloader(results: [])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[.loaded(Self.firstTrack), .finished]]),
            batchEditor: FakeBatchEditor(summary: summary),
            trackReloader: reloader
        )

        await runBatchEdit(viewModel, selecting: [Self.firstTrack.id])

        #expect(viewModel.tracks.isEmpty)
        #expect(await reloader.urls.isEmpty)
    }

    @Test("增量更新列表会按成功文件数发布逐文件进度")
    @MainActor
    func incrementalLibraryUpdatePublishesProgress() async {
        let editedOther = Self.track(
            id: Self.sameArtistTrack.id.rawValue,
            url: Self.sameArtistTrack.url,
            title: "Other Song",
            artist: "Edited Artist",
            album: "Different Album"
        )
        let summary = BatchEditSummary(results: [
            BatchFileResult(url: Self.firstTrack.url, status: .succeeded, message: nil),
            BatchFileResult(url: Self.sameArtistTrack.url, status: .succeeded, message: nil),
            BatchFileResult(url: Self.secondTrack.url, status: .failed, message: "写入失败"),
        ])
        let reloader = SteppedTrackReloader(results: [
            Self.editedFirstTrack,
            editedOther,
        ])
        let viewModel = makeViewModel(
            scanner: ScriptedScanner(scripts: [[
                .loaded(Self.firstTrack),
                .loaded(Self.sameArtistTrack),
                .loaded(Self.secondTrack),
                .finished,
            ]]),
            batchEditor: FakeBatchEditor(summary: summary),
            trackReloader: reloader
        )

        await viewModel.loadDirectory(firstRoot)
        for id in [Self.firstTrack.id, Self.sameArtistTrack.id, Self.secondTrack.id] {
            viewModel.toggleSelection(id)
        }
        viewModel.openBatchEditor()
        viewModel.batchArtist = "Edited Artist"
        viewModel.batchAcknowledgedNoBackup = true
        let run = Task { await viewModel.runBatchEdit() }

        await reloader.waitForCallCount(1)
        #expect(viewModel.batchState == .running(BatchProgress(
            completed: 0,
            total: 2,
            currentURL: Self.firstTrack.url,
            phase: .updatingLibrary
        )))

        await reloader.completeCall(0)
        await reloader.waitForCallCount(2)
        #expect(viewModel.batchState == .running(BatchProgress(
            completed: 1,
            total: 2,
            currentURL: Self.sameArtistTrack.url,
            phase: .updatingLibrary
        )))

        await reloader.completeCall(1)
        await run.value
        #expect(viewModel.batchState == .completed(summary))
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
        trackReloader: any AudioTrackReloading = FailingTrackReloader(),
        accessLog: AccessLog? = nil
    ) -> LibraryViewModel {
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(defaults: defaults, resolver: IdentityBookmarkResolver())
        let migrationStore = SecurityScopedDirectoryStore(
            storageKey: "audioToolbox.migrationDirectoryBookmark",
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )
        let accessor: any SecurityScopedResourceAccessing = accessLog ?? NoopAccessor()
        return LibraryViewModel(
            scanner: scanner,
            batchEditor: batchEditor,
            bookmarkStore: store,
            migrationBookmarkStore: migrationStore,
            trackReloader: trackReloader,
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
    private func runBatchEdit(
        _ viewModel: LibraryViewModel,
        selecting trackIDs: Set<FileIdentity>
    ) async {
        await viewModel.loadDirectory(firstRoot)
        await waitUntil { viewModel.scanState == .loaded(failures: []) }
        for trackID in trackIDs {
            viewModel.toggleSelection(trackID)
        }
        viewModel.openBatchEditor()
        viewModel.batchArtist = "Edited Artist"
        viewModel.batchAcknowledgedNoBackup = true
        await viewModel.runBatchEdit()
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

    private static func suspectedDuplicateTrack(
        id: String,
        fileName: String,
        title: String?,
        artist: String,
        album: String = "重复专辑",
        duration: TimeInterval?
    ) -> AudioTrack {
        AudioTrack(
            id: FileIdentity(rawValue: id),
            url: URL(fileURLWithPath: "/virtual/\(fileName)"),
            format: .mp3,
            metadata: AudioMetadata(
                title: title,
                artists: [artist],
                albums: [album],
                duration: duration
            ),
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isWritable: true,
            issue: nil
        )
    }

    private static func track(
        id: String,
        fileName: String,
        title: String,
        artist: String,
        album: String,
        format: AudioFormat = .mp3
    ) -> AudioTrack {
        track(
            id: id,
            url: URL(fileURLWithPath: "/virtual/library-one", isDirectory: true)
                .appendingPathComponent(fileName),
            title: title,
            artist: artist,
            album: album,
            format: format
        )
    }

    private static func track(
        id: String,
        url: URL,
        title: String,
        artist: String,
        album: String,
        format: AudioFormat = .mp3
    ) -> AudioTrack {
        AudioTrack(
            id: FileIdentity(rawValue: id),
            url: url,
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

private enum TrackReloadTestError: LocalizedError {
    case missingResult
    case reloadFailed

    var errorDescription: String? {
        switch self {
        case .missingResult:
            "缺少测试重载结果"
        case .reloadFailed:
            "测试重载失败"
        }
    }
}

private actor RecordingTrackReloader: AudioTrackReloading {
    private var results: [Result<AudioTrack, Error>]
    private(set) var urls: [URL] = []

    init(results: [Result<AudioTrack, Error>]) {
        self.results = results
    }

    func reload(url: URL) async throws -> AudioTrack {
        urls.append(url)
        guard !results.isEmpty else {
            throw TrackReloadTestError.missingResult
        }
        return try results.removeFirst().get()
    }
}

private actor SuspendedTrackReloader: AudioTrackReloading {
    private let result: AudioTrack
    private var started = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var completionContinuation: CheckedContinuation<Void, Never>?

    init(result: AudioTrack) {
        self.result = result
    }

    func reload(url: URL) async throws -> AudioTrack {
        started = true
        let continuations = startedContinuations
        startedContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
        return result
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func complete() {
        completionContinuation?.resume()
        completionContinuation = nil
    }
}

private actor SteppedTrackReloader: AudioTrackReloading {
    private let results: [AudioTrack]
    private var urls: [URL] = []
    private var callContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(results: [AudioTrack]) {
        self.results = results
    }

    func reload(url: URL) async throws -> AudioTrack {
        let index = urls.count
        urls.append(url)
        let readyWaiters = callCountWaiters.filter { $0.0 <= urls.count }
        callCountWaiters.removeAll { $0.0 <= urls.count }
        readyWaiters.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            callContinuations[index] = continuation
        }
        return results[index]
    }

    func waitForCallCount(_ count: Int) async {
        if urls.count >= count { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func completeCall(_ index: Int) {
        callContinuations.removeValue(forKey: index)?.resume()
    }
}

private struct FailingTrackReloader: AudioTrackReloading {
    func reload(url: URL) async throws -> AudioTrack {
        throw TrackReloadTestError.missingResult
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
