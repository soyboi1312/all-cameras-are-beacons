import ActivityKit
import Foundation

/// Live Activity model for a "Drive mode" detection session, shown in the Dynamic
/// Island and on the Lock Screen (and, on iOS 26+, mirrored to the CarPlay Dashboard).
///
/// Compiled into BOTH the app and the widget extension. Deliberately dependency-free
/// and Color-free: the widget maps each bucket to a symbol/tint with its own tokens,
/// so we never drag the app's `DeviceType`/`ACABTheme` (which pull SwiftUI `Color`)
/// into the extension. The four buckets mirror the dashboard tiles exactly
/// (ALPR = flockCamera + flockRaven, drone, body cam, tracker); there is no police
/// bucket because the app drops firmware `t=6` in Detection's decoder.
struct DetectionActivityAttributes: ActivityAttributes {
    typealias ContentState = DetectionState

    /// Static for the whole session.
    let deviceName: String
    let sessionStart: Date

    /// Live counts, pushed by the app as detections arrive. ~4 ints + 2 short
    /// strings, far under ActivityKit's 4 KB ContentState limit.
    struct DetectionState: Codable, Hashable {
        var alpr: Int          // flockCamera + flockRaven
        var drones: Int
        var bodyCams: Int
        var trackers: Int
        var lastKind: String   // "ALPR" / "DRONE" / "BODY CAM" / "TRACKER" / ""
        var lastSeen: Date
        var connected: Bool    // false -> show "Reconnecting…" instead of a frozen count
        var redact: Bool       // hide counts on the Lock Screen banner (user setting, default on)

        var total: Int { alpr + drones + bodyCams + trackers }

        static let empty = DetectionState(alpr: 0, drones: 0, bodyCams: 0, trackers: 0,
                                          lastKind: "", lastSeen: .now, connected: true, redact: true)
    }
}
