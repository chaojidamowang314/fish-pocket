// files: take in a file the user picks from the Files app, and hand a file the
// engine made back out to a place the user chooses.
//
// **The picker is the permission.** The document picker runs in its own process
// and this app sees nothing of the user's files until they tap one — and then
// sees exactly that one. So there is no system permission here, no switch on the
// capability screen and no write policy: each call already stops in front of the
// user on Apple's sheet, and an agent cannot press its buttons. A second gate of
// ours on top would ask the same question twice. For the same reason nothing
// here is a `writeOps` entry — `export` writes only where the user points it,
// in the picker, at that moment.
//
// **Copy in, copy out — never in place.** `pick` lands a copy inside the engine's
// filesystem and `export` leaves the engine's original where it was. Both are
// `asCopy:YES`, and both are load-bearing:
//
// - Opening without it hands back the original under a security scope that only
//   this process holds, at a path outside the engine's filesystem view. The
//   engine could neither name that path nor keep the access across a restart.
// - Exporting without it MOVES the file: the agent's own copy would vanish from
//   the workspace the moment the user saved it.
//
// What that rules out is granting a live folder — a place in iCloud Drive the
// engine reads and writes directly. That needs a security-scoped bookmark and a
// mount in the engine's filesystem view (`native/root`), which has no such API
// today. Until it does, an edit to a picked file stays in the engine, and getting
// it back to the user is a second, explicit `export`.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "root.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// Where picked files land, as an engine path. Beside `photos`' export
/// directory and for the same reasons: the agent did not put these here, and
/// what the native side hands the engine as files belongs in one place.
static NSString *const kPickDirectory = @"/home/dsh/.ios/files";

/// A picked file can be a video of several gigabytes and it is moved on the
/// filesystem, which neither the main thread nor Node's is a place to wait for.
static dispatch_queue_t files_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.files",
                                  dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

#pragma mark - The picker on screen

/// The delegate of the one picker that is up, and the record of whether it has
/// answered.
///
/// `answered` is set the moment a delegate method is entered, not when the work
/// it starts has finished: after a pick the files are still being moved when the
/// bridge reports the picker gone, and "gone, and nobody answered" must mean the
/// remote view died — not "the user chose, and we are still busy". Main thread only.
@interface DshFilesSession : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^picked)(NSArray<NSURL *> *urls);
@property (nonatomic, copy) void (^cancelled)(void);
@property (nonatomic) BOOL answered;
@end

@implementation DshFilesSession

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (self.answered) return;
  self.answered = YES;
  self.picked(urls);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  if (self.answered) return;
  self.answered = YES;
  self.cancelled();
}

@end

/// The picker's `delegate` is weak, so something has to own the session while
/// the picker is up, and this is it. It doubles as "a picker is up". Main thread only.
static DshFilesSession *sSession;

/// Put the picker `build` makes in front of the user and route its one answer.
///
/// Three things can end it and exactly one of them settles `reply`: a delegate
/// method (through `picked` / `cancelled`), the bridge failing to show it, or the
/// bridge reporting it gone with the delegate never called. The last is not a
/// cancel and is not reported as one — the picker is a remote view that can be
/// torn down from outside, and "the user said no" is a different fact from "the
/// sheet went away" (§4.3.2).
static void show_picker(UIDocumentPickerViewController *(^build)(void),
                        void (^picked)(NSArray<NSURL *> *urls),
                        void (^cancelled)(void),
                        DshNativeReply reply) {
  // UIKit objects are made on the main thread, which is why the picker arrives
  // as a block rather than as an object built on Node's.
  dsh_native_on_main(^{
    if (sSession != nil) {
      // UIKit would refuse to stack a second one anyway, and silently. Worse
      // would be succeeding: two pickers in a row with nothing on them to say
      // which request each belongs to.
      reply(nil, @"a file picker is already open and waiting for the user. Nothing new was shown; "
                  "wait for that one to finish before asking again.");
      return;
    }
    id<DshNativeBridging> bridge = DshNativeCurrentBridge();
    if (bridge == nil) {
      reply(nil, @"the app cannot show the file picker right now, so nothing was picked or saved");
      return;
    }

    DshFilesSession *session = [DshFilesSession new];
    session.picked = picked;
    session.cancelled = cancelled;
    UIDocumentPickerViewController *picker = build();
    picker.delegate = session;
    // Before presenting, not after: presentation is asynchronous, and a second
    // call arriving in that gap must find the slot taken.
    sSession = session;

    [bridge presentSystemController:picker failure:^(NSString *error) {
      // Never reached the screen, so the delegate cannot have been called.
      sSession = nil;
      reply(nil, error);
    } gone:^{
      if (!session.answered) {
        session.answered = YES;
        reply(nil, @"the file picker closed before the user chose anything");
      }
      sSession = nil;
    }];
  });
}

#pragma mark - pick

