import SwiftUI

/// What this app looks for. Raw values match the firmware's `t` field (see
/// docs/ble-protocol.md). `nearbyDevice` (t=7) is Desert mode's catch-all. The
/// firmware no longer emits a separate police-gear type (t=6) - Motorola/LE gear
/// now reports as a body cam.
enum DeviceType: Int, CaseIterable, Identifiable, Codable {
    case flockCamera = 1
    case flockRaven  = 2
    case axonBodyCam = 3
    case drone       = 4
    case tracker     = 5
    case nearbyDevice = 7   // Desert mode: any device in range

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .flockCamera: return "ALPR Camera"
        case .flockRaven:  return "Flock Raven"
        case .axonBodyCam: return "Body Camera"
        case .drone:       return "Drone"
        case .tracker:     return "Tracker"
        case .nearbyDevice:return "Nearby Device"
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
        }
    }

    /// Category color: Flock = crimson, drone = amber, Axon = gray, tracker = teal.
    var tint: Color {
        switch self {
        case .flockCamera, .flockRaven: return ACABTheme.flockTone
        case .drone:                    return ACABTheme.droneTone
        case .axonBodyCam:              return ACABTheme.axonTone
        case .tracker:                  return ACABTheme.trackerTone
        case .nearbyDevice:             return Color(red: 0.82, green: 0.67, blue: 0.40)   // desert sand
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

    /// Not field-verified yet — the UI flags these specially. Axon is experimental.
    var isExperimental: Bool { self == .axonBodyCam }
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
        }
    }
}
