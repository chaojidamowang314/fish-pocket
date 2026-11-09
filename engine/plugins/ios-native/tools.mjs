// The tools the agent sees for the native capabilities. One per capability, so
// a capability the addon does not implement contributes no tool at all.
//
// Each tool is thin on purpose: validate, call the addon, render. The addon owns
// permission, the main thread and the framework call.
import { defineTool } from '@deepseek-ai/dsh-tools';
import { invoke as invokeNative } from './binding.mjs';
import { ENGINE_CLAIM } from './caller.mjs';

// These are the engine's own tools, so every call from here claims the engine.
// It is still only a claim — nothing downstream treats it as proof.
const invoke = (capability, op, args) => invokeNative(capability, op, args, ENGINE_CLAIM);

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

/** A week is what "what's coming up" means to most people asking. */
const DEFAULT_RANGE_DAYS = 7;

/**
 * Seconds since 1970 for a date the model wrote.
 *
 * A bare `YYYY-MM-DD` has to mean local midnight: `new Date('2026-11-09')` is
 * parsed as UTC by the language, which would shift the whole day for anyone east
 * or west of Greenwich and quietly return the wrong events.
 *
 * Exported so that behaviour can be pinned by a test; nothing else uses it.
 */
export function toEpochSeconds(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  if (typeof value !== 'string') throw new Error(`calendar: '${value}' is not a date`);
  const bare = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
  const date = bare
    ? new Date(Number(bare[1]), Number(bare[2]) - 1, Number(bare[3]))
    : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error(`calendar: could not read the date '${value}'`);
  return Math.floor(date.getTime() / 1000);
}

// The addon formats times in the device's own timezone and includes the offset,
// so reading the parts straight out of the string keeps this from re-interpreting
// a moment that is already correct.
const dayOf = (iso) => (typeof iso === 'string' ? iso.slice(0, 10) : '');
const timeOf = (iso) => (typeof iso === 'string' ? iso.slice(11, 16) : '');

function renderEvent(event) {
  const day = dayOf(event.start);
  const when = event.allDay
    ? `${day} all day`
    : dayOf(event.end) === day
      ? `${day} ${timeOf(event.start)}–${timeOf(event.end)}`
      : `${day} ${timeOf(event.start)} – ${dayOf(event.end)} ${timeOf(event.end)}`;
  const parts = [when, event.title || '(no title)'];
  if (event.calendar) parts.push(`[${event.calendar}]`);
  if (event.location) parts.push(`@ ${event.location}`);
  const line = parts.join('  ');
  return event.notes ? `${line}\n    ${event.notes.replace(/\n+/g, ' ')}` : line;
}

