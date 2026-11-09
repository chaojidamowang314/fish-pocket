// A plugin that checks the boundary from the outside. **Not a template.**
//
// It exists to be run, not copied. Installing it proves the thing the design
// actually claims (docs/native-services.md §5.3): a plugin and the engine itself
// are the same kind of caller. There is no second authorisation step here and no
// privileged path — this plugin asks for `iosNative` and gets exactly what the
// agent's own tools get, no more.
//
// **Do not build a plugin on these capabilities by copying this file.** The
// capability names, operation names and argument shapes are internal and change
// with the app; nothing here is versioned and nothing is promised (§5.6). The
// agent keeps up because it re-reads the skill file every session. A plugin that
// wrote `calendar`/`list`/`from`/`to` into its source would break on an update,
// quietly, on someone else's phone.
//
// That is also why this one is written to survive being wrong: every call is
// wrapped, and the report says what it found rather than assuming a shape.
//
// Two tools, for two different questions:
//   `native_check`    — does the boundary hold? (§9.3's lesson, as a tool)
//   `daily_briefing`  — is any of this actually useful? (device + today, spoken)
import { defineTool } from '@deepseek-ai/dsh-tools';

const text = (value) => [{ type: 'text', text: value }];

/** Local midnight today, and local midnight tomorrow, in seconds. */
function today() {
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return { from: Math.floor(start / 1000), to: Math.floor(end / 1000) };
}

const hhmm = (iso) => (typeof iso === 'string' ? iso.slice(11, 16) : '');

function briefingText(device, events, reminders) {
  const lines = [];
  if (device) {
    const battery = device.batteryLevel === null ? 'battery unknown' : `battery ${device.batteryLevel}%`;
    lines.push(`${device.model} · ${battery}${device.lowPowerMode ? ' · low power mode' : ''}`);
  }
  if (events.length === 0) {
    lines.push('Nothing on the calendar today.');
  } else {
    lines.push(`${events.length} event${events.length === 1 ? '' : 's'} today:`);
    for (const event of events) {
      lines.push(`  ${event.allDay ? 'all day' : `${hhmm(event.start)}–${hhmm(event.end)}`}  ${event.title || '(no title)'}`);
    }
  }
  if (reminders.length > 0) {
    lines.push(`${reminders.length} still to do:`);
    for (const reminder of reminders) lines.push(`  ${reminder.title || '(no title)'}`);
  }
  return lines.join('\n');
}

export default {
  name: 'dsh-plugin-native-demo',
  // Without the host's native capabilities this plugin has nothing to do, so it
  // simply does not load elsewhere — the same stance the host's own plugin takes.
  inject: ['iosNative', 'tools'],

  apply(ctx) {
    const briefing = defineTool({
      name: 'daily_briefing',
      description:
        'Summarise the user\'s day on this device: phone state and today\'s calendar, optionally read '
        + 'aloud. Use it for "how does my day look" and similar openers.',
      parameters: {
        speak: { type: 'boolean', description: 'also read the briefing out loud' },
      },
      output: {
        schema: { type: 'json' },
        render: (_args, value) => text(value.briefing),
      },
      execute: async (args) => {
        const { from, to } = today();
        // Both calls go through exactly the same path the agent's own tools take.
        // A read of the calendar here raises the same system prompt, and lands in
        // the same audit list — under this plugin's name rather than the agent's.
        const [device, calendar, reminders] = await Promise.all([
          ctx.iosNative.invoke('device', 'info'),
          ctx.iosNative.invoke('calendar', 'list', { from, to }),
          ctx.iosNative.invoke('reminders', 'list'),
        ]);
        const briefing = briefingText(device, calendar.events ?? [], reminders.reminders ?? []);
        if (args.speak) await ctx.iosNative.invoke('speak', 'say', { text: briefing });
        return { briefing, spoke: Boolean(args.speak) };
      },
    });

    const check = defineTool({
      name: 'native_check',
      description:
        'Report which native capabilities this build exposes, and check that the host still refuses '
        + 'what it has not implemented. Useful when a device feature is not behaving as expected.',
      parameters: {},
      output: {
        schema: { type: 'json' },
        render: (_args, value) => {
          const lines = Object.entries(value.available).map(([name, ops]) => `${name}: ${ops.join(', ')}`);
          lines.push('');
          for (const probe of value.refusals) {
            lines.push(`${probe.call} → ${probe.refused ? `refused (${probe.message})` : 'NOT REFUSED — this is a bug'}`);
          }
          return text(lines.join('\n'));
        },
      },
      execute: async () => {
        // The table the addon reports is the same table it dispatches on, so this
        // is not a second copy that can drift from the truth (§9.3).
        const available = ctx.iosNative.available ?? {};
        const probes = [
          // An operation that is not in the table, on a capability that is.
          { call: 'calendar.wipe', capability: 'calendar', op: 'wipe' },
          // A capability that does not exist at all.
          { call: 'healthkit.read', capability: 'healthkit', op: 'read' },
        ];
        const refusals = [];
        for (const probe of probes) {
          try {
            await ctx.iosNative.invoke(probe.capability, probe.op);
            refusals.push({ call: probe.call, refused: false, message: 'the call went through' });
          } catch (error) {
            refusals.push({ call: probe.call, refused: true, message: error.message });
          }
        }
        return { available, refusals };
      },
    });

    for (const tool of [briefing, check]) {
      ctx.effect(() => ctx.tools.register(tool), `native-demo ${tool.name}`);
    }
  },
};
