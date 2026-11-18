// Cookieless page analytics. Loads only on the production host, so localhost,
// previews and test runs send nothing.
import posthog from '../assets/vendor/posthog-js-1.449.2.mjs';
import { onCLS, onFCP, onINP, onLCP } from '../assets/vendor/web-vitals-6.2.1.mjs';

import {
  POSTHOG_PROXY_HOST,
  POSTHOG_UI_HOST,
  buildCtaEvent,
  buildPageviewEvent,
  buildWebVitalsEvent,
  canonicalizeAnalyticsRoute,
  createPostHogOptions,
  isProductionHost,
  isTrackingRefused,
} from './contract.mjs';
import { createWebVitalsReporter } from './web-vitals-buffer.mjs';

// Public write-only project key, same as the other CodesWhat sites.
const PROJECT_KEY = 'phc_mav2oHZzTVaC4mAFEqaLbGEff65uvGMy47LcWSNBFp9J'; // gitleaks:allow

function capture(event, options) {
  if (event) posthog.capture(event.event, event.properties, options);
}

function start() {
  if (isTrackingRefused(navigator, window)) return;
  const options = createPostHogOptions(PROJECT_KEY, POSTHOG_PROXY_HOST, POSTHOG_UI_HOST);
  if (!options) return;
  posthog.init(PROJECT_KEY, options);

  const path = location.pathname;
  capture(buildPageviewEvent(path));

  const vitals = createWebVitalsReporter(path, capture, buildWebVitalsEvent, canonicalizeAnalyticsRoute);
  const record = metric => vitals.record(metric.name, metric.value);
  onLCP(record);
  onINP(record);
  onCLS(record);
  onFCP(record);
  // Registered after web-vitals' own listeners so CLS and INP, which it reports
  // on hide, are recorded before this flush runs.
  vitals.attachHideFlush(onHide => {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') onHide();
    });
    window.addEventListener('pagehide', onHide);
  });

  document.addEventListener('click', event => {
    const target = event.target instanceof Element ? event.target.closest('[data-cta]') : null;
    if (!target) return;
    capture(buildCtaEvent(location.pathname, target.dataset.cta, target.dataset.ctaPlacement));
  });
}

if (isProductionHost(location.hostname)) start();
