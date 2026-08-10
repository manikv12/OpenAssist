import assert from "node:assert/strict";
import { NarrationArbiter, NarrationRequestQueue } from "../dist-electron/liveVoice/narrationArbiter.js";

const queue = new NarrationRequestQueue();
assert.equal(queue.enqueue({ deliveryID: "normal", reason: "normal response" }), true);
assert.equal(queue.enqueue({ deliveryID: "worker-a", reason: "worker result" }), true);
assert.equal(queue.enqueue({ deliveryID: "worker-b", reason: "worker result" }), true);
assert.equal(queue.enqueue({ deliveryID: "worker-a", reason: "duplicate" }), false);
assert.deepEqual([queue.shift().deliveryID, queue.shift().deliveryID, queue.shift().deliveryID], ["normal", "worker-a", "worker-b"]);

let now = 1;
const arbiter = new NarrationArbiter();
const add = (deliveryID, kind, priority = 50) => arbiter.enqueue({
  deliveryID,
  kind,
  priority,
  sourceTurnID: `turn-${deliveryID}`,
  createdAt: now++
});

add("conversation", "conversation", 100);
add("codex", "delegated", 50);
add("claude", "delegated", 50);
assert.equal(arbiter.reserve("conversation"), true);
assert.equal(arbiter.reserve("codex"), false, "a second speaker cannot reserve the channel");
assert.equal(arbiter.markStreaming("conversation", "response-1"), true);
assert.equal(arbiter.markPlaying("conversation"), true);
assert.equal(arbiter.active().deliveryID, "conversation");
assert.equal(arbiter.finishPlayback("codex"), undefined, "late events cannot finish another speaker");
assert.equal(arbiter.finishPlayback("conversation").state, "delivered");

assert.equal(arbiter.reserve("codex"), true);
assert.equal(arbiter.markPlaying("codex"), true);
const firstInterruption = arbiter.interruptActive();
assert.equal(firstInterruption.action, "retry-short");
assert.equal(arbiter.get("codex").state, "queued");
assert.equal(arbiter.reserve("codex"), true);
const secondInterruption = arbiter.interruptActive();
assert.equal(secondInterruption.action, "leave-silent");
assert.equal(arbiter.get("codex").state, "delivered");

assert.equal(arbiter.reserve("claude"), true);
assert.equal(arbiter.markStreaming("claude", "response-claude"), true);
assert.equal(arbiter.active().deliveryID, "claude");
assert.equal(arbiter.queued().length, 0);
assert.equal(arbiter.finishWithoutAudio("claude").state, "delivered");
assert.equal(arbiter.isFree(), true);

add("knowledge", "knowledge", 70);
add("status", "status", 20);
assert.deepEqual(arbiter.queued().map((entry) => entry.deliveryID), ["knowledge", "status"]);
assert.equal(arbiter.reserve("knowledge"), true);
assert.equal(arbiter.reserve("status"), false);
assert.equal(arbiter.finishPlayback("knowledge").state, "delivered");
assert.equal(arbiter.reserve("status"), true);
assert.equal(arbiter.finishWithoutAudio("status").state, "delivered");

console.log("Single-speaker Live Voice checks passed.");
