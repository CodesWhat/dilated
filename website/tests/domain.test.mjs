import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const config = JSON.parse(await readFile(new URL('../vercel.json', import.meta.url), 'utf8'));
const route = config.routes[0];
const pattern = new RegExp(route.src);

test('the first route sends the old host to dilated.app with a 308', () => {
  assert.deepEqual(route.has, [{ type: 'host', value: 'dilated.codeswhat.com' }]);
  assert.equal(route.status, 308);
  assert.equal(route.headers.Location, 'https://dilated.app/$1');
  assert.notEqual(route.continue, true);
});

test('the old-host redirect covers pages but not shipped update, release, download and source paths', () => {
  for (const path of ['/', '/assets/social-card.png', '/sitemap.xml', '/.well-known/security.txt', '/sourcecode', '/downloads']) {
    assert.match(path, pattern, `${path} should redirect`);
  }
  for (const path of ['/updates/appcast.xml', '/releases/latest.json', '/releases/1.0.0-beta.10/x.dmg', '/download/file', '/source']) {
    assert.doesNotMatch(path, pattern, `${path} must keep serving on the old host`);
  }
});
