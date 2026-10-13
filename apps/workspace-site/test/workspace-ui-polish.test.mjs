import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const componentUrl = new URL('../app/components/workspace-app.tsx', import.meta.url);
const cssUrl = new URL('../app/globals.css', import.meta.url);
const orbUrl = new URL('../app/components/voice-orb.tsx', import.meta.url);

test('workspace exposes owner and judge visual modes', async () => {
  const source = await readFile(componentUrl, 'utf8');
  const css = await readFile(cssUrl, 'utf8');
  assert.match(source, /data-workspace-mode=\{mode === 'live' \? 'owner' : 'judge'\}/);
  assert.match(css, /\[data-workspace-mode='owner'\]/);
  assert.match(css, /\[data-workspace-mode='judge'\]/);
});

test('voice panel is movable, keyboard accessible, and stays below approvals', async () => {
  const source = await readFile(componentUrl, 'utf8');
  const css = await readFile(cssUrl, 'utf8');
  assert.match(source, /openassist\.voice\.position\.v1/);
  assert.match(source, /onPointerDown=\{beginDrag\}/);
  assert.match(source, /moveByKeyboard/);
  assert.match(source, /new ResizeObserver\(keepVisible\)/);
  assert.match(source, /primaryActionRef\.current\?\.focus\(\)/);
  assert.match(source, /event\.key !== 'Escape'/);
  assert.match(source, /role="dialog" aria-modal="false"/);
  assert.match(source, /Reset/);
  assert.match(css, /\.oa-approval-dock\s*\{[^}]*z-index:\s*110/s);
  assert.match(css, /@media \(max-width: 767px\)[\s\S]*overscroll-behavior: contain/);
});

test('orb has clear palettes for every conversation state', async () => {
  const source = await readFile(orbUrl, 'utf8');
  for (const phase of ['idle', 'connecting', 'listening', 'thinking', 'speaking', 'muted', 'error']) {
    assert.match(source, new RegExp(`${phase}: \\{ low:`));
  }
  assert.match(source, /targetPalette = colors \?\? PHASE_COLORS\[current\]/);
});
