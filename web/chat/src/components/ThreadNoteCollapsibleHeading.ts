import type {
  JSONContent,
  MarkdownParseHelpers,
  MarkdownRendererHelpers,
  MarkdownToken,
} from "@tiptap/core";
import Heading from "@tiptap/extension-heading";
import { Plugin, PluginKey, type EditorState, type Transaction } from "@tiptap/pm/state";
import { Decoration, DecorationSet, type EditorView } from "@tiptap/pm/view";

type HeadingCollapsePluginState = {
  collapsedHeadingPositions: number[];
};

type TopLevelBlock = {
  pos: number;
  node: EditorState["doc"]["content"]["content"][number];
};

export interface CollapsedHeadingSection {
  headingPos: number;
  sectionEnd: number;
  headingLevel: number;
}

export interface ThreadNoteHeadingSection extends CollapsedHeadingSection {
  headingNodeEnd: number;
  isCollapsed: boolean;
  isCollapsible: boolean;
}

const NON_COLLAPSIBLE_HEADING_COMMENT = "<!-- oa:non-collapsible -->";

const headingCollapsePluginKey = new PluginKey<HeadingCollapsePluginState>(
  "threadNoteHeadingCollapse"
);

export const ThreadNoteCollapsibleHeading = Heading.extend({
  addAttributes() {
    return {
      ...this.parent?.(),
      collapsible: {
        default: true,
        parseHTML: (element: HTMLElement) =>
          element.getAttribute("data-heading-collapsible") !== "false",
        renderHTML: (attributes: Record<string, unknown>) =>
          attributes.collapsible === false
            ? { "data-heading-collapsible": "false" }
            : {},
      },
    };
  },

  parseMarkdown(token: MarkdownToken, helpers: MarkdownParseHelpers) {
    const inlineTokens = Array.isArray(token.tokens) ? token.tokens : [];
    const isNonCollapsible = inlineTokens.some(isNonCollapsibleHeadingToken);
    const contentTokens = inlineTokens.filter(
      (inlineToken) => !isNonCollapsibleHeadingToken(inlineToken)
    );

    return helpers.createNode(
      "heading",
      {
        level: token.depth || 1,
        collapsible: !isNonCollapsible,
      },
      helpers.parseInline(contentTokens)
    );
  },

  renderMarkdown(node: JSONContent, helpers: MarkdownRendererHelpers) {
    const level = node.attrs?.level ? parseInt(String(node.attrs.level), 10) : 1;
    const headingChars = "#".repeat(level);

    if (!node.content) {
      return "";
    }

    const content = helpers.renderChildren(node.content);
    const comment =
      node.attrs?.collapsible === false ? ` ${NON_COLLAPSIBLE_HEADING_COMMENT}` : "";

    return `${headingChars} ${content}${comment}`;
  },

  addProseMirrorPlugins() {
    const editor = this.editor;

    return [
      new Plugin<HeadingCollapsePluginState>({
        key: headingCollapsePluginKey,
        state: {
          init: () => ({
            collapsedHeadingPositions: [],
          }),
          apply: (transaction, pluginState, _oldState, newState) => {
            const mappedPositions = retainCollapsibleHeadingPositions(
              newState,
              mapHeadingPositions(
                pluginState.collapsedHeadingPositions,
                transaction
              )
            );
            const meta = transaction.getMeta(headingCollapsePluginKey) as
              | { type: "toggleHeading"; pos: number }
              | { type: "setCollapsible"; pos: number; collapsible: boolean }
              | undefined;

            if (!meta) {
              return {
                collapsedHeadingPositions: mappedPositions,
              };
            }

            if (meta.type === "setCollapsible") {
              return {
                collapsedHeadingPositions: meta.collapsible
                  ? mappedPositions
                  : mappedPositions.filter((position) => position !== meta.pos),
              };
            }

            return {
              collapsedHeadingPositions: toggleHeadingPosition(mappedPositions, meta.pos),
            };
          },
        },
        props: {
          decorations: (state) => buildHeadingDecorations(state, editor.view),
          handleDOMEvents: {
            mousedown: (view, event) => {
              const target = event.target;
              if (!(target instanceof Node)) {
                return false;
              }
              const targetElement = target instanceof Element ? target : target.parentElement;
              if (!targetElement) {
                return false;
              }

              const toggleButton = targetElement.closest(".thread-note-heading-toggle");
              const collapsedHeading =
                toggleButton
                  ? null
                  : targetElement.closest(".thread-note-heading-node.is-collapsible.is-collapsed");
              const headingElement =
                (toggleButton?.closest(".thread-note-heading-node.is-collapsible") ??
                  collapsedHeading) as HTMLElement | null;

              if (!headingElement) {
                return false;
              }

              const headingPos = resolveHeadingPositionFromDOM(view, headingElement);
              if (headingPos === null) {
                return false;
              }

              event.preventDefault();
              event.stopPropagation();

              const transaction = view.state.tr.setMeta(headingCollapsePluginKey, {
                type: "toggleHeading",
                pos: headingPos,
              });
              view.dispatch(transaction);
              view.focus();
              return true;
            },
          },
        },
      }),
    ];
  },
});

