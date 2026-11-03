import { expect, test as base } from '@playwright/test';

const releasePath = '/releases/latest.json';

const releaseJson = {
  released: true,
  version: '1.2.3-beta.4',
  build: 42,
  downloadURL: 'https://downloads.example.com/Dilated-1.2.3-beta.4.dmg',
  sha256: 'ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789',
  minimumMacOS: '26.0',
  architecture: 'arm64',
  prerelease: true,
  unverified: ['macOS27ClosedLid', 'sudoRuleRevoked', 'sparkleUpgrade'],
};

const releases = {
  valid: { status: 200, body: JSON.stringify(releaseJson) },
  invalid: { status: 200, body: JSON.stringify({ ...releaseJson, sha256: 'not-a-checksum' }) },
  missing: { status: 404, body: 'Not found' },
};

// Every test fails on page errors, console errors (CSP violations included) and
// failed same-origin requests. The one allowed exception is the metadata request
// a test deliberately 404s, matched by its exact URL.
const test = base.extend({
  failures: [async ({ page, baseURL }, use) => {
    const origin = new URL(baseURL).origin;
    const problems = [];
    const allowed = new Set();
    page.on('pageerror', error => problems.push({ text: `pageerror: ${error.message}` }));
    page.on('console', message => {
      if (message.type() === 'error') problems.push({ text: `console error: ${message.text()}`, url: message.location().url });
    });
    page.on('requestfailed', request => {
      if (request.url().startsWith(origin)) problems.push({ text: `request failed: ${request.url()}`, url: request.url() });
    });
    page.on('response', response => {
      if (response.url().startsWith(origin) && response.status() >= 400) {
        problems.push({ text: `HTTP ${response.status()}: ${response.url()}`, url: response.url() });
      }
    });
    await page.addInitScript(() => {
      document.addEventListener('securitypolicyviolation', event => {
        console.error(`CSP violation: ${event.violatedDirective} blocked ${event.blockedURI}`);
      });
    });
    await use({ allow: url => allowed.add(url) });
    expect(problems.filter(problem => !allowed.has(problem.url)).map(problem => problem.text)).toEqual([]);
  }, { auto: true }],

  // Opens the page with a release metadata fixture and waits for the page to request it.
  open: async ({ page, baseURL, failures }, use) => {
    await use(async (path = '/', { release = releases.valid } = {}) => {
      await page.route(`**${releasePath}`, route => route.fulfill({
        status: release.status, contentType: 'application/json', headers: { 'Cache-Control': 'no-store' }, body: release.body,
      }));
      if (release.status >= 400) failures.allow(`${baseURL}${releasePath}`);
      const requested = page.waitForResponse(`**${releasePath}`);
      await page.goto(path);
      await requested;
    });
  },
});

const concepts = ['gas-station', 'night', 'field'];

test.describe('layout', () => {
  for (const width of [1280, 390, 320]) {
    for (const concept of concepts) {
      test(`${concept} fits at ${width}px and shows only its panel`, async ({ page, open }) => {
        await page.setViewportSize({ width, height: 800 });
        await open(`/?concept=${concept}`);
        await expect(page.locator('html')).toHaveAttribute('data-concept', concept);
        await expect(page.locator('[data-panel]:visible')).toHaveCount(1);
        await expect(page.locator('[data-panel]:visible')).toHaveAttribute('data-panel', concept);
        await page.evaluate(() => document.fonts.ready);
        const overflow = await page.evaluate(() => ({
          root: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          body: document.body.scrollWidth - document.documentElement.clientWidth,
        }));
        expect(overflow.root).toBeLessThanOrEqual(0);
        expect(overflow.body).toBeLessThanOrEqual(0);
      });
    }
  }
});

