#import "eventkit_shared.h"
#import "dsh_ios_native.h"

EKEventStore *DshEventStore(void) {
  static EKEventStore *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [EKEventStore new]; });
  return shared;
}

dispatch_queue_t DshEventKitQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.eventkit", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

NSString *DshISO8601(NSDate *date) {
  static NSISO8601DateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    formatter.timeZone = NSTimeZone.localTimeZone;
  });
  return date == nil ? @"" : [formatter stringFromDate:date];
}

/// The not-asked-yet refusal. Deliberately not a localised string: it is read by
/// the model, which relays it in the user's own language. It describes where the
/// switch is rather than quoting the screen's title, because this file is not
/// translated and a quoted title here would drift from the one on screen.
static NSString *const kNotEnabledMessage =
    @"the user has not switched this capability on for this app yet. Nothing was read or changed. "
     "Tell them they can turn it on themselves under Device capabilities, which is in the app's "
     "sidebar — only they can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// Shared tail of both entry points: iOS answered, so turn that answer into
/// either a go-ahead or a sentence the agent can read out.
static void settle(EKAuthorizationStatus status, BOOL writeOnlyIsEnough, NSString *deniedMessage,
                   void (^next)(BOOL granted, NSString *error), BOOL *resolved) {
  *resolved = YES;
  switch (status) {
    case EKAuthorizationStatusFullAccess:
      next(YES, nil);
      return;
    case EKAuthorizationStatusDenied:
    case EKAuthorizationStatusRestricted:
      next(NO, deniedMessage);
      return;
    case EKAuthorizationStatusWriteOnly:
      // Events only; iOS has no add-only tier for reminders. Adding is all this
      // tier can do — it cannot read back even what it just wrote (§4.0).
      if (writeOnlyIsEnough) {
        next(YES, nil);
      } else {
        next(NO, @"this app has add-only access, which cannot read. Reading needs Full Access, "
                  "which the user can switch on in Settings > Privacy & Security");
      }
      return;
    case EKAuthorizationStatusNotDetermined:
    default:
      *resolved = NO;
      return;
  }
}

void DshEventKitRequireAccess(EKEntityType type, BOOL writeOnlyIsEnough, NSString *deniedMessage,
                              void (^next)(BOOL granted, NSString *error)) {
  BOOL resolved = NO;
  settle([EKEventStore authorizationStatusForEntityType:type], writeOnlyIsEnough, deniedMessage, next, &resolved);
  // Not asked yet. This is where the old code raised the dialog; it now refuses,
  // so the first thing a plugin does can never be to put a system prompt on the
  // user's screen on the app's behalf.
  if (!resolved) next(NO, kNotEnabledMessage);
}

void DshEventKitGrantAccess(EKEntityType type, NSString *deniedMessage,
                            void (^done)(BOOL granted, NSString *error)) {
  BOOL resolved = NO;
  // The grant screen always asks for full access, so add-only can only be
  // something the user chose in Settings: report it, do not ask again.
  settle([EKEventStore authorizationStatusForEntityType:type], NO, deniedMessage, done, &resolved);
  // Already answered, one way or the other: iOS will not ask again, and `settle`
  // has already said what the answer was.
  if (resolved) return;

  // The prompt is UI. It is also the only place the user is ever told what this
  // app does with their data, which is why the Info.plist wording matters as
  // much as the code (§6.2.1).
  void (^granted)(BOOL, NSError *) = ^(BOOL ok, NSError *error) {
    if (error != nil) {
      done(NO, error.localizedDescription);
    } else if (!ok) {
      done(NO, deniedMessage);
    } else {
      // A store queried before the grant keeps answering from the old, empty
      // view until it is reset. Without this the first call after the user taps
      // Allow comes back empty, which reads exactly like having no data.
      [DshEventStore() reset];
      done(YES, nil);
    }
  };
  dsh_native_on_main(^{
    if (type == EKEntityTypeReminder) {
      [DshEventStore() requestFullAccessToRemindersWithCompletion:granted];
    } else {
      [DshEventStore() requestFullAccessToEventsWithCompletion:granted];
    }
  });
}
