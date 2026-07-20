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
  AssistantSidebarNoteFolderItem,
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

const SIDEBAR_ICON_ALIASES: Record<string, string> = {
  clock: "workflow",
};

function sameSidebarID(left?: string | null, right?: string | null) {
  return normalizedSidebarKey(left) === normalizedSidebarKey(right);
}

function normalizedSidebarKey(value?: string | null) {
  return (value || "").trim().toLowerCase();
}

function compactLabel(label: string, maxLength = 26) {
  const trimmed = label.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return `${trimmed.slice(0, maxLength - 1).trimEnd()}…`;
}

function resolveSidebarIconSymbol(symbol: string) {
  return SIDEBAR_ICON_ALIASES[symbol] ?? symbol;
}

type ProjectNoteTreeFolderRow = {
  kind: "folder";
  folder: AssistantSidebarNoteFolderItem;
  depth: number;
  isExpanded: boolean;
};

type ProjectNoteTreeNoteRow = {
  kind: "note";
  note: AssistantSidebarNoteItem;
  depth: number;
};

type ProjectNoteTreeRow = ProjectNoteTreeFolderRow | ProjectNoteTreeNoteRow;

function noteFolderPathLabel(path: string[]) {
  return path.join(" / ");
}

function compareNoteFolders(
  left: AssistantSidebarNoteFolderItem,
  right: AssistantSidebarNoteFolderItem
) {
  const nameCompare = left.name.localeCompare(right.name, undefined, {
    sensitivity: "base",
  });
  if (nameCompare !== 0) {
    return nameCompare;
  }
  return left.id.localeCompare(right.id, undefined, { sensitivity: "base" });
}

function noteFolderSubtitle(folder: AssistantSidebarNoteFolderItem) {
  const countParts = [];
  if (folder.childFolderCount > 0) {
    countParts.push(
      `${folder.childFolderCount} ${folder.childFolderCount === 1 ? "folder" : "folders"}`
    );
  }
  if (folder.noteCount > 0) {
    countParts.push(`${folder.noteCount} ${folder.noteCount === 1 ? "note" : "notes"}`);
  }
  return (
    countParts.join(" · ") ||
    (folder.path.length > 1 ? folder.path.slice(0, -1).join(" / ") : "Empty folder")
  );
}

function buildProjectNoteFolderPanel({
  folders,
  notes,
  activeFolderId,
}: {
  folders: AssistantSidebarNoteFolderItem[];
  notes: AssistantSidebarNoteItem[];
  activeFolderId?: string | null;
}) {
  const folderById = new Map(
    folders.map((folder) => [normalizedSidebarKey(folder.id), folder] as const)
  );
  const childFoldersByParent = new Map<string, AssistantSidebarNoteFolderItem[]>();
  const notesByFolder = new Map<string, AssistantSidebarNoteItem[]>();

  for (const folder of folders) {
    const parentKey = normalizedSidebarKey(folder.parentId);
    const siblings = childFoldersByParent.get(parentKey) ?? [];
    siblings.push(folder);
    childFoldersByParent.set(parentKey, siblings);
  }

  for (const siblings of childFoldersByParent.values()) {
    siblings.sort(compareNoteFolders);
  }

  for (const note of notes) {
    const folderKey = normalizedSidebarKey(note.folderId);
    const siblings = notesByFolder.get(folderKey) ?? [];
    siblings.push(note);
    notesByFolder.set(folderKey, siblings);
  }

  const currentFolder = folderById.get(normalizedSidebarKey(activeFolderId)) ?? null;
  const currentFolderKey = normalizedSidebarKey(currentFolder?.id);
  const parentFolder = currentFolder?.parentId
    ? folderById.get(normalizedSidebarKey(currentFolder.parentId)) ?? null
    : null;

  return {
    currentFolder,
    parentFolder,
    childFolders: childFoldersByParent.get(currentFolderKey) ?? [],
    notes: notesByFolder.get(currentFolderKey) ?? [],
  };
}

