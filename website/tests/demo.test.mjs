import assert from 'node:assert/strict';
import test from 'node:test';
const demo = await import('../dist/demo-state.mjs').catch(() => ({}));

const MIN = 60000;
const run = (state, ...steps) => steps.reduce((current, [action, now]) => demo.transition(current, action, now), state);
const find = (items, key) => items.flatMap(item => item.kind === 'submenu' ? [item, ...item.items] : [item]).find(item => item.key === key);
const labels = items => items.filter(item => item.label).map(item => item.label);

test('status text covers no holds, an indefinite hold and timed holds', () => {
  assert.equal(typeof demo.transition, 'function');
  const idle = demo.initialState();
  assert.equal(demo.statusText(idle, 0), 'Sleeping normally');
  const timed = run(idle, [{ type: 'start', minutes: 30 }, 0]);
  assert.equal(demo.statusText(timed, 0), 'Awake for 30m more');
  assert.equal(demo.statusText(timed, 29 * MIN + 1000), 'Awake for 59s more');
  assert.equal(demo.statusText(run(timed, [{ type: 'start', minutes: 120 }, 0]), 0), 'Awake for 2h 0m more');
  assert.equal(demo.statusText(run(timed, [{ type: 'start' }, 0]), 0), 'Awake indefinitely');
});

test('manual holds carry the labels the app uses', () => {
  const state = run(demo.initialState(), [{ type: 'start' }, 0], [{ type: 'start', minutes: 15 }, 0]);
  assert.deepEqual(state.holds.map(hold => hold.label), ['Keep awake', 'Manual timer']);
  assert.equal(state.holds[1].expiry, 15 * MIN);
  assert.throws(() => demo.transition(demo.initialState(), { type: 'start', minutes: 0 }, 0), RangeError);
});

test('Stop ends every hold and pauses automation until Resume', () => {
  const started = run(demo.initialState(), [{ type: 'start' }, 0], [{ type: 'start', minutes: 15 }, 0]);
  const idle = demo.menuModel(demo.initialState(), 0);
  assert.equal(find(idle, 'toggle').label, 'Keep Awake');
  assert.equal(find(demo.menuModel(started, 0), 'toggle').label, 'Stop');
  const stopped = run(started, [{ type: 'stop' }, 1]);
  assert.deepEqual(stopped.holds, []);
  assert.equal(stopped.automationPaused, true);
  const model = demo.menuModel(stopped, 1);
  assert.equal(labels(model)[0], 'Sleeping normally');
  assert.ok(find(model, 'paused'));
  assert.equal(find(model, 'resume').label, 'Resume automation');
  const preset = find(model, 'duration').items.find(item => item.key === 'preset-15');
  const manual = run(stopped, [preset.action, 2000]);
  assert.equal(manual.holds[0].expiry, 2000 + 15 * MIN);
  assert.equal(manual.automationPaused, true);
  const resumed = run(manual, [{ type: 'resume' }, 3000]);
  assert.equal(resumed.automationPaused, false);
  const after = demo.menuModel(resumed, 3000);
  assert.equal(find(after, 'paused'), undefined);
  assert.equal(find(after, 'resume'), undefined);
});

test('the duration submenu lists the app presets and the dialog items', () => {
  const duration = find(demo.menuModel(demo.initialState(), 0), 'duration');
  assert.deepEqual(labels(duration.items), [
    '15 minutes', '30 minutes', '1 hour', '2 hours', '4 hours', '8 hours',
    'For a duration…', 'Until a time…', 'Indefinitely', 'While a file downloads…', 'While a folder downloads…',
  ]);
  assert.deepEqual(duration.items.map(item => item.kind === 'separator'), [
    false, false, false, false, false, false, true, false, false, false, true, false, false,
  ]);
  for (const key of ['for-duration', 'until-time', 'file-download', 'folder-download']) {
    assert.deepEqual(find(duration.items, key).action, { type: 'close' });
  }
  assert.deepEqual(find(duration.items, 'preset-480').action, { type: 'start', minutes: 480 });
});

