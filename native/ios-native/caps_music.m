// music: search the user's own music library, and drive the Music app's player.
//
// **The library, not the catalogue.** `MPMediaQuery` answers from what is in the
// user's library — what they bought, synced, or added from Apple Music — and
// from nothing else. Searching the Apple Music catalogue is MusicKit, which is
// Swift-only and needs its own app service and a developer token; that is a
// different capability and it is not this one. So "play any song" is a promise
// this file cannot keep, and the tool description says so before a model makes it.
//
// **Why the system player.** `systemMusicPlayer` is the Music app's own player:
// "what is playing" and "skip this" are then about what the user is actually
// listening to, and what `play` starts carries on after this app is suspended.
// The price is that `play` replaces the queue they had in Music, and that is
// state of theirs outside this app — which is why play, pause, next and previous
// are `writeOps` and obey the write policy, though nothing in the library itself
// is ever changed.
//
// **Persistent ids are 64-bit.** They routinely exceed 2^53, so as a JSON number
// one would come back from JS rounded to a neighbouring id that either does not
// exist or — worse — does. They cross as decimal strings in both directions, and
// a number is refused rather than converted.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import <MediaPlayer/MediaPlayer.h>

/// A common word matches thousands of titles and the reply crosses into JS as
/// one JSON string. These bound the size of the reply, not which matches are
/// worth seeing, so `total` and `truncated` always say what was left out (§4.5).
static const NSUInteger kDefaultSearchLimit = 25;
static const NSUInteger kMaxSearchLimit = 100;
static const NSUInteger kMaxPlaylists = 200;

/// Each id in `songs` is its own library lookup. Past this many the caller
/// means an album or a playlist, and those are one lookup each.
static const NSUInteger kMaxQueuedSongs = 200;

/// How long `play` waits for the Music app to say the queue is ready.
///
/// `prepareToPlayWithCompletionHandler:` answers from another process, and
/// there are cases where it does not answer at all: the Simulator has no Music
/// app behind the player, and a device whose user deleted Music is in the same
/// position. Without a deadline that is a Promise that never settles (§4.3.2).
/// Long enough for a song that is not downloaded to start buffering on a poor
/// connection, short enough that an agent is not left waiting on a player that
/// is not there.
static const NSTimeInterval kPrepareTimeout = 20;

static NSString *const kDeniedMessage =
    @"music library access is off for this app. The user can turn it on in Settings > Privacy & "
     "Security > Media & Apple Music. iOS only asks once, so it cannot be requested again from here";

/// `Restricted` is not this user saying no: Screen Time or a management profile
/// has closed the media library to apps, and no switch in this app changes that.
static NSString *const kRestrictedMessage =
    @"the music library is restricted on this device, most likely by Screen Time or a management "
     "profile. Nothing was read or played, and the app cannot lift that restriction";

/// Names the screen's place rather than its title: this file is not translated
/// and the screen is, so a quoted title would drift from the one on display.
static NSString *const kNotEnabledMessage =
    @"the user has not switched music access on for this app yet. Nothing was read or played. Tell "
     "them they can turn it on themselves under Device capabilities, which is in the app's "
     "sidebar — only they can grant it, and iOS asks once per app, so the app will not ask on its own.";

static NSString *const kPrepareTimeoutMessage =
    @"the Music app did not report the queue ready within 20 seconds, so this app stopped waiting "
     "and did not start playback. The queue in Music was already replaced with the new selection. "
     "The usual causes are songs that are not downloaded on a slow or absent connection, or the "
     "Music app not being installed. `now` shows what Music is doing";

/// A library query is synchronous and goes to the media database; on a library
/// of tens of thousands of songs that is long enough to matter. Neither Node's
/// thread nor the main thread is a place to wait for it.
static dispatch_queue_t music_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.music",
                                  dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

#pragma mark - Authorisation