export function findCollapsedHeadingSectionAtSelection(
  state: EditorState,
  selectionPos: number = state.selection.from
): CollapsedHeadingSection | null {
  const topLevelBlocks = getTopLevelBlocks(state);

  for (let index = 0; index < topLevelBlocks.length; index += 1) {
    const block = topLevelBlocks[index];
    const section = buildHeadingSection(state, topLevelBlocks, index);
    if (!section?.isCollapsed) {
      continue;
    }

    if (selectionPos > block.pos && selectionPos < section.sectionEnd) {
      return {
        headingPos: section.headingPos,
        sectionEnd: section.sectionEnd,
        headingLevel: section.headingLevel,
      };
    }
  }

  return null;
}

export function findHeadingSectionAtPosition(
  state: EditorState,
  headingPos: number
): ThreadNoteHeadingSection | null {
  const topLevelBlocks = getTopLevelBlocks(state);
  const headingIndex = topLevelBlocks.findIndex(
    (block) => block.pos === headingPos && block.node.type.name === "heading"
  );

  if (headingIndex === -1) {
    return null;
  }

  return buildHeadingSection(state, topLevelBlocks, headingIndex);
}

export function updateHeadingCollapsibleAtSelection(
  view: EditorView | null,
  selectionPos: number,
  collapsible: boolean
): boolean {
  if (!view) {
    return false;
  }

  try {
    const resolvedPosition = view.state.doc.resolve(selectionPos);

    for (let depth = resolvedPosition.depth; depth > 0; depth -= 1) {
      const node = resolvedPosition.node(depth);
      if (node.type.name !== "heading") {
        continue;
      }

      const nodePos = resolvedPosition.before(depth);
      const currentCollapsible = isHeadingNodeCollapsible(node);
      if (currentCollapsible === collapsible) {
        return true;
      }

      const transaction = view.state.tr.setNodeMarkup(nodePos, undefined, {
        ...node.attrs,
        collapsible,
      }).setMeta(headingCollapsePluginKey, {
        type: "setCollapsible",
        pos: nodePos,
        collapsible,
      });
      view.dispatch(transaction);
      view.focus();
      return true;
    }
  } catch {
    return false;
  }

  return false;
}

export function uncollapseHeadingAtPosition(
  view: EditorView,
  headingPos: number
): boolean {
  const pluginState = headingCollapsePluginKey.getState(view.state);
  if (!pluginState?.collapsedHeadingPositions.includes(headingPos)) {
    return false;
  }

  const transaction = view.state.tr.setMeta(headingCollapsePluginKey, {
    type: "toggleHeading",
    pos: headingPos,
  });
  view.dispatch(transaction);
  return true;
}

function buildHeadingDecorations(
  state: EditorState,
  view: EditorView | null
): DecorationSet {
  const topLevelBlocks = getTopLevelBlocks(state);
  const decorations: Decoration[] = [];

  topLevelBlocks.forEach((block, index) => {
    const section = buildHeadingSection(state, topLevelBlocks, index);
    if (!section) {
      return;
    }

    const { isCollapsed, isCollapsible, sectionEnd } = section;

    decorations.push(
      Decoration.node(block.pos, block.pos + block.node.nodeSize, {
        class: [
          "thread-note-heading-node",
          isCollapsible ? "is-collapsible" : "is-static",
          isCollapsed ? "is-collapsed" : "",
        ]
          .filter(Boolean)
          .join(" "),
        "data-thread-note-heading-pos": String(block.pos),
      })
    );

    if (isCollapsible) {
      decorations.push(
        Decoration.widget(
          block.pos + 1,
          () => createHeadingToggle(view, block.pos, isCollapsed),
          {
            side: -1,
            ignoreSelection: true,
          }
        )
      );
    }

    if (!isCollapsed) {
      return;
    }

    const selectionFrom = state.selection.from;

    for (let nextIndex = index + 1; nextIndex < topLevelBlocks.length; nextIndex += 1) {
      const nextBlock = topLevelBlocks[nextIndex];
      if (nextBlock.pos >= sectionEnd) {
        break;
      }

      const blockEnd = nextBlock.pos + nextBlock.node.nodeSize;
      if (selectionFrom >= nextBlock.pos && selectionFrom <= blockEnd) {
        continue;
      }

      decorations.push(
        Decoration.node(nextBlock.pos, nextBlock.pos + nextBlock.node.nodeSize, {
          class: "thread-note-collapsed-node",
        })
      );
    }
  });

  return DecorationSet.create(state.doc, decorations);
}

