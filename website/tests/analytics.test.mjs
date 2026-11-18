import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

import {
  POSTHOG_PROXY_HOST,
  POSTHOG_UI_HOST,
  buildCtaEvent,
  buildPageleaveEvent,
  buildPageviewEvent,
  buildWebVitalsEvent,
  canonicalizeAnalyticsRoute,
  createPostHogOptions,
  isProductionHost,
  isTrackingRefused,
  sanitizeEvent,
} from '../dist/analytics/contract.mjs';
import { WEB_VITALS_FLUSH_DELAY_MS, createWebVitalsReporter } from '../dist/analytics/web-vitals-buffer.mjs';

const KEY = 'phc_mav2oHZzTVaC4mAFEqaLbGEff65uvGMy47LcWSNBFp9J'; // gitleaks:allow
const UA = 'Mozilla/5.0 (Macintosh)';
const TIMESTAMP = new Date('2026-11-17T12:00:00Z');

const envelope = (event, properties = {}, extra = {}) => ({
  event,
  uuid: '0192f1b2-0000-7000-8000-000000000001',
  timestamp: TIMESTAMP,
  properties: {
    token: KEY,
    distinct_id: '$posthog_cookieless',
    $current_url: 'https://dilated.app/privacy?utm_source=x&email=a@b.c#frag',
    $cookieless_mode: true,
    $process_person_profile: false,
    $raw_user_agent: UA,
    $host: 'dilated.app',
    ...properties,
  },
  ...extra,
});

const leaky = {
  $referrer: 'https://news.example.com/private/path?token=1',
  $ip: '203.0.113.9',
  utm_source: 'newsletter',
  utm_campaign: 'launch',
  gclid: 'abc',
  fbclid: 'def',
  $set: { email: 'a@b.c' },
  $device_id: 'device',
  $session_id: 'session',
  $title: 'Privacy',
  email: 'a@b.c',
};

test('canonical paths cover the three pages, aliases and the /_other bucket', () => {
  const path = raw => canonicalizeAnalyticsRoute(raw).path;
  assert.equal(path('/'), '/');
  assert.equal(path('/privacy'), '/privacy');
  assert.equal(path('/closed-lid-setup'), '/closed-lid-setup');
  assert.equal(path('/privacy/'), '/privacy');
  assert.equal(path('/privacy?utm_source=x#top'), '/privacy');
  assert.equal(path('/#availability'), '/');
  assert.equal(path('/index.html'), '/');
  assert.equal(path('/privacy.html'), '/privacy');
  assert.equal(path('/closed-lid-setup.html'), '/closed-lid-setup');
  assert.equal(path('/releases/latest.json'), '/_other');
  assert.equal(path('/privacy/secret'), '/_other');
  assert.equal(path('privacy'), '/');
  assert.equal(path(''), '/');
  assert.equal(canonicalizeAnalyticsRoute('/x').surface, 'marketing');
});

test('pageview and pageleave carry the base properties and $pathname', () => {
  for (const build of [buildPageviewEvent, buildPageleaveEvent]) {
    const { properties } = build('/privacy.html?x=1');
    assert.deepEqual(properties, {
      schema_version: 1,
      site: 'dilated',
      surface: 'marketing',
      path: '/privacy',
      $pathname: '/privacy',
    });
  }
  assert.equal(buildPageviewEvent('/').event, '$pageview');
  assert.equal(buildPageleaveEvent('/').event, '$pageleave');
});

test('the CTA allowlist accepts the real combinations and rejects everything else', () => {
  const accepted = [
    ['download', 'availability'],
    ['release_history', 'availability'],
    ['sponsor', 'availability'],
    ['donate', 'availability'],
    ['closed_lid_setup_download', 'page'],
    ['github_repository', 'header'],
  ];
  for (const [id, placement] of accepted) {
    const event = buildCtaEvent('/', id, placement);
    assert.equal(event.event, 'cta activated');
    assert.deepEqual(event.properties, {
      schema_version: 1, site: 'dilated', surface: 'marketing', path: '/', cta_id: id, placement,
    });
  }
  assert.equal(buildCtaEvent('/', 'download', 'header'), null);
  assert.equal(buildCtaEvent('/', 'github_repository', 'availability'), null);
  assert.equal(buildCtaEvent('/', 'unknown', 'availability'), null);
  assert.equal(buildCtaEvent('/', undefined, undefined), null);
});