const calendar = defineTool({
  name: 'calendar',
  description:
    'The calendar on this device: read the user\'s events, list their calendars, and — only with '
    + 'their confirmation — add, change or delete an event. Use it to answer anything about their '
    + 'schedule, to check whether they are free, and before suggesting a time. Reading defaults to '
    + 'the next week. The first read asks them to allow calendar access.\n'
    + 'Every write stops in front of the user: `create` opens the system event editor, `update` and '
    + '`delete` ask them to confirm. They may cancel, and the result says so — never tell them '
    + 'something was added or deleted without checking `saved`/`deleted` in the result first.',
  parameters: {
    action: {
      type: 'string',
      enum: ['list', 'calendars', 'create', 'update', 'delete'],
      description:
        'list events in a date range, list the calendars themselves, or create, update or delete one event',
      required: true,
    },
    from: {
      type: 'string',
      description: `list: start of the range, YYYY-MM-DD or a full ISO timestamp; defaults to now`,
    },
    to: {
      type: 'string',
      description: `list: end of the range, YYYY-MM-DD or a full ISO timestamp; defaults to ${DEFAULT_RANGE_DAYS} days after 'from'`,
    },
    id: {
      type: 'string',
      description: 'update/delete: the event, as `list` returned its id',
    },
    title: { type: 'string', description: 'create/update: the event title; required to create' },
    start: {
      type: 'string',
      description: 'create/update: when it starts, YYYY-MM-DD or a full ISO timestamp; required to create',
    },
    end: {
      type: 'string',
      description: 'create/update: when it ends; defaults to an hour after `start` when creating',
    },
    allDay: { type: 'boolean', description: 'create: whether it takes the whole day' },
    location: { type: 'string', description: 'create/update: where it is' },
    notes: { type: 'string', description: 'create/update: free-text notes on the event' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'calendars') {
        const list = value.calendars ?? [];
        if (list.length === 0) return text('No calendars on this device.');
        return text(
          list
            .map((item) => `${item.title}${item.default ? '  (default)' : ''}${item.writable ? '' : '  (read-only)'}`)
            .join('\n'),
        );
      }
      // Writes: say plainly whether anything happened, because the user had the
      // last word and "cancelled" must not be reported to them as done.
      if (args.action === 'create') {
        return text(value.saved
          ? `Added to their calendar${value.id ? ` (id ${value.id})` : ''}.`
          : 'They closed the event editor without adding it. Nothing was added.');
      }
      if (args.action === 'update') {
        if (value.unchanged) return text('That event already matches; nothing to change.');
        return text(value.saved ? 'They confirmed the change; the event is updated.' : 'They declined. The event is unchanged.');
      }
      if (args.action === 'delete') {
        return text(value.deleted ? 'They confirmed; the event is deleted.' : 'They declined. The event is still there.');
      }
      const events = value.events ?? [];
      if (events.length === 0) return text('No events in that range.');
      const lines = events.map(renderEvent);
      if (value.truncated) {
        lines.push(`… showing the first ${events.length} of ${value.total}; ask for a shorter range to see the rest.`);
      }
      return text(lines.join('\n'));
    },
  },
  execute: async (args) => {
    if (args.action === 'calendars') return invoke('calendar', 'calendars');

    if (args.action === 'create') {
      if (!args.title) throw new Error('calendar: creating needs `title`');
      if (!args.start) throw new Error('calendar: creating needs `start`');
      return invoke('calendar', 'create', {
        title: args.title,
        start: toEpochSeconds(args.start),
        ...(args.end === undefined ? {} : { end: toEpochSeconds(args.end) }),
        ...(args.allDay === undefined ? {} : { allDay: args.allDay }),
        ...(args.location === undefined ? {} : { location: args.location }),
        ...(args.notes === undefined ? {} : { notes: args.notes }),
      });
    }

    if (args.action === 'update' || args.action === 'delete') {
      if (!args.id) throw new Error(`calendar: ${args.action} needs the event's \`id\``);
      if (args.action === 'delete') return invoke('calendar', 'delete', { id: args.id });
      const changes = {
        ...(args.title === undefined ? {} : { title: args.title }),
        ...(args.start === undefined ? {} : { start: toEpochSeconds(args.start) }),
        ...(args.end === undefined ? {} : { end: toEpochSeconds(args.end) }),
        ...(args.location === undefined ? {} : { location: args.location }),
        ...(args.notes === undefined ? {} : { notes: args.notes }),
      };
      if (Object.keys(changes).length === 0) {
        throw new Error('calendar: updating needs at least one of title, start, end, location or notes');
      }
      return invoke('calendar', 'update', { id: args.id, ...changes });
    }

    const from = toEpochSeconds(args.from, Math.floor(Date.now() / 1000));
    const to = toEpochSeconds(args.to, from + DEFAULT_RANGE_DAYS * 86400);
    if (to <= from) throw new Error("calendar: 'to' must be after 'from'");
    return invoke('calendar', 'list', { from, to });
  },
});

