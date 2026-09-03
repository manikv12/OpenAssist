'use client';

import { useMemo, useState } from 'react';
import type { WorkspaceToolName } from '../../lib/tool-registry';

type JsonRecord = Record<string, unknown>;
type WorkTab = 'capture' | 'projects' | 'knowledge' | 'agents' | 'sources';

const OWNER_AGENT_ID = 'openassist.owner.orchestrator';

type SecondBrainWorkspaceProps = {
  source: unknown;
  loading: boolean;
  warning: string | null;
  onRefresh: () => void;
  onInvoke: (name: WorkspaceToolName, args?: Record<string, unknown>) => Promise<unknown>;
};

const TABS: Array<{ id: WorkTab; label: string; description: string }> = [
  { id: 'capture', label: 'Capture', description: 'Put a thought in the right backlog.' },
  { id: 'projects', label: 'Projects', description: 'Plans, research, decisions, and work.' },
  { id: 'knowledge', label: 'Knowledge', description: 'Search projects, work, and memory.' },
  { id: 'agents', label: 'Agent work', description: 'Bounded analysis runs and real blockers.' },
  { id: 'sources', label: 'Memory sources', description: 'Codex and Claude memory sync.' },
];

function objectValue(value: unknown): JsonRecord {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as JsonRecord : {};
}

function arrayValue(value: unknown): JsonRecord[] {
  return Array.isArray(value) ? value.filter((item): item is JsonRecord => Boolean(item) && typeof item === 'object' && !Array.isArray(item)) : [];
}

function textValue(record: JsonRecord, keys: string[], fallback = ''): string {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
    if (typeof value === 'number') return String(value);
  }
  return fallback;
}

function numberValue(record: JsonRecord, keys: string[], fallback = 0): number {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'number' && Number.isFinite(value)) return value;
  }
  return fallback;
}

function humanTime(value: unknown): string {
  if (typeof value !== 'string' && typeof value !== 'number') return 'Not yet';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 80);
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(date);
}

function statusTone(status: string): string {
  if (/blocked|failed|needs_user|needs you|stale/i.test(status)) return 'border-danger/25 bg-danger/[0.07] text-danger-strong';
  if (/running|claimed|working|syncing/i.test(status)) return 'border-accent/25 bg-accent/[0.08] text-accent-strong';
  if (/complete|ready|synced|active/i.test(status)) return 'border-success/25 bg-success/[0.08] text-success-strong';
  return 'border-hairline-strong bg-wash text-text-2';
}

function StatusPill({ value }: { value: string }) {
  return <span className={`inline-flex rounded-full border px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.1em] ${statusTone(value)}`}>{value.replaceAll('_', ' ')}</span>;
}

function SectionEmpty({ title, detail }: { title: string; detail: string }) {
  return <div className="rounded-2xl border border-dashed border-hairline-strong bg-wash/60 px-5 py-8 text-center"><p className="text-sm font-medium text-ink">{title}</p><p className="mt-2 text-xs leading-5 text-text-3">{detail}</p></div>;
}

function dashboardData(source: unknown) {
  const root = objectValue(source);
  const assignments = arrayValue(root.assignments);
  const runs = arrayValue(root.runs ?? root.agentRuns);
  return {
    projects: arrayValue(root.projects ?? root.projectRecords ?? root.results),
    workItems: arrayValue(root.workItems ?? root.items ?? root.backlog),
    runs: [
      ...assignments.filter((assignment) => /queued|blocked/i.test(textValue(assignment, ['status'], ''))),
      ...runs,
    ],
    sources: arrayValue(root.memorySources ?? root.sources ?? root.syncSources),
    taskDestination: objectValue(root.taskDestination),
    notice: textValue(root, ['notice']),
  };
}

function knowledgeRows(source: unknown): JsonRecord[] {
  const root = objectValue(source);
  const direct = arrayValue(root.results ?? root.hits ?? root.matches ?? root.items);
  if (direct.length) return direct;
  return [
    ...arrayValue(root.projects).map((item) => ({ ...item, _kind: 'project' })),
    ...arrayValue(root.workItems).map((item) => ({ ...item, _kind: 'work_item' })),
    ...arrayValue(root.memory ?? root.memories ?? root.memoryResults).map((item) => ({ ...item, _kind: 'memory' })),
  ];
}

