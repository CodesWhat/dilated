import { directions, readPreferences, remainingTime } from './state.mjs';
import { loadRelease } from './release.mjs';

const root = document.documentElement;
let saved = {};
try { saved = JSON.parse(localStorage.getItem('dilated-study-fonts') || '{}') || {}; } catch {}
let current = readPreferences(location.search, saved);
let deadline = null;
let duration = 30;
let timer;
let toastTimer;

document.querySelectorAll('[data-demo-mount]').forEach(mount => {
  mount.append(document.querySelector('#awake-demo').content.cloneNode(true));
});

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
  document.querySelector('#font-choice').value = current.font;
  document.title = current.concept === 'gas-station' ? 'Dilated · Keep your Mac awake.' : `Dilated · ${directions[current.concept].name} study`;
  document.querySelector('meta[name="theme-color"]').content = { 'gas-station': '#ffdf24', night: '#101f26', field: '#f4f0e6' }[current.concept];
  if (updateUrl) {
    const url = new URL(location.href);
    url.searchParams.set('concept', current.concept);
    url.searchParams.set('font', current.font);
    history.replaceState(null, '', url);
  }
}

document.querySelectorAll('[data-direction]').forEach(button => button.addEventListener('click', () => {
  current = readPreferences(`?concept=${button.dataset.direction}`, saved);
  applyPreferences();
  window.scrollTo({ top: 0, behavior: 'instant' });
}));

document.querySelector('#font-choice').addEventListener('change', event => {
  current.font = event.target.value;
  saved[current.concept] = current.font;
  try { localStorage.setItem('dilated-study-fonts', JSON.stringify(saved)); } catch {}
  applyPreferences();
});

window.addEventListener('popstate', () => {
  current = readPreferences(location.search, saved);
  applyPreferences(false);
});

function renderDemo() {
  if (deadline !== null && Date.now() >= deadline) { deadline = null; clearInterval(timer); }
  const awake = deadline !== null;
  document.querySelectorAll('.awake-demo').forEach(demo => {
    demo.dataset.awake = String(awake);
    demo.querySelector('[data-status]').textContent = awake ? 'Keeping the work awake.' : 'Ready when you are.';
    demo.querySelector('[data-clock]').textContent = awake ? remainingTime(deadline, Date.now()) : `${String(duration).padStart(2, '0')}:00`;
    demo.querySelector('[data-demo-title]').textContent = awake ? 'Eyes open.' : 'A little longer?';
    demo.querySelector('[data-demo-description]').textContent = awake ? 'System awake. Display allowed to sleep.' : 'Let the display sleep. Keep the work going.';
    demo.querySelector('[data-start]').innerHTML = awake ? 'Stop <span aria-hidden="true">×</span>' : 'Keep awake <span aria-hidden="true">↗</span>';
    demo.querySelector('[data-duration]').value = String(duration);
    demo.querySelector('[data-duration]').disabled = awake;
  });
}

document.querySelectorAll('[data-start]').forEach(button => button.addEventListener('click', () => {
  clearInterval(timer);
  if (deadline === null) {
    deadline = Date.now() + duration * 60 * 1000;
    timer = setInterval(renderDemo, 1000);
    announce(`${duration}-minute preview started.`);
  } else {
    deadline = null;
    announce('Preview stopped.');
  }
  renderDemo();
}));
document.querySelectorAll('[data-duration]').forEach(select => select.addEventListener('change', event => {
  duration = Number(event.target.value);
  renderDemo();
}));
document.addEventListener('visibilitychange', () => { if (!document.hidden) renderDemo(); });
window.addEventListener('pagehide', () => { clearInterval(timer); clearTimeout(toastTimer); });

document.querySelectorAll('[data-icon]').forEach(button => button.addEventListener('click', () => {
  const icon = button.dataset.icon;
  document.querySelectorAll('[data-icon]').forEach(option => {
    const selected = option === button;
    option.setAttribute('aria-pressed', String(selected));
    option.querySelector('.icon-pick').textContent = selected ? 'Selected ↗' : 'Try this icon ↗';
  });
  const path = `./assets/icon-${icon}.svg`;
  document.querySelector('#favicon').href = path;
  const download = document.querySelector('#download-icon');
  download.href = path;
  download.download = `dilated-${icon}.svg`;
  announce('Icon selected. Save the SVG below.');
}));

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
renderDemo();

const release = await loadRelease(window.fetch.bind(window), document.baseURI);
if (release) {
  document.querySelectorAll('[data-release-link]').forEach(link => {
    link.href = release.downloadURL;
    link.hidden = false;
    link.querySelector('[data-release-label]').textContent = 'Download for Mac';
  });
  document.querySelectorAll('[data-testing-only]').forEach(element => { element.hidden = true; });
  document.querySelector('[data-release-status]').textContent = 'ON THE SHELF.';
  document.querySelector('[data-release-heading]').replaceChildren('See you in', document.createElement('br'), 'the menu bar.');
  document.querySelector('[data-release-copy]').textContent = `Dilated ${release.version} is ready for macOS ${release.minimumMacOS}+ on Apple Silicon. Free software from CodesWhat, under MIT.`;
  document.querySelectorAll('[data-release-summary]').forEach(element => {
    element.textContent = `V${release.version} · MACOS ${release.minimumMacOS}+ · APPLE SILICON · MIT LICENSE`;
  });
  document.querySelector('[data-release-version]').textContent = `Version ${release.version} · Build ${release.build}`;
  document.querySelector('[data-release-checksum]').textContent = release.sha256;
  document.querySelector('[data-release-details]').hidden = false;
}
