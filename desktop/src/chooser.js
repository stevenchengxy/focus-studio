'use strict';
let selected = null;
let data = null;
let filter = 'all';
const sources = document.getElementById('sources');
const confirm = document.getElementById('confirm');
const selection = document.getElementById('selection');
function render() {
  sources.replaceChildren();
  const visible = data.sources.filter(source => filter === 'all' || source.kind === filter);
  for (const source of visible) {
    const button = document.createElement('button');
    button.className = 'source'; button.setAttribute('aria-pressed', String(selected === source.id));
    const image = document.createElement('img'); image.src = source.thumbnail; image.alt = '';
    const name = document.createElement('span'); name.textContent = source.name;
    button.append(image, name);
    button.addEventListener('click', () => { selected = source.id; confirm.disabled = false; selection.textContent = source.name; render(); });
    sources.append(button);
  }
  if (!visible.length) { const empty = document.createElement('p'); empty.textContent = 'No sources in this category.'; sources.append(empty); }
}
for (const type of ['all', 'screen', 'window']) document.getElementById(type).addEventListener('click', () => {
  filter = type;
  for (const tab of ['all', 'screen', 'window']) document.getElementById(tab).setAttribute('aria-pressed', String(tab === type));
  render();
});
document.getElementById('cancel').addEventListener('click', () => window.captureChooser.cancel());
document.addEventListener('keydown', event => { if (event.key === 'Escape') window.captureChooser.cancel(); });
confirm.addEventListener('click', async () => {
  confirm.disabled = true;
  await window.captureChooser.select(selected, document.getElementById('audio').checked);
});
window.captureChooser.read().then(value => {
  data = value;
  const available = data.audioRequested && data.systemAudio;
  document.getElementById('audio-label').hidden = !available;
  document.getElementById('audio-note').textContent = available
    ? 'System audio includes every app, even when you select one window. Microphone access is requested separately.'
    : data.audioRequested ? 'System audio is unavailable in this desktop preview on your platform. You can record your microphone separately.'
    : 'System audio is off. Microphone access is requested separately.';
  render();
}).catch(() => { selection.textContent = 'The capture request ended. Close this window and try again.'; });