test.describe('menu preview', () => {
  const previewParts = page => {
    const demo = page.locator('.direction:not([hidden]) .menu-demo');
    const menu = demo.locator('[data-sample-menu]');
    return {
      demo,
      menu,
      trigger: demo.locator('[data-sample-trigger]'),
      countdown: demo.locator('[data-sample-countdown]'),
      row: label => menu.locator('[role^="menuitem"]').filter({ has: page.getByText(label, { exact: true }) }),
      submenu: label => menu.locator(`.sample-submenu[aria-label="${label}"]`),
    };
  };

  // The data-key of the focused row, or "trigger" when the menu bar button has focus.
  const focusedKey = page => page.evaluate(() => {
    const active = document.activeElement;
    if (active?.hasAttribute('data-sample-trigger')) return 'trigger';
    return active?.dataset.key ?? active?.tagName;
  });
  const expectFocus = (page, key) => expect.poll(() => focusedKey(page)).toBe(key);

  test('opens from the trigger, runs a hold, stops it, and closes on an outside click', async ({ page, open }) => {
    await open('/');
    const { demo, menu, trigger, countdown, row } = previewParts(page);
    await expect(menu).toBeHidden();
    await expect(demo).toHaveAttribute('data-awake', 'false');

    await trigger.click();
    await expect(menu).toBeVisible();
    await expect(trigger).toHaveAttribute('aria-expanded', 'true');
    await expect(menu.locator('.sample-header')).toHaveText('Sleeping normally');

    await row('Keep Awake').click();
    await expect(menu).toBeHidden();
    await expect(demo).toHaveAttribute('data-awake', 'true');
    await expect(countdown).toHaveText('∞');

    await trigger.click();
    await expect(menu.locator('.sample-header')).toHaveText('Awake indefinitely');
    await row('Stop').click();
    await expect(demo).toHaveAttribute('data-awake', 'false');
    await expect(countdown).toHaveText('');

    await trigger.click();
    await expect(row('Resume automation')).toBeVisible();
    await expect(menu.locator('.sample-info')).toHaveText('Automation paused');
    await page.locator('.direction:not([hidden]) .section-intro h2').click();
    await expect(menu).toBeHidden();
    await expect(trigger).toHaveAttribute('aria-expanded', 'false');
  });

  test('a timed hold shows a countdown', async ({ page, open }) => {
    await open('/');
    const { demo, menu, trigger, countdown, row } = previewParts(page);
    await trigger.click();
    await row('Keep awake for').hover();
    await row('15 minutes').click();
    await expect(menu).toBeHidden();
    await expect(demo).toHaveAttribute('data-awake', 'true');
    await expect(countdown).toHaveText(/^1[45]:\d\d$/);
  });

  test('hover opens a submenu inside the preview on desktop', async ({ page, open }) => {
    await open('/');
    const { demo, trigger, row, submenu } = previewParts(page);
    await trigger.click();
    await row('Keep awake for').hover();
    await expect(submenu('Keep awake for')).toBeVisible();
    await expect(row('Keep awake for')).toHaveAttribute('aria-expanded', 'true');
    const [box, bounds] = await Promise.all([submenu('Keep awake for').boundingBox(), demo.boundingBox()]);
    expect(box.x).toBeGreaterThanOrEqual(bounds.x);
    expect(box.x + box.width).toBeLessThanOrEqual(bounds.x + bounds.width);
  });

  test('click opens a submenu and moves focus into it', async ({ page, open }) => {
    await open('/');
    const { trigger, row, submenu } = previewParts(page);
    await trigger.click();
    // A bare click event, without the pointer movement that opens a submenu on hover.
    await row('Keep awake for').dispatchEvent('click');
    await expect(submenu('Keep awake for')).toBeVisible();
    await expectFocus(page, 'preset-15');
  });

  test('submenus open inline at narrow width', async ({ page, open }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await open('/');
    const { demo, trigger, row, submenu } = previewParts(page);
    await trigger.click();
    await row('Keep awake for').click();
    const sub = submenu('Keep awake for');
    await expect(sub).toBeVisible();
    await expect(sub).toHaveCSS('position', 'static');
    const [box, bounds] = await Promise.all([sub.boundingBox(), demo.boundingBox()]);
    expect(box.x).toBeGreaterThanOrEqual(bounds.x);
    expect(box.x + box.width).toBeLessThanOrEqual(bounds.x + bounds.width);
  });

  test('keyboard opens the menu, moves focus, and closes submenu then menu on Escape', async ({ page, open }) => {
    await open('/');
    const { menu, trigger, submenu } = previewParts(page);
    await trigger.focus();
    await expectFocus(page, 'trigger');

    await page.keyboard.press('Enter');
    await expect(menu).toBeVisible();
    await expectFocus(page, 'toggle');

    await page.keyboard.press('ArrowDown');
    await expectFocus(page, 'duration');
    await page.keyboard.press('ArrowUp');
    await expectFocus(page, 'toggle');
    await page.keyboard.press('End');
    await expectFocus(page, 'quit');
    await page.keyboard.press('Home');
    await expectFocus(page, 'toggle');

    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('ArrowRight');
    await expect(submenu('Keep awake for')).toBeVisible();
    await expectFocus(page, 'preset-15');

    await page.keyboard.press('Escape');
    await expect(submenu('Keep awake for')).toBeHidden();
    await expect(menu).toBeVisible();
    await expectFocus(page, 'duration');

    await page.keyboard.press('Escape');
    await expect(menu).toBeHidden();
    await expect(trigger).toHaveAttribute('aria-expanded', 'false');
    await expectFocus(page, 'trigger');
  });

  test('ArrowDown on the trigger opens the menu with the first row focused', async ({ page, open }) => {
    await open('/');
    const { menu, trigger } = previewParts(page);
    await trigger.focus();
    await page.keyboard.press('ArrowDown');
    await expect(menu).toBeVisible();
    await expectFocus(page, 'toggle');
  });
});

