'use client';

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { VoiceOrb, type OrbPhase } from './voice-orb';
import { SecondBrainWorkspace } from './second-brain-workspace';
import { VoiceLevelMeter } from '../../lib/voice-levels';
import {
  DEFAULT_REALTIME_VOICE,
  parseRealtimeVoice,
  REALTIME_VOICES,
  type RealtimeVoice,
} from '../../lib/realtime-voices';
import {
  DEMO_ACTIVITY,
  DEMO_EVENTS,
  DEMO_MAIL,
  DEMO_MEMORY,
  DEMO_NOTES,
  DEMO_TASKS,
  DEMO_SUPPLIES,
  EMPTY_DEMO_SUPPLY_CART,
  type DemoAccount,
  type DemoWorkspaceState,
  type DemoSupplyCart,
  type DemoSupplyProduct,
  type WorkspaceView,
} from '../../lib/demo-data';
import {
  isWorkspaceToolName,
  WORKSPACE_TOOL_MAP,
  WORKSPACE_TOOLS,
  type WorkspaceToolDefinition,
  type WorkspaceToolName,
} from '../../lib/tool-registry';

type SiteUser = { id: string; email: string; name: string; owner: boolean; access: 'owner' | 'judge' } | null;
type Mode = 'demo' | 'live';
type ThemePreference = 'system' | 'light' | 'dark';
type DemoVoiceAccess = 'capped' | 'subscription';
type ActiveVoiceKind = 'live_subscription' | 'demo_subscription' | 'demo_capped';
type PendingAction = {
  id: string;
  tool: WorkspaceToolName;
  title: string;
  args: Record<string, unknown>;
  expiresAt: number;
  destructive: boolean;
  token?: string;
};
type LiveState = {
  loading: boolean;
  data: Partial<Record<WorkspaceView, unknown>>;
  accounts: unknown | null;
  error: string | null;
  warning: string | null;
};
type VoicePrompt = { verificationUrl: string; userCode: string } | null;
type VoiceThread = {
  id: string;
  name: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
};
type EditorKind = 'task' | 'note' | null;
type OpenNote = {
  id: string;
  title: string;
  content: string;
  source: string;
  loading?: boolean;
  error?: string;
  openUrl?: string;
};
type OpenLiveItem = {
  id: string;
  view: WorkspaceView;
  item: Record<string, unknown>;
};
type VoiceTranscript = { user: string; assistant: string };
type DemoApiResponse = {
  workspace?: DemoWorkspaceState;
  expiresAt?: number;
  result?: unknown;
  error?: string;
};
type JudgeVoicePolicy = {
  available: boolean;
  sessionSeconds: number;
  maxToolCalls: number;
  dailySessionLimit: number;
};
type JudgeVoiceConfig = JudgeVoicePolicy & {
  enabled: boolean;
  keyConfigured: boolean;
  source: 'owner_key' | 'worker_secret' | 'none';
  updatedAt: number | null;
};
type JudgeVoiceUsage = {
  periodDays: number;
  todaySessions: number;
  fundedToday: number;
  subscriptionToday: number;
  activeSessions: number;
  failures: number;
  uniqueJudges: number;
  totalMinutes: number;
  recent: Array<{
    eventId: string;
    judgeLabel: string;
    kind: 'funded_session' | 'subscription_session' | 'subscription_sign_in';
    status: 'starting' | 'active' | 'stopped' | 'failed' | 'expired';
    startedAt: number;
    endedAt: number | null;
    toolCalls: number;
    errorCode: string | null;
  }>;
};

function voiceLabel(voice: RealtimeVoice): string {
  return REALTIME_VOICES.find((item) => item.id === voice)?.label ?? voice;
}

const NAVIGATION: { view: WorkspaceView; label: string; key: string; ownerOnly?: boolean; demoOnly?: boolean }[] = [
  { view: 'today', label: 'Today', key: 'T' },
  { view: 'inbox', label: 'Inbox', key: 'I' },
  { view: 'tasks', label: 'Tasks', key: 'K' },
  { view: 'work', label: 'Work', key: 'W', ownerOnly: true },
  { view: 'calendar', label: 'Calendar', key: 'C' },
  { view: 'supplies', label: 'Supplies', key: 'S', demoOnly: true },
  { view: 'notes', label: 'Notes', key: 'N' },
  { view: 'memory', label: 'Memory', key: 'M' },
  { view: 'accounts', label: 'Accounts', key: 'A' },
  { view: 'activity', label: 'Activity', key: 'Y' },
];

const VIEW_COPY: Record<WorkspaceView, { eyebrow: string; title: string; subtitle: string }> = {
  today: { eyebrow: 'Today', title: 'Today', subtitle: 'Mail, tasks, and calendar in one calm view.' },
  inbox: { eyebrow: 'Three demo accounts', title: 'Inbox', subtitle: 'Search every connected account without mixing identities.' },
  tasks: { eyebrow: 'My Tasks · Upcoming · Backlog', title: 'Tasks', subtitle: 'Clear next actions with short notes and useful tags.' },
  work: { eyebrow: 'Second brain · Agent queue', title: 'Work', subtitle: 'Capture ideas, shape projects, and let agents carry routine work forward.' },
  calendar: { eyebrow: 'Agenda and week', title: 'Calendar', subtitle: 'Exact local times, account context, and visible reminders.' },
  supplies: { eyebrow: 'Shopify · Synthetic store', title: 'Supplies', subtitle: 'Let the agent search a real dev-store catalog and prepare a cart—never checkout.' },
  notes: { eyebrow: 'Google Drive', title: 'Notes', subtitle: 'Long reference material lives here, not inside task details.' },
  memory: { eyebrow: 'Private Drive memory', title: 'Memory', subtitle: 'Only durable, user-approved facts—never raw email text.' },
  accounts: { eyebrow: 'Routing and defaults', title: 'Accounts', subtitle: 'Friendly labels tell agents where new work belongs.' },
  activity: { eyebrow: 'Transparent operations', title: 'Activity', subtitle: 'See what you, ChatGPT, and voice have read or changed.' },
};

const PAGE_SIZE = 8;

/**
 * Page a list without letting the current page drift out of range when the
 * underlying list shrinks (search, filters, a completed task, a demo reset).
 */
function usePagination<T>(items: T[], pageSize: number = PAGE_SIZE, resetKey?: unknown) {
  const [page, setPage] = useState(1);
  // Reset during render (not in an effect) when the list identity changes, so
  // the very first paint after a filter/search change already shows page one.
  const [lastKey, setLastKey] = useState(resetKey);
  if (lastKey !== resetKey) {
    setLastKey(resetKey);
    setPage(1);
  }

  const pageCount = Math.max(1, Math.ceil(items.length / pageSize));
  // Clamp rather than store: a shrinking list must not strand us on a dead page.
  const safePage = Math.min(Math.max(page, 1), pageCount);
  const start = (safePage - 1) * pageSize;
  const end = Math.min(start + pageSize, items.length);

  return {
    page: safePage,
    pageCount,
    pageItems: items.slice(start, start + pageSize),
    rangeStart: items.length === 0 ? 0 : start + 1,
    rangeEnd: end,
    total: items.length,
    setPage,
  };
}

function pageWindow(page: number, pageCount: number): Array<number | 'gap'> {
  if (pageCount <= 7) return Array.from({ length: pageCount }, (_, index) => index + 1);
  const pages = new Set<number>([1, pageCount, page, page - 1, page + 1]);
  if (page <= 3) [2, 3, 4].forEach((value) => pages.add(value));
  if (page >= pageCount - 2) [pageCount - 3, pageCount - 2, pageCount - 1].forEach((value) => pages.add(value));
  const sorted = [...pages].filter((value) => value >= 1 && value <= pageCount).sort((a, b) => a - b);
  const output: Array<number | 'gap'> = [];
  sorted.forEach((value, index) => {
    if (index > 0 && value - sorted[index - 1] > 1) output.push('gap');
    output.push(value);
  });
  return output;
}

function Pagination({ page, pageCount, rangeStart, rangeEnd, total, unit, onPage }: { page: number; pageCount: number; rangeStart: number; rangeEnd: number; total: number; unit: string; onPage: (page: number) => void }) {
  if (total === 0) return null;
  const window = pageWindow(page, pageCount);
  return (
    <nav aria-label={`${unit} pagination`} className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-hairline pt-4">
      <p className="text-xs text-text-3" aria-live="polite">
        Showing <span className="text-ink/90">{rangeStart}–{rangeEnd}</span> of {total} {unit}
      </p>
      {pageCount > 1 && (
        <div className="flex items-center gap-1">
          <button type="button" onClick={() => onPage(page - 1)} disabled={page <= 1} aria-label={`Previous page of ${unit}`} className="grid h-8 w-8 place-items-center rounded-lg border border-hairline-strong text-sm text-text-2 transition hover:border-hairline-strong hover:text-ink disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:border-hairline-strong">‹</button>
          <div className="flex items-center gap-1 max-sm:hidden">
            {window.map((entry, index) => entry === 'gap'
              ? <span key={`gap-${index}`} aria-hidden="true" className="px-1 text-xs text-text-4">…</span>
              : <button key={entry} type="button" onClick={() => onPage(entry)} aria-label={`Page ${entry}`} aria-current={entry === page ? 'page' : undefined} className={`h-8 min-w-8 rounded-lg px-2 text-xs font-semibold tabular-nums transition ${entry === page ? 'bg-brand text-brand-ink' : 'border border-hairline-strong text-text-2 hover:border-hairline-strong hover:text-ink'}`}>{entry}</button>)}
          </div>
          <span className="px-2 text-xs tabular-nums text-text-2 sm:hidden">{page} / {pageCount}</span>
          <button type="button" onClick={() => onPage(page + 1)} disabled={page >= pageCount} aria-label={`Next page of ${unit}`} className="grid h-8 w-8 place-items-center rounded-lg border border-hairline-strong text-sm text-text-2 transition hover:border-hairline-strong hover:text-ink disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:border-hairline-strong">›</button>
        </div>
      )}
    </nav>
  );
}

function randomId(prefix: string) {
  return `${prefix}-${crypto.randomUUID()}`;
}

function compactArgs(args: Record<string, unknown>) {
  return Object.entries(args)
    .filter(([, value]) => value !== undefined && value !== '')
    .slice(0, 6)
    .map(([key, value]) => ({ key, value: Array.isArray(value) ? value.join(', ') : String(value) }));
}

/**
 * Derive a status tone from the toast copy so success, error, and neutral
 * updates read differently without threading a second state value through
 * every call site.
 */
function toastSeverity(text: string): 'error' | 'success' | 'info' {
  const value = text.toLowerCase();
  if (/(fail|error|could not|unavailable|expired|not enabled|invalid|denied|no longer|not compatible|reached its)/.test(value)) return 'error';
  if (/(ready|saved|applied|completed|registered|verified|reset to|is enabled)/.test(value)) return 'success';
  return 'info';
}

