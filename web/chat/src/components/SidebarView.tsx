import {
  memo,
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent as ReactDragEvent,
  type MouseEvent as ReactMouseEvent,
  type RefObject,
  type ReactNode,
} from "react";
import type {
  AssistantSidebarCollapsedPreviewPane,
  AssistantSidebarNavItem,
  AssistantSidebarNoteItem,
  AssistantSidebarProjectItem,
  AssistantSidebarSessionItem,
  AssistantSidebarState,
} from "../types";
import { AppIcon } from "./AppIcon";

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

type SidebarContextMenuSubmenu = {
  kind: "submenu";
  id: string;
  label: string;
  symbol?: string;
  entries: SidebarContextMenuEntry[];
};

type SidebarContextMenuEntry =
  | SidebarContextMenuAction
  | SidebarContextMenuSubmenu
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

type CollapsedPreviewState = {
  pane: AssistantSidebarCollapsedPreviewPane;
  top: number;
};

const PROJECT_ICON_OPTIONS = [
  { label: "Use Folder Icon", symbol: "folder.fill" },
  { label: "Use Stack Icon", symbol: "square.stack.3d.up.fill" },
  { label: "Use Briefcase Icon", symbol: "briefcase.fill" },
  { label: "Use Book Icon", symbol: "book.closed.fill" },
  { label: "Use Terminal Icon", symbol: "terminal.fill" },
  { label: "Use Sparkles Icon", symbol: "sparkles" },
  { label: "Use Star Icon", symbol: "star.fill" },
  { label: "Use Brain Icon", symbol: "brain" },
];

function sameSidebarID(left?: string | null, right?: string | null) {
  return (left || "").trim().toLowerCase() === (right || "").trim().toLowerCase();
}

function compactLabel(label: string, maxLength = 26) {
  const trimmed = label.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return `${trimmed.slice(0, maxLength - 1).trimEnd()}…`;
}

