import React from 'react';
import { JSDOM } from 'jsdom';
import { createRoot } from 'react-dom/client';
import { ThreadNoteDrawer } from './src/components/ThreadNoteDrawer';
import type { ThreadNoteState } from './src/types';

const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', {
  url: 'http://localhost/'
});

Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  SVGElement: dom.window.SVGElement,
  Node: dom.window.Node,
  DOMParser: dom.window.DOMParser,
  Range: dom.window.Range,
  Selection: dom.window.Selection,
  Text: dom.window.Text,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (cb: FrameRequestCallback) => setTimeout(() => cb(Date.now()), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
});

(globalThis as any).ResizeObserver = class {
  observe() {}
  disconnect() {}
  unobserve() {}
};

const state: ThreadNoteState = {
  threadId: null,
  ownerKind: 'project',
  ownerId: 'project-1',
  ownerTitle: 'Project 1',
  presentation: 'projectFullScreen',
  availableSources: [
    {
      ownerKind: 'project',
      ownerId: 'project-1',
      ownerTitle: 'Project 1',
      sourceLabel: 'Project notes',
    },
  ],
  notes: [
    {
      id: 'note-1',
      title: 'Main note',
      updatedAtLabel: 'Saved now',
      ownerKind: 'project',
      ownerId: 'project-1',
      sourceLabel: 'Project notes',
    },
  ],
  selectedNoteId: 'note-1',
  selectedNoteTitle: 'Main note',
  text: '# Hello\n\nWorld',
  isOpen: true,
  isExpanded: true,
  viewMode: 'edit',
  hasAnyNotes: true,
  isSaving: false,
  isGeneratingAIDraft: false,
  aiDraftMode: null,
  lastSavedAtLabel: 'Saved now',
  canEdit: true,
  placeholder: 'Write note',
  aiDraftPreview: null,
  outgoingLinks: [],
  backlinks: [],
  graph: null,
  canNavigateBack: false,
  previousLinkedNoteTitle: null,
};

process.on('uncaughtException', (error) => {
  console.error('UNCAUGHT', error);
  process.exit(1);
});
process.on('unhandledRejection', (error) => {
  console.error('UNHANDLED', error);
  process.exit(1);
});

const root = createRoot(document.getElementById('root')!);
root.render(React.createElement(ThreadNoteDrawer, { state, onDispatchCommand: () => {} }));

setTimeout(() => {
  console.log('HTML_LENGTH', document.body.innerHTML.length);
  console.log(document.body.innerHTML.slice(0, 1500));
  process.exit(0);
}, 2500);