test('Awake reasons stops one hold at a time and only appears with holds', () => {
  assert.equal(find(demo.menuModel(demo.initialState(), 0), 'reasons'), undefined);
  const state = run(demo.initialState(), [{ type: 'start' }, 0], [{ type: 'start', minutes: 90 }, 0]);
  const reasons = find(demo.menuModel(state, 0), 'reasons');
  assert.deepEqual(labels(reasons.items), ['Stop Keep awake (Indefinite)', 'Stop Manual timer (1h 30m left)']);
  const [keep, timer] = state.holds;
  const left = run(state, [reasons.items[0].action, 1]);
  assert.deepEqual(left.holds.map(hold => hold.id), [timer.id]);
  assert.equal(left.automationPaused, false);
  assert.equal(find(demo.menuModel(left, 1), 'reasons').items[0].label, 'Stop Manual timer (1h 30m left)');
  assert.notEqual(keep.id, timer.id);
});

test('Extend adds time to timed holds and prefixes labels only with several', () => {
  const none = run(demo.initialState(), [{ type: 'start' }, 0]);
  assert.equal(find(demo.menuModel(none, 0), 'extend'), undefined);
  const one = run(none, [{ type: 'start', minutes: 30 }, 0]);
  const extend = find(demo.menuModel(one, 0), 'extend');
  assert.deepEqual(labels(extend.items), ['+15 minutes', '+1 hour']);
  const longer = run(one, [extend.items[0].action, 0], [extend.items[1].action, 0]);
  assert.equal(longer.holds[1].expiry, (30 + 15 + 60) * MIN);
  assert.equal(longer.holds[0].expiry, null);
  const two = run(one, [{ type: 'start', minutes: 60 }, 0]);
  assert.deepEqual(labels(find(demo.menuModel(two, 0), 'extend').items), [
    'Manual timer: +15 minutes', 'Manual timer: +1 hour', 'Manual timer: +15 minutes', 'Manual timer: +1 hour',
  ]);
});

test('display sleep starts allowed and the lid checkbox only flips its mark', () => {
  assert.equal(find(demo.menuModel(demo.initialState(), 0), 'display'), undefined);
  const state = run(demo.initialState(), [{ type: 'start' }, 0]);
  const model = demo.menuModel(state, 0);
  assert.equal(find(model, 'display').label, 'Allow display sleep for Keep awake');
  assert.equal(find(model, 'display').checked, true);
  assert.equal(find(model, 'lid').label, 'Work with lid closed for Keep awake');
  assert.equal(find(model, 'lid').checked, false);
  const toggled = run(state, [find(model, 'display').action, 0], [find(model, 'lid').action, 0]);
  const after = demo.menuModel(toggled, 0);
  assert.equal(find(after, 'display').checked, false);
  assert.equal(find(after, 'lid').checked, true);
  const timed = run(state, [{ type: 'start', minutes: 15 }, 0]);
  assert.equal(find(demo.menuModel(timed, 0), 'display').label, 'Allow display sleep for Manual timer');
});

test('a timer expires at its original deadline, including after a hidden tab', () => {
  const state = run(demo.initialState(), [{ type: 'start', minutes: 30 }, 1000]);
  assert.equal(demo.transition(state, { type: 'tick' }, 1800999).holds.length, 1);
  const ended = demo.transition(state, { type: 'tick' }, 1801000);
  assert.deepEqual(ended.holds, []);
  assert.equal(ended.automationPaused, false);
});

test('Quit ends the holds without pausing automation; Settings and About just close', () => {
  const state = run(demo.initialState(), [{ type: 'start' }, 0]);
  const quit = run(state, [{ type: 'quit' }, 1]);
  assert.deepEqual(quit.holds, []);
  assert.equal(quit.automationPaused, false);
  const model = demo.menuModel(state, 0);
  assert.deepEqual(labels(model).slice(-3), ['Settings…', 'About Dilated', 'Quit Dilated']);
  assert.deepEqual(find(model, 'settings').action, { type: 'close' });
  assert.deepEqual(find(model, 'about').action, { type: 'close' });
  assert.equal(find(model, 'settings').shortcut, '⌘ ,');
  assert.equal(find(model, 'quit').shortcut, '⌘ Q');
});
