/** Product access policy. Third-party AI provider charges and approval are separate. */
export const PRODUCT_ACCESS = Object.freeze({
  mode: 'free' as const,
  paymentsEnabled: false,
  exportsRequireAccount: false,
});

export function freeExportEntitlement() {
  return {
    plan: 'free', accessMode: PRODUCT_ACCESS.mode, canExport: true,
    // Legacy native clients decode this as an integer. New clients use exportLimit.
    freeExportsRemaining: 2_147_483_647, exportLimit: null, activeExportId: null,
  };
}
