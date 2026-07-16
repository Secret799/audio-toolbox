import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("SuspectedDuplicateDetectorTests")
struct SuspectedDuplicateDetectorTests {
    @Test
    func matchesCopySuffixesAndCloseDurations() throws {
        let tracks = [
            fixture(id: "original", title: "姐弟1跨年", duration: 120),
            fixture(id: "copy", title: "姐弟1跨年 - copy (2)", duration: 121.8),
            fixture(id: "chinese-copy", title: "姐弟1跨年（复制 2）", duration: 120.5)
        ]

        let result = SuspectedDuplicateDetector.analyze(tracks)
        let original = try #require(result[tracks[0].id])
        let copy = try #require(result[tracks[1].id])
        let chineseCopy = try #require(result[tracks[2].id])

        #expect(original.groupNumber == copy.groupNumber)
        #expect(copy.groupNumber == chineseCopy.groupNumber)
        #expect(original.similarity >= 0.85)
        #expect(original.durationDifference <= 2)
    }

    @Test
    func onlyRemovesCopyWordsAtTitleEnd() {
        let tracks = [
            fixture(id: "inside", title: "Copy时代", duration: 60),
            fixture(id: "plain", title: "时代", duration: 60)
        ]

        #expect(SuspectedDuplicateDetector.analyze(tracks).isEmpty)
    }

    @Test
    func usesFilenameWithoutExtensionWhenTitleIsMissing() throws {
        let tracks = [
            fixture(id: "a", fileName: "故事.mp3", title: nil, duration: 300),
            fixture(id: "b", fileName: "故事 copy.flac", title: nil, duration: 301)
        ]

        let result = SuspectedDuplicateDetector.analyze(tracks)

        #expect(result.count == 2)
        #expect(try #require(result[tracks[0].id]).groupNumber
            == #require(result[tracks[1].id]).groupNumber)
    }

    @Test
    func appliesSimilarityAndDurationThresholds() {
        let titleThresholdPass = [
            fixture(id: "pass-a", title: "abcdefg", duration: 100),
            fixture(id: "pass-b", title: "abcdefx", duration: 102)
        ]
        let titleThresholdFail = [
            fixture(id: "fail-a", title: "abcdef", duration: 100),
            fixture(id: "fail-b", title: "abcdex", duration: 100)
        ]
        let durationFail = [
            fixture(id: "duration-a", title: "完全相同", duration: 120),
            fixture(id: "duration-b", title: "完全相同", duration: 122.1)
        ]
        let longDurationPass = [
            fixture(id: "long-a", title: "长音频", duration: 1_000),
            fixture(id: "long-b", title: "长音频 copy", duration: 1_009.9)
        ]

        #expect(SuspectedDuplicateDetector.analyze(titleThresholdPass).count == 2)
        #expect(SuspectedDuplicateDetector.analyze(titleThresholdFail).isEmpty)
        #expect(SuspectedDuplicateDetector.analyze(durationFail).isEmpty)
        #expect(SuspectedDuplicateDetector.analyze(longDurationPass).count == 2)
    }

    @Test
    func ignoresTracksWithoutReadableDuration() {
        let tracks = [
            fixture(id: "known", title: "相同标题", duration: 100),
            fixture(id: "unknown", title: "相同标题 copy", duration: nil)
        ]

        #expect(SuspectedDuplicateDetector.analyze(tracks).isEmpty)
    }

    @Test
    func mergesTransitivelyRelatedPairsIntoOneStableGroup() throws {
        let tracks = [
            fixture(id: "a", title: "abcdefghij", duration: 100),
            fixture(id: "b", title: "abcdefghiX", duration: 101),
            fixture(id: "c", title: "abcdefghXX", duration: 102)
        ]

        let result = SuspectedDuplicateDetector.analyze(tracks)
        let groupNumbers = try tracks.map { try #require(result[$0.id]).groupNumber }

        #expect(Set(groupNumbers).count == 1)
        #expect(groupNumbers == [1, 1, 1])
    }

    private func fixture(
        id: String,
        fileName: String? = nil,
        title: String?,
        duration: TimeInterval?
    ) -> AudioTrack {
        AudioTrack(
            id: FileIdentity(rawValue: id),
            url: URL(fileURLWithPath: "/virtual/\(fileName ?? "\(id).mp3")"),
            format: .mp3,
            metadata: AudioMetadata(
                title: title,
                artists: ["同一作者"],
                albums: ["同一专辑"],
                duration: duration
            ),
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isWritable: true,
            issue: nil
        )
    }
}
