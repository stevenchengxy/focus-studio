CREATE TABLE `community_moderation_audit` (
	`id` text PRIMARY KEY NOT NULL,
	`post_id` text NOT NULL,
	`revision` integer NOT NULL,
	`action` text NOT NULL,
	`reason` text NOT NULL,
	`actor_id` text NOT NULL,
	`actor_name` text NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`post_id`) REFERENCES `community_posts`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `community_moderation_revision` ON `community_moderation_audit` (`post_id`,`revision`);--> statement-breakpoint
ALTER TABLE `community_posts` ADD `moderation_deleted_at` integer;--> statement-breakpoint
ALTER TABLE `community_posts` ADD `moderation_revision` integer DEFAULT 0 NOT NULL;