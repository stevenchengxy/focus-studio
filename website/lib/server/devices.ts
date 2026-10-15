import { APIError, nowSeconds, randomSecret, sha256 } from './primitives';
const TTL = 600;
export type DevicePurpose = 'account' | 'community';
export function devicePurpose(value: unknown): DevicePurpose {
  if (value === undefined || value === 'account') return 'account';
  if (value === 'community') return 'community';
  throw new APIError(400, 'invalid_device_purpose', 'Choose a valid device connection purpose.');
}
function normalizedUserCode(code: string) {
  const normalized = code.replace('-', '').toUpperCase();
  if (!/^[A-F0-9]{12}$/.test(normalized)) throw new APIError(400, 'invalid_code', 'Check the code displayed in Focus Studio.');
  return normalized;
}
export async function createDeviceGrant(db: D1Database, origin: string, now = nowSeconds(), purpose: DevicePurpose = 'account') {
  purpose = devicePurpose(purpose);
  const deviceCode = randomSecret(); const hash = await sha256(deviceCode);
  // Twelve hex digits = 48 bits. The displayed hyphen is removed on approval.
  const userCode = randomSecret().slice(0, 12).toUpperCase();
  await db.batch([
    db.prepare('DELETE FROM device_grants WHERE expires_at<=?').bind(now),
    db.prepare(`INSERT INTO device_grants(hash,user_code,name,purpose,expires_at,created_at) SELECT ?,?,'Focus Studio',?,?,? WHERE (SELECT COUNT(*) FROM device_grants)<1000`).bind(hash, userCode, purpose, now + TTL, now),
  ]);
  if (!await db.prepare('SELECT hash FROM device_grants WHERE hash=?').bind(hash).first()) throw new APIError(429, 'pairing_busy', 'Please try connecting your device again shortly.');
  const shownCode = `${userCode.slice(0, 6)}-${userCode.slice(6)}`;
  const suffix = purpose === 'community' ? '&purpose=community' : '';
  return { deviceCode, userCode: shownCode, verificationUri: `${origin}/account`, verificationUriComplete: `${origin}/account?code=${shownCode}${suffix}`, expiresIn: TTL, interval: 5, purpose };
}
/** Resolve the purpose from the unconsumed grant, never a browser form field. */
export async function getDeviceGrantPurpose(db: D1Database, code: string, now = nowSeconds()): Promise<DevicePurpose> {
  const grant = await db.prepare('SELECT purpose FROM device_grants WHERE user_code=? AND account_id IS NULL AND expires_at>?')
    .bind(normalizedUserCode(code), now).first<{purpose: DevicePurpose}>();
  if (!grant || (grant.purpose !== 'account' && grant.purpose !== 'community')) throw new APIError(409, 'code_unavailable', 'This connection code has expired or has already been approved.');
  return grant.purpose;
}
export async function approveDevice(db: D1Database, accountId: string, code: string, name: string, now = nowSeconds(), purpose: DevicePurpose = 'account') {
  const normalized = normalizedUserCode(code);
  const result = await db.prepare(`UPDATE device_grants SET account_id=?,name=? WHERE user_code=? AND purpose=? AND account_id IS NULL AND expires_at>? RETURNING hash`).bind(accountId, name, normalized, purpose, now).first();
  if (!result) throw new APIError(409, 'code_unavailable', 'This connection code has expired or has already been approved.');
  return { approved: true };
}
export async function exchangeDeviceGrant(db: D1Database, deviceCode: string, now = nowSeconds()) {
  if (!/^[a-f0-9]{64}$/.test(deviceCode)) throw new APIError(400, 'invalid_code', 'Invalid connection code.');
  const hash = await sha256(deviceCode);
  const grant = await db.prepare('SELECT * FROM device_grants WHERE hash=? AND expires_at>?').bind(hash, now).first<{account_id:string|null;name:string;created_at:number;purpose:DevicePurpose}>();
  if (!grant) throw new APIError(410, 'code_expired', 'This connection code has expired.');
  if (!grant.account_id) return null;
  if (grant.purpose !== 'account' && grant.purpose !== 'community') throw new APIError(410, 'code_expired', 'This connection code has expired.');
  // Derive an unguessable token from the 256-bit device secret. The database holds
  // only its hash, and retries can recover the identical token if a response is lost.
  const accessToken = `fs_${await sha256(`focus-studio-device-v1:${deviceCode}`)}`;
  const tokenHash = await sha256(accessToken);
  const expiresAt = grant.created_at + 30 * 86400;
  await db.prepare(`INSERT OR IGNORE INTO device_tokens(id,hash,account_id,name,purpose,expires_at,created_at) VALUES(?,?,?,?,?,?,?)`).bind(crypto.randomUUID(), tokenHash, grant.account_id, grant.name, grant.purpose, expiresAt, now).run();
  const token = await db.prepare('SELECT revoked_at,purpose FROM device_tokens WHERE hash=?').bind(tokenHash).first<{revoked_at:number|null;purpose:DevicePurpose}>();
  if (!token || token.revoked_at !== null || token.purpose !== grant.purpose) throw new APIError(410, 'device_revoked', 'This device connection has been revoked.');
  return { accessToken, tokenType: 'Bearer', expiresIn: expiresAt - now, purpose: grant.purpose };
}
