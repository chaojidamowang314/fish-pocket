// compose: put a prefilled email or text message in front of the user, who
// sends it — or does not.
//
// **Nothing in this file sends anything.** It fills in Apple's own compose
// sheet and waits. The Send button is Apple's, it is drawn by another process,
// and an agent cannot press it; that is the same guarantee the event editor
// gives the calendar (DshNativeBridge.h), and it is the whole design here. It
// is also why this capability has no permission, no write policy and no call to
// `DshNativeConfirmWrite`: the user's tap on Send *is* the confirmation, and a
// second sheet of ours in front of Apple's would only be asking twice.
//
// It follows that the answer is never ours to predict. "cancelled" and "saved"
// (a draft) are as normal as "sent", and "sent" itself only means the message
// was handed to Mail's outbox or to Messages — not that it was delivered.
//
// **Why there is no `mailto:` fallback** when Mail has no account. A `mailto:`
// link leaves the app and reports nothing back, so the reply could never say
// whether the user sent it — and the caller would be left guessing, which with
// an email means claiming it was sent. It also cannot carry an attachment. The
// `open` capability already opens `mailto:` for a caller that wants exactly
// that and knows what it gives up.
//
// **Both sheets are remote views** — the form on screen lives in Mail's or
// Messages' process, not ours. Such a view can be torn down without its
// delegate ever hearing about it, and then the engine's Promise would hang for
// good (docs/native-services.md §4.3.2, where the event editor did precisely
// this). So the bridge reports when the sheet is no longer on screen, whatever
// the reason, and every session here ends there if it has not ended already.
//
// Attachments are paths, and a path is the one argument that can point
// somewhere the caller was never meant to reach. Like vision and transcribe,
// every one goes through `dsh_root_real` — the engine's own filesystem view —
// so this attaches exactly the files a plugin could already open with `fs`.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "root.h"
#import <MessageUI/MessageUI.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - One sheet, one answer

/// One compose sheet from the moment it is handed to the bridge until it is off
/// the screen. It is the sheet's delegate, and it owns the reply.
@interface DshComposeSession : NSObject <MFMailComposeViewControllerDelegate,
                                         MFMessageComposeViewControllerDelegate>
- (instancetype)initWithReply:(DshNativeReply)reply;
/// The sheet is off the screen, or never reached it (`presentError`). Settles
/// the reply unless that already happened, and frees the slot for the next sheet.
- (void)closeWithPresentError:(NSString *)presentError;
@end

/// The session whose sheet is up, or nil. Both compose controllers hold their
/// delegate weakly, so this is also what keeps the delegate alive while the
/// user is typing. Main thread only.
static DshComposeSession *sSession;

@implementation DshComposeSession {
  DshNativeReply _reply;   // nil once settled: the "exactly once" of this file
  BOOL _answered;          // the delegate heard from the sheet
  NSDictionary *_result;   // what it heard, when that was an outcome
  NSString *_failure;      // … or when the framework reported a failure
}

- (instancetype)initWithReply:(DshNativeReply)reply {
  if ((self = [super init])) _reply = [reply copy];
  return self;
}

- (void)closeWithPresentError:(NSString *)presentError {
  // Compared rather than cleared blindly: the bridge notices a sheet is gone by
  // polling, up to half a second after the fact, and by then the next call may
  // already have put its own session here.
  if (sSession == self) sSession = nil;

  DshNativeReply reply = _reply;
  if (reply == nil) return;
  _reply = nil;
  if (presentError != nil) {
    reply(nil, presentError);
  } else if (_answered) {
    reply(_result, _failure);
  } else {
    // Not "cancelled": the user did not choose this, the sheet went away under
    // them. The agent reads this out, and the two mean different things.
    reply(nil, @"the compose sheet closed before the user answered it; nothing was sent");
  }
}