/// nil when the library may be read, otherwise the sentence to refuse with.
/// Never prompts: `requestAuthorization:` *is* the prompt, the user gets it once
/// per install, and spending it belongs to them on the capability screen (§5.5).
///
/// Every operation goes through this, the player ones included. The now-playing
/// item is a row of the same library, and a player that answered while the
/// library refused would be a way to read it one song at a time.
static NSString *authorization_refusal(void) {
  switch (MPMediaLibrary.authorizationStatus) {
    case MPMediaLibraryAuthorizationStatusAuthorized:
      return nil;
    case MPMediaLibraryAuthorizationStatusDenied:
      return kDeniedMessage;
    case MPMediaLibraryAuthorizationStatusRestricted:
      return kRestrictedMessage;
    case MPMediaLibraryAuthorizationStatusNotDetermined:
    default:
      return kNotEnabledMessage;
  }
}

void DshMusicGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  if (MPMediaLibrary.authorizationStatus != MPMediaLibraryAuthorizationStatusNotDetermined) {
    // Already answered. iOS will not ask again, so report the standing answer
    // instead of raising a dialog that will not appear.
    NSString *refusal = authorization_refusal();
    done(refusal == nil, refusal);
    return;
  }
  // Without NSAppleMusicUsageDescription in Info.plist this call does not fail,
  // it kills the app. The key is part of this capability, not an extra.
  dsh_native_on_main(^{
    [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus chosen) {
      (void)chosen;
      NSString *refusal = authorization_refusal();
      done(refusal == nil, refusal);
    }];
  });
}

#pragma mark - Ids

static NSString *id_string(MPMediaEntityPersistentID persistentID) {
  return [NSString stringWithFormat:@"%llu", (unsigned long long)persistentID];
}

/// The id a caller sent back, or nil when it is not a decimal string that fits
/// 64 bits. A JSON number is refused on purpose even though it could be read:
/// by the time it is an NSNumber it has been through a double, and an id that
/// lost its low bits there still looks like an id.
static NSNumber *parse_id(id value) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *string = value;
  if (string.length == 0 || string.length > 20) return nil;
  NSCharacterSet *notDigits =
    [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
  if ([string rangeOfCharacterFromSet:notDigits].location != NSNotFound) return nil;
  errno = 0;
  unsigned long long parsed = strtoull(string.UTF8String, NULL, 10);
  if (errno == ERANGE) return nil;
  return @(parsed);
}

#pragma mark - The four kinds

static NSArray<NSString *> *kinds(void) {
  return @[@"song", @"album", @"artist", @"playlist"];
}

static MPMediaQuery *query_for_kind(NSString *kind) {
  if ([kind isEqualToString:@"album"]) return [MPMediaQuery albumsQuery];
  if ([kind isEqualToString:@"artist"]) return [MPMediaQuery artistsQuery];
  if ([kind isEqualToString:@"playlist"]) return [MPMediaQuery playlistsQuery];
  return [MPMediaQuery songsQuery];
}

/// The property `search` compares the caller's text against: each kind's own
/// name and nothing else. One field per kind is the framework's shape — a
/// predicate takes one property, and predicates only AND together — so "title
/// or artist" would be two queries merged by an order of our choosing (§4.5).
static NSString *name_property(NSString *kind) {
  if ([kind isEqualToString:@"album"]) return MPMediaItemPropertyAlbumTitle;
  if ([kind isEqualToString:@"artist"]) return MPMediaItemPropertyArtist;
  if ([kind isEqualToString:@"playlist"]) return MPMediaPlaylistPropertyName;
  return MPMediaItemPropertyTitle;
}

static NSString *id_property(NSString *kind) {
  if ([kind isEqualToString:@"album"]) return MPMediaItemPropertyAlbumPersistentID;
  if ([kind isEqualToString:@"artist"]) return MPMediaItemPropertyArtistPersistentID;
  if ([kind isEqualToString:@"playlist"]) return MPMediaPlaylistPropertyPersistentID;
  return MPMediaItemPropertyPersistentID;
}

static NSDictionary *song_json(MPMediaItem *item) {
  return @{
    @"id": id_string(item.persistentID),
    @"title": item.title ?: @"",
    @"artist": item.artist ?: @"",
    @"album": item.albumTitle ?: @"",
    @"duration": @(item.playbackDuration),
    // In the library but not on the phone. It plays only with a connection, and
    // a caller about to promise music on a flight needs to see that first.
    @"cloud": @(item.cloudItem),
  };
}

