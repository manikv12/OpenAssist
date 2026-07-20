export type NativePermissionID =
  | "electron.accessibility"
  | "electron.screenRecording"
  | "electron.microphone"
  | "electron.fullDiskAccess"
  | "eventkit.reminders"
  | "eventkit.calendar"
  | "speech.microphone"
  | "speech.recognition"
  | "computerUse.accessibility"
  | "computerUse.screenRecording";

export type NativePermissionState =
  | "notDetermined"
  | "granted"
  | "denied"
  | "restricted"
  | "writeOnly"
  | "unavailable"
  | "identityMismatch"
  | "devUnsigned"
  | "unknown";

export type NativeExecutionIdentity = {
  kind: "electron" | "eventkitHelper" | "speechHelper" | "computerUseHelper";
  displayName: string;
  bundleID?: string;
  teamID?: string;
  designatedRequirement?: string;
  executable?: string;
};

export type NativePermissionSnapshot = {
  id: NativePermissionID;
  state: NativePermissionState;
  canRead: boolean;
  canWrite: boolean;
  owner: NativeExecutionIdentity;
  checkedAt: number;
  needsRestart: boolean;
  settingsURL?: string;
  errorCode?: string;
  detail: string;
};

export type NativePermissionBrokerSnapshot = {
  platformSupported: boolean;
  checkedAt: number;
  permissions: NativePermissionSnapshot[];
};

type PermissionProbeResult = Partial<Omit<NativePermissionSnapshot, "id" | "owner" | "checkedAt">> & {
  state: NativePermissionState;
};

type PermissionDescriptor = {
  id: NativePermissionID;
  owner: NativeExecutionIdentity;
  probe: () => Promise<PermissionProbeResult> | PermissionProbeResult;
  request?: () => Promise<void> | void;
  openSettings?: () => Promise<void> | void;
};

export class NativePermissionRequiredError extends Error {
  readonly retryable = false;

  constructor(
    message: string,
    readonly permissionID: NativePermissionID,
    readonly snapshot: NativePermissionSnapshot
  ) {
    super(message);
    this.name = "NativePermissionRequiredError";
  }
}

function defaultDetail(id: NativePermissionID, state: NativePermissionState) {
  const name = id === "eventkit.reminders"
    ? "Apple Reminders"
    : id === "eventkit.calendar"
      ? "Apple Calendar"
      : id.replace(/^[^.]+\./, "").replace(/([A-Z])/g, " $1").trim();
  if (state === "granted") return `${name} access is ready.`;
  if (state === "notDetermined") return `${name} access has not been requested yet.`;
  if (state === "devUnsigned") return `${name} cannot keep stable permission because its development helper is not signed.`;
  if (state === "identityMismatch") return `${name} permission belongs to a different helper build.`;
  if (state === "writeOnly") return `${name} has write-only access and cannot be read.`;
  if (state === "unavailable") return `${name} is not available on this Mac.`;
  return `${name} access is not granted.`;
}

export class NativePermissionBroker {
  private readonly descriptors = new Map<NativePermissionID, PermissionDescriptor>();
  private readonly snapshots = new Map<NativePermissionID, NativePermissionSnapshot>();
  private readonly listeners = new Set<(snapshot: NativePermissionBrokerSnapshot) => void>();
  private settingsOpener: ((url: string) => Promise<void>) | null = null;
  private batchDepth = 0;

  setSettingsOpener(opener: (url: string) => Promise<void>) {
    this.settingsOpener = opener;
  }

  register(descriptor: PermissionDescriptor) {
    this.descriptors.set(descriptor.id, descriptor);
    this.snapshots.delete(descriptor.id);
  }

  onChanged(listener: (snapshot: NativePermissionBrokerSnapshot) => void) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  invalidate(permissionID?: NativePermissionID) {
    if (permissionID) this.snapshots.delete(permissionID);
    else this.snapshots.clear();
  }

