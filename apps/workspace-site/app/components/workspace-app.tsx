'use client';

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import {
  DEMO_ACTIVITY,
  DEMO_EVENTS,
  DEMO_MAIL,
  DEMO_MEMORY,
  DEMO_NOTES,
  DEMO_TASKS,
  type DemoAccount,
  type DemoWorkspaceState,
  type WorkspaceView,
} from '../../lib/demo-data';
import {
  isWorkspaceToolName,
  WORKSPACE_TOOL_MAP,
  WORKSPACE_TOOLS,
  type WorkspaceToolDefinition,
  type WorkspaceToolName,
} from '../../lib/tool-registry';

type SiteUser = { id: string; email: string; name: string } | null;
type Mode = 'demo' | 'live';
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
type DemoApiResponse = {
  workspace?: DemoWorkspaceState;
  expiresAt?: number;
  result?: unknown;
  error?: string;
};

const NAVIGATION: { view: WorkspaceView; label: string; key: string }[] = [
  { view: 'today', label: 'Today', key: 'T' },
  { view: 'inbox', label: 'Inbox', key: 'I' },
  { view: 'tasks', label: 'Tasks', key: 'K' },
  { view: 'calendar', label: 'Calendar', key: 'C' },
  { view: 'notes', label: 'Notes', key: 'N' },
  { view: 'memory', label: 'Memory', key: 'M' },
  { view: 'accounts', label: 'Accounts', key: 'A' },
  { view: 'activity', label: 'Activity', key: 'Y' },
];

