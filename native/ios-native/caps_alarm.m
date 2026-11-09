// alarm: real alarm clocks, through AlarmKit (iOS 26+).
//
// Choosing between this and `notify` is the reason the two are separate, so it
// is worth stating plainly:
//
//   `notify` is an ordinary local notification. It belongs to this app, it does
//   NOT ring in silent mode, Focus can hold it back, and it is gone once it has
//   been delivered. Nothing of the user's is written.
//
//   `alarm` is a system alarm clock. It breaks through silent mode and through
//   Focus, it keeps ringing until the user does something about it, and it holds
//   a Live Activity on the lock screen while it runs. Stronger, and much more
//   intrusive.
//
// So anything the user must not sleep through or miss — waking up, medication, a
// train — is an alarm, and everything else is `notify`. The cost of getting this
// backwards is not symmetric: an alarm that should have been a notification is
// how an app loses this permission for good, while a notification that should
// have been an alarm is merely missed.
//
// This file is only a shim. AlarmKit has no Objective-C interface whatsoever
// (DshAlarmBridge.h says why), so the framework call happens in Swift and this
// keeps only what must not move: argument checking, the authorisation refusal
// (§5.5), the write confirmation and the audit summary. The confirmation in
// particular is taken here, before the provider is called at all, because a
// decision that crossed into Swift or JS would stop being a guarantee (§4.3).
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "DshAlarmBridge.h"

NSString *const DshAlarmAuthorizationAuthorized = @"authorized";
NSString *const DshAlarmAuthorizationDenied = @"denied";
NSString *const DshAlarmAuthorizationNotDetermined = @"notDetermined";
NSString *const DshAlarmAuthorizationUnsupported = @"unsupported";

static const NSUInteger kMaxTitleLength = 100;

static NSString *const kDeniedMessage =
    @"alarms are turned off for this app. The user can turn them back on in Settings, under this "
     "app's own settings. iOS only asks once, so it cannot be requested again from here";

/// The not-asked-yet refusal; the matching ones live in caps_notify.m and
/// eventkit_shared.m, and it names the screen rather than quoting its localised
/// title for the reason given there.
static NSString *const kNotEnabledMessage =
    @"the user has not switched alarms on for this app yet. Nothing was scheduled. "
     "Tell them they can turn it on themselves under Device capabilities, which is in the app's "
     "sidebar — only they can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// Said when iOS is too old for AlarmKit. Deliberately not phrased as a
/// permission problem: sending the user to Settings to look for a switch that
/// does not exist on their iPhone is worse than telling them the truth.
static NSString *const kUnsupportedMessage =
    @"this iPhone's iOS is older than 26, and real alarms need iOS 26 or later. Nothing was "
     "scheduled, and this is not something the user can turn on. Use the `notify` capability "
     "instead, but tell them it will not ring in silent mode";

static NSString *const kNoProviderMessage =
    @"the app has not registered its alarm service, so nothing was scheduled";

/// The weekday names this capability accepts, and the two letters each one
/// contributes to an audit summary.
///
/// The summary is shown to the user verbatim in an app that is translated while
/// this file is not, so it may hold only data — a time, the title the agent wrote,
/// and these fixed abbreviations (§5.4). They are not words to read, they are a
/// compact way to see that an alarm repeats on three days rather than every day.
static NSDictionary<NSString *, NSString *> *weekday_abbreviations(void) {
  static NSDictionary *map;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = @{@"monday": @"Mo", @"tuesday": @"Tu", @"wednesday": @"We", @"thursday": @"Th",
            @"friday": @"Fr", @"saturday": @"Sa", @"sunday": @"Su"};
  });
  return map;
}

/// Build the line the confirmation sheet and the audit list both show.
///
/// Takes boxed numbers so the cancel path can hand it an alarm as the provider
/// reported it, missing keys and all, without unpacking it twice.
static NSString *alarm_summary(NSString *title, NSNumber *hour, NSNumber *minute,
                               NSArray<NSString *> *weekdays) {
  BOOL named = [title isKindOfClass:NSString.class] && title.length > 0;
  NSMutableString *summary = [NSMutableString stringWithString:named ? title : @"(untitled)"];
  if ([hour isKindOfClass:NSNumber.class] && [minute isKindOfClass:NSNumber.class]) {
    [summary appendFormat:@"\n%02ld:%02ld", (long)hour.integerValue, (long)minute.integerValue];
  }
  if ([weekdays isKindOfClass:NSArray.class] && weekdays.count > 0) {
    NSMutableArray<NSString *> *days = [NSMutableArray array];
    for (id day in weekdays) {
      if (![day isKindOfClass:NSString.class]) continue;
      NSString *abbreviation = weekday_abbreviations()[[(NSString *)day lowercaseString]];
      if (abbreviation != nil) [days addObject:abbreviation];
    }
    if (days.count > 0) [summary appendFormat:@" · %@", [days componentsJoinedByString:@" "]];
  }
  return summary;
}

