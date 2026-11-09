// What the app can tell the user about the native capabilities it ships.
//
// Deliberately free of node_api.h so the Swift side can import it through the
// bridging header without dragging Node in. The implementation lives in
// ios_native.m and reads the SAME table the N-API entry dispatches on: the list
// the settings screen shows and the list a call is checked against must not be
// able to drift apart (docs/native-services.md §9.3).
#ifndef DSH_NATIVE_CAPABILITIES_H
#define DSH_NATIVE_CAPABILITIES_H

#import <Foundation/Foundation.h>

/// Every capability this build implements, in table order. Each entry carries:
///   `id`                — capability name, as the engine and the addon use it
///   `ops`               — the operations it accepts
///   `systemPermission`  — the iOS permission it needs, absent when it needs none
///   `writeOps`          — the subset of `ops` that changes the user's own data;
///                         absent when the capability only reads
///   `appGated`          — true when the capability reaches the user's data but
///                         iOS has no permission to ask for, so this app's own
///                         switch is the only gate there can be
///
/// The app supplies its own display names and wording for these ids; an id with
/// no wording still appears, so a capability can never be added natively and go
/// unlisted.
NSArray<NSDictionary<NSString *, id> *> *DshNativeCapabilityList(void);

/// Warm up what the capabilities need before their first call. Right now that is
/// battery monitoring: UIKit reports an unknown level for a moment after it is
/// switched on, and the agent usually asks only once. Call this once, early,
/// from the app's own startup; it is cheap and safe to call again.
void DshNativePrepare(void);

/// What happens when a capability is asked to change the user's own data.
///
/// The gate the user already passed is the iOS permission, and iOS grants read
/// and write together (§4.0) — so this is the only place left where "it may read
/// my calendar" and "it may delete my calendar" can be told apart. It is per
/// capability, not per caller: §2.2 settled that a caller cannot be told apart
/// from the engine, so a plugin-only setting would be a lie.
typedef NS_ENUM(NSInteger, DshWritePolicy) {
  /// Write straight through. The default, and what the audit list exists for.
  DshWritePolicyDirect = 0,
  /// Stop in front of the user every time: the system editor for new events,
  /// a native confirmation for everything else.
  DshWritePolicyConfirm = 1,
  /// Refuse, with a sentence the agent can read out. Reads still work.
  DshWritePolicyBlocked = 2,
};

/// Whether an app-gated capability is switched on. Always NO until the user
/// switches it on, like every capability iOS guards — the difference is only
/// where the answer is kept, not what it means.
///
/// Asked by the dispatcher before a capability runs, so there is one check in
/// one place rather than one per capability (§9.3). A capability with no
/// `appGated` flag is not affected.
BOOL DshNativeCapabilityEnabled(NSString *capability);

/// Switch one on or off. The capability screen is the only caller.
void DshNativeSetCapabilityEnabled(NSString *capability, BOOL enabled);

/// This capability's write policy. Unset reads as `DshWritePolicyDirect`, so a
/// capability added later is not accidentally born blocked.
DshWritePolicy DshNativeWritePolicyFor(NSString *capability);

/// Change it. The capability screen is the only caller; nothing in JS can reach
/// this, which is the point — a plugin must not be able to widen its own gate.
void DshNativeSetWritePolicy(NSString *capability, DshWritePolicy policy);

/// Ask iOS for one capability's permission, and run `done` with what the user
/// said. `permission` is a `systemPermission` value from the list above.
///
/// This is the ONLY place in the app that raises a system permission dialog. The
/// capability handlers refuse a permission iOS has not been asked about instead
/// of prompting, so a dialog only ever appears because the user tapped for it on
/// the capability screen — not because a plugin called something
/// (docs/native-services.md §5.5).
///
/// Already answered, either way: `done` reports that answer without a dialog,
/// because iOS asks once per app and will not ask again.
///
/// `done` runs on the main thread. A plain "the user said no" is
/// `granted: NO, error: nil` — the wording for that belongs to the screen, which
/// is translated, and not to this file, which is not. `error` is non-nil only
/// when iOS itself failed, and is then iOS's own localised description.
void DshNativeRequestPermission(NSString *permission, void (^done)(BOOL granted, NSString *error));

#endif
