import XCTest
@testable import Beacons

final class DriveModeStateTests: XCTestCase {
    private lazy var defaults = isolatedDefaults()

    func testMissingChoiceIsEnabledByDefault() {
        XCTAssertNil(DriveModeState.storedChoice(in: defaults))
        XCTAssertTrue(DriveModeState.wanted(in: defaults))
    }

    func testExplicitOffOverridesDefault() {
        DriveModeState.setWanted(false, in: defaults)
        XCTAssertFalse(DriveModeState.wanted(in: defaults))
    }

    func testOnlySwipeDismissalInfersExplicitOff() {
        XCTAssertTrue(shouldPreserveLiveModeIntent(after: .ended))
        XCTAssertFalse(shouldPreserveLiveModeIntent(after: .dismissed))
    }
}
