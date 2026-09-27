import XCTest
@testable import Beacons

/// IOS-VIS-1: the app is dark-only, but .preferredColorScheme(.dark) applies only after launch.
/// Without UIUserInterfaceStyle = Dark the empty UILaunchScreen draws a white systemBackground on
/// a phone set to Light, a white flash before the black first screen. The suite is hosted by the
/// app target, so Bundle.main is the shipping app's Info.plist, as generated from project.yml.
final class LaunchAppearanceTests: XCTestCase {
    func testAppPinsDarkInterfaceStyle() {
        let style = Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String
        XCTAssertEqual(style, "Dark")
    }
}
