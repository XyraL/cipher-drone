const hudRoot = document.getElementById('hudRoot');
const hud = document.getElementById('hud');
const logo = document.getElementById('logo');

const batFill = document.getElementById('batFill');
const sigFill = document.getElementById('sigFill');
const batVal = document.getElementById('batVal');
const sigVal = document.getElementById('sigVal');

const healthBar = document.getElementById('healthBar');
const hpFill = document.getElementById('hpFill');
const hpVal = document.getElementById('hpVal');

const modeSpot = document.getElementById('modeSpot');
const modeTherm = document.getElementById('modeTherm');
const modeTrack = document.getElementById('modeTrack');
const modeJam = document.getElementById('modeJam');
const hints = document.getElementById('hints');

const dartToast = document.getElementById('dartToast');
const hitFlash = document.getElementById('hitFlash');
const destroyedOverlay = document.getElementById('destroyedOverlay');

const compass = document.getElementById('compass');
const compassTrack = document.getElementById('compassTrack');
const reticle = document.getElementById('reticle');
const radar = document.getElementById('radar');
const radarBlips = document.getElementById('radarBlips');

const bootOverlay = document.getElementById('bootOverlay');
const bootFill = document.getElementById('bootFill');
const bootLines = document.getElementById('bootLines');

// hard-hide on load
hudRoot.classList.add('hidden');
healthBar.classList.add('hidden');

let trackerCdUntil = 0;
let dartToastTimer = null;
let hitFlashTimer = null;
let destroyedTimer = null;
let bootLineTimers = [];

function setPill(el, on){
  if(on) el.classList.add('on');
  else el.classList.remove('on');
}

// ── Compass ──────────────────────────────────────────────────
const COMPASS_PX_PER_TICK = 30;
const COMPASS_DEG_PER_TICK = 15;
const COMPASS_PX_PER_DEG = COMPASS_PX_PER_TICK / COMPASS_DEG_PER_TICK;
const COMPASS_TICKS_PER_LAP = 360 / COMPASS_DEG_PER_TICK;
const COMPASS_LAP_WIDTH = COMPASS_TICKS_PER_LAP * COMPASS_PX_PER_TICK;

const COMPASS_LABELS = { 0: 'N', 45: 'NE', 90: 'E', 135: 'SE', 180: 'S', 225: 'SW', 270: 'W', 315: 'NW' };

function buildCompass(){
  compassTrack.innerHTML = '';
  for (let lap = -1; lap <= 1; lap++) {
    for (let deg = 0; deg < 360; deg += COMPASS_DEG_PER_TICK) {
      const isMajor = deg % 45 === 0;
      const tick = document.createElement('div');
      tick.className = 'compass-tick' + (isMajor ? ' major' : '');

      const mark = document.createElement('div');
      mark.className = 'mark';
      tick.appendChild(mark);

      if (isMajor) {
        const lbl = document.createElement('div');
        lbl.className = 'lbl';
        lbl.textContent = COMPASS_LABELS[deg] || '';
        tick.appendChild(lbl);
      }

      compassTrack.appendChild(tick);
    }
  }
}
buildCompass();

function setHeading(heading){
  const h = ((heading % 360) + 360) % 360;
  // Center the middle lap's 0-degree tick under the fixed pointer, then
  // shift further left as heading increases.
  const offset = -(COMPASS_LAP_WIDTH + (COMPASS_PX_PER_TICK / 2)) - (h * COMPASS_PX_PER_DEG);
  compassTrack.style.transform = `translateX(${offset}px)`;
}

// ── Radar ────────────────────────────────────────────────────
const RADAR_PX_RADIUS = 62;

function updateRadar(blips){
  radarBlips.innerHTML = '';
  if (!Array.isArray(blips)) return;
  blips.forEach((b) => {
    const el = document.createElement('div');
    el.className = 'radar-blip';
    const x = 70 + (b.x || 0) * RADAR_PX_RADIUS;
    const y = 70 - (b.y || 0) * RADAR_PX_RADIUS;
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    radarBlips.appendChild(el);
  });
}

