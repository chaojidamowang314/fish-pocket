// homekit: the user's smart home — what is in it, what state each thing is in,
// and changing one of those states or running one of their scenes.
//
// Three things make this file different from the rest.
//
// **It loads asynchronously, and "empty" is its starting value.** A fresh
// `HMHomeManager` has `homes == @[]` and `authorizationStatus == 0`, and neither
// means anything until the delegate speaks — Apple says so in the header. So
// answering in that window turns "still loading" into "you have no smart home",
// which is the one wrong answer a caller cannot see through: an agent that hears
// it will tell the user they own no accessories. Every operation here therefore
// waits for the manager to settle, and every wait carries a watchdog so it ends
// in an answer rather than a hung `await` (§4.3.2).
//
// **Creating the manager IS the permission prompt.** HomeKit has no class-level
// status query and no request-authorisation call, so there is no way to look
// before asking — unlike EventKit, CoreLocation and UserNotifications, which all
// answer for free. §5.5 says the system dialog may only ever come from the user
// tapping in the capability screen, so this file refuses until it has seen iOS
// grant access at least once, and only `DshHomeKitGrantAccess` ever creates the
// manager without that.
//
// **Nothing here interprets.** A characteristic is forwarded as Apple hands it
// over: raw value, raw type UUID, raw metadata — never "the light is on", never
// a colour temperature converted to kelvin. The classification is HomeKit's own
// `HMAccessoryCategory`, not a vocabulary of ours. And when a name matches more
// than one accessory or scene, the candidates go back to the caller rather than
// `firstObject` going back as an answer (§4.5).
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import <HomeKit/HomeKit.h>

/// A home is capped at 150 accessories by HomeKit itself, but a user may have
/// several homes, and this reply crosses into JS as one JSON string.
static const NSUInteger kMaxAccessories = 150;
static const NSUInteger kMaxRoomsPerHome = 60;
static const NSUInteger kMaxScenes = 100;
/// `get` expands characteristics and reads their values, so its matches are
/// capped much harder than a listing's.
static const NSUInteger kMaxDetailedAccessories = 5;
static const NSUInteger kMaxCharacteristics = 80;
static const NSUInteger kMaxTextLength = 200;
/// Enough for the caller to choose from, short enough to stay a message.
static const NSUInteger kMaxCandidatesListed = 10;

/// How long a caller waits for the manager to populate before being told so.
static const NSTimeInterval kLoadTimeout = 10.0;
/// Longer for the grant: a person is reading a dialog, not a device answering.
static const NSTimeInterval kGrantTimeout = 20.0;
/// An unreachable or sleeping accessory can leave a read outstanding for a long
/// time, and `get` issues one per characteristic.
static const NSTimeInterval kReadTimeout = 8.0;

// Read out to the user by the agent, so each one says what the user can do next.
static NSString *const kDeniedMessage =
    @"home data access is off for this app. The user can turn it on in "
     "Settings > Privacy & Security > HomeKit. iOS only asks once, so it cannot be requested again from here";

static NSString *const kRestrictedMessage =
    @"home data is restricted on this device, most likely by Screen Time or a management profile. "
     "Nothing was read or changed, and the app cannot lift that restriction";

/// The not-asked-yet refusal; worded like the one in `caps_notify.m`, and for the
/// same reason it names the screen's place rather than its title: this file is
/// not translated and the screen is, so a quoted title would drift from the one
/// on the user's display.
static NSString *const kNotEnabledMessage =
    @"the user has not switched home control on for this app yet. Nothing was read or changed. "
     "Tell them they can turn it on themselves under Device capabilities, which is in the app's "
     "sidebar — only they can grant it, and iOS asks once per app, so the app will not ask on its own.";

static NSString *const kTimeoutMessage =
    @"the home data did not finish loading in time, so nothing was read or changed. This is not the "
     "same as having no accessories — HomeKit populates in the background and can be slow after a "
     "wake or without a network. Trying again usually works";

/// What this app has seen iOS answer about home data.
///
/// Kept because HomeKit cannot be asked again without side effects: on a later
/// launch this is the only way to tell "never asked" from "refused", and the
/// only thing that lets an ordinary call create the manager without risking a
/// prompt nobody tapped for.
static NSString *const kAccessKey = @"dsh.native.homekit.access";

typedef NS_ENUM(NSInteger, DshHomeKitRemembered) {
  DshHomeKitRememberedUnknown = 0,
  DshHomeKitRememberedGranted = 1,
  DshHomeKitRememberedRefused = 2,
};

static void remember_access(DshHomeKitRemembered access) {
  [NSUserDefaults.standardUserDefaults setInteger:access forKey:kAccessKey];
}

static DshHomeKitRemembered remembered_access(void) {
  NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:kAccessKey];
  switch (stored) {
    case DshHomeKitRememberedGranted:
    case DshHomeKitRememberedRefused:
      return (DshHomeKitRemembered)stored;
    default:
      // Never set, or set to something this build does not know: treat it as
      // never asked. That costs the user one tap; the alternative — creating a
      // manager on a value we cannot read — costs them the one prompt iOS gives.
      return DshHomeKitRememberedUnknown;
  }
}

#pragma mark - Waiting with an outcome

