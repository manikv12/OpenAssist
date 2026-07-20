import { execFile, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import {
  cachedAppleEventKitRawStatus,
  executeAppleEventKitCommand,
  setAppleEventKitRunner,
  type AppleEventKitCommandRunner
} from "./nativeAccess.js";

const execFileAsync = promisify(execFile);
const pinnedGwsVersion = "0.22.5";
const googleCLIStatusCacheMs = 30_000;
const macAbsoluteEpochOffsetSeconds = 978_307_200;
let cachedGoogleCLIStatus: { checkedAt: number; status: GoogleCLIStatus } | null = null;

export type ConnectorProvider = "google" | "apple" | "local";

export type ConnectorServiceID =
  | "gmail"
  | "googleCalendar"
  | "googleTasks"
  | "googleDriveDocs"
  | "googlePeople"
  | "appleReminders"
  | "appleCalendar"
  | "appleContacts"
  | "appleNotes"
  | "messages";

export type ConnectorItemKind =
  | "task"
  | "backlog"
  | "followUp"
  | "waitingFor"
  | "replyDraft"
  | "event"
  | "file"
  | "document"
  | "person"
  | "note"
  | "message"
  | "projectHint";

export type ConnectorItemStatus = "candidate" | "review" | "approved" | "ignored" | "synced" | "failed" | "conflict";
export type ConnectorSyncState = "externalOnly" | "localOnly" | "synced" | "pendingWrite" | "writePreview" | "failed" | "conflict";

export type ConnectorServiceDefinition = {
  id: ConnectorServiceID;
  provider: ConnectorProvider;
  displayName: string;
  purpose: string;
  syncMode: string;
};

export type ConnectorAccount = {
  id: string;
  provider: ConnectorProvider;
  label: string;
  configPath?: string;
  enabledServiceIDs: ConnectorServiceID[];
  syncCursors: Record<string, string>;
  createdAt: string;
  updatedAt: string;
  lastSyncAt?: string;
};

export type ConnectorAccessStatus = {
  serviceID: ConnectorServiceID;
  status: "granted" | "blocked" | "notSupported" | "unknown";
  label: string;
  detail: string;
  permissionKind?: "fullDiskAccess" | "appleEventKit";
};

export type AppleReminderRecurrence = {
  frequency: "daily" | "weekly" | "monthly" | "yearly";
  interval?: number;
  endDate?: string;
  occurrenceCount?: number;
};

export type AppleReminderRecord = {
  id: string;
  title: string;
  completed: boolean;
  calendar: string;
  notes?: string;
  dueDate?: string;
  completionDate?: string;
  recurrence?: AppleReminderRecurrence;
};

export type AppleCalendarEventRecord = {
  id: string;
  title: string;
  calendar: string;
  startDate: string;
  endDate: string;
  isAllDay: boolean;
  notes?: string;
  location?: string;
};

export type AppleReminderInput = {
  title: string;
  notes?: string;
  details?: string;
  dueDate?: string;
  due?: string;
  calendar?: string;
  list?: string;
  recurrence?: AppleReminderRecurrence;
};

export type AppleReminderUpdateInput = {
  id: string;
  title?: string;
  notes?: string;
  details?: string;
  dueDate?: string;
  due?: string;
  clearNotes?: boolean;
  clearDueDate?: boolean;
  recurrence?: Partial<AppleReminderRecurrence>;
  clearRecurrence?: boolean;
};

export type AppleReminderListOptions = {
  calendar?: string;
  dueBefore?: string;
  dueAfter?: string;
  startDate?: string;
  endDate?: string;
  includeCompleted?: boolean;
  limit?: number;
};

export type AppleCalendarEventInput = {
  title: string;
  startDate: string;
  endDate?: string;
  start?: string;
  end?: string;
  isAllDay?: boolean;
  notes?: string;
  details?: string;
  location?: string;
  calendar?: string;
};

export type AppleCalendarEventListOptions = {
  calendar?: string;
  startDate?: string;
  endDate?: string;
  start?: string;
  end?: string;
  limit?: number;
};

type AppleEventKitStatus = {
  reminders: ConnectorAccessStatus;
  calendar: ConnectorAccessStatus;
};

export function setAppleEventKitCommandRunner(runner: AppleEventKitCommandRunner) {
  setAppleEventKitRunner(runner);
}

export type ConnectorItem = {
  id: string;
  sourceService: ConnectorServiceID;
  accountId: string;
  externalId: string;
  threadId?: string;
  kind: ConnectorItemKind;
  title: string;
  snippet: string;
  date: string;
  status: ConnectorItemStatus;
  dueDate?: string;
  person?: string;
  projectHint?: string;
  syncState: ConnectorSyncState;
  lastExternalVersion?: string;
  lastLocalVersion?: string;
  fullBodyFetched: boolean;
  rawMetadata: Record<string, string>;
  createdAt: string;
  updatedAt: string;
};

export type ConnectorConflictRecord = {
  id: string;
  itemId: string;
  sourceService: ConnectorServiceID;
  accountId: string;
  externalSummary: string;
  localSummary: string;
  externalVersion?: string;
  localVersion?: string;
  detectedAt: string;
  resolvedAt?: string;
};

export type ConnectorMutationRequest = {
  id: string;
  operation:
    | "sendEmail"
    | "archiveEmail"
    | "deleteEmail"
    | "applyGmailLabel"
    | "markDone"
    | "createTask"
    | "updateTask"
    | "deleteTask"
    | "createCalendarEvent"
    | "updateCalendarEvent"
    | "deleteCalendarEvent"
    | "editDocument";
  serviceId: ConnectorServiceID;
  accountId: string;
  externalId?: string;
  title: string;
  preview: string;
  approved: boolean;
  createdAt: string;
};

export type ConnectorSnapshot = {
  version: 1;
  services: ConnectorServiceDefinition[];
  accounts: ConnectorAccount[];
  localAccessStatuses: ConnectorAccessStatus[];
  items: ConnectorItem[];
  conflicts: ConnectorConflictRecord[];
  mutationRequests: ConnectorMutationRequest[];
  gwsStatus: GoogleCLIStatus;
  updatedAt: string;
};

export type ConnectorReviewInboxSnapshot = {
  version: 1;
  services: ConnectorServiceDefinition[];
  accounts: ConnectorAccount[];
  items: ConnectorItem[];
  updatedAt: string;
};

const connectorReviewStatuses = new Set<ConnectorItemStatus>(["candidate", "review", "failed", "conflict"]);

export type GoogleCLIStatus = {
  pinnedVersion: string;
  bundledPath: string;
  pathExecutable?: string;
  resolvedExecutable?: string;
  version?: string;
  supported: boolean;
  installCommand: string;
  setupCommand: string;
};

export type GoogleOAuthSetupStatus = {
  accountID: string;
  accountLabel: string;
  configPath: string;
  clientSecretPath: string;
  hasClientSecret: boolean;
  isLoggedIn: boolean;
  authMethod?: string;
  credentialStorage?: string;
  clientID?: string;
  projectID?: string;
  consentURL: string;
  credentialsURL: string;
  apiLibraryURL: string;
};

type ConnectorStoreFile = Omit<ConnectorSnapshot, "services" | "gwsStatus" | "localAccessStatuses">;

export type GoogleConnectorOperation =
  | { kind: "authSetup" }
  | { kind: "authLogin"; scopes?: string[] }
  | { kind: "authStatus" }
  | { kind: "gmailSearchMetadata"; query: string; maxResults?: number }
  | { kind: "gmailFetchMetadata"; messageId: string }
  | { kind: "gmailFetchBody"; messageId: string }
  | { kind: "calendarList"; timeMin: string; timeMax: string }
  | { kind: "calendarAgenda" }
  | { kind: "tasksList" }
  | { kind: "driveSearch"; query: string; pageSize?: number }
  | { kind: "peopleSearch"; query: string; pageSize?: number }
  | { kind: "applyGmailLabel"; messageId: string; labelName: string }
  | { kind: "sendEmail"; to: string; subject: string; body: string }
  | { kind: "archiveEmail"; messageId: string }
  | { kind: "deleteEmail"; messageId: string }
  | { kind: "createTask"; title: string; notes?: string; dueDate?: string }
  | { kind: "updateTask"; taskListId: string; taskId: string; title?: string; notes?: string }
  | { kind: "markTaskDone"; taskListId: string; taskId: string }
  | { kind: "deleteTask"; taskListId: string; taskId: string }
  | { kind: "createCalendarEvent"; summary: string; start: string; end: string }
  | { kind: "updateCalendarEvent"; calendarId: string; eventId: string; summary?: string }
  | { kind: "deleteCalendarEvent"; calendarId: string; eventId: string };

export type GoogleCommandPlan = {
  executablePath: string;
  arguments: string[];
  environment: Record<string, string>;
  requiresApproval: boolean;
  displayCommand: string;
};

export type GmailSyncOptions = {
  userIntent?: string;
  query?: string;
  timeframeDays?: number;
  maxResults?: number;
};

export type GmailSearchOptions = GmailSyncOptions;

export type LocalMessagesSearchOptions = {
  query?: string;
  userIntent?: string;
  timeframeDays?: number;
  maxResults?: number;
};

export type LocalMessageSearchResult = {
  id: string;
  guid: string;
  handle: string;
  text: string;
  date: string;
  isFromMe: boolean;
};

export const connectorServices: ConnectorServiceDefinition[] = [
  {
    id: "gmail",
    provider: "google",
    displayName: "Gmail",
    purpose: "Find to-dos, backlog items, follow-ups, waiting-for items, and reply drafts.",
    syncMode: "Metadata first; labels and drafts only after approval."
  },
  {
    id: "googleCalendar",
    provider: "google",
    displayName: "Google Calendar",
    purpose: "Bring in today schedule, meeting prep, deadlines, and approved event edits.",
    syncMode: "Two-way for actionable events with approval before writes."
  },
  {
    id: "googleTasks",
    provider: "google",
    displayName: "Google Tasks",
    purpose: "Import and sync Google task lists.",
    syncMode: "Two-way task sync with approval before create, update, complete, or delete."
  },
  {
    id: "googleDriveDocs",
    provider: "google",
    displayName: "Drive / Docs",
    purpose: "Find related files and docs for tasks and projects.",
    syncMode: "Read-only in v1 unless the user asks for a specific doc edit."
  },
  {
    id: "googlePeople",
    provider: "google",
    displayName: "Google People",
    purpose: "Add person and contact context.",
    syncMode: "Read-only in v1."
  },
  {
    id: "appleReminders",
    provider: "apple",
    displayName: "Apple Reminders",
    purpose: "Sync local reminders and due tasks.",
    syncMode: "Two-way through native access with approval before writes."
  },
  {
    id: "appleCalendar",
    provider: "apple",
    displayName: "Apple Calendar",
    purpose: "Sync local calendar events.",
    syncMode: "Two-way through native access with approval before writes."
  },
  {
    id: "appleContacts",
    provider: "apple",
    displayName: "Apple Contacts",
    purpose: "Add names, phones, emails, and person context.",
    syncMode: "Read-only in v1."
  },
  {
    id: "appleNotes",
    provider: "local",
    displayName: "Apple Notes",
    purpose: "Extract notes and possible action items.",
    syncMode: "Read-only in v1 unless the user asks for a specific note edit."
  },
  {
    id: "messages",
    provider: "local",
    displayName: "Messages",
    purpose: "Extract follow-ups from conversations.",
    syncMode: "Read-only in v1."
  }
];

export const gmailDefaultSearches = planGmailMetadataSearches();

export const gmailWriteBackLabels = [
  "OpenAssist/Today",
  "OpenAssist/Backlog",
  "OpenAssist/Waiting",
  "OpenAssist/Done"
];

export function connectorsRoot() {
  return path.join(supportRoot(), "Connectors");
}

export function loadConnectorSnapshot(): ConnectorSnapshot {
  const stored = readConnectorStore();
  const withLocalAccounts = ensureLocalAccounts(stored);
  if (JSON.stringify(withLocalAccounts.accounts) !== JSON.stringify(stored.accounts)) {
    writeConnectorStore(withLocalAccounts);
  }
  return {
    ...withLocalAccounts,
    services: connectorServices,
    localAccessStatuses: localConnectorAccessStatuses(),
    gwsStatus: getGoogleCLIStatus()
  };
}

export function loadConnectorReviewInbox(): ConnectorReviewInboxSnapshot {
  const stored = readConnectorStore();
  const withLocalAccounts = ensureLocalAccounts(stored);
  if (JSON.stringify(withLocalAccounts.accounts) !== JSON.stringify(stored.accounts)) {
    writeConnectorStore(withLocalAccounts);
  }
  return {
    version: 1,
    services: connectorServices,
    accounts: withLocalAccounts.accounts,
    items: withLocalAccounts.items.filter((item) => connectorReviewStatuses.has(item.status)),
    updatedAt: withLocalAccounts.updatedAt
  };
}

export function createGoogleConnectorAccount(label: string) {
  const trimmed = String(label ?? "").trim();
  if (!trimmed) throw new Error("Enter an account label first.");
  const now = new Date().toISOString();
  const account: ConnectorAccount = {
    id: `google-${randomUUID()}`,
    provider: "google",
    label: trimmed,
    configPath: googleConfigDirForLabel(trimmed),
    enabledServiceIDs: [],
    syncCursors: {},
    createdAt: now,
    updatedAt: now
  };
  fs.mkdirSync(account.configPath!, { recursive: true });
  copySharedGoogleClientSecret(account.configPath!);
  const store = readConnectorStore();
  store.accounts.push(account);
  store.updatedAt = now;
  writeConnectorStore(store);
  return loadConnectorSnapshot();
}

export function removeGoogleConnectorAccount(accountId: string) {
  const store = readConnectorStore();
  store.accounts = store.accounts.filter((account) => account.id !== accountId || account.provider !== "google");
  store.items = store.items.filter((item) => item.accountId !== accountId);
  store.conflicts = store.conflicts.filter((conflict) => conflict.accountId !== accountId);
  store.mutationRequests = store.mutationRequests.filter((request) => request.accountId !== accountId);
  store.updatedAt = new Date().toISOString();
  writeConnectorStore(store);
  return loadConnectorSnapshot();
}

export function googleOAuthSetupStatus(accountId: string): GoogleOAuthSetupStatus {
  const account = googleConnectorAccount(accountId);
  const clientSecretPath = path.join(account.configPath!, "client_secret.json");
  const parsed = readGoogleClientSecret(clientSecretPath);
  const authStatus = readGoogleAuthStatus(account.configPath!);
  const projectID = authStatus?.project_id || parsed?.installed?.project_id;
  const projectSuffix = projectID ? `?project=${encodeURIComponent(projectID)}` : "";
  const hasCredentials = Boolean(
    authStatus?.token_cache_exists
    || authStatus?.encrypted_credentials_exists
    || authStatus?.plain_credentials_exists
    || (authStatus?.auth_method && authStatus.auth_method !== "none")
  );
  return {
    accountID: account.id,
    accountLabel: account.label,
    configPath: account.configPath!,
    clientSecretPath,
    hasClientSecret: Boolean(parsed?.installed?.client_id && parsed.installed.client_secret),
    isLoggedIn: hasCredentials,
    authMethod: authStatus?.auth_method,
    credentialStorage: authStatus?.storage,
    clientID: parsed?.installed?.client_id,
    projectID,
    consentURL: `https://console.cloud.google.com/apis/credentials/consent${projectSuffix}`,
    credentialsURL: `https://console.cloud.google.com/apis/credentials${projectSuffix}`,
    apiLibraryURL: `https://console.cloud.google.com/apis/library${projectSuffix}`
  };
}

export function importGoogleClientSecret(accountId: string, sourcePath: string): GoogleOAuthSetupStatus {
  const account = googleConnectorAccount(accountId);
  const raw = fs.readFileSync(sourcePath, "utf8");
  const parsed = JSON.parse(raw) as Record<string, any>;
  if (!parsed?.installed?.client_id || !parsed.installed.client_secret) {
    throw new Error("Choose the Desktop app OAuth client JSON from Google Cloud Console.");
  }
  fs.mkdirSync(account.configPath!, { recursive: true });
  const destinationPath = path.join(account.configPath!, "client_secret.json");
  const normalized = JSON.stringify(parsed, null, 2);
  fs.writeFileSync(destinationPath, normalized, { mode: 0o600 });
  fs.mkdirSync(sharedGoogleOAuthDir(), { recursive: true });
  fs.writeFileSync(sharedGoogleClientSecretPath(), normalized, { mode: 0o600 });
  try {
    fs.chmodSync(destinationPath, 0o600);
    fs.chmodSync(sharedGoogleClientSecretPath(), 0o600);
  } catch {
    // macOS may already apply the requested mode.
  }
  return googleOAuthSetupStatus(accountId);
}

export function reuseGoogleClientSecret(accountId: string): GoogleOAuthSetupStatus {
  const account = googleConnectorAccount(accountId);
  fs.mkdirSync(account.configPath!, { recursive: true });
  const sourcePath = findReusableGoogleClientSecretPath(account.id);
  if (!sourcePath) {
    throw new Error("No reusable Google OAuth JSON was found. Import the Desktop OAuth JSON once first.");
  }
  const raw = fs.readFileSync(sourcePath, "utf8");
  const parsed = JSON.parse(raw) as Record<string, any>;
  if (!parsed?.installed?.client_id || !parsed.installed.client_secret) {
    throw new Error("The saved Google OAuth JSON is invalid. Import the Desktop OAuth JSON again.");
  }
  const destinationPath = path.join(account.configPath!, "client_secret.json");
  fs.writeFileSync(destinationPath, JSON.stringify(parsed, null, 2), { mode: 0o600 });
  try {
    fs.chmodSync(destinationPath, 0o600);
  } catch {
    // macOS may already apply the requested mode.
  }
  return googleOAuthSetupStatus(accountId);
}

export function setConnectorServiceEnabled(accountId: string, serviceId: ConnectorServiceID, enabled: boolean) {
  const store = readConnectorStore();
  const account = store.accounts.find((candidate) => candidate.id === accountId);
  if (!account) throw new Error("Connector account was not found.");
  const service = connectorServices.find((candidate) => candidate.id === serviceId);
  if (!service) throw new Error("Connector service was not found.");
  if (service.provider !== account.provider) throw new Error("This service does not belong to that account.");
  const serviceIDs = new Set(account.enabledServiceIDs);
  if (enabled) serviceIDs.add(serviceId);
  else serviceIDs.delete(serviceId);
  account.enabledServiceIDs = Array.from(serviceIDs);
  account.updatedAt = new Date().toISOString();
  store.updatedAt = account.updatedAt;
  writeConnectorStore(store);
  return loadConnectorSnapshot();
}

export function buildGoogleCommandPlan(accountId: string, operation: GoogleConnectorOperation, approved = false): GoogleCommandPlan {
  const snapshot = loadConnectorSnapshot();
  const account = snapshot.accounts.find((candidate) => candidate.id === accountId && candidate.provider === "google");
  if (!account?.configPath) throw new Error("Google account config path is missing.");
  const requiresApproval = googleOperationRequiresApproval(operation);
  if (requiresApproval && !approved) throw new Error(`Approval is required before ${operation.kind}.`);
  if (operation.kind === "applyGmailLabel" && !gmailWriteBackLabels.includes(operation.labelName)) {
    throw new Error(`Unsupported Gmail label: ${operation.labelName}`);
  }
  const executablePath = snapshot.gwsStatus.resolvedExecutable || snapshot.gwsStatus.bundledPath;
  const args = googleArguments(operation);
  return {
    executablePath,
    arguments: args,
    environment: { GOOGLE_WORKSPACE_CLI_CONFIG_DIR: account.configPath },
    requiresApproval,
    displayCommand: [executablePath, ...args].map(shellEscape).join(" ")
  };
}

export async function runGoogleCommandPlan(plan: GoogleCommandPlan) {
  const env = { ...process.env, ...plan.environment };
  try {
    const { stdout } = await execFileAsync(plan.executablePath, plan.arguments, {
      env,
      encoding: "utf8",
      maxBuffer: 20 * 1024 * 1024
    });
    return String(stdout);
  } catch (error) {
    throw new Error(readableGoogleCommandError(error));
  }
}

export async function installPinnedGoogleCLI() {
  const root = bundledGwsInstallRoot();
  fs.mkdirSync(root, { recursive: true });
  const { stdout, stderr } = await execFileAsync("npm", ["install", "--prefix", root, `@googleworkspace/cli@${pinnedGwsVersion}`], {
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024
  });
  return { ok: true, output: `${stdout}${stderr}`.trim(), snapshot: loadConnectorSnapshot() };
}

export function planGmailMetadataSearches(options: GmailSyncOptions = {}) {
  const intent = String(options.userIntent ?? "").trim();
  const intentText = normalizeGmailCandidateText(intent);
  const timeframeDays = gmailSyncTimeframeDays(options, intentText);
  const intentTerms = gmailIntentSearchTerms(intentText);
  const base = gmailMetadataSearchBase(timeframeDays);
  const actionTerms = '"action required" OR "please" OR "can you" OR "could you" OR "follow up" OR "waiting on" OR "waiting for" OR "reply needed" OR "due" OR "deadline" OR "approve" OR "review" OR "confirm"';
  const unreadTerms = '"please" OR "can you" OR "could you" OR "follow up" OR "due" OR "deadline" OR "approve" OR "review" OR "confirm"';
  const queries = [
    `${base} (${actionTerms})`,
    `${base} is:unread (${unreadTerms})`
  ];
  if (intentTerms.length) {
    queries.unshift(`${base} (${actionTerms}) (${intentTerms.map((term) => `"${term}"`).join(" OR ")})`);
  }
  return [...new Set(queries)];
}

export function planGmailFallbackMetadataSearches(options: GmailSyncOptions = {}) {
  const intentText = normalizeGmailCandidateText(String(options.userIntent ?? "").trim());
  const timeframeDays = gmailSyncTimeframeDays(options, intentText);
  const base = gmailMetadataSearchBase(timeframeDays);
  return [
    `${base} is:unread`,
    `${base} is:important`,
    base
  ];
}

export function planGmailDirectSearches(options: GmailSearchOptions = {}) {
  const rawQuery = String(options.query ?? "").trim();
  const rawIntent = String(options.userIntent ?? options.query ?? "").trim();
  const intentText = normalizeGmailCandidateText(rawIntent);
  const timeframeDays = gmailSearchTimeframeDays(options, intentText);
  const base = gmailMetadataSearchBase(timeframeDays);
  const queryLooksExplicit = /\b(from|to|subject|has|filename|label|category|after|before|newer|older):|["()]/i.test(rawQuery);
  if (queryLooksExplicit) {
    const safeQuery = rawQuery.replace(/\b(in:anywhere|older_than:\d+[ymd]|larger:\S+|smaller:\S+)\b/gi, "").trim();
    return [...new Set([`${base} ${safeQuery}`.trim()])];
  }
  const terms = gmailIntentSearchTerms(intentText);
  if (terms.length === 0) return [base];
  const termQuery = terms.map((term) => `"${term}"`).join(" OR ");
  return [...new Set([
    `${base} (${termQuery})`,
    `${base} is:unread (${termQuery})`,
    `${base} is:important (${termQuery})`
  ])];
}

export async function searchGmailMetadata(accountId: string, options: GmailSearchOptions = {}) {
  const queries = planGmailDirectSearches(options);
  const maxResults = clamp(options.maxResults ?? 10, 1, 20);
  const mergedItems = new Map<string, ConnectorItem>();
  for (const query of queries) {
    const plan = buildGoogleCommandPlan(accountId, { kind: "gmailSearchMetadata", query, maxResults });
    const stdout = await runGoogleCommandPlan(plan);
    const listedItems = parseGmailMetadataOutput(stdout, accountId);
    for (const item of listedItems) {
      try {
        const metadataPlan = buildGoogleCommandPlan(accountId, { kind: "gmailFetchMetadata", messageId: item.externalId });
        const metadata = await runGoogleCommandPlan(metadataPlan);
        for (const metadataItem of parseGmailMetadataOutput(metadata, accountId)) {
          mergedItems.set(metadataItem.externalId, metadataItem);
        }
      } catch {
        mergedItems.set(item.externalId, item);
      }
    }
  }
  return {
    ok: true,
    accountID: accountId,
    resultCount: mergedItems.size,
    queries,
    messages: [...mergedItems.values()]
  };
}

export async function searchLocalMessages(options: LocalMessagesSearchOptions = {}) {
  const terms = localMessageSearchTerms(options);
  if (terms.length === 0) {
    throw new Error("Give me a specific person, word, or appointment detail to search in Messages.");
  }
  const maxResults = clamp(options.maxResults ?? 10, 1, 25);
  const timeframeDays = clamp(options.timeframeDays ?? 30, 1, 365);
  const cutoffSeconds = Math.floor((Date.now() - timeframeDays * 24 * 60 * 60 * 1000) / 1000) - macAbsoluteEpochOffsetSeconds;
  const cutoffNanoseconds = cutoffSeconds * 1_000_000_000;
  const textFields = ["lower(coalesce(message.text, ''))", "lower(coalesce(handle.id, ''))"];
  const likeConditions = terms.flatMap((term) => {
    const escaped = sqliteLikeLiteral(term);
    return textFields.map((field) => `${field} LIKE '%${escaped}%' ESCAPE '\\'`);
  });
  const sql = `
SELECT
  message.ROWID AS id,
  coalesce(message.guid, '') AS guid,
  message.date AS date,
  coalesce(message.text, '') AS text,
  coalesce(handle.id, '') AS handle,
  coalesce(message.is_from_me, 0) AS isFromMe
FROM message
LEFT JOIN handle ON message.handle_id = handle.ROWID
WHERE (message.date >= ${cutoffNanoseconds} OR message.date >= ${cutoffSeconds})
  AND (${likeConditions.join(" OR ")})
ORDER BY message.date DESC
LIMIT ${maxResults};
`.trim();
  try {
    const { stdout } = await execFileAsync("/usr/bin/sqlite3", ["-json", messagesDatabasePath(), sql], {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024
    });
    const rows = JSON.parse(String(stdout || "[]")) as Array<Record<string, unknown>>;
    return {
      ok: true,
      queryTerms: terms,
      resultCount: rows.length,
      messages: rows.map((row) => ({
        id: stringValue(row.id) || "",
        guid: stringValue(row.guid) || "",
        handle: stringValue(row.handle) || "",
        text: stringValue(row.text) || "",
        date: localMessageDate(row.date),
        isFromMe: Boolean(Number(row.isFromMe ?? 0))
      } satisfies LocalMessageSearchResult))
    };
  } catch (error) {
    throw new Error(readableLocalMessagesError(error));
  }
}

export function localConnectorAccessStatuses(): ConnectorAccessStatus[] {
  const rawAppleStatus = cachedAppleEventKitRawStatus();
  const appleStatuses = rawAppleStatus ? mapAppleEventKitStatus(rawAppleStatus) : defaultAppleEventKitStatus();
  return [appleStatuses.reminders, appleStatuses.calendar, messagesAccessStatus()];
}

function defaultAppleEventKitStatus(): AppleEventKitStatus {
  if (process.platform !== "darwin") {
    return {
      reminders: {
        serviceID: "appleReminders",
        status: "notSupported",
        label: "Mac only",
        detail: "Apple Reminders integration is only available on macOS."
      },
      calendar: {
        serviceID: "appleCalendar",
        status: "notSupported",
        label: "Mac only",
        detail: "Apple Calendar integration is only available on macOS."
      }
    };
  }
  return {
    reminders: {
      serviceID: "appleReminders",
      status: "unknown",
      label: "Check access",
      detail: "Open Assist has not checked Apple Reminders access yet.",
      permissionKind: "appleEventKit"
    },
    calendar: {
      serviceID: "appleCalendar",
      status: "unknown",
      label: "Check access",
      detail: "Open Assist has not checked Apple Calendar access yet.",
      permissionKind: "appleEventKit"
    }
  };
}

function appleEventKitAccessStatus(serviceID: "appleReminders" | "appleCalendar", rawStatus: string): ConnectorAccessStatus {
  const isReminders = serviceID === "appleReminders";
  const displayName = isReminders ? "Apple Reminders" : "Apple Calendar";
  const normalized = String(rawStatus ?? "").trim();
  if (process.platform !== "darwin") {
    return {
      serviceID,
      status: "notSupported",
      label: "Mac only",
      detail: `${displayName} integration is only available on macOS.`
    };
  }
  if (normalized === "authorized" || normalized === "fullAccess" || normalized === "granted") {
    return {
      serviceID,
      status: "granted",
      label: "Access ready",
      detail: `Open Assist can read and write ${displayName} on this Mac.`
    };
  }
  if (normalized === "denied" || normalized === "restricted") {
    return {
      serviceID,
      status: "blocked",
      label: "Access blocked",
      detail: `Grant ${displayName} access in macOS Privacy & Security settings.`,
      permissionKind: "appleEventKit"
    };
  }
  if (normalized === "writeOnly") {
    return {
      serviceID,
      status: "blocked",
      label: "Needs full access",
      detail: `Open Assist needs full ${displayName} access so it can read items before editing or reporting them.`,
      permissionKind: "appleEventKit"
    };
  }
  if (normalized === "devUnsigned" || normalized === "identityMismatch") {
    return {
      serviceID,
      status: "blocked",
      label: "Helper identity issue",
      detail: normalized === "devUnsigned"
        ? `The development helper for ${displayName} is not stably signed.`
        : `${displayName} access belongs to a different helper build.`,
      permissionKind: "appleEventKit"
    };
  }
  return {
    serviceID,
    status: "unknown",
    label: "Needs access",
    detail: `Grant ${displayName} access to let Open Assist read and create items.`,
    permissionKind: "appleEventKit"
  };
}

function mapAppleEventKitStatus(data: any): AppleEventKitStatus {
  return {
    reminders: appleEventKitAccessStatus("appleReminders", String(data?.reminders ?? "")),
    calendar: appleEventKitAccessStatus("appleCalendar", String(data?.calendar ?? ""))
  };
}

export async function listAppleReminders(options: AppleReminderListOptions = {}): Promise<AppleReminderRecord[]> {
  const data = await executeAppleEventKitCommand("reminders", {
    command: "list-reminders",
    ...options
  });
  return Array.isArray(data?.reminders) ? data.reminders as AppleReminderRecord[] : [];
}

export type AppleReminderSearchOptions = {
  query: string;
  calendar?: string;
  includeCompleted?: boolean;
  completedOnly?: boolean;
  limit?: number;
};

export type AppleReminderSearchResult = {
  reminders: AppleReminderRecord[];
  totalMatches: number;
  completedMatches: number;
  incompleteMatches: number;
};

export async function searchAppleReminders(options: AppleReminderSearchOptions): Promise<AppleReminderSearchResult> {
  const data = await executeAppleEventKitCommand("reminders", {
    command: "search-reminders",
    ...options
  });
  return {
    reminders: Array.isArray(data?.reminders) ? data.reminders as AppleReminderRecord[] : [],
    totalMatches: Number(data?.totalMatches ?? 0),
    completedMatches: Number(data?.completedMatches ?? 0),
    incompleteMatches: Number(data?.incompleteMatches ?? 0)
  };
}

export async function addAppleReminder(input: AppleReminderInput): Promise<AppleReminderRecord> {
  const data = await executeAppleEventKitCommand("reminders", {
    command: "add-reminder",
    ...input
  });
  if (!data?.reminder) throw new Error("Apple Reminders did not return the created reminder.");
  return data.reminder as AppleReminderRecord;
}

export async function updateAppleReminder(input: AppleReminderUpdateInput): Promise<AppleReminderRecord> {
  const data = await executeAppleEventKitCommand("reminders", {
    command: "update-reminder",
    ...input
  });
  if (!data?.reminder) throw new Error("Apple Reminders did not return the updated reminder.");
  return data.reminder as AppleReminderRecord;
}

export async function completeAppleReminder(id: string, completed = true): Promise<AppleReminderRecord> {
  const data = await executeAppleEventKitCommand("reminders", {
    command: "complete-reminder",
    id,
    completed
  });
  if (!data?.reminder) throw new Error("Apple Reminders did not return the updated reminder.");
  return data.reminder as AppleReminderRecord;
}

export async function listAppleCalendarEvents(options: AppleCalendarEventListOptions = {}): Promise<AppleCalendarEventRecord[]> {
  const data = await executeAppleEventKitCommand("calendar", {
    command: "list-events",
    ...options
  });
  return Array.isArray(data?.events) ? data.events as AppleCalendarEventRecord[] : [];
}

export async function addAppleCalendarEvent(input: AppleCalendarEventInput): Promise<AppleCalendarEventRecord> {
  const data = await executeAppleEventKitCommand("calendar", {
    command: "add-event",
    ...input
  });
  if (!data?.event) throw new Error("Apple Calendar did not return the created event.");
  return data.event as AppleCalendarEventRecord;
}

function messagesAccessStatus(): ConnectorAccessStatus {
  if (process.platform !== "darwin") {
    return {
      serviceID: "messages",
      status: "notSupported",
      label: "Mac only",
      detail: "Messages search is only available on macOS."
    };
  }
  try {
    execFileSync("/usr/bin/sqlite3", [
      "-json",
      messagesDatabasePath(),
      "SELECT count(*) AS count FROM message LIMIT 1;"
    ], {
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 1_500
    });
    return {
      serviceID: "messages",
      status: "granted",
      label: "Access ready",
      detail: "Open Assist can read local Messages on this Mac."
    };
  } catch (error) {
    const detail = readableLocalMessagesError(error);
    const blocked = /Full Disk Access|macOS privacy|permission|authorization denied/i.test(detail);
    return {
      serviceID: "messages",
      status: blocked ? "blocked" : "unknown",
      label: blocked ? "Needs Full Disk Access" : "Check access",
      detail,
      permissionKind: "fullDiskAccess"
    };
  }
}

export async function syncGmailMetadataToReviewInbox(accountId: string, queriesOrOptions: string[] | GmailSyncOptions = gmailDefaultSearches) {
  const queries = Array.isArray(queriesOrOptions)
    ? queriesOrOptions
    : planGmailMetadataSearches(queriesOrOptions);
  const maxResults = Array.isArray(queriesOrOptions)
    ? 8
    : clamp(queriesOrOptions.maxResults ?? 8, 1, 20);
  const mergedItems = new Map<string, ConnectorItem>();
  const executedQueries: string[] = [];
  const runQueries = async (candidateQueries: string[]) => {
    for (const query of candidateQueries) {
      executedQueries.push(query);
      const plan = buildGoogleCommandPlan(accountId, { kind: "gmailSearchMetadata", query, maxResults });
      const stdout = await runGoogleCommandPlan(plan);
      const listedItems = parseGmailMetadataOutput(stdout, accountId);
      for (const item of listedItems) {
        try {
          const metadataPlan = buildGoogleCommandPlan(accountId, { kind: "gmailFetchMetadata", messageId: item.externalId });
          const metadata = await runGoogleCommandPlan(metadataPlan);
          for (const metadataItem of parseGmailMetadataOutput(metadata, accountId, { onlyActionable: true })) {
            mergedItems.set(metadataItem.externalId, metadataItem);
          }
        } catch {
          // Keep noisy list-only results out of Review Inbox. A real item needs metadata.
        }
      }
    }
  };
  await runQueries(queries);
  if (mergedItems.size === 0 && !Array.isArray(queriesOrOptions)) {
    await runQueries(planGmailFallbackMetadataSearches(queriesOrOptions));
  }
  const items = [...mergedItems.values()];
  upsertConnectorItems(items);
  const snapshot = loadConnectorSnapshot();
  // Scope reviewItems to THIS account and the messages this sync actually merged,
  // so the model doesn't narrate stale/cross-account inbox contents as "what I just found".
  const importedExternalIds = new Set(items.map((item) => item.externalId));
  return {
    ok: true,
    importedCount: items.length,
    queries: executedQueries,
    reviewItems: snapshot.items.filter((item) =>
      item.accountId === accountId
      && importedExternalIds.has(item.externalId)
      && reviewStatuses.has(item.status)
    ),
    snapshot
  };
}

export function upsertConnectorItems(items: ConnectorItem[]) {
  const store = readConnectorStore();
  const now = new Date().toISOString();
  for (const incoming of items) {
    const index = store.items.findIndex((item) =>
      item.sourceService === incoming.sourceService
      && item.accountId === incoming.accountId
      && item.externalId === incoming.externalId
    );
    if (index >= 0) {
      const existing = store.items[index];
      if (shouldCreateConflict(existing, incoming)) {
        store.items[index] = {
          ...existing,
          status: "conflict",
          syncState: "conflict",
          updatedAt: now
        };
        store.conflicts.push({
          id: `connector-conflict-${randomUUID()}`,
          itemId: existing.id,
          sourceService: existing.sourceService,
          accountId: existing.accountId,
          externalSummary: incoming.snippet,
          localSummary: existing.snippet,
          externalVersion: incoming.lastExternalVersion,
          localVersion: existing.lastLocalVersion,
          detectedAt: now
        });
      } else {
        store.items[index] = {
          ...incoming,
          id: existing.id,
          createdAt: existing.createdAt,
          updatedAt: now
        };
      }
    } else {
      store.items.push({ ...incoming, updatedAt: now });
    }
  }
  store.updatedAt = now;
  writeConnectorStore(store);
}

export function markConnectorItem(itemId: string, status: ConnectorItemStatus) {
  const store = readConnectorStore();
  const item = store.items.find((candidate) => candidate.id === itemId);
  if (!item) throw new Error("Connector item was not found.");
  item.status = status;
  item.updatedAt = new Date().toISOString();
  store.updatedAt = item.updatedAt;
  writeConnectorStore(store);
  return loadConnectorSnapshot();
}

export function ignoreConnectorReviewItems(accountId?: string) {
  const store = readConnectorStore();
  const now = new Date().toISOString();
  let count = 0;
  for (const item of store.items) {
    if (!connectorReviewStatuses.has(item.status)) continue;
    if (accountId && item.accountId !== accountId) continue;
    item.status = "ignored";
    item.updatedAt = now;
    count += 1;
  }
  store.updatedAt = now;
  writeConnectorStore(store);
  return { count, snapshot: loadConnectorReviewInbox() };
}

export function saveConnectorItemToBacklogInput(itemId: string) {
  const snapshot = loadConnectorSnapshot();
  const item = snapshot.items.find((candidate) => candidate.id === itemId);
  if (!item) throw new Error("Connector item was not found.");
  return {
    id: item.id,
    title: item.title,
    dayID: "backlog",
    status: "todo",
    checked: false,
    detailsMarkdown: [
      item.snippet,
      "",
      `Source: ${serviceName(item.sourceService)}`,
      item.person ? `Person: ${item.person}` : "",
      item.threadId ? `Thread: ${item.threadId}` : "",
      `External ID: ${item.externalId}`
    ].filter(Boolean).join("\n"),
    steps: [],
    links: []
  };
}

export function connectorSkillGuide() {
  return connectorServices.map((service) => ({
    id: service.id,
    title: `${service.displayName} Connector Skill`,
    rules: skillRulesFor(service.id)
  }));
}

function supportRoot() {
  if (process.env.OPENASSIST_SUPPORT_DIR?.trim()) return process.env.OPENASSIST_SUPPORT_DIR.trim();
  return path.join(os.homedir(), "Library", "Application Support", "Open Assist");
}

function connectorStorePath() {
  return path.join(connectorsRoot(), "connectors.json");
}

function readConnectorStore(): ConnectorStoreFile {
  const fallback: ConnectorStoreFile = {
    version: 1,
    accounts: localConnectorAccounts(),
    items: [],
    conflicts: [],
    mutationRequests: [],
    updatedAt: new Date().toISOString()
  };
  try {
    const parsed = JSON.parse(fs.readFileSync(connectorStorePath(), "utf8")) as ConnectorStoreFile;
    return ensureLocalAccounts({
      version: 1,
      accounts: Array.isArray(parsed.accounts) ? parsed.accounts : [],
      items: Array.isArray(parsed.items) ? parsed.items : [],
      conflicts: Array.isArray(parsed.conflicts) ? parsed.conflicts : [],
      mutationRequests: Array.isArray(parsed.mutationRequests) ? parsed.mutationRequests : [],
      updatedAt: typeof parsed.updatedAt === "string" ? parsed.updatedAt : new Date().toISOString()
    });
  } catch {
    return fallback;
  }
}

function writeConnectorStore(store: ConnectorStoreFile) {
  fs.mkdirSync(path.dirname(connectorStorePath()), { recursive: true });
  fs.writeFileSync(connectorStorePath(), `${JSON.stringify(ensureLocalAccounts(store), null, 2)}\n`, "utf8");
}

function ensureLocalAccounts(store: ConnectorStoreFile): ConnectorStoreFile {
  const accounts = [...store.accounts];
  for (const account of localConnectorAccounts()) {
    if (!accounts.some((candidate) => candidate.id === account.id)) accounts.push(account);
  }
  return { ...store, accounts };
}

function localConnectorAccounts(): ConnectorAccount[] {
  const now = new Date().toISOString();
  return [
    {
      id: "apple-this-mac",
      provider: "apple",
      label: "This Mac",
      enabledServiceIDs: [],
      syncCursors: {},
      createdAt: now,
      updatedAt: now
    },
    {
      id: "local-this-mac",
      provider: "local",
      label: "This Mac",
      enabledServiceIDs: [],
      syncCursors: {},
      createdAt: now,
      updatedAt: now
    }
  ];
}

function getGoogleCLIStatus(): GoogleCLIStatus {
  const now = Date.now();
  if (cachedGoogleCLIStatus && now - cachedGoogleCLIStatus.checkedAt < googleCLIStatusCacheMs) {
    return cachedGoogleCLIStatus.status;
  }
  const bundledPath = bundledGwsBinaryPath();
  const pathExecutable = findPathExecutable("gws");
  const resolvedExecutable = fs.existsSync(bundledPath) ? bundledPath : pathExecutable;
  const version = resolvedExecutable ? readGwsVersion(resolvedExecutable) : undefined;
  const status = {
    pinnedVersion: pinnedGwsVersion,
    bundledPath,
    pathExecutable,
    resolvedExecutable,
    version,
    supported: Boolean(version && version.includes(pinnedGwsVersion)),
    installCommand: `npm install --prefix ${shellEscape(bundledGwsInstallRoot())} @googleworkspace/cli@${pinnedGwsVersion}`,
    setupCommand: "gws auth setup && gws auth login --services gmail,calendar,tasks,drive,people"
  };
  cachedGoogleCLIStatus = { checkedAt: now, status };
  return status;
}

function googleConnectorAccount(accountId: string) {
  const store = ensureLocalAccounts(readConnectorStore());
  const account = store.accounts.find((candidate) => candidate.id === accountId && candidate.provider === "google");
  if (!account?.configPath) throw new Error("Google account config path is missing.");
  return account;
}

function currentGoogleCloudProject() {
  try {
    const output = execFileSync("gcloud", ["config", "get-value", "project"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).trim();
    return output && output !== "(unset)" ? output : undefined;
  } catch {
    return undefined;
  }
}

function readGoogleClientSecret(clientSecretPath: string) {
  try {
    const parsed = JSON.parse(fs.readFileSync(clientSecretPath, "utf8")) as {
      installed?: {
        client_id?: string;
        client_secret?: string;
        project_id?: string;
      };
    };
    return parsed?.installed ? parsed : undefined;
  } catch {
    return undefined;
  }
}

function sharedGoogleOAuthDir() {
  return path.join(connectorsRoot(), "Google", "_shared");
}

function sharedGoogleClientSecretPath() {
  return path.join(sharedGoogleOAuthDir(), "client_secret.json");
}

function copySharedGoogleClientSecret(configPath: string) {
  const sourcePath = findReusableGoogleClientSecretPath();
  if (!sourcePath) return false;
  try {
    fs.mkdirSync(configPath, { recursive: true });
    const destinationPath = path.join(configPath, "client_secret.json");
    fs.copyFileSync(sourcePath, destinationPath);
    fs.chmodSync(destinationPath, 0o600);
    return true;
  } catch {
    return false;
  }
}

function findReusableGoogleClientSecretPath(excludeAccountId?: string) {
  const sharedPath = sharedGoogleClientSecretPath();
  if (readGoogleClientSecret(sharedPath)) return sharedPath;
  const store = ensureLocalAccounts(readConnectorStore());
  for (const account of store.accounts) {
    if (account.provider !== "google" || !account.configPath || account.id === excludeAccountId) continue;
    const candidatePath = path.join(account.configPath, "client_secret.json");
    if (readGoogleClientSecret(candidatePath)) return candidatePath;
  }
  return undefined;
}

function readGoogleAuthStatus(configPath: string) {
  const encryptedCredentialsPath = path.join(configPath, "credentials.enc");
  const plainCredentialsPath = path.join(configPath, "credentials.json");
  const tokenCachePath = path.join(configPath, "token_cache.json");
  const encryptedCredentialsExists = fs.existsSync(encryptedCredentialsPath);
  const plainCredentialsExists = fs.existsSync(plainCredentialsPath);
  const tokenCacheExists = fs.existsSync(tokenCachePath);
  const hasCredentials = encryptedCredentialsExists || plainCredentialsExists || tokenCacheExists;
  const storage = encryptedCredentialsExists
    ? "encrypted"
    : plainCredentialsExists
      ? "plain"
      : tokenCacheExists
        ? "token-cache"
        : undefined;
  return {
    auth_method: hasCredentials ? "oauth2" : "none",
    storage,
    encrypted_credentials_exists: encryptedCredentialsExists,
    plain_credentials_exists: plainCredentialsExists,
    token_cache_exists: tokenCacheExists,
    project_id: readGoogleClientSecret(path.join(configPath, "client_secret.json"))?.installed?.project_id
  };
}

function bundledGwsInstallRoot() {
  return path.join(supportRoot(), "Tools", "gws", pinnedGwsVersion);
}

function bundledGwsBinaryPath() {
  return path.join(bundledGwsInstallRoot(), "node_modules", ".bin", process.platform === "win32" ? "gws.cmd" : "gws");
}

function googleConfigDirForLabel(label: string) {
  return path.join(connectorsRoot(), "Google", slug(label), "gws");
}

function findPathExecutable(binary: string) {
  try {
    const result = execFileSyncText("/usr/bin/env", ["which", binary]).trim();
    return result || undefined;
  } catch {
    return undefined;
  }
}

function readGwsVersion(executablePath: string) {
  try {
    return execFileSyncText(executablePath, ["--version"]).trim();
  } catch {
    return undefined;
  }
}

function execFileSyncText(command: string, args: string[]) {
  const child = fs.existsSync(command)
    ? execFileSync(command, args, { encoding: "utf8", timeout: 1_500 })
    : "";
  return typeof child === "string" ? child : "";
}

function commandErrorText(error: unknown) {
  const typed = error as { message?: unknown; stdout?: unknown; stderr?: unknown };
  return [
    typeof typed.stderr === "string" ? typed.stderr : "",
    typeof typed.stdout === "string" ? typed.stdout : "",
    error instanceof Error ? error.message : String(error ?? "")
  ].filter(Boolean).join("\n").trim();
}

function readableGoogleCommandError(error: unknown) {
  const text = commandErrorText(error);
  const projectMatch = text.match(/project[ =:]([a-z0-9-]+)/i) ?? text.match(/project\s+([a-z0-9-]+)/i);
  const projectID = projectMatch?.[1];
  if (text.includes("serviceusage.services.use") || text.includes("roles/serviceusage.serviceUsageConsumer")) {
    const projectLabel = projectID ? ` "${projectID}"` : "";
    const url = projectID
      ? `https://console.developers.google.com/iam-admin/iam?project=${projectID}`
      : "Google Cloud IAM";
    return `Google Cloud permission needed for project${projectLabel}. Grant your Google account the "Service Usage Consumer" role, then try Sync Gmail again. Open: ${url}`;
  }
  if (/invalid_scope/i.test(text)) {
    return "Google rejected the requested scopes. Re-run Google login from Connector Settings. If it keeps happening, replace the OAuth JSON with a Desktop app client and try again.";
  }
  if (/No OAuth client configured/i.test(text) || /client_secret\.json/i.test(text)) {
    return "Google OAuth is not ready for this account. Import the Desktop OAuth JSON in Connector Settings, then run Login.";
  }
  if (/insufficient authentication scopes|Request had insufficient authentication scopes/i.test(text)) {
    return "Google login needs more access. Run Login again from Connector Settings and approve Gmail access.";
  }
  return text || "Google connector command failed.";
}

function googleOperationRequiresApproval(operation: GoogleConnectorOperation) {
  return ![
    "authSetup",
    "authLogin",
    "authStatus",
    "gmailSearchMetadata",
    "gmailFetchMetadata",
    "gmailFetchBody",
    "calendarList",
    "calendarAgenda",
    "tasksList",
    "driveSearch",
    "peopleSearch"
  ].includes(operation.kind);
}

function googleArguments(operation: GoogleConnectorOperation) {
  switch (operation.kind) {
    case "authSetup":
      return ["auth", "setup"];
    case "authLogin":
      return ["auth", "login", "--services", (operation.scopes?.length ? operation.scopes : ["gmail", "calendar", "tasks", "drive", "people"]).join(",")];
    case "authStatus":
      return ["auth", "status"];
    case "gmailSearchMetadata":
      return ["gmail", "users", "messages", "list", "--params", jsonArg({ userId: "me", q: operation.query, maxResults: clamp(operation.maxResults ?? 10, 1, 50) })];
    case "gmailFetchMetadata":
      return ["gmail", "users", "messages", "get", "--params", jsonArg({ userId: "me", id: operation.messageId, format: "metadata", metadataHeaders: ["From", "Subject", "Date"] })];
    case "gmailFetchBody":
      return ["gmail", "users", "messages", "get", "--params", jsonArg({ userId: "me", id: operation.messageId, format: "full" })];
    case "calendarList":
      return ["calendar", "events", "list", "--params", jsonArg({ calendarId: "primary", timeMin: operation.timeMin, timeMax: operation.timeMax, singleEvents: true, orderBy: "startTime" })];
    case "calendarAgenda":
      return ["calendar", "+agenda", "--today"];
    case "tasksList":
      return ["tasks", "tasklists", "list", "--params", jsonArg({ maxResults: 50 })];
    case "driveSearch":
      return ["drive", "files", "list", "--params", jsonArg({ q: operation.query, pageSize: clamp(operation.pageSize ?? 10, 1, 25), fields: "files(id,name,mimeType,webViewLink,modifiedTime,owners)" })];
    case "peopleSearch":
      return ["people", "people", "searchContacts", "--params", jsonArg({ query: operation.query, pageSize: clamp(operation.pageSize ?? 10, 1, 20), readMask: "names,emailAddresses,phoneNumbers,organizations" })];
    case "applyGmailLabel":
      return ["gmail", "users", "messages", "modify", "--params", jsonArg({ userId: "me", id: operation.messageId }), "--json", jsonArg({ addLabelIds: [operation.labelName], removeLabelIds: [] })];
    case "sendEmail":
      return ["gmail", "+send", "--to", operation.to, "--subject", operation.subject, "--body", operation.body];
    case "archiveEmail":
      return ["gmail", "users", "messages", "modify", "--params", jsonArg({ userId: "me", id: operation.messageId }), "--json", jsonArg({ removeLabelIds: ["INBOX"] })];
    case "deleteEmail":
      return ["gmail", "users", "messages", "trash", "--params", jsonArg({ userId: "me", id: operation.messageId })];
    case "createTask":
      return ["tasks", "tasks", "insert", "--params", jsonArg({ tasklist: "@default" }), "--json", jsonArg({ title: operation.title, notes: operation.notes, due: operation.dueDate })];
    case "updateTask":
      return ["tasks", "tasks", "patch", "--params", jsonArg({ tasklist: operation.taskListId, task: operation.taskId }), "--json", jsonArg({ title: operation.title, notes: operation.notes })];
    case "markTaskDone":
      return ["tasks", "tasks", "patch", "--params", jsonArg({ tasklist: operation.taskListId, task: operation.taskId }), "--json", jsonArg({ status: "completed" })];
    case "deleteTask":
      return ["tasks", "tasks", "delete", "--params", jsonArg({ tasklist: operation.taskListId, task: operation.taskId })];
    case "createCalendarEvent":
      return ["calendar", "events", "insert", "--params", jsonArg({ calendarId: "primary" }), "--json", jsonArg({ summary: operation.summary, start: { dateTime: operation.start }, end: { dateTime: operation.end } })];
    case "updateCalendarEvent":
      return ["calendar", "events", "patch", "--params", jsonArg({ calendarId: operation.calendarId, eventId: operation.eventId }), "--json", jsonArg({ summary: operation.summary })];
    case "deleteCalendarEvent":
      return ["calendar", "events", "delete", "--params", jsonArg({ calendarId: operation.calendarId, eventId: operation.eventId })];
  }
}

export function parseGmailMetadataOutput(stdout: string, accountId: string, options: { onlyActionable?: boolean } = {}): ConnectorItem[] {
  const parsed = parseJSONLinesOrJSON(stdout);
  const records = extractRecordArray(parsed);
  return records.flatMap((record) => {
    const externalId = stringValue(record.id ?? record.messageId);
    if (!externalId) return [];
    const headers = gmailHeaders(record);
    const subject = stringValue(record.subject) || headers.subject || "(No subject)";
    const sender = stringValue(record.from) || headers.from || "";
    const snippet = stringValue(record.snippet) || subject;
    if (options.onlyActionable && !isActionableGmailCandidate(subject, snippet, sender)) return [];
    const now = new Date().toISOString();
    return [{
      id: `connector-${randomUUID()}`,
      sourceService: "gmail",
      accountId,
      externalId,
      threadId: stringValue(record.threadId),
      kind: actionKind(subject, snippet),
      title: taskTitle(subject, snippet),
      snippet,
      date: gmailRecordDate(record, headers) || now,
      status: "candidate",
      person: sender || undefined,
      syncState: "externalOnly",
      lastExternalVersion: stringValue(record.historyId ?? record.etag),
      fullBodyFetched: false,
      rawMetadata: { subject, sender, threadId: stringValue(record.threadId) || "" },
      createdAt: now,
      updatedAt: now
    } satisfies ConnectorItem];
  });
}

function parseJSONLinesOrJSON(stdout: string): unknown {
  const trimmed = stdout.trim();
  if (!trimmed) return [];
  try {
    return JSON.parse(trimmed);
  } catch {
    return trimmed
      .split(/\n+/)
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return undefined;
        }
      })
      .filter(Boolean);
  }
}

