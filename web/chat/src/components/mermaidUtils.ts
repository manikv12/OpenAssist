import type { MermaidTemplateType } from "./threadNoteMermaidTemplates";

export type MermaidRenderMode = "default-pretty" | "respect-authored-style";

export interface MermaidSourceAnalysis {
  type: MermaidTemplateType | null;
  isFlowchart: boolean;
  flowDirection: FlowchartDirection | null;
  hasAuthorStyling: boolean;
  hasFrontmatterConfig: boolean;
  hasInitDirective: boolean;
  renderMode: MermaidRenderMode;
}

type FlowchartDirection = "TB" | "TD" | "BT" | "LR" | "RL";

const MERMAID_VARIANT_HEADERS: Record<string, string> = {
  flowchart: "flowchart",
  graph: "graph",
  sequencediagram: "sequenceDiagram",
  classdiagram: "classDiagram",
  statediagram: "stateDiagram-v2",
  statediagramv2: "stateDiagram-v2",
  erdiagram: "erDiagram",
  journey: "journey",
  gantt: "gantt",
  pie: "pie",
  gitgraph: "gitGraph",
  mindmap: "mindmap",
  timeline: "timeline",
  requirementdiagram: "requirementDiagram",
  quadrantschart: "quadrantChart",
  quadrantchart: "quadrantChart",
  sankey: "sankey-beta",
  architecture: "architecture-beta",
  blockdiagram: "block-beta",
};

export function isMermaidLanguage(language?: string | null): boolean {
  const normalized = `${language ?? ""}`.trim().toLowerCase();
  return normalized === "mermaid" || normalized.startsWith("mermaid");
}

export function normalizeMermaidSource(language: string, code: string): string {
  const sourceWithNormalizedHeader = normalizeMermaidHeader(language, code);
  return sanitizeMermaidSource(sourceWithNormalizedHeader);
}

export function inspectMermaidSource(source: string): MermaidSourceAnalysis {
  const normalized = source.replace(/\r\n/g, "\n");
  const firstDirective = firstMeaningfulMermaidDirective(normalized);
  const type = detectTemplateTypeFromDirective(firstDirective);
  const hasFrontmatterConfig = hasLeadingFrontmatter(normalized);
  const hasInitDirective = /%%\{\s*init\s*:/i.test(normalized);
  const hasAuthorStyling =
    hasFrontmatterConfig ||
    hasInitDirective ||
    /^\s*classDef\b/m.test(normalized) ||
    /^\s*style\b/m.test(normalized) ||
    /^\s*linkStyle\b/m.test(normalized);

  return {
    type,
    isFlowchart: type === "flowchart",
    flowDirection: parseFlowchartDirection(firstDirective),
    hasAuthorStyling,
    hasFrontmatterConfig,
    hasInitDirective,
    renderMode: hasAuthorStyling
      ? "respect-authored-style"
      : "default-pretty",
  };
}

function normalizeMermaidHeader(language: string, code: string): string {
  if (language === "mermaid") {
    return code;
  }

  const variant = language.slice("mermaid".length).toLowerCase();
  if (!variant) {
    return code;
  }

  const header = mermaidVariantHeader(variant);
  if (!header) {
    return code;
  }

  const trimmed = code.trimStart();
  const normalizedHeader = header.toLowerCase();
  if (trimmed.toLowerCase().startsWith(normalizedHeader)) {
    return code;
  }
  if (header === "flowchart" && /^graph\b/i.test(trimmed)) {
    return code;
  }

  return `${header}\n${code}`;
}

function sanitizeMermaidSource(source: string): string {
  const normalized = source.replace(/\r\n/g, "\n");
  const firstDirective = firstMeaningfulMermaidDirective(normalized);

  if (!firstDirective) {
    return normalized;
  }

  if (
    firstDirective.startsWith("flowchart") ||
    firstDirective.startsWith("graph")
  ) {
    return normalized
      .split("\n")
      .map((line) => sanitizeFlowchartSubgraphLine(line))
      .join("\n");
  }

  return normalized;
}

function sanitizeFlowchartSubgraphLine(line: string): string {
  const match = line.match(/^(\s*subgraph)\s+([A-Za-z0-9_-]+)\s*\[(.+)\]\s*$/);
  if (!match) {
    return line;
  }

  const [, keyword, identifier, rawLabel] = match;
  const label = rawLabel.trim();
  if (!label) {
    return line;
  }

  return `${keyword} ${identifier}[${quoteMermaidLabel(label)}]`;
}

function quoteMermaidLabel(label: string): string {
  if (/^"(?:[^"\\]|\\.)*"$/.test(label)) {
    return label;
  }

  const escaped = label
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"');
  return `"${escaped}"`;
}

