// How a capability asks the app to put something in front of the user.
//
// Writes are the reason this exists. The system grant that lets us read a
// calendar lets us write it too (§4.0), so "the agent can see my schedule but
// will not quietly change it" is ours to guarantee, not iOS's. The guarantee is
// this: every write stops here, on the main thread, in front of the user, and
// **the decision never leaves the native side**. A plugin cannot intercept it,
// replay it, or carry on without it, because nothing about it crosses into JS
// (docs/native-services.md §4.3).
//
// That is also why this is a protocol the ObjC side owns rather than an import
// of Swift's generated header: the capability depends on a contract, not on the
// app's build products, and the app registers an implementation at launch.
#ifndef DSH_NATIVE_BRIDGE_H
#define DSH_NATIVE_BRIDGE_H

#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Outcomes a bridge call reports back. Strings rather than an enum so they can
/// go straight into the reply a capability sends to JS.
extern NSString *const DshNativeActionSaved;
extern NSString *const DshNativeActionCancelled;
extern NSString *const DshNativeActionDeleted;

@protocol DshNativeBridging <NSObject>

/// Show the system's own event editor, prefilled with `event`, and report what
/// the user did.
///
/// This is the strongest write path available and it costs nothing: the editor
/// is Apple's, the Add button is Apple's, and an agent cannot press it. Use it
/// for anything new.
/// `eventIdentifier` is set when the user saved, so a later turn can talk about
/// the event that was just created.
- (void)presentEventEditorForEvent:(EKEvent *)event
                           inStore:(EKEventStore *)store
                        completion:(void (^)(NSString *_Nullable action,
                                             NSString *_Nullable eventIdentifier,
                                             NSString *_Nullable error))completion;

/// Ask the user to approve one write to something they already have, described
/// exactly. Used where the system has no editor of its own to lend us:
/// everything except creating an event.
///
/// `summary` is the only trustworthy thing in the sheet — it is built natively
/// from the record as it exists right now, not from whatever the caller said it
/// was (§4.3.1).
///
/// It is shown verbatim in an app that is translated while this file is not, so
/// it holds only the record's own title and its dates, with an arrow for a
/// change. The sheet's title and buttons are the app's, and are translated there
/// — which is why `capability` and `op` come along: a sheet that says "change
/// this event?" over a reminder being created is wrong about the one thing it
/// exists to state. They are the same strings the dispatcher and the audit use.
- (void)confirmChange:(NSString *)summary
           capability:(NSString *)capability
                   op:(NSString *)op
          destructive:(BOOL)destructive
           completion:(void (^)(BOOL confirmed))completion;

@end

/// The one way a capability asks "may I change this?".
///
/// It reads the capability's write policy and does the right thing: under
/// `Direct` it answers yes without any UI at all (no bridge needed, so a write
/// no longer depends on a window being up); under `Confirm` it raises the sheet
/// above; under `Blocked` it refuses with a sentence the agent can read out.
///
/// Capabilities call this instead of `confirmChange:` directly, so the policy is
/// decided in one place rather than once per capability — the same reason the
/// dispatcher owns the permission check and the audit (§9.3).
///
/// `ok` is whether to go ahead. `error` is non-nil only when the write was
/// refused outright; a plain "the user tapped Cancel" is `ok: NO, error: nil`,
/// because that is a normal outcome and not a failure.
void DshNativeConfirmWrite(NSString *capability, NSString *op, NSString *summary,
                           BOOL destructive, void (^next)(BOOL ok, NSString *_Nullable error));

/// Registered once by the app at launch. A capability that needs UI and finds
/// no bridge refuses rather than acting unattended.
void DshNativeSetBridge(id<DshNativeBridging> _Nullable bridge);
id<DshNativeBridging> _Nullable DshNativeCurrentBridge(void);

NS_ASSUME_NONNULL_END

#endif
