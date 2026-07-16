import fs from "node:fs";
import path from "node:path";

const root = path.resolve(".");
const bridge = fs.readFileSync(path.join(root, "electron/openassistBridge.ts"), "utf8");
const renderer = fs.readFileSync(path.join(root, "src/App.tsx"), "utf8");
const types = fs.readFileSync(path.join(root, "src/types.ts"), "utf8");

const checks = [
  ["bridge: setting snapshot includes echo guard", bridge, /liveVoiceEchoGuardEnabled: boolean/],
  ["bridge: echo guard is enabled by default", bridge, /liveVoiceEchoGuardEnabled: await readBoolDefault\("OpenAssist\.liveVoice\.echoGuardEnabled", true\)/],
  ["bridge: echo guard setting is writable", bridge, /liveVoiceEchoGuardEnabled: \{ defaultsKey: "OpenAssist\.liveVoice\.echoGuardEnabled", type: "bool" \}/],
  ["types: renderer settings include echo guard", types, /liveVoiceEchoGuardEnabled: boolean/],
  ["types: echo guard can be updated", types, /\| "liveVoiceEchoGuardEnabled"/],
  ["renderer: echo guard ref is synced from settings", renderer, /liveVoiceEchoGuardEnabledRef\.current = Boolean\(appState\.settings\.liveVoiceEchoGuardEnabled\)/],
  ["renderer: flush drops mic chunks while assistant speaks", renderer, /liveVoiceEchoGuardEnabledRef\.current && \(liveVoiceMeterBus\.outputPlaying \|\| liveVoiceStatusRef\.current === "speaking"\)[\s\S]{0,160}liveVoiceInputChunksRef\.current = \[\]/],
  ["renderer: processor drops mic chunks while assistant speaks", renderer, /processor\.onaudioprocess = \(event\) => \{[\s\S]{0,650}liveVoiceEchoGuardEnabledRef\.current && \(liveVoiceMeterBus\.outputPlaying \|\| liveVoiceStatusRef\.current === "speaking"\)/],
  ["renderer: settings UI exposes echo guard", renderer, /checked=\{settings\?\.liveVoiceEchoGuardEnabled \?\? true\}[\s\S]{0,160}label="Pause mic while assistant speaks"/]
];

let failures = 0;
for (const [label, source, pattern] of checks) {
  const pass = pattern.test(source);
  console.log(`${pass ? "PASS" : "FAIL"} ${label}`);
  if (!pass) failures += 1;
}

if (failures > 0) {
  console.error(`\nLive Voice echo guard check FAILED (${failures} missing).`);
  process.exit(1);
}

console.log("\nLive Voice echo guard check passed.");