test.describe('page controls', () => {
  test('the ticker control pauses and resumes the phrases', async ({ page, open }) => {
    await open('/');
    const ticker = page.locator('.retail-strip');
    const control = page.locator('.ticker-control');
    await expect(control).toHaveAccessibleName('Pause scrolling phrases');
    await expect(control).toHaveAttribute('aria-pressed', 'false');

    await control.click();
    await expect(ticker).toHaveAttribute('data-paused', 'true');
    await expect(control).toHaveAttribute('aria-pressed', 'true');
    await expect(control).toHaveAccessibleName('Resume scrolling phrases');

    await control.click();
    await expect(ticker).toHaveAttribute('data-paused', 'false');
    await expect(control).toHaveAccessibleName('Pause scrolling phrases');
  });

  test('command line notes expand and collapse', async ({ page, open }) => {
    await open('/');
    const guide = page.locator('details.command-guide');
    const note = guide.getByText('Dilated includes a CLI.');
    await expect(note).toBeHidden();
    await guide.locator('summary').click();
    await expect(guide).toHaveJSProperty('open', true);
    await expect(note).toBeVisible();
    await guide.locator('summary').click();
    await expect(note).toBeHidden();
  });

  test('copy gives either the copied label or the fallback toast', async ({ page, open }) => {
    await open('/');
    const button = page.locator('#copy-command');
    const toast = page.locator('#toast');
    await button.click();
    await expect(toast).toHaveClass(/visible/);
    await expect(toast).toHaveText(/^(Command copied\.|Select the command to copy it\.)$/);
    if ((await toast.textContent()) === 'Command copied.') await expect(button).toHaveText('Copied ✓');
    else await expect(button).toHaveText('Copy ↗');
  });
});

