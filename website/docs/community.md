# Community operations

The public website offers optional sharing. Creation and export happen in installed Focus Studio; local projects are never uploaded automatically. ChatGPT sign-in uses Sites-provided identity headers. Private drafts are only accessible to their owner, except authorized moderation review of previously reported/held content.

## Pages and profiles

- `/community` and `/community/ai` show static cover cards. Selecting a card opens its own `/community/[id]` page; lists never autoplay or load video players.
- The detail page contains the video, creator name, download and optional product introduction/link. A standalone video needs no product introduction.
- `/community/mine` manages private drafts and published work; `/community/new` uploads a new work. The official sample lives separately at `/community/showcase` and is explicitly labeled.
- `/community/profile` saves a public creator name for the signed-in account. GET/PATCH `/api/community/profile` returns `{displayName}`. The D1 `community_profiles` table binds names to trusted Sites owner IDs. Updating a name atomically updates existing work attribution without changing content, publication state or ordering. New work and metadata edits use the saved name. Email addresses are rejected as public names.
- Apply migration `0004_bouncy_gauntlet.sql` before serving this version. Both language and theme controls are shared across community pages.

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

`/community/moderation` shows reports only to configured moderators. Hide adds a moderation hold; public list/detail/media are blocked and the author cannot publish again. Restore removes the hold and preserves the author's publication choice. Review is limited to public, reported or held posts; unrelated private drafts remain inaccessible. Report data is never returned to the public.

## Release checks

Run `node --test tests/*.test.mjs` from website, TypeScript, and the Sites build helper. With local dev running and migrations applied, run `node scripts/verify-community-local.mjs`. That test refuses non-loopback hosts and uses only the starter's mock local identity. It verifies draft privacy, upload, publish, literal search, media ranges, details edits, unpublish and cleanup against real local HTTP routes. No production sample posts or private recordings are seeded.

The product free-access policy is in `lib/product-access.ts`. Stripe checkout and portal creation are paused. Payment configuration and historical records are preserved; re-enabling billing requires an explicit release, not merely adding a secret.
