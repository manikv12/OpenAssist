CREATE TABLE `demo_activity` (
	`workspace_id` text NOT NULL,
	`activity_id` text NOT NULL,
	`actor` text NOT NULL,
	`action` text NOT NULL,
	`time_label` text DEFAULT 'Just now' NOT NULL,
	`type` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`workspace_id`, `activity_id`),
	FOREIGN KEY (`workspace_id`) REFERENCES `demo_workspaces`(`workspace_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `demo_activity_workspace_created_idx` ON `demo_activity` (`workspace_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `demo_events` (
	`workspace_id` text NOT NULL,
	`event_id` text NOT NULL,
	`title` text NOT NULL,
	`account` text DEFAULT 'Main' NOT NULL,
	`start` text NOT NULL,
	`end` text NOT NULL,
	`day_label` text DEFAULT 'Upcoming' NOT NULL,
	`reminder` text DEFAULT '10 minutes before' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`workspace_id`, `event_id`),
	FOREIGN KEY (`workspace_id`) REFERENCES `demo_workspaces`(`workspace_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `demo_events_workspace_day_idx` ON `demo_events` (`workspace_id`,`day_label`);--> statement-breakpoint
CREATE TABLE `demo_memory` (
	`workspace_id` text NOT NULL,
	`fact_id` text NOT NULL,
	`category` text DEFAULT 'General' NOT NULL,
	`fact` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`workspace_id`, `fact_id`),
	FOREIGN KEY (`workspace_id`) REFERENCES `demo_workspaces`(`workspace_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `demo_memory_workspace_category_idx` ON `demo_memory` (`workspace_id`,`category`);--> statement-breakpoint
CREATE TABLE `demo_messages` (
	`workspace_id` text NOT NULL,
	`message_id` text NOT NULL,
	`account` text NOT NULL,
	`sender` text NOT NULL,
	`subject` text NOT NULL,
	`snippet` text NOT NULL,
	`time_label` text NOT NULL,
	`unread` integer DEFAULT true NOT NULL,
	`urgent` integer DEFAULT false NOT NULL,
	`has_attachment` integer DEFAULT false NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`workspace_id`, `message_id`),
	FOREIGN KEY (`workspace_id`) REFERENCES `demo_workspaces`(`workspace_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `demo_messages_workspace_unread_idx` ON `demo_messages` (`workspace_id`,`unread`);--> statement-breakpoint
CREATE TABLE `demo_notes` (
	`workspace_id` text NOT NULL,
	`note_id` text NOT NULL,
	`title` text NOT NULL,
	`content` text NOT NULL,
	`updated_label` text DEFAULT 'Just now' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`workspace_id`, `note_id`),
	FOREIGN KEY (`workspace_id`) REFERENCES `demo_workspaces`(`workspace_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `demo_notes_workspace_updated_idx` ON `demo_notes` (`workspace_id`,`updated_at`);--> statement-breakpoint
CREATE TABLE `demo_tasks` (
	`workspace_id` text NOT NULL,
	`task_id` text NOT NULL,
	`title` text NOT NULL,
	`list_name` text DEFAULT 'My Tasks' NOT NULL,
	`due` text DEFAULT 'No date' NOT NULL,
	`tags_json` text DEFAULT '[]' NOT NULL,
	`completed` integer DEFAULT false NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	PRIMARY KEY(`workspace_id`, `task_id`),
	FOREIGN KEY (`workspace_id`) REFERENCES `demo_workspaces`(`workspace_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `demo_tasks_workspace_list_idx` ON `demo_tasks` (`workspace_id`,`list_name`);--> statement-breakpoint
CREATE INDEX `demo_tasks_workspace_completed_idx` ON `demo_tasks` (`workspace_id`,`completed`);--> statement-breakpoint
CREATE TABLE `demo_workspaces` (
	`workspace_id` text PRIMARY KEY NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `demo_workspaces_expires_idx` ON `demo_workspaces` (`expires_at`);