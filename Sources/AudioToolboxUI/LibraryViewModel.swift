import Combine
import Foundation
import AudioToolboxCore

public struct LibraryScanFailure: Equatable, Sendable {
    public let url: URL
    public let message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public enum LibraryScreenState: Equatable, Sendable {
    case idle
    case restoring
    case scanning(discovered: Int, processed: Int, loaded: Int, failures: [LibraryScanFailure])
    case loaded(failures: [LibraryScanFailure])
    case empty(failures: [LibraryScanFailure])
    case failed(String)
}

public enum CurrentGroupSelectionState: Equatable, Sendable {
    case none
    case mixed
    case all
}

public enum BatchSheetState: Equatable, Sendable {
    case closed
    case editing
    case running(BatchProgress)
    case stopping(BatchProgress)
    case completed(BatchEditSummary)
}

public enum AuthorManagementState: Equatable, Sendable {
    case closed
    case editing
    case previewing
    case running(BatchProgress)
    case stopping(BatchProgress)
    case completed(BatchEditSummary)
}

public enum AuthorManagementMode: Hashable, Sendable {
    case rename
    case artistComposerSync
}

public enum BatchFieldInitialState: Equatable, Sendable {
    case common(String)
    case mixed
    case empty
}

private extension BatchFieldInitialState {
    var commonValue: String? {
        guard case let .common(value) = self else { return nil }
        return value
    }
}

public struct BatchResultCounts: Equatable, Sendable {
    public let succeeded: Int
    public let warnings: Int
    public let moved: Int
    public let failed: Int
    public let notProcessed: Int

    public init(
        succeeded: Int,
        warnings: Int = 0,
        moved: Int = 0,
        failed: Int,
        notProcessed: Int
    ) {
        self.succeeded = succeeded
        self.warnings = warnings
        self.moved = moved
        self.failed = failed
        self.notProcessed = notProcessed
    }

    public static let zero = BatchResultCounts(
        succeeded: 0,
        warnings: 0,
        moved: 0,
        failed: 0,
        notProcessed: 0
    )
}

@MainActor
public final class LibraryViewModel: ObservableObject {
    public typealias AccessLeaseFactory = @MainActor (URL) -> SecurityScopedAccessLease

    @Published public private(set) var currentDirectoryURL: URL?
    @Published public private(set) var tracks: [AudioTrack] = []
    @Published public private(set) var groups: [AudioGroup] = []
    @Published public var groupingMode: GroupingMode = .artist {
        didSet {
            guard groupingMode != oldValue else { return }
            rebuildGroups()
        }
    }
    @Published public var groupSearchText = "" {
        didSet {
            guard groupSearchText != oldValue else { return }
            repairSelectedGroup()
        }
    }
    @Published public var selectedGroupID: String? {
        didSet {
            guard selectedGroupID != oldValue else { return }
            rebuildSuspectedDuplicateAnalysis()
        }
    }
    @Published public private(set) var selectedTrackIDs: Set<FileIdentity> = []
    @Published public private(set) var scanState: LibraryScreenState = .idle
    @Published public private(set) var directoryOperationError: String?
    @Published public var searchText = ""
    @Published public var titleSortOrder = [AudioTrackTitleComparator()]
    @Published public var showsSuspectedDuplicatesOnly = false
    @Published public var filtersInvalidAudioFiles = true {
        didSet {
            guard filtersInvalidAudioFiles != oldValue else { return }
            rebuildGroups()
            refreshTerminalScanState()
        }
    }
    @Published public private(set) var batchState: BatchSheetState = .closed
    @Published public private(set) var authorManagementState: AuthorManagementState = .closed
    @Published public private(set) var authorManagementMode: AuthorManagementMode = .rename
    @Published public var authorSearchText = ""
    @Published public private(set) var authorRenameDrafts: [AuthorIdentity: String] = [:]
    @Published public var authorRenameAcknowledgedNoBackup = false
    @Published public var artistComposerSearchText = ""
    @Published public var artistComposerAuthority: ArtistComposerAuthority = .artist
    @Published public private(set) var artistComposerDrafts: [ArtistComposerIdentity: String] = [:]
    @Published public var artistComposerAcknowledgedNoBackup = false
    @Published public var batchArtist = "" {
        didSet {
            if batchArtist != oldValue {
                batchAcknowledgedNoBackup = false
            }
        }
    }
    @Published public var batchAlbum = "" {
        didSet {
            if batchAlbum != oldValue {
                batchAcknowledgedNoBackup = false
            }
        }
    }
    @Published public var movesSuccessfulFiles = false {
        didSet {
            if movesSuccessfulFiles != oldValue {
                batchAcknowledgedNoBackup = false
            }
        }
    }
    @Published public private(set) var migrationDirectoryURL: URL?
    @Published public private(set) var migrationDirectoryError: String?
    @Published public var batchAcknowledgedNoBackup = false
    public private(set) var batchArtistInitialState: BatchFieldInitialState = .empty
    public private(set) var batchAlbumInitialState: BatchFieldInitialState = .empty
    public private(set) var authorRenameSnapshot: [AudioTrack] = []

    public var selectedCount: Int {
        selectedTrackIDs.count
    }

    public var canOpenBatchEditor: Bool {
        guard case .closed = batchState,
              case .closed = authorManagementState else {
            return false
        }
        return tracks.contains { track in
            track.isEditable && selectedTrackIDs.contains(track.id)
        }
    }

    public var canOpenAuthorManagement: Bool {
        guard case .closed = batchState,
              case .closed = authorManagementState,
              !tracks.isEmpty else {
            return false
        }
        return switch scanState {
        case .scanning, .loaded, .empty:
            true
        case .idle, .restoring, .failed:
            false
        }
    }