/// The type one entry of `types` names, or nil when this device knows none.
///
/// Callers write either a uniform type identifier or a filename extension, and
/// one string is never both: identifiers are dotted (`public.image`), and UTType
/// answers nil for an "extension" with a dot in it. So trying one and then the
/// other is a lookup, not a guess between two readings.
///
/// A *dynamic* type counts as unknown, deliberately. UTType answers any
/// well-formed extension it has never heard of with a made-up `dyn.…` type
/// rather than with nil — so "image" or "spreadsheet", written by a caller who
/// meant a kind of file, would come back as a real-looking type that matches
/// only files ending in `.image`. The picker would then open with every file
/// greyed out and nothing on screen to say why. An error the caller can read
/// and correct is better than a sheet the user cannot use.
static UTType *resolve_type(NSString *name) {
  UTType *type = [UTType typeWithIdentifier:name];
  if (type == nil) {
    // ".pdf" is how an extension is usually written down; the dot is not part of it.
    NSString *extension = [name hasPrefix:@"."] ? [name substringFromIndex:1] : name;
    type = [UTType typeWithFilenameExtension:extension];
  }
  return type.isDeclared ? type : nil;
}

/// A directory for one pick, created, as a real path.
///
/// One per pick, named by the second it happened, so that every file keeps the
/// name the user knows it by and a later pick of another `report.pdf` lands
/// beside the first instead of on top of it.
///
/// Derived from the engine path rather than from the app container for the
/// reason caps_photos.m gives: the file is written through the real path, but
/// the caller can only use the engine one.
static BOOL prepare_pick_directory(NSString **realDirectory, NSString **error) {
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSDateFormatter new];
    // Pinned, or the name follows the user's settings: a Buddhist or Japanese
    // calendar changes the year, and the 12-hour setting rewrites `HH`.
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
  });
  NSString *directory =
    [kPickDirectory stringByAppendingPathComponent:[formatter stringFromDate:NSDate.date]];

  char real[4096];
  if (dsh_root_real(directory.fileSystemRepresentation, real, sizeof real) != 0) {
    *error = @"the engine's workspace is not available, so there is nowhere to put the file";
    return NO;
  }
  NSError *createError = nil;
  if (![NSFileManager.defaultManager createDirectoryAtPath:@(real)
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&createError]) {
    *error = createError.localizedDescription ?: @"the directory for picked files could not be created";
    return NO;
  }
  *realDirectory = @(real);
  return YES;
}

/// The engine path for a file just placed — round-tripped rather than assumed,
/// as in caps_photos.m: a path the engine cannot open again is not handed back.
static NSString *engine_path(NSString *realFile) {
  char virtual[4096], back[4096];
  const char *real = realFile.fileSystemRepresentation;
  if (dsh_root_virtual(real, virtual, sizeof virtual) != 0) return nil;
  if (dsh_root_real(virtual, back, sizeof back) != 0) return nil;
  if (strcmp(back, real) != 0) return nil;
  return @(virtual);
}

/// Bring what the user picked into the engine's filesystem and settle `reply`.
///
/// The URLs are already this app's own: with `asCopy:YES` the picker downloads
/// the file if it has to and leaves a copy in the app's temporary directory
/// before it calls the delegate. That is why there is no
/// `startAccessingSecurityScopedResource` here — it guards an original outside
/// the container, and these are not originals. It is also why this MOVES rather
/// than copies: the copy has been made once already, a second one would double
/// the disk a large video needs, and the first would sit in the temporary
/// directory until the app next quits.
///
/// A move never replaces a file that is already there, so a name that collides
/// is reported in `failed` with the system's reason rather than overwriting.
static void bring_in(NSArray<NSURL *> *urls, DshNativeReply reply) {
  NSString *realDirectory = nil, *prepareError = nil;
  if (!prepare_pick_directory(&realDirectory, &prepareError)) {
    reply(nil, prepareError);
    return;
  }

  NSMutableArray *files = [NSMutableArray array];
  NSMutableArray *failed = [NSMutableArray array];
  for (NSURL *url in urls) {
    NSString *name = url.lastPathComponent;
    NSURL *landed = [NSURL fileURLWithPath:[realDirectory stringByAppendingPathComponent:name]];
    NSError *moveError = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:url toURL:landed error:&moveError]) {
      [failed addObject:@{@"name": name,
                          @"error": moveError.localizedDescription ?: @"it could not be moved into place"}];
      continue;
    }
    NSString *path = engine_path(landed.path);
    if (path == nil) {
      [failed addObject:@{@"name": name,
                          @"error": @"it did not land at a path the engine can open"}];
      continue;
    }

    NSDictionary *values = [landed resourceValuesForKeys:@[NSURLContentTypeKey, NSURLFileSizeKey,
                                                           NSURLIsDirectoryKey]
                                                   error:NULL];
    UTType *type = values[NSURLContentTypeKey];
    NSMutableDictionary *file = [@{@"path": path, @"name": name} mutableCopy];
    // The system's own identifier, as it is. For an extension iOS has never
    // heard of this is a `dyn.…` string, and that is still the true answer.
    file[@"type"] = type.identifier;
    // A document can be a package — a Pages file, an .rtfd — and a package is a
    // directory. Its own size on disk says nothing about its contents, so it is
    // flagged instead of being given a byte count that looks like one.
    if ([values[NSURLIsDirectoryKey] boolValue]) {
      file[@"directory"] = @YES;
    } else {
      file[@"bytes"] = values[NSURLFileSizeKey];
    }
    [files addObject:file];
  }

  if (files.count == 0) {
    // Nothing usable came out of it, so this is an error and not a result: an
    // empty `files` beside `cancelled: false` reads too much like success.
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    for (NSDictionary *failure in failed) {
      [reasons addObject:[NSString stringWithFormat:@"'%@': %@", failure[@"name"], failure[@"error"]]];
    }
    reply(nil, [NSString stringWithFormat:
                @"the user chose %lu file(s), but none could be copied into the workspace — %@",
                (unsigned long)urls.count, [reasons componentsJoinedByString:@"; "]]);
    return;
  }
  NSMutableDictionary *result = [@{@"files": files, @"cancelled": @NO} mutableCopy];
  // Some arrived and some did not. The ones that arrived are real and usable,
  // so they are returned — with the others named beside them, never dropped.
  if (failed.count > 0) result[@"failed"] = failed;
  reply(result, nil);
}

