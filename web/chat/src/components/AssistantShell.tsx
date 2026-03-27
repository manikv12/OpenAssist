import {
  type CSSProperties,
  forwardRef,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import type {
  AssistantAutomationJob,
  AssistantPaneID,
  AssistantShellState,
  AssistantSkillItem,
  AssistantWorkspaceLaunchTarget,
  ChatMessage,
  MessageCheckpointInfo,
  ProviderTone,
  RewindState,
  RuntimePanelState,
  TypingState,
} from "../types";
import { ChatView } from "./ChatView";
import { MarkdownContent } from "./MarkdownContent";
import { RuntimePanel } from "./RuntimePanel";

interface AssistantShellProps {
  shellState: AssistantShellState | null;
  messages: ChatMessage[];
  typing: TypingState;
  runtimePanel: RuntimePanelState | null;
  activeProviderTone: ProviderTone;
  checkpointsByMessageID: Map<string, MessageCheckpointInfo>;
  rewindState: RewindState | null;
  textScale: number;
  isPinnedToBottom: boolean;
  canLoadOlder: boolean;
  onScrollState: (pinned: boolean, scrolledUp: boolean, distanceFromTop: number) => void;
  onLoadOlder: () => void;
  onJumpToLatest: () => void;
  onSelectRuntimeBackend: (backendID: string) => void;
  onOpenRuntimeSettings: () => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}

type JobDraft = {
  id?: string;
  name: string;
  prompt: string;
  jobType: string;
  recurrence: string;
  hour: number;
  minute: number;
  weekday: number;
  intervalMinutes: number;
  preferredModelId?: string;
  reasoningEffortId?: string;
};

type SidebarContextMenuAction = {
  kind: "action";
  id: string;
  label: string;
  symbol?: string;
  destructive?: boolean;
  disabled?: boolean;
  command: string;
  payload?: Record<string, unknown>;
};

type SidebarContextMenuEntry =
  | SidebarContextMenuAction
  | {
      kind: "separator";
      id: string;
    }
  | {
      kind: "note";
      id: string;
      label: string;
    };

type SidebarContextMenuState = {
  x: number;
  y: number;
  entries: SidebarContextMenuEntry[];
};

const DEFAULT_JOB_DRAFT: JobDraft = {
  name: "",
  prompt: "",
  jobType: "general",
  recurrence: "daily",
  hour: 9,
  minute: 0,
  weekday: 2,
  intervalMinutes: 60,
};

export function AssistantShell({
  shellState,
  messages,
  typing,
  runtimePanel,
  activeProviderTone,
  checkpointsByMessageID,
  rewindState,
  textScale,
  isPinnedToBottom,
  canLoadOlder,
  onScrollState,
  onLoadOlder,
  onJumpToLatest,
  onSelectRuntimeBackend,
  onOpenRuntimeSettings,
  onDispatchCommand,
}: AssistantShellProps) {
  const [hoveredPane, setHoveredPane] = useState<AssistantPaneID | null>(null);
  const [selectedSkill, setSelectedSkill] = useState<AssistantSkillItem | null>(null);
  const [showInstructions, setShowInstructions] = useState(false);
  const [composerText, setComposerText] = useState("");
  const [selectedJobId, setSelectedJobId] = useState<string | "new" | null>(null);
  const [jobDraft, setJobDraft] = useState<JobDraft>(DEFAULT_JOB_DRAFT);
  const [isWorkspaceMenuOpen, setIsWorkspaceMenuOpen] = useState(false);
  const hoverTimeoutRef = useRef<number | null>(null);
  const workspaceMenuRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    setComposerText(shellState?.threadsPane.promptDraft ?? "");
  }, [shellState?.threadsPane.promptDraft, shellState?.threadsPane.selectedSessionId]);

  useEffect(() => {
    const jobs = shellState?.automationsPane.jobs ?? [];
    if (selectedJobId === "new") return;
    if (!jobs.length) {
      setSelectedJobId(null);
      setJobDraft(DEFAULT_JOB_DRAFT);
      return;
    }
    if (!selectedJobId || !jobs.some((job) => job.id === selectedJobId)) {
      setSelectedJobId(jobs[0].id);
    }
  }, [selectedJobId, shellState?.automationsPane.jobs]);

  useEffect(() => {
    if (selectedJobId === "new") {
      setJobDraft(DEFAULT_JOB_DRAFT);
      return;
    }
    const selectedJob = shellState?.automationsPane.jobs.find((job) => job.id === selectedJobId);
    if (!selectedJob) return;
    setJobDraft(jobToDraft(selectedJob));
  }, [selectedJobId, shellState?.automationsPane.jobs]);

  useEffect(() => {
    if (!shellState) {
      setSelectedSkill(null);
      setShowInstructions(false);
      setIsWorkspaceMenuOpen(false);
      return;
    }
    if (selectedSkill) {
      const nextSkill = shellState.skillsPane.groups
        .flatMap((group) => group.skills)
        .find((skill) => skill.name === selectedSkill.name);
      if (!nextSkill) {
        setSelectedSkill(null);
      } else if (JSON.stringify(nextSkill) !== JSON.stringify(selectedSkill)) {
        setSelectedSkill(nextSkill);
      }
    }
  }, [selectedSkill, shellState]);

  const activePane = shellState?.ui.selectedPane ?? "threads";

  useEffect(() => {
    setIsWorkspaceMenuOpen(false);
  }, [activePane, shellState?.threadsPane.selectedSessionId]);

  useEffect(() => {
    if (!isWorkspaceMenuOpen) return;

    const handlePointerDown = (event: PointerEvent) => {
      if (!workspaceMenuRef.current?.contains(event.target as Node)) {
        setIsWorkspaceMenuOpen(false);
      }
    };

    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") {
        setIsWorkspaceMenuOpen(false);
      }
    };

    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [isWorkspaceMenuOpen]);

  const workspace = (
    <div className="oa-shell__workspace">
      {renderPane({
        shellState,
        activePane,
        messages,
        typing,
        runtimePanel,
        activeProviderTone,
        checkpointsByMessageID,
        rewindState,
        textScale,
        isPinnedToBottom,
        canLoadOlder,
        composerText,
        jobDraft,
        selectedJobId,
        onScrollState,
        onLoadOlder,
        onJumpToLatest,
        onSelectRuntimeBackend,
        onOpenRuntimeSettings,
        onDispatchCommand,
        onComposerChange: setComposerText,
        onJobDraftChange: setJobDraft,
        onSelectedJobIdChange: setSelectedJobId,
        onSelectedSkillChange: setSelectedSkill,
        isWorkspaceMenuOpen,
        onWorkspaceMenuOpenChange: setIsWorkspaceMenuOpen,
        workspaceMenuRef,
        onToggleInstructions: () => setShowInstructions((value) => !value),
      })}
    </div>
  );

  return (
    <div
      className={`oa-shell ${shellState?.ui.sidebarCollapsed ? "is-sidebar-collapsed" : ""}`}
      data-active-provider={activeProviderTone}
    >
      <div className="oa-shell__backdrop" />

      <div className="oa-shell__frame">
        <Sidebar
          shellState={shellState}
          hoveredPane={hoveredPane}
          setHoveredPane={setHoveredPane}
          onDispatchCommand={onDispatchCommand}
          onSelectedSkillChange={setSelectedSkill}
        />
        {workspace}
      </div>

      {showInstructions && shellState ? (
        <ModalCard
          title="Session Instructions"
          onClose={() => setShowInstructions(false)}
          footer={
            <button
              type="button"
              className="oa-button oa-button--primary"
              onClick={() => setShowInstructions(false)}
            >
              Done
            </button>
          }
        >
          <textarea
            className="oa-textarea oa-textarea--instructions"
            value={shellState.threadsPane.sessionInstructions}
            placeholder="Optional instructions for this thread"
            onChange={(event) =>
              onDispatchCommand("updateSessionInstructions", {
                text: event.target.value,
              })
            }
          />
        </ModalCard>
      ) : null}

      {selectedSkill ? (
        <SkillDetailModal
          skill={selectedSkill}
          canAttach={shellState?.skillsPane.canAttachToThread ?? false}
          onClose={() => setSelectedSkill(null)}
          onDispatchCommand={onDispatchCommand}
        />
      ) : null}
    </div>
  );
}

