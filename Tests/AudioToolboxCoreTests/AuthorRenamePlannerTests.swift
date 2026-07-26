import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("AuthorRenamePlannerTests")
struct AuthorRenamePlannerTests {
    @Test("作者列表区分未知作者并统计可编辑状态")
    func rowsGroupAuthorsAndCountEditability() {
        let tracks = [
            track(id: "a-1", artists: [" Artist A "]),
            track(id: "a-2", artists: ["Artist A"], isEditable: false),
            track(id: "b", artists: ["", " Artist B "]),
            track(id: "literal-unknown", artists: ["未知作者"]),
            track(id: "unknown", artists: ["  "]),
        ]

        let rows = AuthorRenamePlanner.rows(
            from: tracks,
            locale: Locale(identifier: "zh_CN")
        )

        #expect(rows.count == 4)
        #expect(rows.map(\.id) == AuthorRenamePlanner.rows(
            from: tracks,
            locale: Locale(identifier: "zh_CN")
        ).map(\.id))
        #expect(rows.first(where: { $0.id == .named("Artist A") }) == AuthorRenameRow(
            id: .named("Artist A"),
            displayName: "Artist A",
            totalCount: 2,
            editableCount: 1,
            unavailableCount: 1
        ))
        #expect(rows.first(where: { $0.id == .named("Artist B") })?.totalCount == 1)
        #expect(rows.first(where: { $0.id == .named("未知作者") })?.totalCount == 1)
        #expect(rows.first(where: { $0.id == .unknown }) == AuthorRenameRow(
            id: .unknown,
            displayName: "未知作者",
            totalCount: 1,
            editableCount: 1,
            unavailableCount: 0
        ))
        #expect(AuthorRenamePlanner.identity(for: tracks[2]) == .named("Artist B"))
        #expect(AuthorRenamePlanner.identity(for: tracks[4]) == .unknown)
    }

    @Test("作者映射按原始快照生成只修改作者的逐文件操作")
    func plansMappingsWithoutChaining() {
        let tracks = [
            track(id: "a-editable", artists: ["A"]),
            track(id: "a-read-only", artists: ["A"], isEditable: false),
            track(id: "b-editable", artists: ["B"]),
            track(id: "unknown-editable", artists: []),
            track(id: "unchanged", artists: ["No Change"]),
            track(id: "empty-draft", artists: ["Empty"]),
        ]
        let drafts: [AuthorIdentity: String] = [
            .named("A"): " B ",
            .named("B"): "C",
            .named("No Change"): "No Change",
            .named("Empty"): "  ",
            .unknown: "Known",
        ]

        let previews = AuthorRenamePlanner.previews(
            tracks: tracks,
            drafts: drafts,
            locale: Locale(identifier: "zh_CN")
        )
        let operations = AuthorRenamePlanner.operations(
            tracks: tracks,
            drafts: drafts
        )

        #expect(Set(previews.map(\.id)) == [
            .named("A"),
            .named("B"),
            .unknown,
        ])
        #expect(previews.first(where: { $0.id == .named("A") }) == AuthorRenamePreview(
            id: .named("A"),
            oldAuthor: "A",
            newAuthor: "B",
            editableCount: 1,
            unavailableCount: 1
        ))
        #expect(operations.map(\.target.fileIdentity) == [
            FileIdentity(rawValue: "a-editable"),
            FileIdentity(rawValue: "b-editable"),
            FileIdentity(rawValue: "unknown-editable"),
        ])
        #expect(operations.map(\.patch) == [
            MetadataPatch(artist: "B", album: nil),
            MetadataPatch(artist: "C", album: nil),
            MetadataPatch(artist: "Known", album: nil),
        ])
        #expect(operations.allSatisfy { $0.patch.album == nil })
    }

    private func track(
        id: String,
        artists: [String],
        isEditable: Bool = true
    ) -> AudioTrack {
        AudioTrack(
            id: FileIdentity(rawValue: id),
            url: URL(fileURLWithPath: "/virtual/\(id).mp3"),
            format: .mp3,
            metadata: AudioMetadata(
                title: id,
                artists: artists,
                albums: ["Album"],
                duration: 120
            ),
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isWritable: isEditable,
            issue: nil
        )
    }
}