function localDateString(date: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

function viewForTool(tool: WorkspaceToolName): WorkspaceView | null {
  if (tool === 'workspace_get_daily_brief') return 'today';
  if (tool.includes('second_brain') || tool.includes('agent_assignment') || tool.includes('agent_run')) return 'work';
  if (tool === 'workspace_set_mail_read_state' || tool.includes('mail')) return 'inbox';
  if (tool.includes('task')) return 'tasks';
  if (tool.includes('calendar')) return 'calendar';
  if (tool.includes('note')) return 'notes';
  if (tool.includes('memory') || tool.includes('fact')) return 'memory';
  if (tool.includes('supply')) return 'supplies';
  if (tool.includes('project') || tool.includes('work_item') || tool.includes('work_dashboard') || tool.includes('agent_')) return 'work';
  if (tool === 'workspace_list_accounts') return 'accounts';
  return null;
}

function rowsForToolResult(tool: WorkspaceToolName, result: unknown): Array<Record<string, unknown>> {
  const view = viewForTool(tool);
  if (!view) return [];
  const record = objectValue(result);
  if (tool === 'workspace_search_mail') return arrayValue(record.results).map((item) => ({ ...item, _kind: 'Mail' }));
  if (tool === 'workspace_search_supplies') return arrayValue(record.products).map((item) => ({ ...item, _kind: 'Supply' }));
  if (tool === 'workspace_search_second_brain') return arrayValue(record.results).map((item) => ({ ...item, _kind: 'Second Brain result' }));
  return liveRows(view, result);
}

async function waitForIceGathering(peer: RTCPeerConnection): Promise<void> {
  if (peer.iceGatheringState === 'complete') return;
  await new Promise<void>((resolve) => {
    const timeout = window.setTimeout(() => {
      peer.removeEventListener('icegatheringstatechange', check);
      resolve();
    }, 4_000);
    const check = () => {
      if (peer.iceGatheringState !== 'complete') return;
      window.clearTimeout(timeout);
      peer.removeEventListener('icegatheringstatechange', check);
      resolve();
    };
    peer.addEventListener('icegatheringstatechange', check);
  });
}

export function WorkspaceApp({ user }: { user: SiteUser }) {
  const router = useRouter();
  const ownerAccess = user?.access === 'owner';
  const mode: Mode = ownerAccess ? 'live' : 'demo';
  const visibleNavigation = useMemo(() => ownerAccess ? NAVIGATION.filter((item) => !item.demoOnly) : NAVIGATION.filter((item) => !item.ownerOnly), [ownerAccess]);
  const webMcpTools = useMemo(() => ownerAccess ? WORKSPACE_TOOLS.filter((tool) => !tool.demoOnly) : WORKSPACE_TOOLS.filter((tool) => !tool.ownerOnly), [ownerAccess]);
  const [view, setView] = useState<WorkspaceView>('today');
  const [search, setSearch] = useState('');
  const [selectedId, setSelectedId] = useState<string | null>('mail-security-review');
  const [pending, setPending] = useState<PendingAction | null>(null);
  const [toast, setToast] = useState(() => ownerAccess
    ? 'Private Live Workspace ready.'
    : `Judge Demo ready · ${webMcpTools.length} WebMCP tools available.`);
  const [voiceStatus, setVoiceStatus] = useState('Ready to check compatibility');
  const [selectedVoice, setSelectedVoice] = useState<RealtimeVoice>(DEFAULT_REALTIME_VOICE);
  const [activeVoice, setActiveVoice] = useState<RealtimeVoice | null>(null);
  const [voicePanelOpen, setVoicePanelOpen] = useState(false);
  const [voiceTranscript, setVoiceTranscript] = useState<VoiceTranscript>({ user: '', assistant: '' });
  const [voicePrompt, setVoicePrompt] = useState<VoicePrompt>(null);
  const [voiceConnected, setVoiceConnected] = useState(false);
  const [voiceMuted, setVoiceMuted] = useState(false);
  const [voiceThreads, setVoiceThreads] = useState<VoiceThread[]>([]);
  const [selectedVoiceThreadId, setSelectedVoiceThreadId] = useState<string | null>(null);
  const [voiceThreadsLoading, setVoiceThreadsLoading] = useState(false);
  const [demoVoiceAccess, setDemoVoiceAccess] = useState<DemoVoiceAccess>('capped');
  const [cappedVoiceAvailable, setCappedVoiceAvailable] = useState<boolean | null>(null);
  const [judgeVoicePolicy, setJudgeVoicePolicy] = useState<JudgeVoicePolicy>({
    available: false,
    sessionSeconds: 300,
    maxToolCalls: 12,
    dailySessionLimit: 25,
  });
  const [demoLoading, setDemoLoading] = useState(true);
  const [demoExpiresAt, setDemoExpiresAt] = useState<number | null>(null);
  const [editor, setEditor] = useState<EditorKind>(null);
  const [openNote, setOpenNote] = useState<OpenNote | null>(null);
  const [openLiveItem, setOpenLiveItem] = useState<OpenLiveItem | null>(null);
  const [ownerSetupCode, setOwnerSetupCode] = useState('');
  const [accounts, setAccounts] = useState<DemoAccount[]>([]);
  const [tasks, setTasks] = useState(DEMO_TASKS);
  const [events, setEvents] = useState(DEMO_EVENTS);
  const [messages, setMessages] = useState(DEMO_MAIL);
  const [notes, setNotes] = useState(DEMO_NOTES);
  const [memory, setMemory] = useState(DEMO_MEMORY);
  const [activity, setActivity] = useState<typeof DEMO_ACTIVITY>(ownerAccess ? [] : DEMO_ACTIVITY);
  const [supplies, setSupplies] = useState<DemoSupplyProduct[]>(DEMO_SUPPLIES);
  const [supplyCart, setSupplyCart] = useState<DemoSupplyCart>(EMPTY_DEMO_SUPPLY_CART);
  const [live, setLive] = useState<LiveState>({ loading: ownerAccess, data: {}, accounts: null, error: null, warning: null });
  const [liveRefreshKey, setLiveRefreshKey] = useState(0);
  const [todayEyebrow, setTodayEyebrow] = useState('Today');
  const [themePreference, setThemePreference] = useState<ThemePreference>('system');
  const [systemDark, setSystemDark] = useState(true);
  const liveRef = useRef(live);
  const tasksRef = useRef(tasks);
  const messagesRef = useRef(messages);
  const eventsRef = useRef(events);
  const notesRef = useRef(notes);
  const memoryRef = useRef(memory);
  const accountsRef = useRef(accounts);
  const suppliesRef = useRef(supplies);
  const modeRef = useRef(mode);
  const demoVoiceAccessRef = useRef(demoVoiceAccess);
  const pendingRef = useRef(pending);
  const voicePeerRef = useRef<RTCPeerConnection | null>(null);
  const voiceStreamRef = useRef<MediaStream | null>(null);
  const voiceSocketRef = useRef<WebSocket | null>(null);
  const voiceDataChannelRef = useRef<RTCDataChannel | null>(null);
  const voiceAudioRef = useRef<HTMLAudioElement | null>(null);
  const voiceCallIdRef = useRef<string | null>(null);
  const voiceSessionIdRef = useRef<string | null>(null);
  const activeVoiceKindRef = useRef<ActiveVoiceKind | null>(null);
  const voiceTimeoutRef = useRef<number | null>(null);
  const voiceToolCountRef = useRef(0);
  const cappedToolLimitRef = useRef(12);
  const voiceMeterRef = useRef<VoiceLevelMeter | null>(null);
  const selectedVoiceRef = useRef<RealtimeVoice>(DEFAULT_REALTIME_VOICE);
  const lastFocusedItemRef = useRef<Partial<Record<WorkspaceView, string>>>({});
  const toolRowsRef = useRef<Partial<Record<WorkspaceView, Array<Record<string, unknown>>>>>({});
  const [voiceMeter, setVoiceMeter] = useState<VoiceLevelMeter | null>(null);
  const [voiceHearing, setVoiceHearing] = useState(false);
  const [voiceThinking, setVoiceThinking] = useState(false);
  const [voiceSpeaking, setVoiceSpeaking] = useState(false);

  useEffect(() => { modeRef.current = mode; }, [mode]);
  useEffect(() => { demoVoiceAccessRef.current = demoVoiceAccess; }, [demoVoiceAccess]);
  useEffect(() => { pendingRef.current = pending; }, [pending]);
  useEffect(() => { liveRef.current = live; }, [live]);
  useEffect(() => { tasksRef.current = tasks; }, [tasks]);
  useEffect(() => { messagesRef.current = messages; }, [messages]);
  useEffect(() => { eventsRef.current = events; }, [events]);
  useEffect(() => { notesRef.current = notes; }, [notes]);
  useEffect(() => { memoryRef.current = memory; }, [memory]);
  useEffect(() => { accountsRef.current = accounts; }, [accounts]);
  useEffect(() => { suppliesRef.current = supplies; }, [supplies]);
  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      setTodayEyebrow(new Intl.DateTimeFormat('en-US', {
        weekday: 'long',
        month: 'long',
        day: 'numeric',
      }).format(new Date()));
    });
    return () => window.cancelAnimationFrame(frame);
  }, []);
  useEffect(() => {
    const saved = window.localStorage.getItem('openassist-theme');
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const update = () => setSystemDark(media.matches);
    const frame = window.requestAnimationFrame(() => {
      if (saved === 'system' || saved === 'light' || saved === 'dark') setThemePreference(saved);
      update();
    });
    media.addEventListener('change', update);
    return () => {
      window.cancelAnimationFrame(frame);
      media.removeEventListener('change', update);
    };
  }, []);

  const chooseTheme = useCallback((next: ThemePreference) => {
    setThemePreference(next);
    window.localStorage.setItem('openassist-theme', next);
  }, []);
  const [toastFaded, setToastFaded] = useState(false);
  // Reset during render (the same idiom as usePagination) so a new toast is
  // visible on its very first paint without a cascading effect render.
  const [lastToast, setLastToast] = useState(toast);
  if (lastToast !== toast) {
    setLastToast(toast);
    setToastFaded(false);
  }
  useEffect(() => {
    if (toastSeverity(toast) === 'error') return;
    const timeout = window.setTimeout(() => setToastFaded(true), 6_000);
    return () => window.clearTimeout(timeout);
  }, [toast]);
  useEffect(() => {
    const stored = window.localStorage.getItem('openassist-realtime-voice');
    if (!stored) return;
    const frame = window.requestAnimationFrame(() => {
      const restored = parseRealtimeVoice(stored);
      setSelectedVoice(restored);
      selectedVoiceRef.current = restored;
      setVoiceStatus(`Ready with ${voiceLabel(restored)}`);
    });
    return () => window.cancelAnimationFrame(frame);
  }, []);

  const selectVoice = useCallback((voice: RealtimeVoice) => {
    if (voiceConnected) return;
    selectedVoiceRef.current = voice;
    setSelectedVoice(voice);
    window.localStorage.setItem('openassist-realtime-voice', voice);
    const option = REALTIME_VOICES.find((item) => item.id === voice);
    setVoiceStatus(`Ready with ${option?.label ?? voice}`);
  }, [voiceConnected]);

  const refreshJudgeVoicePolicy = useCallback(() => {
    const controller = new AbortController();
    void fetch('/api/demo/voice/status', { cache: 'no-store', signal: controller.signal })
      .then(async (response) => {
        const body = await response.json() as Partial<JudgeVoicePolicy>;
        const available = response.ok && body.available === true;
        const policy: JudgeVoicePolicy = {
          available,
          sessionSeconds: typeof body.sessionSeconds === 'number' ? body.sessionSeconds : 300,
          maxToolCalls: typeof body.maxToolCalls === 'number' ? body.maxToolCalls : 12,
          dailySessionLimit: typeof body.dailySessionLimit === 'number' ? body.dailySessionLimit : 25,
        };
        setJudgeVoicePolicy(policy);
        cappedToolLimitRef.current = policy.maxToolCalls;
        setCappedVoiceAvailable(available);
        if (!ownerAccess && !available && demoVoiceAccessRef.current === 'capped') setVoiceStatus('Funded judge voice is not enabled in this deployment.');
      })
      .catch(() => setCappedVoiceAvailable(false));
    return controller;
  }, [ownerAccess]);

  useEffect(() => {
    const controller = refreshJudgeVoicePolicy();
    return () => controller.abort();
  }, [refreshJudgeVoicePolicy]);

  const hydrateDemoWorkspace = useCallback((workspace: DemoWorkspaceState, expiresAt?: number) => {
    setAccounts(workspace.accounts);
    setMessages(workspace.messages);
    setTasks(workspace.tasks);
    setEvents(workspace.events);
    setNotes(workspace.notes);
    setMemory(workspace.memory);
    setActivity(workspace.activity);
    setSupplies(workspace.supplies);
    setSupplyCart(workspace.supplyCart);
    if (expiresAt) setDemoExpiresAt(expiresAt);
    setDemoLoading(false);
  }, []);

  const loadDemoWorkspace = useCallback(async () => {
    setDemoLoading(true);
    const response = await fetch('/api/demo/workspace', { cache: 'no-store' });
    const body = (await response.json()) as DemoApiResponse;
    if (!response.ok || !body.workspace) throw new Error(body.error ?? 'The demo workspace could not be loaded.');
    hydrateDemoWorkspace(body.workspace, body.expiresAt);
  }, [hydrateDemoWorkspace]);

  useEffect(() => {
    if (mode !== 'demo') return;
    const timeout = window.setTimeout(() => {
      void loadDemoWorkspace().catch((error: unknown) => {
        setDemoLoading(false);
        setToast(error instanceof Error ? error.message : 'The demo workspace could not be loaded.');
      });
    }, 0);
    return () => window.clearTimeout(timeout);
  }, [loadDemoWorkspace, mode]);

  const focusView = useCallback((nextView: WorkspaceView, itemId?: string) => {
    setView(nextView);
    setSearch('');
    if (itemId) setSelectedId(itemId);
    window.setTimeout(() => {
      document.getElementById(itemId ? `workspace-item-${itemId}` : `view-${nextView}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }, 50);
  }, []);

  const propose = useCallback(async (tool: WorkspaceToolDefinition, args: Record<string, unknown>) => {
    if (modeRef.current === 'live') {
      const response = await fetch('/api/actions/propose', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ tool: tool.name, args }),
      });
      const body = (await response.json()) as { id?: string; token?: string; expiresAt?: number; error?: string };
      if (!response.ok || !body.id || !body.expiresAt) throw new Error(body.error ?? 'Could not create a secure preview.');
      const action: PendingAction = { id: body.id, tool: tool.name, title: tool.title, args, expiresAt: body.expiresAt, destructive: Boolean(tool.destructive), token: body.token };
      setPending(action);
      setToast('Review the exact change before approving it.');
      return action;
    }

    const response = await fetch('/api/demo/actions/propose', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ tool: tool.name, args }),
    });
    const body = (await response.json()) as { id?: string; token?: string; expiresAt?: number; error?: string };
    if (!response.ok || !body.id || !body.token || !body.expiresAt) throw new Error(body.error ?? 'Could not create a secure demo preview.');
    const action: PendingAction = { id: body.id, tool: tool.name, title: tool.title, args, expiresAt: body.expiresAt, destructive: Boolean(tool.destructive), token: body.token };
    setPending(action);
    setToast('Synthetic demo preview created. Nothing has changed yet.');
    return action;
  }, []);

  const invokeTool = useCallback(async (name: WorkspaceToolName, args: Record<string, unknown> = {}, signal?: AbortSignal) => {
    const tool = WORKSPACE_TOOL_MAP.get(name);
    if (!tool) throw new Error(`Unknown workspace tool: ${name}`);
    if (tool.demoOnly && modeRef.current !== 'demo') throw new Error('This Shopify showcase tool is available only in the isolated judge demo.');
    if (tool.ownerOnly && modeRef.current !== 'live') throw new Error('This private owner tool is not available in Judge Demo.');

    if (name === 'workspace_focus_view') {
      const nextView = String(args.view ?? 'today') as WorkspaceView;
      if (nextView === 'work' && modeRef.current !== 'live') throw new Error('The private Work view is available only to the owner.');
      const requestedItemId = typeof args.itemId === 'string' ? args.itemId : undefined;
      const resolvedItemId = requestedItemId ?? lastFocusedItemRef.current[nextView];
      if (!requestedItemId && resolvedItemId) delete lastFocusedItemRef.current[nextView];
      focusView(nextView, resolvedItemId);
      let opened = false;
      if (resolvedItemId && nextView !== 'activity') {
        if (modeRef.current === 'demo') {
          const demoRows = nextView === 'tasks'
            ? tasksRef.current.map((item) => ({ ...item, _kind: 'Demo task' }))
            : nextView === 'inbox' || nextView === 'today'
              ? messagesRef.current.map((item) => ({ ...item, _kind: 'Demo mail' }))
              : nextView === 'calendar'
                ? eventsRef.current.map((item) => ({ ...item, _kind: 'Demo calendar event' }))
                : nextView === 'notes'
                  ? notesRef.current.map((item) => ({ ...item, _kind: 'Demo note' }))
                  : nextView === 'memory'
                    ? memoryRef.current.map((item) => ({ ...item, _kind: 'Demo memory' }))
                    : nextView === 'accounts'
                      ? accountsRef.current.map((item) => ({ ...item, _kind: 'Demo account' }))
                      : nextView === 'supplies'
                        ? suppliesRef.current.map((item) => ({ ...item, _kind: 'Demo supply' }))
            : toolRowsRef.current[nextView] ?? [];
          const item = demoRows.find((candidate, index) => liveItemId(candidate, `${nextView}-${index + 1}`) === resolvedItemId);
          if (item) {
            if (nextView === 'notes') {
              setOpenNote({
                id: resolvedItemId,
                title: displayText(item, ['title', 'name'], 'Demo note'),
                content: displayText(item, ['content', 'text', 'body', 'markdown'], 'This note is empty.'),
                source: 'Temporary demo note',
              });
            } else {
              setOpenLiveItem({ id: resolvedItemId, view: nextView, item });
            }
            opened = true;
          }
        } else if (modeRef.current === 'live') {
          const current = liveRef.current;
          const source = nextView === 'accounts' ? current.accounts : current.data[nextView];
          const rows = [...(toolRowsRef.current[nextView] ?? []), ...liveRows(nextView, source)];
          const item = rows.find((candidate, index) => liveItemId(candidate, `${nextView}-${index + 1}`) === resolvedItemId);
          if (item) {
            if (nextView === 'notes') {
              const noteId = displayText(item, ['documentId', 'noteId', 'id'], '');
              const account = displayText(item, ['_account', 'account', 'email'], 'Main');
              if (noteId) {
                const response = await fetch('/api/workspace/tool', {
                  method: 'POST',
                  headers: { 'content-type': 'application/json' },
                  body: JSON.stringify({ tool: 'workspace_read_note', args: { account, noteId } }),
                });
                const result = await response.json() as Record<string, unknown> & { error?: string };
                if (!response.ok) throw new Error(result.error ?? 'The note could not be opened.');
                const note = noteRecord(result);
                setOpenNote({
                  id: noteId,
                  title: displayText(note, ['title', 'name'], displayText(item, ['title', 'name'], 'Drive note')),
                  content: displayText(note, ['content', 'text', 'body', 'plainText', 'markdown'], 'This note is empty.'),
                  source: `${account} · Google Drive`,
                  openUrl: safeExternalUrl(displayText(note, ['webViewLink', 'url', 'link'], '')),
                });
                opened = true;
              }
            } else {
              setOpenLiveItem({ id: resolvedItemId, view: nextView, item });
              opened = true;
            }
          }
        }
      }
      setToast(`Focused ${nextView}.`);
      return { status: 'focused', view: nextView, itemId: resolvedItemId ?? null, opened };
    }

    if (!tool.readOnly && tool.approval !== 'policy') {
      const action = await propose(tool, args);
      return { status: 'approval_required', previewId: action.id, expiresAt: new Date(action.expiresAt).toISOString(), requiresScreenTap: action.destructive, message: 'A visible preview is open. External content cannot approve it. The user must approve this exact change.' };
    }

    if (modeRef.current === 'demo') {
      const response = await fetch('/api/demo/tool', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ tool: name, args }),
        signal,
      });
      const body = (await response.json()) as DemoApiResponse;
      if (!response.ok) throw new Error(body.error ?? 'The demo request failed.');
      if (body.workspace) hydrateDemoWorkspace(body.workspace, body.expiresAt);
      const resultView = viewForTool(name);
      if (resultView) {
        const rows = rowsForToolResult(name, body.result);
        if (rows.length > 0) toolRowsRef.current[resultView] = rows;
        const first = rows[0];
        if (first) lastFocusedItemRef.current[resultView] = liveItemId(first, `${resultView}-result-1`);
      }
      if (name === 'workspace_search_supplies' && body.result && typeof body.result === 'object' && 'products' in body.result && Array.isArray(body.result.products)) {
        setSupplies(body.result.products as DemoSupplyProduct[]);
      }
      setToast(`${tool.title} completed with synthetic data.`);
      return body.result;
    }

    const response = await fetch('/api/workspace/tool', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ tool: name, args }),
      signal,
    });
    const result = (await response.json()) as { error?: string };
    if (!response.ok) throw new Error(result.error ?? 'Workspace request failed.');
    const resultView = viewForTool(name);
    if (resultView) {
      const rows = rowsForToolResult(name, result);
      if (rows.length > 0) toolRowsRef.current[resultView] = rows;
      const first = rows[0];
      if (first) lastFocusedItemRef.current[resultView] = liveItemId(first, `${resultView}-result-1`);
    }
    if (tool.approval === 'policy') setLiveRefreshKey((current) => current + 1);
    setActivity((current) => [{ id: randomId('activity'), actor: 'Workspace', action: `${tool.readOnly ? 'Read' : 'Policy action'}: ${tool.title}`, time: 'Just now', type: tool.readOnly ? 'read' as const : 'write' as const }, ...current].slice(0, 40));
    setToast(`${tool.title} completed.`);
    return result;
  }, [focusView, hydrateDemoWorkspace, propose]);

  const openDemoNote = useCallback((note: (typeof DEMO_NOTES)[number]) => {
    setOpenNote({ id: note.id, title: note.title, content: note.content, source: 'Temporary demo note' });
  }, []);

  const openLiveNote = useCallback(async (item: Record<string, unknown>) => {
    const noteId = displayText(item, ['documentId', 'noteId', 'id'], '');
    const title = displayText(item, ['title', 'name'], 'Drive note');
    const account = displayText(item, ['_account', 'account', 'email'], 'Main');
    if (!noteId) {
      setOpenNote({ id: 'missing-note', title, content: '', source: 'Google Drive', error: 'This note is missing its document identifier.' });
      return;
    }
    setOpenNote({ id: noteId, title, content: '', source: `${account} · Google Drive`, loading: true });
    try {
      const result = await invokeTool('workspace_read_note', { account, noteId });
      const note = noteRecord(result);
      setOpenNote({
        id: noteId,
        title: displayText(note, ['title', 'name'], title),
        content: displayText(note, ['content', 'text', 'body', 'plainText', 'markdown'], 'This note is empty.'),
        source: `${account} · Google Drive`,
        openUrl: safeExternalUrl(displayText(note, ['webViewLink', 'url', 'link'], '')),
      });
    } catch (error) {
      setOpenNote({ id: noteId, title, content: '', source: `${account} · Google Drive`, error: error instanceof Error ? error.message : 'The note could not be opened.' });
    }
  }, [invokeTool]);

  useEffect(() => {
    if (mode !== 'live' || !user) return;
    const controller = new AbortController();
    const timeout = window.setTimeout(() => {
      setLive((current) => ({ ...current, loading: true, error: null, warning: null }));
      const now = new Date();
      const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      const weekLater = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);
      const requestForView: Record<WorkspaceView, [WorkspaceToolName, Record<string, unknown>]> = {
        today: ['workspace_get_daily_brief', { date: localDateString(now, timeZone), timeZone }],
        inbox: ['workspace_get_daily_brief', { date: localDateString(now, timeZone), timeZone }],
        tasks: ['workspace_find_tasks', { status: 'all' }],
        calendar: ['workspace_list_calendar', { timeMin: now.toISOString(), timeMax: weekLater.toISOString() }],
        supplies: ['workspace_list_accounts', {}],
        notes: ['workspace_list_notes', {}],
        memory: ['workspace_get_memory', {}],
        work: ['workspace_get_work_dashboard', { includeCompleted: false }],
        accounts: ['workspace_list_accounts', {}],
        activity: ['workspace_list_accounts', {}],
      };
      const [toolName, args] = requestForView[view];
      void (async () => {
        const accountsPromise = liveRef.current.accounts
          ? Promise.resolve(liveRef.current.accounts)
          : invokeTool('workspace_list_accounts', {}, controller.signal);
        const viewPromise = toolName === 'workspace_list_accounts'
          ? accountsPromise
          : invokeTool(toolName, args, controller.signal);
        return Promise.all([accountsPromise, viewPromise] as const);
      })().then(([accountsResult, viewResult]) => {
        setLive((current) => ({
          loading: false,
          error: null,
          warning: null,
          accounts: accountsResult,
          data: { ...current.data, [view]: viewResult },
        }));
      }).catch((error: unknown) => {
        if (controller.signal.aborted) return;
        const message = error instanceof Error ? error.message : 'Workspace could not be loaded.';
        const reconnectRequired = /Workspace (?:is not connected|must be reconnected|authorization expired)|Google account .{1,320} must reconnect|No connected Google account|No Google account with connected|No connected Gmail account|Connect the required Google service|Gmail is disconnected/i.test(message);
        setLive((current) => ({
          ...current,
          loading: false,
          error: reconnectRequired || message.startsWith('Owner access') ? message : null,
          warning: reconnectRequired ? null : message,
        }));
      });
    }, 0);
    return () => {
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [invokeTool, liveRefreshKey, mode, user, view]);

  useEffect(() => {
    if (!document.modelContext) {
      const timeout = window.setTimeout(() => {
        setToast('This browser does not expose WebMCP yet. The workspace still works normally.');
      }, 0);
      return () => window.clearTimeout(timeout);
    }

    const controllers = webMcpTools.map(() => new AbortController());
    Promise.all(webMcpTools.map((tool, index) => document.modelContext!.registerTool({
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: { readOnlyHint: tool.readOnly, untrustedContentHint: tool.untrustedContent },
      execute: (input, options) => invokeTool(tool.name, input, options.signal),
    }, { signal: controllers[index].signal })))
      .then(() => setToast(`${webMcpTools.length} WebMCP tools registered in this tab.`))
      .catch((error: unknown) => setToast(error instanceof Error ? error.message : 'WebMCP registration failed.'));

    const siteToolHandler = (event: Event) => {
      const detail = (event as CustomEvent<{ tool: WorkspaceToolName; args: Record<string, unknown>; requestId: string }>).detail;
      void invokeTool(detail.tool, detail.args)
        .then((result) => {
          window.dispatchEvent(new CustomEvent('openassist:site-tool-result', { detail: { requestId: detail.requestId, result } }));
        })
        .catch((error: unknown) => {
          const message = error instanceof Error ? error.message : 'The workspace tool failed.';
          window.dispatchEvent(new CustomEvent('openassist:site-tool-result', { detail: { requestId: detail.requestId, error: message } }));
        });
    };
    window.addEventListener('openassist:use-site-tool', siteToolHandler);
    return () => {
      controllers.forEach((controller) => controller.abort());
      window.removeEventListener('openassist:use-site-tool', siteToolHandler);
    };
  }, [invokeTool, webMcpTools]);

  const approve = useCallback(async (confirmationMethod: 'tap' | 'voice' = 'tap', expectedPreviewId?: string): Promise<Record<string, unknown>> => {
    const action = pendingRef.current;
    if (!action || (expectedPreviewId && action.id !== expectedPreviewId)) throw new Error('That approval preview is no longer active.');
    if (confirmationMethod === 'voice' && action.destructive) throw new Error('This destructive action needs the on-screen Approve button.');
    if (Date.now() > action.expiresAt) {
      setPending(null);
      setToast('That preview expired. Ask for the change again.');
      throw new Error('That approval preview expired.');
    }

    if (modeRef.current === 'demo') {
      const response = await fetch('/api/demo/actions/execute', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ previewId: action.id, token: action.token, tool: action.tool, args: action.args, confirmationMethod }),
      });
      const body = (await response.json()) as DemoApiResponse;
      if (!response.ok) {
        setToast(body.error ?? 'The approved demo change failed. It was not retried.');
        throw new Error(body.error ?? 'The approved demo change failed. It was not retried.');
      }
      if (body.workspace) hydrateDemoWorkspace(body.workspace, body.expiresAt);
      setPending(null);
      setToast('Synthetic change applied and read back successfully.');
      if (action.tool.includes('task')) focusView('tasks', typeof body.result === 'object' && body.result && 'itemId' in body.result ? String(body.result.itemId) : undefined);
      if (action.tool.includes('calendar')) focusView('calendar', typeof body.result === 'object' && body.result && 'itemId' in body.result ? String(body.result.itemId) : undefined);
      if (action.tool.includes('note')) focusView('notes', typeof body.result === 'object' && body.result && 'itemId' in body.result ? String(body.result.itemId) : undefined);
      if (action.tool.includes('memory') || action.tool.includes('fact')) focusView('memory');
      if (action.tool.includes('supply_cart')) focusView('supplies', typeof body.result === 'object' && body.result && 'itemId' in body.result ? String(body.result.itemId) : undefined);
      return (body.result && typeof body.result === 'object' ? body.result : { status: 'completed', verified: true, mode: 'synthetic_demo' }) as Record<string, unknown>;
    }

    const response = await fetch('/api/actions/execute', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ previewId: action.id, token: action.token, tool: action.tool, args: action.args, confirmationMethod }),
    });
    const body = (await response.json()) as Record<string, unknown> & { error?: string };
    if (!response.ok) {
      setToast(body.error ?? 'The approved change failed. It was not retried.');
      throw new Error(body.error ?? 'The approved change failed. It was not retried.');
    }
    setPending(null);
    setActivity((current) => [{ id: randomId('activity'), actor: confirmationMethod === 'voice' ? 'Voice + You' : 'You', action: `Approved: ${action.title}`, time: 'Just now', type: 'write' as const }, ...current].slice(0, 40));
    const updatedView = viewForTool(action.tool);
    if (updatedView) {
      const itemId = typeof body.itemId === 'string'
        ? body.itemId
        : typeof body.id === 'string' ? body.id : undefined;
      focusView(updatedView, itemId);
      setLiveRefreshKey((current) => current + 1);
    }
    setToast('Change saved and verified by reading it back.');
    return body;
  }, [focusView, hydrateDemoWorkspace]);

  const refreshVoiceThreads = useCallback(async (force = false) => {
    const currentMode = modeRef.current;
    const currentAccess = demoVoiceAccessRef.current;
    if (!force && currentMode !== 'live' && currentAccess !== 'subscription') return;
    if (currentMode === 'live' && !user) return;
    if (currentMode === 'demo' && currentAccess !== 'subscription') {
      setVoiceThreads([]);
      setSelectedVoiceThreadId(null);
      return;
    }
    setVoiceThreadsLoading(true);
    try {
      const endpoint = currentMode === 'demo'
        ? '/api/demo/voice/subscription/threads'
        : '/api/voice/threads';
      const response = await fetch(endpoint, { cache: 'no-store' });
      const body = (await response.json()) as { status?: string; message?: string; error?: string; threads?: VoiceThread[] };
      if (response.ok && Array.isArray(body.threads)) {
        setVoiceThreads(body.threads);
        setSelectedVoiceThreadId((current) => current && body.threads?.some((thread) => thread.id === current) ? current : null);
      } else if (response.status !== 409) {
        setVoiceStatus(body.error ?? body.message ?? 'Saved conversations could not be loaded.');
      }
    } catch {
      setVoiceStatus('Saved conversations could not be loaded.');
    } finally {
      setVoiceThreadsLoading(false);
    }
  }, [user]);

  const updateVoiceTranscript = useCallback((role: 'user' | 'assistant', text: string, final = false) => {
    const clean = text.replace(/\s+/g, ' ').slice(0, 2_000);
    if (!clean.trim()) return;
    setVoiceTranscript((current) => ({
      ...current,
      [role]: final ? clean.trim() : `${current[role]}${clean}`.slice(-2_000),
    }));
  }, []);

  const resetVoiceTurn = useCallback((role: 'user' | 'assistant') => {
    setVoiceTranscript((current) => ({ ...current, [role]: '' }));
  }, []);

  const stopVoice = useCallback((message = 'Voice stopped', persist = true) => {
    const kind = activeVoiceKindRef.current;
    const callId = voiceCallIdRef.current;
    const sessionId = voiceSessionIdRef.current;
    const toolCalls = voiceToolCountRef.current;
    const socket = voiceSocketRef.current;
    const channel = voiceDataChannelRef.current;
    const peer = voicePeerRef.current;
    const stream = voiceStreamRef.current;
    const hadSession = Boolean(kind || socket || channel || peer || stream);
    activeVoiceKindRef.current = null;
    voiceCallIdRef.current = null;
    voiceSessionIdRef.current = null;
    voiceToolCountRef.current = 0;
    if (voiceTimeoutRef.current != null) window.clearTimeout(voiceTimeoutRef.current);
    voiceTimeoutRef.current = null;
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'control', action: 'stop' }));
    socket?.close();
    voiceSocketRef.current = null;
    channel?.close();
    voiceDataChannelRef.current = null;
    voicePeerRef.current = null;
    peer?.close();
    voiceStreamRef.current = null;
    stream?.getTracks().forEach((track) => track.stop());
    if (voiceAudioRef.current) voiceAudioRef.current.srcObject = null;
    voiceAudioRef.current = null;
    voiceMeterRef.current?.dispose();
    voiceMeterRef.current = null;
    setVoiceMeter(null);
    setVoiceSpeaking(false);
    setVoiceConnected(false);
    setVoiceMuted(false);
    setVoiceStatus(message);
    if (persist && hadSession && kind) {
      if (kind === 'demo_capped' && callId) {
        void fetch('/api/demo/voice/capped/stop', {
          method: 'POST',
          keepalive: true,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ callId, toolCalls }),
        }).catch(() => undefined);
      } else {
        const endpoint = kind === 'demo_subscription'
          ? '/api/demo/voice/subscription/session/stop'
          : '/api/voice/session/stop';
        void fetch(endpoint, {
          method: 'POST',
          keepalive: true,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(kind === 'demo_subscription' ? { sessionId, toolCalls } : {}),
        })
          .then((response) => response.ok ? refreshVoiceThreads() : undefined)
          .catch(() => undefined);
      }
    }
  }, [refreshVoiceThreads]);

  const connectVoice = useCallback(async () => {
    setVoicePanelOpen(true);
    if (voiceConnected) {
      stopVoice();
      return;
    }
    const currentMode = modeRef.current;
    const currentAccess = demoVoiceAccessRef.current;
    if (currentMode === 'live' && !user) {
      setVoiceStatus('Sign in before starting Live voice.');
      return;
    }
    try {
      const voiceForSession = selectedVoiceRef.current;
      setVoiceTranscript({ user: '', assistant: '' });
      setVoiceStatus(currentMode === 'live' ? 'Checking your private Workspace connection…' : 'Checking the synthetic demo workspace…');
      await invokeTool('workspace_list_accounts', {});

      const subscription = currentMode === 'live' || currentAccess === 'subscription';
      const subscriptionBase = currentMode === 'demo' ? '/api/demo/voice/subscription' : '/api/voice';
      if (!subscription && voiceForSession === 'sol') {
        throw new Error('Sol is available with My ChatGPT. Select My ChatGPT or choose another funded-demo voice.');
      }
      if (subscription) {
        setVoiceStatus('Checking your ChatGPT subscription sign-in…');
        let authResponse = await fetch(`${subscriptionBase}/auth/status`, { cache: 'no-store' });
        let auth = (await authResponse.json()) as { status?: string; message?: string; error?: string; verificationUrl?: string; userCode?: string };
        if (!authResponse.ok && auth.status !== 'pending') {
          authResponse = await fetch(`${subscriptionBase}/auth/start`, { method: 'POST' });
          auth = (await authResponse.json()) as typeof auth;
        } else if (auth.status !== 'ready' && auth.status !== 'pending') {
          authResponse = await fetch(`${subscriptionBase}/auth/start`, { method: 'POST' });
          auth = (await authResponse.json()) as typeof auth;
        }
        if (!authResponse.ok) throw new Error(auth.error ?? auth.message ?? 'The voice gateway could not start ChatGPT sign-in.');
        if (auth.status !== 'ready') {
          if (auth.verificationUrl && auth.userCode) setVoicePrompt({ verificationUrl: auth.verificationUrl, userCode: auth.userCode });
          setVoiceStatus(auth.message ?? (auth.userCode ? 'Finish ChatGPT sign-in, then press voice again.' : 'Voice sign-in is pending.'));
          return;
        }
      }

      setVoicePrompt(null);
      stopVoice('Starting microphone…', false);
      const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
      const peer = new RTCPeerConnection();
      stream.getTracks().forEach((track) => peer.addTrack(track, stream));
      const audio = new Audio();
      audio.autoplay = true;
      const meter = new VoiceLevelMeter();
      meter.attachMic(stream);
      voiceMeterRef.current = meter;
      setVoiceMeter(meter);
      peer.ontrack = (event) => {
        const remote = event.streams[0] ?? new MediaStream([event.track]);
        audio.srcObject = remote;
        meter.attachOutput(remote);
        void audio.play().catch(() => undefined);
      };
      peer.onconnectionstatechange = () => {
        if ((peer.connectionState === 'failed' || peer.connectionState === 'closed') && voicePeerRef.current === peer) stopVoice('Voice connection ended.');
      };
      voicePeerRef.current = peer;
      voiceStreamRef.current = stream;
      voiceAudioRef.current = audio;

      let dataChannel: RTCDataChannel | null = null;
      if (!subscription) {
        activeVoiceKindRef.current = 'demo_capped';
        dataChannel = peer.createDataChannel('oai-events');
        voiceDataChannelRef.current = dataChannel;
        dataChannel.addEventListener('message', (event) => {
          let message: { type?: string; name?: string; call_id?: string; arguments?: string; delta?: string; transcript?: string; text?: string; error?: { message?: string } };
          try { message = JSON.parse(String(event.data)) as typeof message; } catch { return; }
          if (message.type === 'error') {
            setVoiceStatus(message.error?.message ?? 'The demo voice service returned an error.');
            return;
          }
          if (message.type === 'input_audio_buffer.speech_started') resetVoiceTurn('user');
          if (message.type === 'response.created') resetVoiceTurn('assistant');
          if (message.type === 'conversation.item.input_audio_transcription.delta' && message.delta) updateVoiceTranscript('user', message.delta);
          if (message.type === 'conversation.item.input_audio_transcription.completed' && message.transcript) updateVoiceTranscript('user', message.transcript, true);
          if ((message.type === 'response.audio_transcript.delta' || message.type === 'response.output_audio_transcript.delta' || message.type === 'response.text.delta') && message.delta) updateVoiceTranscript('assistant', message.delta);
          if ((message.type === 'response.audio_transcript.done' || message.type === 'response.output_audio_transcript.done' || message.type === 'response.text.done') && (message.transcript || message.text)) updateVoiceTranscript('assistant', message.transcript ?? message.text ?? '', true);
          if (message.type !== 'response.function_call_arguments.done' || !message.call_id || !message.name) return;
          voiceToolCountRef.current += 1;
          const sendResult = (output: unknown) => {
            if (dataChannel?.readyState !== 'open') return;
            dataChannel.send(JSON.stringify({
              type: 'conversation.item.create',
              item: { type: 'function_call_output', call_id: message.call_id, output: JSON.stringify(output ?? null) },
            }));
            dataChannel.send(JSON.stringify({ type: 'response.create' }));
          };
          const toolLimit = cappedToolLimitRef.current;
          if (voiceToolCountRef.current > toolLimit) {
            sendResult({ error: `This funded demo reached its ${toolLimit}-tool safety limit.` });
            setVoiceStatus(`This demo reached its ${toolLimit}-tool limit. Start a new session later or use your subscription.`);
            return;
          }
          if (!isWorkspaceToolName(message.name)) {
            sendResult({ error: 'Only the visible synthetic Workspace tools are allowed.' });
            return;
          }
          let args: Record<string, unknown> = {};
          try {
            const parsed: unknown = JSON.parse(message.arguments || '{}');
            if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) args = parsed as Record<string, unknown>;
          } catch {
            sendResult({ error: 'The voice tool arguments were invalid.' });
            return;
          }
          void invokeTool(message.name, args)
            .then((result) => sendResult({ success: true, result }))
            .catch((error: unknown) => sendResult({ success: false, error: error instanceof Error ? error.message : 'Workspace tool failed.' }));
        });
        dataChannel.addEventListener('open', () => {
          setVoiceConnected(true);
          setActiveVoice(voiceForSession);
          setVoiceStatus(`Listening with ${voiceLabel(voiceForSession)} · funded ${Math.ceil(judgeVoicePolicy.sessionSeconds / 60)}-minute synthetic demo`);
        });
      } else {
        activeVoiceKindRef.current = currentMode === 'demo' ? 'demo_subscription' : 'live_subscription';
      }

      await peer.setLocalDescription(await peer.createOffer({ offerToReceiveAudio: true }));
      await waitForIceGathering(peer);
      const offerSdp = peer.localDescription?.sdp ?? '';
      const sessionEndpoint = subscription
        ? `${subscriptionBase}/session`
        : '/api/demo/voice/capped/session';
      const response = await fetch(sessionEndpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(subscription
          ? { sdp: offerSdp, threadId: selectedVoiceThreadId, voice: voiceForSession }
          : { sdp: offerSdp, voice: voiceForSession }),
      });
      const body = (await response.json()) as { status?: string; message?: string; error?: string; sdp?: string; toolSocketUrl?: string; toolSocketToken?: string; threadId?: string; resumed?: boolean; callId?: string; sessionId?: string; voice?: string; expiresAfterSeconds?: number; warningAfterSeconds?: number; maxToolCalls?: number };
      if (!response.ok || body.status !== 'ready' || !body.sdp) throw new Error(body.message ?? body.error ?? 'Voice is not compatible yet.');
      if (body.threadId) setSelectedVoiceThreadId(body.threadId);
      if (body.callId) voiceCallIdRef.current = body.callId;
      if (body.sessionId) voiceSessionIdRef.current = body.sessionId;
      if (typeof body.maxToolCalls === 'number') cappedToolLimitRef.current = body.maxToolCalls;
      await peer.setRemoteDescription({ type: 'answer', sdp: body.sdp });

      if (!subscription) {
        const warningSeconds = Math.max(1, body.warningAfterSeconds ?? 240);
        const expirySeconds = Math.max(warningSeconds + 1, body.expiresAfterSeconds ?? 300);
        voiceTimeoutRef.current = window.setTimeout(() => {
          setVoiceStatus('One minute remains in this capped demo voice session.');
          voiceTimeoutRef.current = window.setTimeout(() => stopVoice('Funded demo voice session ended.'), (expirySeconds - warningSeconds) * 1_000);
        }, warningSeconds * 1_000);
        return;
      }

      if (!body.toolSocketUrl || !body.toolSocketToken) throw new Error('Subscription voice did not return its secure tool connection.');
      const socket = new WebSocket(body.toolSocketUrl, ['openassist-tools', `openassist-token.${body.toolSocketToken}`]);
      voiceSocketRef.current = socket;
      socket.addEventListener('message', (event) => {
        let message: { type?: string; callId?: string; operation?: string; tool?: string; args?: Record<string, unknown>; previewId?: string; message?: string; role?: string; delta?: string; text?: string };
        try { message = JSON.parse(String(event.data)) as typeof message; } catch { return; }
        if (message.type === 'transcript' && (message.role === 'user' || message.role === 'assistant')) {
          updateVoiceTranscript(message.role, message.text ?? message.delta ?? '', Boolean(message.text));
          return;
        }
        if (message.type === 'tool_call') voiceToolCountRef.current += 1;
        if (message.type === 'tool_call' && message.callId && message.operation === 'confirm_preview' && message.previewId) {
          void approve('voice', message.previewId).then((result) => {
            if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'tool_result', callId: message.callId, success: true, result }));
          }).catch((error: unknown) => {
            if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'tool_result', callId: message.callId, success: false, error: error instanceof Error ? error.message : 'Voice confirmation failed.' }));
          });
        } else if (message.type === 'tool_call' && message.callId && message.tool && isWorkspaceToolName(message.tool)) {
          void invokeTool(message.tool, message.args ?? {}).then((result) => {
            if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'tool_result', callId: message.callId, success: true, result }));
          }).catch((error: unknown) => {
            if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'tool_result', callId: message.callId, success: false, error: error instanceof Error ? error.message : 'Workspace tool failed.' }));
          });
        } else if (message.type === 'session_warning') {
          setVoiceStatus(message.message ?? 'Voice will stop in five minutes.');
        } else if (message.type === 'voice_error') {
          setVoiceStatus(message.message ?? 'The realtime voice service returned an error.');
        } else if (message.type === 'session_ended') {
          stopVoice(message.message ?? 'Voice session ended.');
        }
      });
      socket.addEventListener('open', () => {
        setVoiceConnected(true);
        const confirmedVoice = parseRealtimeVoice(body.voice ?? voiceForSession);
        setActiveVoice(confirmedVoice);
        setVoiceStatus(body.resumed ? `Listening with ${voiceLabel(confirmedVoice)} · resumed saved conversation` : `Listening with ${voiceLabel(confirmedVoice)} · new saved conversation`);
      });
      socket.addEventListener('close', () => {
        if (voiceSocketRef.current === socket) stopVoice('Voice connection ended.');
      });
    } catch (error) {
      stopVoice(error instanceof Error ? error.message : 'Voice is temporarily unavailable.');
    }
  }, [approve, invokeTool, judgeVoicePolicy.sessionSeconds, resetVoiceTurn, selectedVoiceThreadId, stopVoice, updateVoiceTranscript, user, voiceConnected]);

  const toggleVoiceMute = useCallback(() => {
    const next = !voiceMuted;
    voiceStreamRef.current?.getAudioTracks().forEach((track) => { track.enabled = !next; });
    setVoiceMuted(next);
    setVoiceStatus(next ? 'Microphone muted' : activeVoiceKindRef.current === 'demo_capped' ? 'Listening · capped synthetic demo' : 'Listening through your ChatGPT subscription');
  }, [voiceMuted]);

  const selectDemoVoiceAccess = useCallback((access: DemoVoiceAccess) => {
    if (access === 'capped' && cappedVoiceAvailable === false) {
      setVoiceStatus('Quick demo voice is not enabled. Use My ChatGPT or the ChatGPT in-app browser.');
      return;
    }
    if (voiceConnected) stopVoice('Voice stopped before changing access.');
    demoVoiceAccessRef.current = access;
    setDemoVoiceAccess(access);
    setVoicePrompt(null);
    setVoiceThreads([]);
    setSelectedVoiceThreadId(null);
    setVoiceStatus(access === 'capped'
      ? `Ready for a funded ${Math.ceil(judgeVoicePolicy.sessionSeconds / 60)}-minute synthetic demo`
      : 'Ready to connect your own ChatGPT subscription');
    if (access === 'subscription') void refreshVoiceThreads(true);
  }, [cappedVoiceAvailable, judgeVoicePolicy.sessionSeconds, refreshVoiceThreads, stopVoice, voiceConnected]);

  useEffect(() => () => stopVoice('Voice stopped'), [stopVoice]);

  // Derive the visible conversation state from the audio the user actually
  // hears and the microphone signal we actually receive. This keeps the orb in
  // sync even when the realtime protocol does not emit a UI-friendly event.
  useEffect(() => {
    if (!voiceMeter) return;
    let frame = 0;
    let last = performance.now();
    let hearingFor = 0;
    let speakingFor = 0;
    let wasHearing = false;
    let thinkingUntil = 0;
    const tick = (now: number) => {
      const dt = Math.min((now - last) / 1000, 0.1);
      last = now;
      const { mic, output } = voiceMeter.sample(dt);
      // Require a short sustained level so a click or breath cannot flip state.
      hearingFor = mic > 0.045 ? hearingFor + dt : 0;
      speakingFor = output > 0.04 ? speakingFor + dt : 0;
      const hearing = mic > 0.045 && hearingFor > 0.055;
      const speaking = output > 0.04 && speakingFor > 0.065;

      if (hearing) thinkingUntil = 0;
      else if (wasHearing) thinkingUntil = now + 2_400;
      if (speaking) thinkingUntil = 0;
      const thinking = !hearing && !speaking && now < thinkingUntil;

      setVoiceHearing((current) => (current === hearing ? current : hearing));
      setVoiceThinking((current) => (current === thinking ? current : thinking));
      setVoiceSpeaking((current) => (current === speaking ? current : speaking));
      wasHearing = hearing;
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(frame);
      setVoiceHearing(false);
      setVoiceThinking(false);
      setVoiceSpeaking(false);
    };
  }, [voiceMeter]);

  const voiceStatusLower = voiceStatus.toLowerCase();
  const voiceIsConnecting = /checking|starting|pending|sign-in|connecting/.test(voiceStatusLower);
  const voiceHasError = /failed|error|unavailable|could not|ended|not compatible/.test(voiceStatusLower);
  const orbPhase: OrbPhase = !voiceConnected
    ? voiceIsConnecting
      ? 'connecting'
      : voiceHasError
        ? 'error'
        : 'idle'
    : voiceMuted
      ? 'muted'
      : voiceSpeaking
        ? 'speaking'
        : voiceThinking
          ? 'thinking'
          : 'listening';
  const voiceStateLabel = orbPhase === 'connecting'
    ? 'Connecting'
    : orbPhase === 'error'
      ? 'Needs attention'
      : orbPhase === 'muted'
        ? 'Muted'
        : orbPhase === 'speaking'
          ? 'Speaking'
          : orbPhase === 'thinking'
            ? 'Thinking'
            : orbPhase === 'listening'
              ? voiceHearing ? 'Hearing you' : 'Listening'
              : 'Ready';

  const filteredMessages = useMemo(() => {
    const query = search.trim().toLowerCase();
    return query ? messages.filter((message) => `${message.account} ${message.sender} ${message.subject} ${message.snippet}`.toLowerCase().includes(query)) : messages;
  }, [messages, search]);

  const resetDemo = useCallback(async () => {
    if (voiceConnected) stopVoice('Voice stopped because the demo was reset.');
    setDemoLoading(true);
    const response = await fetch('/api/demo/workspace', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'reset' }),
    });
    const body = (await response.json()) as DemoApiResponse;
    if (!response.ok || !body.workspace) {
      setDemoLoading(false);
      setToast(body.error ?? 'The demo workspace could not be reset.');
      return;
    }
    setPending(null);
    hydrateDemoWorkspace(body.workspace, body.expiresAt);
    setToast('Demo workspace reset to safe sample data.');
    focusView('today');
  }, [focusView, hydrateDemoWorkspace, stopVoice, voiceConnected]);

  const submitEditor = useCallback((kind: Exclude<EditorKind, null>, args: Record<string, unknown>) => {
    setEditor(null);
    const tool = kind === 'task' ? 'workspace_create_task' : 'workspace_save_note';
    void invokeTool(tool, args).catch((error: unknown) => {
      setToast(error instanceof Error ? error.message : 'The preview could not be created.');
    });
  }, [invokeTool]);

  const signOut = useCallback(async () => {
    if (voiceConnected) stopVoice('Voice stopped before signing out.');
    if (user?.access === 'owner') {
      router.push('/signout-with-chatgpt?return_to=%2F');
      return;
    }
    await fetch('/api/judge/logout', { method: 'POST' }).catch(() => undefined);
    router.refresh();
  }, [router, stopVoice, user?.access, voiceConnected]);

  const completeOwnerSetup = useCallback(async () => {
    const code = ownerSetupCode.trim();
    if (!code) {
      setToast('Enter the one-time owner code.');
      return;
    }
    const response = await fetch('/api/owner/bootstrap', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code }),
    });
    const text = await response.text();
    let body: { status?: string; error?: string } = {};
    try { body = JSON.parse(text) as typeof body; } catch { body = { error: text }; }
    if (!response.ok || body.status !== 'owner_bound') {
      setToast(body.error ?? 'Owner setup could not be completed.');
      return;
    }
    setOwnerSetupCode('');
    setToast('Owner setup complete. Reloading private mode…');
    window.location.reload();
  }, [ownerSetupCode]);

  const copy = view === 'today'
    ? { ...VIEW_COPY.today, eyebrow: todayEyebrow }
    : mode === 'demo' && view === 'notes'
    ? { eyebrow: 'Temporary demo notes', title: 'Notes', subtitle: 'Judge-created notes stay isolated from Google and expire automatically.' }
    : mode === 'demo' && view === 'memory'
      ? { eyebrow: 'Temporary demo memory', title: 'Memory', subtitle: 'Safe synthetic preferences for testing agent decisions.' }
      : mode === 'live' && view === 'inbox'
        ? { ...VIEW_COPY.inbox, eyebrow: 'Connected Google accounts' }
      : VIEW_COPY[view];
  const resolvedTheme = themePreference === 'system' ? (systemDark ? 'dark' : 'light') : themePreference;
  return (
    <main data-theme={resolvedTheme} className="oa-app-shell min-h-screen text-ink">
      <div className="mx-auto grid min-h-screen w-full max-w-[1800px] grid-cols-[238px_minmax(0,1fr)_minmax(300px,340px)] max-xl:grid-cols-[84px_minmax(0,1fr)] max-md:grid-cols-1">
        <Sidebar view={view} user={user} items={visibleNavigation} onView={focusView} onSignOut={() => void signOut()} />
        <section id={`view-${view}`} className="min-w-0 pb-[calc(88px+env(safe-area-inset-bottom))] md:pb-10">
          <div className="flex items-center justify-between gap-3 border-b border-hairline px-5 py-3.5 md:hidden">
            <div className="flex min-w-0 items-center gap-2.5">
              <BrandMark size="h-8 w-8" />
              <div className="min-w-0">
                <p className="truncate text-sm font-semibold leading-tight">OpenAssist</p>
                <p className="truncate text-[11px] leading-tight text-text-3">Daily Workspace</p>
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-2"><span className="rounded-full border border-brand/20 bg-brand/10 px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">{user?.access === 'judge' ? 'Judge' : mode}</span><button onClick={() => void signOut()} className="text-[10px] font-medium text-text-3">Sign out</button></div>
          </div>

          <div className="px-5 pt-5 sm:px-8 sm:pt-6 lg:px-12">
            <header className="relative pb-5"><div aria-hidden="true" className="oa-header-divider" />
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0">
                  <p className="truncate text-[11px] font-semibold uppercase tracking-[0.14em] text-text-3 sm:text-xs">{copy.eyebrow}</p>
                  <h1 className="mt-1 text-2xl font-semibold tracking-[-0.03em] sm:text-3xl">{copy.title}</h1>
                  <p className="mt-1 max-w-prose text-sm leading-5 text-text-3 max-sm:hidden">{copy.subtitle}</p>
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  <ThemePicker value={themePreference} onChange={chooseTheme} />
                  <button onClick={() => setVoicePanelOpen(true)} aria-label={`Open voice · ${voiceStateLabel}`} title={`Open voice · ${voiceStateLabel}`} className="group grid shrink-0 place-items-center rounded-full opacity-90 transition duration-150 hover:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/50">
                    <VoiceOrb phase={orbPhase} meter={voiceMeter} size={48} />
                  </button>
                </div>
              </div>

              <div className="mt-4 flex flex-wrap items-center gap-2.5">
                <label className="relative min-w-0 flex-1 basis-full sm:basis-auto sm:max-w-xs">
                  <span className="sr-only">Search current view</span>
                  <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder={view === 'work' ? 'Use Knowledge search below' : 'Filter this view'} disabled={view === 'work'} className="w-full min-w-0 rounded-xl border border-hairline-strong bg-wash px-3 py-2 text-sm outline-none transition placeholder:text-text-4 focus:border-brand/50 focus:ring-2 focus:ring-brand/10 disabled:cursor-not-allowed disabled:opacity-45" />
                </label>
                {ownerAccess && <span className="shrink-0 rounded-xl border border-teal/20 bg-teal/10 px-3 py-2 text-xs font-semibold text-teal-strong xl:hidden">Private Live</span>}
                {mode === 'demo' && <button onClick={() => void resetDemo()} className="shrink-0 rounded-xl border border-hairline-strong px-3 py-2 text-xs text-text-2 transition hover:border-brand/35 hover:text-ink">Reset demo</button>}
              </div>
            </header>
            {mode === 'demo' && <div className="mt-4 rounded-xl border border-hairline bg-wash/60 px-4 py-3"><div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 text-xs text-text-3"><span className="oa-wrap-anywhere">Private synthetic judge workspace · no Google data</span><span className="oa-wrap-anywhere">{demoExpiresAt ? `Resets ${new Date(demoExpiresAt).toLocaleDateString()}` : 'Preparing isolated storage…'}</span></div></div>}
            {mode === 'demo' && view === 'today' && <JudgeQuickStart onNavigate={focusView} toolCount={webMcpTools.length} />}
            <div key={view} className="oa-view-in py-7">
              {mode === 'live' ? (
              view === 'activity'
                ? <ActivityView mode={mode} activity={activity} owner={Boolean(user?.owner)} onVoicePolicyChanged={refreshJudgeVoicePolicy} />
                : view === 'work' && live.accounts && !live.error
                  ? <SecondBrainWorkspace source={live.data.work} loading={live.loading} warning={live.warning} onRefresh={() => setLiveRefreshKey((current) => current + 1)} onInvoke={invokeTool} />
                : <LiveWorkspaceView view={view} live={live} query={search} selectedId={selectedId} ownerCode={ownerSetupCode} onOwnerCode={setOwnerSetupCode} onBootstrap={() => void completeOwnerSetup()} onReconnect={() => router.push('/api/workspace/connect')} onRetry={() => setLiveRefreshKey((current) => current + 1)} onOpenNote={(item) => void openLiveNote(item)} onOpenItem={(id, item) => { setSelectedId(id); setOpenLiveItem({ id, view, item }); }} />
            ) : demoLoading ? <WorkspaceLoading title="Preparing your private demo workspace" detail="Loading isolated synthetic mail, tasks, and calendar…" /> : <>
              {view === 'today' && <TodayView messages={messages.filter((message) => message.unread)} tasks={tasks.filter((task) => !task.completed)} events={events.filter((event) => event.day === 'Today')} selectedId={selectedId} onSelect={setSelectedId} onNavigate={focusView} />}
              {view === 'inbox' && <InboxView messages={filteredMessages} selectedId={selectedId} onSelect={setSelectedId} onMarkRead={(message) => void invokeTool('workspace_set_mail_read_state', { account: message.account, messageIds: [message.id], state: 'read', scope: 'thread' })} />}
              {view === 'tasks' && <TasksView tasks={tasks} selectedId={selectedId} onSelect={(id) => { setSelectedId(id); const task = tasks.find((candidate) => candidate.id === id); if (task) setOpenLiveItem({ id, view: 'tasks', item: { ...task, _kind: 'Demo task' } }); }} onCreate={() => setEditor('task')} />}
              {view === 'calendar' && <CalendarView events={events} selectedId={selectedId} onSelect={setSelectedId} onCreate={() => void invokeTool('workspace_create_calendar_event', { account: 'Main', summary: 'WebMCP demo review', start: '2026-08-28T11:00:00-05:00', end: '2026-08-28T11:30:00-05:00', timeZone: 'America/Chicago', reminderMinutes: [10] })} />}
              {view === 'supplies' && <SuppliesView products={supplies} cart={supplyCart} selectedId={selectedId} onSelect={setSelectedId} onSearch={(query) => void invokeTool('workspace_search_supplies', { query, limit: 12 })} onAdd={(product) => void invokeTool('workspace_update_supply_cart', { productId: product.id, variantId: product.variantId, title: product.title, quantity: 1 })} onClear={() => void invokeTool('workspace_clear_supply_cart', {})} />}
              {view === 'notes' && <NotesView mode={mode} notes={notes} onCreate={() => setEditor('note')} onOpen={openDemoNote} />}
              {view === 'memory' && <MemoryView mode={mode} memory={memory} onRemember={() => void invokeTool('workspace_remember_fact', { category: 'Preferences', fact: 'Use the Main account for personal reminders.' })} />}
              {view === 'accounts' && <AccountsView mode={mode} accounts={accounts} />}
              {view === 'activity' && <ActivityView mode={mode} activity={activity} />}
              </>}
            </div>
          </div>
        </section>
        <ActivityRail activity={activity} toast={toast} voiceStatus={voiceStatus} voiceStateLabel={voiceStateLabel} voiceConnected={voiceConnected} orbPhase={orbPhase} voiceMeter={voiceMeter} onOpenVoice={() => setVoicePanelOpen(true)} onOpenActivity={() => focusView('activity')} />
      </div>
      {voicePanelOpen && <VoiceStage mode={mode} demoVoiceAccess={demoVoiceAccess} cappedVoiceAvailable={cappedVoiceAvailable} judgeVoicePolicy={judgeVoicePolicy} status={voiceStatus} stateLabel={voiceStateLabel} prompt={voicePrompt} connected={voiceConnected} muted={voiceMuted} selectedVoice={selectedVoice} activeVoice={activeVoice} phase={orbPhase} meter={voiceMeter} transcript={voiceTranscript} threads={voiceThreads} selectedThreadId={selectedVoiceThreadId} threadsLoading={voiceThreadsLoading} onClose={() => setVoicePanelOpen(false)} onVoice={connectVoice} onMute={toggleVoiceMute} onVoiceChange={selectVoice} onDemoVoiceAccess={selectDemoVoiceAccess} onSelectThread={setSelectedVoiceThreadId} onRefreshThreads={() => void refreshVoiceThreads()} />}
      {pending && <ApprovalDrawer action={pending} onCancel={() => { setPending(null); setToast('Preview cancelled. Nothing changed.'); }} onApprove={() => void approve('tap')} />}
      {editor && <ItemEditor kind={editor} onCancel={() => setEditor(null)} onSubmit={(args) => submitEditor(editor, args)} />}
      {openNote && <NoteReader note={openNote} onClose={() => setOpenNote(null)} />}
      {openLiveItem && <LiveItemReader value={openLiveItem} onClose={() => setOpenLiveItem(null)} />}
      <div aria-live="polite" className={`fixed bottom-[calc(5.25rem+env(safe-area-inset-bottom))] left-1/2 z-30 w-[min(92vw,460px)] -translate-x-1/2 rounded-2xl border bg-surface/95 px-4 py-3 text-center text-xs leading-5 shadow-[0_18px_60px_rgba(0,0,0,0.45)] backdrop-blur-xl transition-opacity duration-500 xl:hidden md:bottom-5 ${toastFaded ? 'pointer-events-none opacity-0' : 'opacity-100'} ${toastSeverity(toast) === 'error' ? 'border-danger/30 text-danger-strong' : toastSeverity(toast) === 'success' ? 'border-success/25 text-text-2' : 'border-hairline-strong text-text-2'}`}>{toast}</div>
      <MobileNavigation view={view} items={visibleNavigation} onView={focusView} />
    </main>
  );
}

function JudgeQuickStart({ onNavigate, toolCount }: { onNavigate: (view: WorkspaceView) => void; toolCount: number }) {
  return (
    <section aria-labelledby="judge-quick-start" className="mt-4 overflow-hidden rounded-2xl border border-hairline bg-wash/60">
      <div className="flex flex-wrap items-start justify-between gap-3 px-4 py-3.5 sm:px-5">
        <div className="min-w-0">
          <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">Judge quick start</p>
          <h2 id="judge-quick-start" className="mt-1 text-sm font-semibold text-ink">Ask ChatGPT to work with this visible workspace</h2>
          <p className="mt-1 max-w-2xl text-xs leading-5 text-text-3">Reads happen immediately. Any change opens an exact preview here and waits for your approval.</p>
        </div>
        <span className="shrink-0 rounded-full border border-accent/20 bg-accent/10 px-2.5 py-1 text-[10px] font-semibold text-accent-strong">{toolCount} WebMCP tools</span>
      </div>
      <div className="grid border-t border-hairline md:grid-cols-3">
        <button type="button" onClick={() => onNavigate('inbox')} className="group px-4 py-3 text-left transition hover:bg-brand/5 focus-visible:bg-brand/5 focus-visible:outline-none sm:px-5 md:border-r md:border-hairline">
          <span className="block text-[10px] font-semibold uppercase tracking-[0.14em] text-text-3 group-hover:text-brand">1 · Understand</span>
          <span className="mt-1 block text-xs leading-5 text-text-2">“Show my daily brief and focus the most urgent unread message.”</span>
        </button>
        <button type="button" onClick={() => onNavigate('supplies')} className="group border-t border-hairline px-4 py-3 text-left transition hover:bg-brand/5 focus-visible:bg-brand/5 focus-visible:outline-none sm:px-5 md:border-r md:border-t-0 md:border-hairline">
          <span className="block text-[10px] font-semibold uppercase tracking-[0.14em] text-text-3 group-hover:text-brand">2 · Find</span>
          <span className="mt-1 block text-xs leading-5 text-text-2">“Find a USB-C Security Key and prepare one in the cart.”</span>
        </button>
        <button type="button" onClick={() => onNavigate('activity')} className="group border-t border-hairline px-4 py-3 text-left transition hover:bg-brand/5 focus-visible:bg-brand/5 focus-visible:outline-none sm:px-5 md:border-t-0">
          <span className="block text-[10px] font-semibold uppercase tracking-[0.14em] text-text-3 group-hover:text-brand">3 · Verify</span>
          <span className="mt-1 block text-xs leading-5 text-text-2">Approve the preview, then see the verified result in Activity.</span>
        </button>
      </div>
    </section>
  );
}

const VIEW_ICONS: Record<WorkspaceView, React.ReactNode> = {
  today: <path d="M3 9h18M7 3v3m10-3v3M5 5h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z" />,
  inbox: <path d="M3 12h4l2 3h6l2-3h4M5 5h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z" />,
  tasks: <path d="m4 12 3.5 3.5L20 6M4 19h10" />,
  work: <><path d="M4 7h6l2 2h8v10a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2Z" /><path d="M8 3h8v4H8zM8 14h8m-8 3h5" /></>,
  calendar: <path d="M8 3v3m8-3v3M4 10h16M5 6h14a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1Z" />,
  supplies: <><path d="M4 7.5 12 3l8 4.5v9L12 21l-8-4.5Z" /><path d="m4 7.5 8 4.5 8-4.5M12 12v9" /></>,
  notes: <path d="M8 4h8l4 4v12a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1Zm7 0v5h5M8 13h8M8 17h5" />,
  memory: <path d="M12 3a4 4 0 0 0-4 4v1a3 3 0 0 0 0 6v2a4 4 0 0 0 8 0v-2a3 3 0 0 0 0-6V7a4 4 0 0 0-4-4Zm0 0v18" />,
  accounts: <path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-8 8a8 8 0 0 1 16 0" />,
  activity: <path d="M3 12h4l3 7 4-16 3 9h4" />,
};

function ViewIcon({ view, className = 'h-[18px] w-[18px]' }: { view: WorkspaceView; className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      {VIEW_ICONS[view]}
    </svg>
  );
}

function MobileNavigation({ view, items, onView }: { view: WorkspaceView; items: typeof NAVIGATION; onView: (view: WorkspaceView) => void }) {
  const [moreOpen, setMoreOpen] = useState(false);
  const primary = items.slice(0, 4);
  const overflow = items.slice(4);
  const overflowActive = overflow.some((item) => item.view === view);

  return (
    <>
      {moreOpen && (
        <div className="fixed inset-0 z-40 bg-black/50 backdrop-blur-[2px] md:hidden" onClick={() => setMoreOpen(false)} aria-hidden="true" />
      )}
      <nav aria-label="Workspace views" className="fixed bottom-0 left-0 z-50 w-screen max-w-full border-t border-hairline bg-surface/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-xl md:hidden">
        {moreOpen && (
          <div className="grid grid-cols-4 gap-1 border-b border-hairline px-2 py-2">
            {overflow.map((item) => (
              <button key={item.view} onClick={() => { onView(item.view); setMoreOpen(false); }} aria-current={view === item.view ? 'page' : undefined} className={`flex flex-col items-center gap-1 rounded-xl px-1 py-2.5 transition ${view === item.view ? 'bg-brand/15 text-brand-strong' : 'text-text-2 hover:bg-wash'}`}>
                <ViewIcon view={item.view} />
                <span className="w-full truncate text-center text-[10px] leading-tight">{item.label}</span>
              </button>
            ))}
          </div>
        )}
        <ul className="grid grid-cols-5 gap-0.5 px-1.5 py-1.5">
          {primary.map((item) => (
            <li key={item.view} className="min-w-0">
              <button onClick={() => { onView(item.view); setMoreOpen(false); }} aria-current={view === item.view ? 'page' : undefined} className={`flex w-full flex-col items-center gap-0.5 rounded-xl px-1 py-1.5 transition ${view === item.view ? 'text-brand-strong' : 'text-text-3'}`}>
                <span className={`grid h-8 w-full max-w-[56px] place-items-center rounded-lg transition ${view === item.view ? 'bg-brand/15' : ''}`}>
                  <ViewIcon view={item.view} />
                </span>
                <span className="w-full truncate text-center text-[10px] font-medium leading-tight">{item.label}</span>
              </button>
            </li>
          ))}
          <li className="min-w-0">
            <button onClick={() => setMoreOpen((open) => !open)} aria-expanded={moreOpen} aria-label="More workspace views" className={`flex w-full flex-col items-center gap-0.5 rounded-xl px-1 py-1.5 transition ${moreOpen || overflowActive ? 'text-brand-strong' : 'text-text-3'}`}>
              <span className={`grid h-8 w-full max-w-[56px] place-items-center rounded-lg transition ${moreOpen || overflowActive ? 'bg-brand/15' : ''}`}>
                <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" className="h-[18px] w-[18px]"><circle cx="5" cy="12" r="1.7" /><circle cx="12" cy="12" r="1.7" /><circle cx="19" cy="12" r="1.7" /></svg>
              </span>
              <span className="w-full truncate text-center text-[10px] font-medium leading-tight">More</span>
            </button>
          </li>
        </ul>
      </nav>
    </>
  );
}

const THEME_OPTIONS: Array<{ id: ThemePreference; label: string; icon: React.ReactNode }> = [
  { id: 'system', label: 'System theme', icon: <path d="M4 5h16a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Zm5 14h6m-3-3v3" /> },
  { id: 'light', label: 'Light theme', icon: <path d="M12 4V2m0 20v-2m8-8h2M2 12h2m13.66-5.66 1.41-1.41M4.93 19.07l1.41-1.41m0-11.32L4.93 4.93m14.14 14.14-1.41-1.41M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10Z" /> },
  { id: 'dark', label: 'Dark theme', icon: <path d="M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8Z" /> },
];

function ThemePicker({ value, onChange }: { value: ThemePreference; onChange: (value: ThemePreference) => void }) {
  return (
    <div role="radiogroup" aria-label="Color theme" className="flex h-9 shrink-0 items-center rounded-xl border border-hairline-strong bg-wash p-0.5">
      {THEME_OPTIONS.map((option) => (
        <button key={option.id} type="button" role="radio" aria-checked={value === option.id} title={option.label} onClick={() => onChange(option.id)} className={`grid h-full w-8 place-items-center rounded-[10px] transition ${value === option.id ? 'bg-wash-strong text-ink shadow-[inset_0_0_0_1px_var(--hairline-strong)]' : 'text-text-4 hover:text-text-2'}`}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className="h-4 w-4">{option.icon}</svg>
          <span className="sr-only">{option.label}</span>
        </button>
      ))}
    </div>
  );
}

function Sidebar({ view, user, items, onView, onSignOut }: { view: WorkspaceView; user: SiteUser; items: typeof NAVIGATION; onView: (view: WorkspaceView) => void; onSignOut: () => void }) {
  const owner = user?.access === 'owner';
  return <aside className="min-w-0 border-r border-hairline px-5 py-6 max-xl:px-3 max-md:hidden"><div className="mb-8 flex items-center gap-3 px-2"><BrandMark /><div className="max-xl:hidden"><p className="font-semibold">OpenAssist</p><p className="text-xs text-text-3">Daily Workspace</p></div></div><nav aria-label="Primary workspace views"><ul className="space-y-1">{items.map((item) => <li key={item.view}><button onClick={() => onView(item.view)} aria-current={view === item.view ? 'page' : undefined} title={item.label} className={`flex w-full items-center gap-3 rounded-xl border-l-2 px-3 py-2.5 text-left text-sm transition max-xl:justify-center max-xl:px-2 ${view === item.view ? 'border-brand bg-wash-strong text-ink' : 'border-transparent text-text-2 hover:bg-wash hover:text-ink'}`}><span className={`grid h-7 w-7 shrink-0 place-items-center rounded-lg ${view === item.view ? 'text-brand' : 'text-text-3'}`}><ViewIcon view={item.view} className="h-4 w-4" /></span><span className="truncate max-xl:hidden">{item.label}</span></button></li>)}</ul></nav><div className="mt-8 border-t border-hairline pt-5 max-xl:hidden"><p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-4">Access</p><span className={`mt-3 inline-flex rounded-full border px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.1em] ${owner ? 'border-teal/20 bg-teal/10 text-teal-strong' : 'border-brand/20 bg-brand/10 text-brand'}`}>{owner ? 'Private Live' : 'Judge Demo'}</span><p className="mt-3 text-xs leading-5 text-text-3">{owner ? `Owner · ${user?.email}` : 'Judge · isolated Demo only'}</p><button onClick={onSignOut} className="mt-3 text-xs font-medium text-text-2 transition hover:text-ink">Sign out</button></div></aside>;
}

function VoiceThreadPicker({ threads, selectedId, loading, connected, onSelect, onRefresh }: { threads: VoiceThread[]; selectedId: string | null; loading: boolean; connected: boolean; onSelect: (threadId: string | null) => void; onRefresh: () => void }) {
  const selectId = useId();
  return (
    <div className="rounded-2xl border border-hairline bg-wash/60 p-3.5">
      <div className="flex items-center justify-between gap-3">
        <label htmlFor={selectId} className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-3">Conversation</label>
        <button type="button" onClick={onRefresh} disabled={loading || connected} className="text-[11px] font-medium text-brand transition hover:text-brand-strong disabled:cursor-not-allowed disabled:opacity-40">{loading ? 'Loading…' : 'Refresh'}</button>
      </div>
      <select id={selectId} value={selectedId ?? ''} onChange={(event) => onSelect(event.target.value || null)} disabled={loading || connected} className="mt-2 w-full rounded-xl border border-hairline-strong bg-surface px-3 py-2.5 text-sm text-ink outline-none transition focus:border-brand/50 focus:ring-2 focus:ring-brand/10 disabled:cursor-not-allowed disabled:opacity-60">
        <option value="">New conversation</option>
        {threads.map((thread) => {
          const savedAt = thread.updatedAt || thread.createdAt;
          const label = thread.name || thread.preview || (savedAt ? `Conversation from ${new Date(savedAt * 1_000).toLocaleDateString()}` : 'Saved conversation');
          return <option key={thread.id} value={thread.id}>{label.slice(0, 90)}</option>;
        })}
      </select>
      <p className="mt-2 text-[11px] leading-4 text-text-3">{connected ? 'Stop voice before changing conversations.' : selectedId ? 'Voice will continue this saved conversation.' : 'Voice will start a new saved conversation.'}</p>
    </div>
  );
}

function VoicePicker({ value, connected, onChange }: { value: RealtimeVoice; connected: boolean; onChange: (voice: RealtimeVoice) => void }) {
  const selectId = useId();
  const selected = REALTIME_VOICES.find((voice) => voice.id === value) ?? REALTIME_VOICES[0];
  return (
    <div className="rounded-2xl border border-hairline bg-wash/60 p-3.5">
      <div className="flex items-center justify-between gap-3">
        <label htmlFor={selectId} className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-3">Voice</label>
        <span className="text-[10px] text-text-4">{connected ? 'Stop to change' : selected.description}</span>
      </div>
      <select id={selectId} value={value} onChange={(event) => onChange(parseRealtimeVoice(event.target.value))} disabled={connected} className="mt-2 w-full rounded-xl border border-hairline-strong bg-surface px-3 py-2.5 text-sm text-ink outline-none transition focus:border-brand/50 focus:ring-2 focus:ring-brand/10 disabled:cursor-not-allowed disabled:opacity-60">
        {REALTIME_VOICES.map((voice) => <option key={voice.id} value={voice.id}>{voice.label} · {voice.description}</option>)}
      </select>
    </div>
  );
}

function DemoVoiceChoice({ value, connected, cappedAvailable, policy, onChange }: { value: DemoVoiceAccess; connected: boolean; cappedAvailable: boolean | null; policy: JudgeVoicePolicy; onChange: (access: DemoVoiceAccess) => void }) {
  const choices: Array<{ id: DemoVoiceAccess; title: string; detail: string }> = [
    { id: 'capped', title: 'Funded judge demo', detail: `Included access · ${Math.ceil(policy.sessionSeconds / 60)} min · ${policy.maxToolCalls} tools` },
  ];
  return (
    <div role="radiogroup" aria-label="Demo voice access" className="grid gap-2 sm:grid-cols-2 xl:grid-cols-1">
      {choices.map((choice) => (
        <button key={choice.id} type="button" role="radio" aria-checked={value === choice.id} disabled={connected || (choice.id === 'capped' && cappedAvailable === false)} onClick={() => onChange(choice.id)} className={`rounded-xl border px-3 py-2.5 text-left transition disabled:cursor-not-allowed disabled:opacity-45 ${value === choice.id ? 'border-brand/45 bg-brand/10 shadow-[0_0_18px_rgba(224,188,99,0.06)]' : 'border-hairline bg-wash/60 hover:border-brand/25'}`}>
          <span className={`block text-xs font-semibold ${value === choice.id ? 'text-brand-strong' : 'text-text-2'}`}>{choice.title}</span>
          <span className="mt-0.5 block text-[10px] leading-4 text-text-4">{choice.id === 'capped' && cappedAvailable === false ? 'Not enabled in this deployment' : choice.detail}</span>
        </button>
      ))}
    </div>
  );
}

function ActivityRail({ activity, toast, voiceStatus, voiceStateLabel, voiceConnected, orbPhase, voiceMeter, onOpenVoice, onOpenActivity }: { activity: typeof DEMO_ACTIVITY; toast: string; voiceStatus: string; voiceStateLabel: string; voiceConnected: boolean; orbPhase: OrbPhase; voiceMeter: VoiceLevelMeter | null; onOpenVoice: () => void; onOpenActivity: () => void }) {
  return (
    <aside className="min-w-0 border-l border-hairline bg-transparent px-5 py-7 max-xl:hidden">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="truncate font-semibold">Workspace activity</h2>
          <p className="mt-1 oa-clamp-1 text-xs text-text-3">Every action stays visible.</p>
        </div>
        <span className="shrink-0 rounded-full border border-accent/20 bg-accent/10 px-2.5 py-1 text-[10px] font-semibold text-accent-strong">WebMCP</span>
      </div>
      <div className="mt-6 space-y-1">
        {activity.length ? activity.slice(0, 5).map((item) => (
          <button key={item.id} onClick={onOpenActivity} className="block w-full rounded-xl px-3 py-2.5 text-left transition hover:bg-wash hover:shadow-[inset_0_0_0_1px_var(--hairline-strong)]">
            <p className="oa-clamp-2 text-sm leading-5 text-ink/90">{item.action}</p>
            <p className="mt-1 oa-clamp-1 text-xs text-text-4">{item.actor} · {item.time}</p>
          </button>
        )) : <div className="rounded-2xl border border-dashed border-hairline px-4 py-5 text-center"><p className="text-xs font-medium text-text-2">No session activity yet</p><p className="mt-1 text-[11px] leading-4 text-text-4">Reads and approved changes will appear here.</p></div>}
      </div>
      <div className="mt-8 border-t border-hairline pt-6">
        <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-4">Voice</p>
        <button onClick={onOpenVoice} className="group mt-3 flex w-full items-center gap-3 rounded-xl border border-hairline bg-wash/60 px-3 py-3 text-left transition hover:border-hairline-strong hover:bg-wash focus-visible:outline-none">
          <VoiceOrb phase={orbPhase} meter={voiceMeter} size={56} />
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-medium">{voiceConnected ? 'Voice is active' : 'Open voice'}</span>
            <span className="mt-1 inline-flex items-center gap-1.5 rounded-full border border-hairline bg-wash px-2 py-0.5 text-[10px] font-semibold text-text-2"><span className={`oa-voice-state-dot oa-voice-state-dot--${orbPhase}`} />{voiceStateLabel}</span>
            <span className="mt-0.5 block oa-clamp-2 text-xs leading-4 text-text-3">{voiceStatus}</span>
          </span>
        </button>
      </div>
      <div aria-live="polite" className="mt-7 rounded-2xl border border-hairline bg-wash p-4">
        <p className="flex items-center gap-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-text-4"><span aria-hidden="true" className={`inline-block h-1.5 w-1.5 rounded-full ${toastSeverity(toast) === 'error' ? 'bg-danger' : toastSeverity(toast) === 'success' ? 'bg-success' : 'bg-text-4'}`} />Latest status</p>
        <p className="mt-2 oa-clamp-3 text-xs leading-5 text-text-2">{toast}</p>
      </div>
    </aside>
  );
}

function VoiceStage({ mode, demoVoiceAccess, cappedVoiceAvailable, judgeVoicePolicy, status, stateLabel, prompt, connected, muted, selectedVoice, activeVoice, phase, meter, transcript, threads, selectedThreadId, threadsLoading, onClose, onVoice, onMute, onVoiceChange, onDemoVoiceAccess, onSelectThread, onRefreshThreads }: { mode: Mode; demoVoiceAccess: DemoVoiceAccess; cappedVoiceAvailable: boolean | null; judgeVoicePolicy: JudgeVoicePolicy; status: string; stateLabel: string; prompt: VoicePrompt; connected: boolean; muted: boolean; selectedVoice: RealtimeVoice; activeVoice: RealtimeVoice | null; phase: OrbPhase; meter: VoiceLevelMeter | null; transcript: VoiceTranscript; threads: VoiceThread[]; selectedThreadId: string | null; threadsLoading: boolean; onClose: () => void; onVoice: () => void; onMute: () => void; onVoiceChange: (voice: RealtimeVoice) => void; onDemoVoiceAccess: (access: DemoVoiceAccess) => void; onSelectThread: (threadId: string | null) => void; onRefreshThreads: () => void }) {
  const liveVoice = activeVoice ?? selectedVoice;
  return (
    <aside className="oa-voice-dock" aria-label="OpenAssist voice agent">
      <section className="oa-voice-dock__panel">
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-accent-strong">OpenAssist agent</p>
            <p className="mt-0.5 truncate text-xs text-text-3">{mode === 'live' ? 'Private Live Workspace' : 'Isolated judge demo'}</p>
          </div>
          <button onClick={onClose} aria-label="Close voice agent" className="grid h-8 w-8 shrink-0 place-items-center rounded-full border border-hairline-strong text-lg text-text-2 transition hover:border-brand/35 hover:bg-wash hover:text-ink">×</button>
        </div>

        <div className="mt-3 grid grid-cols-[88px_minmax(0,1fr)] items-center gap-4 max-sm:grid-cols-[72px_minmax(0,1fr)] max-sm:gap-3">
          <div className="relative grid h-[88px] w-[88px] place-items-center rounded-full max-sm:h-[72px] max-sm:w-[72px]">
            <VoiceOrb phase={phase} meter={meter} size={72} />
            <span className="absolute -bottom-1 inline-flex items-center gap-1 rounded-full border border-hairline-strong bg-surface/95 px-2 py-0.5 text-[9px] font-semibold text-ink/90"><span className={`oa-voice-state-dot oa-voice-state-dot--${phase}`} />{stateLabel}</span>
          </div>
          <div className="min-w-0">
            <h2 className="truncate text-base font-semibold">{connected ? `${voiceLabel(liveVoice)} is ${stateLabel.toLowerCase()}` : `Talk with ${voiceLabel(selectedVoice)}`}</h2>
            <p aria-live="polite" className="mt-1 oa-clamp-2 text-xs leading-5 text-text-3">{status}</p>
            <div className="mt-2 flex flex-wrap gap-2">
              <button onClick={onVoice} className={`rounded-lg px-3.5 py-2 text-xs font-semibold transition ${connected ? 'border border-danger/30 bg-danger/10 text-danger-strong hover:bg-danger/15' : 'oa-btn-primary'}`}>{connected ? 'Stop' : 'Start voice'}</button>
              {connected && <button onClick={onMute} className="rounded-lg border border-hairline-strong px-3.5 py-2 text-xs text-text-2 transition hover:border-brand/30 hover:text-ink">{muted ? 'Unmute' : 'Mute'}</button>}
            </div>
          </div>
        </div>

        <div className="mt-3 grid gap-2 sm:grid-cols-2">
          <div className="min-h-[72px] rounded-xl border border-hairline bg-wash/60 px-3 py-2.5"><p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-text-3">You</p><p className="mt-1 oa-clamp-3 oa-wrap-anywhere text-xs leading-5 text-ink/90">{transcript.user || (connected ? 'Listening for your voice…' : 'Your live words will appear here.')}</p></div>
          <div className="min-h-[72px] rounded-xl border border-accent/15 bg-accent/5 px-3 py-2.5"><p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-accent-strong">OpenAssist</p><p className="mt-1 oa-clamp-3 oa-wrap-anywhere text-xs leading-5 text-ink/90">{transcript.assistant || (connected ? 'Waiting to respond…' : 'The spoken answer will appear here.')}</p></div>
        </div>
        <p className="mt-1.5 text-center text-[9px] text-text-4">Live transcript only · not saved by the website</p>

        <details className="oa-voice-dock__settings mt-3 rounded-xl border border-hairline bg-wash/60">
          <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2.5 text-xs font-medium text-text-2 transition hover:text-ink">
            <span>Voice &amp; conversation</span>
            <span aria-hidden="true" className="oa-voice-dock__chevron text-text-3">⌄</span>
          </summary>
          <div className="grid gap-2 border-t border-hairline p-3 sm:grid-cols-2">{mode === 'demo' && <DemoVoiceChoice value={demoVoiceAccess} connected={connected} cappedAvailable={cappedVoiceAvailable} policy={judgeVoicePolicy} onChange={onDemoVoiceAccess} />}<VoicePicker value={selectedVoice} connected={connected} onChange={onVoiceChange} />{mode === 'live' && <div className="sm:col-span-2"><VoiceThreadPicker threads={threads} selectedId={selectedThreadId} loading={threadsLoading} connected={connected} onSelect={onSelectThread} onRefresh={onRefreshThreads} /></div>}</div>
        </details>
        {mode === 'demo' && demoVoiceAccess === 'capped' && <p className="mt-2 rounded-lg border border-hairline bg-wash/60 px-3 py-2 text-[10px] leading-4 text-text-3">Uses only synthetic data. The server key is never sent to this browser.</p>}
        {prompt && <div className="mt-2 rounded-xl border border-brand/20 bg-brand/5 p-3"><p className="text-[11px] leading-4 text-text-2">Open the secure ChatGPT sign-in page, then enter this one-time code.</p><div className="mt-2 flex items-center gap-2"><a href={prompt.verificationUrl} target="_blank" rel="noreferrer" className="text-[11px] font-semibold text-brand underline underline-offset-4">Open sign-in</a><code className="ml-auto rounded-lg bg-field px-2.5 py-1.5 text-xs font-semibold tracking-[0.14em] text-ink">{prompt.userCode}</code></div></div>}
      </section>
    </aside>
  );
}

type Selectable = { selectedId: string | null; onSelect: (id: string) => void };

function BrandMark({ size = 'h-9 w-9' }: { size?: string }) {
  return <span aria-hidden="true" className={`${size} block shrink-0 rounded-full bg-[url('/openassist-logo.svg')] bg-cover bg-center`} />;
}

/** Stable per-sender colour so the same account always looks the same. */
const AVATAR_TINTS = [
  { bg: 'rgba(224,188,99,0.14)', ring: 'rgba(224,188,99,0.32)', text: '#E6C377' },
  { bg: 'rgba(124,107,240,0.16)', ring: 'rgba(124,107,240,0.34)', text: '#A99BF7' },
  { bg: 'rgba(63,185,198,0.14)', ring: 'rgba(63,185,198,0.32)', text: '#6FD2DC' },
  { bg: 'rgba(95,211,163,0.14)', ring: 'rgba(95,211,163,0.30)', text: '#7FDCB8' },
  { bg: 'rgba(255,193,120,0.14)', ring: 'rgba(255,193,120,0.30)', text: '#FFCF95' },
];

function tintFor(seed: string) {
  let hash = 0;
  for (let i = 0; i < seed.length; i += 1) hash = (hash * 31 + seed.charCodeAt(i)) >>> 0;
  return AVATAR_TINTS[hash % AVATAR_TINTS.length];
}

function initialsFor(name: string) {
  const words = name.replace(/[^\p{L}\p{N} ]/gu, ' ').trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return '?';
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return (words[0][0] + words[words.length - 1][0]).toUpperCase();
}

function Avatar({ name, size = 'h-9 w-9' }: { name: string; size?: string }) {
  const tint = tintFor(name);
  return (
    <span
      aria-hidden="true"
      className={`${size} grid shrink-0 place-items-center rounded-full text-[11px] font-semibold tracking-[0.02em]`}
      style={{ background: tint.bg, boxShadow: `inset 0 0 0 1px ${tint.ring}`, color: tint.text }}
    >
      {initialsFor(name)}
    </span>
  );
}

function PaperclipIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className="h-3.5 w-3.5">
      <path d="M21 12.5 12.5 21a5 5 0 0 1-7-7l8-8a3.5 3.5 0 1 1 5 5l-8 8a2 2 0 0 1-3-3l7.5-7.5" />
    </svg>
  );
}

function HaloRow({ id, selected, children, onClick }: { id: string; selected: boolean; children: React.ReactNode; onClick?: () => void }) {
  const className = `group relative w-full min-w-0 rounded-xl px-3.5 py-3 text-left transition-[background-color,box-shadow] duration-150 ${selected ? 'bg-raised shadow-[inset_0_0_0_1px_var(--ring-selected)]' : onClick ? 'hover:bg-wash hover:shadow-[inset_0_0_0_1px_var(--hairline-strong)]' : 'bg-wash/60'}`;
  if (!onClick) return <div id={`workspace-item-${id}`} className={className}>{children}</div>;
  return <button id={`workspace-item-${id}`} onClick={onClick} className={`${className} focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/45`}>{children}</button>;
}

function SectionHeading({ title, description, action }: { title: string; description?: string; action?: React.ReactNode }) {
  return (
    <div className="mb-3 flex items-end justify-between gap-4">
      <div className="min-w-0">
        <h2 className="truncate text-lg font-semibold">{title}</h2>
        {description && <p className="mt-1 oa-clamp-2 text-sm leading-5 text-text-3">{description}</p>}
      </div>
      {action}
    </div>
  );
}

function EmptyState({ title, hint }: { title: string; hint: string }) {
  return (
    <div className="rounded-2xl border border-hairline bg-wash/60 p-8 text-center">
      <p className="text-sm font-medium">{title}</p>
      <p className="mx-auto mt-2 max-w-sm text-sm leading-6 text-text-3">{hint}</p>
    </div>
  );
}

function TodayView({ messages, tasks, events, selectedId, onSelect, onNavigate }: { messages: typeof DEMO_MAIL; tasks: typeof DEMO_TASKS; events: typeof DEMO_EVENTS } & Selectable & { onNavigate: (view: WorkspaceView, itemId?: string) => void }) {
  const stats: Array<[string, number]> = [['Unread attention', messages.length], ['Open tasks', tasks.length], ['Today’s events', events.length]];
  return (
    <>
      <div className="mb-7 grid grid-cols-3 overflow-hidden rounded-2xl border border-hairline bg-wash/60">
        {stats.map(([label, value], index) => (
          <div key={label} className={`min-w-0 px-4 py-4 sm:px-6 sm:py-5 ${index ? 'border-l border-hairline' : ''}`}>
            <p className="text-2xl font-semibold tabular-nums tracking-[-0.03em] sm:text-3xl">{value}</p>
            <p className="mt-1 oa-clamp-2 text-[11px] leading-4 text-text-3 sm:text-sm">{label}</p>
          </div>
        ))}
      </div>
      <div className="grid grid-cols-[minmax(0,1.25fr)_minmax(0,0.75fr)] gap-8 max-lg:grid-cols-1">
        <section className="min-w-0">
          <SectionHeading title="Needs attention" description="Unread messages across linked accounts." action={<button onClick={() => onNavigate('inbox')} className="shrink-0 text-sm text-brand transition hover:text-brand-strong">Open inbox</button>} />
          {messages.length ? (
            <div className="space-y-2">
              {messages.slice(0, 4).map((message) => (
                <HaloRow key={message.id} id={message.id} selected={selectedId === message.id} onClick={() => onSelect(message.id)}>
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="flex min-w-0 items-center gap-2 text-xs text-text-3">
                        <span className={`inline-block h-1.5 w-1.5 shrink-0 rounded-full ${message.urgent ? 'bg-danger' : 'bg-ink/55'}`} />
                        <span className="min-w-0 truncate">{message.account}</span>
                      </p>
                      <p className="mt-1 oa-clamp-1 text-sm font-medium">{message.subject}</p>
                      <p className="mt-1 oa-clamp-1 text-sm text-text-3">{message.sender}</p>
                    </div>
                    <span className="shrink-0 text-xs tabular-nums text-text-4">{message.time}</span>
                  </div>
                </HaloRow>
              ))}
            </div>
          ) : <EmptyState title="Inbox is clear." hint="No unread messages across your linked accounts right now." />}
        </section>
        <section className="min-w-0">
          <SectionHeading title="Next up" action={<button onClick={() => onNavigate('tasks')} className="shrink-0 text-sm text-brand transition hover:text-brand-strong">Tasks</button>} />
          {tasks.length ? (
            <div className="space-y-2">
              {tasks.slice(0, 4).map((task) => (
                <HaloRow key={task.id} id={task.id} selected={selectedId === task.id} onClick={() => onSelect(task.id)}>
                  <div className="flex items-start gap-3">
                    <span className="mt-0.5 h-4 w-4 shrink-0 rounded-full border border-text-4" />
                    <div className="min-w-0 flex-1">
                      <p className="oa-clamp-2 text-sm">{task.title}</p>
                      <p className="mt-1 oa-clamp-1 text-xs text-text-3">{task.list} · {task.due}</p>
                    </div>
                  </div>
                </HaloRow>
              ))}
            </div>
          ) : <EmptyState title="No open tasks." hint="Everything on your list is done." />}
          {events.slice(0, 1).map((event) => (
            <div key={event.id} className="mt-6 min-w-0 border-l border-brand/60 pl-4">
              <p className="font-mono text-xs tabular-nums text-text-2">{event.start}–{event.end}</p>
              <p className="mt-1 oa-clamp-2 text-sm font-medium">{event.title}</p>
              <p className="mt-1 oa-clamp-1 text-xs text-text-3">{event.account}</p>
            </div>
          ))}
        </section>
      </div>
    </>
  );
}

function InboxView({ messages, selectedId, onSelect, onMarkRead }: { messages: typeof DEMO_MAIL; onMarkRead: (message: (typeof DEMO_MAIL)[number]) => void } & Selectable) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(messages, PAGE_SIZE, messages.length);
  return (
    <section className="min-w-0">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm tabular-nums text-text-3">{total} {total === 1 ? 'message' : 'messages'}</p>
        <span className="rounded-full bg-warning/10 px-3 py-1 text-xs text-warning">External content is untrusted</span>
      </div>
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((message) => (
              <HaloRow key={message.id} id={message.id} selected={selectedId === message.id} onClick={() => onSelect(message.id)}>
                <div className="flex items-start gap-3">
                  {/* Unread rail: a thin bar reads faster than a pill and adds no clutter. */}
                  <span aria-hidden="true" className={`mt-1 h-9 w-[3px] shrink-0 rounded-full ${message.unread ? (message.urgent ? 'bg-danger' : 'bg-ink/55') : 'bg-transparent'}`} />
                  <Avatar name={message.sender} />
                  <div className="min-w-0 flex-1">
                    <div className="flex items-baseline justify-between gap-3">
                      <p className={`min-w-0 truncate text-sm ${message.unread ? 'font-semibold text-ink' : 'font-medium text-text-2'}`}>{message.sender}</p>
                      <span className="shrink-0 text-[11px] tabular-nums text-text-4">{message.time}</span>
                    </div>
                    <p className={`mt-0.5 oa-clamp-1 text-sm ${message.unread ? 'text-ink' : 'text-text-2'}`}>{message.subject}</p>
                    <p className="mt-1 oa-clamp-2 text-[13px] leading-5 text-text-3">{message.snippet}</p>
                    <div className="mt-2 flex items-center gap-3 text-[11px] text-text-4">
                      <span className="truncate">{message.account}</span>
                      {message.hasAttachment && <span className="flex shrink-0 items-center gap-1"><PaperclipIcon />Attachment</span>}
                      {message.unread && (
                        <span
                          role="button"
                          tabIndex={0}
                          onClick={(event) => { event.stopPropagation(); onMarkRead(message); }}
                          onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); onMarkRead(message); } }}
                          className="ml-auto shrink-0 rounded-md px-1.5 py-0.5 text-[11px] text-text-3 opacity-0 transition hover:bg-wash-strong hover:text-brand focus-visible:opacity-100 group-hover:opacity-100 max-md:opacity-100"
                        >
                          Mark read
                        </span>
                      )}
                    </div>
                  </div>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="messages" onPage={setPage} />
        </>
      ) : <EmptyState title="No messages match." hint="Try a different search, or clear the search box to see everything." />}
    </section>
  );
}

const TASK_FILTERS = ['All', 'Open', 'Done'] as const;

function TasksView({ tasks, selectedId, onSelect, onCreate }: { tasks: typeof DEMO_TASKS; onCreate: () => void } & Selectable) {
  const [filter, setFilter] = useState<(typeof TASK_FILTERS)[number]>('All');
  const visible = useMemo(() => tasks.filter((task) => filter === 'All' || (filter === 'Done' ? task.completed : !task.completed)), [filter, tasks]);
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(visible, PAGE_SIZE, `${filter}-${tasks.length}`);
  return (
    <section className="min-w-0">
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div className="flex gap-2 max-sm:oa-scroll-x max-sm:-mx-5 max-sm:px-5">
          {TASK_FILTERS.map((item) => (
            <button key={item} onClick={() => setFilter(item)} aria-pressed={filter === item} className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition ${filter === item ? 'bg-brand text-brand-ink' : 'bg-wash text-text-2 hover:bg-wash-strong hover:text-ink'}`}>{item}</button>
          ))}
        </div>
        <button onClick={onCreate} className="oa-btn-primary shrink-0 rounded-xl px-4 py-2 text-sm font-semibold">New task</button>
      </div>
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((task) => (
              <HaloRow key={task.id} id={task.id} selected={selectedId === task.id} onClick={() => onSelect(task.id)}>
                <div className="flex items-start gap-3">
                  <span
                    aria-hidden="true"
                    className={`mt-0.5 grid h-[18px] w-[18px] shrink-0 place-items-center rounded-[6px] border transition ${task.completed ? 'border-brand bg-brand' : 'border-text-4 group-hover:border-brand/70'}`}
                  >
                    {task.completed && (
                      <svg viewBox="0 0 24 24" fill="none" stroke="var(--brand-ink)" strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round" className="h-3 w-3">
                        <path d="m5 12.5 4.5 4.5L19 7" />
                      </svg>
                    )}
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className={`oa-clamp-2 text-sm leading-5 ${task.completed ? 'text-text-4 line-through' : 'text-ink'}`}>{task.title}</p>
                    <div className="mt-1.5 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-[11px]">
                      <span className="text-text-4">{task.list}</span>
                      {task.tags.slice(0, 3).map((tag) => (
                        <span key={tag} className="rounded-md bg-wash-strong px-1.5 py-0.5 text-text-2">{tag.replace(/^#/, '')}</span>
                      ))}
                      {task.tags.length > 3 && <span className="text-text-4">+{task.tags.length - 3}</span>}
                    </div>
                  </div>
                  <span className={`shrink-0 whitespace-nowrap text-[11px] tabular-nums ${task.completed ? 'text-text-4' : 'text-text-2'}`}>{task.due}</span>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="tasks" onPage={setPage} />
        </>
      ) : <EmptyState title="Nothing here yet." hint={filter === 'Done' ? 'No completed tasks in this workspace yet.' : 'Create a task to see it appear here.'} />}
    </section>
  );
}

