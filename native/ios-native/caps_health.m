// health: read what Apple Health holds — steps, sleep, heart rate, body
// measurements.
//
// **Read only, and that is a decision rather than a phase.** The entitlement
// asks for sharing in and nothing else, `toShare` below is always nil, and
// there is no write operation to add later without a conversation: "do not
// write false data" is a hard platform rule, and an agent acting on a
// sentence it half understood is exactly the way false data gets written
// (docs/native-services.md §3, §6.1).
//
// **iOS will not say whether a read was allowed.** There is no authorisation
// status for a read type — `authorizationStatusForType:` answers only for types
// an app may write. Apple does this on purpose: being told "denied" for
// pregnancy or blood glucose is itself a disclosure about the user. So an empty
// answer here has two causes that cannot be told apart — the user said no, or
// there is genuinely nothing recorded — and nothing in this file pretends
// otherwise. `emptyMeans` in the reply says so in words the agent can relay,
// because the one wrong move is to turn "I cannot tell" into "you have no data"
// or into "access is off".
//
// The one thing iOS does answer is whether the user has ever been SHOWN the
// sheet for a type (`getRequestStatusForAuthorizationToShareTypes:readTypes:`),
// which is enough for the rule every other capability follows: a call never
// raises the sheet, it refuses with a sentence instead, and the sheet belongs to
// the user walking into the capability screen (§5.5) — that is
// `DshHealthGrantAccess`.
//
// **Why `aggregate` is not optional.** A day of step data is hundreds of
// samples a few minutes long each, so "how far did I walk last week" cannot be
// answered out of raw samples inside one reply at all. HealthKit aggregates for
// us (HKStatisticsCollectionQuery); summing those fragments here instead would
// be us computing on the user's data rather than forwarding it (§4.5 ②).
#import "dsh_ios_native.h"
#import <HealthKit/HealthKit.h>

/// Raw samples are fragments, not readings: a quiet morning of walking is
/// hundreds of them. The cap keeps one reply crossing into JS at a sane size;
/// the caller overrides it with `limit` and learns from `total` / `truncated`
/// what it did not see (§4.5, "条数上限不算第三类").
static const NSUInteger kDefaultSampleLimit = 100;
static const NSUInteger kMaxSampleLimit = 500;
/// Hourly buckets over a month is 720 rows of JSON. Same contract as the sample
/// cap: clamp, and say what was cut.
static const NSUInteger kMaxBuckets = 200;
/// A week back from now, when the caller gives no window. Long enough for "how
/// did I sleep this week", short enough that a careless call is cheap.
static const NSTimeInterval kDefaultWindow = 7 * 24 * 60 * 60;

static NSString *const kUnavailableMessage =
    @"this device has no Health database, so there is nothing to read here";

/// The not-asked-yet refusal; see the matching one in eventkit_shared.m for why
/// it describes where the switch is instead of quoting the screen's localised
/// title.
static NSString *const kNotEnabledMessage =
    @"the user has not switched health on for this app yet. Nothing was read. Tell them they can "
     "turn it on themselves under Device capabilities, which is in the app's sidebar — only they "
     "can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// What an empty answer means, said out loud, because the agent cannot work it
/// out and must not guess. Written for the model to relay in the user's own
/// language, like every other message in these files.
static NSString *const kEmptyMeansMessage =
    @"HealthKit returns nothing both when the user has not allowed this type and when there is "
     "genuinely nothing recorded in that range; iOS does not distinguish the two, by design, and "
     "no API here can. Do not tell the user they have no data, and do not tell them access is off "
     "— say it could be either, and that they can check it under Device capabilities, which is in "
     "the app's sidebar.";

#pragma mark - The types this app declares

/// One health type this app reads.
///
/// The table is explicit because HealthKit requires a fixed set at
/// authorisation time: a type that is not here is a type the user was never
/// asked about, so reading it could only ever come back empty. It is also the
/// list the user is shown in Apple's own sheet, which is the only place they are
/// told what this app looks at — so it is a list to keep short and legible, not
/// one to pad with everything HealthKit can store.
typedef struct {
  /// The name a caller uses. HealthKit's own identifier with its prefix
  /// dropped, so the two are the same name twice rather than a mapping.
  const char *id;
  /// HealthKit's identifier in full, kept beside the short one rather than
  /// derived from it: a transformation would be ours to get right, and this way
  /// the row says exactly which Apple type it is.
  const char *identifier;
  bool category;
  /// The unit a value comes back in when the caller names none. A required
  /// argument of `doubleValueForUnit:` with a sensible default (§4.5 ①), handed
  /// to `HKUnit` verbatim so `unit` on the way in and on the way out are the
  /// same vocabulary. NULL for a category type, whose value is an enum rather
  /// than a measure.
  ///
  /// Not always the canonical unit HealthKit documents. Apple stores a day's
  /// walking in metres, a heart rate in count/s and a height in metres; a
  /// person says kilometres, beats per minute and centimetres. The default is
  /// the human one, HealthKit converts between units of the same dimension
  /// itself, and `unit` overrides it — so this costs nothing and nobody has to
  /// divide by sixty in their head.
  const char *unit;
  /// One line, so the agent can pick a type without a round trip. Says what
  /// HealthKit stores, not what it means for the user.
  const char *about;
} dsh_health_type;