    public var isBatchSheetPresented: Bool {
        if case .closed = batchState { return false }
        return true
    }

    public var isAuthorManagementPresented: Bool {
        if case .closed = authorManagementState { return false }
        return true
    }

    public var isBatchExecutionActive: Bool {
        switch batchState {
        case .running, .stopping:
            true
        case .closed, .editing, .completed:
            false
        }
    }

    public var isLibraryInteractionLocked: Bool {
        isBatchActive || isAuthorManagementActive
    }

    public var authorRenameRows: [AuthorRenameRow] {
        AuthorRenamePlanner.rows(from: authorRenameSnapshot)
    }

    public var filteredAuthorRenameRows: [AuthorRenameRow] {
        let query = authorSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return authorRenameRows }
        return authorRenameRows.filter {
            $0.displayName.localizedStandardContains(query)
        }
    }

    public var authorRenamePreviews: [AuthorRenamePreview] {
        AuthorRenamePlanner.previews(
            tracks: authorRenameSnapshot,
            drafts: authorRenameDrafts
        )
    }

    public var authorRenameAuthorCount: Int {
        authorRenamePreviews.count
    }

    public var authorRenameFileCount: Int {
        authorRenamePreviews.reduce(0) { $0 + $1.editableCount }
    }

    public var canPreviewAuthorRenames: Bool {
        guard authorManagementMode == .rename,
              case .editing = authorManagementState else { return false }
        return !effectiveAuthorRenameOperations.isEmpty
    }

    public var canExecuteAuthorRenames: Bool {
        guard authorManagementMode == .rename,
              case .previewing = authorManagementState else { return false }
        return authorRenameAcknowledgedNoBackup
            && !effectiveAuthorRenameOperations.isEmpty
            && authorRenameOperationsAreCurrentlyEditable
    }

    public var artistComposerSyncRows: [ArtistComposerSyncRow] {
        ArtistComposerSyncPlanner.rows(from: authorRenameSnapshot)
    }