function CalendarView({ events, selectedId, onSelect, onCreate }: { events: typeof DEMO_EVENTS; onCreate: () => void } & Selectable) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(events, PAGE_SIZE, events.length);
  return (
    <section className="min-w-0">
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm tabular-nums text-text-3">{total} {total === 1 ? 'event' : 'events'} on the agenda</p>
        <button onClick={onCreate} className="oa-btn-primary shrink-0 rounded-xl px-4 py-2 text-sm font-semibold">New event</button>
      </div>
      {total ? (
        <>
          <div className="border-t border-hairline">
            {pageItems.map((event) => (
              <div key={event.id} className="grid grid-cols-[76px_minmax(0,1fr)] items-center gap-2 border-b border-hairline py-2 max-sm:grid-cols-1 max-sm:gap-0 max-sm:py-3">
                <div className="shrink-0 text-xs text-text-3 max-sm:mb-1 max-sm:px-4">{event.day}</div>
                <div className="min-w-0">
                  <HaloRow id={event.id} selected={selectedId === event.id} onClick={() => onSelect(event.id)}>
                    <div className="flex items-start justify-between gap-4 max-sm:flex-col max-sm:gap-1">
                      <div className="min-w-0 flex-1">
                        <p className="oa-clamp-1 text-sm font-medium">{event.title}</p>
                        <p className="mt-1 oa-clamp-1 text-xs text-text-3">{event.account} · Reminder {event.reminder}</p>
                      </div>
                      <p className="shrink-0 whitespace-nowrap font-mono text-xs tabular-nums text-text-2">{event.start}–{event.end}</p>
                    </div>
                  </HaloRow>
                </div>
              </div>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="events" onPage={setPage} />
        </>
      ) : <EmptyState title="No events scheduled." hint="Your calendar is clear for this range." />}
    </section>
  );
}

function SuppliesView({ products, cart, selectedId, onSelect, onSearch, onAdd, onClear }: {
  products: DemoSupplyProduct[];
  cart: DemoSupplyCart;
  selectedId: string | null;
  onSelect: (id: string) => void;
  onSearch: (query: string) => void;
  onAdd: (product: DemoSupplyProduct) => void;
  onClear: () => void;
}) {
  const [query, setQuery] = useState('travel security supplies');
  const count = cart.lines.reduce((sum, line) => sum + line.quantity, 0);
  return (
    <section className="min-w-0">
      <div className="mb-6 overflow-hidden rounded-2xl border border-hairline bg-wash/60 p-5 sm:p-6">
        <div className="flex flex-wrap items-start justify-between gap-5">
          <div className="max-w-2xl">
            <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-brand">Guided video story</p>
            <h2 className="mt-2 text-xl font-semibold tracking-[-0.02em]">Prepare the Northstar Friday security kit</h2>
            <p className="mt-2 text-sm leading-6 text-text-2">The agent connects an urgent email and open task to a real Shopify dev-store search, then prepares a synthetic cart only after approval.</p>
          </div>
          <div className="min-w-[180px] rounded-2xl border border-hairline-strong bg-field px-4 py-3">
            <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-3">Prepared cart</p>
            <p className="mt-1 text-2xl font-semibold tabular-nums">{count}</p>
            <p className="text-xs text-text-3">{count === 1 ? 'item' : 'items'} · {cart.currency} {cart.total.toFixed(2)}</p>
          </div>
        </div>
        <div className="mt-5 grid gap-3 border-t border-hairline pt-5 md:grid-cols-2">
          <div className="rounded-2xl border border-brand/20 bg-field p-4">
            <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">Demo video · fixed story</p>
            <p className="mt-2 text-sm text-ink/90">Find the urgent security work, search for a USB-C Security Key, preview the cart change, approve it, and show the verified result.</p>
          </div>
          <div className="rounded-2xl border border-hairline-strong bg-field p-4">
            <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-3">Judge test · free sandbox</p>
            <p className="mt-2 text-sm text-ink/90">Search any of the six products, prepare a separate cart, clear it, and reset the full workspace without touching another judge.</p>
          </div>
        </div>
      </div>

      <form onSubmit={(event) => { event.preventDefault(); onSearch(query); }} className="mb-6 flex gap-2 max-sm:flex-col">
        <label className="min-w-0 flex-1"><span className="sr-only">Search Shopify supplies</span><input value={query} onChange={(event) => setQuery(event.target.value)} maxLength={300} className="w-full rounded-xl border border-hairline-strong bg-wash px-4 py-3 text-sm outline-none transition focus:border-brand/50" placeholder="Search the synthetic Shopify catalog" /></label>
        <button type="submit" className="oa-btn-primary rounded-xl px-5 py-3 text-sm font-semibold">Search store</button>
      </form>

      <div className="mb-3 flex items-center justify-between gap-3">
        <p className="text-sm text-text-3">{products.length} Shopify {products.length === 1 ? 'result' : 'results'}</p>
        <span className="rounded-full bg-warning/10 px-3 py-1 text-[11px] text-warning">Catalog text is untrusted</span>
      </div>
      {products.length ? <div className="grid grid-cols-2 gap-3 max-lg:grid-cols-1 2xl:grid-cols-3">
        {products.map((product) => (
          <article key={product.id} id={`workspace-item-${product.id}`} onClick={() => onSelect(product.id)} className={`group flex min-h-[230px] cursor-pointer flex-col overflow-hidden rounded-2xl border bg-surface transition duration-150 hover:border-hairline-strong ${selectedId === product.id ? 'border-brand/60 shadow-[inset_0_0_0_1px_var(--ring-selected)]' : 'border-hairline'}`}>
            <div className="relative h-40 overflow-hidden border-b border-hairline bg-wash">
              {/* Shopify returns its own CDN URLs at runtime, so this intentionally stays an unoptimized remote image. */}
              {/* eslint-disable-next-line @next/next/no-img-element */}
              {product.imageUrl && <img src={product.imageUrl} alt={`${product.title} product`} loading="lazy" className="h-full w-full bg-[#d8d1c8] object-contain" />}
              <span className="absolute left-3 top-3 inline-flex rounded-full border border-hairline-strong bg-surface/85 px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-brand-strong backdrop-blur-md">{product.category}</span>
            </div>
            <div className="flex flex-1 flex-col p-4">
              <div className="flex items-start justify-between gap-3"><h3 className="oa-clamp-2 font-medium leading-5">{product.title}</h3><span className="shrink-0 text-sm font-semibold text-brand">${product.price.toFixed(2)}</span></div>
              <p className="mt-2 oa-clamp-3 text-sm leading-5 text-text-3">{product.description}</p>
              <div className="mt-auto flex items-center justify-between gap-3 pt-4"><span className="text-[11px] text-text-4">{product.available ? 'Available in demo store' : 'Unavailable'}</span><button type="button" disabled={!product.available} onClick={(event) => { event.stopPropagation(); onAdd(product); }} className="rounded-lg border border-brand/30 bg-brand/10 px-3 py-2 text-xs font-semibold text-brand-strong transition hover:border-brand/60 hover:bg-brand/15 disabled:opacity-40">Prepare cart</button></div>
            </div>
          </article>
        ))}
      </div> : <EmptyState title="No supplies found." hint="Try a broader search, or reset the judge demo." />}

      <div className="mt-7 rounded-2xl border border-hairline bg-wash/60 p-5">
        <div className="flex flex-wrap items-center justify-between gap-3"><div><p className="font-medium">Judge-isolated cart</p><p className="mt-1 text-xs text-text-3">Each judge gets a separate Shopify cart pointer. Checkout and payment tools are never exposed.</p></div>{cart.lines.length > 0 && <button onClick={onClear} className="rounded-xl border border-danger/25 px-3 py-2 text-xs text-danger-strong transition hover:border-danger/50">Clear cart</button>}</div>
        {cart.lines.length ? <div className="mt-4 space-y-2">{cart.lines.map((line) => <div key={line.id} className="flex items-center justify-between gap-4 rounded-xl border border-hairline bg-field px-4 py-3"><div className="min-w-0"><p className="truncate text-sm">{line.title}</p><p className="mt-0.5 text-xs text-text-3">Quantity {line.quantity}</p></div><p className="shrink-0 text-sm font-medium text-brand">{line.currency} {(line.price * line.quantity).toFixed(2)}</p></div>)}</div> : <p className="mt-4 text-sm text-text-3">Nothing prepared yet. Ask the agent to find a security key or travel kit.</p>}
      </div>
    </section>
  );
}

function NotesView({ mode, notes, onCreate, onOpen }: { mode: Mode; notes: typeof DEMO_NOTES; onCreate: () => void; onOpen: (note: (typeof DEMO_NOTES)[number]) => void }) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(notes, 6, notes.length);
  return (
    <section className="min-w-0">
      <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm tabular-nums text-text-3">{total} {total === 1 ? 'note' : 'notes'}</p>
        <button onClick={onCreate} className="shrink-0 rounded-xl border border-hairline-strong px-4 py-2 text-sm text-text-2 transition hover:border-brand/35 hover:text-ink">New note</button>
      </div>
      {total ? (
        <>
          <div className="grid grid-cols-2 gap-4 max-md:grid-cols-1 xl:grid-cols-2">
            {pageItems.map((note) => (
              <HaloRow key={note.id} id={note.id} selected={false} onClick={() => onOpen(note)}>
                <div className="min-w-0">
                  <div className="flex items-center justify-between gap-3"><p className="oa-clamp-1 font-medium">{note.title}</p><span className="shrink-0 text-[11px] font-medium text-brand">Open note</span></div>
                  <p className="mt-3 oa-clamp-3 text-sm leading-6 text-text-3">{note.preview}</p>
                  <p className="mt-4 oa-clamp-1 text-xs text-text-4">Updated {note.updated} · {mode === 'demo' ? 'Temporary demo storage' : 'Stored in Drive'}</p>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="notes" onPage={setPage} />
        </>
      ) : <EmptyState title="No notes yet." hint="Notes hold long reference material that would clutter a task." />}
      <p className="mt-7 max-w-2xl text-sm leading-6 text-text-3">{mode === 'demo' ? 'These synthetic notes are isolated to this browser session and automatically removed after 24 hours.' : 'OpenAssist creates a Drive note only when reference material is genuinely too long for a task. Short actions stay as clean Google Tasks.'}</p>
    </section>
  );
}

function MemoryView({ mode, memory, onRemember }: { mode: Mode; memory: typeof DEMO_MEMORY; onRemember: () => void }) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(memory, PAGE_SIZE, memory.length);
  return (
    <section className="min-w-0">
      <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
        <p className="oa-clamp-1 text-sm text-text-3">Strict quality gate · no raw email stored</p>
        <button onClick={onRemember} className="shrink-0 rounded-xl border border-brand/30 px-4 py-2 text-sm text-brand transition hover:border-brand/60 hover:text-brand-strong">Remember a fact</button>
      </div>
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((fact) => (
              <HaloRow key={fact.id} id={fact.id} selected={false}>
                <div className="min-w-0">
                  <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-4">{fact.category}</p>
                  <p className="mt-2 oa-wrap-anywhere text-sm leading-6 text-ink/90">{fact.fact}</p>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="facts" onPage={setPage} />
        </>
      ) : <EmptyState title="No saved facts." hint="Durable preferences appear here once you approve them." />}
      <div className="mt-7 rounded-2xl border border-hairline bg-wash p-5">
        <p className="font-medium">Storage boundary</p>
        <p className="mt-2 text-sm leading-6 text-text-3">{mode === 'demo' ? 'Synthetic memory is stored only in this isolated Cloudflare demo workspace and expires after 24 hours.' : 'Memory text lives in one private Google Drive document. The website stores only its encrypted connection and document pointer.'}</p>
      </div>
    </section>
  );
}

function AccountsView({ mode, accounts }: { mode: Mode; accounts: DemoAccount[] }) {
  return (
    <section className="min-w-0">
      <div className="mb-6 rounded-2xl border border-hairline bg-wash p-5">
        <p className="text-sm font-medium">{mode === 'demo' ? 'Synthetic accounts' : 'Owner connection required'}</p>
        <p className="mt-2 text-sm leading-6 text-text-3">{mode === 'demo' ? 'These are safe sample identities. Judge actions never touch your Google accounts and are removed automatically.' : 'Google credentials remain managed by Composio. OpenAssist never receives the Google refresh token.'}</p>
      </div>
      {accounts.length ? (
        <div className="space-y-3">
          {accounts.map((account, index) => (
            <HaloRow key={account.id} id={account.id} selected={false}>
              <div className="flex items-start justify-between gap-4 max-sm:flex-col max-sm:gap-3">
                <div className="min-w-0 flex-1">
                  <p className="oa-clamp-1 font-medium">{account.label}</p>
                  <p className="mt-1 oa-wrap-anywhere text-sm text-text-3">{account.email}</p>
                  <p className="mt-0.5 text-xs text-text-4">{account.type}</p>
                </div>
                <div className="flex shrink-0 flex-wrap gap-2">
                  {index === 0 && <span className="whitespace-nowrap rounded-full bg-brand/10 px-2.5 py-1 text-[10px] text-brand">Default tasks</span>}
                  <span className="whitespace-nowrap rounded-full bg-wash px-2.5 py-1 text-[10px] text-text-2">Gmail · Calendar · Tasks</span>
                </div>
              </div>
            </HaloRow>
          ))}
        </div>
      ) : <EmptyState title="No accounts linked." hint="Connect Workspace to route new work to the right account." />}
    </section>
  );
}
function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function arrayValue(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value) ? value.filter((item) => item && typeof item === 'object').map((item) => item as Record<string, unknown>) : [];
}

function liveRows(view: WorkspaceView, source: unknown): Array<Record<string, unknown>> {
  const data = objectValue(source);
  if (view === 'today') {
    const mail = arrayValue(objectValue(data.mail).results);
    const tasks = arrayValue(data.tasks);
    const events = arrayValue(objectValue(data.calendar).events);
    return [
      ...mail.map((item) => ({ ...item, _kind: 'Unread mail' })),
      ...tasks.map((item) => ({ ...item, _kind: 'Task' })),
      ...events.map((item) => ({ ...item, _kind: 'Calendar' })),
    ];
  }
  if (view === 'inbox') return arrayValue(objectValue(data.mail).results).map((item) => ({ ...item, _kind: 'Unread mail' }));
  if (view === 'tasks') return arrayValue(data.results).map((item) => {
    const task = objectValue(item.task);
    return Object.keys(task).length
      ? { ...task, taskListId: item.taskListId, _kind: 'Task' }
      : { ...item, _kind: 'Task' };
  });
  if (view === 'calendar') return arrayValue(data.events).map((item) => ({ ...item, _kind: 'Calendar' }));
  if (view === 'notes') {
    const account = displayText(data, ['account'], 'Main');
    return arrayValue(data.notes).map((item) => ({ ...item, _kind: 'Drive note', _account: account }));
  }
  if (view === 'memory') return arrayValue(data.facts ?? data.memories ?? data.results).map((item) => ({ ...item, _kind: 'Memory' }));
  if (view === 'work') {
    return [
      ...arrayValue(data.projects).map((item) => ({ ...item, _kind: 'Second Brain project' })),
      ...arrayValue(data.workItems).map((item) => ({ ...item, _kind: 'Second Brain work item' })),
      ...arrayValue(data.runs).map((item) => ({ ...item, _kind: 'Agent run' })),
      ...arrayValue(data.memorySources).map((item) => ({ ...item, _kind: 'Memory source' })),
    ];
  }
  if (view === 'accounts' || view === 'activity') return arrayValue(data.accounts).map((item) => ({ ...item, _kind: 'Account' }));
  return [];
}

function displayText(item: Record<string, unknown>, keys: string[], fallback: string): string {
  for (const key of keys) {
    const value = item[key];
    if (typeof value === 'string' && value.trim()) return value;
  }
  return fallback;
}

function liveItemId(item: Record<string, unknown>, fallback: string): string {
  return displayText(item, ['id', 'projectId', 'workItemId', 'runId', 'sourceId', 'taskId', 'messageId', 'eventId', 'documentId', 'noteId', 'factId'], fallback);
}

function noteRecord(value: unknown, depth = 0): Record<string, unknown> {
  const record = objectValue(value);
  if (depth >= 4) return record;
  const hasReadableText = ['content', 'text', 'body', 'plainText', 'markdown'].some((key) => typeof record[key] === 'string');
  if (hasReadableText) return record;
  for (const key of ['note', 'document', 'result', 'data', 'file']) {
    if (record[key] && typeof record[key] === 'object' && !Array.isArray(record[key])) return noteRecord(record[key], depth + 1);
  }
  return record;
}

function safeExternalUrl(value: string): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function liveTimeLabel(value: string): string {
  if (!value) return '';
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const date = new Date(`${value}T00:00:00`);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleDateString([], { month: 'short', day: 'numeric' });
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

function liveDayLabel(value: string): string {
  if (!value) return '';
  const date = new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00` : value);
  if (Number.isNaN(date.getTime())) return '';
  const today = new Date();
  if (date.toDateString() === today.toDateString()) return 'Today';
  const tomorrow = new Date(today.getTime() + 86_400_000);
  if (date.toDateString() === tomorrow.toDateString()) return 'Tomorrow';
  return date.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
}

/**
 * Live rows render with the same visual language as the demo views (avatars,
 * unread rails, checkboxes, time columns) instead of a generic list, so the
 * owner surface looks like the product rather than a data dump.
 */
function LiveRowBody({ view, item, fallbackTitle }: { view: WorkspaceView; item: Record<string, unknown>; fallbackTitle: string }) {
  if (view === 'inbox') {
    const sender = displayText(item, ['sender', 'from', 'fromName'], 'Unknown sender');
    const subject = displayText(item, ['subject', 'title'], fallbackTitle);
    const snippet = displayText(item, ['snippet', 'preview', 'summary'], '');
    const account = displayText(item, ['account', 'accountEmail', '_account'], '');
    const time = liveTimeLabel(displayText(item, ['time', 'date', 'receivedAt'], ''));
    return (
      <div className="flex items-start gap-3">
        <span aria-hidden="true" className="mt-1 h-9 w-[3px] shrink-0 rounded-full bg-ink/50" />
        <Avatar name={sender} />
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-3">
            <p className="min-w-0 truncate text-sm font-semibold text-ink">{sender}</p>
            {time && <span className="shrink-0 text-[11px] tabular-nums text-text-3">{time}</span>}
          </div>
          <p className="mt-0.5 oa-clamp-1 text-sm text-ink">{subject}</p>
          {snippet && <p className="mt-1 oa-clamp-2 text-[13px] leading-5 text-text-3">{snippet}</p>}
          {account && <p className="mt-2 truncate text-[11px] text-text-4">{account}</p>}
        </div>
      </div>
    );
  }
  if (view === 'tasks') {
    const completed = item.completed === true || displayText(item, ['status'], '') === 'completed';
    const title = displayText(item, ['title', 'summary'], fallbackTitle);
    const list = displayText(item, ['list', 'listTitle', 'taskListTitle'], '');
    const due = displayText(item, ['due', 'dueDate'], '');
    return (
      <div className="flex items-start gap-3">
        <span aria-hidden="true" className={`mt-0.5 grid h-[18px] w-[18px] shrink-0 place-items-center rounded-[6px] border transition ${completed ? 'border-brand bg-brand' : 'border-text-4 group-hover:border-brand/70'}`}>
          {completed && (
            <svg viewBox="0 0 24 24" fill="none" stroke="var(--brand-ink)" strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round" className="h-3 w-3">
              <path d="m5 12.5 4.5 4.5L19 7" />
            </svg>
          )}
        </span>
        <div className="min-w-0 flex-1">
          <p className={`oa-clamp-2 text-sm leading-5 ${completed ? 'text-text-4 line-through' : 'text-ink'}`}>{title}</p>
          {list && <p className="mt-1 oa-clamp-1 text-[11px] text-text-4">{list}</p>}
        </div>
        {due && <span className="shrink-0 whitespace-nowrap text-[11px] tabular-nums text-text-3">{liveDayLabel(due) || due}</span>}
      </div>
    );
  }
  if (view === 'calendar') {
    const title = displayText(item, ['title', 'summary'], fallbackTitle);
    const start = displayText(item, ['start', 'startTime'], '');
    const end = displayText(item, ['end', 'endTime'], '');
    const account = displayText(item, ['account', 'accountEmail', 'calendar'], '');
    return (
      <div className="flex items-start justify-between gap-4 max-sm:flex-col max-sm:gap-1">
        <div className="min-w-0 flex-1">
          <p className="oa-clamp-1 text-sm font-medium">{title}</p>
          <p className="mt-1 oa-clamp-1 text-xs text-text-3">{[liveDayLabel(start), account].filter(Boolean).join(' · ')}</p>
        </div>
        {(start || end) && <p className="shrink-0 whitespace-nowrap font-mono text-xs tabular-nums text-text-2">{[liveTimeLabel(start), liveTimeLabel(end)].filter(Boolean).join('–')}</p>}
      </div>
    );
  }
  if (view === 'notes') {
    const title = displayText(item, ['title', 'name'], fallbackTitle);
    const preview = displayText(item, ['preview', 'snippet', 'description'], '');
    const updated = displayText(item, ['updated', 'modifiedTime', 'updatedAt'], '');
    return (
      <div className="min-w-0">
        <div className="flex items-center justify-between gap-3"><p className="oa-clamp-1 text-sm font-medium">{title}</p><span className="shrink-0 text-[11px] font-medium text-brand">Open note</span></div>
        {preview && <p className="mt-2 oa-clamp-2 text-sm leading-6 text-text-3">{preview}</p>}
        <p className="mt-2 oa-clamp-1 text-xs text-text-4">{[updated ? `Updated ${liveDayLabel(updated) || updated}` : '', 'Stored in Drive'].filter(Boolean).join(' · ')}</p>
      </div>
    );
  }
  if (view === 'memory') {
    const category = displayText(item, ['category', 'kind'], 'Memory');
    const fact = displayText(item, ['fact', 'text', 'content'], fallbackTitle);
    return (
      <div className="min-w-0">
        <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-4">{category}</p>
        <p className="mt-1.5 oa-wrap-anywhere text-sm leading-6 text-ink/90">{fact}</p>
      </div>
    );
  }
  if (view === 'accounts' || view === 'activity') {
    const label = displayText(item, ['friendlyLabel', 'label', 'name'], fallbackTitle);
    const email = displayText(item, ['email', 'accountEmail'], '');
    const type = displayText(item, ['type', 'kind'], '');
    return (
      <div className="flex items-start justify-between gap-4 max-sm:flex-col max-sm:gap-2">
        <div className="min-w-0 flex-1">
          <p className="oa-clamp-1 text-sm font-medium">{label}</p>
          {email && <p className="mt-1 oa-wrap-anywhere text-sm text-text-3">{email}</p>}
          {type && <p className="mt-0.5 text-xs text-text-4">{type}</p>}
        </div>
        <span className="shrink-0 whitespace-nowrap rounded-full bg-wash-strong px-2.5 py-1 text-[10px] text-text-2">Gmail · Calendar · Tasks</span>
      </div>
    );
  }
  const kind = String(item._kind ?? 'Workspace');
  return (
    <div className="min-w-0 flex-1">
      <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-text-4">{kind}</p>
      <p className="mt-1 oa-clamp-1 text-sm font-medium">{displayText(item, ['subject', 'title', 'summary', 'friendlyLabel', 'fact', 'name', 'email'], fallbackTitle)}</p>
      <p className="mt-1 oa-clamp-1 text-sm text-text-3">{displayText(item, ['sender', 'from', 'email', 'due', 'start', 'account', 'category', 'status'], 'Live Workspace item')}</p>
    </div>
  );
}

function LiveWorkspaceView({ view, live, query, selectedId, ownerCode, onOwnerCode, onBootstrap, onReconnect, onRetry, onOpenNote, onOpenItem }: { view: WorkspaceView; live: LiveState; query: string; selectedId: string | null; ownerCode: string; onOwnerCode: (value: string) => void; onBootstrap: () => void; onReconnect: () => void; onRetry: () => void; onOpenNote: (item: Record<string, unknown>) => void; onOpenItem: (id: string, item: Record<string, unknown>) => void }) {
  const source = view === 'accounts' || view === 'activity' ? live.accounts : live.data[view];
  const rows = useMemo(() => {
    const allRows = liveRows(view, source);
    const normalized = query.trim().toLowerCase();
    if (!normalized) return allRows;
    return allRows.filter((item) => Object.values(item).some((value) => typeof value === 'string' && value.toLowerCase().includes(normalized)));
  }, [query, source, view]);
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(rows, PAGE_SIZE, `${view}-${rows.length}`);

  if (live.loading && !live.data[view]) {
    return <WorkspaceLoading />;
  }
  if (live.error) {
    if (live.error.startsWith('Owner access')) {
      return <div className="mx-auto max-w-xl rounded-2xl border border-brand/20 bg-brand/5 p-6 sm:p-7"><p className="text-xs font-semibold uppercase tracking-[0.14em] text-brand">One-time setup</p><h2 className="mt-2 text-xl font-semibold">Bind this private owner account</h2><p className="mt-3 text-sm leading-6 text-text-2">Enter the one-time owner code. It is used only to bind this signed-in ChatGPT account, then it can be removed.</p><label className="mt-5 block"><span className="sr-only">One-time owner code</span><input type="password" autoComplete="one-time-code" value={ownerCode} onChange={(event) => onOwnerCode(event.target.value)} placeholder="One-time owner code" className="w-full rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm outline-none transition placeholder:text-text-4 focus:border-brand/50 focus:ring-2 focus:ring-brand/10" /></label><button onClick={onBootstrap} disabled={!ownerCode.trim()} className="oa-btn-primary mt-4 w-full rounded-xl px-5 py-2.5 text-sm font-semibold disabled:cursor-not-allowed disabled:opacity-40 sm:w-auto">Finish owner setup</button></div>;
    }
    return <div className="mx-auto max-w-xl rounded-2xl border border-danger/20 bg-danger/5 p-6 sm:p-7"><p className="text-xs font-semibold uppercase tracking-[0.14em] text-danger-strong">Live Workspace unavailable</p><h2 className="mt-2 text-xl font-semibold">Reconnect securely</h2><p className="mt-3 oa-wrap-anywhere text-sm leading-6 text-text-2">{live.error}</p><button onClick={onReconnect} className="oa-btn-primary mt-6 w-full rounded-xl px-5 py-2.5 text-sm font-semibold sm:w-auto">Connect Workspace</button></div>;
  }
  if (!source) {
    return <div className="rounded-2xl border border-hairline bg-wash/60 p-6 sm:p-7"><p className="text-sm leading-6 text-text-2">{live.warning ?? 'Connect Workspace to load private data. Demo records are intentionally hidden in Live mode.'}</p><button onClick={live.warning ? onRetry : onReconnect} className="oa-btn-primary mt-5 w-full rounded-xl px-5 py-2.5 text-sm font-semibold sm:w-auto">{live.warning ? 'Try again' : 'Connect Workspace'}</button></div>;
  }

  return (
    <section className="min-w-0">
      <div className="mb-6 flex items-start justify-between gap-4 rounded-2xl border border-hairline bg-wash/60 px-4 py-3.5 sm:px-5 sm:py-4">
        <div className="min-w-0">
          <p className="text-sm font-medium text-ink">Private owner mode</p>
          <p className="mt-1 oa-clamp-2 text-xs leading-5 text-text-3">Loaded live through OpenAssist. Nothing below is copied into the site database.</p>
        </div>
        <button onClick={onReconnect} className="shrink-0 rounded-lg border border-hairline-strong px-3 py-2 text-xs text-text-2 transition hover:text-ink">Connection</button>
      </div>
      {live.warning && <div className="mb-5 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-warning/20 bg-warning/5 px-4 py-3 text-sm text-warning-strong"><span>Refresh failed. Showing the last loaded Workspace data.</span><button onClick={onRetry} className="rounded-lg border border-warning/25 px-3 py-1.5 text-xs font-semibold text-brand-strong">Retry</button></div>}
      {view === 'today' ? (
        <LiveTodayDashboard rows={rows} selectedId={selectedId} onOpenItem={onOpenItem} />
      ) : total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((item, index) => {
              const itemId = liveItemId(item, `${view}-${rangeStart + index}`);
              return (
                <HaloRow key={itemId} id={itemId} selected={selectedId === itemId} onClick={view === 'notes' ? () => onOpenNote(item) : () => onOpenItem(itemId, item)}>
                  <LiveRowBody view={view} item={item} fallbackTitle={`${String(item._kind ?? 'Workspace')} ${rangeStart + index}`} />
                </HaloRow>
              );
            })}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="items" onPage={setPage} />
        </>
      ) : <EmptyState title="Nothing needs attention here." hint="This is a real empty state, not demo content." />}
    </section>
  );
}

function WorkspaceLoading({ title = 'Organizing your live workspace', detail = 'Checking connected mail, tasks, and calendar securely…' }: { title?: string; detail?: string }) {
  return (
    <section aria-label="Loading private workspace" aria-busy="true" className="space-y-5">
      <div className="flex items-center gap-3 rounded-2xl border border-hairline bg-wash/60 px-4 py-3.5">
        <span className="h-2 w-2 animate-pulse rounded-full bg-text-3" />
        <div><p className="text-sm font-medium text-ink">{title}</p><p className="mt-0.5 text-xs text-text-4">{detail}</p></div>
      </div>
      <div className="grid gap-4 sm:grid-cols-3">
        {[0, 1, 2].map((item) => <div key={item} className="h-24 animate-pulse rounded-2xl border border-hairline bg-wash/60" />)}
      </div>
      <div className="grid gap-5 xl:grid-cols-2">
        {[0, 1].map((column) => <div key={column} className="overflow-hidden rounded-2xl border border-hairline bg-wash/60"><div className="h-16 border-b border-hairline bg-wash/60" /><div className="space-y-3 p-4">{[0, 1, 2].map((row) => <div key={row} className="h-14 animate-pulse rounded-xl bg-wash" />)}</div></div>)}
      </div>
    </section>
  );
}

function LiveTodayDashboard({ rows, selectedId, onOpenItem }: { rows: Array<Record<string, unknown>>; selectedId: string | null; onOpenItem: (id: string, item: Record<string, unknown>) => void }) {
  const mail = rows.filter((item) => item._kind === 'Unread mail');
  const tasks = rows.filter((item) => item._kind === 'Task');
  const events = rows.filter((item) => item._kind === 'Calendar');
  const sections = [
    { id: 'mail', label: 'Needs attention', detail: 'Unread across connected Gmail accounts', rows: mail.slice(0, 5), empty: 'No unread mail needs attention.' },
    { id: 'tasks', label: 'Next actions', detail: 'Open tasks from your default Tasks account', rows: tasks.slice(0, 5), empty: 'Your active task list is clear.' },
    { id: 'calendar', label: 'On your calendar', detail: 'Events scheduled for today', rows: events.slice(0, 5), empty: 'No events are scheduled today.' },
  ];

  return (
    <div className="space-y-6">
      <section aria-label="Today summary" className="grid overflow-hidden rounded-2xl border border-hairline bg-wash/60 sm:grid-cols-3">
        {[
          { label: 'Unread attention', value: mail.length, accent: 'text-ink' },
          { label: 'Open actions', value: tasks.length, accent: 'text-ink' },
          { label: "Today’s events", value: events.length, accent: 'text-ink' },
        ].map((metric, index) => (
          <div key={metric.label} className={`px-5 py-5 sm:px-6 ${index ? 'border-t border-hairline sm:border-l sm:border-t-0' : ''}`}>
            <p className={`text-3xl font-semibold tabular-nums tracking-[-0.04em] ${metric.accent}`}>{metric.value}</p>
            <p className="mt-1 text-xs font-medium text-text-3">{metric.label}</p>
          </div>
        ))}
      </section>

      <div className="grid gap-5 2xl:grid-cols-3">
        {sections.map((section) => (
          <section key={section.id} aria-labelledby={`today-${section.id}`} className="min-w-0 overflow-hidden rounded-2xl border border-hairline bg-wash/60">
            <header className="border-b border-hairline px-5 py-4">
              <div className="flex items-center justify-between gap-3">
                <h2 id={`today-${section.id}`} className="text-sm font-semibold text-ink">{section.label}</h2>
                <span className="rounded-full border border-hairline bg-wash px-2 py-0.5 text-[10px] font-semibold tabular-nums text-text-2">{section.rows.length}</span>
              </div>
              <p className="mt-1 text-[11px] leading-5 text-text-4">{section.detail}</p>
            </header>
            {section.rows.length ? (
              <div className="divide-y divide-hairline">
                {section.rows.map((item, index) => {
                  const itemId = liveItemId(item, `${section.id}-${index + 1}`);
                  const title = displayText(item, ['subject', 'title', 'summary'], 'Untitled item');
                  const subtitle = displayText(item, ['from', 'sender', 'due', 'start', 'accountEmail', 'account'], section.label);
                  return (
                    <button key={itemId} type="button" onClick={() => onOpenItem(itemId, item)} aria-current={selectedId === itemId ? 'true' : undefined} className={`group block w-full px-5 py-4 text-left transition duration-150 ${selectedId === itemId ? 'bg-brand/10' : 'hover:bg-wash'}`}>
                      <div className="flex items-start gap-3">
                        <span aria-hidden="true" className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${section.id === 'calendar' ? 'bg-teal' : section.id === 'tasks' ? 'border border-text-4' : 'bg-ink/55'}`} />
                        <span className="min-w-0 flex-1">
                          <span className="oa-clamp-2 block text-sm font-medium leading-5 text-ink transition group-hover:text-ink">{title}</span>
                          <span className="mt-1 oa-clamp-1 block text-[11px] text-text-4">{subtitle}</span>
                        </span>
                        <span aria-hidden="true" className="text-sm text-text-4 transition group-hover:text-text-2">›</span>
                      </div>
                    </button>
                  );
                })}
              </div>
            ) : <div className="px-5 py-8 text-center text-xs leading-5 text-text-4">{section.empty}</div>}
          </section>
        ))}
      </div>
    </div>
  );
}

