import { initialState, menuModel, statusText, transition } from './demo-state.mjs';
import { remainingTime } from './state.mjs';

const rowSelector = ':scope > [role^="menuitem"]:not([aria-disabled]), :scope > .sample-host > [role^="menuitem"]';

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function buildRow(item) {
  const row = el('button', null);
  row.type = 'button';
  row.dataset.key = item.key;
  row.setAttribute('role', item.kind === 'checkbox' ? 'menuitemcheckbox' : 'menuitem');
  if (item.kind === 'checkbox') row.setAttribute('aria-checked', String(item.checked));
  const check = el('span', 'sample-check', item.checked ? '✓' : '');
  check.setAttribute('aria-hidden', 'true');
  row.append(check, el('span', 'sample-label', item.label));
  if (item.shortcut) row.append(el('kbd', null, item.shortcut));
  return row;
}

function buildMenu(parent, items) {
  parent.replaceChildren();
  items.forEach(item => {
    if (item.kind === 'separator') {
      const rule = el('div', 'sample-separator');
      rule.setAttribute('role', 'separator');
      parent.append(rule);
    } else if (item.kind === 'header') {
      const header = el('div', 'sample-header', item.label);
      header.dataset.key = item.key;
      parent.append(header);
    } else if (item.kind === 'info') {
      const info = el('div', 'sample-info');
      info.dataset.key = item.key;
      info.setAttribute('role', 'menuitem');
      info.setAttribute('aria-disabled', 'true');
      const gutter = el('span', 'sample-check');
      gutter.setAttribute('aria-hidden', 'true');
      info.append(gutter, el('span', 'sample-label', item.label));
      parent.append(info);
    } else if (item.kind === 'submenu') {
      const host = el('div', 'sample-host');
      host.setAttribute('role', 'none');
      host.dataset.hostKey = item.key;
      const row = buildRow(item);
      row.setAttribute('aria-haspopup', 'menu');
      row.setAttribute('aria-expanded', 'false');
      row.dataset.submenu = item.key;
      const chevron = el('span', 'sample-chevron', '›');
      chevron.setAttribute('aria-hidden', 'true');
      row.append(chevron);
      const sub = el('div', 'sample-submenu');
      sub.setAttribute('role', 'menu');
      sub.setAttribute('aria-label', item.label);
      sub.hidden = true;
      buildMenu(sub, item.items);
      host.append(row, sub);
      parent.append(host);
    } else {
      parent.append(buildRow(item));
    }
  });
}

function flatten(items) {
  return items.flatMap(item => item.kind === 'submenu' ? [item, ...flatten(item.items)] : [item]);
}

