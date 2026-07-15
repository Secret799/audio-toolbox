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

public enum BatchSheetState: Equatable, Sendable {
    case closed
    case editing
    case running(BatchProgress)
    case stopping(BatchProgress)
    case completed(BatchEditSummary)
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
    @Published public var searchText = ""
    @Published public private(set) var batchState: BatchSheetState = .closed

    public var selectedCount: Int {
        selectedTrackIDs.count
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
        guard startDirectoryLoad(
            url.standardizedFileURL,
            persistBookmark: true
        ) != nil else {
            return
        }
        await Task.yield()
    }

    public func restoreLastDirectory() async {
        guard !isBatchActive else { return }

        invalidateScan()
        scanState = .restoring

        do {
            guard let restoredURL = try bookmarkStore.restore() else {
                scanState = .idle
                return
            }
            guard startDirectoryLoad(
                restoredURL.standardizedFileURL,
                persistBookmark: false
            ) != nil else {
                return
            }
            await Task.yield()
        } catch {
            scanState = .failed("无法恢复上次目录授权：\(error.localizedDescription)")
        }
    }

    public func toggleSelection(_ id: FileIdentity) {
        guard tracks.contains(where: { $0.id == id }) else { return }
        selectionState.toggle(id)
        publishSelection()
    }

    public func setCurrentGroupSelected(_ selected: Bool) {
        guard let selectedGroupID,
              let group = groups.first(where: { $0.id == selectedGroupID }) else {
            return
        }
        selectionState.setSelected(group.trackIDs, selected: selected)
        publishSelection()
    }

    public func openBatchEditor() {
        guard !selectedTrackIDs.isEmpty, !isBatchActive else { return }
        batchState = .editing
    }

    public func runBatchEdit(patch: MetadataPatch) async {
        guard !isBatchActive else { return }

        let selectedTracks = tracks.filter { selectedTrackIDs.contains($0.id) }
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
            BatchEditRequest(files: selectedTracks.map(\.url), patch: patch)
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
        case let .running(value), let .stopping(value):
            progress = value
        case .closed, .editing, .completed:
            return
        }

        batchState = .stopping(progress)
        await batchEditor.requestStop()
    }

    private var isBatchActive: Bool {
        if isRefreshingAfterBatch { return true }
        return switch batchState {
        case .running, .stopping:
            true
        case .closed, .editing, .completed:
            false
        }
    }

    @discardableResult
    private func startDirectoryLoad(
        _ url: URL,
        persistBookmark: Bool
    ) -> Task<Void, Never>? {
        let isSameDirectory = currentDirectoryURL == url
        let preservedGroupID = isSameDirectory ? selectedGroupID : nil
        let candidateLease = isSameDirectory ? nil : makeAccessLease(url)

        if persistBookmark {
            do {
                try bookmarkStore.save(url: url)
            } catch {
                scanState = .failed("无法保存目录授权：\(error.localizedDescription)")
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
        selectionState.retainOnly(Set(tracks.map(\.id)))
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
