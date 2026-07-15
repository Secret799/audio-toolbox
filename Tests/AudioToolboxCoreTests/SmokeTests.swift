import XCTest
@testable import AudioToolboxCore

final class SmokeTests: XCTestCase {
    func testCoreModuleHasExpectedApplicationName() {
        XCTAssertEqual(AudioToolboxCore.applicationName, "Audio Toolbox")
    }
}
