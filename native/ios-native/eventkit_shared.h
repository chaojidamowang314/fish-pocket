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

/// Resolve full access to `type`, prompting if iOS has not asked yet, then run
/// `next` — which may run on any thread.
///
/// `deniedMessage` is read out to the user by the agent, so it says what the
/// user can do about it. iOS prompts once per app for the life of the install.
void DshEventKitRequestAccess(EKEntityType type, NSString *deniedMessage,
                              void (^next)(BOOL granted, NSString *error));

#endif
