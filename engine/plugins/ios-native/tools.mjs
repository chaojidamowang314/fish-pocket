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
  // update and delete take this id and nothing else finds an event, so every line carries it.
  if (event.id) parts.push(`id ${event.id}`);
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
        return text(value.saved
          ? `They confirmed; the reminder is in their list${value.id ? ` (id ${value.id})` : ''}.`
          : 'They declined. Nothing was added.');
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
        // complete and delete take this id; a title is not one.
        if (item.id) parts.push(`id ${item.id}`);
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
      return text(value.created ? `Alarm set (id ${value.id}).` : 'They declined; no alarm was set.');
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
const contacts = defineTool({
  name: 'contacts',
  description:
    'Look someone up in the user\'s address book, for when another step needs their number or '
    + 'address ("text Zhang San", "email my landlord"). Read-only: nothing here adds, edits or '
    + 'deletes a contact, and nothing here sends anything.\n'
    + '`search` takes exactly ONE of name, phone or email — you say which field you are searching; '
    + 'it is not guessed from how the query looks. Each match already carries its phones and '
    + 'emails, which is usually all you need. Use `get` with an id from `search` only for the rest '
    + 'of a card: postal addresses, birthday, job title, nickname, URLs. Notes and pictures are '
    + 'never returned.\n'
    + 'Matches come in the address book\'s own order, NOT best first. When several people match, '
    + 'show them and ask which one was meant — never choose one yourself, least of all before '
    + 'sending something to them. The same goes for one person with several numbers.\n'
    + 'If the reply says access is "limited", the user shared only some contacts with this app: '
    + 'relay that, and never tell them someone is not in their contacts — only that they are not '
    + 'among the ones shared.',
  parameters: {
    action: {
      type: 'string',
      enum: ['search', 'get'],
      description: 'find contacts by one field, or read one contact\'s whole card',
      required: true,
    },
    name: {
      type: 'string',
      description:
        'search: a name to look for. Matches the start of any word in the name or the company, '
        + 'so "bell" finds Kate Bell and "ate" does not',
    },
    phone: {
      type: 'string',
      description:
        'search: a whole phone number. Spaces, dashes and brackets do not matter, but part of a '
        + 'number matches nothing, and a country code the card does not have can miss',
    },
    email: {
      type: 'string',
      description: 'search: a whole email address, any case. Part of one matches nothing',
    },
    limit: { type: 'number', description: 'search: how many to return; defaults to 25, at most 100' },
    id: { type: 'string', description: 'get: which contact, by the id `search` returned' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      // The limited-access note goes first, every time: "no match" among a few
      // shared contacts reads exactly like "not in your contacts".
      const limited = value.access === 'limited';
      const note = limited && value.note ? `${value.note}\n\n` : '';
      const labeled = (item) => `${item.label ? `${item.label}: ` : ''}${item.value ?? ''}`;
      const heading = (c) => c.name || c.organization || '(no name)';

      if (args.action === 'get') {
        const c = value.contact ?? {};
        const lines = [heading(c)];
        const parts = [
          ['given name', c.givenName], ['middle name', c.middleName], ['family name', c.familyName],
          ['nickname', c.nickname], ['organization', c.organization], ['department', c.department],
          ['job title', c.jobTitle],
        ];
        for (const [label, part] of parts) if (part) lines.push(`${label}: ${part}`);
        for (const p of c.phones ?? []) lines.push(`phone  ${labeled(p)}`);
        for (const e of c.emails ?? []) lines.push(`email  ${labeled(e)}`);
        for (const a of c.addresses ?? []) {
          // The formatter answers in lines; one line each keeps the card readable.
          const oneLine = String(a.formatted ?? '').split('\n').filter(Boolean).join(', ');
          lines.push(`address  ${a.label ? `${a.label}: ` : ''}${oneLine}`);
        }
        if (c.birthday) {
          const pad = (n) => String(n).padStart(2, '0');
          // A missing year stays missing. Most cards have none, and a made-up
          // one turns into a wrong age the moment someone does arithmetic on it.
          lines.push(`birthday: ${c.birthday.year === undefined ? '' : `${c.birthday.year}-`}`
            + `${pad(c.birthday.month)}-${pad(c.birthday.day)}`
            + `${c.birthday.year === undefined ? ' (no year on the card)' : ''}`);
        }
        for (const u of c.urls ?? []) lines.push(`url  ${labeled(u)}`);
        if (c.id) lines.push(`id: ${c.id}`);
        return text(note + lines.join('\n'));
      }

      const list = value.contacts ?? [];
      if (list.length === 0) {
        return text(limited
          ? `${note}No match among the contacts the user shared with this app.`
          : 'No contact matches that.');
      }
      const lines = [];
      if (list.length > 1) {
        lines.push(`${value.total ?? list.length} contacts match — show them and ask which one was meant.`);
      }
      list.forEach((c, index) => {
        const company = c.name && c.organization ? ` (${c.organization})` : '';
        lines.push(`${index + 1}. ${heading(c)}${company}  id ${c.id}`);
        for (const p of c.phones ?? []) lines.push(`   phone  ${labeled(p)}`);
        for (const e of c.emails ?? []) lines.push(`   email  ${labeled(e)}`);
        if (!(c.phones ?? []).length && !(c.emails ?? []).length) {
          lines.push('   no phone or email on this card');
        }
      });
      if (value.truncated) {
        lines.push(`… ${value.total} match in all and ${list.length} are shown; narrow the search or raise limit.`);
      }
      return text(note + lines.join('\n'));
    },
  },
  execute: async (args) => {
    if (args.action === 'get') {
      if (!args.id) throw new Error('contacts: `get` needs `id`');
      return invoke('contacts', 'get', { id: args.id });
    }
    // An empty string is a field the model filled in out of habit, not a query.
    const given = ['name', 'phone', 'email'].filter((key) => typeof args[key] === 'string' && args[key] !== '');
    if (given.length === 0) {
      throw new Error('contacts: `search` needs one of `name`, `phone` or `email`');
    }
    if (given.length > 1) {
      // Not "search all of them and merge": which field the query belongs to is
      // the one thing the caller has to decide, so two answers is no answer.
      throw new Error(`contacts: \`search\` takes exactly one of \`name\`, \`phone\`, \`email\` — got ${given.join(' and ')}. `
        + 'Search one field at a time');
    }
    return invoke('contacts', 'search', {
      [given[0]]: args[given[0]],
      ...(args.limit === undefined ? {} : { limit: args.limit }),
    });
  },
});