/// Park `waiter` on `queue` until something drains it, or until `timeout`.
///
/// Every wait here is a plugin stopped at an `await`, so "nobody answered" has
/// to become an answer (§4.3.2). The watchdog is per waiter rather than per
/// queue so a caller that arrived late still gets its full wait.
static void park(NSMutableArray *queue, NSTimeInterval timeout, NSString *onTimeout,
                 void (^waiter)(NSString *error)) {
  void (^stored)(NSString *) = [waiter copy];
  [queue addObject:stored];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    NSUInteger index = [queue indexOfObjectIdenticalTo:stored];
    if (index == NSNotFound) return;  // answered already
    [queue removeObjectAtIndex:index];
    stored(onTimeout);
  });
}

static void drain(NSMutableArray *queue, NSString *error) {
  NSArray *waiting = [queue copy];
  [queue removeAllObjects];
  for (void (^waiter)(NSString *) in waiting) waiter(error);
}

#pragma mark - The one home manager

/// Owns the process's single `HMHomeManager` and the knowledge of whether it has
/// said anything yet.
///
/// One manager, created as late as possible: a second one would be a second
/// chance to prompt, and the delegate is the only way HomeKit reports either
/// authorisation or the arrival of the home list. Everything here runs on the
/// main thread — HomeKit delivers its delegate calls and completion handlers
/// there, and its object graph is not safe to walk from anywhere else.
@interface DshHomeKitHub : NSObject <HMHomeManagerDelegate>
@property (nonatomic, readonly) HMHomeManager *manager;
@property (nonatomic, readonly) BOOL started;
@end

@implementation DshHomeKitHub {
  HMHomeManager *_manager;
  /// Set by the first `homeManagerDidUpdateHomes:` and never cleared. Before it,
  /// `_manager.homes` is the empty array the manager was born with, which is
  /// indistinguishable from a user who owns nothing.
  BOOL _loaded;
  NSMutableArray<void (^)(NSString *error)> *_waiting;
}

+ (instancetype)shared {
  static DshHomeKitHub *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [DshHomeKitHub new]; });
  return shared;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) _waiting = [NSMutableArray array];
  return self;
}

- (HMHomeManager *)manager { return _manager; }
- (BOOL)started { return _manager != nil; }

/// Create the manager if it does not exist yet. **This is the permission
/// prompt**, the first time it ever runs, which is why the two callers that
/// reach it are the grant path and a call that has already seen iOS say yes.
- (void)start {
  if (_manager != nil) return;
  _manager = [HMHomeManager new];
  _manager.delegate = self;
}

- (HMHomeManagerAuthorizationStatus)status {
  return _manager == nil ? 0 : _manager.authorizationStatus;
}

/// Whether home data can be spoken about truthfully right now.
///
/// Three states hide behind one empty `homes` array and collapsing them is the
/// mistake this capability is most likely to make:
///   - status 0 — iOS has not filled the manager in yet. We know nothing.
///   - not authorised — iOS answered, and the answer was no. Answerable.
///   - authorised but `!_loaded` — allowed, and the list is still empty because
///     it has not arrived. Not answerable.
///
/// The go/no-go test is the `Authorized` bit alone. `Determined` is deliberately
/// not trusted for it: HomeKit's header disagrees with itself about that bit
/// (the constant is named Determined, its own comment says "the user has not yet
/// made a choice"). It is used only to tell a refusal apart from a manager iOS
/// has not populated, where guessing wrong costs a wrong message rather than a
/// wrong decision.
- (BOOL)canAnswer {
  if (_manager == nil) return NO;
  HMHomeManagerAuthorizationStatus status = _manager.authorizationStatus;
  if ((status & HMHomeManagerAuthorizationStatusAuthorized) != 0) return _loaded;
  return status != 0;
}

/// Run `next` once the manager can be answered from, or once the wait runs out.
/// `error` is nil when there is something truthful to say — including "iOS said
/// no", which `refusal` then puts into words.
- (void)whenSettledWithin:(NSTimeInterval)timeout next:(void (^)(NSString *error))next {
  if ([self canAnswer]) {
    next(nil);
    return;
  }
  park(_waiting, timeout, kTimeoutMessage, next);
}

/// Why this call cannot go ahead, or nil when it can.
///
/// Also where the remembered answer is kept up to date, so a user who revoked
/// access in Settings sees the capability screen say so instead of the app
/// quietly refusing forever.
- (NSString *)refusal {
  HMHomeManagerAuthorizationStatus status = self.status;
  if ((status & HMHomeManagerAuthorizationStatusAuthorized) != 0) {
    remember_access(DshHomeKitRememberedGranted);
    return nil;
  }
  remember_access(DshHomeKitRememberedRefused);
  return (status & HMHomeManagerAuthorizationStatusRestricted) != 0 ? kRestrictedMessage : kDeniedMessage;
}

- (void)homeManagerDidUpdateHomes:(HMHomeManager *)manager {
  // Fires again on every significant change to the home configuration, which is
  // fine: loaded stays loaded, and anyone waiting is let through.
  _loaded = YES;
  drain(_waiting, nil);
}

- (void)homeManager:(HMHomeManager *)manager
    didUpdateAuthorizationStatus:(HMHomeManagerAuthorizationStatus)status {
  // A refusal is reported here and nowhere else: `homeManagerDidUpdateHomes:`
  // never arrives for an app that was told no, so without this the waiters
  // would sit until the watchdog and then blame a timeout for a denial.
  if ([self canAnswer]) drain(_waiting, nil);
}
@end