static const dsh_health_type HEALTH_TYPES[] = {
  // Activity.
  {"stepCount", "HKQuantityTypeIdentifierStepCount", false, "count",
   "steps taken, recorded as fragments of a few minutes each; ask aggregate for a daily total"},
  {"distanceWalkingRunning", "HKQuantityTypeIdentifierDistanceWalkingRunning", false, "km",
   "distance covered on foot, in the same fragments as the step count"},
  {"flightsClimbed", "HKQuantityTypeIdentifierFlightsClimbed", false, "count",
   "flights of stairs climbed"},
  {"activeEnergyBurned", "HKQuantityTypeIdentifierActiveEnergyBurned", false, "kcal",
   "energy burned by moving, over and above resting"},
  {"basalEnergyBurned", "HKQuantityTypeIdentifierBasalEnergyBurned", false, "kcal",
   "resting energy burned, which the watch estimates rather than measures"},
  {"appleExerciseTime", "HKQuantityTypeIdentifierAppleExerciseTime", false, "min",
   "minutes Apple Watch counted as exercise"},
  {"appleStandTime", "HKQuantityTypeIdentifierAppleStandTime", false, "min",
   "minutes spent standing, as Apple Watch counts them"},
  {"walkingSpeed", "HKQuantityTypeIdentifierWalkingSpeed", false, "km/hr",
   "walking speed, measured in short stretches"},
  // `ml/(kg*min)` is spelled the way HKTypeIdentifiers.h spells it, parentheses
  // included: HKUnit parses its own documented form, and guessing at the
  // precedence of a bare `ml/kg*min` would be guessing at a dimension.
  {"vo2Max", "HKQuantityTypeIdentifierVO2Max", false, "ml/(kg*min)",
   "VO2 max, estimated from workouts rather than measured"},
  // Heart and breathing.
  {"heartRate", "HKQuantityTypeIdentifierHeartRate", false, "count/min",
   "heart rate readings; a watch records many every day, so aggregate before reading a long range"},
  {"restingHeartRate", "HKQuantityTypeIdentifierRestingHeartRate", false, "count/min",
   "resting heart rate, about one value per day"},
  {"walkingHeartRateAverage", "HKQuantityTypeIdentifierWalkingHeartRateAverage", false, "count/min",
   "average heart rate while walking, about one value per day"},
  {"heartRateVariabilitySDNN", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", false, "ms",
   "heart rate variability as SDNN, usually measured while still"},
  {"respiratoryRate", "HKQuantityTypeIdentifierRespiratoryRate", false, "count/min",
   "breaths per minute, usually measured during sleep"},
  {"oxygenSaturation", "HKQuantityTypeIdentifierOxygenSaturation", false, "%",
   "blood oxygen as a FRACTION in HealthKit's percent unit: 0.97 means 97%"},
  // Body measurements.
  {"bodyMass", "HKQuantityTypeIdentifierBodyMass", false, "kg", "body weight, as logged or weighed"},
  {"bodyFatPercentage", "HKQuantityTypeIdentifierBodyFatPercentage", false, "%",
   "body fat as a FRACTION in HealthKit's percent unit: 0.21 means 21%"},
  {"bodyMassIndex", "HKQuantityTypeIdentifierBodyMassIndex", false, "count",
   "body mass index, a plain number with no unit of its own"},
  {"height", "HKQuantityTypeIdentifierHeight", false, "cm", "height, as entered"},
  {"bodyTemperature", "HKQuantityTypeIdentifierBodyTemperature", false, "degC",
   "body temperature readings"},
  {"bloodPressureSystolic", "HKQuantityTypeIdentifierBloodPressureSystolic", false, "mmHg",
   "the systolic half of a blood pressure reading; HealthKit stores the two halves as separate types"},
  {"bloodPressureDiastolic", "HKQuantityTypeIdentifierBloodPressureDiastolic", false, "mmHg",
   "the diastolic half of a blood pressure reading; read it alongside the systolic type"},
  // Food and water.
  {"dietaryWater", "HKQuantityTypeIdentifierDietaryWater", false, "mL", "water drunk, as logged"},
  {"dietaryEnergyConsumed", "HKQuantityTypeIdentifierDietaryEnergyConsumed", false, "kcal",
   "energy eaten, as logged"},
  // Environment.
  {"headphoneAudioExposure", "HKQuantityTypeIdentifierHeadphoneAudioExposure", false, "dBASPL",
   "how loud headphones have been, as a sound pressure level"},
  // Category types: a value from one of Apple's enums, not a measurement.
  {"sleepAnalysis", "HKCategoryTypeIdentifierSleepAnalysis", true, NULL,
   "sleep, one sample per stretch in a stage; `value` is Apple's stage number and `valueName` its name"},
  {"mindfulSession", "HKCategoryTypeIdentifierMindfulSession", true, NULL,
   "mindfulness sessions; the value carries nothing, the length of the sample is the session"},
};
static const size_t HEALTH_TYPE_COUNT = sizeof(HEALTH_TYPES) / sizeof(HEALTH_TYPES[0]);