test('web vitals events keep only finite non-negative metrics', () => {
  const event = buildWebVitalsEvent('/privacy', { LCP: 1200, CLS: 0, INP: -1, FCP: Number.NaN });
  assert.equal(event.event, '$web_vitals');
  assert.deepEqual(event.properties, {
    schema_version: 1, site: 'dilated', surface: 'marketing', path: '/privacy',
    $web_vitals_CLS_value: 0, $web_vitals_LCP_value: 1200,
  });
  assert.equal(buildWebVitalsEvent('/', {}), null);
  assert.equal(buildWebVitalsEvent('/', { LCP: -5 }), null);
});

test('sanitizeEvent rebuilds a pageview from the allowlist and drops everything else', () => {
  const output = sanitizeEvent(envelope('$pageview', { ...leaky, $referring_domain: 'news.example.com' }));
  assert.deepEqual(Object.keys(output).sort(), ['event', 'properties', 'timestamp', 'uuid']);
  assert.deepEqual(output.properties, {
    schema_version: 1,
    site: 'dilated',
    surface: 'marketing',
    path: '/privacy',
    $pathname: '/privacy',
    token: KEY,
    $cookieless_mode: true,
    $process_person_profile: false,
    $raw_user_agent: UA,
    $host: 'dilated.app',
    $referring_domain: 'news.example.com',
    distinct_id: '$posthog_cookieless',
  });
  assert.equal(output.timestamp, TIMESTAMP);
  assert.equal(output.uuid, '0192f1b2-0000-7000-8000-000000000001');
  for (const key of Object.keys(leaky)) assert.ok(!(key in output.properties), key);
  assert.ok(!('$current_url' in output.properties));
});

test('sanitizeEvent handles each event type', () => {
  assert.equal(sanitizeEvent(envelope('$pageleave')).event, '$pageleave');
  assert.equal(sanitizeEvent(envelope('$pageleave')).properties.$pathname, '/privacy');

  const cta = sanitizeEvent(envelope('cta activated', { cta_id: 'github_repository', placement: 'header' }));
  assert.equal(cta.properties.cta_id, 'github_repository');
  assert.equal(cta.properties.placement, 'header');
  assert.equal(sanitizeEvent(envelope('cta activated', { cta_id: 'download', placement: 'header' })), null);
  assert.equal(sanitizeEvent(envelope('cta activated', { cta_id: 1, placement: 'header' })), null);

  const vitals = sanitizeEvent(envelope('$web_vitals', {
    $web_vitals_LCP_value: 900, $web_vitals_CLS_value: 0.01, $web_vitals_LCP_event: { big: 'object' },
  }));
  assert.equal(vitals.properties.$web_vitals_LCP_value, 900);
  assert.equal(vitals.properties.$web_vitals_CLS_value, 0.01);
  assert.ok(!('$web_vitals_LCP_event' in vitals.properties));
  assert.equal(sanitizeEvent(envelope('$web_vitals')), null);

  assert.equal(sanitizeEvent(envelope('$autocapture')), null);
  assert.equal(sanitizeEvent(envelope('$exception')), null);
  assert.equal(sanitizeEvent(envelope('custom event')), null);
});

test('sanitizeEvent canonicalizes the path from $current_url, preferring an explicit path property', () => {
  const unknown = sanitizeEvent(envelope('$pageview', { $current_url: 'https://dilated.app/some/secret/page?x=1' }));
  assert.equal(unknown.properties.path, '/_other');
  const aliased = sanitizeEvent(envelope('$pageview', { $current_url: 'https://dilated.app/index.html' }));
  assert.equal(aliased.properties.path, '/');
  assert.equal(sanitizeEvent(envelope('$pageview', { $current_url: 'not a url' })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $current_url: undefined })), null);
});