/// An album or an artist is not a record in MediaPlayer, only a grouping of
/// songs, so its id and name are read off the group's representative item.
/// A playlist is a record and carries its own.
static NSDictionary *collection_json(NSString *kind, MPMediaItemCollection *collection) {
  MPMediaItem *item = collection.representativeItem;
  if ([kind isEqualToString:@"album"]) {
    return @{
      @"id": id_string(item.albumPersistentID),
      @"title": item.albumTitle ?: @"",
      // Two albums called "Greatest Hits" are told apart by this and by nothing
      // else in the reply.
      @"artist": item.albumArtist ?: item.artist ?: @"",
      @"count": @(collection.count),
    };
  }
  if ([kind isEqualToString:@"artist"]) {
    return @{
      @"id": id_string(item.artistPersistentID),
      @"name": item.artist ?: @"",
      @"count": @(collection.count),
    };
  }
  MPMediaPlaylist *playlist = (MPMediaPlaylist *)collection;
  return @{
    @"id": id_string(playlist.persistentID),
    @"name": playlist.name ?: @"",
    @"count": @(playlist.count),
  };
}

#pragma mark - Reading the library

static void search_library(NSDictionary *args, DshNativeReply reply) {
  NSString *needle = args[@"query"];
  if (![needle isKindOfClass:NSString.class] || needle.length == 0) {
    reply(nil, @"search needs 'query', the text to look for");
    return;
  }
  NSString *kind = args[@"kind"] ?: @"song";
  if (![kind isKindOfClass:NSString.class] || ![kinds() containsObject:kind]) {
    reply(nil, @"'kind' must be one of song, album, artist or playlist");
    return;
  }
  NSNumber *limit = args[@"limit"];
  NSUInteger wanted = kDefaultSearchLimit;
  if (limit != nil) {
    if (![limit isKindOfClass:NSNumber.class] || limit.integerValue < 1) {
      reply(nil, @"'limit' must be at least 1");
      return;
    }
    wanted = MIN((NSUInteger)limit.integerValue, kMaxSearchLimit);
  }
  NSString *refusal = authorization_refusal();
  if (refusal != nil) {
    reply(nil, refusal);
    return;
  }

  dispatch_async(music_queue(), ^{
    MPMediaQuery *query = query_for_kind(kind);
    [query addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:needle
                                                              forProperty:name_property(kind)
                                                           comparisonType:MPMediaPredicateComparisonContains]];
    BOOL songs = [kind isEqualToString:@"song"];
    NSArray *found = songs ? (NSArray *)query.items : (NSArray *)query.collections;

    // The query's own order, cut at the limit and nothing more: no ranking by
    // how close the title is, no preferring downloaded songs. Which match was
    // meant is for the caller to say, with the whole list in front of it (§4.5).
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:MIN(found.count, wanted)];
    for (NSUInteger i = 0; i < found.count && results.count < wanted; i++) {
      [results addObject:songs ? song_json(found[i]) : collection_json(kind, found[i])];
    }
    NSString *shown = needle.length > 40 ? [[needle substringToIndex:40] stringByAppendingString:@"…"] : needle;
    reply(@{
      @"kind": kind,
      @"results": results,
      @"total": @(found.count),
      // The (BOOL) cast is load-bearing: a C comparison has type int, so without
      // it the JSON carries 0/1 beside the neighbouring true/false.
      @"truncated": @((BOOL)(found.count > results.count)),
      // What was looked for and how many came back — never the titles. The audit
      // list is the user's view of what reached their library, not a copy of it.
      @"auditSummary": [NSString stringWithFormat:@"%@ · %lu", shown, (unsigned long)found.count],
    }, nil);
  });
}

