import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
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

const debugPort = process.env.OPENASSIST_ELECTRON_INSERTION_DEBUG_PORT ?? "8317";
const cdpEndpoint = `http://127.0.0.1:${debugPort}/json/list`;
const probe = `OpenAssist cursor insertion probe ${Date.now()}`;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function run(command, args, options = {}) {
  return execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...options });
}

function osascript(script) {
  return run("/usr/bin/osascript", ["-e", script]).trim();
}

function activateProcessWithAppKit(pid) {
  const source = `
import AppKit
import Foundation

let pid = pid_t(Int32(CommandLine.arguments.dropFirst().first ?? "") ?? 0)
if let app = NSRunningApplication(processIdentifier: pid) {
    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    Thread.sleep(forTimeInterval: 0.25)
}
print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
`;
  return Number(run("/usr/bin/swift", ["-", String(pid)], { input: source }).trim()) === pid;
}

async function waitForRenderer(timeout = 10000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      const targets = await fetch(cdpEndpoint).then((response) => response.json());
      const pageTargets = Array.isArray(targets) ? targets.filter((item) => item.type === "page") : [];
      const target = pageTargets.find((item) => !String(item.title ?? "").includes("Voice HUD") && !String(item.url ?? "").startsWith("data:text/html"))
        ?? pageTargets.find((item) => !String(item.title ?? "").includes("Voice HUD"))
        ?? pageTargets[0];
      if (target?.webSocketDebuggerUrl) return target.webSocketDebuggerUrl;
    } catch {
      // The packaged app has not opened its debug endpoint yet.
    }
    await wait(200);
  }
  throw new Error(`Timed out waiting for Electron renderer at ${cdpEndpoint}.`);
}

async function connectToRenderer(webSocketDebuggerUrl) {
  const socket = new WebSocket(webSocketDebuggerUrl);
  const pending = new Map();
  let requestID = 0;

  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id) return;
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    if (message.error) {
      entry.reject(new Error(message.error.message));
    } else {
      entry.resolve(message.result);
    }
  });

  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });

  const send = (method, params) => {
    const id = ++requestID;
    const promise = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    socket.send(JSON.stringify({ id, method, params }));
    return promise;
  };

  await send("Runtime.enable");

  return {
    evaluate: async (expression) => {
      const result = await send("Runtime.evaluate", {
        expression,
        awaitPromise: true,
        returnByValue: true,
        userGesture: true
      });
      if (result.exceptionDetails) {
        throw new Error(result.exceptionDetails.text ?? JSON.stringify(result.exceptionDetails));
      }
      return result.result?.value;
    },
    close: () => socket.close()
  };
}

function writeSmokeTargetSource(sourcePath) {
  fs.writeFileSync(sourcePath, `
import AppKit
import Foundation

final class SmokeDelegate: NSObject, NSApplicationDelegate {
    let outputPath: String
    var window: NSWindow!
    var textView: NSTextView!
    var timer: Timer?

    init(outputPath: String) {
        self.outputPath = outputPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenAssist Insertion Smoke Target"

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 520, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = ""
        scrollView.documentView = textView

        window.contentView?.addSubview(scrollView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.writeSnapshot()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            self?.writeSnapshot()
            NSApp.terminate(nil)
        }
    }

    func writeSnapshot() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        let text = textView?.string ?? ""
        let payload = ["text": text]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }
}

let outputPath = CommandLine.arguments.dropFirst().first ?? ""
let delegate = SmokeDelegate(outputPath: outputPath)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
`, "utf8");
}

async function waitForSmokeText(outputPath, expected, timeout = 9000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      const payload = JSON.parse(fs.readFileSync(outputPath, "utf8"));
      if (String(payload.text ?? "").includes(expected)) return payload.text;
    } catch {
      // The helper writes this after its text view is ready.
    }
    await wait(200);
  }
  try {
    const payload = JSON.parse(fs.readFileSync(outputPath, "utf8"));
    return String(payload.text ?? "");
  } catch {
    return "";
  }
}

async function focusSmokeTarget(pid, timeout = 5000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      osascript(`tell application "System Events" to set frontmost of first application process whose unix id is ${pid} to true`);
      const frontPid = osascript(`
tell application "System Events"
  set frontApp to first application process whose frontmost is true
  return unix id of frontApp as text
end tell
`);
      if (Number(frontPid) === pid) return true;
    } catch {
      try {
        if (activateProcessWithAppKit(pid)) return true;
      } catch {
        // Try again until the temporary target is frontmost.
      }
    }
    await wait(180);
  }
  return false;
}

assert(process.platform === "darwin", "Insertion smoke test is macOS-only.");
assert(fs.existsSync(appExecutable), `Packaged Open Assist app is missing: ${appExecutable}`);

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-insertion-smoke-"));
const sourcePath = path.join(tempRoot, "InsertionSmokeTarget.swift");
const binaryPath = path.join(tempRoot, "InsertionSmokeTarget");
const outputPath = path.join(tempRoot, "snapshot.json");
let appProcess;
let targetProcess;

try {
  writeSmokeTargetSource(sourcePath);
  run("/usr/bin/swiftc", [sourcePath, "-framework", "AppKit", "-o", binaryPath], { cwd: tempRoot });

  appProcess = spawn(appExecutable, [], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      OPENASSIST_ELECTRON_REMOTE_DEBUG: "1",
      OPENASSIST_ELECTRON_REMOTE_DEBUG_PORT: debugPort
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  appProcess.stderr.on("data", (chunk) => process.stderr.write(chunk));
  appProcess.stdout.on("data", (chunk) => process.stdout.write(chunk));

  const rendererSocket = await waitForRenderer();

  targetProcess = spawn(binaryPath, [outputPath], {
    cwd: tempRoot,
    stdio: ["ignore", "pipe", "pipe"]
  });
  targetProcess.stderr.on("data", (chunk) => process.stderr.write(chunk));

  await wait(1600);
  assert(await focusSmokeTarget(targetProcess.pid), "Could not focus insertion smoke target before connecting to renderer.");
  await wait(300);

  const client = await connectToRenderer(rendererSocket);
  assert(await focusSmokeTarget(targetProcess.pid), "Could not focus insertion smoke target before inserting text.");
  const insertion = await client.evaluate(`window.openAssistElectron.insertTranscriptText(${JSON.stringify(probe)})`);
  client.close();

  const insertedText = await waitForSmokeText(outputPath, probe);
  assert(insertedText.includes(probe), `Transcript was not inserted into the external text cursor. insertion=${JSON.stringify(insertion)} text=${JSON.stringify(insertedText)}`);
  assert(insertion?.ok, `Insertion bridge returned failure: ${JSON.stringify(insertion)}`);

  console.log(JSON.stringify({
    insertionSmoke: true,
    inserted: true,
    insertionResult: insertion.result,
    target: insertion.target?.name ?? null
  }));
} finally {
  if (targetProcess && !targetProcess.killed) targetProcess.kill("SIGTERM");
  if (appProcess && !appProcess.killed) appProcess.kill("SIGTERM");
  await wait(700);
  if (targetProcess && !targetProcess.killed) targetProcess.kill("SIGKILL");
  if (appProcess && !appProcess.killed) appProcess.kill("SIGKILL");
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