function ActivityView({ mode, activity, owner = false, onVoicePolicyChanged }: { mode: Mode; activity: typeof DEMO_ACTIVITY; owner?: boolean; onVoicePolicyChanged?: () => void }) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(activity, PAGE_SIZE, activity.length);
  return (
    <section className="min-w-0">
      {mode === 'live' && owner && <JudgeVoiceAdmin onChanged={onVoicePolicyChanged} />}
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((item) => (
              <HaloRow key={item.id} id={item.id} selected={false}>
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0 flex-1">
                    <p className="oa-clamp-2 text-sm">{item.action}</p>
                    <p className="mt-1 oa-clamp-1 text-xs text-text-3">{item.actor} · {item.type === 'write' ? 'Approved write' : 'Read only'}</p>
                  </div>
                  <span className="shrink-0 whitespace-nowrap text-xs text-text-4">{item.time}</span>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="events" onPage={setPage} />
        </>
      ) : <EmptyState title="No activity yet." hint="Reads and approved writes will appear here as they happen." />}
      <p className="mt-7 max-w-2xl text-sm leading-6 text-text-3">{mode === 'demo' ? 'This temporary activity belongs only to the isolated judge workspace and expires with it.' : 'Activity stores safe metadata only. It does not copy message bodies, attachments, task text, calendar text, notes, memory, audio, or transcripts into the database.'}</p>
    </section>
  );
}