static void list_playlists(DshNativeReply reply) {
  NSString *refusal = authorization_refusal();
  if (refusal != nil) {
    reply(nil, refusal);
    return;
  }
  dispatch_async(music_queue(), ^{
    // Everything the query returns, folders and empty playlists included. The
    // Music app nests and hides some of these; doing the same here would be
    // deciding which of the user's playlists count.
    NSArray<MPMediaItemCollection *> *found = [MPMediaQuery playlistsQuery].collections;
    NSMutableArray *playlists = [NSMutableArray arrayWithCapacity:MIN(found.count, kMaxPlaylists)];
    for (NSUInteger i = 0; i < found.count && playlists.count < kMaxPlaylists; i++) {
      [playlists addObject:collection_json(@"playlist", found[i])];
    }
    reply(@{
      @"playlists": playlists,
      @"total": @(found.count),
      @"truncated": @((BOOL)(found.count > playlists.count)),
      @"auditSummary": [NSString stringWithFormat:@"%lu", (unsigned long)found.count],
    }, nil);
  });
}

static NSString *state_name(MPMusicPlaybackState state) {
  switch (state) {
    case MPMusicPlaybackStatePlaying: return @"playing";
    case MPMusicPlaybackStatePaused: return @"paused";
    case MPMusicPlaybackStateInterrupted: return @"interrupted";
    case MPMusicPlaybackStateSeekingForward:
    case MPMusicPlaybackStateSeekingBackward: return @"seeking";
    case MPMusicPlaybackStateStopped:
    default: return @"stopped";
  }
}

static void now_playing(DshNativeReply reply) {
  NSString *refusal = authorization_refusal();
  if (refusal != nil) {
    reply(nil, refusal);
    return;
  }
  dsh_native_on_main(^{
    MPMusicPlayerController *player = MPMusicPlayerController.systemMusicPlayer;
    MPMediaItem *item = player.nowPlayingItem;
    id current = NSNull.null;
    if (item != nil) {
      NSMutableDictionary *json = [song_json(item) mutableCopy];
      // The player can answer NaN here when it has an item but no position
      // yet, and NSJSONSerialization raises on NaN rather than encoding it — an
      // unguarded read would turn "what is playing" into a crash.
      NSTimeInterval position = player.currentPlaybackTime;
      json[@"position"] = isfinite(position) ? @(position) : NSNull.null;
      current = json;
    }
    reply(@{
      @"state": state_name(player.playbackState),
      @"item": current,
      @"auditSummary": item.title ?: @"",
    }, nil);
  });
}

#pragma mark - Resolving what to play

/// What `play` is about to hand the player, resolved from the library before
/// anyone is asked to approve it — so the sheet and the audit line describe the
/// real playlist with its real name and length, not the caller's account of it.
@interface DshMusicQueue : NSObject
/// Exactly one of these two is set. An album or an artist is a query, so it
/// plays in the library's order for that grouping; a playlist or a list of
/// songs is a collection, because their order is the playlist's or the caller's.
@property(nonatomic, strong) MPMediaQuery *query;
@property(nonatomic, strong) MPMediaItemCollection *collection;
@property(nonatomic, copy) NSString *kind;
/// The album's, artist's or playlist's own name. nil for a list of songs.
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *firstTitle;
@property(nonatomic) NSUInteger count;
/// Shown verbatim in a translated app, so it holds only the user's own titles
/// and a count, never a sentence (§5.4).
@property(nonatomic, copy) NSString *summary;
@end

@implementation DshMusicQueue
@end

