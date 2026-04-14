import { memo, useMemo, useState } from "react";
import type {
  ActiveWorkItem,
  ActiveWorkState,
  ActiveWorkSubagent,
  ProviderTone,
} from "../types";
import { ActivityIcon } from "./ActivityIcon";
import { ChevronIcon } from "./ChevronIcon";

interface Props {
  state: ActiveWorkState;
  providerTone?: ProviderTone;
}

function normalizeKind(kind?: string): string | undefined {
  if (kind === "collabAgentToolCall") {
    return "subagent";
  }
  return kind;
}

function statusClass(status: ActiveWorkItem["status"] | ActiveWorkSubagent["status"]) {
  return status === "completed"
    ? "status-completed"
    : status === "failed"
      ? "status-failed"
      : "status-running";
}

function dedupeByID<T extends { id: string }>(items: T[]): T[] {
  const seen = new Set<string>();
  const unique: T[] = [];

  for (const item of items) {
    if (seen.has(item.id)) {
      continue;
    }
    seen.add(item.id);
    unique.push(item);
  }

  return unique;
}

function pluralize(count: number, singular: string, plural = `${singular}s`) {
  return `${count} ${count === 1 ? singular : plural}`;
}

function countKinds(
  items: ActiveWorkItem[],
  subagents: ActiveWorkSubagent[]
): Record<string, number> {
  const counts: Record<string, number> = {};

  for (const item of items) {
    const kind = normalizeKind(item.kind) || "tool";
    counts[kind] = (counts[kind] || 0) + 1;
  }

  if (subagents.length > 0) {
    counts.subagent = (counts.subagent || 0) + subagents.length;
  }

  return counts;
}

function buildSummaryFragments(counts: Record<string, number>): string[] {
  const fragments: string[] = [];

  if (counts.fileChange) {
    fragments.push(pluralize(counts.fileChange, "file"));
  }
  if (counts.webSearch) {
    fragments.push(pluralize(counts.webSearch, "search", "searches"));
  }
  if (counts.commandExecution) {
    fragments.push(pluralize(counts.commandExecution, "command"));
  }
  if (counts.browserAutomation) {
    fragments.push(pluralize(counts.browserAutomation, "browser step"));
  }

  const genericToolCount =
    (counts.dynamicToolCall || 0) + (counts.mcpToolCall || 0) + (counts.tool || 0);
  if (genericToolCount > 0) {
    fragments.push(pluralize(genericToolCount, "tool"));
  }
  if (counts.subagent) {
    fragments.push(pluralize(counts.subagent, "sub-agent"));
  }

  return fragments;
}

function buildActiveWorkHeadline(
  state: ActiveWorkState,
  activeCalls: ActiveWorkItem[],
  recentCalls: ActiveWorkItem[],
  subagents: ActiveWorkSubagent[]
): string {
  const allCalls = dedupeByID([...activeCalls, ...recentCalls]);
  const counts = countKinds(allCalls, subagents);
  const fragments = buildSummaryFragments(counts).slice(0, 3);
  const hasRunningWork =
    activeCalls.some((item) => item.status === "running") ||
    subagents.some((agent) => agent.status === "running");
  const normalizedTitle = state.title.trim();

  if (hasRunningWork) {
    if (!fragments.length) {
      return normalizedTitle || "Working";
    }

    const leading = normalizedTitle && normalizedTitle.toLowerCase() !== "working"
      ? normalizedTitle
      : "Working";
    return `${leading} · ${fragments.join(", ")}`;
  }

  if (!fragments.length) {
    return state.detail?.trim() || normalizedTitle || "Recent activity";
  }

  return `Explored ${fragments.join(", ")}`;
}

function ToolCallRow({ item }: { item: ActiveWorkItem }) {
  const itemStatusClass = statusClass(item.status);

  return (
    <div className="active-work-item">
      <div className="active-work-item-icon">
        <ActivityIcon kind={normalizeKind(item.kind)} status={item.status} />
      </div>
      <div className="active-work-item-copy">
        <span className="active-work-item-title">{item.title}</span>
        {item.detail && <span className="active-work-item-detail">{item.detail}</span>}
      </div>
      {item.statusLabel && (
        <span className={`active-work-item-status ${itemStatusClass}`}>
          {item.statusLabel}
        </span>
      )}
    </div>
  );
}

