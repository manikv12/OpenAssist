import type { MermaidTemplateType } from "./threadNoteMermaidTemplates";

export interface MermaidSnippetDefinition {
  id: string;
  label: string;
  subtitle: string;
  insertText: string;
}

const MERMAID_HEADER_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "flowchart",
    label: "Start Flowchart",
    subtitle: "Add a flowchart header.",
    insertText: "flowchart TD",
  },
  {
    id: "sequence",
    label: "Start Sequence",
    subtitle: "Add a sequence diagram header.",
    insertText: "sequenceDiagram",
  },
  {
    id: "class",
    label: "Start Class Diagram",
    subtitle: "Add a class diagram header.",
    insertText: "classDiagram",
  },
  {
    id: "state",
    label: "Start State Diagram",
    subtitle: "Add a state diagram header.",
    insertText: "stateDiagram-v2",
  },
  {
    id: "er",
    label: "Start ER Diagram",
    subtitle: "Add a database diagram header.",
    insertText: "erDiagram",
  },
  {
    id: "journey",
    label: "Start Journey",
    subtitle: "Add a user journey header.",
    insertText: "journey",
  },
  {
    id: "gantt",
    label: "Start Gantt",
    subtitle: "Add a gantt chart header.",
    insertText: "gantt",
  },
  {
    id: "pie",
    label: "Start Pie Chart",
    subtitle: "Add a pie chart header.",
    insertText: "pie showData",
  },
  {
    id: "gitgraph",
    label: "Start Git Graph",
    subtitle: "Add a git graph header.",
    insertText: "gitGraph",
  },
  {
    id: "mindmap",
    label: "Start Mindmap",
    subtitle: "Add a mindmap header.",
    insertText: "mindmap",
  },
  {
    id: "timeline",
    label: "Start Timeline",
    subtitle: "Add a timeline header.",
    insertText: "timeline",
  },
  {
    id: "quadrant",
    label: "Start Quadrant Chart",
    subtitle: "Add a quadrant chart header.",
    insertText: "quadrantChart",
  },
  {
    id: "architecture",
    label: "Start Architecture",
    subtitle: "Add an architecture diagram header.",
    insertText: "architecture-beta",
  },
  {
    id: "block",
    label: "Start Block Diagram",
    subtitle: "Add a block diagram header.",
    insertText: "block-beta",
  },
];

const COMMON_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "comment",
    label: "Comment",
    subtitle: "Add a Mermaid comment line.",
    insertText: "%% add note here",
  },
];

const FLOWCHART_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "step",
    label: "Process Step",
    subtitle: "Add a normal box node.",
    insertText: 'A["New step"]',
  },
  {
    id: "decision",
    label: "Decision",
    subtitle: "Add a decision diamond.",
    insertText: 'B{"Decision?"}',
  },
  {
    id: "link",
    label: "Arrow Link",
    subtitle: "Connect one step to another.",
    insertText: "A --> B",
  },
  {
    id: "branch",
    label: "Yes / No Branch",
    subtitle: "Add two labeled paths.",
    insertText: 'B -->|Yes| C["Continue"]\nB -->|No| D["Stop"]',
  },
  {
    id: "subgraph",
    label: "Subgraph Group",
    subtitle: "Group steps under one heading.",
    insertText: 'subgraph Team\n  A["Step 1"]\n  B["Step 2"]\nend',
  },
];

const SEQUENCE_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "participant",
    label: "Participant",
    subtitle: "Add a participant lane.",
    insertText: "participant API",
  },
  {
    id: "actor",
    label: "Actor",
    subtitle: "Add a person actor.",
    insertText: "actor User",
  },
  {
    id: "message",
    label: "Message",
    subtitle: "Send a message between lanes.",
    insertText: "User->>API: Request",
  },
  {
    id: "reply",
    label: "Reply",
    subtitle: "Send a return message.",
    insertText: "API-->>User: Response",
  },
  {
    id: "note",
    label: "Note",
    subtitle: "Add a note beside one lane.",
    insertText: "Note right of API: Important detail",
  },
  {
    id: "alt",
    label: "Alt Branch",
    subtitle: "Add success and failure branches.",
    insertText:
      "alt Success\n  API-->>User: OK\nelse Failure\n  API-->>User: Error\nend",
  },
];