static DshMusicQueue *resolve_songs(NSArray *ids, NSString **error) {
  if (![ids isKindOfClass:NSArray.class] || ids.count == 0) {
    *error = @"'songs' must be a non-empty array of song ids, as `search` returned them";
    return nil;
  }
  if (ids.count > kMaxQueuedSongs) {
    *error = [NSString stringWithFormat:
              @"'songs' takes at most %lu ids at a time, and %lu were given, so nothing was played. "
               "For more than that, play the album or the playlist by its own id",
              (unsigned long)kMaxQueuedSongs, (unsigned long)ids.count];
    return nil;
  }
  NSMutableArray<MPMediaItem *> *items = [NSMutableArray arrayWithCapacity:ids.count];
  NSMutableArray<NSString *> *missing = [NSMutableArray array];
  for (id value in ids) {
    NSNumber *persistentID = parse_id(value);
    if (persistentID == nil) {
      *error = [NSString stringWithFormat:
                @"'%@' is not a song id, so nothing was played. Ids are long decimal numbers and "
                 "must be passed as strings exactly as `search` returned them — as a JSON number "
                 "they lose their last digits", value];
      return nil;
    }
    // No media-type filter: the id is exact, and whether the thing it names is
    // "music enough" to play is not this file's call.
    MPMediaQuery *query = [[MPMediaQuery alloc] initWithFilterPredicates:[NSSet setWithObject:
      [MPMediaPropertyPredicate predicateWithValue:persistentID forProperty:MPMediaItemPropertyPersistentID]]];
    MPMediaItem *item = query.items.firstObject;
    if (item == nil) {
      [missing addObject:value];
    } else {
      [items addObject:item];
    }
  }
  if (missing.count > 0) {
    // All or nothing. Playing the ones that resolved would start music that is
    // not what was asked for, and the caller would learn of the gap only if it
    // counted the queue afterwards.
    *error = [NSString stringWithFormat:
              @"no song in the library has id %@, so nothing was played — not the other songs "
               "either. Ids come from `search`; one from an earlier session can go stale when the "
               "library changes", [missing componentsJoinedByString:@", "]];
    return nil;
  }
  DshMusicQueue *queue = [DshMusicQueue new];
  queue.kind = @"songs";
  queue.collection = [MPMediaItemCollection collectionWithItems:items];
  queue.count = items.count;
  queue.firstTitle = items.firstObject.title ?: @"";
  queue.summary = items.count == 1
    ? [NSString stringWithFormat:@"%@ · %@", queue.firstTitle, items.firstObject.artist ?: @""]
    : [NSString stringWithFormat:@"%@ · %lu", queue.firstTitle, (unsigned long)items.count];
  return queue;
}

static DshMusicQueue *resolve_grouping(NSString *kind, id value, NSString **error) {
  NSNumber *persistentID = parse_id(value);
  if (persistentID == nil) {
    *error = [NSString stringWithFormat:
              @"'%@' must be the %@'s id, so nothing was played. Ids are long decimal numbers and "
               "must be passed as a string exactly as `search` returned them — as a JSON number "
               "they lose their last digits. A name is not accepted here: search for it first",
              kind, kind];
    return nil;
  }
  MPMediaQuery *query = query_for_kind(kind);
  [query addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:persistentID
                                                            forProperty:id_property(kind)]];
  MPMediaItemCollection *collection = query.collections.firstObject;
  if (collection == nil) {
    *error = [NSString stringWithFormat:
              @"no %@ in the library has id %@, so nothing was played. Ids come from `search`%@; "
               "one from an earlier session can go stale when the library changes",
              kind, value, [kind isEqualToString:@"playlist"] ? @" or `playlists`" : @""];
    return nil;
  }
  NSDictionary *described = collection_json(kind, collection);
  NSString *name = described[@"name"] ?: described[@"title"];
  if (collection.count == 0) {
    // Real for playlists: an empty one, or one whose songs were removed from
    // the library. Handing the player an empty queue stops whatever was playing
    // and starts nothing, which is not what "play" was asked to do.
    *error = [NSString stringWithFormat:
              @"the %@ '%@' has no songs in the library, so nothing was played", kind, name];
    return nil;
  }

  DshMusicQueue *queue = [DshMusicQueue new];
  queue.kind = kind;
  queue.name = name;
  queue.count = collection.count;
  queue.firstTitle = collection.items.firstObject.title ?: @"";
  if ([kind isEqualToString:@"playlist"]) {
    queue.collection = collection;
  } else {
    queue.query = query;
  }
  queue.summary = [kind isEqualToString:@"album"]
    ? [NSString stringWithFormat:@"%@ · %@ · %lu", name, described[@"artist"], (unsigned long)collection.count]
    : [NSString stringWithFormat:@"%@ · %lu", name, (unsigned long)collection.count];
  return queue;
}

#pragma mark - Driving the player

