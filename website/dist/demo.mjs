import { initialState, transition } from './demo-state.mjs';
import { remainingTime } from './state.mjs';

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
  let timer;

  function render() {
    state = transition(state, { type: 'tick' }, Date.now());
    const clock = state.deadline === null ? '∞' : remainingTime(state.deadline, Date.now());
    const status = !state.awake ? 'Sleeping normally' : state.deadline === null
      ? 'Awake indefinitely' : `Awake for ${clock} more`;
    demos.forEach(demo => {
      demo.dataset.awake = String(state.awake);
      demo.querySelector('[data-sample-eyes]').setAttribute('href', `./assets/symbols.svg#${state.awake ? 'eyes' : 'eyes-closed'}`);
      demo.querySelector('[data-sample-status]').textContent = status;
      demo.querySelector('[data-sample-countdown]').textContent = state.awake ? clock : '';
      demo.querySelector('[data-sample-trigger]').setAttribute('aria-label', `Dilated preview: ${status}. Open menu`);
      demo.querySelector('[data-action="toggle"] [data-action-label]').textContent = state.awake ? 'Stop' : 'Keep Awake';
      demo.querySelector('[data-action="resume"]').hidden = !state.automationPaused;
      demo.querySelector('[data-pause-note]').hidden = !state.automationPaused;
      demo.querySelector('[data-display-note]').hidden = !state.awake;
      demo.querySelector('[data-display-note]').textContent = state.allowDisplaySleep ? 'Display allowed to sleep.' : 'Keeping the display awake too.';
      demo.querySelector('[data-action="display"]').setAttribute('aria-checked', String(state.allowDisplaySleep));
      demo.querySelector('[data-display-check]').textContent = state.allowDisplaySleep ? '✓' : '';
    });
    if (!state.awake || state.deadline === null) { clearInterval(timer); timer = undefined; }
  }

  function dispatch(action) {
    state = transition(state, action, Date.now());
    clearInterval(timer);
    timer = state.awake && state.deadline !== null ? setInterval(render, 1000) : undefined;
    render();
  }

  function items(demo) {
    return [...demo.querySelectorAll('[data-page-panel]:not([hidden]) [role^="menuitem"]')]
      .filter(item => !item.hidden);
  }

  function showPage(demo, page) {
    demo.querySelectorAll('[data-page-panel]').forEach(panel => { panel.hidden = panel.dataset.pagePanel !== page; });
    items(demo)[0]?.focus({ preventScroll: true });
  }

  function close(restoreFocus = false) {
    if (!active) return;
    const demo = active;
    demo.querySelector('[data-sample-menu]').hidden = true;
    demo.querySelector('[data-sample-trigger]').setAttribute('aria-expanded', 'false');
    demo.dataset.open = 'false';
    active = null;
    if (restoreFocus) demo.querySelector('[data-sample-trigger]').focus({ preventScroll: true });
  }

  function open(demo, last = false) {
    close();
    active = demo;
    render();
    demo.querySelector('[data-sample-menu]').hidden = false;
    demo.querySelector('[data-sample-trigger]').setAttribute('aria-expanded', 'true');
    demo.dataset.open = 'true';
    showPage(demo, 'main');
    if (last) items(demo).at(-1)?.focus({ preventScroll: true });
  }

  demos.forEach(demo => {
    const trigger = demo.querySelector('[data-sample-trigger]');
    trigger.addEventListener('click', () => active === demo ? close() : open(demo));
    trigger.addEventListener('keydown', event => {
      if (['ArrowDown', 'ArrowUp'].includes(event.key)) {
        event.preventDefault();
        open(demo, event.key === 'ArrowUp');
      }
    });
    demo.querySelectorAll('[data-demo-page]').forEach(button => button.addEventListener('click', () => {
      showPage(demo, button.dataset.demoPage);
    }));
    demo.querySelectorAll('[data-action]').forEach(button => button.addEventListener('click', () => {
      switch (button.dataset.action) {
        case 'toggle':
          dispatch({ type: state.awake ? 'stop' : 'start' });
          announce(state.awake ? 'Preview awake indefinitely.' : 'Preview stopped. Automation paused.');
          break;
        case 'start':
          dispatch({ type: 'start', minutes: button.dataset.minutes ? Number(button.dataset.minutes) : null });
          announce(button.dataset.minutes ? `${button.dataset.minutes}-minute preview started.` : 'Preview awake indefinitely.');
          break;
        case 'resume': dispatch({ type: 'resume' }); announce('Preview automation resumed.'); break;
        case 'display': dispatch({ type: 'display', allow: !state.allowDisplaySleep }); return;
        case 'quit': dispatch({ type: 'quit' }); announce('Preview ended.'); break;
      }
      close(true);
    }));
    demo.querySelector('[data-sample-menu]').addEventListener('keydown', event => {
      const available = items(demo);
      const index = available.indexOf(document.activeElement);
      if (event.key === 'Escape') { event.preventDefault(); close(true); }
      else if (event.key === 'ArrowLeft') { event.preventDefault(); showPage(demo, 'main'); }
      else if (event.key === 'ArrowRight' && document.activeElement?.dataset.demoPage) {
        event.preventDefault(); showPage(demo, document.activeElement.dataset.demoPage);
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
