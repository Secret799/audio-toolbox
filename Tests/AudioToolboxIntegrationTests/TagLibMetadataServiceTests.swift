import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("TagLib metadata service")
struct TagLibMetadataServiceTests {
    private let writableFixtureNames = [
        "sample.mp3",
        "sample.m4a",
        "sample.flac",
        "sample.wav",
        "sample.ogg"
    ]

    @Test("reads title, artist, album, and duration from common formats")
    func readsCommonFormatMetadata() async throws {
        let service = TagLibMetadataService()

        for name in writableFixtureNames {
            let metadata = try await service.read(url: try fixtureURL(name))

            #expect(metadata.title == "Fixture Title", "Unexpected title for \(name)")
            #expect(metadata.artists.first == "Original Artist", "Unexpected artist for \(name)")
            #expect(metadata.albums.first == "Original Album", "Unexpected album for \(name)")
            #expect(
                (0.1...1.0).contains(metadata.duration ?? 0),
                "Unexpected duration for \(name): \(String(describing: metadata.duration))"
            )
        }
    }

    @Test("raw AAC without tags is explicitly unreadable")
    func rawAACWithoutTagsIsUnreadable() async throws {
        let service = TagLibMetadataService()
        let url = try fixtureURL("sample.aac")

        do {
            _ = try await service.read(url: url)
            Issue.record("Expected untagged raw AAC to be unreadable")
        } catch let error as MetadataServiceError {
            guard case let .unreadable(message) = error else {
                Issue.record("Unexpected metadata error: \(error)")
                return
            }
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("reports an unreadable error for a missing file")
    func reportsMissingFile() async {
        let service = TagLibMetadataService()
        let missingURL = URL(fileURLWithPath: "/不存在/音频.mp3")

        await #expect(
            throws: MetadataServiceError.unreadable("无法打开或识别音频文件")
        ) {
            _ = try await service.read(url: missingURL)
        }
    }

    @Test("writes artist and preserves album and title in common formats")
    func writesArtistAndPreservesAlbumAndTitle() async throws {
        let service = TagLibMetadataService()

        for name in writableFixtureNames {
            try await withFixtureCopy(name) { copy in
                #expect(await service.canWrite(url: copy), "Expected \(name) to be writable")

                try await service.write(
                    url: copy,
                    patch: MetadataPatch(artist: "New Artist", album: nil)
                )

                let metadata = try await service.read(url: copy)
                #expect(metadata.artists.first == "New Artist", "Unexpected artist for \(name)")
                #expect(metadata.albums.first == "Original Album", "Album changed for \(name)")
                #expect(metadata.title == "Fixture Title", "Title changed for \(name)")
            }
        }
    }

    @Test("writes only album and preserves artist and title")
    func writesOnlyAlbumAndPreservesOtherFields() async throws {
        let service = TagLibMetadataService()

        try await withFixtureCopy("sample.mp3") { copy in
            try await service.write(
                url: copy,
                patch: MetadataPatch(artist: nil, album: "New Album")
            )

            let metadata = try await service.read(url: copy)
            #expect(metadata.artists.first == "Original Artist")
            #expect(metadata.albums.first == "New Album")
            #expect(metadata.title == "Fixture Title")
        }
    }

    @Test("writes artist and album together")
    func writesArtistAndAlbumTogether() async throws {
        let service = TagLibMetadataService()

        try await withFixtureCopy("sample.flac") { copy in
            try await service.write(
                url: copy,
                patch: MetadataPatch(artist: "Both Artist", album: "Both Album")
            )

            let metadata = try await service.read(url: copy)
            #expect(metadata.artists.first == "Both Artist")
            #expect(metadata.albums.first == "Both Album")
            #expect(metadata.title == "Fixture Title")
        }
    }

    @Test("write capability probe does not modify the file")
    func canWriteProbeDoesNotModifyFile() async throws {
        let service = TagLibMetadataService()

        try await withFixtureCopy("sample.m4a") { copy in
            let before = try Data(contentsOf: copy)
            #expect(await service.canWrite(url: copy))
            let after = try Data(contentsOf: copy)

            #expect(after == before)
        }
    }

    @Test("raw AAC is explicitly not writable")
    func rawAACIsNotWritable() async throws {
        let service = TagLibMetadataService()

        try await withFixtureCopy("sample.aac") { copy in
            let before = try Data(contentsOf: copy)
            #expect(await !service.canWrite(url: copy))

            await #expect(
                throws: MetadataServiceError.notWritable("文件不可写或格式不支持标签写入")
            ) {
                try await service.write(
                    url: copy,
                    patch: MetadataPatch(artist: "New Artist", album: nil)
                )
            }
            #expect(try Data(contentsOf: copy) == before)
        }
    }

    private func withFixtureCopy<T>(
        _ name: String,
        operation: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioToolboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let copy = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try fixtureURL(name), to: copy)
        return try await operation(copy)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missing(name)
        }
        return url
    }
}

private enum FixtureError: Error {
    case missing(String)
}
