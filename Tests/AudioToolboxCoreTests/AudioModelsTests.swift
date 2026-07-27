import Testing
@testable import AudioToolboxCore

@Suite("AudioModelsTests")
struct AudioModelsTests {
    @Test
    func metadataPatchTrimsValuesAndRejectsEmptyRequest() {
        #expect(
            MetadataPatch(artist: "  New Artist  ", album: "  ")
                == MetadataPatch(artist: "New Artist", album: nil)
        )
        #expect(MetadataPatch.validated(artist: " ", album: "\n") == nil)
    }

    @Test("作曲者补丁去除空白并参与空补丁校验")
    func composerPatchNormalization() {
        #expect(
            MetadataPatch(artist: nil, album: nil, composer: "  Composer  ")
                == MetadataPatch(artist: nil, album: nil, composer: "Composer")
        )
        #expect(
            MetadataPatch.validated(
                artist: nil,
                album: nil,
                composer: " \n"
            ) == nil
        )
        #expect(AudioMetadata(
            title: nil,
            artists: [],
            albums: [],
            composers: [],
            duration: nil
        ).composerDisplayName == "未设置")
    }

    @Test
    func unknownDisplayValues() {
        let metadata = AudioMetadata(title: nil, artists: [], albums: [], duration: 1)

        #expect(metadata.artistDisplayName == "未知作者")
        #expect(metadata.albumDisplayName == "未知专辑")
    }
}