const VIEW_COPY: Record<WorkspaceView, { eyebrow: string; title: string; subtitle: string }> = {
  today: { eyebrow: 'Thursday · August 27', title: 'Today', subtitle: 'Mail, tasks, and calendar in one calm view.' },
  inbox: { eyebrow: 'Three demo accounts', title: 'Inbox', subtitle: 'Search every connected account without mixing identities.' },
  tasks: { eyebrow: 'My Tasks · Upcoming · Backlog', title: 'Tasks', subtitle: 'Clear next actions with short notes and useful tags.' },
  calendar: { eyebrow: 'Agenda and week', title: 'Calendar', subtitle: 'Exact local times, account context, and visible reminders.' },
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
    <nav aria-label={`${unit} pagination`} className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-white/[0.07] pt-4">
      <p className="text-xs text-[#74828e]" aria-live="polite">
        Showing <span className="text-[#c3ccd4]">{rangeStart}–{rangeEnd}</span> of {total} {unit}
      </p>
      {pageCount > 1 && (
        <div className="flex items-center gap-1">
          <button type="button" onClick={() => onPage(page - 1)} disabled={page <= 1} aria-label={`Previous page of ${unit}`} className="grid h-8 w-8 place-items-center rounded-lg border border-white/10 text-sm text-[#9aa6b0] transition hover:border-[#D8B45A]/40 hover:text-white disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:border-white/10">‹</button>
          <div className="flex items-center gap-1 max-sm:hidden">
            {window.map((entry, index) => entry === 'gap'
              ? <span key={`gap-${index}`} aria-hidden="true" className="px-1 text-xs text-[#4f5b66]">…</span>
              : <button key={entry} type="button" onClick={() => onPage(entry)} aria-label={`Page ${entry}`} aria-current={entry === page ? 'page' : undefined} className={`h-8 min-w-8 rounded-lg px-2 text-xs font-semibold tabular-nums transition ${entry === page ? 'bg-[#D8B45A] text-[#120f08]' : 'border border-white/10 text-[#9aa6b0] hover:border-[#D8B45A]/40 hover:text-white'}`}>{entry}</button>)}
          </div>
          <span className="px-2 text-xs tabular-nums text-[#9aa6b0] sm:hidden">{page} / {pageCount}</span>
          <button type="button" onClick={() => onPage(page + 1)} disabled={page >= pageCount} aria-label={`Next page of ${unit}`} className="grid h-8 w-8 place-items-center rounded-lg border border-white/10 text-sm text-[#9aa6b0] transition hover:border-[#D8B45A]/40 hover:text-white disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:border-white/10">›</button>
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
  const [mode, setMode] = useState<Mode>('demo');
  const [view, setView] = useState<WorkspaceView>('today');
  const [search, setSearch] = useState('');
  const [selectedId, setSelectedId] = useState<string | null>('mail-security-review');
  const [pending, setPending] = useState<PendingAction | null>(null);
  const [toast, setToast] = useState('Private demo ready · 23 WebMCP tools available.');
  const [voiceStatus, setVoiceStatus] = useState('Ready to check compatibility');
  const [voicePrompt, setVoicePrompt] = useState<VoicePrompt>(null);
  const [voiceConnected, setVoiceConnected] = useState(false);
  const [voiceMuted, setVoiceMuted] = useState(false);
  const [voiceThreads, setVoiceThreads] = useState<VoiceThread[]>([]);
  const [selectedVoiceThreadId, setSelectedVoiceThreadId] = useState<string | null>(null);
  const [voiceThreadsLoading, setVoiceThreadsLoading] = useState(false);
  const [demoVoiceAccess, setDemoVoiceAccess] = useState<DemoVoiceAccess>('capped');
  const [demoLoading, setDemoLoading] = useState(true);
  const [demoExpiresAt, setDemoExpiresAt] = useState<number | null>(null);
  const [editor, setEditor] = useState<EditorKind>(null);
  const [ownerSetupCode, setOwnerSetupCode] = useState('');
  const [accounts, setAccounts] = useState<DemoAccount[]>([]);
  const [tasks, setTasks] = useState(DEMO_TASKS);
  const [events, setEvents] = useState(DEMO_EVENTS);
  const [messages, setMessages] = useState(DEMO_MAIL);
  const [notes, setNotes] = useState(DEMO_NOTES);
  const [memory, setMemory] = useState(DEMO_MEMORY);
  const [activity, setActivity] = useState(DEMO_ACTIVITY);
  const [live, setLive] = useState<LiveState>({ loading: false, data: {}, accounts: null, error: null });
  const modeRef = useRef(mode);
  const demoVoiceAccessRef = useRef(demoVoiceAccess);
  const pendingRef = useRef(pending);
  const voicePeerRef = useRef<RTCPeerConnection | null>(null);
  const voiceStreamRef = useRef<MediaStream | null>(null);
  const voiceSocketRef = useRef<WebSocket | null>(null);
  const voiceDataChannelRef = useRef<RTCDataChannel | null>(null);
  const voiceAudioRef = useRef<HTMLAudioElement | null>(null);
  const voiceCallIdRef = useRef<string | null>(null);
  const activeVoiceKindRef = useRef<ActiveVoiceKind | null>(null);
  const voiceTimeoutRef = useRef<number | null>(null);
  const cappedToolCountRef = useRef(0);

  useEffect(() => { modeRef.current = mode; }, [mode]);
  useEffect(() => { demoVoiceAccessRef.current = demoVoiceAccess; }, [demoVoiceAccess]);
  useEffect(() => { pendingRef.current = pending; }, [pending]);

  const hydrateDemoWorkspace = useCallback((workspace: DemoWorkspaceState, expiresAt?: number) => {
    setAccounts(workspace.accounts);
    setMessages(workspace.messages);
    setTasks(workspace.tasks);
    setEvents(workspace.events);
    setNotes(workspace.notes);
    setMemory(workspace.memory);
    setActivity(workspace.activity);
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

    if (name === 'workspace_focus_view') {
      const nextView = String(args.view ?? 'today') as WorkspaceView;
      focusView(nextView, typeof args.itemId === 'string' ? args.itemId : undefined);
      setToast(`Focused ${nextView}.`);
      return { status: 'focused', view: nextView, itemId: args.itemId ?? null };
    }

    if (!tool.readOnly) {
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
    setActivity((current) => [{ id: randomId('activity'), actor: 'Workspace', action: `Read: ${tool.title}`, time: 'Just now', type: 'read' as const }, ...current].slice(0, 40));
    setToast(`${tool.title} completed.`);
    return result;
  }, [focusView, hydrateDemoWorkspace, propose]);

  useEffect(() => {
    if (mode !== 'live' || !user) return;
    const controller = new AbortController();
    const timeout = window.setTimeout(() => {
      setLive((current) => ({ ...current, loading: true, error: null }));
      const now = new Date();
      const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      const weekLater = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);
      const requestForView: Record<WorkspaceView, [WorkspaceToolName, Record<string, unknown>]> = {
        today: ['workspace_get_daily_brief', { date: localDateString(now, timeZone), timeZone }],
        inbox: ['workspace_get_daily_brief', { date: localDateString(now, timeZone), timeZone }],
        tasks: ['workspace_find_tasks', { status: 'all' }],
        calendar: ['workspace_list_calendar', { timeMin: now.toISOString(), timeMax: weekLater.toISOString() }],
        notes: ['workspace_list_notes', {}],
        memory: ['workspace_get_memory', {}],
        accounts: ['workspace_list_accounts', {}],
        activity: ['workspace_list_accounts', {}],
      };
      const [toolName, args] = requestForView[view];
      void Promise.all([
        live.accounts ?? invokeTool('workspace_list_accounts', {}, controller.signal),
        invokeTool(toolName, args, controller.signal),
      ]).then(([accountsResult, viewResult]) => {
        setLive((current) => ({
          loading: false,
          error: null,
          accounts: accountsResult,
          data: { ...current.data, [view]: viewResult },
        }));
      }).catch((error: unknown) => {
        if (controller.signal.aborted) return;
        setLive((current) => ({ ...current, loading: false, error: error instanceof Error ? error.message : 'Workspace could not be loaded.' }));
      });
    }, 0);
    return () => {
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [invokeTool, live.accounts, mode, user, view]);

  useEffect(() => {
    if (!document.modelContext) {
      const timeout = window.setTimeout(() => {
        setToast('This browser does not expose WebMCP yet. The workspace still works normally.');
      }, 0);
      return () => window.clearTimeout(timeout);
    }

    const controllers = WORKSPACE_TOOLS.map(() => new AbortController());
    Promise.all(WORKSPACE_TOOLS.map((tool, index) => document.modelContext!.registerTool({
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: { readOnlyHint: tool.readOnly, untrustedContentHint: tool.untrustedContent },
      execute: (input, options) => invokeTool(tool.name, input, options.signal),
    }, { signal: controllers[index].signal })))
      .then(() => setToast(`${WORKSPACE_TOOLS.length} WebMCP tools registered in this tab.`))
      .catch((error: unknown) => setToast(error instanceof Error ? error.message : 'WebMCP registration failed.'));

    const siteToolHandler = (event: Event) => {
      const detail = (event as CustomEvent<{ tool: WorkspaceToolName; args: Record<string, unknown>; requestId: string }>).detail;
      void invokeTool(detail.tool, detail.args).then((result) => {
        window.dispatchEvent(new CustomEvent('openassist:site-tool-result', { detail: { requestId: detail.requestId, result } }));
      });
    };
    window.addEventListener('openassist:use-site-tool', siteToolHandler);
    return () => {
      controllers.forEach((controller) => controller.abort());
      window.removeEventListener('openassist:use-site-tool', siteToolHandler);
    };
  }, [invokeTool]);

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

  const stopVoice = useCallback((message = 'Voice stopped', persist = true) => {
    const kind = activeVoiceKindRef.current;
    const callId = voiceCallIdRef.current;
    const socket = voiceSocketRef.current;
    const channel = voiceDataChannelRef.current;
    const peer = voicePeerRef.current;
    const stream = voiceStreamRef.current;
    const hadSession = Boolean(kind || socket || channel || peer || stream);
    activeVoiceKindRef.current = null;
    voiceCallIdRef.current = null;
    cappedToolCountRef.current = 0;
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
    setVoiceConnected(false);
    setVoiceMuted(false);
    setVoiceStatus(message);
    if (persist && hadSession && kind) {
      if (kind === 'demo_capped' && callId) {
        void fetch('/api/demo/voice/capped/stop', {
          method: 'POST',
          keepalive: true,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ callId }),
        }).catch(() => undefined);
      } else {
        const endpoint = kind === 'demo_subscription'
          ? '/api/demo/voice/subscription/session/stop'
          : '/api/voice/session/stop';
        void fetch(endpoint, { method: 'POST', keepalive: true })
          .then((response) => response.ok ? refreshVoiceThreads() : undefined)
          .catch(() => undefined);
      }
    }
  }, [refreshVoiceThreads]);

  const connectVoice = useCallback(async () => {
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
      setVoiceStatus(currentMode === 'live' ? 'Checking your private Workspace connection…' : 'Checking the synthetic demo workspace…');
      await invokeTool('workspace_list_accounts', {});

      const subscription = currentMode === 'live' || currentAccess === 'subscription';
      const subscriptionBase = currentMode === 'demo' ? '/api/demo/voice/subscription' : '/api/voice';
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
      peer.ontrack = (event) => {
        audio.srcObject = event.streams[0] ?? new MediaStream([event.track]);
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
          let message: { type?: string; name?: string; call_id?: string; arguments?: string; error?: { message?: string } };
          try { message = JSON.parse(String(event.data)) as typeof message; } catch { return; }
          if (message.type === 'error') {
            setVoiceStatus(message.error?.message ?? 'The demo voice service returned an error.');
            return;
          }
          if (message.type !== 'response.function_call_arguments.done' || !message.call_id || !message.name) return;
          cappedToolCountRef.current += 1;
          const sendResult = (output: unknown) => {
            if (dataChannel?.readyState !== 'open') return;
            dataChannel.send(JSON.stringify({
              type: 'conversation.item.create',
              item: { type: 'function_call_output', call_id: message.call_id, output: JSON.stringify(output ?? null) },
            }));
            dataChannel.send(JSON.stringify({ type: 'response.create' }));
          };
          if (cappedToolCountRef.current > 12) {
            sendResult({ error: 'This five-minute demo reached its 12-tool safety limit.' });
            setVoiceStatus('This demo reached its 12-tool limit. Start a new session later or use your subscription.');
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
          setVoiceStatus('Listening · capped five-minute synthetic demo');
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
        body: JSON.stringify(subscription ? { sdp: offerSdp, threadId: selectedVoiceThreadId } : { sdp: offerSdp }),
      });
      const body = (await response.json()) as { status?: string; message?: string; error?: string; sdp?: string; toolSocketUrl?: string; toolSocketToken?: string; threadId?: string; resumed?: boolean; callId?: string; expiresAfterSeconds?: number; warningAfterSeconds?: number };
      if (!response.ok || body.status !== 'ready' || !body.sdp) throw new Error(body.message ?? body.error ?? 'Voice is not compatible yet.');
      if (body.threadId) setSelectedVoiceThreadId(body.threadId);
      if (body.callId) voiceCallIdRef.current = body.callId;
      await peer.setRemoteDescription({ type: 'answer', sdp: body.sdp });

      if (!subscription) {
        const warningSeconds = Math.max(1, body.warningAfterSeconds ?? 240);
        const expirySeconds = Math.max(warningSeconds + 1, body.expiresAfterSeconds ?? 300);
        voiceTimeoutRef.current = window.setTimeout(() => {
          setVoiceStatus('One minute remains in this capped demo voice session.');
          voiceTimeoutRef.current = window.setTimeout(() => stopVoice('Five-minute demo voice session ended.'), (expirySeconds - warningSeconds) * 1_000);
        }, warningSeconds * 1_000);
        return;
      }

      if (!body.toolSocketUrl || !body.toolSocketToken) throw new Error('Subscription voice did not return its secure tool connection.');
      const socket = new WebSocket(body.toolSocketUrl, ['openassist-tools', `openassist-token.${body.toolSocketToken}`]);
      voiceSocketRef.current = socket;
      socket.addEventListener('message', (event) => {
        let message: { type?: string; callId?: string; operation?: string; tool?: string; args?: Record<string, unknown>; previewId?: string; message?: string };
        try { message = JSON.parse(String(event.data)) as typeof message; } catch { return; }
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
        } else if (message.type === 'session_ended') {
          stopVoice(message.message ?? 'Voice session ended.');
        }
      });
      socket.addEventListener('open', () => {
        setVoiceConnected(true);
        setVoiceStatus(body.resumed ? 'Listening · resumed saved conversation' : 'Listening · new saved conversation');
      });
      socket.addEventListener('close', () => {
        if (voiceSocketRef.current === socket) stopVoice('Voice connection ended.');
      });
    } catch (error) {
      stopVoice(error instanceof Error ? error.message : 'Voice is temporarily unavailable.');
    }
  }, [approve, invokeTool, selectedVoiceThreadId, stopVoice, user, voiceConnected]);

  const toggleVoiceMute = useCallback(() => {
    const next = !voiceMuted;
    voiceStreamRef.current?.getAudioTracks().forEach((track) => { track.enabled = !next; });
    setVoiceMuted(next);
    setVoiceStatus(next ? 'Microphone muted' : activeVoiceKindRef.current === 'demo_capped' ? 'Listening · capped synthetic demo' : 'Listening through your ChatGPT subscription');
  }, [voiceMuted]);

  const selectDemoVoiceAccess = useCallback((access: DemoVoiceAccess) => {
    if (voiceConnected) stopVoice('Voice stopped before changing access.');
    demoVoiceAccessRef.current = access;
    setDemoVoiceAccess(access);
    setVoicePrompt(null);
    setVoiceThreads([]);
    setSelectedVoiceThreadId(null);
    setVoiceStatus(access === 'capped'
      ? 'Ready for a capped five-minute synthetic demo'
      : 'Ready to connect your own ChatGPT subscription');
    if (access === 'subscription') void refreshVoiceThreads(true);
  }, [refreshVoiceThreads, stopVoice, voiceConnected]);

  useEffect(() => () => stopVoice('Voice stopped'), [stopVoice]);

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

  const selectMode = useCallback((nextMode: Mode) => {
    if (nextMode === 'live' && !user) {
      router.push('/signin-with-chatgpt?return_to=%2F');
      return;
    }
    if (nextMode !== modeRef.current && voiceConnected) stopVoice('Voice stopped because the workspace mode changed.');
    setMode(nextMode);
    setVoicePrompt(null);
    if (nextMode === 'live') void refreshVoiceThreads(true);
    if (nextMode === 'demo' && demoVoiceAccessRef.current !== 'subscription') {
      setVoiceThreads([]);
      setSelectedVoiceThreadId(null);
    }
    setToast(nextMode === 'demo' ? 'Safe synthetic data is active.' : 'Owner mode selected. Connect Workspace to continue.');
  }, [refreshVoiceThreads, router, stopVoice, user, voiceConnected]);

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

  const copy = mode === 'demo' && view === 'notes'
    ? { eyebrow: 'Temporary demo notes', title: 'Notes', subtitle: 'Judge-created notes stay isolated from Google and expire automatically.' }
    : mode === 'demo' && view === 'memory'
      ? { eyebrow: 'Temporary demo memory', title: 'Memory', subtitle: 'Safe synthetic preferences for testing agent decisions.' }
      : VIEW_COPY[view];
  return (
    <main className="min-h-screen bg-[radial-gradient(circle_at_38%_-14%,rgba(216,180,90,0.07),transparent_34%),radial-gradient(circle_at_88%_8%,rgba(216,180,90,0.035),transparent_24%),#07080a] text-[#e6edf3]">
      <div className="mx-auto grid min-h-screen w-full max-w-[1800px] grid-cols-[238px_minmax(0,1fr)_minmax(300px,340px)] max-xl:grid-cols-[84px_minmax(0,1fr)] max-md:grid-cols-1">
        <Sidebar mode={mode} view={view} user={user} onMode={selectMode} onView={focusView} onToast={setToast} onSignIn={() => router.push('/signin-with-chatgpt?return_to=%2F')} />
        <section id={`view-${view}`} className="min-w-0 pb-[calc(88px+env(safe-area-inset-bottom))] md:pb-10">
          <div className="flex items-center justify-between gap-3 border-b border-white/[0.08] px-5 py-3.5 md:hidden">
            <div className="flex min-w-0 items-center gap-2.5">
              <BrandMark size="h-8 w-8" />
              <div className="min-w-0">
                <p className="truncate text-sm font-semibold leading-tight">OpenAssist</p>
                <p className="truncate text-[11px] leading-tight text-[#74828e]">Daily Workspace</p>
              </div>
            </div>
            <span className="shrink-0 rounded-full border border-[#D8B45A]/20 bg-[#D8B45A]/[0.07] px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#D8B45A]">{mode}</span>
          </div>

          <div className="px-5 pt-5 sm:px-8 sm:pt-6 lg:px-12">
            <header className="border-b border-white/[0.08] pb-5">
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0">
                  <p className="truncate text-[11px] font-semibold uppercase tracking-[0.15em] text-[#D8B45A] sm:text-xs">{copy.eyebrow}</p>
                  <h1 className="mt-1 text-2xl font-semibold tracking-[-0.03em] sm:text-3xl">{copy.title}</h1>
                  <p className="mt-1 max-w-prose text-sm leading-5 text-[#74828e] max-sm:oa-clamp-2">{copy.subtitle}</p>
                </div>
                <button onClick={connectVoice} aria-label={voiceConnected ? 'Stop voice' : 'Start voice'} className={`grid h-10 w-10 shrink-0 place-items-center rounded-full text-sm font-bold shadow-[0_0_0_5px_rgba(216,180,90,0.08)] transition ${voiceConnected ? 'bg-[#ff806d] text-[#230704]' : 'bg-[#D8B45A] text-[#120f08]'}`}>{voiceConnected ? '■' : '●'}</button>
              </div>

              <div className="mt-4 flex flex-wrap items-center gap-2.5">
                <label className="relative min-w-0 flex-1 basis-full sm:basis-auto sm:max-w-xs">
                  <span className="sr-only">Search current view</span>
                  <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search workspace" className="w-full min-w-0 rounded-xl border border-white/10 bg-white/[0.04] px-3 py-2 text-sm outline-none transition placeholder:text-[#56636e] focus:border-[#D8B45A]/50 focus:ring-2 focus:ring-[#D8B45A]/10" />
                </label>
                <div aria-label="Workspace mode" className="grid shrink-0 grid-cols-2 rounded-xl border border-white/[0.08] bg-white/[0.04] p-1 xl:hidden">
                  {(['demo', 'live'] as const).map((item) => <button key={item} onClick={() => selectMode(item)} aria-pressed={mode === item} className={`rounded-lg px-3 py-1.5 text-xs font-semibold capitalize transition ${mode === item ? 'bg-[#D8B45A] text-[#120f08] shadow-[0_4px_16px_rgba(216,180,90,0.12)]' : 'text-[#80909d] hover:bg-white/[0.05] hover:text-white'}`}>{item}</button>)}
                </div>
                {mode === 'demo' && <button onClick={() => void resetDemo()} className="shrink-0 rounded-xl border border-white/10 px-3 py-2 text-xs text-[#9aa6b0] transition hover:border-[#D8B45A]/35 hover:text-white">Reset demo</button>}
              </div>
            </header>
            {mode === 'demo' && <div className="mt-4 rounded-xl border border-[#D8B45A]/15 bg-[#D8B45A]/[0.035] px-4 py-3"><div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 text-xs text-[#7f8c96]"><span className="oa-wrap-anywhere">Private synthetic judge workspace · no Google data</span><span className="oa-wrap-anywhere">{demoExpiresAt ? `Resets ${new Date(demoExpiresAt).toLocaleDateString()}` : 'Preparing isolated storage…'}</span></div><div className="mt-3 xl:hidden"><DemoVoiceChoice value={demoVoiceAccess} connected={voiceConnected} onChange={selectDemoVoiceAccess} /></div></div>}
            {(mode === 'live' || (mode === 'demo' && demoVoiceAccess === 'subscription')) && <div className="mt-4 xl:hidden"><VoiceThreadPicker threads={voiceThreads} selectedId={selectedVoiceThreadId} loading={voiceThreadsLoading} connected={voiceConnected} onSelect={setSelectedVoiceThreadId} onRefresh={() => void refreshVoiceThreads()} /></div>}
            <div className="py-7">
              {mode === 'live' ? (
              view === 'activity'
                ? <ActivityView mode={mode} activity={activity} />
                : <LiveWorkspaceView view={view} live={live} ownerCode={ownerSetupCode} onOwnerCode={setOwnerSetupCode} onBootstrap={() => void completeOwnerSetup()} onReconnect={() => router.push('/api/workspace/connect')} />
            ) : demoLoading ? <div className="grid min-h-[360px] place-items-center"><div className="text-center"><span className="mx-auto block h-8 w-8 animate-pulse rounded-full border border-[#D8B45A]/50 bg-[#D8B45A]/10" /><p className="mt-4 text-sm text-[#74828e]">Preparing your private demo workspace…</p></div></div> : <>
              {view === 'today' && <TodayView messages={messages.filter((message) => message.unread)} tasks={tasks.filter((task) => !task.completed)} events={events.filter((event) => event.day === 'Today')} selectedId={selectedId} onSelect={setSelectedId} onNavigate={focusView} />}
              {view === 'inbox' && <InboxView messages={filteredMessages} selectedId={selectedId} onSelect={setSelectedId} onMarkRead={(message) => void invokeTool('workspace_set_mail_read_state', { account: message.account, messageIds: [message.id], state: 'read', scope: 'thread' })} />}
              {view === 'tasks' && <TasksView tasks={tasks} selectedId={selectedId} onSelect={setSelectedId} onCreate={() => setEditor('task')} />}
              {view === 'calendar' && <CalendarView events={events} selectedId={selectedId} onSelect={setSelectedId} onCreate={() => void invokeTool('workspace_create_calendar_event', { account: 'Main', summary: 'WebMCP demo review', start: '2026-08-28T11:00:00-05:00', end: '2026-08-28T11:30:00-05:00', timeZone: 'America/Chicago', reminderMinutes: [10] })} />}
              {view === 'notes' && <NotesView mode={mode} notes={notes} onCreate={() => setEditor('note')} />}
              {view === 'memory' && <MemoryView mode={mode} memory={memory} onRemember={() => void invokeTool('workspace_remember_fact', { category: 'Preferences', fact: 'Use the Main account for personal reminders.' })} />}
              {view === 'accounts' && <AccountsView mode={mode} accounts={accounts} />}
              {view === 'activity' && <ActivityView mode={mode} activity={activity} />}
              </>}
            </div>
          </div>
        </section>
        <ActivityRail mode={mode} demoVoiceAccess={demoVoiceAccess} activity={activity} toast={toast} voiceStatus={voiceStatus} voicePrompt={voicePrompt} voiceConnected={voiceConnected} voiceMuted={voiceMuted} voiceThreads={voiceThreads} selectedVoiceThreadId={selectedVoiceThreadId} voiceThreadsLoading={voiceThreadsLoading} onVoice={connectVoice} onMute={toggleVoiceMute} onDemoVoiceAccess={selectDemoVoiceAccess} onSelectVoiceThread={setSelectedVoiceThreadId} onRefreshVoiceThreads={() => void refreshVoiceThreads()} onOpen={() => focusView('activity')} />
      </div>
      {pending && <ApprovalDrawer action={pending} onCancel={() => { setPending(null); setToast('Preview cancelled. Nothing changed.'); }} onApprove={() => void approve('tap')} />}
      {editor && <ItemEditor kind={editor} onCancel={() => setEditor(null)} onSubmit={(args) => submitEditor(editor, args)} />}
      <MobileNavigation view={view} onView={focusView} />
    </main>
  );
}

const VIEW_ICONS: Record<WorkspaceView, React.ReactNode> = {
  today: <path d="M3 9h18M7 3v3m10-3v3M5 5h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z" />,
  inbox: <path d="M3 12h4l2 3h6l2-3h4M5 5h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z" />,
  tasks: <path d="m4 12 3.5 3.5L20 6M4 19h10" />,
  calendar: <path d="M8 3v3m8-3v3M4 10h16M5 6h14a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1Z" />,
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

function MobileNavigation({ view, onView }: { view: WorkspaceView; onView: (view: WorkspaceView) => void }) {
  const [moreOpen, setMoreOpen] = useState(false);
  const primary = NAVIGATION.slice(0, 4);
  const overflow = NAVIGATION.slice(4);
  const overflowActive = overflow.some((item) => item.view === view);

  return (
    <>
      {moreOpen && (
        <div className="fixed inset-0 z-40 bg-black/50 backdrop-blur-[2px] md:hidden" onClick={() => setMoreOpen(false)} aria-hidden="true" />
      )}
      <nav aria-label="Workspace views" className="fixed bottom-0 left-0 z-50 w-screen max-w-full border-t border-white/[0.08] bg-[#101114]/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-xl md:hidden">
        {moreOpen && (
          <div className="grid grid-cols-4 gap-1 border-b border-white/[0.07] px-2 py-2">
            {overflow.map((item) => (
              <button key={item.view} onClick={() => { onView(item.view); setMoreOpen(false); }} aria-current={view === item.view ? 'page' : undefined} className={`flex flex-col items-center gap-1 rounded-xl px-1 py-2.5 transition ${view === item.view ? 'bg-[#D8B45A]/[0.14] text-[#FFF0BF]' : 'text-[#8a97a3] hover:bg-white/[0.05]'}`}>
                <ViewIcon view={item.view} />
                <span className="w-full truncate text-center text-[10px] leading-tight">{item.label}</span>
              </button>
            ))}
          </div>
        )}
        <ul className="grid grid-cols-5 gap-0.5 px-1.5 py-1.5">
          {primary.map((item) => (
            <li key={item.view} className="min-w-0">
              <button onClick={() => { onView(item.view); setMoreOpen(false); }} aria-current={view === item.view ? 'page' : undefined} className={`flex w-full flex-col items-center gap-0.5 rounded-xl px-1 py-1.5 transition ${view === item.view ? 'text-[#FFF0BF]' : 'text-[#7c8994]'}`}>
                <span className={`grid h-8 w-full max-w-[56px] place-items-center rounded-lg transition ${view === item.view ? 'bg-[#D8B45A]/[0.15]' : ''}`}>
                  <ViewIcon view={item.view} />
                </span>
                <span className="w-full truncate text-center text-[10px] font-medium leading-tight">{item.label}</span>
              </button>
            </li>
          ))}
          <li className="min-w-0">
            <button onClick={() => setMoreOpen((open) => !open)} aria-expanded={moreOpen} aria-label="More workspace views" className={`flex w-full flex-col items-center gap-0.5 rounded-xl px-1 py-1.5 transition ${moreOpen || overflowActive ? 'text-[#FFF0BF]' : 'text-[#7c8994]'}`}>
              <span className={`grid h-8 w-full max-w-[56px] place-items-center rounded-lg transition ${moreOpen || overflowActive ? 'bg-[#D8B45A]/[0.15]' : ''}`}>
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

function Sidebar({ mode, view, user, onMode, onView, onToast, onSignIn }: { mode: Mode; view: WorkspaceView; user: SiteUser; onMode: (mode: Mode) => void; onView: (view: WorkspaceView) => void; onToast: (message: string) => void; onSignIn: () => void }) {
  return <aside className="min-w-0 border-r border-white/[0.08] px-5 py-6 max-xl:px-3 max-md:hidden"><div className="mb-8 flex items-center gap-3 px-2"><BrandMark /><div className="max-xl:hidden"><p className="font-semibold">OpenAssist</p><p className="text-xs text-[#798794]">Daily Workspace</p></div></div><nav aria-label="Primary workspace views"><ul className="space-y-1">{NAVIGATION.map((item) => <li key={item.view}><button onClick={() => onView(item.view)} aria-current={view === item.view ? 'page' : undefined} title={item.label} className={`flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left text-sm transition max-xl:justify-center max-xl:px-2 ${view === item.view ? 'bg-white/[0.09] text-white shadow-[inset_0_0_0_1px_rgba(255,255,255,0.05)]' : 'text-[#8d9aa6] hover:bg-white/[0.05] hover:text-white'}`}><span className="grid h-7 w-7 shrink-0 place-items-center rounded-lg border border-white/10"><ViewIcon view={item.view} className="h-4 w-4" /></span><span className="truncate max-xl:hidden">{item.label}</span></button></li>)}</ul></nav><div className="mt-8 border-t border-white/[0.08] pt-5 max-xl:hidden"><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#5f6c78]">Mode</p><div className="mt-3 grid grid-cols-2 rounded-xl bg-white/[0.04] p-1">{(['demo', 'live'] as const).map((item) => <button key={item} onClick={() => { if (item === 'live' && !user) { onSignIn(); return; } onMode(item); onToast(item === 'demo' ? 'Safe synthetic data is active.' : 'Owner mode selected. Connect Workspace to continue.'); }} className={`rounded-lg px-2 py-2 text-xs font-semibold capitalize ${mode === item ? 'bg-[#D8B45A] text-[#120f08]' : 'text-[#80909d]'}`}>{item}</button>)}</div><p className="mt-3 text-xs leading-5 text-[#667480]">{mode === 'demo' ? 'Public synthetic judge data. No private content.' : user ? `Signed in as ${user.email}` : 'ChatGPT sign-in is required.'}</p></div></aside>;
}

function VoiceThreadPicker({ threads, selectedId, loading, connected, onSelect, onRefresh }: { threads: VoiceThread[]; selectedId: string | null; loading: boolean; connected: boolean; onSelect: (threadId: string | null) => void; onRefresh: () => void }) {
  const selectId = useId();
  return (
    <div className="rounded-2xl border border-white/[0.08] bg-white/[0.025] p-3.5">
      <div className="flex items-center justify-between gap-3">
        <label htmlFor={selectId} className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#697783]">Conversation</label>
        <button type="button" onClick={onRefresh} disabled={loading || connected} className="text-[11px] font-medium text-[#D8B45A] transition hover:text-[#F2D783] disabled:cursor-not-allowed disabled:opacity-40">{loading ? 'Loading…' : 'Refresh'}</button>
      </div>
      <select id={selectId} value={selectedId ?? ''} onChange={(event) => onSelect(event.target.value || null)} disabled={loading || connected} className="mt-2 w-full rounded-xl border border-white/10 bg-[#101215] px-3 py-2.5 text-sm text-[#dce4ea] outline-none transition focus:border-[#D8B45A]/50 focus:ring-2 focus:ring-[#D8B45A]/10 disabled:cursor-not-allowed disabled:opacity-60">
        <option value="">New conversation</option>
        {threads.map((thread) => {
          const savedAt = thread.updatedAt || thread.createdAt;
          const label = thread.name || thread.preview || (savedAt ? `Conversation from ${new Date(savedAt * 1_000).toLocaleDateString()}` : 'Saved conversation');
          return <option key={thread.id} value={thread.id}>{label.slice(0, 90)}</option>;
        })}
      </select>
      <p className="mt-2 text-[11px] leading-4 text-[#667480]">{connected ? 'Stop voice before changing conversations.' : selectedId ? 'Voice will continue this saved conversation.' : 'Voice will start a new saved conversation.'}</p>
    </div>
  );
}

function DemoVoiceChoice({ value, connected, onChange }: { value: DemoVoiceAccess; connected: boolean; onChange: (access: DemoVoiceAccess) => void }) {
  const choices: Array<{ id: DemoVoiceAccess; title: string; detail: string }> = [
    { id: 'capped', title: 'Quick judge demo', detail: 'Server-funded · 5 min · 12 tools' },
    { id: 'subscription', title: 'My ChatGPT', detail: 'Private isolated sign-in · saved chats' },
  ];
  return (
    <div role="radiogroup" aria-label="Demo voice access" className="grid gap-2 sm:grid-cols-2 xl:grid-cols-1">
      {choices.map((choice) => (
        <button key={choice.id} type="button" role="radio" aria-checked={value === choice.id} disabled={connected} onClick={() => onChange(choice.id)} className={`rounded-xl border px-3 py-2.5 text-left transition disabled:cursor-not-allowed disabled:opacity-60 ${value === choice.id ? 'border-[#D8B45A]/45 bg-[#D8B45A]/[0.09] shadow-[0_0_18px_rgba(216,180,90,0.06)]' : 'border-white/[0.08] bg-white/[0.025] hover:border-[#D8B45A]/25'}`}>
          <span className={`block text-xs font-semibold ${value === choice.id ? 'text-[#F2D783]' : 'text-[#cbd4db]'}`}>{choice.title}</span>
          <span className="mt-0.5 block text-[10px] leading-4 text-[#667480]">{choice.detail}</span>
        </button>
      ))}
    </div>
  );
}

function ActivityRail({ mode, demoVoiceAccess, activity, toast, voiceStatus, voicePrompt, voiceConnected, voiceMuted, voiceThreads, selectedVoiceThreadId, voiceThreadsLoading, onVoice, onMute, onDemoVoiceAccess, onSelectVoiceThread, onRefreshVoiceThreads, onOpen }: { mode: Mode; demoVoiceAccess: DemoVoiceAccess; activity: typeof DEMO_ACTIVITY; toast: string; voiceStatus: string; voicePrompt: VoicePrompt; voiceConnected: boolean; voiceMuted: boolean; voiceThreads: VoiceThread[]; selectedVoiceThreadId: string | null; voiceThreadsLoading: boolean; onVoice: () => void; onMute: () => void; onDemoVoiceAccess: (access: DemoVoiceAccess) => void; onSelectVoiceThread: (threadId: string | null) => void; onRefreshVoiceThreads: () => void; onOpen: () => void }) {
  const voiceLabel = mode === 'live'
    ? 'Owner voice'
    : demoVoiceAccess === 'capped'
      ? 'Quick demo voice'
      : 'ChatGPT subscription voice';
  return (
    <aside className="min-w-0 border-l border-white/[0.08] bg-[#0b0c0e] px-5 py-7 max-xl:hidden">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="truncate font-semibold">Workspace activity</h2>
          <p className="mt-1 oa-clamp-1 text-xs text-[#667480]">Every action stays visible.</p>
        </div>
        <span className="shrink-0 rounded-full bg-[#D8B45A]/10 px-2.5 py-1 text-[10px] font-semibold text-[#D8B45A]">WebMCP</span>
      </div>
      <div className="mt-6 space-y-1">
        {activity.slice(0, 5).map((item) => (
          <button key={item.id} onClick={onOpen} className="block w-full rounded-xl border-l border-white/10 px-3 py-2.5 text-left transition hover:border-[#D8B45A] hover:bg-[#D8B45A]/[0.05]">
            <p className="oa-clamp-2 text-sm leading-5 text-[#d5dde3]">{item.action}</p>
            <p className="mt-1 oa-clamp-1 text-xs text-[#65737f]">{item.actor} · {item.time}</p>
          </button>
        ))}
      </div>
      <div className="mt-8 border-t border-white/[0.08] pt-6">
        <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#5f6c78]">Voice</p>
        {mode === 'demo' && <div className="mt-3"><DemoVoiceChoice value={demoVoiceAccess} connected={voiceConnected} onChange={onDemoVoiceAccess} /></div>}
        <button onClick={onVoice} className="group mt-3 flex w-full items-center gap-3 rounded-2xl px-2 py-3 text-left transition hover:bg-white/[0.04]">
          <span className={`grid h-11 w-11 shrink-0 place-items-center rounded-full border text-sm transition group-hover:shadow-[0_0_24px_rgba(216,180,90,0.16)] ${voiceConnected ? 'border-[#ff806d]/40 bg-[#ff806d]/10 text-[#ff9a89]' : 'border-[#D8B45A]/30 bg-[#D8B45A]/[0.07] text-[#D8B45A]'}`}>{voiceConnected ? '■' : '●'}</span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-medium">{voiceConnected ? `Stop ${voiceLabel.toLowerCase()}` : voiceLabel}</span>
            <span className="mt-0.5 block oa-clamp-2 text-xs leading-4 text-[#667480]">{voiceStatus}</span>
          </span>
        </button>
        {voiceConnected && <button onClick={onMute} className="mt-2 w-full rounded-xl border border-white/[0.08] px-3 py-2 text-xs text-[#94a1ac] transition hover:border-[#D8B45A]/40 hover:text-white">{voiceMuted ? 'Unmute microphone' : 'Mute microphone'}</button>}
        {(mode === 'live' || demoVoiceAccess === 'subscription') && <div className="mt-3"><VoiceThreadPicker threads={voiceThreads} selectedId={selectedVoiceThreadId} loading={voiceThreadsLoading} connected={voiceConnected} onSelect={onSelectVoiceThread} onRefresh={onRefreshVoiceThreads} /></div>}
        {mode === 'demo' && demoVoiceAccess === 'capped' && <p className="mt-2 rounded-xl border border-white/[0.07] bg-white/[0.02] px-3 py-2.5 text-[11px] leading-4 text-[#667480]">Uses only synthetic data. The server key is never sent to this browser.</p>}
        {voicePrompt && (
          <div className="mt-3 rounded-2xl border border-[#D8B45A]/20 bg-[#D8B45A]/[0.06] p-4">
            <p className="text-xs leading-5 text-[#9dabb5]">Open the secure ChatGPT sign-in page, then enter this one-time code.</p>
            <a href={voicePrompt.verificationUrl} target="_blank" rel="noreferrer" className="mt-3 block oa-wrap-anywhere text-xs font-semibold text-[#D8B45A] underline decoration-[#D8B45A]/30 underline-offset-4">Open ChatGPT sign-in</a>
            <code className="mt-3 block oa-wrap-anywhere rounded-lg bg-black/25 px-3 py-2 text-center text-sm font-semibold tracking-[0.18em] text-white">{voicePrompt.userCode}</code>
          </div>
        )}
      </div>
      <div aria-live="polite" className="mt-7 rounded-2xl border border-white/[0.08] bg-white/[0.03] p-4 oa-clamp-3 text-xs leading-5 text-[#82909c]">{toast}</div>
    </aside>
  );
}

type Selectable = { selectedId: string | null; onSelect: (id: string) => void };

function BrandMark({ size = 'h-9 w-9' }: { size?: string }) {
  return <span aria-hidden="true" className={`${size} block shrink-0 rounded-full bg-[url('/openassist-logo.svg')] bg-cover bg-center shadow-[0_0_28px_rgba(216,180,90,0.16)]`} />;
}

function HaloRow({ id, selected, children, onClick }: { id: string; selected: boolean; children: React.ReactNode; onClick: () => void }) {
  return <button id={`workspace-item-${id}`} onClick={onClick} className={`group relative w-full min-w-0 rounded-2xl px-4 py-3.5 text-left transition duration-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#D8B45A] ${selected ? 'bg-[#211d14] shadow-[0_0_0_1px_rgba(216,180,90,0.48),0_16px_38px_rgba(0,0,0,0.25),0_0_32px_rgba(216,180,90,0.09)]' : 'hover:bg-[#181713] hover:shadow-[0_0_0_1px_rgba(216,180,90,0.28),0_12px_30px_rgba(0,0,0,0.2)]'}`}>{children}</button>;
}

function SectionHeading({ title, description, action }: { title: string; description?: string; action?: React.ReactNode }) {
  return (
    <div className="mb-3 flex items-end justify-between gap-4">
      <div className="min-w-0">
        <h2 className="truncate text-lg font-semibold">{title}</h2>
        {description && <p className="mt-1 oa-clamp-2 text-sm leading-5 text-[#74828e]">{description}</p>}
      </div>
      {action}
    </div>
  );
}

function EmptyState({ title, hint }: { title: string; hint: string }) {
  return (
    <div className="rounded-2xl border border-white/[0.08] bg-white/[0.025] p-8 text-center">
      <p className="text-sm font-medium">{title}</p>
      <p className="mx-auto mt-2 max-w-sm text-sm leading-6 text-[#74828e]">{hint}</p>
    </div>
  );
}

function TodayView({ messages, tasks, events, selectedId, onSelect, onNavigate }: { messages: typeof DEMO_MAIL; tasks: typeof DEMO_TASKS; events: typeof DEMO_EVENTS } & Selectable & { onNavigate: (view: WorkspaceView, itemId?: string) => void }) {
  const stats: Array<[string, number]> = [['Unread attention', messages.length], ['Open tasks', tasks.length], ['Today’s events', events.length]];
  return (
    <>
      <div className="mb-7 grid grid-cols-3 gap-3 border-b border-white/[0.08] pb-6 sm:gap-7">
        {stats.map(([label, value]) => (
          <div key={label} className="min-w-0">
            <p className="text-2xl font-semibold tabular-nums sm:text-3xl">{value}</p>
            <p className="mt-1 oa-clamp-2 text-[11px] leading-4 text-[#75838f] sm:text-sm">{label}</p>
          </div>
        ))}
      </div>
      <div className="grid grid-cols-[minmax(0,1.25fr)_minmax(0,0.75fr)] gap-8 max-lg:grid-cols-1">
        <section className="min-w-0">
          <SectionHeading title="Needs attention" description="Unread messages across linked accounts." action={<button onClick={() => onNavigate('inbox')} className="shrink-0 text-sm text-[#D8B45A] transition hover:text-[#FFF0BF]">Open inbox</button>} />
          {messages.length ? (
            <div className="space-y-2">
              {messages.slice(0, 4).map((message) => (
                <HaloRow key={message.id} id={message.id} selected={selectedId === message.id} onClick={() => onSelect(message.id)}>
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <p className="flex min-w-0 items-center gap-2 text-xs text-[#74828e]">
                        <span className={`inline-block h-1.5 w-1.5 shrink-0 rounded-full ${message.urgent ? 'bg-[#ff806d]' : 'bg-[#D8B45A]'}`} />
                        <span className="min-w-0 truncate">{message.account}</span>
                      </p>
                      <p className="mt-1 oa-clamp-1 text-sm font-medium">{message.subject}</p>
                      <p className="mt-1 oa-clamp-1 text-sm text-[#74828e]">{message.sender}</p>
                    </div>
                    <span className="shrink-0 text-xs tabular-nums text-[#596772]">{message.time}</span>
                  </div>
                </HaloRow>
              ))}
            </div>
          ) : <EmptyState title="Inbox is clear." hint="No unread messages across your linked accounts right now." />}
        </section>
        <section className="min-w-0">
          <SectionHeading title="Next up" action={<button onClick={() => onNavigate('tasks')} className="shrink-0 text-sm text-[#D8B45A] transition hover:text-[#FFF0BF]">Tasks</button>} />
          {tasks.length ? (
            <div className="space-y-2">
              {tasks.slice(0, 4).map((task) => (
                <HaloRow key={task.id} id={task.id} selected={selectedId === task.id} onClick={() => onSelect(task.id)}>
                  <div className="flex items-start gap-3">
                    <span className="mt-0.5 h-4 w-4 shrink-0 rounded-full border border-[#64727e]" />
                    <div className="min-w-0 flex-1">
                      <p className="oa-clamp-2 text-sm">{task.title}</p>
                      <p className="mt-1 oa-clamp-1 text-xs text-[#697783]">{task.list} · {task.due}</p>
                    </div>
                  </div>
                </HaloRow>
              ))}
            </div>
          ) : <EmptyState title="No open tasks." hint="Everything on your list is done." />}
          {events.slice(0, 1).map((event) => (
            <div key={event.id} className="mt-6 min-w-0 border-l border-[#D8B45A]/60 pl-4">
              <p className="text-xs tabular-nums text-[#D8B45A]">{event.start}–{event.end}</p>
              <p className="mt-1 oa-clamp-2 text-sm font-medium">{event.title}</p>
              <p className="mt-1 oa-clamp-1 text-xs text-[#74828e]">{event.account}</p>
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
        <p className="text-sm tabular-nums text-[#74828e]">{total} {total === 1 ? 'message' : 'messages'}</p>
        <span className="rounded-full bg-[#ffb66b]/10 px-3 py-1 text-xs text-[#ffbd78]">External content is untrusted</span>
      </div>
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((message) => (
              <HaloRow key={message.id} id={message.id} selected={selectedId === message.id} onClick={() => onSelect(message.id)}>
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0 flex-1">
                    <p className="oa-clamp-1 text-xs text-[#74828e]">{message.account} · {message.sender}</p>
                    <p className="mt-1 oa-clamp-1 font-medium">{message.subject}</p>
                    <p className="mt-1 oa-clamp-2 text-sm leading-5 text-[#74828e]">{message.snippet}</p>
                    <div className="mt-3 flex flex-wrap gap-2">
                      {message.hasAttachment && <span className="rounded-full bg-white/[0.05] px-2 py-1 text-[10px] text-[#93a0ab]">Attachment</span>}
                      {message.unread && <span className="rounded-full bg-[#D8B45A]/10 px-2 py-1 text-[10px] text-[#D8B45A]">Unread</span>}
                    </div>
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-1.5">
                    <p className="text-xs tabular-nums text-[#596772]">{message.time}</p>
                    {message.unread && <span role="button" tabIndex={0} onClick={(event) => { event.stopPropagation(); onMarkRead(message); }} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); onMarkRead(message); } }} className="whitespace-nowrap text-xs text-[#D8B45A] transition hover:text-[#FFF0BF]">Mark read</span>}
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
            <button key={item} onClick={() => setFilter(item)} aria-pressed={filter === item} className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition ${filter === item ? 'bg-[#D8B45A] text-[#120f08]' : 'bg-white/[0.05] text-[#82909c] hover:bg-white/[0.09] hover:text-white'}`}>{item}</button>
          ))}
        </div>
        <button onClick={onCreate} className="shrink-0 rounded-xl bg-[#D8B45A] px-4 py-2 text-sm font-semibold text-[#120f08] transition hover:bg-[#e6c877]">New task</button>
      </div>
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((task) => (
              <HaloRow key={task.id} id={task.id} selected={selectedId === task.id} onClick={() => onSelect(task.id)}>
                <div className="flex items-start gap-3">
                  <span className={`mt-0.5 h-4 w-4 shrink-0 rounded-full border ${task.completed ? 'border-[#D8B45A] bg-[#D8B45A]' : 'border-[#65727e]'}`} />
                  <div className="min-w-0 flex-1">
                    <p className={`oa-clamp-2 text-sm ${task.completed ? 'text-[#687681] line-through' : ''}`}>{task.title}</p>
                    <div className="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1">
                      <span className="text-[10px] uppercase tracking-[0.1em] text-[#5f6c78]">{task.list}</span>
                      {task.tags.slice(0, 3).map((tag) => <span key={tag} className="text-[10px] text-[#D8B45A]">{tag}</span>)}
                      {task.tags.length > 3 && <span className="text-[10px] text-[#5f6c78]">+{task.tags.length - 3}</span>}
                    </div>
                  </div>
                  <span className="shrink-0 whitespace-nowrap text-xs text-[#667480]">{task.due}</span>
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
        <div className="flex shrink-0 rounded-xl bg-white/[0.04] p-1">
          <button className="rounded-lg bg-white/[0.08] px-3 py-1.5 text-xs">Agenda</button>
          <button className="rounded-lg px-3 py-1.5 text-xs text-[#72808c] transition hover:text-white">Week</button>
        </div>
        <button onClick={onCreate} className="shrink-0 rounded-xl bg-[#D8B45A] px-4 py-2 text-sm font-semibold text-[#120f08]">New event</button>
      </div>
      {total ? (
        <>
          <div className="border-t border-white/[0.08]">
            {pageItems.map((event) => (
              <div key={event.id} className="grid grid-cols-[76px_minmax(0,1fr)] items-center gap-2 border-b border-white/[0.07] py-2 max-sm:grid-cols-1 max-sm:gap-0 max-sm:py-3">
                <div className="shrink-0 text-xs text-[#667480] max-sm:mb-1 max-sm:px-4">{event.day}</div>
                <div className="min-w-0">
                  <HaloRow id={event.id} selected={selectedId === event.id} onClick={() => onSelect(event.id)}>
                    <div className="flex items-start justify-between gap-4 max-sm:flex-col max-sm:gap-1">
                      <div className="min-w-0 flex-1">
                        <p className="oa-clamp-1 text-sm font-medium">{event.title}</p>
                        <p className="mt-1 oa-clamp-1 text-xs text-[#74828e]">{event.account} · Reminder {event.reminder}</p>
                      </div>
                      <p className="shrink-0 whitespace-nowrap text-xs tabular-nums text-[#D8B45A]">{event.start}–{event.end}</p>
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

function NotesView({ mode, notes, onCreate }: { mode: Mode; notes: typeof DEMO_NOTES; onCreate: () => void }) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(notes, 6, notes.length);
  return (
    <section className="min-w-0">
      <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm tabular-nums text-[#74828e]">{total} {total === 1 ? 'note' : 'notes'}</p>
        <button onClick={onCreate} className="shrink-0 rounded-xl border border-white/10 px-4 py-2 text-sm text-[#9aa6b0] transition hover:border-[#D8B45A]/35 hover:text-white">New note</button>
      </div>
      {total ? (
        <>
          <div className="grid grid-cols-2 gap-4 max-md:grid-cols-1 xl:grid-cols-2">
            {pageItems.map((note) => (
              <HaloRow key={note.id} id={note.id} selected={false} onClick={() => undefined}>
                <div className="min-w-0">
                  <p className="oa-clamp-1 font-medium">{note.title}</p>
                  <p className="mt-3 oa-clamp-3 text-sm leading-6 text-[#74828e]">{note.preview}</p>
                  <p className="mt-4 oa-clamp-1 text-xs text-[#596772]">Updated {note.updated} · {mode === 'demo' ? 'Temporary demo storage' : 'Stored in Drive'}</p>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="notes" onPage={setPage} />
        </>
      ) : <EmptyState title="No notes yet." hint="Notes hold long reference material that would clutter a task." />}
      <p className="mt-7 max-w-2xl text-sm leading-6 text-[#697783]">{mode === 'demo' ? 'These synthetic notes are isolated to this browser session and automatically removed after 24 hours.' : 'OpenAssist creates a Drive note only when reference material is genuinely too long for a task. Short actions stay as clean Google Tasks.'}</p>
    </section>
  );
}

function MemoryView({ mode, memory, onRemember }: { mode: Mode; memory: typeof DEMO_MEMORY; onRemember: () => void }) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(memory, PAGE_SIZE, memory.length);
  return (
    <section className="min-w-0">
      <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
        <p className="oa-clamp-1 text-sm text-[#74828e]">Strict quality gate · no raw email stored</p>
        <button onClick={onRemember} className="shrink-0 rounded-xl border border-[#D8B45A]/30 px-4 py-2 text-sm text-[#D8B45A] transition hover:border-[#D8B45A]/60 hover:text-[#FFF0BF]">Remember a fact</button>
      </div>
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((fact) => (
              <HaloRow key={fact.id} id={fact.id} selected={false} onClick={() => undefined}>
                <div className="min-w-0">
                  <p className="text-xs font-semibold uppercase tracking-[0.12em] text-[#D8B45A]">{fact.category}</p>
                  <p className="mt-2 oa-wrap-anywhere text-sm leading-6 text-[#d4dce2]">{fact.fact}</p>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="facts" onPage={setPage} />
        </>
      ) : <EmptyState title="No saved facts." hint="Durable preferences appear here once you approve them." />}
      <div className="mt-7 rounded-2xl border border-white/[0.08] bg-white/[0.03] p-5">
        <p className="font-medium">Storage boundary</p>
        <p className="mt-2 text-sm leading-6 text-[#74828e]">{mode === 'demo' ? 'Synthetic memory is stored only in this isolated Cloudflare demo workspace and expires after 24 hours.' : 'Memory text lives in one private Google Drive document. The website stores only its encrypted connection and document pointer.'}</p>
      </div>
    </section>
  );
}

function AccountsView({ mode, accounts }: { mode: Mode; accounts: DemoAccount[] }) {
  return (
    <section className="min-w-0">
      <div className="mb-6 rounded-2xl border border-white/[0.08] bg-white/[0.03] p-5">
        <p className="text-sm font-medium">{mode === 'demo' ? 'Synthetic accounts' : 'Owner connection required'}</p>
        <p className="mt-2 text-sm leading-6 text-[#74828e]">{mode === 'demo' ? 'These are safe sample identities. Judge actions never touch your Google accounts and are removed automatically.' : 'Google credentials remain managed by Composio. OpenAssist never receives the Google refresh token.'}</p>
      </div>
      {accounts.length ? (
        <div className="space-y-3">
          {accounts.map((account, index) => (
            <HaloRow key={account.id} id={account.id} selected={index === 0} onClick={() => undefined}>
              <div className="flex items-start justify-between gap-4 max-sm:flex-col max-sm:gap-3">
                <div className="min-w-0 flex-1">
                  <p className="oa-clamp-1 font-medium">{account.label}</p>
                  <p className="mt-1 oa-wrap-anywhere text-sm text-[#74828e]">{account.email}</p>
                  <p className="mt-0.5 text-xs text-[#5f6c78]">{account.type}</p>
                </div>
                <div className="flex shrink-0 flex-wrap gap-2">
                  {index === 0 && <span className="whitespace-nowrap rounded-full bg-[#D8B45A]/10 px-2.5 py-1 text-[10px] text-[#D8B45A]">Default tasks</span>}
                  <span className="whitespace-nowrap rounded-full bg-white/[0.05] px-2.5 py-1 text-[10px] text-[#8b98a3]">Gmail · Calendar · Tasks</span>
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
  if (view === 'tasks') return arrayValue(data.results).map((item) => ({ ...item, _kind: 'Task' }));
  if (view === 'calendar') return arrayValue(data.events).map((item) => ({ ...item, _kind: 'Calendar' }));
  if (view === 'notes') return arrayValue(data.notes).map((item) => ({ ...item, _kind: 'Drive note' }));
  if (view === 'memory') return arrayValue(data.facts ?? data.memories ?? data.results).map((item) => ({ ...item, _kind: 'Memory' }));
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

function LiveWorkspaceView({ view, live, ownerCode, onOwnerCode, onBootstrap, onReconnect }: { view: WorkspaceView; live: LiveState; ownerCode: string; onOwnerCode: (value: string) => void; onBootstrap: () => void; onReconnect: () => void }) {
  const source = view === 'accounts' || view === 'activity' ? live.accounts : live.data[view];
  const rows = useMemo(() => liveRows(view, source), [source, view]);
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(rows, PAGE_SIZE, `${view}-${rows.length}`);

  if (live.loading && !live.data[view]) {
    return <div className="grid min-h-[360px] place-items-center"><div className="text-center"><span className="mx-auto block h-8 w-8 animate-pulse rounded-full border border-[#D8B45A]/50 bg-[#D8B45A]/10" /><p className="mt-4 text-sm text-[#74828e]">Loading your private Workspace…</p></div></div>;
  }
  if (live.error) {
    if (live.error.startsWith('Owner access')) {
      return <div className="mx-auto max-w-xl rounded-[26px] border border-[#D8B45A]/20 bg-[#D8B45A]/[0.045] p-6 sm:p-7"><p className="text-xs font-semibold uppercase tracking-[0.14em] text-[#D8B45A]">One-time setup</p><h2 className="mt-2 text-xl font-semibold">Bind this private owner account</h2><p className="mt-3 text-sm leading-6 text-[#8d9aa6]">Enter the one-time owner code. It is used only to bind this signed-in ChatGPT account, then it can be removed.</p><label className="mt-5 block"><span className="sr-only">One-time owner code</span><input type="password" autoComplete="one-time-code" value={ownerCode} onChange={(event) => onOwnerCode(event.target.value)} placeholder="One-time owner code" className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none transition placeholder:text-[#56636e] focus:border-[#D8B45A]/50 focus:ring-2 focus:ring-[#D8B45A]/10" /></label><button onClick={onBootstrap} disabled={!ownerCode.trim()} className="mt-4 w-full rounded-xl bg-[#D8B45A] px-5 py-2.5 text-sm font-semibold text-[#120f08] disabled:cursor-not-allowed disabled:opacity-40 sm:w-auto">Finish owner setup</button></div>;
    }
    return <div className="mx-auto max-w-xl rounded-[26px] border border-[#ff806d]/20 bg-[#ff806d]/[0.045] p-6 sm:p-7"><p className="text-xs font-semibold uppercase tracking-[0.14em] text-[#ff9b8c]">Live Workspace unavailable</p><h2 className="mt-2 text-xl font-semibold">Reconnect securely</h2><p className="mt-3 oa-wrap-anywhere text-sm leading-6 text-[#8d9aa6]">{live.error}</p><button onClick={onReconnect} className="mt-6 w-full rounded-xl bg-[#D8B45A] px-5 py-2.5 text-sm font-semibold text-[#120f08] sm:w-auto">Connect Workspace</button></div>;
  }
  if (!source) {
    return <div className="rounded-[24px] border border-white/[0.08] bg-white/[0.025] p-6 sm:p-7"><p className="text-sm leading-6 text-[#82909c]">Connect Workspace to load private data. Demo records are intentionally hidden in Live mode.</p><button onClick={onReconnect} className="mt-5 w-full rounded-xl bg-[#D8B45A] px-5 py-2.5 text-sm font-semibold text-[#120f08] sm:w-auto">Connect Workspace</button></div>;
  }

  return (
    <section className="min-w-0">
      <div className="mb-6 flex items-start justify-between gap-4 rounded-2xl border border-[#D8B45A]/15 bg-[#D8B45A]/[0.045] px-4 py-3.5 sm:px-5 sm:py-4">
        <div className="min-w-0">
          <p className="text-sm font-medium text-[#F4DE99]">Private owner mode</p>
          <p className="mt-1 oa-clamp-2 text-xs leading-5 text-[#74828e]">Loaded live through OpenAssist. Nothing below is copied into the site database.</p>
        </div>
        <button onClick={onReconnect} className="shrink-0 rounded-xl border border-[#D8B45A]/25 px-3 py-2 text-xs text-[#FFF0BF] transition hover:border-[#D8B45A]/50">Connection</button>
      </div>
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((item, index) => {
              const kind = String(item._kind ?? 'Workspace');
              const title = displayText(item, ['subject', 'title', 'summary', 'friendlyLabel', 'fact', 'name', 'email'], `${kind} ${rangeStart + index}`);
              const subtitle = displayText(item, ['sender', 'from', 'email', 'due', 'start', 'account', 'category', 'status'], 'Live Workspace item');
              return (
                <HaloRow key={displayText(item, ['id', 'messageId', 'eventId', 'documentId'], `${view}-${rangeStart + index}`)} id={`live-${view}-${rangeStart + index}`} selected={false} onClick={() => undefined}>
                  <div className="flex items-start justify-between gap-4">
                    <div className="min-w-0 flex-1">
                      <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#D8B45A]">{kind}</p>
                      <p className="mt-1 oa-clamp-1 text-sm font-medium">{title}</p>
                      <p className="mt-1 oa-clamp-1 text-sm text-[#74828e]">{subtitle}</p>
                    </div>
                    <span aria-hidden="true" className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-[#D8B45A] shadow-[0_0_14px_rgba(216,180,90,0.45)]" />
                  </div>
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

function ActivityView({ mode, activity }: { mode: Mode; activity: typeof DEMO_ACTIVITY }) {
  const { page, pageCount, pageItems, rangeStart, rangeEnd, total, setPage } = usePagination(activity, PAGE_SIZE, activity.length);
  return (
    <section className="min-w-0">
      {total ? (
        <>
          <div className="space-y-2">
            {pageItems.map((item) => (
              <HaloRow key={item.id} id={item.id} selected={false} onClick={() => undefined}>
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0 flex-1">
                    <p className="oa-clamp-2 text-sm">{item.action}</p>
                    <p className="mt-1 oa-clamp-1 text-xs text-[#697783]">{item.actor} · {item.type === 'write' ? 'Approved write' : 'Read only'}</p>
                  </div>
                  <span className="shrink-0 whitespace-nowrap text-xs text-[#596772]">{item.time}</span>
                </div>
              </HaloRow>
            ))}
          </div>
          <Pagination page={page} pageCount={pageCount} rangeStart={rangeStart} rangeEnd={rangeEnd} total={total} unit="events" onPage={setPage} />
        </>
      ) : <EmptyState title="No activity yet." hint="Reads and approved writes will appear here as they happen." />}
      <p className="mt-7 max-w-2xl text-sm leading-6 text-[#697783]">{mode === 'demo' ? 'This temporary activity belongs only to the isolated judge workspace and expires with it.' : 'Activity stores safe metadata only. It does not copy message bodies, attachments, task text, calendar text, notes, memory, audio, or transcripts into the database.'}</p>
    </section>
  );
}
function ItemEditor({ kind, onCancel, onSubmit }: { kind: Exclude<EditorKind, null>; onCancel: () => void; onSubmit: (args: Record<string, unknown>) => void }) {
  const isTask = kind === 'task';
  return <div className="fixed inset-0 z-[60] grid place-items-center overflow-y-auto bg-black/60 p-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="item-editor-title"><form onSubmit={(event) => { event.preventDefault(); const data = new FormData(event.currentTarget); if (isTask) { const tags = String(data.get('tags') ?? '').split(',').map((tag) => tag.trim()).filter(Boolean).map((tag) => tag.startsWith('#') ? tag : `#${tag}`); onSubmit({ account: 'Main', title: String(data.get('title') ?? ''), list: String(data.get('list') ?? 'My Tasks'), due: String(data.get('due') ?? ''), tags }); } else { onSubmit({ account: 'Main', title: String(data.get('title') ?? ''), content: String(data.get('content') ?? '') }); } }} className="my-auto w-full max-w-xl rounded-[26px] border border-white/10 bg-[#151619] p-5 shadow-2xl sm:p-6"><div className="flex items-start justify-between gap-4"><div><p className="text-xs font-semibold uppercase tracking-[0.14em] text-[#D8B45A]">Demo workspace</p><h2 id="item-editor-title" className="mt-1 text-xl font-semibold">{isTask ? 'Create a task' : 'Create a note'}</h2><p className="mt-2 text-sm text-[#82909c]">A locked approval preview will open before anything is saved.</p></div><button type="button" onClick={onCancel} className="rounded-full border border-white/10 px-3 py-1.5 text-sm text-[#82909c]">Close</button></div><div className="mt-6 space-y-4"><label className="block"><span className="mb-2 block text-xs font-medium text-[#8f9ca7]">Title</span><input name="title" required maxLength={200} autoFocus className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none focus:border-[#D8B45A]/50" placeholder={isTask ? 'What needs to be done?' : 'Note title'} /></label>{isTask ? <><div className="grid grid-cols-2 gap-4 max-sm:grid-cols-1"><label className="block"><span className="mb-2 block text-xs font-medium text-[#8f9ca7]">List</span><select name="list" className="w-full rounded-xl border border-white/10 bg-[#111214] px-4 py-3 text-sm outline-none focus:border-[#D8B45A]/50"><option>My Tasks</option><option>Backlog</option></select></label><label className="block"><span className="mb-2 block text-xs font-medium text-[#8f9ca7]">Due date</span><input name="due" type="date" className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none focus:border-[#D8B45A]/50" /></label></div><label className="block"><span className="mb-2 block text-xs font-medium text-[#8f9ca7]">Tags</span><input name="tags" maxLength={240} className="w-full rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm outline-none focus:border-[#D8B45A]/50" placeholder="Launch, Work" /></label></> : <label className="block"><span className="mb-2 block text-xs font-medium text-[#8f9ca7]">Content</span><textarea name="content" required maxLength={20000} rows={9} className="w-full resize-y rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm leading-6 outline-none focus:border-[#D8B45A]/50" placeholder="Add useful reference material…" /></label>}</div><div className="mt-6 flex justify-end gap-3 max-sm:flex-col-reverse"><button type="button" onClick={onCancel} className="rounded-xl border border-white/10 px-4 py-2.5 text-sm transition hover:border-white/25">Cancel</button><button type="submit" className="rounded-xl bg-[#D8B45A] px-5 py-2.5 text-sm font-semibold text-[#120f08]">Review before saving</button></div></form></div>;
}

function ApprovalDrawer({ action, onCancel, onApprove }: { action: PendingAction; onCancel: () => void; onApprove: () => void }) {
  return <div className="fixed inset-0 z-[60] flex items-end justify-center overflow-y-auto bg-black/55 p-4 backdrop-blur-sm sm:items-center" role="dialog" aria-modal="true" aria-labelledby="approval-title"><div className="my-auto w-full max-w-2xl rounded-[26px] border border-white/10 bg-[#151619] p-5 shadow-2xl sm:p-6"><div className="flex items-start justify-between gap-4"><div><p className="text-xs font-semibold uppercase tracking-[0.14em] text-[#ffbd78]">Approval required</p><h2 id="approval-title" className="mt-1 oa-wrap-anywhere text-xl font-semibold">{action.title}</h2><p className="mt-2 text-sm text-[#82909c]">This preview is locked to the exact tool and values below for two minutes.</p></div><button onClick={onCancel} className="rounded-full border border-white/10 px-3 py-1.5 text-sm text-[#82909c]">Close</button></div><dl className="mt-5 max-h-[40vh] space-y-2 overflow-y-auto rounded-2xl bg-black/20 p-4">{compactArgs(action.args).map(({ key, value }) => <div key={key} className="grid grid-cols-[minmax(84px,120px)_minmax(0,1fr)] gap-3 text-sm max-sm:grid-cols-1 max-sm:gap-0.5"><dt className="oa-wrap-anywhere text-[#667480]">{key}</dt><dd className="oa-wrap-anywhere text-[#d5dde3]">{value}</dd></div>)}</dl>{action.destructive ? <p className="mt-4 rounded-xl border border-[#ff806d]/25 bg-[#ff806d]/[0.06] px-4 py-3 text-sm text-[#ff9b8c]">This destructive action always needs this on-screen tap. Voice confirmation cannot approve it.</p> : <p className="mt-4 text-sm text-[#82909c]">You may tap Approve or say “confirm” while this exact preview is open.</p>}<div className="mt-6 flex justify-end gap-3 max-sm:flex-col-reverse"><button onClick={onCancel} className="rounded-xl border border-white/10 px-4 py-2.5 text-sm transition hover:border-white/25">Cancel</button><button onClick={onApprove} className={`rounded-xl px-5 py-2.5 text-sm font-semibold ${action.destructive ? 'bg-[#ff806d] text-[#230704]' : 'bg-[#D8B45A] text-[#120f08]'}`}>Approve exact change</button></div></div></div>;
}
