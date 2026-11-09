// The one slot the app drops its UI implementation into.
//
// Deliberately tiny: the contract is in DshNativeBridge.h, the behaviour is in
// Swift, and this is only the handshake between them. Keeping it a protocol in
// a header the ObjC side owns means no capability has to import the app's
// generated Swift header, so nothing here depends on build order.
#import "DshNativeBridge.h"

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
