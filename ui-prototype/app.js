'use strict';

/* Sample hardware. The real app reads these from Core Audio and Core MIDI. */
const MIDI_DEVICES = [
  { name: 'Hapax', connected: true },
  { name: 'Midicake', connected: true },
  { name: 'Berlinan', connected: true },
  { name: 'KeyLab', connected: true },
  { name: 'Launchpad', connected: false },
  { name: 'Oxi E16', connected: true },
  { name: 'Faderfox', connected: true },
];
const PAIRS = ['1–2', '3–4', '5–6', '7–8', '9–10', '11–12', '13–14', '15–16'];
const AUDIO_INPUTS = PAIRS.map((pair) => `In ${pair}`);
const AUDIO_OUTPUTS = PAIRS.map((pair) => `Out ${pair}`);
const MIDI_CHANNELS = ['All', ...Array.from({ length: 16 }, (_, i) => i + 1)];

/* Plugin names match the machine that was scanned. Sounds and presets are samples. */
const PLUGINS = [
  { id: 'tb303', name: 'TB-303', vendor: 'Roland', kind: 'instrument', factory: [], sounds: ['Squelch Line', 'Round Bass', 'Night Drive', 'Hollow Acid'] },
  { id: 'jupiter8', name: 'JUPITER-8', vendor: 'Roland', kind: 'instrument', factory: [], sounds: ['Warm Strings', 'Big Sync Lead', 'Glass Pad', 'Poly Stab'] },
  { id: 'jd800', name: 'JD-800', vendor: 'Roland', kind: 'instrument', factory: [], sounds: ['Digital Bell', 'Choir Air', 'Fat Keys'] },
  { id: 'sh101', name: 'SH-101', vendor: 'Roland', kind: 'instrument', factory: [], sounds: ['Rubber Bass', 'Sync Blip', 'Sub Thump'] },
  { id: 'sp404', name: 'SP-404MKII', vendor: 'Roland', kind: 'instrument', factory: [], sounds: ['Dusty Kit', 'Tape Loop'] },
  { id: 'mariana', name: 'Mariana', vendor: 'Moog', kind: 'instrument', factory: ['Deep Sub', 'Trench', 'Pressure Drop', 'Abyss Lead'], sounds: ['Deep Sub', 'Trench', 'Pressure Drop', 'Abyss Lead'] },
  { id: 'minitaur', name: 'Minitaur Editor-VI', vendor: 'Moog', kind: 'instrument', factory: [], sounds: ['Taurus Low', 'Soft Pluck'] },
  { id: 'prophet', name: 'Prophet-5 V', vendor: 'Arturia', kind: 'instrument', factory: [], sounds: [], notInstalled: true },
  { id: 'vocoder', name: 'Vocoder (sample)', vendor: 'Sample', kind: 'instrument', factory: [], sounds: ['Robot Choir', 'Whisper'], audioIn: true },
  { id: 'scomp', name: 'Sidechain Comp (sample)', vendor: 'Sample', kind: 'effect', factory: [], sounds: ['Pump', 'Gentle Duck'], sidechain: true },
  { id: 'valhalla', name: 'Valhalla Reverb', vendor: 'Valhalla DSP', kind: 'effect', factory: [], sounds: ['Dark Hall', 'Long Plate', 'Small Room'] },
  { id: 'zendelay', name: 'ZEN Delay', vendor: '', kind: 'effect', factory: [], sounds: ['Dub Echo', 'Slapback', 'Ping Pong'] },
  { id: 'audelay', name: 'AUDelay', vendor: 'Apple', kind: 'effect', factory: ['Short', 'Long'], sounds: ['Short', 'Long'] },
  { id: 'aureverb', name: 'AUMatrixReverb', vendor: 'Apple', kind: 'effect', factory: ['Small Room', 'Cathedral'], sounds: ['Small Room', 'Cathedral'] },
  { id: 'aulimiter', name: 'AUPeakLimiter', vendor: 'Apple', kind: 'effect', factory: [], sounds: ['Default'] },
];

const STORAGE_KEY = 'pluginarium.prototype.v2';
const MAX_PARALLEL = 3;

function initialStore() {
  return {
    configs: [
      {
        id: 'c1',
        name: '303 + Jupiter',
        strips: [
          { id: 's1', type: 'instrument', pluginId: 'tb303', preset: 'Acid Bass 04', sound: null, midiDevice: 'Hapax', midiChannel: 1, audioIn: null, audioOut: 'Out 5–6', chain: [] },
          {
            id: 's2', type: 'instrument', pluginId: 'jupiter8', preset: 'Brass Pad', sound: null, midiDevice: 'KeyLab', midiChannel: 2, audioIn: null, audioOut: 'Out 7–8',
            chain: [
              [{ id: 'f1', pluginId: 'zendelay', preset: null, sound: 'Dub Echo' }],
              [{ id: 'f2', pluginId: 'valhalla', preset: 'Dark Hall', sound: null }, { id: 'f3', pluginId: 'audelay', preset: 'Short', sound: null }],
            ],
          },
        ],
      },
      {
        id: 'c2',
        name: 'Studio reverb',
        strips: [
          { id: 's3', type: 'effect', pluginId: 'valhalla', preset: 'Dark Hall', sound: null, midiDevice: null, midiChannel: null, audioIn: 'In 9–10', audioOut: 'Out 11–12', chain: [] },
        ],
      },
      {
        id: 'c3',
        name: 'Single Jupiter',
        strips: [
          { id: 's4', type: 'instrument', pluginId: 'jupiter8', preset: 'Brass Pad', sound: null, midiDevice: 'Hapax', midiChannel: 1, audioIn: null, audioOut: 'Out 5–6', chain: [] },
        ],
      },
      {
        id: 'c4',
        name: 'Moog night',
        strips: [
          { id: 's5', type: 'instrument', pluginId: 'mariana', preset: 'Deep Sub', sound: null, midiDevice: 'Launchpad', midiChannel: 1, audioIn: null, audioOut: 'Out 5–6', chain: [] },
          { id: 's6', type: 'instrument', pluginId: 'prophet', preset: null, sound: null, midiDevice: 'KeyLab', midiChannel: 2, audioIn: null, audioOut: 'Out 7–8', chain: [] },
        ],
      },
      {
        id: 'c5',
        name: 'Ducked bass and voice',
        strips: [
          {
            id: 's7', type: 'instrument', pluginId: 'tb303', preset: 'Rolling 16ths', sound: null, midiDevice: 'Hapax', midiChannel: 1, audioIn: null, audioOut: 'Out 5–6',
            chain: [[{ id: 'f4', pluginId: 'scomp', preset: null, sound: 'Pump', sidechainIn: 'In 3–4' }]],
          },
          { id: 's8', type: 'instrument', pluginId: 'vocoder', preset: null, sound: 'Robot Choir', midiDevice: 'KeyLab', midiChannel: 2, audioIn: 'In 1–2', audioOut: 'Out 7–8', chain: [] },
          { id: 's9', type: 'effect', pluginId: 'scomp', preset: null, sound: 'Gentle Duck', midiDevice: null, midiChannel: null, audioIn: 'In 9–10', sidechainIn: 'In 3–4', audioOut: 'Out 11–12', chain: [] },
        ],
      },
    ],
    presets: {
      tb303: ['Acid Bass 04', 'Rolling 16ths'],
      jupiter8: ['Brass Pad', 'Night Lead'],
      valhalla: ['Dark Hall'],
    },
    recent: ['jupiter8', 'tb303', 'valhalla'],
    settings: {
      audioDevice: 'AudioFuse 16Rig',
      sampleRate: '48 kHz',
      bufferSize: '128 samples',
      clockSource: 'Hapax',
      instrumentPositions: [
        { midiDevice: 'Hapax', midiChannel: 1, audioOut: 'Out 5–6' },
        { midiDevice: 'KeyLab', midiChannel: 2, audioOut: 'Out 7–8' },
        { midiDevice: 'KeyLab', midiChannel: 3, audioOut: 'Out 9–10' },
        { midiDevice: 'KeyLab', midiChannel: 4, audioOut: 'Out 11–12' },
      ],
      effectPositions: [
        { audioIn: 'In 9–10', audioOut: 'Out 11–12' },
        { audioIn: 'In 11–12', audioOut: 'Out 13–14' },
      ],
    },
  };
}