const CLASS_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "classbox",
    label: "Class",
    subtitle: "Add a class block.",
    insertText: "class Order {\n  +id\n  +save()\n}",
  },
  {
    id: "relation",
    label: "Relationship",
    subtitle: "Connect two classes.",
    insertText: 'Order --> Item : contains',
  },
  {
    id: "inheritance",
    label: "Inheritance",
    subtitle: "Show one class extending another.",
    insertText: "AdminUser --|> User",
  },
  {
    id: "property",
    label: "Property",
    subtitle: "Add a field line.",
    insertText: "+status",
  },
  {
    id: "method",
    label: "Method",
    subtitle: "Add a method line.",
    insertText: "+save()",
  },
];

const STATE_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "state",
    label: "State",
    subtitle: "Add a named state.",
    insertText: 'state "Editing" as Editing',
  },
  {
    id: "transition",
    label: "Transition",
    subtitle: "Connect one state to another.",
    insertText: "Idle --> Editing : start",
  },
  {
    id: "choice",
    label: "Choice",
    subtitle: "Add a decision choice.",
    insertText: "state Choice <<choice>>",
  },
  {
    id: "start",
    label: "Start",
    subtitle: "Add the start marker.",
    insertText: "[*] --> Idle",
  },
  {
    id: "end",
    label: "End",
    subtitle: "Add the end marker.",
    insertText: "Done --> [*]",
  },
];

const ER_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "entity",
    label: "Entity",
    subtitle: "Add a table or entity block.",
    insertText: "USER {\n  string id PK\n  string email\n}",
  },
  {
    id: "relation",
    label: "Relationship",
    subtitle: "Connect two entities.",
    insertText: "USER ||--o{ ORDER : places",
  },
  {
    id: "field",
    label: "Field",
    subtitle: "Add a field definition.",
    insertText: "string id PK",
  },
  {
    id: "optional",
    label: "Optional Link",
    subtitle: "Show an optional relationship.",
    insertText: "ORDER }o--|| COUPON : uses",
  },
];

const JOURNEY_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "title",
    label: "Title",
    subtitle: "Add a chart title.",
    insertText: "title Customer onboarding",
  },
  {
    id: "section",
    label: "Section",
    subtitle: "Add a new journey section.",
    insertText: "section Signup",
  },
  {
    id: "task",
    label: "Task",
    subtitle: "Add a scored journey step.",
    insertText: "Create account: 5: User",
  },
];

const GANTT_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "title",
    label: "Title",
    subtitle: "Add a chart title.",
    insertText: "title Release plan",
  },
  {
    id: "section",
    label: "Section",
    subtitle: "Add a task section.",
    insertText: "section Build",
  },
  {
    id: "task",
    label: "Task",
    subtitle: "Add a dated task.",
    insertText: "Build UI :active, task1, 2026-04-01, 4d",
  },
  {
    id: "milestone",
    label: "Milestone",
    subtitle: "Add a milestone item.",
    insertText: "Launch :milestone, launch1, 2026-04-15, 0d",
  },
];

const PIE_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "title",
    label: "Title",
    subtitle: "Add a chart title.",
    insertText: "title Usage split",
  },
  {
    id: "slice",
    label: "Slice",
    subtitle: "Add one pie slice.",
    insertText: '"API": 42',
  },
];

const GITGRAPH_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "commit",
    label: "Commit",
    subtitle: "Add one commit.",
    insertText: 'commit id: "Init"',
  },
  {
    id: "branch",
    label: "Branch",
    subtitle: "Create a new branch.",
    insertText: "branch feature-auth",
  },
  {
    id: "checkout",
    label: "Checkout",
    subtitle: "Move to another branch.",
    insertText: "checkout feature-auth",
  },
  {
    id: "merge",
    label: "Merge",
    subtitle: "Merge one branch into another.",
    insertText: "merge feature-auth",
  },
];

