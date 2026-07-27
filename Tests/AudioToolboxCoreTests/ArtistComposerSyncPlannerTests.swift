import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("ArtistComposerSyncPlannerTests")
struct ArtistComposerSyncPlannerTests {
    @Test("只分组作者与作曲者不一致的曲目并统计可编辑状态")
    func rowsGroupMismatchesAndCountEditability() {
        let tracks = fixtureTracks()

        let rows = ArtistComposerSyncPlanner.rows(
            from: tracks,
            locale: Locale(identifier: "zh_CN")
        )

        #expect(rows.count == 4)
        #expect(rows.map(\.id) == ArtistComposerSyncPlanner.rows(
            from: tracks,
            locale: Locale(identifier: "zh_CN")
        ).map(\.id))
        #expect(!rows.contains(where: {
            $0.id == ArtistComposerIdentity(artist: "A", composer: "A")
        }))
        #expect(rows.contains(where: {
            $0.id == ArtistComposerIdentity(artist: "A", composer: "a")
        }))

        let conflictID = ArtistComposerIdentity(artist: "D", composer: "E")
        #expect(rows.first(where: { $0.id == conflictID }) == ArtistComposerSyncRow(
            id: conflictID,
            artistDisplayName: "D",
            composerDisplayName: "E",
            totalCount: 2,
            editableCount: 1,
            unavailableCount: 1
        ))
        #expect(ArtistComposerSyncPlanner.identity(for: tracks[0])
            == ArtistComposerIdentity(artist: "A", composer: "A"))
    }

    @Test("自动草稿对空值始终使用非空侧并按所选基准解决冲突")
    func automaticDraftsUseNonEmptyValuesAndSelectedAuthority() {
        let rows = ArtistComposerSyncPlanner.rows(
            from: fixtureTracks(),
            locale: Locale(identifier: "zh_CN")
        )
        let artistOnlyID = ArtistComposerIdentity(artist: "B", composer: nil)
        let composerOnlyID = ArtistComposerIdentity(artist: nil, composer: "C")
        let conflictID = ArtistComposerIdentity(artist: "D", composer: "E")

        let artistDrafts = ArtistComposerSyncPlanner.automaticDrafts(
            rows: rows,
            authority: .artist
        )
        let composerDrafts = ArtistComposerSyncPlanner.automaticDrafts(
            rows: rows,
            authority: .composer
        )

        #expect(artistDrafts[artistOnlyID] == "B")
        #expect(composerDrafts[artistOnlyID] == "B")
        #expect(artistDrafts[composerOnlyID] == "C")
        #expect(composerDrafts[composerOnlyID] == "C")
        #expect(artistDrafts[conflictID] == "D")
        #expect(composerDrafts[conflictID] == "E")
    }

    @Test("手动草稿仅生成实际变化字段并保持快照顺序")
    func manualDraftsProduceMinimalOperationsInSnapshotOrder() {
        let tracks = fixtureTracks()
        let caseID = ArtistComposerIdentity(artist: "A", composer: "a")
        let artistOnlyID = ArtistComposerIdentity(artist: "B", composer: nil)
        let composerOnlyID = ArtistComposerIdentity(artist: nil, composer: "C")
        let conflictID = ArtistComposerIdentity(artist: "D", composer: "E")
        let drafts: [ArtistComposerIdentity: String] = [
            caseID: "Manual",
            artistOnlyID: "B",
            composerOnlyID: "C",
            conflictID: "Manual",
        ]

        let previews = ArtistComposerSyncPlanner.previews(
            tracks: tracks,
            drafts: drafts,
            locale: Locale(identifier: "zh_CN")
        )
        let operations = ArtistComposerSyncPlanner.operations(
            tracks: tracks,
            drafts: drafts
        )

        #expect(previews.first(where: { $0.id == conflictID }) == ArtistComposerSyncPreview(
            id: conflictID,
            artistDisplayName: "D",
            composerDisplayName: "E",
            unifiedValue: "Manual",
            editableCount: 1,
            unavailableCount: 1
        ))
        #expect(operations.map(\.target.fileIdentity) == [
            FileIdentity(rawValue: "case"),
            FileIdentity(rawValue: "artist-only"),
            FileIdentity(rawValue: "composer-only"),
            FileIdentity(rawValue: "conflict-1"),
        ])
        #expect(operations.map(\.patch) == [
            MetadataPatch(artist: "Manual", album: nil, composer: "Manual"),
            MetadataPatch(artist: nil, album: nil, composer: "B"),
            MetadataPatch(artist: "C", album: nil, composer: nil),
            MetadataPatch(artist: "Manual", album: nil, composer: "Manual"),
        ])
        #expect(operations.allSatisfy { $0.patch.album == nil })
    }

    private func fixtureTracks() -> [AudioTrack] {
        [
            track(id: "same", artist: "A", composer: " A "),
            track(id: "case", artist: "A", composer: "a"),
            track(id: "artist-only", artist: "B", composer: nil),
            track(id: "composer-only", artist: nil, composer: "C"),
            track(id: "conflict-1", artist: "D", composer: "E"),
            track(id: "conflict-2", artist: "D", composer: "E", isEditable: false),
        ]
    }

    private func track(
        id: String,
        artist: String?,
        composer: String?,
        isEditable: Bool = true
    ) -> AudioTrack {
        AudioTrack(
            id: FileIdentity(rawValue: id),
            url: URL(fileURLWithPath: "/virtual/\(id).mp3"),
            format: .mp3,
            metadata: AudioMetadata(
                title: id,
                artists: artist.map { [$0] } ?? [],
                albums: ["Album"],
                composers: composer.map { [$0] } ?? [],
                duration: 120
            ),
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isWritable: isEditable,
            issue: nil
        )
    }
}