static void pick_files(NSDictionary *args, DshNativeReply reply) {
  NSArray *names = args[@"types"];
  if (names != nil && ![names isKindOfClass:NSArray.class]) {
    reply(nil, @"'types' must be a list of type identifiers or filename extensions");
    return;
  }
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  for (NSString *name in names) {
    UTType *type = [name isKindOfClass:NSString.class] ? resolve_type(name) : nil;
    if (type == nil) {
      reply(nil, [NSString stringWithFormat:
                  @"'%@' is not a file type this device knows, so no picker was shown. Pass a uniform "
                   "type identifier such as public.image or com.adobe.pdf, or a filename extension "
                   "such as pdf — or leave 'types' out and the user can pick any file.", name]);
      return;
    }
    [types addObject:type];
  }
  // The initializer has no "anything" spelling of its own, so absent `types`
  // this names the root of the type tree, which every file conforms to.
  if (types.count == 0) [types addObject:UTTypeItem];
  NSNumber *multiple = args[@"multiple"];
  BOOL allowsMultiple = [multiple isKindOfClass:NSNumber.class] && multiple.boolValue;

  show_picker(^{
    UIDocumentPickerViewController *picker =
      [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.allowsMultipleSelection = allowsMultiple;
    return picker;
  }, ^(NSArray<NSURL *> *urls) {
    dispatch_async(files_queue(), ^{ bring_in(urls, reply); });
  }, ^{
    // Closing the picker is an answer, not a failure.
    reply(@{@"files": @[], @"cancelled": @YES}, nil);
  }, reply);
}

#pragma mark - export

static void export_files(NSDictionary *args, DshNativeReply reply) {
  NSArray *paths = args[@"paths"];
  if (![paths isKindOfClass:NSArray.class] || paths.count == 0) {
    reply(nil, @"export needs 'paths': the files or directories to hand to the user");
    return;
  }
  // Every path is checked before anything is shown. The picker itself would
  // accept a file that is not there and fail after the user had already chosen
  // where to put it — a question asked for nothing.
  NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:paths.count];
  for (NSString *path in paths) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) {
      reply(nil, @"every entry in 'paths' must be a path to a file or directory");
      return;
    }
    char real[4096];
    if (dsh_root_real(path.fileSystemRepresentation, real, sizeof real) != 0) {
      reply(nil, [NSString stringWithFormat:@"'%@' is not a path this app can reach", path]);
      return;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:@(real)]) {
      reply(nil, [NSString stringWithFormat:
                  @"'%@' does not exist, so no picker was shown and nothing was saved", path]);
      return;
    }
    // A relative path is the workspace's, as it is for `vision`. Made absolute
    // here because the URL crosses into the picker's process, which does not
    // share this one's working directory.
    [urls addObject:[NSURL fileURLWithPath:@(real)].absoluteURL];
  }

  show_picker(^{
    return [[UIDocumentPickerViewController alloc] initForExportingURLs:urls asCopy:YES];
  }, ^(NSArray<NSURL *> *saved) {
    // The picker's own count of what it wrote, not the number we asked for.
    reply(@{@"saved": @YES, @"count": @(saved.count)}, nil);
  }, ^{
    reply(@{@"saved": @NO}, nil);
  }, reply);
}

void dsh_native_files(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"pick"]) { pick_files(args, reply); return; }
  if ([op isEqualToString:@"export"]) { export_files(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"files has no operation '%@'", op]);
}
