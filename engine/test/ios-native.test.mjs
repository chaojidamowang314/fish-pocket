// The native-capability seam as the engine sees it. These tests run on a
// desktop Node, where the dsh_ios_native addon does not exist — which is
// exactly the case worth pinning: the plugin must contribute nothing rather
// than register tools that cannot work.
//
// The addon's own table (which capability accepts which operation) is enforced
// in native/ios-native/ios_native.m and cannot be reached from here.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { binding, capabilities, invoke } from '../plugins/ios-native/binding.mjs';
import { TOOLS, toEpochSeconds } from '../plugins/ios-native/tools.mjs';

test('the boundary-check plugin at least parses', () => {
  // It cannot be imported here: it resolves `@deepseek-ai/dsh-tools` from the
  // engine's node_modules, which only exists once it is installed on a device.
  // A syntax check still catches the failure mode that would otherwise surface
  // as a plugin that silently refuses to load on the device it was meant to
  // check — the one place its silence would be mistaken for a passing boundary.
  const example = fileURLToPath(new URL('./native-boundary-plugin/index.mjs', import.meta.url));
  const result = spawnSync(process.execPath, ['--check', example], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});

test('without the addon the binding reports absent rather than throwing', () => {
  assert.equal(binding(), null);
  assert.equal(capabilities(), null);
});

test('invoking without the addon fails with a reason a model can relay', async () => {
  await assert.rejects(invoke('device', 'info'), /only available in the iOS app/);
});

test('every tool declares the schema the registry requires', () => {
  for (const [capability, tool] of Object.entries(TOOLS)) {
    assert.equal(typeof tool.name, 'string', `${capability}: name`);
    assert.ok(tool.description.length > 40, `${capability}: description is too thin to guide a model`);
    assert.equal(typeof tool.execute, 'function', `${capability}: execute`);
    // defineTool compiles `parameters` into this; its absence means the
    // definition was rejected before registration.
    assert.ok(tool.parameters, `${capability}: compiled parameters`);
    assert.ok(tool.output?.schema, `${capability}: output schema`);
  }
});

test('tool names are unique and stable', () => {
  const names = Object.values(TOOLS).map((tool) => tool.name);
  assert.deepEqual(names, [...new Set(names)]);
  // Pinned because they reach the model's prompt and a rename is a breaking
  // change for any skill or plugin that mentions them.
  assert.deepEqual(names.sort(),
    ['alarm', 'calendar', 'clipboard', 'compose', 'contacts', 'device_info', 'files', 'health',
     'homekit', 'location', 'maps', 'music', 'notify', 'open_url', 'photos', 'read_image',
     'reminders', 'speak', 'text_analysis', 'transcribe_audio', 'weather']);
});

test('a reminders write is refused before the addon when it has nothing to act on', async () => {
  await assert.rejects(TOOLS.reminders.execute({ action: 'create' }, {}), /creating needs `title`/);
  await assert.rejects(TOOLS.reminders.execute({ action: 'complete' }, {}), /complete needs the reminder's `id`/);
  await assert.rejects(TOOLS.reminders.execute({ action: 'delete' }, {}), /delete needs the reminder's `id`/);
});

test('reminders render their own cancelled writes as cancelled', () => {
  const render = (action, value) => TOOLS.reminders.output.render({ action }, value)[0].text;
  assert.match(render('create', { saved: false }), /declined.*Nothing was added/i);
  assert.match(render('create', { saved: true }), /in their list/);
  assert.match(render('complete', { unchanged: true }), /already done/);
  assert.match(render('complete', { saved: false }), /still open/);
  assert.match(render('delete', { deleted: false }), /still there/);

  // An undated reminder must say so rather than render an empty column: "no due
  // date" is the difference between a task and one that will actually alert.
  const listed = render('list', {
    reminders: [
      { title: '买牛奶', completed: false, list: '家' },
      { title: '交房租', due: '2026-11-10T09:00:00+08:00', completed: false, list: '家' },
    ],
  });
  assert.match(listed, /no due date {2}买牛奶/);
  assert.match(listed, /2026-11-10 09:00 {2}交房租/);
  assert.match(render('list', { reminders: [] }), /Nothing on their reminders/);
});

test('a list gives the id the next call needs', () => {
  // complete, delete and update find an item by id and by nothing else. The addon
  // has always returned it; the text the model reads once left it out, so the model
  // could see a reminder and had no way to act on it.
  const reminders = (action, value) => TOOLS.reminders.output.render({ action }, value)[0].text;
  assert.match(
    reminders('list', { reminders: [{ id: 'R-1', title: '买牛奶', completed: false, list: '家', notes: '两盒' }] }),
    /买牛奶 {2}\[家\] {2}id R-1\n {4}两盒/,
  );
  assert.match(reminders('create', { saved: true, id: 'R-2' }), /in their list \(id R-2\)/);

  const events = TOOLS.calendar.output.render({ action: 'list' }, {
    events: [{ id: 'E-1', title: '周会', start: '2026-11-09T09:00:00+08:00', end: '2026-11-09T10:00:00+08:00' }],
  })[0].text;
  assert.match(events, /周会 {2}id E-1/);
});

test('an alarm that was set is reported as set', () => {
  // The renderer once read `saved` while the addon answers `created`, so every
  // alarm that went through was reported as declined and the model set it again.
  const native = readFileSync(new URL('../../native/ios-native/caps_alarm.m', import.meta.url), 'utf8');
  assert.match(native, /@"created": @YES/);
  const render = (value) => TOOLS.alarm.output.render({ action: 'create' }, value)[0].text;
  assert.match(render({ action: 'saved', created: true, id: 'A-1' }), /Alarm set \(id A-1\)/);
  assert.match(render({ action: 'cancelled', created: false }), /no alarm was set/);
});

test('the flags render the same whether the addon sends booleans or 0/1', () => {
  // On a real device `@(a > b)` once boxed a C int, so `default` and `truncated`
  // arrived as 0/1 while `writable` next to them arrived as true/false
  // (native/ios-native/caps_calendar.m). The addon now casts to BOOL, but this
  // file cannot see that table — so the renderer must not care either way.
  const calendars = (flag) => TOOLS.calendar.output.render({ action: 'calendars' }, {
    calendars: [{ title: '工作', writable: true, default: flag }],
  })[0].text;
  assert.equal(calendars(1), calendars(true));
  assert.equal(calendars(0), calendars(false));
  assert.match(calendars(1), /\(default\)/);
  assert.doesNotMatch(calendars(0), /\(default\)/);

  const listed = (flag) => TOOLS.calendar.output.render({ action: 'list' }, {
    events: [{ title: 'x', start: '2026-11-09T09:00:00+08:00', end: '2026-11-09T10:00:00+08:00' }],
    total: 480, truncated: flag,
  })[0].text;
  assert.equal(listed(1), listed(true));
  assert.equal(listed(0), listed(false));
  assert.match(listed(1), /showing the first/);
  assert.doesNotMatch(listed(0), /showing the first/);

  const reminders = (flag) => TOOLS.reminders.output.render({ action: 'list' }, {
    reminders: [{ title: '买牛奶', completed: flag, list: '家' }],
  })[0].text;
  assert.equal(reminders(1), reminders(true));
  assert.equal(reminders(0), reminders(false));
});

test('open_url and text_analysis refuse before the addon when they have nothing to act on', async () => {
  // These two arguments are always required, so the schema refuses first and the
  // tool does not check again. Pinned because dropping `required` would turn a
  // clear refusal into an addon call with an undefined argument.
  await assert.rejects(TOOLS.open.execute({}, {}), /missing required property "url"/);
  await assert.rejects(TOOLS.nlp.execute({ action: 'language' }, {}), /missing required property "text"/);
});

test('text_analysis renders each analysis as something a model can relay', () => {
  const render = (action, value, extra = {}) => TOOLS.nlp.output.render({ action, ...extra }, value)[0].text;

  // `similar` prints the index because the caller usually holds a parallel array
  // (the file paths these names came from) and has to map back to it.
  // The cosine value must never reach the rendered text: on device a correct
  // best match measured 0.10 while an identical string measured 1.00, so a
  // reader shown the number treats a right answer as a bad one.
  const ranked = render('similar', {
    compared: 120,
    matches: [
      { rank: 1, index: 7, text: '差旅报销指南.md', cosine: 0.1021 },
      { rank: 2, index: 2, text: '发票整理', cosine: -0.0659 },
    ],
  });
  assert.match(ranked, /an order, not a score/);
  assert.match(ranked, /1\. \[7\] {2}差旅报销指南\.md/);
  assert.doesNotMatch(ranked, /0\.10|-0\.06/);
  assert.match(render('similar', { matches: [], compared: 0 }), /Nothing to rank/);

  assert.match(render('language', { language: 'zh-Hans', hypotheses: [{ language: 'zh-Hans', confidence: 0.98 }] }),
               /zh-Hans 98%/);
  // A string with nothing to go on — digits, emoji — has no dominant language.
  // Saying so beats naming whichever language scored least badly.
  assert.match(render('language', { language: null, hypotheses: [] }), /Could not tell/);

  assert.match(render('entities', { entities: [{ text: '北京', type: 'PlaceName' }], total: 1 }), /Place {2}北京/);
  assert.match(render('entities', { entities: [], total: 0 }), /No people, places or organisations/);
});

test('similar refuses before the addon when it has nothing to rank against', async () => {
  await assert.rejects(
    TOOLS.nlp.execute({ action: 'similar', text: '报销' }, {}),
    /`similar` needs `candidates`/,
  );
});

test('maps routes between coordinates only, never between names', async () => {
  await assert.rejects(TOOLS.maps.execute({ action: 'search' }, {}), /`search` needs `query`/);
  // A name is not accepted, however reasonable it looks: resolving it would mean
  // picking one answer out of several, and a geocoder answers something even
  // when it does not know the place (§4.5).
  await assert.rejects(
    TOOLS.maps.execute({ action: 'eta', fromQuery: 'San Francisco', toQuery: 'San Jose' }, {}),
    /needs both ends as coordinates/,
  );
  await assert.rejects(
    TOOLS.maps.execute({ action: 'route', fromLatitude: 1, fromLongitude: 2, toLatitude: 3 }, {}),
    /needs both ends as coordinates/,
  );
  // 0, 0 is a real point in the Gulf of Guinea; a truthiness check would reject it.
  await assert.rejects(
    TOOLS.maps.execute({ action: 'eta', fromLatitude: 0, fromLongitude: 0, toLatitude: 1, toLongitude: 1 }, {}),
    /only available in the iOS app/,
  );
});

test('maps renders distances and durations the way a person says them', () => {
  const render = (action, value) => TOOLS.maps.output.render({ action }, value)[0].text;

  assert.match(render('eta', { from: '北京', to: '上海', seconds: 5100, meters: 1_214_000, mode: 'driving' }),
               /1 h 25 min, 1214\.0 km by driving/);
  assert.match(render('eta', { from: 'A', to: 'B', seconds: 480, meters: 650, mode: 'walking' }),
               /8 min, 650 m by walking/);

  const routed = render('route', {
    from: 'A', to: 'B', seconds: 480, meters: 650, mode: 'walking', name: '中山路',
    steps: [{ instruction: '向北走', meters: 120 }],
  });
  assert.match(routed, /via 中山路/);
  assert.match(routed, /向北走 \(120 m\)/);

  assert.match(render('search', { places: [{ name: '同仁堂', address: '朝阳区' }], total: 1 }), /同仁堂 {2}朝阳区/);
  assert.match(render('search', { places: [], total: 0 }), /No places found/);
});

test('read_image says what it found, or plainly that it found nothing', () => {
  const render = (action, value) => TOOLS.vision.output.render({ action }, value)[0].text;

  assert.match(render('text', { text: '合计 ¥128.00', lines: [{}], total: 1 }), /合计 ¥128\.00/);
  // An image with no text is a normal outcome, not a failure to retry.
  assert.match(render('text', { text: '', lines: [], total: 0 }), /No text found/);
  assert.match(render('text', { text: 'a', lines: [{}], total: 9, truncated: true }),
               /showing the first 1 of 9 lines/);

  assert.match(render('barcodes', { codes: [{ symbology: 'VNBarcodeSymbologyQR', payload: 'https://x' }] }),
               /VNBarcodeSymbologyQR {2}https:\/\/x/);
  assert.match(render('barcodes', { codes: [] }), /No barcodes/);

  // Singular and plural both have to read right: "1 faces found" is the kind of
  // thing a model repeats verbatim to the user.
  assert.match(render('faces', { count: 1, faces: [{}] }), /^1 face found\.$/);
  assert.match(render('faces', { count: 3, faces: [] }), /3 faces found/);
  assert.match(render('faces', { count: 0, faces: [] }), /No faces found/);

  // No confidence threshold: a near-zero score is reported as a near-zero score,
  // because whether 0.09 matters is a question about this image, not a number
  // for us to pick.
  assert.match(render('classify', { labels: [{ label: 'receipt', confidence: 0.91 }], total: 1 }), /91% {2}receipt/);
  assert.match(render('classify', { labels: [{ label: 'paper', confidence: 0.04 }], total: 1 }), /4% {2}paper/);
  assert.match(render('classify', { labels: [{ label: 'x', confidence: 0.5 }], total: 900, truncated: true }),
               /the most confident 1 of 900/);
  assert.match(render('classify', { labels: [], total: 0 }), /Nothing recognisable/);
});

test('clipboard and location refuse before the addon when an argument is missing', async () => {
  await assert.rejects(TOOLS.clipboard.execute({ action: 'set' }, {}), /`set` needs `text`/);
  // An empty string is a legitimate thing to copy; only `undefined` is missing.
  await assert.rejects(TOOLS.clipboard.execute({ action: 'set', text: '' }, {}), /only available in the iOS app/);
  await assert.rejects(TOOLS.location.execute({ action: 'geocode' }, {}), /`geocode` needs `address`/);
  await assert.rejects(TOOLS.location.execute({ action: 'reverse', latitude: 0 }, {}), /needs `latitude` and `longitude`/);
  // 0, 0 is a real point in the Gulf of Guinea; a truthiness check would reject it.
  await assert.rejects(
    TOOLS.location.execute({ action: 'reverse', latitude: 0, longitude: 0 }, {}),
    /only available in the iOS app/,
  );
});

test('clipboard and location say plainly when there is nothing to report', () => {
  const clip = (action, value) => TOOLS.clipboard.output.render({ action }, value)[0].text;
  assert.match(clip('get', { text: null, kinds: ['image'] }), /no text.*It holds: image/s);
  assert.match(clip('get', { text: 'abc', characters: 3, truncated: false }), /^abc$/);
  assert.match(clip('get', { text: 'a', characters: 20000, truncated: true }), /it is longer/);
  // A declined write must never read as done — the same rule as the calendar.
  assert.match(clip('set', { saved: false }), /declined.*unchanged/i);
  assert.match(clip('set', { saved: true, characters: 12 }), /Copied 12 characters/);
  assert.match(clip('clear', { cleared: false }), /declined.*unchanged/i);

  const loc = (action, value) => TOOLS.location.output.render({ action }, value)[0].text;
  assert.match(loc('current', { latitude: 39.9042, longitude: 116.4074, accuracyMeters: 65 }),
               /39\.90420, 116\.40740 \(±65 m\)/);

  // Every candidate, numbered, because choosing among them is the caller's job.
  // Measured on a device in the China region, asking for "San Francisco" really
  // did return a township in Yunnan — which a reader spots at once and a
  // string-similarity rule of ours would spend forever trying to.
  const many = loc('geocode', {
    total: 2,
    places: [
      { name: '旧金山', country: '美国', latitude: 37.7749, longitude: -122.4194 },
      { name: '上安宁', locality: '普洱', country: '中国', latitude: 23.2325, longitude: 101.6679 },
    ],
  });
  assert.match(many, /2 places match — pick the one you meant/);
  assert.match(many, /1\. 旧金山, 美国 {2}\(37\.77490, -122\.41940\)/);
  assert.match(many, /2\. 上安宁, 普洱, 中国/);
  // One match needs no "pick one" line; it is still a list, not a verdict.
  const one = loc('geocode', { total: 1, places: [{ name: '故宫', locality: '北京', latitude: 39.9163, longitude: 116.3972 }] });
  assert.doesNotMatch(one, /pick the one/);
  assert.match(one, /1\. 故宫, 北京/);
  assert.match(loc('reverse', { total: 0, places: [] }), /Nothing was found/);
});

test('maps names the coordinates it was given rather than "Unknown Location"', () => {
  const rendered = TOOLS.maps.output.render({ action: 'eta' }, {
    from: '39.90420, 116.40740', to: '39.08510, 117.19940',
    seconds: 6910, meters: 137096, mode: 'driving',
  })[0].text;
  assert.match(rendered, /39\.90420, 116\.40740 → 39\.08510, 117\.19940/);
  assert.match(rendered, /1 h 55 min, 137\.1 km/);
});

test('the capabilities added last refuse before the addon when an argument is missing', async () => {
  await assert.rejects(TOOLS.health.execute({ action: 'read' }, {}), /needs `type`/);
  await assert.rejects(
    TOOLS.health.execute({ action: 'read', type: 'stepCount', from: '2026-11-10', to: '2026-11-09' }, {}),
    /'to' must be after 'from'/,
  );
  await assert.rejects(TOOLS.transcribe.execute({ action: 'file' }, {}), /`file` needs `path`/);
  await assert.rejects(TOOLS.homekit.execute({ action: 'get' }, {}), /needs `name` or `uniqueIdentifier`/);
  await assert.rejects(TOOLS.homekit.execute({ action: 'set', accessory: 'a' }, {}), /needs `characteristic`/);
  // 0 is a real characteristic value — "off" on a bool. A truthiness check here
  // would refuse exactly the request to turn something off.
  await assert.rejects(
    TOOLS.homekit.execute({ action: 'set', accessory: 'a', characteristic: 'b', value: 0 }, {}),
    /only available in the iOS app/,
  );
  await assert.rejects(TOOLS.alarm.execute({ action: 'create', title: 'x' }, {}), /needs `hour`/);
  // Midnight is 0:00, and both halves of it are falsy.
  await assert.rejects(
    TOOLS.alarm.execute({ action: 'create', title: 'x', hour: 0, minute: 0 }, {}),
    /only available in the iOS app/,
  );
  await assert.rejects(TOOLS.alarm.execute({ action: 'cancel' }, {}), /cancelling needs `id`/);
});

test('an empty health answer never reads as "you have no data"', () => {
  const render = (action, value) => TOOLS.health.output.render({ action }, value)[0].text;
  // iOS will not say whether a read was allowed, so the renderer must carry the
  // addon's "could be either" line rather than stating one of the two.
  const empty = render('read', {
    type: 'stepCount', from: '2026-11-03T00:00:00+08:00', to: '2026-11-10T00:00:00+08:00',
    samples: [], emptyMeans: 'This is either not allowed or not recorded; iOS does not say which.',
  });
  assert.match(empty, /either not allowed or not recorded/);

  // A bucket with no samples is not a zero: a watch left on the table and a day
  // spent sitting still are different answers.
  const gaps = render('aggregate', {
    type: 'stepCount', stat: 'sum', interval: 'day', unit: 'count',
    buckets: [{ start: '2026-11-09T00:00:00+08:00', value: null },
              { start: '2026-11-10T00:00:00+08:00', value: 8421 }],
  });
  assert.match(gaps, /2026-11-09 {2}—/);
  assert.match(gaps, /2026-11-10 {2}8421/);
});

test('a limited photo library is never reported as the whole library', () => {
  const rendered = TOOLS.photos.output.render({ action: 'list' }, {
    access: 'limited',
    note: 'These are the photos the user shared with this app, not their library.',
    photos: [{ created: '2026-11-09', width: 4032, height: 3024, id: 'A' }],
    total: 1,
  })[0].text;
  // The note comes first, because a count taken from a handful of shared photos
  // reads exactly like a count of everything they have.
  assert.match(rendered.split('\n')[0], /shared with this app/);
});

test('a bare date means local midnight, not UTC midnight', () => {
  // The whole point of the conversion. `new Date('2026-11-09')` is UTC midnight,
  // which lands on 8 November for anyone west of Greenwich and skips the first
  // hours of the day for anyone east of it — the user would ask for "today" and
  // be shown someone else's today.
  const local = new Date(2026, 10, 9);
  assert.equal(toEpochSeconds('2026-11-09'), Math.floor(local.getTime() / 1000));
  assert.equal(new Date(toEpochSeconds('2026-11-09') * 1000).getDate(), 9);
  assert.equal(new Date(toEpochSeconds('2026-11-09') * 1000).getHours(), 0);

  // A full timestamp carries its own offset and must be taken at face value.
  assert.equal(toEpochSeconds('2026-11-09T12:00:00Z'), Date.parse('2026-11-09T12:00:00Z') / 1000);
});

test('a missing range falls back rather than failing', () => {
  assert.equal(toEpochSeconds(undefined, 1234), 1234);
  assert.equal(toEpochSeconds('', 1234), 1234);
  assert.equal(toEpochSeconds(null, 1234), 1234);
});

test('an unreadable date is refused with the value in the message', () => {
  assert.throws(() => toEpochSeconds('next tuesday'), /could not read the date 'next tuesday'/);
  assert.throws(() => toEpochSeconds(20261109), /is not a date/);
  // The message names no tool on purpose: `calendar` and `health` share this
  // helper, and "calendar: ..." on a health range sends the reader to the wrong file.
  assert.throws(() => toEpochSeconds('nope'), (error) => !/^calendar:/.test(error.message));
});

test('a calendar write is refused before the addon when it cannot say what to write', async () => {
  await assert.rejects(TOOLS.calendar.execute({ action: 'create' }, {}), /creating needs `title`/);
  await assert.rejects(TOOLS.calendar.execute({ action: 'create', title: 'x' }, {}), /creating needs `start`/);
  await assert.rejects(TOOLS.calendar.execute({ action: 'update' }, {}), /update needs the event's `id`/);
  await assert.rejects(TOOLS.calendar.execute({ action: 'delete' }, {}), /delete needs the event's `id`/);
  // An update that changes nothing would still raise a confirmation sheet, and
  // a sheet that asks about nothing teaches the user to tap through them.
  await assert.rejects(
    TOOLS.calendar.execute({ action: 'update', id: 'abc' }, {}),
    /needs at least one of title, start, end, location or notes/,
  );
});

test('a cancelled write is never reported as done', () => {
  const render = (action, value) => TOOLS.calendar.output.render({ action }, value)[0].text;

  // The user had the last word in every one of these. The model reads this text
  // and tells them what happened, so "cancelled" must never read as success.
  assert.match(render('create', { saved: false, action: 'cancelled' }), /Nothing was added/);
  assert.match(render('create', { saved: true, id: 'E1' }), /Added to their calendar \(id E1\)/);
  assert.match(render('update', { saved: false }), /declined.*unchanged/i);
  assert.match(render('update', { saved: true }), /updated/);
  assert.match(render('update', { unchanged: true }), /already matches/);
  assert.match(render('delete', { deleted: false }), /declined.*still there/i);
  assert.match(render('delete', { deleted: true }), /deleted/);
});

test('the calendar tool checks its range before reaching the addon', async () => {
  await assert.rejects(
    TOOLS.calendar.execute({ action: 'list', from: '2026-11-09', to: '2026-11-08' }, {}),
    /'to' must be after 'from'/,
  );
  await assert.rejects(
    TOOLS.calendar.execute({ action: 'list', from: 'whenever' }, {}),
    /could not read the date/,
  );
});

test('a tool rejects arguments its operation cannot use, before reaching the addon', async () => {
  // The addon is absent here, so "rejected for a missing argument" and not
  // "rejected for a missing addon" shows the check happened in the tool.
  await assert.rejects(TOOLS.notify.execute({ action: 'schedule' }, {}), /needs `body`/);
  await assert.rejects(
    TOOLS.notify.execute({ action: 'schedule', body: 'x' }, {}),
    /needs `afterSeconds`/,
  );
  await assert.rejects(TOOLS.notify.execute({ action: 'cancel' }, {}), /needs `id`/);
  await assert.rejects(TOOLS.speak.execute({ action: 'say' }, {}), /needs `text`/);
});

test('renderers are pure and survive the shapes the addon can return', () => {
  const rendered = TOOLS.device.output.render({}, {
    model: 'iPhone', systemName: 'iOS', systemVersion: '26.0', idiom: 'phone',
    batteryLevel: null, batteryState: 'unknown', lowPowerMode: false,
    thermalState: 0, availableBytes: 12e9, processorCount: 6,
  });
  assert.equal(rendered[0].type, 'text');
  // A battery iOS will not report must not render as "null%".
  assert.match(rendered[0].text, /battery: unknown/);
  assert.match(rendered[0].text, /free storage: 12\.0 GB/);

  const empty = TOOLS.notify.output.render({ action: 'pending' }, { notifications: [] });
  assert.match(empty[0].text, /No notifications scheduled/);
});

test('the calendar renderer reads the addon times without reinterpreting them', () => {
  const render = (value) => TOOLS.calendar.output.render({ action: 'list' }, value)[0].text;

  // The addon already formatted these in the device's timezone and kept the
  // offset. Parsing them back into a Date here would be a second conversion and
  // a second chance to be wrong, so the renderer slices the string instead — the
  // +08:00 below must not move the printed time.
  const sameDay = render({
    events: [{
      title: '产品评审', start: '2026-11-09T14:00:00+08:00', end: '2026-11-09T15:00:00+08:00',
      allDay: false, calendar: '工作', location: '会议室 A',
    }],
  });
  assert.match(sameDay, /2026-11-09 14:00–15:00/);
  assert.match(sameDay, /\[工作\]/);
  assert.match(sameDay, /@ 会议室 A/);

  assert.match(
    render({ events: [{ title: '出差', start: '2026-11-10T00:00:00+08:00', end: '2026-11-11T00:00:00+08:00', allDay: true }] }),
    /2026-11-10 all day {2}出差/,
  );
  // Spanning midnight has to show the end date too, or "22:00–01:00" reads as a
  // three-hour meeting that ended before it started.
  assert.match(
    render({ events: [{ title: '红眼航班', start: '2026-11-10T22:00:00+08:00', end: '2026-11-11T01:00:00+08:00', allDay: false }] }),
    /2026-11-10 22:00 – 2026-11-11 01:00/,
  );

  assert.match(render({ events: [] }), /No events in that range/);
  assert.match(
    render({ events: [{ title: 'x', start: '2026-11-09T09:00:00+08:00', end: '2026-11-09T10:00:00+08:00' }], total: 480, truncated: true }),
    /showing the first 1 of 480/,
  );
  // A title the user never typed still has to render as a line, not as "undefined".
  assert.match(render({ events: [{ start: '2026-11-09T09:00:00+08:00', end: '2026-11-09T10:00:00+08:00' }] }), /\(no title\)/);

  const calendars = TOOLS.calendar.output.render({ action: 'calendars' }, {
    calendars: [
      { title: '工作', writable: true, default: true },
      { title: '节假日', writable: false, default: false },
    ],
  })[0].text;
  assert.match(calendars, /工作 {2}\(default\)/);
  assert.match(calendars, /节假日 {2}\(read-only\)/);
});

test('contacts refuses before the addon unless it knows which one field to search', async () => {
  await assert.rejects(TOOLS.contacts.execute({ action: 'search' }, {}), /needs one of `name`, `phone` or `email`/);
  // Two fields is not "search both": saying which field the query belongs to is
  // the caller's half of the bargain, and the tool must not guess for it.
  await assert.rejects(
    TOOLS.contacts.execute({ action: 'search', name: '张三', phone: '13800000000' }, {}),
    /exactly one of.*got name and phone/,
  );
  // A model fills unused string parameters with '' out of habit. That is not a
  // second field, and on its own it is not a query either.
  await assert.rejects(TOOLS.contacts.execute({ action: 'search', name: '' }, {}), /needs one of/);
  await assert.rejects(
    TOOLS.contacts.execute({ action: 'search', name: '张三', phone: '', email: '' }, {}),
    /only available in the iOS app/,
  );
  await assert.rejects(
    TOOLS.contacts.execute({ action: 'search', email: 'zs@example.com', limit: 5 }, {}),
    /only available in the iOS app/,
  );
  await assert.rejects(TOOLS.contacts.execute({ action: 'get' }, {}), /`get` needs `id`/);
  await assert.rejects(TOOLS.contacts.execute({ action: 'get', id: 'A:ABPerson' }, {}), /only available in the iOS app/);
});

test('contacts lists every match and never presents one as the answer', () => {
  const render = (value) => TOOLS.contacts.output.render({ action: 'search', name: '张' }, value)[0].text;
  const many = render({
    access: 'full', total: 2, truncated: false,
    contacts: [
      { id: 'A', name: '张三', organization: 'Acme', phones: [{ label: 'mobile', value: '+86 138 0000 0000' }], emails: [] },
      // No label is a real shape: the card has a number nobody labelled.
      { id: 'B', name: '张三丰', organization: '', phones: [{ value: '010-5555' }], emails: [{ label: 'work', value: 'zsf@example.com' }] },
    ],
  });
  assert.match(many.split('\n')[0], /2 contacts match — show them and ask/);
  assert.match(many, /1\. 张三 \(Acme\) {2}id A\n {3}phone {2}mobile: \+86 138 0000 0000/);
  assert.match(many, /2\. 张三丰 {2}id B\n {3}phone {2}010-5555\n {3}email {2}work: zsf@example\.com/);
  assert.doesNotMatch(many, /undefined|null/);

  // One match needs no "ask which" line; it is still a list, not a verdict.
  const one = render({ access: 'full', total: 1, contacts: [{ id: 'A', name: '张三', phones: [], emails: [] }] });
  assert.doesNotMatch(one, /ask which/);
  assert.match(one, /1\. 张三 {2}id A\n {3}no phone or email on this card/);

  // A company card has no person's name; a bare saved number has neither.
  const nameless = render({
    access: 'full', total: 2,
    contacts: [{ id: 'C', name: '', organization: 'Acme' }, { id: 'D', name: '', organization: '' }],
  });
  assert.match(nameless, /1\. Acme {2}id C/);
  assert.match(nameless, /2\. \(no name\) {2}id D/);

  const cut = render({ access: 'full', total: 140, truncated: true, contacts: [{ id: 'A', name: '张一' }, { id: 'B', name: '张二' }] });
  assert.match(cut, /^140 contacts match/);
  assert.match(cut, /140 match in all and 2 are shown/);

  assert.match(render({ access: 'full', total: 0, truncated: false, contacts: [] }), /^No contact matches that\.$/);
  // Survives a reply with nothing in it at all.
  assert.match(render({}), /No contact matches that/);
});

test('a limited contact selection is never reported as the whole address book', () => {
  const note = 'The user shared a selected set of contacts, not their address book.';
  const empty = TOOLS.contacts.output.render({ action: 'search', name: '李四' }, {
    access: 'limited', note, contacts: [], total: 0, truncated: false,
  })[0].text;
  // The note comes first, and the empty line itself is scoped to the selection:
  // "No contact matches" on its own is the sentence that must never be relayed.
  assert.match(empty.split('\n')[0], /shared a selected set/);
  assert.match(empty, /No match among the contacts the user shared/);
  assert.doesNotMatch(empty, /No contact matches that/);

  const found = TOOLS.contacts.output.render({ action: 'search', name: '张三' }, {
    access: 'limited', note, total: 1, contacts: [{ id: 'A', name: '张三', phones: [], emails: [] }],
  })[0].text;
  assert.match(found.split('\n')[0], /shared a selected set/);

  const card = TOOLS.contacts.output.render({ action: 'get', id: 'A' }, {
    access: 'limited', note, contact: { id: 'A', name: '张三' },
  })[0].text;
  assert.match(card.split('\n')[0], /shared a selected set/);
});

test('a contact card renders what is on it and invents nothing', () => {
  const render = (contact) => TOOLS.contacts.output.render({ action: 'get', id: 'A' }, { access: 'full', contact })[0].text;
  const full = render({
    id: 'A', name: '张三', organization: 'Acme', givenName: '三', familyName: '张', middleName: '',
    nickname: '老张', jobTitle: 'Engineer', department: 'R&D',
    phones: [{ label: 'mobile', value: '+86 138 0000 0000' }],
    emails: [{ label: 'work', value: 'zs@example.com' }],
    addresses: [{ label: 'home', formatted: '1 Infinite Loop\nCupertino CA 95014\nUnited States', city: 'Cupertino' }],
    birthday: { month: 3, day: 9 },
    urls: [{ label: 'homepage', value: 'https://example.com' }],
  });
  assert.match(full, /^张三\n/);
  assert.match(full, /given name: 三\nfamily name: 张\nnickname: 老张\norganization: Acme\ndepartment: R&D\njob title: Engineer/);
  assert.doesNotMatch(full, /middle name/);
  assert.match(full, /phone {2}mobile: \+86 138 0000 0000/);
  assert.match(full, /address {2}home: 1 Infinite Loop, Cupertino CA 95014, United States/);
  // Most cards have no year. The renderer must not supply one.
  assert.match(full, /birthday: 03-09 \(no year on the card\)/);
  assert.match(full, /url {2}homepage: https:\/\/example\.com/);
  assert.match(full, /id: A$/);

  assert.match(render({ id: 'A', name: '张三', birthday: { year: 1990, month: 12, day: 25 } }), /birthday: 1990-12-25$/m);
  // The barest card the addon can return, and a reply with no card at all.
  assert.equal(render({ id: 'B', name: '', organization: '', phones: [], emails: [], addresses: [], urls: [] }), '(no name)\nid: B');
  assert.equal(TOOLS.contacts.output.render({ action: 'get', id: 'A' }, {})[0].text, '(no name)');
});

test('compose refuses before the addon when there is nothing to put in the sheet', async () => {
  // On a desktop Node the addon is absent, so "rejected for the arguments"
  // rather than "only available in the iOS app" proves the check is in the tool.
  await assert.rejects(TOOLS.compose.execute({ action: 'mail' }, {}), /`mail` needs at least one of `to`, `cc`, `bcc`, `subject`, `body`, `attachments`/);
  await assert.rejects(TOOLS.compose.execute({ action: 'message' }, {}), /`message` needs at least one of `to`, `body`, `attachments`/);
  // Empty values are the same lost arguments, and `html` alone is not content.
  await assert.rejects(
    TOOLS.compose.execute({ action: 'mail', to: [], subject: '', body: '', html: true }, {}),
    /`mail` needs at least one of/,
  );
  await assert.rejects(TOOLS.compose.execute({ action: 'message', to: [], body: '' }, {}), /`message` needs at least one of/);

  // With something to show, the call gets as far as the addon.
  await assert.rejects(TOOLS.compose.execute({ action: 'mail', subject: 'Hello' }, {}), /only available in the iOS app/);
  await assert.rejects(TOOLS.compose.execute({ action: 'message', to: ['+8613800138000'] }, {}), /only available in the iOS app/);
  await assert.rejects(TOOLS.compose.execute({ action: 'mail', attachments: ['report.pdf'] }, {}), /only available in the iOS app/);
});

test('compose refuses arguments that would silently change the draft', async () => {
  // A single address as a string is the likeliest slip; it is refused rather
  // than wrapped, so the caller sees exactly what was put in front of the user.
  // The schema stops the wrong shapes before `execute`; the tool's own check is
  // what catches an empty string inside an otherwise well-formed list.
  await assert.rejects(TOOLS.compose.execute({ action: 'mail', to: 'a@example.com' }, {}), /"to" must be an array/);
  await assert.rejects(TOOLS.compose.execute({ action: 'mail', to: ['a@example.com', ''] }, {}), /`to` must be an array of non-empty strings/);
  await assert.rejects(TOOLS.compose.execute({ action: 'mail', cc: [7] }, {}), /"cc\[0\]" must be a string/);
  await assert.rejects(TOOLS.compose.execute({ action: 'message', attachments: 'a.png' }, {}), /"attachments" must be an array/);
  await assert.rejects(TOOLS.compose.execute({ action: 'mail', body: 42 }, {}), /"body" must be a string/);

  // A text message has no subject line to carry one in; dropping it would show
  // the user a draft missing something the caller believes is there.
  await assert.rejects(
    TOOLS.compose.execute({ action: 'message', to: ['+8613800138000'], subject: 'Hi', body: 'x' }, {}),
    /`message` has no `subject`/,
  );
  await assert.rejects(
    TOOLS.compose.execute({ action: 'message', body: 'x', cc: ['a@example.com'], html: true }, {}),
    /`message` has no `cc`, `html`/,
  );
});

test('compose only says "sent" when the user sent it', () => {
  const render = (action, value) => TOOLS.compose.output.render({ action }, value)[0].text;

  // "sent" is handed over, not delivered — the wording must not promise more.
  assert.match(render('mail', { result: 'sent' }), /tapped Send.*outbox.*not confirmed delivered/);
  assert.match(render('message', { result: 'sent' }), /tapped Send.*Messages.*not confirmed delivered/);

  // A draft and a cancel are ordinary answers, and neither may read as sent.
  assert.match(render('mail', { result: 'saved' }), /draft.*Nothing was sent/);
  assert.match(render('mail', { result: 'cancelled' }), /without sending\. No email was sent/);
  assert.match(render('message', { result: 'cancelled' }), /without sending\. No message was sent/);

  // Anything unexpected is reported as unknown, never as success.
  for (const value of [{}, { result: 'queued' }, undefined]) {
    assert.match(render('mail', value), /Do not assume the email was sent/);
    assert.match(render('message', value), /Do not assume the message was sent/);
  }
});

test('music refuses before the addon when search has no query or play has two targets', async () => {
  await assert.rejects(TOOLS.music.execute({ action: 'search' }, {}), /`search` needs `query`/);
  await assert.rejects(TOOLS.music.execute({ action: 'search', query: '' }, {}), /`search` needs `query`/);
  await assert.rejects(
    TOOLS.music.execute({ action: 'play', album: '1', playlist: '2' }, {}),
    /takes one of .*not `album` and `playlist`/,
  );
  await assert.rejects(
    TOOLS.music.execute({ action: 'play', songs: ['1'], artist: '2', shuffle: true }, {}),
    /not `songs` and `artist`/,
  );
});

test('music lets valid calls through to the addon', async () => {
  // On desktop Node there is no addon, so reaching it is the proof that
  // validation passed.
  const reached = /only available in the iOS app/;
  await assert.rejects(TOOLS.music.execute({ action: 'search', query: 'run', kind: 'playlist', limit: 5 }, {}), reached);
  await assert.rejects(TOOLS.music.execute({ action: 'playlists' }, {}), reached);
  await assert.rejects(TOOLS.music.execute({ action: 'play' }, {}), reached);
  await assert.rejects(TOOLS.music.execute({ action: 'play', shuffle: false }, {}), reached);
  await assert.rejects(TOOLS.music.execute({ action: 'play', songs: ['17293822569102704640'] }, {}), reached);
  await assert.rejects(TOOLS.music.execute({ action: 'play', playlist: '42', shuffle: true }, {}), reached);
  for (const action of ['pause', 'next', 'previous', 'now']) {
    await assert.rejects(TOOLS.music.execute({ action }, {}), reached);
  }
});

test('music renders search results with their ids, and says the library is all it searched', () => {
  const render = (args, value) => TOOLS.music.output.render(args, value)[0].text;
  const song = {
    id: '17293822569102704640', title: 'Running Up That Hill', artist: 'Kate Bush',
    album: 'Hounds of Love', duration: 298.4, cloud: true,
  };

  const songs = render({ action: 'search', query: 'running' },
    { kind: 'song', results: [song, { ...song, id: '7', title: 'Running', cloud: false }], total: 2, truncated: false });
  // The id must survive as the string it arrived as: it does not fit a double.
  assert.match(songs, /Running Up That Hill — Kate Bush · Hounds of Love {2}4:58 {2}cloud {2}17293822569102704640/);
  assert.match(songs, /\nRunning — Kate Bush · Hounds of Love {2}4:58 {2}7$/);

  const albums = render({ action: 'search', query: 'hits', kind: 'album' }, {
    kind: 'album',
    results: [{ id: '11', title: 'Greatest Hits', artist: 'Queen', count: 17 }, { id: '12', title: 'Greatest Hits', artist: 'ABBA', count: 1 }],
    total: 140,
    truncated: true,
  });
  assert.match(albums, /Greatest Hits — Queen {2}17 songs {2}11/);
  assert.match(albums, /Greatest Hits — ABBA {2}1 song {2}12/);
  assert.match(albums, /140 albums match in all/);

  assert.match(
    render({ action: 'search', query: 'run', kind: 'playlist' },
      { kind: 'playlist', results: [{ id: '42', name: 'Running', count: 40 }], total: 1, truncated: false }),
    /^Running {2}40 songs {2}42$/,
  );
  assert.match(
    render({ action: 'search', query: 'bush', kind: 'artist' },
      { kind: 'artist', results: [{ id: '5', name: 'Kate Bush', count: 12 }], total: 1, truncated: false }),
    /^Kate Bush {2}12 songs {2}5$/,
  );

  const none = render({ action: 'search', query: 'nope', kind: 'album' }, { kind: 'album', results: [], total: 0, truncated: false });
  assert.match(none, /No album in their library matches "nope"/);
  assert.match(none, /not the Apple Music catalogue/);
  // A reply with fields missing must still render.
  assert.match(render({ action: 'search' }, {}), /No song in their library/);
  assert.match(render({ action: 'search', query: 'x' }, { results: [{}] }), /\(untitled\)/);
});

test('music renders the playlist list, empty and truncated', () => {
  const render = (value) => TOOLS.music.output.render({ action: 'playlists' }, value)[0].text;
  assert.equal(render({ playlists: [], total: 0, truncated: false }), 'Their library has no playlists.');
  assert.equal(render({}), 'Their library has no playlists.');
  const listed = render({ playlists: [{ id: '42', name: 'Running', count: 40 }, { id: '43', name: '', count: 0 }], total: 260, truncated: true });
  assert.match(listed, /Running {2}40 songs {2}42/);
  assert.match(listed, /\(unnamed\) {2}0 songs {2}43/);
  assert.match(listed, /260 playlists in all/);
});

test('music renders play as queued, shuffled, resumed or declined', () => {
  const render = (value) => TOOLS.music.output.render({ action: 'play' }, value)[0].text;
  assert.equal(render({ action: 'cancelled', played: false }), 'They declined; nothing was played.');
  assert.equal(
    render({ action: 'saved', played: true, kind: 'playlist', name: 'Running', count: 40, shuffle: false, first: 'Eye of the Tiger' }),
    'Playing playlist "Running" (40 songs). First: Eye of the Tiger.',
  );
  const shuffled = render({ action: 'saved', played: true, kind: 'album', name: 'Hounds of Love', count: 12, shuffle: true });
  assert.match(shuffled, /Playing album "Hounds of Love" \(12 songs\)/);
  assert.match(shuffled, /Shuffled/);
  assert.equal(
    render({ action: 'saved', played: true, kind: 'songs', count: 1, shuffle: false, first: 'Cloudbusting' }),
    'Playing the songs asked for (1 song). First: Cloudbusting.',
  );
  assert.equal(
    render({ action: 'saved', played: true, kind: 'resume', item: { id: '7', title: 'Cloudbusting', artist: 'Kate Bush', album: 'Hounds of Love' } }),
    'Resumed: Cloudbusting — Kate Bush · Hounds of Love.',
  );
  // Resuming with an empty queue is not reported as music playing.
  assert.match(render({ action: 'saved', played: true, kind: 'resume', item: null }), /nothing was queued/);
});

test('music renders pause and skips, including a declined one and an empty queue', () => {
  const render = (action, value) => TOOLS.music.output.render({ action }, value)[0].text;
  const item = { id: '7', title: 'Cloudbusting', artist: 'Kate Bush', album: '' };
  assert.equal(render('pause', { action: 'saved', paused: true, item }), 'Paused: Cloudbusting — Kate Bush.');
  assert.match(render('pause', { action: 'saved', paused: true, item: null }), /^Paused\. Nothing was queued/);
  assert.match(render('pause', { action: 'cancelled', paused: false }), /declined/);

  // A skip names the song it left, never the one it landed on: the addon does
  // not know that yet.
  assert.equal(
    render('next', { action: 'saved', skipped: true, from: item }),
    'Skipped forward from Cloudbusting — Kate Bush. Call `now` to see what is playing.',
  );
  assert.match(render('previous', { action: 'saved', skipped: true, from: null }), /^Went back one\. Call `now`/);
  assert.match(render('next', { action: 'cancelled', skipped: false }), /declined/);
  assert.match(render('previous', { action: 'cancelled', skipped: false }), /declined/);
});

test('music renders what is playing, and an empty queue', () => {
  const render = (value) => TOOLS.music.output.render({ action: 'now' }, value)[0].text;
  assert.equal(
    render({
      state: 'playing',
      item: { id: '17293822569102704640', title: 'Cloudbusting', artist: 'Kate Bush', album: 'Hounds of Love', duration: 310, cloud: false, position: 62.7 },
    }),
    'playing: Cloudbusting — Kate Bush · Hounds of Love  1:03 / 5:10  17293822569102704640',
  );
  // The player can have an item and no position yet.
  assert.match(
    render({ state: 'paused', item: { id: '7', title: 'Cloudbusting', artist: '', album: '', duration: 310, cloud: true, position: null } }),
    /^paused: Cloudbusting {2}5:10 {2}cloud {2}7$/,
  );
  assert.equal(render({ state: 'stopped', item: null }), 'Nothing is queued in Music (stopped).');
  assert.equal(render({}), 'Nothing is queued in Music (stopped).');
});

test('files refuses an export with nothing to hand over before the addon', async () => {
  await assert.rejects(TOOLS.files.execute({ action: 'export' }, {}), /`export` needs `paths`/);
  await assert.rejects(TOOLS.files.execute({ action: 'export', paths: [] }, {}), /`export` needs `paths`/);
  // Past the check, the only thing left to fail on a desktop is the addon itself.
  await assert.rejects(TOOLS.files.execute({ action: 'export', paths: ['/home/dsh/a.txt'] }, {}),
                       /only available in the iOS app/);
  // `pick` has no required argument: with nothing at all the user may choose any one file.
  await assert.rejects(TOOLS.files.execute({ action: 'pick' }, {}), /only available in the iOS app/);
});

test('a closed file picker is reported as the user\'s answer, not as an empty result', () => {
  const render = (action, value) => TOOLS.files.output.render({ action }, value)[0].text;
  assert.match(render('pick', { files: [], cancelled: true }), /closed the picker without choosing/);
  assert.match(render('export', { saved: false }), /closed the picker without saving/);
  assert.match(render('export', { saved: true, count: 1 }), /Saved 1 item to/);
  assert.match(render('export', { saved: true, count: 3 }), /Saved 3 items to/);
  // Missing fields must not throw: the reply shape is the addon's, not a promise.
  assert.equal(typeof render('pick', {}), 'string');
  assert.equal(typeof render('export', {}), 'string');
  assert.equal(typeof render('export', { saved: true }), 'string');
});

test('picked files are listed by the path the engine can open, and failures come first', () => {
  const render = (value) => TOOLS.files.output.render({ action: 'pick' }, value)[0].text;
  const one = render({
    cancelled: false,
    files: [{ path: '/home/dsh/.ios/files/20261110-093000/report.pdf', name: 'report.pdf',
              bytes: 48213, type: 'com.adobe.pdf' }],
  });
  assert.equal(one, '/home/dsh/.ios/files/20261110-093000/report.pdf\t47 KB\tcom.adobe.pdf');

  const mixed = render({
    cancelled: false,
    files: [
      { path: '/home/dsh/.ios/files/20261110-093000/a.txt', name: 'a.txt', bytes: 12, type: 'public.plain-text' },
      { path: '/home/dsh/.ios/files/20261110-093000/Trip.pages', name: 'Trip.pages', directory: true,
        type: 'com.apple.iwork.pages.sffpages' },
      { path: '/home/dsh/.ios/files/20261110-093000/clip.mov', name: 'clip.mov', bytes: 5 * 1024 * 1024 },
    ],
    failed: [{ name: 'b.txt', error: 'The file “b.txt” couldn’t be saved.' }],
  }).split('\n');
  // Otherwise three good paths read as "everything they chose is here".
  assert.match(mixed[0], /^NOT copied: b\.txt — /);
  assert.match(mixed[1], /a\.txt\t12 B\tpublic\.plain-text$/);
  // A package is a directory; it is flagged rather than given a size that is not its contents'.
  assert.match(mixed[2], /Trip\.pages\tdirectory\t/);
  // No type and the row still renders, without a dangling separator.
  assert.match(mixed[3], /clip\.mov\t5\.0 MB$/);
});

test('weather takes a point, never a place name, and refuses before the addon otherwise', async () => {
  await assert.rejects(TOOLS.weather.execute({ action: 'current' }, {}), /`current` needs `latitude` and `longitude`/);
  await assert.rejects(TOOLS.weather.execute({ action: 'daily', latitude: 31.2 }, {}), /needs `latitude` and `longitude`/);
  // A name is the natural thing to pass, and the refusal has to say where
  // coordinates come from or the agent has nowhere to go next.
  await assert.rejects(
    TOOLS.weather.execute({ action: 'hourly', query: 'Chengdu' }, {}),
    /does not take place names.*`location`/,
  );
  // A numeric string never reaches `execute`: the tool's schema stops it.
  await assert.rejects(
    TOOLS.weather.execute({ action: 'current', latitude: '31.2', longitude: '121.5' }, {}),
    /latitude/,
  );
  // Swapped pairs are the usual way to land off the globe.
  await assert.rejects(
    TOOLS.weather.execute({ action: 'current', latitude: 121.5, longitude: 31.2 }, {}),
    /`latitude` must be between -90 and 90/,
  );
  await assert.rejects(
    TOOLS.weather.execute({ action: 'current', latitude: 0, longitude: 180.5 }, {}),
    /`longitude` between -180 and 180/,
  );
  // 0, 0 is a real point and the edges are inside the range: these get past
  // validation and stop only because there is no addon on a desktop.
  await assert.rejects(
    TOOLS.weather.execute({ action: 'current', latitude: 0, longitude: 0 }, {}),
    /only available in the iOS app/,
  );
  await assert.rejects(
    TOOLS.weather.execute({ action: 'daily', latitude: -90, longitude: 180, days: 10 }, {}),
    /only available in the iOS app/,
  );
});

test('weather refuses a count it cannot serve rather than quietly serving fewer', async () => {
  const at = { latitude: 31.2, longitude: 121.5 };
  await assert.rejects(TOOLS.weather.execute({ action: 'hourly', ...at, hours: 0 }, {}), /`hours` must be a whole number from 1 to 240/);
  await assert.rejects(TOOLS.weather.execute({ action: 'hourly', ...at, hours: 241 }, {}), /`hours` must be/);
  await assert.rejects(TOOLS.weather.execute({ action: 'hourly', ...at, hours: 1.5 }, {}), /`hours` must be/);
  await assert.rejects(TOOLS.weather.execute({ action: 'daily', ...at, days: 30 }, {}), /`days` must be a whole number from 1 to 10/);
  await assert.rejects(TOOLS.weather.execute({ action: 'hourly', ...at, hours: 240 }, {}), /only available in the iOS app/);
  // A count for the other action is not this call's argument, so it is not judged.
  await assert.rejects(TOOLS.weather.execute({ action: 'current', ...at, hours: 9999 }, {}), /only available in the iOS app/);
});

const WEATHER_ENVELOPE = {
  units: { temperature: 'celsius', speed: 'km/h', pressure: 'hPa', distance: 'km', precipitation: 'mm' },
  timeZone: 'UTC',
  attribution: { service: 'Apple Weather', legalURL: 'https://weatherkit.apple.com/legal-attribution.html' },
};
const WEATHER_CREDIT = 'Weather data: Apple Weather — https://weatherkit.apple.com/legal-attribution.html';

test('weather renders current conditions with their units and ends on the credit line', () => {
  const render = (value) => TOOLS.weather.output.render({ action: 'current' }, value)[0].text;
  const rendered = render({
    ...WEATHER_ENVELOPE,
    current: {
      date: '2026-11-10T08:00:00Z', temperature: 18.36, apparentTemperature: 17.02, humidity: 0.62,
      condition: 'mostlyCloudy', conditionDescription: 'Mostly Cloudy', symbolName: 'cloud',
      wind: { speed: 14.4, gust: 28.2, direction: 230 },
      pressure: 1013.2, visibility: 19.96, uvIndex: 3, cloudCover: 0.71, dewPoint: 10.94, isDaylight: true,
    },
  });
  assert.match(rendered, /^2026-11-10 08:00 UTC: Mostly Cloudy, 18\.4°C \(feels like 17\.0°C\)/);
  assert.match(rendered, /wind 14 km\/h from 230°, gusts 28 km\/h/);
  assert.match(rendered, /humidity 62%, cloud cover 71%, dew point 10\.9°C/);
  assert.match(rendered, /pressure 1013 hPa, visibility 20\.0 km, UV index 3, daylight/);
  assert.equal(rendered.split('\n').at(-1), WEATHER_CREDIT);

  // No gust is a calm reading, not a missing one, and night is said as such.
  const calm = render({
    ...WEATHER_ENVELOPE,
    current: { date: '2026-11-10T20:00:00Z', temperature: 9, condition: 'clear', wind: { speed: 3, direction: 10 }, isDaylight: false },
  });
  assert.doesNotMatch(calm, /gusts/);
  // Falls back to WeatherKit's own word when there is no description.
  assert.match(calm, /UTC: clear, 9\.0°C/);
  assert.match(calm, /dark$/m);

  // Survives an answer with nothing in it, and still credits the source.
  assert.equal(render({ ...WEATHER_ENVELOPE }), `No current conditions came back for that point.\n${WEATHER_CREDIT}`);
  assert.equal(render({}), 'No current conditions came back for that point.');
  assert.doesNotThrow(() => render({ current: {} }));
});

test('weather renders an hourly forecast, says when it was cut, and keeps the credit last', () => {
  const render = (value) => TOOLS.weather.output.render({ action: 'hourly' }, value)[0].text;
  const hour = (date, temperature) => ({
    date, temperature, apparentTemperature: temperature - 1, condition: 'rain', conditionDescription: 'Rain',
    precipitationChance: 0.8, precipitationAmount: 2.34, windSpeed: 21.6, humidity: 0.9, uvIndex: 0,
  });
  const rendered = render({
    ...WEATHER_ENVELOPE,
    hours: [hour('2026-11-10T08:00:00Z', 12), hour('2026-11-10T09:00:00Z', 12.5)],
    total: 3,
    truncated: true,
  });
  const lines = rendered.split('\n');
  assert.equal(lines[0], 'Hour by hour, times in UTC:');
  assert.equal(
    lines[1],
    '2026-11-10 08:00  12.0°C (feels 11.0°C)  Rain  precipitation 80% 2.3 mm  wind 22 km/h  humidity 90%  UV 0',
  );
  assert.equal(lines[3], '… the first 2 of the 3 hours Apple Weather returned');
  assert.equal(lines.at(-1), WEATHER_CREDIT);

  const whole = render({ ...WEATHER_ENVELOPE, hours: [hour('2026-11-10T08:00:00Z', 12)], total: 1, truncated: false });
  assert.doesNotMatch(whole, /the first/);

  assert.equal(
    render({ ...WEATHER_ENVELOPE, hours: [], total: 0, truncated: false }),
    `No hourly forecast came back for that point.\n${WEATHER_CREDIT}`,
  );
  assert.doesNotThrow(() => render({ hours: [{}] }));
});

test('weather renders a daily forecast and warns that a day is stamped in UTC', () => {
  const render = (value) => TOOLS.weather.output.render({ action: 'daily' }, value)[0].text;
  const rendered = render({
    ...WEATHER_ENVELOPE,
    days: [
      {
        // Shanghai's 11 November: local midnight is 16:00 the day before in UTC.
        date: '2026-11-10T16:00:00Z', high: 19.6, low: 11.2, condition: 'partlyCloudy',
        conditionDescription: 'Partly Cloudy', precipitationChance: 0.15, precipitationAmount: 0,
        sunrise: '2026-11-10T22:17:00Z', sunset: '2026-11-11T08:58:00Z', uvIndex: 4, windSpeed: 12.2,
      },
      // A polar day has neither, and the keys are absent rather than null.
      { date: '2026-11-11T16:00:00Z', high: -3, low: -9.5, condition: 'snow', precipitationChance: 0.7, precipitationAmount: 4.25, uvIndex: 0, windSpeed: 30 },
    ],
    total: 10,
    truncated: true,
  });
  const lines = rendered.split('\n');
  assert.match(lines[0], /^Day by day\. .*UTC instant.*local midnight.*a day early/);
  assert.equal(
    lines[1],
    '2026-11-10 16:00  11.2 to 19.6°C  Partly Cloudy  precipitation 15% 0.0 mm  wind 12 km/h  UV 4  sunrise 22:17 sunset 08:58',
  );
  assert.equal(lines[2], '2026-11-11 16:00  -9.5 to -3.0°C  snow  precipitation 70% 4.3 mm  wind 30 km/h  UV 0');
  assert.equal(lines[3], '… the first 2 of the 10 days Apple Weather returned');
  assert.equal(lines.at(-1), WEATHER_CREDIT);

  assert.equal(
    render({ ...WEATHER_ENVELOPE, days: [], total: 0, truncated: false }),
    `No daily forecast came back for that point.\n${WEATHER_CREDIT}`,
  );
  assert.doesNotThrow(() => render({ days: [{}] }));
});