function JudgeVoiceAdmin({ onChanged }: { onChanged?: () => void }) {
  const [config, setConfig] = useState<JudgeVoiceConfig | null>(null);
  const [usage, setUsage] = useState<JudgeVoiceUsage | null>(null);
  const [apiKey, setApiKey] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [configResponse, usageResponse] = await Promise.all([
        fetch('/api/owner/judge-voice/config', { cache: 'no-store' }),
        fetch('/api/owner/judge-voice/usage?days=7', { cache: 'no-store' }),
      ]);
      const configBody = await configResponse.json() as JudgeVoiceConfig & { error?: string };
      const usageBody = await usageResponse.json() as JudgeVoiceUsage & { error?: string };
      if (!configResponse.ok) throw new Error(configBody.error ?? 'Judge voice settings could not be loaded.');
      if (!usageResponse.ok) throw new Error(usageBody.error ?? 'Judge voice usage could not be loaded.');
      setConfig(configBody);
      setUsage(usageBody);
      setMessage('');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Judge voice controls could not be loaded.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const timeout = window.setTimeout(() => { void load(); }, 0);
    return () => window.clearTimeout(timeout);
  }, [load]);

  const save = useCallback(async (next?: Partial<JudgeVoiceConfig>) => {
    if (!config) return;
    setSaving(true);
    setMessage('');
    try {
      const response = await fetch('/api/owner/judge-voice/config', {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          enabled: next?.enabled ?? config.enabled,
          apiKey,
          dailySessionLimit: next?.dailySessionLimit ?? config.dailySessionLimit,
          sessionSeconds: next?.sessionSeconds ?? config.sessionSeconds,
          maxToolCalls: next?.maxToolCalls ?? config.maxToolCalls,
        }),
      });
      const body = await response.json() as JudgeVoiceConfig & { error?: string };
      if (!response.ok) throw new Error(body.error ?? 'Judge voice settings could not be saved.');
      setConfig(body);
      setApiKey('');
      setMessage(body.enabled ? 'Funded judge voice is enabled.' : 'Funded judge voice is paused.');
      onChanged?.();
      await load();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Judge voice settings could not be saved.');
    } finally {
      setSaving(false);
    }
  }, [apiKey, config, load, onChanged]);

  const removeKey = useCallback(async () => {
    setSaving(true);
    setMessage('');
    try {
      const response = await fetch('/api/owner/judge-voice/config', { method: 'DELETE' });
      const body = await response.json() as JudgeVoiceConfig & { error?: string };
      if (!response.ok) throw new Error(body.error ?? 'The judge voice key could not be removed.');
      setConfig(body);
      setApiKey('');
      setMessage('The funded key was removed and judge-funded voice is paused.');
      onChanged?.();
      await load();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'The judge voice key could not be removed.');
    } finally {
      setSaving(false);
    }
  }, [load, onChanged]);

  return (
    <section className="mb-8 overflow-hidden rounded-2xl border border-hairline bg-wash/60">
      <div className="flex flex-wrap items-start justify-between gap-4 border-b border-hairline px-5 py-5 sm:px-6">
        <div>
          <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">Owner only</p>
          <h2 className="mt-1 text-xl font-semibold">Judge voice controls</h2>
          <p className="mt-1 max-w-2xl text-sm leading-6 text-text-3">Fund the judge demo with your protected API key, set strict limits, and monitor usage.</p>
        </div>
        <button type="button" onClick={() => void load()} disabled={loading || saving} className="rounded-xl border border-hairline-strong px-3 py-2 text-xs text-text-2 transition hover:border-brand/35 hover:text-ink disabled:opacity-50">Refresh</button>
      </div>

      {loading && !config ? <div className="px-6 py-8 text-sm text-text-3">Loading secure settings…</div> : config && (
        <div className="grid gap-6 px-5 py-6 lg:grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)] sm:px-6">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className={`rounded-full px-2.5 py-1 text-[10px] font-semibold ${config.available ? 'bg-success/10 text-success-strong' : 'bg-danger/10 text-danger-strong'}`}>{config.available ? 'Funded demo ready' : config.enabled ? 'Key needed' : 'Paused'}</span>
              <span className="text-xs text-text-4">{config.source === 'owner_key' ? 'Encrypted owner key' : config.source === 'worker_secret' ? 'Protected deployment key' : 'No funded key'}</span>
            </div>

            <label className="mt-5 block">
              <span className="mb-2 block text-xs font-medium text-text-2">OpenAI API key</span>
              <input type="password" value={apiKey} onChange={(event) => setApiKey(event.target.value)} autoComplete="new-password" spellCheck={false} placeholder={config.keyConfigured ? 'Key is saved securely · enter a new key to replace it' : 'Paste a funded project key'} className="w-full rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm outline-none transition placeholder:text-text-4 focus:border-brand/50 focus:ring-2 focus:ring-brand/10" />
              <span className="mt-2 block text-[11px] leading-5 text-text-4">The key is verified server-side, encrypted in R2, and never returned to this page or shown to judges.</span>
            </label>

            <div className="mt-5 grid gap-3 sm:grid-cols-3">
              <label className="block"><span className="mb-2 block text-xs text-text-2">Sessions / day</span><input type="number" min={1} max={100} value={config.dailySessionLimit} onChange={(event) => setConfig({ ...config, dailySessionLimit: Number(event.target.value) })} className="w-full rounded-xl border border-hairline-strong bg-field px-3 py-2.5 text-sm outline-none focus:border-brand/50" /></label>
              <label className="block"><span className="mb-2 block text-xs text-text-2">Seconds / session</span><input type="number" min={60} max={300} step={30} value={config.sessionSeconds} onChange={(event) => setConfig({ ...config, sessionSeconds: Number(event.target.value) })} className="w-full rounded-xl border border-hairline-strong bg-field px-3 py-2.5 text-sm outline-none focus:border-brand/50" /></label>
              <label className="block"><span className="mb-2 block text-xs text-text-2">Tools / session</span><input type="number" min={1} max={25} value={config.maxToolCalls} onChange={(event) => setConfig({ ...config, maxToolCalls: Number(event.target.value) })} className="w-full rounded-xl border border-hairline-strong bg-field px-3 py-2.5 text-sm outline-none focus:border-brand/50" /></label>
            </div>

            <div className="mt-5 flex flex-wrap gap-2">
              <button type="button" onClick={() => void save({ enabled: true })} disabled={saving || (!apiKey && !config.keyConfigured)} className="oa-btn-primary rounded-xl px-4 py-2.5 text-sm font-semibold disabled:cursor-not-allowed disabled:opacity-45">{saving ? 'Saving…' : config.enabled ? 'Save limits' : 'Enable funded demo'}</button>
              {config.enabled && <button type="button" onClick={() => void save({ enabled: false })} disabled={saving} className="rounded-xl border border-hairline-strong px-4 py-2.5 text-sm text-text-2 transition hover:border-brand/35 hover:text-ink disabled:opacity-45">Pause</button>}
              {config.keyConfigured && <button type="button" onClick={() => void removeKey()} disabled={saving} className="rounded-xl border border-danger/20 px-4 py-2.5 text-sm text-danger-strong transition hover:border-danger/45 disabled:opacity-45">Remove key</button>}
            </div>
            {message && <p aria-live="polite" className="mt-4 rounded-xl border border-hairline bg-field px-3 py-2.5 text-xs leading-5 text-text-2">{message}</p>}
          </div>

          <div className="min-w-0 rounded-2xl border border-hairline bg-field p-4 sm:p-5">
            <div className="flex items-center justify-between gap-3"><h3 className="text-sm font-semibold">Anonymous usage</h3><a href="https://platform.openai.com/usage" target="_blank" rel="noreferrer" className="text-xs font-medium text-brand underline decoration-brand/25 underline-offset-4">OpenAI usage</a></div>
            {usage ? <>
              <div className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-2 xl:grid-cols-3">
                {[
                  ['Today', usage.todaySessions],
                  ['Funded', usage.fundedToday],
                  ['Owner ChatGPT', usage.subscriptionToday],
                  ['Active', usage.activeSessions],
                  ['Failures', usage.failures],
                  ['Minutes', usage.totalMinutes],
                ].map(([label, value]) => <div key={String(label)} className="rounded-xl border border-hairline bg-wash/60 px-3 py-3"><p className="text-lg font-semibold tabular-nums">{value}</p><p className="mt-0.5 text-[10px] uppercase tracking-[0.14em] text-text-4">{label}</p></div>)}
              </div>
              <div className="mt-4 max-h-56 space-y-1 overflow-y-auto pr-1">
                {usage.recent.length ? usage.recent.map((event) => <div key={event.eventId} className="flex items-center justify-between gap-3 rounded-lg px-2 py-2 text-xs transition hover:bg-wash/60"><div className="min-w-0"><p className="truncate text-text-2">{event.judgeLabel} · {event.kind === 'funded_session' ? 'Funded' : event.kind === 'subscription_session' ? 'My ChatGPT' : 'Sign-in'}</p><p className="mt-0.5 text-[10px] text-text-4">{new Date(event.startedAt).toLocaleString()} · {event.toolCalls} tools</p></div><span className={`shrink-0 text-[10px] font-semibold uppercase ${event.status === 'failed' ? 'text-danger-strong' : event.status === 'active' ? 'text-success-strong' : 'text-text-3'}`}>{event.status}</span></div>) : <p className="py-5 text-center text-xs text-text-4">No judge voice use yet.</p>}
              </div>
            </> : <p className="mt-5 text-xs text-text-4">Usage has not loaded yet.</p>}
            <p className="mt-4 border-t border-hairline pt-4 text-[11px] leading-5 text-text-4">Only session counts, time, tool counts, and safe error codes are stored. No audio, transcript, prompt, tool arguments, or Workspace content is saved.</p>
          </div>
        </div>
      )}
    </section>
  );
}