const reminders = defineTool({
  name: 'reminders',
  description:
    'The user\'s Reminders app on this device: list what they have to do, and — only with their '
    + 'confirmation — add one, mark one done, or delete one.\n'
    + 'This is not the same as `notify`. `notify` is this app\'s own alert and leaves nothing '
    + 'behind, so it is the right answer to "remind me in twenty minutes". A reminder here is a row '
    + 'in their Reminders app that syncs to their other devices and may sit in a list they share, '
    + 'so every write asks them first and they may say no — check `saved`/`deleted` in the result '
    + 'before telling them it is done.',
  parameters: {
    action: {
      type: 'string',
      enum: ['list', 'create', 'complete', 'delete'],
      description: 'list the reminders, add one, mark one done, or delete one',
      required: true,
    },
    includeCompleted: {
      type: 'boolean',
      description: 'list: include the ones already done; by default only the unfinished ones',
    },
    title: { type: 'string', description: 'create: what the reminder says; required' },
    due: {
      type: 'string',
      description: 'create: when it is due, YYYY-MM-DD or a full ISO timestamp. Without one it never alerts',
    },
    notes: { type: 'string', description: 'create: free-text notes on the reminder' },
    id: { type: 'string', description: 'complete/delete: the reminder, as `list` returned its id' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'create') {
        return text(value.saved ? 'They confirmed; the reminder is in their list.' : 'They declined. Nothing was added.');
      }
      if (args.action === 'complete') {
        if (value.unchanged) return text('That one is already done.');
        return text(value.saved ? 'They confirmed; it is marked done.' : 'They declined. It is still open.');
      }
      if (args.action === 'delete') {
        return text(value.deleted ? 'They confirmed; the reminder is deleted.' : 'They declined. It is still there.');
      }
      const list = value.reminders ?? [];
      if (list.length === 0) return text('Nothing on their reminders.');
      const lines = list.map((item) => {
        const when = item.due ? `${dayOf(item.due)} ${timeOf(item.due)}` : 'no due date';
        const parts = [`${item.completed ? '[done] ' : ''}${when}`, item.title || '(no title)'];
        if (item.list) parts.push(`[${item.list}]`);
        const line = parts.join('  ');
        return item.notes ? `${line}\n    ${item.notes.replace(/\n+/g, ' ')}` : line;
      });
      if (value.truncated) {
        lines.push(`… showing the first ${list.length} of ${value.total}.`);
      }
      return text(lines.join('\n'));
    },
  },
  execute: async (args) => {
    if (args.action === 'list') {
      return invoke('reminders', 'list', {
        ...(args.includeCompleted === undefined ? {} : { includeCompleted: args.includeCompleted }),
      });
    }
    if (args.action === 'create') {
      if (!args.title) throw new Error('reminders: creating needs `title`');
      return invoke('reminders', 'create', {
        title: args.title,
        ...(args.due === undefined ? {} : { due: toEpochSeconds(args.due) }),
        ...(args.notes === undefined ? {} : { notes: args.notes }),
      });
    }
    if (!args.id) throw new Error(`reminders: ${args.action} needs the reminder's \`id\``);
    return invoke('reminders', args.action, { id: args.id });
  },
});

const openUrl = defineTool({
  name: 'open_url',
  description:
    'Hand a URL to the app that owns it on this phone: a map, a draft email or text, the dialler '
    + 'with a number filled in, the App Store, or a web page in the browser. Use it when the user '
    + 'asked you to take them somewhere; to merely offer a link, write a Markdown link in your '
    + 'reply instead, which works for any scheme and leaves the choice to them. Only a short list '
    + 'of schemes is allowed, each one landing somewhere the user still has to act.',
  parameters: {
    url: { type: 'string', description: 'the URL, with its scheme', required: true },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => text(`Opened ${value.url} in whichever app handles it.`),
  },
  // `url` is required in the schema above, so defineTool refuses a call without
  // it before we get here — no second check.
  execute: async (args) => invoke('open', 'url', { url: args.url }),
});