/// Run `next` on the main thread with a loaded, authorised manager — or with a
/// refusal the agent can read out. **Never raises a dialog**: a capability that
/// has not seen iOS grant access refuses, so the one prompt HomeKit gives is
/// spent on a user who tapped for it rather than on whichever plugin called
/// first (§5.5).
static void require_homes(void (^next)(HMHomeManager *manager, NSString *error)) {
  dsh_native_on_main(^{
    DshHomeKitHub *hub = DshHomeKitHub.shared;
    if (!hub.started && remembered_access() != DshHomeKitRememberedGranted) {
      next(nil, kNotEnabledMessage);
      return;
    }
    [hub start];
    [hub whenSettledWithin:kLoadTimeout next:^(NSString *error) {
      if (error != nil) {
        // Timed out. Says so, rather than reporting an empty home: the two are
        // different facts and only one of them is about the user's setup.
        next(nil, error);
        return;
      }
      NSString *refusal = [hub refusal];
      if (refusal != nil) {
        next(nil, refusal);
        return;
      }
      next(hub.manager, nil);
    }];
  });
}

#pragma mark - Shapes

static NSString *truncated(NSString *text, NSUInteger limit) {
  if (text.length <= limit) return text;
  NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:limit];
  return [[text substringToIndex:range.location] stringByAppendingString:@"…"];
}

/// A characteristic value as something JSON can carry, saying how it got there.
///
/// Numbers and strings go through untouched — no 0/1 turned into off/on, no mired
/// turned into kelvin, no unit maths. A few characteristics carry TLV8 blobs as
/// NSData, which `NSJSONSerialization` cannot encode at all, and an unencodable
/// field fails the whole call rather than itself; those come through base64 with
/// `valueEncoding` saying so, so the caller knows it is holding a re-encoding
/// instead of something that looks like the value and is not.
static id json_value(id value, NSString **encoding) {
  *encoding = nil;
  if ([value isKindOfClass:NSNumber.class]) return value;
  if ([value isKindOfClass:NSString.class]) return truncated(value, kMaxTextLength);
  if ([value isKindOfClass:NSData.class]) {
    *encoding = @"base64";
    return [(NSData *)value base64EncodedStringWithOptions:0];
  }
  *encoding = @"description";
  return truncated([value description], kMaxTextLength);
}

/// One value, short, for a confirmation sheet and an audit line.
static NSString *render_value(id value) {
  if (value == nil) return @"?";
  if ([value isKindOfClass:NSString.class]) return truncated(value, 80);
  if ([value isKindOfClass:NSNumber.class]) return ((NSNumber *)value).stringValue;
  if ([value isKindOfClass:NSData.class]) {
    return [NSString stringWithFormat:@"%lu B", (unsigned long)((NSData *)value).length];
  }
  return truncated([value description], 80);
}

/// Apple's own metadata, field for field. This is what makes forwarding a raw
/// value usable instead of cryptic: `format`, the range, the step and the units
/// are how a caller works out what 0.5 or 140 means in this characteristic,
/// which is a judgement about the user's request and so belongs to the caller.
static NSDictionary *metadata_json(HMCharacteristicMetadata *meta) {
  NSMutableDictionary *entry = [NSMutableDictionary dictionary];
  if (meta.format.length > 0) entry[@"format"] = meta.format;
  if (meta.units.length > 0) entry[@"units"] = meta.units;
  if (meta.minimumValue != nil) entry[@"minimumValue"] = meta.minimumValue;
  if (meta.maximumValue != nil) entry[@"maximumValue"] = meta.maximumValue;
  if (meta.stepValue != nil) entry[@"stepValue"] = meta.stepValue;
  if (meta.maxLength != nil) entry[@"maxLength"] = meta.maxLength;
  if (meta.validValues.count > 0) entry[@"validValues"] = meta.validValues;
  if (meta.manufacturerDescription.length > 0) {
    entry[@"manufacturerDescription"] = meta.manufacturerDescription;
  }
  return entry;
}

static NSDictionary *characteristic_json(HMCharacteristic *characteristic, NSString *readError) {
  NSMutableDictionary *entry = [@{
    // The handle for `set`. It is the only unambiguous one: a type repeats across
    // the services of a multi-outlet accessory, and a label repeats with it.
    @"uniqueIdentifier": characteristic.uniqueIdentifier.UUIDString ?: @"",
    @"type": characteristic.characteristicType ?: @"",
    // Apple's label for this characteristic, in the device's language. Passed on
    // as a label, not used to decide anything.
    @"localizedDescription": characteristic.localizedDescription ?: @"",
    @"properties": characteristic.properties ?: @[],
  } mutableCopy];
  if (characteristic.value != nil) {
    NSString *encoding = nil;
    entry[@"value"] = json_value(characteristic.value, &encoding);
    if (encoding != nil) entry[@"valueEncoding"] = encoding;
  }
  NSDictionary *metadata = metadata_json(characteristic.metadata);
  if (metadata.count > 0) entry[@"metadata"] = metadata;
  // Reported rather than swallowed: "the read failed" and "there is no value"
  // are different things to a caller deciding whether to try again.
  if (readError != nil) entry[@"readError"] = readError;
  return entry;
}

