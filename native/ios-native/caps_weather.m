// weather: current conditions and forecasts for a coordinate, from WeatherKit.
//
// **Nothing here reads where the user is.** Every operation takes a latitude and
// a longitude the caller names, which is why this capability has no permission
// and no switch: it is Apple's servers answering a question about a point on the
// map. "The weather here" is a `location` question first and a `weather`
// question second, exactly as "near me" is for `maps`, and keeping them apart
// means "will it rain in Chengdu tomorrow" costs no privacy at all.
//
// This file is only a shim. WeatherKit has no Objective-C interface
// (DshWeatherBridge.h says why), so the framework call happens in Swift and this
// keeps what must not be split across the language boundary: argument checking,
// the cut to the count the caller asked for, and every sentence a caller can be
// refused with.
#import "dsh_ios_native.h"
#import "DshWeatherBridge.h"

static const NSInteger kDefaultHours = 24;
/// Ten days of hours, the same horizon as the daily forecast. WeatherKit does not
/// promise hourly data that far out everywhere; when it has less, `total` in the
/// result is what says so.
static const NSInteger kMaxHours = 240;
static const NSInteger kDefaultDays = 7;
/// WeatherKit's daily forecast is ten days long; asking for more would promise
/// days that never arrive.
static const NSInteger kMaxDays = 10;

static NSString *const kNoProviderMessage =
    @"the app has not registered its weather service, so no forecast was fetched";

/// Said in front of WeatherKit's own error when that error is its refusal to
/// authenticate the app.
///
/// WeatherKit only answers an app whose App ID has the WeatherKit capability and
/// app service enabled and whose build carries the matching entitlement. Without
/// them every request fails with an opaque daemon error that reads like a network
/// blip, and an agent that relays it as "try again later" sends the user round a
/// loop that cannot end. So this one case gets a plain sentence in front, and the
/// framework's text is still passed through behind it for whoever debugs it.
static NSString *const kNotProvisionedPrefix =
    @"Weather is not enabled for this build of the app yet: Apple's weather service refused to "
     "authenticate it. That is a setup step on the developer's side — nothing the user can switch "
     "on, and retrying will not help. Tell them weather is not available in this version. "
     "The system's own error was: ";

/// Same registration as the alarm provider in caps_alarm.m, for the same reason:
/// written once at launch from the main thread, read from Node's thread.
static dispatch_queue_t provider_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.weather-provider", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static id<DshWeatherProviding> sProvider;

void DshWeatherSetProvider(id<DshWeatherProviding> provider) {
  dispatch_sync(provider_queue(), ^{ sProvider = provider; });
}

id<DshWeatherProviding> DshWeatherCurrentProvider(void) {
  __block id<DshWeatherProviding> provider;
  dispatch_sync(provider_queue(), ^{ provider = sProvider; });
  return provider;
}

/// The sentence a failed request is reported with: WeatherKit's own text, with
/// the not-provisioned explanation in front when that is what it is.
///
/// The authentication failure has no public error case to match — it surfaces
/// from a private daemon domain (`WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors`)
/// whose description is just "The operation couldn't be completed" followed by
/// that domain. So the test is on the text of the domain and the description,
/// and it is the only category drawn here: everything else is passed through as
/// the framework worded it.
static NSString *failure_message(NSError *error) {
  NSString *text = error.localizedDescription.length > 0
      ? error.localizedDescription
      : @"the weather request failed";
  NSString *evidence = [[NSString stringWithFormat:@"%@ %@", error.domain, text] lowercaseString];
  if ([evidence containsString:@"jwt"] || [evidence containsString:@"authenticat"]) {
    return [kNotProvisionedPrefix stringByAppendingString:text];
  }
  return text;
}

/// Read the point, or set `error` to the reason there is none.
static BOOL read_coordinate(NSDictionary *args, NSString *op,
                            double *latitude, double *longitude, NSString **error) {
  NSNumber *lat = args[@"latitude"], *lon = args[@"longitude"];
  if (![lat isKindOfClass:NSNumber.class] || ![lon isKindOfClass:NSNumber.class]) {
    // Says where coordinates come from, because the natural next move for a
    // caller holding only a city name is to pass the name, and that is refused
    // here for the reason `maps` refuses it: resolving a name is picking one
    // answer out of several (§4.5).
    *error = [NSString stringWithFormat:
        @"%@ needs 'latitude' and 'longitude' as numbers. Place names are not resolved here and "
         "the user's position is never read — get the coordinates from `location` or a `maps` "
         "search first.", op];
    return NO;
  }
  // A point off the globe is refused rather than sent: WeatherKit's answer to
  // one is the same opaque failure as everything else, and "latitude 131" is
  // nearly always a swapped pair the caller can fix in one retry if told.
  if (lat.doubleValue < -90 || lat.doubleValue > 90 ||
      lon.doubleValue < -180 || lon.doubleValue > 180) {
    *error = @"'latitude' must be between -90 and 90 and 'longitude' between -180 and 180";
    return NO;
  }
  *latitude = lat.doubleValue;
  *longitude = lon.doubleValue;
  return YES;
}

