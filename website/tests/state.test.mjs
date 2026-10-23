import assert from 'node:assert/strict';
import test from 'node:test';

const state = await import('../dist/state.mjs').catch(() => ({}));

test('a shared link selects its direction and font, rejecting unknown values', () => {
  assert.equal(typeof state.readPreferences, 'function');
  assert.deepEqual(state.readPreferences('?concept=night&font=fraunces'), { concept: 'night', font: 'fraunces' });
  assert.deepEqual(state.readPreferences('?concept=unknown&font=unknown'), { concept: 'gas-station', font: 'barlow' });
});

test('font defaults belong to each direction and a saved font may override them', () => {
  assert.equal(typeof state.readPreferences, 'function');
  assert.deepEqual(state.readPreferences('?concept=field'), { concept: 'field', font: 'instrument' });
  assert.deepEqual(state.readPreferences('?concept=night', { night: 'barlow' }), { concept: 'night', font: 'barlow' });
  assert.deepEqual(state.readPreferences('?concept=night&font=instrument', { night: 'barlow' }), { concept: 'night', font: 'instrument' });
});

test('a preview timer expires at its absolute deadline and never displays negative time', () => {
  assert.equal(typeof state.remainingTime, 'function');
  assert.equal(state.remainingTime(120_000, 0), '02:00');
  assert.equal(state.remainingTime(120_000, 60_001), '01:00');
  assert.equal(state.remainingTime(120_000, 120_001), '00:00');
  assert.equal(state.remainingTime(null, 0), '30:00');
});