/// Compact: what a caller needs to pick one accessory out and ask about it.
static NSDictionary *accessory_summary_json(HMAccessory *accessory) {
  NSMutableDictionary *entry = [@{
    @"uniqueIdentifier": accessory.uniqueIdentifier.UUIDString ?: @"",
    @"name": accessory.name ?: @"",
    // HomeKit's own classification, forwarded as its own constant. No "light" or
    // "lock" vocabulary of ours on top: a second taxonomy would have to be kept
    // in step with Apple's forever, and callers can read Apple's directly (§4.5).
    @"category": accessory.category.categoryType ?: @"",
    @"categoryLocalizedDescription": accessory.category.localizedDescription ?: @"",
    // Reported, never used to filter: an unreachable accessory is still one the
    // user owns, and whether to bother with it is the caller's call.
    @"reachable": @(accessory.isReachable),
    @"blocked": @(accessory.isBlocked),
    @"bridged": @(accessory.isBridged),
    @"serviceCount": @(accessory.services.count),
  } mutableCopy];
  if (accessory.room.name.length > 0) entry[@"room"] = accessory.room.name;
  return entry;
}

static NSDictionary *scene_json(HMActionSet *scene, HMHome *home) {
  NSMutableDictionary *entry = [@{
    @"uniqueIdentifier": scene.uniqueIdentifier.UUIDString ?: @"",
    @"name": scene.name ?: @"",
    @"home": home.name ?: @"",
    // Forwarded, not filtered. `HMActionSetTypeTriggerOwned` action sets belong
    // to automations rather than to the scene list in the Home app, and dropping
    // them here would be this file deciding which of HomeKit's answers count
    // (§4.5). The type is right there for a caller that wants only user scenes.
    @"actionSetType": scene.actionSetType ?: @"",
    @"actionCount": @(scene.actions.count),
    @"executing": @(scene.isExecuting),
  } mutableCopy];
  if (scene.lastExecutionDate != nil) {
    entry[@"lastExecutedAt"] = @(scene.lastExecutionDate.timeIntervalSince1970);
  }
  return entry;
}

/// Home names and a count: the user's own words plus a number, which is what an
/// audit line shown verbatim in a translated app can safely hold (§5.4).
static NSString *homes_summary(NSArray<HMHome *> *homes, NSUInteger count) {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (HMHome *home in homes) {
    if (home.name.length > 0) [names addObject:home.name];
  }
  return [NSString stringWithFormat:@"%@ · %lu", [names componentsJoinedByString:@", "], (unsigned long)count];
}

#pragma mark - Finding things by what the caller called them

/// Exact, case-insensitive. Not a substring search and not fuzzy: a caller that
/// wants to search reads `list` and decides for itself, which keeps us out of
/// the business of inventing a match rule and then patching it forever (§4.5).
static BOOL names_match(NSString *candidate, NSString *needle) {
  return candidate.length > 0 && [candidate caseInsensitiveCompare:needle] == NSOrderedSame;
}

/// **Every** accessory whose name or identifier the caller's string matches,
/// across every home — never the first one.
///
/// A name is the user's own label and nothing stops two accessories sharing it;
/// two homes make it likely. `firstObject` here is a confident wrong answer, and
/// §4.5 was written around exactly that failure after a geocoder answered
/// "San Francisco" with a township in Yunnan and the ETA came back as one metre.
/// The caller is a language model holding the user's actual sentence; it can
/// choose between "Bedroom lamp" in two homes and this function cannot.
static NSArray<HMAccessory *> *accessories_matching(HMHomeManager *manager, NSString *needle) {
  NSMutableArray<HMAccessory *> *found = [NSMutableArray array];
  for (HMHome *home in manager.homes) {
    for (HMAccessory *accessory in home.accessories) {
      if (names_match(accessory.name, needle)
          || names_match(accessory.uniqueIdentifier.UUIDString, needle)) {
        [found addObject:accessory];
      }
    }
  }
  return found;
}

/// Same rule, for scenes. Scene names repeat across homes more often than
/// accessory names do — "Good Morning" in both the flat and the house — so this
/// is the matcher most likely to come back with two.
static NSArray<HMActionSet *> *scenes_matching(HMHomeManager *manager, NSString *needle,
                                               NSMutableArray<HMHome *> *homesOut) {
  NSMutableArray<HMActionSet *> *found = [NSMutableArray array];
  for (HMHome *home in manager.homes) {
    for (HMActionSet *scene in home.actionSets) {
      if (names_match(scene.name, needle) || names_match(scene.uniqueIdentifier.UUIDString, needle)) {
        [found addObject:scene];
        [homesOut addObject:home];
      }
    }
  }
  return found;
}

/// Every characteristic of `accessory` the caller's string names, by
/// characteristic type or by unique identifier. Both are UUID strings, so both
/// are tried rather than the caller being asked which kind it holds.
static NSArray<HMCharacteristic *> *characteristics_matching(HMAccessory *accessory, NSString *needle) {
  NSMutableArray<HMCharacteristic *> *found = [NSMutableArray array];
  for (HMService *service in accessory.services) {
    for (HMCharacteristic *characteristic in service.characteristics) {
      if (names_match(characteristic.characteristicType, needle)
          || names_match(characteristic.uniqueIdentifier.UUIDString, needle)) {
        [found addObject:characteristic];
      }
    }
  }
  return found;
}

/// The candidates, as a line a caller can read and then retry with. Refusing
/// without saying what the choices were just moves the guess to the caller.
static NSString *list_accessory_candidates(NSArray<HMAccessory *> *accessories) {
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (HMAccessory *accessory in accessories) {
    if (lines.count >= kMaxCandidatesListed) {
      [lines addObject:@"…"];
      break;
    }
    [lines addObject:[NSString stringWithFormat:@"'%@' in %@/%@ (%@)",
                      accessory.name ?: @"",
                      accessory.home.name ?: @"?",
                      accessory.room.name ?: @"?",
                      accessory.uniqueIdentifier.UUIDString ?: @""]];
  }
  return [lines componentsJoinedByString:@"; "];
}

