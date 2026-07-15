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
    case scanning(discovered: Int, loaded: Int, failures: [LibraryScanFailure])
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

public struct BatchResultCounts: Equatable, Sendable {
    public let succeeded: Int
    public let failed: Int
    public let notProcessed: Int

    public init(succeeded: Int, failed: Int, notProcessed: Int) {
        self.succeeded = succeeded
        self.failed = failed
        self.notProcessed = notProcessed
    }

    public static let zero = BatchResultCounts(
        succeeded: 0,
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
    @Published public var selectedGroupID: String?
    @Published public private(set) var selectedTrackIDs: Set<FileIdentity> = []
    @Published public private(set) var scanState: LibraryScreenState = .idle
    @Published public private(set) var directoryOperationError: String?
    @Published public var searchText = ""
    @Published public private(set) var batchState: BatchSheetState = .closed
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
    @Published public var batchAcknowledgedNoBackup = false

    public var selectedCount: Int {
        selectedTrackIDs.count
    }

    public var canOpenBatchEditor: Bool {
        guard case .closed = batchState, !isBatchActive else { return false }
        return tracks.contains { track in
            track.isEditable && selectedTrackIDs.contains(track.id)
        }
    }

    public var isBatchSheetPresented: Bool {
        if case .closed = batchState { return false }
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
        switch batchState {
        case .editing, .running, .stopping:
            true
        case .closed, .completed:
            false
        }
    }

    public var batchEditTracks: [AudioTrack] {
        batchEditTrackSnapshot
    }

    public var validatedBatchPatch: MetadataPatch? {
        MetadataPatch.validated(artist: batchArtist, album: batchAlbum)
    }

    public var canAdvanceBatchEdit: Bool {
        guard case .editing = batchState else { return false }
        return validatedBatchPatch != nil
    }

    public var canExecuteBatchEdit: Bool {
        canAdvanceBatchEdit
            && batchAcknowledgedNoBackup
            && !batchEditTrackSnapshot.isEmpty
            && batchEditTrackSnapshot.allSatisfy(\.isEditable)
            && batchSnapshotIsCurrentlyEditable
    }

    private var batchSnapshotIsCurrentlyEditable: Bool {
        let currentTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return batchEditTrackSnapshot.allSatisfy { snapshot in
            currentTracks[snapshot.id]?.isEditable == true
        }
    }

    public var batchResultCounts: BatchResultCounts {
        guard case let .completed(summary) = batchState else { return .zero }
        return BatchResultCounts(
            succeeded: summary.succeededCount,
            failed: summary.failedCount,
            notProcessed: summary.notProcessedCount
        )
    }

    public var currentGroup: AudioGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.id == selectedGroupID }
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
        case let .scanning(_, _, failures), let .loaded(failures), let .empty(failures):
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
        let tracksInGroup = tracks.filter { visibleIDs.contains($0.id) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracksInGroup }

