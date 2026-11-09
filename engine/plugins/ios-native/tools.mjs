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
 * Exported so that behaviour can be pinned by a test. Shared by `calendar` and
 * `health`, which is why the message names no tool: a health range failing with
 * "calendar: ..." sends the reader looking in the wrong place.
 */
export function toEpochSeconds(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  if (typeof value !== 'string') throw new Error(`'${value}' is not a date`);
  const bare = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
  const date = bare
    ? new Date(Number(bare[1]), Number(bare[2]) - 1, Number(bare[3]))
    : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error(`could not read the date '${value}'`);
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
    + '`search` finds places by name or kind, optionally around a coordinate. `eta` and `route` '
    + 'take COORDINATES, not names: look the two ends up first with `search` or `location geocode` '
    + 'and pick them yourself. That is on purpose — a geocoder answers something even when it does '
    + 'not know a place, and a wrong match hidden inside a route reads like a real answer.',
  parameters: {
    action: { type: 'string', enum: ['search', 'eta', 'route'], description: 'which one', required: true },
    query: { type: 'string', description: 'search: what to look for, e.g. "pharmacy" or a place name' },
    nearLatitude: { type: 'number', description: 'search: centre the search here' },
    nearLongitude: { type: 'number', description: 'search: centre the search here' },
    radiusMeters: { type: 'number', description: 'search: how far around the centre to look; defaults to 10 km' },
    fromLatitude: { type: 'number', description: 'eta/route: where to start' },
    fromLongitude: { type: 'number', description: 'eta/route: where to start' },
    toLatitude: { type: 'number', description: 'eta/route: where to end' },
    toLongitude: { type: 'number', description: 'eta/route: where to end' },
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
    for (const key of ['fromLatitude', 'fromLongitude', 'toLatitude', 'toLongitude']) {
      if (args[key] !== undefined) ends[key] = args[key];
    }
    if (Object.keys(ends).length < 4) {
      throw new Error(`maps: \`${args.action}\` needs both ends as coordinates`
        + ' (`fromLatitude`/`fromLongitude` and `toLatitude`/`toLongitude`).'
        + ' Find them with `search` or `location geocode` first and choose which result you meant.');
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
      // Vision names over a thousand things in any photo and most scores are near
      // zero. The confidences come through as they are: where "relevant" begins
      // is your judgement about this image, not a number we picked.
      const lines = value.labels.map((row) => `${(row.confidence * 100).toFixed(0)}%  ${row.label}`);
      if (value.truncated) lines.push(`… the most confident ${value.labels.length} of ${value.total}`);
      return text(lines.join('\n'));
    },
  },
  execute: async (args) => invoke('vision', args.action, {
    path: args.path,
    ...(args.level === undefined ? {} : { level: args.level }),
    ...(args.languages === undefined ? {} : { languages: args.languages }),
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
    + 'question is about a place rather than about where the user is.\n'
    + 'They return EVERY candidate, not a best guess: a geocoder answers something even when it '
    + 'does not know the place, so read the list and choose. Feed the coordinates you chose to '
    + '`maps` for a route, or for "what is near me".',
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
      // Every candidate the geocoder gave, in its order — choosing among them is
      // the caller's job, and the numbering is how they say which one they meant.
      if (!value.places?.length) return text('Nothing was found for that.');
      const lines = value.places.map((place, i) => {
        const where = [place.name, place.thoroughfare, place.locality, place.administrativeArea,
                       place.postalCode, place.country].filter(Boolean).join(', ');
        return `${i + 1}. ${where}  (${place.latitude.toFixed(5)}, ${place.longitude.toFixed(5)})`;
      });
      if (value.places.length > 1) {
        lines.unshift(`${value.total} places match — pick the one you meant before routing:`);
      }
      return text(lines.join('\n'));
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

const transcribe = defineTool({
  name: 'transcribe_audio',
  description:
    'Read what is said in an audio file already on this device: a voice memo, a recorded meeting, '
    + 'an audio attachment. Runs on the phone by default, so the recording is not uploaded and it '
    + 'costs no tokens — prefer it over attaching the audio itself.\n'
    + 'It reads a FILE. It does not listen to the microphone and cannot record: there is no live '
    + 'dictation here, so do not offer it.\n'
    + '`text` is Apple\'s own best reading of the audio and the other readings come back in '
    + '`alternatives` — when the transcript has a word that makes no sense in context, look there '
    + 'before guessing.',
  parameters: {
    action: {
      type: 'string',
      enum: ['file', 'languages'],
      description: 'transcribe one audio file, or list the languages this device can recognise',
      required: true,
    },
    path: { type: 'string', description: 'file: path to the audio file' },
    language: {
      type: 'string',
      description: 'file: BCP-47 code to recognise, e.g. zh-CN or en-US; defaults to the language the phone is set to',
    },
    onDevice: {
      type: 'boolean',
      description:
        'file: keep recognition on the phone. Defaults to true. Passing false sends the recording to '
        + 'Apple\'s servers, so ask the user first and tell them afterwards that it was uploaded.',
    },
    punctuation: { type: 'boolean', description: 'file: let Apple punctuate the transcript; defaults to true' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'languages') {
        const fallback = value.default
          ? `\ndefault: ${value.default}${value.defaultSupportsOnDevice ? '' : ' (server-only on this device)'}`
          : '\nno recogniser for the language this phone is set to';
        return text(`${value.total} languages: ${value.languages.join(', ')}${fallback}`);
      }
      if (!value.text) return text('Nothing was said in that recording, or none of it could be made out.');
      const others = value.alternativeCount > 1
        ? `\n… Apple's best of ${value.alternativeCount} readings; the others are in "alternatives"`
        : '';
      // Said every time it happens, because the user cannot see that their
      // recording left the phone and would have no other way to learn it.
      const uploaded = value.onDevice
        ? ''
        : '\n… this was transcribed by Apple\'s servers, so the recording left the phone — tell the user';
      const cut = value.segmentsTruncated
        ? `\n… the transcript is complete; only the timed word list was cut to ${value.segments.length} of ${value.segmentTotal}`
        : '';
      return text(value.text + others + uploaded + cut);
    },
  },
  execute: async (args) => {
    if (args.action === 'languages') return invoke('transcribe', 'languages', {});
    if (args.path === undefined) throw new Error('transcribe_audio: `file` needs `path`');
    return invoke('transcribe', 'file', {
      path: args.path,
      ...(args.language === undefined ? {} : { language: args.language }),
      ...(args.onDevice === undefined ? {} : { onDevice: args.onDevice }),
      ...(args.punctuation === undefined ? {} : { punctuation: args.punctuation }),
    });
  },
});

const HEALTH_DEFAULT_DAYS = 7;

/** `YYYY-MM-DD HH:MM`, from stamps the addon already wrote in device-local time. */
const stampOf = (iso) => `${dayOf(iso)} ${timeOf(iso)}`;

/** Enough digits to read, not enough to look like precision nobody measured. */
function healthNumber(value) {
  if (typeof value !== 'number') return '—';
  if (Number.isInteger(value)) return String(value);
  return Math.abs(value) >= 10 ? value.toFixed(0) : value.toFixed(2);
}

const health = defineTool({
  name: 'health',
  description:
    'Apple Health on this device, READ ONLY: steps, distance, stairs, energy, exercise and stand '
    + 'minutes, heart rate and HRV, breathing, blood oxygen, blood pressure, weight and body '
    + 'measurements, sleep, mindfulness, water and food energy. Call `types` first for what can be '
    + 'read and in which unit. Nothing here writes to Health, and there is no operation that can.\n'
    + 'Prefer `aggregate` for anything about activity. A day of step data is hundreds of fragments, '
    + 'so "how far did I walk last week" cannot be answered from raw samples — and raw samples from '
    + 'an iPhone and a Watch overlap, so adding them up double counts. `aggregate` is HealthKit\'s '
    + 'own statistics, which do not.\n'
    + 'iOS never says whether a read was allowed — Apple withholds that on purpose, so that being '
    + 'refused is not itself a disclosure. An empty answer means EITHER the user did not allow that '
    + 'type OR there is genuinely nothing recorded, and nothing can tell the two apart. Say it could '
    + 'be either; never report "you have no data" and never report "access is off".',
  parameters: {
    action: {
      type: 'string',
      enum: ['types', 'read', 'aggregate'],
      description: 'list the readable types, read raw samples, or total/average them per interval',
      required: true,
    },
    type: { type: 'string', description: 'read/aggregate: the type, as `types` returned its id (e.g. stepCount)' },
    from: {
      type: 'string',
      description: `read/aggregate: start of the range, YYYY-MM-DD or a full ISO timestamp; defaults to ${HEALTH_DEFAULT_DAYS} days before 'to'`,
    },
    to: { type: 'string', description: "read/aggregate: end of the range; defaults to now" },
    limit: { type: 'number', description: 'read: how many samples, newest first; defaults to 100, capped at 500' },
    interval: {
      type: 'string',
      enum: ['hour', 'day', 'week', 'month'],
      description: 'aggregate: one bucket per hour, day, week or month; defaults to day',
    },
    unit: {
      type: 'string',
      description: "the unit to read values in, HealthKit's own spelling (count, kg, km, kcal, count/min, %, degC); defaults to the one `types` names",
    },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'types') {
        return text((value.types ?? []).map((row) => {
          const bits = [row.kind];
          if (row.unit) bits.push(row.unit);
          if (row.aggregatesAs) bits.push(`aggregate → ${row.aggregatesAs}`);
          return `${row.id}  (${bits.join(', ')})\n    ${row.about}`;
        }).join('\n'));
      }
      if (args.action === 'read') {
        const samples = value.samples ?? [];
        if (samples.length === 0) {
          return text(`No ${value.type} samples between ${dayOf(value.from)} and ${dayOf(value.to)}.\n${value.emptyMeans ?? ''}`.trim());
        }
        const lines = samples.map((sample) => {
          const when = sample.start === sample.end
            ? stampOf(sample.start)
            : `${stampOf(sample.start)} – ${dayOf(sample.end) === dayOf(sample.start) ? timeOf(sample.end) : stampOf(sample.end)}`;
          // A category sample's name is the value; a quantity's is a number and a unit.
          const what = sample.valueName ?? `${healthNumber(sample.value)}${value.unit ? ` ${value.unit}` : ''}`;
          return `${when}  ${what}${sample.source ? `  [${sample.source}]` : ''}`;
        });
        if (value.truncated) {
          lines.push(`… the newest ${samples.length}; there are more. Narrow the range, raise \`limit\` (max 500), or use \`aggregate\`.`);
        }
        return text(lines.join('\n'));
      }
      const buckets = value.buckets ?? [];
      const lines = [`${value.type} · ${value.stat} per ${value.interval} · ${value.unit}`];
      for (const bucket of buckets) {
        const when = value.interval === 'hour' ? stampOf(bucket.start) : dayOf(bucket.start);
        // Null is "HealthKit had no samples here", which is not the same as zero —
        // a watch left on the table and a day spent sitting still look different.
        if (bucket.value === null) { lines.push(`${when}  —`); continue; }
        const span = bucket.min === undefined ? '' : `  (${healthNumber(bucket.min)}–${healthNumber(bucket.max)})`;
        lines.push(`${when}  ${healthNumber(bucket.value)}${span}`);
      }
      if (value.truncated) lines.push(`… ${buckets.length} of ${value.total} buckets.`);
      if (value.emptyMeans) lines.push(value.emptyMeans);
      return text(lines.join('\n'));
    },
  },
  execute: async (args) => {
    if (args.action === 'types') return invoke('health', 'types');
    if (!args.type) {
      throw new Error(`health: ${args.action} needs \`type\`; call \`types\` for the ones this app can read`);
    }
    const to = toEpochSeconds(args.to, Math.floor(Date.now() / 1000));
    const from = toEpochSeconds(args.from, to - HEALTH_DEFAULT_DAYS * 86400);
    if (to <= from) throw new Error("health: 'to' must be after 'from'");
    const window = { type: args.type, from, to, ...(args.unit === undefined ? {} : { unit: args.unit }) };
    if (args.action === 'read') {
      return invoke('health', 'read', { ...window, ...(args.limit === undefined ? {} : { limit: args.limit }) });
    }
    return invoke('health', 'aggregate', {
      ...window, ...(args.interval === undefined ? {} : { interval: args.interval }),
    });
  },
});

