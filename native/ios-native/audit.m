// The audit trail: a ring of the most recent capability calls, kept natively.
//
// Why a ring and not a log: the user reads this to answer "what touched my
// calendar", which is a question about the recent past. A growing file would be
// a logging system nobody prunes, and this lives in UserDefaults next to the
// user's own data.
#import "DshNativeAudit.h"

/// Enough that a busy afternoon does not push out the morning, small enough that
/// reading it back is instant and UserDefaults stays a reasonable home.
static const NSUInteger kMaxEntries = 200;
static NSString *const kDefaultsKey = @"dsh.native.audit";
/// A caller name is a plugin id, not an essay; a summary is one line.
static const NSUInteger kMaxFieldLength = 200;

/// Every read and write goes through here, so a call arriving on the main thread
/// and one arriving on the calendar queue cannot interleave into a torn array.
static dispatch_queue_t audit_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.audit", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static NSString *clipped(NSString *text) {
  if (![text isKindOfClass:NSString.class] || text.length == 0) return nil;
  if (text.length <= kMaxFieldLength) return text;
  // On a composed-character boundary: cutting a string in the middle of an emoji
  // or a combining sequence leaves half a character, and a lone surrogate does
  // not survive being written out as JSON later.
  NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:kMaxFieldLength];
  return [[text substringToIndex:range.location] stringByAppendingString:@"…"];
}

void DshNativeAuditRecord(NSString *capability, NSString *op, NSString *callerClaim, NSString *summary) {
  if (![capability isKindOfClass:NSString.class] || ![op isKindOfClass:NSString.class]) return;

  NSMutableDictionary *entry = [@{
    @"capability": capability,
    @"op": op,
    @"at": @([NSDate.date timeIntervalSince1970]),
  } mutableCopy];
  NSString *caller = clipped(callerClaim);
  if (caller != nil) entry[@"caller"] = caller;
  NSString *note = clipped(summary);
  if (note != nil) entry[@"summary"] = note;

  dispatch_async(audit_queue(), ^{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *existing = [defaults arrayForKey:kDefaultsKey] ?: @[];
    // Newest first, so the list reads top-down and trimming is a suffix cut.
    NSMutableArray *entries = [NSMutableArray arrayWithObject:entry];
    [entries addObjectsFromArray:existing];
    if (entries.count > kMaxEntries) {
      [entries removeObjectsInRange:NSMakeRange(kMaxEntries, entries.count - kMaxEntries)];
    }
    [defaults setObject:entries forKey:kDefaultsKey];
  });
}

NSArray<NSDictionary<NSString *, id> *> *DshNativeAuditEntries(void) {
  __block NSArray *entries;
  // Synchronous: the settings screen asks for this and then draws it. Anything
  // queued ahead has to land first, or a call the user just triggered is missing
  // from the list they opened to check it.
  dispatch_sync(audit_queue(), ^{
    entries = [NSUserDefaults.standardUserDefaults arrayForKey:kDefaultsKey] ?: @[];
  });
  return entries;
}

void DshNativeAuditClear(void) {
  dispatch_sync(audit_queue(), ^{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kDefaultsKey];
  });
}