const nlp = defineTool({
  name: 'text_analysis',
  description:
    'On-device text work that is cheaper or more private than doing it yourself, using Apple\'s '
    + 'NaturalLanguage framework. Nothing leaves the phone and it costs no tokens.\n'
    + '`similar` ranks a list of strings by how close their MEANING is to a query, which you cannot '
    + 'do yourself — it needs embedding vectors. Use it to narrow hundreds of file names, note '
    + 'titles or subjects down to the few worth opening.\n'
    + 'It gives you an ORDER, not a relevance score, and the order is only roughly right: treat the '
    + 'top handful as candidates to check, never as the answer, and do not conclude that a low '
    + 'number means "not relevant" — a correct best match often scores near zero.\n'
    + '`language` and `entities` are for bulk only. On text you can already see, your own reading '
    + 'is better than theirs — only call them when the text is not in front of you and there is a '
    + 'lot of it.',
  parameters: {
    action: {
      type: 'string',
      enum: ['similar', 'language', 'entities'],
      description: 'rank candidates by meaning, identify the language, or pull out names and places',
      required: true,
    },
    text: { type: 'string', description: 'the query for `similar`; the text to analyse otherwise', required: true },
    candidates: {
      type: 'array',
      items: { type: 'string' },
      description: 'similar: the strings to rank against `text`',
    },
    limit: { type: 'number', description: 'similar: how many matches to return; defaults to 10' },
    language: {
      type: 'string',
      description: 'similar: BCP-47 code of the query, when guessing it from a short query would be unreliable',
    },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'language') {
        if (!value.language) return text('Could not tell what language that is.');
        const ranked = (value.hypotheses ?? [])
          .map((row) => `${row.language} ${(row.confidence * 100).toFixed(0)}%`)
          .join(', ');
        return text(`Language: ${value.language}${ranked ? ` (${ranked})` : ''}`);
      }
      if (args.action === 'entities') {
        if (!value.entities?.length) return text('No people, places or organisations found.');
        const lines = value.entities.map((row) => `${row.type.replace(/Name$/, '')}  ${row.text}`);
        if (value.truncated) lines.push(`… showing the first ${value.entities.length} of ${value.total}`);
        return text(lines.join('\n'));
      }
      if (!value.matches?.length) return text('Nothing to rank.');
      // The cosine value is deliberately NOT printed. It is not a relevance
      // score — a correct best match measured 0.10 on device while an identical
      // string measured 1.00 — and a reader shown "0.10" discards a right
      // answer. The rank is the finding; the number stays in the JSON.
      // The index is printed because the caller usually holds a parallel array,
      // the file paths it took these names from, and has to map back to it.
      const lines = value.matches.map((row) => `${row.rank}. [${row.index}]  ${row.text}`);
      lines.unshift(`Closest in meaning, of ${value.compared} compared (an order, not a score):`);
      return text(lines.join('\n'));
    },
  },
  execute: async (args) => {
    if (args.action === 'similar' && !args.candidates?.length) {
      throw new Error('text_analysis: `similar` needs `candidates` to rank');
    }
    return invoke('nlp', args.action, {
      text: args.text,
      ...(args.candidates === undefined ? {} : { candidates: args.candidates }),
      ...(args.limit === undefined ? {} : { limit: args.limit }),
      ...(args.language === undefined ? {} : { language: args.language }),
    });
  },
});

/** Seconds as something a person says out loud: "1 h 25 min", "8 min". */
const duration = (seconds) => {
  const total = Math.round(seconds / 60);
  if (total < 60) return `${total} min`;
  return `${Math.floor(total / 60)} h ${total % 60} min`;
};

/** Metres, in the unit the distance deserves. */
const distance = (meters) =>
  (meters < 1000 ? `${Math.round(meters)} m` : `${(meters / 1000).toFixed(1)} km`);

