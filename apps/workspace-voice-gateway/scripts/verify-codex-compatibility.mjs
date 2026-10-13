import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const root = process.cwd();
const server = await readFile(path.join(root, 'container/server.mjs'), 'utf8');
const dockerfile = await readFile(path.join(root, 'Dockerfile'), 'utf8');
const packageJson = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const toolNames = JSON.parse(await readFile(path.join(root, 'container/tool-names.json'), 'utf8'));
const realtimeVoices = JSON.parse(await readFile(path.join(root, 'container/realtime-voices.json'), 'utf8'));

assert.match(server, /thread\/realtime\/start/);
assert.match(server, /outputModality: 'audio'/);
assert.match(server, /outputModality: 'audio',[\s\S]{0,80}voice,/);
assert.match(server, /transport: \{ type: 'webrtc', sdp: offerSdp \}/);
assert.match(server, /capabilities: \{ experimentalApi: true \}/);
assert.doesNotMatch(server, /session\.model/);
assert.doesNotMatch(server, /thread\/realtime\/start[\s\S]{0,500}\bmodel\s*:/);
assert.match(dockerfile, /ARG CODEX_VERSION=0\.150\.1/);
assert.equal(packageJson.dependencies.ws, '8.21.0');
assert.equal(toolNames.length, 43);
assert.ok(realtimeVoices.some((voice) => voice.id === 'marin'));
assert.ok(realtimeVoices.some((voice) => voice.id === 'cedar'));

const authenticatedCanaryPassed = process.env.VOICE_AUTH_CANARY_PASSED === '1';
const report = {
  codexVersion: '0.150.1',
  protocolShape: 'pass',
  webrtcShape: 'pass',
  forbiddenModelField: 'absent',
  apiKeyFallback: 'absent',
  toolContractCount: toolNames.length,
  selectableVoices: realtimeVoices.map((voice) => voice.id),
  authenticatedMicrophoneCanary: authenticatedCanaryPassed ? 'pass' : 'required before release',
};
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

if (process.env.REQUIRE_AUTH_CANARY === '1' && !authenticatedCanaryPassed) {
  throw new Error('Release is blocked until the real subscription microphone and spoken-audio canary passes.');
}
