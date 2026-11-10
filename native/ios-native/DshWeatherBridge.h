// How the weather capability reaches WeatherKit, which Objective-C cannot.
//
// WeatherKit is the second framework here with no Objective-C surface (AlarmKit
// was the first; DshAlarmBridge.h has the long version of this argument). Its
// only entry point is `async throws`, and everything it answers with is a Swift
// value type wrapped in `Measurement`s — there is no class to message and no
// header to import. So the framework call is in Swift, and this file is the seam.
//
// Same shape as the alarm seam and for the same reason: the capability depends
// on a contract the ObjC side owns, the app registers an implementation at
// launch, and the capability table in ios_native.m stays the single dispatch
// path. Nothing about weather needs a permission or a write confirmation, but a
// second path would still be a second place to forget the next rule that is
// added to the first.
#ifndef DSH_WEATHER_BRIDGE_H
#define DSH_WEATHER_BRIDGE_H

#import <Foundation/Foundation.h>
#import "dsh_ios_native.h"

NS_ASSUME_NONNULL_BEGIN

/// What the app implements so the weather capability has something to call.
///
/// **A provider decides nothing.** Coordinates arrive already range-checked and
/// `hours` already bounded, so it does not re-validate them; it asks WeatherKit
/// and turns the answer into plain dictionaries, in the framework's own order,
/// without dropping or re-ranking anything (§4.5). How many entries the caller
/// gets to see is cut in caps_weather.m, not here.
///
/// Every completion is called exactly once, on any thread, with exactly one of
/// its two arguments non-nil.
///
/// The failure is an `NSError` and not a sentence, unlike the alarm seam. The
/// one failure worth explaining — the app is not provisioned for WeatherKit —
/// is recognisable only from the error's domain, and the explaining is wording,
/// which belongs in caps_weather.m with every other refusal.
///
/// Each answer carries, besides its own payload:
///   `units`        the fixed units every number is in, so nobody has to guess
///   `timeZone`     the zone every date string is written in
///   `attribution`  `{service, legalURL}` — required by the WeatherKit licence
///                  on anything that shows this data, so it travels with it
@protocol DshWeatherProviding <NSObject>

/// Conditions now at a point. The answer's `current` is one dictionary.
- (void)currentWeatherAtLatitude:(double)latitude
                       longitude:(double)longitude
                      completion:(void (^)(NSDictionary<NSString *, id> *_Nullable answer,
                                           NSError *_Nullable error))done;

/// The hourly forecast for the window from now to `hours` hours ahead. The
/// answer's `hours` is an array, earliest first.
///
/// It holds whatever WeatherKit returned for that window, which may be an entry
/// more than `hours`: the window is in hours, but which partial hour at either
/// end counts is the framework's call.
- (void)hourlyWeatherAtLatitude:(double)latitude
                      longitude:(double)longitude
                          hours:(NSInteger)hours
                     completion:(void (^)(NSDictionary<NSString *, id> *_Nullable answer,
                                          NSError *_Nullable error))done;

/// The daily forecast, as far ahead as WeatherKit gives it by default (ten days,
/// starting with today at that point). The answer's `days` is an array, earliest
/// first.
- (void)dailyWeatherAtLatitude:(double)latitude
                     longitude:(double)longitude
                    completion:(void (^)(NSDictionary<NSString *, id> *_Nullable answer,
                                         NSError *_Nullable error))done;

@end

/// Registered once by the app at launch, next to `DshAlarmSetProvider`.
void DshWeatherSetProvider(id<DshWeatherProviding> _Nullable provider);
id<DshWeatherProviding> _Nullable DshWeatherCurrentProvider(void);

// The handler the capability table dispatches to. It also belongs in
// dsh_ios_native.h beside its siblings, and declaring it there as well is
// harmless for the reason DshAlarmBridge.h gives: that header annotates no
// nullability, so the redeclaration cannot conflict with this one.
void dsh_native_weather(NSString *op, NSDictionary *args, DshNativeReply reply);

NS_ASSUME_NONNULL_END

#endif
