'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const {SITE_ORIGIN} = require('./policy.cjs');

const DAY = 24 * 60 * 60 * 1000;
const RETRY = 60 * 60 * 1000;
const RELEASE_REPOSITORY = 'https://github.com/stevenchengxy/focus-studio/releases/tag/';

function parseVersion(value) {
  if (typeof value !== 'string' || value.length > 100) return null;
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.exec(value);
  if (!match) return null;
  const core = match.slice(1, 4).map(Number);
  const pre = match[4]?.split('.') ?? [];
  if (!core.every(Number.isSafeInteger) || pre.some(v => /^\d+$/.test(v) && (v.length > 1 && v[0] === '0' || !Number.isSafeInteger(Number(v))))) return null;
  return {core, pre};
}

function compareVersions(left, right) {
  const a = parseVersion(left), b = parseVersion(right);
  if (!a || !b) throw new Error('Invalid release version.');
  for (let i = 0; i < 3; i++) if (a.core[i] !== b.core[i]) return a.core[i] > b.core[i] ? 1 : -1;
  if (!a.pre.length || !b.pre.length) return a.pre.length === b.pre.length ? 0 : a.pre.length ? -1 : 1;
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    if (a.pre[i] === undefined || b.pre[i] === undefined) return a.pre[i] === undefined ? -1 : 1;
    if (a.pre[i] === b.pre[i]) continue;
    const an = /^\d+$/.test(a.pre[i]), bn = /^\d+$/.test(b.pre[i]);
    if (an && bn) return Number(a.pre[i]) > Number(b.pre[i]) ? 1 : -1;
    if (an !== bn) return an ? -1 : 1;
    return a.pre[i] > b.pre[i] ? 1 : -1;
  }
  return 0;
}

function officialDownload(raw, platform, channel, version) {
  try {
    const url = new URL(raw);
    return url.origin === SITE_ORIGIN && !url.username && !url.password && !url.hash &&
      url.pathname === `/api/download/${platform}` && [...url.searchParams.keys()].every(k => ['channel', 'version'].includes(k)) &&
      url.searchParams.getAll('channel').length === 1 && url.searchParams.get('channel') === channel &&
      url.searchParams.getAll('version').length === 1 && url.searchParams.get('version') === version && Boolean(parseVersion(version));
  } catch { return false; }
}

function validateRelease(data, platform, channel) {
  if (!data || data.platform !== platform || !['stable', 'preview'].includes(data.channel) ||
      (channel === 'stable' && data.channel !== 'stable') || !parseVersion(data.version) ||
      typeof data.title !== 'string' || data.title.length > 160 || !data.title.trim() ||
      typeof data.published_at !== 'string' || !Number.isFinite(Date.parse(data.published_at)) ||
      !officialDownload(data.download_url, platform, channel, data.version)) throw new Error('The update response is invalid.');
  let release;
  try { release = new URL(data.release_url); } catch { throw new Error('The release link is invalid.'); }
  if (!release.href.startsWith(RELEASE_REPOSITORY) || release.username || release.password || release.search || release.hash ||
      !/^\/stevenchengxy\/focus-studio\/releases\/tag\/[A-Za-z0-9._-]+$/.test(release.pathname)) throw new Error('The release link is invalid.');
  return {platform, channel: data.channel, requested_channel: channel, version: data.version, title: data.title, published_at: data.published_at,
    download_url: data.download_url, release_url: release.href};
}

