import {
  classifyOllamaCliPath,
  classifyRunningCommand,
  compareVersions,
  isOllamaVersionUpgradeError,
  parseOllamaVersion
} from "../dist-electron/ollamaRuntime.js";

const versionChecks = [
  ["ollama version is 0.30.3", "0.30.3"],
  ["v0.30.8", "0.30.8"],
  ["", null]
];

for (const [raw, expected] of versionChecks) {
  const actual = parseOllamaVersion(raw);
  if (actual !== expected) {
    console.error(`parseOllamaVersion(${JSON.stringify(raw)}) expected ${expected}, got ${actual}`);
    process.exit(1);
  }
}

if (compareVersions("0.20.2", "0.30.8") >= 0) {
  console.error("compareVersions should mark 0.20.2 as older than 0.30.8");
  process.exit(1);
}

if (!isOllamaVersionUpgradeError("pull model manifest: 412: The model you are attempting to pull requires a newer version of Ollama.")) {
  console.error("isOllamaVersionUpgradeError should detect 412 upgrade errors");
  process.exit(1);
}

if (classifyOllamaCliPath("/opt/homebrew/Cellar/ollama/0.20.2/bin/ollama") !== "homebrew-formula") {
  console.error("classifyOllamaCliPath should detect Homebrew Cellar installs");
  process.exit(1);
}

if (classifyOllamaCliPath("/Applications/Ollama.app/Contents/Resources/ollama") !== "native-app") {
  console.error("classifyOllamaCliPath should detect native Ollama.app installs");
  process.exit(1);
}

if (classifyRunningCommand("/opt/homebrew/Cellar/ollama/0.20.2/bin/ollama serve") !== "homebrew-formula") {
  console.error("classifyRunningCommand should detect Homebrew serve processes");
  process.exit(1);
}

console.log("verify-ollama-runtime: ok");
