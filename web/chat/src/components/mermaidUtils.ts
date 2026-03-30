import type { MermaidTemplateType } from "./threadNoteMermaidTemplates";

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
  const firstDirective = normalized
    .split("\n")
    .map((line) => line.trim())
    .find(Boolean)
    ?.toLowerCase();

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
  const firstLine = source
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => line.trim())
    .find(Boolean)
    ?.toLowerCase();

  if (!firstLine) {
    return null;
  }

  if (firstLine.startsWith("flowchart") || firstLine.startsWith("graph")) {
    return "flowchart";
  }
  if (firstLine.startsWith("sequencediagram")) {
    return "sequence";
  }
  if (firstLine.startsWith("classdiagram")) {
    return "class";
  }
  if (
    firstLine.startsWith("statediagram-v2") ||
    firstLine.startsWith("statediagram")
  ) {
    return "state";
  }
  if (firstLine.startsWith("erdiagram")) {
    return "er";
  }
  if (firstLine.startsWith("journey")) {
    return "journey";
  }
  if (firstLine.startsWith("gantt")) {
    return "gantt";
  }
  if (firstLine.startsWith("pie")) {
    return "pie";
  }
  if (firstLine.startsWith("gitgraph")) {
    return "gitgraph";
  }
  if (firstLine.startsWith("mindmap")) {
    return "mindmap";
  }
  if (firstLine.startsWith("timeline")) {
    return "timeline";
  }
  if (firstLine.startsWith("quadrantchart")) {
    return "quadrant";
  }
  if (firstLine.startsWith("architecture-beta")) {
    return "architecture";
  }
  if (firstLine.startsWith("block-beta")) {
    return "block";
  }

  return null;
}

function mermaidVariantHeader(variant: string): string | null {
  return MERMAID_VARIANT_HEADERS[variant] || null;
}
