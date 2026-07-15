import Testing
@testable import AudioToolboxCore

@Suite("SmokeTests")
struct SmokeTests {
    @Test
    func coreModuleHasExpectedApplicationName() {
        #expect(AudioToolboxCore.applicationName == "Audio Toolbox")
    }
}
