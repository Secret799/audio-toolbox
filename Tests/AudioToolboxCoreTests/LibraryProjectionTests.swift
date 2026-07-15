import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("LibraryProjectionTests")
struct LibraryProjectionTests {
    @Test
    func groupsUnknownArtistWithItsTrack() {
        let tracks = [
            fixture(id: "2", artist: nil, album: "B"),
            fixture(id: "1", artist: "Alpha", album: "A")
        ]

        let groups = LibraryProjection.groups(
            tracks: tracks,
            mode: .artist,
            locale: Locale(identifier: "zh_CN")
        )
        let unknownGroup = groups.first { $0.displayName == "未知作者" }

        #expect(unknownGroup?.trackIDs == [FileIdentity(rawValue: "2")])
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

        #expect(Set(groups.map(\.displayName)) == Set(["Éclair", "Zulu", "未知专辑"]))
        #expect(groups.first { $0.displayName == "Éclair" }?.id == "album:Éclair")
        #expect(groups.first { $0.displayName == "未知专辑" }?.id == "album:未知专辑")
        #expect(groups.first { $0.displayName == "Zulu" }?.id == "album:Zulu")
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
    func keepsDistinctDisplayNamesInDistinctGroupsWithUniqueIDs() {
        let tracks = [
            fixture(id: "1", artist: "Alpha"),
            fixture(id: "2", artist: "alpha"),
            fixture(id: "3", artist: "Éclair"),
            fixture(id: "4", artist: "eclair")
        ]

        let groups = LibraryProjection.groups(
            tracks: tracks,
            mode: .artist,
            locale: Locale(identifier: "en_US")
        )

        #expect(groups.count == 4)
        #expect(Set(groups.map(\.id)).count == groups.count)
        #expect(Set(groups.map(\.id)) == Set([
            "artist:Alpha",
            "artist:alpha",
            "artist:Éclair",
            "artist:eclair"
        ]))
    }

    @Test
    func ordersEquivalentGroupNamesDeterministically() {
        let tracks = [
            fixture(id: "1", artist: "alpha"),
            fixture(id: "2", artist: "Alpha"),
            fixture(id: "3", artist: "Éclair"),
            fixture(id: "4", artist: "eclair")
        ]
        let locale = Locale(identifier: "en_US")

        let forward = LibraryProjection.groups(
            tracks: tracks,
            mode: .artist,
            locale: locale
        ).map(\.displayName)
        let reversed = LibraryProjection.groups(
            tracks: Array(tracks.reversed()),
            mode: .artist,
            locale: locale
        ).map(\.displayName)

        #expect(forward == ["Alpha", "alpha", "eclair", "Éclair"])
        #expect(reversed == forward)
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

    @Test
    func ordersEquivalentTrackNamesDeterministically() {
        let tracks = [
            fixture(id: "2", title: "alpha"),
            fixture(id: "1", title: "Alpha"),
            fixture(id: "b", title: "same"),
            fixture(id: "a", title: "same")
        ]
        let locale = Locale(identifier: "en_US")

        let forward = LibraryProjection.sortedTracks(tracks, locale: locale).map(\.id)
        let reversed = LibraryProjection.sortedTracks(
            Array(tracks.reversed()),
            locale: locale
        ).map(\.id)
        let expected = ["1", "2", "a", "b"].map(FileIdentity.init(rawValue:))

        #expect(forward == expected)
        #expect(reversed == expected)
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