function LiveItemReader({ value, onClose }: { value: OpenLiveItem; onClose: () => void }) {
  const item = value.item;
  const kind = displayText(item, ['_kind'], value.view === 'tasks' ? 'Task' : 'Workspace item');
  const title = displayText(item, ['subject', 'title', 'summary', 'friendlyLabel', 'fact', 'name', 'email'], kind);
  const fields = [
    ['Account', displayText(item, ['account', '_account', 'email'], '')],
    ['List', displayText(item, ['list', 'taskListTitle', 'listTitle'], '')],
    ['Due', displayText(item, ['due', 'dueDate'], '')],
    ['Status', displayText(item, ['status'], '')],
    ['Notes', displayText(item, ['notes', 'description', 'snippet'], '')],
  ].filter((entry) => entry[1]);
  return (
    <div className="fixed inset-0 z-[80] grid place-items-center bg-black/65 p-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-label={`${kind} details`} onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section className="w-full max-w-xl rounded-2xl border border-hairline-strong bg-raised p-6 shadow-[0_24px_64px_rgba(0,0,0,0.5)] sm:p-7">
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0"><p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-brand">{kind}</p><h2 className="mt-2 oa-wrap-anywhere text-xl font-semibold leading-7">{title}</h2></div>
          <button onClick={onClose} aria-label="Close details" className="grid h-9 w-9 shrink-0 place-items-center rounded-full border border-hairline-strong text-text-2 transition hover:border-brand/35 hover:text-ink">×</button>
        </div>
        <dl className="mt-6 divide-y divide-hairline rounded-2xl border border-hairline bg-wash/60 px-4">
          {fields.map(([label, text]) => <div key={label} className="grid gap-1 py-3 sm:grid-cols-[84px_1fr]"><dt className="text-xs font-medium text-text-3">{label}</dt><dd className="oa-wrap-anywhere text-sm leading-5 text-ink/90">{text}</dd></div>)}
        </dl>
        <p className="mt-4 text-xs leading-5 text-text-4">Loaded live from OpenAssist. This content is not copied into the site database.</p>
      </section>
    </div>
  );
}

