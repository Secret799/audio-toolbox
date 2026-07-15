import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("LibraryProjectionTests")
struct LibraryProjectionTests {
    @Test
    func groupsUnknownArtistAndSortsByDisplayName() {
        let tracks = [
            fixture(id: "2", artist: nil, album: "B"),
            fixture(id: "1", artist: "Alpha", album: "A")
        ]

        let groups = LibraryProjection.groups(
            tracks: tracks,
            mode: .artist,
            locale: Locale(identifier: "zh_CN")
        )

        #expect(groups.map(\.displayName) == ["Alpha", "未知作者"])
    }

    @Test
    func groupsByAlbumAndUsesUnknownAlbumDisplayName() {
        let tracks = [
            fixture(id: "1", artist: "Artist A", album: "Zulu"),
            fixture(id: "2", artist: "Artist B", album: nil),
            fixture(id: "3", artist: "Artist C", album: "Éclair")
        ]

        let groups = LibraryProjection.groups(
            tracks: tracks,
            mode: .album,
            locale: Locale(identifier: "en_US")
        )

        #expect(groups.map(\.displayName) == ["Éclair", "Zulu", "未知专辑"])
        #expect(groups.first { $0.displayName == "Éclair" }?.id == "album:eclair")
        #expect(groups.first { $0.displayName == "未知专辑" }?.id == "album:未知专辑")
        #expect(groups.first { $0.displayName == "Zulu" }?.id == "album:zulu")
    }

    @Test
    func sortsGroupsIgnoringCaseAndDiacritics() {
        let tracks = [
            fixture(id: "1", artist: "Zulu", album: "Album"),
            fixture(id: "2", artist: "éclair", album: "Album"),
            fixture(id: "3", artist: "alpha", album: "Album")
        ]

        let groups = LibraryProjection.groups(
            tracks: tracks,
            mode: .artist,
            locale: Locale(identifier: "en_US")
        )

        #expect(groups.map(\.displayName) == ["alpha", "éclair", "Zulu"])
    }

    @Test
    func sortsTracksByTrimmedTitleAndFallsBackToFileName() {
        let tracks = [
            fixture(id: "3", fileName: "Zulu.mp3", title: "  beta  "),
            fixture(id: "2", fileName: "éclair.mp3", title: "  "),
            fixture(id: "1", fileName: "Alpha.mp3", title: nil)
        ]

        let sorted = LibraryProjection.sortedTracks(
            tracks,
            locale: Locale(identifier: "en_US")
        )

        #expect(sorted.map(\.id) == [
            FileIdentity(rawValue: "1"),
            FileIdentity(rawValue: "3"),
            FileIdentity(rawValue: "2")
        ])
    }

    private func fixture(
        id: String,
        fileName: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        title: String? = nil
    ) -> AudioTrack {
        AudioTrack(
            id: FileIdentity(rawValue: id),
            url: URL(fileURLWithPath: "/library/\(fileName ?? "\(id).mp3")"),
            format: .mp3,
            metadata: AudioMetadata(
                title: title,
                artists: artist.map { [$0] } ?? [],
                albums: album.map { [$0] } ?? [],
                duration: 120
            ),
            fileSize: 1_024,
            isWritable: true,
            issue: nil
        )
    }
}
