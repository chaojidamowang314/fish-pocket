// What the app can tell the user about which native capabilities were used.
//
// With no app-layer permission gate, this is the only place a user can see what
// this app did with the data they allowed it to reach (docs/native-services.md
// §5.4), so it is a feature rather than a diagnostic.
//
// Kept free of node_api.h so SwiftUI can read it through the bridging header.
// It lives on the native side on purpose: an audit the engine could write is an
// audit a plugin could rewrite.
#ifndef DSH_NATIVE_AUDIT_H
#define DSH_NATIVE_AUDIT_H

#import <Foundation/Foundation.h>

/// Record one capability call that succeeded. Safe from any thread.
///
/// `callerClaim` is what the caller said it was, and the name says so: a plugin
/// can present itself as the engine with one line (§2.2), so this is a hint for
/// the user, never an input to a decision. Nil when nothing was claimed.
/// `summary` is the capability's own one-line account of what it did; nil when
/// there is nothing worth saying beyond the operation name.
///
/// The app shows `summary` to the user **verbatim**, and the app is translated
/// while this file is not. So a summary must be language-neutral — dates,
/// counts, an event title, the user's own words — never a sentence. The row's
/// wording ("Calendar · read events") is the app's job, built from `capability`
/// and `op`.
void DshNativeAuditRecord(NSString *capability, NSString *op, NSString *callerClaim, NSString *summary);

/// The recorded calls, newest first. Each entry has `capability`, `op` and `at`
/// (seconds since 1970), plus `caller` and `summary` when they are known.
NSArray<NSDictionary<NSString *, id> *> *DshNativeAuditEntries(void);

/// Forget every recorded call.
void DshNativeAuditClear(void);

#endif
