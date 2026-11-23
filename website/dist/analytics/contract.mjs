// Pure analytics contract: no DOM, importable from node. Everything the site
// sends to PostHog is rebuilt from the allowlists here by sanitizeEvent.

export const POSTHOG_PROXY_HOST = 'https://e.codeswhat.com';
export const POSTHOG_UI_HOST = 'https://us.posthog.com';
export const PRODUCTION_HOST = 'dilated.app';

const SCHEMA_VERSION = 1;
const SITE = 'dilated';
const SURFACE = 'marketing';
const PROJECT_KEY_PATTERN = /^phc_[A-Za-z0-9_-]+$/u;
const COOKIELESS_DISTINCT_ID = '$posthog_cookieless';

const KNOWN_PATHS = new Set(['/', '/privacy', '/closed-lid-setup']);

const FILE_ALIASES = new Map([
  ['/index.html', '/'],
  ['/privacy.html', '/privacy'],
  ['/closed-lid-setup.html', '/closed-lid-setup'],
]);

const CTA_COMBINATIONS = new Set([
  'download:availability',
  'release_history:availability',
  'sponsor:availability',
  'donate:availability',
  'closed_lid_setup_download:page',
  'github_repository:header',
]);

const WEB_VITAL_NAMES = ['CLS', 'FCP', 'INP', 'LCP'];
const WEB_VITAL_KEYS = WEB_VITAL_NAMES.map(name => `$web_vitals_${name}_value`);

export function isProductionHost(hostname) {
  return hostname === PRODUCTION_HOST;
}

function normalizedPath(rawPath) {
  const withoutQuery = rawPath.split(/[?#]/u, 1)[0] || '/';
  if (!withoutQuery.startsWith('/')) return '/';
  if (withoutQuery.length > 1 && withoutQuery.endsWith('/')) {
    return withoutQuery.slice(0, -1);
  }
  return withoutQuery;
}

export function canonicalizeAnalyticsRoute(rawPath) {
  const normalized = normalizedPath(rawPath);
  const aliased = FILE_ALIASES.get(normalized) ?? normalized;
  return {
    normalizedPath: aliased,
    path: KNOWN_PATHS.has(aliased) ? aliased : '/_other',
    surface: SURFACE,
  };
}

function baseProperties(rawPath) {
  const { path, surface } = canonicalizeAnalyticsRoute(rawPath);
  return { schema_version: SCHEMA_VERSION, site: SITE, surface, path };
}

// PostHog's Web analytics tables key off $pathname. It carries the canonical
// path, so it adds nothing the event wasn't already sending.
function navigationProperties(rawPath) {
  const base = baseProperties(rawPath);
  return { ...base, $pathname: base.path };
}

export function buildPageviewEvent(rawPath) {
  return { event: '$pageview', properties: navigationProperties(rawPath) };
}

// posthog-js emits $pageleave itself once capture_pageleave is true.
export function buildPageleaveEvent(rawPath) {
  return { event: '$pageleave', properties: navigationProperties(rawPath) };
}

export function buildCtaEvent(rawPath, ctaId, placement) {
  if (!CTA_COMBINATIONS.has(`${ctaId}:${placement}`)) return null;
  return {
    event: 'cta activated',
    properties: { ...baseProperties(rawPath), cta_id: ctaId, placement },
  };
}

export function buildWebVitalsEvent(rawPath, metrics) {
  const properties = baseProperties(rawPath);
  let metricCount = 0;
  for (const name of WEB_VITAL_NAMES) {
    const value = metrics[name];
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
      properties[`$web_vitals_${name}_value`] = value;
      metricCount += 1;
    }
  }
  return metricCount === 0 ? null : { event: '$web_vitals', properties };
}

// $referring_domain is either "$direct" or a bare host (optionally with a
// port). Anything else is dropped rather than trimmed, so an unexpected shape
// can't leak a path. $referrer (the full URL) is never forwarded.
const HOSTNAME_PATTERN =
  /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:\d{1,5})?$/iu;
const DIRECT_REFERRING_DOMAIN = '$direct';

function isAcceptableReferringDomain(value) {
  return (
    typeof value === 'string' && (value === DIRECT_REFERRING_DOMAIN || HOSTNAME_PATTERN.test(value))
  );
}

function rawPathFromProperties(properties) {
  if (typeof properties.path === 'string') return properties.path;
  if (typeof properties.$current_url !== 'string') return undefined;
  try {
    return new URL(properties.$current_url).pathname;
  } catch {
    return undefined;
  }
}

const DNT_ENABLED = new Set(['1', 'yes']);