function Sidebar({
  shellState,
  hoveredPane,
  setHoveredPane,
  onDispatchCommand,
  onSelectedSkillChange,
}: {
  shellState: AssistantShellState | null;
  hoveredPane: AssistantPaneID | null;
  setHoveredPane: (pane: AssistantPaneID | null) => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
  onSelectedSkillChange: (skill: AssistantSkillItem | null) => void;
}) {
  const hoverTimeoutRef = useRef<number | null>(null);
  const contextMenuRef = useRef<HTMLDivElement | null>(null);
  const [contextMenu, setContextMenu] = useState<SidebarContextMenuState | null>(null);
  const [contextMenuPosition, setContextMenuPosition] = useState<{ x: number; y: number } | null>(null);
  const sidebar = shellState?.sidebar;
  const primaryNavItems = (sidebar?.navItems ?? []).filter((item) => item.id !== "archived");
  const selectedSessions =
    shellState?.ui.selectedPane === "archived"
      ? sidebar?.archived ?? []
      : sidebar?.threads ?? [];

  useEffect(() => {
    setContextMenu(null);
    setContextMenuPosition(null);
  }, [shellState?.ui.selectedPane, shellState?.ui.sidebarCollapsed]);

  useEffect(() => {
    if (!contextMenu) return;

    const handlePointerDown = (event: PointerEvent) => {
      if (!contextMenuRef.current?.contains(event.target as Node)) {
        setContextMenu(null);
        setContextMenuPosition(null);
      }
    };

    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") {
        setContextMenu(null);
        setContextMenuPosition(null);
      }
    };

    const handleViewportChange = () => {
      setContextMenu(null);
      setContextMenuPosition(null);
    };

    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("keydown", handleKeyDown);
    document.addEventListener("scroll", handleViewportChange, true);
    window.addEventListener("resize", handleViewportChange);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("keydown", handleKeyDown);
      document.removeEventListener("scroll", handleViewportChange, true);
      window.removeEventListener("resize", handleViewportChange);
    };
  }, [contextMenu]);

  useEffect(() => {
    if (!contextMenu || !contextMenuRef.current) return;

    const rect = contextMenuRef.current.getBoundingClientRect();
    const padding = 12;
    const nextX = Math.max(
      padding,
      Math.min(contextMenu.x, window.innerWidth - rect.width - padding)
    );
    const nextY = Math.max(
      padding,
      Math.min(contextMenu.y, window.innerHeight - rect.height - padding)
    );

    if (!contextMenuPosition || contextMenuPosition.x !== nextX || contextMenuPosition.y !== nextY) {
      setContextMenuPosition({ x: nextX, y: nextY });
    }
  }, [contextMenu, contextMenuPosition]);

  const openContextMenu = (
    event: React.MouseEvent<HTMLElement>,
    entries: SidebarContextMenuEntry[]
  ) => {
    event.preventDefault();
    event.stopPropagation();
    if (!entries.length) {
      setContextMenu(null);
      setContextMenuPosition(null);
      return;
    }
    setContextMenu({
      x: event.clientX,
      y: event.clientY,
      entries,
    });
    setContextMenuPosition({
      x: event.clientX,
      y: event.clientY,
    });
  };

  const dispatchContextMenuCommand = (entry: SidebarContextMenuAction) => {
    if (entry.disabled) return;
    setContextMenu(null);
    setContextMenuPosition(null);
    onDispatchCommand(entry.command, entry.payload);
  };

  const projectSectionContextMenuEntries = (): SidebarContextMenuEntry[] => [
    {
      kind: "action",
      id: "open-folder-as-project",
      label: "Open Folder as Project",
      symbol: "folder.badge.plus",
      command: "createProjectFromFolderPrompt",
    },
    {
      kind: "action",
      id: "create-named-project",
      label: "Create Named Project",
      symbol: "square.stack.3d.up.fill",
      command: "createNamedProjectPrompt",
    },
    { kind: "separator", id: "projects-separator" },
    ...(sidebar.hiddenProjects.length
      ? sidebar.hiddenProjects.map<SidebarContextMenuEntry>((project) => ({
          kind: "action",
          id: `unhide-${project.id}`,
          label: `Unhide ${project.name}`,
          symbol: project.symbol,
          command: "unhideProject",
          payload: { projectId: project.id },
        }))
      : [
          {
            kind: "note" as const,
            id: "no-hidden-projects",
            label: "No hidden projects right now",
          },
        ]),
  ];

  const projectContextMenuEntries = (project: typeof sidebar.projects[number]): SidebarContextMenuEntry[] => {
    const entries: SidebarContextMenuEntry[] = [
      {
        kind: "action",
        id: `rename-project-${project.id}`,
        label: "Rename Project",
        symbol: "pencil",
        command: "renameProjectPrompt",
        payload: { projectId: project.id },
      },
      {
        kind: "action",
        id: `change-project-icon-${project.id}`,
        label: "Change Icon...",
        symbol: "sparkles",
        command: "changeProjectIconPrompt",
        payload: { projectId: project.id },
      },
      {
        kind: "action",
        id: `link-project-folder-${project.id}`,
        label: project.hasLinkedFolder ? "Change Folder" : "Link Folder",
        symbol: "folder",
        command: "linkProjectFolder",
        payload: { projectId: project.id },
      },
    ];

    if (project.hasLinkedFolder) {
      entries.push({
        kind: "action",
        id: `unlink-project-folder-${project.id}`,
        label: "Remove Folder Link",
        symbol: "folder.badge.minus",
        command: "removeProjectFolderLink",
        payload: { projectId: project.id },
      });
    }

    entries.push(
      { kind: "separator", id: `project-danger-separator-${project.id}` },
      {
        kind: "action",
        id: `hide-project-${project.id}`,
        label: "Hide Project",
        symbol: "eye.slash",
        command: "hideProject",
        payload: { projectId: project.id },
      },
      {
        kind: "action",
        id: `delete-project-${project.id}`,
        label: "Delete Project",
        symbol: "trash",
        destructive: true,
        command: "deleteProject",
        payload: { projectId: project.id },
      }
    );

    return entries;
  };

  const threadContextMenuEntries = (session: typeof selectedSessions[number]): SidebarContextMenuEntry[] => {
    if (session.isArchived) {
      return [
        {
          kind: "action",
          id: `unarchive-session-${session.id}`,
          label: "Unarchive Chat",
          symbol: "tray.and.arrow.up",
          command: "unarchiveSession",
          payload: { sessionId: session.id },
        },
        { kind: "separator", id: `archived-session-separator-${session.id}` },
        {
          kind: "action",
          id: `delete-session-${session.id}`,
          label: "Delete Permanently",
          symbol: "trash",
          destructive: true,
          command: "deleteSessionPermanently",
          payload: { sessionId: session.id },
        },
      ];
    }

    const entries: SidebarContextMenuEntry[] = [
      {
        kind: "action",
        id: `rename-session-${session.id}`,
        label: "Rename Chat",
        symbol: "pencil",
        command: "renameSessionPrompt",
        payload: { sessionId: session.id },
      },
    ];

    if (session.isTemporary) {
      entries.push({
        kind: "action",
        id: `promote-session-${session.id}`,
        label: "Keep as Regular Chat",
        symbol: "pin",
        command: "promoteTemporarySession",
        payload: { sessionId: session.id },
      });
    }

    entries.push({ kind: "separator", id: `session-project-separator-${session.id}` });

    if (sidebar.projects.length) {
      entries.push(
        ...sidebar.projects.map<SidebarContextMenuEntry>((project) => ({
          kind: "action",
          id: `assign-session-${session.id}-${project.id}`,
          label: `${session.projectId ? "Move to" : "Add to"} ${project.name}`,
          symbol: project.symbol,
          disabled: session.projectId === project.id,
          command: "assignSessionToProject",
          payload: {
            sessionId: session.id,
            projectId: project.id,
          },
        }))
      );
    } else {
      entries.push({
        kind: "action",
        id: `create-project-for-session-${session.id}`,
        label: "Create Project",
        symbol: "plus",
        command: "createProjectPrompt",
      });
    }

    if (session.projectId) {
      entries.push({
        kind: "action",
        id: `remove-session-project-${session.id}`,
        label: "Remove from Project",
        symbol: "minus.circle",
        command: "removeSessionFromProject",
        payload: { sessionId: session.id },
      });
    }

    entries.push(
      { kind: "separator", id: `session-archive-separator-${session.id}` },
      {
        kind: "action",
        id: `archive-session-${session.id}`,
        label: "Archive Chat",
        symbol: "archivebox",
        command: "archiveSession",
        payload: { sessionId: session.id },
      }
    );

    return entries;
  };

  if (!shellState || !sidebar) {
    return <aside className="oa-sidebar" />;
  }

  if (shellState.ui.sidebarCollapsed) {
    return (
      <aside className="oa-sidebar oa-sidebar--collapsed">
        <div className="oa-sidebar__rail-top">
          <button
            type="button"
            className="oa-rail-button oa-rail-button--control"
            onClick={() => onDispatchCommand("setSidebarCollapsed", { collapsed: false })}
            title="Expand sidebar"
          >
            <ShellIcon symbol="sidebar.right" />
          </button>
          <button
            type="button"
            className="oa-rail-button oa-rail-button--accent"
            onClick={() => onDispatchCommand("newThread")}
            title="New thread"
          >
            <ShellIcon symbol="plus" />
          </button>
        </div>

        <div className="oa-rail-group">
          {sidebar.navItems.map((item) => (
            <button
              key={item.id}
              type="button"
              className={[
                "oa-rail-button",
                shellState.ui.selectedPane === item.id ? "is-active" : "",
              ]
                .filter(Boolean)
                .join(" ")}
              onClick={() => onDispatchCommand("setSelectedPane", { pane: item.id })}
              title={item.label}
            >
              <ShellIcon symbol={item.symbol} />
            </button>
          ))}
        </div>

        <div className="oa-rail-spacer" />

        <button
          type="button"
          className="oa-rail-button"
          onClick={() => onDispatchCommand("openAssistantSetup")}
          title="Settings"
        >
          <ShellIcon symbol="gearshape" />
        </button>
      </aside>
    );
  }

  return (
    <aside className="oa-sidebar">
      <div className="oa-sidebar__header">
        <button
          type="button"
          className="oa-button oa-button--ghost oa-button--wide oa-sidebar__new-thread"
          onClick={() => onDispatchCommand("newThread")}
          disabled={!sidebar.canCreateThread}
        >
          <span className="oa-nav-button__icon"><ShellIcon symbol="plus" /></span>
          New thread
        </button>
        <button
          type="button"
          className="oa-icon-button oa-sidebar__toggle"
          onClick={() => onDispatchCommand("setSidebarCollapsed", { collapsed: true })}
          title="Collapse sidebar"
        >
          <ShellIcon symbol="sidebar.left" />
        </button>
      </div>

      <div className="oa-sidebar__nav">
        {primaryNavItems.map((item) => (
          <button
            key={item.id}
            type="button"
            className={`oa-nav-button ${shellState.ui.selectedPane === item.id ? "is-active" : ""}`}
            onClick={() => onDispatchCommand("setSelectedPane", { pane: item.id })}
          >
            <span className="oa-nav-button__icon"><ShellIcon symbol={item.symbol} /></span>
            <span>{item.label}</span>
          </button>
        ))}
      </div>

      <div className="oa-sidebar__scroll">
        <SidebarSection
          title={sidebar.projectsTitle}
          helperText={sidebar.projectsHelperText}
          expanded={sidebar.projectsExpanded}
          onToggle={() => onDispatchCommand("toggleProjectsExpanded")}
          action={
            <button
              type="button"
              className="oa-icon-button"
              onClick={() => onDispatchCommand("createProjectPrompt")}
              onContextMenu={(event) =>
                openContextMenu(event, projectSectionContextMenuEntries())
              }
              title="Create project"
            >
              +
            </button>
          }
        >
          {sidebar.projects.length ? (
            sidebar.projects.map((project) => (
              <button
                key={project.id}
                type="button"
                className={`oa-list-row ${project.isSelected ? "is-active" : ""}`}
                onClick={() => {
                  setContextMenu(null);
                  setContextMenuPosition(null);
                  onDispatchCommand("selectProjectFilter", {
                    projectId: project.isSelected ? "" : project.id,
                  });
                }}
                onContextMenu={(event) =>
                  openContextMenu(event, projectContextMenuEntries(project))
                }
              >
                <div className="oa-list-row__title">
                  <span className="oa-list-row__icon"><ShellIcon symbol={project.symbol} /></span>
                  <span>{project.name}</span>
                </div>
                <div className="oa-list-row__subtitle">
                  {project.subtitle}
                  {project.folderMissing ? " · missing folder" : ""}
                </div>
              </button>
            ))
          ) : (
            <div className="oa-empty-inline">
              {sidebar.hiddenProjects.length
                ? "All projects are hidden. Right-click + to unhide one."
                : "No projects yet."}
            </div>
          )}
        </SidebarSection>

        <SidebarSection
          title={
            shellState.ui.selectedPane === "archived"
              ? sidebar.archivedTitle
              : sidebar.threadsTitle
          }
          helperText={
            shellState.ui.selectedPane === "archived"
              ? sidebar.archivedHelperText
              : sidebar.projectsHelperText
          }
          expanded={
            shellState.ui.selectedPane === "archived"
              ? sidebar.archivedExpanded
              : sidebar.threadsExpanded
          }
          onToggle={() =>
            onDispatchCommand(
              shellState.ui.selectedPane === "archived"
                ? "toggleArchivedExpanded"
                : "toggleThreadsExpanded"
            )
          }
          action={
            shellState.ui.selectedPane === "archived" ? null : (
              <button
                type="button"
                className="oa-icon-button"
                onClick={() => onDispatchCommand("newThread")}
                title="Create thread"
              >
                +
              </button>
            )
          }
        >
          {selectedSessions.length ? (
            selectedSessions.map((session) => (
              <button
                key={session.id}
                type="button"
                className={`oa-list-row ${session.isSelected ? "is-active" : ""}`}
                onClick={() => {
                  setContextMenu(null);
                  setContextMenuPosition(null);
                  onDispatchCommand("openSession", {
                    sessionId: session.id,
                    pane: shellState.ui.selectedPane === "archived" ? "archived" : "threads",
                  });
                }}
                onContextMenu={(event) =>
                  openContextMenu(event, threadContextMenuEntries(session))
                }
              >
                <div className="oa-list-row__title">
                  <span>{session.title}</span>
                  {session.timeLabel ? (
                    <span className="oa-list-row__meta">{session.timeLabel}</span>
                  ) : null}
                </div>
                <div className="oa-list-row__subtitle">{session.subtitle}</div>
              </button>
            ))
          ) : (
            <div className="oa-empty-inline">
              {shellState.ui.selectedPane === "archived"
                ? "No archived chats."
                : "No threads yet."}
            </div>
          )}
        </SidebarSection>
      </div>

      <div className="oa-sidebar__footer">
        <button
          type="button"
          className="oa-footer-button"
          onClick={() => onDispatchCommand("openAssistantSetup")}
        >
          <span className="oa-footer-button__icon"><ShellIcon symbol="gearshape" /></span>
          <span>Settings</span>
        </button>
        <button
          type="button"
          className={`oa-footer-button ${shellState.ui.selectedPane === "archived" ? "is-active" : ""}`}
          onClick={() => onDispatchCommand("setSelectedPane", { pane: "archived" })}
        >
          <span className="oa-footer-button__icon"><ShellIcon symbol="archivebox" /></span>
          <span>Archived</span>
          {sidebar.archived.length > 0 ? (
            <span className="oa-footer-button__count">{sidebar.archived.length}</span>
          ) : null}
        </button>
      </div>

      {contextMenu ? (
        <SidebarContextMenu
          ref={contextMenuRef}
          entries={contextMenu.entries}
          position={contextMenuPosition ?? { x: contextMenu.x, y: contextMenu.y }}
          onSelect={dispatchContextMenuCommand}
        />
      ) : null}
    </aside>
  );
}

