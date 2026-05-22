import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const outputDirectory = path.join(process.cwd(), "verification");
const appExecutable = path.join(
  process.cwd(),
  "out",
  "Open Assist-darwin-arm64",
  "Open Assist.app",
  "Contents",
  "MacOS",
  "Open Assist"
);
const cdpEndpoint = process.env.OPENASSIST_ELECTRON_CDP ?? "http://127.0.0.1:8315/json/list";

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForRenderer(timeout = 8000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      const response = await fetch(cdpEndpoint);
      const targets = await response.json();
      const pageTargets = targets.filter((item) => item.type === "page" && item.webSocketDebuggerUrl);
      const target = pageTargets.find((item) => String(item.url ?? "").includes("127.0.0.1:5187"))
        ?? pageTargets.find((item) => !String(item.title ?? "").includes("Voice HUD") && !String(item.url ?? "").startsWith("data:text/html"))
        ?? pageTargets.find((item) => !String(item.title ?? "").includes("Voice HUD"))
        ?? pageTargets[0];
      if (target) return target;
    } catch {
      // Renderer is not ready yet.
    }
    await wait(200);
  }
  throw new Error(`Timed out waiting for Electron renderer at ${cdpEndpoint}.`);
}

function createCDPClient(webSocketDebuggerUrl) {
  const socket = new WebSocket(webSocketDebuggerUrl);
  const pending = new Map();
  let id = 0;
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (!pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  };
  const opened = new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  const send = async (method, params = {}) => {
    await opened;
    return new Promise((resolve, reject) => {
      pending.set(++id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
  };
  return {
    send,
    close: () => socket.close()
  };
}

async function evaluate(client, expression) {
  const result = await client.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || "Renderer evaluation failed.");
  }
  return result.result?.value;
}

async function waitFor(client, expression, label, timeout = 8000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (await evaluate(client, expression)) return;
    await wait(160);
  }
  throw new Error(`Timed out waiting for ${label}.`);
}

async function capture(client, filename) {
  const result = await client.send("Page.captureScreenshot", { format: "png", fromSurface: true });
  const outputPath = path.join(outputDirectory, filename);
  fs.writeFileSync(outputPath, Buffer.from(result.data, "base64"));
  return outputPath;
}

fs.mkdirSync(outputDirectory, { recursive: true });

const app = spawn(appExecutable, [], {
  cwd: process.cwd(),
  env: {
    ...process.env,
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

const captures = [];
let client;

try {
  const target = await waitForRenderer();
  client = createCDPClient(target.webSocketDebuggerUrl);
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await waitFor(client, `Boolean(document.querySelector(".app-shell"))`, "app shell");
  await evaluate(client, `window.openAssistElectron?.setWindowMode?.("full", true, "right")`);
  await waitFor(client, `!document.querySelector(".app-shell")?.className.includes("sidebar-collapsed")`, "expanded app shell");
  await evaluate(client, `
    (() => {
      if (document.querySelector(".assistant-main")) return true;
      const buttons = Array.from(document.querySelectorAll("button"));
      buttons.find((button) => button.textContent.trim() === "Open Assistant" || button.textContent.trim() === "Threads")?.click();
      return true;
    })()
  `);
  await waitFor(client, `Boolean(document.querySelector(".assistant-main"))`, "threads view");
  await wait(300);

  captures.push(await capture(client, "openassist-chat-view.png"));

  await evaluate(client, `
    (() => {
      const buttons = Array.from(document.querySelectorAll("button"));
      buttons.find((button) => button.textContent.trim().startsWith("Notes"))?.click();
      return true;
    })()
  `);
  await waitFor(client, `Boolean(document.querySelector(".notes-layout"))`, "notes view");
  await evaluate(client, `
    (() => {
      if (!document.querySelector(".note-preview")) {
        document.querySelector(".notes-list-panel .note-row")?.click();
      }
      return true;
    })()
  `);
  await waitFor(client, `Boolean(document.querySelector(".note-preview .note-format-toolbar"))`, "notes editor toolbar");
  await evaluate(client, `
    (() => {
      const buttons = Array.from(document.querySelectorAll(".note-preview .note-format-toolbar button"));
      buttons.find((button) => button.textContent.trim() === "Preview")?.click();
      return true;
    })()
  `);
  await waitFor(client, `Boolean(document.querySelector(".note-preview .markdown-preview-surface"))`, "notes preview");
  captures.push(await capture(client, "openassist-notes-view.png"));

  await evaluate(client, `
    (() => {
      const buttons = Array.from(document.querySelectorAll("button"));
      buttons.find((button) => button.textContent.trim().startsWith("Threads"))?.click();
      return true;
    })()
  `);
  await waitFor(client, `Boolean(document.querySelector(".assistant-main"))`, "threads view");
  await evaluate(client, `document.querySelector('button[title="Open thread note"]')?.click()`);
  await waitFor(client, `Boolean(document.querySelector(".assistant-inspector .thread-note-editor .note-format-toolbar"))`, "thread note drawer");
  captures.push(await capture(client, "openassist-thread-note-drawer.png"));

  console.log(JSON.stringify({ ok: true, captures }, null, 2));
} finally {
  client?.close();
  if (!appExited) {
    app.kill("SIGTERM");
    await wait(1000);
    if (!appExited) app.kill("SIGKILL");
  }
}