function extractRecordArray(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value.flatMap(extractRecordArray);
  if (!value || typeof value !== "object") return [];
  const record = value as Record<string, unknown>;
  for (const key of ["messages", "items", "results", "threads", "files", "connections"]) {
    if (Array.isArray(record[key])) return (record[key] as unknown[]).flatMap(extractRecordArray);
  }
  return [record];
}

function gmailHeaders(record: Record<string, unknown>) {
  const payload = record.payload && typeof record.payload === "object" ? record.payload as Record<string, unknown> : undefined;
  const headers = Array.isArray(payload?.headers) ? payload.headers as Array<Record<string, unknown>> : [];
  return headers.reduce<Record<string, string>>((result, header) => {
    const name = stringValue(header.name)?.toLowerCase();
    const value = stringValue(header.value);
    if (name && value) result[name] = value;
    return result;
  }, {});
}

function gmailRecordDate(record: Record<string, unknown>, headers: Record<string, string>) {
  const internalDate = Number(stringValue(record.internalDate));
  if (Number.isFinite(internalDate) && internalDate > 0) return new Date(internalDate).toISOString();
  const parsed = headers.date ? Date.parse(headers.date) : NaN;
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : undefined;
}

function actionKind(subject: string, snippet: string): ConnectorItemKind {
  const text = `${subject} ${snippet}`.toLowerCase();
  if (/\bwaiting|following up\b/.test(text)) return "waitingFor";
  if (/\breply|respond\b/.test(text)) return "replyDraft";
  if (/\bfollow up|circle back\b/.test(text)) return "followUp";
  if (/\baction required|approve|approval|review|invoice due|payment due|due|deadline|please|can you|could you|need you|reminder\b/.test(text)) return "task";
  return "backlog";
}

