import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// Widget-local presentation tokens for the four detection buckets. The shared
// ActivityAttributes is intentionally Color-free, so the extension owns its own
// symbol + tint map (mirrors the app's DeviceType, kept self-contained here).
private enum DetCat: CaseIterable {
    case alpr, drone, bodyCam, tracker

    var symbol: String {
        switch self {
        case .alpr:    return "camera.fill"
        case .drone:   return "airplane"
        case .bodyCam: return "person.fill.viewfinder"
        case .tracker: return "dot.radiowaves.left.and.right"
        }
    }
    var tint: Color {
        switch self {
        case .alpr:    return .red
        case .drone:   return .orange
        case .bodyCam: return Color(white: 0.62)
        case .tracker: return .teal
        }
    }
    var label: String {
        switch self {
        case .alpr:    return "ALPR"
        case .drone:   return "DRONE"
        case .bodyCam: return "BODY"
        case .tracker: return "TRACK"
        }
    }
    func count(_ s: DetectionActivityAttributes.DetectionState) -> Int {
        switch self {
        case .alpr:    return s.alpr
        case .drone:   return s.drones
        case .bodyCam: return s.bodyCams
        case .tracker: return s.trackers
        }
    }
}

// TODO(iOS27 — wire up after Xcode 27 GM ~Sept 2026; these need the iOS 27 SDK and
// won't compile on stable Xcode 26.5, so they are intentionally NOT added yet):
//   • @Environment(\.isDynamicIslandLimitedInWidth) in compactLeading/compactTrailing
//     -> collapse to icon + number when the Island is width-limited (landscape mount).
//   • @Environment(\.showsWidgetContainerBackground) in LockScreenView -> paint the
//     panel edge-to-edge in StandBy (charging + landscape dock).
// Landscape Dynamic Island rendering itself is automatic on iOS 27 — no code needed.

/// The Drive-mode detection counter, presented on the Lock Screen and in the
/// Dynamic Island. One ActivityConfiguration drives both surfaces.
struct DetectionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DetectionActivityAttributes.self) { context in
            // Routes by activity family: Lock Screen (medium), and the compact "small"
            // cell that iOS 26 auto-mirrors onto the CarPlay Dashboard (also the Watch
            // Smart Stack). The small family is declared below via supplementalActivityFamilies.
            DetectionActivityContent(state: context.state, deviceName: context.attributes.deviceName)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { StatBadge(cat: .alpr, state: s) }
                DynamicIslandExpandedRegion(.trailing) { StatBadge(cat: .tracker, state: s) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(s.connected ? "DRIVE MODE" : "RECONNECTING")
                            .font(.system(size: 9, weight: .semibold)).tracking(1)
                            .foregroundStyle(s.connected ? Color(white: 0.6) : Color.orange)
                        Text("\(s.total)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        StatBadge(cat: .drone, state: s)
                        Spacer(minLength: 4)
                        Group {
                            if s.total > 0 {
                                Text("last \(s.lastKind) ").foregroundStyle(.secondary)
                                + Text(s.lastSeen, style: .relative).foregroundStyle(.secondary)
                            } else {
                                Text("all clear").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 10))
                        Spacer(minLength: 4)
                        StatBadge(cat: .bodyCam, state: s)
                    }
                }
            } compactLeading: {
                Image(systemName: s.connected ? "dot.radiowaves.left.and.right" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(s.total > 0 ? Color.red : Color(white: 0.6))
            } compactTrailing: {
                Text("\(s.total)").monospacedDigit().fontWeight(.semibold)
            } minimal: {
                Text("\(s.total)").monospacedDigit().fontWeight(.semibold)
                    .foregroundStyle(s.total > 0 ? Color.red : Color.white)
            }
            .keylineTint(.red)
        }
        // iOS 26 auto-mirrors the .small family onto the CarPlay Dashboard (no CarPlay
        // entitlement); also drives the Apple Watch Smart Stack. iOS 18+ API.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Content router (Lock Screen vs CarPlay / Watch "small")

private struct DetectionActivityContent: View {
    @Environment(\.activityFamily) private var family
    let state: DetectionActivityAttributes.DetectionState
    let deviceName: String
    var body: some View {
        switch family {
        case .small:
            SmallCell(state: state)
        default:                       // .medium -> Lock Screen
            LockScreenView(state: state, deviceName: deviceName).padding(14)
        }
    }
}

/// Compact standalone cell for the CarPlay Dashboard (iOS 26 auto-mirror) and the Apple
/// Watch Smart Stack. Has to read on its own glance , just the shield, the total, a word.
private struct SmallCell: View {
    let state: DetectionActivityAttributes.DetectionState
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(state.total > 0 ? Color.red : Color(white: 0.6))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(state.total)")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text(state.total > 0 ? (state.connected ? "detected" : "reconnecting") : "all clear")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Color(white: 0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let state: DetectionActivityAttributes.DetectionState
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
                Text("BEACONS · DRIVE MODE")
                    .font(.system(size: 11, weight: .semibold)).tracking(1)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if !state.connected {
                    Text("RECONNECTING")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(.orange)
                }
                Button(intent: EndDriveModeIntent()) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
            if state.redact {
                // Lock-Screen privacy (user setting, default on): no counts or per-category
                // breakdown on a locked phone, so a glance reveals nothing about what's being
                // detected. Full counts still show in the Dynamic Island and in the app.
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Text(state.connected ? "Drive mode active · counts hidden" : "Reconnecting…")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 8) {
                    ForEach(DetCat.allCases, id: \.self) { StatTile(cat: $0, state: state) }
                }
                HStack(spacing: 4) {
                    Text(deviceName).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    Spacer(minLength: 6)
                    Group {
                        if state.total > 0 {
                            Text("last \(state.lastKind) ")
                            + Text(state.lastSeen, style: .relative)
                        } else {
                            Text("nothing detected yet")
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

private struct StatTile: View {
    let cat: DetCat
    let state: DetectionActivityAttributes.DetectionState
    var body: some View {
        let n = cat.count(state)
        VStack(spacing: 3) {
            Image(systemName: cat.symbol).font(.system(size: 13))
                .foregroundStyle(n > 0 ? cat.tint : .white.opacity(0.35))
            Text("\(n)")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(n > 0 ? .white : .white.opacity(0.4))
            Text(cat.label)
                .font(.system(size: 8, weight: .semibold)).tracking(0.5)
                .foregroundStyle(n > 0 ? cat.tint : .white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Dynamic Island badge

private struct StatBadge: View {
    let cat: DetCat
    let state: DetectionActivityAttributes.DetectionState
    var body: some View {
        let n = cat.count(state)
        HStack(spacing: 4) {
            Image(systemName: cat.symbol).font(.system(size: 12))
                .foregroundStyle(n > 0 ? cat.tint : Color(white: 0.6))
            Text("\(n)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }
    }
}
