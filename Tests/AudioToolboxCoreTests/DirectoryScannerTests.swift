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
    }

    @Test
    func scannerRecursesAndIgnoresHiddenUnsupportedTemporaryAndSymlinkEntries() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        try directory.createFile("song.MP3", contents: "song")
        try directory.createFile("cover.jpg", contents: "cover")
        try directory.createFile(".hidden.mp3", contents: "hidden")
        try directory.createFile(".audio-toolbox-staging.mp3", contents: "temporary")
        try directory.createFile("album/track.FlAc", contents: "track")
        try directory.createFile(".hidden-album/secret.mp3", contents: "secret")
        try FileManager.default.createSymbolicLink(
            at: directory.url.appendingPathComponent("link.mp3"),
            withDestinationURL: directory.url.appendingPathComponent("song.MP3")
        )
        try FileManager.default.createSymbolicLink(
            at: directory.url.appendingPathComponent("linked-album"),
            withDestinationURL: directory.url.appendingPathComponent("album", isDirectory: true)
        )

        let service = FakeMetadataService()
        let events = await collect(DirectoryScanner(metadataService: service).scan(root: directory.url))
        let loaded = events.compactMap(loadedTrack)

        #expect(Set(loaded.map { $0.url.lastPathComponent }) == ["song.MP3", "track.FlAc"])
        #expect(loaded.allSatisfy { $0.metadata == .fixture })
        #expect(loaded.allSatisfy { $0.fileSize > 0 })
        #expect(loaded.allSatisfy { $0.isWritable })
        #expect(events.filter(isFinished).count == 1)
        #expect(events.last == .finished)
        #expect(await service.readFileNames() == ["song.MP3", "track.FlAc"])
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
    func cancellingConsumerStopsRecursiveScan() async throws {
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
