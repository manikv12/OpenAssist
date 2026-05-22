import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const appExecutable = path.join(
  process.cwd(),
  "out",
  "Open Assist-darwin-arm64",
  "Open Assist.app",
  "Contents",
  "MacOS",
  "Open Assist"
);

const packagedDebugPort = process.env.OPENASSIST_ELECTRON_REMOTE_DEBUG_PORT ?? "8316";
const cdpEndpoint = process.env.OPENASSIST_ELECTRON_CDP ?? `http://127.0.0.1:${packagedDebugPort}/json/list`;
const verifierEnvironment = {
  ...process.env,
  OPENASSIST_ELECTRON_CDP: cdpEndpoint,
  OPENASSIST_ELECTRON_REMOTE_DEBUG_PORT: packagedDebugPort
};

const sourceIconPath = path.join(process.cwd(), "icon.icns");
const packagedIconPath = path.join(
  process.cwd(),
  "out",
  "Open Assist-darwin-arm64",
  "Open Assist.app",
  "Contents",
  "Resources",
  "electron.icns"
);

function fileHash(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function verifyPackagedIcon() {
  if (!fs.existsSync(sourceIconPath)) {
    throw new Error(`Missing source OpenAssist app icon: ${sourceIconPath}`);
  }
  if (!fs.existsSync(packagedIconPath)) {
    throw new Error(`Missing packaged app icon: ${packagedIconPath}`);
  }
  const sourceHash = fileHash(sourceIconPath);
  const packagedHash = fileHash(packagedIconPath);
  if (sourceHash !== packagedHash) {
    throw new Error(`Packaged icon does not match OpenAssist icon. source=${sourceHash} packaged=${packagedHash}`);
  }
  console.log(JSON.stringify({ packagedIconMatchesSource: true, iconHash: sourceHash }));
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForRenderer(timeout = 8000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      const response = await fetch(cdpEndpoint);
      const targets = await response.json();
      if (Array.isArray(targets) && targets.some((target) => target.type === "page")) return;
    } catch {
      // The app has not opened the debug endpoint yet.
    }
    await wait(200);
  }
  throw new Error(`Timed out waiting for Electron renderer at ${cdpEndpoint}.`);
}

function runNodeScript(scriptPath) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [scriptPath], {
      cwd: process.cwd(),
      env: verifierEnvironment,
      stdio: "inherit"
    });
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${scriptPath} failed with code ${code ?? signal}.`));
    });
  });
}

const app = spawn(appExecutable, [], {
  cwd: process.cwd(),
  env: {
    ...verifierEnvironment,
    OPENASSIST_ELECTRON_REMOTE_DEBUG: "1"
  },
  stdio: ["ignore", "pipe", "pipe"]
});

app.stdout.on("data", (chunk) => process.stdout.write(chunk));
app.stderr.on("data", (chunk) => process.stderr.write(chunk));

let appExited = false;
app.on("exit", () => {
  appExited = true;
});

try {
  verifyPackagedIcon();
  await waitForRenderer();
  await runNodeScript(path.join(process.cwd(), "scripts", "verify-running-electron.mjs"));
} finally {
  if (!appExited) {
    app.kill("SIGTERM");
    await wait(1000);
    if (!appExited) app.kill("SIGKILL");
  }
}
