import fs from "node:fs";
import path from "node:path";

const sourcePath = path.join(process.cwd(), "bin", "openassist-knowledge.mjs");
const packagedPath = path.join(
  process.cwd(),
  "out",
  "Open Assist-darwin-arm64",
  "Open Assist.app",
  "Contents",
  "Resources",
  "app",
  "bin",
  "openassist-knowledge.mjs"
);

if (!fs.existsSync(sourcePath)) {
  throw new Error(`Missing source OpenAssist Knowledge proxy: ${sourcePath}`);
}

if (!fs.existsSync(packagedPath)) {
  throw new Error(`Missing packaged OpenAssist Knowledge proxy: ${packagedPath}`);
}

console.log(JSON.stringify({ knowledgeProxyBundled: true, path: packagedPath }));