test('referring domain is kept only as $direct or a bare hostname', () => {
  const referring = value => sanitizeEvent(envelope('$pageview', { $referring_domain: value })).properties.$referring_domain;
  assert.equal(referring('$direct'), '$direct');
  assert.equal(referring('github.com'), 'github.com');
  assert.equal(referring('localhost:5173'), 'localhost:5173');
  for (const bad of ['https://github.com/path', 'github.com/path', 'a b', '', 42, null, 'x.com?q=1', '$other']) {
    assert.equal(referring(bad), undefined, String(bad));
  }
});

test('the distinct id survives only as the cookieless sentinel; a bad timestamp is dropped', () => {
  assert.equal(sanitizeEvent(envelope('$pageview', { distinct_id: 'person-123' })).properties.distinct_id, undefined);
  assert.equal(sanitizeEvent(envelope('$pageview', { distinct_id: undefined })).properties.distinct_id, undefined);
  assert.equal('timestamp' in sanitizeEvent(envelope('$pageview', {}, { timestamp: new Date('nope') })), false);
  assert.equal('timestamp' in sanitizeEvent(envelope('$pageview', {}, { timestamp: '2026-11-17' })), false);
});

test('sanitizeEvent rejects envelopes missing a required field', () => {
  assert.equal(sanitizeEvent(null), null);
  assert.equal(sanitizeEvent({}), null);
  assert.equal(sanitizeEvent({ event: '$pageview' }), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { token: 'not-a-key' })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { token: undefined })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $cookieless_mode: undefined })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $cookieless_mode: 'true' })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $process_person_profile: true })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $process_person_profile: undefined })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $raw_user_agent: '' })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $raw_user_agent: undefined })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $host: '' })), null);
  assert.equal(sanitizeEvent(envelope('$pageview', { $host: undefined })), null);
});

test('createPostHogOptions returns the cookieless, no-persistence, no-campaign shape', () => {
  const options = createPostHogOptions(KEY, POSTHOG_PROXY_HOST, POSTHOG_UI_HOST);
  assert.equal(options.api_host, 'https://e.codeswhat.com');
  assert.equal(options.ui_host, 'https://us.posthog.com');
  assert.equal(options.cookieless_mode, 'always');
  assert.equal(options.person_profiles, 'never');
  assert.equal(options.persistence, 'memory');
  assert.equal(options.disable_persistence, true);
  assert.equal(options.autocapture, false);
  assert.equal(options.capture_pageview, false);
  assert.equal(options.capture_pageleave, true);
  assert.equal(options.advanced_disable_flags, true);
  assert.equal(options.disable_session_recording, true);
  assert.equal(options.respect_dnt, true);
  assert.equal(options.save_referrer, true);
  assert.equal(options.save_campaign_params, false);
  assert.equal(options.capture_performance, false);
  assert.equal(options.disable_external_dependency_loading, true);
  assert.equal(options.before_send, sanitizeEvent);

  assert.equal(createPostHogOptions(undefined, POSTHOG_PROXY_HOST, POSTHOG_UI_HOST), null);
  assert.equal(createPostHogOptions('bad', POSTHOG_PROXY_HOST, POSTHOG_UI_HOST), null);
  assert.equal(createPostHogOptions(KEY, 'https://example.com', POSTHOG_UI_HOST), null);
  assert.equal(createPostHogOptions(KEY, POSTHOG_PROXY_HOST, 'https://example.com'), null);
});

test('analytics only run on the production host', () => {
  assert.equal(isProductionHost('dilated.app'), true);
  for (const host of ['localhost', '127.0.0.1', 'dilated-website.vercel.app', 'www.dilated.app', 'dilated.app.evil.com', '']) {
    assert.equal(isProductionHost(host), false, host);
  }
});

