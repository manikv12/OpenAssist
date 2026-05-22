import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const bundledCodexPath = "/Applications/Codex.app/Contents/Resources/codex";
const codexExecutable = fs.existsSync(bundledCodexPath) ? bundledCodexPath : "codex";
const outputDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "codex-realtime-protocol-"));

const requiredMethods = [
  "thread/realtime/start",
  "thread/realtime/appendAudio",
  "thread/realtime/appendText",
  "thread/realtime/stop",
  "thread/realtime/listVoices"
];

const requiredTypeFiles = [
  "v2/ThreadRealtimeStartParams.ts",
  "v2/ThreadRealtimeAppendAudioParams.ts"
];

const notificationTypeCandidates = [
  "v2/ThreadRealtimeOutputAudioDeltaNotification.ts",
  "ThreadRealtimeOutputAudioDeltaNotification.ts"
];

function fail(message) {
  throw new Error(message);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function relativePath(filePath) {
  return path.relative(outputDirectory, filePath).split(path.sep).join("/");
}

function walkFiles(directory) {
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFiles(fullPath));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }
  return files;
}

function runGenerateTs() {
  const args = [
    "app-server",
    "generate-ts",
    "--experimental",
    "--enable",
    "realtime_conversation",
    "--out",
    outputDirectory
  ];

  const result = spawnSync(codexExecutable, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });

  if (result.error) {
    fail(`Could not run Codex app-server generator with ${codexExecutable}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const stderr = result.stderr?.trim();
    const stdout = result.stdout?.trim();
    fail([
      `Codex app-server generate-ts failed with exit code ${result.status}.`,
      stderr ? `stderr:\n${stderr}` : null,
      stdout ? `stdout:\n${stdout}` : null
    ].filter(Boolean).join("\n"));
  }
}

function verifyClientRequest() {
  const clientRequestPath = path.join(outputDirectory, "ClientRequest.ts");
  assert(fs.existsSync(clientRequestPath), `Missing generated ClientRequest.ts in ${outputDirectory}`);

  const clientRequest = fs.readFileSync(clientRequestPath, "utf8");
  const missingMethods = requiredMethods.filter((method) => !clientRequest.includes(`"method": "${method}"`));
  assert(
    missingMethods.length === 0,
    `ClientRequest.ts is missing realtime methods: ${missingMethods.join(", ")}`
  );
}

function verifyTypeFiles() {
  const generatedFiles = walkFiles(outputDirectory);
  const generatedRelativePaths = new Set(generatedFiles.map(relativePath));

  const missingTypeFiles = requiredTypeFiles.filter((filePath) => !generatedRelativePaths.has(filePath));
  assert(
    missingTypeFiles.length === 0,
    `Missing realtime type files: ${missingTypeFiles.join(", ")}`
  );

  const hasOutputAudioDeltaNotification = notificationTypeCandidates.some((filePath) => generatedRelativePaths.has(filePath))
    || generatedFiles.some((filePath) => {
      const baseName = path.basename(filePath);
      if (!baseName.includes("OutputAudioDelta") || !baseName.includes("Notification")) return false;
      return fs.readFileSync(filePath, "utf8").includes("ThreadRealtimeOutputAudioDeltaNotification");
    });

  assert(
    hasOutputAudioDeltaNotification,
    "Missing realtime output audio delta notification type, expected ThreadRealtimeOutputAudioDeltaNotification or equivalent."
  );
}

try {
  runGenerateTs();
  verifyClientRequest();
  verifyTypeFiles();

  console.log(`Codex realtime protocol smoke check passed using ${codexExecutable}.`);
  console.log(`Generated TypeScript included ${requiredMethods.length} realtime request methods and required realtime type files.`);

  if (!process.env.OPENASSIST_KEEP_CODEX_REALTIME_PROTOCOL_TMP) {
    fs.rmSync(outputDirectory, { recursive: true, force: true });
  } else {
    console.log(`Kept generated TypeScript at ${outputDirectory}`);
  }
} catch (error) {
  console.error(`Codex realtime protocol smoke check failed: ${error.message}`);
  console.error(`Generated TypeScript directory: ${outputDirectory}`);
  process.exitCode = 1;
}