function SidebarSection({
  title,
  helperText,
  expanded,
  onToggle,
  action,
  children,
}: {
  title: string;
  helperText?: string;
  expanded: boolean;
  onToggle: () => void;
  action?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="oa-section">
      <div className="oa-section__header">
        <button type="button" className="oa-section__toggle" onClick={onToggle}>
          <span>{title}</span>
          <span className={`oa-section__chevron ${expanded ? "is-open" : ""}`}>
            <ShellIcon symbol="chevron.down" />
          </span>
        </button>
        {action ? <div className="oa-section__actions">{action}</div> : null}
      </div>
      {helperText ? <div className="oa-section__helper">{helperText}</div> : null}
      {expanded ? <div className="oa-section__body">{children}</div> : null}
    </section>
  );
}

const SidebarContextMenu = forwardRef<
  HTMLDivElement,
  {
    entries: SidebarContextMenuEntry[];
    position: { x: number; y: number };
    onSelect: (entry: SidebarContextMenuAction) => void;
  }
>(function SidebarContextMenu({ entries, position, onSelect }, ref) {
  return (
    <div
      ref={ref}
      className="oa-context-menu"
      role="menu"
      style={
        {
          "--oa-context-menu-x": `${position.x}px`,
          "--oa-context-menu-y": `${position.y}px`,
        } as CSSProperties
      }
    >
      {entries.map((entry) => {
        if (entry.kind === "separator") {
          return <div key={entry.id} className="oa-context-menu__separator" role="separator" />;
        }

        if (entry.kind === "note") {
          return (
            <div key={entry.id} className="oa-context-menu__note">
              {entry.label}
            </div>
          );
        }

        return (
          <button
            key={entry.id}
            type="button"
            role="menuitem"
            className={`oa-context-menu__item ${entry.destructive ? "is-destructive" : ""}`}
            disabled={entry.disabled}
            onClick={() => onSelect(entry)}
          >
            <span className="oa-context-menu__item-main">
              <span className="oa-context-menu__item-icon">
                {entry.symbol ? <ShellIcon symbol={entry.symbol} /> : null}
              </span>
              <span>{entry.label}</span>
            </span>
          </button>
        );
      })}
    </div>
  );
});

function CollapsedPreview({
  pane,
  shellState,
  onDispatchCommand,
  onSelectedSkillChange,
  onMouseEnter,
  onMouseLeave,
}: {
  pane: AssistantPaneID;
  shellState: AssistantShellState;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
  onSelectedSkillChange: (skill: AssistantSkillItem | null) => void;
  onMouseEnter: () => void;
  onMouseLeave: () => void;
}) {
  return (
    <div className="oa-collapsed-preview" onMouseEnter={onMouseEnter} onMouseLeave={onMouseLeave}>
      <div className="oa-collapsed-preview__title">
        {shellState.sidebar.navItems.find((item) => item.id === pane)?.label ?? "Preview"}
      </div>

      {pane === "threads" ? (
        <div className="oa-collapsed-preview__list">
          {shellState.sidebar.threads.slice(0, 5).map((session) => (
            <button
              key={session.id}
              type="button"
              className={`oa-preview-row ${session.isSelected ? "is-active" : ""}`}
              onClick={() =>
                onDispatchCommand("openSession", { sessionId: session.id, pane: "threads" })
              }
            >
              <span className="oa-preview-row__title">{session.title}</span>
              <span className="oa-preview-row__subtitle">{session.subtitle}</span>
            </button>
          ))}
        </div>
      ) : null}

      {pane === "archived" ? (
        <div className="oa-collapsed-preview__list">
          {shellState.sidebar.archived.slice(0, 5).map((session) => (
            <button
              key={session.id}
              type="button"
              className={`oa-preview-row ${session.isSelected ? "is-active" : ""}`}
              onClick={() =>
                onDispatchCommand("openSession", { sessionId: session.id, pane: "archived" })
              }
            >
              <span className="oa-preview-row__title">{session.title}</span>
              <span className="oa-preview-row__subtitle">{session.subtitle}</span>
            </button>
          ))}
        </div>
      ) : null}

      {pane === "automations" ? (
        <div className="oa-collapsed-preview__list">
          {shellState.automationsPane.jobs.slice(0, 5).map((job) => (
            <button
              key={job.id}
              type="button"
              className="oa-preview-row"
              onClick={() => onDispatchCommand("setSelectedPane", { pane: "automations" })}
            >
              <span className="oa-preview-row__title">{job.name}</span>
              <span className="oa-preview-row__subtitle">
                {job.scheduleDescription} · {job.lastOutcomeLabel}
              </span>
            </button>
          ))}
        </div>
      ) : null}

      {pane === "skills" ? (
        <div className="oa-collapsed-preview__list">
          {shellState.skillsPane.groups
            .flatMap((group) => group.skills)
            .slice(0, 5)
            .map((skill) => (
              <button
                key={skill.name}
                type="button"
                className="oa-preview-row"
                onClick={() => {
                  onDispatchCommand("setSelectedPane", { pane: "skills" });
                  onSelectedSkillChange(skill);
                }}
              >
                <span className="oa-preview-row__title">{skill.displayName}</span>
                <span className="oa-preview-row__subtitle">{skill.summary}</span>
              </button>
            ))}
        </div>
      ) : null}
    </div>
  );
}

