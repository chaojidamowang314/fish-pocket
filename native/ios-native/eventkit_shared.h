// What the calendar and the reminders capabilities both need from EventKit.
//
// They share a store because EventKit objects belong to the store that produced
// them, and because `reset` after a grant arrives only helps if there is one
// store to reset. They share a queue for the same reason both need one: the
// store is not thread-safe and some of its queries are synchronous, so neither
// Node's thread nor the main thread is a safe place to run them.
#ifndef DSH_EVENTKIT_SHARED_H
#define DSH_EVENTKIT_SHARED_H

#import <EventKit/EventKit.h>

/// The one EventKit store for the process. Handles both events and reminders;
/// authorisation is per entity type, the store is not.
EKEventStore *DshEventStore(void);

/// The serial queue every EventKit call runs on.
dispatch_queue_t DshEventKitQueue(void);

/// ISO 8601 with the device's own UTC offset, so neither the model nor the user
/// has to guess which timezone a time is in. Empty string for nil.
NSString *DshISO8601(NSDate *date);

/// Check full access to `type` and run `next` — which may run on any thread.
///
/// Never prompts. A capability iOS has not been asked about yet is refused like
/// any other unavailable one, because the alternative is a system dialog raised
/// by whichever plugin happened to call first, with no way for the user to tell
/// what asked or why. The grant belongs to the user, in the app's own
/// capability screen: that is `DshNativeRequestPermission`, the only place in
/// this app that raises one of these dialogs (docs/native-services.md §5.5).
///
/// `deniedMessage` and the not-asked-yet message are read out to the user by the
/// agent, so both say what the user can do about it.
/// `writeOnlyIsEnough` is for operations that only ever add. iOS 17 has an
/// add-only tier for events, and refusing a create that iOS would allow is just
/// as wrong as allowing a read it would not; everything that has to look at an
/// existing event — including update and delete, which read it before changing
/// it — passes NO.
void DshEventKitRequireAccess(EKEntityType type, BOOL writeOnlyIsEnough, NSString *deniedMessage,
                              void (^next)(BOOL granted, NSString *error));

/// Raise the system permission dialog for `type`, then run `done`.
///
/// Only `DshNativeRequestPermission` calls this, and only because the user
/// asked for it on screen. iOS prompts once per app for the life of the
/// install, so a dialog nobody is looking at is a permission spent.
void DshEventKitGrantAccess(EKEntityType type, NSString *deniedMessage,
                            void (^done)(BOOL granted, NSString *error));

#endif