// posthog-js 1.449.2 skips its own respect_dnt check when cookieless_mode is
// "always", so Do Not Track and Global Privacy Control are checked here.
export function isTrackingRefused(nav, win) {
  return (
    DNT_ENABLED.has(nav?.doNotTrack) ||
    DNT_ENABLED.has(nav?.msDoNotTrack) ||
    DNT_ENABLED.has(win?.doNotTrack) ||
    nav?.globalPrivacyControl === true
  );
}

function currentTrackingRefused() {
  return isTrackingRefused(
    typeof navigator === 'undefined' ? undefined : globalThis.navigator,
    globalThis,
  );
}

export function sanitizeEvent(envelope) {
  if (currentTrackingRefused()) return null;
  if (!envelope || typeof envelope.event !== 'string' || !envelope.properties) return null;
  const rawPath = rawPathFromProperties(envelope.properties);
  const key = envelope.properties.token;
  // PostHog's cookieless ingestion hashes day + team + IP + $host +
  // $raw_user_agent and drops the event if either of the last two is missing,
  // so both must survive the allowlist rebuild. $ip is never forwarded.
  const rawUserAgent = envelope.properties.$raw_user_agent;
  const host = envelope.properties.$host;
  if (
    typeof rawPath !== 'string' ||
    typeof key !== 'string' ||
    !PROJECT_KEY_PATTERN.test(key) ||
    envelope.properties.$cookieless_mode !== true ||
    envelope.properties.$process_person_profile !== false ||
    typeof rawUserAgent !== 'string' ||
    rawUserAgent === '' ||
    typeof host !== 'string' ||
    host === ''
  ) {
    return null;
  }

  let sanitized;
  if (envelope.event === '$pageview') {
    sanitized = buildPageviewEvent(rawPath);
  } else if (envelope.event === '$pageleave') {
    sanitized = buildPageleaveEvent(rawPath);
  } else if (envelope.event === 'cta activated') {
    const ctaId = envelope.properties.cta_id;
    const placement = envelope.properties.placement;
    if (typeof ctaId !== 'string' || typeof placement !== 'string') return null;
    sanitized = buildCtaEvent(rawPath, ctaId, placement);
  } else if (envelope.event === '$web_vitals') {
    const metrics = {};
    WEB_VITAL_KEYS.forEach((metricKey, index) => {
      const value = envelope.properties[metricKey];
      if (typeof value === 'number') metrics[WEB_VITAL_NAMES[index]] = value;
    });
    sanitized = buildWebVitalsEvent(rawPath, metrics);
  } else {
    return null;
  }

  if (!sanitized) return null;
  const output = {
    event: sanitized.event,
    properties: {
      ...sanitized.properties,
      token: key,
      $cookieless_mode: true,
      $process_person_profile: false,
      $raw_user_agent: rawUserAgent,
      $host: host,
    },
    uuid: envelope.uuid,
  };
  if (isAcceptableReferringDomain(envelope.properties.$referring_domain)) {
    output.properties.$referring_domain = envelope.properties.$referring_domain;
  }
  if (envelope.properties.distinct_id === COOKIELESS_DISTINCT_ID) {
    output.properties.distinct_id = COOKIELESS_DISTINCT_ID;
  }
  if (envelope.timestamp instanceof Date && Number.isFinite(envelope.timestamp.getTime())) {
    output.timestamp = envelope.timestamp;
  }
  return output;
}

export function createPostHogOptions(projectKey, proxyHost, uiHost) {
  if (
    !projectKey ||
    !PROJECT_KEY_PATTERN.test(projectKey) ||
    proxyHost !== POSTHOG_PROXY_HOST ||
    uiHost !== POSTHOG_UI_HOST
  ) {
    return null;
  }
  return {
    api_host: POSTHOG_PROXY_HOST,
    ui_host: POSTHOG_UI_HOST,
    autocapture: false,
    rageclick: false,
    capture_pageview: false,
    capture_pageleave: true,
    capture_heatmaps: false,
    capture_dead_clicks: false,
    capture_exceptions: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_surveys_automatic_display: true,
    disable_product_tours: true,
    disable_web_experiments: true,
    advanced_disable_flags: true,
    cookieless_mode: 'always',
    person_profiles: 'never',
    persistence: 'memory',
    disable_persistence: true,
    respect_dnt: true,
    save_campaign_params: false,
    save_referrer: true,
    disable_capture_url_hashes: true,
    disable_scroll_properties: true,
    mask_all_element_attributes: true,
    mask_all_text: true,
    capture_performance: false,
    disable_external_dependency_loading: true,
    before_send: sanitizeEvent,
  };
}