function taskTitle(subject: string, snippet: string) {
  const cleanSubject = subject.trim();
  if (cleanSubject && cleanSubject !== "(No subject)") return cleanSubject;
  return snippet.trim().split(/\s+/).slice(0, 12).join(" ") || "Review email";
}

function isActionableGmailCandidate(subject: string, snippet: string, sender: string) {
  const text = normalizeGmailCandidateText(`${subject} ${snippet}`);
  const senderText = normalizeGmailCandidateText(sender);
  const hasStrongAction = /\b(action required|approval needed|please review|please approve|can you|could you|would you|please send|please call|please confirm|follow up|following up|circle back|waiting on|waiting for|reply needed|respond by|due today|due tomorrow|overdue|deadline|needs your attention)\b/.test(text);
  const hasTaskWord = /\b(approve|approval|review|confirm|send|call|schedule|book|pay|renew|submit|sign|complete|finish|prepare|remind|reminder|deadline|due)\b/.test(text);
  const hasRequestShape = /\b(please|can you|could you|would you|need you|need to|needs to|todo|to-do|task)\b/.test(text);
  const looksLikePassiveSystemMail = /\b(receipt|payment summary|transaction id|statement|newsletter|digest|sale|discount|promotion|security alert|verification code|password reset|login code|one-time code|otp|shipped|delivered|order confirmation)\b/.test(text)
    || /\b(no-?reply|donotreply|do-not-reply|notification|updates)\b/.test(senderText);
  if (hasStrongAction) return true;
  if (looksLikePassiveSystemMail && !/\b(invoice due|payment due|action required|approval needed|please review|please approve|deadline|overdue)\b/.test(text)) return false;
  return hasTaskWord && hasRequestShape;
}