export function SidebarView({
  state,
  textScale = 1,
  onDispatchCommand,
}: {
  state: AssistantSidebarState | null;
  textScale?: number;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}) {
  const [contextMenu, setContextMenu] = useState<SidebarContextMenuState | null>(null);
  const [contextMenuPosition, setContextMenuPosition] = useState<{
    x: number;
    y: number;
  } | null>(null);
  const [collapsedPreview, setCollapsedPreview] = useState<CollapsedPreviewState | null>(null);
  const [draggedProjectId, setDraggedProjectId] = useState<string | null>(null);
  const [dropTargetProjectId, setDropTargetProjectId] = useState<string | null>(null);
  const [rootDropActive, setRootDropActive] = useState(false);
  const [noteSearch, setNoteSearch] = useState("");
  const contextMenuRef = useRef<HTMLDivElement | null>(null);
  const collapsedPreviewCloseRef = useRef<number | null>(null);
  const sidebarScaleStyle = {
    "--oa-sidebar-scale": String(Math.max(0.8, textScale)),
  } as CSSProperties;

  const closeContextMenu = () => {
    setContextMenu(null);
    setContextMenuPosition(null);
  };

  const clearCollapsedPreviewClose = () => {
    if (collapsedPreviewCloseRef.current !== null) {
      window.clearTimeout(collapsedPreviewCloseRef.current);
      collapsedPreviewCloseRef.current = null;
    }
  };

  const closeCollapsedPreview = () => {
    clearCollapsedPreviewClose();
    setCollapsedPreview(null);
    onDispatchCommand("setCollapsedPreviewPane", { open: false });
  };

  const scheduleCollapsedPreviewClose = () => {
    clearCollapsedPreviewClose();
    collapsedPreviewCloseRef.current = window.setTimeout(() => {
      setCollapsedPreview(null);
      onDispatchCommand("setCollapsedPreviewPane", { open: false });
    }, 120);
  };

  const openCollapsedPreview = (
    pane: AssistantSidebarCollapsedPreviewPane,
    top: number
  ) => {
    clearCollapsedPreviewClose();
    setCollapsedPreview({ pane, top });
    onDispatchCommand("setCollapsedPreviewPane", { pane, open: true });
  };

  useEffect(() => {
    if (!contextMenu) {
      return;
    }

    const handlePointerDown = (event: PointerEvent) => {
      if (!contextMenuRef.current?.contains(event.target as Node)) {
        closeContextMenu();
      }
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeContextMenu();
      }
    };

    const handleViewportChange = () => {
      closeContextMenu();
    };

    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("keydown", handleKeyDown);
    document.addEventListener("scroll", handleViewportChange, true);
    window.addEventListener("resize", handleViewportChange);
    window.addEventListener("blur", handleViewportChange);

    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("keydown", handleKeyDown);
      document.removeEventListener("scroll", handleViewportChange, true);
      window.removeEventListener("resize", handleViewportChange);
      window.removeEventListener("blur", handleViewportChange);
    };
  }, [contextMenu]);

  useEffect(() => {
    const handleCloseRequest = () => {
      closeContextMenu();
    };

    window.addEventListener("openassist:close-sidebar-context-menu", handleCloseRequest);
    return () => {
      window.removeEventListener(
        "openassist:close-sidebar-context-menu",
        handleCloseRequest
      );
    };
  }, []);

  useEffect(() => {
    if (!contextMenu || !contextMenuRef.current) {
      return;
    }

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

    if (
      !contextMenuPosition ||
      contextMenuPosition.x !== nextX ||
      contextMenuPosition.y !== nextY
    ) {
      setContextMenuPosition({ x: nextX, y: nextY });
    }
  }, [contextMenu, contextMenuPosition]);

  useEffect(
    () => () => {
      clearCollapsedPreviewClose();
    },
    []
  );

  useEffect(() => {
    if (!state?.isCollapsed) {
      clearCollapsedPreviewClose();
      setCollapsedPreview(null);
    }
  }, [state?.isCollapsed]);

  useEffect(() => {
    if (!state?.isCollapsed) {
      return;
    }

    if (state.collapsedPreviewPane) {
      setCollapsedPreview((current) =>
        current?.pane === state.collapsedPreviewPane
          ? current
          : {
              pane: state.collapsedPreviewPane,
              top: current?.top ?? 74,
            }
      );
      return;
    }

    setCollapsedPreview(null);
  }, [state?.collapsedPreviewPane, state?.isCollapsed]);

  useEffect(() => {
    setNoteSearch("");
  }, [state?.selectedPane, state?.selectedNotesProjectId, state?.notesScope]);

  if (!state) {
    return (
      <aside className="oa-react-sidebar" style={sidebarScaleStyle}>
        <div className="oa-react-sidebar__empty">Loading sidebar…</div>
      </aside>
    );
  }

  const openContextMenu = (
    event: ReactMouseEvent<HTMLElement>,
    entries: SidebarContextMenuEntry[]
  ) => {
    event.preventDefault();
    event.stopPropagation();

    if (!entries.length) {
      closeContextMenu();
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
    if (entry.disabled) {
      return;
    }
    closeContextMenu();
    onDispatchCommand(entry.command, entry.payload);
  };

  const sessionPane: "threads" | "archived" =
    state.selectedPane === "archived" ? "archived" : "threads";
  const sessions = sessionPane === "archived" ? state.archived : state.threads;
  const sessionsExpanded =
    sessionPane === "archived" ? state.archivedExpanded : state.threadsExpanded;
  const sessionsTitle =
    sessionPane === "archived" ? state.archivedTitle : state.threadsTitle;
  const sessionsHelper =
    sessionPane === "archived" ? state.archivedHelperText : state.threadsHelperText;
  const canLoadMore =
    sessionPane === "archived" ? state.canLoadMoreArchived : state.canLoadMoreThreads;
  const allSessions = [...state.threads, ...state.archived];
  const activeSession = allSessions.find((session) => session.isSelected) ?? null;
  const allKnownProjects = state.allProjects.length ? state.allProjects : state.projects;
  const availableProjects = allKnownProjects.filter(
    (project) => project.kind === "project"
  );
  const projectById = new Map(allKnownProjects.map((project) => [project.id, project]));
  const draggedProject = draggedProjectId ? projectById.get(draggedProjectId) ?? null : null;
  const projectInfoByID = new Map<
    string,
    { name: string; hasLinkedFolder: boolean; menuTitle: string }
  >(
    allKnownProjects.map((project) => [
      project.id,
      {
        name: project.name,
        hasLinkedFolder: project.hasLinkedFolder,
        menuTitle: project.menuTitle,
      },
    ])
  );
  const isNotesPane = state.selectedPane === "notes";
  const notesSearch = noteSearch.trim().toLowerCase();
  const filteredNotes = notesSearch
    ? state.notes.filter((note) => {
        const haystack = [note.title, note.subtitle, note.sourceLabel]
          .join(" ")
          .toLowerCase();
        return haystack.includes(notesSearch);
      })
    : state.notes;

  const projectSectionContextMenuEntries = (): SidebarContextMenuEntry[] => {
    const entries: SidebarContextMenuEntry[] = [
      {
        kind: "action",
        id: "create-folder",
        label: "Create Group",
        symbol: "square.grid.2x2",
        command: "createFolderPrompt",
      },
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
      { kind: "separator", id: "project-section-divider" },
    ];

    if (state.hiddenProjects.length) {
      entries.push({
        kind: "submenu",
        id: "project-section-unhide",
        label: "Unhide",
        symbol: "eye.slash",
        entries: hiddenProjectMenuEntries(),
      });
    } else {
      entries.push(...hiddenProjectMenuEntries());
    }

    return entries;
  };

  const hiddenProjectMenuEntries = (): SidebarContextMenuEntry[] => {
    if (state.hiddenProjects.length) {
      return [
        ...state.hiddenProjects.map<SidebarContextMenuEntry>((project) => ({
          kind: "action",
          id: `unhide-project-${project.id}`,
          label: `Unhide ${project.name}`,
          symbol: project.symbol,
          command: "unhideProject",
          payload: { projectId: project.id },
        })),
      ];
    }
    return [
      {
        kind: "note",
        id: "no-hidden-projects",
        label: "No hidden groups or projects right now",
      },
    ];
  };

  const projectContextMenuEntries = (
    project: AssistantSidebarProjectItem
  ): SidebarContextMenuEntry[] => {
    const entries: SidebarContextMenuEntry[] = [];

    if (project.kind === "project") {
      entries.push({
        kind: "action",
        id: `inspect-project-memory-${project.id}`,
        label: "Project Notes",
        symbol: "note.text",
        command: "openProjectNotes",
        payload: { projectId: project.id },
      });
    }

    if (project.kind === "project" && activeSession && !sameSidebarID(activeSession.projectId, project.id)) {
      entries.push(
        { kind: "separator", id: `project-move-divider-${project.id}` },
        {
          kind: "action",
          id: `move-selected-session-${project.id}`,
          label: `Move "${compactLabel(activeSession.title)}" Here`,
          symbol: "arrow.down.circle",
          command: "assignSessionToProject",
          payload: {
            sessionId: activeSession.id,
            projectId: project.id,
          },
        }
      );
    }

    entries.push(
      { kind: "separator", id: `project-edit-divider-${project.id}` },
      {
        kind: "action",
        id: `rename-project-${project.id}`,
        label: project.kind === "folder" ? "Rename Group" : "Rename Project",
        symbol: "pencil",
        command: "renameProjectPrompt",
        payload: { projectId: project.id },
      }
    );

    entries.push({
      kind: "submenu",
      id: `project-change-icon-${project.id}`,
      label: "Change Icon",
      symbol: project.symbol,
      entries: [
        {
          kind: "action",
          id: `project-default-icon-${project.id}`,
          label: "Use Default Icon",
          symbol: "arrow.counterclockwise",
          disabled: !project.hasCustomIcon,
          command: "setProjectIcon",
          payload: { projectId: project.id, symbol: "" },
        },
        { kind: "separator", id: `project-icon-divider-${project.id}` },
        ...PROJECT_ICON_OPTIONS.map<SidebarContextMenuEntry>((option) => ({
          kind: "action",
          id: `project-icon-${project.id}-${option.symbol}`,
          label: option.label,
          symbol: option.symbol,
          disabled: sameSidebarID(project.symbol, option.symbol),
          command: "setProjectIcon",
          payload: {
            projectId: project.id,
            symbol: option.symbol,
          },
        })),
        { kind: "separator", id: `project-icon-custom-divider-${project.id}` },
        {
          kind: "action",
          id: `project-custom-icon-${project.id}`,
          label: "Custom Symbol…",
          symbol: "sparkles",
          command: "changeProjectIconPrompt",
          payload: { projectId: project.id },
        },
      ],
    });

    if (project.kind === "project") {
      entries.push(
        { kind: "separator", id: `project-folder-divider-${project.id}` },
        {
          kind: "action",
          id: `project-folder-link-${project.id}`,
          label: project.hasLinkedFolder ? "Change Folder" : "Link Folder",
          symbol: "folder",
          command: "linkProjectFolder",
          payload: { projectId: project.id },
        },
        {
          kind: "action",
          id: `project-move-folder-${project.id}`,
          label: "Move to Group",
          symbol: "square.grid.2x2",
          command: "moveProjectToFolderPrompt",
          payload: { projectId: project.id },
        },
        {
          kind: "action",
          id: `project-move-root-${project.id}`,
          label: "Move to Top Level",
          symbol: "arrow.up.left.and.arrow.down.right",
          disabled: !project.parentId,
          command: "moveProjectToRoot",
          payload: { projectId: project.id },
        }
      );

      if (project.hasLinkedFolder) {
        entries.push({
          kind: "action",
          id: `project-folder-unlink-${project.id}`,
          label: "Remove Folder Link",
          symbol: "folder.badge.minus",
          command: "removeProjectFolderLink",
          payload: { projectId: project.id },
        });
      }
    } else {
      entries.push(
        {
          kind: "action",
          id: `folder-create-project-${project.id}`,
          label: "Create Project Inside Group",
          symbol: "plus",
          command: "createProjectInFolderPrompt",
          payload: { projectId: project.id },
        }
      );
    }

    entries.push(
      { kind: "separator", id: `project-danger-divider-${project.id}` },
      {
        kind: "action",
        id: `hide-project-${project.id}`,
        label: project.kind === "folder" ? "Hide Group" : "Hide Project",
        symbol: "eye.slash",
        command: "hideProject",
        payload: { projectId: project.id },
      },
      {
        kind: "action",
        id: `delete-project-${project.id}`,
        label: project.kind === "folder" ? "Delete Group" : "Delete Project",
        symbol: "trash",
        destructive: true,
        command: "deleteProject",
        payload: { projectId: project.id },
      }
    );

    return entries;
  };

  const threadContextMenuEntries = (
    session: AssistantSidebarSessionItem
  ): SidebarContextMenuEntry[] => {
    if (sessionPane === "archived") {
      return [
        {
          kind: "action",
          id: `unarchive-session-${session.id}`,
          label: "Unarchive Session",
          symbol: "tray.and.arrow.up",
          command: "unarchiveSession",
          payload: { sessionId: session.id },
        },
        { kind: "separator", id: `archived-session-divider-${session.id}` },
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
        label: "Rename Session",
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

    const projectEntries: SidebarContextMenuEntry[] = [];

    if (availableProjects.length) {
      projectEntries.push(
        ...availableProjects.map<SidebarContextMenuEntry>((project) => ({
          kind: "action",
          id: `assign-session-${session.id}-${project.id}`,
          label: `${session.projectId ? "Move to" : "Add to"} ${project.menuTitle}`,
          symbol: project.symbol,
          disabled: sameSidebarID(session.projectId, project.id),
          command: "assignSessionToProject",
          payload: {
            sessionId: session.id,
            projectId: project.id,
          },
        }))
      );
    } else {
      projectEntries.push({
        kind: "action",
        id: `create-project-for-session-${session.id}`,
        label: "Create Project",
        symbol: "plus",
        command: "createProjectPrompt",
      });
    }

    if (session.projectId) {
      projectEntries.push(
        { kind: "separator", id: `session-project-remove-divider-${session.id}` },
        {
        kind: "action",
        id: `remove-session-project-${session.id}`,
        label: "Remove from Project",
        symbol: "minus.circle",
        command: "removeSessionFromProject",
        payload: { sessionId: session.id },
        }
      );
    }

    entries.push(
      { kind: "separator", id: `session-project-divider-${session.id}` },
      {
        kind: "submenu",
        id: `session-projects-${session.id}`,
        label: "Projects",
        symbol: "folder",
        entries: projectEntries,
      },
      { kind: "separator", id: `session-archive-divider-${session.id}` },
      {
        kind: "submenu",
        id: `archive-session-submenu-${session.id}`,
        label: "Archive",
        symbol: "archivebox",
        entries: [
          {
            kind: "action",
            id: `archive-session-${session.id}`,
            label: "Archive Session",
            symbol: "archivebox",
            command: "archiveSession",
            payload: { sessionId: session.id },
          },
        ],
      },
    );

    return entries;
  };

  const resetProjectDragState = () => {
    setDraggedProjectId(null);
    setDropTargetProjectId(null);
    setRootDropActive(false);
  };

  const handleProjectDragStart = (
    event: ReactDragEvent<HTMLButtonElement>,
    project: AssistantSidebarProjectItem
  ) => {
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", project.id);
    setDraggedProjectId(project.id);
    setDropTargetProjectId(null);
    setRootDropActive(false);
  };

  const handleProjectDropIntoGroup = (
    event: ReactDragEvent<HTMLElement>,
    group: AssistantSidebarProjectItem
  ) => {
    if (group.kind !== "folder") {
      return;
    }
    const projectId = draggedProjectId ?? event.dataTransfer.getData("text/plain");
    const draggedProjectInfo = projectId ? projectById.get(projectId) ?? null : null;
    if (
      !projectId ||
      sameSidebarID(projectId, group.id) ||
      sameSidebarID(draggedProjectInfo?.parentId, group.id)
    ) {
      resetProjectDragState();
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    closeContextMenu();
    onDispatchCommand("moveProjectToFolder", {
      projectId,
      folderId: group.id,
    });
    resetProjectDragState();
  };

  const handleProjectDropToRoot = (event: ReactDragEvent<HTMLElement>) => {
    const projectId = draggedProjectId ?? event.dataTransfer.getData("text/plain");
    if (!projectId) {
      resetProjectDragState();
      return;
    }
    event.preventDefault();
    closeContextMenu();
    onDispatchCommand("moveProjectToRoot", { projectId });
    resetProjectDragState();
  };

  if (state.isCollapsed) {
    return (
      <CollapsedSidebarRail
        state={state}
        style={sidebarScaleStyle}
        preview={collapsedPreview}
        onPreviewEnter={openCollapsedPreview}
        onPreviewLeave={scheduleCollapsedPreviewClose}
        onPreviewHold={clearCollapsedPreviewClose}
        onDispatchCommand={onDispatchCommand}
      />
    );
  }

  return (
    <aside className="oa-react-sidebar" style={sidebarScaleStyle}>
      <div className="oa-react-sidebar__nav">
        {state.navItems.map((item) => (
          <NavButton
            key={item.id}
            item={item}
            isSelected={state.selectedPane === item.id}
            onClick={() => {
              closeContextMenu();
              onDispatchCommand("setSelectedPane", { pane: item.id });
            }}
          />
        ))}
        {state.canCollapse ? (
          <button
            type="button"
            className="oa-react-sidebar__icon-button oa-react-sidebar__collapse-btn"
            onClick={() => onDispatchCommand("setSidebarCollapsed", { collapsed: true })}
            title="Hide sidebar"
          >
            <SidebarIcon symbol="sidebar.left" />
          </button>
        ) : null}
      </div>

      <div className="oa-react-sidebar__scroll">
        {sessionPane === "archived" ? null : (
          <SidebarSection
            title={state.projectsTitle}
            helperText={state.projectsHelperText}
            expanded={state.projectsExpanded}
            onToggle={() => {
              closeContextMenu();
              onDispatchCommand("toggleProjectsExpanded");
            }}
            action={
              <button
                type="button"
                className="oa-react-sidebar__icon-button"
                onClick={() => {
                  closeContextMenu();
                  onDispatchCommand("createProjectPrompt");
                }}
                onContextMenu={(event) =>
                  openContextMenu(event, projectSectionContextMenuEntries())
                }
                title="Create group or project"
              >
                <SidebarIcon symbol="plus.square.on.square" />
              </button>
            }
          >
            {state.projects.length ? (
              <div className="oa-react-sidebar__list">
                {draggedProject?.parentId ? (
                  <div
                    className={`oa-react-sidebar__drop-target ${
                      rootDropActive ? "is-active" : ""
                    }`}
                    onDragOver={(event) => {
                      event.preventDefault();
                      event.dataTransfer.dropEffect = "move";
                      setRootDropActive(true);
                      setDropTargetProjectId(null);
                    }}
                    onDragLeave={() => {
                      setRootDropActive(false);
                    }}
                    onDrop={handleProjectDropToRoot}
                  >
                    Drop here to move this project to the top level
                  </div>
                ) : null}
                {state.projects.map((project) => (
                  <ProjectRow
                    key={project.id}
                    project={project}
                    onClick={() => {
                      closeContextMenu();
                      if (isNotesPane) {
                        onDispatchCommand("selectNotesProject", {
                          projectId: project.id,
                        });
                      } else {
                        onDispatchCommand("selectProjectFilter", {
                          projectId: project.isSelected ? "" : project.id,
                        });
                      }
                    }}
                    onToggleExpanded={() => {
                      if (project.kind !== "folder") {
                        return;
                      }
                      closeContextMenu();
                      onDispatchCommand("toggleProjectExpanded", {
                        projectId: project.id,
                        expanded: !project.isExpanded,
                      });
                    }}
                    onContextMenu={(event) =>
                      openContextMenu(event, projectContextMenuEntries(project))
                    }
                    onDragStart={(event) => handleProjectDragStart(event, project)}
                    onDragEnd={resetProjectDragState}
                    onDragOver={(event) => {
                      if (
                        project.kind !== "folder" ||
                        !draggedProject ||
                        sameSidebarID(draggedProject.id, project.id) ||
                        sameSidebarID(draggedProject.parentId, project.id)
                      ) {
                        return;
                      }
                      event.preventDefault();
                      event.stopPropagation();
                      event.dataTransfer.dropEffect = "move";
                      setDropTargetProjectId(project.id);
                      setRootDropActive(false);
                    }}
                    onDragLeave={() => {
                      if (sameSidebarID(dropTargetProjectId, project.id)) {
                        setDropTargetProjectId(null);
                      }
                    }}
                    onDrop={(event) => handleProjectDropIntoGroup(event, project)}
                    isDragging={sameSidebarID(draggedProjectId, project.id)}
                    isDropTarget={sameSidebarID(dropTargetProjectId, project.id)}
                  />
                ))}
              </div>
            ) : (
              <div className="oa-react-sidebar__empty">
                {state.hiddenProjectCount > 0
                  ? "Groups or projects are hidden right now. Right-click the add button to unhide them."
                  : "No projects yet."}
              </div>
            )}
          </SidebarSection>
        )}

        {isNotesPane ? (
          <SidebarSection
            title={state.notesTitle}
            helperText={state.notesHelperText}
            expanded={state.notesExpanded}
            onToggle={() => {
              closeContextMenu();
              onDispatchCommand("toggleNotesExpanded");
            }}
            action={
              state.canCreateProjectNote ? (
                <button
                  type="button"
                  className="oa-react-sidebar__icon-button oa-react-sidebar__new-thread"
                  onClick={() => {
                    closeContextMenu();
                    onDispatchCommand("createSidebarNote");
                  }}
                  title="New project note"
                >
                  <SidebarIcon symbol="plus" />
                </button>
              ) : undefined
            }
          >
            <div className="oa-react-sidebar__notes-toolbar">
              <div className="oa-react-sidebar__scope-toggle" role="tablist" aria-label="Note scope">
                <button
                  type="button"
                  className={`oa-react-sidebar__scope-pill ${
                    state.notesScope === "project" ? "is-selected" : ""
                  }`}
                  aria-pressed={state.notesScope === "project"}
                  onClick={() => {
                    closeContextMenu();
                    onDispatchCommand("setNotesScope", { scope: "project" });
                  }}
                >
                  Project notes
                </button>
                <button
                  type="button"
                  className={`oa-react-sidebar__scope-pill ${
                    state.notesScope === "thread" ? "is-selected" : ""
                  }`}
                  aria-pressed={state.notesScope === "thread"}
                  onClick={() => {
                    closeContextMenu();
                    onDispatchCommand("setNotesScope", { scope: "thread" });
                  }}
                >
                  Thread notes
                </button>
              </div>

              <input
                type="search"
                className="oa-react-sidebar__notes-search"
                value={noteSearch}
                onChange={(event) => setNoteSearch(event.target.value)}
                placeholder="Search notes"
                aria-label="Search notes"
              />
            </div>

            {filteredNotes.length ? (
              <div className="oa-react-sidebar__list">
                {filteredNotes.map((note) => (
                  <SidebarNoteRow
                    key={note.id}
                    note={note}
                    onClick={() => {
                      closeContextMenu();
                      onDispatchCommand("selectSidebarNote", {
                        ownerKind: note.ownerKind,
                        ownerId: note.ownerId,
                        noteId: note.noteId,
                      });
                    }}
                    onOpenThread={
                      note.threadId
                        ? () => {
                            closeContextMenu();
                            onDispatchCommand("openSession", {
                              sessionId: note.threadId,
                              pane: "threads",
                            });
                          }
                        : undefined
                    }
                  />
                ))}
              </div>
            ) : (
              <div className="oa-react-sidebar__empty">
                {noteSearch.trim()
                  ? `No notes match "${noteSearch.trim()}".`
                  : state.notesScope === "project"
                    ? "No project notes yet."
                    : "No thread notes yet for this project."}
              </div>
            )}
          </SidebarSection>
        ) : (
          <SidebarSection
            title={sessionsTitle}
            helperText={sessionsHelper}
            expanded={sessionsExpanded}
            onToggle={() => {
              closeContextMenu();
              onDispatchCommand(
                sessionPane === "archived" ? "toggleArchivedExpanded" : "toggleThreadsExpanded"
              );
            }}
            action={
              sessionPane === "threads" ? (
                <button
                  type="button"
                  className="oa-react-sidebar__icon-button oa-react-sidebar__new-thread"
                  disabled={!state.canCreateThread}
                  onClick={() => {
                    closeContextMenu();
                    onDispatchCommand("newThread");
                  }}
                  title={
                    state.canCreateThread
                      ? "New thread"
                      : "You can't start a new thread right now."
                  }
                >
                  <SidebarIcon symbol="plus" />
                </button>
              ) : undefined
            }
          >
            {sessions.length ? (
              <div className="oa-react-sidebar__list">
                {sessions.map((session) => (
                  <SessionRow
                    key={session.id}
                    session={session}
                    projectName={(() => {
                      if (!session.projectId) {
                        return undefined;
                      }
                      const projectInfo = projectInfoByID.get(session.projectId);
                      if (!projectInfo) {
                        return undefined;
                      }
                      return state.projectFilterKind === "folder" || projectInfo.hasLinkedFolder
                        ? projectInfo.name
                        : undefined;
                    })()}
                    onClick={() => {
                      closeContextMenu();
                      onDispatchCommand("openSession", {
                        sessionId: session.id,
                        pane: sessionPane,
                      });
                    }}
                    onContextMenu={(event) =>
                      openContextMenu(event, threadContextMenuEntries(session))
                    }
                  />
                ))}
              </div>
            ) : (
              <div className="oa-react-sidebar__empty">
                {sessionPane === "archived" ? "No archived chats." : "No threads yet."}
              </div>
            )}

            {canLoadMore ? (
              <button
                type="button"
                className="oa-react-sidebar__load-more"
                onClick={() => {
                  closeContextMenu();
                  onDispatchCommand("loadMoreSessions");
                }}
              >
                Load more
              </button>
            ) : null}
          </SidebarSection>
        )}
      </div>

      <div className="oa-react-sidebar__footer">
        <button
          type="button"
          className="oa-react-sidebar__footer-button"
          onClick={() => {
            closeContextMenu();
            onDispatchCommand("openAssistantSetup");
          }}
        >
          <SidebarIcon symbol="gearshape" />
          <span>Settings</span>
        </button>

        <button
          type="button"
          className={`oa-react-sidebar__footer-button ${
            state.selectedPane === "archived" ? "is-selected" : ""
          }`}
          onClick={() => {
            closeContextMenu();
            onDispatchCommand("setSelectedPane", { pane: "archived" });
          }}
        >
          <SidebarIcon symbol="archivebox" />
          <span>Archived</span>
          {state.archivedCount > 0 ? (
            <span className="oa-react-sidebar__count">{state.archivedCount}</span>
          ) : null}
        </button>
      </div>

      {contextMenu ? (
        <SidebarContextMenu
          menuRef={contextMenuRef}
          entries={contextMenu.entries}
          position={contextMenuPosition ?? { x: contextMenu.x, y: contextMenu.y }}
          onSelect={dispatchContextMenuCommand}
        />
      ) : null}
    </aside>
  );
}

const NavButton = memo(function NavButton({
  item,
  isSelected,
  onClick,
}: {
  item: AssistantSidebarNavItem;
  isSelected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className={`oa-react-sidebar__nav-button ${isSelected ? "is-selected" : ""}`}
      onClick={onClick}
    >
      <SidebarIcon symbol={item.symbol} />
      <span>{item.label}</span>
    </button>
  );
});

const SidebarSection = memo(function SidebarSection({
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
    <section className="oa-react-sidebar__section">
      <div className="oa-react-sidebar__section-header">
        <button
          type="button"
          className="oa-react-sidebar__section-toggle"
          onClick={onToggle}
        >
          <span>{title}</span>
          <span
            className={`oa-react-sidebar__section-chevron ${
              expanded ? "is-open" : ""
            }`}
          >
            <SidebarIcon symbol="chevron.down" />
          </span>
        </button>
        {action ? <div className="oa-react-sidebar__section-action">{action}</div> : null}
      </div>

      {helperText ? <div className="oa-react-sidebar__section-helper">{helperText}</div> : null}
      {expanded ? children : null}
    </section>
  );
});

const ProjectRow = memo(function ProjectRow({
  project,
  onClick,
  onToggleExpanded,
  onContextMenu,
  onDragStart,
  onDragEnd,
  onDragOver,
  onDragLeave,
  onDrop,
  isDragging,
  isDropTarget,
}: {
  project: AssistantSidebarProjectItem;
  onClick: () => void;
  onToggleExpanded: () => void;
  onContextMenu: (event: ReactMouseEvent<HTMLButtonElement>) => void;
  onDragStart: (event: ReactDragEvent<HTMLButtonElement>) => void;
  onDragEnd: () => void;
  onDragOver: (event: ReactDragEvent<HTMLButtonElement>) => void;
  onDragLeave: () => void;
  onDrop: (event: ReactDragEvent<HTMLButtonElement>) => void;
  isDragging: boolean;
  isDropTarget: boolean;
}) {
  const style = {
    paddingLeft: `calc(${10 + project.depth * 18}px * var(--oa-sidebar-scale))`,
  } as CSSProperties;

  return (
    <button
      type="button"
      className={`oa-react-sidebar__row oa-react-sidebar__row--project ${
        project.kind === "folder" ? "oa-react-sidebar__row--folder" : ""
      } ${project.isSelected ? "is-selected" : ""} ${
        isDropTarget ? "is-drop-target" : ""
      } ${isDragging ? "is-dragging" : ""}`}
      onClick={onClick}
      onContextMenu={onContextMenu}
      draggable={project.kind === "project"}
      onDragStart={onDragStart}
      onDragEnd={onDragEnd}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
      style={style}
    >
      {project.kind === "folder" ? (
        <span
          className="oa-react-sidebar__row-folder-chevron oa-react-sidebar__row-folder-chevron--interactive"
          onClick={(event) => {
            event.preventDefault();
            event.stopPropagation();
            onToggleExpanded();
          }}
        >
          <SidebarIcon symbol={project.isExpanded ? "chevron.down" : "chevron.right"} />
        </span>
      ) : (
        <span className="oa-react-sidebar__row-folder-chevron oa-react-sidebar__row-folder-chevron--spacer" />
      )}
      <span className="oa-react-sidebar__row-icon">
        <SidebarIcon symbol={project.symbol} />
      </span>
      <span className="oa-react-sidebar__row-copy">
        <span className="oa-react-sidebar__row-title-line">
          <span className="oa-react-sidebar__row-title-wrap">
            <span className="oa-react-sidebar__row-title">{project.name}</span>
          </span>
        </span>
        <span className="oa-react-sidebar__row-subtitle">{project.subtitle}</span>
      </span>
    </button>
  );
});

const SessionRow = memo(function SessionRow({
  session,
  projectName,
  onClick,
  onContextMenu,
}: {
  session: AssistantSidebarSessionItem;
  projectName?: string;
  onClick: () => void;
  onContextMenu: (event: ReactMouseEvent<HTMLButtonElement>) => void;
}) {
  const isWorking =
    session.activityState === "running" || session.activityState === "waiting";

  return (
    <button
      type="button"
      className={`oa-react-sidebar__row oa-react-sidebar__row--session ${
        session.isSelected ? "is-selected" : ""
      }`}
      onClick={onClick}
      onContextMenu={onContextMenu}
    >
      <span className="oa-react-sidebar__row-copy">
        <span className="oa-react-sidebar__row-title-line">
          <span className="oa-react-sidebar__row-title-wrap">
            {isWorking ? (
              <span
                aria-hidden="true"
                className={`oa-react-sidebar__thread-activity oa-react-sidebar__thread-activity--${
                  session.activityState ?? "running"
                }`}
              />
            ) : null}
            <span className="oa-react-sidebar__row-title">{session.title}</span>
          </span>
          {session.timeLabel ? (
            <span className="oa-react-sidebar__row-meta">{session.timeLabel}</span>
          ) : null}
        </span>
        {projectName ? (
          <span className="oa-react-sidebar__row-subtitle">{projectName}</span>
        ) : null}
      </span>
      {session.isTemporary ? (
        <span className="oa-react-sidebar__badge">Temp</span>
      ) : null}
    </button>
  );
});

const SidebarNoteRow = memo(function SidebarNoteRow({
  note,
  onClick,
  onOpenThread,
}: {
  note: AssistantSidebarNoteItem;
  onClick: () => void;
  onOpenThread?: () => void;
}) {
  return (
    <button
      type="button"
      className={`oa-react-sidebar__row oa-react-sidebar__row--note ${
        note.isSelected ? "is-selected" : ""
      }`}
      onClick={onClick}
    >
      <span className="oa-react-sidebar__row-icon">
        <SidebarIcon symbol={note.ownerKind === "project" ? "note.text" : "text.bubble"} />
      </span>
      <span className="oa-react-sidebar__row-copy">
        <span className="oa-react-sidebar__row-title-line">
          <span className="oa-react-sidebar__row-title-wrap">
            <span className="oa-react-sidebar__row-title">{note.title}</span>
          </span>
          {note.isArchivedThread ? (
            <span className="oa-react-sidebar__row-meta">Archived</span>
          ) : null}
        </span>
        <span className="oa-react-sidebar__row-subtitle">{note.subtitle}</span>
      </span>
      {onOpenThread ? (
        <button
          type="button"
          className="oa-react-sidebar__row-badge oa-react-sidebar__row-badge--link"
          onClick={(event) => {
            event.preventDefault();
            event.stopPropagation();
            onOpenThread();
          }}
        >
          Open
        </button>
      ) : null}
    </button>
  );
});

function CollapsedSidebarRail({
  state,
  style,
  preview,
  onPreviewEnter,
  onPreviewLeave,
  onPreviewHold,
  onDispatchCommand,
}: {
  state: AssistantSidebarState;
  style?: CSSProperties;
  preview: CollapsedPreviewState | null;
  onPreviewEnter: (pane: AssistantSidebarCollapsedPreviewPane, top: number) => void;
  onPreviewLeave: () => void;
  onPreviewHold: () => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}) {
  const hasSelectedProject = state.projects.some((project) => project.isSelected);
  const hasSelectedNotesProject = state.projects.some(
    (project) => project.id === state.selectedNotesProjectId
  );

  return (
    <aside className="oa-react-sidebar oa-react-sidebar--collapsed" style={style}>
      <div className="oa-react-sidebar__collapsed-shell" onMouseLeave={onPreviewLeave}>
        <div className="oa-react-sidebar__collapsed-rail">
          <div className="oa-react-sidebar__collapsed-group">
            <CollapsedRailButton
              symbol="sidebar.right"
              label="Expand sidebar"
              onClick={() => onDispatchCommand("setSidebarCollapsed", { collapsed: false })}
            />
            <CollapsedRailButton
              symbol="bubble.left.and.bubble.right"
              label="Threads"
              isSelected={state.selectedPane === "threads"}
              onMouseEnter={(event) =>
                onPreviewEnter("threads", event.currentTarget.offsetTop - 8)
              }
              onClick={() => onDispatchCommand("setSelectedPane", { pane: "threads" })}
            />
            <CollapsedRailButton
              symbol="note.text"
              label="Notes"
              isSelected={state.selectedPane === "notes"}
              onMouseEnter={(event) =>
                onPreviewEnter("notes", event.currentTarget.offsetTop - 8)
              }
              onClick={() => onDispatchCommand("setSelectedPane", { pane: "notes" })}
            />
            <CollapsedRailButton
              symbol="square.grid.2x2"
              label="Projects"
              isSelected={state.selectedPane === "notes" ? hasSelectedNotesProject : hasSelectedProject}
              onMouseEnter={(event) =>
                onPreviewEnter("projects", event.currentTarget.offsetTop - 8)
              }
              onClick={() => onDispatchCommand("setSelectedPane", { pane: "threads" })}
            />
            <CollapsedRailButton
              symbol="archivebox"
              label="Archived"
              isSelected={state.selectedPane === "archived"}
              onMouseEnter={(event) =>
                onPreviewEnter("archived", event.currentTarget.offsetTop - 8)
              }
              onClick={() => onDispatchCommand("setSelectedPane", { pane: "archived" })}
            />
            <CollapsedRailButton
              symbol="clock"
              label="Automations"
              isSelected={state.selectedPane === "automations"}
              onMouseEnter={(event) =>
                onPreviewEnter("automations", event.currentTarget.offsetTop - 8)
              }
              onClick={() => onDispatchCommand("setSelectedPane", { pane: "automations" })}
            />
            <CollapsedRailButton
              symbol="sparkles"
              label="Skills"
              isSelected={state.selectedPane === "skills"}
              onMouseEnter={(event) =>
                onPreviewEnter("skills", event.currentTarget.offsetTop - 8)
              }
              onClick={() => onDispatchCommand("setSelectedPane", { pane: "skills" })}
            />
          </div>

          <div className="oa-react-sidebar__collapsed-spacer" />

          <CollapsedRailButton
            symbol="gearshape"
            label="Settings"
            onClick={() => onDispatchCommand("openAssistantSetup")}
          />
        </div>

        {preview ? (
          <CollapsedSidebarPreview
            state={state}
            preview={preview}
            onMouseEnter={onPreviewHold}
            onMouseLeave={onPreviewLeave}
            onDispatchCommand={onDispatchCommand}
          />
        ) : null}
      </div>
    </aside>
  );
}

function CollapsedRailButton({
  symbol,
  label,
  isSelected = false,
  isAccent = false,
  onClick,
  onMouseEnter,
}: {
  symbol: string;
  label: string;
  isSelected?: boolean;
  isAccent?: boolean;
  onClick: () => void;
  onMouseEnter?: (event: ReactMouseEvent<HTMLButtonElement>) => void;
}) {
  return (
    <button
      type="button"
      className={[
        "oa-react-sidebar__rail-button",
        isSelected ? "is-selected" : "",
        isAccent ? "is-accent" : "",
      ]
        .filter(Boolean)
        .join(" ")}
      onClick={onClick}
      onMouseEnter={onMouseEnter}
      title={label}
      aria-label={label}
    >
      <SidebarIcon symbol={symbol} />
    </button>
  );
}

function CollapsedSidebarPreview({
  state,
  preview,
  onMouseEnter,
  onMouseLeave,
  onDispatchCommand,
}: {
  state: AssistantSidebarState;
  preview: CollapsedPreviewState;
  onMouseEnter: () => void;
  onMouseLeave: () => void;
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}) {
  const style = {
    "--oa-sidebar-preview-top": `${preview.top}px`,
  } as CSSProperties;

  const projectItems = state.projects.slice(0, 4);
  const noteItems = state.notes.slice(0, 4);
  const threadItems = state.threads.slice(0, 4);
  const archivedItems = state.archived.slice(0, 4);

  return (
    <div
      className="oa-react-sidebar__collapsed-preview"
      style={style}
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
    >
      <div className="oa-react-sidebar__collapsed-preview-title">
        {preview.pane === "projects"
          ? "Projects"
          : preview.pane === "notes"
            ? "Notes"
          : preview.pane === "threads"
            ? "Threads"
            : preview.pane === "archived"
              ? "Archived"
              : preview.pane === "automations"
                ? "Automations"
                : "Skills"}
      </div>

      {preview.pane === "projects" ? (
        projectItems.length ? (
          <div className="oa-react-sidebar__collapsed-preview-list">
            {projectItems.map((project) => (
              <button
                key={project.id}
                type="button"
                className={`oa-react-sidebar__collapsed-preview-row ${
                  project.isSelected ? "is-selected" : ""
                }`}
                onClick={() => {
                  if (state.selectedPane === "notes") {
                    onDispatchCommand("setSelectedPane", { pane: "notes" });
                    onDispatchCommand("selectNotesProject", {
                      projectId: project.id,
                    });
                  } else {
                    onDispatchCommand("setSelectedPane", { pane: "threads" });
                    onDispatchCommand("selectProjectFilter", {
                      projectId: project.isSelected ? "" : project.id,
                    });
                  }
                }}
              >
                <span className="oa-react-sidebar__collapsed-preview-icon">
                  <SidebarIcon symbol={project.symbol} />
                </span>
                <span className="oa-react-sidebar__collapsed-preview-copy">
                  <span className="oa-react-sidebar__collapsed-preview-name">
                    {project.name}
                  </span>
                  <span className="oa-react-sidebar__collapsed-preview-meta">
                    {project.subtitle}
                  </span>
                </span>
              </button>
            ))}
          </div>
        ) : (
          <div className="oa-react-sidebar__collapsed-preview-note">
            {state.hiddenProjectCount > 0
              ? "Groups or projects are hidden right now."
              : "No projects yet."}
          </div>
        )
      ) : null}

      {preview.pane === "notes" ? (
        noteItems.length ? (
          <div className="oa-react-sidebar__collapsed-preview-list">
            {noteItems.map((note) => (
              <button
                key={note.id}
                type="button"
                className={`oa-react-sidebar__collapsed-preview-row ${
                  note.isSelected ? "is-selected" : ""
                }`}
                onClick={() => {
                  onDispatchCommand("setSelectedPane", { pane: "notes" });
                  onDispatchCommand("selectSidebarNote", {
                    ownerKind: note.ownerKind,
                    ownerId: note.ownerId,
                    noteId: note.noteId,
                  });
                }}
              >
                <span className="oa-react-sidebar__collapsed-preview-icon">
                  <SidebarIcon
                    symbol={note.ownerKind === "project" ? "note.text" : "text.bubble"}
                  />
                </span>
                <span className="oa-react-sidebar__collapsed-preview-copy">
                  <span className="oa-react-sidebar__collapsed-preview-name">
                    {note.title}
                  </span>
                  <span className="oa-react-sidebar__collapsed-preview-meta">
                    {note.subtitle}
                  </span>
                </span>
              </button>
            ))}
          </div>
        ) : (
          <div className="oa-react-sidebar__collapsed-preview-note">
            {state.notesScope === "project"
              ? "No project notes yet."
              : "No thread notes yet for this project."}
          </div>
        )
      ) : null}

      {preview.pane === "threads" ? (
        threadItems.length ? (
          <div className="oa-react-sidebar__collapsed-preview-list">
            {threadItems.map((session) => (
              <CollapsedSessionPreviewRow
                key={session.id}
                session={session}
                pane="threads"
                onDispatchCommand={onDispatchCommand}
              />
            ))}
          </div>
        ) : (
          <div className="oa-react-sidebar__collapsed-preview-note">
            No threads yet.
          </div>
        )
      ) : null}

      {preview.pane === "archived" ? (
        archivedItems.length ? (
          <div className="oa-react-sidebar__collapsed-preview-list">
            {archivedItems.map((session) => (
              <CollapsedSessionPreviewRow
                key={session.id}
                session={session}
                pane="archived"
                onDispatchCommand={onDispatchCommand}
              />
            ))}
          </div>
        ) : (
          <div className="oa-react-sidebar__collapsed-preview-note">
            No archived chats.
          </div>
        )
      ) : null}

      {preview.pane === "automations" ? (
        <div className="oa-react-sidebar__collapsed-preview-note">
          Hover preview is not available here yet. Click the clock to open automations.
        </div>
      ) : null}

      {preview.pane === "skills" ? (
        <div className="oa-react-sidebar__collapsed-preview-note">
          Hover preview is not available here yet. Click the sparkles icon to open skills.
        </div>
      ) : null}
    </div>
  );
}

function CollapsedSessionPreviewRow({
  session,
  pane,
  onDispatchCommand,
}: {
  session: AssistantSidebarSessionItem;
  pane: "threads" | "archived";
  onDispatchCommand: (type: string, payload?: Record<string, unknown>) => void;
}) {
  return (
    <button
      type="button"
      className={`oa-react-sidebar__collapsed-preview-row oa-react-sidebar__collapsed-preview-row--session ${
        session.isSelected ? "is-selected" : ""
      }`}
      onClick={() =>
        onDispatchCommand("openSession", {
          sessionId: session.id,
          pane,
        })
      }
    >
      <span className="oa-react-sidebar__collapsed-preview-copy">
        <span className="oa-react-sidebar__collapsed-preview-name">{session.title}</span>
      </span>
      {session.timeLabel ? (
        <span className="oa-react-sidebar__collapsed-preview-time">
          {session.timeLabel}
        </span>
      ) : null}
    </button>
  );
}

function SidebarIcon({ symbol }: { symbol: string }) {
  return (
    <AppIcon
      symbol={symbol}
      className="oa-react-sidebar__icon-svg"
      strokeWidth={1.9}
    />
  );
}

function SidebarContextMenu({
  menuRef,
  entries,
  position,
  onSelect,
}: {
  menuRef: RefObject<HTMLDivElement | null>;
  entries: SidebarContextMenuEntry[];
  position: { x: number; y: number };
  onSelect: (entry: SidebarContextMenuAction) => void;
}) {
  const [activeSubmenu, setActiveSubmenu] = useState<SidebarContextMenuSubmenu | null>(
    null
  );

  useEffect(() => {
    setActiveSubmenu(null);
  }, [entries]);

  const displayedEntries = activeSubmenu ? activeSubmenu.entries : entries;

  return (
    <div
      ref={menuRef}
      className="oa-react-context-menu"
      role="menu"
      onContextMenu={(event) => event.preventDefault()}
      style={
        {
          "--oa-context-menu-x": `${position.x}px`,
          "--oa-context-menu-y": `${position.y}px`,
        } as CSSProperties
      }
    >
      {activeSubmenu ? (
        <div className="oa-react-context-menu__header">
          <button
            type="button"
            className="oa-react-context-menu__back"
            onClick={() => setActiveSubmenu(null)}
          >
            <AppIcon symbol="chevron.left" size={13} />
            <span>Back</span>
          </button>
          <div className="oa-react-context-menu__title">{activeSubmenu.label}</div>
        </div>
      ) : null}

      {displayedEntries.map((entry) => {
        if (entry.kind === "separator") {
          return (
            <div
              key={entry.id}
              className="oa-react-context-menu__separator"
              role="separator"
            />
          );
        }

        if (entry.kind === "note") {
          return (
            <div key={entry.id} className="oa-react-context-menu__note">
              {entry.label}
            </div>
          );
        }

        if (entry.kind === "submenu") {
          return (
            <button
              key={entry.id}
              type="button"
              role="menuitem"
              className="oa-react-context-menu__item oa-react-context-menu__item--submenu"
              onClick={() => setActiveSubmenu(entry)}
            >
              <span className="oa-react-context-menu__item-main">
                <span className="oa-react-context-menu__item-icon">
                  {entry.symbol ? <AppIcon symbol={entry.symbol} size={14} /> : null}
                </span>
                <span>{entry.label}</span>
              </span>
              <span className="oa-react-context-menu__item-trailing">
                <AppIcon symbol="chevron.right" size={13} />
              </span>
            </button>
          );
        }

        return (
          <button
            key={entry.id}
            type="button"
            role="menuitem"
            className={`oa-react-context-menu__item ${
              entry.destructive ? "is-destructive" : ""
            }`}
            disabled={entry.disabled}
            onClick={() => onSelect(entry)}
          >
            <span className="oa-react-context-menu__item-main">
              <span className="oa-react-context-menu__item-icon">
                {entry.symbol ? <AppIcon symbol={entry.symbol} size={14} /> : null}
              </span>
              <span>{entry.label}</span>
            </span>
          </button>
        );
      })}
    </div>
  );
}
