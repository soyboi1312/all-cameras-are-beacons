import XCTest
@testable import Beacons

/// IOS-CMP-02: the pinned banners (reconnect, sample data, offline sync) slide in on the y-axis.
/// Under Reduce Motion they must fade instead (HIG Accessibility: "Replacing transitions in x-, y-,
/// and z-axes with fades to avoid motion"). RootView.topBanners reads its transition from
/// pinnedBannerMotion, so pinning the policy pins what the banners do.
final class ReduceMotionBannerTests: XCTestCase {
    func testReduceMotionFadesThePinnedBanners() {
        XCTAssertEqual(pinnedBannerMotion(reduceMotion: true), .fade)
    }

    func testDefaultMotionKeepsTheSlide() {
        XCTAssertEqual(pinnedBannerMotion(reduceMotion: false), .slideFromTop)
    }
}
