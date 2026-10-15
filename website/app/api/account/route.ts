import { googleConfigured } from '@/lib/server/google-auth';
import { api, authenticate, billingConfigured, database, json, settings } from '@/lib/server/runtime';
import { APIError, nowSeconds } from '@/lib/server/primitives';
import { entitlement } from '@/lib/server/exports';
import { PRODUCT_ACCESS, freeExportEntitlement } from '@/lib/product-access';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) { return api(async () => {
  try {
    const account = await authenticate(request);
    const devices = await database().prepare(`SELECT id,name,created_at,expires_at FROM device_tokens WHERE account_id=? AND revoked_at IS NULL AND expires_at>? ORDER BY created_at DESC`).bind(account.id, nowSeconds()).all();
    return json({ authenticated: true, accessMode: PRODUCT_ACCESS.mode, exportsRequireAccount: PRODUCT_ACCESS.exportsRequireAccount, account: {id:account.id,email:account.email}, entitlement: await entitlement(database(), account.id), billingConfigured: billingConfigured(), googleConfigured:googleConfigured(settings()), devices: devices.results });
  } catch (error) {
    if (error instanceof APIError && error.status === 401 && !request.headers.get('authorization')) return json({authenticated:false, accessMode: PRODUCT_ACCESS.mode, exportsRequireAccount: PRODUCT_ACCESS.exportsRequireAccount, entitlement: {...freeExportEntitlement(), subscriptionStatus: "none", currentPeriodEnd: null}, billingConfigured:billingConfigured(),googleConfigured:googleConfigured(settings())}, 401);
    throw error;
  }
}); }
