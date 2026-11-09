// calendar: read the user's calendar. The first capability here that touches
// personal data, so it is also the first one iOS stands in front of.
//
// Reading needs FULL access, not a read-only tier — iOS 17 offers write-only or
// full, and write-only cannot read back even the events it created
// (docs/native-services.md §4.0). So a user who allows reading has also allowed
// writing at the system level, and "the agent can see my schedule but will not
// quietly change it" is ours to guarantee rather than the system's.
//
// The guarantee is not the operation list — writes are listed here like anything
// else. It is that every one of them stops in front of the user before it
// happens: `create` opens Apple's own event editor, `update` and `delete` wait
// on a native confirmation. A plugin reaching the addon directly meets exactly
// the same stop. There is no unchecked variant.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "eventkit_shared.h"
#import <EventKit/EventKit.h>

/// A single query can span years; a model does not need ten thousand events and
/// the reply has to cross into JS as one JSON string.
static const NSUInteger kMaxEvents = 200;
/// Notes can hold a whole meeting agenda. Enough to be useful, bounded enough
/// not to flood the conversation.
static const NSUInteger kMaxNotesLength = 500;

// The agent reads this out to the user, so it says what happened and what the
// user can do about it. iOS prompts once per app for the lifetime of the install:
// after a refusal there is no second prompt, only Settings.
static NSString *const kDeniedMessage =
  @"calendar access is off for this app. The user can turn it on in "
  @"Settings > Privacy & Security > Calendars. iOS only asks once, so it cannot be requested again from here";

static void with_full_access(void (^next)(BOOL granted, NSString *error)) {
  DshEventKitRequestAccess(EKEntityTypeEvent, kDeniedMessage, next);
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
    @"start": DshISO8601(event.startDate),
    @"end": DshISO8601(event.endDate),
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
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
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
                                [DshISO8601([NSDate dateWithTimeIntervalSince1970:from.doubleValue]) substringToIndex:10],
                                [DshISO8601([NSDate dateWithTimeIntervalSince1970:to.doubleValue]) substringToIndex:10],
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
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
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

#pragma mark - Writing

/// What a confirmation sheet and an audit line say about an event.
///
/// Title and dates only, and built from the event itself — the point of the
/// sheet is that it shows what will actually happen, not what the caller said
/// it would (§4.3.1). It also stays language-neutral, because the app shows it
/// verbatim in three languages and this file is in none of them.
static NSString *event_summary(EKEvent *event) {
  NSString *title = event.title.length > 0 ? event.title : @"(untitled)";
  if (event.allDay) {
    return [NSString stringWithFormat:@"%@\n%@", title, [DshISO8601(event.startDate) substringToIndex:10]];
  }
  NSString *start = DshISO8601(event.startDate), *end = DshISO8601(event.endDate);
  return [NSString stringWithFormat:@"%@\n%@ %@ – %@ %@", title,
          [start substringToIndex:10], [start substringWithRange:NSMakeRange(11, 5)],
          [end substringToIndex:10], [end substringWithRange:NSMakeRange(11, 5)]];
}

static id<DshNativeBridging> require_bridge(DshNativeReply reply) {
  id<DshNativeBridging> bridge = DshNativeCurrentBridge();
  if (bridge == nil) {
    // Never silently fall through to writing unattended: the confirmation is
    // the only thing standing between a plugin and the user's calendar.
    reply(nil, @"the app cannot show a confirmation right now, so nothing was changed");
  }
  return bridge;
}

/// Read an optional date argument. Returns nil when absent, and reports a bad one.
static NSDate *date_arg(NSDictionary *args, NSString *key, NSString **error) {
  NSNumber *value = args[key];
  if (value == nil) return nil;
  if (![value isKindOfClass:NSNumber.class]) {
    *error = [NSString stringWithFormat:@"'%@' must be seconds since 1970", key];
    return nil;
  }
  return [NSDate dateWithTimeIntervalSince1970:value.doubleValue];
}

/// Hand a prefilled event to the system's own editor. Nothing is written unless
/// the user taps Add there, which is why this needs no permission of its own and
/// is the strongest write path we have.
static void create_event(NSDictionary *args, DshNativeReply reply) {
  NSString *title = args[@"title"];
  if (![title isKindOfClass:NSString.class] || title.length == 0) {
    reply(nil, @"create needs a non-empty 'title'");
    return;
  }
  NSString *dateError = nil;
  NSDate *start = date_arg(args, @"start", &dateError);
  NSDate *end = date_arg(args, @"end", &dateError);
  if (dateError != nil) { reply(nil, dateError); return; }
  if (start == nil) { reply(nil, @"create needs 'start' as seconds since 1970"); return; }

  id<DshNativeBridging> bridge = require_bridge(reply);
  if (bridge == nil) return;

  dispatch_async(DshEventKitQueue(), ^{
    EKEventStore *store = DshEventStore();
    EKEvent *event = [EKEvent eventWithEventStore:store];
    event.title = title;
    event.startDate = start;
    // An event with no end is an hour long, which is what a person means by
    // "put it at three" far more often than a zero-length marker.
    event.endDate = end ?: [start dateByAddingTimeInterval:3600];
    NSNumber *allDay = args[@"allDay"];
    if ([allDay isKindOfClass:NSNumber.class]) event.allDay = allDay.boolValue;
    NSString *location = args[@"location"];
    if ([location isKindOfClass:NSString.class]) event.location = location;
    NSString *notes = args[@"notes"];
    if ([notes isKindOfClass:NSString.class]) event.notes = notes;
    event.calendar = store.defaultCalendarForNewEvents;

    [bridge presentEventEditorForEvent:event inStore:store
                            completion:^(NSString *action, NSString *identifier, NSString *error) {
      if (error != nil) {
        reply(nil, error);
        return;
      }
      BOOL saved = [action isEqualToString:DshNativeActionSaved];
      NSMutableDictionary *result = [@{@"action": action ?: DshNativeActionCancelled, @"saved": @(saved)} mutableCopy];
      if (identifier != nil) result[@"id"] = identifier;
      // Only a save is worth an audit line; a cancelled editor changed nothing.
      if (saved) result[@"auditSummary"] = event_summary(event);
      reply(result, nil);
    }];
  });
}

/// Find the event an id names, on the calendar queue, then run `next` with it.
static void with_event(NSString *identifier, DshNativeReply reply, void (^next)(EKEventStore *store, EKEvent *event)) {
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    reply(nil, @"this operation needs the event's 'id', as `list` returned it");
    return;
  }
  with_full_access(^(BOOL granted, NSString *error) {
    if (!granted) { reply(nil, error); return; }
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
      EKEvent *event = [store eventWithIdentifier:identifier];
      if (event == nil) {
        reply(nil, @"no event with that id; it may have been deleted or the id may be stale");
        return;
      }
      next(store, event);
    });
  });
}