export function mountMenuDemos(announce) {
  const demos = [...document.querySelectorAll('[data-demo-mount]')].map((mount, index) => {
    mount.append(document.querySelector('#awake-demo').content.cloneNode(true));
    const demo = mount.querySelector('.menu-demo');
    const menu = demo.querySelector('[data-sample-menu]');
    menu.id = `dilated-preview-menu-${index}`;
    demo.querySelector('[data-sample-trigger]').setAttribute('aria-controls', menu.id);
    return demo;
  });
  let state = initialState();
  let active = null;
  let signature = '';
  let timer;
  const actions = new Map();

  const hasTimer = () => state.holds.some(hold => hold.expiry !== null);

  function menuEl(demo) { return demo.querySelector('[data-sample-menu]'); }
  function rows(menu) { return [...menu.querySelectorAll(rowSelector)]; }

  function openSub(host) {
    const row = host.querySelector(':scope > [role^="menuitem"]');
    const sub = host.querySelector(':scope > .sample-submenu');
    host.parentElement.querySelectorAll(':scope > .sample-host').forEach(other => { if (other !== host) closeSub(other); });
    sub.hidden = false;
    row.setAttribute('aria-expanded', 'true');
    delete host.dataset.flip;
    const bounds = host.closest('.menu-demo').getBoundingClientRect();
    if (sub.getBoundingClientRect().right > bounds.right - 4) host.dataset.flip = 'left';
  }

  function closeSub(host) {
    host.querySelector(':scope > .sample-submenu').hidden = true;
    host.querySelector(':scope > [role^="menuitem"]').setAttribute('aria-expanded', 'false');
  }

  function closeAllSubs(menu) { menu.querySelectorAll('.sample-host').forEach(closeSub); }

  function patch(menu, items) {
    flatten(items).forEach(item => {
      if (!item.key) return;
      const node = menu.querySelector(`[data-key="${item.key}"]`);
      if (!node) return;
      const label = node.querySelector(':scope > .sample-label');
      if (label) label.textContent = item.label;
      else node.textContent = item.label;
      if (item.kind === 'checkbox') {
        node.setAttribute('aria-checked', String(item.checked));
        node.querySelector('.sample-check').textContent = item.checked ? '✓' : '';
      }
    });
  }

  function renderMenu(demo) {
    const menu = menuEl(demo);
    const items = menuModel(state, Date.now());
    actions.clear();
    flatten(items).forEach(item => { if (item.action) actions.set(item.key, item); });
    const next = flatten(items).map(item => item.key ?? '-').join('|');
    if (next === signature && menu.childElementCount > 0) { patch(menu, items); return; }
    const focusedKey = menu.contains(document.activeElement) ? document.activeElement.dataset.key : null;
    const openKeys = [...menu.querySelectorAll('.sample-host')]
      .filter(host => !host.querySelector(':scope > .sample-submenu').hidden).map(host => host.dataset.hostKey);
    buildMenu(menu, items);
    signature = next;
    openKeys.forEach(key => { const host = menu.querySelector(`[data-host-key="${key}"]`); if (host) openSub(host); });
    if (focusedKey) (menu.querySelector(`[data-key="${focusedKey}"]`) ?? rows(menu)[0])?.focus({ preventScroll: true });
  }

  function render() {
    state = transition(state, { type: 'tick' }, Date.now());
    const now = Date.now();
    const status = statusText(state, now);
    const awake = state.holds.length > 0;
    const indefinite = state.holds.some(hold => hold.expiry === null);
    const clock = indefinite ? '∞' : remainingTime(Math.max(...state.holds.map(hold => hold.expiry), now), now);
    demos.forEach(demo => {
      demo.dataset.awake = String(awake);
      demo.querySelector('[data-sample-eyes]').setAttribute('href', `./assets/symbols.svg#${awake ? 'eyes' : 'eyes-closed'}`);
      demo.querySelector('[data-sample-countdown]').textContent = awake ? clock : '';
      demo.querySelector('[data-sample-trigger]').setAttribute('aria-label', `Dilated preview: ${status}. Open menu`);
    });
    if (active) renderMenu(active);
    if (!hasTimer()) { clearInterval(timer); timer = undefined; }
  }

  function dispatch(action) {
    state = transition(state, action, Date.now());
    clearInterval(timer);
    timer = hasTimer() ? setInterval(render, 1000) : undefined;
    render();
  }

  function close(restoreFocus = false) {
    if (!active) return;
    const demo = active;
    closeAllSubs(menuEl(demo));
    menuEl(demo).hidden = true;
    demo.querySelector('[data-sample-trigger]').setAttribute('aria-expanded', 'false');
    demo.dataset.open = 'false';
    active = null;
    if (restoreFocus) demo.querySelector('[data-sample-trigger]').focus({ preventScroll: true });
  }

  function open(demo, last = false) {
    close();
    active = demo;
    signature = '';
    menuEl(demo).replaceChildren();
    render();
    menuEl(demo).hidden = false;
    demo.querySelector('[data-sample-trigger]').setAttribute('aria-expanded', 'true');
    demo.dataset.open = 'true';
    const all = rows(menuEl(demo));
    (last ? all.at(-1) : all[0])?.focus({ preventScroll: true });
  }

  function run(row) {
    const item = actions.get(row.dataset.key);
    if (!item) return;
    const { action } = item;
    if (action.type !== 'close') dispatch(action);
    if (item.say) announce(item.say);
    if (item.kind === 'checkbox') return;
    close(true);
  }

  demos.forEach(demo => {
    const trigger = demo.querySelector('[data-sample-trigger]');
    const menu = menuEl(demo);
    trigger.addEventListener('click', () => active === demo ? close() : open(demo));
    trigger.addEventListener('keydown', event => {
      if (['ArrowDown', 'ArrowUp'].includes(event.key)) {
        event.preventDefault();
        open(demo, event.key === 'ArrowUp');
      }
    });
    menu.addEventListener('click', event => {
      const row = event.target.closest('[role^="menuitem"]');
      if (!row || row.getAttribute('aria-disabled') === 'true') return;
      const host = row.closest('.sample-host');
      if (host && row === host.querySelector(':scope > [role^="menuitem"]')) {
        openSub(host);
        host.querySelector('.sample-submenu [role^="menuitem"]:not([aria-disabled])')?.focus({ preventScroll: true });
        return;
      }
      run(row);
    });
    menu.addEventListener('pointerover', event => {
      if (event.pointerType !== 'mouse') return;
      const host = event.target.closest('.sample-host');
      if (!host) { if (event.target !== menu) menu.querySelectorAll(':scope > .sample-host').forEach(closeSub); }
      else if (!event.target.closest('.sample-submenu')) openSub(host);
    });
    menu.addEventListener('keydown', event => {
      const current = document.activeElement?.closest('[role="menu"]') ?? menu;
      const available = rows(current);
      const index = available.indexOf(document.activeElement);
      const host = document.activeElement?.closest('.sample-host');
      const inSub = current !== menu;
      if (event.key === 'Escape') {
        event.preventDefault();
        if (inSub) { const owner = current.parentElement; closeSub(owner); owner.querySelector(':scope > [role^="menuitem"]').focus({ preventScroll: true }); }
        else close(true);
      } else if (event.key === 'ArrowLeft') {
        event.preventDefault();
        if (inSub) { const owner = current.parentElement; closeSub(owner); owner.querySelector(':scope > [role^="menuitem"]').focus({ preventScroll: true }); }
      } else if (event.key === 'ArrowRight') {
        event.preventDefault();
        const owner = host && document.activeElement === host.querySelector(':scope > [role^="menuitem"]') ? host : null;
        if (owner) { openSub(owner); owner.querySelector('.sample-submenu [role^="menuitem"]:not([aria-disabled])')?.focus({ preventScroll: true }); }
      } else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
        event.preventDefault();
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? available.length - 1
          : (index + (event.key === 'ArrowDown' ? 1 : -1) + available.length) % available.length;
        available[next]?.focus({ preventScroll: true });
      }
    });
    demo.addEventListener('focusout', event => {
      if (active === demo && event.relatedTarget && !demo.contains(event.relatedTarget)) close();
    });
  });
  document.addEventListener('pointerdown', event => { if (active && !active.contains(event.target)) close(); });
  document.addEventListener('visibilitychange', () => {
    clearInterval(timer);
    timer = undefined;
    if (!document.hidden) dispatch({ type: 'tick' });
  });
  window.addEventListener('pagehide', () => { clearInterval(timer); close(); });
  window.addEventListener('pageshow', event => { if (event.persisted) dispatch({ type: 'tick' }); });
  render();
}