function SubagentRow({ agent }: { agent: ActiveWorkSubagent }) {
  const agentStatusClass = statusClass(agent.status);

  return (
    <div className="active-work-item">
      <div className="active-work-item-icon">
        <ActivityIcon kind="subagent" status={agent.status} />
      </div>
      <div className="active-work-item-copy">
        <span className="active-work-item-title">
          {agent.name}
          {agent.role && <span className="active-work-item-role"> · {agent.role}</span>}
        </span>
        {agent.detail && <span className="active-work-item-detail">{agent.detail}</span>}
      </div>
      {agent.statusLabel && (
        <span className={`active-work-item-status ${agentStatusClass}`}>
          {agent.statusLabel}
        </span>
      )}
    </div>
  );
}

function ActiveWorkCardInner({ state, providerTone = "default" }: Props) {
  const [expanded, setExpanded] = useState(false);
  const activeCalls = state.activeCalls || [];
  const recentCalls = state.recentCalls || [];
  const subagents = state.subagents || [];
  const hasRunningWork =
    activeCalls.some((item) => item.status === "running") ||
    subagents.some((agent) => agent.status === "running");
  const canExpand =
    activeCalls.length > 0 || recentCalls.length > 0 || subagents.length > 0;
  const headline = useMemo(
    () => buildActiveWorkHeadline(state, activeCalls, recentCalls, subagents),
    [state, activeCalls, recentCalls, subagents]
  );
  const shouldAnimateRunning = hasRunningWork;

  const summaryToggle = (
    <button
      type="button"
      className={`active-work-summary-toggle${shouldAnimateRunning ? " activity-card-running" : ""}`}
      onClick={() => {
        if (!canExpand) {
          return;
        }
        setExpanded((current) => !current);
      }}
      aria-expanded={canExpand ? expanded : undefined}
      disabled={!canExpand}
    >
      {canExpand ? (
        <ChevronIcon expanded={expanded} className="active-work-summary-chevron" />
      ) : (
        <span className="active-work-summary-dot" aria-hidden="true" />
      )}
      <span
        className={`active-work-summary-text${shouldAnimateRunning ? " active-work-summary-text--live" : ""}`}
        data-provider={providerTone}
      >
        {headline}
      </span>
    </button>
  );

  return (
    <div className="message-row active-work-row">
      <div className="active-work-shell">
        {summaryToggle}

        {expanded && canExpand && (
          <div
            className={`active-work-card${shouldAnimateRunning ? " activity-card-running" : ""}`}
            data-provider={providerTone}
          >
            <div className="active-work-header">
              <span className="active-work-eyebrow">
                {hasRunningWork ? "Working" : "Recent"}
              </span>
              <span className="active-work-title" data-provider={providerTone}>
                {hasRunningWork ? state.title : headline}
              </span>
              {state.detail && <span className="active-work-summary">{state.detail}</span>}
            </div>

            {activeCalls.length > 0 && (
              <div className="active-work-section">
                <span className="active-work-section-title">Running</span>
                <div className="active-work-list">
                  {activeCalls.map((item) => (
                    <ToolCallRow key={item.id} item={item} />
                  ))}
                </div>
              </div>
            )}

            {subagents.length > 0 && (
              <div className="active-work-section">
                <span className="active-work-section-title">
                  {subagents.length === 1 ? "Agent" : "Agents"}
                </span>
                <div className="active-work-list">
                  {subagents.map((agent) => (
                    <SubagentRow key={agent.id} agent={agent} />
                  ))}
                </div>
              </div>
            )}

            {recentCalls.length > 0 && (
              <div className="active-work-section">
                <span className="active-work-section-title">Recent</span>
                <div className="active-work-list">
                  {recentCalls.map((item) => (
                    <ToolCallRow key={item.id} item={item} />
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

export const ActiveWorkCard = memo(ActiveWorkCardInner);
