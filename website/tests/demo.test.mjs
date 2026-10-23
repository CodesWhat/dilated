import assert from 'node:assert/strict';
import test from 'node:test';
const demo = await import('../dist/demo-state.mjs').catch(() => ({}));

test('the first manual start is indefinite and keeps the display asleep', () => {
  assert.equal(typeof demo.transition, 'function');
  const state = demo.transition(demo.initialState(), { type: 'start' }, 1000);
  assert.equal(state.awake, true);
  assert.equal(state.deadline, null);
  assert.equal(state.allowDisplaySleep, true);
});

test('Stop pauses automation and a new manual timer does not resume it', () => {
  assert.equal(typeof demo.transition, 'function');
  const stopped = demo.transition(demo.transition(demo.initialState(), { type: 'start' }, 0), { type: 'stop' }, 1);
  assert.equal(stopped.awake, false);
  assert.equal(stopped.automationPaused, true);
  const manual = demo.transition(stopped, { type: 'start', minutes: 15 }, 2000);
  assert.equal(manual.deadline, 902000);
  assert.equal(manual.automationPaused, true);
  assert.equal(demo.transition(manual, { type: 'resume' }, 3000).automationPaused, false);
});

test('a timer expires at its original deadline, including after a hidden tab', () => {
  assert.equal(typeof demo.transition, 'function');
  const state = demo.transition(demo.initialState(), { type: 'start', minutes: 30 }, 1000);
  assert.equal(demo.transition(state, { type: 'tick' }, 1800999).awake, true);
  const ended = demo.transition(state, { type: 'tick' }, 1900000);
  assert.equal(ended.awake, false);
  assert.equal(ended.deadline, null);
  assert.equal(ended.automationPaused, false);
});

test('display preference and Quit match the app without changing automation pause', () => {
  assert.equal(typeof demo.transition, 'function');
  let state = demo.transition(demo.initialState(), { type: 'stop' }, 0);
  state = demo.transition(state, { type: 'display', allow: false }, 0);
  state = demo.transition(state, { type: 'start', minutes: 60 }, 0);
  state = demo.transition(state, { type: 'quit' }, 1);
  assert.equal(state.awake, false);
  assert.equal(state.deadline, null);
  assert.equal(state.automationPaused, true);
  assert.equal(state.allowDisplaySleep, false);
});
