// dsh_ios_native: the iOS frameworks the agent is allowed to reach, behind one
// N-API call. `invoke(capability, op, argsJson)` resolves with a JSON string, or
// rejects with the capability's own message.
//
// Why one entry and one table: the capability a call is CHECKED against must be
// the capability it is DISPATCHED to, or the two rules drift and the gap is a
// bypass. (OpenMinis shipped exactly that bug — its gate matched argv[0]
// verbatim while its kernel dispatched on the basename, so an absolute path
// reached HealthKit with no prompt. See docs/native-services.md §9.3.)
// Everything here reads CAPABILITIES once: to validate, to find the handler,
// and to decide policy.
//
// Threading: Node calls in on its own thread. Capabilities that need the main
// thread hop there themselves (dsh_native_on_main) and reply later, so every
// call settles through the same threadsafe-function path.
#import "dsh_ios_native.h"
#import "DshNativeCapabilities.h"
#import "DshNativeAudit.h"
#import "eventkit_shared.h"
#import <node_api.h>

/// A capability may put a one-line account of what it did under this key. The
/// dispatcher lifts it into the audit entry and removes it before the result
/// crosses into JS: it is for the user's audit list, not for the model.
static NSString *const kAuditSummaryKey = @"auditSummary";

#pragma mark - Capability table

typedef struct {
  const char *capability;
  DshNativeHandler handler;
  /// Operations this capability accepts, NULL-terminated. A name not listed
  /// never reaches the handler: an unimplemented operation must not execute,
  /// which is what keeps a plugin calling us directly (process._linkedBinding
  /// is visible to any JS) from reaching something we have not built yet.
  const char *ops[8];
  /// The iOS permission this capability needs, or NULL when it needs none.
  /// Only for display in the app's capability list — the capability itself
  /// still asks iOS at use time, and nothing here gates on this field.
  const char *systemPermission;
  /// The subset of `ops` that changes the user's own data, NULL-terminated.
  /// Reads are already gated by the iOS permission; this is what the write
  /// policy applies to, and what the capability screen offers a switch for.
  /// Empty for a capability that only reads or only touches our own state.
  const char *writeOps[6];
} dsh_capability;

// `calendar` is the first entry that reaches personal data, and the only one so
// far that iOS guards with a privacy prompt. Its writes are listed here like
// anything else, which is the point: the user's system grant already covers
// writing (§4.0), so what separates "may read my calendar" from "may delete my
// calendar" is not this list but the write policy the user sets per capability
// (§4.3). `notify` has no writeOps on purpose — a local notification is this
// app's own alert, it leaves nothing behind in the user's data, so it is not a
// write in the sense this policy is about.
static const dsh_capability CAPABILITIES[] = {
  {"device",   dsh_native_device,   {"info", NULL}, NULL, {NULL}},
  {"notify",   dsh_native_notify,   {"schedule", "cancel", "pending", NULL}, "notifications", {NULL}},
  {"speak",    dsh_native_speak,    {"say", "stop", NULL}, NULL, {NULL}},
  {"calendar", dsh_native_calendar, {"list", "calendars", "create", "update", "delete", NULL}, "calendar",
   {"create", "update", "delete", NULL}},
  {"reminders", dsh_native_reminders, {"list", "create", "complete", "delete", NULL}, "reminders",
   {"create", "complete", "delete", NULL}},
  // `open` leaves the app, so it reaches no user data of ours and needs no
  // permission — what it needs instead is a scheme allowlist, in caps_open.m.
  {"open",     dsh_native_open,     {"url", NULL}, NULL, {NULL}},
  {"nlp",      dsh_native_nlp,      {"language", "tokenize", "sentiment", "entities", NULL}, NULL, {NULL}},
};
static const size_t CAPABILITY_COUNT = sizeof(CAPABILITIES) / sizeof(CAPABILITIES[0]);

static const dsh_capability *find_capability(NSString *name) {
  const char *wanted = name.UTF8String;
  if (wanted == NULL) return NULL;
  for (size_t i = 0; i < CAPABILITY_COUNT; i++) {
    if (strcmp(CAPABILITIES[i].capability, wanted) == 0) return &CAPABILITIES[i];
  }
  return NULL;
}

/// The capability's operations as an array, shared by both readers of the table.
static NSArray<NSString *> *capability_ops(const dsh_capability *cap) {
  NSMutableArray<NSString *> *ops = [NSMutableArray array];
  for (size_t i = 0; i < sizeof(cap->ops) / sizeof(cap->ops[0]) && cap->ops[i] != NULL; i++) {
    [ops addObject:@(cap->ops[i])];
  }
  return ops;
}