#pragma mark - Store, types, units

/// The one HealthKit store for the process.
///
/// HealthKit hands query results back on its own queues and keys an app's
/// authorisation to the store, so one store is both cheaper and the only way a
/// grant and a later read agree about what was asked. Creating it on a device
/// without a Health database is allowed — its queries simply fail — so
/// availability is checked separately, where the refusal can name which of the
/// two problems it is.
static HKHealthStore *health_store(void) {
  static HKHealthStore *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [HKHealthStore new]; });
  return shared;
}

/// ISO 8601 with the device's own UTC offset, so neither the model nor the user
/// has to guess which timezone a sleep stage or a reading is in. Kept here
/// rather than reusing the EventKit helper of the same shape: this file links no
/// EventKit, and a HealthKit capability reaching into that header for a date
/// formatter would be the wrong dependency to leave for the next person.
static NSString *iso8601(NSDate *date) {
  static NSISO8601DateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    formatter.timeZone = NSTimeZone.localTimeZone;
  });
  return date == nil ? @"" : [formatter stringFromDate:date];
}

/// Just the date, for an audit line. Guarded on length because `from` and `to`
/// are numbers a caller chose: a time no formatter can render comes back as a
/// short string, and taking ten characters off it would raise.
static NSString *iso_day(NSDate *date) {
  NSString *stamp = iso8601(date);
  return stamp.length >= 10 ? [stamp substringToIndex:10] : stamp;
}

/// Look up a row by either name a caller might hold: the short id, or
/// HealthKit's identifier in full for a caller reading Apple's documentation.
/// Nothing outside the table resolves — a type the sheet never listed is a type
/// the user never saw, and reading it would come back empty for a reason we
/// could not explain.
static const dsh_health_type *find_type(id requested, NSString **error) {
  if (![requested isKindOfClass:NSString.class] || [requested length] == 0) {
    *error = @"this operation needs a 'type'; call `types` for the ones this app can read";
    return NULL;
  }
  NSString *name = requested;
  for (size_t i = 0; i < HEALTH_TYPE_COUNT; i++) {
    if ([name caseInsensitiveCompare:@(HEALTH_TYPES[i].id)] == NSOrderedSame
        || [name caseInsensitiveCompare:@(HEALTH_TYPES[i].identifier)] == NSOrderedSame) {
      return &HEALTH_TYPES[i];
    }
  }
  *error = [NSString stringWithFormat:
            @"'%@' is not a type this app declared, so the user was never asked about it and it "
             "cannot be read. Call `types` for the list.", name];
  return NULL;
}

static HKSampleType *sample_type(const dsh_health_type *row) {
  NSString *identifier = @(row->identifier);
  return row->category ? (HKSampleType *)[HKCategoryType categoryTypeForIdentifier:identifier]
                       : (HKSampleType *)[HKQuantityType quantityTypeForIdentifier:identifier];
}

/// Every type this app ever reads, in one set, as the sheet needs it.
static NSSet<HKObjectType *> *all_read_types(void) {
  NSMutableSet<HKObjectType *> *types = [NSMutableSet setWithCapacity:HEALTH_TYPE_COUNT];
  for (size_t i = 0; i < HEALTH_TYPE_COUNT; i++) {
    HKSampleType *type = sample_type(&HEALTH_TYPES[i]);
    // A type this iOS version does not know comes back nil rather than
    // throwing. Skipping it keeps the other twenty-six askable; the type itself
    // then refuses at use time, naming the version, instead of taking the whole
    // grant down with it.
    if (type != nil) [types addObject:type];
  }
  return types;
}