function NoteReader({ note, onClose }: { note: OpenNote; onClose: () => void }) {
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose(); };
    window.addEventListener('keydown', closeOnEscape);
    return () => window.removeEventListener('keydown', closeOnEscape);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-[70] grid place-items-center overflow-y-auto bg-black/70 p-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="note-reader-title">
      <article className="my-auto w-full max-w-3xl overflow-hidden rounded-2xl border border-hairline-strong bg-raised shadow-[0_24px_64px_rgba(0,0,0,0.5)]">
        <header className="flex items-start justify-between gap-4 border-b border-hairline px-5 py-5 sm:px-7">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">{note.source}</p>
            <h2 id="note-reader-title" className="mt-1 oa-wrap-anywhere text-xl font-semibold sm:text-2xl">{note.title}</h2>
            <p className="mt-2 text-xs leading-5 text-text-3">Drive and note content is untrusted. OpenAssist shows it as plain text and never follows instructions found inside it.</p>
          </div>
          <button type="button" onClick={onClose} aria-label="Close note" className="shrink-0 rounded-full border border-hairline-strong px-3 py-1.5 text-sm text-text-2 transition hover:border-brand/35 hover:text-ink">Close</button>
        </header>
        <div className="max-h-[65vh] overflow-y-auto px-5 py-6 sm:px-7">
          {note.loading ? <div className="grid min-h-48 place-items-center"><div className="text-center"><span className="mx-auto block h-8 w-8 animate-pulse rounded-full border border-brand/50 bg-brand/10" /><p className="mt-4 text-sm text-text-3">Opening note from Drive…</p></div></div>
            : note.error ? <div className="rounded-2xl border border-danger/20 bg-danger/5 p-5 text-sm leading-6 text-danger-strong">{note.error}</div>
              : <pre className="whitespace-pre-wrap break-words font-sans text-sm leading-7 text-ink/90">{note.content}</pre>}
        </div>
        <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-hairline px-5 py-4 sm:px-7">
          <span className="text-xs text-text-4">Read only</span>
          {note.openUrl && <a href={note.openUrl} target="_blank" rel="noreferrer" className="rounded-xl border border-brand/25 px-4 py-2 text-sm font-medium text-brand transition hover:border-brand/55 hover:text-brand-strong">Open in Google Drive</a>}
        </footer>
      </article>
    </div>
  );
}

