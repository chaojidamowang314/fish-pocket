// clipboard: read and replace what the user copied.
//
// **Reading the clipboard is a privacy event, and iOS treats it as one.** Since
// iOS 16 a programmatic read raises a banner naming this app, every time — that
// banner is the user's notice and we do not try to avoid it. What they copied
// last is often the most sensitive thing on the phone (a password, a one-time
// code, an address), so this sits in the permission-bearing half of the table
// even though iOS asks for no up-front grant: the capability screen is where
// the user turns it on, like everything else that reaches their data.
//
// Writing is the opposite — harmless, silent, and genuinely useful ("put that
// into my clipboard") — but it still destroys what was there, which is why it
// is a `writeOps` entry and obeys the write policy.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import <UIKit/UIKit.h>

/// A clipboard entry can be a whole document. Enough to be useful, bounded
/// enough not to drop a megabyte of text into a model's context by accident.
static const NSUInteger kMaxLength = 20000;

static void read_clipboard(DshNativeReply reply) {
  dsh_native_on_main(^{
    UIPasteboard *board = UIPasteboard.generalPasteboard;
    // `hasStrings` does not raise the banner; reading does. Checking first means
    // "is there anything to paste" costs the user no notification.
    if (!board.hasStrings) {
      NSMutableArray *kinds = [NSMutableArray array];
      if (board.hasImages) [kinds addObject:@"image"];
      if (board.hasURLs) [kinds addObject:@"url"];
      if (board.hasColors) [kinds addObject:@"color"];
      reply(@{@"text": NSNull.null, @"kinds": kinds}, nil);
      return;
    }
    NSString *text = board.string ?: @"";
    BOOL truncated = text.length > kMaxLength;
    if (truncated) text = [text substringToIndex:kMaxLength];
    reply(@{@"text": text,
            @"characters": @(text.length),
            @"truncated": @(truncated),
            // The audit line says how much was read, never what: this list is
            // shown to the user and a clipboard's contents are the last thing
            // that should be copied into a second place (§5.4).
            @"auditSummary": [NSString stringWithFormat:@"· %lu", (unsigned long)text.length]}, nil);
  });
}

static void write_clipboard(NSDictionary *args, DshNativeReply reply) {
  NSString *text = args[@"text"];
  if (![text isKindOfClass:NSString.class]) {
    reply(nil, @"set needs 'text'");
    return;
  }
  NSString *summary = text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"…"] : text;
  DshNativeConfirmWrite(@"clipboard", @"set", summary, NO, ^(BOOL confirmed, NSString *refusal) {
    if (refusal != nil) { reply(nil, refusal); return; }
    if (!confirmed) {
      reply(@{@"action": DshNativeActionCancelled, @"saved": @NO}, nil);
      return;
    }
    dsh_native_on_main(^{
      UIPasteboard.generalPasteboard.string = text;
      reply(@{@"action": DshNativeActionSaved, @"saved": @YES,
              @"characters": @(text.length),
              @"auditSummary": summary}, nil);
    });
  });
}

static void clear_clipboard(DshNativeReply reply) {
  DshNativeConfirmWrite(@"clipboard", @"clear", @"", YES, ^(BOOL confirmed, NSString *refusal) {
    if (refusal != nil) { reply(nil, refusal); return; }
    if (!confirmed) {
      reply(@{@"action": DshNativeActionCancelled, @"cleared": @NO}, nil);
      return;
    }
    dsh_native_on_main(^{
      UIPasteboard.generalPasteboard.items = @[];
      reply(@{@"action": DshNativeActionDeleted, @"cleared": @YES, @"auditSummary": @""}, nil);
    });
  });
}

void dsh_native_clipboard(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"get"]) { read_clipboard(reply); return; }
  if ([op isEqualToString:@"set"]) { write_clipboard(args, reply); return; }
  if ([op isEqualToString:@"clear"]) { clear_clipboard(reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"clipboard has no operation '%@'", op]);
}