const photos = defineTool({
  name: 'photos',
  description:
    'Read the metadata of the photos and videos on this device, list its albums, or export one '
    + 'photo to a file. Nothing here returns image data: use `list` or `albums` to find the picture '
    + 'you mean, then `export` to get a file path and read it with read_image — all on the phone, so '
    + 'a receipt or a screenshot never has to be uploaded.\n'
    + 'Photos come back in the library\'s own order, which is OLDEST FIRST, so ask for a stretch of '
    + 'time with from/to or pass newestFirst when the question is about recent pictures.\n'
    + 'If the reply says access is "limited", the user shared a few photos rather than their '
    + 'library: relay that instead of telling them how many photos they have.',
  parameters: {
    action: {
      type: 'string',
      enum: ['list', 'albums', 'export'],
      description: 'list photo metadata, list the albums, or export one photo to a file',
      required: true,
    },
    from: { type: 'number', description: 'list: earliest creation time, seconds since 1970' },
    to: { type: 'number', description: 'list: latest creation time, seconds since 1970' },
    album: { type: 'string', description: 'list: restrict to one album, by the id `albums` returned' },
    newestFirst: { type: 'boolean', description: 'list: newest first instead of the library order; defaults to false' },
    limit: { type: 'number', description: 'list: how many to return, at most 200' },
    id: { type: 'string', description: 'export: which photo, by the id `list` returned' },
    maxPixels: { type: 'number', description: 'export: cap the longest edge in pixels; omit for full resolution' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      // The limited-access note goes first, every time: a count taken from a
      // handful of shared photos reads exactly like a count of their library.
      const note = value.access === 'limited' ? `${value.note}\n\n` : '';
      if (args.action === 'albums') {
        const list = value.albums ?? [];
        if (list.length === 0) return text(`${note}No albums on this device.`);
        return text(note + list.map((a) => `${a.count}\t${a.title || '(untitled)'}\t${a.kind}\t${a.id}`).join('\n')
          + (value.truncated ? `\n… ${value.total} albums in all.` : ''));
      }
      if (args.action === 'export') {
        return text(`${note}Exported to ${value.path} — ${value.width}x${value.height} jpeg, `
          + `${Math.round(value.bytes / 1024)} KB. Read it with read_image.`);
      }
      const list = value.photos ?? [];
      if (list.length === 0) return text(`${note}No photos match that.`);
      return text(note + list.map((p) => `${p.created}\t${p.width}x${p.height}`
        + `${p.isVideo ? `\tvideo ${Math.round(p.duration)}s` : ''}${p.favorite ? '\t★' : ''}\t${p.id}`).join('\n')
        + (value.truncated ? `\n… ${value.total} in all; narrow it with from/to.` : ''));
    },
  },
  execute: (args) => invoke('photos', args.action, {
    ...(args.from === undefined ? {} : { from: args.from }),
    ...(args.to === undefined ? {} : { to: args.to }),
    ...(args.album === undefined ? {} : { album: args.album }),
    ...(args.newestFirst === undefined ? {} : { newestFirst: args.newestFirst }),
    ...(args.limit === undefined ? {} : { limit: args.limit }),
    ...(args.id === undefined ? {} : { id: args.id }),
    ...(args.maxPixels === undefined ? {} : { maxPixels: args.maxPixels }),
  }),
});

