import Foundation
import ActivityKit

/// Owns the Drive-mode Live Activity: started in the foreground, fed throttled count
/// updates as detections arrive over BLE, and ended on demand. Kept off BLEManager so
/// the manager stays focused on the link. Call on the main thread (BLEManager's
/// CoreBluetooth delegates already land there).
final class LiveActivityController {
    private var activity: Activity<DetectionActivityAttributes>?
    private var lastPushed = Date.distantPast
    private var pending: DispatchWorkItem?
    private var latest = DetectionActivityAttributes.DetectionState.empty

    private let stale: TimeInterval = 8 * 60   // -> "stale" if no update in 8 min (drive dropout)
    private let minGap: TimeInterval = 1.5     // coalesce routine updates to ~1 / 1.5 s

    /// Fired when the system ends or dismisses the activity out from under us (e.g. the
    /// user swiped it away), so the owner can sync its Drive-mode toggle back to off.
    var onInactive: (() -> Void)?

    /// Live Activities can be disabled per-app in Settings.
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var isRunning: Bool { activity != nil }

    /// True only while the system is actually showing the activity. A handle can linger
    /// non-nil after the user dismisses it, so check the real state for reconciliation.
    var isActive: Bool {
        guard let a = activity else { return false }
        switch a.activityState {
        case .active, .stale: return true
        default:              return false   // .ended, .dismissed
        }
    }

    /// Drop a handle the system already ended/dismissed, so a fresh start() can begin anew.
    func dropIfInactive() {
        guard let a = activity else { return }
        switch a.activityState {
        case .ended, .dismissed: pending?.cancel(); pending = nil; activity = nil
        default: break
        }
    }

    /// Start a session. iOS requires the app to be foregrounded to begin one. Returns
    /// whether the activity actually started (request can fail silently).
    @discardableResult
    func start(deviceName: String, state: DetectionActivityAttributes.DetectionState) -> Bool {
        guard isAvailable, activity == nil else { return activity != nil }
        latest = state
        let attrs = DetectionActivityAttributes(deviceName: deviceName, sessionStart: .now)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(stale))
        activity = try? Activity.request(attributes: attrs, content: content, pushType: nil)
        if let a = activity { observe(a) }
        return activity != nil
    }

    /// Re-attach to an activity still running from a previous launch, so a relaunch
    /// mid-drive resumes it instead of orphaning it. Returns whether one was adopted.
    @discardableResult
    func adoptExisting() -> Bool {
        guard activity == nil, let a = Activity<DetectionActivityAttributes>.activities.first
        else { return isActive }
        activity = a
        latest = a.content.state
        observe(a)
        return isActive
    }

    /// Watch for the system ending/dismissing this activity and notify the owner once.
    private func observe(_ a: Activity<DetectionActivityAttributes>) {
        let id = a.id
        Task { @MainActor [weak self] in
            for await s in a.activityStateUpdates where s == .ended || s == .dismissed {
                self?.handleInactive(id: id)
                return
            }
        }
    }

    /// The system ended/dismissed the activity: drop our handle and tell the owner so it
    /// can sync its Drive-mode toggle off. Runs on the main thread.
    private func handleInactive(id: String) {
        if activity?.id == id { pending?.cancel(); pending = nil; activity = nil }
        onInactive?()
    }

    /// Push new counts. Coalesced to ~1 update / `minGap`, EXCEPT `escalate` (a brand-new
    /// device) goes out immediately so a fresh threat shows without delay.
    func update(_ state: DetectionActivityAttributes.DetectionState, escalate: Bool = false) {
        guard isRunning else { return }
        latest = state
        let gap = Date().timeIntervalSince(lastPushed)
        if escalate || gap >= minGap {
            pending?.cancel(); pending = nil
            push()
        } else if pending == nil {
            let work = DispatchWorkItem { [weak self] in self?.push() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minGap - gap), execute: work)
        }
    }

    /// Flip the connected flag (drives the "Reconnecting…" line) without ending.
    func setConnected(_ connected: Bool) {
        guard isRunning else { return }
        latest.connected = connected
        push()
    }

    func end() {
        pending?.cancel(); pending = nil
        let a = activity
        activity = nil
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
    }

    private func push() {
        guard let activity else { return }
        lastPushed = Date(); pending = nil
        let content = ActivityContent(state: latest, staleDate: Date().addingTimeInterval(stale))
        Task { await activity.update(content) }
    }
}
