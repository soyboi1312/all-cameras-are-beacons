import AppIntents
import ActivityKit

// Interactive intents for the Drive-mode Live Activity (the in-activity End button) and the
// Control Center toggle. Deliberately dependency-free - they use only ActivityKit and the
// shared DetectionActivityAttributes, NEVER BLEManager - so this one file compiles into BOTH
// the app and the widget extension. The app re-syncs its own `driveModeOn` flag from
// ActivityKit when it next comes to the foreground (BLEManager.reconcileDriveMode()).

/// Ends the Drive-mode Live Activity. Backs the "End" button shown inside the activity.
struct EndDriveModeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Drive Mode"

    func perform() async throws -> some IntentResult {
        for activity in Activity<DetectionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

/// Control Center toggle for Drive mode. Off ends the activity (works from anywhere); on
/// opens the app and starts one, since iOS only lets a Live Activity begin while the app is
/// foregrounded (openAppWhenRun brings it forward, and perform() then runs in-app).
struct ToggleDriveModeIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Drive Mode"
    static var openAppWhenRun = true

    @Parameter(title: "On") var value: Bool

    func perform() async throws -> some IntentResult {
        let running = Activity<DetectionActivityAttributes>.activities
        if value {
            if running.isEmpty {
                let attrs = DetectionActivityAttributes(deviceName: "Beacons", sessionStart: .now)
                let content = ActivityContent(state: DetectionActivityAttributes.ContentState.empty,
                                              staleDate: Date().addingTimeInterval(8 * 60))
                _ = try? Activity.request(attributes: attrs, content: content, pushType: nil)
            }
        } else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        return .result()
    }
}
