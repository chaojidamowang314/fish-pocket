// calendar: read the user's calendar. The first capability here that touches
// personal data, so it is also the first one iOS stands in front of.
//
// Reading needs FULL access, not a read-only tier — iOS 17 offers write-only or
// full, and write-only cannot read back even the events it created
// (docs/native-services.md §4.0). So a user who allows reading has also allowed
// writing at the system level; keeping writes behind a confirmation is our job,
// not the system's, and phase 1 simply registers no write operation at all.
//
// Everything here is behind the same capability table as every other capability,
// which means a plugin reaching the addon directly gets exactly this and nothing
// more: `list` and `calendars`. There is no unchecked variant.
#import "dsh_ios_native.h"
#import <EventKit/EventKit.h>

/// A single query can span years; a model does not need ten thousand events and
/// the reply has to cross into JS as one JSON string.
static const NSUInteger kMaxEvents = 200;
/// Notes can hold a whole meeting agenda. Enough to be useful, bounded enough
/// not to flood the conversation.
static const NSUInteger kMaxNotesLength = 500;

/// One store for the process. EventKit hands back objects that belong to their
/// store, and `reset` (needed after a grant arrives) only helps if everyone is
/// looking at the same one.
static EKEventStore *event_store(void) {
  static EKEventStore *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [EKEventStore new]; });
  return shared;
}

/// EKEventStore is not thread-safe, and `eventsMatchingPredicate:` is a
/// synchronous query that can take a noticeable moment on a busy calendar. Both
/// reasons point the same way: one serial queue that is neither Node's thread
/// nor the main one.
static dispatch_queue_t calendar_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.calendar", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

// The agent reads these out to the user, so they say what happened and what the
// user can do about it. iOS prompts once per app for the lifetime of the install:
// after a refusal there is no second prompt, only Settings.
static NSString *const kDeniedMessage =
  @"calendar access is off for this app. The user can turn it on in "
  @"Settings > Privacy & Security > Calendars. iOS only asks once, so it cannot be requested again from here";
static NSString *const kWriteOnlyMessage =
  @"this app has add-only calendar access, which cannot read events. Reading needs Full Access, "
  @"which the user can switch on in Settings > Privacy & Security > Calendars";

/// Resolve full calendar access, prompting if iOS has not asked yet, then run
/// `next`. `next` may run on any thread.
static void with_full_access(void (^next)(BOOL granted, NSString *error)) {
  switch ([EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent]) {
    case EKAuthorizationStatusFullAccess:
      next(YES, nil);
      return;
    case EKAuthorizationStatusDenied:
    case EKAuthorizationStatusRestricted:
      next(NO, kDeniedMessage);
      return;
    case EKAuthorizationStatusWriteOnly:
      next(NO, kWriteOnlyMessage);
      return;
    case EKAuthorizationStatusNotDetermined:
    default:
      break;
  }

  // The prompt is UI. It is also the only place the user is ever told what this
  // app does with their calendar, which is why the Info.plist wording matters
  // as much as the code (§6.2.1).
  dsh_native_on_main(^{
    [event_store() requestFullAccessToEventsWithCompletion:^(BOOL granted, NSError *error) {
      if (error != nil) {
        next(NO, error.localizedDescription);
      } else if (!granted) {
        next(NO, kDeniedMessage);
      } else {
        // A store that was queried before the grant keeps answering from the old,
        // empty view until it is reset. Without this the first call after the
        // user taps Allow returns nothing, which reads exactly like an empty
        // calendar.
        [event_store() reset];
        next(YES, nil);
      }
    }];
  });
}

/// ISO 8601 with the device's own offset, so neither the model nor the user has
/// to guess which timezone a time is in.
static NSString *iso8601(NSDate *date) {
  static NSISO8601DateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    formatter.timeZone = NSTimeZone.localTimeZone;
  });
  return date == nil ? @"" : [formatter stringFromDate:date];
}

