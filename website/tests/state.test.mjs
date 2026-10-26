import assert from 'node:assert/strict';
import test from 'node:test';

const state = await import('../dist/state.mjs').catch(() => ({}));

test('a shared link selects its direction, rejecting unknown values', () => {
  assert.equal(typeof state.readPreferences, 'function');
  assert.deepEqual(state.readPreferences('?concept=night&font=fraunces'), { concept: 'night', font: 'fraunces' });
  assert.deepEqual(state.readPreferences('?concept=unknown&font=unknown'), { concept: 'gas-station', font: 'barlow' });
});

test('each direction uses its chosen typeface despite old font links or saved preferences', () => {
  assert.equal(typeof state.readPreferences, 'function');
  assert.deepEqual(state.readPreferences('?concept=field'), { concept: 'field', font: 'instrument' });
  assert.deepEqual(state.readPreferences('?concept=gas-station&font=instrument', { 'gas-station': 'fraunces' }), { concept: 'gas-station', font: 'barlow' });
  assert.deepEqual(state.readPreferences('?concept=night', { night: 'barlow' }), { concept: 'night', font: 'fraunces' });
  assert.deepEqual(state.readPreferences('?concept=night&font=instrument'), { concept: 'night', font: 'fraunces' });
});

test('a preview timer expires at its absolute deadline and never displays negative time', () => {
  assert.equal(typeof state.remainingTime, 'function');
  assert.equal(state.remainingTime(120_000, 0), '02:00');
  assert.equal(state.remainingTime(120_000, 60_001), '01:00');
  assert.equal(state.remainingTime(120_000, 120_001), '00:00');
  assert.equal(state.remainingTime(null, 0), '30:00');
});

test('remaining time reads like the app: hours and minutes, minutes rounded up, then seconds', () => {
  assert.equal(typeof state.formatRemaining, 'function');
  assert.equal(state.formatRemaining(5400_000, 0), '1h 30m');
  assert.equal(state.formatRemaining(3600_000, 0), '1h 0m');
  assert.equal(state.formatRemaining(3599_000, 0), '60m');
  assert.equal(state.formatRemaining(61_000, 0), '2m');
  assert.equal(state.formatRemaining(59_000, 0), '59s');
  assert.equal(state.formatRemaining(60_000, 0), '1m');
  assert.equal(state.formatRemaining(59_001, 0), '1m');
  assert.equal(state.formatRemaining(45_000, 0), '45s');
  assert.equal(state.formatRemaining(1_000, 5_000), '0s');
});
