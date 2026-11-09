// notify: local notifications. "Remind me in 20 minutes" is the single most
// common assistant request, and this answers it without touching the Reminders
// app or any privacy permission — notification authorisation is its own prompt,
// raised by the capability screen when the user switches this on, never from
// here (docs/native-services.md §5.5).
//
// These are the agent's own notifications, not calendar events or reminders:
// nothing is written to the user's data, and they disappear once delivered.
#import "dsh_ios_native.h"
#import <UserNotifications/UserNotifications.h>

static NSString *const kIdentifierPrefix = @"dsh.agent.";

static NSString *const kDeniedMessage =
    @"notifications are turned off for this app; turn them on in Settings > Notifications";

/// The not-asked-yet refusal; see the matching one in eventkit_shared.m for why
/// it names the screen rather than quoting its localised title.
static NSString *const kNotEnabledMessage =
    @"the user has not switched notifications on for this app yet. Nothing was scheduled. "
     "Tell them they can turn it on themselves under Device capabilities, which is in the app's "
     "sidebar — only they can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// Check notification authorisation and run `next` with the outcome. Never
/// prompts: `requestAuthorizationWithOptions:` *is* the prompt, so calling it
/// here would let whichever plugin schedules first raise a system dialog.
static void require_authorization(void (^next)(BOOL granted, NSString *error)) {
  [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:
   ^(UNNotificationSettings *settings) {
    switch (settings.authorizationStatus) {
      case UNAuthorizationStatusAuthorized:
      case UNAuthorizationStatusProvisional:
      case UNAuthorizationStatusEphemeral:
        next(YES, nil);
        return;
      case UNAuthorizationStatusDenied:
        // Actionable, because the agent will read this out to the user: iOS only
        // ever prompts once, so after a denial the Settings app is the only way back.
        next(NO, kDeniedMessage);
        return;
      case UNAuthorizationStatusNotDetermined:
      default:
        next(NO, kNotEnabledMessage);
        return;
    }
  }];
}

void DshNotifyGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  [UNUserNotificationCenter.currentNotificationCenter
   requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                 completionHandler:^(BOOL granted, NSError *error) {
    if (error != nil) {
      done(NO, error.localizedDescription);
    } else if (!granted) {
      done(NO, kDeniedMessage);
    } else {
      done(YES, nil);
    }
  }];
}

static void schedule(NSDictionary *args, DshNativeReply reply) {
  NSString *body = args[@"body"];
  if (![body isKindOfClass:NSString.class] || body.length == 0) {
    reply(nil, @"schedule needs a non-empty 'body'");
    return;
  }
  NSNumber *seconds = args[@"afterSeconds"];
  if (![seconds isKindOfClass:NSNumber.class] || seconds.doubleValue < 1) {
    reply(nil, @"schedule needs 'afterSeconds' >= 1");
    return;
  }

  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  NSString *title = args[@"title"];
  content.title = [title isKindOfClass:NSString.class] && title.length > 0 ? title : @"Fish Pocket";
  content.body = body;
  content.sound = UNNotificationSound.defaultSound;

  NSString *identifier = [kIdentifierPrefix stringByAppendingString:NSUUID.UUID.UUIDString];
  UNNotificationRequest *request =
    [UNNotificationRequest requestWithIdentifier:identifier
                                         content:content
                                         trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:seconds.doubleValue
                                                                                                   repeats:NO]];

  require_authorization(^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request
                                                        withCompletionHandler:^(NSError *addError) {
      if (addError != nil) {
        reply(nil, addError.localizedDescription);
      } else {
        reply(@{@"id": identifier,
                @"deliversAt": @([NSDate.date timeIntervalSince1970] + seconds.doubleValue),
                // The user's own wording, which is the most useful thing their
                // audit list can show and needs no translating.
                @"auditSummary": body}, nil);
      }
    }];
  });
}

static void cancel(NSDictionary *args, DshNativeReply reply) {
  NSString *identifier = args[@"id"];
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    reply(nil, @"cancel needs an 'id'");
    return;
  }
  // Only our own: the prefix check keeps this from cancelling a notification
  // another part of the app scheduled.
  if (![identifier hasPrefix:kIdentifierPrefix]) {
    reply(nil, @"that id was not scheduled by the agent");
    return;
  }
  [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[identifier]];
  reply(@{@"cancelled": identifier}, nil);
}

static void pending(DshNativeReply reply) {
  [UNUserNotificationCenter.currentNotificationCenter getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
    NSMutableArray *list = [NSMutableArray array];
    for (UNNotificationRequest *request in requests) {
      if (![request.identifier hasPrefix:kIdentifierPrefix]) continue;
      NSMutableDictionary *entry = [@{@"id": request.identifier,
                                      @"title": request.content.title ?: @"",
                                      @"body": request.content.body ?: @""} mutableCopy];
      if ([request.trigger isKindOfClass:UNTimeIntervalNotificationTrigger.class]) {
        NSDate *next = [(UNTimeIntervalNotificationTrigger *)request.trigger nextTriggerDate];
        if (next != nil) entry[@"deliversAt"] = @(next.timeIntervalSince1970);
      }
      [list addObject:entry];
    }
    reply(@{@"notifications": list}, nil);
  }];
}

void dsh_native_notify(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"schedule"]) {
    schedule(args, reply);
  } else if ([op isEqualToString:@"cancel"]) {
    cancel(args, reply);
  } else {
    pending(reply);
  }
}