const homekit = defineTool({
  name: 'homekit',
  description:
    'Read and control the user\'s HomeKit home: list homes, rooms and accessories, read one '
    + 'accessory in full with its characteristics and current values, write one characteristic, '
    + 'list scenes, and run one.\n'
    + 'Values come straight from HomeKit and are NOT translated for you — read a characteristic\'s '
    + '`type` to know which one it is, and its `metadata` (format, minimumValue, maximumValue, '
    + 'units) to work out what a number means. Categories are HomeKit\'s own constants.\n'
    + 'When a name matches more than one accessory or scene, `get` returns every match while `set` '
    + 'and `trigger` refuse and list them: pick one and pass its uniqueIdentifier. Writing may stop '
    + 'for the user to confirm, depending on their setting.',
  parameters: {
    action: {
      type: 'string',
      enum: ['list', 'get', 'set', 'scenes', 'trigger'],
      description: 'list the home, read one accessory, set one characteristic, list scenes, or run a scene',
      required: true,
    },
    name: { type: 'string', description: "get: the accessory's name; trigger: the scene's name" },
    uniqueIdentifier: { type: 'string', description: 'get: the accessory to read, when a name matched several' },
    accessory: { type: 'string', description: 'set: the accessory to change, by name or uniqueIdentifier' },
    characteristic: {
      type: 'string',
      description: 'set: which characteristic to write, by `type` or `uniqueIdentifier` from `get`. '
        + 'Use the uniqueIdentifier when one accessory has the same characteristic twice, like a two-gang switch',
    },
    value: { type: 'number', description: 'set: the new value; a bool characteristic takes 0 or 1' },
    valueText: { type: 'string', description: 'set: the new value when the characteristic is a string' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'list') {
        const homes = value.homes ?? [];
        if (homes.length === 0) return text('No homes are set up on this device.');
        const lines = [];
        for (const home of homes) {
          lines.push(`${home.name}${home.primary ? ' (primary)' : ''}  hub state ${home.homeHubState}`);
          for (const item of home.accessories ?? []) {
            lines.push(`  ${item.name}  ${item.room ?? '-'}  ${item.categoryLocalizedDescription}`
              + `${item.reachable ? '' : '  UNREACHABLE'}  ${item.uniqueIdentifier}`);
          }
        }
        if (value.truncated) lines.push(`… ${value.total} accessories in all`);
        return text(lines.join('\n'));
      }
      if (args.action === 'get') {
        const lines = [];
        for (const item of value.accessories ?? []) {
          lines.push(`${item.name}  ${item.room ?? '-'}  ${item.categoryLocalizedDescription}`
            + `${item.reachable ? '' : '  UNREACHABLE'}  ${item.uniqueIdentifier}`);
          for (const service of item.services ?? []) {
            lines.push(`  service ${service.name} (${service.localizedDescription})`);
            for (const c of service.characteristics ?? []) {
              const meta = c.metadata ?? {};
              const range = meta.minimumValue === undefined
                ? '' : ` [${meta.minimumValue}..${meta.maximumValue}${meta.units ? ` ${meta.units}` : ''}]`;
              lines.push(`    ${c.localizedDescription} = `
                + `${c.readError ? `(${c.readError})` : JSON.stringify(c.value)}`
                + `${range}  ${(c.properties ?? []).join(',')}  ${c.uniqueIdentifier}`);
            }
          }
        }
        if (value.total > (value.accessories ?? []).length) {
          lines.push(`… ${value.total} accessories match that name; pass a uniqueIdentifier to pick one`);
        }
        if (value.characteristicsTruncated) lines.push('… some characteristics were left out');
        if (value.valuesTimedOut) lines.push('some values did not come back in time and may be stale');
        return text(lines.join('\n'));
      }
      if (args.action === 'scenes') {
        const scenes = value.scenes ?? [];
        if (scenes.length === 0) return text('No scenes are set up.');
        const lines = scenes.map((s) =>
          `${s.name}  ${s.home}  ${s.actionSetType}  ${s.actionCount} actions  ${s.uniqueIdentifier}`);
        if (value.truncated) lines.push(`… ${value.total} scenes in all`);
        return text(lines.join('\n'));
      }
      if (args.action === 'trigger') {
        return text(value.executed ? 'Scene run.' : 'They declined; the scene did not run.');
      }
      return text(value.written ? 'Written.' : 'They declined; nothing was changed.');
    },
  },
  execute: (args) => {
    if (args.action === 'list') return invoke('homekit', 'list');
    if (args.action === 'scenes') return invoke('homekit', 'scenes');
    if (args.action === 'get') {
      if (!args.name && !args.uniqueIdentifier) throw new Error('homekit: `get` needs `name` or `uniqueIdentifier`');
      return invoke('homekit', 'get', {
        ...(args.uniqueIdentifier === undefined ? {} : { uniqueIdentifier: args.uniqueIdentifier }),
        ...(args.name === undefined ? {} : { name: args.name }),
      });
    }
    if (args.action === 'trigger') {
      if (!args.name) throw new Error('homekit: `trigger` needs the scene `name`');
      return invoke('homekit', 'trigger', { name: args.name });
    }
    if (!args.accessory) throw new Error('homekit: `set` needs `accessory`');
    if (!args.characteristic) throw new Error('homekit: `set` needs `characteristic`');
    // Two parameters because the schema has no union type and a characteristic
    // may be a number, a bool (0/1) or a string. Nothing here maps "on" to 1 —
    // inventing that mapping is exactly the kind of rule §4.5 refuses.
    const written = args.valueText === undefined ? args.value : args.valueText;
    if (written === undefined) {
      throw new Error('homekit: `set` needs `value`, or `valueText` for a string characteristic');
    }
    return invoke('homekit', 'set', {
      accessory: args.accessory, characteristic: args.characteristic, value: written,
    });
  },
});