const maps = defineTool({
  name: 'maps',
  description:
    'Find places, and work out how long it takes to get between two of them. Apple Maps answers '
    + 'these, so it needs no permission and never reads where the user is — "near me" needs their '
    + 'location first, which is a separate capability they have to switch on.\n'
    + '`search` finds places by name or kind, optionally around a coordinate. `eta` gives the '
    + 'travel time and distance between two places. `route` adds the turn-by-turn steps.',
  parameters: {
    action: { type: 'string', enum: ['search', 'eta', 'route'], description: 'which one', required: true },
    query: { type: 'string', description: 'search: what to look for, e.g. "pharmacy" or a place name' },
    nearLatitude: { type: 'number', description: 'search: centre the search here' },
    nearLongitude: { type: 'number', description: 'search: centre the search here' },
    radiusMeters: { type: 'number', description: 'search: how far around the centre to look; defaults to 10 km' },
    fromQuery: { type: 'string', description: 'eta/route: where to start, by name' },
    fromLatitude: { type: 'number', description: 'eta/route: where to start; skips a lookup' },
    fromLongitude: { type: 'number', description: 'eta/route: where to start; skips a lookup' },
    toQuery: { type: 'string', description: 'eta/route: where to end, by name' },
    toLatitude: { type: 'number', description: 'eta/route: where to end; skips a lookup' },
    toLongitude: { type: 'number', description: 'eta/route: where to end; skips a lookup' },
    mode: {
      type: 'string',
      enum: ['driving', 'walking', 'transit'],
      description: 'eta/route: how they are travelling; defaults to driving',
    },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'search') {
        if (!value.places?.length) return text('No places found for that.');
        const lines = value.places.map((place) => {
          const where = place.address ? `  ${place.address}` : '';
          return `${place.name}${where}`;
        });
        if (value.truncated) lines.push(`… showing the first ${value.places.length} of ${value.total}`);
        return text(lines.join('\n'));
      }
      const head = `${value.from} → ${value.to}: ${duration(value.seconds)}, ${distance(value.meters)} by ${value.mode}`;
      if (args.action === 'eta') return text(head);
      const steps = (value.steps ?? []).map((step) => `  ${step.instruction} (${distance(step.meters)})`);
      return text([head, ...(value.name ? [`via ${value.name}`] : []), ...steps].join('\n'));
    },
  },
  execute: async (args) => {
    if (args.action === 'search') {
      if (!args.query) throw new Error('maps: `search` needs `query`');
      return invoke('maps', 'search', {
        query: args.query,
        ...(args.nearLatitude === undefined ? {} : { nearLatitude: args.nearLatitude }),
        ...(args.nearLongitude === undefined ? {} : { nearLongitude: args.nearLongitude }),
        ...(args.radiusMeters === undefined ? {} : { radiusMeters: args.radiusMeters }),
      });
    }
    const ends = {};
    for (const key of ['fromQuery', 'fromLatitude', 'fromLongitude', 'toQuery', 'toLatitude', 'toLongitude']) {
      if (args[key] !== undefined) ends[key] = args[key];
    }
    if (!ends.fromQuery && ends.fromLatitude === undefined) {
      throw new Error(`maps: \`${args.action}\` needs \`fromQuery\`, or \`fromLatitude\` and \`fromLongitude\``);
    }
    if (!ends.toQuery && ends.toLatitude === undefined) {
      throw new Error(`maps: \`${args.action}\` needs \`toQuery\`, or \`toLatitude\` and \`toLongitude\``);
    }
    return invoke('maps', args.action, { ...ends, ...(args.mode === undefined ? {} : { mode: args.mode }) });
  },
});

const vision = defineTool({
  name: 'read_image',
  description:
    'Read what is in an image file on this device: the text in it, barcodes and QR codes, what it '
    + 'is a picture of, or how many faces are in it. Runs on the phone — the image is never '
    + 'uploaded and it costs no tokens, so prefer it over attaching a picture when you only need '
    + 'the text out of it. Faces are counted and located, never identified.',
  parameters: {
    action: {
      type: 'string',
      enum: ['text', 'barcodes', 'classify', 'faces'],
      description: 'read the text, find barcodes, say what it is a picture of, or count faces',
      required: true,
    },
    path: { type: 'string', description: 'path to the image file', required: true },
    level: {
      type: 'string',
      enum: ['accurate', 'fast'],
      description: 'text: accuracy over speed; defaults to accurate',
    },
    languages: {
      type: 'array',
      items: { type: 'string' },
      description: 'text: BCP-47 codes to recognise; defaults to Chinese and English',
    },
    minimumConfidence: { type: 'number', description: 'classify: drop labels below this; defaults to 0.1' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'text') {
        if (!value.text) return text('No text found in that image.');
        const note = value.truncated ? `\n… showing the first ${value.lines.length} of ${value.total} lines` : '';
        return text(value.text + note);
      }
      if (args.action === 'barcodes') {
        if (!value.codes?.length) return text('No barcodes or QR codes found.');
        return text(value.codes.map((code) => `${code.symbology}  ${code.payload}`).join('\n'));
      }
      if (args.action === 'faces') {
        return text(value.count === 0 ? 'No faces found.'
                                      : `${value.count} face${value.count === 1 ? '' : 's'} found.`);
      }
      if (!value.labels?.length) return text('Nothing recognisable in that image.');
      return text(value.labels
        .map((row) => `${(row.confidence * 100).toFixed(0)}%  ${row.label}`)
        .join('\n'));
    },
  },
  execute: async (args) => invoke('vision', args.action, {
    path: args.path,
    ...(args.level === undefined ? {} : { level: args.level }),
    ...(args.languages === undefined ? {} : { languages: args.languages }),
    ...(args.minimumConfidence === undefined ? {} : { minimumConfidence: args.minimumConfidence }),
  }),
});