  cached(permissionID: NativePermissionID) {
    return this.snapshots.get(permissionID);
  }

  async get(permissionID: NativePermissionID, refresh = true) {
    const existing = this.snapshots.get(permissionID);
    if (!refresh && existing) return existing;
    const descriptor = this.descriptors.get(permissionID);
    if (!descriptor) {
      return this.store({
        id: permissionID,
        state: "unavailable",
        canRead: false,
        canWrite: false,
        owner: { kind: "electron", displayName: "Open Assist" },
        checkedAt: Date.now(),
        needsRestart: false,
        errorCode: "permission_not_registered",
        detail: defaultDetail(permissionID, "unavailable")
      });
    }
    try {
      const result = await descriptor.probe();
      const state = result.state;
      return this.store({
        id: permissionID,
        state,
        canRead: result.canRead ?? state === "granted",
        canWrite: result.canWrite ?? (state === "granted" || state === "writeOnly"),
        owner: descriptor.owner,
        checkedAt: Date.now(),
        needsRestart: result.needsRestart ?? false,
        settingsURL: result.settingsURL,
        errorCode: result.errorCode,
        detail: result.detail || defaultDetail(permissionID, state)
      });
    } catch (error) {
      return this.store({
        id: permissionID,
        state: "unknown",
        canRead: false,
        canWrite: false,
        owner: descriptor.owner,
        checkedAt: Date.now(),
        needsRestart: false,
        errorCode: "permission_probe_failed",
        detail: error instanceof Error ? error.message : defaultDetail(permissionID, "unknown")
      });
    }
  }

  async getSnapshot(permissionIDs?: NativePermissionID[]) {
    const ids = permissionIDs?.length ? permissionIDs : [...this.descriptors.keys()];
    this.batchDepth += 1;
    try {
      const permissions = await Promise.all(ids.map((id) => this.get(id)));
      const snapshot = {
        platformSupported: process.platform === "darwin",
        checkedAt: Date.now(),
        permissions
      } satisfies NativePermissionBrokerSnapshot;
      this.emit(snapshot);
      return snapshot;
    } finally {
      this.batchDepth -= 1;
    }
  }

  async request(permissionID: NativePermissionID) {
    const descriptor = this.descriptors.get(permissionID);
    if (!descriptor) throw new Error(`Permission ${permissionID} is not registered.`);
    if (descriptor.request) await descriptor.request();
    else if (descriptor.openSettings) await descriptor.openSettings();
    this.invalidate(permissionID);
    return this.get(permissionID);
  }

  async openSettings(permissionID: NativePermissionID) {
    const descriptor = this.descriptors.get(permissionID);
    if (descriptor?.openSettings) await descriptor.openSettings();
    else {
      const snapshot = await this.get(permissionID);
      if (!snapshot.settingsURL || !this.settingsOpener) {
        throw new Error(`Permission ${permissionID} does not have a Settings page.`);
      }
      await this.settingsOpener(snapshot.settingsURL);
    }
    return this.get(permissionID);
  }

  async require(permissionIDs: NativePermissionID[], access: "read" | "write" = "read") {
    for (const permissionID of permissionIDs) {
      const snapshot = await this.get(permissionID);
      const allowed = access === "read" ? snapshot.canRead : snapshot.canWrite;
      if (!allowed) throw new NativePermissionRequiredError(snapshot.detail, permissionID, snapshot);
    }
  }

  private store(snapshot: NativePermissionSnapshot) {
    this.snapshots.set(snapshot.id, snapshot);
    if (this.batchDepth === 0) this.emit({
      platformSupported: process.platform === "darwin",
      checkedAt: Date.now(),
      permissions: [...this.snapshots.values()]
    });
    return snapshot;
  }

  private emit(snapshot: NativePermissionBrokerSnapshot) {
    for (const listener of this.listeners) listener(snapshot);
  }
}