        return tracksInGroup.filter { track in
            let values: [String] = [
                track.metadata.title,
                track.url.lastPathComponent,
                track.metadata.artists.joined(separator: " "),
                track.metadata.albums.joined(separator: " "),
            ].compactMap { $0 }
            return values.contains { $0.localizedStandardContains(query) }
        }
    }

    private let scanner: any DirectoryScanning
    private let batchEditor: any BatchEditing
    private let bookmarkStore: SecurityScopedDirectoryStore
    private let makeAccessLease: AccessLeaseFactory

    private var selectionState = SelectionState()
    private var accessLease: SecurityScopedAccessLease?
    private var scanTask: Task<Void, Never>?
    private var batchProgressTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var batchGeneration: UInt64 = 0
    private var batchEditTrackSnapshot: [AudioTrack] = []
    private var hasAttemptedDirectoryRestore = false
    private var isRefreshingAfterBatch = false
    private var discoveredCount = 0
    private var scanFailureValues: [LibraryScanFailure] = []

    public init(
        scanner: any DirectoryScanning,
        batchEditor: any BatchEditing,
        bookmarkStore: SecurityScopedDirectoryStore,
        makeAccessLease: @escaping AccessLeaseFactory = {
            SecurityScopedAccessLease(url: $0)
        }
    ) {
        self.scanner = scanner
        self.batchEditor = batchEditor
        self.bookmarkStore = bookmarkStore
        self.makeAccessLease = makeAccessLease
    }

    deinit {
        scanTask?.cancel()
        batchProgressTask?.cancel()
    }

    public static func live(
        bookmarkStore: SecurityScopedDirectoryStore = SecurityScopedDirectoryStore()
    ) -> LibraryViewModel {
        let metadataService = TagLibMetadataService()
        let scanner = DirectoryScanner(metadataService: metadataService)
        let writer = SafeMetadataWriter(metadataService: metadataService)
        let batchEditor = BatchEditor(writer: writer)
        return LibraryViewModel(
            scanner: scanner,
            batchEditor: batchEditor,
            bookmarkStore: bookmarkStore
        )
    }

    public func loadDirectory(_ url: URL) async {
        guard !isBatchActive else { return }
        guard let task = startDirectoryLoad(
            url.standardizedFileURL,
            persistBookmark: true
        ) else {
            return
        }
        await Self.waitForScanTask(task)
    }

    public func restoreLastDirectoryIfNeeded() async {
        guard !hasAttemptedDirectoryRestore, !isBatchActive else { return }
        hasAttemptedDirectoryRestore = true
        await restoreLastDirectory()
    }

    public func restoreLastDirectory() async {
        guard !isBatchActive else { return }

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
                persistBookmark: false
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
        guard case .closed = batchState else { return }
        guard !selectedTrackIDs.isEmpty, !isBatchActive else { return }
        let selectedTracks = tracks.filter {
            $0.isEditable && selectedTrackIDs.contains($0.id)
        }
        guard !selectedTracks.isEmpty else { return }
        resetBatchDraft()
        batchEditTrackSnapshot = selectedTracks
        batchState = .editing
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
        guard canExecuteBatchEdit,
              let patch = validatedBatchPatch else {
            return
        }

        let selectedTracks = batchEditTrackSnapshot
        guard !selectedTracks.isEmpty else { return }

        batchGeneration &+= 1
        let generation = batchGeneration
        let directoryURL = currentDirectoryURL
        let retainedLease = accessLease
        let initialProgress = BatchProgress(
            completed: 0,
            total: selectedTracks.count,
            currentURL: nil
        )
        batchState = .running(initialProgress)

        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: BatchProgress.self
        )
        let progressTask = Task { @MainActor [weak self] in
            for await progress in progressStream {
                guard let self, self.batchGeneration == generation else { continue }
                switch self.batchState {
                case .stopping:
                    self.batchState = .stopping(progress)
                case .closed, .editing, .running, .completed:
                    self.batchState = .running(progress)
                }
            }
        }

        batchProgressTask?.cancel()
        batchProgressTask = progressTask

        let summary = await batchEditor.run(
            BatchEditRequest(
                targets: selectedTracks.map { track in
                    BatchEditTarget(
                        url: track.url,
                        fileIdentity: track.id,
                        fileSize: track.fileSize,
                        modificationDate: track.modificationDate
                    )
                },
                patch: patch
            )
        ) { progress in
            progressContinuation.yield(progress)
        }
        progressContinuation.finish()
        await progressTask.value
        if batchGeneration == generation {
            batchProgressTask = nil
        }

        guard batchGeneration == generation else {
            withExtendedLifetime(retainedLease) {}
            return
        }

        let shouldRefresh = directoryURL != nil
            && currentDirectoryURL == directoryURL
            && batchGeneration == generation
        isRefreshingAfterBatch = shouldRefresh
        defer { isRefreshingAfterBatch = false }

        batchState = .completed(summary)

        if let directoryURL, shouldRefresh {
            await refreshCurrentDirectory(directoryURL)
        }

        withExtendedLifetime(retainedLease) {}
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

    private func resetBatchDraft() {
        batchArtist = ""
        batchAlbum = ""
        batchAcknowledgedNoBackup = false
    }

    private var isBatchActive: Bool {
        if isRefreshingAfterBatch { return true }
        return switch batchState {
        case .editing, .running, .stopping:
            true
        case .closed, .completed:
            false
        }
    }

    @discardableResult
    private func startDirectoryLoad(
        _ url: URL,
        persistBookmark: Bool
    ) -> Task<Void, Never>? {
        directoryOperationError = nil
        let isSameDirectory = currentDirectoryURL == url
        let preservedGroupID = isSameDirectory ? selectedGroupID : nil
        let candidateLease = isSameDirectory ? nil : makeAccessLease(url)

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

    private func refreshCurrentDirectory(_ url: URL) async {
        invalidateScan()
        let generation = scanGeneration
        let task = beginScan(
            root: url,
            generation: generation,
            preservingGroupID: selectedGroupID
        )
        await task.value
    }

    private func invalidateScan() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
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
        scanFailureValues = []
        scanState = .scanning(discovered: 0, loaded: 0, failures: [])

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
                    self.publishScanningState()
                case let .loaded(track):
                    self.upsert(
                        track,
                        preservingMissingGroupID: preservingGroupID
                    )
                    self.publishScanningState()
                case let .unreadable(track, message):
                    self.scanFailureValues.append(
                        LibraryScanFailure(url: track.url, message: message)
                    )
                    self.upsert(
                        track,
                        preservingMissingGroupID: preservingGroupID
                    )
                    self.publishScanningState()
                case let .failed(url, message):
                    self.scanFailureValues.append(
                        LibraryScanFailure(url: url, message: message)
                    )
                    self.publishScanningState()
                case .finished:
                    receivedFinished = true
                    self.finishScan()
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
                self.finishScan()
            }
            self.scanTask = nil
        }

        scanTask = task
        return task
    }

    private func upsert(
        _ track: AudioTrack,
        preservingMissingGroupID: String?
    ) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
        } else {
            tracks.append(track)
        }
        if !track.isEditable {
            selectionState.setSelected([track.id], selected: false)
            publishSelection()
        }
        tracks = LibraryProjection.sortedTracks(tracks)
        rebuildGroups(preservingMissingGroupID: preservingMissingGroupID)
    }

    private func rebuildGroups(preservingMissingGroupID: String? = nil) {
        groups = LibraryProjection.groups(tracks: tracks, mode: groupingMode)
        repairSelectedGroup(preservingMissingGroupID: preservingMissingGroupID)
    }

    private func repairSelectedGroup(preservingMissingGroupID: String? = nil) {
        if let selectedGroupID,
           groups.contains(where: { $0.id == selectedGroupID }) {
            return
        }
        if let preservingMissingGroupID,
           selectedGroupID == preservingMissingGroupID {
            return
        }
        selectedGroupID = groups.first?.id
    }

    private func publishScanningState() {
        scanState = .scanning(
            discovered: discoveredCount,
            loaded: tracks.count,
            failures: scanFailureValues
        )
    }

    private func finishScan() {
        selectionState.retainOnly(Set(tracks.filter(\.isEditable).map(\.id)))
        publishSelection()
        rebuildGroups()
        if tracks.isEmpty {
            scanState = .empty(failures: scanFailureValues)
        } else {
            scanState = .loaded(failures: scanFailureValues)
        }
    }

    private func publishSelection() {
        selectedTrackIDs = selectionState.ids
    }
}
