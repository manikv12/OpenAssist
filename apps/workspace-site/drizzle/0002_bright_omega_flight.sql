CREATE TABLE `judge_voice_events` (
	`event_id` text PRIMARY KEY NOT NULL,
	`visitor_hash` text NOT NULL,
	`external_id_hash` text,
	`kind` text NOT NULL,
	`status` text NOT NULL,
	`started_at` integer NOT NULL,
	`expires_at` integer,
	`ended_at` integer,
	`tool_calls` integer DEFAULT 0 NOT NULL,
	`error_code` text
);
--> statement-breakpoint
CREATE INDEX `judge_voice_events_started_idx` ON `judge_voice_events` (`started_at`);--> statement-breakpoint
CREATE INDEX `judge_voice_events_status_expires_idx` ON `judge_voice_events` (`status`,`expires_at`);--> statement-breakpoint
CREATE INDEX `judge_voice_events_visitor_idx` ON `judge_voice_events` (`visitor_hash`,`started_at`);