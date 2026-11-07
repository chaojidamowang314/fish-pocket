// The iOS frameworks the agent is allowed to reach, as engine tools and as a
// service third-party plugins can inject.
//
// This is phase 0 of docs/native-services.md: only capabilities that need no
// system permission and no user decision (device state, local notifications,
// speech). The permission machinery the later phases need lives in the addon,
// not here — see native/ios-native/ios_native.m's `policy_allows`.
//
// Nothing is registered when the addon is absent (any non-iOS build), so the
// model never sees a tool it cannot call.
import { Service } from '@deepseek-ai/cordis';
import { capabilities, invoke } from './binding.mjs';
import { TOOLS } from './tools.mjs';

/**
 * `ctx.iosNative` — the same path the engine's own tools take, exposed so a
 * third-party plugin can build on these capabilities.
 *
 * Deliberately NOT a per-caller gate: a plugin can reach the addon directly
 * (`process._linkedBinding`), and could present itself as the engine itself by
 * calling through `ctx.root`, so a check here would only stop the plugins that
 * were not trying to get around it. The checks that hold are iOS's own
 * permission prompts and, for writes, the confirmation the addon runs on the
 * main thread (docs/native-services.md §2.2, §5.3).
 */
class IosNativeService extends Service {
  constructor(ctx, available) {
    super(ctx, 'iosNative');
    this.available = available;
  }

  /**
   * Call one native capability operation.
   * @param capability - capability name, e.g. 'device'.
   * @param op - operation within it, e.g. 'info'.
   * @param args - JSON-serialisable arguments.
   * @returns the capability's result.
   */
  async invoke(capability, op, args = {}) {
    return invoke(capability, op, args);
  }
}

export default function IosNative(ctx) {
  const available = capabilities();
  if (available === null) {
    ctx.logger.debug('no dsh_ios_native addon; native capabilities are off');
    return;
  }

  ctx.plugin(
    class extends IosNativeService {
      constructor(serviceCtx) {
        super(serviceCtx, available);
      }
    },
  );

  // One tool per capability the addon actually implements. A tool whose
  // capability is missing is never registered, so the addon's table stays the
  // single source of truth for what exists.
  ctx.inject(['tools'], (toolsCtx) => {
    for (const [capability, tool] of Object.entries(TOOLS)) {
      if (available[capability] === undefined) continue;
      toolsCtx.effect(() => toolsCtx.tools.register(tool), `ios-native ${capability} tool`);
    }
    toolsCtx.logger.info('native capabilities: %s', Object.keys(available).join(', '));
  });
}
