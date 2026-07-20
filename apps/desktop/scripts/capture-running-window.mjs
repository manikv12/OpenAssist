import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const outputDirectory = path.join(process.cwd(), "verification");
const mode = process.env.OPENASSIST_CAPTURE_MODE === "smallest" ? "smallest" : "largest";
const outputPath = process.env.OPENASSIST_CAPTURE_PATH
  ? path.resolve(process.env.OPENASSIST_CAPTURE_PATH)
  : path.join(outputDirectory, `openassist-${mode}-window.png`);
const cdpEndpoint = process.env.OPENASSIST_ELECTRON_CDP ?? "http://127.0.0.1:8315/json/list";

async function captureWithCDP(filePath) {
  const targets = await fetch(cdpEndpoint).then((response) => response.json());
  const target = targets.find((item) => item.type === "page");
  if (!target?.webSocketDebuggerUrl) {
    throw new Error("No Electron renderer target was available for CDP screenshot fallback.");
  }
  const socket = new WebSocket(target.webSocketDebuggerUrl);
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
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    pending.set(++id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  await send("Page.enable");
  const result = await send("Page.captureScreenshot", { format: "png", fromSurface: true });
  socket.close();
  fs.writeFileSync(filePath, Buffer.from(result.data, "base64"));
}

function runningOpenAssistWindows() {
  const source = `
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.compactMap { window -> String? in
  let owner = window[kCGWindowOwnerName as String] as? String ?? ""
  let title = window[kCGWindowName as String] as? String ?? ""
  guard owner == "Open Assist" || owner == "Electron" else { return nil }
  guard title == "Open Assist" else { return nil }
  guard let number = window[kCGWindowNumber as String] as? Int,
        let pid = window[kCGWindowOwnerPID as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double,
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double else { return nil }
  return "{\\"number\\":\\(number),\\"pid\\":\\(pid),\\"owner\\":\\"\\(owner)\\",\\"title\\":\\"\\(title)\\",\\"x\\":\\(x),\\"y\\":\\(y),\\"width\\":\\(width),\\"height\\":\\(height)}"
}

print("[\\(candidates.joined(separator: ","))]")
`;
  const output = execFileSync("/usr/bin/swift", ["-"], {
    input: source,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "ignore"]
  }).trim();
  return JSON.parse(output || "[]");
}

const windows = runningOpenAssistWindows();
if (!windows.length) {
  throw new Error("No running Open Assist or Electron window named Open Assist was found.");
}

const selected = [...windows].sort((a, b) => {
  const areaA = a.width * a.height;
  const areaB = b.width * b.height;
  return mode === "smallest" ? areaA - areaB : areaB - areaA;
})[0];

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
let captureMethod = "window";
try {
  execFileSync("/usr/sbin/screencapture", ["-x", "-l", String(selected.number), outputPath], {
    stdio: ["ignore", "pipe", "pipe"]
  });
} catch {
  captureMethod = "region";
  const region = [
    Math.round(selected.x),
    Math.round(selected.y),
    Math.round(selected.width),
    Math.round(selected.height)
  ].join(",");
  try {
    execFileSync("/usr/sbin/screencapture", ["-x", "-R", region, outputPath], {
      stdio: ["ignore", "pipe", "pipe"]
    });
  } catch {
    captureMethod = "cdp";
    await captureWithCDP(outputPath);
  }
}

const metadataPath = outputPath.replace(/\.png$/i, ".json");
fs.writeFileSync(metadataPath, JSON.stringify({ mode, outputPath, captureMethod, selected, windows }, null, 2));
console.log(JSON.stringify({ ok: true, outputPath, metadataPath, captureMethod, selected }, null, 2));
