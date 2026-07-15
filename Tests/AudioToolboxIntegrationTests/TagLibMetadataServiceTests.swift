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

    @Test("reads and probes FLAC with a leading ID3v2 tag")
    func readsFLACWithLeadingID3Tag() async throws {
        let service = TagLibMetadataService()
        var contents = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        contents.append(try Data(contentsOf: fixtureURL("sample.flac")))

        try await withTemporaryFile(named: "id3-prefixed.flac", contents: contents) { copy in
            let metadata = try await service.read(url: copy)
            #expect(metadata.title == "Fixture Title")
            #expect(await service.canWrite(url: copy))
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

    @Test("writes and rereads an artist stored beyond a 64 KiB ID3 tag")
    func writesArtistBeyondLargeID3Tag() async throws {
        let service = TagLibMetadataService()
        let largeArtist = String(repeating: "A", count: 70_000)

        try await withFixtureCopy("sample.mp3") { copy in
            try await service.write(
                url: copy,
                patch: MetadataPatch(artist: largeArtist, album: nil)
            )

            #expect(await service.canWrite(url: copy))
            let metadata = try await service.read(url: copy)
            #expect(metadata.artists.first == largeArtist)
            #expect(metadata.albums.first == "Original Album")
            #expect(metadata.title == "Fixture Title")
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

    @Test("rejects malformed or out-of-bounds ID3 declarations")
    func rejectsMalformedID3Declarations() async throws {
        let service = TagLibMetadataService()
        let mp3 = try Data(contentsOf: fixtureURL("sample.mp3"))
        let headers: [(String, [UInt8])] = [
            ("unsupported-version.mp3", [0x49, 0x44, 0x33, 0x05, 0x00, 0x00, 0, 0, 0, 0]),
            ("invalid-synchsafe.mp3", [0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x80, 0, 0, 0]),
            ("out-of-bounds.mp3", [0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x7F, 0x7F, 0x7F, 0x7F])
        ]

        for (name, header) in headers {
            var contents = Data(header)
            contents.append(mp3)
            try await withTemporaryFile(named: name, contents: contents) { copy in
                try await expectRejectedWritePreservingBytes(copy, service: service)
            }
        }
    }

    @Test("rejects malformed ID3 headers and v2.4 footers")
    func rejectsMalformedID3HeadersAndFooters() async throws {
        let service = TagLibMetadataService()
        let flac = try Data(contentsOf: fixtureURL("sample.flac"))
        let header = id3Header(major: 4, revision: 0, flags: 0x10)
        let footer = id3Footer(major: 4, revision: 0, flags: 0x10)

        var cases: [(String, Data)] = []
        cases.append(("missing-footer.flac", Data(header) + flac))
        cases.append(("truncated-footer.flac", Data(header) + Data(footer.prefix(5))))
        cases.append(("wrong-footer-identifier.flac", Data(header) + Data([0x42, 0x41, 0x44] + footer.dropFirst(3)) + flac))
        cases.append(("footer-version-mismatch.flac", Data(header) + Data(id3Footer(major: 3, revision: 0, flags: 0x10)) + flac))
        cases.append(("footer-revision-mismatch.flac", Data(header) + Data(id3Footer(major: 4, revision: 1, flags: 0x10)) + flac))
        cases.append(("footer-flags-mismatch.flac", Data(header) + Data(id3Footer(major: 4, revision: 0, flags: 0x00)) + flac))
        cases.append(("footer-size-mismatch.flac", Data(header) + Data(id3Footer(major: 4, revision: 0, flags: 0x10, size: [0, 0, 0, 1])) + flac))
        cases.append(("footer-non-synchsafe-size.flac", Data(header) + Data(id3Footer(major: 4, revision: 0, flags: 0x10, size: [0x80, 0, 0, 0])) + flac))
        cases.append(("header-revision-ff.flac", Data(id3Header(major: 4, revision: 0xFF, flags: 0x00)) + flac))
        cases.append(("v22-reserved-flags.flac", Data(id3Header(major: 2, revision: 0, flags: 0x20)) + flac))
        cases.append(("v23-reserved-flags.flac", Data(id3Header(major: 3, revision: 0, flags: 0x01)) + flac))
        cases.append(("v23-footer-flag.flac", Data(id3Header(major: 3, revision: 0, flags: 0x10)) + flac))
        cases.append(("v24-reserved-flags.flac", Data(id3Header(major: 4, revision: 0, flags: 0x01)) + flac))

        for (name, contents) in cases {
            try await withTemporaryFile(named: name, contents: contents) { copy in
                try await expectRejectedWritePreservingBytes(copy, service: service)
            }
        }
    }

    @Test("accepts a valid ID3v2.4 footer")
    func acceptsValidID3v24Footer() async throws {
        let service = TagLibMetadataService()
        var contents = Data(id3Header(major: 4, revision: 0, flags: 0x10))
        contents.append(contentsOf: id3Footer(major: 4, revision: 0, flags: 0x10))
        contents.append(try Data(contentsOf: fixtureURL("sample.flac")))

        try await withTemporaryFile(named: "valid-footer.flac", contents: contents) { copy in
            let metadata = try await service.read(url: copy)
            #expect(metadata.title == "Fixture Title")
            #expect(await service.canWrite(url: copy))
        }
    }

    @Test("rejects text disguised as MP3 without changing bytes")
    func rejectsTextDisguisedAsMP3() async throws {
        let service = TagLibMetadataService()
        let contents = Data("This is plain text, not MPEG audio.".utf8)

        try await withTemporaryFile(named: "disguised.mp3", contents: contents) { copy in
            try await expectRejectedWritePreservingBytes(copy, service: service)
        }
    }

    @Test("rejects an MPEG frame header without real audio")
    func rejectsMPEGHeaderWithoutAudio() async throws {
        let service = TagLibMetadataService()
        var contents = Data([0xFF, 0xFB, 0x90, 0x64])
        contents.append(Data(repeating: 0, count: 512))

        try await withTemporaryFile(named: "header-only.mp3", contents: contents) { copy in
            try await expectRejectedWritePreservingBytes(copy, service: service)
        }
    }

    @Test("rejects raw AAC renamed as MP3 without changing bytes")
    func rejectsRawAACRenamedAsMP3() async throws {
        let service = TagLibMetadataService()

        try await withFixtureCopy("sample.aac", named: "disguised.mp3") { copy in
            try await expectRejectedWritePreservingBytes(copy, service: service)
        }
    }

    @Test("rejects valid MP3 renamed as AAC without changing bytes")
    func rejectsMP3RenamedAsAAC() async throws {
        let service = TagLibMetadataService()

        try await withFixtureCopy("sample.mp3", named: "renamed.aac") { copy in
            try await expectRejectedWritePreservingBytes(copy, service: service)
        }
    }

    private func expectRejectedWritePreservingBytes(
        _ url: URL,
        service: TagLibMetadataService
    ) async throws {
        let before = try Data(contentsOf: url)
        await #expect(throws: MetadataServiceError.self) {
            _ = try await service.read(url: url)
        }
        #expect(await !service.canWrite(url: url))

        await #expect(
            throws: MetadataServiceError.notWritable("文件不可写或格式不支持标签写入")
        ) {
            try await service.write(
                url: url,
                patch: MetadataPatch(artist: "New Artist", album: nil)
            )
        }
        #expect(try Data(contentsOf: url) == before)
    }

    private func withFixtureCopy<T>(
        _ name: String,
        named copyName: String? = nil,
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

        let copy = directory.appendingPathComponent(copyName ?? name)
        try FileManager.default.copyItem(at: try fixtureURL(name), to: copy)
        return try await operation(copy)
    }

    private func withTemporaryFile<T>(
        named name: String,
        contents: Data,
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

        let file = directory.appendingPathComponent(name)
        try contents.write(to: file)
        return try await operation(file)
    }

    private func id3Header(
        major: UInt8,
        revision: UInt8,
        flags: UInt8,
        size: [UInt8] = [0, 0, 0, 0]
    ) -> [UInt8] {
        [0x49, 0x44, 0x33, major, revision, flags] + size
    }

    private func id3Footer(
        major: UInt8,
        revision: UInt8,
        flags: UInt8,
        size: [UInt8] = [0, 0, 0, 0]
    ) -> [UInt8] {
        [0x33, 0x44, 0x49, major, revision, flags] + size
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
