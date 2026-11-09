// location: where the phone is, and turning names into coordinates and back.
//
// **Only "when in use", and only one reading at a time.** There is no tracking
// here: no significant-change monitoring, no background updates, no history.
// The agent asks once, gets one fix, and the hardware goes quiet again — which
// is also why the Info.plist asks for `WhenInUse` and nothing else. A capability
// that could follow the user around would need a different conversation than
// this one, and a different permission.
//
// `geocode` and `reverse` need no permission at all: they are Apple's servers
// turning an address into a point and back. They are in this capability rather
// than in `maps` because that is where a caller looks for them, but asking
// "where is Beijing" costs the user nothing.
#import "dsh_ios_native.h"
#import "DshNativeCapabilities.h"
#import <CoreLocation/CoreLocation.h>

static NSString *const kDeniedMessage =
    @"location is turned off for this app; the user can turn it on in Settings > Privacy & Security "
     "> Location Services";
static NSString *const kNotEnabledMessage =
    @"the user has not switched location on for this app yet. Nothing was read. Tell them they can "
     "turn it on themselves under Device capabilities, which is in the app's sidebar — only they "
     "can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// One manager for the process; it owns the delegate callbacks for a fix.
///
/// CoreLocation insists on being created and used from a thread with a run
/// loop, and delivers everything through a delegate, so this class exists to
/// turn "ask for one reading" into a block that settles exactly once.
@interface DshLocationOnce : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *manager;
@property (nonatomic, copy) void (^done)(CLLocation *location, NSString *error);
@end

@implementation DshLocationOnce {
  /// A fix can arrive after an error, or twice. The caller gets one answer.
  BOOL _settled;
}

- (void)settle:(CLLocation *)location error:(NSString *)error {
  if (_settled) return;
  _settled = YES;
  void (^done)(CLLocation *, NSString *) = self.done;
  self.done = nil;
  self.manager.delegate = nil;
  self.manager = nil;
  if (done) done(location, error);
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
  [self settle:locations.lastObject error:nil];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
  [self settle:nil error:error.localizedDescription ?: @"the location could not be read"];
}
@end

/// Held while a reading is in flight, because nothing else retains it.
static DshLocationOnce *sPending;

NSLocale *DshGeocodeLocaleForQuery(NSString *query) {
  for (NSUInteger i = 0; i < query.length; i++) {
    unichar c = [query characterAtIndex:i];
    if (c >= 0x3040 && c <= 0x30FF) return [NSLocale localeWithLocaleIdentifier:@"ja"];
    if (c >= 0xAC00 && c <= 0xD7AF) return [NSLocale localeWithLocaleIdentifier:@"ko"];
    if (c >= 0x0400 && c <= 0x04FF) return [NSLocale localeWithLocaleIdentifier:@"ru"];
    if (c >= 0x2E80) return [NSLocale localeWithLocaleIdentifier:@"zh-Hans"];
  }
  return [NSLocale localeWithLocaleIdentifier:@"en_US"];
}

BOOL DshGeocodePlausible(NSString *query, NSString *resolved) {
  if (query.length == 0 || resolved.length == 0) return NO;
  NSString *q = query.lowercaseString, *r = resolved.lowercaseString;
  // Either contains the other: "the louvre" → "musée du louvre", "故宫" →
  // "故宫博物院". This covers most honest answers.
  if ([r containsString:q] || [q containsString:r]) return YES;

  // Otherwise require one shared piece. Latin words of three letters or more,
  // and for scripts without spaces, any two adjacent characters — "北京市" and
  // "北京" share "北京" even though neither contains the other whole.
  NSMutableCharacterSet *breaks = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
  [breaks formUnionWithCharacterSet:NSCharacterSet.punctuationCharacterSet];
  for (NSString *word in [q componentsSeparatedByCharactersInSet:breaks]) {
    if (word.length >= 3 && [r containsString:word]) return YES;
  }
  for (NSUInteger i = 0; i + 1 < q.length; i++) {
    NSRange pair = [q rangeOfComposedCharacterSequencesForRange:NSMakeRange(i, 2)];
    NSString *gram = [q substringWithRange:pair];
    // Only for characters that are not plain letters-with-spaces scripts; a
    // two-letter Latin fragment matches far too much.
    unichar first = [gram characterAtIndex:0];
    if (first < 0x2E80) continue;
    if ([r containsString:gram]) return YES;
  }
  return NO;
}