static void apply_shuffle(MPMusicPlayerController *player, NSNumber *shuffle) {
  // Absent means "as the user left it": the shuffle switch in Music is theirs,
  // and a `play` that did not mention it has no business turning it off.
  if (shuffle == nil) return;
  player.shuffleMode = shuffle.boolValue ? MPMusicShuffleModeSongs : MPMusicShuffleModeOff;
}

/// Replace the Music app's queue with `queue` and start it.
static void start_queue(DshMusicQueue *queue, NSNumber *shuffle, DshNativeReply reply) {
  DshNativeConfirmWrite(@"music", @"play", queue.summary, NO, ^(BOOL confirmed, NSString *refusal) {
    // The player is main-thread only, and so is `settled` below: the completion
    // and the deadline both land here, so neither needs a lock to see the other.
    dsh_native_on_main(^{
      // Two different outcomes, never merged: `refusal` is the write policy
      // saying no, `confirmed == NO` is the user tapping Cancel on the sheet,
      // which is a normal answer and not a failure (§4.3.3).
      if (refusal != nil) {
        reply(nil, refusal);
        return;
      }
      if (!confirmed) {
        reply(@{@"action": DshNativeActionCancelled, @"played": @NO}, nil);
        return;
      }

      MPMusicPlayerController *player = MPMusicPlayerController.systemMusicPlayer;
      if (queue.collection != nil) {
        [player setQueueWithItemCollection:queue.collection];
      } else {
        [player setQueueWithQuery:queue.query];
      }
      apply_shuffle(player, shuffle);

      __block BOOL settled = NO;
      [player prepareToPlayWithCompletionHandler:^(NSError *prepareError) {
        dsh_native_on_main(^{
          // After the deadline has answered, a late "ready" must not start music
          // behind a reply that already said playback was not started.
          if (settled) return;
          settled = YES;
          if (prepareError != nil) {
            // MediaPlayer's own description is often just a domain and a number,
            // so it is forwarded inside a sentence rather than as the sentence.
            reply(nil, [NSString stringWithFormat:
                        @"the Music app could not get that ready to play, so nothing was started "
                         "(the queue in Music was already replaced). It reported: %@. Songs marked "
                         "`cloud` need a connection, and Apple Music items need an active subscription",
                        prepareError.localizedDescription ?: @"no reason given"]);
            return;
          }
          [player play];
          NSMutableDictionary *result = [@{
            @"action": DshNativeActionSaved,
            @"played": @YES,
            @"kind": queue.kind,
            @"count": @(queue.count),
            @"auditSummary": queue.summary,
          } mutableCopy];
          if (queue.name != nil) result[@"name"] = queue.name;
          // Under shuffle the player picks the first song, and it does not say
          // which until it is playing. The first in queue order would be a guess
          // presented as a fact, so it is left out and `now` answers instead.
          BOOL shuffled = player.shuffleMode != MPMusicShuffleModeOff;
          result[@"shuffle"] = @(shuffled);
          if (!shuffled) result[@"first"] = queue.firstTitle;
          reply(result, nil);
        });
      }];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPrepareTimeout * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        if (settled) return;
        settled = YES;
        reply(nil, kPrepareTimeoutMessage);
      });
    });
  });
}

/// The four commands that act on whatever Music already has: resume, pause,
/// next, previous. `flag` is the result key that says whether it was sent, and
/// `itemKey` names the song that was current WHEN it was sent — for a skip that
/// is the song skipped from, not the one now playing, hence a different key.
///
/// The song after a skip is deliberately not reported: the player answers from
/// another process and `nowPlayingItem` still names the old song for a moment
/// afterwards, so reading it here would report the wrong one with confidence.
static void send_command(NSString *op, NSString *flag, NSString *itemKey, DshNativeReply reply,
                         void (^command)(MPMusicPlayerController *player)) {
  dsh_native_on_main(^{
    MPMusicPlayerController *player = MPMusicPlayerController.systemMusicPlayer;
    MPMediaItem *current = player.nowPlayingItem;
    // The current song's own title, or nothing: with an empty queue there is no
    // record to describe, and the sheet's question still names the action.
    NSString *summary = current.title ?: @"";
    DshNativeConfirmWrite(@"music", op, summary, NO, ^(BOOL confirmed, NSString *refusal) {
      dsh_native_on_main(^{
        if (refusal != nil) {
          reply(nil, refusal);
          return;
        }
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, flag: @NO}, nil);
          return;
        }
        command(player);
        reply(@{@"action": DshNativeActionSaved, flag: @YES,
                itemKey: current != nil ? song_json(current) : NSNull.null,
                @"auditSummary": summary}, nil);
      });
    });
  });
}