const MINDMAP_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "root",
    label: "Root Topic",
    subtitle: "Add the main topic.",
    insertText: "Root",
  },
  {
    id: "branch",
    label: "Branch",
    subtitle: "Add a child branch.",
    insertText: "  Feature area",
  },
  {
    id: "subbranch",
    label: "Sub Branch",
    subtitle: "Add a deeper child item.",
    insertText: "    Detail",
  },
];

const TIMELINE_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "title",
    label: "Title",
    subtitle: "Add a timeline title.",
    insertText: "title Product timeline",
  },
  {
    id: "period",
    label: "Period",
    subtitle: "Add a major period or date.",
    insertText: "2026 Q2 : Planning",
  },
  {
    id: "event",
    label: "Event",
    subtitle: "Add an event under the current period.",
    insertText: "        : Launch beta",
  },
];

const QUADRANT_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "title",
    label: "Title",
    subtitle: "Add a chart title.",
    insertText: "title Priority map",
  },
  {
    id: "quadrant",
    label: "Quadrant Label",
    subtitle: "Name one quadrant.",
    insertText: "quadrant-1 Quick wins",
  },
  {
    id: "point",
    label: "Point",
    subtitle: "Plot one item on the chart.",
    insertText: "Feature A: [0.72, 0.81]",
  },
];

const ARCHITECTURE_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "group",
    label: "Group",
    subtitle: "Add a group container.",
    insertText: "group cloud(cloud)[Cloud]",
  },
  {
    id: "service",
    label: "Service",
    subtitle: "Add a service node.",
    insertText: "service api(server)[API]",
  },
  {
    id: "database",
    label: "Database",
    subtitle: "Add a database node.",
    insertText: "database db(database)[Primary DB]",
  },
  {
    id: "link",
    label: "Link",
    subtitle: "Connect two architecture nodes.",
    insertText: "api:R --> L:db",
  },
];

const BLOCK_SNIPPETS: MermaidSnippetDefinition[] = [
  {
    id: "columns",
    label: "Columns",
    subtitle: "Set the block layout columns.",
    insertText: "columns 2",
  },
  {
    id: "block",
    label: "Block",
    subtitle: "Add a named block.",
    insertText: "block:App",
  },
  {
    id: "child",
    label: "Nested Block",
    subtitle: "Add a child block.",
    insertText: "  block:API",
  },
  {
    id: "link",
    label: "Link",
    subtitle: "Connect one block to another.",
    insertText: "App --> API",
  },
];

const MERMAID_TYPE_SNIPPETS: Record<
  MermaidTemplateType,
  MermaidSnippetDefinition[]
> = {
  flowchart: FLOWCHART_SNIPPETS,
  sequence: SEQUENCE_SNIPPETS,
  class: CLASS_SNIPPETS,
  state: STATE_SNIPPETS,
  er: ER_SNIPPETS,
  journey: JOURNEY_SNIPPETS,
  gantt: GANTT_SNIPPETS,
  pie: PIE_SNIPPETS,
  gitgraph: GITGRAPH_SNIPPETS,
  mindmap: MINDMAP_SNIPPETS,
  timeline: TIMELINE_SNIPPETS,
  quadrant: QUADRANT_SNIPPETS,
  architecture: ARCHITECTURE_SNIPPETS,
  block: BLOCK_SNIPPETS,
};

export function mermaidSnippetsForType(
  type: MermaidTemplateType | null
): MermaidSnippetDefinition[] {
  if (!type) {
    return [...MERMAID_HEADER_SNIPPETS, ...COMMON_SNIPPETS];
  }

  return [...MERMAID_TYPE_SNIPPETS[type], ...COMMON_SNIPPETS];
}
