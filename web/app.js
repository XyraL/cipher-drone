const hud = document.getElementById('hud');
const logo = document.getElementById('logo');

const batFill = document.getElementById('batFill');
const sigFill = document.getElementById('sigFill');
const batVal = document.getElementById('batVal');
const sigVal = document.getElementById('sigVal');

const modeSpot = document.getElementById('modeSpot');
const modeTherm = document.getElementById('modeTherm');
const modeTrack = document.getElementById('modeTrack');
const hints = document.getElementById('hints');

// hard-hide on load
hud.classList.add('hidden');

let trackerCdUntil = 0;

function setPill(el, on){
  if(on) el.classList.add('on');
  else el.classList.remove('on');
}

window.addEventListener('message', (e) => {
  const d = e.data;
  if (!d || !d.type) return;

  if (d.type === 'toggle') {
    if (d.theme) {
      document.documentElement.style.setProperty('--primary', d.theme.primary || '#38BDF8');
      document.documentElement.style.setProperty('--accent', d.theme.accent || '#FBBF24');
      if (d.theme.logoUrl) logo.src = d.theme.logoUrl;
    }
    hints.style.display = d.showHints ? 'block' : 'none';
    if (d.state) hud.classList.remove('hidden'); else hud.classList.add('hidden');
  }

  if (d.type === 'update') {
    const b = Math.max(0, Math.min(100, d.battery ?? 100));
    const s = Math.max(0, Math.min(100, d.signal ?? 100));
    batFill.style.width = `${b}%`;
    sigFill.style.width = `${s}%`;
    batVal.textContent = `${b}%`;
    sigVal.textContent = `${s}%`;

    setPill(modeSpot, !!d.spotlight);
    setPill(modeTherm, !!d.thermal);

    const cd = Math.max(0, trackerCdUntil - Date.now());
    setPill(modeTrack, cd <= 0);
    modeTrack.textContent = cd <= 0 ? 'TRACK' : `CD ${Math.ceil(cd/1000)}s`;
  }

  if (d.type === 'trackerCd') {
    const sec = Math.max(0, d.seconds || 0);
    trackerCdUntil = Date.now() + sec * 1000;
  }
});