async function responseJSON(response) {
  if (!response.body?.getReader) throw new Error('No update response.');
  const reader = response.body.getReader(); let size = 0; const chunks = [];
  try {
    while (true) {
      const {done, value} = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > 32768) throw new Error('The update response is too large.');
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally { await reader.cancel().catch(() => {}); }
}

/// Version checks never download, install or relaunch the app. All external links
/// are validated in the main process, separate from the renderer's account bridge.
class UpdateController {
  constructor({directory, platform = process.platform, version, fetcher = fetch, now = Date.now,
    isIdle = () => false, present, openExternal, onChanged = () => {}}) {
    Object.assign(this, {directory, version, fetcher, now, isIdle, present, openExternal, onChanged});
    this.platform = platform === 'win32' ? 'windows' : platform === 'linux' ? 'linux' : null;
    this.file = path.join(directory, 'updates.json'); this.writes = Promise.resolve();
    this.settings = {channel: 'preview', automatic: true, lastCheckedAt: null, lastAttemptAt: null, notifiedVersion: null};
    this.pending = null; this.inFlight = null; this.presenting = false; this.disposed = false; this.epoch = 0;
  }
  async load() {
    try {
      const raw = await fs.readFile(this.file); if (raw.byteLength > 32768) return;
      const data = JSON.parse(raw.toString('utf8'));
      if (['stable', 'preview'].includes(data.channel)) this.settings.channel = data.channel;
      if (typeof data.automatic === 'boolean') this.settings.automatic = data.automatic;
      for (const key of ['lastCheckedAt', 'lastAttemptAt']) if (Number.isFinite(data[key]) && data[key] >= 0) this.settings[key] = data[key];
      if (parseVersion(data.notifiedVersion)) this.settings.notifiedVersion = data.notifiedVersion;
    } catch { /* A missing/corrupt preference file never prevents Studio opening. */ }
    this.onChanged(this.settings);
  }
  persist() {
    const data = JSON.stringify(this.settings);
    this.writes = this.writes.catch(() => {}).then(async () => {
      await fs.mkdir(this.directory, {recursive: true, mode: 0o700});
      const temporary = this.file + '.' + crypto.randomUUID() + '.tmp';
      try { await fs.writeFile(temporary, data, {mode: 0o600}); await fs.rename(temporary, this.file); }
      finally { await fs.unlink(temporary).catch(() => {}); }
    });
    return this.writes.catch(() => {});
  }
  start() {
    if (!this.platform || this.disposed) return;
    this.startTimer = setTimeout(() => { void this.check(); }, 30000); this.startTimer.unref?.();
    this.timer = setInterval(() => { void this.check(); void this.flush(); }, RETRY); this.timer.unref?.();
  }
  setAutomatic(value) {
    this.settings.automatic = value === true; this.onChanged(this.settings); void this.persist();
    if (!this.settings.automatic && this.pending?.manual !== true) this.pending = null;
  }
  setChannel(channel) {
    if (!['preview', 'stable'].includes(channel) || this.settings.channel === channel) return;
    this.epoch++; this.controller?.abort(); this.pending = null;
    this.settings = {...this.settings, channel, lastCheckedAt: null, lastAttemptAt: null, notifiedVersion: null};
    this.onChanged(this.settings); void this.persist();
  }
  async check({manual = false} = {}) {
    if (this.disposed || !this.platform) return;
    if (this.inFlight) { this.manualRequested ||= manual; return this.inFlight; }
    if (!manual && !this.settings.automatic) return;
    const now = this.now(), elapsed = stamp => stamp === null ? Infinity : now - stamp;
    if (!manual && ((elapsed(this.settings.lastCheckedAt) >= 0 && elapsed(this.settings.lastCheckedAt) < DAY) ||
      (elapsed(this.settings.lastAttemptAt) >= 0 && elapsed(this.settings.lastAttemptAt) < RETRY))) return;
    if (manual && elapsed(this.settings.lastAttemptAt) >= 0 && elapsed(this.settings.lastAttemptAt) < 10000) {
      this.pending ||= {kind: 'message', manual: true, message: 'Please wait a few seconds before checking again.'};
      return this.flush();
    }
    const channel = this.settings.channel, epoch = this.epoch;
    this.settings.lastAttemptAt = now; void this.persist();
    this.manualRequested = manual;
    this.controller = new AbortController();
    const timeout = setTimeout(() => this.controller?.abort(), 10000); timeout.unref?.();
    this.inFlight = Promise.resolve().then(async () => {
      try {
        const response = await this.fetcher(`${SITE_ORIGIN}/api/releases?platform=${this.platform}&channel=${channel}`,
          {headers: {'accept': 'application/json'}, redirect: 'error', signal: this.controller.signal});
        if (response.status !== 404 && !response.ok) throw new Error('Update service unavailable.');
        const release = response.status === 404 ? null : validateRelease(await responseJSON(response), this.platform, channel);
        if (this.disposed || this.epoch !== epoch) return;
        this.settings.lastCheckedAt = this.now(); await this.persist();
        if (this.disposed || this.epoch !== epoch || (!this.manualRequested && !this.settings.automatic)) return;
        const newer = release && compareVersions(release.version, this.version) > 0;
        if (newer && (this.manualRequested || release.version !== this.settings.notifiedVersion)) {
          this.pending = {kind: 'available', release, manual: this.manualRequested};
        } else if (this.manualRequested) {
          this.pending = {kind: 'message', manual: true, message: release ? `You’re up to date (${this.version}).` : 'No release is available in this channel yet.'};
        }
      } catch {
        if (!this.disposed && this.epoch === epoch && this.manualRequested) {
          this.pending = {kind: 'message', manual: true, message: 'Could not check for updates. Check your connection and try again.'};
        }
      } finally { clearTimeout(timeout); this.inFlight = null; this.controller = null; }
      await this.flush();
    });
    return this.inFlight;
  }
  async flush() {
    if (this.disposed || this.presenting || !this.pending || !this.isIdle()) return;
    const notice = this.pending; this.pending = null; this.presenting = true;
    try {
      const answer = await this.present(notice);
      if (this.disposed || (notice.kind === 'available' && notice.release.requested_channel !== this.settings.channel)) return;
      if (notice.kind === 'available') {
        this.settings.notifiedVersion = notice.release.version; await this.persist();
        // Check again after an awaited dialog, and only open a download after
        // the person explicitly chose it. It never touches the installed app.
        if (answer === 'download' && officialDownload(notice.release.download_url, this.platform, notice.release.requested_channel, notice.release.version)) {
          await this.openExternal(notice.release.download_url);
        }
      }
    } catch { /* Browser/dialog failure cannot break recording or clear user media. */ }
    finally { this.presenting = false; }
  }
  dispose() { this.disposed = true; this.epoch++; clearTimeout(this.startTimer); clearInterval(this.timer); this.controller?.abort(); this.pending = null; }
}

module.exports = {UpdateController, parseVersion, compareVersions, officialDownload, validateRelease, responseJSON, DAY, RETRY};