function normalizeGmailCandidateText(value: string) {
  return value.toLowerCase().replace(/[\u2018\u2019]/g, "'").replace(/[\u201c\u201d]/g, "\"");
}

function gmailSyncTimeframeDays(options: GmailSyncOptions, intentText: string) {
  return clamp(
    options.timeframeDays
      ?? (/\btoday\b/.test(intentText) ? 2 : /\byesterday|previous day\b/.test(intentText) ? 3 : 7),
    1,
    30
  );
}

function gmailSearchTimeframeDays(options: GmailSearchOptions, intentText: string) {
  return clamp(
    options.timeframeDays
      ?? (/\btoday\b/.test(intentText) ? 2 : /\byesterday|previous day\b/.test(intentText) ? 3 : 30),
    1,
    365
  );
}

function gmailMetadataSearchBase(timeframeDays: number) {
  return `newer_than:${timeframeDays}d -category:promotions -category:social -in:chats`;
}

function messagesDatabasePath() {
  if (process.env.OPENASSIST_MESSAGES_DB?.trim()) return process.env.OPENASSIST_MESSAGES_DB.trim();
  return path.join(os.homedir(), "Library", "Messages", "chat.db");
}

function localMessageSearchTerms(options: LocalMessagesSearchOptions) {
  const raw = normalizeGmailCandidateText(`${options.query ?? ""} ${options.userIntent ?? ""}`);
  const words = raw
    .replace(/\b(imessage|message|messages|text|texts|sms|check|find|look|search|have|any|for|in|my|me|do|did|there|about)\b/g, " ")
    .split(/[^a-z0-9@.+-]+/i)
    .map((word) => word.trim())
    .filter((word) => word.length >= 3);
  if (/\bappt\b|\bappointment\b/.test(raw)) words.push("appointment", "appt", "schedule", "scheduled");
  if (/\btomorrow\b/.test(raw)) words.push("tomorrow");
  if (/\btoday\b/.test(raw)) words.push("today");
  return [...new Set(words)].slice(0, 8);
}

