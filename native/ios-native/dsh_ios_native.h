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
void dsh_native_open(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_nlp(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_maps(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_vision(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_clipboard(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_location(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_transcribe(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_health(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_homekit(NSString *op, NSDictionary *args, DshNativeReply reply);
void dsh_native_photos(NSString *op, NSDictionary *args, DshNativeReply reply);

/// The locale to ask a geocoder to answer `query` in, chosen by the script the
/// query is written in.
///
/// Not a filter and not a judgement about the answer — just which language to
/// receive it in. Without it a Chinese query comes back as "Beijing", and a
/// caller comparing the answer to what they asked for sees two strings with
/// nothing in common. Choosing the parameters of the call is ours to do;
/// choosing among the answers is not (§4.5).
NSLocale *DshGeocodeLocaleForQuery(NSString *query);

/// Raise the location permission dialog. Only `DshNativeRequestPermission`
/// calls it; see caps_location.m for why it answers before the user does.
void DshLocationGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Raise Apple's Health sheet for every type this app reads, then run `done`.
/// Only `DshNativeRequestPermission` calls this; see caps_health.m.
///
/// `granted` is NO even when the sheet succeeded, and that is not a bug:
/// HealthKit's completion says the sheet ran, never what the user chose, and iOS
/// has no API that tells an app whether a READ was allowed. The capability
/// screen re-reads `DshHealthRequestStatus` instead.
void DshHealthGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Whether iOS would still show the Health sheet, as `HKAuthorizationRequestStatus`:
/// 0 unknown, 1 not everything has been asked about, 2 it has — which is NOT the
/// same as having been allowed. That is the whole of what can be known.
void DshHealthRequestStatus(void (^done)(NSInteger status));

/// Raise the HomeKit permission dialog, then run `done`. Only
/// `DshNativeRequestPermission` calls this; see caps_homekit.m.
///
/// HomeKit has no request-authorisation call and no side-effect-free status
/// query — creating the `HMHomeManager` *is* the prompt. So this is the only
/// place allowed to create one cold, and the capability refuses until it has
/// seen iOS grant access at least once (§5.5).
void DshHomeKitGrantAccess(void (^done)(BOOL granted, NSString *error));

/// What this app has seen iOS answer about home data, without asking again —
/// because asking is the prompt. Two booleans rather than an enum so that the
/// screen can tell "never asked" from "refused" without a new type. Neither is
/// YES before the user has been asked. Main thread only.
BOOL DshHomeKitAccessGranted(void);
BOOL DshHomeKitAccessRefused(void);

/// Raise the photo library permission dialog, then run `done`. Only
/// `DshNativeRequestPermission` calls this; see caps_photos.m for why a limited
/// selection comes back granted.
void DshPhotosGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Raise the speech-recognition permission dialog, then run `done`. Only
/// `DshNativeRequestPermission` calls this; see caps_transcribe.m.
///
/// Speech recognition only — nothing here asks for the microphone, because this
/// capability transcribes a file that already exists and never records.
void DshTranscribeGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Raise the notification permission dialog, then run `done`. Only
/// `DshNativeRequestPermission` calls this; see caps_notify.m.
void DshNotifyGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Run `block` on the main thread and return without waiting. UIKit, AVFoundation
/// and the permission prompts all want the main thread; the engine calls us from
/// Node's thread, never that one.
void dsh_native_on_main(void (^block)(void));

#endif