function sourcePointer(record: JsonRecord): string {
  const direct = record.sourcePointer ?? record.source ?? record.pointer;
  if (typeof direct === 'string' && direct.trim()) return direct.trim().slice(0, 500);
  const nested = objectValue(direct);
  const parts = [
    textValue(nested, ['label', 'name', 'fileName', 'path', 'uri']),
    textValue(nested, ['projectId', 'workItemId', 'sourceId', 'fileId', 'driveFileId']),
  ].filter(Boolean);
  if (parts.length) return parts.join(' · ');
  return textValue(record, ['driveUrl', 'path', 'uri', 'fileName', 'projectId', 'workItemId', 'sourceId', 'driveFileId', 'fileId'], 'Source pointer unavailable');
}

export function SecondBrainWorkspace({ source, loading, warning, onRefresh, onInvoke }: SecondBrainWorkspaceProps) {
  const [tab, setTab] = useState<WorkTab>('capture');
  const [selectedProjectId, setSelectedProjectId] = useState('');
  const [saving, setSaving] = useState(false);
  const [knowledgeLoading, setKnowledgeLoading] = useState(false);
  const [knowledgeResult, setKnowledgeResult] = useState<unknown>(null);
  const [localMessage, setLocalMessage] = useState('');
  const data = useMemo(() => dashboardData(source), [source]);
  const selectedProject = data.projects.find((project) => textValue(project, ['projectId', 'id']) === selectedProjectId) ?? data.projects[0];
  const effectiveProjectId = selectedProjectId || (selectedProject ? textValue(selectedProject, ['projectId', 'id']) : '');

  const runTool = async (name: WorkspaceToolName, args: Record<string, unknown>) => {
    setSaving(true);
    setLocalMessage('');
    try {
      const result = await onInvoke(name, args);
      const status = textValue(objectValue(result), ['status'], 'ready');
      setLocalMessage(status === 'approval_required' ? 'Review the exact change in the approval panel.' : 'Saved. The workspace is refreshing.');
    } catch (error) {
      setLocalMessage(error instanceof Error ? error.message : 'The request could not be completed.');
    } finally {
      setSaving(false);
    }
  };

  const searchKnowledge = async (args: Record<string, unknown>) => {
    setKnowledgeLoading(true);
    setLocalMessage('');
    try {
      setKnowledgeResult(await onInvoke('workspace_search_second_brain', args));
    } catch (error) {
      setLocalMessage(error instanceof Error ? error.message : 'Knowledge search could not be completed.');
    } finally {
      setKnowledgeLoading(false);
    }
  };

  return (
    <div className="space-y-5" data-second-brain-workspace>
      <section className="overflow-hidden rounded-2xl border border-hairline bg-wash/60">
        <div className="flex flex-wrap items-start justify-between gap-4 px-5 py-4 sm:px-6">
          <div>
            <div className="flex items-center gap-2"><span className="h-2 w-2 rounded-full bg-success shadow-[0_0_14px_rgba(89,201,155,0.55)]" /><p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-success-strong">Autonomy-first workspace</p></div>
            <h2 className="mt-2 text-lg font-semibold tracking-[-0.02em] text-ink">Projects, knowledge, and agent work</h2>
          </div>
          <button type="button" onClick={onRefresh} disabled={loading} className="rounded-xl border border-hairline-strong px-3.5 py-2 text-xs font-medium text-text-2 transition hover:border-brand/35 hover:text-ink disabled:opacity-50">{loading ? 'Refreshing…' : 'Refresh'}</button>
        </div>
        <div className="grid border-t border-hairline sm:grid-cols-5">
          {TABS.map((item) => <button key={item.id} type="button" title={item.description} onClick={() => setTab(item.id)} aria-pressed={tab === item.id} className={`border-b border-hairline px-4 py-3 text-left transition last:border-b-0 sm:border-b-0 sm:border-r sm:last:border-r-0 ${tab === item.id ? 'bg-brand/[0.08]' : 'hover:bg-wash/60'}`}><span className={`block text-xs font-semibold ${tab === item.id ? 'text-ink' : 'text-text-2'}`}>{item.label}</span></button>)}
        </div>
      </section>

      {warning && <div role="status" className="rounded-xl border border-danger/20 bg-danger/[0.045] px-4 py-3 text-xs leading-5 text-danger-strong">{warning}</div>}
      {data.notice && <div className="rounded-xl border border-hairline bg-wash/60 px-4 py-3 text-xs leading-5 text-text-3">{data.notice}</div>}
      {localMessage && <div role="status" className="rounded-xl border border-brand/20 bg-brand/[0.05] px-4 py-3 text-xs leading-5 text-brand-strong">{localMessage}</div>}

      {tab === 'capture' && <CapturePanel projects={data.projects} workItems={data.workItems} saving={saving} projectId={selectedProjectId} onProject={setSelectedProjectId} onCapture={(args) => runTool('workspace_capture_work_item', args)} onCreateProject={(args) => runTool('workspace_create_project', args)} onOrganize={(args) => runTool('workspace_organize_inbox_item', args)} />}
      {tab === 'projects' && <ProjectsPanel projects={data.projects} workItems={data.workItems} taskDestination={data.taskDestination} selectedId={effectiveProjectId} saving={saving} onSelect={setSelectedProjectId} onAssign={(args) => runTool('workspace_assign_work_item', args)} onPromote={(args) => runTool('workspace_promote_work_item_to_task', args)} />}
      {tab === 'knowledge' && <KnowledgePanel result={knowledgeResult} loading={knowledgeLoading} onSearch={searchKnowledge} />}
      {tab === 'agents' && <AgentRunsPanel runs={data.runs} onResume={(args) => runTool('workspace_resume_agent_work', args)} />}
      {tab === 'sources' && <MemorySourcesPanel sources={data.sources} />}
    </div>
  );
}

