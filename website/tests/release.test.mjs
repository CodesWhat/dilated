import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const release = await import('../dist/release.mjs').catch(() => ({}));
const baseURL = 'https://example.com/dilated/';
const metadata = {
  released: true,
  version: '1.0.0',
  build: '7',
  downloadURL: './releases/Dilated-1.0.0.dmg',
  sha256: 'a'.repeat(64),
  minimumMacOS: '26.0',
  architecture: 'arm64',
};

test('the static page describes the public beta while downloads wait for verified metadata', async () => {
  const html = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8');
  assert.doesNotMatch(html, /no public download|first release is in testing|currently in testing/i);
  assert.match(html, /data-release-copy>[^<]*public beta/i);
  assert.match(html, /<a[^>]*href="https:\/\/github\.com\/CodesWhat\/dilated\/releases"[^>]*>Release history/);
  const downloadLinks = [...html.matchAll(/<a\b[^>]*data-release-link[^>]*>/g)].map(match => match[0]);
  assert.ok(downloadLinks.length > 0);
  for (const link of downloadLinks) {
    const href = link.match(/\bhref="([^"]*)"/)?.[1];
    assert.ok(href === '#availability' || (href === undefined && /\bhidden\b/.test(link)), link);
  }
});

test('only a complete accepted release enables the download', () => {
  assert.equal(typeof release.validateRelease, 'function');
  assert.equal(release.validateRelease(null, baseURL), null);
  assert.equal(release.validateRelease({}, baseURL), null);
  assert.equal(release.validateRelease({ ...metadata, released: false }, baseURL), null);
  for (const key of Object.keys(metadata)) {
    const incomplete = { ...metadata };
    delete incomplete[key];
    assert.equal(release.validateRelease(incomplete, baseURL), null, key);
  }
  assert.deepEqual(release.validateRelease(metadata, baseURL), {
    ...metadata,
    downloadURL: 'https://example.com/dilated/releases/Dilated-1.0.0.dmg',
    prerelease: false,
    unverified: [],
  });
});

test('release links permit page-relative paths and HTTPS without credentials', () => {
  assert.equal(typeof release.validateRelease, 'function');
  const absolute = 'https://github.com/CodesWhat/dilated/releases/download/v1.0.0/Dilated.dmg';
  assert.equal(release.validateRelease({ ...metadata, downloadURL: absolute }, baseURL).downloadURL, absolute);
  assert.equal(release.validateRelease(metadata, 'http://127.0.0.1:5173/').downloadURL, 'http://127.0.0.1:5173/releases/Dilated-1.0.0.dmg');
  for (const downloadURL of ['javascript:alert(1)', 'data:text/html,bad', 'file:///tmp/app.dmg', 'http://example.com/app.dmg', '//example.com/app.dmg', 'https://user:secret@example.com/app.dmg', '#download', '?download=1', '', ' releases/app.dmg', 'https:\\example.com/app.dmg']) {
    assert.equal(release.validateRelease({ ...metadata, downloadURL }, baseURL), null, downloadURL);
  }
});

test('release metadata rejects malformed integrity and unsupported requirements', () => {
  assert.equal(typeof release.validateRelease, 'function');
  for (const invalid of [
    { sha256: 'abc' }, { sha256: 'g'.repeat(64) },
    { architecture: 'x86_64' }, { minimumMacOS: '25.0' },
    { minimumMacOS: 'latest' }, { version: '' }, { version: '<b>1.0</b>' },
    { build: '' }, { build: -1 }, { build: 'seven' },
  ]) assert.equal(release.validateRelease({ ...metadata, ...invalid }, baseURL), null, JSON.stringify(invalid));
  assert.equal(release.validateRelease({ ...metadata, version: '1.1.0-beta.1', build: 8 }, baseURL).build, '8');
});

test('missing, unreadable or invalid metadata leaves the testing state available', async () => {
  assert.equal(typeof release.loadRelease, 'function');
  for (const fetcher of [
    async () => ({ ok: false }),
    async () => { throw new Error('offline'); },
    async () => ({ ok: true, json: async () => { throw new Error('not JSON'); } }),
    async () => ({ ok: true, json: async () => ({ ...metadata, released: false }) }),
  ]) assert.equal(await release.loadRelease(fetcher, baseURL), null);
  let requested;
  const found = await release.loadRelease(async (url, options) => {
    requested = { url, options };
    return { ok: true, json: async () => metadata };
  }, baseURL);
  assert.equal(requested.url, 'https://example.com/dilated/releases/latest.json');
  assert.equal(requested.options.cache, 'no-store');
  assert.equal(found.version, '1.0.0');
});

test('prerelease and unverified checks pass through with safe defaults', () => {
  assert.equal(release.validateRelease(metadata, baseURL).prerelease, false);
  assert.deepEqual(release.validateRelease(metadata, baseURL).unverified, []);
  const beta = release.validateRelease({ ...metadata, version: '1.0.0-beta.1', prerelease: true, unverified: ['rebootRecovery', 'nativeUI'] }, baseURL);
  assert.equal(beta.prerelease, true);
  assert.deepEqual(beta.unverified, ['rebootRecovery', 'nativeUI']);
  for (const invalid of [{ prerelease: 'yes' }, { prerelease: 1 }, { unverified: 'nativeUI' }, { unverified: ['ok', 7] }, { unverified: [null] }, { unverified: {} }]) {
    assert.equal(release.validateRelease({ ...metadata, ...invalid }, baseURL), null, JSON.stringify(invalid));
  }
});

test('a beta release changes the download label, copy, summary and caveat', () => {
  const beta = release.releaseCopy(release.validateRelease({ ...metadata, version: '1.0.0-beta.1', prerelease: true, unverified: ['rebootRecovery', 'nativeUI'] }, baseURL));
  assert.equal(beta.label, 'Download beta for Mac');
  assert.equal(beta.copy, 'Dilated 1.0.0-beta.1 is a public beta for macOS 26.0+ on Apple Silicon. Free software from CodesWhat, under MIT.');
  assert.equal(beta.summary, 'BETA 1.0.0-beta.1 · MACOS 26.0+ · APPLE SILICON · MIT LICENSE');
  assert.equal(beta.caveat, 'Closed-lid mode is experimental in this beta. Not yet verified on hardware: rebootRecovery, nativeUI.');
  const clean = release.releaseCopy(release.validateRelease({ ...metadata, version: '1.0.0-beta.2', prerelease: true }, baseURL));
  assert.equal(clean.caveat, '');
  const ga = release.releaseCopy(release.validateRelease(metadata, baseURL));
  assert.equal(ga.label, 'Download for Mac');
  assert.equal(ga.copy, 'Dilated 1.0.0 is ready for macOS 26.0+ on Apple Silicon. Free software from CodesWhat, under MIT.');
  assert.equal(ga.summary, 'V1.0.0 · MACOS 26.0+ · APPLE SILICON · MIT LICENSE');
  assert.equal(ga.caveat, '');
});
