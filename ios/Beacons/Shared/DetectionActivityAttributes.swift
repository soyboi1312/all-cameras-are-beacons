import ActivityKit
import Foundation

/// Live Activity model for a "Drive mode" detection session, shown in the Dynamic
/// Island and on the Lock Screen (and, on iOS 26+, mirrored to the CarPlay Dashboard).
///
/// Compiled into BOTH the app and the widget extension. Deliberately dependency-free
/// and Color-free: the widget maps each bucket to a symbol/tint with its own tokens,
/// so we never drag the app's `DeviceType`/`ACABTheme` (which pull SwiftUI `Color`)
/// into the extension. The five buckets mirror the dashboard tiles exactly
/// (ALPR = flockCamera + flockRaven, drone, body cam, tracker, glasses); there is no police
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
        var glasses: Int
        var lastKind: String   // "ALPR" / "DRONE" / "BODY CAM" / "TRACKER" / "GLASSES" / ""
        var lastSeen: Date
        var connected: Bool    // false -> show "Reconnecting…" instead of a frozen count
        var redact: Bool       // hide counts on the Lock Screen banner (user setting, default on)

        var total: Int { alpr + drones + bodyCams + trackers + glasses }

        static let empty = DetectionState(alpr: 0, drones: 0, bodyCams: 0, trackers: 0, glasses: 0,
                                          lastKind: "", lastSeen: .now, connected: true, redact: true)
    }
}

/// The category breakdown the medium home-screen widget draws, and the single source of truth for
/// its App Group keys.
///
/// It lives in Shared/ because the widget target compiles only `BeaconsWidget/` plus this file and
/// DriveModeIntents (see project.yml). DeviceType.swift is app-only, so the widget cannot map a
/// detection type itself; the app does that mapping (DeviceType.widgetCategoryKey) and writes one
/// scalar per key, and the widget reads them back by the same key.
///
/// Six categories, matching the Status and Log screens rather than the five the Live Activity
/// tracks. The Live Activity deliberately omits network cameras because they are opt-in and would
/// dilute its drive-mode buckets; the widget mirrors what the app's own screens show instead.
public enum WidgetCategory: String, CaseIterable {
    case alpr    = "ALPR"
    case drone   = "DRONE"
    case body    = "BODY"
    case tracker = "TRACKER"
    case glasses = "GLASSES"
    case camera  = "CAMERA"

    /// App Group key holding today's count for this category.
    public var defaultsKey: String { "w_c_" + rawValue }

    /// Short label for the strip. Kept to four characters so six of them fit a medium widget.
    public var short: String {
        switch self {
        case .alpr: return "ALPR"
        case .drone: return "DRON"
        case .body: return "BODY"
        case .tracker: return "TRKR"
        case .glasses: return "GLAS"
        case .camera: return "NCAM"
        }
    }

    /// SF Symbol, matching each type's glyph in the app.
    public var symbol: String {
        switch self {
        case .alpr: return "camera.fill"
        case .drone: return "airplane"
        case .body: return "person.fill.viewfinder"
        case .tracker: return "dot.radiowaves.left.and.right"
        case .glasses: return "eyeglasses"
        case .camera: return "web.camera.fill"
        }
    }
}