function CapturePanel({ projects, workItems, saving, projectId, onProject, onCapture, onCreateProject, onOrganize }: { projects: JsonRecord[]; workItems: JsonRecord[]; saving: boolean; projectId: string; onProject: (id: string) => void; onCapture: (args: Record<string, unknown>) => void; onCreateProject: (args: Record<string, unknown>) => void; onOrganize: (args: Record<string, unknown>) => void }) {
  const [creatingProject, setCreatingProject] = useState(false);
  const inboxItems = workItems.filter((item) => textValue(item, ['stage', 'status']) === 'inbox' && !textValue(item, ['projectId']));
  return <div className="space-y-5"><div className="grid gap-5 xl:grid-cols-[minmax(0,1.35fr)_minmax(280px,.65fr)]">
    <form onSubmit={(event) => { event.preventDefault(); const form = event.currentTarget; const data = new FormData(form); const selectedProject = String(data.get('projectId') ?? '').trim(); onCapture({ ...(selectedProject ? { projectId: selectedProject } : {}), title: String(data.get('title') ?? ''), details: String(data.get('details') ?? ''), priority: String(data.get('priority') ?? 'normal'), stage: selectedProject ? 'backlog' : 'inbox' }); form.reset(); }} className="rounded-[22px] border border-hairline bg-wash/60 p-5 sm:p-6">
      <div className="flex items-start justify-between gap-3"><div><p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">Quick capture</p><h3 className="mt-1 text-base font-semibold">Add it now. Organize it once.</h3></div><span className="rounded-full border border-hairline-strong px-2.5 py-1 text-[10px] text-text-3">Drive Markdown</span></div>
      <div className="mt-5 space-y-4">
        <label className="block"><span className="mb-2 block text-xs font-medium text-text-2">What do you want to remember or do?</span><input name="title" required maxLength={240} autoFocus placeholder="Research a local-first voice assistant for the salon" className="w-full rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm outline-none transition placeholder:text-text-4 focus:border-brand/50 focus:ring-2 focus:ring-[#E0BC63]/10" /></label>
        <label className="block"><span className="mb-2 block text-xs font-medium text-text-2">Useful context</span><textarea name="details" maxLength={12_000} rows={6} placeholder="Links, constraints, decisions, and what a useful result looks like…" className="w-full resize-y rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm leading-6 outline-none transition placeholder:text-text-4 focus:border-brand/50 focus:ring-2 focus:ring-[#E0BC63]/10" /></label>
        <div className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_150px]">
          <label><span className="mb-2 block text-xs font-medium text-text-2">Project</span><select name="projectId" value={projectId} onChange={(event) => onProject(event.target.value)} className="w-full rounded-xl border border-hairline-strong bg-surface px-3 py-3 text-sm outline-none focus:border-brand/50"><option value="">Inbox — organize later</option>{projects.map((project) => { const id = textValue(project, ['projectId', 'id']); return <option key={id} value={id}>{textValue(project, ['name', 'title'], 'Untitled project')}</option>; })}</select></label>
          <label><span className="mb-2 block text-xs font-medium text-text-2">Priority</span><select name="priority" defaultValue="normal" className="w-full rounded-xl border border-hairline-strong bg-surface px-3 py-3 text-sm outline-none focus:border-brand/50"><option value="low">Low</option><option value="normal">Normal</option><option value="high">High</option><option value="urgent">Urgent</option></select></label>
        </div>
      </div>
      <div className="mt-5 flex justify-end"><button type="submit" disabled={saving} className="rounded-xl bg-brand px-5 py-2.5 text-sm font-semibold text-brand-ink transition hover:bg-brand disabled:cursor-not-allowed disabled:opacity-45">Save capture</button></div>
    </form>

    <div className="rounded-[22px] border border-hairline bg-wash/60 p-5 sm:p-6"><p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-accent-strong">Projects</p><h3 className="mt-1 text-base font-semibold">Related work</h3>{!creatingProject ? <button type="button" onClick={() => setCreatingProject(true)} className="mt-5 w-full rounded-xl border border-brand/25 bg-brand/[0.06] px-4 py-2.5 text-sm font-medium text-brand-strong transition hover:border-brand/50">Create project</button> : <form onSubmit={(event) => { event.preventDefault(); const data = new FormData(event.currentTarget); onCreateProject({ name: String(data.get('name') ?? ''), purpose: String(data.get('purpose') ?? ''), autonomy: 'autonomous', externalActionsAllowed: false, maxSpendCents: 0 }); setCreatingProject(false); }} className="mt-5 space-y-3"><input name="name" required maxLength={160} placeholder="Project name" className="w-full rounded-xl border border-hairline-strong bg-field px-3 py-2.5 text-sm outline-none focus:border-brand/50" /><textarea name="purpose" maxLength={2_000} rows={4} placeholder="What this project is trying to achieve" className="w-full resize-y rounded-xl border border-hairline-strong bg-field px-3 py-2.5 text-sm outline-none focus:border-brand/50" /><div className="flex gap-2"><button type="button" onClick={() => setCreatingProject(false)} className="flex-1 rounded-xl border border-hairline-strong px-3 py-2 text-xs text-text-2">Cancel</button><button type="submit" disabled={saving} className="flex-1 rounded-xl bg-brand px-3 py-2 text-xs font-semibold text-brand-ink">Review</button></div></form>}<div className="mt-5 space-y-2 border-t border-hairline pt-4">{projects.slice(0, 4).map((project) => <div key={textValue(project, ['projectId', 'id'])} className="flex items-center justify-between gap-3 rounded-xl bg-field px-3 py-2.5"><div className="min-w-0"><p className="truncate text-xs font-medium text-ink">{textValue(project, ['name', 'title'], 'Untitled project')}</p><p className="mt-0.5 text-[10px] text-text-4">{textValue(project, ['autonomy', 'autonomyMode'], 'autonomous')}</p></div><span className="text-[10px] text-brand">{numberValue(project, ['openWorkItemCount', 'openItems'], 0)} open</span></div>)}</div></div>
  </div>{inboxItems.length > 0 && <section className="rounded-[22px] border border-hairline bg-wash/60 p-5 sm:p-6"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">Inbox</p><h3 className="mt-1 text-base font-semibold">Organize inbox</h3></div><span className="rounded-full border border-hairline-strong px-2.5 py-1 text-[10px] text-text-3">{inboxItems.length} waiting</span></div><div className="mt-4 space-y-2">{inboxItems.map((item) => <InboxOrganizerRow key={textValue(item, ['workItemId', 'id'])} item={item} projects={projects} saving={saving} onOrganize={onOrganize} />)}</div></section>}</div>;
}

