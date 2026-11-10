import AlarmKit
import Foundation

/// What rides along with an alarm the agent set, so the lock screen and the
/// Dynamic Island have something to say about it. Compiled into the app and the
/// widget extension: the app sets alarms (`AlarmProvider`), the extension draws
/// them (`AlarmActivity`).
///
/// It carries the label because AlarmKit will not give it back. `Alarm` has an
/// id, a schedule and a state and nothing else — the title lives in the
/// presentation, which only ever travels outwards. So without this the alert
/// could say no more than the time it is ringing at.
@available(iOS 26.0, *)
struct DshAlarmMetadata: AlarmMetadata {
    /// What the user asked to be woken for, in their own words.
    var label: String

    init(label: String) {
        self.label = label
    }
}
