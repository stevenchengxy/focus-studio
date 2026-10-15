'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const {SITE_ORIGIN, TOKEN_PATTERN} = require('./policy.cjs');

function validCredential(value, now = Date.now()) {
  return Boolean(value && value.purpose === 'community' && TOKEN_PATTERN.test(value.accessToken) &&
    Number.isFinite(value.expiresAt) && value.expiresAt > now);
}

// This file and encrypted envelope are deliberately separate from account-token.enc.
// A legacy account credential must never become a community confirmation credential.
class CommunityVault {
  constructor({directory, safeStorage, platform = process.platform, now = Date.now}) {
    Object.assign(this, {safeStorage, platform, now});
    this.file = path.join(directory, 'community-token.enc');
    this.loaded = false; this.memory = null; this.queue = Promise.resolve(); this.writeFailed = false;
  }
  durable() {
    return !this.writeFailed && this.safeStorage.isEncryptionAvailable() && (this.platform !== 'linux' ||
      ['gnome_libsecret', 'kwallet', 'kwallet5', 'kwallet6'].includes(this.safeStorage.getSelectedStorageBackend()));
  }
  serial(action) { const result = this.queue.then(action); this.queue = result.catch(() => {}); return result; }
  get() { return this.serial(async () => {
    if (!this.loaded) {
      this.loaded = true;
      try {
        if (this.durable() && (await fs.stat(this.file)).size <= 4096) {
          const value = JSON.parse(this.safeStorage.decryptString(await fs.readFile(this.file)));
          if (validCredential(value, this.now())) this.memory = value;
        }
      } catch { this.memory = null; }
    }
    return validCredential(this.memory, this.now()) ? {...this.memory} : null;
  }); }
  set(value) { return this.serial(async () => {
    if (!validCredential(value, this.now())) throw new Error('Invalid community credential.');
    this.memory = {purpose: 'community', accessToken: value.accessToken, expiresAt: value.expiresAt}; this.loaded = true;
    try {
      if (!this.durable()) { await fs.rm(this.file, {force: true}); return; }
      await fs.mkdir(path.dirname(this.file), {recursive: true, mode: 0o700});
      await fs.writeFile(`${this.file}.tmp`, this.safeStorage.encryptString(JSON.stringify(this.memory)), {mode: 0o600});
      await fs.rename(`${this.file}.tmp`, this.file);
    } catch {
      // An unavailable system keyring permits memory-only connection, never plaintext.
      this.writeFailed = true;
      await fs.rm(this.file, {force: true}).catch(() => {});
      await fs.rm(`${this.file}.tmp`, {force: true}).catch(() => {});
    }
  }); }
  clear() { return this.serial(async () => {
    this.memory = null; this.loaded = true;
    await fs.rm(this.file, {force: true}); await fs.rm(`${this.file}.tmp`, {force: true});
  }); }
}

function validateCommunityGrant(data) {
  if (!data || data.purpose !== 'community' || !/^[0-9a-f]{64}$/.test(data.deviceCode) ||
      !/^[A-Z0-9]{6}-[A-Z0-9]{6}$/.test(data.userCode) ||
      !Number.isFinite(data.expiresIn) || data.expiresIn < 30 || data.expiresIn > 900 ||
      !Number.isFinite(data.interval) || data.interval < 1 || data.interval > 30) throw new Error('Invalid community grant.');
  const url = new URL(data.verificationUriComplete);
  if (url.origin !== SITE_ORIGIN || url.username || url.password || url.hash || url.pathname !== '/account' ||
      url.searchParams.get('code') !== data.userCode || url.searchParams.get('purpose') !== 'community' ||
      [...url.searchParams.keys()].length !== 2 || [...url.searchParams.keys()].some(key => !['code', 'purpose'].includes(key))) {
    throw new Error('Invalid community approval link.');
  }
  return {deviceCode: data.deviceCode, userCode: data.userCode, expiresIn: data.expiresIn,
    interval: data.interval, verificationUriComplete: url.href};
}