test('the web vitals buffer flushes after 5s or when all four metrics arrive, once', () => {
  const emitted = [];
  const timers = [];
  const make = () => createWebVitalsReporter(
    '/privacy.html?x=1',
    event => emitted.push(event),
    buildWebVitalsEvent,
    canonicalizeAnalyticsRoute,
    (callback, delay) => { timers.push({ callback, delay, cancelled: false }); return timers.length - 1; },
    id => { timers[id].cancelled = true; },
  );

  const partial = make();
  partial.record('LCP', 1000);
  partial.record('LCP', 1100);
  partial.record('bogus', 1);
  partial.record('CLS', -1);
  partial.record('FCP', Number.NaN);
  assert.equal(timers.length, 1);
  assert.equal(timers[0].delay, WEB_VITALS_FLUSH_DELAY_MS);
  assert.equal(WEB_VITALS_FLUSH_DELAY_MS, 5000);
  assert.equal(emitted.length, 0);
  timers[0].callback();
  assert.equal(emitted.length, 1);
  assert.equal(emitted[0].properties.path, '/privacy');
  assert.equal(emitted[0].properties.$web_vitals_LCP_value, 1100);
  partial.record('INP', 10);
  timers[0].callback();
  assert.equal(emitted.length, 1);

  emitted.length = 0;
  timers.length = 0;
  const full = make();
  for (const name of ['LCP', 'INP', 'CLS', 'FCP']) full.record(name, 1);
  assert.equal(emitted.length, 1);
  assert.equal(timers[0].cancelled, true);
  assert.equal(Object.keys(emitted[0].properties).filter(key => key.startsWith('$web_vitals_')).length, 4);
});

test('vercel.json allows e.codeswhat.com in script-src and connect-src and nothing else new', async () => {
  const config = JSON.parse(await readFile(new URL('../vercel.json', import.meta.url), 'utf8'));
  const csp = config.routes.find(route => route.headers?.['Content-Security-Policy']).headers['Content-Security-Policy'];
  const directives = Object.fromEntries(csp.split(';').map(part => {
    const [name, ...values] = part.trim().split(/\s+/);
    return [name, values];
  }));
  assert.deepEqual(directives['script-src'], ["'self'", 'https://e.codeswhat.com']);
  assert.deepEqual(directives['connect-src'], ["'self'", 'https://e.codeswhat.com']);
  for (const [name, values] of Object.entries(directives)) {
    if (name === 'script-src' || name === 'connect-src') continue;
    assert.ok(!values.some(value => value.includes('codeswhat.com')), `${name} must not allow the proxy`);
  }
  assert.deepEqual(directives['default-src'], ["'self'"]);
  assert.deepEqual(directives['style-src'], ["'self'"]);
  assert.deepEqual(directives['img-src'], ["'self'"]);
});

test('every page wires the client module and its data-cta attributes are allowlisted', async () => {
  const pages = { 'index.html': ['./analytics/client.mjs', 4], 'privacy.html': ['/analytics/client.mjs', 1], 'closed-lid-setup.html': ['/analytics/client.mjs', 2] };
  for (const [name, [src, count]] of Object.entries(pages)) {
    const html = await readFile(new URL(`../dist/${name}`, import.meta.url), 'utf8');
    assert.ok(html.includes(`<script type="module" src="${src}"></script>`), `${name} loads the client`);
    const ctas = [...html.matchAll(/data-cta="([^"]+)" data-cta-placement="([^"]+)"/g)];
    assert.equal(ctas.length, count, name);
    for (const [, id, placement] of ctas) assert.ok(buildCtaEvent('/', id, placement), `${name}: ${id}:${placement}`);
  }
});