static void read_current(NSDictionary *args, DshNativeReply reply) {
  dsh_native_on_main(^{
    CLLocationManager *manager = [CLLocationManager new];
    switch (manager.authorizationStatus) {
      case kCLAuthorizationStatusAuthorizedAlways:
      case kCLAuthorizationStatusAuthorizedWhenInUse:
        break;
      case kCLAuthorizationStatusDenied:
      case kCLAuthorizationStatusRestricted:
        reply(nil, kDeniedMessage);
        return;
      case kCLAuthorizationStatusNotDetermined:
      default:
        // Same rule as every other capability: the dialog belongs to the
        // capability screen, not to whichever plugin called first (§5.5).
        reply(nil, kNotEnabledMessage);
        return;
    }
    if (sPending != nil) {
      reply(nil, @"a location reading is already in progress; wait for it to finish");
      return;
    }

    DshLocationOnce *once = [DshLocationOnce new];
    once.manager = manager;
    manager.delegate = once;
    // Rough by default: "which city am I in" is the common question and it does
    // not deserve the battery or the precision of a navigation-grade fix.
    manager.desiredAccuracy = [args[@"accuracy"] isEqualToString:@"precise"]
                              ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters;
    once.done = ^(CLLocation *location, NSString *error) {
      sPending = nil;
      if (location == nil) { reply(nil, error ?: @"no location was returned"); return; }
      reply(@{@"latitude": @(location.coordinate.latitude),
              @"longitude": @(location.coordinate.longitude),
              @"accuracyMeters": @(location.horizontalAccuracy),
              @"altitudeMeters": @(location.altitude),
              @"at": @(location.timestamp.timeIntervalSince1970),
              // Coordinates are not put in the audit line: it is shown to the
              // user and a list of where they were is exactly the record this
              // app should not be keeping (§5.4).
              @"auditSummary": @""}, nil);
    };
    sPending = once;
    [manager requestLocation];
  });
}

static void geocode(NSDictionary *args, DshNativeReply reply) {
  NSString *address = args[@"address"];
  if (![address isKindOfClass:NSString.class] || address.length == 0) {
    reply(nil, @"geocode needs a non-empty 'address'");
    return;
  }
  // CLGeocoder is deprecated from iOS 26 in favour of MKGeocodingRequest, but
  // this app deploys to iOS 17 and MKGeocodingRequest does not exist there. An
  // availability split would double this code for no difference in behaviour
  // today; revisit when the deployment target moves past 26.
  [[CLGeocoder new] geocodeAddressString:address
                                inRegion:nil
                         preferredLocale:DshGeocodeLocaleForQuery(address)
                       completionHandler:^(NSArray<CLPlacemark *> *places, NSError *error) {
    CLPlacemark *first = places.firstObject;
    if (first == nil) {
      reply(nil, error.localizedDescription ?: [NSString stringWithFormat:@"no place found for '%@'", address]);
      return;
    }
    NSString *resolved = [@[first.name ?: @"", first.locality ?: @"", first.administrativeArea ?: @"",
                            first.country ?: @""] componentsJoinedByString:@" "];
    if (!DshGeocodePlausible(address, resolved)) {
      reply(nil, [NSString stringWithFormat:
                  @"'%@' could not be resolved here — the nearest answer was '%@', which is not the "
                   "same place. Geocoding is answered by the provider for this device's region and "
                   "may not know places elsewhere. Give coordinates instead.", address, resolved]);
      return;
    }
    reply(@{@"latitude": @(first.location.coordinate.latitude),
            @"longitude": @(first.location.coordinate.longitude),
            @"name": first.name ?: @"",
            @"locality": first.locality ?: @"",
            @"country": first.country ?: @""}, nil);
  }];
}

static void reverse_geocode(NSDictionary *args, DshNativeReply reply) {
  NSNumber *lat = args[@"latitude"], *lon = args[@"longitude"];
  if (![lat isKindOfClass:NSNumber.class] || ![lon isKindOfClass:NSNumber.class]) {
    reply(nil, @"reverse needs 'latitude' and 'longitude'");
    return;
  }
  CLLocation *point = [[CLLocation alloc] initWithLatitude:lat.doubleValue longitude:lon.doubleValue];
  [[CLGeocoder new] reverseGeocodeLocation:point
                         completionHandler:^(NSArray<CLPlacemark *> *places, NSError *error) {
    CLPlacemark *first = places.firstObject;
    if (first == nil) {
      reply(nil, error.localizedDescription ?: @"nothing is known about that point");
      return;
    }
    reply(@{@"name": first.name ?: @"",
            @"thoroughfare": first.thoroughfare ?: @"",
            @"locality": first.locality ?: @"",
            @"administrativeArea": first.administrativeArea ?: @"",
            @"country": first.country ?: @"",
            @"postalCode": first.postalCode ?: @""}, nil);
  }];
}

void DshLocationGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  // CoreLocation reports the answer through the delegate, so the grant goes
  // through the same one-shot wrapper a reading does.
  dsh_native_on_main(^{
    CLLocationManager *manager = [CLLocationManager new];
    if (manager.authorizationStatus != kCLAuthorizationStatusNotDetermined) {
      BOOL granted = manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways
                  || manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse;
      done(granted, granted ? nil : kDeniedMessage);
      return;
    }
    static DshLocationOnce *grantHolder;
    DshLocationOnce *once = [DshLocationOnce new];
    once.manager = manager;
    manager.delegate = once;
    once.done = ^(CLLocation *location, NSString *error) { grantHolder = nil; };
    grantHolder = once;
    [manager requestWhenInUseAuthorization];
    // The dialog is modal to the user, not to us; the screen re-reads the
    // status when the app comes back to the foreground, which is how every
    // other capability on that screen refreshes too.
    done(NO, nil);
  });
}

void dsh_native_location(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"current"]) { read_current(args, reply); return; }
  if ([op isEqualToString:@"geocode"]) { geocode(args, reply); return; }
  if ([op isEqualToString:@"reverse"]) { reverse_geocode(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"location has no operation '%@'", op]);
}