class CommunityClient {
  constructor({vault, isPackaged = () => false, fetchImpl = fetch, openExternal, onChanged = () => {},
    now = Date.now, setTimer = setTimeout, clearTimer = clearTimeout}) {
    Object.assign(this, {vault, isPackaged, fetchImpl, openExternal, onChanged, now, setTimer, clearTimer});
    this.state = {state: 'idle'}; this.epoch = 0; this.pairing = null; this.timer = null;
    this.abort = null; this.storageQueue = Promise.resolve(); this.disposed = false;
  }
  storage(action) { const result = this.storageQueue.then(action); this.storageQueue = result.catch(() => {}); return result; }
  snapshot() {
    const result = {state: this.state.state};
    // Explicit projection: no response body, credential, deviceCode or URL crosses IPC.
    for (const key of ['error', 'requiresReconnect']) if (this.state[key] !== undefined) result[key] = this.state[key];
    if (this.pairing && this.state.state === 'awaitingApproval') {
      result.userCode = this.pairing.userCode; result.expiresIn = Math.max(0, Math.ceil((this.pairing.expiresAt - this.now()) / 1000));
    }
    return result;
  }
  status() { return Promise.resolve(this.snapshot()); }
  change(state, fields = {}) { this.state = {state, ...fields}; this.onChanged(this.snapshot()); return this.snapshot(); }
  allowed() {
    if (!this.disposed && this.isPackaged()) return true;
    this.change('error', {error: 'Community confirmation is available in the installed Focus Studio desktop app.', requiresReconnect: false});
    return false;
  }
  active() { return ['connecting', 'awaitingApproval', 'confirming'].includes(this.state.state); }
  current(epoch) { return !this.disposed && epoch === this.epoch; }
  invalidate() {
    this.epoch++; this.abort?.abort(); this.abort = new AbortController();
    this.clearTimer(this.timer); this.timer = null; this.pairing = null;
    return this.epoch;
  }
  async http(endpoint, body, token, signal) {
    try {
      const response = await this.fetchImpl(`${SITE_ORIGIN}${endpoint}`, {method: 'POST', redirect: 'error',
        headers: {Accept: 'application/json', 'Content-Type': 'application/json', ...(token ? {Authorization: `Bearer ${token}`} : {})},
        body: JSON.stringify(body), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000)});
      if (!response.headers.get('content-type')?.includes('application/json')) throw new Error('Invalid response.');
      const text = await response.text();
      if (text.length > 128 * 1024) throw new Error('Response too large.');
      return {status: response.status, body: JSON.parse(text)};
    } catch { return {status: 503, body: null}; }
  }
  revoke(value) {
    if (value?.purpose === 'community' && TOKEN_PATTERN.test(value.accessToken)) {
      void this.http('/api/device/revoke', {}, value.accessToken).catch(() => {});
    }
  }
  async restore() {
    if (!this.isPackaged() || this.disposed) return this.snapshot();
    const epoch = this.epoch;
    try {
      const value = await this.storage(() => this.vault.get());
      if (this.current(epoch) && validCredential(value, this.now())) return this.retry();
    } catch { if (this.current(epoch)) this.change('error', {error: 'Could not read the saved community connection.', requiresReconnect: true}); }
    return this.snapshot();
  }
  async start() {
    if (!this.allowed() || this.active() || this.state.state === 'confirmed') return this.snapshot();
    const epoch = this.invalidate(); this.change('connecting');
    try {
      const previous = await this.storage(async () => { const value = await this.vault.get(); await this.vault.clear(); return value; });
      this.revoke(previous);
      if (!this.current(epoch)) return this.snapshot();
      const response = await this.http('/api/device/start', {purpose: 'community'}, undefined, this.abort.signal);
      if (!this.current(epoch)) return this.snapshot();
      if (response.status !== 200) throw new Error('grant');
      const grant = validateCommunityGrant(response.body);
      this.pairing = {...grant, expiresAt: this.now() + grant.expiresIn * 1000};
      await this.openExternal(grant.verificationUriComplete);
      if (!this.current(epoch)) return this.snapshot();
      this.change('awaitingApproval'); this.schedule(epoch);
    } catch {
      if (this.current(epoch)) { this.pairing = null; this.change('error', {error: 'Could not open a community connection. Please try again.', requiresReconnect: true}); }
    }
    return this.snapshot();
  }
  schedule(epoch) {
    if (!this.current(epoch) || !this.pairing) return;
    this.clearTimer(this.timer);
    const delay = Math.min(Math.max(5, this.pairing.interval) * 1000, Math.max(0, this.pairing.expiresAt - this.now()));
    this.timer = this.setTimer(() => { void this.poll(epoch); }, delay); this.timer?.unref?.();
  }
  async poll(epoch) {
    const pair = this.pairing;
    if (!this.current(epoch) || !pair) return;
    if (pair.expiresAt <= this.now()) { this.pairing = null; this.change('error', {error: 'The approval code expired. Connect again for a new code.', requiresReconnect: true}); return; }
    const response = await this.http('/api/device/token', {deviceCode: pair.deviceCode}, undefined, this.abort.signal);
    const data = response.body;
    const value = response.status === 200 && data?.purpose === 'community' && data.tokenType === 'Bearer' &&
      TOKEN_PATTERN.test(data.accessToken) && Number.isFinite(data.expiresIn) && data.expiresIn > 0 && data.expiresIn <= 31 * 86400
      ? {purpose: 'community', accessToken: data.accessToken, expiresAt: this.now() + data.expiresIn * 1000} : null;
    if (!this.current(epoch)) { this.revoke(value); return; }
    if (pair.expiresAt <= this.now()) {
      this.revoke(value); this.pairing = null;
      this.change('error', {error: 'The approval code expired. Connect again for a new code.', requiresReconnect: true}); return;
    }
    if (value) {
      this.pairing = null; this.change('confirming');
      try {
        await this.storage(async () => { if (this.current(epoch)) await this.vault.set(value); });
        if (this.current(epoch)) await this.activate(value, epoch);
        else this.revoke(value);
      } catch {
        this.revoke(value);
        if (this.current(epoch)) this.change('error', {error: 'Could not save the community connection. Please reconnect.', requiresReconnect: true});
      }
    } else if ((response.status === 202 && data?.status === 'authorization_pending') || response.status === 429 || response.status >= 500) {
      this.schedule(epoch);
    } else {
      this.pairing = null;
      this.change('error', {error: 'The community connection was not approved or has expired. Please reconnect.', requiresReconnect: true});
    }
  }
  async activate(value, epoch) {
    const response = await this.http('/api/device/activate', {}, value.accessToken, this.abort.signal);
    if (!this.current(epoch)) return this.snapshot();
    if (response.status === 200 && response.body?.confirmed === true) return this.change('confirmed');
    const reconnect = [400, 401, 403, 410].includes(response.status);
    if (reconnect) await this.storage(async () => { if (this.current(epoch)) await this.vault.clear(); });
    if (this.current(epoch)) this.change('error', {error: reconnect
      ? 'This community connection has expired or is invalid. Please reconnect.'
      : 'Community confirmation has not completed. Check your connection and retry.', requiresReconnect: reconnect});
    return this.snapshot();
  }
  async retry() {
    if (!this.allowed() || this.active()) return this.snapshot();
    const epoch = this.invalidate(); this.change('confirming');
    try {
      const value = await this.storage(() => this.vault.get());
      if (!this.current(epoch)) return this.snapshot();
      if (!validCredential(value, this.now())) return this.change('error', {error: 'Connect to the community first.', requiresReconnect: true});
      return await this.activate(value, epoch);
    } catch {
      if (this.current(epoch)) this.change('error', {error: 'Could not read the saved community connection. Please reconnect.', requiresReconnect: true});
      return this.snapshot();
    }
  }
  async disconnect() {
    const epoch = this.invalidate(); this.change('idle');
    try {
      const value = await this.storage(async () => { const previous = await this.vault.get(); await this.vault.clear(); return previous; });
      this.revoke(value);
    } catch { if (this.current(epoch)) this.change('error', {error: 'Could not remove the saved community connection. Please try again.', requiresReconnect: true}); }
    return this.snapshot();
  }
  cancel() { return this.disconnect(); }
  dispose() { this.invalidate(); this.disposed = true; }
}

module.exports = {CommunityClient, CommunityVault, validateCommunityGrant};
