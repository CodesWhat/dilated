import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const read = name => readFile(new URL(`../dist/${name}`, import.meta.url), 'utf8');
const privacy = await read('privacy.html');
const index = await read('index.html');
const sitemap = await read('sitemap.xml');
const llms = await read('llms.txt');
const config = JSON.parse(await readFile(new URL('../vercel.json', import.meta.url), 'utf8'));

test('privacy.html exists with a title, h1 and the canonical https://dilated.app/privacy', () => {
  assert.match(privacy, /<title>Privacy · Dilated<\/title>/);
  assert.match(privacy, /<h1>Privacy\.<\/h1>/);
  assert.match(privacy, /<link rel="canonical" href="https:\/\/dilated\.app\/privacy">/);
  assert.match(privacy, /<meta property="og:url" content="https:\/\/dilated\.app\/privacy">/);
  assert.match(privacy, /EFFECTIVE 2026-11-03/);
});

test('privacy.html reuses the site stylesheet and loads no script or third-party resource', () => {
  assert.match(privacy, /<link rel="stylesheet" href="\/styles\.css">/);
  assert.doesNotMatch(privacy, /<script\b/);
  assert.doesNotMatch(privacy, /<(?:link|img|iframe)\b[^>]*(?:href|src)="https?:\/\/(?!dilated\.app\/)/);
});

test('privacy.html contact is the security.txt address and the text keeps the house tone', () => {
  assert.match(privacy, /href="mailto:security@codeswhat\.com"/);
  const prose = privacy.replace(/<[^>]+>/g, ' ');
  assert.doesNotMatch(prose, /[—–]/, 'no em or en dashes in public prose');
});

test('the home page footer links to the privacy page', () => {
  const footer = index.match(/<footer[\s\S]*?<\/footer>/)[0];
  assert.match(footer, /<a href="\.\/privacy">PRIVACY<\/a>/);
});

test('the sitemap lists the privacy page once', () => {
  assert.equal(sitemap.match(/<loc>https:\/\/dilated\.app\/privacy<\/loc>/g)?.length, 1);
});

test('llms.txt lists the privacy page', () => {
  assert.match(llms, /\]\(https:\/\/dilated\.app\/privacy\)/);
});

test('/privacy resolves to privacy.html without the extension, with or without a trailing slash', () => {
  const route = config.routes.find(item => item.dest === '/privacy.html');
  assert.ok(route, 'route missing');
  const pattern = new RegExp(route.src);
  assert.match('/privacy', pattern);
  assert.match('/privacy/', pattern);
  assert.doesNotMatch('/privacy-policy', pattern);
  assert.doesNotMatch('/privacy.html', pattern);
  assert.notEqual(route.continue, true);
});

test('privacy.html has no relative asset or nav hrefs, so it renders from /privacy and /privacy/', () => {
  const urls = [...privacy.matchAll(/\b(?:href|src)="([^"]*)"/g)].map(match => match[1]);
  assert.ok(urls.length > 0);
  for (const url of urls) {
    assert.match(url, /^(?:\/(?!\/)|#|https:\/\/|mailto:)/, `relative url: ${url}`);
  }
});

test('/privacy/ redirects to /privacy with a 308 before the rewrite', () => {
  const index = config.routes.findIndex(item => item.status === 308 && !item.has && new RegExp(item.src).test('/privacy/'));
  assert.ok(index >= 0, 'redirect route missing');
  assert.equal(config.routes[index].headers.Location, '/privacy');
  assert.doesNotMatch('/privacy', new RegExp(config.routes[index].src));
  assert.ok(index < config.routes.findIndex(item => item.dest === '/privacy.html'), 'redirect must come before the rewrite');
});