/// Read an optional count, or set `error` when it is outside what can be served.
///
/// Out of range is refused, not clamped: a caller that asked for 30 days and was
/// quietly handed 10 would describe a month it never saw.
static BOOL read_count(NSDictionary *args, NSString *key, NSInteger fallback, NSInteger max,
                       NSInteger *count, NSString **error) {
  id requested = args[key];
  if (requested == nil || [requested isKindOfClass:NSNull.class]) {
    *count = fallback;
    return YES;
  }
  if (![requested isKindOfClass:NSNumber.class] ||
      [(NSNumber *)requested integerValue] < 1 || [(NSNumber *)requested integerValue] > max) {
    *error = [NSString stringWithFormat:@"'%@' must be a number from 1 to %ld", key, (long)max];
    return NO;
  }
  *count = [(NSNumber *)requested integerValue];
  return YES;
}

/// Cut the list under `key` to the first `count` entries and say that it was cut.
///
/// A size limit the caller chose, not a choice among answers: the entries are in
/// time order and the ones kept are simply the nearest (§4.5). `total` is what
/// WeatherKit sent, so the caller can see there was more to ask for.
static NSDictionary *first_entries(NSDictionary<NSString *, id> *answer, NSString *key,
                                   NSInteger count) {
  NSArray *all = [answer[key] isKindOfClass:NSArray.class] ? answer[key] : @[];
  NSArray *kept = all.count > (NSUInteger)count
      ? [all subarrayWithRange:NSMakeRange(0, (NSUInteger)count)]
      : all;
  NSMutableDictionary *result = [answer mutableCopy];
  result[key] = kept;
  result[@"total"] = @(all.count);
  result[@"truncated"] = @((BOOL)(all.count > kept.count));
  return result;
}

void dsh_native_weather(NSString *op, NSDictionary *args, DshNativeReply reply) {
  double latitude = 0, longitude = 0;
  NSInteger hours = kDefaultHours, days = kDefaultDays;
  NSString *error = nil;
  if (!read_coordinate(args, op, &latitude, &longitude, &error) ||
      ([op isEqualToString:@"hourly"] &&
       !read_count(args, @"hours", kDefaultHours, kMaxHours, &hours, &error)) ||
      ([op isEqualToString:@"daily"] &&
       !read_count(args, @"days", kDefaultDays, kMaxDays, &days, &error))) {
    reply(nil, error);
    return;
  }

  id<DshWeatherProviding> provider = DshWeatherCurrentProvider();
  if (provider == nil) {
    // Never quietly do nothing: the capability table says this build has
    // weather, so a missing provider is a wiring bug, and saying so is how it
    // gets found.
    reply(nil, kNoProviderMessage);
    return;
  }

  if ([op isEqualToString:@"current"]) {
    [provider currentWeatherAtLatitude:latitude
                             longitude:longitude
                            completion:^(NSDictionary<NSString *, id> *answer, NSError *failure) {
      if (failure != nil) { reply(nil, failure_message(failure)); return; }
      reply(answer, nil);
    }];
  } else if ([op isEqualToString:@"hourly"]) {
    [provider hourlyWeatherAtLatitude:latitude
                            longitude:longitude
                                hours:hours
                           completion:^(NSDictionary<NSString *, id> *answer, NSError *failure) {
      if (failure != nil) { reply(nil, failure_message(failure)); return; }
      reply(first_entries(answer, @"hours", hours), nil);
    }];
  } else if ([op isEqualToString:@"daily"]) {
    [provider dailyWeatherAtLatitude:latitude
                           longitude:longitude
                          completion:^(NSDictionary<NSString *, id> *answer, NSError *failure) {
      if (failure != nil) { reply(nil, failure_message(failure)); return; }
      reply(first_entries(answer, @"days", days), nil);
    }];
  } else {
    // Unreachable: the dispatcher checked `op` against the table first.
    reply(nil, [NSString stringWithFormat:@"weather has no operation '%@'", op]);
  }
}