/// Same shape as `capability_ops`, for the operations that change user data.
static NSArray<NSString *> *capability_write_ops(const dsh_capability *cap) {
  NSMutableArray<NSString *> *ops = [NSMutableArray array];
  for (size_t i = 0; i < sizeof(cap->writeOps) / sizeof(cap->writeOps[0]) && cap->writeOps[i] != NULL; i++) {
    [ops addObject:@(cap->writeOps[i])];
  }
  return ops;
}

/// One key per capability rather than one dictionary, so a capability added
/// later starts at 0 (direct) without a migration, and so a corrupted value for
/// one capability cannot take the others with it.
static NSString *write_policy_key(NSString *capability) {
  return [@"dsh.native.write." stringByAppendingString:capability];
}

DshWritePolicy DshNativeWritePolicyFor(NSString *capability) {
  if (capability.length == 0) return DshWritePolicyDirect;
  NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:write_policy_key(capability)];
  // Anything we do not recognise is treated as the strictest setting rather than
  // the loosest: a value we cannot read is not a reason to widen a gate.
  switch (stored) {
    case DshWritePolicyDirect:
    case DshWritePolicyConfirm:
    case DshWritePolicyBlocked:
      return (DshWritePolicy)stored;
    default:
      return DshWritePolicyBlocked;
  }
}

void DshNativeSetWritePolicy(NSString *capability, DshWritePolicy policy) {
  if (capability.length == 0) return;
  [NSUserDefaults.standardUserDefaults setInteger:policy forKey:write_policy_key(capability)];
}

NSArray<NSDictionary<NSString *, id> *> *DshNativeCapabilityList(void) {
  NSMutableArray *list = [NSMutableArray arrayWithCapacity:CAPABILITY_COUNT];
  for (size_t i = 0; i < CAPABILITY_COUNT; i++) {
    NSMutableDictionary *entry = [@{
      @"id": @(CAPABILITIES[i].capability),
      @"ops": capability_ops(&CAPABILITIES[i]),
      @"writeOps": capability_write_ops(&CAPABILITIES[i]),
    } mutableCopy];
    if (CAPABILITIES[i].systemPermission != NULL) {
      entry[@"systemPermission"] = @(CAPABILITIES[i].systemPermission);
    }
    [list addObject:entry];
  }
  return list;
}

void DshNativeRequestPermission(NSString *permission, void (^done)(BOOL granted, NSString *error)) {
  // The screen is the caller, so settle where it can use the answer.
  void (^reply)(BOOL, NSString *) = ^(BOOL granted, NSString *error) {
    dsh_native_on_main(^{ done(granted, error); });
  };

  // Only a permission some capability in the table actually asks for. A name
  // this build does not use must not come back looking like a refusal by the
  // user, which is indistinguishable from a bug in the screen.
  BOOL named = NO;
  for (size_t i = 0; i < CAPABILITY_COUNT; i++) {
    const char *needed = CAPABILITIES[i].systemPermission;
    if (needed != NULL && [permission isEqualToString:@(needed)]) {
      named = YES;
      break;
    }
  }
  if (!named) {
    reply(NO, [NSString stringWithFormat:@"no capability in this build needs '%@'", permission]);
    return;
  }

  if ([permission isEqualToString:@"calendar"]) {
    DshEventKitGrantAccess(EKEntityTypeEvent, nil, reply);
  } else if ([permission isEqualToString:@"reminders"]) {
    DshEventKitGrantAccess(EKEntityTypeReminder, nil, reply);
  } else if ([permission isEqualToString:@"notifications"]) {
    DshNotifyGrantAccess(reply);
  } else {
    // In the table, but nothing here knows how to ask for it: a capability was
    // added with a new `systemPermission` and this function was not extended.
    // Loud, because the alternative is a switch on screen that does nothing.
    reply(NO, [NSString stringWithFormat:@"'%@' has no grant path in DshNativeRequestPermission", permission]);
  }
}

static BOOL capability_accepts(const dsh_capability *cap, NSString *op) {
  const char *wanted = op.UTF8String;
  if (wanted == NULL) return NO;
  for (size_t i = 0; i < sizeof(cap->ops) / sizeof(cap->ops[0]) && cap->ops[i] != NULL; i++) {
    if (strcmp(cap->ops[i], wanted) == 0) return YES;
  }
  return NO;
}