static void update_event(NSDictionary *args, DshNativeReply reply) {
  id<DshNativeBridging> bridge = require_bridge(reply);
  if (bridge == nil) return;

  with_event(args[@"id"], reply, ^(EKEventStore *store, EKEvent *event) {
    NSString *before = event_summary(event);

    NSString *dateError = nil;
    NSDate *start = date_arg(args, @"start", &dateError);
    NSDate *end = date_arg(args, @"end", &dateError);
    if (dateError != nil) { reply(nil, dateError); return; }

    NSString *title = args[@"title"];
    if ([title isKindOfClass:NSString.class] && title.length > 0) event.title = title;
    if (start != nil) event.startDate = start;
    if (end != nil) event.endDate = end;
    NSString *location = args[@"location"];
    if ([location isKindOfClass:NSString.class]) event.location = location;
    NSString *notes = args[@"notes"];
    if ([notes isKindOfClass:NSString.class]) event.notes = notes;

    if (!event.hasChanges) {
      // Nothing to ask about. Asking anyway trains the user to tap through.
      reply(@{@"action": DshNativeActionCancelled, @"saved": @NO, @"unchanged": @YES}, nil);
      return;
    }

    NSString *summary = [NSString stringWithFormat:@"%@\n→\n%@", before, event_summary(event)];
    [bridge confirmChange:summary destructive:NO completion:^(BOOL confirmed) {
      dispatch_async(DshEventKitQueue(), ^{
        if (!confirmed) {
          // Put the store's copy back the way it was; these edits were never saved.
          [event reset];
          reply(@{@"action": DshNativeActionCancelled, @"saved": @NO}, nil);
          return;
        }
        NSError *saveError = nil;
        // This occurrence only. Changing a whole series from a one-line request
        // is a much bigger action than the user agreed to in that sheet.
        if (![store saveEvent:event span:EKSpanThisEvent commit:YES error:&saveError]) {
          reply(nil, saveError.localizedDescription ?: @"the event could not be saved");
          return;
        }
        reply(@{@"action": DshNativeActionSaved, @"saved": @YES, @"id": event.eventIdentifier ?: @"",
                @"auditSummary": summary}, nil);
      });
    }];
  });
}

static void delete_event(NSDictionary *args, DshNativeReply reply) {
  id<DshNativeBridging> bridge = require_bridge(reply);
  if (bridge == nil) return;

  with_event(args[@"id"], reply, ^(EKEventStore *store, EKEvent *event) {
    NSString *summary = event_summary(event);
    [bridge confirmChange:summary destructive:YES completion:^(BOOL confirmed) {
      dispatch_async(DshEventKitQueue(), ^{
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"deleted": @NO}, nil);
          return;
        }
        NSError *removeError = nil;
        if (![store removeEvent:event span:EKSpanThisEvent commit:YES error:&removeError]) {
          reply(nil, removeError.localizedDescription ?: @"the event could not be deleted");
          return;
        }
        reply(@{@"action": DshNativeActionDeleted, @"deleted": @YES, @"auditSummary": summary}, nil);
      });
    }];
  });
}

void dsh_native_calendar(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"list"]) {
    list_events(args, reply);
  } else if ([op isEqualToString:@"calendars"]) {
    list_calendars(reply);
  } else if ([op isEqualToString:@"create"]) {
    create_event(args, reply);
  } else if ([op isEqualToString:@"update"]) {
    update_event(args, reply);
  } else {
    delete_event(args, reply);
  }
}
