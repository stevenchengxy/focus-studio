'use strict';
const {SITE_ORIGIN, TOKEN_PATTERN, requestSpec, validatePairing} = require('./policy.cjs');

class AccountClient {
  constructor({vault, fetchImpl = fetch, openExternal, onChanged = () => {}, now = Date.now,
    setTimer = setTimeout, clearTimer = clearTimeout}) {
    Object.assign(this, {vault, fetchImpl, openExternal, onChanged, now, setTimer, clearTimer});
    this.pairing = null;
    this.timer = null;
    this.epoch = 0;
    this.starting = null;
  }
  async http(path, method, body, token) {
    try {
      const response = await this.fetchImpl(`${SITE_ORIGIN}${path}`, {
        method, headers: {Accept: 'application/json', ...(body ? {'Content-Type': 'application/json'} : {}),
          ...(token ? {Authorization: `Bearer ${token}`} : {})},
        body: body ? JSON.stringify(body) : undefined, redirect: 'error', signal: AbortSignal.timeout(15000)
      });
      if (!response.headers.get('content-type')?.includes('application/json')) throw new Error('Unexpected server response.');
      const text = await response.text();
      if (text.length > 128 * 1024) throw new Error('Response too large.');
      return {status: response.status, body: JSON.parse(text)};
    } catch {
      return {status: 503, body: {error: {code: 'network_unavailable', message: 'Cannot reach Focus Studio. Check your connection and retry.'}}};
    }
  }
  async request(input) {
    const spec = requestSpec(input);
    const token = await this.vault.get();
    if (!token) return {status: 401, body: {authenticated: false, error: {code: 'sign_in_required', message: 'Connect your account first.'}}};
    const result = await this.http(spec.path, spec.method, spec.body, token);
    if (result.status === 401 && (await this.vault.get()) === token) { await this.vault.clear(); this.onChanged(); }
    return result;
  }
  async startSignIn() {
    if (this.starting) return this.starting;
    if (this.pairing && this.pairing.expiresAt > this.now()) return this.publicPairing();
    this.starting = this.beginSignIn();
    try { return await this.starting; } finally { this.starting = null; }
  }
  publicPairing() { return {userCode: this.pairing.userCode, expiresIn: Math.max(0, Math.floor((this.pairing.expiresAt - this.now()) / 1000))}; }
  async beginSignIn() {
    const epoch = ++this.epoch;
    const result = await this.http('/api/device/start', 'POST', {});
    if (result.status !== 200) throw new Error(result.body.error?.message ?? 'Pairing could not start.');
    const data = validatePairing(result.body);
    if (epoch !== this.epoch) throw new Error('Pairing cancelled.');
    this.pairing = {...data, expiresAt: this.now() + data.expiresIn * 1000};
    try { await this.openExternal(data.verificationUriComplete); }
    catch { this.pairing = null; throw new Error('Open your system browser and try connecting again.'); }
    this.schedulePoll(epoch);
    return this.publicPairing();
  }
  schedulePoll(epoch) {
    if (!this.pairing || epoch !== this.epoch) return;
    this.clearTimer(this.timer);
    this.timer = this.setTimer(() => { void this.poll(epoch); }, Math.max(5, this.pairing.interval) * 1000);
    this.timer?.unref?.();
  }
  async poll(epoch) {
    const pair = this.pairing;
    if (!pair || epoch !== this.epoch) return;
    if (pair.expiresAt <= this.now()) { this.pairing = null; this.onChanged(); return; }
    const result = await this.http('/api/device/token', 'POST', {deviceCode: pair.deviceCode});
    if (epoch !== this.epoch) return;
    if (result.status === 200 && TOKEN_PATTERN.test(result.body.accessToken)) {
      await this.vault.set(result.body.accessToken);
      // A logout may occur while secure storage is awaiting the OS keyring.
      if (epoch !== this.epoch) { await this.vault.clear(); return; }
      this.pairing = null; this.onChanged(); return;
    }
    if ([400, 401, 403, 410].includes(result.status)) { this.pairing = null; this.onChanged(); return; }
    this.schedulePoll(epoch);
  }
  async signOut() {
    this.epoch++; this.pairing = null; this.clearTimer(this.timer);
    const token = await this.vault.get();
    await this.vault.clear(); this.onChanged();
    if (token) await this.http('/api/device/revoke', 'POST', {}, token);
  }
  dispose() { this.epoch++; this.clearTimer(this.timer); this.pairing = null; }
}
module.exports = {AccountClient};
