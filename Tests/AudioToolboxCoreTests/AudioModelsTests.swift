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

    @Test
    func unknownDisplayValues() {
        let metadata = AudioMetadata(title: nil, artists: [], albums: [], duration: 1)

        #expect(metadata.artistDisplayName == "未知作者")
        #expect(metadata.albumDisplayName == "未知专辑")
    }
}
