export function initialState() {
  return { awake: false, deadline: null, automationPaused: false, allowDisplaySleep: true };
}

export function transition(state, action, now) {
  const next = state.awake && state.deadline !== null && now >= state.deadline
    ? { ...state, awake: false, deadline: null } : { ...state };
  switch (action.type) {
    case 'start':
      if (action.minutes != null && (!Number.isFinite(action.minutes) || action.minutes <= 0)) {
        throw new RangeError('Duration must be positive and finite.');
      }
      return { ...next, awake: true, deadline: action.minutes == null ? null : now + action.minutes * 60000 };
    case 'stop': return { ...next, awake: false, deadline: null, automationPaused: true };
    case 'resume': return { ...next, automationPaused: false };
    case 'display': return { ...next, allowDisplaySleep: action.allow };
    case 'quit': return { ...next, awake: false, deadline: null };
    default: return next;
  }
}
