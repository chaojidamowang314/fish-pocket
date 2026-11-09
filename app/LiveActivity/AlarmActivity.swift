import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// An agent-set alarm on the lock screen and in the Dynamic Island.
///
/// This is not optional decoration. AlarmKit presents through ActivityKit, so an
/// alarm whose attributes no widget in this bundle claims has nowhere to appear
/// — which is why `AlarmAttributes` is an `ActivityAttributes` in the first
/// place. The ringing alert itself is drawn by the system from the
/// `AlarmPresentation` the app supplied; what is left to us is the quieter
/// states around it.
@available(iOS 26.0, *)
struct AlarmActivity: Widget {
    /// Matches `AlarmProvider.tint`, and for the same reason it is a literal
    /// there: the two targets do not share an asset catalog.
    static let tint = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<DshAlarmMetadata>.self) { context in
            AlarmLockScreen(label: Self.label(of: context.attributes), mode: context.state.mode)
        } dynamicIsland: { context in
            let label = Self.label(of: context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "alarm.fill").foregroundStyle(Self.tint)
                        Text(label).font(.headline).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AlarmTime(mode: context.state.mode)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(Self.tint)
            } compactTrailing: {
                AlarmTime(mode: context.state.mode)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(Self.tint)
            }
            .keylineTint(Self.tint)
        }
    }

    /// The label the agent set the alarm for. Falls back to a generic word rather
    /// than showing nothing: an alarm with no text at all reads like a bug.
    private static func label(of attributes: AlarmAttributes<DshAlarmMetadata>) -> String {
        let label = attributes.metadata?.label ?? ""
        return label.isEmpty ? String(localized: "闹钟") : label
    }
}

@available(iOS 26.0, *)
private struct AlarmLockScreen: View {
    let label: String
    let mode: AlarmPresentationState.Mode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "alarm.fill")
                .font(.title3)
                .foregroundStyle(AlarmActivity.tint)
            Text(label)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 0)
            AlarmTime(mode: mode)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

/// When it goes off, or how long is left — whichever the state is actually in.
@available(iOS 26.0, *)
private struct AlarmTime: View {
    let mode: AlarmPresentationState.Mode

    var body: some View {
        switch mode {
        case .alert(let alert):
            Text(String(format: "%02d:%02d", alert.time.hour, alert.time.minute))
        case .countdown(let countdown):
            // Clamped: a fire date already in the past would make an invalid
            // range, and a widget that traps takes the whole bundle with it.
            let now = Date()
            Text(timerInterval: now...max(countdown.fireDate, now), countsDown: true)
        case .paused(let paused):
            Text(
                Duration
                    .seconds(max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration))
                    .formatted(.time(pattern: .minuteSecond))
            )
        @unknown default:
            EmptyView()
        }
    }
}