function sqliteLikeLiteral(value: string) {
  return value
    .toLowerCase()
    .replace(/'/g, "''")
    .replace(/\\/g, "\\\\")
    .replace(/%/g, "\\%")
    .replace(/_/g, "\\_");
}

function localMessageDate(value: unknown) {
  const raw = Number(stringValue(value));
  if (!Number.isFinite(raw)) return new Date().toISOString();
  const secondsSinceMacEpoch = raw > 10_000_000_000 ? raw / 1_000_000_000 : raw;
  return new Date((secondsSinceMacEpoch + macAbsoluteEpochOffsetSeconds) * 1000).toISOString();
}

function readableLocalMessagesError(error: unknown) {
  const text = commandErrorText(error);
  if (/operation not permitted|authorization denied|permission denied|unable to open database file/i.test(text)) {
    return "Messages access is blocked by macOS privacy. Give Open Assist Full Disk Access in System Settings, then try again.";
  }
  if (/no such table/i.test(text)) {
    return "Messages database was found, but it does not look like the macOS Messages database.";
  }
  return text || "Could not search Messages.";
}

function gmailIntentSearchTerms(intentText: string) {
  const stopWords = new Set([
    "about",
    "after",
    "again",
    "anything",
    "back",
    "before",
    "bring",
    "check",
    "could",
    "email",
    "emails",
    "from",
    "gmail",
    "google",
    "have",
    "into",
    "list",
    "mail",
    "need",
    "needs",
    "review",
    "show",
    "sync",
    "task",
    "tasks",
    "that",
    "them",
    "thing",
    "things",
    "this",
    "today",
    "todo",
    "with",
    "what",
    "yesterday"
  ]);
  const seen = new Set<string>();
  const terms: string[] = [];
  for (const raw of intentText.match(/[a-z0-9][a-z0-9._-]{2,}/g) ?? []) {
    const term = raw.replace(/^[-_.]+|[-_.]+$/g, "");
    if (term.length < 3 || stopWords.has(term) || seen.has(term)) continue;
    seen.add(term);
    terms.push(term);
    if (terms.length >= 5) break;
  }
  return terms;
}

function shouldCreateConflict(existing: ConnectorItem, incoming: ConnectorItem) {
  return (existing.syncState === "pendingWrite" || existing.syncState === "writePreview")
    && Boolean(existing.lastLocalVersion)
    && Boolean(existing.lastExternalVersion)
    && Boolean(incoming.lastExternalVersion)
    && existing.lastExternalVersion !== incoming.lastExternalVersion;
}

const reviewStatuses = new Set<ConnectorItemStatus>(["candidate", "review", "failed", "conflict"]);

function serviceName(serviceId: ConnectorServiceID) {
  return connectorServices.find((service) => service.id === serviceId)?.displayName || serviceId;
}

function skillRulesFor(serviceId: ConnectorServiceID) {
  if (serviceId === "gmail") {
    return [
      "Use the connector wrapper, not raw gws commands.",
      "Pass the user's request as userIntent; OpenAssist builds strict Gmail queries and caps result size.",
      "Search metadata first. Fetch full body only when the user opens or reviews the item.",
      "Ask before send, archive, delete, label, or draft write-back."
    ];
  }
  if (serviceId.startsWith("google")) {
    return [
      "Use the connector wrapper, not raw gws commands.",
      "Read context freely after account login.",
      "Ask before any create, update, delete, complete, or doc edit action."
    ];
  }
  if (serviceId === "appleReminders" || serviceId === "appleCalendar") {
    return [
      "Use the native EventKit helper, not AppleScript.",
      "Only write when the user explicitly asks for Apple Reminders or Apple Calendar.",
      "If macOS access is missing, ask the user to grant access in Open Assist Settings."
    ];
  }
  return [
    "Use native/local adapter access.",
    "Read-only in v1.",
    "Extract action candidates into Review Inbox."
  ];
}

function jsonArg(value: Record<string, unknown>) {
  return JSON.stringify(Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined && entry !== null)));
}

function stringValue(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return undefined;
}

function slug(value: string) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    || "google-account";
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function shellEscape(value: string) {
  return /^[A-Za-z0-9_./:=@+-]+$/.test(value) ? value : `'${value.replace(/'/g, "'\\''")}'`;
}
