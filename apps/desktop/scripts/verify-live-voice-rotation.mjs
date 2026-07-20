import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bridge = await readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const app = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");

// Voice threads are identified by the persisted kind flag, not exact title.
assert.match(bridge, /kind\?: string;/, "SessionSummary must carry the kind flag");
assert.match(bridge, /liveVoiceDayID\?: string;/, "SessionSummary must carry liveVoiceDayID");
assert.match(bridge, /function isLiveVoiceSession/, "bridge must resolve voice threads by flag with title fallback");

// Rotation: at session start, a stale-day thread is renamed to a dated title,
// archived synchronously in the registry, and a fresh thread is created.
assert.match(bridge, /session\.liveVoiceDayID !== todayDayID/, "rotation must compare the stored day to today");
assert.match(bridge, /liveVoiceArchivedTitle\(rotatedDayID\)/, "rotated logs must get dated titles");
assert.match(bridge, /session\.isArchived = true;[\s\S]{0,200}?updateSession\(session\);[\s\S]{0,400}?archiveCodexProviderThread/, "registry archive must be synchronous with provider archive best-effort after");
assert.match(bridge, /finalizeLiveVoiceDayLog\(rotatedID\)/, "rotation must invoke the day-log finalize hook");
assert.match(bridge, /pruneArchivedLiveVoiceThreads\(\)/, "rotation must prune old voice archives (registry 200-cap)");
assert.match(bridge, /session\.kind = "liveVoice";\s*\n\s*session\.liveVoiceDayID = todayDayID;/, "fresh voice threads must be stamped with flag and day");

// Migration: legacy title-matched thread gets the flag stamped on first touch.
assert.match(bridge, /session\.kind !== "liveVoice" \|\| !session\.liveVoiceDayID/, "legacy threads must be migrated in place");

// Renderer: never renames an existing thread back to "Today Live Voice".
assert.match(app, /const renamed = thread\s*\n?\s*\? null/, "renderer rename must only apply to freshly created threads");
// Renderer persists the bridge's (possibly rotated) thread ID after start.
assert.match(app, /saveTodayLiveVoiceThreadID\(liveThreadID\);/, "start result must persist the authoritative thread ID");
// Predicates recognize the flag and dated archives so they group under Archived Voice.
assert.match(app, /thread\?\.kind === "liveVoice"/, "renderer predicate must honor the kind flag");
assert.match(app, /isRotatedLiveVoiceThreadTitle/, "renderer must recognize rotated dated titles");
assert.doesNotMatch(app, /thread\.title === "Today Live Voice"/, "no hardcoded title literals outside the predicate helpers");

// ThreadItem carries the kind flag across the bridge boundary.
const types = await readFile(new URL("../src/types.ts", import.meta.url), "utf8");
assert.match(types, /kind\?: string;/, "renderer ThreadItem must carry kind");

console.log("Live Voice daily rotation checks passed.");
