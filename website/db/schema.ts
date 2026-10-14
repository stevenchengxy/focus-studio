import { sqliteTable, text, integer, uniqueIndex, index } from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';

export const accounts = sqliteTable('accounts', {
  id: text('id').primaryKey(), email: text('email').notNull(), createdAt: integer('created_at').notNull(),
  stripeCustomerId: text('stripe_customer_id').unique(), syncVersion: integer('sync_version').notNull().default(0),
});
export const subscriptions = sqliteTable('subscriptions', {
  id: text('id').primaryKey(), accountId: text('account_id').notNull().references(() => accounts.id),
  status: text('status').notNull(), plan: text('plan').notNull(), priceId: text('price_id').notNull(),
  currentPeriodEnd: integer('current_period_end').notNull(), updatedAt: integer('updated_at').notNull(),
}, t => [index('subscriptions_account').on(t.accountId)]);
export const exportJobs = sqliteTable('export_jobs', {
  id: text('id').primaryKey(), accountId: text('account_id').notNull().references(() => accounts.id),
  idempotencyKey: text('idempotency_key').notNull(), projectId: text('project_id').notNull(),
  mode: text('mode').notNull(), status: text('status').notNull(), expiresAt: integer('expires_at').notNull(),
  createdAt: integer('created_at').notNull(), completedAt: integer('completed_at'),
}, t => [
  uniqueIndex('export_account_idempotency').on(t.accountId, t.idempotencyKey),
  uniqueIndex('export_one_trial').on(t.accountId).where(sql`${t.mode} = 'trial' AND ${t.status} IN ('reserved', 'committed')`),
]);
export const deviceGrants = sqliteTable('device_grants', {
  hash: text('hash').primaryKey(), userCode: text('user_code').notNull().unique(),
  accountId: text('account_id').references(() => accounts.id), name: text('name').notNull(),
  expiresAt: integer('expires_at').notNull(), createdAt: integer('created_at').notNull(),
});
export const deviceTokens = sqliteTable('device_tokens', {
  id: text('id').primaryKey(), hash: text('hash').notNull().unique(), accountId: text('account_id').notNull().references(() => accounts.id),
  name: text('name').notNull(), expiresAt: integer('expires_at').notNull(), createdAt: integer('created_at').notNull(), revokedAt: integer('revoked_at'),
});
export const webhookEvents = sqliteTable('webhook_events', {
  id: text('id').primaryKey(), processedAt: integer('processed_at').notNull(),
});
export const rateLimits = sqliteTable('rate_limits', {
  key: text('key').primaryKey(), count: integer('count').notNull(), expiresAt: integer('expires_at').notNull(),
});
export const checkoutSessions = sqliteTable('checkout_sessions', {
  accountId: text('account_id').primaryKey().references(() => accounts.id), plan: text('plan').notNull(),
  requestKey: text('request_key').notNull(), sessionId: text('session_id'), url: text('url'), expiresAt: integer('expires_at').notNull(),
});
export const oauthRequests = sqliteTable('oauth_requests', {
  stateHash: text('state_hash').primaryKey(), nonceHash: text('nonce_hash').notNull(), verifier: text('verifier').notNull(),
  returnTo: text('return_to').notNull(), expiresAt: integer('expires_at').notNull(),
});
export const webSessions = sqliteTable('web_sessions', {
  hash: text('hash').primaryKey(), accountId: text('account_id').notNull().references(() => accounts.id), expiresAt: integer('expires_at').notNull(),
});

// Community assets stay private in R2; every read checks publication/ownership.
export const communityPosts = sqliteTable('community_posts', {
  id: text('id').primaryKey(), ownerId: text('owner_id').notNull(),
  title: text('title').notNull(), description: text('description').notNull().default(''),
  caption: text('caption').notNull().default(''), productUrl: text('product_url'),
  category: text('category').notNull(), authorName: text('author_name').notNull(),
  status: text('status').notNull().default('draft'), license: text('license'),
  filename: text('filename').notNull(), mimeType: text('mime_type').notNull(),
  sizeBytes: integer('size_bytes').notNull(), mediaState: text('media_state').notNull().default('pending'),
  posterKey: text('poster_key'), posterBytes: integer('poster_bytes'), posterToken: text('poster_token'), posterExpiresAt: integer('poster_expires_at'),
  objectKey: text('object_key'), uploadToken: text('upload_token'), uploadExpiresAt: integer('upload_expires_at'),
  createdAt: integer('created_at').notNull(), updatedAt: integer('updated_at').notNull(),
  uploadedAt: integer('uploaded_at'), publishedAt: integer('published_at'),
  licenseAcceptedAt: integer('license_accepted_at'), deletedAt: integer('deleted_at'),
  moderationHold: integer('moderation_hold').notNull().default(0), moderationReason: text('moderation_reason'),
  moderatedAt: integer('moderated_at'), moderatedBy: text('moderated_by'),
}, t => [
  index('community_public_feed').on(t.status, t.publishedAt, t.id),
  index('community_owner_items').on(t.ownerId, t.updatedAt),
]);
export const communityReports = sqliteTable('community_reports', {
  id: text('id').primaryKey(), postId: text('post_id').notNull().references(() => communityPosts.id, {onDelete: 'cascade'}),
  reporterId: text('reporter_id').notNull(), reason: text('reason').notNull(),
  details: text('details').notNull().default(''), createdAt: integer('created_at').notNull(),
}, t => [uniqueIndex('community_one_report_per_user').on(t.postId, t.reporterId)]);
