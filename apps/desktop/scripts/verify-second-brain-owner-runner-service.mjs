import assert from "node:assert/strict";
import { SecondBrainOwnerRunnerService } from "../dist-electron/secondBrainOwnerRunnerService.js";

let created = 0;
let stopped = 0;
let observedPoll = 0;
let observedIdlePoll = 0;
let release;
const service = new SecondBrainOwnerRunnerService({
  enabled: true,
  pollIntervalMs: 1_000,
  createHost() {
    created += 1;
    return {
      async runUntilStopped(input) {
        observedPoll = input.pollIntervalMs;
        observedIdlePoll = input.idlePollIntervalMs;
        input.onOutcome({ status: "idle" }, {
          nextPollMs: 120_000,
          consecutiveIdle: 2,
          pollIntervalMs: input.pollIntervalMs,
          idlePollIntervalMs: input.idlePollIntervalMs,
        });
        await new Promise((resolve) => {
          release = resolve;
          input.signal.addEventListener("abort", resolve, { once: true });
        });
      },
      async stop() { stopped += 1; release?.(); },
    };
  },
});

assert.equal((await service.start("app-ready")).running, true);
assert.equal(created, 1);
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(observedPoll, 30_000, "polling must never churn below 30 seconds");
assert.equal(observedIdlePoll, 900_000, "the idle backoff ceiling defaults to 15 minutes");
assert.deepEqual(service.status().lastOutcome, { status: "idle" });
assert.deepEqual(service.status().poll, {
  nextPollMs: 120_000,
  consecutiveIdle: 2,
  pollIntervalMs: 30_000,
  idlePollIntervalMs: 900_000,
}, "status must surface the next poll delay for the desktop");
assert.equal((await service.pause("lock")).paused, true);
assert.ok(stopped >= 1);
assert.equal((await service.resume("unlock")).running, true);
assert.equal(created, 2);
assert.equal((await service.setEnabled(false)).enabled, false);
assert.equal(service.status().running, false);
assert.equal((await service.start("must-not-start")).running, false);
assert.equal(created, 2);

// The idle ceiling is clamped to 1-30 minutes and never drops below the floor.
for (const [requested, expected] of [[undefined, 900_000], [1_000, 60_000], [60 * 60_000, 1_800_000]]) {
  let seen;
  const clampService = new SecondBrainOwnerRunnerService({
    enabled: true,
    pollIntervalMs: 60_000,
    idlePollIntervalMs: requested,
    createHost() {
      return {
        async runUntilStopped(input) {
          seen = input;
          await new Promise((resolve) => input.signal.addEventListener("abort", resolve, { once: true }));
        },
        async stop() {},
      };
    },
  });
  await clampService.start("clamp");
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(seen.idlePollIntervalMs, expected, `idlePollIntervalMs ${requested} must clamp to ${expected}`);
  assert.ok(seen.idlePollIntervalMs >= seen.pollIntervalMs, "the ceiling must never sit below the floor");
  await clampService.stop("clamp-done");
}

console.log("Second Brain owner runner service verification passed.");
