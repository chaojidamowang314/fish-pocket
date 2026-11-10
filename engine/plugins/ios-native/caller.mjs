// Who is calling, as far as cordis can tell — for the audit list and nothing
// else.
//
// cordis's service tracker rewrites `this.ctx` inside a service method to the
// *caller's* context, so a service can name whoever reached it. That naming is
// reliable for an honest caller and worthless against a dishonest one: a plugin
// that writes `ctx.root.iosNative` instead of `ctx.iosNative` arrives holding
// the very same fiber object the engine itself holds, with no field left to
// tell them apart (docs/native-services.md §2.2).
//
// So this is a claim, not an identity. Everything downstream names it
// `callerClaim` so that nobody later mistakes it for something to check.
export const ENGINE_CLAIM = 'dsh';

/**
 * Best-effort name of whatever context reached the service.
 *
 * @param ctx - the context the service method saw as `this.ctx`.
 * @returns the caller's plugin name, or null when it cannot be read.
 */
export function callerClaim(ctx) {
  try {
    // `fiber.name` is the plugin's display name, inherited from the nearest
    // named ancestor and `'root'` for the root fiber. Reading the fiber chain by
    // hand is not worth it: cordis throws on properties a context did not
    // inject, so a walk upwards dies partway and tells you less than this.
    const name = ctx?.fiber?.name;
    return typeof name === 'string' && name.length > 0 ? name : null;
  } catch {
    return null;
  }
}