// ── Boot sequence ────────────────────────────────────────────
const BOOT_LOG_MESSAGES = [
  'UPLINK HANDSHAKE...',
  'GYRO CALIBRATION OK',
  'SPECTRUM CHECK OK',
  'ROTOR SPINUP',
  'LINK ESTABLISHED',
];

function startBoot(seconds){
  seconds = seconds || 2.2;

  bootLineTimers.forEach(t => clearTimeout(t));
  bootLineTimers = [];
  bootLines.innerHTML = '';

  bootOverlay.classList.add('show');

  bootFill.style.transition = 'none';
  bootFill.style.width = '0%';
  void bootFill.offsetWidth;
  bootFill.style.transition = `width ${seconds}s linear`;
  bootFill.style.width = '100%';

  BOOT_LOG_MESSAGES.forEach((msg, i) => {
    const t = setTimeout(() => {
      const div = document.createElement('div');
      div.className = 'boot-line';
      div.textContent = '> ' + msg;
      bootLines.appendChild(div);
    }, (seconds * 1000 / BOOT_LOG_MESSAGES.length) * i);
    bootLineTimers.push(t);
  });
}

function endBoot(){
  bootOverlay.classList.remove('show');
  bootLineTimers.forEach(t => clearTimeout(t));
  bootLineTimers = [];
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
    healthBar.classList.toggle('hidden', !d.canBeShotDown);
    compass.classList.toggle('hidden', !d.showCompass);
    radar.classList.toggle('hidden', !d.showRadar);

    if (d.state) {
      hudRoot.classList.remove('hidden');
    } else {
      hudRoot.classList.add('hidden');
      hud.classList.remove('jammed');
      hudRoot.classList.remove('jammed');
      destroyedOverlay.classList.remove('show');
      reticle.classList.remove('locked');
    }
  }

  if (d.type === 'update') {
    const b = Math.max(0, Math.min(100, d.battery ?? 100));
    const s = Math.max(0, Math.min(100, d.signal ?? 100));
    batFill.style.width = `${b}%`;
    sigFill.style.width = `${s}%`;
    batVal.textContent = `${b}%`;
    sigVal.textContent = `${s}%`;

    if (d.health !== null && d.health !== undefined) {
      const h = Math.max(0, Math.min(100, d.health));
      hpFill.style.width = `${h}%`;
      hpVal.textContent = `${h}%`;
    }

    if (typeof d.heading === 'number') setHeading(d.heading);

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

  if (d.type === 'jammed') {
    hud.classList.toggle('jammed', !!d.state);
    hudRoot.classList.toggle('jammed', !!d.state);
    setPill(modeJam, !!d.state);
  }

  if (d.type === 'reticle') {
    reticle.classList.toggle('locked', !!d.locked);
  }

  if (d.type === 'radar') {
    updateRadar(d.blips);
  }

  if (d.type === 'hit') {
    hitFlash.classList.remove('show');
    void hitFlash.offsetWidth;
    hitFlash.classList.add('show');
    if (hitFlashTimer) clearTimeout(hitFlashTimer);
    hitFlashTimer = setTimeout(() => hitFlash.classList.remove('show'), 320);
  }

  if (d.type === 'destroyed') {
    destroyedOverlay.classList.add('show');
    if (destroyedTimer) clearTimeout(destroyedTimer);
    destroyedTimer = setTimeout(() => destroyedOverlay.classList.remove('show'), 2600);
  }

  if (d.type === 'dartFired') {
    dartToast.classList.add('show');
    if (dartToastTimer) clearTimeout(dartToastTimer);
    dartToastTimer = setTimeout(() => dartToast.classList.remove('show'), 900);

    reticle.classList.remove('fired');
    void reticle.offsetWidth;
    reticle.classList.add('fired');
  }

  if (d.type === 'boot') {
    if (d.theme) {
      document.documentElement.style.setProperty('--primary', d.theme.primary || '#38BDF8');
      document.documentElement.style.setProperty('--accent', d.theme.accent || '#FBBF24');
    }
    if (d.show) {
      startBoot(d.seconds);
    } else {
      endBoot();
    }
  }
});