function InboxOrganizerRow({ item, projects, saving, onOrganize }: { item: JsonRecord; projects: JsonRecord[]; saving: boolean; onOrganize: (args: Record<string, unknown>) => void }) {
  const [destination, setDestination] = useState('');
  const itemAccount = textValue(item, ['accountId']);
  const eligibleProjects = projects.filter((project) => {
    const projectAccount = textValue(project, ['accountId']);
    return !itemAccount || !projectAccount || itemAccount === projectAccount;
  });
  const itemId = textValue(item, ['workItemId', 'id']);
  return <div className="grid gap-3 rounded-2xl border border-hairline bg-field px-4 py-3 sm:grid-cols-[minmax(0,1fr)_minmax(190px,280px)_auto] sm:items-center"><div className="min-w-0"><p className="truncate text-sm font-medium text-ink">{textValue(item, ['title', 'name'], 'Untitled Inbox item')}</p><p className="mt-1 text-[11px] text-text-4">{textValue(item, ['priority'], 'normal')} priority · captured {humanTime(item.createdAt ?? item.updatedAt)}</p></div><select aria-label={`Project for ${textValue(item, ['title', 'name'], 'Inbox item')}`} value={destination} onChange={(event) => setDestination(event.target.value)} disabled={!eligibleProjects.length || saving} className="w-full rounded-xl border border-hairline-strong bg-surface px-3 py-2.5 text-xs outline-none transition focus:border-brand/50 disabled:opacity-45"><option value="">{eligibleProjects.length ? 'Choose a project' : 'No project in this Drive account'}</option>{eligibleProjects.map((project) => { const id = textValue(project, ['projectId', 'id']); return <option key={id} value={id}>{textValue(project, ['name', 'title'], 'Untitled project')}</option>; })}</select><button type="button" disabled={!destination || saving} onClick={() => onOrganize({ workItemId: itemId, projectId: destination, stage: 'backlog' })} className="rounded-xl border border-brand/25 bg-brand/[0.055] px-4 py-2.5 text-xs font-medium text-brand-strong transition hover:border-brand/50 disabled:cursor-not-allowed disabled:opacity-35">Review move</button></div>;
}