/// Written once at launch from the main thread, read from Node's thread. Same
/// shape and same reasoning as the bridge's own registration in bridge.m: a
/// serial queue is overkill for one pointer and costs nothing at the rate it is
/// actually written.
static dispatch_queue_t provider_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.alarm-provider", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static id<DshAlarmProviding> sProvider;

void DshAlarmSetProvider(id<DshAlarmProviding> provider) {
  dispatch_sync(provider_queue(), ^{ sProvider = provider; });
}

id<DshAlarmProviding> DshAlarmCurrentProvider(void) {
  __block id<DshAlarmProviding> provider;
  dispatch_sync(provider_queue(), ^{ provider = sProvider; });
  return provider;
}

static id<DshAlarmProviding> require_provider(DshNativeReply reply) {
  id<DshAlarmProviding> provider = DshAlarmCurrentProvider();
  if (provider == nil) {
    // Never quietly do nothing: the capability table says this build has alarms,
    // so a missing provider is a wiring bug, and saying so is how it gets found.
    reply(nil, kNoProviderMessage);
  }
  return provider;
}

/// Check AlarmKit authorisation and run `next` with the outcome.
///
/// Never prompts — hence Require and not Request. The dialog belongs to the
/// capability screen, raised only because the user tapped for it there, so that
/// the one question iOS allows per app is not spent at a moment the user was not
/// even looking (§5.5).
static void require_authorization(id<DshAlarmProviding> provider,
                                  void (^next)(BOOL granted, NSString *error)) {
  [provider alarmAuthorizationState:^(NSString *state) {
    if ([state isEqualToString:DshAlarmAuthorizationAuthorized]) {
      next(YES, nil);
    } else if ([state isEqualToString:DshAlarmAuthorizationDenied]) {
      next(NO, kDeniedMessage);
    } else if ([state isEqualToString:DshAlarmAuthorizationUnsupported]) {
      next(NO, kUnsupportedMessage);
    } else {
      next(NO, kNotEnabledMessage);
    }
  }];
}

void DshAlarmGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  id<DshAlarmProviding> provider = DshAlarmCurrentProvider();
  if (provider == nil) {
    done(NO, kNoProviderMessage);
    return;
  }
  // Ask before asking. On an iPhone too old for AlarmKit there is no dialog to
  // raise, and an empty refusal from the grant path would read on screen as the
  // user having declined something they were never offered.
  [provider alarmAuthorizationState:^(NSString *state) {
    if ([state isEqualToString:DshAlarmAuthorizationUnsupported]) {
      done(NO, kUnsupportedMessage);
      return;
    }
    [provider requestAlarmAuthorization:done];
  }];
}

#pragma mark - Reading

static void list_alarms(DshNativeReply reply) {
  id<DshAlarmProviding> provider = require_provider(reply);
  if (provider == nil) return;

  require_authorization(provider, ^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    [provider listAlarmsWithCompletion:^(NSArray<NSDictionary<NSString *, id> *> *alarms,
                                         NSString *listError) {
      if (listError != nil) {
        reply(nil, listError);
        return;
      }
      // Forwarded as they came, in AlarmKit's own order. Which alarm matters is
      // the caller's judgement about the user's day, not ours (§4.5).
      reply(@{@"alarms": alarms ?: @[], @"total": @(alarms.count)}, nil);
    }];
  });
}

#pragma mark - Writing

/// Read the weekday list, rejecting a name this capability does not know.
///
/// Returns NO and sets `error` on a bad list; an absent list is not an error, it
/// just means the alarm does not repeat.
static BOOL read_weekdays(NSDictionary *args, NSArray<NSString *> **weekdays, NSString **error) {
  id requested = args[@"repeatWeekdays"];
  if (requested == nil || [requested isKindOfClass:NSNull.class]) return YES;
  if (![requested isKindOfClass:NSArray.class]) {
    *error = @"'repeatWeekdays' must be an array of weekday names";
    return NO;
  }
  NSMutableArray<NSString *> *checked = [NSMutableArray array];
  for (id day in (NSArray *)requested) {
    NSString *name = [day isKindOfClass:NSString.class] ? [(NSString *)day lowercaseString] : nil;
    if (name == nil || weekday_abbreviations()[name] == nil) {
      // Name the shape rather than listing all seven: the agent gets this back
      // and retries, and "monday" is enough to show the pattern.
      *error = @"'repeatWeekdays' takes lowercase English weekday names, like \"monday\"";
      return NO;
    }
    if (![checked containsObject:name]) [checked addObject:name];
  }
  if (checked.count > 0) *weekdays = checked;
  return YES;
}