static NSString *truncated(NSString *text, NSUInteger limit) {
  if (text.length <= limit) return text;
  return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

static NSDictionary *event_json(EKEvent *event) {
  NSMutableDictionary *entry = [@{
    // Needed by phase 2 to change or delete a specific event, and by the model to
    // talk about "that one" across turns.
    @"id": event.eventIdentifier ?: @"",
    @"title": event.title ?: @"",
    @"start": iso8601(event.startDate),
    @"end": iso8601(event.endDate),
    @"allDay": @(event.allDay),
    @"calendar": event.calendar.title ?: @"",
  } mutableCopy];
  if (event.location.length > 0) entry[@"location"] = event.location;
  if (event.notes.length > 0) entry[@"notes"] = truncated(event.notes, kMaxNotesLength);
  return entry;
}

static void list_events(NSDictionary *args, DshNativeReply reply) {
  NSNumber *from = args[@"from"], *to = args[@"to"];
  if (![from isKindOfClass:NSNumber.class] || ![to isKindOfClass:NSNumber.class]) {
    reply(nil, @"list needs 'from' and 'to' as seconds since 1970");
    return;
  }
  if (to.doubleValue <= from.doubleValue) {
    reply(nil, @"list needs 'to' to be after 'from'");
    return;
  }

  with_full_access(^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    dispatch_async(calendar_queue(), ^{
      EKEventStore *store = event_store();
      NSPredicate *predicate =
        [store predicateForEventsWithStartDate:[NSDate dateWithTimeIntervalSince1970:from.doubleValue]
                                       endDate:[NSDate dateWithTimeIntervalSince1970:to.doubleValue]
                                     calendars:nil];
      NSArray<EKEvent *> *found =
        [[store eventsMatchingPredicate:predicate] sortedArrayUsingSelector:@selector(compareStartDateWithEvent:)];

      NSMutableArray *events = [NSMutableArray arrayWithCapacity:MIN(found.count, kMaxEvents)];
      for (EKEvent *event in found) {
        if (events.count >= kMaxEvents) break;
        [events addObject:event_json(event)];
      }
      // Said plainly rather than silently dropped: a model that asked for a year
      // should know it is looking at the first slice of one.
      //
      // The audit line is dates and a count on purpose — it is shown to the user
      // verbatim in an app that is translated, and this file is not.
      reply(@{@"events": events,
              @"total": @(found.count),
              @"truncated": @(found.count > events.count),
              @"auditSummary": [NSString stringWithFormat:@"%@ → %@ · %lu",
                                [iso8601([NSDate dateWithTimeIntervalSince1970:from.doubleValue]) substringToIndex:10],
                                [iso8601([NSDate dateWithTimeIntervalSince1970:to.doubleValue]) substringToIndex:10],
                                (unsigned long)found.count]}, nil);
    });
  });
}

static void list_calendars(DshNativeReply reply) {
  with_full_access(^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    dispatch_async(calendar_queue(), ^{
      EKEventStore *store = event_store();
      NSString *defaultId = store.defaultCalendarForNewEvents.calendarIdentifier;
      NSMutableArray *calendars = [NSMutableArray array];
      for (EKCalendar *calendar in [store calendarsForEntityType:EKEntityTypeEvent]) {
        [calendars addObject:@{
          @"id": calendar.calendarIdentifier ?: @"",
          @"title": calendar.title ?: @"",
          // Subscribed and holiday calendars refuse writes; phase 2 needs to know
          // before offering to put something in one.
          @"writable": @(calendar.allowsContentModifications),
          @"default": @(defaultId != nil && [calendar.calendarIdentifier isEqualToString:defaultId]),
        }];
      }
      reply(@{@"calendars": calendars}, nil);
    });
  });
}

void dsh_native_calendar(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"list"]) {
    list_events(args, reply);
  } else {
    list_calendars(reply);
  }
}