static void play(NSDictionary *args, DshNativeReply reply) {
  NSNumber *shuffle = args[@"shuffle"];
  if (shuffle != nil && ![shuffle isKindOfClass:NSNumber.class]) {
    reply(nil, @"'shuffle' must be true or false");
    return;
  }
  NSArray<NSString *> *targets = @[@"songs", @"album", @"artist", @"playlist"];
  NSString *target = nil;
  for (NSString *key in targets) {
    if (args[key] == nil || args[key] == NSNull.null) continue;
    if (target != nil) {
      // Not resolved in some order of preference: two targets is a request this
      // file cannot read, and playing either would be choosing for the caller.
      reply(nil, [NSString stringWithFormat:
                  @"play takes one of 'songs', 'album', 'artist' or 'playlist', and both '%@' and "
                   "'%@' were given, so nothing was played", target, key]);
      return;
    }
    target = key;
  }
  NSString *refusal = authorization_refusal();
  if (refusal != nil) {
    reply(nil, refusal);
    return;
  }

  if (target == nil) {
    // No target is "carry on with what was there". Whether Music has anything
    // to carry on with is not checked: its queue may hold something this app
    // cannot see as a library item, and refusing on our reading of an empty
    // `nowPlayingItem` would block exactly that case. The reply carries the item
    // (or null) so the caller can tell which it was.
    send_command(@"play", @"played", @"item", ^(NSDictionary *result, NSString *error) {
      if (result == nil || ![result[@"played"] boolValue]) {
        reply(result, error);
        return;
      }
      NSMutableDictionary *resumed = [result mutableCopy];
      resumed[@"kind"] = @"resume";
      reply(resumed, nil);
    }, ^(MPMusicPlayerController *player) {
      apply_shuffle(player, shuffle);
      [player play];
    });
    return;
  }

  id value = args[target];
  dispatch_async(music_queue(), ^{
    NSString *error = nil;
    DshMusicQueue *queue = [target isEqualToString:@"songs"]
      ? resolve_songs(value, &error)
      : resolve_grouping(target, value, &error);
    if (queue == nil) {
      reply(nil, error);
      return;
    }
    start_queue(queue, shuffle, reply);
  });
}

static void transport(NSString *op, DshNativeReply reply) {
  NSString *refusal = authorization_refusal();
  if (refusal != nil) {
    reply(nil, refusal);
    return;
  }
  if ([op isEqualToString:@"pause"]) {
    send_command(op, @"paused", @"item", reply, ^(MPMusicPlayerController *player) { [player pause]; });
  } else if ([op isEqualToString:@"next"]) {
    send_command(op, @"skipped", @"from", reply, ^(MPMusicPlayerController *player) { [player skipToNextItem]; });
  } else {
    // Not `skipToBeginning`: "previous" asked for the song before this one, and
    // restarting the current one is a different request with the same sound for
    // the first second.
    send_command(op, @"skipped", @"from", reply, ^(MPMusicPlayerController *player) { [player skipToPreviousItem]; });
  }
}

void dsh_native_music(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"search"]) { search_library(args, reply); return; }
  if ([op isEqualToString:@"playlists"]) { list_playlists(reply); return; }
  if ([op isEqualToString:@"now"]) { now_playing(reply); return; }
  if ([op isEqualToString:@"play"]) { play(args, reply); return; }
  if ([op isEqualToString:@"pause"] || [op isEqualToString:@"next"] || [op isEqualToString:@"previous"]) {
    transport(op, reply);
    return;
  }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"music has no operation '%@'", op]);
}
