CREATE TABLE `accounts` (
	`id` text PRIMARY KEY NOT NULL,
	`email` text NOT NULL,
	`created_at` integer NOT NULL,
	`stripe_customer_id` text,
	`sync_version` integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `accounts_stripe_customer_id_unique` ON `accounts` (`stripe_customer_id`);--> statement-breakpoint
CREATE TABLE `checkout_sessions` (
	`account_id` text PRIMARY KEY NOT NULL,
	`plan` text NOT NULL,
	`request_key` text NOT NULL,
	`session_id` text,
	`url` text,
	`expires_at` integer NOT NULL,
	FOREIGN KEY (`account_id`) REFERENCES `accounts`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `device_grants` (
	`hash` text PRIMARY KEY NOT NULL,
	`user_code` text NOT NULL,
	`account_id` text,
	`name` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`account_id`) REFERENCES `accounts`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `device_grants_user_code_unique` ON `device_grants` (`user_code`);--> statement-breakpoint
CREATE TABLE `device_tokens` (
	`id` text PRIMARY KEY NOT NULL,
	`hash` text NOT NULL,
	`account_id` text NOT NULL,
	`name` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	`revoked_at` integer,
	FOREIGN KEY (`account_id`) REFERENCES `accounts`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `device_tokens_hash_unique` ON `device_tokens` (`hash`);--> statement-breakpoint
CREATE TABLE `export_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`idempotency_key` text NOT NULL,
	`project_id` text NOT NULL,
	`mode` text NOT NULL,
	`status` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	`completed_at` integer,
	FOREIGN KEY (`account_id`) REFERENCES `accounts`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `export_account_idempotency` ON `export_jobs` (`account_id`,`idempotency_key`);--> statement-breakpoint
CREATE UNIQUE INDEX `export_one_trial` ON `export_jobs` (`account_id`) WHERE "export_jobs"."mode" = 'trial' AND "export_jobs"."status" IN ('reserved', 'committed');--> statement-breakpoint
CREATE TABLE `rate_limits` (
	`key` text PRIMARY KEY NOT NULL,
	`count` integer NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `subscriptions` (
	`id` text PRIMARY KEY NOT NULL,
	`account_id` text NOT NULL,
	`status` text NOT NULL,
	`plan` text NOT NULL,
	`price_id` text NOT NULL,
	`current_period_end` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`account_id`) REFERENCES `accounts`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `subscriptions_account` ON `subscriptions` (`account_id`);--> statement-breakpoint
CREATE TABLE `webhook_events` (
	`id` text PRIMARY KEY NOT NULL,
	`processed_at` integer NOT NULL
);
