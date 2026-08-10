import fs from "node:fs";
import path from "node:path";

const appRoot = path.join(
  process.cwd(),
  "out",
  "Open Assist-darwin-arm64",
  "Open Assist.app",
  "Contents",
  "Resources",
  "app"
);
const sdkPath = path.join(appRoot, "node_modules", "@anthropic-ai", "claude-agent-sdk", "sdk.mjs");
const runtimePath = path.join(appRoot, "node_modules", "@anthropic-ai", "claude-agent-sdk-darwin-arm64", "claude");

if (!fs.existsSync(sdkPath)) throw new Error(`Missing packaged Claude Agent SDK: ${sdkPath}`);
if (!fs.existsSync(runtimePath)) throw new Error(`Missing packaged Claude native runtime: ${runtimePath}`);
if ((fs.statSync(runtimePath).mode & 0o111) === 0) throw new Error(`Packaged Claude runtime is not executable: ${runtimePath}`);

console.log(JSON.stringify({ claudeAgentSDKBundled: true, sdkPath, runtimePath }));
