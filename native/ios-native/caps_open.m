// open: hand a URL to whichever app the system says owns it — Maps for a
// `maps:` link, the dialler for `tel:`, Mail for `mailto:`, Safari for a web
// address. No permission, nothing stored.
//
// This is not the "open a page for the user to read" path: that is the app's
// own in-conversation preview, and a plain Markdown link already does it. This
// one is for leaving the app on purpose, which is why it is worth being careful
// about what may be opened.
//
// **Why there is an allowlist of schemes.** `UIApplication.open` is the one
// capability here that hands control to another app with the caller's words as
// the payload, and some schemes do something irreversible on arrival rather
// than after another tap: a `facetime-audio:` URL can start a call, and the
// various pay/transfer schemes some apps register are worse. A plugin cannot be
// told apart from the engine (§2.2), so "it only opens what the agent asked
// for" is not a guard at all. The schemes below either land on a screen the
// user must still act on, or are the web.
#import "dsh_ios_native.h"
#import <UIKit/UIKit.h>

/// Schemes that may be opened without the user confirming. Each one lands the
/// user somewhere they can still back out of: a map, a draft, a dialler with the
/// number filled in but not dialled, a web page.
static NSSet<NSString *> *allowed_schemes(void) {
  static NSSet<NSString *> *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [NSSet setWithArray:@[
      @"http", @"https",
      @"mailto",            // a draft, not a sent message
      @"tel",               // the dialler, filled in; iOS still asks before calling
      @"sms",               // a draft
      @"maps",              // Apple Maps
      @"shortcuts",         // the user's own automations
      @"itms-apps",         // App Store page
      @"calshow",           // Calendar, at a date
      @"x-apple-reminderkit",
    ]];
  });
  return shared;
}

static void open_url(NSDictionary *args, DshNativeReply reply) {
  NSString *string = args[@"url"];
  if (![string isKindOfClass:NSString.class] || string.length == 0) {
    reply(nil, @"open needs a non-empty 'url'");
    return;
  }
  NSURL *url = [NSURL URLWithString:string];
  if (url == nil || url.scheme.length == 0) {
    reply(nil, [NSString stringWithFormat:@"'%@' is not a URL with a scheme", string]);
    return;
  }
  NSString *scheme = url.scheme.lowercaseString;
  if (![allowed_schemes() containsObject:scheme]) {
    // Names the scheme and the reason, because the agent reads this out and the
    // user may reasonably want to know what was refused on their behalf.
    reply(nil, [NSString stringWithFormat:
                @"'%@' links are not opened from here. Allowed: %@. Give the user the link to tap "
                 "instead — a plain Markdown link in the reply works for any scheme.",
                scheme, [[allowed_schemes().allObjects sortedArrayUsingSelector:@selector(compare:)]
                         componentsJoinedByString:@", "]]);
    return;
  }

  dsh_native_on_main(^{
    // `canOpenURL` without the scheme in LSApplicationQueriesSchemes answers NO
    // even for schemes that would open, so it is not asked: `open` reports the
    // real outcome anyway, and asking first would refuse things that work.
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL opened) {
      if (opened) {
        reply(@{@"opened": @YES, @"url": url.absoluteString}, nil);
      } else {
        reply(nil, [NSString stringWithFormat:
                    @"nothing on this device opens '%@' links", scheme]);
      }
    }];
  });
}

void dsh_native_open(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"url"]) {
    open_url(args, reply);
    return;
  }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"open has no operation '%@'", op]);
}