/// Resolve the unit for a read: the caller's `unit` if it passed one, otherwise
/// the row's default.
///
/// `unitFromString:` RAISES on a string it cannot parse — an NSException, which
/// would take the app down rather than fail a call — so it is caught here and
/// turned into a sentence. The same guard covers the row's own default: if one
/// of the strings in the table above is wrong, the capability says which, rather
/// than crashing the app that ships it.
static HKUnit *unit_for(const dsh_health_type *row, NSDictionary *args, NSString **error) {
  id requested = args[@"unit"];
  BOOL fromCaller = [requested isKindOfClass:NSString.class] && [requested length] > 0;
  if (!fromCaller && row->unit == NULL) {
    *error = [NSString stringWithFormat:@"'%@' is a category type: its samples carry an enum value, "
                                         "not a measurement, so there is no unit", @(row->id)];
    return nil;
  }
  NSString *string = fromCaller ? requested : @(row->unit);
  HKUnit *unit = nil;
  @try {
    unit = [HKUnit unitFromString:string];
  } @catch (NSException *exception) {
    unit = nil;
  }
  if (unit == nil) {
    *error = fromCaller
      ? [NSString stringWithFormat:@"HealthKit cannot read '%@' as a unit. It wants forms like "
                                    "'count', 'kg', 'km', 'kcal', 'count/min', '%%' or 'degC'.", string]
      : [NSString stringWithFormat:@"this build's default unit for '%@' ('%@') is not one HealthKit "
                                    "accepts; pass 'unit' to work around it", @(row->id), string];
    return nil;
  }
  return unit;
}

/// Apple's own names for the `HKCategoryValueSleepAnalysis` enum.
///
/// A table lookup, not a reading of the data: the bare integer is unusable to a
/// caller, the names are Apple's rather than ours, and `value` is reported
/// beside the name so nothing here is the caller's only view of the number.
static NSString *sleep_value_name(NSInteger value) {
  switch (value) {
    case HKCategoryValueSleepAnalysisInBed: return @"inBed";
    case HKCategoryValueSleepAnalysisAsleepUnspecified: return @"asleepUnspecified";
    case HKCategoryValueSleepAnalysisAwake: return @"awake";
    case HKCategoryValueSleepAnalysisAsleepCore: return @"asleepCore";
    case HKCategoryValueSleepAnalysisAsleepDeep: return @"asleepDeep";
    case HKCategoryValueSleepAnalysisAsleepREM: return @"asleepREM";
    default: return nil;
  }
}

#pragma mark - Arguments

/// Read an optional epoch-seconds argument, falling back to `fallback`.
static NSDate *date_arg(NSDictionary *args, NSString *key, NSDate *fallback, NSString **error) {
  id value = args[key];
  if (value == nil) return fallback;
  if (![value isKindOfClass:NSNumber.class]) {
    *error = [NSString stringWithFormat:@"'%@' must be seconds since 1970", key];
    return nil;
  }
  return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
}

/// The window a read or an aggregate covers. Both ends are optional: `to`
/// defaults to now and `from` to a week before it, which is the range almost
/// every question about health actually means.
static BOOL window_args(NSDictionary *args, NSDate **from, NSDate **to, NSString **error) {
  NSDate *now = [NSDate date];
  *to = date_arg(args, @"to", now, error);
  if (*error != nil) return NO;
  *from = date_arg(args, @"from", [*to dateByAddingTimeInterval:-kDefaultWindow], error);
  if (*error != nil) return NO;
  if ([*to timeIntervalSinceDate:*from] <= 0) {
    *error = @"'to' must be after 'from'";
    return NO;
  }
  return YES;
}

#pragma mark - Authorisation

/// Refuse unless the user has already been through Apple's sheet for `type`.
///
/// This is **not** a check that reading was allowed — iOS will not say, and the
/// top of this file explains why. It answers only "has the user ever been asked
/// about this type", which is what §5.5 needs: a plugin's first call must not be
/// what puts the sheet on screen, and a read taken before the user has visited
/// the capability screen comes back empty for a reason the agent could not name.
///
/// Asked per type rather than for the whole set on purpose. Asking about the set
/// would answer `ShouldRequest` as soon as a later version adds a type nobody
/// has seen yet, and would then refuse to read the steps the user allowed
/// months ago.
static void require_asked(HKSampleType *type, void (^next)(BOOL ok, NSString *error)) {
  if (!HKHealthStore.isHealthDataAvailable) {
    next(NO, kUnavailableMessage);
    return;
  }
  if (type == nil) {
    next(NO, @"this version of iOS does not know that health type, so it cannot be read here");
    return;
  }
  [health_store() getRequestStatusForAuthorizationToShareTypes:[NSSet set]
                                                     readTypes:[NSSet setWithObject:type]
                                                    completion:^(HKAuthorizationRequestStatus status,
                                                                 NSError *error) {
    if (error != nil) {
      next(NO, error.localizedDescription ?: @"HealthKit would not say whether this app may ask");
      return;
    }
    if (status == HKAuthorizationRequestStatusShouldRequest) {
      next(NO, kNotEnabledMessage);
      return;
    }
    // `Unnecessary` means asked, NOT allowed: the user may well have said no to
    // this type on the sheet and iOS reports the same status either way. That is
    // why `emptyMeans` exists rather than a status check here.
    //
    // `Unknown` arrives without an error when HealthKit simply has no answer;
    // reading anyway is more honest than inventing a refusal, and an empty
    // result already says what it says.
    next(YES, nil);
  }];
}