static NSString *list_characteristic_candidates(NSArray<HMCharacteristic *> *characteristics) {
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (HMCharacteristic *characteristic in characteristics) {
    if (lines.count >= kMaxCandidatesListed) {
      [lines addObject:@"…"];
      break;
    }
    [lines addObject:[NSString stringWithFormat:@"%@ on service '%@' (%@)",
                      characteristic.localizedDescription ?: characteristic.characteristicType ?: @"",
                      characteristic.service.name ?: @"",
                      characteristic.uniqueIdentifier.UUIDString ?: @""]];
  }
  return [lines componentsJoinedByString:@"; "];
}

#pragma mark - Reading

/// list: homes, their rooms, and their accessories — enough to pick one out of,
/// and no characteristics. Characteristics are per-accessory and there can be
/// dozens each; putting them here would make the common "what have I got"
/// question the most expensive call in the capability.
static void list_homes(DshNativeReply reply) {
  require_homes(^(HMHomeManager *manager, NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    NSUInteger totalAccessories = 0, shown = 0;
    NSMutableArray *homes = [NSMutableArray array];
    for (HMHome *home in manager.homes) {
      NSMutableArray *rooms = [NSMutableArray array];
      for (HMRoom *room in home.rooms) {
        if (rooms.count >= kMaxRoomsPerHome) break;
        [rooms addObject:@{@"uniqueIdentifier": room.uniqueIdentifier.UUIDString ?: @"",
                           @"name": room.name ?: @""}];
      }
      NSMutableArray *accessories = [NSMutableArray array];
      for (HMAccessory *accessory in home.accessories) {
        totalAccessories++;
        if (shown >= kMaxAccessories) continue;
        [accessories addObject:accessory_summary_json(accessory)];
        shown++;
      }
      NSMutableDictionary *entry = [@{
        @"uniqueIdentifier": home.uniqueIdentifier.UUIDString ?: @"",
        @"name": home.name ?: @"",
        @"primary": @(home.isPrimary),
        // HomeKit's own enum, forwarded as the number it is. Whether a missing
        // hub matters to this request is the caller's call.
        @"homeHubState": @(home.homeHubState),
        @"rooms": rooms,
        @"accessories": accessories,
      } mutableCopy];
      if (home.rooms.count > rooms.count) entry[@"roomsTruncated"] = @YES;
      [homes addObject:entry];
    }
    // The (BOOL) cast is load-bearing, for the reason caps_calendar.m spells
    // out: a C comparison has type int, so without it this encodes as 0/1 and a
    // model reading `"truncated": 0` beside `"primary": false` may take the 0
    // for a count rather than for false.
    reply(@{@"homes": homes,
            @"total": @(totalAccessories),
            @"truncated": @((BOOL)(totalAccessories > shown)),
            @"auditSummary": homes_summary(manager.homes, totalAccessories)}, nil);
  });
}

/// Read every characteristic in `characteristics`, then run `done`.
///
/// `HMCharacteristic.value` is a cache: nil until something reads it, and stale
/// afterwards. "Current value" therefore has to mean an actual read, so this
/// issues one per readable characteristic. Unreadable ones are skipped because
/// HomeKit rejects a read on them — that is Apple's `properties` saying so, not
/// a judgement of ours.
///
/// `complete` is NO when the batch ran out of time; the values already in are
/// still reported. The counter and the error table are touched on the main queue
/// only — HomeKit already delivers these completions there, and the hop costs
/// nothing when it is already true but removes the race if it ever stops being.
static void read_values(NSArray<HMCharacteristic *> *characteristics,
                        NSMutableDictionary<NSString *, NSString *> *errors,
                        void (^done)(BOOL complete)) {
  NSMutableArray<HMCharacteristic *> *readable = [NSMutableArray array];
  for (HMCharacteristic *characteristic in characteristics) {
    if ([characteristic.properties containsObject:HMCharacteristicPropertyReadable]) {
      [readable addObject:characteristic];
    }
  }
  if (readable.count == 0) {
    done(YES);
    return;
  }

  __block NSUInteger outstanding = readable.count;
  __block BOOL settled = NO;
  void (^settle)(BOOL) = ^(BOOL complete) {
    if (settled) return;
    settled = YES;
    done(complete);
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReadTimeout * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ settle(NO); });
  for (HMCharacteristic *characteristic in readable) {
    NSString *key = characteristic.uniqueIdentifier.UUIDString ?: @"";
    [characteristic readValueWithCompletionHandler:^(NSError *readError) {
      dsh_native_on_main(^{
        if (readError != nil && key.length > 0) {
          errors[key] = readError.localizedDescription ?: @"the value could not be read";
        }
        if (--outstanding == 0) settle(YES);
      });
    }];
  }
}

