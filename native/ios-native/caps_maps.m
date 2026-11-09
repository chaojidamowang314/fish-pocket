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

/// Turn `fromQuery`/`toQuery` (or coordinates) into map items, then run `next`.
static void resolve_ends(NSDictionary *args, DshNativeReply reply,
                         void (^next)(MKMapItem *from, MKMapItem *to)) {
  __block MKMapItem *resolvedFrom = nil;
  __block MKMapItem *resolvedTo = nil;

  // Each end is either a coordinate the caller already has, or a name to look
  // up. Looking it up is one more round trip, which is why a caller that has
  // coordinates should pass them.
  void (^resolve)(NSString *, NSString *, void (^)(MKMapItem *, NSString *)) =
  ^(NSString *prefix, NSString *queryKey, void (^done)(MKMapItem *, NSString *)) {
    CLLocationCoordinate2D point = coordinate_arg(args, prefix);
    if (CLLocationCoordinate2DIsValid(point)) {
      MKPlacemark *place = [[MKPlacemark alloc] initWithCoordinate:point];
      MKMapItem *item = [[MKMapItem alloc] initWithPlacemark:place];
      // Without a name MapKit calls it "Unknown Location", which reads in the
      // result as if the lookup failed. The coordinates are what the caller
      // gave; echoing them back says plainly that they were used as given.
      item.name = [NSString stringWithFormat:@"%.5f, %.5f", point.latitude, point.longitude];
      done(item, nil);
      return;
    }
    NSString *query = args[queryKey];
    if (![query isKindOfClass:NSString.class] || query.length == 0) {
      done(nil, [NSString stringWithFormat:@"needs '%@', or '%@Latitude' and '%@Longitude'",
                 queryKey, prefix, prefix]);
      return;
    }
    // Geocoding, not local search. `MKLocalSearch` ranks businesses near the
    // device: asked to resolve "San Francisco" from a phone in Hong Kong it
    // answers "San Francisco Bakery", and the route that follows is confidently
    // wrong — far worse than an error. `CLGeocoder` resolves place names as
    // places, which is the question being asked here.
    [[CLGeocoder new] geocodeAddressString:query
                                  inRegion:nil
                           preferredLocale:DshGeocodeLocaleForQuery(query)
                         completionHandler:^(NSArray<CLPlacemark *> *places, NSError *error) {
      CLPlacemark *first = places.firstObject;
      if (first == nil) {
        done(nil, [NSString stringWithFormat:@"no place found for '%@'", query]);
        return;
      }
      // Geocoding answers *something* even when it does not know the place, and
      // two ends resolved to the same wrong town produce a one-metre route that
      // reads as a real answer. Refuse rather than route between guesses.
      NSString *resolved = [@[first.name ?: @"", first.locality ?: @"",
                              first.administrativeArea ?: @"", first.country ?: @""]
                            componentsJoinedByString:@" "];
      if (!DshGeocodePlausible(query, resolved)) {
        done(nil, [NSString stringWithFormat:
                   @"'%@' could not be resolved here — the nearest answer was '%@', which is not the "
                    "same place. Geocoding is answered by the provider for this device's region and "
                    "may not know places elsewhere. Give coordinates instead.", query, resolved]);
        return;
      }
      MKPlacemark *place = [[MKPlacemark alloc] initWithPlacemark:first];
      MKMapItem *item = [[MKMapItem alloc] initWithPlacemark:place];
      item.name = first.name ?: query;
      done(item, nil);
    }];
  };

  resolve(@"from", @"fromQuery", ^(MKMapItem *from, NSString *error) {
    if (from == nil) { reply(nil, error); return; }
    resolvedFrom = from;
    resolve(@"to", @"toQuery", ^(MKMapItem *to, NSString *error2) {
      if (to == nil) { reply(nil, error2); return; }
      resolvedTo = to;
      next(resolvedFrom, resolvedTo);
    });
  });
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
  resolve_ends(args, reply, ^(MKMapItem *from, MKMapItem *to) {
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
  });
}

static void route(NSDictionary *args, DshNativeReply reply) {
  resolve_ends(args, reply, ^(MKMapItem *from, MKMapItem *to) {
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
  });
}

void dsh_native_maps(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"search"]) { search(args, reply); return; }
  if ([op isEqualToString:@"eta"]) { eta(args, reply); return; }
  if ([op isEqualToString:@"route"]) { route(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"maps has no operation '%@'", op]);
}