#pragma mark - Operations

/// The types this app declares, so an agent can choose one without guessing at
/// HealthKit's identifier vocabulary. Touches no health data at all — it is this
/// file's own table — so it needs no authorisation and leaves no audit line.
static void list_types(DshNativeReply reply) {
  NSMutableArray *rows = [NSMutableArray arrayWithCapacity:HEALTH_TYPE_COUNT];
  for (size_t i = 0; i < HEALTH_TYPE_COUNT; i++) {
    const dsh_health_type *row = &HEALTH_TYPES[i];
    NSMutableDictionary *entry = [@{
      @"id": @(row->id),
      @"healthKitIdentifier": @(row->identifier),
      @"kind": row->category ? @"category" : @"quantity",
      @"about": @(row->about),
    } mutableCopy];
    entry[@"unit"] = row->unit == NULL ? (id)NSNull.null : @(row->unit);
    if (!row->category) {
      // Which statistic `aggregate` will produce, taken from HealthKit's own
      // classification of the type rather than from a list of our own: a
      // cumulative type sums, anything else averages, and the caller should not
      // have to call to find out which.
      HKQuantityType *quantity = [HKQuantityType quantityTypeForIdentifier:@(row->identifier)];
      if (quantity != nil) {
        entry[@"aggregatesAs"] =
          quantity.aggregationStyle == HKQuantityAggregationStyleCumulative ? @"sum" : @"average";
      }
    }
    [rows addObject:entry];
  }
  reply(@{@"types": rows, @"total": @(HEALTH_TYPE_COUNT)}, nil);
}

