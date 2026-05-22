import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import type {
  RemoteAccessActionResponse,
  RemoteAccessActionType,
  RemoteAccessEvent,
  RemoteAccessPermissionQuestion,
  RemoteAccessProject,
  RemoteAccessSession,
  RemoteAccessSnapshot,
  RemoteAccessToolCall,
  RemoteAccessUsage,
  RemoteProfile,
} from "./types";
import { MarkdownContent } from "./components/MarkdownContent";
import {
  ProviderMark,
  providerLabelFromBackend,
  providerToneFromBackend,
} from "./components/ProviderMark";
import { APP_LOGO_DATA_URL } from "./components/appLogo";

const STORAGE_KEY = "openassist.remote.profiles.v1";

function makeID(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `oa-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function normalizeBaseURL(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function readProfiles(): RemoteProfile[] {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as RemoteProfile[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writeProfiles(profiles: RemoteProfile[]) {
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(profiles));
}

function deviceName(): string {
  const platform = navigator.platform || "Browser";
  return `${platform} Browser`;
}

async function parseJSON<T>(response: Response): Promise<T> {
  const text = await response.text();
  return JSON.parse(text) as T;
}

// Sleep for `ms`, but resolve early if the AbortSignal fires (so teardown
// from the connect loop doesn't have to wait the full backoff).
function waitWithAbort(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve();
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      resolve();
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function ArrowUpIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 19V5" />
      <path d="M5 12l7-7 7 7" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <rect x="6" y="6" width="12" height="12" rx="2" />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function MenuIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <line x1="4" y1="7" x2="20" y2="7" />
      <line x1="4" y1="12" x2="20" y2="12" />
      <line x1="4" y1="17" x2="20" y2="17" />
    </svg>
  );
}

function RefreshIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M3 12a9 9 0 1 0 3-6.7" />
      <path d="M3 4v5h5" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M3 6h18" />
      <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
      <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
    </svg>
  );
}

function BoltIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M13 2L3 14h7l-1 8 10-12h-7l1-8z" />
    </svg>
  );
}

function SlidersIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <line x1="4" y1="6" x2="20" y2="6" />
      <line x1="4" y1="12" x2="20" y2="12" />
      <line x1="4" y1="18" x2="20" y2="18" />
      <circle cx="9" cy="6" r="2.2" fill="currentColor" stroke="none" />
      <circle cx="15" cy="12" r="2.2" fill="currentColor" stroke="none" />
      <circle cx="11" cy="18" r="2.2" fill="currentColor" stroke="none" />
    </svg>
  );
}

function SunIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
    </svg>
  );
}

function MonitorIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="3" y="4" width="18" height="12" rx="2" />
      <path d="M8 20h8M12 16v4" />
    </svg>
  );
}

type ThemePref = "system" | "light" | "dark";
type SidebarSectionID = "projects" | "chats";

const THEME_KEY = "openassist.remote.theme.v1";
const SIDEBAR_COLLAPSED_KEY = "openassist.remote.sidebarCollapsed.v1";
const SIDEBAR_SECTIONS_KEY = "openassist.remote.sidebarSections.v1";
const SIDEBAR_PROJECTS_KEY = "openassist.remote.sidebarProjects.v1";
const SIDEBAR_PROJECT_CHAT_LIMIT = 5;
const SIDEBAR_STANDALONE_CHAT_LIMIT = 8;
const DEFAULT_SIDEBAR_SECTIONS: SidebarSectionID[] = ["projects", "chats"];

function readTheme(): ThemePref {
  try {
    const raw = window.localStorage.getItem(THEME_KEY);
    if (raw === "light" || raw === "dark" || raw === "system") return raw;
  } catch {}
  return "system";
}

function readSidebarCollapsed(): boolean {
  try {
    return window.localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === "1";
  } catch {
    return false;
  }
}

function readStoredStringArray(key: string, fallback: string[]): string[] {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed)
      ? parsed.filter((value): value is string => typeof value === "string")
      : fallback;
  } catch {
    return fallback;
  }
}

function writeStoredStringArray(key: string, values: string[]) {
  try {
    window.localStorage.setItem(key, JSON.stringify(values));
  } catch {}
}

function normalizedSidebarProjectName(value: string | null | undefined): string {
  return (value ?? "").trim().toLowerCase();
}

interface SidebarProjectGroup {
  key: string;
  name: string;
  kind: string;
  projectID: string | null;
  sessionCount: number;
  sessions: RemoteAccessSession[];
}

interface SidebarData {
  projectGroups: SidebarProjectGroup[];
  standaloneChats: RemoteAccessSession[];
}

function PanelCollapseIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="3" y="4" width="18" height="16" rx="2.5" />
      <line x1="9" y1="4" x2="9" y2="20" />
      <path d="M14.5 9.5L12 12l2.5 2.5" />
    </svg>
  );
}

function PanelExpandIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="3" y="4" width="18" height="16" rx="2.5" />
      <line x1="9" y1="4" x2="9" y2="20" />
      <path d="M11 9.5L13.5 12 11 14.5" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <line x1="6" y1="6" x2="18" y2="18" />
      <line x1="18" y1="6" x2="6" y2="18" />
    </svg>
  );
}

function HomeIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M3 11l9-7 9 7v9a2 2 0 0 1-2 2h-4v-7h-6v7H5a2 2 0 0 1-2-2z" />
    </svg>
  );
}

export function App() {
  const query = useMemo(() => new URLSearchParams(window.location.search), []);
  const initialPairingCode = query.get("pairingCode") ?? "";
  const defaultBaseURL = `${window.location.protocol}//${window.location.host}`;

  const [profiles, setProfiles] = useState<RemoteProfile[]>(() => readProfiles());
  const [activeProfileID, setActiveProfileID] = useState<string>(() => readProfiles()[0]?.id ?? "");
  const [baseURLInput, setBaseURLInput] = useState(defaultBaseURL);
  const [pairingCodeInput, setPairingCodeInput] = useState(initialPairingCode);
  const [showPairingCodeInput, setShowPairingCodeInput] = useState(initialPairingCode.trim().length > 0);
  const [adminPasswordInput, setAdminPasswordInput] = useState("");
  const [snapshot, setSnapshot] = useState<RemoteAccessSnapshot | null>(null);
  const [composerText, setComposerText] = useState("");
  const [selectedPluginIDs, setSelectedPluginIDs] = useState<string[]>([]);
  const [approvalAnswers, setApprovalAnswers] = useState<Record<string, string>>({});
  const [statusMessage, setStatusMessage] = useState<string>("Enter the helper URL and Remote Access password to connect.");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isBusy, setIsBusy] = useState(false);
  const [isConnected, setIsConnected] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [settingsSheetOpen, setSettingsSheetOpen] = useState(false);
  const [providerPickerOpen, setProviderPickerOpen] = useState(false);
  const [newThreadSheetOpen, setNewThreadSheetOpen] = useState(false);
  const [newThreadProjectID, setNewThreadProjectID] = useState<string>("");
  const [newThreadTemporary, setNewThreadTemporary] = useState(false);
  const [theme, setTheme] = useState<ThemePref>(() => readTheme());
  const [sidebarCollapsed, setSidebarCollapsed] = useState<boolean>(() => readSidebarCollapsed());
  const [expandedSidebarSections, setExpandedSidebarSections] = useState<Set<SidebarSectionID>>(
    () => new Set(
      readStoredStringArray(SIDEBAR_SECTIONS_KEY, DEFAULT_SIDEBAR_SECTIONS)
        .filter((value): value is SidebarSectionID => value === "projects" || value === "chats")
    )
  );
  const [expandedSidebarProjects, setExpandedSidebarProjects] = useState<Set<string>>(
    () => new Set(readStoredStringArray(SIDEBAR_PROJECTS_KEY, []))
  );
  const [showAllStandaloneChats, setShowAllStandaloneChats] = useState(false);
  const [expandedProjectChatLists, setExpandedProjectChatLists] = useState<Set<string>>(
    () => new Set()
  );
  const [forceDashboard, setForceDashboard] = useState<boolean>(true);
  const providerPickerRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    try {
      window.localStorage.setItem(SIDEBAR_COLLAPSED_KEY, sidebarCollapsed ? "1" : "0");
    } catch {}
  }, [sidebarCollapsed]);

  useEffect(() => {
    writeStoredStringArray(SIDEBAR_SECTIONS_KEY, Array.from(expandedSidebarSections));
  }, [expandedSidebarSections]);

  useEffect(() => {
    writeStoredStringArray(SIDEBAR_PROJECTS_KEY, Array.from(expandedSidebarProjects));
  }, [expandedSidebarProjects]);

  // Close provider picker on outside click / Escape
  useEffect(() => {
    if (!providerPickerOpen) return;
    const handleClick = (event: MouseEvent) => {
      if (!providerPickerRef.current) return;
      if (!providerPickerRef.current.contains(event.target as Node)) {
        setProviderPickerOpen(false);
      }
    };
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setProviderPickerOpen(false);
    };
    document.addEventListener("mousedown", handleClick);
    document.addEventListener("keydown", handleKey);
    return () => {
      document.removeEventListener("mousedown", handleClick);
      document.removeEventListener("keydown", handleKey);
    };
  }, [providerPickerOpen]);

  useEffect(() => {
    const root = document.documentElement;
    if (theme === "system") {
      root.removeAttribute("data-theme");
    } else {
      root.setAttribute("data-theme", theme);
    }
    try {
      window.localStorage.setItem(THEME_KEY, theme);
    } catch {}
  }, [theme]);

  function cycleTheme() {
    setTheme((prev) => (prev === "system" ? "light" : prev === "light" ? "dark" : "system"));
  }
  const eventAbortRef = useRef<AbortController | null>(null);
  const transcriptScrollRef = useRef<HTMLDivElement | null>(null);
  const composerInputRef = useRef<HTMLTextAreaElement | null>(null);

  const activeProfile = profiles.find((profile) => profile.id === activeProfileID) ?? null;
  const selectedSession = snapshot?.selectedSession ?? null;
  const remoteControl = snapshot?.remoteControl ?? null;
  const selectedSessionIsControlled =
    !!remoteControl &&
    !!selectedSession &&
    remoteControl.sessionID.toLowerCase() === selectedSession.session.id.toLowerCase();
  const currentBrowserOwnsControl =
    selectedSessionIsControlled && snapshot?.pairedDevice?.id === remoteControl?.deviceID;
  const blockedByOtherRemote = selectedSessionIsControlled && !currentBrowserOwnsControl;

  const sidebarData = useMemo<SidebarData>(() => {
    const sessions = snapshot?.sessions ?? [];
    const projects = snapshot?.projects ?? [];
    const groups = new Map<string, SidebarProjectGroup>();
    const projectIDByName = new Map<string, string>();

    const makeProjectKey = (project: RemoteAccessProject) => `project:${project.id}`;

    for (const project of projects) {
      const key = makeProjectKey(project);
      groups.set(key, {
        key,
        name: project.name,
        kind: project.kind,
        projectID: project.kind === "folder" ? null : project.id,
        sessionCount: project.sessionCount,
        sessions: [],
      });
      const normalizedName = normalizedSidebarProjectName(project.name);
      if (normalizedName && !projectIDByName.has(normalizedName)) {
        projectIDByName.set(normalizedName, project.id);
      }
    }

    const standaloneChats: RemoteAccessSession[] = [];
    for (const session of sessions) {
      const projectID = session.projectID?.trim();
      const projectNameKey = normalizedSidebarProjectName(session.projectName);
      let groupKey: string | null = null;

      if (projectID) {
        groupKey = `project:${projectID}`;
      } else if (projectNameKey) {
        const matchedProjectID = projectIDByName.get(projectNameKey);
        groupKey = matchedProjectID ? `project:${matchedProjectID}` : `project-name:${projectNameKey}`;
      }

      if (!groupKey) {
        standaloneChats.push(session);
        continue;
      }

      const existingGroup = groups.get(groupKey);
      if (existingGroup) {
        existingGroup.sessions.push(session);
      } else {
        groups.set(groupKey, {
          key: groupKey,
          name: session.projectName?.trim() || "Project",
          kind: "project",
          projectID: null,
          sessionCount: 0,
          sessions: [session],
        });
      }
    }

    const projectGroups = Array.from(groups.values())
      .map((group) => ({
        ...group,
        sessionCount: Math.max(group.sessionCount, group.sessions.length),
      }))
      .sort((left, right) => {
        const leftHasChats = left.sessions.length > 0 ? 0 : 1;
        const rightHasChats = right.sessions.length > 0 ? 0 : 1;
        if (leftHasChats !== rightHasChats) return leftHasChats - rightHasChats;
        return left.name.localeCompare(right.name);
      });

    return { projectGroups, standaloneChats };
  }, [snapshot?.projects, snapshot?.sessions]);

  useEffect(() => {
    if (!selectedSession) {
      setSelectedPluginIDs([]);
      return;
    }
    setSelectedPluginIDs(selectedSession.selectedPluginIDs);
  }, [selectedSession?.session.id, selectedSession?.selectedPluginIDs]);

  useEffect(() => {
    const initialProfile = readProfiles()[0];
    if (!activeProfileID && initialProfile) {
      setActiveProfileID(initialProfile.id);
    }
  }, [activeProfileID]);

  useEffect(() => {
    if (!activeProfile) {
      setSnapshot(null);
      setIsConnected(false);
      eventAbortRef.current?.abort();
      return;
    }

    let disposed = false;
    const abortController = new AbortController();
    eventAbortRef.current?.abort();
    eventAbortRef.current = abortController;

    void refreshState(activeProfile, disposed);
    // Run the reconnecting event loop. It internally retries with backoff
    // until disposed.
    void connectEventsLoop(activeProfile, abortController, () => disposed);

    // When the tab returns to the foreground or the network comes back,
    // re-fetch state and let the reconnecting loop pick up sooner.
    const wakeUp = () => {
      if (disposed) return;
      void refreshState(activeProfile);
    };
    const onVisibility = () => {
      if (document.visibilityState === "visible") wakeUp();
    };
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("online", wakeUp);
    window.addEventListener("focus", wakeUp);

    return () => {
      disposed = true;
      abortController.abort();
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("online", wakeUp);
      window.removeEventListener("focus", wakeUp);
    };
  }, [activeProfileID]);

  // Auto-scroll transcript on new content.
  useEffect(() => {
    const el = transcriptScrollRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
  }, [
    selectedSession?.transcript.length,
    selectedSession?.transcript[selectedSession.transcript.length - 1]?.text,
  ]);

  // Auto-grow composer textarea.
  useEffect(() => {
    const ta = composerInputRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 220)}px`;
  }, [composerText]);

  // iOS keyboard: keep the floating composer above the on-screen keyboard.
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const setOffset = () => {
      const offset = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
      document.documentElement.style.setProperty("--keyboard-offset", `${offset}px`);
    };
    setOffset();
    vv.addEventListener("resize", setOffset);
    vv.addEventListener("scroll", setOffset);
    return () => {
      vv.removeEventListener("resize", setOffset);
      vv.removeEventListener("scroll", setOffset);
    };
  }, []);

  async function refreshState(profile: RemoteProfile, disposed = false) {
    try {
      const response = await fetch(`${profile.baseURL}/remote/v1/state`, {
        headers: { Authorization: `Bearer ${profile.token}` },
      });
      if (response.status === 401) {
        handleUnauthorized(profile.id);
        return;
      }
      const nextSnapshot = await parseJSON<RemoteAccessSnapshot>(response);
      if (!disposed) {
        setSnapshot(nextSnapshot);
        setStatusMessage(`Connected to ${nextSnapshot.machine.displayName}.`);
        setErrorMessage(null);
        setIsConnected(true);
      }
    } catch (error) {
      if (!disposed) {
        setErrorMessage(`Could not load state: ${String(error)}`);
        setIsConnected(false);
      }
    }
  }

  // Run a single fetch+read cycle of the SSE stream. Returns "ok" on a clean
  // close (server ended the stream), "auth" if the token was rejected, or
  // "error" if the fetch / read threw (network drop, iOS suspend, etc.).
  async function readEventsOnce(
    profile: RemoteProfile,
    abortController: AbortController,
    isDisposed: () => boolean,
    onSnapshot: (snapshot: RemoteAccessSnapshot) => void
  ): Promise<"ok" | "auth" | "error"> {
    try {
      const response = await fetch(`${profile.baseURL}/remote/v1/events`, {
        headers: {
          Accept: "text/event-stream",
          Authorization: `Bearer ${profile.token}`,
        },
        signal: abortController.signal,
      });
      if (response.status === 401) {
        return "auth";
      }
      const reader = response.body?.getReader();
      if (!reader) {
        return "error";
      }

      const decoder = new TextDecoder();
      let buffer = "";

      while (!isDisposed()) {
        const { value, done } = await reader.read();
        if (done) return "ok";
        buffer += decoder.decode(value, { stream: true });

        let markerIndex = buffer.indexOf("\n\n");
        while (markerIndex >= 0) {
          const block = buffer.slice(0, markerIndex);
          buffer = buffer.slice(markerIndex + 2);
          const dataLines = block
            .split("\n")
            .filter((line) => line.startsWith("data:"))
            .map((line) => line.slice(5).trim());
          if (dataLines.length > 0) {
            const event = JSON.parse(dataLines.join("\n")) as RemoteAccessEvent;
            if (event.snapshot) {
              onSnapshot(event.snapshot);
            }
          }
          markerIndex = buffer.indexOf("\n\n");
        }
      }
      return "ok";
    } catch {
      return "error";
    }
  }

  // Outer loop: keeps re-establishing the SSE stream with backoff until the
  // effect tears down. iOS Safari aborts long-lived fetches on background /
  // calls / network blips ("TypeError: Load failed"); without this we'd be
  // stuck on Offline forever.
  async function connectEventsLoop(
    profile: RemoteProfile,
    abortController: AbortController,
    isDisposed: () => boolean
  ) {
    let attempt = 0;
    while (!isDisposed() && !abortController.signal.aborted) {
      const result = await readEventsOnce(profile, abortController, isDisposed, (snapshot) => {
        setSnapshot(snapshot);
        setIsConnected(true);
        // Once anything streams successfully, drop the paused banner and
        // reset the backoff for next disconnect.
        setErrorMessage(null);
        attempt = 0;
      });

      if (isDisposed() || abortController.signal.aborted) return;

      if (result === "auth") {
        handleUnauthorized(profile.id);
        return;
      }

      // The stream ended (server close) or errored (network). Mark offline,
      // re-fetch state right away, then back off before reconnecting.
      setIsConnected(false);
      if (result === "error") {
        setErrorMessage("Live updates paused — reconnecting…");
      }
      void refreshState(profile);

      attempt += 1;
      const backoffMs = Math.min(15000, 1000 * Math.pow(2, Math.max(0, attempt - 1)));
      await waitWithAbort(backoffMs, abortController.signal);
    }
  }

  function saveProfiles(nextProfiles: RemoteProfile[]) {
    setProfiles(nextProfiles);
    writeProfiles(nextProfiles);
  }

  function handleUnauthorized(profileID: string) {
    const remaining = profiles.filter((profile) => profile.id !== profileID);
    saveProfiles(remaining);
    setActiveProfileID(remaining[0]?.id ?? "");
    setSnapshot(null);
    setIsConnected(false);
    setErrorMessage("That device token is no longer valid. Pair again from the Mac.");
  }

  async function claimPairing() {
    const baseURL = normalizeBaseURL(baseURLInput);
    const pairingCode = pairingCodeInput.trim();
    const adminPassword = adminPasswordInput.trim();
    if (!baseURL) {
      setErrorMessage("Enter the helper URL.");
      return;
    }
    if (!adminPassword && !pairingCode) {
      setErrorMessage("Enter the Remote Access password.");
      return;
    }

    setIsBusy(true);
    setErrorMessage(null);
    try {
      const response = await fetch(`${baseURL}/remote/v1/pair/claim`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code: pairingCode || null,
          deviceName: deviceName(),
          adminPassword,
        }),
      });
      const result = await parseJSON<{
        ok: boolean;
        machineID?: string | null;
        deviceToken?: string | null;
        snapshot?: RemoteAccessSnapshot | null;
        error?: string | null;
      }>(response);
      if (!result.ok || !result.deviceToken || !result.snapshot || !result.machineID) {
        setErrorMessage(result.error ?? "Pairing failed.");
        return;
      }

      const profile: RemoteProfile = {
        id: makeID(),
        machineID: result.machineID,
        name: result.snapshot.machine.displayName,
        baseURL,
        token: result.deviceToken,
        lastUsedAt: new Date().toISOString(),
      };
      const deduped = [
        profile,
        ...profiles.filter((entry) => entry.machineID !== profile.machineID || entry.baseURL !== profile.baseURL),
      ];
      saveProfiles(deduped);
      setActiveProfileID(profile.id);
      setSnapshot(result.snapshot);
      setIsConnected(true);
      setStatusMessage(`Paired with ${profile.name}.`);
      window.history.replaceState({}, "", window.location.pathname);
      setPairingCodeInput("");
      setAdminPasswordInput("");
    } catch (error) {
      setErrorMessage(`Pairing failed: ${String(error)}`);
    } finally {
      setIsBusy(false);
    }
  }

  async function performAction(
    type: RemoteAccessActionType,
    payload: Record<string, unknown> = {},
    sessionID?: string | null
  ): Promise<RemoteAccessActionResponse | null> {
    if (!activeProfile) {
      setErrorMessage("Pair with a machine first.");
      return null;
    }

    setIsBusy(true);
    try {
      const response = await fetch(`${activeProfile.baseURL}/remote/v1/actions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${activeProfile.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: makeID(),
          machineID: activeProfile.machineID,
          type,
          sessionID,
          payload,
        }),
      });
      if (response.status === 401) {
        handleUnauthorized(activeProfile.id);
        return null;
      }
      const result = await parseJSON<RemoteAccessActionResponse>(response);
      if (result.snapshot) {
        setSnapshot(result.snapshot);
      }
      if (result.ok) {
        setErrorMessage(null);
      } else if (result.error) {
        setErrorMessage(result.error);
      }
      return result;
    } catch (error) {
      setErrorMessage(`Action failed: ${String(error)}`);
      return null;
    } finally {
      setIsBusy(false);
    }
  }

  async function submitPrompt() {
    const prompt = composerText.trim();
    if (!prompt || !snapshot) return;
    const result = await performAction(
      "sendPrompt",
      {
        prompt,
        selectedPluginIDs,
      },
      snapshot.selectedSessionID
    );
    if (result?.ok) {
      setComposerText("");
    }
  }

  async function submitPermissionAnswers() {
    if (!selectedSession?.pendingPermission) return;
    const answers = selectedSession.pendingPermission.questions.reduce<Record<string, string[]>>(
      (acc, question) => {
        const value = approvalAnswers[question.id]?.trim();
        if (value) acc[question.id] = [value];
        return acc;
      },
      {}
    );
    await performAction(
      "resolvePermission",
      {
        requestID: selectedSession.pendingPermission.id,
        answers,
      },
      snapshot?.selectedSessionID
    );
  }

  function handleComposerKey(event: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void submitPrompt();
    }
  }

  function togglePlugin(pluginID: string) {
    const next = selectedPluginIDs.includes(pluginID)
      ? selectedPluginIDs.filter((id) => id !== pluginID)
      : [...selectedPluginIDs, pluginID];
    setSelectedPluginIDs(next);
    void performAction("applyPlugins", { pluginIDs: next }, snapshot?.selectedSessionID);
  }

  function openNewThreadSheet() {
    // Reset form state to a sensible default each time the picker opens.
    setNewThreadProjectID("");
    setNewThreadTemporary(false);
    setNewThreadSheetOpen(true);
  }

  function openNewThreadForProject(projectID: string | null) {
    void createNewThread(projectID, false);
  }

  function toggleSidebarSection(section: SidebarSectionID) {
    setExpandedSidebarSections((previous) => {
      const next = new Set(previous);
      if (next.has(section)) {
        next.delete(section);
      } else {
        next.add(section);
      }
      return next;
    });
  }

  function toggleSidebarProject(projectKey: string) {
    setExpandedSidebarProjects((previous) => {
      const next = new Set(previous);
      if (next.has(projectKey)) {
        next.delete(projectKey);
      } else {
        next.add(projectKey);
      }
      return next;
    });
  }

  function toggleProjectChatList(projectKey: string) {
    setExpandedProjectChatLists((previous) => {
      const next = new Set(previous);
      if (next.has(projectKey)) {
        next.delete(projectKey);
      } else {
        next.add(projectKey);
      }
      return next;
    });
  }

  async function createNewThread(projectID: string | null, temporary = false) {
    const payload: Record<string, unknown> = { temporary };
    const normalizedProjectID = projectID?.trim();
    if (normalizedProjectID) {
      payload.projectID = normalizedProjectID;
    }
    const result = await performAction("newSession", payload);
    if (result?.ok) {
      setNewThreadSheetOpen(false);
      setSidebarOpen(false);
      setForceDashboard(false);
    }
  }

  async function submitNewThread() {
    await createNewThread(newThreadProjectID || null, newThreadTemporary);
  }

  const transcript = (selectedSession?.transcript ?? []).filter((entry) => {
    if (entry.role === "user" || entry.role === "assistant") {
      return (entry.text ?? "").trim().length > 0 || entry.isStreaming;
    }
    // Hide system / placeholder roles entirely from the chat view.
    return false;
  });
  const activeToolCalls = selectedSession?.activeToolCalls ?? [];
  const recentToolCalls = selectedSession?.recentToolCalls ?? [];
  const hasActiveTurn = !!selectedSession?.activeTurnID;
  const sessionTitle = selectedSession?.session.title || "No session selected";
  const projectName = selectedSession?.session.projectName ?? null;
  const sessionBackend = (selectedSession?.session.backend ?? "").toLowerCase();
  const pluginsAllowed = sessionBackend === "codex";

  const renderSidebarSessionRow = (session: RemoteAccessSession, options?: { nested?: boolean }) => {
    const isActive = session.id === snapshot?.selectedSessionID;
    const sessionTone = providerToneFromBackend(session.backend ?? null);
    const sessionToneClass = sessionTone === "default" ? "" : `provider-${sessionTone}`;
    const timeLabel = formatRelativeUpdated(session.updatedAt ?? null);
    const metaParts = [
      providerLabelFromBackend(session.backend ?? null),
      session.modelID,
      session.isTemporary ? "temp" : null,
      timeLabel || null,
    ].filter((part): part is string => !!part && part.trim().length > 0);

    return (
      <div
        key={session.id}
        className={`sidebar-thread-row ${sessionToneClass} ${isActive ? "is-active" : ""} ${
          options?.nested ? "is-nested" : ""
        }`}
      >
        <button
          className={`sidebar-thread ${isActive ? "is-active" : ""}`}
          onClick={() => {
            setSidebarOpen(false);
            setForceDashboard(false);
            void performAction("selectSession", {}, session.id);
          }}
        >
          <span
            className={`sidebar-thread-dot ${sessionToneClass} ${session.hasActiveTurn ? "is-active" : ""}`}
            aria-hidden="true"
          />
          <div className="sidebar-thread-body">
            <div className="sidebar-thread-title">{session.title || "Untitled chat"}</div>
            {(session.summary || (!options?.nested && session.projectName)) && (
              <div className="sidebar-thread-summary">
                {session.summary || session.projectName}
              </div>
            )}
            <div className="sidebar-thread-meta">{metaParts.join(" - ")}</div>
          </div>
        </button>
        <button
          className="sidebar-thread-delete"
          aria-label={`Archive chat ${session.title || ""}`}
          title="Archive chat"
          onClick={(event) => {
            event.stopPropagation();
            const label = session.title?.trim() || "this chat";
            if (window.confirm(`Archive ${label}? You can restore it later from Open Assist on this Mac.`)) {
              void performAction("deleteSession", {}, session.id);
            }
          }}
        >
          <TrashIcon />
        </button>
      </div>
    );
  };

  // ── PAIRING SCREEN ─────────────────────────────────────────────────────
  if (!activeProfile) {
    return (
      <div className="shell">
        <div className="surface-panel">
          <div className="brand-row">
            <div className="brand-mark" aria-hidden="true">
              <img src={APP_LOGO_DATA_URL} alt="" className="brand-mark-img" />
            </div>
            <div>
              <div className="brand-name">OpenAssist Remote</div>
              <div className="brand-sub">Pair this browser with your Mac</div>
            </div>
          </div>

          <div className="eyebrow">Connect</div>
          <h1>Pair this browser</h1>
          <p className="simple-copy">
            Use the helper URL and Remote Access password from the OpenAssist app on your Mac.
          </p>

          <form
            className="pair-form"
            onSubmit={(event) => {
              event.preventDefault();
              void claimPairing();
            }}
          >
            <label className="field-label">
              <span>Helper URL</span>
              <input
                value={baseURLInput}
                onChange={(event) => setBaseURLInput(event.target.value)}
                autoComplete="url"
                placeholder="https://example.trycloudflare.com"
              />
            </label>
            <label className="field-label">
              <span>Remote Access password</span>
              <input
                value={adminPasswordInput}
                onChange={(event) => setAdminPasswordInput(event.target.value)}
                autoComplete="current-password"
                placeholder="Password from your Mac"
                type="password"
              />
            </label>
            {showPairingCodeInput ? (
              <label className="field-label">
                <span>Pairing code</span>
                <input
                  value={pairingCodeInput}
                  onChange={(event) => setPairingCodeInput(event.target.value)}
                  autoComplete="one-time-code"
                  placeholder="123-456"
                />
              </label>
            ) : (
              <button
                className="ghost-action pair-code-toggle"
                type="button"
                onClick={() => setShowPairingCodeInput(true)}
              >
                Use pairing code
              </button>
            )}
            <button className="primary-action full-width" type="submit" disabled={isBusy}>
              {isBusy ? "Pairing…" : "Pair this browser"}
            </button>
            {errorMessage && <p className="form-error">{errorMessage}</p>}
          </form>

          {profiles.length > 0 && (
            <div className="saved-list">
              <h2>Saved machines</h2>
              {profiles.map((profile) => (
                <div key={profile.id} className="profile-row">
                  <button
                    className="profile-button"
                    onClick={() => setActiveProfileID(profile.id)}
                  >
                    <strong>{profile.name}</strong>
                    <span>{profile.baseURL}</span>
                  </button>
                  <button
                    className="icon-button danger"
                    aria-label="Remove saved machine"
                    onClick={() => {
                      const next = profiles.filter((entry) => entry.id !== profile.id);
                      saveProfiles(next);
                    }}
                  >
                    <TrashIcon />
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    );
  }

  // ── PAIRED APP ─────────────────────────────────────────────────────────
  const showDashboard = forceDashboard || !selectedSession;
  return (
    <div className={`app-shell ${sidebarCollapsed ? "is-collapsed" : ""}`}>
      {sidebarOpen && (
        <div className="sidebar-backdrop" onClick={() => setSidebarOpen(false)} />
      )}
      <aside className={`app-sidebar ${sidebarOpen ? "is-open" : ""}`}>
        <div className="sidebar-brand">
          <div
            className="brand-mark"
            aria-hidden="true"
            onClick={() => {
              if (sidebarCollapsed) setSidebarCollapsed(false);
            }}
          >
            <img src={APP_LOGO_DATA_URL} alt="" className="brand-mark-img" />
          </div>
          <div className="sidebar-machine" title={snapshot?.machine.displayName ?? ""}>
            {snapshot?.machine.displayName ?? "OpenAssist"}
          </div>
          <button
            className="sidebar-collapse-button"
            aria-label={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
            title={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
            onClick={() => setSidebarCollapsed(!sidebarCollapsed)}
          >
            {sidebarCollapsed ? <PanelExpandIcon /> : <PanelCollapseIcon />}
          </button>
        </div>

        <div className="sidebar-new-row">
          <button
            className="sidebar-new"
            onClick={() => void createNewThread(null)}
            disabled={isBusy}
          >
            <PlusIcon />
            <span>New chat</span>
          </button>
          <button
            className="icon-button"
            aria-label="Refresh"
            onClick={() => void refreshState(activeProfile)}
            disabled={isBusy}
          >
            <RefreshIcon />
          </button>
        </div>

        <div className="sidebar-section-label">Workspace</div>
        <div className="sidebar-nav-scroll">
          <section className="sidebar-nav-section">
            <div className="sidebar-group-heading">
              <button
                className="sidebar-group-header"
                type="button"
                aria-expanded={expandedSidebarSections.has("projects")}
                onClick={() => toggleSidebarSection("projects")}
              >
                <span className="sidebar-group-chevron" aria-hidden="true">
                  <ChevronRightIcon />
                </span>
                <span className="sidebar-group-title">Projects</span>
                <span className="sidebar-section-count">{sidebarData.projectGroups.length}</span>
              </button>
            </div>

            {expandedSidebarSections.has("projects") && (
              <div className="sidebar-group-list">
                {sidebarData.projectGroups.length === 0 ? (
                  <div className="sidebar-empty">No projects yet.</div>
                ) : (
                  sidebarData.projectGroups.map((project) => {
                    const isExpanded = expandedSidebarProjects.has(project.key);
                    const showAll = expandedProjectChatLists.has(project.key);
                    const visibleSessions = showAll
                      ? project.sessions
                      : project.sessions.slice(0, SIDEBAR_PROJECT_CHAT_LIMIT);
                    const hiddenCount = Math.max(0, project.sessions.length - visibleSessions.length);

                    return (
                      <div key={project.key} className="sidebar-project-group">
                        <div className="sidebar-project-row">
                          <button
                            className="sidebar-project-button"
                            type="button"
                            aria-expanded={isExpanded}
                            onClick={() => toggleSidebarProject(project.key)}
                          >
                            <span className="sidebar-project-chevron" aria-hidden="true">
                              <ChevronRightIcon />
                            </span>
                            <span className="sidebar-project-name">{project.name}</span>
                            <span className="sidebar-project-count">{project.sessionCount}</span>
                          </button>
                          {project.projectID && (
                            <button
                              className="sidebar-project-add"
                              type="button"
                              aria-label={`New chat in ${project.name}`}
                              title={`New chat in ${project.name}`}
                              disabled={isBusy}
                              onClick={(event) => {
                                event.stopPropagation();
                                openNewThreadForProject(project.projectID);
                              }}
                            >
                              <PlusIcon />
                            </button>
                          )}
                        </div>

                        {isExpanded && (
                          <div className="sidebar-project-thread-list">
                            {project.sessions.length === 0 ? (
                              <div className="sidebar-empty compact">
                                {project.kind === "folder"
                                  ? "Use a project inside this group."
                                  : "No chats yet."}
                              </div>
                            ) : (
                              <>
                                {visibleSessions.map((session) => renderSidebarSessionRow(session, { nested: true }))}
                                {hiddenCount > 0 && (
                                  <button
                                    className="sidebar-show-more"
                                    type="button"
                                    onClick={() => toggleProjectChatList(project.key)}
                                  >
                                    Show more {hiddenCount} older chats
                                  </button>
                                )}
                                {showAll && project.sessions.length > SIDEBAR_PROJECT_CHAT_LIMIT && (
                                  <button
                                    className="sidebar-show-more"
                                    type="button"
                                    onClick={() => toggleProjectChatList(project.key)}
                                  >
                                    Show fewer
                                  </button>
                                )}
                              </>
                            )}
                          </div>
                        )}
                      </div>
                    );
                  })
                )}
              </div>
            )}
          </section>

          <section className="sidebar-nav-section">
            <div className="sidebar-group-heading has-action">
              <button
                className="sidebar-group-header"
                type="button"
                aria-expanded={expandedSidebarSections.has("chats")}
                onClick={() => toggleSidebarSection("chats")}
              >
                <span className="sidebar-group-chevron" aria-hidden="true">
                  <ChevronRightIcon />
                </span>
                <span className="sidebar-group-title">Chats</span>
                <span className="sidebar-section-count">{sidebarData.standaloneChats.length}</span>
              </button>
              <button
                className="sidebar-group-add"
                type="button"
                aria-label="New chat"
                title="New chat"
                disabled={isBusy}
                onClick={(event) => {
                  event.stopPropagation();
                  openNewThreadForProject(null);
                }}
              >
                <PlusIcon />
              </button>
            </div>

            {expandedSidebarSections.has("chats") && (
              <div className="sidebar-group-list">
                {sidebarData.standaloneChats.length === 0 ? (
                  <div className="sidebar-empty">No chats yet.</div>
                ) : (
                  <>
                    {(showAllStandaloneChats
                      ? sidebarData.standaloneChats
                      : sidebarData.standaloneChats.slice(0, SIDEBAR_STANDALONE_CHAT_LIMIT)
                    ).map((session) => renderSidebarSessionRow(session))}
                    {!showAllStandaloneChats && sidebarData.standaloneChats.length > SIDEBAR_STANDALONE_CHAT_LIMIT && (
                      <button
                        className="sidebar-show-more"
                        type="button"
                        onClick={() => setShowAllStandaloneChats(true)}
                      >
                        Show more {sidebarData.standaloneChats.length - SIDEBAR_STANDALONE_CHAT_LIMIT} older chats
                      </button>
                    )}
                    {showAllStandaloneChats && sidebarData.standaloneChats.length > SIDEBAR_STANDALONE_CHAT_LIMIT && (
                      <button
                        className="sidebar-show-more"
                        type="button"
                        onClick={() => setShowAllStandaloneChats(false)}
                      >
                        Show fewer
                      </button>
                    )}
                  </>
                )}
              </div>
            )}
          </section>
        </div>

        <div className="sidebar-footer">
          <div className="sidebar-footer-row">
            <span className="label">Helper</span>
            <span className="value" title={snapshot?.status.helperState ?? ""}>
              {snapshot?.status.helperState ?? "—"}
            </span>
            <span className={`health-pill ${isConnected ? "is-ok" : "is-warn"}`}>
              <span className="dot" />
              {isConnected
                ? "Live"
                : errorMessage && errorMessage.toLowerCase().includes("reconnecting")
                  ? "Reconnecting…"
                  : "Offline"}
            </span>
          </div>
          <div className="sidebar-footer-row">
            <span className="label">Tunnel</span>
            <span className="value" title={snapshot?.status.tunnel.publicURL || snapshot?.machine.localBaseURL || ""}>
              {snapshot?.status.tunnel.publicURL || snapshot?.machine.localBaseURL || "—"}
            </span>
          </div>
          <div className="sidebar-footer-actions">
            <button
              className="ghost-action theme-toggle"
              onClick={cycleTheme}
              aria-label={`Theme: ${theme}`}
              title={`Theme: ${theme}`}
            >
              {theme === "system" ? <MonitorIcon /> : theme === "light" ? <SunIcon /> : <MoonIcon />}
              <span>
                {theme === "system" ? "System" : theme === "light" ? "Light" : "Dark"}
              </span>
            </button>
            <button
              className="ghost-action"
              onClick={() => {
                setActiveProfileID("");
              }}
            >
              Switch machine
            </button>
          </div>
        </div>
      </aside>

      <main className="app-main">
        <header className={`thread-header ${showDashboard ? "is-dashboard" : ""}`}>
          {sidebarCollapsed && (
            <button
              className="sidebar-expand-button"
              aria-label="Show sidebar"
              title="Show sidebar"
              onClick={() => setSidebarCollapsed(false)}
            >
              <PanelExpandIcon />
            </button>
          )}
          <button
            className="menu-toggle"
            aria-label="Open menu"
            onClick={() => setSidebarOpen(true)}
          >
            <MenuIcon />
          </button>
          {!showDashboard && snapshot && (
            <ProviderPicker
              snapshot={snapshot}
              currentBackend={selectedSession?.session.backend ?? null}
              isBusy={isBusy}
              blocked={blockedByOtherRemote}
              open={providerPickerOpen}
              setOpen={setProviderPickerOpen}
              onChoose={(backend) =>
                void performAction(
                  "chooseBackend",
                  { backend },
                  snapshot?.selectedSessionID
                )
              }
              pickerRef={providerPickerRef}
            />
          )}

          {!showDashboard && (
          <div className="thread-header-left">
            <div className="thread-title" title={sessionTitle}>{sessionTitle}</div>
            {projectName && <div className="thread-workspace">{projectName}</div>}
            {selectedSession?.session.isTemporary && (
              <span className="thread-temp-pill" title="Temporary thread — not saved to history">
                Temporary
              </span>
            )}
          </div>
          )}
          {showDashboard && <div className="thread-header-spacer" />}
          {!showDashboard && (
            <button
              className="thread-close-button"
              aria-label="Back to dashboard"
              title="Back to dashboard"
              onClick={() => setForceDashboard(true)}
            >
              <CloseIcon />
            </button>
          )}
        </header>

        {!showDashboard && (
          <>
        {(hasActiveTurn ||
          (selectedSession?.queuedPromptCount ?? 0) > 0 ||
          !isConnected) && (
          <div className="status-strip">
            {!isConnected && (
              <span className="status-chip tone-orange">
                <strong>
                  {errorMessage && errorMessage.toLowerCase().includes("reconnecting")
                    ? "Reconnecting…"
                    : "Offline"}
                </strong>
              </span>
            )}
            {hasActiveTurn && (
              <span className="status-chip tone-blue">
                <strong>Working…</strong>
              </span>
            )}
            {(selectedSession?.queuedPromptCount ?? 0) > 0 && (
              <span className="status-chip">
                <strong>Queued</strong>
                {selectedSession?.queuedPromptCount}
              </span>
            )}
          </div>
        )}

        {errorMessage && <div className="banner-status banner-error">{errorMessage}</div>}
        {!errorMessage && statusMessage && !isConnected && (
          <div className="banner-status">{statusMessage}</div>
        )}

        {selectedSession?.pendingPermission && (
          <div className="approval-card">
            <h2>Approval needed</h2>
            <div className="approval-tool">{selectedSession.pendingPermission.toolTitle}</div>
            {selectedSession.pendingPermission.rationale && (
              <div className="approval-rationale">{selectedSession.pendingPermission.rationale}</div>
            )}
            {selectedSession.pendingPermission.requiresDesktopAppConfirmation ? (
              <div className="approval-warn">Finish this confirmation on the Mac.</div>
            ) : (
              <>
                {selectedSession.pendingPermission.options.length > 0 && (
                  <div className="button-row">
                    {selectedSession.pendingPermission.options.map((option) => (
                      <button
                        key={option.id}
                        className={option.isDefault ? "primary-action" : "secondary-action"}
                        onClick={() =>
                          void performAction(
                            "resolvePermission",
                            {
                              requestID: selectedSession.pendingPermission?.id,
                              optionID: option.id,
                            },
                            snapshot?.selectedSessionID
                          )
                        }
                        disabled={blockedByOtherRemote}
                      >
                        {option.title}
                      </button>
                    ))}
                    <button
                      className="secondary-action danger"
                      onClick={() =>
                        void performAction(
                          "cancelPermission",
                          { requestID: selectedSession.pendingPermission?.id },
                          snapshot?.selectedSessionID
                        )
                      }
                      disabled={blockedByOtherRemote}
                    >
                      Deny
                    </button>
                  </div>
                )}

                {selectedSession.pendingPermission.questions.length > 0 && (
                  <div className="question-list">
                    {selectedSession.pendingPermission.questions.map(
                      (question: RemoteAccessPermissionQuestion) => (
                        <label key={question.id} className="field-label">
                          <span>{question.prompt}</span>
                          <input
                            value={approvalAnswers[question.id] ?? ""}
                            onChange={(event) =>
                              setApprovalAnswers((previous) => ({
                                ...previous,
                                [question.id]: event.target.value,
                              }))
                            }
                            placeholder={question.options[0]?.label ?? "Answer"}
                          />
                        </label>
                      )
                    )}
                    <button
                      className="primary-action"
                      onClick={() => void submitPermissionAnswers()}
                      disabled={blockedByOtherRemote}
                    >
                      Submit answers
                    </button>
                  </div>
                )}
              </>
            )}
          </div>
        )}
          </>
        )}

        {showDashboard && snapshot && (
          <Dashboard
            snapshot={snapshot}
            isConnected={isConnected}
            onOpenSession={(sessionID) => {
              setSidebarOpen(false);
              setForceDashboard(false);
              void performAction("selectSession", {}, sessionID);
            }}
            onNewThread={() => void createNewThread(null)}
          />
        )}

        {!showDashboard && (
          <>
        <div className="thread-content" ref={transcriptScrollRef}>
          {transcript.length === 0 && activeToolCalls.length === 0 ? (
            <div className="thread-empty">
              {selectedSession
                ? "No messages yet. Send a prompt below to get started."
                : "Select a thread on the left or create a new thread."}
            </div>
          ) : (
            (() => {
              const lastAssistantIndex = (() => {
                for (let i = transcript.length - 1; i >= 0; i -= 1) {
                  if (transcript[i].role === "assistant") return i;
                }
                return -1;
              })();
              return transcript.map((entry, index) => {
                const isUser = entry.role === "user";
                const showRecentToolsHere =
                  !isUser && index === lastAssistantIndex && recentToolCalls.length > 0;
                const toolBlock = showRecentToolsHere
                  ? <ToolCallList key={`tools-${entry.id}`} calls={recentToolCalls} />
                  : null;

                if (isUser) {
                  return (
                    <div key={entry.id} className="message-row user-row">
                      <div className="user-content">
                        <div className="user-bubble">
                          <div className="user-bubble-body">
                            <span className="user-bubble-text">{entry.text || " "}</span>
                          </div>
                        </div>
                      </div>
                    </div>
                  );
                }

                const messageTone = providerToneFromBackend(entry.providerBackend ?? null);
                const providerClass = messageTone === "default" ? "" : `provider-${messageTone}`;
                const messageRowClass = `message-row assistant-row ${providerClass} ${entry.isStreaming ? "is-streaming" : ""}`;
                const providerName = providerLabelFromBackend(entry.providerBackend ?? null);
                const showProviderFooter = !!entry.providerBackend && messageTone !== "default";
                return (
                  <Fragment key={entry.id}>
                    {toolBlock}
                    <div className={messageRowClass}>
                      <div className="assistant-content">
                        <div className="assistant-message-stage">
                          <div className="assistant-markdown-shell">
                            <MarkdownContent markdown={entry.text || ""} />
                          </div>
                          {showProviderFooter && (
                            <span className="assistant-provider-footer">
                              <ProviderMark tone={messageTone} size="sm" />
                              <span className="assistant-provider-footer-name">{providerName}</span>
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                  </Fragment>
                );
              });
            })()
          )}

          {activeToolCalls.length > 0 && (
            <ToolCallList calls={activeToolCalls} />
          )}
        </div>

        <div
          className="thread-bottom"
          style={{ transform: "translateY(calc(-1 * var(--keyboard-offset, 0px)))" }}
        >
          <div className="composer">
            <div className="composer-frame">
              <textarea
                ref={composerInputRef}
                className="composer-input"
                value={composerText}
                onChange={(event) => setComposerText(event.target.value)}
                onKeyDown={handleComposerKey}
                placeholder={
                  blockedByOtherRemote
                    ? `Controlled from ${remoteControl?.deviceName}`
                    : selectedSession
                      ? "Send a prompt to this thread"
                      : "Create a session first"
                }
                disabled={blockedByOtherRemote || !selectedSession}
                rows={1}
              />

              <div className="composer-row">
                <div className="composer-row-left">
                  <select
                    className="pill-select"
                    value={selectedSession?.session.backend ?? ""}
                    disabled={blockedByOtherRemote || !selectedSession}
                    onChange={(event) =>
                      void performAction(
                        "chooseBackend",
                        { backend: event.target.value },
                        snapshot?.selectedSessionID
                      )
                    }
                    aria-label="Backend"
                  >
                    <option value="" disabled>Backend</option>
                    {snapshot?.availableBackends.map((backend) => (
                      <option key={backend.id} value={backend.id}>{backend.displayName}</option>
                    ))}
                  </select>

                  <select
                    className="pill-select"
                    value={selectedSession?.session.modelID ?? ""}
                    disabled={blockedByOtherRemote || !selectedSession}
                    onChange={(event) =>
                      void performAction(
                        "chooseModel",
                        { modelID: event.target.value },
                        snapshot?.selectedSessionID
                      )
                    }
                    aria-label="Model"
                  >
                    <option value="" disabled>Model</option>
                    {snapshot?.availableModels.map((model) => (
                      <option key={model.id} value={model.id}>{model.displayName}</option>
                    ))}
                  </select>

                  <select
                    className={`pill-select ${selectedSession?.session.interactionMode === "agentic" ? "is-active" : ""}`}
                    value={selectedSession?.session.interactionMode ?? ""}
                    disabled={blockedByOtherRemote || !selectedSession}
                    onChange={(event) =>
                      void performAction(
                        "setMode",
                        { mode: event.target.value },
                        snapshot?.selectedSessionID
                      )
                    }
                    aria-label="Mode"
                  >
                    <option value="" disabled>Mode</option>
                    <option value="plan">Plan</option>
                    <option value="agentic">Agentic</option>
                  </select>

                  <select
                    className="pill-select"
                    value={selectedSession?.session.reasoningEffort ?? ""}
                    disabled={blockedByOtherRemote || !selectedSession}
                    onChange={(event) =>
                      void performAction(
                        "setReasoningEffort",
                        { reasoningEffort: event.target.value },
                        snapshot?.selectedSessionID
                      )
                    }
                    aria-label="Reasoning effort"
                  >
                    <option value="" disabled>Reasoning</option>
                    {["low", "medium", "high", "xhigh"].map((value) => (
                      <option key={value} value={value}>{value}</option>
                    ))}
                  </select>
                </div>

                <div className="composer-row-right">
                  <button
                    className="composer-add"
                    aria-label="Session settings"
                    onClick={() => setSettingsSheetOpen(true)}
                    disabled={!selectedSession}
                  >
                    <SlidersIcon />
                  </button>
                  {hasActiveTurn ? (
                    <button
                      className="composer-send is-stop"
                      aria-label="Stop"
                      onClick={() => void performAction("stopTurn", {}, snapshot?.selectedSessionID)}
                      disabled={isBusy || blockedByOtherRemote}
                    >
                      <StopIcon />
                    </button>
                  ) : (
                    <button
                      className="composer-send"
                      aria-label="Send"
                      onClick={() => void submitPrompt()}
                      disabled={isBusy || blockedByOtherRemote || !composerText.trim() || !selectedSession}
                    >
                      <ArrowUpIcon />
                    </button>
                  )}
                </div>
              </div>

              {pluginsAllowed && snapshot && snapshot.installedPlugins.length > 0 && (
                <div className="plugin-chips">
                  {snapshot.installedPlugins.map((plugin) => {
                    const checked = selectedPluginIDs.includes(plugin.id);
                    return (
                      <button
                        key={plugin.id}
                        className={`plugin-chip ${checked ? "is-active" : ""}`}
                        disabled={blockedByOtherRemote || !selectedSession}
                        onClick={() => togglePlugin(plugin.id)}
                      >
                        <span className="plugin-chip-dot" />
                        {plugin.displayName}
                      </button>
                    );
                  })}
                </div>
              )}

              {selectedSession && (
                <div
                  className={`composer-foot provider-${
                    providerToneFromBackend(selectedSession.session.backend ?? null) === "default"
                      ? "codex"
                      : providerToneFromBackend(selectedSession.session.backend ?? null)
                  }`}
                >
                  <div className="composer-foot-left">
                    <span className="provider-tag">
                      <span className="provider-tag-dot" aria-hidden="true" />
                      {providerLabelFromBackend(selectedSession.session.backend ?? null)}
                    </span>
                    {selectedSession.session.modelID && (
                      <>
                        <span className="composer-foot-sep" aria-hidden="true" />
                        <span className="composer-foot-meta">
                          {selectedSession.session.modelID}
                        </span>
                      </>
                    )}
                    {selectedSession.session.reasoningEffort && (
                      <>
                        <span className="composer-foot-sep" aria-hidden="true" />
                        <span className="composer-foot-meta">
                          {selectedSession.session.reasoningEffort} reasoning
                        </span>
                      </>
                    )}
                  </div>
                  <div className="composer-foot-right">
                    <UsageChips usage={snapshot?.status.usage ?? null} />
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
          </>
        )}

        {settingsSheetOpen && (
          <div className="sheet-backdrop" onClick={() => setSettingsSheetOpen(false)}>
            <div className="sheet" onClick={(event) => event.stopPropagation()}>
              <div className="sheet-grip" />
              <div className="sheet-header">
                <h2>Session settings</h2>
                <button
                  className="ghost-action"
                  onClick={() => setSettingsSheetOpen(false)}
                >
                  Done
                </button>
              </div>

              <div className="sheet-row">
                <label htmlFor="sheet-backend">Backend</label>
                <select
                  id="sheet-backend"
                  value={selectedSession?.session.backend ?? ""}
                  disabled={blockedByOtherRemote || !selectedSession}
                  onChange={(event) =>
                    void performAction(
                      "chooseBackend",
                      { backend: event.target.value },
                      snapshot?.selectedSessionID
                    )
                  }
                >
                  <option value="" disabled>Choose backend</option>
                  {snapshot?.availableBackends.map((backend) => (
                    <option key={backend.id} value={backend.id}>{backend.displayName}</option>
                  ))}
                </select>
              </div>

              <div className="sheet-row">
                <label htmlFor="sheet-model">Model</label>
                <select
                  id="sheet-model"
                  value={selectedSession?.session.modelID ?? ""}
                  disabled={blockedByOtherRemote || !selectedSession}
                  onChange={(event) =>
                    void performAction(
                      "chooseModel",
                      { modelID: event.target.value },
                      snapshot?.selectedSessionID
                    )
                  }
                >
                  <option value="" disabled>Choose model</option>
                  {snapshot?.availableModels.map((model) => (
                    <option key={model.id} value={model.id}>{model.displayName}</option>
                  ))}
                </select>
              </div>

              <div className="sheet-row">
                <label htmlFor="sheet-mode">Mode</label>
                <select
                  id="sheet-mode"
                  value={selectedSession?.session.interactionMode ?? ""}
                  disabled={blockedByOtherRemote || !selectedSession}
                  onChange={(event) =>
                    void performAction(
                      "setMode",
                      { mode: event.target.value },
                      snapshot?.selectedSessionID
                    )
                  }
                >
                  <option value="" disabled>Choose mode</option>
                  <option value="plan">Plan</option>
                  <option value="agentic">Agentic</option>
                </select>
              </div>

              <div className="sheet-row">
                <label htmlFor="sheet-reasoning">Reasoning effort</label>
                <select
                  id="sheet-reasoning"
                  value={selectedSession?.session.reasoningEffort ?? ""}
                  disabled={blockedByOtherRemote || !selectedSession}
                  onChange={(event) =>
                    void performAction(
                      "setReasoningEffort",
                      { reasoningEffort: event.target.value },
                      snapshot?.selectedSessionID
                    )
                  }
                >
                  <option value="" disabled>Choose effort</option>
                  {["low", "medium", "high", "xhigh"].map((value) => (
                    <option key={value} value={value}>{value}</option>
                  ))}
                </select>
              </div>

              {pluginsAllowed && snapshot && snapshot.installedPlugins.length > 0 && (
                <div className="sheet-row">
                  <label>Plugins</label>
                  <div className="plugin-chips">
                    {snapshot.installedPlugins.map((plugin) => {
                      const checked = selectedPluginIDs.includes(plugin.id);
                      return (
                        <button
                          key={plugin.id}
                          className={`plugin-chip ${checked ? "is-active" : ""}`}
                          disabled={blockedByOtherRemote || !selectedSession}
                          onClick={() => togglePlugin(plugin.id)}
                        >
                          <span className="plugin-chip-dot" />
                          {plugin.displayName}
                        </button>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>
          </div>
        )}

        {newThreadSheetOpen && snapshot && (
          <div className="sheet-backdrop" onClick={() => setNewThreadSheetOpen(false)}>
            <div className="sheet" onClick={(event) => event.stopPropagation()}>
              <div className="sheet-grip" />
              <div className="sheet-header">
                <h2>New thread</h2>
                <button
                  className="ghost-action"
                  onClick={() => setNewThreadSheetOpen(false)}
                >
                  Cancel
                </button>
              </div>

              <div className="sheet-row">
                <label>Project</label>
                <div className="project-list">
                  <button
                    type="button"
                    className={`project-option ${newThreadProjectID === "" ? "is-selected" : ""}`}
                    onClick={() => setNewThreadProjectID("")}
                  >
                    <span className="project-option-name">No project</span>
                    <span className="project-option-meta">Loose thread, not tied to a project</span>
                  </button>
                  {snapshot.projects.filter((project) => project.kind !== "folder").length === 0 ? (
                    <p className="muted-copy">
                      No projects yet — create projects on the Mac to organize threads.
                    </p>
                  ) : (
                    snapshot.projects
                      .filter((project) => project.kind !== "folder")
                      .map((project) => (
                      <button
                        key={project.id}
                        type="button"
                        className={`project-option ${newThreadProjectID === project.id ? "is-selected" : ""}`}
                        onClick={() => setNewThreadProjectID(project.id)}
                      >
                        <span className="project-option-name">{project.name}</span>
                        <span className="project-option-meta">
                          {project.kind === "folder" ? "Folder" : "Project"}
                          {project.sessionCount > 0 ? ` · ${project.sessionCount} thread${project.sessionCount === 1 ? "" : "s"}` : ""}
                        </span>
                      </button>
                    ))
                  )}
                </div>
              </div>

              <label className="toggle-row">
                <input
                  type="checkbox"
                  checked={newThreadTemporary}
                  onChange={(event) => setNewThreadTemporary(event.target.checked)}
                />
                <span className="toggle-text">
                  <span className="toggle-title">Temporary thread</span>
                  <span className="toggle-hint">
                    Auto-deleted when the assistant restarts. Use for one-off questions.
                  </span>
                </span>
              </label>

              <div className="button-row sheet-actions">
                <button
                  className="primary-action full-width"
                  onClick={() => void submitNewThread()}
                  disabled={isBusy}
                >
                  Start thread
                </button>
              </div>
            </div>
          </div>
        )}
      </main>
    </div>
  );
}

function ChevronDownIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M3 4.5l3 3 3-3" />
    </svg>
  );
}

interface ProviderPickerProps {
  snapshot: RemoteAccessSnapshot;
  currentBackend: string | null;
  isBusy: boolean;
  blocked: boolean;
  open: boolean;
  setOpen: (next: boolean) => void;
  onChoose: (backend: string) => void;
  pickerRef: React.RefObject<HTMLDivElement | null>;
}

function ProviderPicker({
  snapshot,
  currentBackend,
  isBusy,
  blocked,
  open,
  setOpen,
  onChoose,
  pickerRef,
}: ProviderPickerProps) {
  const tone = providerToneFromBackend(currentBackend);
  const label = providerLabelFromBackend(currentBackend);
  const wrapperClass = `provider-picker provider-${tone === "default" ? "codex" : tone}`;

  return (
    <div className={wrapperClass} ref={pickerRef}>
      <button
        type="button"
        className="provider-picker-trigger"
        onClick={() => setOpen(!open)}
        disabled={isBusy || blocked}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        <ProviderMark tone={tone === "default" ? "codex" : tone} size="sm" />
        <span className="provider-picker-name">{label}</span>
        <span className="provider-picker-chevron">
          <ChevronDownIcon />
        </span>
      </button>

      {open && (
        <div className="provider-picker-menu" role="listbox">
          {snapshot.availableBackends.map((backend) => {
            const itemTone = providerToneFromBackend(backend.id);
            const itemActive = (currentBackend ?? "").toLowerCase() === backend.id.toLowerCase();
            const itemClass = `provider-picker-item provider-${itemTone === "default" ? "codex" : itemTone} ${
              itemActive ? "is-active" : ""
            }`;
            const status = providerStatusFor(backend.displayName);
            return (
              <button
                key={backend.id}
                type="button"
                className={itemClass}
                onClick={() => {
                  onChoose(backend.id);
                  setOpen(false);
                }}
                disabled={blocked}
              >
                <ProviderMark tone={itemTone === "default" ? "codex" : itemTone} size="md" />
                <span className="provider-picker-item-name">
                  {providerLabelFromBackend(backend.id)}
                </span>
                <span className={`provider-picker-status ${status.className}`}>
                  {status.label}
                </span>
                {status.hint && (
                  <span className="provider-picker-item-hint">{status.hint}</span>
                )}
              </button>
            );
          })}
          <div className="provider-picker-foot">
            Tap a provider to switch this thread.
          </div>
        </div>
      )}
    </div>
  );
}

// The remote snapshot doesn't yet expose a per-provider readiness flag, so we
// surface the friendly "Ready" / informational hints based on the displayName
// the helper sends back. Anything unknown stays neutral.
function providerStatusFor(displayName: string): {
  label: string;
  className: string;
  hint?: string;
} {
  const normalized = displayName.toLowerCase();
  if (normalized.includes("sign in")) {
    return { label: "Sign In", className: "is-action", hint: "Sign in on the Mac to use this assistant." };
  }
  if (normalized.includes("install") || normalized.includes("setup")) {
    return { label: "Set Up", className: "is-action", hint: "Finish setup on the Mac to enable." };
  }
  if (normalized.includes("offline") || normalized.includes("unavailable")) {
    return { label: "Offline", className: "is-disabled" };
  }
  return { label: "Ready", className: "is-ready" };
}

interface DashboardProps {
  snapshot: RemoteAccessSnapshot;
  isConnected: boolean;
  onOpenSession: (sessionID: string) => void;
  onNewThread: () => void;
}

function Dashboard({ snapshot, isConnected, onOpenSession, onNewThread }: DashboardProps) {
  const sessions = snapshot.sessions;
  const running = sessions.filter((s) => s.hasActiveTurn);
  const idleCount = sessions.length - running.length;
  const recent = sessions.slice(0, 10);
  const review = sessions.slice(0, Math.min(14, sessions.length));

  // Group projects by parentless (top-level) only — keeps the list readable.
  const projects = snapshot.projects
    .filter((p) => !p.parentID)
    .slice(0, 6);

  // Models grouped + counted just by displayName.
  const modelCounts = new Map<string, number>();
  for (const m of snapshot.availableModels) {
    const key = m.displayName.toLowerCase();
    modelCounts.set(key, (modelCounts.get(key) ?? 0) + 1);
  }

  const helperState = snapshot.status.helperState ?? "Unknown";
  const helperToneClass = isConnected ? "is-ready" : "is-action";

  return (
    <div className="dashboard">
      <section className="dashboard-main">
        <div className="dashboard-headline">
          <div className="dashboard-bubble" aria-hidden="true">
            <BubbleIcon />
          </div>
          <h1>{running.length} thread{running.length === 1 ? "" : "s"} running</h1>
          <p>
            {running.length > 0
              ? "Live work is in progress. Open a thread to watch the latest changes."
              : "Nothing running right now. Start a new thread or open a recent one."}
          </p>
          <span className="dashboard-running-pill">
            <span className="dashboard-running-dot" /> {running.length} running
          </span>
        </div>

        <div className="dashboard-stats">
          <div className="dashboard-stat tone-running">
            <strong>{running.length}</strong>
            <span>Running</span>
          </div>
          <div className="dashboard-stat tone-attention">
            <strong>{review.length}</strong>
            <span>Review</span>
          </div>
          <div className="dashboard-stat tone-neutral">
            <strong>{recent.length}</strong>
            <span>Recent</span>
          </div>
        </div>

        <div className="dashboard-card dashboard-list">
          <div className="dashboard-card-header">
            <h2>Needs review</h2>
            <button className="ghost-action" onClick={onNewThread}>+ New thread</button>
          </div>
          {review.length === 0 ? (
            <p className="muted-copy">No threads yet. Tap "New thread" to start one.</p>
          ) : (
            <ul className="dashboard-needs-review">
              {review.map((session) => {
                const tone = providerToneFromBackend(session.backend ?? null);
                const toneClass = tone === "default" ? "" : `provider-${tone}`;
                return (
                  <li key={session.id}>
                    <button
                      type="button"
                      className={`dashboard-review-row ${toneClass}`}
                      onClick={() => onOpenSession(session.id)}
                    >
                      <span
                        className={`dashboard-review-dot ${toneClass} ${session.hasActiveTurn ? "is-active" : ""}`}
                      />
                      <ProviderMark tone={tone === "default" ? "codex" : tone} size="sm" />
                      <span className="dashboard-review-title">
                        {session.title || "Untitled thread"}
                      </span>
                      <span className="dashboard-review-state">
                        {session.hasActiveTurn ? "Running" : "Review"}
                      </span>
                      <span className="dashboard-review-time">
                        {formatRelativeUpdated(session.updatedAt ?? null)}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </section>

      <aside className="dashboard-aside">
        <div className="dashboard-card">
          <div className="dashboard-card-eyebrow">Helper</div>
          <div className={`dashboard-helper-row ${helperToneClass}`}>
            <span className="dashboard-helper-dot" />
            <span>{helperState}</span>
          </div>
        </div>

        <div className="dashboard-card">
          <div className="dashboard-card-eyebrow">Status breakdown</div>
          <DashboardStatusBar running={running.length} idle={idleCount} />
          <div className="dashboard-status-legend">
            <span><span className="legend-dot tone-blue" /> Running · {running.length}</span>
            <span><span className="legend-dot tone-green" /> Idle · {idleCount}</span>
          </div>
        </div>

        {projects.length > 0 && (
          <div className="dashboard-card">
            <div className="dashboard-card-eyebrow">Workspaces</div>
            <ul className="dashboard-mini-list">
              {projects.map((p) => (
                <li key={p.id}>
                  <span className="dashboard-mini-label">{p.name}</span>
                  <span className="dashboard-mini-count">{p.sessionCount}</span>
                </li>
              ))}
            </ul>
          </div>
        )}

        {recent.length > 0 && (
          <div className="dashboard-card">
            <div className="dashboard-card-eyebrow">Recent activity</div>
            <ul className="dashboard-mini-list">
              {recent.slice(0, 5).map((session) => {
                const tone = providerToneFromBackend(session.backend ?? null);
                const toneClass = tone === "default" ? "" : `provider-${tone}`;
                return (
                  <li
                    key={session.id}
                    className={`dashboard-mini-row ${toneClass}`}
                    onClick={() => onOpenSession(session.id)}
                  >
                    <ProviderMark tone={tone === "default" ? "codex" : tone} size="sm" />
                    <span className="dashboard-mini-label">
                      {session.title || "Untitled thread"}
                    </span>
                    <span className="dashboard-mini-state">
                      {session.hasActiveTurn ? "Running" : "Idle"}
                    </span>
                  </li>
                );
              })}
            </ul>
          </div>
        )}

        {snapshot.availableModels.length > 0 && (
          <div className="dashboard-card">
            <div className="dashboard-card-eyebrow">Models</div>
            <ul className="dashboard-mini-list">
              {snapshot.availableModels.slice(0, 6).map((m) => (
                <li key={m.id}>
                  <span className="dashboard-mini-label">{m.displayName}</span>
                  {m.isDefault && <span className="dashboard-mini-tag">default</span>}
                </li>
              ))}
            </ul>
          </div>
        )}
      </aside>
    </div>
  );
}

function BubbleIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M21 15a4 4 0 0 1-4 4H8l-5 4V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z" />
    </svg>
  );
}

function DashboardStatusBar({ running, idle }: { running: number; idle: number }) {
  const total = Math.max(running + idle, 1);
  const runningPct = (running / total) * 100;
  const idlePct = (idle / total) * 100;
  return (
    <div className="dashboard-statusbar" aria-hidden="true">
      <span className="dashboard-statusbar-fill tone-blue" style={{ width: `${runningPct}%` }} />
      <span className="dashboard-statusbar-fill tone-green" style={{ width: `${idlePct}%` }} />
    </div>
  );
}

function formatRelativeUpdated(iso: string | null): string {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const now = Date.now();
  const diffSec = Math.max(0, Math.round((now - date.getTime()) / 1000));
  if (diffSec < 60) return `${diffSec}s ago`;
  const diffMin = Math.round(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffH = Math.round(diffMin / 60);
  if (diffH < 24) return `${diffH}h ago`;
  const diffD = Math.round(diffH / 24);
  if (diffD < 7) return `${diffD}d ago`;
  return date.toLocaleDateString();
}

function UsageChips({ usage }: { usage: RemoteAccessUsage | null }) {
  const [openIndex, setOpenIndex] = useState<number | null>(null);
  const wrapRef = useRef<HTMLSpanElement | null>(null);

  useEffect(() => {
    if (openIndex === null) return;
    const onDown = (event: MouseEvent) => {
      if (!wrapRef.current) return;
      if (!wrapRef.current.contains(event.target as Node)) setOpenIndex(null);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpenIndex(null);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [openIndex]);

  if (!usage) return null;
  const windows = [usage.primary, usage.secondary]
    .filter((w): w is NonNullable<typeof w> => !!w);
  const context = usage.context ?? null;
  if (windows.length === 0 && !context) return null;

  return (
    <span className="usage-chips" ref={wrapRef}>
      {windows.map((w, idx) => (
        <UsageChip
          key={`${w.label}-${idx}`}
          window={w}
          isOpen={openIndex === idx}
          onToggle={() => setOpenIndex(openIndex === idx ? null : idx)}
        />
      ))}
      {context && <ContextCircle context={context} />}
    </span>
  );
}

function UsageChip({
  window: w,
  isOpen,
  onToggle,
}: {
  window: { label: string; usedPercent: number; resetsInLabel?: string | null };
  isOpen: boolean;
  onToggle: () => void;
}) {
  const tone = w.usedPercent >= 90 ? "is-danger" : w.usedPercent >= 60 ? "is-warn" : "";
  const labelText = (w.label || "USED").toUpperCase();
  return (
    <button
      type="button"
      className={`usage-chip ${tone} ${isOpen ? "is-open" : ""}`}
      onClick={onToggle}
      aria-expanded={isOpen}
    >
      <span className="usage-chip-label">{labelText}</span>
      <span className="usage-chip-pct">{w.usedPercent}%</span>
      {isOpen && (
        <span className="usage-chip-popover" role="tooltip">
          <strong>{labelText}</strong>
          <span>{w.usedPercent}% used</span>
          {w.resetsInLabel && (
            <span className="usage-chip-popover-meta">Resets {w.resetsInLabel}</span>
          )}
        </span>
      )}
    </button>
  );
}

function ContextCircle({
  context,
}: {
  context: { usedPercent: number; summary: string; detail?: string | null };
}) {
  const pct = Math.max(0, Math.min(100, context.usedPercent));
  const tone = pct >= 90 ? "is-danger" : pct >= 60 ? "is-warn" : "";
  const ringStyle = {
    background: `conic-gradient(currentColor ${pct * 3.6}deg, color-mix(in srgb, currentColor 22%, transparent) 0)`,
  } as React.CSSProperties;
  const title = context.detail ? `${context.summary} · ${context.detail}` : context.summary;
  return (
    <span className={`context-circle ${tone}`} title={title} aria-label={title}>
      <span className="context-circle-ring" style={ringStyle} />
      <span className="context-circle-inner">{pct}%</span>
    </span>
  );
}

function GearIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M9 6l6 6-6 6" />
    </svg>
  );
}

function ToolCallList({ calls }: { calls: RemoteAccessToolCall[] }) {
  if (!calls.length) return null;
  return (
    <div className="message-row tool-row">
      <div className="tool-row-list">
        {calls.map((call) => (
          <ToolCallRow key={call.id} call={call} />
        ))}
      </div>
    </div>
  );
}

function ToolCallRow({ call }: { call: RemoteAccessToolCall }) {
  const status = (call.status ?? "").toLowerCase();
  const tone =
    status.includes("fail") || status.includes("error")
      ? "failed"
      : status.includes("complet") || status.includes("done") || status.includes("ok")
        ? "completed"
        : status.includes("run") || status.includes("active") || status.includes("progress")
          ? "running"
          : "neutral";
  const statusLabel = (call.status ?? "").trim().toUpperCase();

  return (
    <div className={`tool-call-inline tone-${tone}`}>
      <span className="tool-call-icon" aria-hidden="true">
        <GearIcon />
      </span>
      <div className="tool-call-body">
        <div className="tool-call-title">{call.title || "Tool"}</div>
        {call.detail && <div className="tool-call-detail">{call.detail}</div>}
      </div>
      <div className="tool-call-meta">
        {statusLabel && <span className="tool-call-status">{statusLabel}</span>}
        <span className="tool-call-chevron"><ChevronRightIcon /></span>
      </div>
    </div>
  );
}
