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
