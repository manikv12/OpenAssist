import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = process.cwd();
const image = process.env.VOICE_LINUX_IMAGE || 'openassist-workspace-voice:0.150.1-canary';
const containerName = `openassist-voice-canary-${process.pid}`;
const internalToken = 'local-canary-token-1234567890-abcdef';
const schemaDir = await mkdtemp(path.join(os.tmpdir(), 'openassist-voice-schema-'));

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    timeout: options.timeout ?? 180_000,
    input: options.input,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed (${result.status}).\n${result.stderr || result.stdout}`);
  }
  return String(result.stdout || '').trim();
}

async function waitForHealth(origin) {
  const deadline = Date.now() + 20_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${origin}/health`, { signal: AbortSignal.timeout(2_000) });
      const body = await response.json();
      if (response.ok && body.status === 'ok') return body;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw lastError || new Error('The Linux voice image did not become healthy.');
}

try {
  run('docker', ['build', '--platform', 'linux/amd64', '--build-arg', 'CODEX_VERSION=0.150.1', '-t', image, '.']);
  const platform = run('docker', ['image', 'inspect', '--format', '{{.Os}}/{{.Architecture}}', image]);
  assert.equal(platform, 'linux/amd64');
  assert.equal(run('docker', ['run', '--rm', '--platform', 'linux/amd64', '--entrypoint', 'codex', image, '--version']), 'codex-cli 0.150.1');

  run('docker', [
    'run', '--rm', '--platform', 'linux/amd64', '-i',
    '-v', `${path.join(root, 'container/config.toml')}:/runtime/codex/config.toml:ro`,
    '--entrypoint', 'codex', image, '--strict-config', '--enable', 'realtime_conversation', 'app-server',
  ], { input: '' });

  run('docker', [
    'run', '--rm', '--platform', 'linux/amd64',
    '-v', `${schemaDir}:/schemas`,
    '--entrypoint', 'codex', image,
    'app-server', 'generate-json-schema', '--experimental', '--out', '/schemas',
  ]);
  const protocol = await readFile(path.join(schemaDir, 'ClientRequest.json'), 'utf8');
  assert.match(protocol, /thread\/realtime\/start/);
  assert.match(protocol, /ThreadRealtimeStartParams/);
  assert.match(protocol, /"webrtc"/);
  assert.match(protocol, /"v3"/);
  assert.match(protocol, /outputModality/);

  run('docker', [
    'run', '-d', '--rm', '--platform', 'linux/amd64', '--name', containerName,
    '-e', `CONTAINER_INTERNAL_TOKEN=${internalToken}`,
    '-p', '127.0.0.1::8080', image,
  ]);
  const portLine = run('docker', ['port', containerName, '8080/tcp']);
  const match = portLine.match(/127\.0\.0\.1:(\d+)/);
  assert.ok(match, `Could not determine the Linux canary port from ${portLine}`);
  const origin = `http://127.0.0.1:${match[1]}`;
  const health = await waitForHealth(origin);
  assert.equal(health.runtimeVersion, 'unknown');
  const unauthorized = await fetch(`${origin}/auth/status`, { headers: { accept: 'application/json' } });
  assert.equal(unauthorized.status, 401);

  const authorizedHeaders = {
    accept: 'application/json',
    'content-type': 'application/json',
    'x-openassist-container-token': internalToken,
  };
  const deviceAuth = await fetch(`${origin}/auth/start`, {
    method: 'POST',
    headers: authorizedHeaders,
    body: '{}',
    signal: AbortSignal.timeout(30_000),
  });
  const deviceAuthBody = await deviceAuth.json();
  assert.equal(deviceAuth.status, 200, deviceAuthBody.message || 'The Linux image could not start ChatGPT device sign-in.');
  assert.equal(deviceAuthBody.status, 'pending');
  assert.match(deviceAuthBody.verificationUrl, /^https:\/\/auth\.openai\.com\/codex\/device$/);
  assert.match(deviceAuthBody.userCode, /^[A-Z0-9]{4}-[A-Z0-9]{4,8}$/);
  const disconnect = await fetch(`${origin}/disconnect`, {
    method: 'POST',
    headers: authorizedHeaders,
    body: '{}',
    signal: AbortSignal.timeout(10_000),
  });
  assert.equal(disconnect.status, 200);

  process.stdout.write(`${JSON.stringify({
    image,
    platform,
    codexVersion: '0.150.1',
    strictConfig: 'pass',
    realtimeProtocol: 'pass',
    containerHealth: 'pass',
    unauthenticatedAccessDenied: 'pass',
    subscriptionDeviceSignIn: 'pass',
  }, null, 2)}\n`);
} finally {
  spawnSync('docker', ['stop', containerName], { cwd: root, encoding: 'utf8', timeout: 20_000 });
  await rm(schemaDir, { recursive: true, force: true });
}
