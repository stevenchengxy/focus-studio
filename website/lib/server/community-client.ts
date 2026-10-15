import { APIError, nowSeconds, sha256 } from './primitives';

/** A completed client pairing survives token expiry/revocation. This records a
 * client callback, not binary attestation or proof of an official installation. */
export async function hasCommunityClientActivation(db: D1Database, ownerId: string) {
  return !!await db.prepare('SELECT owner_id FROM community_client_activations WHERE owner_id=?').bind(ownerId).first();
}
export async function activateCommunityClient(db: D1Database, authorization: string | null, now = nowSeconds()) {
  if (!authorization || !/^Bearer fs_[a-f0-9]{64}$/.test(authorization)) {
    throw new APIError(401, 'community_device_required', 'Connect Focus Studio to your ChatGPT account before confirming this device.');
  }
  // Validate the purpose, lifetime and revocation in the same SQL statement as
  // the permanent confirmation. Browser cookies and supplied owner IDs never
  // select the account. Retrying keeps the first confirmation/device unchanged.
  const confirmed = await db.prepare(`INSERT INTO community_client_activations(owner_id,confirmed_at,device_id)
    SELECT account_id,?,id FROM device_tokens WHERE hash=? AND purpose='community' AND revoked_at IS NULL AND expires_at>?
    ON CONFLICT(owner_id) DO UPDATE SET owner_id=excluded.owner_id RETURNING owner_id`)
    .bind(now, await sha256(authorization.slice(7)), now).first();
  if (!confirmed) throw new APIError(401, 'community_device_required', 'This community device connection is invalid or expired. Reconnect Focus Studio.');
  return { confirmed: true };
}
