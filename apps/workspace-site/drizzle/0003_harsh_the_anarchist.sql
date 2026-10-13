CREATE TABLE `judge_login_limits` (
	`attempt_key` text PRIMARY KEY NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `judge_login_limits_expires_idx` ON `judge_login_limits` (`expires_at`);