test('the vendored modules load as-is: no bare-specifier or dynamic imports', async () => {
  for (const name of ['posthog-js-1.449.2.mjs', 'web-vitals-6.2.1.mjs']) {
    const source = await readFile(new URL(`../dist/assets/vendor/${name}`, import.meta.url), 'utf8');
    assert.doesNotMatch(source, /\bimport\s*\(/, name);
    assert.doesNotMatch(source, /(?:^|[;}\s])import\s*(?:[\w*{][^;]*?\s)?from\s*["']/, name);
  }
});

const makeReporter = () => {
  const emitted = [];
  const timers = [];
  let hide;
  const reporter = createWebVitalsReporter(
    '/',
    (event, options) => emitted.push({ event, options }),
    buildWebVitalsEvent,
    canonicalizeAnalyticsRoute,
    (callback, delay) => { timers.push({ callback, delay, cancelled: false }); return timers.length - 1; },
    id => { timers[id].cancelled = true; },
  );
  reporter.attachHideFlush(handler => { hide = handler; });
  return { emitted, timers, reporter, hide: () => hide() };
};

test('CLS and INP that arrive after the 5s flush are sent once on hide via sendBeacon', () => {
  const { emitted, timers, reporter, hide } = makeReporter();
  reporter.record('LCP', 900);
  reporter.record('FCP', 400);
  timers[0].callback();
  assert.equal(emitted.length, 1);
  assert.equal(emitted[0].options, undefined);

  reporter.record('CLS', 0.1);
  reporter.record('LCP', 950);
  assert.equal(emitted.length, 1);
  hide();
  hide();
  assert.equal(emitted.length, 2);
  assert.deepEqual(emitted[1].options, { transport: 'sendBeacon' });
  const props = emitted[1].event.properties;
  assert.equal(props.$web_vitals_CLS_value, 0.1);
  assert.equal('$web_vitals_LCP_value' in props, false);
  assert.equal('$web_vitals_FCP_value' in props, false);
  reporter.record('INP', 80);
  assert.equal(emitted.length, 3);
  assert.equal(emitted[2].event.properties.$web_vitals_INP_value, 80);
});

test('a hide before the timer sends what it has once, and later metrics go out alone', () => {
  const { emitted, timers, reporter, hide } = makeReporter();
  reporter.record('LCP', 900);
  hide();
  assert.equal(emitted.length, 1);
  assert.equal(timers[0].cancelled, true);
  hide();
  assert.equal(emitted.length, 1);
  reporter.record('CLS', 0.2);
  assert.equal(emitted.length, 2);
  assert.equal(emitted[1].event.properties.$web_vitals_CLS_value, 0.2);
  reporter.record('CLS', 0.3);
  assert.equal(emitted.length, 2);
});

test('a hide with nothing recorded emits nothing, and the all-four flush still fires immediately', () => {
  const empty = makeReporter();
  empty.hide();
  assert.equal(empty.emitted.length, 0);

  const full = makeReporter();
  for (const name of ['LCP', 'INP', 'CLS', 'FCP']) full.reporter.record(name, 1);
  assert.equal(full.emitted.length, 1);
  full.hide();
  assert.equal(full.emitted.length, 1);
});

test('isTrackingRefused honors Do Not Track and Global Privacy Control', () => {
  assert.equal(isTrackingRefused({ doNotTrack: '1' }), true);
  assert.equal(isTrackingRefused({ doNotTrack: 'yes' }), true);
  assert.equal(isTrackingRefused({ msDoNotTrack: '1' }), true);
  assert.equal(isTrackingRefused({}, { doNotTrack: '1' }), true);
  assert.equal(isTrackingRefused({ globalPrivacyControl: true }), true);
  assert.equal(isTrackingRefused({ doNotTrack: '0', globalPrivacyControl: false }, { doNotTrack: 'unspecified' }), false);
  assert.equal(isTrackingRefused({}), false);
  assert.equal(isTrackingRefused(undefined, undefined), false);
});

test('sanitizeEvent returns null when the browser sends DNT or GPC, and works normally otherwise', () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  const setNavigator = value => Object.defineProperty(globalThis, 'navigator', { value, configurable: true, writable: true });
  const build = () => sanitizeEvent(envelope('$pageview', {}));
  try {
    setNavigator({});
    assert.notEqual(build(), null);
    setNavigator({ doNotTrack: '1' });
    assert.equal(build(), null);
    setNavigator({ globalPrivacyControl: true });
    assert.equal(build(), null);
    setNavigator({ doNotTrack: '0' });
    assert.notEqual(build(), null);
  } finally {
    if (original) Object.defineProperty(globalThis, 'navigator', original);
    else delete globalThis.navigator;
  }
});
