import { APIError, nowSeconds } from './primitives';
import { freeExportEntitlement } from '../product-access';

export interface ExportJob { id: string; account_id: string; idempotency_key: string; project_id: string; mode: 'trial' | 'subscription' | 'free'; status: 'reserved' | 'committed' | 'released' | 'expired'; expires_at: number }
const LEASE_SECONDS = 7200;
export function exportResponse(job: ExportJob) { return { exportId: job.id, status: job.status, mode: job.mode, expiresAt: job.expires_at }; }
export async function entitlement(db: D1Database, accountId: string, now = nowSeconds()) {
  // Preserve existing billing records for account history; they no longer gate exports.
  const subscription = await db.prepare(`SELECT plan,status,current_period_end FROM subscriptions WHERE account_id=? ORDER BY CASE WHEN status='active' AND current_period_end>? THEN 0 ELSE 1 END,updated_at DESC LIMIT 1`).bind(accountId, now).first<{plan:string;status:string;current_period_end:number}>();
  return { ...freeExportEntitlement(), subscriptionStatus: subscription?.status ?? 'none', currentPeriodEnd: subscription?.current_period_end ?? null };
}
export async function reserveExport(db: D1Database, accountId: string, key: string, projectId: string, now = nowSeconds()) {
  // Compatibility receipts for older installed apps. New desktop exports are local
  // and never call this endpoint. 'free' avoids the historical one-trial index.
  const id = crypto.randomUUID();
  await db.prepare(`INSERT OR IGNORE INTO export_jobs(id,account_id,idempotency_key,project_id,mode,status,expires_at,created_at) VALUES(?,?,?,?,'free','reserved',?,?)`).bind(id, accountId, key, projectId, now + LEASE_SECONDS, now).run();
  const job = await db.prepare(`SELECT * FROM export_jobs WHERE account_id=? AND idempotency_key=?`).bind(accountId, key).first<ExportJob>();
  if (!job) throw new APIError(503, 'export_unavailable', 'Could not prepare the export. Please retry.');
  if (job.project_id !== projectId) throw new APIError(409, 'idempotency_conflict', 'Use a new export identifier for another project.');
  return exportResponse(job);
}
export async function updateExport(db: D1Database, accountId: string, id: string, action: string, now = nowSeconds()) {
  if (!['commit', 'release', 'renew'].includes(action)) throw new APIError(404, 'not_found', 'Unknown export action.');
  if (action === 'commit') {
    // An old lease or subscription expiry must not strand an already-rendered video.
    // Migrate old trial mode before commit to avoid its historical unique index.
    await db.prepare(`UPDATE export_jobs SET status='committed',mode='free',completed_at=? WHERE id=? AND account_id=? AND status IN ('reserved','expired')`).bind(now, id, accountId).run();
  } else if (action === 'release') {
    await db.prepare(`UPDATE export_jobs SET status='released' WHERE id=? AND account_id=? AND status IN ('reserved','expired')`).bind(id, accountId).run();
  } else {
    await db.prepare(`UPDATE export_jobs SET status='reserved',mode='free',expires_at=? WHERE id=? AND account_id=? AND status IN ('reserved','expired')`).bind(now + LEASE_SECONDS, id, accountId).run();
  }
  const job = await db.prepare(`SELECT * FROM export_jobs WHERE id=? AND account_id=?`).bind(id, accountId).first<ExportJob>();
  if (!job) throw new APIError(404, 'export_not_found', 'Export not found.');
  if (action === 'commit' && job.status !== 'committed') throw new APIError(409, 'export_released', 'This export was discarded. Start a new export.');
  if (action === 'renew' && job.status !== 'reserved') throw new APIError(409, 'export_closed', 'This export has already finished.');
  return exportResponse(job);
}