test.describe('release metadata', () => {
  test('a valid release reveals the download links and details', async ({ page, open }) => {
    await open('/', { release: releases.valid });
    const links = page.locator('[data-release-link]');
    await expect(links.first()).toHaveAttribute('href', releaseJson.downloadURL);
    await expect(page.locator(`[data-release-link]:not([href="${releaseJson.downloadURL}"])`)).toHaveCount(0);
    await expect(page.locator('#availability [data-release-link]')).toBeVisible();
    await expect(page.locator('#availability [data-release-label]')).toHaveText('Download beta for Mac');
    await expect(page.locator('[data-release-version]')).toHaveText('Version 1.2.3-beta.4 · Build 42');
    const caveat = page.locator('[data-release-caveat]');
    await expect(caveat).toContainText('closed-lid mode on macOS 27, recovery after the sudo rule is revoked, and in-app updates');
    expect((await caveat.textContent()).replaceAll('macOS', '')).not.toMatch(/[a-z][A-Z]/);
    await page.locator('.release-details summary').click();
    await expect(page.locator('[data-release-checksum]')).toHaveText(releaseJson.sha256.toLowerCase());
    await expect(page.locator('[data-testing-only]:visible')).toHaveCount(0);
  });

  for (const [name, release] of [['invalid metadata', releases.invalid], ['a 404', releases.missing]]) {
    test(`${name} keeps the testing copy and no download href`, async ({ page, open }) => {
      await open('/', { release });
      // Nothing changes on the page when the metadata is rejected. Importing the page's own module
      // resolves once its top-level await (the metadata load) has finished.
      await page.evaluate(() => import('./app.mjs'));
      const download = page.locator('#availability a[data-release-link]');
      await expect(download).toBeHidden();
      await expect(download).not.toHaveAttribute('href');
      await expect(page.locator('[data-testing-only]:visible')).toHaveCount(2);
      await expect(page.locator('[data-release-status]')).toHaveText('PUBLIC BETA.');
      await expect(page.locator('[data-release-details]')).toBeHidden();
      await expect(page.locator('[data-release-caveat]')).toBeHidden();
    });
  }
});

test.describe('readability and usability', () => {
  for (const width of [1280, 390, 320]) {
    test(`no visible text computes below 12px at ${width}px`, async ({ page, open }) => {
      await page.setViewportSize({ width, height: 844 });
      await open('/?concept=gas-station');
      await page.evaluate(() => document.fonts.ready);
      const small = await page.evaluate(() => {
        const found = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          const el = node.parentElement;
          if (!node.textContent.trim() || el.closest('script,template,[hidden],[aria-hidden="true"]')) continue;
          const style = getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden' || !el.getBoundingClientRect().width) continue;
          if (parseFloat(style.fontSize) < 12) found.push(`${el.tagName}.${el.className}: ${style.fontSize} "${node.textContent.trim().slice(0, 30)}"`);
        }
        return found;
      });
      expect(small).toEqual([]);
    });
  }

  test('nav links stay reachable at narrow widths without overflow', async ({ page, open }) => {
    for (const width of [390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      await open('/');
      for (const name of ['How it works', 'Command line']) {
        const link = page.locator('.masthead nav').getByRole('link', { name });
        await expect(link).toBeVisible();
        const box = await link.boundingBox();
        expect(box.x).toBeGreaterThanOrEqual(0);
        expect(box.x + box.width).toBeLessThanOrEqual(width);
      }
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow).toBeLessThanOrEqual(0);
    }
  });

  test('footer carries one SUPPORT link and the availability section a single support sentence', async ({ page, open }) => {
    await open('/');
    const link = page.locator('footer a', { hasText: 'SUPPORT' });
    await expect(link).toHaveCount(1);
    await expect(link).toHaveAttribute('href', 'https://codeswhat.com/support');
    await expect(page.locator('footer a[href*="sponsors"]')).toHaveCount(0);
    const note = page.locator('#availability .support-note');
    await expect(note).toHaveCount(1);
    await expect(note.locator('a')).toHaveCount(2);
    await expect(note.locator('a').nth(0)).toHaveAttribute('href', 'https://github.com/sponsors/CodesWhat');
    await expect(note.locator('a').nth(1)).toHaveAttribute('href', 'https://codeswhat.com/support');
  });

  for (const width of [390, 320]) {
    test(`footer SUPPORT link is a tall target and does not overflow at ${width}px`, async ({ page, open }) => {
      await page.setViewportSize({ width, height: 844 });
      await open('/');
      await page.evaluate(() => document.fonts.ready);
      const box = await page.locator('footer a', { hasText: 'SUPPORT' }).evaluate(el => {
        const r = el.getBoundingClientRect();
        return { w: r.width, h: r.height, right: r.right };
      });
      expect(box.h).toBeGreaterThanOrEqual(44);
      expect(box.right).toBeLessThanOrEqual(width);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow).toBeLessThanOrEqual(0);
    });
  }

  test('listed controls are at least 44px at 390px', async ({ page, open }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await open('/');
    const selectors = ['.hero-preview-link', '#copy-command', '.sample-trigger', 'footer a', '.release-details summary', '.ticker-control', '.masthead nav a'];
    for (const selector of selectors) {
      const boxes = await page.locator(selector).evaluateAll(els => els.map(el => {
        const r = el.getBoundingClientRect();
        return { w: r.width, h: r.height };
      }).filter(box => box.w > 0));
      expect(boxes.length, selector).toBeGreaterThan(0);
      for (const box of boxes) expect(Math.min(box.w, box.h), selector).toBeGreaterThanOrEqual(44);
    }
  });

  test('the ticker control has its own gutter and never overlaps phrase text', async ({ page, open }) => {
    for (const width of [1280, 390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      await open('/');
      const result = await page.evaluate(() => {
        const control = document.querySelector('.ticker-control').getBoundingClientRect();
        const win = document.querySelector('.retail-strip-window').getBoundingClientRect();
        const overlaps = [...document.querySelectorAll('.retail-strip-track span')].filter(span => {
          const r = span.getBoundingClientRect();
          const left = Math.max(r.left, win.left), right = Math.min(r.right, win.right);
          return right > left && left < control.right && right > control.left;
        }).length;
        return { overlaps, gap: control.left - win.right, w: control.width, h: control.height };
      });
      expect(result.overlaps).toBe(0);
      expect(result.gap).toBeGreaterThanOrEqual(0);
      expect(Math.min(result.w, result.h)).toBeGreaterThanOrEqual(44);
    }
  });

  test('buttons that scroll to availability do not promise a download, and the closing icon alt is short', async ({ page, open }) => {
    await open('/', { release: releases.missing });
    const links = page.locator('[data-release-link][href="#availability"]');
    await expect(links).toHaveCount(2);
    for (const label of await links.allTextContents()) expect(label).not.toMatch(/^\s*download\b/i);
    const alt = await page.locator('.availability-icon').getAttribute('alt');
    expect(alt.trim().split(/\s+/).length).toBeLessThanOrEqual(8);
  });
});