/// get: one accessory in full — its services, its characteristics, their current
/// values and Apple's metadata for each.
///
/// When the name matches several, **all of them come back**. Not a refusal and
/// not a pick: a read can honestly answer for every match, and a caller looking
/// at two "Bedroom lamp" entries with their rooms and identifiers can say which
/// one it meant (§4.5).
static void get_accessory(NSDictionary *args, DshNativeReply reply) {
  NSString *identifier = args[@"uniqueIdentifier"];
  NSString *name = args[@"name"];
  NSString *needle = [identifier isKindOfClass:NSString.class] && identifier.length > 0 ? identifier
                   : ([name isKindOfClass:NSString.class] && name.length > 0 ? name : nil);
  if (needle == nil) {
    reply(nil, @"get needs 'name' or 'uniqueIdentifier', as `list` returned them");
    return;
  }

  require_homes(^(HMHomeManager *manager, NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    NSArray<HMAccessory *> *matches = accessories_matching(manager, needle);
    if (matches.count == 0) {
      reply(nil, [NSString stringWithFormat:
                  @"no accessory in this home is named '%@'. Names are matched exactly (case aside), "
                   "not as a search; `list` shows what there is", needle]);
      return;
    }

    // One flat pass, so the cap is on the whole reply rather than per accessory,
    // and so the reads below cover exactly what will be reported.
    NSMutableArray<HMCharacteristic *> *selected = [NSMutableArray array];
    NSMutableSet<NSString *> *included = [NSMutableSet set];
    NSUInteger totalCharacteristics = 0;
    NSArray<HMAccessory *> *expanded = matches.count > kMaxDetailedAccessories
      ? [matches subarrayWithRange:NSMakeRange(0, kMaxDetailedAccessories)] : matches;
    for (HMAccessory *accessory in expanded) {
      for (HMService *service in accessory.services) {
        for (HMCharacteristic *characteristic in service.characteristics) {
          totalCharacteristics++;
          if (selected.count >= kMaxCharacteristics) continue;
          [selected addObject:characteristic];
          [included addObject:characteristic.uniqueIdentifier.UUIDString ?: @""];
        }
      }
    }

    NSMutableDictionary<NSString *, NSString *> *readErrors = [NSMutableDictionary dictionary];
    read_values(selected, readErrors, ^(BOOL complete) {
      NSMutableArray *accessories = [NSMutableArray array];
      for (HMAccessory *accessory in expanded) {
        NSMutableDictionary *entry = [accessory_summary_json(accessory) mutableCopy];
        if (accessory.home.name.length > 0) entry[@"home"] = accessory.home.name;
        if (accessory.manufacturer.length > 0) entry[@"manufacturer"] = accessory.manufacturer;
        if (accessory.model.length > 0) entry[@"model"] = accessory.model;
        if (accessory.firmwareVersion.length > 0) entry[@"firmwareVersion"] = accessory.firmwareVersion;
        NSMutableArray *services = [NSMutableArray array];
        for (HMService *service in accessory.services) {
          NSMutableArray *characteristics = [NSMutableArray array];
          for (HMCharacteristic *characteristic in service.characteristics) {
            NSString *key = characteristic.uniqueIdentifier.UUIDString ?: @"";
            if (![included containsObject:key]) continue;
            [characteristics addObject:characteristic_json(characteristic, readErrors[key])];
          }
          [services addObject:@{@"uniqueIdentifier": service.uniqueIdentifier.UUIDString ?: @"",
                                @"name": service.name ?: @"",
                                @"type": service.serviceType ?: @"",
                                @"localizedDescription": service.localizedDescription ?: @"",
                                @"primary": @(service.isPrimaryService),
                                @"userInteractive": @(service.isUserInteractive),
                                @"characteristics": characteristics}];
        }
        entry[@"services"] = services;
        [accessories addObject:entry];
      }
      // The names that were read, which are the user's own words, plus how many.
      // Every match, not the first: the audit list is the user's only record of
      // what this app touched, so it has to name all of what it touched (§5.4).
      NSMutableArray<NSString *> *read = [NSMutableArray array];
      for (HMAccessory *accessory in expanded) {
        if (accessory.name.length > 0) [read addObject:accessory.name];
      }
      NSMutableDictionary *result = [@{
        @"accessories": accessories,
        @"total": @(matches.count),
        @"truncated": @((BOOL)(matches.count > expanded.count)),
        @"auditSummary": [NSString stringWithFormat:@"%@ · %lu",
                          [read componentsJoinedByString:@", "], (unsigned long)matches.count],
      } mutableCopy];
      if (totalCharacteristics > selected.count) result[@"characteristicsTruncated"] = @YES;
      // Said plainly: some values above are whatever HomeKit had cached, because
      // the read did not come back. Silence here would pass a stale number off
      // as a current one.
      if (!complete) result[@"valuesTimedOut"] = @YES;
      reply(result, nil);
    });
  });
}

/// scenes: the home's action sets, every type of them, with the type attached.
static void list_scenes(DshNativeReply reply) {
  require_homes(^(HMHomeManager *manager, NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    NSUInteger total = 0;
    NSMutableArray *scenes = [NSMutableArray array];
    for (HMHome *home in manager.homes) {
      for (HMActionSet *scene in home.actionSets) {
        total++;
        if (scenes.count >= kMaxScenes) continue;
        [scenes addObject:scene_json(scene, home)];
      }
    }
    reply(@{@"scenes": scenes,
            @"total": @(total),
            @"truncated": @((BOOL)(total > scenes.count)),
            @"auditSummary": homes_summary(manager.homes, total)}, nil);
  });
}

#pragma mark - Writing

/// What the confirmation sheet and the audit line say about one change.
///
/// The accessory's own name and room (the user's words), Apple's label for the
/// characteristic, and both values — because a sheet has to show what will
/// change, and "Bedroom lamp" alone cannot be judged (§4.3.1). Built natively
/// from the characteristic as it is right now, not from what the caller claimed.
static NSString *change_summary(HMAccessory *accessory, HMCharacteristic *characteristic, id value) {
  NSMutableString *summary = [NSMutableString stringWithString:accessory.name ?: @""];
  if (accessory.room.name.length > 0) [summary appendFormat:@" · %@", accessory.room.name];
  [summary appendFormat:@"\n%@ %@ → %@",
   characteristic.localizedDescription ?: characteristic.characteristicType ?: @"",
   render_value(characteristic.value), render_value(value)];
  return summary;
}