function KnowledgePanel({ result, loading, onSearch }: { result: unknown; loading: boolean; onSearch: (args: Record<string, unknown>) => void }) {
  const rows = knowledgeRows(result);
  const root = objectValue(result);
  const total = numberValue(root, ['total', 'totalCount'], rows.length);
  return <section className="overflow-hidden rounded-[22px] border border-hairline bg-wash/60" data-untrusted-knowledge>
    <form onSubmit={(event) => { event.preventDefault(); const data = new FormData(event.currentTarget); const sourceKinds = data.getAll('sourceKinds').map(String); onSearch({ query: String(data.get('query') ?? '').trim(), ...(sourceKinds.length ? { sourceKinds } : {}), limit: 8, maxScanned: 16 }); }} className="border-b border-hairline p-5 sm:p-6">
      <div className="flex flex-wrap items-start justify-between gap-4"><div><p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-accent-strong">Private knowledge</p><h3 className="mt-1 text-lg font-semibold tracking-[-0.02em]">Find context across your work</h3></div><span className="rounded-full border border-accent/20 bg-accent/[0.06] px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.1em] text-accent-strong">Owner only</span></div>
      <div className="mt-5 grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end"><label><span className="mb-2 block text-xs font-medium text-text-2">Search knowledge</span><input name="query" required minLength={2} maxLength={200} placeholder="What did we decide about the launch?" className="w-full rounded-xl border border-hairline-strong bg-field px-4 py-3 text-sm outline-none transition placeholder:text-text-4 focus:border-accent/50 focus:ring-2 focus:ring-[#8A7DFF]/10" /></label><button type="submit" disabled={loading} className="rounded-xl bg-accent px-5 py-3 text-sm font-semibold text-ink transition hover:bg-accent disabled:cursor-not-allowed disabled:opacity-45">{loading ? 'Searching…' : 'Search'}</button></div>
      <fieldset className="mt-4 flex flex-wrap gap-x-5 gap-y-2"><legend className="sr-only">Knowledge kinds</legend>{[['project', 'Projects'], ['work_item', 'Work items'], ['memory', 'Memory']].map(([value, label]) => <label key={value} className="flex items-center gap-2 text-xs text-text-2"><input type="checkbox" name="sourceKinds" value={value} defaultChecked className="accent-[#8A7DFF]" />{label}</label>)}</fieldset>
    </form>
    <div className="p-5 sm:p-6">{result === null ? <SectionEmpty title="Search your Second Brain" detail="Projects, work items, and approved memory." /> : rows.length ? <><div className="mb-3 flex items-center justify-between gap-3"><p className="text-xs text-text-3">{total} result{total === 1 ? '' : 's'}</p><p className="text-[10px] font-semibold uppercase tracking-[0.1em] text-danger-strong">Untrusted excerpts</p></div><div className="divide-y divide-hairline">{rows.map((row, index) => { const kind = textValue(row, ['sourceKind', 'kind', 'type', '_kind'], 'knowledge').replaceAll('_', ' '); const pointer = sourcePointer(row); return <article key={`${pointer}:${index}`} className="py-4 first:pt-0 last:pb-0"><div className="flex flex-wrap items-start justify-between gap-2"><div className="min-w-0"><p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-accent-strong">{kind}</p><h4 className="mt-1 text-sm font-semibold text-ink">{textValue(row, ['title', 'name', 'heading', 'sourceId'], 'Knowledge result')}</h4></div><span className="rounded-full border border-danger/20 bg-danger/[0.045] px-2 py-1 text-[9px] font-semibold uppercase tracking-[0.08em] text-danger-strong">Reference only</span></div><p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-text-2">{textValue(row, ['excerpt', 'snippet', 'summary', 'text', 'content'], 'No excerpt returned.')}</p><p className="mt-2 break-all font-mono text-[10px] leading-4 text-text-4">Source · {pointer}</p></article>; })}</div></> : <SectionEmpty title="No matching knowledge" detail="Try fewer words or include more knowledge kinds." />}</div>
  </section>;
}