function ItemEditor({ kind, onCancel, onSubmit }: { kind: Exclude<EditorKind, null>; onCancel: () => void; onSubmit: (args: Record<string, unknown>) => void }) {
  const isTask = kind === 'task';
  return <div className="fixed inset-0 z-[60] grid place-items-center overflow-y-auto bg-black/60 p-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="item-editor-title"><form onSubmit={(event) => { event.preventDefault(); const data = new FormData(event.currentTarget); if (isTask) { const tags = String(data.get('tags') ?? '').split(',').map((tag) => tag.trim()).filter(Boolean).map((tag) => tag.startsWith('#') ? tag : `#${tag}`); onSubmit({ account: 'Main', title: String(data.get('title') ?? ''), list: String(data.get('list') ?? 'My Tasks'), due: String(data.get('due') ?? ''), tags }); } else { onSubmit({ account: 'Main', title: String(data.get('title') ?? ''), content: String(data.get('content') ?? '') }); } }} className="my-auto w-full max-w-xl rounded-2xl border border-hairline-strong bg-raised p-5 shadow-[0_24px_64px_rgba(0,0,0,0.5)] sm:p-6"><div className="flex items-start justify-between gap-4"><div><p className="text-xs font-semibold uppercase tracking-[0.14em] text-brand">Demo workspace</p><h2 id="item-editor-title" className="mt-1 text-xl font-semibold">{isTask ? 'Create a task' : 'Create a note'}</h2><p className="mt-2 text-sm text-text-2">A locked approval preview will open before anything is saved.</p></div><button type="button" onClick={onCancel} className="rounded-full border border-hairline-strong px-3 py-1.5 text-sm text-text-2">Close</button></div><div className="mt-6 space-y-4"><label className="block"><span className="mb-2 block text-xs font-medium text-text-2">Title</span><input name="title" required maxLength={200} autoFocus className="w-full rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm outline-none focus:border-brand/50" placeholder={isTask ? 'What needs to be done?' : 'Note title'} /></label>{isTask ? <><div className="grid grid-cols-2 gap-4 max-sm:grid-cols-1"><label className="block"><span className="mb-2 block text-xs font-medium text-text-2">List</span><select name="list" className="w-full rounded-xl border border-hairline-strong bg-surface px-4 py-3 text-sm outline-none focus:border-brand/50"><option>My Tasks</option><option>Backlog</option></select></label><label className="block"><span className="mb-2 block text-xs font-medium text-text-2">Due date</span><input name="due" type="date" className="w-full rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm outline-none focus:border-brand/50" /></label></div><label className="block"><span className="mb-2 block text-xs font-medium text-text-2">Tags</span><input name="tags" maxLength={240} className="w-full rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm outline-none focus:border-brand/50" placeholder="Launch, Work" /></label></> : <label className="block"><span className="mb-2 block text-xs font-medium text-text-2">Content</span><textarea name="content" required maxLength={20000} rows={9} className="w-full resize-y rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm leading-6 outline-none focus:border-brand/50" placeholder="Add useful reference material…" /></label>}</div><div className="mt-6 flex justify-end gap-3 max-sm:flex-col-reverse"><button type="button" onClick={onCancel} className="rounded-xl border border-hairline-strong px-4 py-2.5 text-sm transition hover:border-hairline-strong">Cancel</button><button type="submit" className="oa-btn-primary rounded-xl px-5 py-2.5 text-sm font-semibold">Review before saving</button></div></form></div>;
}

function ApprovalDrawer({ action, onCancel, onApprove }: { action: PendingAction; onCancel: () => void; onApprove: () => void }) {
  return <aside className="oa-approval-dock" aria-labelledby="approval-title"><div className="oa-approval-dock__panel"><div className="flex items-start justify-between gap-3"><div className="min-w-0"><p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-warning">Approval required</p><h2 id="approval-title" className="mt-1 oa-wrap-anywhere text-base font-semibold">{action.title}</h2><p className="mt-1 text-xs leading-5 text-text-2">Review this exact change while the workspace remains visible.</p></div><button onClick={onCancel} aria-label="Cancel approval" className="grid h-8 w-8 shrink-0 place-items-center rounded-full border border-hairline-strong text-lg text-text-2 transition hover:border-brand/35 hover:text-ink">×</button></div><dl className="mt-3 max-h-[26vh] space-y-1.5 overflow-y-auto rounded-xl bg-field p-3">{compactArgs(action.args).map(({ key, value }) => <div key={key} className="grid grid-cols-[minmax(72px,96px)_minmax(0,1fr)] gap-2 text-xs max-sm:grid-cols-1 max-sm:gap-0.5"><dt className="oa-wrap-anywhere text-text-3">{key}</dt><dd className="oa-wrap-anywhere text-ink/90">{value}</dd></div>)}</dl>{action.destructive ? <p className="mt-3 rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-xs leading-5 text-danger-strong">A screen tap is required. Voice confirmation cannot approve it.</p> : <p className="mt-3 text-xs leading-5 text-text-2">Tap Approve or say “confirm” while this preview is active.</p>}<div className="mt-3 flex justify-end gap-2"><button onClick={onCancel} className="rounded-lg border border-hairline-strong px-3.5 py-2 text-xs transition hover:border-hairline-strong">Cancel</button><button onClick={onApprove} className={`rounded-lg px-4 py-2 text-xs font-semibold ${action.destructive ? 'bg-danger text-brand-ink' : 'oa-btn-primary'}`}>Approve</button></div></div></aside>;
}