export function detectMermaidTemplateType(
  source: string
): MermaidTemplateType | null {
  return detectTemplateTypeFromDirective(firstMeaningfulMermaidDirective(source));
}

function mermaidVariantHeader(variant: string): string | null {
  return MERMAID_VARIANT_HEADERS[variant] || null;
}

function detectTemplateTypeFromDirective(
  firstDirective?: string | null
): MermaidTemplateType | null {
  if (!firstDirective) {
    return null;
  }

  if (firstDirective.startsWith("flowchart") || firstDirective.startsWith("graph")) {
    return "flowchart";
  }
  if (firstDirective.startsWith("sequencediagram")) {
    return "sequence";
  }
  if (firstDirective.startsWith("classdiagram")) {
    return "class";
  }
  if (
    firstDirective.startsWith("statediagram-v2") ||
    firstDirective.startsWith("statediagram")
  ) {
    return "state";
  }
  if (firstDirective.startsWith("erdiagram")) {
    return "er";
  }
  if (firstDirective.startsWith("journey")) {
    return "journey";
  }
  if (firstDirective.startsWith("gantt")) {
    return "gantt";
  }
  if (firstDirective.startsWith("pie")) {
    return "pie";
  }
  if (firstDirective.startsWith("gitgraph")) {
    return "gitgraph";
  }
  if (firstDirective.startsWith("mindmap")) {
    return "mindmap";
  }
  if (firstDirective.startsWith("timeline")) {
    return "timeline";
  }
  if (firstDirective.startsWith("quadrantchart")) {
    return "quadrant";
  }
  if (firstDirective.startsWith("architecture-beta")) {
    return "architecture";
  }
  if (firstDirective.startsWith("block-beta")) {
    return "block";
  }

  return null;
}

function parseFlowchartDirection(
  firstDirective?: string | null
): FlowchartDirection | null {
  if (!firstDirective) {
    return null;
  }

  const match = firstDirective.match(/^(?:flowchart|graph)\s+([a-z][a-z0-9-]*)/i);
  if (!match) {
    return null;
  }

  const direction = match[1].toUpperCase();
  switch (direction) {
    case "TB":
    case "TD":
    case "BT":
    case "LR":
    case "RL":
      return direction;
    default:
      return null;
  }
}

function firstMeaningfulMermaidDirective(source: string): string | undefined {
  const normalized = stripLeadingConfigBlocks(source.replace(/\r\n/g, "\n"));
  return normalized
    .split("\n")
    .map((line) => line.trim())
    .find(Boolean)
    ?.toLowerCase();
}

function stripLeadingConfigBlocks(source: string): string {
  let remaining = source.trimStart();

  if (remaining.startsWith("---")) {
    const frontmatterMatch = remaining.match(/^---\s*\n[\s\S]*?\n---\s*(?:\n|$)/);
    if (frontmatterMatch) {
      remaining = remaining.slice(frontmatterMatch[0].length);
    }
  }

  while (remaining.startsWith("%%{")) {
    const directiveMatch = remaining.match(/^%%\{[\s\S]*?\}%%\s*(?:\n|$)/);
    if (!directiveMatch) {
      break;
    }
    remaining = remaining.slice(directiveMatch[0].length).trimStart();
  }

  return remaining;
}

function hasLeadingFrontmatter(source: string): boolean {
  return /^(\s*)---\s*\n[\s\S]*?\n---\s*(?:\n|$)/.test(source);
}