function renderPane({
  shellState,
  activePane,
  messages,
  typing,
  runtimePanel,
  activeProviderTone,
  checkpointsByMessageID,
  rewindState,
  textScale,
  isPinnedToBottom,
  canLoadOlder,
  composerText,
  jobDraft,
  selectedJobId,
  onScrollState,
  onLoadOlder,
  onJumpToLatest,
  onSelectRuntimeBackend,
  onOpenRuntimeSettings,
  onDispatchCommand,
  onComposerChange,
  onJobDraftChange,
  onSelectedJobIdChange,
  onSelectedSkillChange,
  isWorkspaceMenuOpen,
  onWorkspaceMenuOpenChange,
  workspaceMenuRef,
  onToggleInstructions,
}: {
  shellState: AssistantShellState | null;
  activePane: AssistantPaneID;
  messages: ChatMessage[];
  typing: TypingState;
  runtimePanel: RuntimePanelState | null;
  activeProviderTone: ProviderTone;
  checkpointsByMessageID: Map<string, MessageCheckpointInfo>;
  rewindState: RewindState | null;
  textScale: number;
  isPinnedToBottom: boolean;
  canLoadOlder: boolean;
  composerText: string;
  jobDraft: JobDraft;
  selectedJobId: string | "new" | null;
  onScrollState: (pinned: boolean, scrolledUp: boolean, distanceFromTop: number) => void;
  onLoadOlder: () => void;
  onJumpToLatest: () => void;
  onSelectRuntimeBackend: (backendID: string) => void;
  onOpenRuntimeSettings: () => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
  onComposerChange: (value: string) => void;
  onJobDraftChange: (draft: JobDraft) => void;
  onSelectedJobIdChange: (id: string | "new" | null) => void;
  onSelectedSkillChange: (skill: AssistantSkillItem | null) => void;
  isWorkspaceMenuOpen: boolean;
  onWorkspaceMenuOpenChange: (open: boolean) => void;
  workspaceMenuRef: React.MutableRefObject<HTMLDivElement | null>;
  onToggleInstructions: () => void;
}) {
  if (!shellState) {
    return <div className="oa-pane oa-pane--empty">Loading…</div>;
  }

  if (activePane === "automations") {
    return (
      <AutomationsPane
        shellState={shellState}
        selectedJobId={selectedJobId}
        jobDraft={jobDraft}
        onDispatchCommand={onDispatchCommand}
        onDraftChange={onJobDraftChange}
        onSelectedJobIdChange={onSelectedJobIdChange}
      />
    );
  }

  if (activePane === "skills") {
    return (
      <SkillsPane
        shellState={shellState}
        onDispatchCommand={onDispatchCommand}
        onSelectedSkillChange={onSelectedSkillChange}
      />
    );
  }

  const showArchivedEmpty = activePane === "archived" && !shellState.archivedPane.hasSelection;
  const showThreadEmpty = activePane === "threads" && !shellState.threadsPane.hasSelectedSession;
  const topbarTitle =
    activePane === "threads"
      ? shellState.threadsPane.hasSelectedSession
        ? shellState.threadsPane.title
        : null
      : activePane === "archived"
        ? shellState.archivedPane.hasSelection
          ? shellState.threadsPane.title
          : shellState.sidebar.archivedTitle
        : activePane === "automations"
          ? "Automations"
          : "Skills";
  const workspaceLauncher = shellState.threadsPane.workspaceLauncher ?? null;

  return (
    <div className="oa-pane">
      <div className="oa-pane__topbar">
        <div className="oa-pane__topbar-left">
          {runtimePanel ? (
            <RuntimePanel
              panel={runtimePanel}
              onSelectBackend={onSelectRuntimeBackend}
              onOpenSettings={onOpenRuntimeSettings}
            />
          ) : null}
        </div>

        <div className="oa-pane__topbar-center">
          {topbarTitle ? <div className="oa-pane__topbar-title">{topbarTitle}</div> : null}
        </div>

        <div className="oa-pane__topbar-right">
          <div className="oa-pane__topbar-status">
            <span className={`oa-header-dot oa-header-dot--${runtimePanel?.tone ?? "idle"}`} />
          </div>
          {workspaceLauncher ? (
            <div
              ref={workspaceMenuRef}
              className={`oa-workspace-launcher ${isWorkspaceMenuOpen ? "is-open" : ""}`}
            >
              <button
                type="button"
                className="oa-workspace-launcher__primary"
                onClick={() =>
                  onDispatchCommand("openWorkspace", {
                    targetId: workspaceLauncher.currentTargetId,
                  })
                }
                disabled={!shellState.threadsPane.canOpenWorkspace}
                title={
                  shellState.threadsPane.canOpenWorkspace
                    ? `Open this chat folder in ${workspaceLauncher.currentTargetTitle}`
                    : "This chat does not have a usable folder yet."
                }
              >
                <WorkspaceTargetIcon
                  target={{
                    id: workspaceLauncher.currentTargetId,
                    title: workspaceLauncher.currentTargetTitle,
                    fallbackSymbol: workspaceLauncher.currentTargetFallbackSymbol,
                    isInstalled: true,
                    isPreferred: true,
                    iconDataUrl: workspaceLauncher.currentTargetIconDataUrl,
                  }}
                />
              </button>
              <button
                type="button"
                className="oa-workspace-launcher__chevron"
                aria-expanded={isWorkspaceMenuOpen}
                aria-haspopup="menu"
                onClick={() => onWorkspaceMenuOpenChange(!isWorkspaceMenuOpen)}
                title="Choose editor"
              >
                <ShellIcon symbol="chevron.down" />
              </button>

              {isWorkspaceMenuOpen ? (
                <div className="oa-workspace-launcher__menu" role="menu">
                  {!shellState.threadsPane.canOpenWorkspace ? (
                    <div className="oa-workspace-launcher__menu-note">
                      Open a project chat first, then choose which editor should open it.
                    </div>
                  ) : null}
                  {workspaceLauncher.targets.map((target) => (
                    <button
                      key={target.id}
                      type="button"
                      role="menuitem"
                      className={`oa-workspace-launcher__item ${
                        target.id === workspaceLauncher.currentTargetId ? "is-active" : ""
                      }`}
                      disabled={!shellState.threadsPane.canOpenWorkspace || !target.isInstalled}
                      onClick={() => {
                        onWorkspaceMenuOpenChange(false);
                        onDispatchCommand("openWorkspace", { targetId: target.id });
                      }}
                    >
                      <span className="oa-workspace-launcher__item-main">
                        <WorkspaceTargetIcon target={target} />
                        <span className="oa-workspace-launcher__item-label">{target.title}</span>
                      </span>
                      <span className="oa-workspace-launcher__item-meta">
                        {target.id === workspaceLauncher.currentTargetId
                          ? "Current"
                          : target.isInstalled
                            ? ""
                            : "Not installed"}
                      </span>
                    </button>
                  ))}
                </div>
              ) : null}
            </div>
          ) : null}
          <div className="oa-pane__topbar-tools">
          <button
            type="button"
            className="oa-header-icon"
            onClick={() => onDispatchCommand("inspectMemory")}
            disabled={!shellState.threadsPane.canInspectMemory}
            title="Memory"
          >
            <ShellIcon symbol="bookmark" />
          </button>
          <button
            type="button"
            className="oa-header-icon"
            onClick={onToggleInstructions}
            title="Instructions"
          >
            <ShellIcon symbol="line.3.horizontal" />
          </button>
          <button
            type="button"
            className="oa-header-icon"
            onClick={() => onDispatchCommand("openRuntimeSettings")}
            title="Settings"
          >
            <ShellIcon symbol="slider.horizontal.3" />
          </button>
          <button
            type="button"
            className="oa-header-icon"
            onClick={() => onDispatchCommand("minimizeToCompact")}
            disabled={!shellState.threadsPane.canMinimize}
            title="Orb"
          >
            <ShellIcon symbol="rectangle.compress.vertical" />
          </button>
          </div>
        </div>
      </div>

      {activePane === "archived" ? (
        <div className="oa-archived-banner">
          <div>
            <strong>Archived default cleanup</strong>
            <span>Choose how long archived chats stay before automatic cleanup.</span>
          </div>
          <select
            value={String(shellState.archivedPane.retentionHours)}
            onChange={(event) =>
              onDispatchCommand("setArchiveRetention", {
                hours: Number(event.target.value),
              })
            }
          >
            {shellState.archivedPane.retentionOptions.map((option) => (
              <option key={option.hours} value={option.hours}>
                {option.label}
              </option>
            ))}
          </select>
        </div>
      ) : null}

      {showArchivedEmpty ? (
        <EmptyPanel title={shellState.archivedPane.emptyTitle} message={shellState.archivedPane.emptyMessage} />
      ) : showThreadEmpty ? (
        <EmptyPanel
          title="Select or start a thread"
          message="Use the sidebar to open an existing conversation, or create a new one to start chatting."
        />
      ) : (
        <>
          <div className="oa-pane__chat">
            <ChatView
              messages={messages}
              typing={typing}
              activeProviderTone={activeProviderTone}
              checkpointsByMessageID={checkpointsByMessageID}
              rewindState={rewindState}
              textScale={textScale}
              isPinnedToBottom={isPinnedToBottom}
              canLoadOlder={canLoadOlder}
              onScrollState={onScrollState}
              onLoadOlder={onLoadOlder}
              onJumpToLatest={onJumpToLatest}
            />
          </div>
          <Composer
            shellState={shellState}
            composerText={composerText}
            onComposerChange={onComposerChange}
            onDispatchCommand={onDispatchCommand}
          />
          <ThreadFooter paneState={shellState.threadsPane} />
        </>
      )}
    </div>
  );
}

