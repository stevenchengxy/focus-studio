'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const {TOKEN_PATTERN} = require('./policy.cjs');

class TokenVault {
  constructor({directory, safeStorage, platform = process.platform}) {
    this.file = path.join(directory, 'account-token.enc');
    this.safeStorage = safeStorage;
    this.platform = platform;
    this.memory = null;
    this.loaded = false;
    this.queue = Promise.resolve();
    this.writeFailed = false;
  }
  durable() {
    return !this.writeFailed && this.safeStorage.isEncryptionAvailable() && (this.platform !== 'linux' ||
      ['gnome_libsecret', 'kwallet', 'kwallet5', 'kwallet6'].includes(this.safeStorage.getSelectedStorageBackend()));
  }
  serial(action) {
    const result = this.queue.then(action);
    this.queue = result.catch(() => {});
    return result;
  }
  get() { return this.serial(() => this.read()); }
  async read() {
    if (this.loaded) return this.memory;
    this.loaded = true;
    if (!this.durable()) return null;
    try {
      const stat = await fs.stat(this.file);
      if (stat.size > 4096) return null;
      const token = this.safeStorage.decryptString(await fs.readFile(this.file));
      this.memory = TOKEN_PATTERN.test(token) ? token : null;
    } catch { this.memory = null; }
    return this.memory;
  }
  set(token) { return this.serial(() => this.write(token)); }
  async write(token) {
    if (!TOKEN_PATTERN.test(token)) throw new Error('Invalid account token.');
    this.memory = token; this.loaded = true;
    try {
      if (!this.durable()) { await fs.rm(this.file, {force: true}); return; }
      await fs.mkdir(path.dirname(this.file), {recursive: true, mode: 0o700});
      const encrypted = this.safeStorage.encryptString(token);
      await fs.writeFile(`${this.file}.tmp`, encrypted, {mode: 0o600});
      await fs.rename(`${this.file}.tmp`, this.file);
    } catch {
      this.writeFailed = true;
      // An unavailable keyring or read-only profile may use this login in memory;
      // never downgrade to plaintext persistence.
      await fs.rm(this.file, {force: true}).catch(() => {});
      await fs.rm(`${this.file}.tmp`, {force: true}).catch(() => {});
    }
  }
  clear() { return this.serial(async () => {
    this.memory = null; this.loaded = true;
    await fs.rm(this.file, {force: true});
    await fs.rm(`${this.file}.tmp`, {force: true});
  }); }
}
module.exports = {TokenVault};
