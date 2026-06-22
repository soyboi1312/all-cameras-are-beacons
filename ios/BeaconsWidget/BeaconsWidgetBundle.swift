import WidgetKit
import SwiftUI

/// Widget extension entry point. Hosts the Live Activity (and is where any future
/// home/Lock-Screen widgets would slot in).
@main
struct BeaconsWidgetBundle: WidgetBundle {
    var body: some Widget {
        DetectionLiveActivity()
        DriveModeControl()
    }
}
