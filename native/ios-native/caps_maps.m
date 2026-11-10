// maps: find places, work out how long it takes to get somewhere, and get the
// turns in between. MapKit's search and directions need no permission at all —
// they are Apple's servers answering a query, not the user's location.
//
// **Nothing here reads where the user is.** A search takes a region the caller
// names, and directions take two places the caller names. "Near me" is a
// `location` question first and a `maps` question second, and keeping them
// apart means the common cases — "how far is Shanghai from Beijing", "find a
// pharmacy in Chaoyang" — cost no privacy at all.
#import "dsh_ios_native.h"
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

static const NSUInteger kMaxResults = 15;

static NSDictionary *place_json(MKMapItem *item) {
  MKPlacemark *place = item.placemark;
  NSMutableDictionary *entry = [@{
    @"name": item.name ?: place.name ?: @"",
    @"latitude": @(place.coordinate.latitude),
    @"longitude": @(place.coordinate.longitude),
  } mutableCopy];
  // The one-line postal address, assembled by the system in its own format —
  // the orders differ by country and we are not going to get that right by hand.
  NSString *address = place.title;
  if (address.length > 0) entry[@"address"] = address;
  if (item.phoneNumber.length > 0) entry[@"phone"] = item.phoneNumber;
  if (item.url != nil) entry[@"url"] = item.url.absoluteString;
  // A `maps:` link the agent can hand to the user, or pass to `open_url`.
  entry[@"mapsUrl"] = [NSString stringWithFormat:@"maps://?ll=%f,%f&q=%@",
                       place.coordinate.latitude, place.coordinate.longitude,
                       [(item.name ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:
                        NSCharacterSet.URLQueryAllowedCharacterSet] ?: @""];
  return entry;
}

/// A coordinate pair the caller gave, or `kCLLocationCoordinate2DInvalid`.
static CLLocationCoordinate2D coordinate_arg(NSDictionary *args, NSString *prefix) {
  NSNumber *lat = args[[prefix stringByAppendingString:@"Latitude"]];
  NSNumber *lon = args[[prefix stringByAppendingString:@"Longitude"]];
  if (![lat isKindOfClass:NSNumber.class] || ![lon isKindOfClass:NSNumber.class]) {
    return kCLLocationCoordinate2DInvalid;
  }
  return CLLocationCoordinate2DMake(lat.doubleValue, lon.doubleValue);
}

static void search(NSDictionary *args, DshNativeReply reply) {
  NSString *query = args[@"query"];
  if (![query isKindOfClass:NSString.class] || query.length == 0) {
    reply(nil, @"search needs a non-empty 'query'");
    return;
  }
  MKLocalSearchRequest *request = [MKLocalSearchRequest new];
  request.naturalLanguageQuery = query;
  CLLocationCoordinate2D near = coordinate_arg(args, @"near");
  if (CLLocationCoordinate2DIsValid(near)) {
    NSNumber *radius = args[@"radiusMeters"];
    CLLocationDistance span = [radius isKindOfClass:NSNumber.class] ? radius.doubleValue : 10000;
    request.region = MKCoordinateRegionMakeWithDistance(near, span, span);
  }

  MKLocalSearch *localSearch = [[MKLocalSearch alloc] initWithRequest:request];
  [localSearch startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
    if (error != nil) {
      reply(nil, error.localizedDescription ?: @"the search failed");
      return;
    }
    NSMutableArray *places = [NSMutableArray array];
    for (MKMapItem *item in response.mapItems) {
      if (places.count >= kMaxResults) break;
      [places addObject:place_json(item)];
    }
    reply(@{@"places": places,
            @"total": @(response.mapItems.count),
            @"truncated": @((BOOL)(response.mapItems.count > places.count))}, nil);
  }];
}

