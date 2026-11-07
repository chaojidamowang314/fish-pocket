// The tools the agent sees for the native capabilities. One per capability, so
// a capability the addon does not implement contributes no tool at all.
//
// Each tool is thin on purpose: validate, call the addon, render. The addon owns
// permission, the main thread and the framework call.
import { defineTool } from '@deepseek-ai/dsh-tools';
import { invoke } from './binding.mjs';

const text = (value) => [{ type: 'text', text: value }];

/** Round a byte count to something a model reads without arithmetic. */
function gigabytes(bytes) {
  return typeof bytes === 'number' ? `${(bytes / 1e9).toFixed(1)} GB` : 'unknown';
}

const THERMAL_STATES = ['nominal', 'fair', 'serious', 'critical'];

const device = defineTool({
  name: 'device_info',
  description:
    'Report the state of the iPhone or iPad this session runs on: model, iOS version, battery, '
    + 'low power mode, thermal state and free storage. Read this before starting work that is long '
    + 'or storage-hungry, and when the user asks about their device.',
  parameters: {},
  output: {
    schema: { type: 'json' },
    render: (_args, value) => {
      const lines = [
        `${value.model} · ${value.systemName} ${value.systemVersion} (${value.idiom})`,
        `battery: ${value.batteryLevel === null ? 'unknown' : `${value.batteryLevel}%`} (${value.batteryState})`
          + `${value.lowPowerMode ? ', low power mode ON' : ''}`,
        `thermal: ${THERMAL_STATES[value.thermalState] ?? value.thermalState}`,
        `free storage: ${gigabytes(value.availableBytes)}`,
        `cpu cores: ${value.processorCount}`,
      ];
      return text(lines.join('\n'));
    },
  },
  execute: () => invoke('device', 'info'),
});

const notify = defineTool({
  name: 'notify',
  description:
    'Schedule a local notification on the user\'s device, or list and cancel ones you scheduled. '
    + 'Use this for "remind me in N minutes" — it alerts the user even if the app is closed, and '
    + 'does not touch their Reminders or Calendar. The first use asks the user to allow notifications.',
  parameters: {
    action: {
      type: 'string',
      enum: ['schedule', 'cancel', 'pending'],
      description: 'schedule a new notification, cancel one by id, or list the pending ones',
      required: true,
    },
    body: { type: 'string', description: 'what the notification says; required to schedule' },
    afterSeconds: {
      type: 'number',
      description: 'how long from now to deliver it, in seconds (at least 1); required to schedule',
    },
    title: { type: 'string', description: 'optional title; defaults to the app name' },
    id: { type: 'string', description: 'the notification to cancel, as schedule returned it' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'pending') {
        const list = value.notifications ?? [];
        if (list.length === 0) return text('No notifications scheduled.');
        return text(
          list
            .map((item) => `${item.id}  in ${Math.max(0, Math.round((item.deliversAt ?? 0) - Date.now() / 1000))}s  ${item.body}`)
            .join('\n'),
        );
      }
      if (args.action === 'cancel') return text(`Cancelled ${value.cancelled}.`);
      const seconds = Math.round((value.deliversAt ?? 0) - Date.now() / 1000);
      return text(`Scheduled in ${seconds}s (id ${value.id}).`);
    },
  },
  execute: async (args) => {
    if (args.action === 'schedule') {
      if (!args.body) throw new Error('notify: scheduling needs `body`');
      if (typeof args.afterSeconds !== 'number') throw new Error('notify: scheduling needs `afterSeconds`');
      return invoke('notify', 'schedule', {
        body: args.body,
        afterSeconds: args.afterSeconds,
        ...(args.title === undefined ? {} : { title: args.title }),
      });
    }
    if (args.action === 'cancel') {
      if (!args.id) throw new Error('notify: cancelling needs `id`');
      return invoke('notify', 'cancel', { id: args.id });
    }
    return invoke('notify', 'pending');
  },
});

const speak = defineTool({
  name: 'speak',
  description:
    'Read text aloud through the device speaker, using the system voices. Returns as soon as '
    + 'speech starts, not when it finishes. Use it when the user asks you to say something out '
    + 'loud or cannot look at the screen.',
  parameters: {
    action: { type: 'string', enum: ['say', 'stop'], description: 'start speaking, or stop at once', required: true },
    text: { type: 'string', description: 'what to say; required for `say`' },
    language: {
      type: 'string',
      description: 'BCP-47 language of the text, e.g. zh-CN or en-US. Set it when the text is not in the device language',
    },
    rate: { type: 'number', description: 'speech rate; the system default is about 0.5' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) =>
      text(args.action === 'stop' ? 'Stopped speaking.' : `Speaking ${value.characters} characters.`),
  },
  execute: async (args) => {
    if (args.action === 'stop') return invoke('speak', 'stop');
    if (!args.text) throw new Error('speak: `say` needs `text`');
    return invoke('speak', 'say', {
      text: args.text,
      ...(args.language === undefined ? {} : { language: args.language }),
      ...(args.rate === undefined ? {} : { rate: args.rate }),
    });
  },
});

/** Tool definitions by the capability each one needs. */
export const TOOLS = {
  device: device,
  notify: notify,
  speak: speak,
};
