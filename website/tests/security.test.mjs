import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const text = await readFile(new URL('../dist/.well-known/security.txt', import.meta.url), 'utf8');
const fields = Object.fromEntries(text.trim().split('\n').map(line => {
  const index = line.indexOf(':');
  return [line.slice(0, index), line.slice(index + 1).trim()];
}));

test('security.txt carries the RFC 9116 fields', () => {
  assert.equal(fields.Contact, 'mailto:security@codeswhat.com');
  assert.equal(fields.Canonical, 'https://dilated.codeswhat.com/.well-known/security.txt');
  assert.equal(fields['Preferred-Languages'], 'en');
});

// This goes red when Expires passes. That is intended: renew the date before then.
test('security.txt Expires is a future UTC timestamp', () => {
  assert.match(fields.Expires, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.ok(Date.parse(fields.Expires) > Date.now(), `security.txt expired ${fields.Expires}; renew it`);
});

test('vercel.json serves security.txt as text/plain', async () => {
  const config = JSON.parse(await readFile(new URL('../vercel.json', import.meta.url), 'utf8'));
  const route = config.routes.find(item => item.src === '/.well-known/security.txt');
  assert.ok(route, 'route missing');
  assert.match(route.headers['Content-Type'], /^text\/plain/);
  assert.equal(route.continue, true);
});
