CREATE TABLE `action_receipts` (
	`idempotency_hash` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`tool_name` text NOT NULL,
	`created_at` integer NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `action_receipts_user_expires_idx` ON `action_receipts` (`user_id`,`expires_at`);--> statement-breakpoint
CREATE TABLE `site_preferences` (
	`user_id` text PRIMARY KEY NOT NULL,
	`default_view` text DEFAULT 'today' NOT NULL,
	`density` text DEFAULT 'comfortable' NOT NULL,
	`time_zone` text DEFAULT 'America/Chicago' NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `site_users` (
	`user_id` text PRIMARY KEY NOT NULL,
	`role` text DEFAULT 'viewer' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `voice_auth` (
	`user_id` text PRIMARY KEY NOT NULL,
	`r2_object_key` text NOT NULL,
	`status` text NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `workspace_links` (
	`user_id` text PRIMARY KEY NOT NULL,
	`access_token_ciphertext` text NOT NULL,
	`refresh_token_ciphertext` text,
	`expires_at` integer,
	`scope` text DEFAULT 'workspace.manage' NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`updated_at` integer NOT NULL
);