test.describe('privacy page', () => {
  test('/privacy serves the policy with a title, canonical and no console errors', async ({ page, request }) => {
    const response = await request.get('/privacy');
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toMatch(/text\/html/);
    await page.goto('/privacy');
    await expect(page).toHaveTitle('Privacy · Dilated');
    await expect(page.locator('h1')).toHaveText('Privacy.');
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', 'https://dilated.app/privacy');
    await page.evaluate(() => document.fonts.ready);
  });

  test('the home footer links to it and the link lands on the page', async ({ page, open }) => {
    await open('/');
    const link = page.locator('footer a', { hasText: 'PRIVACY' });
    await expect(link).toHaveCount(1);
    await link.click();
    await expect(page).toHaveURL(/\/privacy$/);
    await expect(page.locator('h1')).toHaveText('Privacy.');
  });

  for (const width of [1280, 390, 320]) {
    test(`fits at ${width}px with no text under 12px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await page.goto('/privacy');
      await page.evaluate(() => document.fonts.ready);
      const result = await page.evaluate(() => {
        const small = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          const el = node.parentElement;
          if (!node.textContent.trim() || el.closest('[aria-hidden="true"]') || !el.getBoundingClientRect().width) continue;
          if (parseFloat(getComputedStyle(el).fontSize) < 12) small.push(`${el.tagName}: "${node.textContent.trim().slice(0, 30)}"`);
        }
        return { small, overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
      });
      expect(result.small).toEqual([]);
      expect(result.overflow).toBeLessThanOrEqual(0);
    });
  }
});

test.describe('discoverability', () => {
  test('structured data is inert under the CSP and the crawl files are served', async ({ page, request, open }) => {
    await open('/', { release: releases.missing });
    const raw = await page.locator('script[type="application/ld+json"]').first().textContent();
    expect(JSON.parse(raw)['@type']).toBe('SoftwareApplication');
    for (const [path, type] of [['/robots.txt', /text\/plain/], ['/sitemap.xml', /xml/], ['/llms.txt', /text\/plain/], ['/assets/social-card.png', /image\/png/]]) {
      const response = await request.get(path);
      expect(response.status(), path).toBe(200);
      expect(response.headers()['content-type'], path).toMatch(type);
    }
  });
});
