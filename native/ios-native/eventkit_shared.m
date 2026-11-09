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

void DshEventKitRequestAccess(EKEntityType type, NSString *deniedMessage,
                              void (^next)(BOOL granted, NSString *error)) {
  switch ([EKEventStore authorizationStatusForEntityType:type]) {
    case EKAuthorizationStatusFullAccess:
      next(YES, nil);
      return;
    case EKAuthorizationStatusDenied:
    case EKAuthorizationStatusRestricted:
      next(NO, deniedMessage);
      return;
    case EKAuthorizationStatusWriteOnly:
      // Events only; iOS has no add-only tier for reminders. Reading needs full
      // access, and add-only cannot read back even what it just wrote (§4.0).
      next(NO, @"this app has add-only access, which cannot read. Reading needs Full Access, "
                "which the user can switch on in Settings > Privacy & Security");
      return;
    case EKAuthorizationStatusNotDetermined:
    default:
      break;
  }

  // The prompt is UI. It is also the only place the user is ever told what this
  // app does with their data, which is why the Info.plist wording matters as
  // much as the code (§6.2.1).
  void (^granted)(BOOL, NSError *) = ^(BOOL ok, NSError *error) {
    if (error != nil) {
      next(NO, error.localizedDescription);
    } else if (!ok) {
      next(NO, deniedMessage);
    } else {
      // A store queried before the grant keeps answering from the old, empty
      // view until it is reset. Without this the first call after the user taps
      // Allow comes back empty, which reads exactly like having no data.
      [DshEventStore() reset];
      next(YES, nil);
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