function ProjectsPanel({ projects, workItems, taskDestination, selectedId, saving, onSelect, onAssign, onPromote }: { projects: JsonRecord[]; workItems: JsonRecord[]; taskDestination: JsonRecord; selectedId: string; saving: boolean; onSelect: (id: string) => void; onAssign: (args: Record<string, unknown>) => void; onPromote: (args: Record<string, unknown>) => void }) {
  const [selectedTaskListId, setSelectedTaskListId] = useState('');
  const selected = projects.find((project) => textValue(project, ['projectId', 'id']) === selectedId) ?? projects[0];
  if (!selected) return <SectionEmpty title="No projects yet" detail="Use Capture to create the first project, then add research, decisions, and work items." />;
  const id = textValue(selected, ['projectId', 'id']);
  const items = workItems.filter((item) => textValue(item, ['projectId']) === id);
  const autonomy = textValue(selected, ['autonomy', 'autonomyMode'], 'autonomous');
  const taskLists = arrayValue(taskDestination.taskLists);
  const effectiveTaskListId = selectedTaskListId || textValue(taskLists[0] ?? {}, ['id']);
  const taskAccount = textValue(taskDestination, ['account']);
  const taskError = textValue(taskDestination, ['error']);
  return <div className="grid gap-5 xl:grid-cols-[300px_minmax(0,1fr)]"><div className="space-y-2">{projects.map((project) => { const projectId = textValue(project, ['projectId', 'id']); const active = projectId === id; return <button key={projectId} type="button" onClick={() => onSelect(projectId)} className={`w-full rounded-2xl border px-4 py-3.5 text-left transition ${active ? 'border-brand/30 bg-brand/[0.07]' : 'border-hairline bg-wash/60 hover:border-hairline-strong'}`}><div className="flex items-center justify-between gap-3"><p className="truncate text-sm font-semibold text-ink">{textValue(project, ['name', 'title'], 'Untitled project')}</p><span className="text-[10px] text-brand">{numberValue(project, ['openWorkItemCount', 'openItems'], 0)}</span></div><p className="mt-1 line-clamp-2 text-xs leading-5 text-text-3">{textValue(project, ['purpose', 'summary'], 'No purpose added yet.')}</p></button>; })}</div><section className="rounded-[22px] border border-hairline bg-wash/60 p-5 sm:p-6"><div className="flex flex-wrap items-start justify-between gap-4"><div><p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-brand">Project</p><h3 className="mt-1 text-xl font-semibold tracking-[-0.025em]">{textValue(selected, ['name', 'title'], 'Untitled project')}</h3><p className="mt-2 max-w-2xl text-sm leading-6 text-text-3">{textValue(selected, ['purpose', 'summary'], 'No purpose added yet.')}</p></div><StatusPill value={autonomy} /></div><div className="mt-5 grid gap-3 sm:grid-cols-3"><PolicyMetric label="Internal work" value={autonomy === 'paused' ? 'Paused' : 'Allowed'} /><PolicyMetric label="External actions" value={Boolean(selected.externalActionsAllowed) ? 'Allowed' : 'Ask first'} /><PolicyMetric label="Spend cap" value={numberValue(selected, ['maxSpendCents'], 0) ? `$${(numberValue(selected, ['maxSpendCents']) / 100).toFixed(2)}` : 'No spend'} /></div><div className="mt-6 border-t border-hairline pt-5"><div className="flex flex-wrap items-end justify-between gap-3"><div><h4 className="text-sm font-semibold">Backlog and active work</h4><p className="mt-1 text-[11px] text-text-4">{items.length} items</p></div><label className="min-w-[220px]"><span className="mb-1.5 block text-[10px] font-semibold uppercase tracking-[0.1em] text-text-4">Google Tasks destination</span><select aria-label="Google Tasks destination" value={effectiveTaskListId} onChange={(event) => setSelectedTaskListId(event.target.value)} disabled={!taskLists.length} className="w-full rounded-xl border border-hairline-strong bg-surface px-3 py-2 text-xs outline-none focus:border-accent/50 disabled:opacity-45"><option value="">No list available</option>{taskLists.map((list) => <option key={textValue(list, ['id'])} value={textValue(list, ['id'])}>{textValue(list, ['title'], 'Untitled list')}</option>)}</select>{taskAccount && <span className="mt-1 block text-[10px] text-text-4">{taskAccount}</span>}</label></div>{taskError && <p role="status" className="mt-3 rounded-xl border border-danger/20 bg-danger/[0.045] px-3 py-2 text-xs leading-5 text-danger-strong">{taskError} Adding to Google Tasks is disabled.</p>}<div className="mt-3 space-y-2">{items.length ? items.map((item) => { const itemId = textValue(item, ['workItemId', 'itemId', 'id']); const status = textValue(item, ['status', 'stage'], 'backlog'); const title = textValue(item, ['title', 'name'], 'Untitled work').slice(0, 200); const promotion = objectValue(item.taskPromotion ?? item.promotion); const promoted = Boolean(textValue(promotion, ['googleTaskId', 'id', 'status'])); return <div key={itemId} className="flex flex-wrap items-center gap-3 rounded-2xl border border-hairline bg-field px-4 py-3"><div className="min-w-0 flex-1"><p className="truncate text-sm font-medium text-ink">{title}</p><p className="mt-1 text-[11px] text-text-4">{textValue(item, ['priority'], 'normal')} priority · updated {humanTime(item.updatedAt)}</p></div><StatusPill value={status} /><div className="flex flex-wrap gap-2">{promoted ? <span className="rounded-lg border border-success/25 bg-success/[0.06] px-3 py-1.5 text-[11px] font-medium text-success-strong">In Google Tasks</span> : <button type="button" disabled={saving || !taskAccount || !effectiveTaskListId || Boolean(taskError)} onClick={() => onPromote({ workItemId: itemId, account: taskAccount, taskListId: effectiveTaskListId, title })} className="rounded-lg border border-accent/25 px-3 py-1.5 text-[11px] font-medium text-accent-strong transition hover:border-accent/50 disabled:cursor-not-allowed disabled:opacity-40">Add to Google Tasks</button>}{status === 'backlog' && <button type="button" disabled={saving} onClick={() => onAssign({ projectId: id, workItemId: itemId, agentId: OWNER_AGENT_ID, agentLabel: 'OpenAssist Agent' })} className="rounded-lg border border-brand/25 px-3 py-1.5 text-[11px] font-medium text-brand-strong transition hover:border-brand/50 disabled:opacity-40">Assign to agent</button>}</div></div>; }) : <SectionEmpty title="Backlog is clear" detail="Capture a thought or research item and it will appear here." />}</div><p className="mt-4 text-[11px] leading-5 text-text-4">Approval required before adding to Google Tasks.</p></div></section></div>;
}