/// The one place an application-layer permission decision will go.
///
/// Phase 0 has nothing to decide: none of the capabilities above touch personal
/// data, so every call is allowed. It exists now, called on the only dispatch
/// path, so tightening later is a change HERE and nowhere else — adding the gate
/// afterwards would otherwise mean touching every caller, and by then third-party
/// plugins are already calling us (docs/native-services.md §4.1).
///
/// The shape it will take is three levels, not a boolean: bypass (this) /
/// ask-once-per-session / not-allowed.
static BOOL policy_allows(const dsh_capability *cap, NSString *op) {
  (void)cap;
  (void)op;
  return YES;
}

#pragma mark - Main-thread helper

void dsh_native_on_main(void (^block)(void)) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

#pragma mark - Call plumbing

/// One in-flight invoke. The threadsafe function is what lets a capability
/// reply from the main thread (or any other) after Node's thread has moved on.
typedef struct {
  napi_deferred deferred;
  napi_threadsafe_function settle;
  char *result_json;
  char *error;
} dsh_call;

static char *copy_utf8(NSString *string) {
  const char *utf8 = string.UTF8String;
  if (utf8 == NULL) return NULL;
  size_t size = strlen(utf8) + 1;
  char *copy = malloc(size);
  if (copy != NULL) memcpy(copy, utf8, size);
  return copy;
}

/// Runs on Node's thread once a capability has replied.
static void settle_on_js_thread(napi_env env, napi_value unused_cb, void *unused_ctx, void *data) {
  (void)unused_cb;
  (void)unused_ctx;
  dsh_call *call = data;
  if (env != NULL) {
    napi_value value;
    if (call->error != NULL) {
      napi_value message;
      napi_create_string_utf8(env, call->error, NAPI_AUTO_LENGTH, &message);
      napi_create_error(env, NULL, message, &value);
      napi_reject_deferred(env, call->deferred, value);
    } else {
      napi_create_string_utf8(env, call->result_json ? call->result_json : "null", NAPI_AUTO_LENGTH, &value);
      napi_resolve_deferred(env, call->deferred, value);
    }
  }
  napi_release_threadsafe_function(call->settle, napi_tsfn_release);
  free(call->result_json);
  free(call->error);
  free(call);
}

/// Hand a capability's answer back to Node. Tolerates being called on any
/// thread; ignores everything after the first reply, because a capability that
/// replies twice must not settle a promise twice.
static void finish(dsh_call *call, NSDictionary *result, NSString *error) {
  if (error == nil && result != nil) {
    NSError *encodeError = nil;
    // The reply crosses as a JSON string: it keeps this file free of N-API value
    // building, and the engine side parses it once.
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&encodeError];
    if (json == nil) {
      error = [NSString stringWithFormat:@"result is not JSON-serialisable: %@", encodeError.localizedDescription];
    } else {
      call->result_json = malloc(json.length + 1);
      if (call->result_json != NULL) {
        memcpy(call->result_json, json.bytes, json.length);
        call->result_json[json.length] = '\0';
      }
    }
  }
  if (error != nil) call->error = copy_utf8(error);
  if (call->error == NULL && call->result_json == NULL) call->error = copy_utf8(@"out of memory");
  napi_call_threadsafe_function(call->settle, call, napi_tsfn_blocking);
}

static NSString *string_arg(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) return nil;
  char *buffer = malloc(length + 1);
  if (buffer == NULL) return nil;
  NSString *string = nil;
  if (napi_get_value_string_utf8(env, value, buffer, length + 1, &length) == napi_ok) {
    string = [NSString stringWithUTF8String:buffer];
  }
  free(buffer);
  return string;
}

static napi_value reject_now(napi_env env, const char *message) {
  napi_deferred deferred;
  napi_value promise, error, text;
  napi_create_promise(env, &deferred, &promise);
  napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &text);
  napi_create_error(env, NULL, text, &error);
  napi_reject_deferred(env, deferred, error);
  return promise;
}

