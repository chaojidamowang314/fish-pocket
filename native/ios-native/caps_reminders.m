// reminders: the user's Reminders app.
//
// Not the same thing as `notify`, and the difference decides which one an agent
// should reach for. `notify` schedules a local notification: it fires once, it
// belongs to this app, and it leaves nothing behind — so "remind me in twenty
// minutes" needs no confirmation and no permission beyond notifications.
// Writing here puts a row in the user's own Reminders, which syncs to their
// other devices and may be a list they share with someone. That is their data,
// so every write stops for a confirmation, the same as the calendar's (§4.3).
//
// Reminders have no add-only tier and no system editor to borrow (EventKit's
// editor is events-only), so all three writes go through our own sheet.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "eventkit_shared.h"

static const NSUInteger kMaxReminders = 200;
static const NSUInteger kMaxNotesLength = 500;

static NSString *const kDeniedMessage =
  @"reminders access is off for this app. The user can turn it on in "
  @"Settings > Privacy & Security > Reminders. iOS only asks once, so it cannot be requested again from here";

static void with_access(void (^next)(BOOL granted, NSString *error)) {
  DshEventKitRequestAccess(EKEntityTypeReminder, kDeniedMessage, next);
}

/// EKReminder keeps its due date as components, not a date.
static NSDate *due_date(EKReminder *reminder) {
  NSDateComponents *components = reminder.dueDateComponents;
  return components == nil ? nil : [NSCalendar.currentCalendar dateFromComponents:components];
}

static NSDateComponents *components_for(NSDate *date) {
  return [NSCalendar.currentCalendar
          components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
                   | NSCalendarUnitHour | NSCalendarUnitMinute
            fromDate:date];
}

static NSString *truncated(NSString *text, NSUInteger limit) {
  if (text.length <= limit) return text;
  NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:limit];
  return [[text substringToIndex:range.location] stringByAppendingString:@"…"];
}

static NSDictionary *reminder_json(EKReminder *reminder) {
  NSMutableDictionary *entry = [@{
    @"id": reminder.calendarItemIdentifier ?: @"",
    @"title": reminder.title ?: @"",
    @"completed": @(reminder.completed),
    @"list": reminder.calendar.title ?: @"",
  } mutableCopy];
  NSDate *due = due_date(reminder);
  if (due != nil) entry[@"due"] = DshISO8601(due);
  if (reminder.notes.length > 0) entry[@"notes"] = truncated(reminder.notes, kMaxNotesLength);
  // 0 is "none"; 1-4 high, 5 medium, 6-9 low, as EventKit defines it.
  if (reminder.priority != 0) entry[@"priority"] = @(reminder.priority);
  return entry;
}

/// Title and due date only: shown verbatim in a translated app, built natively
/// from the reminder as it is right now (§4.3.1).
static NSString *reminder_summary(EKReminder *reminder) {
  NSString *title = reminder.title.length > 0 ? reminder.title : @"(untitled)";
  NSDate *due = due_date(reminder);
  if (due == nil) return title;
  NSString *iso = DshISO8601(due);
  return [NSString stringWithFormat:@"%@\n%@ %@", title,
          [iso substringToIndex:10], [iso substringWithRange:NSMakeRange(11, 5)]];
}

static id<DshNativeBridging> require_bridge(DshNativeReply reply) {
  id<DshNativeBridging> bridge = DshNativeCurrentBridge();
  if (bridge == nil) {
    reply(nil, @"the app cannot show a confirmation right now, so nothing was changed");
  }
  return bridge;
}

#pragma mark - Reading

static void list_reminders(NSDictionary *args, DshNativeReply reply) {
  NSNumber *includeCompleted = args[@"includeCompleted"];
  BOOL wantCompleted = [includeCompleted isKindOfClass:NSNumber.class] && includeCompleted.boolValue;

  with_access(^(BOOL granted, NSString *error) {
    if (!granted) { reply(nil, error); return; }
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
      // Unfinished ones are what "what do I have to do" means; finished ones are
      // only asked for on purpose.
      NSPredicate *predicate = wantCompleted
        ? [store predicateForRemindersInCalendars:nil]
        : [store predicateForIncompleteRemindersWithDueDateStarting:nil ending:nil calendars:nil];
      // This fetch is already asynchronous, so it does not block the queue it
      // was asked on.
      [store fetchRemindersMatchingPredicate:predicate completion:^(NSArray<EKReminder *> *found) {
        if (found == nil) {
          reply(nil, @"the reminders could not be read");
          return;
        }
        NSArray<EKReminder *> *sorted = [found sortedArrayUsingComparator:^NSComparisonResult(EKReminder *a, EKReminder *b) {
          NSDate *left = due_date(a), *right = due_date(b);
          // Undated ones last: a list that opens with everything undated buries
          // whatever is actually due.
          if (left == nil && right == nil) return [a.title ?: @"" compare:b.title ?: @""];
          if (left == nil) return NSOrderedDescending;
          if (right == nil) return NSOrderedAscending;
          return [left compare:right];
        }];

        NSMutableArray *reminders = [NSMutableArray array];
        for (EKReminder *reminder in sorted) {
          if (reminders.count >= kMaxReminders) break;
          [reminders addObject:reminder_json(reminder)];
        }
        reply(@{@"reminders": reminders,
                @"total": @(sorted.count),
                @"truncated": @(sorted.count > reminders.count),
                @"auditSummary": [NSString stringWithFormat:@"· %lu", (unsigned long)sorted.count]}, nil);
      }];
    });
  });
}

