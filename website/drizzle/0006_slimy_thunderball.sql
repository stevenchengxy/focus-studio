CREATE TABLE `community_client_activations` (
	`owner_id` text PRIMARY KEY NOT NULL,
	`confirmed_at` integer NOT NULL,
	`device_id` text NOT NULL
);
--> statement-breakpoint
ALTER TABLE `device_grants` ADD `purpose` text DEFAULT 'account' NOT NULL;--> statement-breakpoint
ALTER TABLE `device_tokens` ADD `purpose` text DEFAULT 'account' NOT NULL;