function getTopLevelBlocks(state: EditorState): TopLevelBlock[] {
  const blocks: TopLevelBlock[] = [];

  state.doc.forEach((node, offset) => {
    blocks.push({
      pos: offset,
      node,
    });
  });

  return blocks;
}

function findSectionEnd(
  blocks: TopLevelBlock[],
  currentIndex: number,
  currentLevel: number,
  fallbackEnd: number
): number {
  for (let index = currentIndex + 1; index < blocks.length; index += 1) {
    const block = blocks[index];
    if (block.node.type.name !== "heading") {
      continue;
    }

    const nextLevel = Number(block.node.attrs.level ?? 1);
    if (nextLevel <= currentLevel) {
      return block.pos;
    }
  }

  return fallbackEnd;
}

function buildHeadingSection(
  state: EditorState,
  blocks: TopLevelBlock[],
  headingIndex: number
): ThreadNoteHeadingSection | null {
  const block = blocks[headingIndex];
  if (!block || block.node.type.name !== "heading") {
    return null;
  }

  const pluginState = headingCollapsePluginKey.getState(state);
  const collapsedPositions = new Set(pluginState?.collapsedHeadingPositions ?? []);
  const headingLevel = Number(block.node.attrs.level ?? 1);
  const sectionEnd = findSectionEnd(blocks, headingIndex, headingLevel, state.doc.content.size);

  return {
    headingPos: block.pos,
    headingNodeEnd: block.pos + block.node.nodeSize,
    sectionEnd,
    headingLevel,
    isCollapsed: collapsedPositions.has(block.pos) && isHeadingNodeCollapsible(block.node),
    isCollapsible: isHeadingNodeCollapsible(block.node),
  };
}

function createHeadingToggle(
  view: EditorView | null,
  pos: number,
  isCollapsed: boolean
): HTMLElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "thread-note-heading-toggle";
  button.setAttribute("data-heading-toggle", "true");
  button.setAttribute("data-heading-pos", String(pos));
  button.setAttribute("data-thread-note-heading-pos", String(pos));
  button.textContent = isCollapsed ? "▸" : "▾";
  button.setAttribute("aria-label", isCollapsed ? "Expand section" : "Collapse section");
  button.setAttribute("title", isCollapsed ? "Expand section" : "Collapse section");
  button.contentEditable = "false";

  button.addEventListener("mousedown", (event) => {
    event.preventDefault();
    event.stopPropagation();

    if (!view) {
      return;
    }

    const transaction = view.state.tr.setMeta(headingCollapsePluginKey, {
      type: "toggleHeading",
      pos,
    });
    view.dispatch(transaction);
    view.focus();
  });

  return button;
}

function resolveHeadingPositionFromDOM(
  view: EditorView,
  headingElement: HTMLElement
): number | null {
  const decoratedHeadingPos = resolveHeadingPositionFromAttributes(headingElement);
  if (decoratedHeadingPos !== null) {
    return decoratedHeadingPos;
  }

  try {
    const domPosition = view.posAtDOM(headingElement, 0);
    const resolvedPosition = view.state.doc.resolve(domPosition);

    for (let depth = resolvedPosition.depth; depth > 0; depth -= 1) {
      const node = resolvedPosition.node(depth);
      if (node.type.name === "heading") {
        return resolvedPosition.before(depth);
      }
    }
  } catch {
    return null;
  }

  return null;
}

function resolveHeadingPositionFromAttributes(element: Element): number | null {
  const positionText =
    element.getAttribute("data-thread-note-heading-pos") ??
    element.closest("[data-thread-note-heading-pos]")?.getAttribute("data-thread-note-heading-pos");
  if (!positionText) {
    return null;
  }

  const position = Number.parseInt(positionText, 10);
  return Number.isInteger(position) && position >= 0 ? position : null;
}

function mapHeadingPositions(positions: number[], transaction: Transaction): number[] {
  const mapped = positions
    .map((position) => transaction.mapping.mapResult(position, -1))
    .filter((result) => !result.deleted)
    .map((result) => result.pos);

  return [...new Set(mapped)];
}

function retainCollapsibleHeadingPositions(
  state: EditorState,
  positions: number[]
): number[] {
  return [...new Set(positions)].filter((position) => {
    const node = state.doc.nodeAt(position);
    return node?.type.name === "heading" && isHeadingNodeCollapsible(node);
  });
}

function toggleHeadingPosition(positions: number[], pos: number): number[] {
  return positions.includes(pos)
    ? positions.filter((position) => position !== pos)
    : [...positions, pos];
}

function isHeadingNodeCollapsible(node: TopLevelBlock["node"]): boolean {
  return node.attrs?.collapsible !== false;
}

function isNonCollapsibleHeadingToken(token: MarkdownToken): boolean {
  return token.type === "html" && typeof token.text === "string"
    ? token.text.includes("oa:non-collapsible")
    : false;
}
