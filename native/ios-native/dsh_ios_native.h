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

/// Does `resolved` plausibly answer `query`, as a geocoding result?
///
/// Geocoding is region-biased, and when it cannot answer it does not say so —
/// it answers something else. Measured on a device in the China region,
/// `CLGeocoder` resolved "San Francisco" to a township in Yunnan, which then
/// produced a one-metre route between two copies of it. A confidently wrong
/// answer is worse than an error, so a resolution that shares nothing with what
/// was asked is treated as a failure to resolve.
BOOL DshGeocodePlausible(NSString *query, NSString *resolved);

/// The locale to ask a geocoder to answer `query` in, chosen by the script the
/// query is written in.
///
/// Not for display — for comparison. A geocoder answers in whatever language it
/// likes, so "北京市" comes back as "Beijing" and `DshGeocodePlausible` then
/// sees two strings with nothing in common and calls a correct answer wrong.
/// Asking for the answer in the query's own script makes the comparison
/// possible at all.
NSLocale *DshGeocodeLocaleForQuery(NSString *query);

/// Raise the location permission dialog. Only `DshNativeRequestPermission`
/// calls it; see caps_location.m for why it answers before the user does.
void DshLocationGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Raise the notification permission dialog, then run `done`. Only
/// `DshNativeRequestPermission` calls this; see caps_notify.m.
void DshNotifyGrantAccess(void (^done)(BOOL granted, NSString *error));

/// Run `block` on the main thread and return without waiting. UIKit, AVFoundation
/// and the permission prompts all want the main thread; the engine calls us from
/// Node's thread, never that one.
void dsh_native_on_main(void (^block)(void));

#endif
