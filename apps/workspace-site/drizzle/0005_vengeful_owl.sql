CREATE TABLE `workspace_refresh_locks` (
	`user_id` text PRIMARY KEY NOT NULL,
	`lease_id` text NOT NULL,
	`expires_at` integer NOT NULL
);
