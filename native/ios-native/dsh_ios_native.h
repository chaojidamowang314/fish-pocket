// Internal interface between the N-API entry (ios_native.m) and the capability
// implementations (caps_*.m). Everything crosses this seam as Foundation
// objects; the entry owns all JSON and N-API handling, a capability owns only
// its framework call.
#ifndef DSH_IOS_NATIVE_H
#define DSH_IOS_NATIVE_H

#import <Foundation/Foundation.h>

/// Settle one capability call. Exactly one of `result` / `error` is non-nil.
/// May be invoked on any thread, including synchronously before the capability
/// function returns.
typedef void (^DshNativeReply)(NSDictionary *result, NSString *error);

/// One capability's entry point. `op` is the operation within the capability
/// (already validated to be one the capability declared), `args` the decoded
/// arguments object (never nil; empty when the caller passed none).
typedef void (*DshNativeHandler)(NSString *op, NSDictionary *args, DshNativeReply reply);

// Capability handlers. One per caps_*.m.
void dsh_native_device(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_notify(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_speak(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_calendar(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_reminders(NSString *op, NSDictionary *args, DshNativeReply reply);

/// Raise the notification permission dialog, then run `done`. Only
/// `DshNativeRequestPermission` calls this; see caps_notify.m.
void DshNotifyGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Run `block` on the main thread and return without waiting. UIKit, AVFoundation
/// and the permission prompts all want the main thread; the engine calls us from
/// Node's thread, never that one.
void dsh_native_on_main(void (^block)(void));

#endif
