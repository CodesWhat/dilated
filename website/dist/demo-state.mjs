import { formatRemaining } from './state.mjs';

export const presets = [15, 30, 60, 120, 240, 480];
const maxListedReasons = 6;

export function presetLabel(minutes) {
  return minutes >= 60 && minutes % 60 === 0
    ? `${minutes / 60} hour${minutes === 60 ? '' : 's'}` : `${minutes} minutes`;
}

export function initialState() {
  return { holds: [], automationPaused: false, nextId: 1 };
}

function withoutExpired(state, now) {
  const holds = state.holds.filter(hold => hold.expiry === null || hold.expiry > now);
  return holds.length === state.holds.length ? { ...state } : { ...state, holds };
}

export function transition(state, action, now) {
  const next = withoutExpired(state, now);
  const update = (id, change) => ({
    ...next, holds: next.holds.map(hold => hold.id === id ? { ...hold, ...change(hold) } : hold),
  });
  switch (action.type) {
    case 'start': {
      if (action.minutes != null && (!Number.isFinite(action.minutes) || action.minutes <= 0)) {
        throw new RangeError('Duration must be positive and finite.');
      }
      const timed = action.minutes != null;
      const hold = {
        id: next.nextId, label: timed ? 'Manual timer' : 'Keep awake',
        expiry: timed ? now + action.minutes * 60000 : null,
        allowDisplaySleep: true, closedLid: false,
      };
      return { ...next, holds: [...next.holds, hold], nextId: next.nextId + 1 };
    }
    case 'stop': return { ...next, holds: [], automationPaused: true };
    case 'resume': return { ...next, automationPaused: false };
    case 'stopHold': return { ...next, holds: next.holds.filter(hold => hold.id !== action.id) };
    case 'extend':
      return update(action.id, hold => hold.expiry === null ? {} : { expiry: hold.expiry + action.minutes * 60000 });
    case 'display': return update(action.id, hold => ({ allowDisplaySleep: !hold.allowDisplaySleep }));
    case 'lid': return update(action.id, hold => ({ closedLid: !hold.closedLid }));
    case 'quit': return { ...next, holds: [] };
    default: return next;
  }
}

export function statusText(state, now) {
  if (state.holds.length === 0) return 'Sleeping normally';
  if (state.holds.some(hold => hold.expiry === null)) return 'Awake indefinitely';
  const latest = Math.max(...state.holds.map(hold => hold.expiry));
  return `Awake for ${formatRemaining(latest, now)} more`;
}

// The menu the app builds in AwakeMenu.make, as plain data the page renders.
export function menuModel(state, now) {
  const holds = state.holds;
  const timed = holds.filter(hold => hold.expiry !== null);
  const close = { type: 'close' };
  const items = [{ kind: 'header', key: 'status', label: statusText(state, now) }];
  if (state.automationPaused) items.push({ kind: 'info', key: 'paused', label: 'Automation paused' });
  items.push({ kind: 'separator' });
  items.push({
    kind: 'item', key: 'toggle', label: holds.length === 0 ? 'Keep Awake' : 'Stop', shortcut: '⌘ D',
    action: { type: holds.length === 0 ? 'start' : 'stop' },
    say: holds.length === 0 ? 'Preview awake indefinitely.' : 'Preview stopped. Automation paused.',
  });
  if (state.automationPaused) {
    items.push({ kind: 'item', key: 'resume', label: 'Resume automation', action: { type: 'resume' }, say: 'Preview automation resumed.' });
  }
  items.push({
    kind: 'submenu', key: 'duration', label: 'Keep awake for',
    items: [
      ...presets.map(minutes => ({
        kind: 'item', key: `preset-${minutes}`, label: presetLabel(minutes),
        action: { type: 'start', minutes }, say: `${presetLabel(minutes)} preview started.`,
      })),
      { kind: 'separator' },
      { kind: 'item', key: 'for-duration', label: 'For a duration…', action: close },
      { kind: 'item', key: 'until-time', label: 'Until a time…', action: close },
      { kind: 'item', key: 'indefinitely', label: 'Indefinitely', action: { type: 'start' }, say: 'Preview awake indefinitely.' },
      { kind: 'separator' },
      { kind: 'item', key: 'file-download', label: 'While a file downloads…', action: close },
      { kind: 'item', key: 'folder-download', label: 'While a folder downloads…', action: close },
    ],
  });
  if (holds.length > 0) {
    const reasons = holds.slice(0, maxListedReasons).map(hold => ({
      kind: 'item', key: `stop-${hold.id}`,
      label: `Stop ${hold.label} (${hold.expiry === null ? 'Indefinite' : `${formatRemaining(hold.expiry, now)} left`})`,
      action: { type: 'stopHold', id: hold.id }, say: `${hold.label} stopped.`,
    }));
    if (holds.length > maxListedReasons) {
      reasons.push({ kind: 'item', key: 'more-reasons', label: `${holds.length - maxListedReasons} more in Settings…`, action: close });
    }
    items.push({ kind: 'submenu', key: 'reasons', label: 'Awake reasons', items: reasons });
  }
  if (timed.length > 0) {
    const extend = timed.flatMap(hold => [15, 60].map(minutes => ({
      kind: 'item', key: `extend-${hold.id}-${minutes}`,
      label: `${timed.length === 1 ? '' : `${hold.label}: `}+${minutes === 15 ? '15 minutes' : '1 hour'}`,
      action: { type: 'extend', id: hold.id, minutes }, say: `${hold.label} extended.`,
    })));
    items.push({ kind: 'submenu', key: 'extend', label: 'Extend', items: extend });
  }
  const target = holds.at(-1);
  if (target) {
    items.push({
      kind: 'checkbox', key: 'display', label: `Allow display sleep for ${target.label}`,
      checked: target.allowDisplaySleep, action: { type: 'display', id: target.id },
    });
    items.push({
      kind: 'checkbox', key: 'lid', label: `Work with lid closed for ${target.label}`,
      checked: target.closedLid, action: { type: 'lid', id: target.id },
    });
  }
  items.push({ kind: 'separator' });
  items.push({ kind: 'item', key: 'settings', label: 'Settings…', shortcut: '⌘ ,', action: close });
  items.push({ kind: 'item', key: 'updates', label: 'Check for Updates…', action: close });
  items.push({ kind: 'item', key: 'about', label: 'About Dilated', action: close });
  items.push({ kind: 'item', key: 'quit', label: 'Quit Dilated', shortcut: '⌘ Q', action: { type: 'quit' }, say: 'Preview ended.' });
  return items;
}
