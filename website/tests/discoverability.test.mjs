import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const CANONICAL = 'https://dilated.app/';
const read = name => readFile(new URL(`../dist/${name}`, import.meta.url), 'utf8');
const html = await read('index.html');

function jsonLd() {
  const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
  assert.equal(blocks.length, 1, 'expected exactly one JSON-LD block');
  return JSON.parse(blocks[0][1]);
}

test('JSON-LD parses as a SoftwareApplication with the required fields', () => {
  const data = jsonLd();
  assert.equal(data['@context'], 'https://schema.org');
  assert.equal(data['@type'], 'SoftwareApplication');
  assert.equal(data.name, 'Dilated');
  assert.equal(data.applicationCategory, 'UtilitiesApplication');
  assert.equal(data.operatingSystem, 'macOS 26 or later');
  assert.equal(data.url, CANONICAL);
  assert.equal(data.downloadUrl, `${CANONICAL}download/file`);
  assert.match(data.license, /MIT/);
  assert.equal(data.offers['@type'], 'Offer');
  assert.equal(data.offers.price, '0');
  assert.equal(data.offers.priceCurrency, 'USD');
  assert.equal(data.publisher['@type'], 'Organization');
  assert.equal(data.publisher.name, 'CodesWhat');
  assert.match(data.publisher.url, /^https:\/\//);
});

test('JSON-LD carries no version that the release pipeline could leave stale', () => {
  const raw = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1];
  assert.equal(jsonLd().softwareVersion, undefined);
  assert.doesNotMatch(raw, /beta\.\d|\d+\.\d+\.\d+/);
});

test('social meta uses absolute URLs and a card image', () => {
  const metas = [...html.matchAll(/<meta (?:property|name)="((?:og|twitter):[^"]+)" content="([^"]*)"/g)];
  const byName = Object.fromEntries(metas.map(([, name, content]) => [name, content]));
  for (const key of ['og:url', 'og:image', 'twitter:image']) {
    assert.match(byName[key], /^https:\/\/dilated\.app\//, `${key} must be absolute`);
  }
  assert.equal(byName['og:url'], CANONICAL);
  assert.equal(byName['og:site_name'], 'Dilated');
  assert.equal(byName['twitter:card'], 'summary_large_image');
  assert.equal(byName['og:image'], byName['twitter:image']);
});

test('the social card is a 1200x630 PNG', async () => {
  const png = await readFile(new URL('../dist/assets/social-card.png', import.meta.url));
  assert.equal(png.subarray(1, 4).toString(), 'PNG');
  assert.equal(png.readUInt32BE(16), 1200);
  assert.equal(png.readUInt32BE(20), 630);
});

test('robots.txt allows all and names the sitemap', async () => {
  const robots = await read('robots.txt');
  assert.match(robots, /^User-agent: \*$/m);
  assert.match(robots, /^Allow: \/$/m);
  assert.doesNotMatch(robots, /^Disallow: \/\s*$/m);
  assert.match(robots, new RegExp(`^Sitemap: ${CANONICAL}sitemap\\.xml$`, 'm'));
});

test('sitemap.xml lists the home page and the privacy page', async () => {
  const sitemap = await read('sitemap.xml');
  assert.deepEqual([...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => match[1]), [CANONICAL, `${CANONICAL}privacy`]);
});

test('llms.txt leads with the product and links the key pages', async () => {
  const text = await read('llms.txt');
  assert.match(text, /^# Dilated$/m);
  assert.match(text, /^> /m);
  for (const link of [
    `${CANONICAL}download/file`,
    'https://github.com/CodesWhat/dilated/blob/main/docs/INSTALLATION.md',
    'https://github.com/CodesWhat/dilated/blob/main/docs/AUTOMATION.md',
    'https://github.com/CodesWhat/dilated/releases',
    'https://github.com/CodesWhat/dilated',
  ]) assert.ok(text.includes(`](${link})`), `missing ${link}`);
  assert.match(text, /brew install --cask codeswhat\/tap\/dilated/);
});

test('vercel.json sets content types for robots, llms and sitemap', async () => {
  const config = JSON.parse(await readFile(new URL('../vercel.json', import.meta.url), 'utf8'));
  const expected = { '/robots.txt': /^text\/plain/, '/llms.txt': /^text\/plain/, '/sitemap.xml': /^application\/xml/ };
  for (const [src, type] of Object.entries(expected)) {
    const route = config.routes.find(item => item.src === src);
    assert.ok(route, `${src} route missing`);
    assert.match(route.headers['Content-Type'], type);
    assert.equal(route.continue, true);
  }
});
