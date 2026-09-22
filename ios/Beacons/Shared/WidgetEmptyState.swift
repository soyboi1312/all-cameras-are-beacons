import Foundation

/// The home-screen widget's bottom line when there is no last hit to show: an empty store, no
/// dateable row yet, or no session at all. Compiled into the app AND the widget extension (see
/// project.yml, BeaconsWidget sources) so BeaconsTests can pin it; the widget cannot be tested
/// from the hosted suite on its own.
///
/// NEUTRAL BY RULE: no check mark and no "all clear" green. This line shows when nothing
/// supported has been recognized, which is not the same as nothing being there ("quiet does not
/// mean clear", FirstRunTourView), and the SAME line shows when the beacon is not connected at
/// all, which proves nothing either way. Until 2026-09-20 both states drew a green
/// `checkmark.shield.fill` and read as an all-clear on a surface people glance at with the app
/// closed. The symbol is the half shield the Live Activity already draws on a zero
/// (DetectionLiveActivity), so the two glanceable surfaces agree.
///
/// TWIN: android widget/BeaconsWidgetProvider.kt `widgetLastLine`, whose empty state uses the
/// half-shield vector ic_w_shield in the dim ink. The words differ on purpose and predate this
/// file: Android's disconnected line reads "open the app to connect", because its widget cannot
/// tell a cold process from a real disconnect.
enum WidgetEmptyState {
    static let symbol = "shield.lefthalf.filled"

    static func text(connected: Bool) -> String {
        connected ? "no detections" : "not connected"
    }
}