const compose = defineTool({
  name: 'compose',
  description:
    'Put a prefilled email or text message in front of the user, in Apple\'s own compose sheet. '
    + 'You do not send anything: the Send button is Apple\'s, only the user can tap it, and they '
    + 'can change every field first. So tell them you have opened a draft for them to send, and '
    + 'never say it was sent unless the result says `sent`.\n'
    + 'The call returns only once they have dealt with the sheet. `cancelled` and, for mail, '
    + '`saved` (they kept it as a draft) are ordinary answers, not errors — say what they chose '
    + 'and do not open the sheet again unless they ask. `sent` means handed to Mail\'s outbox or '
    + 'to Messages, not delivered.\n'
    + 'Never guess an address or a phone number: look it up with `contacts` first, or ask. '
    + '`mail` needs an account in Apple\'s Mail app and is refused without one — people who use '
    + 'another mail app often have none; give them the text to paste instead. `message` is '
    + 'refused on a device that cannot text. One sheet at a time.',
  parameters: {
    action: {
      type: 'string',
      enum: ['mail', 'message'],
      description: 'open an email draft, or a text message (iMessage/SMS) draft',
      required: true,
    },
    to: {
      type: 'array',
      items: { type: 'string' },
      description: 'recipients — mail: email addresses; message: phone numbers or Apple IDs',
    },
    cc: { type: 'array', items: { type: 'string' }, description: 'mail: addresses to copy' },
    bcc: { type: 'array', items: { type: 'string' }, description: 'mail: addresses to copy blind' },
    subject: { type: 'string', description: 'mail: the subject line' },
    body: { type: 'string', description: 'the text of the email or message' },
    html: { type: 'boolean', description: 'mail: `body` is HTML rather than plain text; defaults to false' },
    attachments: {
      type: 'array',
      items: { type: 'string' },
      description: 'paths of files to attach. Files only, not folders',
    },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      const mail = args.action === 'mail';
      const what = mail ? 'email' : 'message';
      if (value?.result === 'sent') {
        return text(mail
          ? 'They tapped Send. The email is in Mail\'s outbox — handed over, not confirmed delivered.'
          : 'They tapped Send. The message was handed to Messages — not confirmed delivered.');
      }
      if (value?.result === 'saved') {
        return text('They kept it as a draft in Mail instead of sending it. Nothing was sent.');
      }
      if (value?.result === 'cancelled') {
        return text(`They closed the sheet without sending. No ${what} was sent.`);
      }
      // An answer this tool has no words for must not read as success: the one
      // mistake that matters here is telling them something went out.
      return text(`The compose sheet did not say what happened. Do not assume the ${what} was sent.`);
    },
  },
  execute: async (args) => {
    const mail = args.action === 'mail';
    const lists = mail ? ['to', 'cc', 'bcc', 'attachments'] : ['to', 'attachments'];
    const strings = mail ? ['subject', 'body'] : ['body'];
    if (!mail) {
      // Dropping these quietly would show the user a draft missing something
      // the caller believes is in it.
      const extra = ['cc', 'bcc', 'subject', 'html'].filter((key) => args[key] !== undefined);
      if (extra.length > 0) {
        throw new Error(`compose: \`message\` has no ${extra.map((key) => `\`${key}\``).join(', ')}; `
          + 'a text message is only `to`, `body` and `attachments`');
      }
    }
    const fields = {};
    for (const key of lists) {
      const value = args[key];
      if (value === undefined) continue;
      if (!Array.isArray(value) || value.some((item) => typeof item !== 'string' || item === '')) {
        throw new Error(`compose: \`${key}\` must be an array of non-empty strings`);
      }
      if (value.length > 0) fields[key] = value;
    }
    for (const key of strings) {
      const value = args[key];
      if (value === undefined) continue;
      if (typeof value !== 'string') throw new Error(`compose: \`${key}\` must be a string`);
      if (value !== '') fields[key] = value;
    }
    if (Object.keys(fields).length === 0) {
      // An empty sheet is a caller that lost its arguments, not a request.
      const names = (mail ? ['to', 'cc', 'bcc', 'subject', 'body', 'attachments'] : ['to', 'body', 'attachments'])
        .map((key) => `\`${key}\``).join(', ');
      throw new Error(`compose: \`${args.action}\` needs at least one of ${names}`);
    }
    return invoke('compose', args.action, {
      ...fields,
      ...(mail && args.html !== undefined ? { html: args.html === true } : {}),
    });
  },
});

