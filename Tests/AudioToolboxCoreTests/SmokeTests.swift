import Testing
@testable import AudioToolboxCore

@Suite("SmokeTests")
struct SmokeTests {
    @Test
    func supportsExpectedAudioFormats() {
        #expect(AudioFormat.allCases.count == 8)
    }
}
