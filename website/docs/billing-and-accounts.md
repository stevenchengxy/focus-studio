# Current access policy

As of 1.14.4, Focus Studio creation and export are free. Native exports run locally without account/network authorization. New Stripe checkout and portal creation are paused even if credentials are configured. Historical billing data is retained. The sections below describe the retained subscription implementation for a possible future explicit reactivation, not current user-facing policy. See `community.md` for ChatGPT community identity and sharing.

# Accounts, subscriptions and export entitlement

This website preserves the Sites trusted ChatGPT identity integration and includes an optional Google OpenID Connect adapter requested for this product. It uses a D1 database, Stripe Checkout and customer portal. No card details are handled by Focus Studio. Sites identity headers must **only** be trusted behind the Sites identity proxy. Do not expose this Worker directly on an untrusted host.

## What is implemented

- One free **successful** export per signed-in account, shared between browser and paired desktop devices.
- A failed or canceled render releases its reservation. A crash automatically releases after a two-hour lease. Active renders renew their leases. Only a successful `commit` consumes the allowance; release never refunds a committed job.
- D1 transactional reservation and a partial unique index prevent two devices reserving the same free export. Idempotency keys identify render jobs and make network retries safe.
- A paid subscription is $29 USD each month, or $108 USD each year (equivalent to $9/month). Yearly is a single annual charge. Stripe recurring prices are verified server-side against these exact amounts/intervals.
- Five-minute timestamp tolerance, HMAC-SHA256 signature verification, event-ID deduplication and canonical customer subscription retrieval for webhooks. Synchronization generations prevent stale in-flight responses overwriting newer state.
- Explicit desktop device approval, 10-minute pairing codes, 30-day bearer tokens, hashed token storage and account-side revocation. Tokens belong in the desktop OS credential store.
- Browser writes enforce same origin and JSON; native writes require valid bearer credentials. Client-supplied account IDs, prices, return URLs and plan entitlements are never trusted.

This is account entitlement enforcement in the supported application, not tamper-proof DRM for a user-controlled open-source client. Modified clients can bypass local output gates. An account can claim one trial; preventing multiple-account abuse is a separate product policy.

## Deployment setup

1. Set `.openai/hosting.json` `d1` to `DB`. Keep generated `drizzle` migration SQL and metadata in source. Sites applies schema migrations on deployment. Local previews require the starter's local D1 migrations too.
2. Publish the website with public access, so the landing page and signed Stripe webhooks are reachable. Account pages still require user identity for every protected API call.
3. Set the public `SITE_ORIGIN` using the Sites environment controls (for this deployment: `https://focus-studio.stevenchengxy19.chatgpt.site`). Set `MAC_DOWNLOAD_URL` only after a real, tested release exists; unset means download is unavailable. Demo media defaults to `/media/focus-studio-demo.mp4` and `.jpg`.
4. In the merchant's Stripe account, create two active USD recurring Prices for the same product: `2900` cents every month, and `10800` cents every year. Do not create introductory recurring trial days. Enable the customer portal for cancellation, invoice history and payment methods. Do not enable arbitrary portal plan-price switches without validating those prices.
5. Configure **secret** values through Sites environment controls: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_MONTHLY_PRICE_ID`, `STRIPE_YEARLY_PRICE_ID`. Only key names appear in `.env.example`. No credentials belong in source, browser storage, manifests, logs or tool prompts.
6. Add a **snapshot** webhook at `https://<site>/api/billing/webhook` for `customer.subscription.created`, `.updated`, `.deleted`, `.paused`, `.resumed`, `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `invoice.paid`, and `invoice.payment_failed`. Configure the signing secret from that exact endpoint. Use the same Stripe environment for prices, key and endpoint.
7. Complete Stripe **test-mode** Checkout + portal + cancellation + renewal + delayed/duplicate/reordered webhook tests before installing live keys. Configure merchant tax, receipts, cancellation/refund policies and legal/business details in the merchant account and publish the matching policies. No live charges were made during implementation.

Without payment keys the website says subscriptions are not open, disables checkout, and returns an explicit `503 billing_not_configured`. The free account export still works. Never silently grant unlimited exports because the payment service is unavailable.

## Google sign-in setup

The Google button is disabled until all four server settings exist: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `SESSION_SECRET` (at least 32 random characters) and an HTTPS `SITE_ORIGIN`. Configure them through Sites environment controls. Never enter client secrets in a public account form.

In Google Cloud Console, create a **Web application** OAuth client. Register the exact redirect URI `https://focus-studio.stevenchengxy19.chatgpt.site/api/auth/google/callback`. Configure the consent screen with the actual product name, support contact, homepage, privacy and terms URLs. Request only `openid email`. Complete Google's publishing/domain requirements for external production users; until verified, test with the merchant's permitted test accounts. Google may require a verifiable custom domain for brand verification; the free hosted subdomain alone does not prove ownership of its parent domain.