/// set: write one characteristic.
///
/// Ambiguity is refused here rather than resolved, which is the opposite of
/// `get`: a read can answer for all the matches, but a write has to pick one,
/// and picking is exactly what this file does not do. The refusal carries the
/// candidates so the caller can come back with an identifier (§4.5).
static void set_characteristic(NSDictionary *args, DshNativeReply reply) {
  NSString *accessoryRef = args[@"accessory"];
  NSString *characteristicRef = args[@"characteristic"];
  id value = args[@"value"];
  if (![accessoryRef isKindOfClass:NSString.class] || accessoryRef.length == 0) {
    reply(nil, @"set needs 'accessory', a name or uniqueIdentifier as `list` returned it");
    return;
  }
  if (![characteristicRef isKindOfClass:NSString.class] || characteristicRef.length == 0) {
    reply(nil, @"set needs 'characteristic', a type or uniqueIdentifier as `get` returned it");
    return;
  }
  if (value == nil || [value isKindOfClass:NSNull.class]) {
    reply(nil, @"set needs 'value'. It is passed to HomeKit as given — see the characteristic's "
                "metadata from `get` for the format, range and units it expects");
    return;
  }

  require_homes(^(HMHomeManager *manager, NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    NSArray<HMAccessory *> *accessories = accessories_matching(manager, accessoryRef);
    if (accessories.count == 0) {
      reply(nil, [NSString stringWithFormat:
                  @"no accessory in this home is named '%@', so nothing was changed. Names are "
                   "matched exactly (case aside); `list` shows what there is", accessoryRef]);
      return;
    }
    if (accessories.count > 1) {
      reply(nil, [NSString stringWithFormat:
                  @"'%@' matches %lu accessories, so nothing was changed — which one was meant is "
                   "the caller's call, not this app's. Pass one of their identifiers as "
                   "'accessory': %@",
                  accessoryRef, (unsigned long)accessories.count,
                  list_accessory_candidates(accessories)]);
      return;
    }
    HMAccessory *accessory = accessories.firstObject;

    NSArray<HMCharacteristic *> *characteristics = characteristics_matching(accessory, characteristicRef);
    if (characteristics.count == 0) {
      reply(nil, [NSString stringWithFormat:
                  @"'%@' has no characteristic '%@', so nothing was changed. `get` lists the ones "
                   "it has, with the identifiers to use here",
                  accessory.name ?: @"", characteristicRef]);
      return;
    }
    if (characteristics.count > 1) {
      // A two-gang switch has the same characteristic type on each of its
      // services; writing to "the first one" would turn on whichever socket
      // HomeKit happened to list first.
      reply(nil, [NSString stringWithFormat:
                  @"'%@' has %lu characteristics matching '%@', so nothing was changed. Pass one of "
                   "their uniqueIdentifiers instead: %@",
                  accessory.name ?: @"", (unsigned long)characteristics.count, characteristicRef,
                  list_characteristic_candidates(characteristics)]);
      return;
    }
    HMCharacteristic *characteristic = characteristics.firstObject;
    if (![characteristic.properties containsObject:HMCharacteristicPropertyWritable]) {
      reply(nil, [NSString stringWithFormat:
                  @"'%@' on '%@' is read-only — HomeKit reports it without the writable property, "
                   "so nothing was changed",
                  characteristic.localizedDescription ?: characteristicRef, accessory.name ?: @""]);
      return;
    }

    NSString *summary = change_summary(accessory, characteristic, value);
    DshNativeConfirmWrite(@"homekit", @"set", summary, NO, ^(BOOL confirmed, NSString *refusal) {
      dsh_native_on_main(^{
        // Two different outcomes, never merged: `refusal` is the write policy
        // saying no (the user set this capability to read-only, and the agent
        // should say so), while `confirmed == NO` is the user tapping Cancel on
        // a sheet, which is a normal answer and not a failure (§4.3.3).
        if (refusal != nil) {
          reply(nil, refusal);
          return;
        }
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"written": @NO}, nil);
          return;
        }
        // The value goes to HomeKit exactly as the caller gave it. No coercion
        // from "on" to 1 and no unit maths: HomeKit's own error for a wrong type
        // is a better answer than a guess of ours that happens to write
        // something (§4.5).
        [characteristic writeValue:value completionHandler:^(NSError *writeError) {
          if (writeError != nil) {
            reply(nil, writeError.localizedDescription ?: @"the value could not be written");
            return;
          }
          reply(@{@"action": DshNativeActionSaved, @"written": @YES,
                  @"accessory": accessory.uniqueIdentifier.UUIDString ?: @"",
                  @"characteristic": characteristic.uniqueIdentifier.UUIDString ?: @"",
                  @"auditSummary": summary}, nil);
        }];
      });
    });
  });
}

