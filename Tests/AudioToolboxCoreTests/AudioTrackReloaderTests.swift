import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("AudioTrackReloaderTests")
struct AudioTrackReloaderTests {
    @Test("单文件重载会读取完整曲目属性且不枚举目录")
    func reloadsOneAudioTrack() async throws {
        let fixture = try TemporaryReloadFixture(fileName: "track.mp3", contents: "test")
        defer { fixture.remove() }
        let metadata = AudioMetadata(
            title: "Title",
            artists: ["Artist"],
            albums: ["Album"],
            duration: 42
        )
        let service = StubReloadMetadataService(
            readResult: .success(metadata),
            canWriteResult: true
        )

        let track = try await AudioTrackReloader(metadataService: service)
            .reload(url: fixture.fileURL)

        #expect(track.url == fixture.fileURL)
        #expect(track.format == .mp3)
        #expect(track.metadata == metadata)
        #expect(track.fileSize == 4)
        #expect(track.modificationDate != .distantPast)
        #expect(track.isWritable)
        #expect(track.issue == nil)
        #expect(
            track.id.rawValue.hasPrefix("resource:")
                || track.id.rawValue.hasPrefix("posix:")
        )
        #expect(await service.readURLs == [fixture.fileURL])
        #expect(await service.canWriteURLs == [fixture.fileURL])
    }

    @Test("不支持的扩展名在读取元数据前失败")
    func rejectsUnsupportedFormatBeforeMetadataRead() async throws {
        let fixture = try TemporaryReloadFixture(fileName: "track.txt", contents: "test")
        defer { fixture.remove() }
        let service = StubReloadMetadataService(
            readResult: .success(
                AudioMetadata(title: nil, artists: [], albums: [], duration: nil)
            ),
            canWriteResult: true
        )

        do {
            _ = try await AudioTrackReloader(metadataService: service)
                .reload(url: fixture.fileURL)
            Issue.record("Expected unsupported format")
        } catch let error as AudioTrackReloadError {
            #expect(error == .unsupportedFormat(fixture.fileURL))
        }

        #expect(await service.readURLs.isEmpty)
        #expect(await service.canWriteURLs.isEmpty)
    }

    @Test("文件不存在时不会产生部分曲目")
    func rejectsMissingFile() async throws {
        let fixture = try TemporaryReloadFixture(fileName: "missing.mp3", contents: "test")
        fixture.remove()
        let service = StubReloadMetadataService(
            readResult: .success(
                AudioMetadata(title: nil, artists: [], albums: [], duration: nil)
            ),
            canWriteResult: true
        )

        do {
            _ = try await AudioTrackReloader(metadataService: service)
                .reload(url: fixture.fileURL)
            Issue.record("Expected missing file failure")
        } catch {
            #expect(!(error is AudioTrackReloadError))
        }

        #expect(await service.readURLs.isEmpty)
        #expect(await service.canWriteURLs.isEmpty)
    }

    @Test("元数据读取失败会原样抛出")
    func propagatesMetadataReadFailure() async throws {
        let fixture = try TemporaryReloadFixture(fileName: "broken.flac", contents: "test")
        defer { fixture.remove() }
        let expected = MetadataServiceError.unreadable("标签损坏")
        let service = StubReloadMetadataService(
            readResult: .failure(expected),
            canWriteResult: true
        )

        do {
            _ = try await AudioTrackReloader(metadataService: service)
                .reload(url: fixture.fileURL)
            Issue.record("Expected metadata failure")
        } catch let error as MetadataServiceError {
            #expect(error == expected)
        }

        #expect(await service.readURLs == [fixture.fileURL])
        #expect(await service.canWriteURLs.isEmpty)
    }
}

private actor StubReloadMetadataService: MetadataService {
    let readResult: Result<AudioMetadata, MetadataServiceError>
    let canWriteResult: Bool
    private(set) var readURLs: [URL] = []
    private(set) var canWriteURLs: [URL] = []

    init(
        readResult: Result<AudioMetadata, MetadataServiceError>,
        canWriteResult: Bool
    ) {
        self.readResult = readResult
        self.canWriteResult = canWriteResult
    }

    func read(url: URL) async throws -> AudioMetadata {
        readURLs.append(url)
        return try readResult.get()
    }

    func canWrite(url: URL) async -> Bool {
        canWriteURLs.append(url)
        return canWriteResult
    }

    func write(url: URL, patch: MetadataPatch) async throws {}
}

private struct TemporaryReloadFixture {
    let root: URL
    let fileURL: URL

    init(fileName: String, contents: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-toolbox-track-reloader-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = root.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