const alarm = defineTool({
  name: 'alarm',
  description:
    'Set a real alarm clock on the user\'s device, or list and cancel ones you set. Unlike '
    + '`notify`, an alarm breaks through silent mode and Focus and keeps ringing until they stop '
    + 'it — so use it only for things they must not sleep through or miss, and use `notify` for '
    + 'ordinary reminders. Needs iOS 26 or later, and they must switch alarms on under Device '
    + 'capabilities first.',
  parameters: {
    action: {
      type: 'string',
      enum: ['list', 'create', 'cancel'],
      description: 'list the alarms you set, create one, or cancel one by id',
      required: true,
    },
    title: { type: 'string', description: 'what the alarm is for; required to create' },
    hour: { type: 'number', description: 'hour of day, 0-23; required to create' },
    minute: { type: 'number', description: 'minute of the hour, 0-59; required to create' },
    repeatWeekdays: {
      type: 'array',
      items: { type: 'string' },
      description: 'optional; lowercase English weekday names to repeat on, e.g. ["monday","friday"]. '
        + 'Omit for a one-off alarm at the next occurrence of that time.',
    },
    id: { type: 'string', description: 'the alarm to cancel, as create or list returned it' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'list') {
        const list = value.alarms ?? [];
        if (list.length === 0) return text('No alarms set.');
        return text(list.map((item) => {
          const at = typeof item.hour === 'number'
            ? `${String(item.hour).padStart(2, '0')}:${String(item.minute ?? 0).padStart(2, '0')}`
            : '';
          const days = (item.repeatWeekdays ?? []).join(' ');
          return [at, days, item.state, item.title ?? '', item.id].filter(Boolean).join('  ');
        }).join('\n'));
      }
      if (args.action === 'cancel') {
        return text(value.cancelled ? 'Alarm turned off.' : 'They declined; the alarm is still set.');
      }
      return text(value.saved ? `Alarm set (id ${value.id}).` : 'They declined; no alarm was set.');
    },
  },
  execute: async (args) => {
    if (args.action === 'create') {
      if (!args.title) throw new Error('alarm: creating needs `title`');
      if (typeof args.hour !== 'number') throw new Error('alarm: creating needs `hour`');
      if (typeof args.minute !== 'number') throw new Error('alarm: creating needs `minute`');
      return invoke('alarm', 'create', {
        title: args.title,
        hour: args.hour,
        minute: args.minute,
        ...(args.repeatWeekdays === undefined ? {} : { repeatWeekdays: args.repeatWeekdays }),
      });
    }
    if (args.action === 'cancel') {
      if (!args.id) throw new Error('alarm: cancelling needs `id`');
      return invoke('alarm', 'cancel', { id: args.id });
    }
    return invoke('alarm', 'list');
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
  transcribe: transcribe,
  health: health,
  photos: photos,
  homekit: homekit,
  alarm: alarm,
};