/// Neither compose controller dismisses itself; a delegate that forgets leaves
/// the user stuck behind a sheet whose buttons no longer do anything.
///
/// The reply is settled once the sheet is actually down, not here, so that a
/// caller sending two messages in a row is not told "a compose sheet is already
/// open" about a sheet the user has just finished with and is watching slide
/// away. If the dismissal never completes, the bridge's `gone` settles it with
/// the outcome recorded here.
- (void)dismiss:(UIViewController *)controller {
  [controller dismissViewControllerAnimated:YES completion:^{
    [self closeWithPresentError:nil];
  }];
}

- (void)mailComposeController:(MFMailComposeViewController *)controller
          didFinishWithResult:(MFMailComposeResult)result
                        error:(NSError *)error {
  _answered = YES;
  switch (result) {
    case MFMailComposeResultSent: _result = @{@"result": @"sent"}; break;
    case MFMailComposeResultSaved: _result = @{@"result": @"saved"}; break;
    case MFMailComposeResultCancelled: _result = @{@"result": @"cancelled"}; break;
    case MFMailComposeResultFailed:
    default:
      _failure = [NSString stringWithFormat:@"Mail could not save or send the message: %@",
                  error.localizedDescription ?: @"it gave no reason"];
      break;
  }
  [self dismiss:controller];
}

- (void)messageComposeViewController:(MFMessageComposeViewController *)controller
                 didFinishWithResult:(MessageComposeResult)result {
  _answered = YES;
  switch (result) {
    case MessageComposeResultSent: _result = @{@"result": @"sent"}; break;
    case MessageComposeResultCancelled: _result = @{@"result": @"cancelled"}; break;
    case MessageComposeResultFailed:
    default:
      // Messages reports that it failed and never why.
      _failure = @"Messages could not send the message, and gave no reason. It was not sent.";
      break;
  }
  [self dismiss:controller];
}

@end

/// The bridge to present through, or nil after refusing. Main thread.
///
/// Asked before a controller is built, so that a call which cannot be shown
/// costs nothing and leaves nothing half-made.
static id<DshNativeBridging> bridge_for_sheet(DshNativeReply reply) {
  id<DshNativeBridging> bridge = DshNativeCurrentBridge();
  if (bridge == nil) {
    reply(nil, @"the app has no window to show the compose sheet in, so nothing was sent");
    return nil;
  }
  // Two sheets cannot be stacked, and a queue of them would have the user
  // answering a message they can no longer connect to anything they asked for.
  if (sSession != nil) {
    reply(nil, @"a compose sheet is already open; finish that one first");
    return nil;
  }
  return bridge;
}

/// Put `controller` up with `session` as the thing that ends it. Main thread.
static void present_sheet(id<DshNativeBridging> bridge, UIViewController *controller,
                          DshComposeSession *session) {
  sSession = session;
  // Exactly one of these runs. `gone` runs after an ordinary answer too; the
  // session has usually settled by then and only gives up its slot.
  [bridge presentSystemController:controller
                          failure:^(NSString *error) { [session closeWithPresentError:error]; }
                             gone:^{ [session closeWithPresentError:nil]; }];
}

#pragma mark - Arguments

/// An optional string. Absent is nil; anything else that is not a string is an
/// error, because a draft silently missing its body is worse than a refusal.
static NSString *optional_string(NSDictionary *args, NSString *key, NSString **error) {
  id value = args[key];
  if (value == nil) return nil;
  if (![value isKindOfClass:NSString.class]) {
    if (*error == nil) *error = [NSString stringWithFormat:@"'%@' must be a string", key];
    return nil;
  }
  return value;
}

/// An optional list of strings; absent is an empty list.
static NSArray<NSString *> *optional_strings(NSDictionary *args, NSString *key, NSString **error) {
  id value = args[key];
  if (value == nil) return @[];
  BOOL valid = [value isKindOfClass:NSArray.class];
  if (valid) {
    for (id item in (NSArray *)value) {
      if (![item isKindOfClass:NSString.class] || [(NSString *)item length] == 0) { valid = NO; break; }
    }
  }
  if (!valid) {
    if (*error == nil) {
      *error = [NSString stringWithFormat:@"'%@' must be an array of non-empty strings", key];
    }
    return @[];
  }
  return value;
}

