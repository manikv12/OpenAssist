import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const outputDirectory = path.join(process.cwd(), "verification", "native-reference");
const nativeCommandHint = process.env.OPENASSIST_NATIVE_COMMAND_HINT ?? "/Applications/Open Assist.app/Contents/MacOS/OpenAssist";

function openAssistWindows() {
  const source = `
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.compactMap { window -> String? in
  let owner = window[kCGWindowOwnerName as String] as? String ?? ""
  guard owner == "Open Assist" else { return nil }
  guard let number = window[kCGWindowNumber as String] as? Int,
        let pid = window[kCGWindowOwnerPID as String] as? Int,
        let layer = window[kCGWindowLayer as String] as? Int,
        let alpha = window[kCGWindowAlpha as String] as? Double,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double,
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double else { return nil }
  let title = window[kCGWindowName as String] as? String ?? ""
  return "{\\"number\\":\\(number),\\"pid\\":\\(pid),\\"owner\\":\\"\\(owner)\\",\\"title\\":\\"\\(title.replacingOccurrences(of: "\\\"", with: "\\\\\\\""))\\",\\"layer\\":\\(layer),\\"alpha\\":\\(alpha),\\"x\\":\\(x),\\"y\\":\\(y),\\"width\\":\\(width),\\"height\\":\\(height)}"
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

function processCommand(pid) {
  try {
    return execFileSync("/bin/ps", ["-p", String(pid), "-o", "command="], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).trim();
  } catch {
    return "";
  }
}

function captureWindow(window, outputPath) {
  try {
    execFileSync("/usr/sbin/screencapture", ["-x", "-l", String(window.number), outputPath], {
      stdio: ["ignore", "pipe", "pipe"]
    });
    return "window";
  } catch {
    const region = [
      Math.round(window.x),
      Math.round(window.y),
      Math.round(window.width),
      Math.round(window.height)
    ].join(",");
    execFileSync("/usr/sbin/screencapture", ["-x", "-R", region, outputPath], {
      stdio: ["ignore", "pipe", "pipe"]
    });
    return "region";
  }
}

fs.mkdirSync(outputDirectory, { recursive: true });

const allWindows = openAssistWindows().map((window) => ({
  ...window,
  command: processCommand(window.pid)
}));
const nativeWindows = allWindows.filter((window) => window.command.includes(nativeCommandHint));

if (!nativeWindows.length) {
  throw new Error(`No native Open Assist windows matched command hint: ${nativeCommandHint}`);
}

const captures = [];
for (const window of nativeWindows) {
  const outputPath = path.join(outputDirectory, `window-${window.number}.png`);
  let captureMethod = "failed";
  let error = "";
  try {
    captureMethod = captureWindow(window, outputPath);
  } catch (captureError) {
    error = captureError instanceof Error ? captureError.message : String(captureError);
  }
  captures.push({
    outputPath,
    captureMethod,
    error,
    window
  });
}

const metadataPath = path.join(outputDirectory, "metadata.json");
fs.writeFileSync(metadataPath, JSON.stringify({
  capturedAt: new Date().toISOString(),
  nativeCommandHint,
  captures,
  allOpenAssistWindows: allWindows
}, null, 2));

console.log(JSON.stringify({
  ok: true,
  outputDirectory,
  metadataPath,
  captures
}, null, 2));
