// How the alarm capability reaches AlarmKit, which Objective-C cannot.
//
// Every other capability calls its framework straight from its own caps_*.m.
// AlarmKit cannot be called from here at all: the framework ships an umbrella
// header that exports nothing but two version symbols, and its whole public
// surface — generic over an `AlarmMetadata` conformance, `async throws`,
// `AsyncSequence`, plus ActivityKit and SwiftUI types — has no Objective-C
// representation. It is not a missing header we could work around; there is
// nothing to declare. So this one capability is implemented in Swift, and this
// file is the seam.
//
// It is deliberately the same shape as DshNativeBridge.h rather than an import
// of the app's generated Swift header: the capability depends on a contract the
// ObjC side owns, not on the app's build products, and the app registers an
// implementation at launch. That keeps the capability table in ios_native.m the
// single dispatch path, so the permission check, the write policy and the audit
// still happen there, exactly once, and this capability cannot slip around them
// the way a second path would let it (§9.3).
#ifndef DSH_ALARM_BRIDGE_H
#define DSH_ALARM_BRIDGE_H

#import <Foundation/Foundation.h>
#import "dsh_ios_native.h"

NS_ASSUME_NONNULL_BEGIN

/// What the provider reports when asked about authorisation. Strings rather than
/// an enum so the refusal wording stays in caps_alarm.m next to every other
/// refusal this capability can produce, instead of being split across the
/// language boundary.
extern NSString *const DshAlarmAuthorizationAuthorized;
extern NSString *const DshAlarmAuthorizationDenied;
extern NSString *const DshAlarmAuthorizationNotDetermined;
/// The OS is older than AlarmKit. A state and not an error, because "this iPhone
/// cannot do it" and "you have not allowed it" are different things to tell the
/// user, and the agent reads that difference out loud. Reporting them the same
/// way would send the user hunting through Settings for a switch that is not there.
extern NSString *const DshAlarmAuthorizationUnsupported;

/// What the app implements so the alarm capability has something to call.
///
/// **A provider decides nothing.** Argument checking, the authorisation refusal
/// (§5.5), the write confirmation and the audit summary all happen in
/// caps_alarm.m, and a provider is only ever called once those have passed. The
/// write confirmation especially does not move: it has to stay on the one native
/// path, because that is the whole reason a plugin cannot replay it or carry on
/// without it (§4.3). A provider's job is to do what was already approved, and
/// to answer honestly about authorisation.
@protocol DshAlarmProviding <NSObject>

/// The current AlarmKit authorisation, as one of the constants above.
///
/// **Never prompts.** The capability screen reads this every time it appears, and
/// a read that could raise a system dialog would put that dialog in front of a
/// user who was only looking at a list (§5.5).
- (void)alarmAuthorizationState:(void (^)(NSString *state))done;

/// Raise the AlarmKit authorisation dialog. Reached only through
/// `DshNativeRequestPermission`, which is only reached from the capability
/// screen's "turn on" button.
///
/// A plain "the user said no" is `granted: NO, error: nil`: the wording for that
/// belongs to the screen, which is translated, and not to this file, which is not.
- (void)requestAlarmAuthorization:(void (^)(BOOL granted, NSString *_Nullable error))done;

/// Every alarm this app currently has set, in AlarmKit's own order.
///
/// Each entry carries `id` and `state`, plus `title`, `hour` and `minute` and an
/// optional `repeatWeekdays` for a recurring one, or `at` (seconds since 1970)
/// for one set to a fixed moment. Keys are absent rather than null when AlarmKit
/// has nothing to report for them.
- (void)listAlarmsWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, id> *> *_Nullable alarms,
                                           NSString *_Nullable error))done;

/// Set one alarm. Arguments arrive already checked, so a provider does not
/// re-validate them: `hour` is 0-23, `minute` is 0-59, and each weekday is one of
/// the lowercase English names caps_alarm.m accepts.
///
/// `weekdays` nil or empty means a one-off alarm at the next occurrence of that
/// time; otherwise it repeats weekly on those days.
- (void)createAlarmWithTitle:(NSString *)title
                        hour:(NSInteger)hour
                      minute:(NSInteger)minute
                    weekdays:(nullable NSArray<NSString *> *)weekdays
                  completion:(void (^)(NSString *_Nullable identifier,
                                       NSString *_Nullable error))done;

/// Cancel one alarm by the id `list` or `create` reported.
- (void)cancelAlarmWithIdentifier:(NSString *)identifier
                       completion:(void (^)(NSString *_Nullable error))done;

@end

/// Registered once by the app at launch, next to `DshNativeSetBridge`.
///
/// Registered on every iOS version, including the ones too old for AlarmKit: a
/// provider that reports `Unsupported` lets the capability say why, while no
/// provider at all can only say the app is wired wrong.
void DshAlarmSetProvider(id<DshAlarmProviding> _Nullable provider);
id<DshAlarmProviding> _Nullable DshAlarmCurrentProvider(void);

// The two entry points ios_native.m wires up: the handler the capability table
// dispatches to, and the one grant path `DshNativeRequestPermission` calls.
//
// Both also belong in dsh_ios_native.h beside their siblings, and declaring them
// there as well is harmless: that header annotates no nullability, and
// unspecified agrees with anything, so the redeclaration cannot conflict with
// the implicit _Nonnull these pick up here.

void dsh_native_alarm(NSString *op, NSDictionary *args, DshNativeReply reply);

/// Raise the AlarmKit permission dialog. Only `DshNativeRequestPermission` calls
/// it; see caps_alarm.m.
void DshAlarmGrantAccess(void (^done)(BOOL granted, NSString *_Nullable error));

NS_ASSUME_NONNULL_END

#endif
