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
import { fileURLToPath } from 'node:url';
import { binding, capabilities, invoke } from '../plugins/ios-native/binding.mjs';
import { TOOLS, toEpochSeconds } from '../plugins/ios-native/tools.mjs';

test('the example plugin at least parses', () => {
  // It cannot be imported here: it resolves `@deepseek-ai/dsh-tools` from the
  // engine's node_modules, which only exists once it is installed on a device.
  // A syntax check still catches the failure mode that would otherwise surface
  // as a plugin that silently refuses to load on someone's phone.
  const example = fileURLToPath(new URL('../../examples/dsh-plugin-native-demo/index.mjs', import.meta.url));
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
    ['calendar', 'clipboard', 'device_info', 'location', 'maps', 'notify', 'open_url', 'read_image',
     'reminders', 'speak', 'text_analysis']);
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

test('maps refuses before the addon when an end is missing', async () => {
  await assert.rejects(TOOLS.maps.execute({ action: 'search' }, {}), /`search` needs `query`/);
  await assert.rejects(TOOLS.maps.execute({ action: 'eta', toQuery: '上海' }, {}), /needs `fromQuery`/);
  await assert.rejects(TOOLS.maps.execute({ action: 'route', fromQuery: '北京' }, {}), /needs `toQuery`/);
  // Coordinates stand in for a name, and 0 is a real coordinate — a check that
  // tested truthiness would reject the equator and the prime meridian.
  await assert.rejects(
    TOOLS.maps.execute({ action: 'eta', fromLatitude: 0, fromLongitude: 0, toQuery: '上海' }, {}),
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

  assert.match(render('classify', { labels: [{ label: 'receipt', confidence: 0.91 }] }), /91% {2}receipt/);
  assert.match(render('classify', { labels: [] }), /Nothing recognisable/);
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
  assert.match(loc('geocode', { name: '故宫', locality: '北京', country: '中国', latitude: 39.9163, longitude: 116.3972 }),
               /故宫, 北京, 中国: 39\.91630/);
  // Reverse geocoding the open ocean returns a placemark with nothing in it.
  assert.match(loc('reverse', { name: '', thoroughfare: '', locality: '', administrativeArea: '', country: '' }),
               /Nothing is known about that point/);
});

test('a place that resolves to something else is a refusal, not a route', async () => {
  // Measured on a device in the China region: CLGeocoder answered "San Francisco"
  // with a township in Yunnan, and both ends of a route resolved to the same
  // wrong town — a confident one-metre answer. The addon now refuses; this test
  // pins the engine-side half, that the tool does not paper over the refusal.
  await assert.rejects(
    TOOLS.maps.execute({ action: 'eta', fromQuery: 'San Francisco', toQuery: 'San Jose' }, {}),
    /only available in the iOS app/,
  );
});

test('maps names the coordinates it was given rather than "Unknown Location"', () => {
  const rendered = TOOLS.maps.output.render({ action: 'eta' }, {
    from: '39.90420, 116.40740', to: '39.08510, 117.19940',
    seconds: 6910, meters: 137096, mode: 'driving',
  })[0].text;
  assert.match(rendered, /39\.90420, 116\.40740 → 39\.08510, 117\.19940/);
  assert.match(rendered, /1 h 55 min, 137\.1 km/);
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
