import { APIError, nowSeconds, sha256 } from './primitives';

async function communityDeviceHash(authorization: string | null) {
  if (!authorization || !/^Bearer fs_[a-f0-9]{64}$/.test(authorization)) {
    throw new APIError(401, 'community_device_required', 'Connect Focus Studio to your ChatGPT account to continue.');
  }
  return sha256(authorization.slice(7));
}

/** Read only the identity bound to a live community-purpose device credential.
 * Browser identities, cookies and caller-supplied owner IDs never select it. */
export async function getCommunityClientSession(db: D1Database, authorization: string | null, now = nowSeconds()) {
  const hash = await communityDeviceHash(authorization);
  const session = await db.prepare(`SELECT a.id,a.email,p.display_name,t.expires_at,c.owner_id AS confirmed_owner_id
    FROM device_tokens t JOIN accounts a ON a.id=t.account_id
    LEFT JOIN community_profiles p ON p.owner_id=a.id
    LEFT JOIN community_client_activations c ON c.owner_id=a.id
    WHERE t.hash=? AND t.purpose='community' AND t.revoked_at IS NULL AND t.expires_at>?`)
    .bind(hash, now).first<{id:string;email:string;display_name:string|null;expires_at:number;confirmed_owner_id:string|null}>();
  if (!session) throw new APIError(401, 'community_device_required', 'This community device connection is invalid or expired. Reconnect Focus Studio.');
  return {
    purpose: 'community' as const,
    account: { id: session.id, email: session.email, displayName: session.display_name },
    clientConfirmed: session.confirmed_owner_id !== null,
    expiresAt: session.expires_at,
  };
}

/** A completed client pairing survives token expiry/revocation. This records a
 * client callback, not binary attestation or proof of an official installation. */
export async function hasCommunityClientActivation(db: D1Database, ownerId: string) {
  return !!await db.prepare('SELECT owner_id FROM community_client_activations WHERE owner_id=?').bind(ownerId).first();
}
export async function activateCommunityClient(db: D1Database, authorization: string | null, now = nowSeconds()) {
  const hash = await communityDeviceHash(authorization);
  // Validate the purpose, lifetime and revocation in the same SQL statement as
  // the permanent confirmation. Browser cookies and supplied owner IDs never
  // select the account. Retrying keeps the first confirmation/device unchanged.
  const confirmed = await db.prepare(`INSERT INTO community_client_activations(owner_id,confirmed_at,device_id)
    SELECT account_id,?,id FROM device_tokens WHERE hash=? AND purpose='community' AND revoked_at IS NULL AND expires_at>?
    ON CONFLICT(owner_id) DO UPDATE SET owner_id=excluded.owner_id RETURNING owner_id`)
    .bind(now, hash, now).first();
  if (!confirmed) throw new APIError(401, 'community_device_required', 'This community device connection is invalid or expired. Reconnect Focus Studio.');
  return { confirmed: true };
}