static void create_alarm(NSDictionary *args, DshNativeReply reply) {
  NSString *title = args[@"title"];
  if (![title isKindOfClass:NSString.class] || title.length == 0) {
    reply(nil, @"create needs a non-empty 'title'");
    return;
  }
  if (title.length > kMaxTitleLength) {
    reply(nil, [NSString stringWithFormat:@"'title' is longer than %lu characters",
                                          (unsigned long)kMaxTitleLength]);
    return;
  }
  NSNumber *hour = args[@"hour"];
  if (![hour isKindOfClass:NSNumber.class] || hour.integerValue < 0 || hour.integerValue > 23) {
    reply(nil, @"create needs 'hour' between 0 and 23");
    return;
  }
  NSNumber *minute = args[@"minute"];
  if (![minute isKindOfClass:NSNumber.class] || minute.integerValue < 0 || minute.integerValue > 59) {
    reply(nil, @"create needs 'minute' between 0 and 59");
    return;
  }
  NSArray<NSString *> *weekdays = nil;
  NSString *weekdayError = nil;
  if (!read_weekdays(args, &weekdays, &weekdayError)) {
    reply(nil, weekdayError);
    return;
  }

  NSString *summary = alarm_summary(title, hour, minute, weekdays);

  id<DshAlarmProviding> provider = require_provider(reply);
  if (provider == nil) return;

  require_authorization(provider, ^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    DshNativeConfirmWrite(@"alarm", @"create", summary, NO, ^(BOOL confirmed, NSString *refusal) {
      // Two different outcomes, and they must not collapse into one: a refusal is
      // the user's own policy saying no, which the agent has to explain and which
      // must never reach the audit; a cancel is them answering the sheet, which is
      // a normal answer and not a failure (§4.3.3).
      if (refusal != nil) {
        reply(nil, refusal);
        return;
      }
      if (!confirmed) {
        reply(@{@"action": DshNativeActionCancelled, @"created": @NO}, nil);
        return;
      }
      [provider createAlarmWithTitle:title
                                hour:hour.integerValue
                              minute:minute.integerValue
                            weekdays:weekdays
                          completion:^(NSString *identifier, NSString *createError) {
        if (createError != nil) {
          reply(nil, createError);
          return;
        }
        reply(@{@"action": DshNativeActionSaved, @"created": @YES,
                @"id": identifier ?: @"",
                @"auditSummary": summary}, nil);
      }];
    });
  });
}

static void cancel_alarm(NSDictionary *args, DshNativeReply reply) {
  NSString *identifier = args[@"id"];
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    reply(nil, @"cancel needs an 'id'");
    return;
  }

  id<DshAlarmProviding> provider = require_provider(reply);
  if (provider == nil) return;

  require_authorization(provider, ^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    // Read it back before asking anyone anything. The summary in the sheet has to
    // describe the alarm as it is right now — that is the only trustworthy thing
    // in there, and a caller's own description of what it is cancelling is not
    // evidence of anything (§4.3.1).
    [provider listAlarmsWithCompletion:^(NSArray<NSDictionary<NSString *, id> *> *alarms,
                                         NSString *listError) {
      if (listError != nil) {
        reply(nil, listError);
        return;
      }
      NSDictionary<NSString *, id> *found = nil;
      for (NSDictionary<NSString *, id> *alarm in alarms) {
        id candidate = alarm[@"id"];
        if ([candidate isKindOfClass:NSString.class] &&
            [(NSString *)candidate isEqualToString:identifier]) {
          found = alarm;
          break;
        }
      }
      if (found == nil) {
        reply(nil, @"no alarm with that id is set by this app");
        return;
      }
      NSString *summary = alarm_summary(found[@"title"], found[@"hour"], found[@"minute"],
                                        found[@"repeatWeekdays"]);
      DshNativeConfirmWrite(@"alarm", @"cancel", summary, YES, ^(BOOL confirmed, NSString *refusal) {
        if (refusal != nil) {
          reply(nil, refusal);
          return;
        }
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"cancelled": @NO}, nil);
          return;
        }
        [provider cancelAlarmWithIdentifier:identifier completion:^(NSString *cancelError) {
          if (cancelError != nil) {
            reply(nil, cancelError);
            return;
          }
          reply(@{@"action": DshNativeActionDeleted, @"cancelled": @YES,
                  @"id": identifier,
                  @"auditSummary": summary}, nil);
        }];
      });
    }];
  });
}

void dsh_native_alarm(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"create"]) {
    create_alarm(args, reply);
  } else if ([op isEqualToString:@"cancel"]) {
    cancel_alarm(args, reply);
  } else {
    list_alarms(reply);
  }
}
