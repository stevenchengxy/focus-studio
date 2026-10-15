ALTER TABLE `community_posts` ADD `moderation_hold` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `community_posts` ADD `moderation_reason` text;--> statement-breakpoint
ALTER TABLE `community_posts` ADD `moderated_at` integer;--> statement-breakpoint
ALTER TABLE `community_posts` ADD `moderated_by` text;