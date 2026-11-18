import assert from 'node:assert/strict';
import test from 'node:test';
import { access, readFile } from 'node:fs/promises';

const read = name => readFile(new URL(`../${name}`, import.meta.url), 'utf8');
const config = JSON.parse(await read('vercel.json'));
const headers = config.routes.find(route => route.headers?.['Content-Security-Policy']).headers;

test('every path gets the security header set', () => {
  assert.match(headers['Strict-Transport-Security'], /^max-age=(\d+); includeSubDomains$/);
  assert.ok(Number(headers['Strict-Transport-Security'].match(/\d+/)[0]) >= 31536000);
  assert.doesNotMatch(headers['Strict-Transport-Security'], /preload/);
  assert.equal(headers['X-Content-Type-Options'], 'nosniff');
  assert.equal(headers['X-Frame-Options'], 'DENY');
  assert.equal(headers['Referrer-Policy'], 'strict-origin-when-cross-origin');
  assert.equal(headers['Cross-Origin-Opener-Policy'], 'same-origin');
  assert.equal(headers['Permissions-Policy'], 'camera=(), microphone=(), geolocation=()');
});

test('the CSP blocks framing and objects and keeps the analytics host', () => {
  const csp = headers['Content-Security-Policy'];
  assert.match(csp, /(^|; )default-src 'self'(;|$)/);
  assert.match(csp, /(^|; )frame-ancestors 'none'(;|$)/);
  assert.match(csp, /(^|; )object-src 'none'(;|$)/);
  assert.match(csp, /(^|; )script-src 'self' https:\/\/e\.codeswhat\.com(;|$)/);
  assert.match(csp, /(^|; )connect-src 'self' https:\/\/e\.codeswhat\.com(;|$)/);
});

test('the header route applies to every path and falls through to the rest', () => {
  const route = config.routes.find(item => item.headers === headers);
  assert.equal(route.src, '/(.*)');
  assert.equal(route.continue, true);
});

test('every sitemap URL resolves to a file under the vercel.json routes', async () => {
  const sitemap = await read('dist/sitemap.xml');
  const locs = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => new URL(match[1]));
  assert.ok(locs.length >= 3);
  for (const loc of locs) {
    assert.equal(loc.origin, 'https://dilated.app');
    const rewrite = config.routes.find(item => item.dest && new RegExp(item.src).test(loc.pathname));
    const path = rewrite ? rewrite.dest : loc.pathname.endsWith('/') ? `${loc.pathname}index.html` : loc.pathname;
    await access(new URL(`../dist${path}`, import.meta.url));
    const page = await read(`dist${path}`);
    assert.ok(page.includes(`<link rel="canonical" href="${loc.href}">`), `${loc.href} must be its own canonical`);
    assert.doesNotMatch(page, /name="robots"[^>]*noindex/i);
  }
});