function PolicyMetric({ label, value }: { label: string; value: string }) {
  return <div className="rounded-xl border border-hairline bg-field px-3.5 py-3"><p className="text-[10px] uppercase tracking-[0.12em] text-text-4">{label}</p><p className="mt-1 text-sm font-medium text-ink">{value}</p></div>;
}

function AgentRunsPanel({ runs, onResume }: { runs: JsonRecord[]; onResume: (args: Record<string, unknown>) => void }) {
  const active = runs.filter((run) => /assigned|claimed|running|needs_user/i.test(textValue(run, ['status'], '')));
  return <div className="space-y-4"><div className="grid gap-3 sm:grid-cols-3"><PolicyMetric label="Working now" value={String(active.filter((run) => /claimed|running/i.test(textValue(run, ['status'], ''))).length)} /><PolicyMetric label="Needs you" value={String(runs.filter((run) => /needs_user|blocked/i.test(textValue(run, ['status'], ''))).length)} /><PolicyMetric label="Queued" value={String(runs.filter((run) => /queued/i.test(textValue(run, ['status'], ''))).length)} /></div>{runs.length ? <div className="space-y-3">{runs.map((run) => { const status = textValue(run, ['status'], 'queued'); const artifacts = arrayValue(run.artifacts); const workItemId = textValue(run, ['workItemId']); const agentId = textValue(run, ['agentId', 'assignedAgentId'], OWNER_AGENT_ID); return <article key={textValue(run, ['runId', 'assignmentId', 'id'])} className="rounded-[20px] border border-hairline bg-wash/60 p-5"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-accent-strong">{textValue(run, ['agentLabel', 'agentId', 'assignedAgentId'], 'OpenAssist Agent')}</p><h3 className="mt-1 text-base font-semibold">{textValue(run, ['workItemTitle', 'title'], 'Assigned project work')}</h3></div><StatusPill value={status} /></div><div className="mt-4 grid gap-3 sm:grid-cols-[minmax(0,1fr)_180px]"><div className="rounded-xl border border-hairline bg-field px-4 py-3"><p className="text-[10px] uppercase tracking-[0.12em] text-text-4">Current step</p><p className="mt-1 text-sm leading-6 text-text-2">{textValue(run, ['currentStep', 'progressSummary'], status === 'queued' ? 'Waiting for an available agent.' : 'Working through the assigned objective.')}</p></div><div className="rounded-xl border border-hairline bg-field px-4 py-3"><p className="text-[10px] uppercase tracking-[0.12em] text-text-4">Last heartbeat</p><p className="mt-1 text-sm text-text-2">{humanTime(run.lastHeartbeatAt ?? run.updatedAt)}</p></div></div>{artifacts.length > 0 && <div className="mt-4 flex flex-wrap gap-2">{artifacts.map((artifact) => <span key={textValue(artifact, ['artifactId', 'fileId', 'id'])} className="rounded-lg border border-hairline px-2.5 py-1 text-[11px] text-text-2">{textValue(artifact, ['name', 'kind'], 'Artifact')}</span>)}</div>}{/needs_user|blocked/i.test(status) && <div className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-danger/20 bg-danger/[0.05] px-4 py-3"><div><p className="text-xs font-semibold text-danger-strong">Needs you</p><p className="mt-1 text-xs leading-5 text-danger-strong">{textValue(run, ['blocker', 'blockerSummary'], 'The agent needs a credential, a material decision, or permission for an outside-world action.')}</p></div>{workItemId && <button type="button" onClick={() => onResume({ workItemId, agentId })} className="rounded-lg border border-danger/25 px-3 py-1.5 text-[11px] font-medium text-danger-strong transition hover:border-danger/50">Resolve and resume</button>}</div>}</article>; })}</div> : <SectionEmpty title="No agent runs yet" detail="Assign a backlog item to start an agent run." />}</div>;
}