/// Both ends, as coordinates, or nil with the reason.
///
/// **Names are not accepted here, on purpose.** Resolving a name means picking
/// one answer out of several, and a geocoder answers *something* even when it
/// does not know the place: measured on a device in the China region, "San
/// Francisco" resolved to a township in Yunnan, and with both ends resolved the
/// same way the route came back as one metre and one second — an answer that
/// looks real. We tried refusing when the resolution looked implausible, and
/// that worked, but it was a string-similarity guess of our own that already
/// needed one patch (a Chinese query against an English answer shares no
/// letters) and would need more for abbreviations and transliterations.
///
/// So the choice goes back to the caller, who is a language model and is far
/// better placed to notice that Yunnan is not San Francisco: run `maps search`
/// or `location geocode` first, look at the candidates, then ask for a route
/// between two points. One more call, and nothing is decided on their behalf.
static BOOL ends_from_args(NSDictionary *args, MKMapItem **from, MKMapItem **to, NSString **error) {
  CLLocationCoordinate2D start = coordinate_arg(args, @"from");
  CLLocationCoordinate2D finish = coordinate_arg(args, @"to");
  if (!CLLocationCoordinate2DIsValid(start) || !CLLocationCoordinate2DIsValid(finish)) {
    *error = @"this operation needs 'fromLatitude'/'fromLongitude' and 'toLatitude'/'toLongitude'. "
              "Place names are not resolved here — run `search` or `location geocode` first and pick "
              "the right one, so a wrong match cannot hide inside a route.";
    return NO;
  }
  // The name echoes the coordinates the caller gave. Without one MapKit calls it
  // "Unknown Location", which reads in the result as if the lookup failed.
  MKMapItem *(^item)(CLLocationCoordinate2D) = ^(CLLocationCoordinate2D point) {
    MKMapItem *made = [[MKMapItem alloc] initWithPlacemark:
                       [[MKPlacemark alloc] initWithCoordinate:point]];
    made.name = [NSString stringWithFormat:@"%.5f, %.5f", point.latitude, point.longitude];
    return made;
  };
  *from = item(start);
  *to = item(finish);
  return YES;
}

static MKDirectionsTransportType transport_type(NSDictionary *args) {
  NSString *mode = args[@"mode"];
  if ([mode isEqualToString:@"walking"]) return MKDirectionsTransportTypeWalking;
  if ([mode isEqualToString:@"transit"]) return MKDirectionsTransportTypeTransit;
  return MKDirectionsTransportTypeAutomobile;
}

static MKDirectionsRequest *directions_request(MKMapItem *from, MKMapItem *to, NSDictionary *args) {
  MKDirectionsRequest *request = [MKDirectionsRequest new];
  request.source = from;
  request.destination = to;
  request.transportType = transport_type(args);
  return request;
}

static void eta(NSDictionary *args, DshNativeReply reply) {
  MKMapItem *from = nil, *to = nil;
  NSString *error = nil;
  if (!ends_from_args(args, &from, &to, &error)) { reply(nil, error); return; }
  {
    MKDirections *directions =
      [[MKDirections alloc] initWithRequest:directions_request(from, to, args)];
    [directions calculateETAWithCompletionHandler:^(MKETAResponse *response, NSError *error) {
      if (error != nil) {
        reply(nil, error.localizedDescription ?: @"no route could be worked out");
        return;
      }
      reply(@{@"from": from.name ?: @"",
              @"to": to.name ?: @"",
              @"seconds": @(response.expectedTravelTime),
              @"meters": @(response.distance),
              @"mode": args[@"mode"] ?: @"driving"}, nil);
    }];
  }
}

static void route(NSDictionary *args, DshNativeReply reply) {
  MKMapItem *from = nil, *to = nil;
  NSString *argError = nil;
  if (!ends_from_args(args, &from, &to, &argError)) { reply(nil, argError); return; }
  {
    MKDirections *directions =
      [[MKDirections alloc] initWithRequest:directions_request(from, to, args)];
    [directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
      if (error != nil) {
        reply(nil, error.localizedDescription ?: @"no route could be worked out");
        return;
      }
      MKRoute *best = response.routes.firstObject;
      if (best == nil) {
        reply(nil, @"no route between those two places for that mode of travel");
        return;
      }
      NSMutableArray *steps = [NSMutableArray array];
      for (MKRouteStep *step in best.steps) {
        // MapKit emits a first step with no instruction ("start here"); a line
        // of guidance with nothing in it is noise in a read-aloud route.
        if (step.instructions.length == 0) continue;
        [steps addObject:@{@"instruction": step.instructions, @"meters": @(step.distance)}];
      }
      reply(@{@"from": from.name ?: @"",
              @"to": to.name ?: @"",
              @"seconds": @(best.expectedTravelTime),
              @"meters": @(best.distance),
              @"mode": args[@"mode"] ?: @"driving",
              @"name": best.name ?: @"",
              @"steps": steps}, nil);
    }];
  }
}

void dsh_native_maps(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"search"]) { search(args, reply); return; }
  if ([op isEqualToString:@"eta"]) { eta(args, reply); return; }
  if ([op isEqualToString:@"route"]) { route(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"maps has no operation '%@'", op]);
}