function buildProjectNoteTree({
  folders,
  notes,
  search,
}: {
  folders: AssistantSidebarNoteFolderItem[];
  notes: AssistantSidebarNoteItem[];
  search: string;
}): ProjectNoteTreeRow[] {
  const normalizedSearch = search.trim().toLowerCase();
  const folderById = new Map(
    folders.map((folder) => [normalizedSidebarKey(folder.id), folder] as const)
  );
  const childFoldersByParent = new Map<string, AssistantSidebarNoteFolderItem[]>();
  const notesByFolder = new Map<string, AssistantSidebarNoteItem[]>();

  const sortedFolders = [...folders].sort((left, right) => {
    const leftLabel = noteFolderPathLabel(left.path);
    const rightLabel = noteFolderPathLabel(right.path);
    const pathCompare = leftLabel.localeCompare(rightLabel, undefined, {
      sensitivity: "base",
    });
    if (pathCompare !== 0) {
      return pathCompare;
    }
    return left.id.localeCompare(right.id, undefined, { sensitivity: "base" });
  });

  for (const folder of sortedFolders) {
    const parentKey = normalizedSidebarKey(folder.parentId);
    const siblings = childFoldersByParent.get(parentKey) ?? [];
    siblings.push(folder);
    childFoldersByParent.set(parentKey, siblings);
  }

  for (const note of notes) {
    const folderKey = normalizedSidebarKey(note.folderId);
    const siblings = notesByFolder.get(folderKey) ?? [];
    siblings.push(note);
    notesByFolder.set(folderKey, siblings);
  }

  const visibleFolderIds = new Set<string>();
  const visibleNoteIds = new Set<string>();
  const expandedFolderIds = new Set<string>();

  if (normalizedSearch) {
    for (const note of notes) {
      const folder = folderById.get(normalizedSidebarKey(note.folderId));
      const haystack = [
        note.title,
        note.subtitle,
        note.sourceLabel,
        folder?.name ?? "",
        noteFolderPathLabel(note.folderPath),
      ]
        .join(" ")
        .toLowerCase();
      if (!haystack.includes(normalizedSearch)) {
        continue;
      }

      visibleNoteIds.add(note.id);
      let cursor = note.folderId;
      while (cursor) {
        const cursorKey = normalizedSidebarKey(cursor);
        if (!cursorKey || visibleFolderIds.has(cursorKey)) {
          break;
        }
        visibleFolderIds.add(cursorKey);
        expandedFolderIds.add(cursorKey);
        cursor = folderById.get(cursorKey)?.parentId;
      }
    }
  } else {
    for (const note of notes) {
      visibleNoteIds.add(note.id);
    }
    for (const folder of folders) {
      const folderKey = normalizedSidebarKey(folder.id);
      visibleFolderIds.add(folderKey);
      if (folder.isExpanded) {
        expandedFolderIds.add(folderKey);
      }
    }
  }

  const rows: ProjectNoteTreeRow[] = [];

  const visit = (parentId: string | undefined, depth: number) => {
    const parentKey = normalizedSidebarKey(parentId);
    const childFolders = childFoldersByParent.get(parentKey) ?? [];
    const childNotes = notesByFolder.get(parentKey) ?? [];

    for (const folder of childFolders) {
      const folderKey = normalizedSidebarKey(folder.id);
      if (normalizedSearch && !visibleFolderIds.has(folderKey)) {
        continue;
      }

      const isExpanded = normalizedSearch ? true : expandedFolderIds.has(folderKey);
      rows.push({
        kind: "folder",
        folder,
        depth,
        isExpanded,
      });

      if (isExpanded) {
        visit(folder.id, depth + 1);
      }
    }

    for (const note of childNotes) {
      if (normalizedSearch && !visibleNoteIds.has(note.id)) {
        continue;
      }
      rows.push({
        kind: "note",
        note,
        depth,
      });
    }
  };

  visit(undefined, 0);
  return rows;
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
  const [draggedProjectNoteId, setDraggedProjectNoteId] = useState<string | null>(null);
  const [draggedProjectNoteFolderId, setDraggedProjectNoteFolderId] = useState<string | null>(
    null
  );
  const [dropTargetNoteFolderId, setDropTargetNoteFolderId] = useState<string | null>(null);
  const [noteRootDropActive, setNoteRootDropActive] = useState(false);
  const [noteSearch, setNoteSearch] = useState("");
  const [activeProjectNoteFolderId, setActiveProjectNoteFolderId] = useState<string | null>(
    null
  );
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

  useEffect(() => {
    setActiveProjectNoteFolderId(null);
  }, [state?.selectedNotesProjectId, state?.notesScope]);

  useEffect(() => {
    if (
      !activeProjectNoteFolderId ||
      (state?.noteFolders ?? []).some((folder) =>
        sameSidebarID(folder.id, activeProjectNoteFolderId)
      )
    ) {
      return;
    }
    setActiveProjectNoteFolderId(null);
  }, [activeProjectNoteFolderId, state?.noteFolders]);

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

  const openAnchoredContextMenu = (
    target: HTMLElement,
    entries: SidebarContextMenuEntry[]
  ) => {
    if (!entries.length) {
      closeContextMenu();
      return;
    }

    const rect = target.getBoundingClientRect();
    const x = rect.right - 4;
    const y = rect.bottom + 6;

    setContextMenu({
      x,
      y,
      entries,
    });
    setContextMenuPosition({ x, y });
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
  const isProjectNotesScope = state.notesScope === "project";
  const projectNoteFolders = isProjectNotesScope ? state.noteFolders : [];
  const filteredNotes = notesSearch
    ? state.notes.filter((note) => {
        const haystack = [
          note.title,
          note.subtitle,
          note.sourceLabel,
          noteFolderPathLabel(note.folderPath),
        ]
          .join(" ")
          .toLowerCase();
        return haystack.includes(notesSearch);
      })
    : state.notes;
  const projectScopeNotes = filteredNotes.filter((note) => note.ownerKind === "project");
  const visibleProjectNoteTreeRows =
    isProjectNotesScope
      ? buildProjectNoteTree({
          folders: projectNoteFolders,
          notes: projectScopeNotes,
          search: noteSearch,
        })
      : [];
  const activeProjectNoteFolderPanel = isProjectNotesScope
    ? buildProjectNoteFolderPanel({
        folders: projectNoteFolders,
        notes: projectScopeNotes,
        activeFolderId: activeProjectNoteFolderId,
      })
    : {
        currentFolder: null,
        parentFolder: null,
        childFolders: [],
        notes: [],
      };
  const activeProjectNoteFolder = activeProjectNoteFolderPanel.currentFolder;
  const activeProjectNoteParentFolder = activeProjectNoteFolderPanel.parentFolder;
  const visibleProjectNoteFolders = activeProjectNoteFolderPanel.childFolders;
  const visibleProjectFolderNotes = activeProjectNoteFolderPanel.notes;
  const isProjectNotesSearchActive = isProjectNotesScope && Boolean(notesSearch);

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

  const threadSectionContextMenuEntries = (): SidebarContextMenuEntry[] => [
    {
      kind: "action",
      id: "new-thread",
      label: "New Thread",
      symbol: "plus",
      disabled: !state.canCreateThread,
      command: "newThread",
    },
    {
      kind: "action",
      id: "new-temporary-thread",
      label: "New Temporary Chat",
      symbol: "eye.slash",
      disabled: !state.canCreateThread,
      command: "newTemporaryThread",
    },
  ];

  const sortedNoteFolders = [...projectNoteFolders].sort((left, right) =>
    noteFolderPathLabel(left.path).localeCompare(noteFolderPathLabel(right.path), undefined, {
      sensitivity: "base",
    })
  );

  const noteFolderMenuEntries = (
    folder: AssistantSidebarNoteFolderItem
  ): SidebarContextMenuEntry[] => [
    {
      kind: "action",
      id: `folder-new-note-${folder.id}`,
      label: "New Note Here",
      symbol: "note.text.badge.plus",
      command: "createSidebarNote",
      payload: { folderId: folder.id },
    },
    {
      kind: "action",
      id: `folder-new-subfolder-${folder.id}`,
      label: "New Subfolder",
      symbol: "folder.badge.plus",
      command: "createNoteFolderPrompt",
      payload: { parentFolderId: folder.id },
    },
    { kind: "separator", id: `folder-edit-divider-${folder.id}` },
    {
      kind: "action",
      id: `folder-rename-${folder.id}`,
      label: "Rename Folder",
      symbol: "pencil",
      command: "renameNoteFolderPrompt",
      payload: { folderId: folder.id },
    },
    {
      kind: "action",
      id: `folder-move-${folder.id}`,
      label: "Move Folder",
      symbol: "arrow.up.and.down.and.arrow.left.and.right",
      command: "moveNoteFolderPrompt",
      payload: { folderId: folder.id },
    },
    {
      kind: "action",
      id: `folder-delete-${folder.id}`,
      label: "Delete Folder",
      symbol: "trash",
      destructive: true,
      disabled: folder.childFolderCount > 0 || folder.noteCount > 0,
      command: "deleteNoteFolder",
      payload: { folderId: folder.id },
    },
  ];

  const projectNoteContextMenuEntries = (
    note: AssistantSidebarNoteItem
  ): SidebarContextMenuEntry[] => {
    const moveEntries: SidebarContextMenuEntry[] = sortedNoteFolders.length
      ? sortedNoteFolders.map((folder) => ({
          kind: "action" as const,
          id: `move-note-${note.id}-${folder.id}`,
          label: noteFolderPathLabel(folder.path),
          symbol: "folder",
          disabled: sameSidebarID(note.folderId, folder.id),
          command: "moveSidebarProjectNote",
          payload: { noteId: note.noteId, folderId: folder.id },
        }))
      : [
          {
            kind: "note",
            id: `move-note-empty-${note.id}`,
            label: "No note folders yet",
          },
        ];

    return [
      {
        kind: "submenu",
        id: `move-note-folder-submenu-${note.id}`,
        label: "Move to Folder",
        symbol: "folder",
        entries: moveEntries,
      },
      {
        kind: "action",
        id: `move-note-root-${note.id}`,
        label: "Move to Top Level",
        symbol: "arrow.up.left.and.arrow.down.right",
        disabled: !note.folderId,
        command: "moveSidebarProjectNote",
        payload: { noteId: note.noteId, folderId: "" },
      },
      { kind: "separator", id: `note-actions-divider-${note.id}` },
      {
        kind: "action",
        id: `delete-note-${note.id}`,
        label: "Delete Note",
        symbol: "trash",
        destructive: true,
        command: "deleteSidebarProjectNote",
        payload: {
          ownerKind: note.ownerKind,
          ownerId: note.ownerId,
          noteId: note.noteId,
        },
      },
    ];
  };

  const notesSectionContextMenuEntries = (): SidebarContextMenuEntry[] => {
    const canOrganizeProjectNotes =
      isProjectNotesScope && Boolean(state.selectedNotesProjectId);

    if (activeProjectNoteFolder && !isProjectNotesSearchActive) {
      return [
        {
          kind: "action",
          id: "create-project-note-current-folder",
          label: "New Note Here",
          symbol: "note.text.badge.plus",
          disabled: !canOrganizeProjectNotes,
          command: "createSidebarNote",
          payload: { folderId: activeProjectNoteFolder.id },
        },
        {
          kind: "action",
          id: "create-project-note-root",
          label: "New Note at Top Level",
          symbol: "arrow.up.left.and.arrow.down.right",
          disabled: !canOrganizeProjectNotes,
          command: "createSidebarNote",
        },
        {
          kind: "action",
          id: "create-project-note-folder-current",
          label: "New Subfolder",
          symbol: "folder.badge.plus",
          disabled: !canOrganizeProjectNotes,
          command: "createNoteFolderPrompt",
          payload: { parentFolderId: activeProjectNoteFolder.id },
        },
        { kind: "separator", id: "current-folder-divider" },
        ...noteFolderMenuEntries(activeProjectNoteFolder).slice(2),
      ];
    }

    return [
      {
        kind: "action",
        id: "create-project-note-root",
        label: "New Note",
        symbol: "note.text.badge.plus",
        disabled: !canOrganizeProjectNotes,
        command: "createSidebarNote",
      },
      {
        kind: "action",
        id: "create-project-note-folder-root",
        label: "New Folder",
        symbol: "folder.badge.plus",
        disabled: !canOrganizeProjectNotes,
        command: "createNoteFolderPrompt",
      },
    ];
  };

  const resetProjectDragState = () => {
    setDraggedProjectId(null);
    setDropTargetProjectId(null);
    setRootDropActive(false);
  };

  const resetProjectNoteDragState = () => {
    setDraggedProjectNoteId(null);
    setDraggedProjectNoteFolderId(null);
    setDropTargetNoteFolderId(null);
    setNoteRootDropActive(false);
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

  const handleProjectNoteDragStart = (
    event: ReactDragEvent<HTMLElement>,
    note: AssistantSidebarNoteItem
  ) => {
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", note.noteId);
    setDraggedProjectNoteId(note.noteId);
    setDraggedProjectNoteFolderId(note.folderId ?? null);
    setDropTargetNoteFolderId(null);
    setNoteRootDropActive(false);
    closeContextMenu();
  };

  const handleProjectNoteDropIntoFolder = (
    event: ReactDragEvent<HTMLElement>,
    folder: AssistantSidebarNoteFolderItem
  ) => {
    const noteId = draggedProjectNoteId ?? event.dataTransfer.getData("text/plain");
    if (!noteId || sameSidebarID(draggedProjectNoteFolderId, folder.id)) {
      resetProjectNoteDragState();
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    onDispatchCommand("moveSidebarProjectNote", {
      noteId,
      folderId: folder.id,
    });
    resetProjectNoteDragState();
  };

  const handleProjectNoteDropToRoot = (event: ReactDragEvent<HTMLElement>) => {
    const noteId = draggedProjectNoteId ?? event.dataTransfer.getData("text/plain");
    if (!noteId) {
      resetProjectNoteDragState();
      return;
    }
    event.preventDefault();
    onDispatchCommand("moveSidebarProjectNote", {
      noteId,
      folderId: "",
    });
    resetProjectNoteDragState();
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
                    onDispatchCommand(
                      "createSidebarNote",
                      activeProjectNoteFolder && !isProjectNotesSearchActive
                        ? { folderId: activeProjectNoteFolder.id }
                        : undefined
                    );
                  }}
                  onContextMenu={(event) =>
                    openContextMenu(event, notesSectionContextMenuEntries())
                  }
                  title={
                    activeProjectNoteFolder && !isProjectNotesSearchActive
                      ? `New note in ${activeProjectNoteFolder.name}`
                      : "New project note"
                  }
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

            {isProjectNotesScope && draggedProjectNoteId && draggedProjectNoteFolderId ? (
              <div
                className={`oa-react-sidebar__drop-target ${
                  noteRootDropActive ? "is-active" : ""
                }`}
                onDragOver={(event) => {
                  event.preventDefault();
                  event.dataTransfer.dropEffect = "move";
                  setNoteRootDropActive(true);
                  setDropTargetNoteFolderId(null);
                }}
                onDragLeave={() => {
                  setNoteRootDropActive(false);
                }}
                onDrop={handleProjectNoteDropToRoot}
              >
                Drop here to move this note to the top level
              </div>
            ) : null}

            {isProjectNotesScope ? (
              isProjectNotesSearchActive ? (
                visibleProjectNoteTreeRows.length ? (
                  <div className="oa-react-sidebar__list">
                    {visibleProjectNoteTreeRows.map((row) =>
                      row.kind === "folder" ? (
                        <SidebarNoteFolderRow
                          key={row.folder.id}
                          folder={row.folder}
                          depth={row.depth}
                          chevronSymbol={row.isExpanded ? "chevron.down" : "chevron.right"}
                          onClick={() => {
                            closeContextMenu();
                            setNoteSearch("");
                            setActiveProjectNoteFolderId(row.folder.id);
                          }}
                          onContextMenu={(event) =>
                            openContextMenu(event, noteFolderMenuEntries(row.folder))
                          }
                          onDragOver={(event) => {
                            if (
                              !draggedProjectNoteId ||
                              sameSidebarID(draggedProjectNoteFolderId, row.folder.id)
                            ) {
                              return;
                            }
                            event.preventDefault();
                            event.stopPropagation();
                            event.dataTransfer.dropEffect = "move";
                            setDropTargetNoteFolderId(row.folder.id);
                            setNoteRootDropActive(false);
                          }}
                          onDragLeave={() => {
                            if (sameSidebarID(dropTargetNoteFolderId, row.folder.id)) {
                              setDropTargetNoteFolderId(null);
                            }
                          }}
                          onDrop={(event) => handleProjectNoteDropIntoFolder(event, row.folder)}
                          isDropTarget={sameSidebarID(dropTargetNoteFolderId, row.folder.id)}
                        />
                      ) : (
                        <SidebarNoteRow
                          key={row.note.id}
                          note={row.note}
                          depth={row.depth}
                          draggable
                          onClick={() => {
                            closeContextMenu();
                            onDispatchCommand("selectSidebarNote", {
                              ownerKind: row.note.ownerKind,
                              ownerId: row.note.ownerId,
                              noteId: row.note.noteId,
                            });
                          }}
                          onContextMenu={(event) =>
                            openContextMenu(event, projectNoteContextMenuEntries(row.note))
                          }
                          onDragStart={(event) => handleProjectNoteDragStart(event, row.note)}
                          onDragEnd={resetProjectNoteDragState}
                        />
                      )
                    )}
                  </div>
                ) : (
                  <div className="oa-react-sidebar__empty">
                    {noteSearch.trim()
                      ? `No notes match "${noteSearch.trim()}".`
                      : "No project notes or folders yet."}
                  </div>
                )
              ) : (
                <div className="oa-react-sidebar__notes-folder-shell">
                  {activeProjectNoteFolder ? (
                    <div className="oa-react-sidebar__notes-folder-header">
                      <div className="oa-react-sidebar__notes-folder-topbar">
                        <button
                          type="button"
                          className="oa-react-sidebar__notes-folder-back"
                          onClick={() => {
                            closeContextMenu();
                            setActiveProjectNoteFolderId(activeProjectNoteParentFolder?.id ?? null);
                          }}
                          title={
                            activeProjectNoteParentFolder
                              ? `Back to ${activeProjectNoteParentFolder.name}`
                              : "Back to all project notes"
                          }
                        >
                          <SidebarIcon symbol="chevron.left" />
                          <span>
                            {activeProjectNoteParentFolder
                              ? activeProjectNoteParentFolder.name
                              : "All notes"}
                          </span>
                        </button>

                        <div className="oa-react-sidebar__notes-folder-actions">
                          {state.canCreateProjectNote ? (
                            <button
                              type="button"
                              className="oa-react-sidebar__icon-button oa-react-sidebar__notes-folder-action"
                              onClick={() => {
                                closeContextMenu();
                                onDispatchCommand("createSidebarNote", {
                                  folderId: activeProjectNoteFolder.id,
                                });
                              }}
                              title={`New note in ${activeProjectNoteFolder.name}`}
                            >
                              <SidebarIcon symbol="plus" />
                            </button>
                          ) : null}

                          <button
                            type="button"
                            className="oa-react-sidebar__icon-button oa-react-sidebar__notes-folder-action oa-react-sidebar__notes-folder-menu"
                            onClick={(event) => {
                              event.preventDefault();
                              event.stopPropagation();
                              openAnchoredContextMenu(
                                event.currentTarget,
                                noteFolderMenuEntries(activeProjectNoteFolder)
                              );
                            }}
                            title={`Folder actions for ${activeProjectNoteFolder.name}`}
                          >
                            <SidebarIcon symbol="ellipsis" />
                          </button>
                        </div>
                      </div>

                      <div className="oa-react-sidebar__notes-folder-current">
                        <span className="oa-react-sidebar__notes-folder-label">Folder</span>
                        <span className="oa-react-sidebar__notes-folder-title-row">
                          <span className="oa-react-sidebar__notes-folder-icon">
                            <SidebarIcon symbol="folder" />
                          </span>
                          <span className="oa-react-sidebar__notes-folder-title">
                            {activeProjectNoteFolder.name}
                          </span>
                        </span>
                        <span className="oa-react-sidebar__notes-folder-path">
                          {noteFolderSubtitle(activeProjectNoteFolder)}
                        </span>
                      </div>
                    </div>
                  ) : null}

                  {visibleProjectNoteFolders.length || visibleProjectFolderNotes.length ? (
                    <div
                      key={activeProjectNoteFolder?.id ?? "project-note-root"}
                      className="oa-react-sidebar__notes-folder-panel"
                    >
                      <div className="oa-react-sidebar__list">
                        {visibleProjectNoteFolders.map((folder) => (
                          <SidebarNoteFolderRow
                            key={folder.id}
                            folder={folder}
                            depth={0}
                            chevronSymbol="chevron.right"
                            onClick={() => {
                              closeContextMenu();
                              setActiveProjectNoteFolderId(folder.id);
                            }}
                            onContextMenu={(event) =>
                              openContextMenu(event, noteFolderMenuEntries(folder))
                            }
                            onDragOver={(event) => {
                              if (
                                !draggedProjectNoteId ||
                                sameSidebarID(draggedProjectNoteFolderId, folder.id)
                              ) {
                                return;
                              }
                              event.preventDefault();
                              event.stopPropagation();
                              event.dataTransfer.dropEffect = "move";
                              setDropTargetNoteFolderId(folder.id);
                              setNoteRootDropActive(false);
                            }}
                            onDragLeave={() => {
                              if (sameSidebarID(dropTargetNoteFolderId, folder.id)) {
                                setDropTargetNoteFolderId(null);
                              }
                            }}
                            onDrop={(event) => handleProjectNoteDropIntoFolder(event, folder)}
                            isDropTarget={sameSidebarID(dropTargetNoteFolderId, folder.id)}
                          />
                        ))}

                        {visibleProjectFolderNotes.map((note) => (
                          <SidebarNoteRow
                            key={note.id}
                            note={note}
                            depth={0}
                            draggable
                            onClick={() => {
                              closeContextMenu();
                              onDispatchCommand("selectSidebarNote", {
                                ownerKind: note.ownerKind,
                                ownerId: note.ownerId,
                                noteId: note.noteId,
                              });
                            }}
                            onContextMenu={(event) =>
                              openContextMenu(event, projectNoteContextMenuEntries(note))
                            }
                            onDragStart={(event) => handleProjectNoteDragStart(event, note)}
                            onDragEnd={resetProjectNoteDragState}
                          />
                        ))}
                      </div>
                    </div>
                  ) : (
                    <div className="oa-react-sidebar__empty">
                      {activeProjectNoteFolder
                        ? "This folder is empty."
                        : "No project notes or folders yet."}
                    </div>
                  )}
                </div>
              )
            ) : filteredNotes.length ? (
              <div className="oa-react-sidebar__list">
                {filteredNotes.map((note) => (
                  <SidebarNoteRow
                    key={note.id}
                    note={note}
                    depth={0}
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
                  onContextMenu={(event) =>
                    openContextMenu(event, threadSectionContextMenuEntries())
                  }
                  title={
                    state.canCreateThread
                      ? "New thread. Right-click for a temporary chat."
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
          <span className="oa-react-sidebar__footer-icon">
            <SidebarIcon symbol="gearshape" />
          </span>
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
          <span className="oa-react-sidebar__footer-icon">
            <SidebarIcon symbol="archivebox" />
          </span>
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
      <span className="oa-react-sidebar__nav-icon">
        <SidebarIcon symbol={item.symbol} />
      </span>
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

const SidebarNoteFolderRow = memo(function SidebarNoteFolderRow({
  folder,
  depth,
  chevronSymbol = "chevron.right",
  onClick,
  onContextMenu,
  onDragOver,
  onDragLeave,
  onDrop,
  isDropTarget,
}: {
  folder: AssistantSidebarNoteFolderItem;
  depth: number;
  chevronSymbol?: string;
  onClick: () => void;
  onContextMenu: (event: ReactMouseEvent<HTMLButtonElement>) => void;
  onDragOver: (event: ReactDragEvent<HTMLButtonElement>) => void;
  onDragLeave: () => void;
  onDrop: (event: ReactDragEvent<HTMLButtonElement>) => void;
  isDropTarget: boolean;
}) {
  const style = {
    paddingLeft: `calc(${10 + depth * 18}px * var(--oa-sidebar-scale))`,
  } as CSSProperties;

  return (
    <button
      type="button"
      className={`oa-react-sidebar__row oa-react-sidebar__row--note-folder ${
        isDropTarget ? "is-drop-target" : ""
      }`}
      style={style}
      onClick={onClick}
      onContextMenu={onContextMenu}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
    >
      <span className="oa-react-sidebar__row-folder-chevron">
        <SidebarIcon symbol={chevronSymbol} />
      </span>
      <span className="oa-react-sidebar__row-icon">
        <SidebarIcon symbol="folder" />
      </span>
      <span className="oa-react-sidebar__row-copy">
        <span className="oa-react-sidebar__row-title-line">
          <span className="oa-react-sidebar__row-title-wrap">
            <span className="oa-react-sidebar__row-title">{folder.name}</span>
          </span>
        </span>
        <span className="oa-react-sidebar__row-subtitle">{noteFolderSubtitle(folder)}</span>
      </span>
    </button>
  );
});

const SidebarNoteRow = memo(function SidebarNoteRow({
  note,
  depth = 0,
  draggable = false,
  onClick,
  onContextMenu,
  onDragStart,
  onDragEnd,
  onOpenThread,
}: {
  note: AssistantSidebarNoteItem;
  depth?: number;
  draggable?: boolean;
  onClick: () => void;
  onContextMenu?: (event: ReactMouseEvent<HTMLDivElement>) => void;
  onDragStart?: (event: ReactDragEvent<HTMLDivElement>) => void;
  onDragEnd?: () => void;
  onOpenThread?: () => void;
}) {
  const style = {
    paddingLeft: `calc(${10 + depth * 18}px * var(--oa-sidebar-scale))`,
  } as CSSProperties;

  return (
    <div
      role="button"
      tabIndex={0}
      className={`oa-react-sidebar__row oa-react-sidebar__row--note ${
        note.isSelected ? "is-selected" : ""
      }`}
      style={style}
      onClick={onClick}
      onContextMenu={onContextMenu}
      draggable={draggable}
      onDragStart={onDragStart}
      onDragEnd={() => onDragEnd?.()}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onClick();
        }
      }}
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
    </div>
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
              symbol="skills"
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
      <span className="oa-react-sidebar__rail-icon">
        <SidebarIcon symbol={symbol} />
      </span>
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
  const noteItems =
    state.notesScope === "project"
      ? buildProjectNoteTree({
          folders: state.noteFolders,
          notes: state.notes.filter((note) => note.ownerKind === "project"),
          search: "",
        }).slice(0, 4)
      : state.notes.slice(0, 4);
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
            {state.notesScope === "project"
              ? (noteItems as ProjectNoteTreeRow[]).map((row) =>
                  row.kind === "folder" ? (
                    <button
                      key={row.folder.id}
                      type="button"
                      className="oa-react-sidebar__collapsed-preview-row"
                      style={{
                        paddingLeft: `${12 + row.depth * 14}px`,
                      }}
                      onClick={() => {
                        onDispatchCommand("setSelectedPane", { pane: "notes" });
                        onDispatchCommand("toggleNoteFolderExpanded", {
                          folderId: row.folder.id,
                          expanded: !row.isExpanded,
                        });
                      }}
                    >
                      <span className="oa-react-sidebar__collapsed-preview-icon">
                        <SidebarIcon symbol="folder" />
                      </span>
                      <span className="oa-react-sidebar__collapsed-preview-copy">
                        <span className="oa-react-sidebar__collapsed-preview-name">
                          {row.folder.name}
                        </span>
                        <span className="oa-react-sidebar__collapsed-preview-meta">
                          {row.folder.noteCount === 1
                            ? "1 note"
                            : `${row.folder.noteCount} notes`}
                        </span>
                      </span>
                    </button>
                  ) : (
                    <button
                      key={row.note.id}
                      type="button"
                      className={`oa-react-sidebar__collapsed-preview-row ${
                        row.note.isSelected ? "is-selected" : ""
                      }`}
                      style={{
                        paddingLeft: `${12 + row.depth * 14}px`,
                      }}
                      onClick={() => {
                        onDispatchCommand("setSelectedPane", { pane: "notes" });
                        onDispatchCommand("selectSidebarNote", {
                          ownerKind: row.note.ownerKind,
                          ownerId: row.note.ownerId,
                          noteId: row.note.noteId,
                        });
                      }}
                    >
                      <span className="oa-react-sidebar__collapsed-preview-icon">
                        <SidebarIcon symbol="note.text" />
                      </span>
                      <span className="oa-react-sidebar__collapsed-preview-copy">
                        <span className="oa-react-sidebar__collapsed-preview-name">
                          {row.note.title}
                        </span>
                        <span className="oa-react-sidebar__collapsed-preview-meta">
                          {row.note.subtitle}
                        </span>
                      </span>
                    </button>
                  )
                )
              : (noteItems as AssistantSidebarNoteItem[]).map((note) => (
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
              ? "No project notes or folders yet."
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
          Hover preview is not available here yet. Click the skills icon to open skills.
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
      symbol={resolveSidebarIconSymbol(symbol)}
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
