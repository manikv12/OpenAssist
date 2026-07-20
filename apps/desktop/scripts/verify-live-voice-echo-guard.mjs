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
  ["renderer: echo guard uses acoustic echo cancellation", renderer, /const liveVoiceAudioProcessing[\s\S]{0,260}echoCancellation: liveVoiceEchoGuardEnabledRef\.current/],
  ["renderer: voice isolation is requested when supported", renderer, /supportedAudioConstraints\?\.voiceIsolation[\s\S]{0,80}voiceIsolation: true/],
  ["renderer: automatic gain does not amplify distant audio", renderer, /autoGainControl: false/],
  ["renderer: mic processing stays open for barge-in", renderer, /processor\.onaudioprocess = \(event\) => \{[\s\S]{0,500}if \(liveVoiceMutedRef\.current\)[\s\S]{0,300}const channel = event\.inputBuffer\.getChannelData\(0\)/],
  ["renderer: real mic frames reach provider VAD", renderer, /const frame = new Float32Array\(channel\);[\s\S]{0,400}liveVoiceInputChunksRef\.current\.push\(frame\)/],
  ["renderer: settings UI exposes echo guard", renderer, /checked=\{settings\?\.liveVoiceEchoGuardEnabled \?\? true\}[\s\S]{0,160}label="Prevent assistant audio echo"/]
];

const hardPausePattern = /liveVoiceEchoGuardEnabledRef\.current && \(liveVoiceMeterBus\.outputPlaying \|\| liveVoiceStatusRef\.current === "speaking"\)/;
if (hardPausePattern.test(renderer)) {
  console.error("FAIL renderer: echo guard must not hard-pause the mic while the assistant speaks");
  process.exit(1);
}

if (/liveVoiceGate|new Float32Array\(channel\.length\)/.test(renderer)) {
  console.error("FAIL renderer: cloud Live Voice must not replace quiet speech before provider VAD");
  process.exit(1);
}

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