/// trigger: run one scene. Same refusal-over-picking rule as `set`, and more
/// often needed: one scene name usually exists in every home the user owns.
static void trigger_scene(NSDictionary *args, DshNativeReply reply) {
  NSString *needle = args[@"name"];
  if (![needle isKindOfClass:NSString.class] || needle.length == 0) {
    reply(nil, @"trigger needs 'name', a scene name or uniqueIdentifier as `scenes` returned it");
    return;
  }

  require_homes(^(HMHomeManager *manager, NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    NSMutableArray<HMHome *> *homes = [NSMutableArray array];
    NSArray<HMActionSet *> *scenes = scenes_matching(manager, needle, homes);
    if (scenes.count == 0) {
      reply(nil, [NSString stringWithFormat:
                  @"no scene is named '%@', so nothing ran. Names are matched exactly (case aside); "
                   "`scenes` shows what there is", needle]);
      return;
    }
    if (scenes.count > 1) {
      NSMutableArray<NSString *> *lines = [NSMutableArray array];
      for (NSUInteger i = 0; i < scenes.count && i < kMaxCandidatesListed; i++) {
        [lines addObject:[NSString stringWithFormat:@"'%@' in %@ (%@)",
                          scenes[i].name ?: @"", homes[i].name ?: @"",
                          scenes[i].uniqueIdentifier.UUIDString ?: @""]];
      }
      reply(nil, [NSString stringWithFormat:
                  @"'%@' matches %lu scenes, so nothing ran — which home was meant is the caller's "
                   "call. Pass one of their uniqueIdentifiers as 'name': %@",
                  needle, (unsigned long)scenes.count, [lines componentsJoinedByString:@"; "]]);
      return;
    }
    HMActionSet *scene = scenes.firstObject;
    HMHome *home = homes.firstObject;

    // The scene's own name and its home, both the user's words. What a scene
    // actually does is a list of actions on accessories; naming them all would
    // make the sheet unreadable, and the name is what the user chose for them.
    NSString *summary = [NSString stringWithFormat:@"%@ · %@", scene.name ?: @"", home.name ?: @""];
    DshNativeConfirmWrite(@"homekit", @"trigger", summary, NO, ^(BOOL confirmed, NSString *refusal) {
      dsh_native_on_main(^{
        if (refusal != nil) {
          reply(nil, refusal);
          return;
        }
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"executed": @NO}, nil);
          return;
        }
        [home executeActionSet:scene completionHandler:^(NSError *runError) {
          if (runError != nil) {
            reply(nil, runError.localizedDescription ?: @"the scene could not be run");
            return;
          }
          reply(@{@"action": DshNativeActionSaved, @"executed": @YES,
                  @"scene": scene.uniqueIdentifier.UUIDString ?: @"",
                  @"auditSummary": summary}, nil);
        }];
      });
    });
  });
}

#pragma mark - The grant, and what we know about it

/// What the capability screen reads, instead of asking HomeKit.
///
/// Every other capability's screen row asks its framework (`EKEventStore
/// .authorizationStatus`, `CLLocationManager.authorizationStatus`); HomeKit has
/// no such call, and the thing that would answer — an `HMHomeManager` — is the
/// prompt. So the row reads what this app has already seen iOS say. Side-effect
/// free, and main-thread only, like the statuses it stands in for.
///
/// Two functions rather than a tri-state, so nothing new has to be declared in
/// the shared header: granted, refused, or neither (never asked).
static DshHomeKitRemembered observed_access(void) {
  DshHomeKitHub *hub = DshHomeKitHub.shared;
  if (hub.started) {
    HMHomeManagerAuthorizationStatus status = hub.status;
    if ((status & HMHomeManagerAuthorizationStatusAuthorized) != 0) return DshHomeKitRememberedGranted;
    // A live manager at 0 has not been populated yet, which is not a refusal —
    // fall through to what was remembered rather than telling the screen "no".
    if (status != 0) return DshHomeKitRememberedRefused;
  }
  return remembered_access();
}

BOOL DshHomeKitAccessGranted(void) {
  return observed_access() == DshHomeKitRememberedGranted;
}

BOOL DshHomeKitAccessRefused(void) {
  return observed_access() == DshHomeKitRememberedRefused;
}

void DshHomeKitGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  dsh_native_on_main(^{
    DshHomeKitHub *hub = DshHomeKitHub.shared;
    // Creating the manager is the dialog, and this is the only place allowed to
    // do it cold: the user is on the capability screen and just tapped for it
    // (§5.5). HomeKit offers nothing to call instead — no requestAuthorization,
    // no class-level status.
    [hub start];
    [hub whenSettledWithin:kGrantTimeout next:^(NSString *error) {
      HMHomeManagerAuthorizationStatus status = hub.status;
      if ((status & HMHomeManagerAuthorizationStatusAuthorized) != 0) {
        remember_access(DshHomeKitRememberedGranted);
        done(YES, nil);
        return;
      }
      if (error != nil) {
        // Nothing was learned: the dialog may still be on screen, unanswered.
        // Reported as "not granted yet" with no error, like caps_location.m —
        // the screen re-reads on foreground. Writing "refused" down here would
        // be inventing an answer the user has not given.
        done(NO, nil);
        return;
      }
      remember_access(DshHomeKitRememberedRefused);
      done(NO, (status & HMHomeManagerAuthorizationStatusRestricted) != 0 ? kRestrictedMessage
                                                                          : kDeniedMessage);
    }];
  });
}

void dsh_native_homekit(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"list"]) { list_homes(reply); return; }
  if ([op isEqualToString:@"get"]) { get_accessory(args, reply); return; }
  if ([op isEqualToString:@"set"]) { set_characteristic(args, reply); return; }
  if ([op isEqualToString:@"scenes"]) { list_scenes(reply); return; }
  if ([op isEqualToString:@"trigger"]) { trigger_scene(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"homekit has no operation '%@'", op]);
}
