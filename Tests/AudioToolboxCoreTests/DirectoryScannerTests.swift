import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("DirectoryScannerTests")
struct DirectoryScannerTests {
    @Test
    func candidateRecognizesSupportedExtensionsCaseInsensitively() {
        #expect(AudioFileCandidate.format(for: URL(fileURLWithPath: "/tmp/song.MP3")) == .mp3)
        #expect(AudioFileCandidate.format(for: URL(fileURLWithPath: "/tmp/track.FlAc")) == .flac)
        #expect(AudioFileCandidate.format(for: URL(fileURLWithPath: "/tmp/cover.jpg")) == nil)

        #expect(
            AudioFileCandidate.shouldSkip(
                URL(fileURLWithPath: "/tmp/.audio-toolbox-staging.mp3"),
                values: URLResourceValues()
            )
        )
        #expect(
            AudioFileCandidate.shouldSkip(
                URL(fileURLWithPath: "/tmp/.audio-toolbox-123.work/working.mp3"),
                values: URLResourceValues()
            )
        )
    }

    @Test
    func productionEnumeratorSkipsHiddenFilesAtEnumerationLayer() {
        #expect(DirectoryScanner.enumerationOptions.contains(.skipsHiddenFiles))
    }

    @Test
    func scannerRecursesAndIgnoresHiddenUnsupportedTemporaryAndSymlinkEntries() async throws {
        let directory = try TemporaryDirectory()
        let externalDirectory = try TemporaryDirectory()
        defer {
            directory.remove()
            externalDirectory.remove()
        }

        try directory.createFile("song.MP3", contents: "song")
        try directory.createFile("cover.jpg", contents: "cover")
        try directory.createFile(".hidden.mp3", contents: "hidden")
        try directory.createFile(".audio-toolbox-staging.mp3", contents: "temporary")
        try directory.createFile(
            ".audio-toolbox-12345678.work/working.mp3",
            contents: "private working copy"
        )
        try directory.createFile("album/track.FlAc", contents: "track")
        try directory.createFile(".hidden-album/secret.mp3", contents: "secret")
        try externalDirectory.createFile("external-only.mp3", contents: "external")
        try FileManager.default.createSymbolicLink(
            at: directory.url.appendingPathComponent("link.mp3"),
            withDestinationURL: directory.url.appendingPathComponent("song.MP3")
        )
        try FileManager.default.createSymbolicLink(
            at: directory.url.appendingPathComponent("linked-external-album"),
            withDestinationURL: externalDirectory.url
        )

        let service = FakeMetadataService()
        let events = await collect(DirectoryScanner(metadataService: service).scan(root: directory.url))
        let loaded = events.compactMap(loadedTrack)
        let readFileNames = await service.readFileNames()

        #expect(Set(loaded.map { $0.url.lastPathComponent }) == ["song.MP3", "track.FlAc"])
        #expect(loaded.allSatisfy { $0.metadata == .fixture })
        #expect(loaded.allSatisfy { $0.fileSize > 0 })
        #expect(loaded.allSatisfy { $0.modificationDate.timeIntervalSince1970 > 0 })
        #expect(loaded.allSatisfy { $0.isWritable })
        #expect(events.filter(isFinished).count == 1)
        #expect(events.last == .finished)
        #expect(readFileNames == ["song.MP3", "track.FlAc"])
        #expect(!readFileNames.contains("external-only.mp3"))
    }

    @Test
    func metadataFailureEmitsFailedAndScanningContinues() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        try directory.createFile("broken.mp3", contents: "broken")
        try directory.createFile("good.flac", contents: "good")

        let service = FakeMetadataService(failingFileNames: ["broken.mp3"])
        let events = await collect(DirectoryScanner(metadataService: service).scan(root: directory.url))

        #expect(events.contains { event in
            guard case let .failed(url, message) = event else { return false }
            return url.lastPathComponent == "broken.mp3" && message.contains("broken.mp3")
        })
        #expect(events.contains { event in
            guard case let .loaded(track) = event else { return false }
            return track.url.lastPathComponent == "good.flac"
        })
        #expect(events.compactMap(discoveredCount) == [1, 2])
        #expect(events.filter(isFinished).count == 1)
        #expect(events.last == .finished)
    }

    @Test
    func scannerAvoidsLoadingTheSameFileTwiceAndKeepsStableIdentity() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let original = try directory.createFile("song.mp3", contents: "song")
        try FileManager.default.linkItem(
            at: original,
            to: directory.url.appendingPathComponent("song-copy.mp3")
        )

        let service = FakeMetadataService()
        let scanner = DirectoryScanner(metadataService: service)
        let firstTracks = await collect(scanner.scan(root: directory.url)).compactMap(loadedTrack)
        let secondTracks = await collect(scanner.scan(root: directory.url)).compactMap(loadedTrack)

        #expect(firstTracks.count == 1)
        #expect(secondTracks.count == 1)
        #expect(firstTracks[0].id == secondTracks[0].id)
    }

    @Test
    func resourceIdentityArchivesVolumeAndFileIdentifiersDeterministically() throws {
        let url = URL(fileURLWithPath: "/tmp/../tmp/song.mp3")
        let first = DirectoryScanner.fileIdentity(
            for: url,
            fileResourceIdentifier: NSNumber(value: 42),
            volumeIdentifier: NSNumber(value: 7)
        )
        let repeated = DirectoryScanner.fileIdentity(
            for: url,
            fileResourceIdentifier: NSNumber(value: 42),
            volumeIdentifier: NSNumber(value: 7)
        )
        let otherVolume = DirectoryScanner.fileIdentity(
            for: url,
            fileResourceIdentifier: NSNumber(value: 42),
            volumeIdentifier: NSNumber(value: 8)
        )
        let fallback = DirectoryScanner.fileIdentity(
            for: url,
            fileResourceIdentifier: nil,
            volumeIdentifier: NSNumber(value: 7)
        )
        let archiveFailureFallback = DirectoryScanner.fileIdentity(
            for: url,
            fileResourceIdentifier: FailingSecureIdentifier(),
            volumeIdentifier: NSNumber(value: 7)
        )

        #expect(first == repeated)
        #expect(first != otherVolume)
        #expect(first.rawValue.hasPrefix("resource:"))
        #expect(first.rawValue.split(separator: ":").count == 3)
        let expectedFallback = "path:\(url.standardizedFileURL.resolvingSymlinksInPath().path)"
        #expect(fallback.rawValue == expectedFallback)
        #expect(archiveFailureFallback.rawValue == expectedFallback)
    }

    @Test
    func detailResourceFailureStillLoadsCandidateWithFallbackValues() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createFile("song.mp3", contents: "song")

        let enumerator = FakeDirectoryEnumerator(urls: [fileURL])
        let prefetchedKeys = LockedValue<Set<URLResourceKey>>([])
        let service = FakeMetadataService()
        let scanner = DirectoryScanner(
            metadataService: service,
            makeEnumerator: { _, keys, _ in
                prefetchedKeys.set(Set(keys))
                return enumerator
            },
            readResourceValues: { url, keys in
                if keys.contains(.fileSizeKey) {
                    throw FakeScannerError.detailsUnavailable
                }
                return try url.resourceValues(forKeys: keys)
            }
        )

        let events = await collect(scanner.scan(root: directory.url))
        let loaded = events.compactMap(loadedTrack)

        #expect(loaded.count == 1)
        #expect(loaded[0].fileSize == 0)
        #expect(loaded[0].modificationDate == .distantPast)
        #expect(
            loaded[0].id.rawValue
                == "path:\(fileURL.standardizedFileURL.resolvingSymlinksInPath().path)"
        )
        #expect(events.allSatisfy { event in
            if case .failed = event { return false }
            return true
        })
        #expect(
            prefetchedKeys.get()
                == [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        )
    }

    @Test
    func traversalFailureForFileDoesNotPruneFollowingDirectory() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let brokenURL = try directory.createFile("broken.mp3", contents: "broken")
        let trackURL = try directory.createFile("album/track.mp3", contents: "track")
        let albumURL = trackURL.deletingLastPathComponent()

        let enumerator = FakeDirectoryEnumerator(
            urls: [brokenURL, albumURL, trackURL],
            discardRemainingOnSkip: true
        )
        let service = FakeMetadataService()
        let scanner = DirectoryScanner(
            metadataService: service,
            makeEnumerator: { _, _, _ in enumerator },
            readResourceValues: { url, keys in
                if url == brokenURL && keys.contains(.isRegularFileKey) {
                    throw FakeScannerError.traversalUnavailable
                }
                return try url.resourceValues(forKeys: keys)
            }
        )

        let events = await collect(scanner.scan(root: directory.url))

        #expect(events.contains { event in
            guard case let .failed(url, _) = event else { return false }
            return url == brokenURL
        })
        #expect(events.contains { event in
            guard case let .loaded(track) = event else { return false }
            return track.url == trackURL
        })
        #expect(enumerator.skipCount == 0)
        #expect(await service.readFileNames() == ["track.mp3"])
        #expect(events.filter(isFinished).count == 1)
        #expect(events.last == .finished)
    }

    @Test
    func scannerChecksCancellationBeforeRequestingNextEnumeratorObject() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let firstURL = try directory.createFile("first.mp3", contents: "first")
        let secondURL = try directory.createFile("second.mp3", contents: "second")

        let enumerator = FakeDirectoryEnumerator(urls: [firstURL, secondURL])
        let service = FakeMetadataService()
        let scanner = DirectoryScanner(
            metadataService: service,
            makeEnumerator: { _, _, _ in enumerator },
            readResourceValues: { url, keys in try url.resourceValues(forKeys: keys) },
            iterationBoundary: {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        )

        let events = await collect(scanner.scan(root: directory.url))

        #expect(enumerator.nextCallCount == 1)
        #expect(events.compactMap(loadedTrack).map { $0.url } == [firstURL])
        #expect(events.filter(isFinished).count == 1)
        #expect(events.last == .finished)
    }

    @Test
    func cancellingConsumerStopsMetadataWork() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        for index in 0..<20 {
            try directory.createFile("album/track-\(index).mp3", contents: "track")
        }

        let service = FakeMetadataService(readDelay: .milliseconds(200))
        let scanner = DirectoryScanner(metadataService: service)
        let consumer = Task {
            await collect(scanner.scan(root: directory.url))
        }

        for _ in 0..<100 {
            if await service.readCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.readCount() == 1)

        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(250))

        #expect(await service.readCount() == 1)
    }

    @Test
    func rootEnumerationFailuresEmitFailedAndFinishOnce() async {
        let root = URL(fileURLWithPath: "/unavailable-root", isDirectory: true)
        let service = FakeMetadataService()
        let scanner = DirectoryScanner(
            metadataService: service,
            makeEnumerator: { _, _, _ in nil },
            readResourceValues: { url, keys in try url.resourceValues(forKeys: keys) }
        )

        let events = await collect(scanner.scan(root: root))

        #expect(events.contains { event in
            guard case let .failed(url, _) = event else { return false }
            return url == root
        })
        #expect(events.filter(isFinished).count == 1)
        #expect(events.last == .finished)
    }

    @Test
    func enumerationErrorHandlerEmitsFailedAndContinuesToFinished() async {
        let root = URL(fileURLWithPath: "/enumeration-root", isDirectory: true)
        let failedURL = root.appendingPathComponent("unreadable")
        let enumerator = FakeDirectoryEnumerator(urls: [])
        let service = FakeMetadataService()
        let scanner = DirectoryScanner(
            metadataService: service,
            makeEnumerator: { _, _, errorHandler in
                _ = errorHandler(failedURL, FakeScannerError.enumerationFailed)
                return enumerator
            },
            readResourceValues: { url, keys in try url.resourceValues(forKeys: keys) }
        )

        let events = await collect(scanner.scan(root: root))

        #expect(events.contains { event in
            guard case let .failed(url, message) = event else { return false }
            return url == failedURL && message.contains("enumerationFailed")
        })
        #expect(events.filter(isFinished).count == 1)
        #expect(events.last == .finished)
    }
}

