import { APIError, nowSeconds } from './primitives';

export interface ExportJob { id: string; account_id: string; idempotency_key: string; project_id: string; mode: 'trial' | 'subscription'; status: 'reserved' | 'committed' | 'released' | 'expired'; expires_at: number }
const LEASE_SECONDS = 7200;
const paidSQL = `EXISTS(SELECT 1 FROM subscriptions WHERE account_id=? AND status='active' AND current_period_end>?)`;
export function exportResponse(job: ExportJob) { return { exportId: job.id, status: job.status, mode: job.mode, expiresAt: job.expires_at }; }
export async function entitlement(db: D1Database, accountId: string, now = nowSeconds()) {
  const subscription = await db.prepare(`SELECT plan,status,current_period_end FROM subscriptions WHERE account_id=? ORDER BY CASE WHEN status='active' AND current_period_end>? THEN 0 ELSE 1 END,updated_at DESC LIMIT 1`).bind(accountId, now).first<{plan:string;status:string;current_period_end:number}>();
  const consumed = await db.prepare(`SELECT id FROM export_jobs WHERE account_id=? AND mode='trial' AND status='committed' LIMIT 1`).bind(accountId).first();
  const reserved = await db.prepare(`SELECT id FROM export_jobs WHERE account_id=? AND mode='trial' AND status='reserved' AND expires_at>? LIMIT 1`).bind(accountId, now).first<{id:string}>();
  const paid = subscription?.status === 'active' && subscription.current_period_end > now;
  return { plan: paid ? subscription.plan : 'free', subscriptionStatus: subscription?.status ?? 'none', currentPeriodEnd: subscription?.current_period_end ?? null, canExport: !!paid || (!consumed && !reserved), freeExportsRemaining: consumed ? 0 : 1, activeExportId: reserved?.id ?? null };
}
export async function reserveExport(db: D1Database, accountId: string, key: string, projectId: string, now = nowSeconds()) {
  const id = crypto.randomUUID();
  // D1 batch is a transaction. The partial unique index is the ultimate concurrency
  // guard: one reserved OR committed free export for the entire account.
  await db.batch([
    db.prepare(`UPDATE export_jobs SET status='expired' WHERE account_id=? AND status='reserved' AND expires_at<=?`).bind(accountId, now),
    db.prepare(`INSERT OR IGNORE INTO export_jobs(id,account_id,idempotency_key,project_id,mode,status,expires_at,created_at)
      SELECT ?,?,?,?,CASE WHEN ${paidSQL} THEN 'subscription' ELSE 'trial' END,'reserved',?,?`).bind(id, accountId, key, projectId, accountId, now, now + LEASE_SECONDS, now),
  ]);
  const job = await db.prepare(`SELECT * FROM export_jobs WHERE account_id=? AND idempotency_key=?`).bind(accountId, key).first<ExportJob>();
  if (job) {
    if (job.project_id !== projectId) throw new APIError(409, 'idempotency_conflict', 'Use a new export identifier for another project.');
    return exportResponse(job);
  }
  const state = await entitlement(db, accountId, now);
  if (state.activeExportId) throw new APIError(409, 'export_in_progress', 'Your free export is already in progress on another device.');
  throw new APIError(402, 'subscription_required', 'Your free export has been used. Choose a plan to keep exporting.');
}
export async function updateExport(db: D1Database, accountId: string, id: string, action: string, now = nowSeconds()) {
  if (!['commit', 'release', 'renew'].includes(action)) throw new APIError(404, 'not_found', 'Unknown export action.');
  await db.prepare(`UPDATE export_jobs SET status='expired' WHERE id=? AND account_id=? AND status='reserved' AND expires_at<=?`).bind(id, accountId, now).run();
  if (action === 'commit') {
    await db.prepare(`UPDATE export_jobs SET status='committed',completed_at=? WHERE id=? AND account_id=? AND status='reserved' AND expires_at>? AND (mode='trial' OR ${paidSQL})`).bind(now, id, accountId, now, accountId, now).run();
  } else if (action === 'release') {
    await db.prepare(`UPDATE export_jobs SET status='released' WHERE id=? AND account_id=? AND status='reserved'`).bind(id, accountId).run();
  } else {
    await db.prepare(`UPDATE export_jobs SET expires_at=? WHERE id=? AND account_id=? AND status='reserved' AND expires_at>? AND (mode='trial' OR ${paidSQL})`).bind(now + LEASE_SECONDS, id, accountId, now, accountId, now).run();
  }
  const job = await db.prepare(`SELECT * FROM export_jobs WHERE id=? AND account_id=?`).bind(id, accountId).first<ExportJob>();
  if (!job) throw new APIError(404, 'export_not_found', 'Export not found.');
  if (action === 'commit' && job.status === 'reserved') throw new APIError(402, 'subscription_required', 'Your subscription is no longer active.');
  if (action === 'commit' && job.status !== 'committed') throw new APIError(409, 'export_lease_expired', 'This export reservation ended. Start a new export.');
  if (action === 'renew' && (job.status !== 'reserved' || job.expires_at !== now + LEASE_SECONDS)) throw new APIError(409, 'export_lease_expired', 'This export reservation cannot be renewed.');
  // Releasing a committed export deliberately never refunds the consumed trial.
  return exportResponse(job);
}