    public var filteredArtistComposerSyncRows: [ArtistComposerSyncRow] {
        let query = artistComposerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return artistComposerSyncRows }
        return artistComposerSyncRows.filter { row in
            row.artistDisplayName.localizedStandardContains(query)
                || row.composerDisplayName.localizedStandardContains(query)
        }
    }

    public var artistComposerSyncPreviews: [ArtistComposerSyncPreview] {
        ArtistComposerSyncPlanner.previews(
            tracks: authorRenameSnapshot,
            drafts: artistComposerDrafts
        )
    }

    public var artistComposerSyncGroupCount: Int {
        artistComposerSyncPreviews.count
    }

    public var artistComposerSyncFileCount: Int {
        artistComposerSyncPreviews.reduce(0) { $0 + $1.editableCount }
    }

    public var canPreviewArtistComposerSync: Bool {
        guard authorManagementMode == .artistComposerSync,
              case .editing = authorManagementState else { return false }
        return !effectiveArtistComposerSyncOperations.isEmpty
    }

    public var canExecuteArtistComposerSync: Bool {
        guard authorManagementMode == .artistComposerSync,
              case .previewing = authorManagementState else { return false }
        return artistComposerAcknowledgedNoBackup
            && !effectiveArtistComposerSyncOperations.isEmpty
            && artistComposerSyncOperationsAreCurrentlyEditable
    }

    public var batchEditTracks: [AudioTrack] {
        batchEditTrackSnapshot
    }

    public var batchArtistPrompt: String {
        batchPrompt(for: batchArtistInitialState, commonLabel: "原作者", mixedLabel: "多个不同作者")
    }

    public var batchAlbumPrompt: String {
        batchPrompt(for: batchAlbumInitialState, commonLabel: "原专辑", mixedLabel: "多个不同专辑")
    }

    public var validatedBatchPatch: MetadataPatch? {
        let operations = effectiveBatchOperations
        let artist = operations.contains { $0.patch.artist != nil }
            ? MetadataPatch(artist: batchArtist, album: nil).artist
            : nil
        let album = operations.contains { $0.patch.album != nil }
            ? MetadataPatch(artist: nil, album: batchAlbum).album
            : nil
        return MetadataPatch.validated(artist: artist, album: album)
    }

    public var batchActualModificationCount: Int {
        effectiveBatchOperations.count
    }

    public func effectiveBatchPatch(for track: AudioTrack) -> MetadataPatch? {
        let desiredArtist = MetadataPatch(artist: batchArtist, album: nil).artist
        let desiredAlbum = MetadataPatch(artist: nil, album: batchAlbum).album
        let originalArtist = Self.batchMetadataValue(track.metadata.artists)
        let originalAlbum = Self.batchMetadataValue(track.metadata.albums)
        let artist = desiredArtist != nil && desiredArtist != originalArtist
            ? desiredArtist
            : nil
        let album = desiredAlbum != nil && desiredAlbum != originalAlbum
            ? desiredAlbum
            : nil
        return MetadataPatch.validated(artist: artist, album: album)
    }

    public var canAdvanceBatchEdit: Bool {
        guard case .editing = batchState else { return false }
        return !effectiveBatchOperations.isEmpty
    }

    public var canExecuteBatchEdit: Bool {
        canAdvanceBatchEdit
            && batchAcknowledgedNoBackup
            && effectiveBatchOperationsAreCurrentlyEditable
            && (!movesSuccessfulFiles || hasValidMigrationDirectory)
    }

    public var isMigrationDirectoryValid: Bool {
        hasValidMigrationDirectory
    }

    private var effectiveBatchOperationsAreCurrentlyEditable: Bool {
        let currentTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return effectiveBatchOperations.allSatisfy { operation in
            currentTracks[operation.target.fileIdentity]?.isEditable == true
        }
    }

    private var effectiveBatchOperations: [BatchEditOperation] {
        batchEditTrackSnapshot.compactMap { track in
            guard let patch = effectiveBatchPatch(for: track) else { return nil }
            return BatchEditOperation(
                target: BatchEditTarget(
                    url: track.url,
                    fileIdentity: track.id,
                    fileSize: track.fileSize,
                    modificationDate: track.modificationDate
                ),
                patch: patch
            )
        }
    }

    public var batchResultCounts: BatchResultCounts {
        guard case let .completed(summary) = batchState else { return .zero }
        return BatchResultCounts(
            succeeded: summary.succeededCount,
            warnings: summary.succeededWithWarningCount,
            moved: summary.movedCount,
            failed: summary.failedCount,
            notProcessed: summary.notProcessedCount
        )
    }

    public var filteredGroups: [AudioGroup] {
        let query = groupSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.displayName.localizedStandardContains(query)
        }
    }

    public var groupSearchPrompt: String {
        groupingMode == .artist ? "搜索作者" : "搜索专辑"
    }

    public var groupSearchEmptyMessage: String {
        groupingMode == .artist ? "没有匹配的作者" : "没有匹配的专辑"
    }

    public var currentGroup: AudioGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.id == selectedGroupID }
    }

    public var suspectedDuplicateTrackCount: Int {
        suspectedDuplicateMemberships.count
    }

    public func suspectedDuplicateMembership(
        for trackID: FileIdentity
    ) -> SuspectedDuplicateMembership? {
        suspectedDuplicateMemberships[trackID]
    }

    public func suspectedDuplicateStatusText(for trackID: FileIdentity) -> String? {
        guard let membership = suspectedDuplicateMemberships[trackID] else { return nil }
        let percentage = Int((membership.similarity * 100).rounded())
        let durationDifference = membership.durationDifference.formatted(
            .number.precision(.fractionLength(1))
        )
        return "疑似重复 \(membership.groupNumber) · \(percentage)% · 相差 \(durationDifference) 秒"
    }

    public var currentGroupHasEditableTracks: Bool {
        guard let currentGroup else { return false }
        let editableIDs = Set(tracks.lazy.filter(\.isEditable).map(\.id))
        return currentGroup.trackIDs.contains(where: editableIDs.contains)
    }

    public var currentGroupSelectionState: CurrentGroupSelectionState {
        guard let currentGroup else { return .none }
        let editableIDs = Set(tracks.lazy.filter(\.isEditable).map(\.id))
        let selectableIDs = currentGroup.trackIDs.filter(editableIDs.contains)
        guard !selectableIDs.isEmpty else { return .none }

        let selectedInGroup = selectableIDs.reduce(into: 0) { count, id in
            if selectedTrackIDs.contains(id) {
                count += 1
            }
        }
        if selectedInGroup == 0 { return .none }
        if selectedInGroup == selectableIDs.count { return .all }
        return .mixed
    }

    public var visibleTracks: [AudioTrack] {
        guard filtersInvalidAudioFiles else { return tracks }
        return tracks.filter { $0.issue == nil }
    }

    public var visibleTrackCount: Int {
        visibleTracks.count
    }

    public var hiddenInvalidTrackCount: Int {
        filtersInvalidAudioFiles ? tracks.count(where: { $0.issue != nil }) : 0
    }

    public var emptyDirectoryMessage: String? {
        guard case let .empty(failures) = scanState,
              let currentDirectoryURL else {
            return nil
        }
        if !failures.isEmpty {
            return "\(currentDirectoryURL.lastPathComponent) 中没有成功载入的音频文件（\(failures.count) 个文件读取失败）"
        }
        return "\(currentDirectoryURL.lastPathComponent) 中没有支持的音频文件"
    }

    public var scanFailureCount: Int {
        scanFailures.count
    }

    public var scanFailures: [LibraryScanFailure] {
        switch scanState {
        case let .scanning(_, _, _, failures), let .loaded(failures), let .empty(failures):
            failures
        case .idle, .restoring, .failed:
            []
        }
    }

    public var scanFailureMessage: String? {
        guard !scanFailures.isEmpty else { return nil }
        return scanFailures
            .map { "\($0.url.lastPathComponent)：\($0.message)" }
            .joined(separator: "\n")
    }

    public var filteredTracks: [AudioTrack] {
        guard let selectedGroupID,
              let group = groups.first(where: { $0.id == selectedGroupID }) else {
            return []
        }

        let visibleIDs = Set(group.trackIDs)
        var tracksInGroup = tracks.filter { visibleIDs.contains($0.id) }
        if showsSuspectedDuplicatesOnly {
            tracksInGroup.removeAll { suspectedDuplicateMemberships[$0.id] == nil }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            tracksInGroup.removeAll { track in
                let values: [String] = [
                    track.metadata.title,
                    track.url.lastPathComponent,
                    track.metadata.artists.joined(separator: " "),
                    track.metadata.albums.joined(separator: " "),
                ].compactMap { $0 }
                return !values.contains { $0.localizedStandardContains(query) }
            }
        }

        let comparator = titleSortOrder.first ?? AudioTrackTitleComparator()
        return tracksInGroup.sorted {
            comparator.compare($0, $1) == .orderedAscending
        }
    }

    private var suspectedDuplicateMemberships: [
        FileIdentity: SuspectedDuplicateMembership
    ] = [:]

    private let scanner: any DirectoryScanning
    private let batchEditor: any BatchEditing
    private let bookmarkStore: SecurityScopedDirectoryStore
    private let migrationBookmarkStore: SecurityScopedDirectoryStore
    private let trackReloader: (any AudioTrackReloading)?
    private let makeAccessLease: AccessLeaseFactory

    private var selectionState = SelectionState()
    private var accessLease: SecurityScopedAccessLease?
    private var migrationAccessLease: SecurityScopedAccessLease?
    private var scanTask: Task<Void, Never>?
    private var scanFlushTask: Task<Void, Never>?
    private var batchProgressTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var batchGeneration: UInt64 = 0
    private var batchEditTrackSnapshot: [AudioTrack] = []
    private var hasAttemptedDirectoryRestore = false
    private var hasAttemptedMigrationDirectoryRestore = false
    private var discoveredCount = 0
    private var processedCount = 0
    private var loadedCount = 0
    private var scannedTracksByID: [FileIdentity: AudioTrack] = [:]
    private var pendingTracksByID: [FileIdentity: AudioTrack] = [:]
    private var scanFailureValues: [LibraryScanFailure] = []

    public init(
        scanner: any DirectoryScanning,
        batchEditor: any BatchEditing,
        bookmarkStore: SecurityScopedDirectoryStore,
        migrationBookmarkStore: SecurityScopedDirectoryStore = SecurityScopedDirectoryStore(
            storageKey: "audioToolbox.migrationDirectoryBookmark"
        ),
        trackReloader: (any AudioTrackReloading)? = nil,
        makeAccessLease: @escaping AccessLeaseFactory = {
            SecurityScopedAccessLease(url: $0)
        }
    ) {
        self.scanner = scanner
        self.batchEditor = batchEditor
        self.bookmarkStore = bookmarkStore
        self.migrationBookmarkStore = migrationBookmarkStore
        self.trackReloader = trackReloader
        self.makeAccessLease = makeAccessLease
    }

    deinit {
        scanTask?.cancel()
        scanFlushTask?.cancel()
        batchProgressTask?.cancel()
    }

    public static func live(
        bookmarkStore: SecurityScopedDirectoryStore = SecurityScopedDirectoryStore(),
        migrationBookmarkStore: SecurityScopedDirectoryStore = SecurityScopedDirectoryStore(
            storageKey: "audioToolbox.migrationDirectoryBookmark"
        )
    ) -> LibraryViewModel {
        let metadataService = TagLibMetadataService()
        let scanner = DirectoryScanner(metadataService: metadataService)
        let writer = SafeMetadataWriter(metadataService: metadataService)
        let batchEditor = BatchEditor(writer: writer)
        return LibraryViewModel(
            scanner: scanner,
            batchEditor: batchEditor,
            bookmarkStore: bookmarkStore,
            migrationBookmarkStore: migrationBookmarkStore,
            trackReloader: AudioTrackReloader(metadataService: metadataService)
        )
    }

    public func loadDirectory(_ url: URL) async {
        guard !isEditingWorkflowActive else { return }
        guard let task = startDirectoryLoad(
            url.standardizedFileURL,
            persistBookmark: true
        ) else {
            return
        }
        await Self.waitForScanTask(task)
    }

    public func restoreLastDirectoryIfNeeded() async {
        guard !hasAttemptedDirectoryRestore, !isEditingWorkflowActive else { return }
        hasAttemptedDirectoryRestore = true
        await restoreLastDirectory()
    }

    public func restoreMigrationDirectoryIfNeeded() async {
        guard !hasAttemptedMigrationDirectoryRestore else { return }
        hasAttemptedMigrationDirectoryRestore = true
        migrationDirectoryError = nil

        do {
            guard let restoredURL = try migrationBookmarkStore.restore() else {
                return
            }
            let url = restoredURL.standardizedFileURL
            let lease = makeAccessLease(url)
            guard lease.didStart else {
                clearMigrationDirectory(
                    message: "迁移目录授权已失效，请重新选择目录。"
                )
                return
            }
            guard Self.isDirectory(url) else {
                clearMigrationDirectory(
                    message: "上次迁移目录已不存在，请重新选择目录。"
                )
                return
            }

            migrationAccessLease = lease
            migrationDirectoryURL = url
        } catch {
            clearMigrationDirectory(
                message: "无法恢复迁移目录授权：\(error.localizedDescription)"
            )
        }
    }

    public func chooseMigrationDirectory(_ selectedURL: URL) {
        let url = selectedURL.standardizedFileURL
        migrationDirectoryError = nil
        let lease = makeAccessLease(url)
        guard lease.didStart else {
            migrationDirectoryError = "无法取得迁移目录权限，请重新选择目录。"
            return
        }
        guard Self.isDirectory(url) else {
            migrationDirectoryError = "所选迁移目录不存在或不是文件夹。"
            return
        }

        do {
            try migrationBookmarkStore.save(url: url)
        } catch {
            migrationDirectoryError = "无法保存迁移目录授权：\(error.localizedDescription)"
            return
        }

        migrationAccessLease = lease
        migrationDirectoryURL = url
        movesSuccessfulFiles = true
    }

    public func restoreLastDirectory() async {
        guard !isEditingWorkflowActive else { return }

        directoryOperationError = nil
        invalidateScan()
        scanState = .restoring

        do {
            guard let restoredURL = try bookmarkStore.restore() else {
                scanState = .idle
                return
            }
            guard let task = startDirectoryLoad(
                restoredURL.standardizedFileURL,
                persistBookmark: false,
                requireSecurityScopeStarted: true
            ) else {
                return
            }
            await Self.waitForScanTask(task)
        } catch {
            scanState = .failed("无法恢复上次目录授权：\(error.localizedDescription)")
        }
    }

    private nonisolated static func waitForScanTask(
        _ task: Task<Void, Never>
    ) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func toggleSelection(_ id: FileIdentity) {
        guard !isLibraryInteractionLocked else { return }
        guard tracks.contains(where: { $0.id == id && $0.isEditable }) else { return }
        selectionState.toggle(id)
        publishSelection()
    }

    public func clearSelection() {
        guard !isLibraryInteractionLocked else { return }
        selectionState.removeAll()
        publishSelection()
    }

    public func setCurrentGroupSelected(_ selected: Bool) {
        guard !isLibraryInteractionLocked else { return }
        guard let selectedGroupID,
              let group = groups.first(where: { $0.id == selectedGroupID }) else {
            return
        }
        let editableIDs = Set(
            tracks.lazy
                .filter { $0.isEditable }
                .map(\.id)
        )
        let affectedIDs = selected
            ? group.trackIDs.filter(editableIDs.contains)
            : group.trackIDs
        selectionState.setSelected(affectedIDs, selected: selected)
        publishSelection()
    }

    public func openBatchEditor() {
        guard case .closed = batchState,
              case .closed = authorManagementState else {
            return
        }
        guard !selectedTrackIDs.isEmpty else { return }
        let selectedTracks = tracks.filter {
            $0.isEditable && selectedTrackIDs.contains($0.id)
        }
        guard !selectedTracks.isEmpty else { return }
        batchEditTrackSnapshot = selectedTracks
        initializeBatchDraft(from: selectedTracks)
        movesSuccessfulFiles = hasValidMigrationDirectory
        batchState = .editing
    }

    public func openAuthorManagement() {
        guard canOpenAuthorManagement else { return }
        authorRenameSnapshot = tracks
        authorManagementMode = .rename
        authorRenameDrafts = [:]
        authorSearchText = ""
        authorRenameAcknowledgedNoBackup = false
        artistComposerDrafts = [:]
        artistComposerSearchText = ""
        artistComposerAuthority = .artist
        artistComposerAcknowledgedNoBackup = false
        authorManagementState = .editing
    }

    public func closeAuthorManagement() {
        switch authorManagementState {
        case .editing, .previewing, .completed:
            authorManagementState = .closed
            authorRenameSnapshot = []
            authorManagementMode = .rename
            authorRenameDrafts = [:]
            authorSearchText = ""
            authorRenameAcknowledgedNoBackup = false
            artistComposerDrafts = [:]
            artistComposerSearchText = ""
            artistComposerAuthority = .artist
            artistComposerAcknowledgedNoBackup = false
        case .closed, .running, .stopping:
            return
        }
    }

    public func setAuthorManagementMode(_ mode: AuthorManagementMode) {
        guard case .editing = authorManagementState else { return }
        authorManagementMode = mode
    }

    public func setAuthorRenameDraft(
        _ value: String,
        for author: AuthorIdentity
    ) {
        guard case .editing = authorManagementState else { return }
        authorRenameDrafts[author] = value
        authorRenameAcknowledgedNoBackup = false
    }

    public func applyArtistComposerAuthorityToAll() {
        guard authorManagementMode == .artistComposerSync,
              case .editing = authorManagementState else { return }
        artistComposerDrafts = ArtistComposerSyncPlanner.automaticDrafts(
            rows: artistComposerSyncRows,
            authority: artistComposerAuthority
        )
        artistComposerAcknowledgedNoBackup = false
    }

    public func setArtistComposerDraft(
        _ value: String,
        for identity: ArtistComposerIdentity
    ) {
        guard authorManagementMode == .artistComposerSync,
              case .editing = authorManagementState else { return }
        artistComposerDrafts[identity] = value
        artistComposerAcknowledgedNoBackup = false
    }

    public func showAuthorRenamePreview() {
        guard canPreviewAuthorRenames else { return }
        authorRenameAcknowledgedNoBackup = false
        authorManagementState = .previewing
    }

    public func returnToAuthorRenameEditing() {
        guard authorManagementMode == .rename,
              case .previewing = authorManagementState else { return }
        authorRenameAcknowledgedNoBackup = false
        authorManagementState = .editing
    }

    public func showArtistComposerPreview() {
        guard canPreviewArtistComposerSync else { return }
        artistComposerAcknowledgedNoBackup = false
        authorManagementState = .previewing
    }

    public func returnToArtistComposerEditing() {
        guard authorManagementMode == .artistComposerSync,
              case .previewing = authorManagementState else { return }
        artistComposerAcknowledgedNoBackup = false
        authorManagementState = .editing
    }

    public func closeBatchEditor() {
        switch batchState {
        case .editing, .completed:
            batchState = .closed
            resetBatchDraft()
            batchEditTrackSnapshot = []
        case .closed, .running, .stopping:
            return
        }
    }

    public func runBatchEdit() async {
        guard canExecuteBatchEdit else { return }
        let operations = effectiveBatchOperations
        guard !operations.isEmpty else { return }
        let migration = movesSuccessfulFiles
            ? migrationDirectoryURL.map(BatchMigrationConfiguration.init(destinationDirectory:))
            : nil
        guard !movesSuccessfulFiles || migration != nil else { return }

        guard let summary = await executeBatchOperations(
            operations,
            migration: migration,
            publishProgress: { [weak self] progress in
                self?.publishBatchProgress(progress)
            }
        ) else {
            return
        }
        batchState = .completed(summary)
    }

    public func runAuthorRenames() async {
        guard canExecuteAuthorRenames else { return }
        let operations = effectiveAuthorRenameOperations
        guard !operations.isEmpty else { return }

        guard let summary = await executeBatchOperations(
            operations,
            migration: nil,
            publishProgress: { [weak self] progress in
                self?.publishAuthorRenameProgress(progress)
            }
        ) else {
            return
        }
        authorManagementState = .completed(summary)
    }

    public func runArtistComposerSync() async {
        guard canExecuteArtistComposerSync else { return }
        let operations = effectiveArtistComposerSyncOperations
        guard !operations.isEmpty else { return }

        guard let summary = await executeBatchOperations(
            operations,
            migration: nil,
            publishProgress: { [weak self] progress in
                self?.publishAuthorRenameProgress(progress)
            }
        ) else {
            return
        }
        authorManagementState = .completed(summary)
    }

    private func executeBatchOperations(
        _ operations: [BatchEditOperation],
        migration: BatchMigrationConfiguration?,
        publishProgress: @MainActor @escaping (BatchProgress) -> Void
    ) async -> BatchEditSummary? {
        batchGeneration &+= 1
        let generation = batchGeneration
        let directoryURL = currentDirectoryURL
        let retainedLease = accessLease
        let retainedMigrationLease = migration == nil ? nil : migrationAccessLease
        let initialProgress = BatchProgress(
            completed: 0,
            total: operations.count,
            currentURL: nil,
            phase: .preparing
        )
        publishProgress(initialProgress)

        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: BatchProgress.self
        )
        let progressTask = Task { @MainActor [weak self] in
            for await progress in progressStream {
                guard let self, self.batchGeneration == generation else { continue }
                publishProgress(progress)
            }
        }

        batchProgressTask?.cancel()
        batchProgressTask = progressTask

        let summary = await batchEditor.run(
            BatchEditRequest(operations: operations, migration: migration)
        ) { progress in
            progressContinuation.yield(progress)
        }
        progressContinuation.finish()
        await progressTask.value
        if batchGeneration == generation {
            batchProgressTask = nil
        }

        guard batchGeneration == generation else {
            withExtendedLifetime((retainedLease, retainedMigrationLease)) {}
            return nil
        }

        let reconciledSummary = await reconcileBatchResults(
            summary,
            operations: operations,
            root: directoryURL,
            publishProgress: publishProgress
        )

        withExtendedLifetime((retainedLease, retainedMigrationLease)) {}
        return reconciledSummary
    }

    private func publishBatchProgress(_ progress: BatchProgress) {
        switch batchState {
        case .stopping:
            batchState = .stopping(progress)
        case .closed, .editing, .running, .completed:
            batchState = .running(progress)
        }
    }

    private func publishAuthorRenameProgress(_ progress: BatchProgress) {
        switch authorManagementState {
        case .stopping:
            authorManagementState = .stopping(progress)
        case .closed, .editing, .previewing, .running, .completed:
            authorManagementState = .running(progress)
        }
    }

    private func reconcileBatchResults(
        _ summary: BatchEditSummary,
        operations: [BatchEditOperation],
        root: URL?,
        publishProgress: @MainActor (BatchProgress) -> Void
    ) async -> BatchEditSummary {
        guard let root,
              currentDirectoryURL == root,
              let trackReloader else {
            return summary
        }
        var tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var updatedResults = summary.results
        let successfulResultCount = summary.results.count {
            $0.status == .succeeded
        }
        var completedResultCount = 0

        for (index, operation) in operations.enumerated() {
            guard updatedResults.indices.contains(index) else { break }
            let result = updatedResults[index]
            guard result.status == .succeeded else {
                continue
            }
            publishProgress(BatchProgress(
                completed: completedResultCount,
                total: successfulResultCount,
                currentURL: result.finalURL,
                phase: .updatingLibrary
            ))

            let oldIdentity = operation.target.fileIdentity
            selectionState.setSelected([oldIdentity], selected: false)
            if result.migrationStatus == .moved,
               !Self.contains(result.finalURL, in: root) {
                tracksByID.removeValue(forKey: oldIdentity)
                completedResultCount += 1
                continue
            }

            do {
                let track = try await trackReloader.reload(url: result.finalURL)
                tracksByID.removeValue(forKey: oldIdentity)
                tracksByID[track.id] = track
            } catch {
                if result.migrationStatus == .moved {
                    tracksByID.removeValue(forKey: oldIdentity)
                }
                updatedResults[index] = Self.appendingReloadWarning(
                    to: result,
                    error: error
                )
            }
            completedResultCount += 1
        }

        scannedTracksByID = tracksByID
        tracks = LibraryProjection.sortedTracks(Array(tracksByID.values))
        selectionState.retainOnly(Set(tracks.filter(\.isEditable).map(\.id)))
        publishSelection()
        rebuildGroups()
        refreshTerminalScanState()
        return BatchEditSummary(results: updatedResults)
    }

    private static func contains(_ fileURL: URL, in rootURL: URL) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        return fileComponents.count > rootComponents.count
            && fileComponents.starts(with: rootComponents)
    }

    private static func appendingReloadWarning(
        to result: BatchFileResult,
        error: Error
    ) -> BatchFileResult {
        let warning = "修改成功，但列表更新失败，请手动刷新：\(error.localizedDescription)"
        let message = [result.message, warning]
            .compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
        return BatchFileResult(
            url: result.url,
            status: result.status,
            message: message,
            recoveryURL: result.recoveryURL,
            finalURL: result.finalURL,
            migrationStatus: result.migrationStatus
        )
    }

    public func stopBatchEdit() async {
        let progress: BatchProgress
        switch batchState {
        case let .running(value):
            progress = value
        case .closed, .editing, .stopping, .completed:
            return
        }

        batchState = .stopping(progress)
        await batchEditor.requestStop()
    }

    public func stopAuthorManagement() async {
        let progress: BatchProgress
        switch authorManagementState {
        case let .running(value):
            progress = value
        case .closed, .editing, .previewing, .stopping, .completed:
            return
        }

        authorManagementState = .stopping(progress)
        await batchEditor.requestStop()
    }

    private func initializeBatchDraft(from tracks: [AudioTrack]) {
        batchAcknowledgedNoBackup = false
        batchArtistInitialState = Self.batchFieldInitialState(
            tracks.map { Self.batchMetadataValue($0.metadata.artists) }
        )
        batchAlbumInitialState = Self.batchFieldInitialState(
            tracks.map { Self.batchMetadataValue($0.metadata.albums) }
        )
        batchArtist = batchArtistInitialState.commonValue ?? ""
        batchAlbum = batchAlbumInitialState.commonValue ?? ""
    }

    private func resetBatchDraft() {
        batchArtist = ""
        batchAlbum = ""
        batchArtistInitialState = .empty
        batchAlbumInitialState = .empty
        batchAcknowledgedNoBackup = false
        movesSuccessfulFiles = false
    }

    private var hasValidMigrationDirectory: Bool {
        guard let migrationDirectoryURL,
              migrationAccessLease?.didStart == true else {
            return false
        }
        return Self.isDirectory(migrationDirectoryURL)
    }

    private func clearMigrationDirectory(message: String) {
        migrationAccessLease = nil
        migrationDirectoryURL = nil
        movesSuccessfulFiles = false
        migrationBookmarkStore.clear()
        migrationDirectoryError = message
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func batchPrompt(
        for state: BatchFieldInitialState,
        commonLabel: String,
        mixedLabel: String
    ) -> String {
        switch state {
        case .common:
            commonLabel
        case .mixed:
            mixedLabel
        case .empty:
            "原值为空"
        }
    }

    private static func batchFieldInitialState(
        _ values: [String?]
    ) -> BatchFieldInitialState {
        guard !values.isEmpty else { return .empty }
        let distinctValues = Set(values)
        guard distinctValues.count == 1 else { return .mixed }
        guard let value = values[0] else { return .empty }
        return .common(value)
    }

    private static func batchMetadataValue(_ values: [String]) -> String? {
        let normalizedValues = values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !normalizedValues.isEmpty else { return nil }
        return normalizedValues.joined(separator: " / ")
    }

    private var isBatchActive: Bool {
        return switch batchState {
        case .editing, .running, .stopping:
            true
        case .closed, .completed:
            false
        }
    }

    private var isAuthorManagementActive: Bool {
        return switch authorManagementState {
        case .editing, .previewing, .running, .stopping:
            true
        case .closed, .completed:
            false
        }
    }

    private var isEditingWorkflowActive: Bool {
        isBatchActive || isAuthorManagementActive
    }

    private var effectiveAuthorRenameOperations: [BatchEditOperation] {
        AuthorRenamePlanner.operations(
            tracks: authorRenameSnapshot,
            drafts: authorRenameDrafts
        )
    }

    private var authorRenameOperationsAreCurrentlyEditable: Bool {
        let currentTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return effectiveAuthorRenameOperations.allSatisfy { operation in
            currentTracks[operation.target.fileIdentity]?.isEditable == true
        }
    }

    private var effectiveArtistComposerSyncOperations: [BatchEditOperation] {
        ArtistComposerSyncPlanner.operations(
            tracks: authorRenameSnapshot,
            drafts: artistComposerDrafts
        )
    }

    private var artistComposerSyncOperationsAreCurrentlyEditable: Bool {
        let currentTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return effectiveArtistComposerSyncOperations.allSatisfy { operation in
            currentTracks[operation.target.fileIdentity]?.isEditable == true
        }
    }

    @discardableResult
    private func startDirectoryLoad(
        _ url: URL,
        persistBookmark: Bool,
        requireSecurityScopeStarted: Bool = false
    ) -> Task<Void, Never>? {
        directoryOperationError = nil
        let isSameDirectory = currentDirectoryURL == url
        let preservedGroupID = isSameDirectory ? selectedGroupID : nil
        let candidateLease = isSameDirectory ? nil : makeAccessLease(url)

        if requireSecurityScopeStarted,
           (candidateLease ?? accessLease)?.didStart != true {
            bookmarkStore.clear()
            directoryOperationError = "目录授权已失效，请重新选择目录。"
            scanState = .failed("上次目录授权已失效，请重新选择目录。")
            return nil
        }

        if persistBookmark {
            do {
                try bookmarkStore.save(url: url)
            } catch {
                directoryOperationError = "无法保存目录授权：\(error.localizedDescription)"
                return nil
            }
        }

        invalidateScan()
        let generation = scanGeneration

        if let candidateLease {
            accessLease = candidateLease
            currentDirectoryURL = url
            selectedGroupID = nil
            selectionState.removeAll()
            publishSelection()
        }

        return beginScan(
            root: url,
            generation: generation,
            preservingGroupID: preservedGroupID
        )
    }

    private func invalidateScan() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanFlushTask?.cancel()
        scanFlushTask = nil
        pendingTracksByID.removeAll(keepingCapacity: false)
    }

    private func beginScan(
        root: URL,
        generation: UInt64,
        preservingGroupID: String?
    ) -> Task<Void, Never> {
        tracks = []
        groups = []
        selectedGroupID = preservingGroupID
        discoveredCount = 0
        processedCount = 0
        loadedCount = 0
        scannedTracksByID = [:]
        pendingTracksByID = [:]
        scanFailureValues = []
        scanState = .scanning(
            discovered: 0,
            processed: 0,
            loaded: 0,
            failures: []
        )

        let stream = scanner.scan(root: root)
        let task = Task { @MainActor [weak self] in
            var receivedFinished = false

            eventLoop: for await event in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard self.scanGeneration == generation,
                      self.currentDirectoryURL == root else {
                    break
                }

                switch event {
                case let .discovered(count):
                    self.discoveredCount = count
                    self.scheduleScanFlush(
                        generation: generation,
                        root: root,
                        preservingGroupID: preservingGroupID
                    )
                case let .loaded(track):
                    self.loadedCount += 1
                    self.processedCount += 1
                    self.pendingTracksByID[track.id] = track
                    self.scheduleScanFlush(
                        generation: generation,
                        root: root,
                        preservingGroupID: preservingGroupID
                    )
                case let .unreadable(track, message):
                    self.processedCount += 1
                    self.scanFailureValues.append(
                        LibraryScanFailure(url: track.url, message: message)
                    )
                    self.pendingTracksByID[track.id] = track
                    self.scheduleScanFlush(
                        generation: generation,
                        root: root,
                        preservingGroupID: preservingGroupID
                    )
                case let .failed(url, message):
                    self.scanFailureValues.append(
                        LibraryScanFailure(url: url, message: message)
                    )
                    self.scheduleScanFlush(
                        generation: generation,
                        root: root,
                        preservingGroupID: preservingGroupID
                    )
                case .finished:
                    receivedFinished = true
                    self.finishScan(preservingGroupID: preservingGroupID)
                    break eventLoop
                }
            }

            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.scanGeneration == generation,
                  self.currentDirectoryURL == root else {
                return
            }
            if !receivedFinished {
                self.finishScan(preservingGroupID: preservingGroupID)
            }
            self.scanTask = nil
        }

        scanTask = task
        return task
    }

    private func scheduleScanFlush(
        generation: UInt64,
        root: URL,
        preservingGroupID: String?
    ) {
        guard scanFlushTask == nil else { return }
        scanFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled, let self else { return }
            guard self.scanGeneration == generation,
                  self.currentDirectoryURL == root else {
                return
            }
            self.scanFlushTask = nil
            self.flushScanUpdates(preservingGroupID: preservingGroupID)
        }
    }

    private func flushScanUpdates(preservingGroupID: String?) {
        if !pendingTracksByID.isEmpty {
            for (id, track) in pendingTracksByID {
                scannedTracksByID[id] = track
                if !track.isEditable {
                    selectionState.setSelected([id], selected: false)
                }
            }
            pendingTracksByID.removeAll(keepingCapacity: true)
            tracks = LibraryProjection.sortedTracks(Array(scannedTracksByID.values))
            publishSelection()
            rebuildGroups(preservingMissingGroupID: preservingGroupID)
        }
        publishScanningState()
    }

    private func rebuildGroups(preservingMissingGroupID: String? = nil) {
        groups = LibraryProjection.groups(tracks: visibleTracks, mode: groupingMode)
        repairSelectedGroup(preservingMissingGroupID: preservingMissingGroupID)
        rebuildSuspectedDuplicateAnalysis()
    }

    private func rebuildSuspectedDuplicateAnalysis() {
        guard let selectedGroupID,
              let group = groups.first(where: { $0.id == selectedGroupID }) else {
            suspectedDuplicateMemberships = [:]
            return
        }
        let groupIDs = Set(group.trackIDs)
        let groupTracks = tracks.filter { groupIDs.contains($0.id) }
        suspectedDuplicateMemberships = SuspectedDuplicateDetector.analyze(groupTracks)
    }

    private func repairSelectedGroup(preservingMissingGroupID: String? = nil) {
        if let selectedGroupID,
           filteredGroups.contains(where: { $0.id == selectedGroupID }) {
            return
        }
        let groupQuery = groupSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if groupQuery.isEmpty,
           let preservingMissingGroupID,
           selectedGroupID == preservingMissingGroupID,
           !groups.contains(where: { $0.id == preservingMissingGroupID }) {
            return
        }
        selectedGroupID = filteredGroups.first?.id
    }

    private func publishScanningState() {
        scanState = .scanning(
            discovered: discoveredCount,
            processed: processedCount,
            loaded: loadedCount,
            failures: scanFailureValues
        )
    }

    private func finishScan(preservingGroupID: String?) {
        scanFlushTask?.cancel()
        scanFlushTask = nil
        flushScanUpdates(preservingGroupID: preservingGroupID)
        selectionState.retainOnly(Set(tracks.filter(\.isEditable).map(\.id)))
        publishSelection()
        rebuildGroups()
        scanState = visibleTracks.isEmpty
            ? .empty(failures: scanFailureValues)
            : .loaded(failures: scanFailureValues)
    }

    private func refreshTerminalScanState() {
        switch scanState {
        case .loaded, .empty:
            scanState = visibleTracks.isEmpty
                ? .empty(failures: scanFailureValues)
                : .loaded(failures: scanFailureValues)
        case .idle, .restoring, .scanning, .failed:
            break
        }
    }

    private func publishSelection() {
        selectedTrackIDs = selectionState.ids
    }
}
