import assert from 'node:assert/strict';
import test from 'node:test';
import { LatestRequestGate } from '../lib/latest-request.mjs';

test('closing the reader invalidates an in-flight message read', () => {
  const gate = new LatestRequestGate();
  const request = gate.begin();
  gate.cancel();
  assert.equal(gate.isCurrent(request), false);
});

test('a newer message wins when reads finish out of order', () => {
  const gate = new LatestRequestGate();
  const messageA = gate.begin();
  const messageB = gate.begin();
  assert.equal(gate.isCurrent(messageA), false);
  assert.equal(gate.isCurrent(messageB), true);
});
