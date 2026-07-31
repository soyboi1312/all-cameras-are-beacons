import SwiftUI

/// What this app looks for. Raw values match the firmware's `t` field (see
/// docs/ble-protocol.md). `nearbyDevice` (t=7) is Desert mode's catch-all. The
/// firmware no longer emits a separate police-gear type (t=6) - Motorola/LE gear
/// now reports as a body cam.
enum DeviceType: Int, CaseIterable, Identifiable, Codable {
    /// A wire type this build doesn't recognize: a future `t` from firmware newer than the app
    /// (OTA ships board updates independently of app releases), or the retired t=6 off an old
    /// build still in the field. Shown as a generic row instead of being dropped, so this
    /// platform never silently hides a detection the other one shows. Mirrors Android's
    /// UNKNOWN(0) fallback in DeviceType.from().
    case unknown     = 0
    case flockCamera = 1
    case flockRaven  = 2
    case axonBodyCam = 3
    case drone       = 4
    case tracker     = 5
    case nearbyDevice = 7   // Desert mode: any device in range
    case watched      = 8   // user-starred: alert on this exact MAC even with no signature match
    case recordingGlasses = 9   // smart / camera glasses (Ray-Ban/Oakley Meta, Snap, Luxottica) by BLE company ID
    case networkCamera = 10  // branded IP-camera OUI on host WiFi (Hikvision/Dahua/etc.); opt-in, WiFi data-frame source MAC

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .flockCamera: return "ALPR Camera"
        case .flockRaven:  return "Flock Raven"
        case .axonBodyCam: return "Body Camera"
        case .drone:       return "Drone"
        case .tracker:     return "Tracker"
        case .nearbyDevice:return "Nearby Device"
        case .watched:     return "Watched device"
        case .recordingGlasses: return "Recording glasses"
        case .networkCamera: return "Network camera"
        case .unknown:     return "Unknown"
        }
    }

    var shortTag: String {
        switch self {
        case .flockCamera: return "ALPR"
        case .flockRaven:  return "RAVEN"
        case .axonBodyCam: return "BODY CAM"
        case .drone:       return "DRONE"
        case .tracker:     return "TRACKER"
        case .nearbyDevice:return "NEARBY"
        case .watched:     return "WATCHED"
        case .recordingGlasses: return "GLASSES"
        case .networkCamera: return "NET CAM"
        case .unknown:     return "UNKNOWN"
        }
    }

    /// SF Symbol for lists, map markers, and detail headers.
    var symbol: String {
        switch self {
        case .flockCamera: return "camera.fill"
        case .flockRaven:  return "waveform"
        case .axonBodyCam: return "person.fill.viewfinder"
        case .drone:       return "airplane"
        case .tracker:     return "dot.radiowaves.left.and.right"
        case .nearbyDevice:return "antenna.radiowaves.left.and.right"
        case .watched:     return "star.fill"
        case .recordingGlasses: return "eyeglasses"
        // Wall/IP surveillance-camera glyph, distinct from flockCamera's plain camera.fill so
        // a network camera reads as a fixed CCTV/NVR install rather than a handheld camera.
        case .networkCamera: return "web.camera.fill"
        case .unknown:       return "questionmark.circle"   // Android's HelpOutline analog
        }
    }

    /// Category color: Flock = crimson, drone = amber, Axon = gray, tracker = teal, glasses = violet.
    var tint: Color {
        switch self {
        case .flockCamera, .flockRaven: return ACABTheme.flockTone
        case .drone:                    return ACABTheme.droneTone
        case .axonBodyCam:              return ACABTheme.axonTone
        case .tracker:                  return ACABTheme.trackerTone
        case .nearbyDevice:             return Color(red: 0.82, green: 0.67, blue: 0.40)   // desert sand
        case .watched:                  return ACABTheme.watchTone
        case .recordingGlasses:         return ACABTheme.glassesTone
        case .networkCamera:            return ACABTheme.netcamTone
        case .unknown:                  return ACABTheme.dim   // neutral, like Android's Acab.dim
        }
    }

    /// Whether the drive-mode surfaces speak this bucket: the five counters plus a starred
    /// device (a star pinging the drive surface is the point of starring). Desert-mode
    /// .nearbyDevice and opt-in .networkCamera rows fill no tile, so letting them set the
    /// "last ..." line would name a category the surface never shows. The home widget is
    /// separate state and deliberately keeps all six categories.
    var onDriveSurface: Bool {
        switch self {
        case .flockCamera, .flockRaven, .drone, .axonBodyCam, .tracker,
             .recordingGlasses, .watched:
            return true
        case .nearbyDevice, .networkCamera, .unknown:
            return false
        }
    }

    /// Coarse category label for the dashboard tiles and map filters.
    var category: String {
        switch self {
        case .flockCamera, .flockRaven: return "ALPR"
        case .drone:                    return "DRONE"
        case .axonBodyCam:              return "BODY CAM"
        case .tracker:                  return "TRACKER"
        case .nearbyDevice:             return "NEARBY"
        case .watched:                  return "WATCHED"
        case .recordingGlasses:         return "GLASSES"
        case .networkCamera:            return "CAMERA"
        case .unknown:                  return "UNKNOWN"
        }
    }

    /// Vendor behind the hardware, shown in the detail view. ALPR gear is Flock
    /// Safety; the rest aren't tied to one brand.
    var brand: String? {
        switch self {
        case .flockCamera, .flockRaven: return "Flock Safety"
        default:                        return nil
        }
    }

    /// Drones move and broadcast their own position; everything else is a fixed install.
    var isMobile: Bool { self == .drone }

    /// Not field-verified yet - the UI flags these specially. Glasses is the last one:
    /// body cam graduated on 2026-07-19 when the Axon "BWCDEVICE" service-data tag
    /// (confidence 90) was field-validated against a visually confirmed scene. Keep in
    /// step with Android DeviceType.isExperimental and the EXP counter on both platforms.
    var isExperimental: Bool { self == .recordingGlasses }

    /// Which home-screen-widget bucket this type falls into, or nil for types the widget does not
    /// break out. ALPR folds flockCamera + flockRaven the same way the Log and Status tiles do.
    /// nearbyDevice / watched are excluded on purpose: Desert rows are ambient noise, and a starred
    /// device is a user-defined bucket that would need its own label to mean anything.
    var widgetCategoryKey: String? {
        switch self {
        case .flockCamera, .flockRaven: return WidgetCategory.alpr.rawValue
        case .drone:                    return WidgetCategory.drone.rawValue
        case .axonBodyCam:              return WidgetCategory.body.rawValue
        case .tracker:                  return WidgetCategory.tracker.rawValue
        case .recordingGlasses:         return WidgetCategory.glasses.rawValue
        case .networkCamera:            return WidgetCategory.camera.rawValue
        case .nearbyDevice, .watched, .unknown: return nil
        }
    }
}

/// Which radio saw the device (firmware `s` field).
enum DetectionSource: Int, Codable {
    case ble = 0, wifi = 1, remoteID = 2
    var label: String {
        switch self {
        case .ble:      return "BLE"
        case .wifi:     return "WiFi"
        case .remoteID: return "Remote ID"
        }
    }
}

/// What made the device match (firmware `meth` field).
enum DetectionMethod: Int, Codable {
    case none = 0, oui, name, mfgID, serviceUUID, ssid, probe, remoteID
    case serviceData = 8   // ASCII tag in service data / 128-bit UUID (MAC-independent)
    case mfgSubtype  = 9   // decoded manufacturer-data subtype
    case watchlist   = 10  // exact-MAC user rule (starred device)
    var label: String {
        switch self {
        case .none:        return "unknown"
        case .oui:         return "OUI match"
        case .name:        return "device name"
        case .mfgID:       return "manufacturer ID"
        case .serviceUUID: return "service UUID"
        case .ssid:        return "SSID"
        case .probe:       return "wildcard probe"
        case .remoteID:    return "Remote ID"
        case .serviceData: return "service data"
        case .mfgSubtype:  return "manufacturer subtype"
        case .watchlist:   return "watchlist"
        }
    }
}