const clipboard = defineTool({
  name: 'clipboard',
  description:
    'Read, replace or empty what the user last copied. Reading raises a banner naming this app '
    + 'every time — that is iOS telling them, and it is why this is worth asking for only when they '
    + 'actually meant the clipboard ("what did I just copy", "paste that into the file"). What '
    + 'someone copied last is often the most sensitive thing on their phone, so do not read it to '
    + 'see whether it might be useful.',
  parameters: {
    action: { type: 'string', enum: ['get', 'set', 'clear'], description: 'read it, replace it, or empty it', required: true },
    text: { type: 'string', description: 'set: what to put there' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'get') {
        if (value.text === null || value.text === undefined) {
          const kinds = value.kinds?.length ? ` It holds: ${value.kinds.join(', ')}.` : '';
          return text(`The clipboard holds no text.${kinds}`);
        }
        return text(value.truncated
          ? `${value.text}\n… ${value.characters} characters shown; it is longer`
          : value.text);
      }
      if (args.action === 'clear') {
        return text(value.cleared ? 'Clipboard emptied.' : 'They declined; the clipboard is unchanged.');
      }
      return text(value.saved
        ? `Copied ${value.characters} characters to the clipboard.`
        : 'They declined; the clipboard is unchanged.');
    },
  },
  execute: async (args) => {
    if (args.action === 'set' && args.text === undefined) {
      throw new Error('clipboard: `set` needs `text`');
    }
    return invoke('clipboard', args.action, args.action === 'set' ? { text: args.text } : {});
  },
});

const location = defineTool({
  name: 'location',
  description:
    'Where the phone is right now, and turning addresses into coordinates and back. One reading at '
    + 'a time, only while the app is open — there is no tracking and no history. `geocode` and '
    + '`reverse` are Apple\'s servers and cost the user no privacy at all, so prefer them when the '
    + 'question is about a place rather than about where the user is. Feed the coordinates to '
    + '`maps` for "what is near me".',
  parameters: {
    action: {
      type: 'string',
      enum: ['current', 'geocode', 'reverse'],
      description: 'read the current position, an address → a point, or a point → an address',
      required: true,
    },
    address: { type: 'string', description: 'geocode: the address or place name' },
    latitude: { type: 'number', description: 'reverse: the point' },
    longitude: { type: 'number', description: 'reverse: the point' },
    accuracy: {
      type: 'string',
      enum: ['coarse', 'precise'],
      description: 'current: precise costs battery and takes longer; defaults to coarse, which answers "which city"',
    },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'current') {
        return text(`${value.latitude.toFixed(5)}, ${value.longitude.toFixed(5)}`
          + ` (±${Math.round(value.accuracyMeters)} m)`);
      }
      if (args.action === 'geocode') {
        const where = [value.name, value.locality, value.country].filter(Boolean).join(', ');
        return text(`${where}: ${value.latitude.toFixed(5)}, ${value.longitude.toFixed(5)}`);
      }
      const parts = [value.name, value.thoroughfare, value.locality, value.administrativeArea,
                     value.postalCode, value.country].filter(Boolean);
      return text(parts.length ? parts.join(', ') : 'Nothing is known about that point.');
    },
  },
  execute: async (args) => {
    if (args.action === 'geocode' && !args.address) {
      throw new Error('location: `geocode` needs `address`');
    }
    if (args.action === 'reverse' && (args.latitude === undefined || args.longitude === undefined)) {
      throw new Error('location: `reverse` needs `latitude` and `longitude`');
    }
    if (args.action === 'geocode') return invoke('location', 'geocode', { address: args.address });
    if (args.action === 'reverse') {
      return invoke('location', 'reverse', { latitude: args.latitude, longitude: args.longitude });
    }
    return invoke('location', 'current', args.accuracy === undefined ? {} : { accuracy: args.accuracy });
  },
});

/** Tool definitions by the capability each one needs. */
export const TOOLS = {
  device: device,
  notify: notify,
  speak: speak,
  calendar: calendar,
  reminders: reminders,
  open: openUrl,
  nlp: nlp,
  maps: maps,
  vision: vision,
  clipboard: clipboard,
  location: location,
};