/// The real files behind the engine paths in `paths`, in the same order, or nil
/// with a reason the agent can read.
///
/// Call this on the thread the handler was called on, not on the main thread: a
/// relative path is resolved against the calling thread's working directory in
/// the engine's view, and the main thread does not have one.
///
/// Everything is checked here, before any sheet exists, so that a bad path is a
/// refusal the caller can fix rather than a draft that turns up one file short.
static NSArray<NSURL *> *resolve_attachments(NSArray<NSString *> *paths, NSString **error) {
  NSMutableArray<NSURL *> *files = [NSMutableArray arrayWithCapacity:paths.count];
  for (NSString *path in paths) {
    char real[4096];
    if (dsh_root_real(path.fileSystemRepresentation, real, sizeof(real)) != 0) {
      // The same sentence vision and transcribe use for the same boundary.
      *error = [NSString stringWithFormat:@"'%@' is not a path this app can reach", path];
      return nil;
    }
    NSString *file = @(real);
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:file isDirectory:&directory]) {
      *error = [NSString stringWithFormat:@"'%@' could not be opened as a file to attach: nothing is there", path];
      return nil;
    }
    if (directory) {
      // Neither composer takes a folder, and zipping one would be this file
      // inventing an attachment the caller never named.
      *error = [NSString stringWithFormat:
                @"'%@' is a folder, and only files can be attached. Archive it first and attach the archive.", path];
      return nil;
    }
    if (![NSFileManager.defaultManager isReadableFileAtPath:file]) {
      *error = [NSString stringWithFormat:@"'%@' could not be opened as a file to attach: it is not readable", path];
      return nil;
    }
    [files addObject:[NSURL fileURLWithPath:file]];
  }
  return files;
}

/// "iPhone" or "iPad", so a refusal names the thing the user is holding.
static NSString *device_name(void) {
  return UIDevice.currentDevice.model;
}

#pragma mark - Mail

static void compose_mail(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSArray<NSString *> *to = optional_strings(args, @"to", &error);
  NSArray<NSString *> *cc = optional_strings(args, @"cc", &error);
  NSArray<NSString *> *bcc = optional_strings(args, @"bcc", &error);
  NSString *subject = optional_string(args, @"subject", &error);
  NSString *body = optional_string(args, @"body", &error);
  NSArray<NSString *> *paths = optional_strings(args, @"attachments", &error);
  if (error != nil) { reply(nil, error); return; }
  if (to.count + cc.count + bcc.count + paths.count == 0 && subject.length == 0 && body.length == 0) {
    // An empty sheet is never what anyone asked for; it is a caller that lost
    // its arguments, and showing it would put the mistake on the user's screen.
    reply(nil, @"mail needs at least one of 'to', 'cc', 'bcc', 'subject', 'body' or 'attachments'");
    return;
  }
  NSNumber *html = args[@"html"];
  BOOL isHTML = [html isKindOfClass:NSNumber.class] && html.boolValue;

  NSArray<NSURL *> *files = resolve_attachments(paths, &error);
  if (files == nil) { reply(nil, error); return; }
  // Mail takes bytes, not a file. Mapping rather than reading keeps a large
  // attachment out of memory until Mail actually copies it, and it is the last
  // check that the file can really be read before anything is shown.
  NSMutableArray<NSData *> *contents = [NSMutableArray arrayWithCapacity:files.count];
  for (NSUInteger i = 0; i < files.count; i++) {
    NSData *data = [NSData dataWithContentsOfURL:files[i] options:NSDataReadingMappedIfSafe error:NULL];
    if (data == nil) {
      reply(nil, [NSString stringWithFormat:
                  @"'%@' could not be opened as a file to attach: it is not readable", paths[i]]);
      return;
    }
    [contents addObject:data];
  }

  dsh_native_on_main(^{
    // NO means Apple's Mail has no account (or has been deleted). Building the
    // controller anyway is documented to fail, and the sheet it would show is
    // an alert about accounts, not a draft.
    if (![MFMailComposeViewController canSendMail]) {
      reply(nil, [NSString stringWithFormat:
                  @"Apple's Mail app has no account set up on this %@ (or has been removed), so there is "
                   "no compose sheet to show. Nothing was sent. The user can add an account under Mail in "
                   "the Settings app; until then, give them the text to send from the mail app they use.",
                  device_name()]);
      return;
    }
    id<DshNativeBridging> bridge = bridge_for_sheet(reply);
    if (bridge == nil) return;

    DshComposeSession *session = [[DshComposeSession alloc] initWithReply:reply];
    MFMailComposeViewController *controller = [[MFMailComposeViewController alloc] init];
    controller.mailComposeDelegate = session;
    if (to.count > 0) [controller setToRecipients:to];
    if (cc.count > 0) [controller setCcRecipients:cc];
    if (bcc.count > 0) [controller setBccRecipients:bcc];
    if (subject != nil) [controller setSubject:subject];
    if (body != nil) [controller setMessageBody:body isHTML:isHTML];
    for (NSUInteger i = 0; i < files.count; i++) {
      // Mail decides how to show an attachment (inline picture or file icon)
      // from this type. An extension the system does not know still attaches,
      // as opaque bytes.
      NSString *mime = [UTType typeWithFilenameExtension:files[i].pathExtension].preferredMIMEType
                       ?: @"application/octet-stream";
      [controller addAttachmentData:contents[i] mimeType:mime fileName:files[i].lastPathComponent];
    }
    present_sheet(bridge, controller, session);
  });
}