/// Raw samples, newest first.
///
/// Newest first because the commonest single question is "what is my weight" or
/// "what was last night", and `limit: 1` should answer it. It also means a
/// truncated reply holds the recent end of the window, which is the half a
/// caller asking about health usually wants.
static void read_samples(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  const dsh_health_type *row = find_type(args[@"type"], &error);
  if (row == NULL) { reply(nil, error); return; }

  NSDate *from = nil, *to = nil;
  if (!window_args(args, &from, &to, &error)) { reply(nil, error); return; }

  HKUnit *unit = nil;
  if (!row->category) {
    unit = unit_for(row, args, &error);
    if (unit == nil) { reply(nil, error); return; }
  } else if (args[@"unit"] != nil) {
    reply(nil, [NSString stringWithFormat:@"'%@' is a category type: its samples carry an enum "
                                           "value, not a measurement, so 'unit' means nothing here",
                                          @(row->id)]);
    return;
  }

  NSUInteger wanted = kDefaultSampleLimit;
  id limit = args[@"limit"];
  if (limit != nil) {
    if (![limit isKindOfClass:NSNumber.class] || [limit integerValue] < 1) {
      reply(nil, @"'limit' must be a positive number of samples");
      return;
    }
    wanted = MIN((NSUInteger)[limit integerValue], kMaxSampleLimit);
  }

  HKSampleType *type = sample_type(row);
  require_asked(type, ^(BOOL ok, NSString *accessError) {
    if (!ok) { reply(nil, accessError); return; }

    // `HKQueryOptionNone` is HealthKit's own default and takes anything that
    // OVERLAPS the window. It matters for sleep: a night that starts before
    // midnight belongs to a question about last night, and a strict-start query
    // would drop it.
    NSPredicate *predicate = [HKQuery predicateForSamplesWithStartDate:from endDate:to
                                                               options:HKQueryOptionNone];
    NSSortDescriptor *newestFirst = [[NSSortDescriptor alloc] initWithKey:HKSampleSortIdentifierStartDate
                                                               ascending:NO];
    // One more than we will return, so `truncated` is a fact rather than a
    // guess — and so a year of step fragments is never pulled into memory to
    // produce a count nobody asked for. The price is that `total` is only known
    // when nothing was cut; see the reply below.
    HKSampleQuery *query =
      [[HKSampleQuery alloc] initWithSampleType:type
                                      predicate:predicate
                                          limit:wanted + 1
                                sortDescriptors:@[newestFirst]
                                 resultsHandler:^(HKSampleQuery *finished,
                                                  NSArray<__kindof HKSample *> *found,
                                                  NSError *queryError) {
      if (found == nil) {
        reply(nil, queryError.localizedDescription ?: @"the health samples could not be read");
        return;
      }
      BOOL more = found.count > wanted;
      NSUInteger count = MIN(found.count, wanted);
      NSMutableArray *samples = [NSMutableArray arrayWithCapacity:count];
      for (NSUInteger i = 0; i < count; i++) {
        HKSample *sample = found[i];
        NSMutableDictionary *entry = [@{
          @"start": iso8601(sample.startDate),
          @"end": iso8601(sample.endDate),
        } mutableCopy];
        // Which app or device wrote it. A step count from the phone and one from
        // a watch are different facts, and the caller cannot tell them apart
        // from the number.
        NSString *source = sample.sourceRevision.source.name;
        if (source.length > 0) entry[@"source"] = source;
        if (row->category) {
          HKCategorySample *category = (HKCategorySample *)sample;
          entry[@"value"] = @(category.value);
          NSString *name = [@(row->identifier) isEqualToString:HKCategoryTypeIdentifierSleepAnalysis]
                           ? sleep_value_name(category.value) : nil;
          if (name != nil) entry[@"valueName"] = name;
        } else {
          HKQuantity *quantity = ((HKQuantitySample *)sample).quantity;
          if (![quantity isCompatibleWithUnit:unit]) {
            // Checked rather than attempted: `doubleValueForUnit:` raises on a
            // unit of the wrong dimension, and an exception is not a way to fail
            // a call.
            reply(nil, [NSString stringWithFormat:
                        @"'%@' cannot be read in '%@' — wrong kind of unit for what this type "
                         "measures. Call `types` for the unit it uses by default.",
                        @(row->id), unit.unitString]);
            return;
          }
          entry[@"value"] = @([quantity doubleValueForUnit:unit]);
        }
        [samples addObject:entry];
      }

      NSMutableDictionary *result = [@{
        @"type": @(row->id),
        @"from": iso8601(from),
        @"to": iso8601(to),
        @"samples": samples,
        @"returned": @(samples.count),
        @"limit": @(wanted),
        @"truncated": @(more),
        // Known only when nothing was cut, because counting past the limit is
        // the expensive query this one avoids. A number we did not count would
        // read exactly like one we did, so this says null instead.
        @"total": more ? (id)NSNull.null : @(samples.count),
        // Stated for every read, not only the truncated ones: the order is what
        // makes `limit` mean "the most recent few".
        @"order": @"newest first",
      } mutableCopy];
      if (unit != nil) result[@"unit"] = unit.unitString;
      if (samples.count == 0) result[@"emptyMeans"] = kEmptyMeansMessage;
      // Type and count, never a value: the audit list is the user's record of
      // what touched their data, and copying their heart rate into a second
      // place is the thing it exists to discourage (§5.4). Language-neutral,
      // because the app shows it verbatim in three languages and this file is in
      // none of them.
      result[@"auditSummary"] = [NSString stringWithFormat:@"%@ · %@ → %@ · %lu",
                                 @(row->id), iso_day(from), iso_day(to),
                                 (unsigned long)samples.count];
      reply(result, nil);
    }];
    [health_store() executeQuery:query];
  });
}