/// invoke(capability, op, argsJson?, callerClaim?) -> Promise<string>
static napi_value invoke(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value argv[4];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) {
    return reject_now(env, "invoke(capability, op, argsJson?, callerClaim?) needs a capability and an op");
  }

  NSString *capabilityName = string_arg(env, argv[0]);
  NSString *op = string_arg(env, argv[1]);
  if (capabilityName == nil || op == nil) return reject_now(env, "capability and op must be strings");

  const dsh_capability *cap = find_capability(capabilityName);
  if (cap == NULL) {
    return reject_now(env, [NSString stringWithFormat:@"unknown capability '%@'", capabilityName].UTF8String);
  }
  if (!capability_accepts(cap, op)) {
    return reject_now(env, [NSString stringWithFormat:@"capability '%@' has no operation '%@'", capabilityName, op].UTF8String);
  }
  if (!policy_allows(cap, op)) {
    return reject_now(env, [NSString stringWithFormat:@"'%@.%@' is not allowed", capabilityName, op].UTF8String);
  }

  NSDictionary *args = @{};
  if (argc >= 3) {
    NSString *argsJson = string_arg(env, argv[2]);
    if (argsJson != nil && argsJson.length > 0) {
      NSData *data = [argsJson dataUsingEncoding:NSUTF8StringEncoding];
      id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
      if (![decoded isKindOfClass:NSDictionary.class]) return reject_now(env, "argsJson must encode an object");
      args = decoded;
    }
  }

  // What the caller says it is. Never checked, never used to decide anything —
  // it only ever reaches the audit list, where it is labelled as a claim.
  NSString *callerClaim = argc >= 4 ? string_arg(env, argv[3]) : nil;

  dsh_call *call = calloc(1, sizeof(dsh_call));
  if (call == NULL) return reject_now(env, "out of memory");

  napi_value promise, name;
  napi_create_promise(env, &call->deferred, &promise);
  napi_create_string_utf8(env, "dsh_ios_native", NAPI_AUTO_LENGTH, &name);
  if (napi_create_threadsafe_function(env, NULL, NULL, name, 0, 1, NULL, NULL, NULL,
                                      settle_on_js_thread, &call->settle) != napi_ok) {
    free(call);
    return reject_now(env, "could not create the reply channel");
  }

  // The audit is taken here rather than inside each capability, for the same
  // reason the permission check is: this is the only path, so nothing can be
  // added later that quietly skips it.
  //
  // Only the capabilities iOS itself guards are recorded, and only when they
  // succeeded. That is what the list is for — "what reached my data" — and
  // recording `device.info` or every `speak.say` would push the one calendar
  // read the user is looking for out of the ring.
  BOOL audited = cap->systemPermission != NULL;
  NSString *auditedCapability = capabilityName;
  cap->handler(op, args, ^(NSDictionary *result, NSString *error) {
    NSDictionary *payload = result;
    if (result[kAuditSummaryKey] != nil) {
      NSMutableDictionary *stripped = [result mutableCopy];
      [stripped removeObjectForKey:kAuditSummaryKey];
      payload = stripped;
    }
    // 摘要在，才算真的发生过：能力只在写成功时给摘要，用户点了取消的那一次没有。
    // 用摘要在不在当条件，而不是另记一个标志，是因为这样「被拒绝的写不进审计」
    // 不依赖以后每个新能力都记得这回事——审计页是用户唯一的事后凭据，记错一条
    // 比少记一条更糟。
    if (audited && error == nil && result[kAuditSummaryKey] != nil) {
      DshNativeAuditRecord(auditedCapability, op, callerClaim, result[kAuditSummaryKey]);
    }
    finish(call, payload, error);
  });
  return promise;
}

/// capabilities() -> JSON string. What this build actually implements, so the
/// engine registers tools for these and nothing else.
static napi_value capabilities(napi_env env, napi_callback_info info) {
  (void)info;
  NSMutableDictionary *table = [NSMutableDictionary dictionary];
  for (size_t i = 0; i < CAPABILITY_COUNT; i++) {
    table[@(CAPABILITIES[i].capability)] = capability_ops(&CAPABILITIES[i]);
  }
  NSData *json = [NSJSONSerialization dataWithJSONObject:table options:0 error:NULL];
  napi_value value;
  napi_create_string_utf8(env, json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String : "{}",
                          NAPI_AUTO_LENGTH, &value);
  return value;
}

static napi_value init(napi_env env, napi_value exports) {
  napi_value fn;
  napi_create_function(env, "invoke", NAPI_AUTO_LENGTH, invoke, NULL, &fn);
  napi_set_named_property(env, exports, "invoke", fn);
  napi_create_function(env, "capabilities", NAPI_AUTO_LENGTH, capabilities, NULL, &fn);
  napi_set_named_property(env, exports, "capabilities", fn);
  return exports;
}

#ifdef DSH_IOS_NATIVE_LINKED
// Linked into the app: registered before Node starts, reached through
// process._linkedBinding('dsh_ios_native') from any thread's environment.
static napi_module module = {1, 0, __FILE__, init, "dsh_ios_native", NULL, {0}};
__attribute__((constructor)) static void register_module(void) { napi_module_register(&module); }
#else
NAPI_MODULE(dsh_ios_native, init)
#endif
