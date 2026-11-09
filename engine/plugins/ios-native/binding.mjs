// The dsh_ios_native addon (native/ios-native): linked into the iOS app and
// reached through process._linkedBinding. Null anywhere else — on a development
// machine there is no UIKit to talk to, so the native capabilities are simply
// not part of the execution world there (the same stance runtime/git/binding.mjs
// takes for libgit2).
//
// `_linkedBinding` is visible to any JavaScript in the process, so a plugin can
// reach the addon without going through ctx.iosNative. That is by design: the
// permission model does not distinguish callers, because it cannot
// (docs/native-services.md §2.2, §4.1). What matters is that the addon itself
// holds every check — there is no unchecked variant of a capability in here.

let cached;

export function binding() {
  if (cached !== undefined) return cached;
  cached = null;
  try {
    cached = process._linkedBinding('dsh_ios_native');
  } catch {
    // Not an iOS build.
  }
  return cached;
}

/**
 * What this build implements: `{ capability: [op, ...] }`, or null without the
 * addon. The addon is the only source — the engine never keeps its own copy of
 * the list, so a capability cannot appear in the tool set without existing
 * natively.
 */
export function capabilities() {
  const addon = binding();
  if (addon === null) return null;
  try {
    return JSON.parse(addon.capabilities());
  } catch {
    return null;
  }
}

/**
 * Call one capability operation.
 * @param capability - capability name, as `capabilities()` lists it.
 * @param op - operation within that capability.
 * @param args - JSON-serialisable arguments object.
 * @param callerClaim - who the caller says it is, for the user's audit list
 *   only. Left empty it is recorded as unknown, which is the honest answer when
 *   nobody claimed anything — including when a plugin reaches the addon
 *   directly and simply omits it. Never a basis for any decision (see caller.mjs).
 * @returns the capability's result, already parsed.
 * @throws when the addon is absent, or with the capability's own message.
 */
export async function invoke(capability, op, args = {}, callerClaim = null) {
  const addon = binding();
  if (addon === null) throw new Error('native capabilities are only available in the iOS app');
  return JSON.parse(await addon.invoke(capability, op, JSON.stringify(args), callerClaim ?? ''));
}
