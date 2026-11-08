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

#endif