const music = defineTool({
  name: 'music',
  description:
    'Search the user\'s own music library and control playback in the Music app: find songs, '
    + 'albums, artists or playlists, start one playing, pause, skip, and say what is playing.\n'
    + 'LIBRARY ONLY. This sees what the user has bought, synced or added to their library — NOT '
    + 'the Apple Music catalogue. A song they never added cannot be found or played from here, so '
    + 'never promise "play any song": search first, and when nothing matches say it is not in '
    + 'their library.\n'
    + '`play` takes ids, not names: `search` (or `playlists`) first, then pass the id back exactly '
    + 'as it came — ids are long numbers kept as strings, and they break if turned into numbers. '
    + '`search` matches one field per kind (a song by its title, an album by its title, an artist '
    + 'or playlist by its name) and returns every match in library order, not best first. When '
    + 'several match, say which one you picked or ask; do not play the first silently.\n'
    + '`play` replaces whatever was queued in Music and keeps playing after this app is closed. '
    + '`play` with no target resumes what was paused. A song marked `cloud` is not downloaded and '
    + 'needs a connection. After `next` or `previous`, call `now` to see what is playing. Playing, '
    + 'pausing and skipping may stop for the user to confirm, depending on their setting.',
  parameters: {
    action: {
      type: 'string',
      enum: ['search', 'playlists', 'play', 'pause', 'next', 'previous', 'now'],
      description: 'search the library, list every playlist, start or resume playback, pause, skip '
        + 'forward, go back one, or report what is playing',
      required: true,
    },
    query: { type: 'string', description: 'search: text the title or name must contain' },
    kind: {
      type: 'string',
      enum: ['song', 'album', 'artist', 'playlist'],
      description: 'search: what to look for, default song',
    },
    limit: { type: 'number', description: 'search: how many to return, default 25, at most 100' },
    songs: {
      type: 'array',
      items: { type: 'string' },
      description: 'play: song ids from `search`, played in this order (at most 200)',
    },
    album: { type: 'string', description: 'play: an album id from `search`' },
    artist: { type: 'string', description: 'play: an artist id from `search`; plays everything by them in the library' },
    playlist: { type: 'string', description: 'play: a playlist id from `search` or `playlists`' },
    shuffle: { type: 'boolean', description: 'play: turn shuffle on or off; leave out to keep the user\'s own setting' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      const clock = (seconds) => {
        if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return '';
        const whole = Math.max(0, Math.round(seconds));
        return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
      };
      const songs = (n) => `${n ?? 0} ${n === 1 ? 'song' : 'songs'}`;
      const song = (item) => [
        item.title || '(untitled)',
        [item.artist, item.album].filter(Boolean).join(' · '),
      ].filter(Boolean).join(' — ');
      const more = (what) => (value.truncated ? [`… ${value.total} ${what} in all; only the first ones are shown`] : []);

      if (args.action === 'search') {
        const results = value.results ?? [];
        const kind = value.kind ?? args.kind ?? 'song';
        if (results.length === 0) {
          return text(`No ${kind} in their library matches "${args.query ?? ''}". `
            + 'This searches the library only, not the Apple Music catalogue.');
        }
        const lines = results.map((item) => (kind === 'song'
          ? `${song(item)}  ${clock(item.duration)}${item.cloud ? '  cloud' : ''}  ${item.id}`
          : `${item.title ?? item.name ?? '(unnamed)'}${item.artist ? ` — ${item.artist}` : ''}  ${songs(item.count)}  ${item.id}`));
        return text([...lines, ...more(`${kind}s match`)].join('\n'));
      }
      if (args.action === 'playlists') {
        const playlists = value.playlists ?? [];
        if (playlists.length === 0) return text('Their library has no playlists.');
        const lines = playlists.map((item) => `${item.name || '(unnamed)'}  ${songs(item.count)}  ${item.id}`);
        return text([...lines, ...more('playlists')].join('\n'));
      }
      if (args.action === 'play') {
        if (!value.played) return text('They declined; nothing was played.');
        if (value.kind === 'resume') {
          return text(value.item
            ? `Resumed: ${song(value.item)}.`
            : 'Told Music to play, but nothing was queued that this app can see. Check with `now`.');
        }
        const what = value.name ? `${value.kind} "${value.name}"` : 'the songs asked for';
        const first = value.shuffle
          ? ' Shuffled, so `now` says which song came first.'
          : (value.first ? ` First: ${value.first}.` : '');
        return text(`Playing ${what} (${songs(value.count)}).${first}`);
      }
      if (args.action === 'pause') {
        if (!value.paused) return text('They declined; playback was left as it was.');
        return text(value.item ? `Paused: ${song(value.item)}.` : 'Paused. Nothing was queued that this app can see.');
      }
      if (args.action === 'next' || args.action === 'previous') {
        if (!value.skipped) return text('They declined; playback was left as it was.');
        const from = value.from ? ` from ${song(value.from)}` : '';
        return text(`${args.action === 'next' ? 'Skipped forward' : 'Went back one'}${from}. `
          + 'Call `now` to see what is playing.');
      }
      if (!value.item) return text(`Nothing is queued in Music (${value.state ?? 'stopped'}).`);
      const at = clock(value.item.position);
      const of = clock(value.item.duration);
      return text(`${value.state ?? 'unknown'}: ${song(value.item)}`
        + `${at || of ? `  ${[at, of].filter(Boolean).join(' / ')}` : ''}`
        + `${value.item.cloud ? '  cloud' : ''}  ${value.item.id}`);
    },
  },
  execute: async (args) => {
    if (args.action === 'search') {
      if (!args.query) throw new Error('music: `search` needs `query`');
      return invoke('music', 'search', {
        query: args.query,
        ...(args.kind === undefined ? {} : { kind: args.kind }),
        ...(args.limit === undefined ? {} : { limit: args.limit }),
      });
    }
    if (args.action === 'play') {
      const given = ['songs', 'album', 'artist', 'playlist'].filter((key) => args[key] !== undefined);
      // Refused rather than resolved in some order: which of the two was meant
      // is the model's to say, and it is cheaper to say so here than after a
      // round trip to the addon.
      if (given.length > 1) {
        throw new Error(`music: \`play\` takes one of \`songs\`, \`album\`, \`artist\` or \`playlist\`, not ${given.map((key) => `\`${key}\``).join(' and ')}`);
      }
      return invoke('music', 'play', {
        ...(given.length === 0 ? {} : { [given[0]]: args[given[0]] }),
        ...(args.shuffle === undefined ? {} : { shuffle: args.shuffle }),
      });
    }
    return invoke('music', args.action);
  },
});

const files = defineTool({
  name: 'files',
  description:
    'Ask the user for a file from their Files app — iCloud Drive, On My iPhone, or any other '
    + 'provider there — or hand them a file you made. You cannot browse their files: `pick` opens '
    + 'the system picker, they choose, and you get only what they chose. Use it when they mention a '
    + 'file that is not in the workspace ("the PDF in my iCloud", "that spreadsheet I downloaded"). '
    + 'The call waits for them and returns when they are done.\n'
    + 'What comes back is a COPY inside the workspace, at the path returned. Editing it does not '
    + 'change their original — when they want the result back in Files, `export` it, which opens '
    + 'the picker again for them to choose where it goes. Your own file stays where it was.\n'
    + 'Closing the picker without choosing is a normal answer, not an error: say so and move on. '
    + 'Do not open it again on your own.\n'
    + '`types` narrows what they can tap, as uniform type identifiers (`public.image`, '
    + '`com.adobe.pdf`, `public.plain-text`) or filename extensions (`pdf`, `csv`). A string iOS '
    + 'does not recognise is refused rather than guessed at; leave `types` out and any file can be '
    + 'picked, which is the right default when you are not sure.',
  parameters: {
    action: {
      type: 'string',
      enum: ['pick', 'export'],
      description: 'ask the user for a file, or hand files to the user to save somewhere',
      required: true,
    },
    types: {
      type: 'array',
      items: { type: 'string' },
      description: 'pick: type identifiers or filename extensions they may choose from; omit for any file',
    },
    multiple: { type: 'boolean', description: 'pick: let them choose several files; defaults to false' },
    paths: {
      type: 'array',
      items: { type: 'string' },
      description: 'export: the files or directories to hand over',
    },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      if (args.action === 'export') {
        if (!value.saved) return text('They closed the picker without saving. Nothing left the workspace.');
        return text(`Saved ${value.count ?? 0} item${value.count === 1 ? '' : 's'} to the place they chose.`);
      }
      if (value.cancelled) return text('They closed the picker without choosing a file.');
      const size = (bytes) => (typeof bytes !== 'number' ? ''
        : bytes < 1024 ? `${bytes} B`
        : bytes < 1024 * 1024 ? `${Math.round(bytes / 1024)} KB`
        : `${(bytes / 1024 / 1024).toFixed(1)} MB`);
      const lines = [];
      // What did not arrive goes first: a list of paths that all look fine reads
      // as "everything they chose is here" unless something says otherwise.
      for (const failure of value.failed ?? []) {
        lines.push(`NOT copied: ${failure.name} — ${failure.error}`);
      }
      for (const file of value.files ?? []) {
        lines.push([file.path, file.directory ? 'directory' : size(file.bytes), file.type]
          .filter(Boolean).join('\t'));
      }
      return text(lines.length > 0 ? lines.join('\n') : 'They chose nothing.');
    },
  },
  execute: async (args) => {
    if (args.action === 'export') {
      if (!args.paths?.length) {
        throw new Error('files: `export` needs `paths`');
      }
      return invoke('files', 'export', { paths: args.paths });
    }
    return invoke('files', args.action, {
      ...(args.types === undefined ? {} : { types: args.types }),
      ...(args.multiple === undefined ? {} : { multiple: args.multiple }),
    });
  },
});

const weather = defineTool({
  name: 'weather',
  description:
    'Current conditions and forecasts for a point on the map, from Apple Weather. It needs no '
    + 'permission because it never reads where the user is: every call takes COORDINATES. For "the '
    + 'weather here" get them from `location` `current` first (that one does need the user\'s '
    + 'permission); for a named place use `location` `geocode` or `maps` `search` and choose the '
    + 'result you meant. A place name is not accepted here.\n'
    + '`current` is now, `hourly` the next hours (24 unless you say, up to 240), `daily` the next '
    + 'days starting today (7 unless you say, up to 10). There are no weather alerts, no '
    + 'minute-by-minute rain and no past weather.\n'
    + 'Units are fixed whatever the phone is set to: °C, km/h, hPa, km, mm. Humidity, cloud cover '
    + 'and chance of precipitation are fractions from 0 to 1. Wind direction is the bearing the '
    + 'wind comes FROM. Every time is UTC, not the local time at that place — convert before '
    + 'telling the user an hour. A day in `daily` is stamped with the UTC instant its local '
    + 'midnight falls on, so for places east of Greenwich the date reads one day early.\n'
    + 'The result ends with a "Weather data:" line naming the source and its legal page. Apple\'s '
    + 'licence requires that credit wherever the data is shown, so keep that line whenever you '
    + 'relay a forecast.',
  parameters: {
    action: {
      type: 'string',
      enum: ['current', 'hourly', 'daily'],
      description: 'conditions now, an hour-by-hour forecast, or a day-by-day one',
      required: true,
    },
    // Needed by every action, but not marked `required`: the schema check would
    // then answer a call that has only a place name with "missing required
    // property", and the refusal in `execute` — which says where coordinates
    // come from — would never be seen.
    latitude: { type: 'number', description: 'always needed: the point, -90 to 90' },
    longitude: { type: 'number', description: 'always needed: the point, -180 to 180' },
    hours: { type: 'number', description: 'hourly: how many hours ahead, 1 to 240; defaults to 24' },
    days: { type: 'number', description: 'daily: how many days starting today, 1 to 10; defaults to 7' },
  },
  output: {
    schema: { type: 'json' },
    render: (args, value) => {
      const number = (n, digits = 0) => (typeof n === 'number' ? n.toFixed(digits) : '?');
      const percent = (fraction) => (typeof fraction === 'number' ? `${Math.round(fraction * 100)}%` : '?');
      const stamp = (iso) => (typeof iso === 'string' ? `${iso.slice(0, 10)} ${iso.slice(11, 16)}` : '?');
      const sky = (entry) => entry.conditionDescription ?? entry.condition ?? 'unknown conditions';
      const zone = value.timeZone ?? 'UTC';
      // The credit is the last line of every shape, including the empty ones: the
      // licence attaches it to the data's source, not to how much data came back.
      const credit = value.attribution
        ? [`Weather data: ${value.attribution.service} — ${value.attribution.legalURL}`]
        : [];

      if (args.action === 'current') {
        const now = value.current;
        if (!now) return text(['No current conditions came back for that point.', ...credit].join('\n'));
        const wind = now.wind ?? {};
        const gust = typeof wind.gust === 'number' ? `, gusts ${number(wind.gust)} km/h` : '';
        return text([
          `${stamp(now.date)} ${zone}: ${sky(now)}, ${number(now.temperature, 1)}°C`
            + ` (feels like ${number(now.apparentTemperature, 1)}°C)`,
          `wind ${number(wind.speed)} km/h from ${number(wind.direction)}°${gust}`,
          `humidity ${percent(now.humidity)}, cloud cover ${percent(now.cloudCover)},`
            + ` dew point ${number(now.dewPoint, 1)}°C`,
          `pressure ${number(now.pressure)} hPa, visibility ${number(now.visibility, 1)} km,`
            + ` UV index ${number(now.uvIndex)}, ${now.isDaylight ? 'daylight' : 'dark'}`,
          ...credit,
        ].join('\n'));
      }

      const hourly = args.action === 'hourly';
      const entries = (hourly ? value.hours : value.days) ?? [];
      if (entries.length === 0) {
        return text([`No ${hourly ? 'hourly' : 'daily'} forecast came back for that point.`, ...credit].join('\n'));
      }
      const lines = hourly
        ? entries.map((hour) => `${stamp(hour.date)}  ${number(hour.temperature, 1)}°C`
            + ` (feels ${number(hour.apparentTemperature, 1)}°C)  ${sky(hour)}`
            + `  precipitation ${percent(hour.precipitationChance)} ${number(hour.precipitationAmount, 1)} mm`
            + `  wind ${number(hour.windSpeed)} km/h  humidity ${percent(hour.humidity)}`
            + `  UV ${number(hour.uvIndex)}`)
        : entries.map((day) => {
            // Absent at the poles in their season, so they are left off rather
            // than printed as unknown.
            const sun = [
              ...(day.sunrise ? [`sunrise ${stamp(day.sunrise).slice(11)}`] : []),
              ...(day.sunset ? [`sunset ${stamp(day.sunset).slice(11)}`] : []),
            ].join(' ');
            return `${stamp(day.date)}  ${number(day.low, 1)} to ${number(day.high, 1)}°C  ${sky(day)}`
              + `  precipitation ${percent(day.precipitationChance)} ${number(day.precipitationAmount, 1)} mm`
              + `  wind ${number(day.windSpeed)} km/h  UV ${number(day.uvIndex)}${sun ? `  ${sun}` : ''}`;
          });
      lines.unshift(hourly
        ? `Hour by hour, times in ${zone}:`
        : `Day by day. Each line starts with the ${zone} instant that day begins at that place`
          + ' (its local midnight), so the date can read a day early:');
      if (value.truncated) {
        lines.push(`… the first ${entries.length} of the ${value.total} ${hourly ? 'hours' : 'days'} Apple Weather returned`);
      }
      return text([...lines, ...credit].join('\n'));
    },
  },
  execute: async (args) => {
    const { action, latitude, longitude } = args;
    // `Number.isFinite` and not a truthiness test: 0, 0 is a real point.
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
      throw new Error(`weather: \`${action}\` needs \`latitude\` and \`longitude\` as numbers.`
        + ' It does not take place names and never reads where the user is — get the coordinates'
        + ' from `location` (`current` or `geocode`) or a `maps` search first.');
    }
    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
      throw new Error('weather: `latitude` must be between -90 and 90 and `longitude` between -180 and 180');
    }
    const point = { latitude, longitude };
    if (action === 'hourly' && args.hours !== undefined) {
      if (!Number.isInteger(args.hours) || args.hours < 1 || args.hours > 240) {
        throw new Error('weather: `hours` must be a whole number from 1 to 240');
      }
      return invoke('weather', 'hourly', { ...point, hours: args.hours });
    }
    if (action === 'daily' && args.days !== undefined) {
      if (!Number.isInteger(args.days) || args.days < 1 || args.days > 10) {
        throw new Error('weather: `days` must be a whole number from 1 to 10');
      }
      return invoke('weather', 'daily', { ...point, days: args.days });
    }
    return invoke('weather', action, point);
  },
});

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
  contacts: contacts,
  compose: compose,
  music: music,
  files: files,
  weather: weather,
};