/// Per-bucket statistics, which is the only way most of this data answers a
/// question a person would ask.
///
/// The statistic is HealthKit's choice, not ours: a cumulative type sums, a
/// discrete one averages (and carries its min and max along, from the same
/// query). Offering the caller the other option would be offering a crash —
/// HealthKit raises on a sum over a discrete type — so the type decides, and
/// `stat` in the reply says which it was.
static void aggregate(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  const dsh_health_type *row = find_type(args[@"type"], &error);
  if (row == NULL) { reply(nil, error); return; }
  if (row->category) {
    reply(nil, [NSString stringWithFormat:
                @"'%@' is a category type: HealthKit has no statistics for enum values, so there is "
                 "nothing to total or average. Use `read` and count the samples you care about.",
                @(row->id)]);
    return;
  }

  NSDate *from = nil, *to = nil;
  if (!window_args(args, &from, &to, &error)) { reply(nil, error); return; }

  HKUnit *unit = unit_for(row, args, &error);
  if (unit == nil) { reply(nil, error); return; }

  // Buckets are anchored to real calendar boundaries in the device's own
  // calendar — local midnight, the locale's first day of the week, the first of
  // the month — because that is what a person means by "per day". Anchoring to
  // the raw `from` instead would put the day boundary at whatever o'clock the
  // caller happened to pass.
  id requestedInterval = args[@"interval"];
  if (requestedInterval != nil && ![requestedInterval isKindOfClass:NSString.class]) {
    reply(nil, @"'interval' must be the string 'hour', 'day', 'week' or 'month'");
    return;
  }
  NSString *interval = requestedInterval ?: @"day";
  NSCalendarUnit granularity;
  NSDateComponents *step = [NSDateComponents new];
  // Roughly how long a bucket lasts, only ever used to count them before asking
  // for them. The month figure being approximate is fine: it decides whether a
  // window is near the cap, not where a boundary falls.
  NSTimeInterval bucketSeconds;
  if ([interval isEqualToString:@"hour"]) {
    granularity = NSCalendarUnitHour;
    step.hour = 1;
    bucketSeconds = 60 * 60;
  } else if ([interval isEqualToString:@"day"]) {
    granularity = NSCalendarUnitDay;
    step.day = 1;
    bucketSeconds = 24 * 60 * 60;
  } else if ([interval isEqualToString:@"week"]) {
    granularity = NSCalendarUnitWeekOfYear;
    step.weekOfYear = 1;
    bucketSeconds = 7 * 24 * 60 * 60;
  } else if ([interval isEqualToString:@"month"]) {
    granularity = NSCalendarUnitMonth;
    step.month = 1;
    bucketSeconds = 28 * 24 * 60 * 60;
  } else {
    reply(nil, @"'interval' must be 'hour', 'day', 'week' or 'month'");
    return;
  }

  // Refused up front rather than cut short, and that is the opposite of how
  // `read` handles its cap on purpose. The first hundred of a thousand samples
  // is a smaller answer to the same question; the first two hundred hours of a
  // year is a different question — eight days of January. Which coarser
  // interval to use instead is the caller's call, and a reply that quietly
  // answered for January would hide that a choice was ever made. It also keeps
  // HealthKit from building a collection this size only to throw it away.
  //
  // The count below still clamps and still reports `truncated`, because this
  // estimate is an estimate: a month is not twenty-eight days.
  double estimated = [to timeIntervalSinceDate:from] / bucketSeconds;
  if (estimated > (double)kMaxBuckets) {
    reply(nil, [NSString stringWithFormat:
                @"that range is about %.0f %@ buckets and the limit is %lu. Ask for a coarser "
                 "'interval' or a shorter range — which one depends on what you are looking for.",
                estimated, interval, (unsigned long)kMaxBuckets]);
    return;
  }

  NSCalendar *calendar = NSCalendar.currentCalendar;
  NSDate *anchor = nil;
  if (![calendar rangeOfUnit:granularity startDate:&anchor interval:NULL forDate:from]) {
    reply(nil, @"'from' does not fall in a date this device's calendar can bucket");
    return;
  }

  HKQuantityType *quantity = [HKQuantityType quantityTypeForIdentifier:@(row->identifier)];
  require_asked(quantity, ^(BOOL ok, NSString *accessError) {
    if (!ok) { reply(nil, accessError); return; }

    BOOL cumulative = quantity.aggregationStyle == HKQuantityAggregationStyleCumulative;
    HKStatisticsOptions options =
      cumulative ? HKStatisticsOptionCumulativeSum
                 : (HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin
                    | HKStatisticsOptionDiscreteMax);
    NSPredicate *predicate = [HKQuery predicateForSamplesWithStartDate:from endDate:to
                                                               options:HKQueryOptionNone];
    // HealthKit validates the options against the type by RAISING, so the build
    // of the query is guarded: a type whose aggregation style we read wrongly
    // should refuse the call, not take the app down with it.
    HKStatisticsCollectionQuery *query = nil;
    @try {
      query = [[HKStatisticsCollectionQuery alloc] initWithQuantityType:quantity
                                               quantitySamplePredicate:predicate
                                                               options:options
                                                            anchorDate:anchor
                                                    intervalComponents:step];
    } @catch (NSException *exception) {
      query = nil;
    }
    if (query == nil) {
      reply(nil, [NSString stringWithFormat:
                  @"HealthKit will not total or average '%@' this way. Read its samples instead.",
                  @(row->id)]);
      return;
    }

    query.initialResultsHandler = ^(HKStatisticsCollectionQuery *finished,
                                    HKStatisticsCollection *collection,
                                    NSError *queryError) {
      // A collection query keeps running when it has an update handler, and we
      // want exactly one answer, so it is stopped either way. Through the
      // handler's own argument rather than the local `query`: capturing that
      // would be a cycle, since the query owns this block.
      [health_store() stopQuery:finished];
      if (collection == nil) {
        reply(nil, queryError.localizedDescription ?: @"the health statistics could not be read");
        return;
      }
      NSMutableArray *buckets = [NSMutableArray array];
      __block NSUInteger total = 0;
      [collection enumerateStatisticsFromDate:from toDate:to withBlock:^(HKStatistics *statistics,
                                                                         BOOL *stop) {
        total += 1;
        if (buckets.count >= kMaxBuckets) return;
        HKQuantity *value = cumulative ? statistics.sumQuantity : statistics.averageQuantity;
        NSMutableDictionary *bucket = [@{
          @"start": iso8601(statistics.startDate),
          @"end": iso8601(statistics.endDate),
          // A bucket HealthKit had no samples for is reported with a null value
          // rather than dropped. Whether "nothing recorded" means zero steps or
          // an unworn watch is the caller's read of their own data, not ours
          // (§4.5 ③).
          @"value": value == nil || ![value isCompatibleWithUnit:unit]
                    ? (id)NSNull.null : @([value doubleValueForUnit:unit]),
        } mutableCopy];
        if (!cumulative) {
          HKQuantity *low = statistics.minimumQuantity, *high = statistics.maximumQuantity;
          if (low != nil && [low isCompatibleWithUnit:unit]) {
            bucket[@"min"] = @([low doubleValueForUnit:unit]);
          }
          if (high != nil && [high isCompatibleWithUnit:unit]) {
            bucket[@"max"] = @([high doubleValueForUnit:unit]);
          }
        }
        [buckets addObject:bucket];
      }];

      NSMutableDictionary *result = [@{
        @"type": @(row->id),
        @"from": iso8601(from),
        @"to": iso8601(to),
        @"interval": interval,
        @"unit": unit.unitString,
        // Named rather than implied: a caller that reads a sum as an average
        // gets a wrong answer with no sign that anything went wrong.
        @"stat": cumulative ? @"sum" : @"average",
        @"buckets": buckets,
        @"total": @(total),
        @"truncated": @((BOOL)(total > buckets.count)),
      } mutableCopy];
      // Said when every bucket came back empty, which is the case that reads as
      // "no data" and might be no permission instead.
      BOOL anyValue = NO;
      for (NSDictionary *bucket in buckets) {
        if (bucket[@"value"] != NSNull.null) { anyValue = YES; break; }
      }
      if (!anyValue) result[@"emptyMeans"] = kEmptyMeansMessage;
      // Type, window and bucket count. No values, for the same reason as `read`.
      result[@"auditSummary"] = [NSString stringWithFormat:@"%@ · %@ → %@ · %@ × %lu",
                                 @(row->id), iso_day(from), iso_day(to), interval,
                                 (unsigned long)total];
      reply(result, nil);
    };
    [health_store() executeQuery:query];
  });
}

