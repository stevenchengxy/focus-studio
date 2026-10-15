# Launch checks — 2026-10-14

This record distinguishes completed checks from remaining launch dependencies. It does **not** certify that all production integrations have been verified.

## Completed

- **Backend:** 15 automated SQLite/WebCrypto regression tests passed (`node --test tests/backend.test.mjs`). These exercise real generated schema/SQL with a D1-compatible adapter and mocked external providers: concurrent trial reservations, successful-commit accounting, cancellation/expiry recovery, account isolation, device pairing/revocation, CSRF and input limits, Stripe signature/price/order handling, and Google token/session validation.
- **Browser Studio, local browser acceptance:** loaded the sample, trimmed to **2–5 seconds**, applied **Spotlight**, and produced a **WebM** export. The first completed export consumed the free trial. Recovery using the **same export receipt** downloaded the completed output without consuming another allowance. A subsequent new export was rejected when no allowance remained.
- **Recovery review:** rendered media is saved locally before commit. Cross-tab operations use Web Locks, reread the journal under the lock, and check export identity before deletion/replacement. Download requires a matching `committed` receipt. Browsers without safe lock support disable export. This includes source review; it is not a claim that every possible crash or multi-tab sequence has been browser-tested.
- **Layout:** the website was checked at **390 px** width with no horizontal overflow. A screenshot of the actual native editor is included; it is not a fabricated product UI.

## Not yet verified or available

- **Stripe:** merchant keys, recurring Price IDs and webhook credentials are not configured. Checkout and production payments have **not** been exercised. Paid-plan controls remain disabled until configured. Advertised pricing is **$29/month** or **$108/year** (equivalent to $9/month, billed annually).
- **Google:** OAuth client credentials, session secret and production consent/domain setup are not configured. Real Google sign-in has **not** been exercised. The optional adapter has mocked cryptographic/flow coverage; the Google button remains disabled until configured. Existing ChatGPT sign-in remains available through Sites.
- **macOS distribution:** the app is **ad-hoc signed and not notarized**. It is not yet a notarized, frictionless public installer; macOS may show security prompts.
- **Windows and Linux:** **Desktop Preview 0.1.0** has Windows x64 NSIS and Linux x64 AppImage/Debian installers. Both platform jobs passed installer builds and Electron smoke checks in [CI run 38441738897](https://github.com/stevenchengxy/focus-studio/actions/runs/38441738897). These apps load the hosted Studio editor; they do not include the native Mac editor or MCP service. Real Windows/Linux capture, audio and install/uninstall acceptance remains pending; see [CROSS-PLATFORM-DESKTOP.md](CROSS-PLATFORM-DESKTOP.md).
- Native preview has a measured short-window main-thread comparison and interaction acceptance in [PREVIEW-PERFORMANCE.md](PREVIEW-PERFORMANCE.md). These results do not establish a guaranteed frame rate across all projects or hardware.

Account, billing and identity configuration instructions are in [billing-and-accounts.md](../website/docs/billing-and-accounts.md). Remaining launch work is tracked in [GitHub issue #28](https://github.com/stevenchengxy/focus-studio/issues/28).