function loadStore() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) return JSON.parse(saved);
  } catch (error) {
    console.warn('Stored prototype data ignored', error);
  }
  return initialStore();
}

function persist() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(store));
  } catch (error) {
    console.warn('Prototype data not stored', error);
  }
}

let store = loadStore();

const session = {
  screen: 'start',
  settingsReturn: 'start',
  config: null,
  savedId: null,
  dirty: false,
  windows: [],
  add: null,
  nextWindowOffset: 0,
};

const app = document.getElementById('app');
const windowLayer = document.getElementById('windows');
const menu = document.getElementById('menu');
const dialog = document.getElementById('dialog');
const toast = document.getElementById('toast');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

function uid(prefix) {
  return `${prefix}${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function pluginOf(id) {
  return PLUGINS.find((plugin) => plugin.id === id);
}

function stripOf(id) {
  return session.config.strips.find((strip) => strip.id === id);
}

function findFx(strip, fxId) {
  for (const row of strip.chain) {
    const fx = row.find((item) => item.id === fxId);
    if (fx) return fx;
  }
  return null;
}

function targetOf(stripId, fxId) {
  const strip = stripOf(stripId);
  return fxId ? findFx(strip, fxId) : strip;
}

function deviceConnected(name) {
  return MIDI_DEVICES.some((device) => device.name === name && device.connected);
}

function clockRunning() {
  return deviceConnected(store.settings.clockSource);
}

function soundLabel(target) {
  if (target.preset) return target.preset;
  if (target.sound) return `${target.sound} (not saved)`;
  return 'Default sound';
}

function configSummary(config) {
  if (!config.strips.length) return 'Empty';
  return config.strips.map((strip) => pluginOf(strip.pluginId).name).join(', ');
}

function optionList(values, selected, labelOf = (value) => value) {
  return values.map((value) => `<option value="${esc(value)}"${String(value) === String(selected) ? ' selected' : ''}>${esc(labelOf(value))}</option>`).join('');
}

function midiDeviceOptions(selected) {
  return optionList(MIDI_DEVICES.map((device) => device.name), selected, (name) => (deviceConnected(name) ? name : `${name} (not connected)`));
}

function sidechainOptions(selected) {
  return optionList(['Off', ...AUDIO_INPUTS], selected ?? 'Off');
}

function routeValue(key, value) {
  if (key === 'midiChannel' && value !== 'All') return Number(value);
  if (key === 'sidechainIn' && value === 'Off') return null;
  return value;
}

/* Screens */

function startScreen() {
  return `
    <section class="start">
      <div>
        <h1 class="wordmark">Pluginarium</h1>
        <p class="tagline">Your plugins as instruments in the studio.</p>
        <div class="power"><span class="led" aria-hidden="true"></span>Ready</div>
      </div>
      <div>
        <div class="configs">
          ${store.configs.map((config) => `
            <button class="config-row" data-action="loadConfig" data-id="${config.id}">
              <strong>${esc(config.name)}</strong>
              <span>${esc(configSummary(config))}</span>
            </button>`).join('')}
        </div>
        <div class="start-actions">
          <button class="key primary" data-action="newConfig">New configuration</button>
          <button class="key" data-action="showSettings">Settings</button>
        </div>
      </div>
    </section>`;
}

function clockReadout() {
  if (!clockRunning()) {
    return `<span class="readout"><span class="led off" aria-hidden="true"></span>No MIDI clock</span>`;
  }
  return `<span class="readout"><span class="led beat" aria-hidden="true"></span>${esc(store.settings.clockSource)} clock, 124.0 BPM</span>`;
}

function cpuLoad() {
  return Math.min(95, 4 + session.config.strips.reduce((sum, strip) => sum + 7 + strip.chain.flat().length * 3, 0));
}

function mixerScreen() {
  const { config, dirty, savedId } = session;
  const name = config.name || 'New configuration';
  return `
    <header class="topbar">
      <button class="config-name" data-action="configMenu" aria-haspopup="menu">${esc(name)}<span class="caret" aria-hidden="true">▾</span></button>
      ${dirty ? '<span class="status">Unsaved changes</span><button class="key" data-action="save">Save</button>' : ''}
      ${!dirty && savedId ? '<span class="status">Saved</span>' : ''}
      <span class="spacer"></span>
      ${clockReadout()}
      <span class="readout">CPU ${cpuLoad()} %</span>
      <button class="key" data-action="showSettings">Settings</button>
    </header>
    <section class="strips" aria-label="Instruments and effects">
      ${config.strips.map(stripHtml).join('')}
      <button class="add-strip" data-action="addStrip">Add instrument or effect</button>
    </section>
    <footer class="note">Prototype: no sound, and plugin windows are stand-ins. Presets, channels and devices are samples.</footer>`;
}

function stripHtml(strip, index) {
  const plugin = pluginOf(strip.pluginId);
  const isOpen = session.windows.some((win) => win.stripId === strip.id && !win.fxId);
  return `
    <article class="strip${strip.type === 'effect' ? ' standalone' : ''}" data-strip="${strip.id}">
      <div class="strip-head">
        <span>${index + 1}</span>
        <button class="remove" data-action="removeStrip" data-strip="${strip.id}" aria-label="Remove ${esc(plugin.name)}" title="Remove">×</button>
      </div>
      ${strip.type === 'instrument' ? midiInHtml(strip) : ''}
      ${strip.type === 'effect' || plugin.audioIn ? audioInHtml(strip) : ''}
      ${plugin.sidechain ? sidechainInHtml(strip) : ''}
      <div>
        <h2 class="plugin-name" title="${esc(plugin.name)}">${esc(plugin.name)}</h2>
        ${plugin.notInstalled ? `
          <div class="fault-box">
            <span>Plugin not installed on this Mac</span>
            <button class="key" data-action="replacePlugin" data-strip="${strip.id}">Replace plugin</button>
          </div>` : `
          <button class="preset" data-action="presetMenu" data-strip="${strip.id}" aria-haspopup="menu">
            <span>${esc(soundLabel(strip))}</span><span class="caret" aria-hidden="true">▾</span>
          </button>`}
      </div>
      ${plugin.notInstalled ? '' : `
        <button class="open" data-action="togglePlugin" data-strip="${strip.id}" aria-pressed="${isOpen}">
          <span class="led${isOpen ? '' : ' off'}" aria-hidden="true"></span>${isOpen ? 'Close plugin' : 'Open plugin'}
        </button>`}
      <div class="slots">
        <span class="legend">Effects</span>
        ${strip.chain.map((row, rowIndex) => rowHtml(strip, row, rowIndex)).join('')}
        <button class="slot-empty" data-action="addInsert" data-strip="${strip.id}">Add effect</button>
      </div>
      <div class="meter" data-meter="${plugin.notInstalled ? 'off' : strip.id}" aria-hidden="true"><div><i></i></div><div><i></i></div></div>
      <label>
        <span class="legend">Audio out</span>
        <select class="field" id="${strip.id}-audioOut" data-change="stripField" data-strip="${strip.id}" data-key="audioOut">${optionList(AUDIO_OUTPUTS, strip.audioOut)}</select>
      </label>
    </article>`;
}

function midiInHtml(strip) {
  const channelId = `${strip.id}-midiChannel`;
  return `
    <div>
      <span class="legend">MIDI in</span>
      <div class="route-pair">
        <select class="field" id="${strip.id}-midiDevice" aria-label="MIDI device" data-change="stripField" data-strip="${strip.id}" data-key="midiDevice">${midiDeviceOptions(strip.midiDevice)}</select>
        <select class="field" id="${channelId}" aria-label="MIDI channel" data-change="stripField" data-strip="${strip.id}" data-key="midiChannel">${optionList(MIDI_CHANNELS, strip.midiChannel)}</select>
      </div>
      ${deviceConnected(strip.midiDevice) ? '' : `<div class="warning"><span class="led fault" aria-hidden="true"></span>${esc(strip.midiDevice)} is not connected</div>`}
    </div>`;
}

function audioInHtml(strip) {
  return `
    <label>
      <span class="legend">Audio in</span>
      <select class="field" id="${strip.id}-audioIn" data-change="stripField" data-strip="${strip.id}" data-key="audioIn">${optionList(AUDIO_INPUTS, strip.audioIn)}</select>
    </label>`;
}

function sidechainInHtml(strip) {
  return `
    <label>
      <span class="legend">Sidechain in</span>
      <select class="field" id="${strip.id}-sidechainIn" data-change="stripField" data-strip="${strip.id}" data-key="sidechainIn">${sidechainOptions(strip.sidechainIn)}</select>
    </label>`;
}

function rowHtml(strip, row, rowIndex) {
  const parallel = row.length > 1;
  return `
    <div class="fx-row${parallel ? ' parallel' : ''}" style="grid-template-columns: repeat(${row.length}, minmax(0, 1fr))">
      ${row.map((fx) => {
        const plugin = pluginOf(fx.pluginId);
        const title = fx.sidechainIn ? `${plugin.name}, sidechain from ${fx.sidechainIn}` : plugin.name;
        return `<button class="fx" data-action="fxMenu" data-strip="${strip.id}" data-fx="${fx.id}" data-row="${rowIndex}" title="${esc(title)}" aria-haspopup="menu">${esc(plugin.name)}</button>${fx.sidechainIn ? `<span class="sidechain-note">Sidechain from ${esc(fx.sidechainIn)}</span>` : ''}`;
      }).join('')}
    </div>`;
}

function settingsScreen() {
  const { settings } = store;
  return `
    <header class="topbar">
      <span class="config-name">Settings</span>
      <span class="spacer"></span>
      <button class="key" data-action="closeSettings">Done</button>
    </header>
    <div class="settings">
      <section>
        <h2>Audio</h2>
        <p>Plugins play and listen through this device.</p>
        <div class="settings-grid">
          ${settingSelect('Device', 'audioDevice', ['AudioFuse 16Rig'], settings.audioDevice)}
          ${settingSelect('Sample rate', 'sampleRate', ['44.1 kHz', '48 kHz', '96 kHz'], settings.sampleRate)}
          ${settingSelect('Buffer size', 'bufferSize', ['64 samples', '128 samples', '256 samples', '512 samples'], settings.bufferSize)}
        </div>
      </section>
      <section>
        <h2>MIDI clock</h2>
        <p>Plugins with tempo sync follow this device.</p>
        <div class="settings-grid">
          ${settingSelect('Clock source', 'clockSource', MIDI_DEVICES.map((device) => device.name), settings.clockSource)}
        </div>
      </section>
      <section>
        <h2>Instrument positions</h2>
        <p>A new instrument takes the routing of its position in the stack. You can change it on the channel afterwards.</p>
        <table>
          <thead><tr><th>Position</th><th>MIDI device</th><th>Channel</th><th>Audio out</th></tr></thead>
          <tbody>
            ${settings.instrumentPositions.map((position, index) => `
              <tr>
                <td>${index + 1}</td>
                <td>${positionSelect('instrumentPositions', index, 'midiDevice', midiDeviceOptions(position.midiDevice), 'MIDI device')}</td>
                <td>${positionSelect('instrumentPositions', index, 'midiChannel', optionList(MIDI_CHANNELS, position.midiChannel), 'Channel')}</td>
                <td>${positionSelect('instrumentPositions', index, 'audioOut', optionList(AUDIO_OUTPUTS, position.audioOut), 'Audio out')}</td>
              </tr>`).join('')}
          </tbody>
        </table>
      </section>
      <section>
        <h2>Effect positions</h2>
        <p>A new standalone effect takes these audio channels.</p>
        <table>
          <thead><tr><th>Position</th><th>Audio in</th><th>Audio out</th></tr></thead>
          <tbody>
            ${settings.effectPositions.map((position, index) => `
              <tr>
                <td>${index + 1}</td>
                <td>${positionSelect('effectPositions', index, 'audioIn', optionList(AUDIO_INPUTS, position.audioIn), 'Audio in')}</td>
                <td>${positionSelect('effectPositions', index, 'audioOut', optionList(AUDIO_OUTPUTS, position.audioOut), 'Audio out')}</td>
              </tr>`).join('')}
          </tbody>
        </table>
      </section>
      <section>
        <h2>Prototype</h2>
        <p>Restores the sample configurations and presets.</p>
        <button class="key" data-action="resetPrototype">Reset sample data</button>
      </section>
    </div>`;
}

function settingSelect(label, key, values, selected) {
  return `
    <label>
      <span class="legend">${esc(label)}</span>
      <select class="field" id="setting-${key}" data-change="setting" data-key="${key}">${optionList(values, selected)}</select>
    </label>`;
}

function positionSelect(list, index, key, options, label) {
  return `<select class="field" id="${list}-${index}-${key}" aria-label="${esc(label)} for position ${index + 1}" data-change="position" data-list="${list}" data-index="${index}" data-key="${key}">${options}</select>`;
}

function render() {
  closeMenu();
  const scroller = app.querySelector('.strips');
  const scrollLeft = scroller ? scroller.scrollLeft : 0;
  const focusedId = document.activeElement && document.activeElement.id;
  if (session.screen === 'start') app.innerHTML = startScreen();
  else if (session.screen === 'settings') app.innerHTML = settingsScreen();
  else app.innerHTML = mixerScreen();
  const nextScroller = app.querySelector('.strips');
  if (nextScroller) nextScroller.scrollLeft = scrollLeft;
  if (focusedId) document.getElementById(focusedId)?.focus();
  renderWindows();
  paintMeters(0);
}

function touch() {
  session.dirty = true;
  render();
}

/* Plugin windows */

function renderWindows() {
  if (session.screen !== 'mixer') {
    windowLayer.innerHTML = '';
    return;
  }
  windowLayer.innerHTML = session.windows.map(windowHtml).join('');
}

function windowHtml(win) {
  const target = targetOf(win.stripId, win.fxId);
  const plugin = pluginOf(target.pluginId);
  return `
    <section class="win" data-window="${win.id}" style="left:${win.x}px; top:${win.y}px" aria-label="${esc(plugin.name)} plugin window">
      <div class="win-title" data-drag="${win.id}">
        <strong>${esc(plugin.name)}</strong>
        <span class="spacer"></span>
        <button class="remove" data-action="closeWindow" data-window="${win.id}" aria-label="Close ${esc(plugin.name)}">×</button>
      </div>
      <div class="win-body">
        <div class="knobs" aria-hidden="true">
          ${[110, 190, 70, 240, 150].map((turn) => `<span class="knob" style="--turn:${turn}deg"></span>`).join('')}
        </div>
        <span class="legend">Sounds inside the plugin</span>
        <div class="win-sounds" role="listbox" aria-label="Sounds inside ${esc(plugin.name)}">
          ${plugin.sounds.map((sound) => `<button class="pick" role="option" aria-selected="${target.sound === sound}" data-action="pickSound" data-window="${win.id}" data-sound="${esc(sound)}">${esc(sound)}</button>`).join('')}
        </div>
        <div class="win-foot">
          <span class="hint">${esc(soundLabel(target))}</span>
          <button class="key" data-action="savePreset" data-strip="${win.stripId}" data-fx="${win.fxId || ''}">Save preset</button>
        </div>
      </div>
    </section>`;
}

function openWindow(stripId, fxId) {
  if (session.windows.some((win) => win.stripId === stripId && win.fxId === fxId)) return;
  const offset = session.nextWindowOffset;
  session.nextWindowOffset = (offset + 1) % 6;
  session.windows.push({ id: uid('w'), stripId, fxId, x: 240 + offset * 34, y: 90 + offset * 30 });
  render();
}

function closeWindow(stripId, fxId) {
  session.windows = session.windows.filter((win) => !(win.stripId === stripId && win.fxId === fxId));
  render();
}

/* Menus */

function openMenu(anchor, html) {
  const key = anchor.dataset.fx || anchor.dataset.strip || anchor.dataset.action;
  const toggled = !menu.hidden && menu.dataset.anchor === key;
  closeMenu();
  if (toggled) return;
  menu.dataset.anchor = key;
  menu.innerHTML = html;
  menu.hidden = false;
  const rect = anchor.getBoundingClientRect();
  const left = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 26);
  const top = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 12);
  menu.style.left = `${Math.max(26, left)}px`;
  menu.style.top = `${Math.max(12, top)}px`;
  menu.querySelector('button')?.focus();
}

function closeMenu() {
  menu.hidden = true;
  menu.innerHTML = '';
  delete menu.dataset.anchor;
}

function presetMenuHtml(stripId, fxId) {
  const target = targetOf(stripId, fxId);
  const plugin = pluginOf(target.pluginId);
  const mine = store.presets[plugin.id] || [];
  const item = (name) => `<button role="menuitem" class="${target.preset === name ? 'current' : ''}" data-action="pickPreset" data-strip="${stripId}" data-fx="${fxId || ''}" data-preset="${esc(name)}">${esc(name)}</button>`;
  return `
    <span class="legend">My presets</span>
    ${mine.length ? mine.map(item).join('') : '<div class="hint">None saved yet</div>'}
    ${plugin.factory.length ? `<hr><span class="legend">Factory presets</span>${plugin.factory.map(item).join('')}` : ''}
    <hr>
    ${plugin.factory.length ? '' : '<div class="hint">This plugin keeps its factory sounds in its own window. Open it, choose a sound and save it here.</div>'}
    <button role="menuitem" data-action="savePreset" data-strip="${stripId}" data-fx="${fxId || ''}">Save as preset</button>`;
}

function fxMenuHtml(strip, fx, rowIndex) {
  const row = strip.chain[rowIndex];
  const isOpen = session.windows.some((win) => win.stripId === strip.id && win.fxId === fx.id);
  const data = `data-strip="${strip.id}" data-fx="${fx.id}" data-row="${rowIndex}"`;
  return `
    <button role="menuitem" data-action="toggleFxPlugin" ${data}>${isOpen ? 'Close plugin' : 'Open plugin'}</button>
    <button role="menuitem" data-action="fxPresetMenu" ${data}>Presets: ${esc(soundLabel(fx))}</button>
    ${pluginOf(fx.pluginId).sidechain ? `<button role="menuitem" data-action="fxSidechainMenu" ${data}>Sidechain in: ${esc(fx.sidechainIn ?? 'Off')}</button>` : ''}
    <hr>
    ${row.length < MAX_PARALLEL ? `<button role="menuitem" data-action="addParallel" ${data}>Add parallel effect</button>` : ''}
    ${row.length > 1 ? `<button role="menuitem" data-action="moveToSeries" ${data}>Move to series</button>` : ''}
    <button role="menuitem" data-action="removeFx" ${data}>Remove</button>`;
}

function sidechainMenuHtml(strip, fx) {
  const item = (label, value) => `<button role="menuitem" class="${(fx.sidechainIn ?? null) === value ? 'current' : ''}" data-action="pickSidechain" data-strip="${strip.id}" data-fx="${fx.id}" data-input="${esc(value ?? '')}">${esc(label)}</button>`;
  return `
    <span class="legend">Sidechain in</span>
    ${item('Off', null)}
    ${AUDIO_INPUTS.map((input) => item(input, input)).join('')}`;
}

function configMenuHtml() {
  return `
    <span class="legend">Load configuration</span>
    ${store.configs.map((config) => `<button role="menuitem" class="${config.id === session.savedId ? 'current' : ''}" data-action="loadConfig" data-id="${config.id}">${esc(config.name)}</button>`).join('')}
    <hr>
    <button role="menuitem" data-action="newConfig">New configuration</button>
    <button role="menuitem" data-action="saveAs">Save as</button>`;
}

/* Dialogs */

function showDialog(html, wide = false) {
  closeMenu();
  dialog.innerHTML = html;
  dialog.className = wide ? 'wide' : '';
  if (!dialog.open) dialog.showModal();
  (dialog.querySelector('[data-autofocus]') || dialog.querySelector('button')).focus();
}

function closeDialog() {
  if (dialog.open) dialog.close();
  session.add = null;
}

function nameDialog({ title, label, value, confirm, onConfirm, note = '' }) {
  session.pendingName = onConfirm;
  showDialog(`
    <form data-submit="confirmName">
      <h2>${esc(title)}</h2>
      ${note ? `<p>${esc(note)}</p>` : ''}
      <label>
        <span class="legend">${esc(label)}</span>
        <input class="field" name="name" value="${esc(value)}" autocomplete="off" required data-autofocus>
      </label>
      <div class="dialog-actions">
        <button type="button" class="key" data-action="closeDialog">Cancel</button>
        <button type="submit" class="key primary">${esc(confirm)}</button>
      </div>
    </form>`);
  dialog.querySelector('input').select();
}

function choiceDialog({ title, text, buttons }) {
  session.pendingChoice = {};
  showDialog(`
    <h2>${esc(title)}</h2>
    <p>${esc(text)}</p>
    <div class="dialog-actions">
      ${buttons.map((button, index) => {
        session.pendingChoice[index] = button.onClick;
        return `<button class="key${button.primary ? ' primary' : ''}" data-action="choice" data-index="${index}"${button.primary ? ' data-autofocus' : ''}>${esc(button.label)}</button>`;
      }).join('')}
    </div>`);
}

function showToast(text) {
  toast.textContent = text;
  toast.hidden = false;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { toast.hidden = true; }, 3600);
}

/* Unsaved changes */

function leaveConfig(next) {
  if (!session.dirty) {
    next();
    return;
  }
  const name = session.config.name || 'this new configuration';
  choiceDialog({
    title: 'Save changes?',
    text: `Do you want to save the changes to ${name}?`,
    buttons: [
      { label: "Don't save", onClick: next },
      { label: 'Cancel', onClick: () => {} },
      { label: 'Save', primary: true, onClick: () => saveConfig(next) },
    ],
  });
}

function saveConfig(after = () => {}) {
  if (!session.savedId) {
    nameDialog({
      title: 'Save configuration',
      label: 'Name',
      value: session.config.name,
      confirm: 'Save',
      onConfirm: (name) => {
        session.config.name = name;
        session.config.id = uid('c');
        session.savedId = session.config.id;
        store.configs.push(clone(session.config));
        finishSave(after);
      },
    });
    return;
  }
  const index = store.configs.findIndex((config) => config.id === session.savedId);
  store.configs[index] = clone(session.config);
  finishSave(after);
}

function finishSave(after) {
  session.dirty = false;
  persist();
  render();
  showToast(`${session.config.name} saved`);
  after();
}

function loadConfig(id) {
  const config = store.configs.find((item) => item.id === id);
  session.config = clone(config);
  session.savedId = id;
  session.dirty = false;
  session.windows = [];
  session.screen = 'mixer';
  render();
}

function newConfig() {
  session.config = { id: null, name: '', strips: [] };
  session.savedId = null;
  session.dirty = false;
  session.windows = [];
  session.screen = 'mixer';
  render();
  openAdd({ kind: 'strip' }, 'instrument');
}

/* Add dialog */

function nextRouting(mode) {
  const { settings } = store;
  const count = session.config.strips.filter((strip) => strip.type === mode).length;
  if (mode === 'instrument') {
    const position = settings.instrumentPositions[count];
    return position ? clone(position) : { midiDevice: MIDI_DEVICES[0].name, midiChannel: Math.min(count + 1, 16), audioOut: AUDIO_OUTPUTS[Math.min(count + 2, AUDIO_OUTPUTS.length - 1)] };
  }
  const position = settings.effectPositions[count];
  return position ? clone(position) : { audioIn: AUDIO_INPUTS[Math.min(count + 4, AUDIO_INPUTS.length - 1)], audioOut: AUDIO_OUTPUTS[Math.min(count + 5, AUDIO_OUTPUTS.length - 1)] };
}

function addCandidates() {
  const { mode, query } = session.add;
  const needle = query.trim().toLowerCase();
  return PLUGINS.filter((plugin) => plugin.kind === mode && !plugin.notInstalled && `${plugin.name} ${plugin.vendor}`.toLowerCase().includes(needle));
}

function openAdd(target, mode) {
  session.add = { target, mode, query: '', pluginId: null, preset: null, routing: nextRouting(mode) };
  session.add.pluginId = defaultPluginId();
  const replacing = target.kind === 'replace';
  const title = target.kind === 'insert' ? `Add effect to ${pluginOf(stripOf(target.stripId).pluginId).name}` : replacing ? 'Replace plugin' : 'Add to stack';
  showDialog(`
    <h2>${esc(title)}</h2>
    ${target.kind === 'strip' ? `
      <div class="tabs" role="tablist">
        <button role="tab" data-action="addMode" data-mode="instrument" aria-selected="${mode === 'instrument'}">Instrument</button>
        <button role="tab" data-action="addMode" data-mode="effect" aria-selected="${mode === 'effect'}">Standalone effect</button>
      </div>` : ''}
    <input id="add-search" class="field" type="search" placeholder="Search plugins" aria-label="Search plugins" autocomplete="off" data-autofocus>
    <div id="add-body"></div>
    <div class="dialog-actions">
      <button class="key" data-action="closeDialog">Cancel</button>
      <button class="key primary" id="add-confirm" data-action="confirmAdd">${replacing ? 'Replace' : 'Add'}</button>
    </div>`, true);
  renderAddBody();
}

function defaultPluginId() {
  const candidates = addCandidates();
  const recent = store.recent.map(pluginOf).find((plugin) => plugin && candidates.includes(plugin));
  return (recent || candidates[0] || {}).id || null;
}

function renderAddBody() {
  const { add } = session;
  const candidates = addCandidates();
  if (!candidates.some((plugin) => plugin.id === add.pluginId)) {
    add.pluginId = (candidates[0] || {}).id || null;
    add.preset = null;
  }
  const pick = (plugin) => `
    <button class="pick" role="option" aria-selected="${plugin.id === add.pluginId}" data-action="addPlugin" data-id="${plugin.id}">
      ${esc(plugin.name)}<span>${esc(plugin.vendor)}</span>
    </button>`;
  const recent = store.recent.map(pluginOf).filter((plugin) => plugin && candidates.includes(plugin));
  const others = candidates.filter((plugin) => !recent.includes(plugin));
  const plugin = pluginOf(add.pluginId);
  const presetPick = (label, value) => `<button class="pick" role="option" aria-selected="${add.preset === value}" data-action="addPreset" data-preset="${esc(value ?? '')}">${esc(label)}</button>`;
  const mine = plugin ? store.presets[plugin.id] || [] : [];
  document.getElementById('add-body').innerHTML = `
    <div class="add-cols">
      <div class="add-col" role="listbox" aria-label="Plugins">
        ${recent.length ? `<span class="legend">Recent</span>${recent.map(pick).join('')}` : ''}
        ${others.length ? `<span class="legend">${recent.length ? 'All' : add.mode === 'instrument' ? 'Instruments' : 'Effects'}</span>${others.map(pick).join('')}` : ''}
        ${candidates.length ? '' : '<div class="hint">No plugin matches this search.</div>'}
      </div>
      <div class="add-col" role="listbox" aria-label="Presets">
        ${plugin ? `
          <span class="legend">Sound</span>
          ${presetPick('Default sound', null)}
          ${mine.length ? `<span class="legend">My presets</span>${mine.map((name) => presetPick(name, name)).join('')}` : ''}
          ${plugin.factory.length ? `<span class="legend">Factory presets</span>${plugin.factory.map((name) => presetPick(name, name)).join('')}` : '<div class="hint">Factory sounds stay inside this plugin. Choose one in its window and save it as a preset.</div>'}` : ''}
      </div>
    </div>
    ${routingHtml()}`;
  document.getElementById('add-confirm').disabled = !plugin;
}

function routingHtml() {
  const { add } = session;
  if (add.target.kind !== 'strip') return '';
  const { routing } = add;
  const plugin = pluginOf(add.pluginId);
  const field = (label, key, options) => `<label><span class="legend">${label}</span><select class="field" data-change="addRoute" data-key="${key}">${options}</select></label>`;
  return `
    <div class="add-route">
      ${add.mode === 'instrument' ? field('MIDI device', 'midiDevice', midiDeviceOptions(routing.midiDevice)) : ''}
      ${add.mode === 'instrument' ? field('Channel', 'midiChannel', optionList(MIDI_CHANNELS, routing.midiChannel)) : ''}
      ${add.mode === 'effect' || plugin?.audioIn ? field('Audio in', 'audioIn', optionList(AUDIO_INPUTS, routing.audioIn ?? AUDIO_INPUTS[0])) : ''}
      ${plugin?.sidechain ? field('Sidechain in', 'sidechainIn', sidechainOptions(routing.sidechainIn)) : ''}
      ${field('Audio out', 'audioOut', optionList(AUDIO_OUTPUTS, routing.audioOut))}
    </div>`;
}

function confirmAdd() {
  const { add } = session;
  if (!add.pluginId) return;
  const { target, pluginId, preset, routing, mode } = add;
  const plugin = pluginOf(pluginId);
  const takesAudio = mode === 'effect' || plugin.audioIn;
  if (target.kind === 'strip') {
    session.config.strips.push({
      id: uid('s'),
      type: mode,
      pluginId,
      preset,
      sound: null,
      midiDevice: routing.midiDevice ?? null,
      midiChannel: routing.midiChannel ?? null,
      audioIn: takesAudio ? routing.audioIn ?? AUDIO_INPUTS[0] : null,
      sidechainIn: plugin.sidechain ? routing.sidechainIn ?? null : null,
      audioOut: routing.audioOut,
      chain: [],
    });
  } else if (target.kind === 'replace') {
    const strip = stripOf(target.stripId);
    Object.assign(strip, { pluginId, preset, sound: null, audioIn: takesAudio ? strip.audioIn ?? AUDIO_INPUTS[0] : null, sidechainIn: null });
  } else {
    const strip = stripOf(target.stripId);
    const fx = { id: uid('f'), pluginId, preset, sound: null };
    if (target.row === null) strip.chain.push([fx]);
    else strip.chain[target.row].push(fx);
  }
  store.recent = [pluginId, ...store.recent.filter((id) => id !== pluginId)].slice(0, 5);
  persist();
  closeDialog();
  touch();
}

/* Saving presets */

function savePreset(stripId, fxId) {
  const target = targetOf(stripId, fxId);
  const plugin = pluginOf(target.pluginId);
  nameDialog({
    title: 'Save preset',
    label: `Preset name for ${plugin.name}`,
    value: target.preset || target.sound || '',
    confirm: 'Save preset',
    note: 'The preset stays available for this plugin in all configurations.',
    onConfirm: (name) => {
      const mine = store.presets[plugin.id] || [];
      if (!mine.includes(name)) store.presets[plugin.id] = [...mine, name];
      target.preset = name;
      target.sound = null;
      persist();
      session.dirty = true;
      if (session.savedId) askToStoreInConfig(name);
      else {
        render();
        showToast(`${name} saved. It joins this configuration when you save it.`);
      }
    },
  });
}

function askToStoreInConfig(presetName) {
  render();
  choiceDialog({
    title: 'Update configuration?',
    text: `${presetName} is saved as a preset. Do you also want to use it in ${session.config.name}?`,
    buttons: [
      { label: 'Not now', onClick: () => {} },
      { label: 'Save configuration', primary: true, onClick: () => saveConfig() },
    ],
  });
}

/* Actions */

const actions = {
  loadConfig(el) {
    const { id } = el.dataset;
    leaveConfig(() => loadConfig(id));
  },
  newConfig() {
    leaveConfig(newConfig);
  },
  configMenu(el) {
    openMenu(el, configMenuHtml());
  },
  save() {
    saveConfig();
  },
  saveAs() {
    nameDialog({
      title: 'Save as',
      label: 'Name',
      value: session.config.name ? `${session.config.name} copy` : '',
      confirm: 'Save',
      onConfirm: (name) => {
        session.config.name = name;
        session.config.id = uid('c');
        session.savedId = session.config.id;
        store.configs.push(clone(session.config));
        finishSave(() => {});
      },
    });
  },
  showSettings() {
    session.settingsReturn = session.screen;
    session.screen = 'settings';
    render();
  },
  closeSettings() {
    session.screen = session.settingsReturn;
    render();
  },
  resetPrototype() {
    choiceDialog({
      title: 'Reset sample data?',
      text: 'Configurations and presets you created in the prototype will be removed.',
      buttons: [
        { label: 'Cancel', onClick: () => {} },
        {
          label: 'Reset',
          primary: true,
          onClick: () => {
            store = initialStore();
            persist();
            Object.assign(session, { screen: 'start', config: null, savedId: null, dirty: false, windows: [] });
            render();
          },
        },
      ],
    });
  },
  addStrip() {
    openAdd({ kind: 'strip' }, 'instrument');
  },
  addMode(el) {
    openAdd({ kind: 'strip' }, el.dataset.mode);
  },
  addInsert(el) {
    openAdd({ kind: 'insert', stripId: el.dataset.strip, row: null }, 'effect');
  },
  addParallel(el) {
    openAdd({ kind: 'insert', stripId: el.dataset.strip, row: Number(el.dataset.row) }, 'effect');
  },
  replacePlugin(el) {
    const strip = stripOf(el.dataset.strip);
    openAdd({ kind: 'replace', stripId: strip.id }, strip.type);
  },
  addPlugin(el) {
    session.add.pluginId = el.dataset.id;
    session.add.preset = null;
    renderAddBody();
  },
  addPreset(el) {
    session.add.preset = el.dataset.preset || null;
    renderAddBody();
  },
  confirmAdd,
  closeDialog,
  choice(el) {
    const onClick = session.pendingChoice[el.dataset.index];
    closeDialog();
    onClick();
  },
  removeStrip(el) {
    const { strip: stripId } = el.dataset;
    const strip = stripOf(stripId);
    choiceDialog({
      title: 'Remove channel?',
      text: `${pluginOf(strip.pluginId).name} and its effects will be removed from this configuration.`,
      buttons: [
        { label: 'Cancel', onClick: () => {} },
        {
          label: 'Remove',
          primary: true,
          onClick: () => {
            session.config.strips = session.config.strips.filter((item) => item.id !== stripId);
            session.windows = session.windows.filter((win) => win.stripId !== stripId);
            touch();
          },
        },
      ],
    });
  },
  togglePlugin(el) {
    const { strip } = el.dataset;
    const isOpen = session.windows.some((win) => win.stripId === strip && !win.fxId);
    if (isOpen) closeWindow(strip, null);
    else openWindow(strip, null);
  },
  toggleFxPlugin(el) {
    const { strip, fx } = el.dataset;
    const isOpen = session.windows.some((win) => win.stripId === strip && win.fxId === fx);
    if (isOpen) closeWindow(strip, fx);
    else openWindow(strip, fx);
  },
  closeWindow(el) {
    session.windows = session.windows.filter((win) => win.id !== el.dataset.window);
    render();
  },
  pickSound(el) {
    const win = session.windows.find((item) => item.id === el.dataset.window);
    const target = targetOf(win.stripId, win.fxId);
    target.sound = el.dataset.sound;
    target.preset = null;
    touch();
  },
  presetMenu(el) {
    openMenu(el, presetMenuHtml(el.dataset.strip, null));
  },
  fxPresetMenu(el) {
    const { strip, fx } = el.dataset;
    closeMenu();
    openMenu(app.querySelector(`.fx[data-fx="${fx}"]`), presetMenuHtml(strip, fx));
  },
  fxSidechainMenu(el) {
    const { strip: stripId, fx: fxId } = el.dataset;
    const strip = stripOf(stripId);
    closeMenu();
    openMenu(app.querySelector(`.fx[data-fx="${fxId}"]`), sidechainMenuHtml(strip, findFx(strip, fxId)));
  },
  pickSidechain(el) {
    findFx(stripOf(el.dataset.strip), el.dataset.fx).sidechainIn = el.dataset.input || null;
    touch();
  },
  pickPreset(el) {
    const target = targetOf(el.dataset.strip, el.dataset.fx || null);
    target.preset = el.dataset.preset;
    target.sound = null;
    touch();
  },
  savePreset(el) {
    savePreset(el.dataset.strip, el.dataset.fx || null);
  },
  fxMenu(el) {
    const strip = stripOf(el.dataset.strip);
    openMenu(el, fxMenuHtml(strip, findFx(strip, el.dataset.fx), Number(el.dataset.row)));
  },
  moveToSeries(el) {
    const strip = stripOf(el.dataset.strip);
    const rowIndex = Number(el.dataset.row);
    const row = strip.chain[rowIndex];
    const fx = findFx(strip, el.dataset.fx);
    strip.chain[rowIndex] = row.filter((item) => item !== fx);
    strip.chain.splice(rowIndex + 1, 0, [fx]);
    touch();
  },
  removeFx(el) {
    const strip = stripOf(el.dataset.strip);
    const fx = findFx(strip, el.dataset.fx);
    strip.chain = strip.chain.map((row) => row.filter((item) => item !== fx)).filter((row) => row.length);
    session.windows = session.windows.filter((win) => win.fxId !== fx.id);
    touch();
  },
};

const changes = {
  stripField(el) {
    stripOf(el.dataset.strip)[el.dataset.key] = routeValue(el.dataset.key, el.value);
    touch();
  },
  setting(el) {
    store.settings[el.dataset.key] = el.value;
    persist();
    render();
  },
  position(el) {
    store.settings[el.dataset.list][el.dataset.index][el.dataset.key] = routeValue(el.dataset.key, el.value);
    persist();
    render();
  },
  addRoute(el) {
    session.add.routing[el.dataset.key] = routeValue(el.dataset.key, el.value);
  },
};

document.addEventListener('click', (event) => {
  const el = event.target.closest('[data-action]');
  if (!el) {
    if (!event.target.closest('#menu')) closeMenu();
    return;
  }
  const opensMenu = ['configMenu', 'presetMenu', 'fxMenu', 'fxPresetMenu', 'fxSidechainMenu'].includes(el.dataset.action);
  if (!opensMenu) closeMenu();
  actions[el.dataset.action](el, event);
});

document.addEventListener('change', (event) => {
  const el = event.target.closest('[data-change]');
  if (el) changes[el.dataset.change](el);
});

document.addEventListener('submit', (event) => {
  const form = event.target.closest('[data-submit="confirmName"]');
  if (!form) return;
  event.preventDefault();
  const name = new FormData(form).get('name').trim();
  if (!name) return;
  const onConfirm = session.pendingName;
  closeDialog();
  onConfirm(name);
});

document.addEventListener('input', (event) => {
  if (event.target.id !== 'add-search') return;
  session.add.query = event.target.value;
  renderAddBody();
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeMenu();
  if (event.key === 's' && event.metaKey && session.screen === 'mixer' && !dialog.open) {
    event.preventDefault();
    if (session.dirty) saveConfig();
  }
  if (event.target.id === 'add-search') handleAddKeys(event);
});

function handleAddKeys(event) {
  if (event.key === 'Enter') {
    event.preventDefault();
    confirmAdd();
    return;
  }
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  event.preventDefault();
  const candidates = addCandidates();
  const index = candidates.findIndex((plugin) => plugin.id === session.add.pluginId);
  const step = event.key === 'ArrowDown' ? 1 : -1;
  const next = candidates[(index + step + candidates.length) % candidates.length];
  if (next) {
    session.add.pluginId = next.id;
    session.add.preset = null;
    renderAddBody();
  }
}

dialog.addEventListener('close', () => { session.add = null; });

/* Plugin window dragging */

windowLayer.addEventListener('pointerdown', (event) => {
  const handle = event.target.closest('[data-drag]');
  if (!handle || event.target.closest('button')) return;
  const win = session.windows.find((item) => item.id === handle.dataset.drag);
  const node = handle.closest('.win');
  const startX = event.clientX - win.x;
  const startY = event.clientY - win.y;
  handle.setPointerCapture(event.pointerId);
  const move = (moveEvent) => {
    win.x = Math.max(0, Math.min(window.innerWidth - 120, moveEvent.clientX - startX));
    win.y = Math.max(0, Math.min(window.innerHeight - 40, moveEvent.clientY - startY));
    node.style.left = `${win.x}px`;
    node.style.top = `${win.y}px`;
  };
  const stop = () => {
    handle.removeEventListener('pointermove', move);
    handle.removeEventListener('pointerup', stop);
  };
  handle.addEventListener('pointermove', move);
  handle.addEventListener('pointerup', stop);
});

/* Simulated level meters */

const levels = new Map();

function paintMeters(step) {
  app.querySelectorAll('.meter').forEach((meter) => {
    const key = meter.dataset.meter;
    if (key === 'off') return;
    const previous = levels.get(key) || 0.4;
    const level = Math.max(0.08, Math.min(0.92, previous + (Math.random() - 0.5) * step));
    levels.set(key, level);
    meter.querySelectorAll('i').forEach((bar, side) => {
      const value = level - side * 0.05;
      bar.style.clipPath = `inset(0 ${100 - value * 100}% 0 0)`;
    });
  });
}

function animateMeters() {
  paintMeters(0.14);
  if (!reducedMotion) setTimeout(animateMeters, 90);
}

render();
animateMeters();
