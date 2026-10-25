import { directions, readPreferences } from './state.mjs';
import { mountMenuDemos } from './demo.mjs';
import { loadRelease, releaseCopy } from './release.mjs';

const root = document.documentElement;
let current = readPreferences(location.search);
let toastTimer;

function announce(message) {
  const toast = document.querySelector('#toast');
  toast.textContent = message;
  toast.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('visible'), 3000);
}

function applyPreferences(updateUrl = true) {
  root.dataset.concept = current.concept;
  root.dataset.font = current.font;
  document.querySelectorAll('[data-panel]').forEach(panel => { panel.hidden = panel.dataset.panel !== current.concept; });
  document.querySelectorAll('[data-direction]').forEach(button => { button.setAttribute('aria-pressed', String(button.dataset.direction === current.concept)); });
  document.title = current.concept === 'gas-station' ? 'Dilated · Keep your Mac awake.' : `Dilated · ${directions[current.concept].name} study`;
  document.querySelector('meta[name="theme-color"]').content = { 'gas-station': '#ffdf24', night: '#101f26', field: '#f4f0e6' }[current.concept];
  if (updateUrl) {
    const url = new URL(location.href);
    url.searchParams.set('concept', current.concept);
    url.searchParams.delete('font');
    history.replaceState(null, '', url);
  }
}

document.querySelectorAll('[data-direction]').forEach(button => button.addEventListener('click', () => {
  current = readPreferences(`?concept=${button.dataset.direction}`);
  applyPreferences();
  window.scrollTo({ top: 0, behavior: 'instant' });
}));

window.addEventListener('popstate', () => {
  current = readPreferences(location.search);
  applyPreferences(false);
});

const ticker = document.querySelector('.retail-strip');
const tickerControl = document.querySelector('.ticker-control');
tickerControl.addEventListener('click', () => {
  const paused = ticker.dataset.paused !== 'true';
  ticker.dataset.paused = String(paused);
  tickerControl.setAttribute('aria-pressed', String(paused));
  tickerControl.setAttribute('aria-label', paused ? 'Resume scrolling phrases' : 'Pause scrolling phrases');
  tickerControl.querySelector('span').textContent = paused ? '▶' : 'Ⅱ';
});

document.querySelector('#copy-command').addEventListener('click', async event => {
  try {
    await navigator.clipboard.writeText('dilated run -- make test');
    event.target.textContent = 'Copied ✓';
    announce('Command copied.');
    setTimeout(() => { event.target.textContent = 'Copy ↗'; }, 2500);
  } catch {
    announce('Select the command to copy it.');
  }
});

applyPreferences(false);
mountMenuDemos(announce);

const release = await loadRelease(window.fetch.bind(window), document.baseURI);
if (release) {
  const copy = releaseCopy(release);
  document.querySelectorAll('[data-release-link]').forEach(link => {
    link.href = release.downloadURL;
    link.hidden = false;
    link.querySelector('[data-release-label]').textContent = copy.label;
  });
  document.querySelectorAll('[data-testing-only]').forEach(element => { element.hidden = true; });
  document.querySelector('[data-release-status]').textContent = 'ON THE SHELF.';
  document.querySelector('[data-release-heading]').replaceChildren('See you in', document.createElement('br'), 'the menu bar.');
  document.querySelector('[data-release-copy]').textContent = copy.copy;
  document.querySelectorAll('[data-release-summary]').forEach(element => {
    element.textContent = copy.summary;
  });
  document.querySelector('[data-release-version]').textContent = `Version ${release.version} · Build ${release.build}`;
  document.querySelector('[data-release-checksum]').textContent = release.sha256;
  const caveat = document.querySelector('[data-release-caveat]');
  caveat.textContent = copy.caveat;
  caveat.hidden = !copy.caveat;
  document.querySelector('[data-release-details]').hidden = false;
}
