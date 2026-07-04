import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-connectors-"));
process.env.OPENASSIST_SUPPORT_DIR = tempRoot;
process.env.OPENASSIST_MESSAGES_DB = path.join(tempRoot, "chat.db");

const connectors = await import("../dist-electron/connectors.js");
const appSource = fs.readFileSync(path.resolve("src/App.tsx"), "utf8");
const stylesSource = fs.readFileSync(path.resolve("src/styles.css"), "utf8");
const bridgeSource = fs.readFileSync(path.resolve("electron/openassistBridge.ts"), "utf8");
const realtimeSource = fs.readFileSync(path.resolve("electron/realtimeProxy.ts"), "utf8");

try {
  assert.ok(appSource.includes("connector-review-summary"), "Connector Settings must show only a Review Inbox summary");
  assert.ok(!appSource.includes("saveConnectorReviewItemToBacklog"), "Connector Settings must not duplicate Review Inbox backlog actions");
  assert.ok(!appSource.includes("markConnectorReviewItem"), "Connector Settings must not duplicate Review Inbox ignore actions");
  assert.ok(!stylesSource.includes("connector-review-list"), "Connector Settings must not keep the old review-card grid");
  assert.ok(bridgeSource.includes("name: \"oa_connector_search_gmail\""), "Knowledge tools must include direct Gmail search");
  assert.ok(bridgeSource.includes("return \"oa_connector_search_gmail\""), "Gmail search aliases must not route to sync");
  assert.ok(bridgeSource.includes("name: \"oa_connector_search_messages\""), "Knowledge tools must include local Messages search");
  assert.ok(bridgeSource.includes("return \"oa_connector_search_messages\""), "Messages search aliases must route to Messages search");
  assert.ok(realtimeSource.includes("name: \"knowledge_connector_search_gmail\""), "Realtime knowledge tools must include direct Gmail search");
  assert.ok(realtimeSource.includes("name: \"knowledge_connector_search_messages\""), "Realtime knowledge tools must include Messages search");
  assert.ok(realtimeSource.includes("do not sync Review Inbox"), "Realtime instructions must separate search from sync");
  assert.ok(appSource.includes("Open Full Disk Access"), "Connector Settings must show a Messages Full Disk Access action");

  let snapshot = connectors.loadConnectorSnapshot();
  assert.equal(snapshot.accounts.some((account) => account.id === "apple-this-mac"), true);
  assert.equal(snapshot.accounts.some((account) => account.id === "local-this-mac"), true);
  assert.ok(Array.isArray(snapshot.localAccessStatuses), "Connector snapshot must include local access statuses");

  snapshot = connectors.createGoogleConnectorAccount("Personal Gmail");
  const google = snapshot.accounts.find((account) => account.provider === "google");
  assert.ok(google);
  assert.equal(fs.existsSync(google.configPath), true);
  assert.equal(google.configPath.includes("Connectors/Google/personal-gmail/gws"), true);

  snapshot = connectors.setConnectorServiceEnabled(google.id, "gmail", true);
  const updatedGoogle = snapshot.accounts.find((account) => account.id === google.id);
  assert.equal(updatedGoogle.enabledServiceIDs.includes("gmail"), true);

  const plannedQueries = connectors.planGmailMetadataSearches({
    userIntent: "Find email tasks for Quality Nails today",
    timeframeDays: 2,
    maxResults: 5
  });
  assert.equal(plannedQueries.some((query) => query.includes("newer_than:2d")), true);
  assert.equal(plannedQueries.some((query) => query.includes("-category:promotions")), true);
  assert.equal(plannedQueries.some((query) => query.includes('"quality"')), true);
  assert.equal(plannedQueries.some((query) => query.trim() === "newer_than:7d"), false);
  const fallbackQueries = connectors.planGmailFallbackMetadataSearches({
    userIntent: "Find email tasks for Quality Nails today",
    timeframeDays: 2
  });
  assert.equal(fallbackQueries.some((query) => query === "newer_than:2d -category:promotions -category:social -in:chats"), true);
  assert.equal(fallbackQueries.some((query) => query.includes("is:unread")), true);
  assert.equal(fallbackQueries.some((query) => query.includes("is:important")), true);
  const directQueries = connectors.planGmailDirectSearches({
    query: "from:alex@example.com invoice",
    timeframeDays: 30,
    maxResults: 5
  });
  assert.equal(directQueries.length, 1);
  assert.equal(directQueries[0].includes("newer_than:30d"), true);
  assert.equal(directQueries[0].includes("from:alex@example.com invoice"), true);
  const naturalDirectQueries = connectors.planGmailDirectSearches({
    userIntent: "find Quality Nails receipt email",
    timeframeDays: 30
  });
  assert.equal(naturalDirectQueries.some((query) => query.includes('"quality"')), true);
  assert.equal(naturalDirectQueries.some((query) => query.includes('"receipt"')), true);

  execFileSync("/usr/bin/sqlite3", [process.env.OPENASSIST_MESSAGES_DB, [
    "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);",
    "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, text TEXT, handle_id INTEGER, is_from_me INTEGER);",
    "INSERT INTO handle (ROWID, id) VALUES (1, '+14175550123');",
    "INSERT INTO message (ROWID, guid, date, text, handle_id, is_from_me) VALUES (1, 'msg-1', 900000000000000000, 'Appointment tomorrow at 3 PM', 1, 0);"
  ].join("\n")]);
  const messageSearch = await connectors.searchLocalMessages({
    query: "appointment tomorrow",
    timeframeDays: 365,
    maxResults: 5
  });
  assert.equal(messageSearch.resultCount, 1);
  assert.equal(messageSearch.messages[0].text, "Appointment tomorrow at 3 PM");
  const messagesAccess = connectors.localConnectorAccessStatuses().find((status) => status.serviceID === "messages");
  assert.equal(messagesAccess?.status, "granted");

  const clientSecretSourcePath = path.join(tempRoot, "client_secret_source.json");
  fs.writeFileSync(clientSecretSourcePath, JSON.stringify({
    installed: {
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      project_id: "test-project"
    }
  }));
  const importedStatus = connectors.importGoogleClientSecret(google.id, clientSecretSourcePath);
  assert.equal(importedStatus.hasClientSecret, true);
  snapshot = connectors.createGoogleConnectorAccount("Business Gmail");
  const businessGoogle = snapshot.accounts.find((account) => account.provider === "google" && account.label === "Business Gmail");
  assert.ok(businessGoogle);
  const reusedStatus = connectors.googleOAuthSetupStatus(businessGoogle.id);
  assert.equal(reusedStatus.hasClientSecret, true);
  assert.equal(reusedStatus.projectID, "test-project");
  fs.writeFileSync(path.join(google.configPath, "credentials.enc"), "fake encrypted credentials");
  const oauthStatus = connectors.googleOAuthSetupStatus(google.id);
  assert.equal(oauthStatus.hasClientSecret, true);
  assert.equal(oauthStatus.isLoggedIn, true);
  assert.equal(oauthStatus.credentialStorage, "encrypted");
  assert.equal(oauthStatus.projectID, "test-project");

  const readPlan = connectors.buildGoogleCommandPlan(google.id, {
    kind: "gmailSearchMetadata",
    query: "newer_than:7d",
    maxResults: 5
  });
  assert.equal(readPlan.requiresApproval, false);
  assert.equal(readPlan.environment.GOOGLE_WORKSPACE_CLI_CONFIG_DIR, google.configPath);
  assert.deepEqual(readPlan.arguments.slice(0, 4), ["gmail", "users", "messages", "list"]);

  const fakeGwsPath = path.join(tempRoot, "fake-gws-permission-error.sh");
  fs.writeFileSync(fakeGwsPath, [
    "#!/bin/sh",
    "echo 'error[api]: Caller does not have required permission to use project qualitynailsreporting. Grant the caller the roles/serviceusage.serviceUsageConsumer role, or a custom role with the serviceusage.services.use permission.' 1>&2",
    "exit 1",
    ""
  ].join("\n"));
  fs.chmodSync(fakeGwsPath, 0o755);
  await assert.rejects(
    () => connectors.runGoogleCommandPlan({
      executablePath: fakeGwsPath,
      arguments: [],
      environment: {},
      requiresApproval: false,
      displayCommand: fakeGwsPath
    }),
    /Google Cloud permission needed for project "qualitynailsreporting"/
  );

  assert.throws(() => connectors.buildGoogleCommandPlan(google.id, {
    kind: "sendEmail",
    to: "person@example.com",
    subject: "Hello",
    body: "Hi"
  }), /Approval is required/);

  assert.throws(() => connectors.buildGoogleCommandPlan(google.id, {
    kind: "applyGmailLabel",
    messageId: "m1",
    labelName: "Random/Label"
  }, true), /Unsupported Gmail label/);

  const parsed = connectors.parseGmailMetadataOutput(JSON.stringify({
    id: "m1",
    threadId: "t1",
    snippet: "Can you send the invoice today?",
    internalDate: "1767225600000",
    payload: {
      headers: [
        { name: "Subject", value: "Invoice follow up" },
        { name: "From", value: "Alex <alex@example.com>" }
      ]
    },
    historyId: "h1"
  }), google.id);
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].kind, "followUp");
  assert.equal(parsed[0].title, "Invoice follow up");
  assert.equal(parsed[0].person, "Alex <alex@example.com>");

  const ignoredReceipt = connectors.parseGmailMetadataOutput(JSON.stringify({
    id: "m2",
    threadId: "t2",
    snippet: "Payment summary Amount billed $99.73 USD Transaction ID 123",
    internalDate: "1767225600000",
    payload: {
      headers: [
        { name: "Subject", value: "Your Meta ads receipt" },
        { name: "From", value: "Meta for Business <noreply@business-updates.facebook.com>" }
      ]
    },
    historyId: "h2"
  }), google.id, { onlyActionable: true });
  assert.equal(ignoredReceipt.length, 0);

  connectors.upsertConnectorItems(parsed);
  snapshot = connectors.loadConnectorSnapshot();
  assert.equal(snapshot.items.length, 1);
  assert.equal(snapshot.items[0].status, "candidate");

  const backlogInput = connectors.saveConnectorItemToBacklogInput(snapshot.items[0].id);
  assert.equal(backlogInput.dayID, "backlog");
  assert.equal(backlogInput.title, "Invoice follow up");

  console.log("Connector verification passed.");
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
