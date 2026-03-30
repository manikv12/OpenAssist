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

const headingCollapsePluginKey = new PluginKey<HeadingCollapsePluginState>(
  "threadNoteHeadingCollapse"
);

export const ThreadNoteCollapsibleHeading = Heading.extend({
  addProseMirrorPlugins() {
    const editor = this.editor;

    return [
      new Plugin<HeadingCollapsePluginState>({
        key: headingCollapsePluginKey,
        state: {
          init: () => ({
            collapsedHeadingPositions: [],
          }),
          apply: (transaction, pluginState) => {
            const mappedPositions = mapHeadingPositions(
              pluginState.collapsedHeadingPositions,
              transaction
            );
            const meta = transaction.getMeta(headingCollapsePluginKey) as
              | { type: "toggleHeading"; pos: number }
              | undefined;

            if (!meta || meta.type !== "toggleHeading") {
              return {
                collapsedHeadingPositions: mappedPositions,
              };
            }

            return {
              collapsedHeadingPositions: toggleHeadingPosition(mappedPositions, meta.pos),
            };
          },
        },
        props: {
          decorations: (state) => buildHeadingDecorations(state, editor.view),
        },
      }),
    ];
  },
});

function buildHeadingDecorations(
  state: EditorState,
  view: EditorView | null
): DecorationSet {
  const pluginState = headingCollapsePluginKey.getState(state);
  const collapsedPositions = new Set(pluginState?.collapsedHeadingPositions ?? []);
  const topLevelBlocks = getTopLevelBlocks(state);
  const decorations: Decoration[] = [];

  topLevelBlocks.forEach((block, index) => {
    if (block.node.type.name !== "heading") {
      return;
    }

    const level = Number(block.node.attrs.level ?? 1);
    const isCollapsed = collapsedPositions.has(block.pos);
    const sectionEnd = findSectionEnd(topLevelBlocks, index, level, state.doc.content.size);

    decorations.push(
      Decoration.node(block.pos, block.pos + block.node.nodeSize, {
        class: [
          "thread-note-heading-node",
          "is-collapsible",
          isCollapsed ? "is-collapsed" : "",
        ]
          .filter(Boolean)
          .join(" "),
      })
    );

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

    if (!isCollapsed) {
      return;
    }

    for (let nextIndex = index + 1; nextIndex < topLevelBlocks.length; nextIndex += 1) {
      const nextBlock = topLevelBlocks[nextIndex];
      if (nextBlock.pos >= sectionEnd) {
        break;
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

function createHeadingToggle(
  view: EditorView | null,
  pos: number,
  isCollapsed: boolean
): HTMLElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "thread-note-heading-toggle";
  button.textContent = isCollapsed ? "▸" : "▾";
  button.setAttribute("aria-label", isCollapsed ? "Expand section" : "Collapse section");
  button.setAttribute("title", isCollapsed ? "Expand section" : "Collapse section");

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

function mapHeadingPositions(positions: number[], transaction: Transaction): number[] {
  const mapped = positions
    .map((position) => transaction.mapping.mapResult(position, -1))
    .filter((result) => !result.deleted)
    .map((result) => result.pos);

  return [...new Set(mapped)];
}

function toggleHeadingPosition(positions: number[], pos: number): number[] {
  return positions.includes(pos)
    ? positions.filter((position) => position !== pos)
    : [...positions, pos];
}