export type AppleEventKitNativeService = "reminders" | "calendar";
export type AppleEventKitRawStatus = { reminders: string; calendar: string };
export type AppleEventKitCommandRunner = (command: Record<string, unknown>) => Promise<any>;

function eventKitState(value: string): NativePermissionState {
  if (value === "authorized" || value === "fullAccess") return "granted";
  if (value === "notDetermined") return "notDetermined";
  if (value === "denied") return "denied";
  if (value === "restricted") return "restricted";
  if (value === "writeOnly") return "writeOnly";
  if (value === "devUnsigned" || value === "identityMismatch") return value;
  return "unknown";
}

const eventKitOwner: NativeExecutionIdentity = {
  kind: "eventkitHelper",
  displayName: "Open Assist Apple EventKit Helper",
  bundleID: "com.developingadventures.OpenAssist.ElectronAppleEventKitHelper"
};

export const nativePermissionBroker = new NativePermissionBroker();
let eventKitRunner: AppleEventKitCommandRunner | null = null;
let eventKitStatusCache: { value: AppleEventKitRawStatus; checkedAt: number } | null = null;
let eventKitStatusPending: Promise<AppleEventKitRawStatus> | null = null;

function requireEventKitRunner() {
  if (!eventKitRunner) throw new Error("Apple EventKit helper is not available yet.");
  return eventKitRunner;
}

async function eventKitStatus() {
  if (eventKitStatusCache && Date.now() - eventKitStatusCache.checkedAt < 5_000) return eventKitStatusCache.value;
  if (eventKitStatusPending) return eventKitStatusPending;
  eventKitStatusPending = requireEventKitRunner()({ command: "status" }).then((data) => {
    const value = {
      reminders: String(data?.reminders ?? "unknown"),
      calendar: String(data?.calendar ?? "unknown")
    } satisfies AppleEventKitRawStatus;
    eventKitStatusCache = { value, checkedAt: Date.now() };
    return value;
  }).finally(() => { eventKitStatusPending = null; });
  return eventKitStatusPending;
}

export function setAppleEventKitRunner(runner: AppleEventKitCommandRunner, owner: Partial<NativeExecutionIdentity> = {}) {
  eventKitRunner = runner;
  eventKitStatusCache = null;
  Object.assign(eventKitOwner, owner);
  const settings = {
    reminders: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",
    calendar: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
  } as const;
  for (const service of ["reminders", "calendar"] as const) {
    const id: NativePermissionID = `eventkit.${service}`;
    nativePermissionBroker.register({
      id,
      owner: eventKitOwner,
      probe: async () => {
        const status = await eventKitStatus();
        const rawState = eventKitState(status[service]);
        const state = !eventKitOwner.teamID ? "devUnsigned" : rawState;
        return { state, settingsURL: settings[service] };
      },
      request: async () => {
        await requireEventKitRunner()({ command: "request-access", service });
        eventKitStatusCache = null;
      }
    });
  }
}

export function updateAppleEventKitOwner(owner: Partial<NativeExecutionIdentity>) {
  Object.assign(eventKitOwner, owner);
}

export function cachedAppleEventKitRawStatus(): AppleEventKitRawStatus | null {
  const reminders = nativePermissionBroker.cached("eventkit.reminders");
  const calendar = nativePermissionBroker.cached("eventkit.calendar");
  if (!reminders || !calendar) return null;
  return { reminders: reminders.state, calendar: calendar.state };
}

export async function executeAppleEventKitCommand<T = any>(service: AppleEventKitNativeService, command: Record<string, unknown>) {
  const access = /^(list|search)-/.test(String(command.command ?? "")) ? "read" : "write";
  await nativePermissionBroker.require([`eventkit.${service}`], access);
  try {
    return await requireEventKitRunner()(command) as T;
  } catch (error) {
    eventKitStatusCache = null;
    nativePermissionBroker.invalidate(`eventkit.${service}`);
    throw error;
  }
}