#pragma mark - Writing

static void create_reminder(NSDictionary *args, DshNativeReply reply) {
  NSString *title = args[@"title"];
  if (![title isKindOfClass:NSString.class] || title.length == 0) {
    reply(nil, @"create needs a non-empty 'title'");
    return;
  }
  NSNumber *dueSeconds = args[@"due"];
  if (dueSeconds != nil && ![dueSeconds isKindOfClass:NSNumber.class]) {
    reply(nil, @"'due' must be seconds since 1970");
    return;
  }
  id<DshNativeBridging> bridge = require_bridge(reply);
  if (bridge == nil) return;

  with_access(^(BOOL granted, NSString *error) {
    if (!granted) { reply(nil, error); return; }
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
      EKReminder *reminder = [EKReminder reminderWithEventStore:store];
      reminder.title = title;
      reminder.calendar = store.defaultCalendarForNewReminders;
      NSString *notes = args[@"notes"];
      if ([notes isKindOfClass:NSString.class]) reminder.notes = notes;
      if (dueSeconds != nil) {
        NSDate *due = [NSDate dateWithTimeIntervalSince1970:dueSeconds.doubleValue];
        reminder.dueDateComponents = components_for(due);
        // A due date on its own is silent. Without an alarm the user is told
        // nothing when the time comes, which is not what they asked for.
        [reminder addAlarm:[EKAlarm alarmWithAbsoluteDate:due]];
      }
      if (reminder.calendar == nil) {
        reply(nil, @"this device has no list to put reminders in");
        return;
      }

      NSString *summary = reminder_summary(reminder);
      [bridge confirmChange:summary destructive:NO completion:^(BOOL confirmed) {
        dispatch_async(DshEventKitQueue(), ^{
          if (!confirmed) {
            reply(@{@"action": DshNativeActionCancelled, @"saved": @NO}, nil);
            return;
          }
          NSError *saveError = nil;
          if (![store saveReminder:reminder commit:YES error:&saveError]) {
            reply(nil, saveError.localizedDescription ?: @"the reminder could not be saved");
            return;
          }
          reply(@{@"action": DshNativeActionSaved, @"saved": @YES,
                  @"id": reminder.calendarItemIdentifier ?: @"",
                  @"auditSummary": summary}, nil);
        });
      }];
    });
  });
}

/// Find the reminder an id names, then run `next` with it on the EventKit queue.
static void with_reminder(NSString *identifier, DshNativeReply reply,
                          void (^next)(EKEventStore *store, EKReminder *reminder)) {
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    reply(nil, @"this operation needs the reminder's 'id', as `list` returned it");
    return;
  }
  with_access(^(BOOL granted, NSString *error) {
    if (!granted) { reply(nil, error); return; }
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
      EKCalendarItem *item = [store calendarItemWithIdentifier:identifier];
      if (![item isKindOfClass:EKReminder.class]) {
        reply(nil, @"no reminder with that id; it may have been deleted or the id may be stale");
        return;
      }
      next(store, (EKReminder *)item);
    });
  });
}

static void complete_reminder(NSDictionary *args, DshNativeReply reply) {
  id<DshNativeBridging> bridge = require_bridge(reply);
  if (bridge == nil) return;

  with_reminder(args[@"id"], reply, ^(EKEventStore *store, EKReminder *reminder) {
    if (reminder.completed) {
      // Already done. Asking anyway trains the user to tap through sheets.
      reply(@{@"action": DshNativeActionCancelled, @"saved": @NO, @"unchanged": @YES}, nil);
      return;
    }
    NSString *summary = reminder_summary(reminder);
    [bridge confirmChange:summary destructive:NO completion:^(BOOL confirmed) {
      dispatch_async(DshEventKitQueue(), ^{
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"saved": @NO}, nil);
          return;
        }
        reminder.completed = YES;
        NSError *saveError = nil;
        if (![store saveReminder:reminder commit:YES error:&saveError]) {
          reply(nil, saveError.localizedDescription ?: @"the reminder could not be updated");
          return;
        }
        reply(@{@"action": DshNativeActionSaved, @"saved": @YES, @"auditSummary": summary}, nil);
      });
    }];
  });
}

static void delete_reminder(NSDictionary *args, DshNativeReply reply) {
  id<DshNativeBridging> bridge = require_bridge(reply);
  if (bridge == nil) return;

  with_reminder(args[@"id"], reply, ^(EKEventStore *store, EKReminder *reminder) {
    NSString *summary = reminder_summary(reminder);
    [bridge confirmChange:summary destructive:YES completion:^(BOOL confirmed) {
      dispatch_async(DshEventKitQueue(), ^{
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"deleted": @NO}, nil);
          return;
        }
        NSError *removeError = nil;
        if (![store removeReminder:reminder commit:YES error:&removeError]) {
          reply(nil, removeError.localizedDescription ?: @"the reminder could not be deleted");
          return;
        }
        reply(@{@"action": DshNativeActionDeleted, @"deleted": @YES, @"auditSummary": summary}, nil);
      });
    }];
  });
}

void dsh_native_reminders(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"list"]) {
    list_reminders(args, reply);
  } else if ([op isEqualToString:@"create"]) {
    create_reminder(args, reply);
  } else if ([op isEqualToString:@"complete"]) {
    complete_reminder(args, reply);
  } else {
    delete_reminder(args, reply);
  }
}
