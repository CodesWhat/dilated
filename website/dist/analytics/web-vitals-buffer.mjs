export const WEB_VITALS_FLUSH_DELAY_MS = 5_000;

const WEB_VITAL_NAMES = new Set(['CLS', 'FCP', 'INP', 'LCP']);
const HIDE_SEND_OPTIONS = { transport: 'sendBeacon' };

const defaultSchedule = (callback, delayMs) => setTimeout(callback, delayMs);
const defaultCancel = timer => clearTimeout(timer);

// Collects the four vitals. The first $web_vitals event goes out when all four
// have arrived or WEB_VITALS_FLUSH_DELAY_MS after the first one. CLS and INP
// are only reported when the page is hidden, so metrics that arrive later are
// kept: the hide flush sends whatever hasn't gone out yet, once, and anything
// reported after that is sent straight away. No metric is sent twice.
export function createWebVitalsReporter(
  initialPath,
  emit,
  buildEvent,
  canonicalizePath,
  schedule = defaultSchedule,
  cancel = defaultCancel,
) {
  const path = canonicalizePath(initialPath).normalizedPath;
  const pending = {};
  const sentNames = new Set();
  let timer;
  let timerDone = false;
  let hidden = false;

  const cancelTimer = () => {
    if (timer !== undefined) {
      cancel(timer);
      timer = undefined;
    }
  };

  const flush = options => {
    cancelTimer();
    const event = buildEvent(path, pending);
    for (const name of Object.keys(pending)) {
      sentNames.add(name);
      delete pending[name];
    }
    if (event) emit(event, options);
  };

  return {
    record(name, value) {
      if (!WEB_VITAL_NAMES.has(name) || sentNames.has(name)) return;
      if (!Number.isFinite(value) || value < 0) return;

      pending[name] = value;
      if (hidden) {
        flush(HIDE_SEND_OPTIONS);
        return;
      }
      if (sentNames.size + Object.keys(pending).length === WEB_VITAL_NAMES.size) {
        timerDone = true;
        flush();
        return;
      }
      if (timer === undefined && !timerDone) {
        timer = schedule(() => {
          if (timerDone) return;
          timer = undefined;
          timerDone = true;
          flush();
        }, WEB_VITALS_FLUSH_DELAY_MS);
      }
    },

    // listen receives the hide handler and wires it to the real page events.
    attachHideFlush(listen) {
      listen(() => {
        if (hidden) return;
        hidden = true;
        flush(HIDE_SEND_OPTIONS);
      });
    },
  };
}