private actor FakeMetadataService: MetadataService {
    private let failingFileNames: Set<String>
    private let readDelay: Duration?
    private var readURLs: [URL] = []

    init(failingFileNames: Set<String> = [], readDelay: Duration? = nil) {
        self.failingFileNames = failingFileNames
        self.readDelay = readDelay
    }

    func read(url: URL) async throws -> AudioMetadata {
        readURLs.append(url)
        if let readDelay {
            try await Task.sleep(for: readDelay)
        }
        if failingFileNames.contains(url.lastPathComponent) {
            throw MetadataServiceError.unreadable(url.lastPathComponent)
        }
        return .fixture
    }

    func canWrite(url: URL) async -> Bool {
        true
    }

    func write(url: URL, patch: MetadataPatch) async throws {}

    func readFileNames() -> [String] {
        readURLs.map(\.lastPathComponent).sorted()
    }

    func readCount() -> Int {
        readURLs.count
    }
}

private final class FakeDirectoryEnumerator: ScanningDirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private let discardRemainingOnSkip: Bool
    private var urls: [URL]
    private var index = 0
    private var storedNextCallCount = 0
    private var storedSkipCount = 0

    init(urls: [URL], discardRemainingOnSkip: Bool = false) {
        self.urls = urls
        self.discardRemainingOnSkip = discardRemainingOnSkip
    }

    func nextObject() -> Any? {
        lock.withLock {
            storedNextCallCount += 1
            guard index < urls.count else { return nil }
            defer { index += 1 }
            return urls[index]
        }
    }

    func skipDescendants() {
        lock.withLock {
            storedSkipCount += 1
            if discardRemainingOnSkip {
                index = urls.count
            }
        }
    }

    var nextCallCount: Int {
        lock.withLock { storedNextCallCount }
    }

    var skipCount: Int {
        lock.withLock { storedSkipCount }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.withLock { self.value = value }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}

@objc(DirectoryScannerTestsFailingSecureIdentifier)
private final class FailingSecureIdentifier: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    required init?(coder: NSCoder) {
        nil
    }

    override init() {}

    func encode(with coder: NSCoder) {
        coder.failWithError(FakeScannerError.archiveFailed)
    }
}

private enum FakeScannerError: Error {
    case detailsUnavailable
    case traversalUnavailable
    case enumerationFailed
    case archiveFailed
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func createFile(_ path: String, contents: String) throws -> URL {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private extension AudioMetadata {
    static let fixture = AudioMetadata(
        title: "Fixture",
        artists: ["Artist"],
        albums: ["Album"],
        duration: 120
    )
}

private func collect(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
    var events: [ScanEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func loadedTrack(_ event: ScanEvent) -> AudioTrack? {
    guard case let .loaded(track) = event else { return nil }
    return track
}

private func discoveredCount(_ event: ScanEvent) -> Int? {
    guard case let .discovered(count) = event else { return nil }
    return count
}

private func isFinished(_ event: ScanEvent) -> Bool {
    event == .finished
}
