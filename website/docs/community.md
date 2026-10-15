# Community operations

The public website offers optional sharing. Browsing remains public. Uploading, saving an uploaded draft, editing post content and publishing require ChatGPT sign-in and one completed client confirmation for that same Sites user ID. Creation and export happen in installed Focus Studio; local projects are never uploaded automatically. ChatGPT sign-in uses Sites-provided identity headers. Private drafts are only accessible to their owner, except authorized moderation review of previously reported/held content.

## Client confirmation

The user installs and opens Focus Studio, chooses **Community publishing → Connect ChatGPT**, and approves the displayed code in their browser with the same ChatGPT account they use on the community. The client exchanges the grant and calls the bearer-only activation endpoint. Only a successful activation grants the persistent account-level publishing capability; clicking Download, approving a code without the client callback, browser storage, user-agent strings and ordinary account tokens do not grant it.

Community device grants and tokens have a separate purpose, token storage and API scope. They do not enable billing or gate free local recording, editing or exports. The approval endpoint uses the grant's stored purpose to select ChatGPT identity, so a legacy Google cookie cannot silently bind community confirmation to the wrong account. Token expiry or disconnection does not remove an already completed one-time confirmation.

This verifies completion of device pairing and a client callback. It is not hardware attestation of an official binary: a determined user could implement the public device protocol. No fixed secret is embedded in the client and no claim of tamper-proof installation detection is made.

`/api/community/me` returns `canPublish` and `clientConfirmed`. Server checks apply independently to create, metadata edit, video upload, poster upload and publish routes. Authors can still delete or unpublish their content; reporting, profiles, moderation and public reads retain their existing access rules. Missing confirmation returns `403 community_client_required` before media storage is touched.

## Pages and profiles

- `/community` and `/community/ai` show static cover cards. Selecting a card opens its own `/community/[id]` page; lists never autoplay or load video players.
- The detail page contains the video, creator name, download and optional product introduction/link. A standalone video needs no product introduction.
- `/community/mine` manages private drafts and published work; `/community/new` uploads a new work. The official sample lives separately at `/community/showcase` and is explicitly labeled.
- `/community/profile` saves a public creator name for the signed-in account. GET/PATCH `/api/community/profile` returns `{displayName}`. The D1 `community_profiles` table binds names to trusted Sites owner IDs. Updating a name atomically updates existing work attribution without changing content, publication state or ordering. New work and metadata edits use the saved name. Email addresses are rejected as public names.
- Apply migrations through `0006_slimy_thunderball.sql` before serving this version. Both language and theme controls are shared across community pages.

## Storage and ownership

- Logical bindings: D1 `DB`, R2 `BUCKET` in `.openai/hosting.json`.
- Apply Drizzle migrations through the Sites workflow. Never change applied migration history.
- One file: MP4/WebM, max 100 MiB; optional JPEG poster <=512 KiB.
- One author: max 20 active drafts/posts, 500 MiB reserved video bytes. Draft and upload reservations are atomic; rate limits apply server-side.
- Owner IDs come only from Sites identity, not request bodies or legacy billing cookies/device bearer tokens. Email is not returned in community public records.
- Publish requires explicit CC BY 4.0 rights confirmation. A private draft is not visible in the feed. Public media is served through an authorization-aware range endpoint; bucket objects have no public URL.
- Unpublish blocks subsequent public access; delete removes the uploaded copy. Existing downloaded copies retain their license.

## Moderation

Set the production secret `COMMUNITY_MODERATOR_IDS` to trusted Sites user IDs, separated by commas. `/api/community/me` returns the current authenticated visitor's own viewerId, never another user's. Validate the intended moderator account before setting this value. Empty configuration grants nobody moderation rights.

`/community/moderation` is a compact, separate admin page visible in navigation only to configured moderators. It lists eligible work with search, category and status filters, and opens preview, reports and review history on demand. All API access checks the trusted Sites identity and configured allowlist server-side; hiding navigation is not the authorization boundary. Reporters' IDs and creator ownership IDs are never included in admin responses.

- `GET /api/community/moderation?scope=all|published|reported|held|deleted&q=...&category=demo|ai-video&limit=24&cursor=...` returns `{items,nextCursor,scope}`. `all` includes active public/reported/held work; `deleted` is the separate moderator trash. `published` means currently public. Search treats SQL wildcard characters literally; q is limited to 120 characters and limit to 1–50. Items include reportCount, lastReportAt, deletedAt, moderatedAt, moderatedBy and moderationRevision only in this privileged response.
- `GET /api/community/[id]/moderate` returns `{item,reports,audit}` with the latest 100 reports and latest 100 decisions. Reports contain id/reason/details/createdAt, never reporter identity. Audit events contain id/revision/action/reason/actorId/actorName/createdAt; the actor comes from the signed-in moderator.
- `POST /api/community/[id]/moderate` accepts `{action,reason,expectedRevision?}`. A nonblank reason (up to 500 characters) is required. The UI supplies expectedRevision and the server uses an atomic D1 batch plus monotonically increasing revision to reject stale decisions with 409. Unknown fields/actions fail with 400.
- `hide` adds a moderation hold; public list/detail/media are blocked and the author cannot republish. `reinstate` removes the hold while preserving the author's publication choice.
- `delete` moves eligible work to moderator trash without deleting R2 objects or changing its prior publication/hold state. Public and owner detail/media access stop. Only configured moderators can preview or restore trash. `restore` applies only to moderator trash and restores its previous publication and hold state; a held or author-unpublished work remains held/private.

Every successful decision and its actor/reason/time are committed in one transaction with the visibility change. Review is limited to public, reported, held or moderator-trashed work; unrelated private drafts remain inaccessible. Normal author DELETE retains its existing meaning: remove their upload and its media. That immediately clears the moderator-restorable marker, even if R2 cleanup fails and the author must retry. Successful author deletion cascades reports/audit, so admin restore never overrides an author's deletion. This release provides no moderator purge operation. Trash still counts toward storage quotas.

## Release checks

Run `node --test tests/*.test.mjs` from website, TypeScript, and the Sites build helper. With local dev running and migrations applied, run `node scripts/verify-community-local.mjs`. That test refuses non-loopback hosts and uses random synthetic Sites identities against the built local Worker, including the complete community device confirmation flow. It verifies draft privacy, upload, publish, literal search, media ranges, details edits, unpublish and cleanup against real local HTTP routes. No production sample posts or private recordings are seeded.

For the built Worker moderation HTTP check, run a separate loopback Wrangler preview with a temporary `--var COMMUNITY_MODERATOR_IDS:focus-local-reviewer-<UUID>` (no saved environment change). Set `COMMUNITY_MODERATION_TEST_ORIGIN` to that loopback URL and `COMMUNITY_MODERATION_TEST_ADMIN` to the same synthetic ID, then run `node scripts/verify-community-moderation-local.mjs`. This script emulates trusted Sites headers only against the local built Worker, creates random synthetic owners and uploads, and cleans up its own fixtures. It refuses non-loopback destinations and non-fixture administrator IDs. The ordinary dev preview strips incoming identity headers and continues to use its single mock sign-in account.

The product free-access policy is in `lib/product-access.ts`. Stripe checkout and portal creation are paused. Payment configuration and historical records are preserved; re-enabling billing requires an explicit release, not merely adding a secret.
