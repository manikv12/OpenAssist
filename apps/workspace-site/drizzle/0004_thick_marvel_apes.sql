CREATE TABLE `demo_supply_carts` (
	`workspace_id` text PRIMARY KEY NOT NULL,
	`cart_id` text,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`workspace_id`) REFERENCES `demo_workspaces`(`workspace_id`) ON UPDATE no action ON DELETE cascade
);
