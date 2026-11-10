// The one slot the app drops its UI implementation into.
//
// Deliberately tiny: the contract is in DshNativeBridge.h, the behaviour is in
// Swift, and this is only the handshake between them. Keeping it a protocol in
// a header the ObjC side owns means no capability has to import the app's
// generated Swift header, so nothing here depends on build order.
#import "DshNativeBridge.h"
#import "DshNativeCapabilities.h"

NSString *const DshNativeActionSaved = @"saved";
NSString *const DshNativeActionCancelled = @"cancelled";
NSString *const DshNativeActionDeleted = @"deleted";

/// Written once at launch from the main thread, read from Node's thread and from
/// the calendar queue. The queue is overkill for one pointer and costs nothing
/// at the rate writes actually happen (once per user confirmation).
static dispatch_queue_t bridge_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.bridge", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static id<DshNativeBridging> sBridge;

void DshNativeSetBridge(id<DshNativeBridging> bridge) {
  dispatch_sync(bridge_queue(), ^{ sBridge = bridge; });
}

id<DshNativeBridging> DshNativeCurrentBridge(void) {
  __block id<DshNativeBridging> bridge;
  dispatch_sync(bridge_queue(), ^{ bridge = sBridge; });
  return bridge;
}

void DshNativeConfirmWrite(NSString *capability, NSString *op, NSString *summary,
                           BOOL destructive, void (^next)(BOOL ok, NSString *error)) {
  switch (DshNativeWritePolicyFor(capability)) {
    case DshWritePolicyDirect:
      next(YES, nil);
      return;
    case DshWritePolicyBlocked:
      // Says who decided and where, because the agent reads this out and the
      // user may well have forgotten setting it.
      next(NO, [NSString stringWithFormat:
                @"the user has set '%@' to read-only under Device capabilities, which is in the app's "
                 "sidebar. Nothing was changed. Only they can change that setting.", capability]);
      return;
    case DshWritePolicyConfirm:
      break;
  }

  id<DshNativeBridging> bridge = DshNativeCurrentBridge();
  if (bridge == nil) {
    // Only reachable under Confirm: the user asked to be shown every write, and
    // we cannot show it. Doing it anyway would be deciding on their behalf.
    next(NO, @"the app cannot show a confirmation right now, so nothing was changed");
    return;
  }
  [bridge confirmChange:summary capability:capability op:op destructive:destructive
             completion:^(BOOL confirmed) { next(confirmed, nil); }];
}
