export const WEB_VITALS_FLUSH_DELAY_MS = 5_000;

const WEB_VITAL_NAMES = new Set(['CLS', 'FCP', 'INP', 'LCP']);

const defaultSchedule = (callback, delayMs) => setTimeout(callback, delayMs);
const defaultCancel = timer => clearTimeout(timer);

// Collects the four vitals and emits one $web_vitals event: when all four have
// arrived, or WEB_VITALS_FLUSH_DELAY_MS after the first one, whichever is first.
export function createWebVitalsReporter(
  initialPath,
  emit,
  buildEvent,
  canonicalizePath,
  schedule = defaultSchedule,
  cancel = defaultCancel,
) {
  const path = canonicalizePath(initialPath).normalizedPath;
  const metrics = {};
  let timer;
  let sent = false;

  const flush = () => {
    if (sent) return;
    sent = true;
    if (timer !== undefined) {
      cancel(timer);
      timer = undefined;
    }
    const event = buildEvent(path, metrics);
    if (event) emit(event);
  };

  return {
    record(name, value) {
      if (sent || !WEB_VITAL_NAMES.has(name)) return;
      if (!Number.isFinite(value) || value < 0) return;

      metrics[name] = value;
      if (timer === undefined) {
        timer = schedule(flush, WEB_VITALS_FLUSH_DELAY_MS);
      }
      if (WEB_VITAL_NAMES.size === Object.keys(metrics).length) flush();
    },
  };
}