The implementation uses authorization code + PKCE S256, a signed HttpOnly state cookie, a single-use D1 state record, nonce checks and local WebCrypto RS256 validation against Google's HTTPS JWKS. It validates issuer, audience/authorized party, expiration, issuance time, subject and verified email before creating a session. Google sessions use `__Host-` Secure/HttpOnly/SameSite=Lax cookies, HMAC authentication and hashed server-side session records. Session lifetime is 30 days; logout revokes the record. Rotating `SESSION_SECRET` invalidates existing Google cookies.

Google accounts use immutable `google:<sub>` identifiers. They are **not** automatically merged with ChatGPT accounts having the same email; use the same sign-in provider when subscribing and pairing. No OAuth access/refresh token is retained, and no Google API access beyond sign-in is requested.

Missing keys return `503 google_not_configured`. Provider denial, stale state or failed token validation returns to `/account?auth=retry`. A successful real Google login still requires the merchant's OAuth credentials and authorized redirect/domain configuration; mocked tests do not prove those external settings.

Official references: [Google OpenID Connect server flow](https://developers.google.com/identity/openid-connect/openid-connect), [ID token verification](https://developers.google.com/identity/gsi/web/guides/verify-google-id-token).

## Desktop connection

1. App calls `POST /api/device/start` with `{}` and JSON content type. Response provides `deviceCode`, a displayable `userCode`, `verificationUriComplete`, `expiresIn:600`, and `interval:5`.
2. Open `verificationUriComplete` in the system browser. The user signs in with ChatGPT and explicitly approves the matching code.
3. Poll `POST /api/device/token` with `{deviceCode}` every five seconds. `202 authorization_pending` means wait; `200` returns `{accessToken,tokenType:"Bearer",expiresIn}`; `410 code_expired` means start again. Pairing does not automatically approve the device.
4. Keep `accessToken` in Keychain / Credential Manager / Secret Service. Send `Authorization: Bearer <token>` and **no browser Origin**. The server stores SHA-256 hashes only. Retry delivery returns the same token while the code remains valid.
5. `GET /api/account` returns account, entitlement and connected device metadata. Expired/revoked tokens get `401 device_expired`. Users can revoke devices from `/account`. Native sign-out can call `POST /api/device/revoke {}` with its current bearer; this idempotently revokes that token without selecting another device. Offline sign-out should still erase the local credential.

## Export transaction contract

| Request | Body | Success |
| --- | --- | --- |
| `POST /api/exports/reserve` | `{idempotencyKey, projectId}` | `{exportId,status,mode,expiresAt}` |
| `POST /api/exports/{id}/renew` | `{}` | Lease extended for two hours |
| `POST /api/exports/{id}/commit` | `{}` | `status:"committed"`; repeated commit is safe |
| `POST /api/exports/{id}/release` | `{}` | Release uncommitted work; committed jobs stay committed |

Each response uses UNIX seconds. Start a render only when reserve says `reserved`. Use a fresh UUID for each distinct export attempt. If response delivery fails, retry the **same** request/key. Do not render again when reserve returns `committed`.

Render to a temporary file. Renew about every five minutes. On cancellation or render failure, release. After successful finalization, commit **before** making the finished file available. On a transient commit failure retain the temporary output and retry the same commit; do not invent another reservation. If the lease expired, do not publish that output. A desktop crash between commit and final rename must recover the already-authorized temporary output (journal the export ID and destination locally). It must not charge a second trial.

`402 subscription_required` means the trial was consumed or a paid subscription ended. `409 export_in_progress` means another device has reserved the trial. `409 export_lease_expired` means that job cannot be finalized. All errors have `{error:{code,message}}`; secrets and raw provider responses are never returned.

## Validation

Run `node --test tests/backend.test.mjs` with Node 24 and installed dependencies. Tests execute the generated SQL on real SQLite using a D1-compatible transactional adapter; external Stripe requests are mocked. Coverage includes 20 concurrent trial reservations, commit replay, failed/cancel/expired recovery, account isolation, subscription expiry, explicit pairing/revocation, CSRF, payload bounds, signature replay/tampering, advertised price checks, stale in-flight Stripe responses, signed Google cookies, ID-token claim validation, PKCE callbacks, single-use OAuth state and session revocation.

These tests verify application logic. They do not certify production Stripe setup, merchant onboarding, actual payments, edge identity behavior or a real checkout. Run those checks after owner credentials are configured.

Official references: [Stripe webhooks](https://docs.stripe.com/webhooks), [Checkout session creation](https://docs.stripe.com/api/checkout/sessions/create), [Customer portal](https://docs.stripe.com/api/customer_portal/sessions/create).
