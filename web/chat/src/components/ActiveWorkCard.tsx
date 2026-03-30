import { memo } from "react";
import type {
  ActiveWorkItem,
  ActiveWorkState,
  ActiveWorkSubagent,
  ProviderTone,
} from "../types";
import { ActivityIcon } from "./ActivityIcon";

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
  const activeCalls = state.activeCalls || [];
  const recentCalls = state.recentCalls || [];
  const subagents = state.subagents || [];

  return (
    <div className="message-row active-work-row">
      <div className="active-work-card activity-card-running">
        <div className="active-work-header">
          <span className="active-work-eyebrow">Working now</span>
          <span className="active-work-title" data-provider={providerTone}>
            {state.title}
          </span>
          {state.detail && <span className="active-work-summary">{state.detail}</span>}
        </div>

        {activeCalls.length > 0 && (
          <div className="active-work-section">
            <span className="active-work-section-title">Running now</span>
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
              {subagents.length === 1 ? "Sub-agent" : "Sub-agents"}
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
            <span className="active-work-section-title">Recent steps</span>
            <div className="active-work-list">
              {recentCalls.map((item) => (
                <ToolCallRow key={item.id} item={item} />
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

export const ActiveWorkCard = memo(ActiveWorkCardInner);