function Composer({
  shellState,
  composerText,
  onComposerChange,
  onDispatchCommand,
}: {
  shellState: AssistantShellState;
  composerText: string;
  onComposerChange: (value: string) => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}) {
  const paneState = shellState.threadsPane;

  const handleKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      onDispatchCommand("sendPrompt");
    }
  };

  return (
    <div className="oa-composer">
      {paneState.activeThreadSkills.length ? (
        <div className="oa-chip-row">
          {paneState.activeThreadSkills.map((skill) => (
            <button
              key={skill.skillName}
              type="button"
              className={`oa-chip ${skill.isMissing ? "is-warning" : ""}`}
              onClick={() =>
                onDispatchCommand(skill.isMissing ? "repairMissingSkillBindings" : "detachSkill", {
                  skillName: skill.skillName,
                })
              }
            >
              <span>{skill.displayName}</span>
              <span className="oa-chip__meta">{skill.isMissing ? "Repair" : "Remove"}</span>
            </button>
          ))}
        </div>
      ) : null}

      {paneState.attachments.length ? (
        <div className="oa-chip-row">
          {paneState.attachments.map((attachment) => (
            <button
              key={attachment.id}
              type="button"
              className="oa-chip"
              onClick={() =>
                onDispatchCommand("removeAttachment", {
                  attachmentId: attachment.id,
                })
              }
            >
              <span>{attachment.filename}</span>
              <span className="oa-chip__meta">
                {(attachment.kind === "folder"
                  ? "Folder"
                  : attachment.kind === "image"
                    ? "Image"
                    : "File") + " · Remove"}
              </span>
            </button>
          ))}
        </div>
      ) : null}

      <div className="oa-composer__surface">
        <textarea
          className="oa-textarea"
          value={composerText}
          placeholder={paneState.canChat ? "What would you like to do?" : "Connect a runtime to start chatting"}
          onChange={(event) => {
            const value = event.target.value;
            onComposerChange(value);
            onDispatchCommand("updatePromptDraft", { text: value });
          }}
          onKeyDown={handleKeyDown}
        />

        <div className="oa-composer__toolbar">
          <div className="oa-toolbar-left">
            <button
              type="button"
              className="oa-composer-dropdown"
              onClick={() => onDispatchCommand("openFilePicker")}
              title="Attach file, image, or folder"
            >
              <span className="oa-composer-dropdown__icon">+</span>
              <ShellIcon symbol="chevron.down" />
            </button>

            <div className="oa-select-wrap">
              <ShellIcon symbol="square.stack.3d.up.fill" />
              <select
                value={paneState.selectedInteractionMode}
                onChange={(event) =>
                  onDispatchCommand("setInteractionMode", {
                    mode: event.target.value,
                  })
                }
              >
                {paneState.interactionModes.map((option) => (
                  <option key={option.id} value={option.id}>
                    {option.label}
                  </option>
                ))}
              </select>
              <ShellIcon symbol="chevron.down" />
            </div>

            <div className="oa-select-wrap">
              <select
                value={paneState.selectedModelId ?? ""}
                onChange={(event) =>
                  onDispatchCommand("setModel", {
                    modelId: event.target.value,
                  })
                }
              >
                {paneState.modelOptions.map((option) => (
                  <option key={option.id} value={option.id}>
                    {option.label}
                  </option>
                ))}
              </select>
              <ShellIcon symbol="chevron.down" />
            </div>

            <div className="oa-select-wrap">
              <select
                value={paneState.selectedReasoningId}
                onChange={(event) =>
                  onDispatchCommand("setReasoningEffort", {
                    effort: event.target.value,
                  })
                }
              >
                {paneState.reasoningOptions.map((option) => (
                  <option key={option.id} value={option.id}>
                    {option.label}
                  </option>
                ))}
              </select>
              <ShellIcon symbol="chevron.down" />
            </div>
          </div>

          <div className="oa-toolbar-right">
            {paneState.isBusy ? (
              <button
                type="button"
                className="oa-button oa-button--danger oa-button--sm"
                onClick={() => onDispatchCommand("cancelActiveTurn")}
              >
                Stop
              </button>
            ) : (
              <>
                <button
                  type="button"
                  className={`oa-mic-button ${paneState.isVoiceCapturing ? "is-active" : ""}`}
                  onClick={() =>
                    onDispatchCommand(
                      paneState.isVoiceCapturing ? "stopVoiceCapture" : "startVoiceCapture"
                    )
                  }
                  title={paneState.isVoiceCapturing ? "Listening…" : "Voice input"}
                >
                  <ShellIcon symbol="mic.fill" />
                </button>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function ThreadFooter({
  paneState,
}: {
  paneState: AssistantShellState["threadsPane"];
}) {
  const { footerStatus } = paneState;
  const hasUsage = typeof footerStatus.contextUsageSummary === "string" && footerStatus.contextUsageSummary.length > 0;
  const hasAccount = typeof footerStatus.accountSummary === "string" && footerStatus.accountSummary.length > 0;

  if (!hasUsage && !hasAccount) {
    return null;
  }

  const usagePercent = Math.max(0, Math.min(100, footerStatus.contextUsagePercent ?? 0));
  const weeklyPercent = Math.max(0, Math.min(100, footerStatus.weeklyUsagePercent ?? 0));

  return (
    <div className="oa-thread-footer">
      <div className="oa-thread-footer__badges">
        {hasUsage ? (
          <span
            className="oa-footer-badge"
            title={footerStatus.contextUsageTitle ?? footerStatus.contextUsageDetail ?? footerStatus.contextUsageSummary}
          >
            <span
              className="oa-footer-badge__ring"
              style={{ ["--usage-percent" as string]: `${usagePercent}%` }}
              aria-hidden="true"
            />
            <span>{footerStatus.contextUsageSummary}</span>
          </span>
        ) : null}

        {footerStatus.weeklyUsageSummary ? (
          <span
            className="oa-footer-badge"
            title={footerStatus.weeklyUsageDetail ?? footerStatus.weeklyUsageSummary}
          >
            <span
              className="oa-footer-badge__ring oa-footer-badge__ring--weekly"
              style={{ ["--usage-percent" as string]: `${weeklyPercent}%` }}
              aria-hidden="true"
            />
            <span>{footerStatus.weeklyUsageSummary}</span>
          </span>
        ) : null}
      </div>

      <div className="oa-thread-footer__spacer" />

      <div className="oa-thread-footer__status">
        {hasUsage ? (
          <FooterUsageCircle
            percent={usagePercent}
            title={footerStatus.contextUsageTitle ?? footerStatus.contextUsageSummary ?? "Context usage"}
            detail={footerStatus.contextUsageDetail ?? "Current context in this chat"}
          />
        ) : null}

        {hasAccount ? (
          <FooterAccountCircle
            summary={footerStatus.accountSummary ?? ""}
            email={footerStatus.accountEmail}
            plan={footerStatus.accountPlan}
          />
        ) : null}
      </div>
    </div>
  );
}

function FooterUsageCircle({
  percent,
  title,
  detail,
}: {
  percent: number;
  title: string;
  detail: string;
}) {
  const [isHovering, setIsHovering] = useState(false);
  const ringColor = percent > 85 ? "rgba(255,108,108,0.86)" : percent > 65 ? "rgba(255,184,76,0.86)" : "rgba(113,168,255,0.86)";

  return (
    <span
      className={`oa-footer-circle-wrap ${isHovering ? "is-hovered" : ""}`}
      onMouseEnter={() => setIsHovering(true)}
      onMouseLeave={() => setIsHovering(false)}
      onFocus={() => setIsHovering(true)}
      onBlur={() => setIsHovering(false)}
      tabIndex={0}
    >
      <span
        className="oa-footer-circle oa-footer-circle--usage"
        style={
          {
            ["--usage-percent" as string]: `${percent}%`,
            ["--usage-ring-color" as string]: ringColor,
          } as CSSProperties
        }
      >
        <span className="oa-footer-circle__value">{percent}%</span>
      </span>
      {isHovering ? <FooterHoverCard title={title} detail={detail} /> : null}
    </span>
  );
}

function FooterAccountCircle({
  summary,
  email,
  plan,
}: {
  summary: string;
  email?: string;
  plan?: string;
}) {
  const [isHovering, setIsHovering] = useState(false);

  return (
    <span
      className={`oa-footer-circle-wrap ${isHovering ? "is-hovered" : ""}`}
      onMouseEnter={() => setIsHovering(true)}
      onMouseLeave={() => setIsHovering(false)}
      onFocus={() => setIsHovering(true)}
      onBlur={() => setIsHovering(false)}
      tabIndex={0}
    >
      <span className="oa-footer-circle oa-footer-circle--account" title={summary}>
        <ShellIcon symbol="person.fill" />
      </span>
      {isHovering ? (
        <FooterHoverCard
          title={email ?? summary}
          detail={plan ?? (email ? summary : "Signed-in account")}
          tone={plan ? "account" : "neutral"}
        />
      ) : null}
    </span>
  );
}

function FooterHoverCard({
  title,
  detail,
  tone = "neutral",
}: {
  title: string;
  detail: string;
  tone?: "neutral" | "account";
}) {
  return (
    <span className={`oa-footer-hover-card oa-footer-hover-card--${tone}`}>
      <span className="oa-footer-hover-card__title">{title}</span>
      <span className="oa-footer-hover-card__detail">{detail}</span>
    </span>
  );
}

function AutomationsPane({
  shellState,
  selectedJobId,
  jobDraft,
  onDispatchCommand,
  onDraftChange,
  onSelectedJobIdChange,
}: {
  shellState: AssistantShellState;
  selectedJobId: string | "new" | null;
  jobDraft: JobDraft;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
  onDraftChange: (draft: JobDraft) => void;
  onSelectedJobIdChange: (id: string | "new" | null) => void;
}) {
  const selectedJob =
    selectedJobId && selectedJobId !== "new"
      ? shellState.automationsPane.jobs.find((job) => job.id === selectedJobId) ?? null
      : null;
  const groupedJobs = useMemo(
    () => ({
      running: shellState.automationsPane.jobs.filter((job) => job.isRunning),
      active: shellState.automationsPane.jobs.filter((job) => job.isEnabled && !job.isRunning),
      paused: shellState.automationsPane.jobs.filter((job) => !job.isEnabled),
    }),
    [shellState.automationsPane.jobs]
  );
  const visibleSections = [
    { id: "running", title: "Running", jobs: groupedJobs.running, emptyText: "No automations are running right now." },
    { id: "active", title: "Scheduled", jobs: groupedJobs.active, emptyText: "No active automations yet." },
    { id: "paused", title: "Paused", jobs: groupedJobs.paused, emptyText: "No paused automations." },
  ].filter((section) => section.jobs.length > 0);

  return (
    <div className="oa-pane oa-pane--automations">
      <div className="oa-page-header oa-page-header--topbar">
        <div className="oa-page-header__lead">
          <span className="oa-page-header__icon oa-page-header__icon--automation">
            <ShellIcon symbol="clock.badge.checkmark.fill" />
          </span>
          <div>
          <h1>Automations</h1>
          <p>Create and manage recurring assistant jobs.</p>
          </div>
        </div>
        <button
          type="button"
          className="oa-button oa-button--primary"
          onClick={() => onSelectedJobIdChange("new")}
        >
          New automation
        </button>
      </div>

      <div className="oa-automation-layout">
        <div className="oa-automation-list">
          {visibleSections.length ? (
            visibleSections.map((section) => (
              <AutomationSection
                key={section.id}
                title={section.title}
                jobs={section.jobs}
                selectedJobId={selectedJobId}
                emptyText={section.emptyText}
                onDispatchCommand={onDispatchCommand}
                onSelectedJobIdChange={onSelectedJobIdChange}
              />
            ))
          ) : (
            <div className="oa-empty-inline">No automations yet.</div>
          )}
        </div>

        <div className="oa-automation-editor">
          <div className="oa-detail-card">
            <div className="oa-detail-card__header">
              <div>
                <h2>{selectedJobId === "new" ? "New automation" : selectedJob?.name ?? "Select an automation"}</h2>
                <p>
                  {selectedJobId === "new"
                    ? "Create a new recurring job."
                    : selectedJob
                      ? `${selectedJob.scheduleDescription} · next ${selectedJob.nextRunDescription}`
                      : "Choose a job from the list to inspect or edit it."}
                </p>
              </div>
              {selectedJob ? (
                <div className="oa-toolbar-group">
                  <button
                    type="button"
                    className="oa-button oa-button--ghost"
                    onClick={() => onDispatchCommand("runAutomationJob", { jobId: selectedJob.id })}
                  >
                    Run now
                  </button>
                  <button
                    type="button"
                    className="oa-button oa-button--danger"
                    onClick={() => {
                      if (window.confirm(`Delete automation "${selectedJob.name}"?`)) {
                        onDispatchCommand("deleteAutomationJob", { jobId: selectedJob.id });
                      }
                    }}
                  >
                    Delete
                  </button>
                </div>
              ) : null}
            </div>

            {selectedJobId || shellState.automationsPane.jobs.length === 0 ? (
              <AutomationEditor
                selectedJob={selectedJob}
                draft={jobDraft}
                modelOptions={shellState.automationsPane.modelOptions}
                reasoningOptions={shellState.automationsPane.reasoningOptions}
                onDraftChange={onDraftChange}
                onDispatchCommand={onDispatchCommand}
              />
            ) : (
              <EmptyPanel title="Select an automation" message="Pick one from the left to inspect or edit it." />
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function AutomationSection({
  title,
  jobs,
  selectedJobId,
  emptyText,
  onDispatchCommand,
  onSelectedJobIdChange,
}: {
  title: string;
  jobs: AssistantAutomationJob[];
  selectedJobId: string | "new" | null;
  emptyText: string;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
  onSelectedJobIdChange: (id: string | "new" | null) => void;
}) {
  return (
    <section className="oa-library-section oa-library-section--automation">
      <div className="oa-library-section__header">
        <h3>{title}</h3>
        <span className="oa-library-section__meta">{jobs.length}</span>
      </div>
      {jobs.length ? (
        <div className="oa-stacked-list oa-stacked-list--compact">
          {jobs.map((job) => (
            <button
              key={job.id}
              type="button"
              className={`oa-job-row ${selectedJobId === job.id ? "is-active" : ""}`}
              onClick={() => onSelectedJobIdChange(job.id)}
            >
              <span className="oa-job-row__icon"><ShellIcon symbol="clock" /></span>
              <div className="oa-job-row__copy">
                <strong>{job.name}</strong>
                <span>{job.scheduleDescription}</span>
              </div>
              <div className="oa-job-row__meta">
                <span className={`oa-status-dot is-${job.lastOutcomeTone}`} />
                <span>{job.isEnabled ? job.lastOutcomeLabel : "Paused"}</span>
                <label className="oa-switch" onClick={(event) => event.stopPropagation()}>
                  <input
                    type="checkbox"
                    checked={job.isEnabled}
                    onChange={(event) =>
                      onDispatchCommand("toggleAutomationJob", {
                        jobId: job.id,
                        isEnabled: event.target.checked,
                      })
                    }
                  />
                  <span />
                </label>
              </div>
            </button>
          ))}
        </div>
      ) : (
        <div className="oa-empty-inline">{emptyText}</div>
      )}
    </section>
  );
}

function AutomationEditor({
  selectedJob,
  draft,
  modelOptions,
  reasoningOptions,
  onDraftChange,
  onDispatchCommand,
}: {
  selectedJob: AssistantAutomationJob | null;
  draft: JobDraft;
  modelOptions: Array<{ id: string; label: string }>;
  reasoningOptions: Array<{ id: string; label: string }>;
  onDraftChange: (draft: JobDraft) => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}) {
  const applyChange = (patch: Partial<JobDraft>) => onDraftChange({ ...draft, ...patch });

  return (
    <div className="oa-form">
      <div className="oa-form__grid">
        <label>
          <span>Name</span>
          <input value={draft.name} onChange={(event) => applyChange({ name: event.target.value })} />
        </label>
        <label>
          <span>Type</span>
          <select value={draft.jobType} onChange={(event) => applyChange({ jobType: event.target.value })}>
            <option value="general">General</option>
            <option value="browser">Browser</option>
            <option value="app">App Control</option>
            <option value="system">System</option>
          </select>
        </label>
      </div>

      <label>
        <span>Prompt</span>
        <textarea
          className="oa-textarea oa-textarea--job"
          value={draft.prompt}
          onChange={(event) => applyChange({ prompt: event.target.value })}
        />
      </label>

      <div className="oa-form__grid oa-form__grid--wide">
        <label>
          <span>Recurrence</span>
          <select value={draft.recurrence} onChange={(event) => applyChange({ recurrence: event.target.value })}>
            <option value="everyNMinutes">Every N Minutes</option>
            <option value="everyHour">Every Hour</option>
            <option value="daily">Daily</option>
            <option value="weekdays">Weekdays</option>
            <option value="weekends">Weekends</option>
            <option value="weekly">Weekly</option>
          </select>
        </label>
        <label>
          <span>Hour</span>
          <input
            type="number"
            min={0}
            max={23}
            value={draft.hour}
            onChange={(event) => applyChange({ hour: Number(event.target.value) })}
          />
        </label>
        <label>
          <span>Minute</span>
          <input
            type="number"
            min={0}
            max={59}
            value={draft.minute}
            onChange={(event) => applyChange({ minute: Number(event.target.value) })}
          />
        </label>
        <label>
          <span>Weekday</span>
          <input
            type="number"
            min={1}
            max={7}
            value={draft.weekday}
            onChange={(event) => applyChange({ weekday: Number(event.target.value) })}
          />
        </label>
        <label>
          <span>Interval Minutes</span>
          <input
            type="number"
            min={5}
            max={1440}
            value={draft.intervalMinutes}
            onChange={(event) => applyChange({ intervalMinutes: Number(event.target.value) })}
          />
        </label>
      </div>

      <div className="oa-form__grid">
        <label>
          <span>Model</span>
          <select
            value={draft.preferredModelId ?? ""}
            onChange={(event) => applyChange({ preferredModelId: event.target.value || undefined })}
          >
            {modelOptions.map((option) => (
              <option key={option.id} value={option.id}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          <span>Reasoning</span>
          <select
            value={draft.reasoningEffortId ?? ""}
            onChange={(event) => applyChange({ reasoningEffortId: event.target.value || undefined })}
          >
            {reasoningOptions.map((option) => (
              <option key={option.id} value={option.id}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="oa-toolbar-group oa-toolbar-group--end">
        <button
          type="button"
          className="oa-button oa-button--primary"
          disabled={!draft.name.trim() || !draft.prompt.trim()}
          onClick={() =>
            onDispatchCommand("saveAutomationJob", {
              job: draft,
            })
          }
        >
          {selectedJob ? "Save changes" : "Create job"}
        </button>
      </div>

      {selectedJob ? (
        <>
          <div className="oa-info-grid">
            <InfoCard title="Latest Outcome" value={selectedJob.lastOutcomeLabel} tone={selectedJob.lastOutcomeTone} />
            <InfoCard title="Next Run" value={selectedJob.nextRunDescription} />
            <InfoCard title="Lessons" value={String(selectedJob.lastLearnedLessonCount)} />
          </div>

          {selectedJob.sessionLinks.length ? (
            <div className="oa-subsection">
              <h3>Attached Sessions</h3>
              <div className="oa-stacked-list">
                {selectedJob.sessionLinks.map((session) => (
                  <button
                    key={session.sessionId}
                    type="button"
                    className="oa-card-button"
                    onClick={() =>
                      onDispatchCommand("openSession", {
                        sessionId: session.sessionId,
                        pane: "threads",
                      })
                    }
                  >
                    <strong>{session.title}</strong>
                    <span>{session.subtitle}</span>
                  </button>
                ))}
              </div>
            </div>
          ) : null}

          <div className="oa-subsection">
            <h3>Automation Memory</h3>
            {selectedJob.lessons.length ? (
              <div className="oa-stacked-list">
                {selectedJob.lessons.map((lesson) => (
                  <div key={lesson.id} className="oa-card">
                    <strong>{lesson.title}</strong>
                    <p>{lesson.summary}</p>
                    <span>{lesson.sourceLabel ?? lesson.updatedLabel}</span>
                  </div>
                ))}
              </div>
            ) : (
              <div className="oa-empty-inline">
                No long-term lessons are saved for this automation yet.
              </div>
            )}
          </div>
        </>
      ) : null}
    </div>
  );
}

function SkillsPane({
  shellState,
  onDispatchCommand,
  onSelectedSkillChange,
}: {
  shellState: AssistantShellState;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
  onSelectedSkillChange: (skill: AssistantSkillItem | null) => void;
}) {
  const [query, setQuery] = useState("");
  const filteredGroups = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    if (!normalizedQuery) {
      return shellState.skillsPane.groups;
    }
    return shellState.skillsPane.groups.map((group) => ({
      ...group,
      skills: group.skills.filter((skill) => {
        const haystack = `${skill.displayName} ${skill.summary} ${skill.sourceBadge}`.toLowerCase();
        return haystack.includes(normalizedQuery);
      }),
    }));
  }, [query, shellState.skillsPane.groups]);

  return (
    <div className="oa-pane oa-pane--skills">
      <div className="oa-page-header oa-page-header--topbar">
        <div className="oa-page-header__lead">
          <span className="oa-page-header__icon oa-page-header__icon--skills">
            <ShellIcon symbol="sparkles.rectangle.stack.fill" />
          </span>
          <div>
          <h1>Skills</h1>
          <p>Give Open Assist reusable powers for threads and automations.</p>
          </div>
        </div>
        <div className="oa-toolbar-group">
          <button type="button" className="oa-button oa-button--ghost" onClick={() => onDispatchCommand("refreshSkills")}>
            Refresh
          </button>
          <input
            className="oa-search-input"
            value={query}
            placeholder="Search skills"
            onChange={(event) => setQuery(event.target.value)}
          />
          <button type="button" className="oa-button oa-button--primary" onClick={() => onDispatchCommand("createSkill")}>
            New skill
          </button>
        </div>
      </div>

      <div className="oa-page-toolbar">
        <button type="button" className="oa-button oa-button--ghost" onClick={() => onDispatchCommand("importSkillFolder")}>
          Import folder
        </button>
        <button type="button" className="oa-button oa-button--ghost" onClick={() => onDispatchCommand("importSkillGitHub")}>
          Import GitHub
        </button>
      </div>

      <div className="oa-page-scroll">
        <section className="oa-inline-panel">
          <div className="oa-inline-panel__header">
            <div>
              <h3>Active on this thread</h3>
              {shellState.skillsPane.selectedThreadTitle ? (
                <span className="oa-subsection__meta">{shellState.skillsPane.selectedThreadTitle}</span>
              ) : null}
            </div>
          </div>

          {shellState.skillsPane.activeThreadSkills.length ? (
            <div className="oa-skill-grid oa-skill-grid--attached">
              {shellState.skillsPane.activeThreadSkills.map((skill) => (
                <button
                  key={skill.skillName}
                  type="button"
                  className={`oa-skill-row oa-skill-row--attached ${skill.isMissing ? "is-warning" : ""}`}
                  onClick={() =>
                    onDispatchCommand(skill.isMissing ? "repairMissingSkillBindings" : "detachSkill", {
                      skillName: skill.skillName,
                    })
                  }
                >
                  <span className="oa-skill-row__icon"><ShellIcon symbol={skill.symbol} /></span>
                  <span className="oa-skill-row__copy">
                    <strong>{skill.displayName}</strong>
                    <span>{skill.summary}</span>
                  </span>
                  <span className="oa-skill-row__state">{skill.isMissing ? "Repair" : "Attached"}</span>
                </button>
              ))}
            </div>
          ) : (
            <div className="oa-empty-inline">
              {shellState.skillsPane.canAttachToThread
                ? "No skills attached to this thread yet."
                : "Open a thread first, then attach skills to it."}
            </div>
          )}
        </section>

        {filteredGroups.map((group) => (
          <section key={group.id} className="oa-library-section">
            <div className="oa-library-section__header">
              <h3>{group.title}</h3>
              <span className="oa-library-section__meta">{group.skills.length}</span>
            </div>

            {group.skills.length ? (
              <div className="oa-skill-grid">
                {group.skills.map((skill) => (
                  <div key={skill.name} className={`oa-skill-row ${skill.isAttached ? "is-active" : ""}`}>
                    <button
                      type="button"
                      className="oa-skill-row__main"
                      onClick={() => onSelectedSkillChange(skill)}
                    >
                      <span className="oa-skill-row__icon"><ShellIcon symbol={skill.symbol} /></span>
                      <span className="oa-skill-row__copy">
                        <strong>{skill.displayName}</strong>
                        <span>{skill.summary}</span>
                      </span>
                    </button>

                    <div className="oa-skill-row__actions">
                      <span className="oa-skill-row__badge">{skill.sourceBadge}</span>
                      <button
                        type="button"
                        className={skill.isAttached ? "oa-mini-button is-active" : "oa-mini-button"}
                        disabled={!skill.isAttached && !shellState.skillsPane.canAttachToThread}
                        onClick={() =>
                          onDispatchCommand(skill.isAttached ? "detachSkill" : "attachSkill", {
                            skillName: skill.name,
                          })
                        }
                      >
                        {skill.isAttached ? "Attached" : "Attach"}
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="oa-empty-inline">
                {query.trim() ? "No skills match your search." : group.emptyStateText}
              </div>
            )}
          </section>
        ))}
      </div>
    </div>
  );
}

function SkillDetailModal({
  skill,
  canAttach,
  onClose,
  onDispatchCommand,
}: {
  skill: AssistantSkillItem;
  canAttach: boolean;
  onClose: () => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}) {
  return (
    <ModalCard
      title={skill.displayName}
      subtitle={skill.sourceBadge}
      onClose={onClose}
      footer={
        <>
          <button type="button" className="oa-button oa-button--ghost" onClick={() => onDispatchCommand("revealSkill", { skillName: skill.name })}>
            Open in Finder
          </button>
          {!skill.isReadOnly ? (
            <button
              type="button"
              className="oa-button oa-button--ghost"
              onClick={() => onDispatchCommand("duplicateSkill", { skillName: skill.name })}
            >
              Duplicate
            </button>
          ) : null}
          <button
            type="button"
            className={skill.isAttached ? "oa-button oa-button--ghost" : "oa-button oa-button--primary"}
            disabled={!skill.isAttached && !canAttach}
            onClick={() =>
              onDispatchCommand(skill.isAttached ? "detachSkill" : "attachSkill", {
                skillName: skill.name,
              })
            }
          >
            {skill.isAttached ? "Detach" : "Attach to Thread"}
          </button>
          <button
            type="button"
            className="oa-button oa-button--primary"
            onClick={() =>
              onDispatchCommand("trySkill", {
                skillName: skill.name,
                prompt: skill.examplePrompt,
              })
            }
          >
            Try in New Thread
          </button>
          {!skill.isReadOnly ? (
            <button
              type="button"
              className="oa-button oa-button--danger"
              onClick={() => {
                if (window.confirm(`Delete skill "${skill.displayName}"?`)) {
                  onDispatchCommand("deleteSkill", { skillName: skill.name });
                  onClose();
                }
              }}
            >
              Delete
            </button>
          ) : null}
        </>
      }
    >
      <div className="oa-modal-copy">
        <div className="oa-subsection">
          <h3>Example Prompt</h3>
          <pre className="oa-code-block">{skill.examplePrompt}</pre>
        </div>
        <div className="oa-subsection">
          <h3>Skill Instructions</h3>
          <div className="assistant-markdown-shell oa-markdown-surface">
            <MarkdownContent markdown={skill.bodyMarkdown} />
          </div>
        </div>
      </div>
    </ModalCard>
  );
}

function ModalCard({
  title,
  subtitle,
  children,
  footer,
  onClose,
}: {
  title: string;
  subtitle?: string;
  children: ReactNode;
  footer?: ReactNode;
  onClose: () => void;
}) {
  return (
    <div className="oa-modal-backdrop" onClick={onClose}>
      <div className="oa-modal" onClick={(event) => event.stopPropagation()}>
        <div className="oa-modal__header">
          <div>
            <h2>{title}</h2>
            {subtitle ? <p>{subtitle}</p> : null}
          </div>
          <button type="button" className="oa-icon-button" onClick={onClose}>
            ×
          </button>
        </div>
        <div className="oa-modal__body">{children}</div>
        {footer ? <div className="oa-modal__footer">{footer}</div> : null}
      </div>
    </div>
  );
}

function EmptyPanel({ title, message }: { title: string; message: string }) {
  return (
    <div className="oa-empty-panel">
      <h2>{title}</h2>
      <p>{message}</p>
    </div>
  );
}

function InfoCard({
  title,
  value,
  tone = "neutral",
}: {
  title: string;
  value: string;
  tone?: "success" | "warning" | "danger" | "neutral";
}) {
  return (
    <div className={`oa-info-card is-${tone}`}>
      <span>{title}</span>
      <strong>{value}</strong>
    </div>
  );
}

function jobToDraft(job: AssistantAutomationJob): JobDraft {
  return {
    id: job.id,
    name: job.name,
    prompt: job.prompt,
    jobType: job.jobType,
    recurrence: job.recurrence,
    hour: job.hour,
    minute: job.minute,
    weekday: job.weekday,
    intervalMinutes: job.intervalMinutes,
    preferredModelId: job.preferredModelId,
    reasoningEffortId: job.reasoningEffortId,
  };
}

function clearHoverTimeout(ref: React.MutableRefObject<number | null>) {
  if (ref.current !== null) {
    window.clearTimeout(ref.current);
    ref.current = null;
  }
}

function scheduleHoverClear(
  ref: React.MutableRefObject<number | null>,
  setHoveredPane: (pane: AssistantPaneID | null) => void
) {
  clearHoverTimeout(ref);
  ref.current = window.setTimeout(() => {
    setHoveredPane(null);
  }, 120);
}

function WorkspaceTargetIcon({
  target,
}: {
  target: Pick<AssistantWorkspaceLaunchTarget, "title" | "iconDataUrl" | "fallbackSymbol">;
}) {
  if (target.iconDataUrl) {
    return (
      <img
        className="oa-workspace-launcher__icon-image"
        src={target.iconDataUrl}
        alt=""
        aria-hidden="true"
      />
    );
  }

  return (
    <span className="oa-workspace-launcher__icon-fallback" aria-hidden="true">
      <ShellIcon symbol={target.fallbackSymbol} />
    </span>
  );
}

function ShellIcon({ symbol }: { symbol: string }) {
  const props = {
    className: "oa-shell-icon",
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.9,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };

  switch (symbol) {
    case "bubble.left.and.bubble.right":
      return (
        <svg {...props}>
          <path d="M4 8.5a4.5 4.5 0 0 1 4.5-4.5h6a4.5 4.5 0 0 1 0 9H10l-3.5 3v-3A4.5 4.5 0 0 1 4 8.5Z" />
          <path d="M14.5 10H16a4 4 0 0 1 4 4v4l-2.8-2H14" />
        </svg>
      );
    case "folder":
    case "folder.fill":
      return (
        <svg {...props}>
          <path d="M3.5 7.5h5l1.7 2H20a1 1 0 0 1 1 1v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a1 1 0 0 1 .5-1Z" />
        </svg>
      );
    case "folder.badge.plus":
      return (
        <svg {...props}>
          <path d="M3.5 7.5h5l1.7 2H20a1 1 0 0 1 1 1v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a1 1 0 0 1 .5-1Z" />
          <path d="M16.5 9.5v5" />
          <path d="M14 12h5" />
        </svg>
      );
    case "folder.badge.minus":
      return (
        <svg {...props}>
          <path d="M3.5 7.5h5l1.7 2H20a1 1 0 0 1 1 1v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a1 1 0 0 1 .5-1Z" />
          <path d="M14 12h5" />
        </svg>
      );
    case "square.stack.3d.up.fill":
      return (
        <svg {...props}>
          <path d="M7 7.5 12 5l5 2.5-5 2.5L7 7.5Z" />
          <path d="M7 12 12 9.5l5 2.5-5 2.5L7 12Z" />
          <path d="M7 16.5 12 14l5 2.5-5 2.5-5-2.5Z" />
        </svg>
      );
    case "briefcase.fill":
      return (
        <svg {...props}>
          <rect x="4" y="7" width="16" height="11" rx="2.5" />
          <path d="M9 7V6a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v1" />
        </svg>
      );
    case "book.closed.fill":
      return (
        <svg {...props}>
          <path d="M5 5.5A2.5 2.5 0 0 1 7.5 3H19v16H7.5A2.5 2.5 0 0 0 5 21V5.5Z" />
          <path d="M5 5.5V19" />
        </svg>
      );
    case "terminal.fill":
      return (
        <svg {...props}>
          <path d="m5 7 4 4-4 4" />
          <path d="M11.5 15H19" />
        </svg>
      );
    case "clock":
    case "clock.badge.checkmark.fill":
    case "clock.badge.exclamationmark":
      return (
        <svg {...props}>
          <circle cx="12" cy="12" r="8" />
          <path d="M12 8v4.5l3 1.5" />
        </svg>
      );
    case "sparkles":
    case "sparkles.rectangle.stack.fill":
      return (
        <svg {...props}>
          <path d="M12 4.5 13.8 9 18.5 10.8 14 12.5 12.2 17 10.5 12.5 6 10.8 10.5 9 12 4.5Z" />
          <path d="m18.5 4 0.8 2 2 0.8-2 0.7-0.8 2-0.7-2-2-0.7 2-0.8 0.7-2Z" />
        </svg>
      );
    case "star.fill":
      return (
        <svg {...props}>
          <path d="m12 4 2.3 4.6 5 .7-3.6 3.5.9 5-4.6-2.4-4.6 2.4.9-5L4.7 9.3l5-.7L12 4Z" />
        </svg>
      );
    case "brain":
      return (
        <svg {...props}>
          <path d="M9 7a3 3 0 1 1 6 0 3 3 0 1 1 2.5 5.7v.3A3 3 0 0 1 15 16v1a3 3 0 0 1-6 0v-1a3 3 0 0 1-2.5-3v-.3A3 3 0 0 1 9 7Z" />
          <path d="M10 8.5c0 1 .5 1.6 1.4 2.2M14 8.5c0 1-.5 1.6-1.4 2.2M12 10.7V17" />
        </svg>
      );
    case "bookmark":
      return (
        <svg {...props}>
          <path d="M7 5.5h10a1.5 1.5 0 0 1 1.5 1.5V19l-6.5-3-6.5 3V7A1.5 1.5 0 0 1 7 5.5Z" />
        </svg>
      );
    case "archivebox":
      return (
        <svg {...props}>
          <path d="M4 6.5h16v4H4z" />
          <path d="M6.5 10.5h11V18a2 2 0 0 1-2 2h-7a2 2 0 0 1-2-2v-7.5Z" />
          <path d="M10 14h4" />
        </svg>
      );
    case "chevron.left.forwardslash.chevron.right":
      return (
        <svg {...props}>
          <path d="m8 7-4 5 4 5" />
          <path d="m16 7 4 5-4 5" />
          <path d="M14 5 10 19" />
        </svg>
      );
    case "command.square":
      return (
        <svg {...props}>
          <rect x="4" y="4" width="16" height="16" rx="3" />
          <path d="M9 9.2a1.8 1.8 0 1 1 2.6 1.6V13a1.8 1.8 0 1 1-1.2 0v-2.2A1.8 1.8 0 0 1 9 9.2Z" />
          <path d="M15 9.2a1.8 1.8 0 1 1 2.6 1.6V13a1.8 1.8 0 1 1-1.2 0v-2.2A1.8 1.8 0 0 1 15 9.2Z" />
        </svg>
      );
    case "exclamationmark.triangle.fill":
      return (
        <svg {...props}>
          <path d="M12 4.5 20 19H4l8-14.5Z" />
          <path d="M12 9.5v4.5M12 17h.01" />
        </svg>
      );
    case "wind":
      return (
        <svg {...props}>
          <path d="M4 9.5h10a2.5 2.5 0 1 0-2.5-2.5" />
          <path d="M4 13h13a2.5 2.5 0 1 1-2.5 2.5" />
          <path d="M4 16.5h7" />
        </svg>
      );
    case "hammer.fill":
      return (
        <svg {...props}>
          <path d="M8.5 6h6l1.5 1.5-2 2-1.5-1.5H11L7 12" />
          <path d="m6.5 12.5 5 5" />
          <path d="m5 19 2-2" />
        </svg>
      );
    case "curlybraces.square.fill":
      return (
        <svg {...props}>
          <rect x="4" y="4" width="16" height="16" rx="3" />
          <path d="M10 8.5c-1.2 0-1.5.7-1.5 1.8v.4c0 .8-.3 1.4-1 1.7.7.3 1 1 1 1.7v.4c0 1.1.3 1.8 1.5 1.8" />
          <path d="M14 8.5c1.2 0 1.5.7 1.5 1.8v.4c0 .8.3 1.4 1 1.7-.7.3-1 1-1 1.7v.4c0 1.1-.3 1.8-1.5 1.8" />
        </svg>
      );
    case "gearshape":
      return (
        <svg {...props}>
          <path d="M12 3.8v2.1M12 18.1v2.1M20.2 12h-2.1M5.9 12H3.8M17.8 6.2l-1.5 1.5M7.7 16.3l-1.5 1.5M17.8 17.8l-1.5-1.5M7.7 7.7 6.2 6.2" />
          <circle cx="12" cy="12" r="3.4" />
        </svg>
      );
    case "eye":
      return (
        <svg {...props}>
          <path d="M2.8 12S6.3 6.5 12 6.5 21.2 12 21.2 12 17.7 17.5 12 17.5 2.8 12 2.8 12Z" />
          <circle cx="12" cy="12" r="2.8" />
        </svg>
      );
    case "eye.slash":
      return (
        <svg {...props}>
          <path d="M3.5 4.5 20.5 19.5" />
          <path d="M10.2 6.7A10.8 10.8 0 0 1 12 6.5c5.7 0 9.2 5.5 9.2 5.5a16.7 16.7 0 0 1-3.4 3.8" />
          <path d="M13.9 14.1A2.8 2.8 0 0 1 9.9 10" />
          <path d="M7.1 7.2A17.2 17.2 0 0 0 2.8 12s3.5 5.5 9.2 5.5c1.2 0 2.3-.2 3.3-.6" />
        </svg>
      );
    case "pencil":
      return (
        <svg {...props}>
          <path d="m15.5 5.5 3 3" />
          <path d="m5 19 3.8-1 8.9-8.9a2.1 2.1 0 0 0-3-3L5.8 15 5 19Z" />
        </svg>
      );
    case "trash":
      return (
        <svg {...props}>
          <path d="M4.5 7.5h15" />
          <path d="M9 4.5h6" />
          <path d="M7 7.5 8 19a2 2 0 0 0 2 1.8h4a2 2 0 0 0 2-1.8l1-11.5" />
          <path d="M10 11v5.5M14 11v5.5" />
        </svg>
      );
    case "sidebar.left":
    case "sidebar.right":
      return (
        <svg {...props}>
          <path d="M5 5.5h14v13H5z" />
          <path d="M9 5.5v13" />
        </svg>
      );
    case "chevron.down":
      return (
        <svg {...props}>
          <path d="m7 10 5 5 5-5" />
        </svg>
      );
    case "line.3.horizontal":
      return (
        <svg {...props}>
          <path d="M5 8h14" />
          <path d="M5 12h14" />
          <path d="M5 16h10" />
        </svg>
      );
    case "photo":
      return (
        <svg {...props}>
          <rect x="4" y="5" width="16" height="14" rx="2.5" />
          <circle cx="9" cy="10" r="1.5" />
          <path d="m6.5 16 3.3-3.3 2.4 2.4 2-2 3.3 2.9" />
        </svg>
      );
    case "paperclip":
      return (
        <svg {...props}>
          <path d="M9 12.5 15.5 6a3 3 0 1 1 4.2 4.2l-8.2 8.2a5 5 0 0 1-7-7l7.4-7.4" />
        </svg>
      );
    case "plus":
      return (
        <svg {...props}>
          <path d="M12 5v14M5 12h14" />
        </svg>
      );
    case "pin":
      return (
        <svg {...props}>
          <path d="M9 5.5h6l-1 4 2.5 2.5H7.5L10 9.5 9 5.5Z" />
          <path d="M12 12v7.5" />
        </svg>
      );
    case "tray.and.arrow.up":
      return (
        <svg {...props}>
          <path d="M4.5 13.5h4l2 3h3l2-3h4V18a2 2 0 0 1-2 2h-11a2 2 0 0 1-2-2v-4.5Z" />
          <path d="M12 4.5v8" />
          <path d="m8.8 7.7 3.2-3.2 3.2 3.2" />
        </svg>
      );
    case "minus.circle":
      return (
        <svg {...props}>
          <circle cx="12" cy="12" r="8.5" />
          <path d="M8.5 12h7" />
        </svg>
      );
    case "slider.horizontal.3":
      return (
        <svg {...props}>
          <path d="M5 8h14" />
          <circle cx="9" cy="8" r="1.8" />
          <path d="M5 12h14" />
          <circle cx="15" cy="12" r="1.8" />
          <path d="M5 16h14" />
          <circle cx="11" cy="16" r="1.8" />
        </svg>
      );
    case "list.bullet.rectangle":
      return (
        <svg {...props}>
          <rect x="3" y="4" width="18" height="16" rx="2" />
          <line x1="8" y1="9" x2="17" y2="9" />
          <line x1="8" y1="12" x2="17" y2="12" />
          <line x1="8" y1="15" x2="14" y2="15" />
          <circle cx="5.5" cy="9" r="0.5" fill="currentColor" stroke="none" />
          <circle cx="5.5" cy="12" r="0.5" fill="currentColor" stroke="none" />
          <circle cx="5.5" cy="15" r="0.5" fill="currentColor" stroke="none" />
        </svg>
      );
    case "pip":
      return (
        <svg {...props}>
          <rect x="2" y="3" width="20" height="14" rx="2" />
          <rect x="12" y="13" width="10" height="8" rx="1.5" />
        </svg>
      );
    case "rectangle.compress.vertical":
      return (
        <svg {...props}>
          <rect x="4" y="5" width="16" height="14" rx="2.5" />
          <path d="m12 9-3 3" />
          <path d="M12 9V14H17" />
          <path d="m12 15 3-3" />
          <path d="M12 15V10H7" />
        </svg>
      );
    case "mic.fill":
      return (
        <svg {...props}>
          <rect x="9" y="2" width="6" height="11" rx="3" />
          <path d="M5 11a7 7 0 0 0 14 0" />
          <line x1="12" y1="18" x2="12" y2="22" />
          <line x1="9" y1="22" x2="15" y2="22" />
        </svg>
      );
    case "person.fill":
      return (
        <svg {...props}>
          <circle cx="12" cy="8.5" r="3.2" />
          <path d="M6.5 18.5a5.5 5.5 0 0 1 11 0" />
        </svg>
      );
    case "person.crop.circle":
      return (
        <svg {...props}>
          <circle cx="12" cy="12" r="10" />
          <circle cx="12" cy="10" r="3" />
          <path d="M5 19.5a7 7 0 0 1 14 0" />
        </svg>
      );
    default:
      return (
        <svg {...props}>
          <circle cx="12" cy="12" r="2.5" fill="currentColor" stroke="none" />
        </svg>
      );
  }
}
