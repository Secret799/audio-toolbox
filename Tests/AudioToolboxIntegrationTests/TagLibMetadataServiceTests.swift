import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("TagLib metadata service")
struct TagLibMetadataServiceTests {
    @Test("reads title, artist, album, and duration from common formats")
    func readsCommonFormatMetadata() async throws {
        let service = TagLibMetadataService()

        for name in ["sample.mp3", "sample.m4a", "sample.flac", "sample.wav", "sample.ogg"] {
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

    @Test("write is explicitly unsupported")
    func writeIsUnsupported() async throws {
        let service = TagLibMetadataService()
        let url = try fixtureURL("sample.mp3")
        let patch = MetadataPatch(artist: "Changed Artist", album: nil)

        await #expect(throws: MetadataServiceError.unsupported("标签写入尚未接入")) {
            try await service.write(url: url, patch: patch)
        }
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
