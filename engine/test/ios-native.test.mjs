// The native-capability seam as the engine sees it. These tests run on a
// desktop Node, where the dsh_ios_native addon does not exist — which is
// exactly the case worth pinning: the plugin must contribute nothing rather
// than register tools that cannot work.
//
// The addon's own table (which capability accepts which operation) is enforced
// in native/ios-native/ios_native.m and cannot be reached from here.
import test from 'node:test';
import assert from 'node:assert/strict';
import { binding, capabilities, invoke } from '../plugins/ios-native/binding.mjs';
import { TOOLS } from '../plugins/ios-native/tools.mjs';

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
  assert.deepEqual(names.sort(), ['device_info', 'notify', 'speak']);
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
