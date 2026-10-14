CREATE TABLE `community_posts` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`title` text NOT NULL,
	`description` text DEFAULT '' NOT NULL,
	`caption` text DEFAULT '' NOT NULL,
	`product_url` text,
	`category` text NOT NULL,
	`author_name` text NOT NULL,
	`status` text DEFAULT 'draft' NOT NULL,
	`license` text,
	`filename` text NOT NULL,
	`mime_type` text NOT NULL,
	`size_bytes` integer NOT NULL,
	`media_state` text DEFAULT 'pending' NOT NULL,
	`poster_key` text,
	`poster_bytes` integer,
	`poster_token` text,
	`poster_expires_at` integer,
	`object_key` text,
	`upload_token` text,
	`upload_expires_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`uploaded_at` integer,
	`published_at` integer,
	`license_accepted_at` integer,
	`deleted_at` integer
);
--> statement-breakpoint
CREATE INDEX `community_public_feed` ON `community_posts` (`status`,`published_at`,`id`);--> statement-breakpoint
CREATE INDEX `community_owner_items` ON `community_posts` (`owner_id`,`updated_at`);--> statement-breakpoint
CREATE TABLE `community_reports` (
	`id` text PRIMARY KEY NOT NULL,
	`post_id` text NOT NULL,
	`reporter_id` text NOT NULL,
	`reason` text NOT NULL,
	`details` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`post_id`) REFERENCES `community_posts`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `community_one_report_per_user` ON `community_reports` (`post_id`,`reporter_id`);