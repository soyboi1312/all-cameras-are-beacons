import WidgetKit
import SwiftUI

/// Widget extension entry point. Hosts the Live Activity, the Control Center toggle,
/// and the Home-Screen detections glance.
@main
struct BeaconsWidgetBundle: WidgetBundle {
    var body: some Widget {
        DetectionLiveActivity()
        DriveModeControl()
        DetectionsWidget()
    }
}