function MemorySourcesPanel({ sources }: { sources: JsonRecord[] }) {
  return <div className="space-y-4"><div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-hairline bg-wash/60 px-5 py-4"><div className="flex items-center gap-3"><span className="grid h-8 w-8 shrink-0 place-items-center rounded-xl border border-accent/25 bg-accent/[0.08] text-sm text-accent-strong">↻</span><h3 className="text-sm font-semibold">Approved memory sources</h3></div><span className="rounded-full border border-hairline-strong px-2.5 py-1 text-[10px] font-medium text-text-3">No chat history</span></div>{sources.length ? <div className="grid gap-3 lg:grid-cols-2">{sources.map((source) => { const status = textValue(source, ['status', 'syncStatus'], 'not synced'); return <article key={`${textValue(source, ['deviceId'])}:${textValue(source, ['sourceId', 'id'])}`} className="rounded-[20px] border border-hairline bg-wash/60 p-5"><div className="flex items-start justify-between gap-3"><div><p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-brand">{textValue(source, ['kind', 'sourceKind'], 'Memory')}</p><h3 className="mt-1 text-base font-semibold">{textValue(source, ['displayName', 'alias', 'deviceName'], 'This Mac')}</h3><p className="mt-1 text-xs text-text-4">{textValue(source, ['locationLabel'], 'Location not set')}</p></div><StatusPill value={status} /></div><dl className="mt-4 grid grid-cols-2 gap-3 border-t border-hairline pt-4"><div><dt className="text-[10px] uppercase tracking-[0.1em] text-text-4">Last synced</dt><dd className="mt-1 text-xs text-text-2">{humanTime(source.lastSuccessfulAt ?? source.lastSyncedAt)}</dd></div><div><dt className="text-[10px] uppercase tracking-[0.1em] text-text-4">Markdown files</dt><dd className="mt-1 text-xs text-text-2">{numberValue(source, ['fileCount', 'manifestFileCount'], 0)}</dd></div></dl><p className="mt-4 truncate font-mono text-[10px] text-text-4">{textValue(source, ['deviceId'], 'device pending')} · {textValue(source, ['sourceId', 'id'], 'source pending')}</p></article>; })}</div> : <SectionEmpty title="No memory sources yet" detail="Sync approved Codex or Claude Markdown from the desktop companion." />}</div>;
}