#pragma mark - The grant

/// Raise Apple's Health sheet, then run `done`.
///
/// Only `DshNativeRequestPermission` calls this, and only because the user asked
/// for it on screen (§5.5). `toShare` is nil and will stay nil: this app reads.
///
/// **`granted` is NO even when the sheet succeeded, and that is not a bug.**
/// HealthKit's `success` means the sheet ran to completion, nothing more — it is
/// YES when the user allowed everything, when they allowed nothing, and when
/// they tapped through without looking. There is no API that distinguishes those
/// afterwards, so claiming a grant here would be inventing one. The capability
/// screen does what it does for location: re-reads the status when the app comes
/// back to the foreground, through `DshHealthRequestStatus`, which can say
/// whether the user has been asked and never whether they said yes.
void DshHealthGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  if (!HKHealthStore.isHealthDataAvailable) {
    done(NO, kUnavailableMessage);
    return;
  }
  dsh_native_on_main(^{
    [health_store() requestAuthorizationToShareTypes:nil
                                           readTypes:all_read_types()
                                          completion:^(BOOL success, NSError *error) {
      if (error != nil) {
        done(NO, error.localizedDescription);
        return;
      }
      // Sheet finished. What the user chose is between them and iOS.
      done(NO, nil);
    }];
  });
}

/// Whether iOS would still show the sheet, as `HKAuthorizationRequestStatus`.
///
/// The whole of what can be known about read access, handed to the screen
/// without interpretation: `ShouldRequest` (1) means the user has not been
/// asked about every type this app declares, `Unnecessary` (2) means they have
/// been asked — NOT that they allowed anything — and `Unknown` (0) means iOS
/// would not say, which is also what an error here amounts to.
void DshHealthRequestStatus(void (^done)(NSInteger status)) {
  if (!HKHealthStore.isHealthDataAvailable) {
    done(HKAuthorizationRequestStatusUnknown);
    return;
  }
  [health_store() getRequestStatusForAuthorizationToShareTypes:[NSSet set]
                                                     readTypes:all_read_types()
                                                    completion:^(HKAuthorizationRequestStatus status,
                                                                 NSError *error) {
    done(error != nil ? HKAuthorizationRequestStatusUnknown : (NSInteger)status);
  }];
}

void dsh_native_health(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"types"]) { list_types(reply); return; }
  if ([op isEqualToString:@"read"]) { read_samples(args, reply); return; }
  if ([op isEqualToString:@"aggregate"]) { aggregate(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"health has no operation '%@'", op]);
}
