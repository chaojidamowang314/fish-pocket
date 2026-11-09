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