#pragma mark - Message

static void compose_message(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSArray<NSString *> *to = optional_strings(args, @"to", &error);
  NSString *body = optional_string(args, @"body", &error);
  NSArray<NSString *> *paths = optional_strings(args, @"attachments", &error);
  if (error != nil) { reply(nil, error); return; }
  if (to.count + paths.count == 0 && body.length == 0) {
    reply(nil, @"message needs at least one of 'to', 'body' or 'attachments'");
    return;
  }
  NSArray<NSURL *> *files = resolve_attachments(paths, &error);
  if (files == nil) { reply(nil, error); return; }

  dsh_native_on_main(^{
    // NO on an iPad with neither iMessage nor a paired iPhone to relay SMS, and
    // in the Simulator.
    if (![MFMessageComposeViewController canSendText]) {
      reply(nil, [NSString stringWithFormat:
                  @"this %@ cannot send text messages right now: iMessage is not signed in and it has no "
                   "way to send SMS. Nothing was sent.", device_name()]);
      return;
    }
    if (files.count > 0 && ![MFMessageComposeViewController canSendAttachments]) {
      reply(nil, [NSString stringWithFormat:
                  @"this %@ can send text messages but not attachments right now (iMessage and MMS are "
                   "both unavailable). Nothing was sent. Call again without 'attachments' to send the "
                   "text alone.", device_name()]);
      return;
    }
    id<DshNativeBridging> bridge = bridge_for_sheet(reply);
    if (bridge == nil) return;

    DshComposeSession *session = [[DshComposeSession alloc] initWithReply:reply];
    MFMessageComposeViewController *controller = [[MFMessageComposeViewController alloc] init];
    controller.messageComposeDelegate = session;
    if (to.count > 0) controller.recipients = to;
    if (body != nil) controller.body = body;
    for (NSUInteger i = 0; i < files.count; i++) {
      // Messages has its own list of what it will carry and says no here rather
      // than at send time. Checked before presenting for the same reason paths
      // are: a draft that quietly dropped a file looks complete to the user.
      if (![controller addAttachmentURL:files[i] withAlternateFilename:nil]) {
        reply(nil, [NSString stringWithFormat:
                    @"Messages would not take '%@' as an attachment (it does not send that kind of "
                     "file), so nothing was shown.", paths[i]]);
        return;
      }
    }
    present_sheet(bridge, controller, session);
  });
}

void dsh_native_compose(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"mail"]) { compose_mail(args, reply); return; }
  if ([op isEqualToString:@"message"]) { compose_message(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"compose has no operation '%@'", op]);
}
