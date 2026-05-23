import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const endpoint = process.env.OPENASSIST_ELECTRON_CDP ?? "http://127.0.0.1:8315/json/list";
const expectedProviders = ["Codex", "Copilot", "Claude", "Antigravity", "Ollama"];
const forbiddenProviders = ["OpenAI", "Google AI Studio", "OpenRouter", "Groq", "Anthropic", "Grok"];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function connectToRenderer() {
  const targets = await fetch(endpoint).then((response) => response.json());
  const pageTargets = targets.filter((item) => item.type === "page");
  const target = pageTargets.find((item) => {
    const url = String(item.url ?? "");
    return url.includes("127.0.0.1:5187") && !url.includes("window=settings");
  })
    ?? pageTargets.find((item) => String(item.url ?? "").includes("127.0.0.1:5187"))
    ?? pageTargets.find((item) => !String(item.title ?? "").includes("Voice HUD") && !String(item.url ?? "").startsWith("data:text/html"))
    ?? pageTargets.find((item) => !String(item.title ?? "").includes("Voice HUD"))
    ?? pageTargets[0];
  assert(target?.webSocketDebuggerUrl, "Electron renderer target was not found.");

  const socket = new WebSocket(target.webSocketDebuggerUrl);
  const pending = new Map();
  let id = 0;

  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
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
    const requestID = ++id;
    pending.set(requestID, { resolve, reject });
    socket.send(JSON.stringify({ id: requestID, method, params }));
  });

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

function assertNoLocalChatStores() {
  const root = process.cwd();
  const disallowed = [];
  const visit = (directory, depth = 0) => {
    if (depth > 4 || !fs.existsSync(directory)) return;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (["node_modules", "out", "dist-renderer", "dist-electron", ".vite"].includes(entry.name)) continue;
      const fullPath = path.join(directory, entry.name);
      if (/chat|conversation|AssistantConversationStore/i.test(entry.name)) {
        disallowed.push(path.relative(root, fullPath));
      }
      if (/charts?/i.test(entry.name)) {
        disallowed.push(path.relative(root, fullPath));
      }
      visit(fullPath, depth + 1);
    }
  };
  visit(root);
  assert(disallowed.length === 0, `Chat/conversation/chart stores must not be created inside electron-react: ${disallowed.join(", ")}`);
}

function assertProviderMarkAssets() {
  const assetsRoot = path.join(process.cwd(), "src", "assets", "provider-marks");
  const expectedAssets = {
    codex: "codex.svg",
    copilot: "copilot.svg",
    claude: "claude.svg",
    antigravity: "antigravity.png",
    ollama: "ollama.svg"
  };
  for (const [name, fileName] of Object.entries(expectedAssets)) {
    const filePath = path.join(assetsRoot, fileName);
    assert(fs.existsSync(filePath), `Missing provider mark asset: ${filePath}`);
    assert(fs.statSync(filePath).size > 100, `Provider mark asset is empty: ${filePath}`);
  }
}

function providerKeychainAccount(providerKey, provider) {
  if (providerKey === "promptRewriteProvider" && provider === "Google AI Studio (Gemini)") {
    return "google-api-key";
  }
  if (providerKey === "cloudTranscriptionProvider" && provider === "Google Gemini (AI Studio)") {
    return "google-api-key";
  }
  const prefix = providerKey === "cloudTranscriptionProvider"
    ? "cloud-transcription-provider-api-key"
    : "prompt-rewrite-provider-api-key";
  const normalized = provider.toLowerCase()
    .replace(/[()]/g, "")
    .replace(/\//g, "-")
    .replace(/ /g, "-");
  return `${prefix}.${normalized}`;
}

function hasProviderKeychainAccount(providerKey, provider) {
  try {
    execFileSync("security", [
      "find-generic-password",
      "-s",
      "com.developingadventures.OpenAssist",
      "-a",
      providerKeychainAccount(providerKey, provider)
    ], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function macWindowBounds(titleMatch = "Open Assist") {
  if (process.platform !== "darwin") return null;
  const source = `
import CoreGraphics
import Foundation

let titleMatch = ${JSON.stringify(titleMatch)}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.compactMap { window -> String? in
  let owner = window[kCGWindowOwnerName as String] as? String ?? ""
  let title = window[kCGWindowName as String] as? String ?? ""
  guard owner == "Electron" || owner == "Open Assist" else { return nil }
  guard title == titleMatch else { return nil }
  guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double,
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double else { return nil }
  return "{\\"owner\\":\\"\\(owner)\\",\\"title\\":\\"\\(title)\\",\\"x\\":\\(x),\\"y\\":\\(y),\\"width\\":\\(width),\\"height\\":\\(height)}"
}

print("[\\(candidates.joined(separator: ","))]")
`;
  const output = execFileSync("/usr/bin/swift", ["-"], {
    input: source,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "ignore"]
  }).trim();
  const windows = JSON.parse(output || "[]");
  return windows.sort((a, b) => (a.width * a.height) - (b.width * b.height))[0] ?? null;
}

function macMenuBarItems() {
  if (process.platform !== "darwin") return null;
  try {
    const output = execFileSync("/usr/bin/osascript", [
      "-e",
      'tell application "System Events" to tell process "Open Assist" to get name of every menu bar item of menu bar 1'
    ], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).trim();
    return output.split(",").map((item) => item.trim()).filter(Boolean);
  } catch {
    return null;
  }
}

function macViewMenuItems() {
  if (process.platform !== "darwin") return null;
  try {
    const output = execFileSync("/usr/bin/osascript", [
      "-e",
      'tell application "System Events" to tell process "Open Assist" to get name of every menu item of menu "View" of menu bar item "View" of menu bar 1'
    ], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).trim();
    return output.split(",").map((item) => item.trim()).filter(Boolean);
  } catch {
    return null;
  }
}

const client = await connectToRenderer();
try {
  const result = await client.evaluate(`(async () => {
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const waitFor = async (predicate, label, timeout = 7000) => {
      const started = Date.now();
      while (Date.now() - started < timeout) {
        const value = predicate();
        if (value) return value;
        await sleep(60);
      }
      throw new Error("Timed out waiting for " + label);
    };
    const byLabel = (label) => Array.from(document.querySelectorAll("button"))
      .find((button) => button.getAttribute("aria-label") === label || button.title === label || button.textContent.trim() === label);
    window.sessionStorage.setItem("openassist.verifyInlineSettings", "1");
    const setNativeInputValue = (input, value) => {
      if (!input) return;
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
      if (setter) setter.call(input, value);
      else input.value = value;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    };

    if (document.querySelector(".app-shell")?.className.includes("sidebar-collapsed")) {
      byLabel("Open sidebar assistant")?.click();
      await waitFor(
        () => !document.querySelector(".app-shell")?.className.includes("sidebar-collapsed"),
        "expanded sidebar",
        1600
      );
    }
    if (!document.querySelector(".assistant-main")) {
      const openAssistantButton = Array.from(document.querySelectorAll("button"))
        .find((button) => button.textContent.trim() === "Open Assistant");
      const threadsButton = Array.from(document.querySelectorAll("button"))
        .find((button) => button.textContent.trim() === "Threads");
      (openAssistantButton ?? threadsButton)?.click();
      await waitFor(() => document.querySelector(".assistant-main"), "initial threads view", 5000);
    }
    const assistantSidebarUpdateHidden = !document.querySelector(".app-sidebar .status-card");

    const clickButtonText = (label) => Array.from(document.querySelectorAll("button"))
      .find((button) => button.textContent.trim() === label);
    const clickSidebarBottomButton = (label) => {
      const button = Array.from(document.querySelectorAll(".sidebar-bottom button"))
        .find((item) => item.textContent.trim().startsWith(label));
      if (!button) return false;
      button.click();
      return true;
    };
    const openSettingsView = async (label = "settings navigation") => {
      if (document.querySelector(".settings-window")) return;
      if (!clickSidebarBottomButton("Settings")) clickButtonText("Settings")?.click();
      await waitFor(() => document.querySelector(".settings-window"), label, 15000);
    };
    const openAssistantView = async (label = "threads view") => {
      clickButtonText("Open Assistant")?.click();
      await waitFor(() => document.querySelector(".assistant-main"), label, 8000);
    };
    const checkSidebarNavigation = async (label, selector, verifier = () => true) => {
      clickButtonText(label)?.click();
      await waitFor(() => document.querySelector(selector), label + " surface");
      return {
        label,
        worked: Boolean(document.querySelector(selector)) && verifier()
      };
    };
    const sidebarNavigationChecks = [
      await checkSidebarNavigation("Notes", ".notes-layout", () => document.querySelector(".notes-list-panel .subhead-row strong")?.textContent.trim() === "Notes"),
      await checkSidebarNavigation("Automations", ".split-feature-main", () => document.querySelector(".split-feature-main h1")?.textContent.trim() === "Automations"),
      await checkSidebarNavigation("Skills", ".catalog-main", () => document.querySelector(".catalog-main h1")?.textContent.trim() === "Skills"),
      await checkSidebarNavigation("Plugins", ".plugins-main", () => Array.from(document.querySelectorAll(".plugins-main h1")).some((node) => node.textContent.trim() === "Plugins")),
      await checkSidebarNavigation("Threads", ".assistant-main", () => Boolean(document.querySelector(".composer-input")))
    ];
    const findArchivedNavButton = () => Array.from(document.querySelectorAll(".sidebar-bottom button"))
      .find((button) => button.textContent.trim().startsWith("Archived"));
    const archivedNavButton = await waitFor(findArchivedNavButton, "archived sidebar button");
    archivedNavButton.click();
    await waitFor(() => document.querySelector(".threads-heading span")?.textContent.trim() === "Archived", "archived sidebar navigation");
    sidebarNavigationChecks.push({
      label: "Archived",
      worked: document.querySelector(".threads-heading span")?.textContent.trim() === "Archived"
    });
    const restoredThreadsButton = await waitFor(findArchivedNavButton, "archived sidebar restore button");
    restoredThreadsButton.click();
    try {
      await waitFor(() => document.querySelector(".threads-heading span")?.textContent.trim() === "Threads", "threads sidebar navigation restored", 2500);
    } catch {
      clickButtonText("Threads")?.click();
      await waitFor(() => document.querySelector(".threads-heading span")?.textContent.trim() === "Threads", "threads sidebar navigation restored");
    }
    await openSettingsView();
    const settingsUpdateCardScoped = Boolean(document.querySelector(".settings-window .settings-sidebar .settings-update"))
      && !Boolean(document.querySelector(".assistant-main .settings-update"));
    const assistantHistoryNavHidden = !Array.from(document.querySelectorAll(".nav-block .nav-item"))
      .some((button) => button.textContent.trim() === "History");
    sidebarNavigationChecks.push({
      label: "Settings",
      worked: Boolean(document.querySelector(".settings-window")) && document.querySelector(".settings-content h1")?.textContent.trim() === "Assistant"
    });
    await openAssistantView("threads view after sidebar navigation");

    await waitFor(() => document.querySelectorAll(".project-row").length > 0, "bridge-loaded project rows", 20000);
    const projectRows = Array.from(document.querySelectorAll(".project-row"));
    const projectTarget = projectRows.find((row) => !row.className.includes("expanded")) ?? projectRows[0];
    const selectedProjectName = projectTarget?.querySelector("strong")?.textContent?.trim() ?? "";
    if (projectTarget) {
      projectTarget.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 180, clientY: 180, button: 2 }));
      await waitFor(() => document.querySelector(".sidebar-context-menu"), "project context menu");
    }
    const projectContextText = document.querySelector(".sidebar-context-menu")?.textContent ?? "";
    const projectContextMenuWorked = [
      "Project Notes",
      "View Memory",
      "Rename Project",
      "Change Icon",
      "Move to Group",
      "Hide Project",
      "Delete Project"
    ].every((label) => projectContextText.includes(label));
    document.querySelector(".sidebar-context-scrim")?.click();
    await sleep(80);
    if (projectTarget) {
      projectTarget.click();
      await sleep(350);
    }
    const threadProjectLabels = Array.from(document.querySelectorAll(".thread-row:not(.show-more-row) small"))
      .map((node) => node.textContent.trim())
      .filter(Boolean);
    const projectFilterWorked = Boolean(selectedProjectName)
      && threadProjectLabels.length > 0
      && threadProjectLabels.every((label) => label === selectedProjectName);
    if (!document.querySelector(".project-create-panel")) {
      byLabel("Create group or project")?.click();
    }
    await sleep(160);
    const projectCreatePanelWorked = Boolean(document.querySelector(".project-create-panel"));
    const temporaryThreadButtonWorked = Boolean(byLabel("New temporary chat"));
    const firstThreadRow = document.querySelector(".thread-row:not(.show-more-row)");
    if (firstThreadRow) {
      firstThreadRow.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 220, clientY: 520, button: 2 }));
      await waitFor(() => document.querySelector(".sidebar-context-menu"), "thread context menu");
    }
    const threadContextText = document.querySelector(".sidebar-context-menu")?.textContent ?? "";
    const threadContextMenuWorked = Boolean(firstThreadRow)
      && ["Rename Session", "Move to Project", "Archive Session"].every((label) => threadContextText.includes(label));
    document.querySelector(".sidebar-context-scrim")?.click();
    await sleep(80);
    const activeProjectRowCount = document.querySelectorAll(".project-row.expanded").length;
    const activeThreadRowCount = document.querySelectorAll(".thread-row.active:not(.show-more-row)").length;
    const activeThreadShadow = getComputedStyle(document.querySelector(".thread-row.active") ?? document.body).boxShadow;
    const activeNavShadow = getComputedStyle(document.querySelector(".nav-item.active") ?? document.body).boxShadow;
    const sidebarSingleSelectionWorked = activeProjectRowCount <= 1
      && activeThreadRowCount <= 1
      && !activeThreadShadow.includes("2px 0px")
      && !activeNavShadow.includes("2px 0px")
      && !activeNavShadow.includes("3px 0px");
    const tempThread = await window.openAssistElectron.createThread(undefined, true);
    const tempStateBeforeDestroy = await window.openAssistElectron.loadAppState();
    const tempDestroyed = await window.openAssistElectron.destroyTemporaryThread(tempThread.thread.id);
    const tempStateAfterDestroy = await window.openAssistElectron.loadAppState();
    const temporaryThreadLifecycle = {
      threadID: tempThread.thread.id,
      isTemporary: Boolean(tempThread.thread.isTemporary),
      messageCount: tempThread.detail.messages.length,
      visibleBeforeDestroy: tempStateBeforeDestroy.threads.some((thread) => thread.id === tempThread.thread.id),
      destroyOk: Boolean(tempDestroyed?.ok),
      visibleAfterDestroy: tempStateAfterDestroy.threads.some((thread) => thread.id === tempThread.thread.id)
    };
    const temporaryThreadLifecycleWorked = Boolean(
      temporaryThreadLifecycle.isTemporary
      && temporaryThreadLifecycle.messageCount === 0
      && !temporaryThreadLifecycle.visibleBeforeDestroy
      && temporaryThreadLifecycle.destroyOk
      && !temporaryThreadLifecycle.visibleAfterDestroy
    );
    const codeTrackingBridgeProbe = {
      hasLoad: typeof window.openAssistElectron.loadCodeTrackingState === "function",
      hasOpenReview: typeof window.openAssistElectron.openCodeReview === "function",
      hasRestore: typeof window.openAssistElectron.restoreCodeCheckpoint === "function",
      noProjectState: null
    };
    if (codeTrackingBridgeProbe.hasLoad) {
      codeTrackingBridgeProbe.noProjectState = await window.openAssistElectron.loadCodeTrackingState(tempThread.thread.id);
    }
    const codexRuntimeParityProbe = window.openAssistElectron.codexRuntimeParityProbe
      ? await window.openAssistElectron.codexRuntimeParityProbe({
        prompt: "Can you check X notifications in the browser?",
        cwd: "/tmp/openassist-electron-runtime-probe",
        pluginIDs: ["computer-use@openai-bundled"],
        sessionInstructions: "Use simple English.",
        reasoningEffort: "High",
        interactionMode: "Agentic",
        permissionMode: "fullAccess",
        modelID: "gpt-5.4"
      })
      : { skipped: true };
    const codexDefaultPermissionProbe = window.openAssistElectron.codexRuntimeParityProbe
      ? await window.openAssistElectron.codexRuntimeParityProbe({
        prompt: "Check default permissions.",
        cwd: "/tmp/openassist-electron-runtime-probe",
        reasoningEffort: "High",
        interactionMode: "Agentic",
        permissionMode: "default",
        modelID: "gpt-5.4"
      })
      : { skipped: true };
    const codexAutoReviewPermissionProbe = window.openAssistElectron.codexRuntimeParityProbe
      ? await window.openAssistElectron.codexRuntimeParityProbe({
        prompt: "Check auto-review permissions.",
        cwd: "/tmp/openassist-electron-runtime-probe",
        reasoningEffort: "High",
        interactionMode: "Agentic",
        permissionMode: "autoReview",
        modelID: "gpt-5.4"
      })
      : { skipped: true };
    const codexCustomPermissionProbe = window.openAssistElectron.codexRuntimeParityProbe
      ? await window.openAssistElectron.codexRuntimeParityProbe({
        prompt: "Check custom permissions.",
        cwd: "/tmp/openassist-electron-runtime-probe",
        reasoningEffort: "High",
        interactionMode: "Agentic",
        permissionMode: "custom",
        modelID: "gpt-5.4"
      })
      : { skipped: true };
    const codexNoProjectRuntimeProbe = window.openAssistElectron.codexRuntimeParityProbe
      ? await window.openAssistElectron.codexRuntimeParityProbe({
        prompt: "Start a new no-project chat.",
        pluginIDs: ["computer-use@openai-bundled"],
        reasoningEffort: "High",
        interactionMode: "Agentic",
        permissionMode: "default",
        modelID: "gpt-5.4"
      })
      : { skipped: true };
    const runtimeProbeTextItems = [
      ...(codexRuntimeParityProbe.pluginItems ?? []),
      ...((codexRuntimeParityProbe.turnStart?.input ?? []))
    ]
      .filter((item) => item?.type === "text")
      .map((item) => String(item.text ?? ""));
    const forbiddenRuntimeHints = runtimeProbeTextItems.filter((text) =>
      /Chrome may not expose|For Computer Use|Brave Browser|Google Chrome|Safari/.test(text)
    );
    const runtimeProbeMentionPaths = [
      ...(codexRuntimeParityProbe.pluginItems ?? []),
      ...((codexRuntimeParityProbe.turnStart?.input ?? []))
    ]
      .filter((item) => item?.type === "mention")
      .map((item) => String(item.path ?? ""));
    const mcpApprovalLabels = (probe) => (probe?.approvalOptions ?? []).map((option) => option.label);
    const mcpApprovalActions = (probe) => (probe?.approvalOptions ?? []).map((option) => option.result?.action);
    const mcpApprovalShapeWorked = [codexRuntimeParityProbe.approvalProbes?.mcpServerRequest, codexRuntimeParityProbe.approvalProbes?.elicitationCreate]
      .every((probe) =>
        probe?.approvalKind === "mcpElicitation"
        && JSON.stringify(mcpApprovalLabels(probe)) === JSON.stringify(["Allow", "Decline", "Cancel"])
        && JSON.stringify(mcpApprovalActions(probe)) === JSON.stringify(["accept", "decline", "cancel"])
      );
    const codexRuntimeParityWorked = Boolean(
      !codexRuntimeParityProbe.skipped
      && codexRuntimeParityProbe.threadStart?.approvalPolicy === "never"
      && codexRuntimeParityProbe.threadStart?.sandbox === "danger-full-access"
      && !("permissions" in (codexRuntimeParityProbe.threadStart ?? {}))
      && codexRuntimeParityProbe.threadStart?.cwd === "/tmp/openassist-electron-runtime-probe"
      && Array.isArray(codexRuntimeParityProbe.threadStart?.dynamicTools)
      && String(codexRuntimeParityProbe.threadStart?.developerInstructions ?? "").includes("# Workspace Boundary")
      && !("instructions" in (codexRuntimeParityProbe.threadStart ?? {}))
      && codexRuntimeParityProbe.turnStart?.collaborationMode?.mode === "default"
      && codexRuntimeParityProbe.turnStart?.collaborationMode?.settings?.reasoningEffort === "high"
      && codexRuntimeParityProbe.turnStart?.approvalPolicy === "never"
      && codexRuntimeParityProbe.turnStart?.sandboxPolicy?.type === "dangerFullAccess"
      && !("permissions" in (codexRuntimeParityProbe.turnStart ?? {}))
      && codexRuntimeParityProbe.turnStart?.effort === "high"
      && codexRuntimeParityProbe.turnStart?.input?.at(-1)?.text === "Can you check X notifications in the browser?"
      && codexRuntimeParityProbe.desktopToolSuppression?.filtered?.includes("exec_command")
      && !codexRuntimeParityProbe.desktopToolSuppression?.filtered?.includes("app_action")
      && !codexRuntimeParityProbe.desktopToolSuppression?.filtered?.includes("computer_use")
      && codexDefaultPermissionProbe.threadStart?.approvalPolicy === "on-request"
      && codexDefaultPermissionProbe.threadStart?.approvalsReviewer === "user"
      && codexDefaultPermissionProbe.threadStart?.permissions?.id === ":workspace"
      && codexAutoReviewPermissionProbe.threadStart?.approvalPolicy === "on-request"
      && codexAutoReviewPermissionProbe.threadStart?.approvalsReviewer === "auto_review"
      && codexAutoReviewPermissionProbe.threadStart?.permissions?.id === ":workspace"
      && !("approvalPolicy" in (codexCustomPermissionProbe.threadStart ?? {}))
      && !("approvalsReviewer" in (codexCustomPermissionProbe.threadStart ?? {}))
      && !("permissions" in (codexCustomPermissionProbe.threadStart ?? {}))
      && !("cwd" in (codexNoProjectRuntimeProbe.threadStart ?? {}))
      && forbiddenRuntimeHints.length === 0
      && runtimeProbeMentionPaths.includes("plugin://computer-use@openai-bundled")
      && mcpApprovalShapeWorked
    );

	    const hideProjectProbe = { skipped: true };
	    if (window.openAssistElectron.hideProject && window.openAssistElectron.unhideProject) {
	      const probeProject = await window.openAssistElectron.createProject("Electron Hide Verify " + Date.now(), "project");
	      const stateWithProject = await window.openAssistElectron.loadAppState();
      await window.openAssistElectron.hideProject(probeProject.id);
      const hiddenState = await window.openAssistElectron.loadAppState();
      const restoredProject = await window.openAssistElectron.unhideProject(probeProject.id);
      const restoredState = await window.openAssistElectron.loadAppState();
      await window.openAssistElectron.deleteProject(probeProject.id);
      hideProjectProbe.skipped = false;
      hideProjectProbe.createdVisible = stateWithProject.projects.some((project) => project.id === probeProject.id);
      hideProjectProbe.hiddenFromProjects = !hiddenState.projects.some((project) => project.id === probeProject.id);
      hideProjectProbe.listedAsHidden = hiddenState.hiddenProjects.some((project) => project.id === probeProject.id);
	      hideProjectProbe.unhideReturned = restoredProject?.id === probeProject.id;
	      hideProjectProbe.restoredVisible = restoredState.projects.some((project) => project.id === probeProject.id);
	    }

	    const hiddenProjectContextMenuProbe = { skipped: true };
	    const originalConfirmForHiddenMenu = window.confirm;
	    try {
	      const probeName = "Electron Hidden Menu Verify " + Date.now();
	      hiddenProjectContextMenuProbe.skipped = false;
	      window.confirm = () => true;
	      if (!document.querySelector(".project-create-panel")) {
	        byLabel("Create group or project")?.click();
	      }
	      await waitFor(() => document.querySelector(".project-create-panel"), "project create panel for hidden menu");
	      setNativeInputValue(document.querySelector(".project-create-panel input"), probeName);
	      Array.from(document.querySelectorAll(".project-create-actions button"))
	        .find((button) => button.textContent.trim() === "Create")
	        ?.click();
	      const projectRowForName = () => Array.from(document.querySelectorAll(".project-row"))
	        .find((row) => row.querySelector("strong")?.textContent?.trim() === probeName);
	      const createdProjectRow = await waitFor(projectRowForName, "created project row for hidden menu");
	      createdProjectRow.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 220, clientY: 420, button: 2 }));
	      await waitFor(() => document.querySelector(".sidebar-context-menu"), "created project context menu");
	      const hideButton = Array.from(document.querySelectorAll(".sidebar-context-item"))
	        .find((button) => button.textContent.includes("Hide Project"));
	      hideButton?.click();
	      await waitFor(() => !projectRowForName(), "project hidden through UI");

	      const projectsHeading = Array.from(document.querySelectorAll(".sidebar-section-heading"))
	        .find((heading) => heading.textContent.includes("Projects"));
	      projectsHeading?.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 90, clientY: 365, button: 2 }));
	      await waitFor(() => document.querySelector(".sidebar-context-menu"), "projects heading context menu");
	      const projectsContextText = document.querySelector(".sidebar-context-menu")?.textContent ?? "";
	      const unhideWrap = Array.from(document.querySelectorAll(".sidebar-context-item-wrap"))
	        .find((wrap) => wrap.textContent.includes("Unhide Project or Group"));
	      unhideWrap?.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, cancelable: true }));
	      unhideWrap?.querySelector(".sidebar-context-item")?.click();
	      const unhideButton = await waitFor(() => Array.from(document.querySelectorAll(".sidebar-context-submenu .sidebar-context-item"))
	        .find((button) => button.textContent.includes(probeName)), "hidden project in heading submenu");
	      unhideButton.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, cancelable: true }));
	      await sleep(80);
	      await waitFor(() => Array.from(document.querySelectorAll(".sidebar-context-submenu .sidebar-context-item"))
	        .some((button) => button.textContent.includes(probeName)), "hidden project submenu remains open while hovering child");
	      unhideButton.click();
	      const restoredProjectRow = await waitFor(projectRowForName, "project restored from heading submenu");

	      restoredProjectRow.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 220, clientY: 420, button: 2 }));
	      await waitFor(() => document.querySelector(".sidebar-context-menu"), "restored project context menu");
	      Array.from(document.querySelectorAll(".sidebar-context-item"))
	        .find((button) => button.textContent.includes("Delete Project"))
	        ?.click();
	      await waitFor(() => !projectRowForName(), "hidden menu project cleanup");
	      window.confirm = originalConfirmForHiddenMenu;
	      hiddenProjectContextMenuProbe.projectsContextText = projectsContextText;
	      hiddenProjectContextMenuProbe.hadUnhideSubmenu = projectsContextText.includes("Unhide Project or Group");
	      hiddenProjectContextMenuProbe.restoredVisible = Boolean(restoredProjectRow);
	      hiddenProjectContextMenuProbe.cleanedUp = !projectRowForName();
	    } catch (error) {
	      window.confirm = originalConfirmForHiddenMenu;
	      hiddenProjectContextMenuProbe.error = String(error?.message ?? error);
	    }

		    const archivedButton = await waitFor(findArchivedNavButton, "archived sidebar toggle button");
	    archivedButton.click();
	    await waitFor(() => document.querySelector(".threads-heading span")?.textContent?.trim() === "Archived", "archived toggle heading");
	    const archivedHeading = document.querySelector(".threads-heading span")?.textContent?.trim() ?? "";
	    const archivedToggleWorked = archivedHeading === "Archived";
	    const archivedRestoreButton = await waitFor(findArchivedNavButton, "archived sidebar toggle restore button");
	    archivedRestoreButton.click();
	    await waitFor(() => document.querySelector(".threads-heading span")?.textContent?.trim() === "Threads", "archived toggle heading restored");

	    await openSettingsView("settings view");
	    await waitFor(() => document.querySelector(".settings-content"), "settings content");
    const settingsSearchInput = document.querySelector(".settings-search input");
    setNativeInputValue(settingsSearchInput, "");
    const openSettingsSection = async (label) => {
      if (!document.querySelector(".settings-window")) {
        await openSettingsView("settings view before " + label);
      }
      setNativeInputValue(document.querySelector(".settings-search input"), "");
      let button = Array.from(document.querySelectorAll(".settings-nav button"))
        .find((candidate) => candidate.textContent.trim() === label);
      if (!button) {
        await sleep(120);
        button = Array.from(document.querySelectorAll(".settings-nav button"))
          .find((candidate) => candidate.textContent.trim() === label);
      }
      if (!button) {
        const navLabels = Array.from(document.querySelectorAll(".settings-nav button")).map((candidate) => candidate.textContent.trim());
        throw new Error("Missing " + label + " settings button. Available: " + JSON.stringify(navLabels) + ". Search: " + (document.querySelector(".settings-search input")?.value ?? "") + ". Main: " + (document.querySelector("main")?.className ?? ""));
      }
      button.scrollIntoView({ block: "nearest" });
      button.click();
      await waitFor(() => document.querySelector(".settings-content h1")?.textContent.trim() === label, label + " settings section");
    };
    const settingsNavigationLabels = [
      "Assistant",
      "Voice & Dictation",
      "Models & Connections",
      "Automation & Remote",
      "App & Permissions"
    ];
    const settingsNavigationChecks = [];
    for (const label of settingsNavigationLabels) {
      await openSettingsSection(label);
      settingsNavigationChecks.push({
        label,
        worked: document.querySelector(".settings-content h1")?.textContent.trim() === label,
        navLabels: Array.from(document.querySelectorAll(".settings-nav button")).map((button) => button.textContent.trim()),
        searchValue: document.querySelector(".settings-search input")?.value ?? "",
        bodyClass: document.body.className,
        mainClass: document.querySelector("main")?.className ?? ""
      });
    }
    await openSettingsSection("Assistant");
    const styleButtons = Array.from(document.querySelectorAll(".segmented button"));
    const orbStyle = styleButtons.find((button) => button.textContent.trim() === "Orb");
    const notchStyle = styleButtons.find((button) => button.textContent.trim() === "Notch");
    const sidebarStyle = styleButtons.find((button) => button.textContent.trim() === "Sidebar");
    const compactStyleGuardWorked = Boolean(orbStyle?.disabled && notchStyle?.disabled && sidebarStyle && !sidebarStyle.disabled);
    const compactToggleClickable = Boolean(
      sidebarStyle
      && Array.from(document.querySelectorAll(".field-label span")).some((node) => node.textContent.trim() === "Sidebar edge")
    );
    const codeTrackingClickable = Boolean(Array.from(document.querySelectorAll(".checkbox-button"))
      .find((button) => button.getAttribute("aria-label") === "Track code changes in Git repositories" || button.textContent.includes("Track code changes in Git repositories")));
    const settingRoundTripState = await window.openAssistElectron.loadAppState();
    const waitForSetting = async (key, expected, timeout = 1800) => {
      const started = Date.now();
      while (Date.now() - started < timeout) {
        const state = await window.openAssistElectron.loadAppState();
        if (state.settings[key] === expected) return true;
        await sleep(120);
      }
      return false;
    };
    const applySettingAndConfirm = async (key, expected) => {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const nextSettings = await window.openAssistElectron.updateSetting(key, expected);
        if (nextSettings?.[key] === expected) return true;
        if (await waitForSetting(key, expected)) return true;
        await sleep(160);
      }
      return false;
    };
    const roundTripBooleanSetting = async (key, original) => {
      const changed = await applySettingAndConfirm(key, !original);
      const restored = await applySettingAndConfirm(key, original);
      return {
        key,
        changed,
        restored
      };
    };
    const roundTripStringSetting = async (key, original, probe, alternateProbe = probe) => {
      const nextValue = original === probe ? alternateProbe : probe;
      const changed = await applySettingAndConfirm(key, nextValue);
      const restored = await applySettingAndConfirm(key, original);
      return {
        key,
        changed,
        restored
      };
    };
    const waitForShortcutSetting = async (keyCode, modifiers, timeout = 1800) => {
      const started = Date.now();
      while (Date.now() - started < timeout) {
        const state = await window.openAssistElectron.loadAppState();
        if (
          state.settings.holdToTalkShortcutKeyCode === keyCode
          && state.settings.holdToTalkShortcutModifiers === modifiers
        ) {
          return true;
        }
        await sleep(120);
      }
      return false;
    };
    const providerKeyProbe = async ({ providerKey, targetProvider, saveMethod, clearMethod, statusKey }) => {
      const originalProvider = (await window.openAssistElectron.loadAppState()).settings[providerKey];
      const providerChanged = await applySettingAndConfirm(providerKey, targetProvider);
      const probeState = await window.openAssistElectron.loadAppState();
      const wasConfigured = Boolean(probeState.settings[statusKey]);
      const waitForProviderKeyStatus = async (expected, timeout = 2400) => {
        const started = Date.now();
        while (Date.now() - started < timeout) {
          const current = await window.openAssistElectron.loadAppState();
          if (Boolean(current.settings[statusKey]) === expected) return true;
          await sleep(120);
        }
        return false;
      };
      let saved = true;
      let cleared = true;
      if (!wasConfigured) {
        const savedSettings = await window.openAssistElectron[saveMethod](targetProvider, "electron-react-temporary-test-key");
        saved = Boolean(savedSettings?.[statusKey]) || await waitForProviderKeyStatus(true);
        const clearedSettings = await window.openAssistElectron[clearMethod](targetProvider);
        cleared = !Boolean(clearedSettings?.[statusKey]) || await waitForProviderKeyStatus(false, 5000);
      }
      const restoredProvider = await applySettingAndConfirm(providerKey, originalProvider);
      return {
        providerKey,
        targetProvider,
        providerChanged,
        wasConfigured,
        saved,
        cleared,
        restoredProvider
      };
    };
    const settingsRoundTrips = [
      await roundTripBooleanSetting("assistantFloatingHUDEnabled", settingRoundTripState.settings.assistantFloatingHUDEnabled),
      await roundTripBooleanSetting("assistantVoiceOutputEnabled", settingRoundTripState.settings.assistantVoiceOutputEnabled),
      await roundTripBooleanSetting("assistantTrackCodeChangesInGitRepos", settingRoundTripState.settings.assistantTrackCodeChangesInGitRepos),
      await roundTripStringSetting("promptRewriteProvider", settingRoundTripState.settings.promptRewriteProvider, "Ollama (Local)", "OpenAI"),
      await roundTripStringSetting("promptRewriteModel", settingRoundTripState.settings.promptRewriteModel, "electron-react-verify-model"),
      await roundTripStringSetting("promptRewriteBaseURL", settingRoundTripState.settings.promptRewriteBaseURL, "http://127.0.0.1:11434/v1"),
      await roundTripStringSetting("cloudTranscriptionProvider", settingRoundTripState.settings.cloudTranscriptionProvider, "ChatGPT / Codex Session", "OpenAI"),
      await roundTripStringSetting("cloudTranscriptionModel", settingRoundTripState.settings.cloudTranscriptionModel, "electron-react-transcribe-verify"),
      await roundTripStringSetting("cloudTranscriptionBaseURL", settingRoundTripState.settings.cloudTranscriptionBaseURL, "https://127.0.0.1/transcribe"),
      await roundTripStringSetting("voiceEngine", settingRoundTripState.settings.voiceEngine, "macos", "humeOctave"),
      await roundTripStringSetting("whisperModel", settingRoundTripState.settings.whisperModel, "tiny.en", "base.en"),
      await roundTripBooleanSetting("whisperUseCoreML", settingRoundTripState.settings.whisperUseCoreML),
      await roundTripStringSetting("transcriptionEngine", settingRoundTripState.settings.transcriptionEngine, "Apple Speech", "Cloud Providers"),
      await roundTripStringSetting("colorTheme", settingRoundTripState.settings.colorTheme, "Noir Gold", "Ocean"),
      await roundTripStringSetting("appChromeStyle", settingRoundTripState.settings.appChromeStyle, "Classic", "Glass (High Contrast)"),
      await roundTripStringSetting("waveformTheme", settingRoundTripState.settings.waveformTheme, "Monochrome", "Vibrant Spectrum")
    ];
    await openSettingsSection("App & Permissions");
    const appearanceOriginalState = await window.openAssistElectron.loadAppState();
    const originalColorTheme = appearanceOriginalState.settings.colorTheme;
    const originalWaveformTheme = appearanceOriginalState.settings.waveformTheme;
    const targetColorTheme = originalColorTheme === "Forest" ? "Ocean" : "Forest";
    const targetWaveformTheme = originalWaveformTheme === "Monochrome" ? "Vibrant Spectrum" : "Monochrome";
    let colorSwatchWorked = false;
    let waveformThemePreviewWorked = false;
    try {
      const swatchButton = Array.from(document.querySelectorAll(".theme-swatch-grid button"))
        .find((button) => button.textContent.includes(targetColorTheme));
      swatchButton?.click();
      colorSwatchWorked = Boolean(await waitFor(() =>
        document.querySelector(".app-shell")?.classList.contains("theme-" + targetColorTheme.toLowerCase().replace(/[^a-z0-9]+/g, "-")),
        "color theme swatch",
        3000
      ));
      const waveformField = Array.from(document.querySelectorAll(".field-label"))
        .find((label) => label.textContent.includes("Waveform Theme"));
      const waveformSelect = waveformField?.querySelector("select");
      if (waveformSelect) {
        waveformSelect.value = targetWaveformTheme;
        waveformSelect.dispatchEvent(new Event("change", { bubbles: true }));
        waveformThemePreviewWorked = Boolean(await waitFor(() =>
          document.querySelector(".waveform")?.classList.contains("waveform-" + targetWaveformTheme.toLowerCase().replace(/[^a-z0-9]+/g, "-")),
          "waveform theme preview",
          3000
        ));
      }
    } catch {
      colorSwatchWorked = false;
      waveformThemePreviewWorked = false;
    }
    await applySettingAndConfirm("colorTheme", originalColorTheme);
    await applySettingAndConfirm("waveformTheme", originalWaveformTheme);
    const appearanceControlsWorked = colorSwatchWorked && waveformThemePreviewWorked;
    const providerKeyRoundTrips = [
      await providerKeyProbe({
        providerKey: "promptRewriteProvider",
        targetProvider: "OpenRouter",
        saveMethod: "savePromptRewriteAPIKey",
        clearMethod: "clearPromptRewriteAPIKey",
        statusKey: "promptRewriteAPIKeyConfigured"
      }),
      await providerKeyProbe({
        providerKey: "cloudTranscriptionProvider",
        targetProvider: "Deepgram",
        saveMethod: "saveCloudTranscriptionAPIKey",
        clearMethod: "clearCloudTranscriptionAPIKey",
        statusKey: "cloudTranscriptionAPIKeyConfigured"
      })
    ];
    let voiceConfigurationProbe = { skipped: true };
    if (window.openAssistElectron.voiceInputConfiguration && window.openAssistElectron.startVoiceInput) {
      const originalVoiceState = await window.openAssistElectron.loadAppState();
      const originalTranscriptionEngine = originalVoiceState.settings.transcriptionEngine;
      const originalCloudProvider = originalVoiceState.settings.cloudTranscriptionProvider;
      const waitForVoiceConfiguration = async (predicate, timeout = 5200) => {
        const started = Date.now();
        while (Date.now() - started < timeout) {
          const configuration = await window.openAssistElectron.voiceInputConfiguration();
          if (predicate(configuration)) return configuration;
          await sleep(160);
        }
        return await window.openAssistElectron.voiceInputConfiguration();
      };
      const cloudEngineChanged = await applySettingAndConfirm("transcriptionEngine", "Cloud Providers");
      const cloudProviderChanged = await applySettingAndConfirm("cloudTranscriptionProvider", "ChatGPT / Codex Session");
      const cloudConfiguration = await waitForVoiceConfiguration((configuration) =>
        configuration?.transcriptionEngine === "Cloud Providers"
        && configuration?.cloudTranscriptionProvider === "ChatGPT / Codex Session"
      );
      const whisperChanged = await applySettingAndConfirm("transcriptionEngine", "whisper.cpp");
      const whisperConfiguration = await waitForVoiceConfiguration((configuration) =>
        configuration?.transcriptionEngine === "whisper.cpp"
        && typeof configuration?.whisperModelInstalled === "boolean"
        && Array.isArray(configuration?.whisperInstalledModels)
      );
      const whisperStart = whisperConfiguration?.transcriptionEngine === "whisper.cpp"
        ? await window.openAssistElectron.startVoiceInput()
        : { ok: false, error: "whisper.cpp voice input is not the selected transcription engine." };
      const whisperStop = whisperStart?.ok && window.openAssistElectron.stopVoiceInput
        ? await window.openAssistElectron.stopVoiceInput()
        : null;
      const restoredProvider = await applySettingAndConfirm("cloudTranscriptionProvider", originalCloudProvider);
      const restoredEngine = await applySettingAndConfirm("transcriptionEngine", originalTranscriptionEngine);
      const whisperStartError = whisperStart?.error || "";
      const whisperStopError = whisperStop?.error || "";
      const realWhisperFailure = /whisper\.cpp|whisper|model|microphone|permission|voice input|recording/i;
      voiceConfigurationProbe = {
        skipped: false,
        cloudEngineChanged,
        cloudProviderChanged,
        cloudConfiguration,
        cloudReflected: cloudConfiguration?.transcriptionEngine === "Cloud Providers"
          && cloudConfiguration?.cloudTranscriptionProvider === "ChatGPT / Codex Session"
          && cloudConfiguration?.cloudTranscriptionProviderRequiresKey === false,
        whisperChanged,
        whisperReflected: whisperConfiguration?.transcriptionEngine === "whisper.cpp"
          && typeof whisperConfiguration?.whisperModelInstalled === "boolean"
          && Array.isArray(whisperConfiguration?.whisperInstalledModels),
        whisperHandled: whisperStart?.ok
          ? Boolean(whisperStop?.ok) || realWhisperFailure.test(whisperStopError)
          : realWhisperFailure.test(whisperStartError),
        whisperStartError,
        whisperStopError,
        restoredProvider,
        restoredEngine
      };
    }
    await openSettingsSection("Voice & Dictation");
    await waitFor(() => Array.from(document.querySelectorAll(".settings-card strong")).some((node) =>
      ["Assistant Voice Output", "Voice Reply Output"].includes(node.textContent.trim())
    ), "voice settings");
    const voiceOutputClickable = Boolean(Array.from(document.querySelectorAll(".checkbox-button"))
      .find((button) => button.getAttribute("aria-label") === "Enable assistant reply voice output" || button.textContent.includes("Enable assistant reply voice output")));
    const voiceEngineControlWorked = Boolean(
      Array.from(document.querySelectorAll(".field-label span")).some((node) => node.textContent.trim() === "Voice engine")
      && Array.from(document.querySelectorAll("select")).some((select) => ["humeOctave", "macos"].includes(select.value))
    );
    await openSettingsSection("Keyboard Shortcuts");
    await waitFor(() => document.querySelector("[data-shortcut-target]"), "keyboard shortcut settings");
    const voiceShortcutRowsWorked = ["Hold-to-talk shortcut", "Continuous toggle shortcut", "Agent voice shortcut", "Compact assistant shortcut"]
      .every((label) => Array.from(document.querySelectorAll(".shortcut-recorder-label")).some((node) => node.textContent.trim() === label))
      && document.querySelectorAll("[data-shortcut-target]").length >= 4
      && !document.querySelector(".settings-content")?.innerText.includes("Key 65535")
      && !document.querySelector(".settings-content")?.innerText.includes("fn fn");
    const originalShortcutState = await window.openAssistElectron.loadAppState();
    const originalHoldShortcut = {
      keyCode: originalShortcutState.settings.holdToTalkShortcutKeyCode,
      modifiers: originalShortcutState.settings.holdToTalkShortcutModifiers
    };
    const shortcutRecorderRoundTrip = {
      rendered: false,
      changed: false,
      restored: false
    };
    const holdShortcutButton = document.querySelector('[data-shortcut-target="holdToTalk"]');
    shortcutRecorderRoundTrip.rendered = Boolean(holdShortcutButton);
    if (holdShortcutButton) {
      holdShortcutButton.click();
      await sleep(90);
      window.dispatchEvent(new KeyboardEvent("keydown", {
        key: "F20",
        code: "F20",
        ctrlKey: true,
        shiftKey: true,
        altKey: true,
        bubbles: true,
        cancelable: true
      }));
      shortcutRecorderRoundTrip.changed = await waitForShortcutSetting(90, 262144 | 524288 | 131072);
      const restoredSettings = await window.openAssistElectron.updateShortcut(
        "holdToTalk",
        originalHoldShortcut.keyCode,
        originalHoldShortcut.modifiers
      );
      shortcutRecorderRoundTrip.restored = Boolean(
        restoredSettings
        && restoredSettings.holdToTalkShortcutKeyCode === originalHoldShortcut.keyCode
        && restoredSettings.holdToTalkShortcutModifiers === originalHoldShortcut.modifiers
      ) || await waitForShortcutSetting(originalHoldShortcut.keyCode, originalHoldShortcut.modifiers);
    }
    await openSettingsSection("Voice & Dictation");
    const cloudProviderControlsWorked = Boolean(
      Array.from(document.querySelectorAll(".field-label span")).some((node) => node.textContent.trim() === "Cloud provider")
      && Array.from(document.querySelectorAll(".field-label span")).some((node) => node.textContent.trim() === "Cloud model")
      && Array.from(document.querySelectorAll(".field-label span")).some((node) => node.textContent.trim() === "Cloud base URL")
      && Array.from(document.querySelectorAll(".provider-credential-box strong")).some((node) => node.textContent.trim() === "Cloud transcription API key")
    );
    await openSettingsSection("Models & Connections");
    await waitFor(() => Array.from(document.querySelectorAll(".settings-card strong")).some((node) => node.textContent.trim() === "Prompt Rewrite"), "model settings");
    const modelSettingControlsWorked = Boolean(
      Array.from(document.querySelectorAll("select")).some((select) => select.value === settingRoundTripState.settings.promptRewriteProvider)
      && ["Runtime status", "Runtime account", "Authentication", "Setup command"].every((label) =>
        Array.from(document.querySelectorAll(".select-row span:first-child")).some((node) => node.textContent.trim() === label)
      )
      && typeof settingRoundTripState.settings.assistantRuntimeStatus === "string"
      && settingRoundTripState.settings.assistantRuntimeStatus.trim()
      && typeof settingRoundTripState.settings.assistantRuntimeAccount === "string"
      && Array.from(document.querySelectorAll(".field-label span")).some((node) => node.textContent.trim() === "Prompt rewrite model")
      && Array.from(document.querySelectorAll(".field-label span")).some((node) => node.textContent.trim() === "Prompt rewrite base URL")
      && Array.from(document.querySelectorAll(".provider-credential-box strong")).some((node) => node.textContent.trim() === "Prompt rewrite API key")
      && Array.from(document.querySelectorAll(".provider-credential-box button")).some((button) => button.textContent.trim() === "Save Key")
    );
    await openSettingsSection("Automation & Remote");
    await waitFor(() => Array.from(document.querySelectorAll(".settings-card strong")).some((node) =>
      ["Telegram Remote", "Telegram Remote Control"].includes(node.textContent.trim())
    ), "automation remote settings");
    const telegramButtons = Array.from(document.querySelectorAll("button")).map((button) => button.textContent.trim()).filter(Boolean);
    const telegramSetupWorked = Boolean(
      document.querySelector('input[type="password"][placeholder="Paste your Telegram bot token"]')
      && telegramButtons.includes("Save Token")
      && telegramButtons.includes("Clear Token")
      && telegramButtons.includes("Test Bot Connection")
      && telegramButtons.includes("Open BotFather")
    );
    const telegramNoTokenProbe = settingRoundTripState.settings.telegramTokenConfigured
      ? { skipped: true }
      : await window.openAssistElectron.testTelegramConnection("");
    await openSettingsSection("App & Permissions");
    await waitFor(() => Array.from(document.querySelectorAll(".settings-card strong")).some((node) =>
      ["Diagnostics", "Diagnostics Logs"].includes(node.textContent.trim())
    ), "app diagnostics");
    const diagnosticsButtons = Array.from(document.querySelectorAll("button")).map((button) => button.textContent.trim()).filter(Boolean);
    const diagnosticsButtonsWorked = ["Open Crash Logs", "Open Helper Logs", "Open Insertion Diagnostics", "Open App Data"]
      .every((label) => diagnosticsButtons.includes(label));
    await openSettingsSection("Assistant");
    await waitFor(() => Array.from(document.querySelectorAll("button")).some((button) => button.textContent.trim() === "Open Assistant"), "assistant settings");
    await openAssistantView("threads view after settings");

    Array.from(document.querySelectorAll("button")).find((button) => button.textContent.trim() === "Automations")?.click();
    await waitFor(() => document.querySelector(".split-feature-main"), "automations view");
    byLabel("New scheduled job")?.click();
    await sleep(180);
    const automationCreatePanelWorked = Boolean(document.querySelector(".automation-edit-panel"));

    Array.from(document.querySelectorAll("button")).find((button) => button.textContent.trim() === "Skills")?.click();
    await waitFor(() => document.querySelector(".catalog-main"), "skills view");
    Array.from(document.querySelectorAll("button")).find((button) => button.textContent.trim() === "New Skill")?.click();
    await sleep(160);
    const skillCreatePanelWorked = Boolean(document.querySelector(".skill-action-panel textarea"));
    Array.from(document.querySelectorAll("button")).find((button) => button.textContent.trim() === "New Skill")?.click();
    await sleep(80);
    Array.from(document.querySelectorAll("button")).find((button) => button.textContent.trim() === "Import GitHub")?.click();
    await sleep(160);
    const skillGitHubPanelWorked = Boolean(document.querySelector(".skill-action-panel input"));

    Array.from(document.querySelectorAll("button")).find((button) => button.textContent.trim() === "Plugins")?.click();
    await waitFor(() => document.querySelector(".plugins-main"), "plugins view");
    Array.from(document.querySelectorAll(".plugin-filter button")).find((button) => button.textContent.trim() === "Installed")?.click();
    await sleep(220);
    const installedPluginStatuses = Array.from(document.querySelectorAll(".plugin-row:not(.show-more-row) b"))
      .map((node) => node.textContent.trim());
    const pluginFilterWorked = installedPluginStatuses.length > 0
      && installedPluginStatuses.every((status) => status === "Installed" || status === "In Chat");
    const starterButton = Array.from(document.querySelectorAll("button"))
      .find((button) => button.className.includes("prompt-button"));
    starterButton?.click();
    await waitFor(() => document.querySelector(".assistant-main"), "threads view");
    const starterPromptText = document.querySelector(".composer-input")?.value ?? "";
    const starterPromptWorked = starterPromptText.startsWith("Use ") && starterPromptText.includes("help with this task");

    if (document.querySelector(".composer-provider-popover")) document.querySelector(".composer-provider-trigger")?.click();
    const topbarProviderRemoved = !Boolean(document.querySelector(".topbar .provider-pill"));
    document.querySelector(".composer-provider-trigger")?.click();
    await sleep(120);
    const providers = Array.from(document.querySelectorAll(".composer-provider-popover button strong")).map((node) => node.textContent.trim());
	    const providerBrandColors = Object.fromEntries(
	      Array.from(document.querySelectorAll(".composer-provider-popover button")).map((button) => {
	        const label = button.querySelector("strong")?.textContent.trim() ?? "";
	        const mark = button.querySelector(".provider-mark");
	        const color = mark ? getComputedStyle(mark).getPropertyValue("--provider-color").trim().toLowerCase() : "";
	        return [label, color];
	      })
	    );
	    const providerMarkImagesWorked = Array.from(document.querySelectorAll(".composer-provider-popover button"))
	      .every((button) => Boolean(button.querySelector(".provider-mark-image")));
	    const providerMenuText = document.querySelector(".composer-provider-popover")?.innerText ?? "";
	    document.querySelector(".composer-provider-trigger")?.click();
	    document.querySelector(".workspace-launch-chevron")?.click();
	    await waitFor(() => document.querySelector(".editor-popover"), "editor action menu");
	    const editorMenuText = document.querySelector(".editor-popover")?.innerText ?? "";
	    const editorMenuWorked = ["VS Code", "VS Code Insiders", "Cursor", "Finder", "Terminal"]
	      .every((label) => editorMenuText.includes(label))
        && document.querySelectorAll(".editor-popover button").length >= 6
        && Boolean(document.querySelector(".workspace-launch-primary .workspace-target-icon, .workspace-launch-primary .workspace-target-fallback"));
	    document.querySelector(".workspace-launch-chevron")?.click();
	    const bottomModelButton = document.querySelector(".composer-model-main")
	      ?? document.querySelector(".composer-menu-wrap .pill-button");
	    bottomModelButton?.click();
	    await waitFor(() => document.querySelector(".composer-popover.model-popover"), "bottom model menu");
	    const composerModelMenuText = document.querySelector(".composer-popover.model-popover")?.innerText ?? "";
	    const composerModelSelectorWorked = Boolean(composerModelMenuText.trim())
	      && !Boolean(document.querySelector(".topbar-actions .model-popover"));
	    bottomModelButton?.click();
	    const permissionButton = document.querySelector(".composer-permission-wrap .permission-pill");
	    permissionButton?.click();
	    await waitFor(() => document.querySelector(".permission-popover"), "permission menu");
	    const permissionLabels = Array.from(document.querySelectorAll(".permission-popover button strong")).map((node) => node.textContent.trim());
	    const permissionMenuWorked = ["Default permissions", "Auto-review", "Full access", "Custom (config.toml)"]
	      .every((label) => permissionLabels.includes(label));
	    Array.from(document.querySelectorAll(".permission-popover button"))
	      .find((button) => button.textContent.includes("Auto-review"))?.click();
	    await sleep(80);
	    const permissionSelectionWorked = (document.querySelector(".composer-permission-wrap .permission-pill")?.textContent ?? "").includes("Auto-review");
		    const selectedProviderLabel = document.querySelector(".composer-provider-trigger > span:not(.provider-mark)")?.textContent?.trim() ?? "";
		    const usageFooterText = document.querySelector(".usage-footer")?.innerText ?? "";
		    const profilePillText = document.querySelector(".usage-footer .profile-pill")?.textContent?.trim() ?? "";
		    const usageFooterHasZeroLimit = /(^|[^\\d])0%($|[^\\d])/.test(usageFooterText);
		    const usageFooterWorked = Boolean(usageFooterText.trim())
		      && Boolean(selectedProviderLabel)
		      && profilePillText.includes(selectedProviderLabel)
		      && !usageFooterHasZeroLimit;
	    const workingProbe = document.createElement("div");
	    workingProbe.className = "assistant-working-row assistant-working-row-codex";
	    workingProbe.innerHTML = '<span class="provider-mark-inline assistant-working-provider-mark"></span><span class="assistant-working-text">Codex is working</span>';
	    document.body.appendChild(workingProbe);
	    const workingText = workingProbe.querySelector(".assistant-working-text");
	    const workingStatusIndicatorWorked = Boolean(workingText)
	      && workingText.textContent.trim() === "Codex is working"
	      && getComputedStyle(workingText).animationName === "assistant-working-shimmer"
	      && !Boolean(workingProbe.querySelector(".streaming-wave, .assistant-working-dot, .assistant-working-meta"));
	    workingProbe.remove();

    const closeInspector = async () => {
      byLabel("Close panel")?.click();
      await sleep(120);
    };
    const ensureThreadNoteHandle = async () => {
      if (document.querySelector(".thread-note-side-handle")) return true;
      clickButtonText("Threads")?.click();
      await waitFor(() => document.querySelector(".assistant-main"), "threads view before thread-note handle");
      byLabel("Show all threads")?.click();
      await sleep(180);
      const threadRow = document.querySelector(".thread-row:not(.show-more-row)");
      threadRow?.click();
      await waitFor(() => document.querySelector(".thread-note-side-handle"), "thread-note side handle", 5000);
      return true;
    };
    const inspectorTitle = () => document.querySelector(".assistant-inspector .inspector-header strong")?.textContent?.trim() ?? "";
    const ensureThreadNoteEditor = async () => {
      const existingEditor = document.querySelector(".thread-note-editor textarea");
      if (existingEditor) return existingEditor;
      const createButton = Array.from(document.querySelectorAll(".thread-note-empty-card button, button"))
        .find((button) => button.textContent.trim() === "New thread note");
      createButton?.click();
      await waitFor(() => document.querySelector(".thread-note-editor .note-format-toolbar"), "thread note toolbar");
      const markdownButton = Array.from(document.querySelectorAll(".thread-note-editor .note-format-toolbar button"))
        .find((button) => button.textContent.trim() === "Markdown");
      markdownButton?.click();
      return await waitFor(() => document.querySelector(".thread-note-editor textarea"), "thread note editor");
    };
    await closeInspector();
    await ensureThreadNoteHandle();
    document.querySelector(".thread-note-side-handle")?.click();
    await waitFor(() => inspectorTitle() === "Thread Note", "thread-note action panel");
    await ensureThreadNoteEditor();
    const threadNoteActionWorked = Boolean(document.querySelector(".thread-note-editor textarea"))
      && Boolean(document.querySelector(".thread-note-editor .note-format-toolbar"));
    await closeInspector();
    byLabel("Session instructions")?.click();
    await waitFor(() => inspectorTitle() === "Session Instructions", "session-instructions action panel");
    const sessionInstructionsActionWorked = Boolean(document.querySelector('.inspector-textarea[placeholder="Add one-time rules for this chat..."]'));
    await closeInspector();
    byLabel("Open memory")?.click();
    await waitFor(() => inspectorTitle() === "Memory", "memory action panel");
    const memoryActionWorked = Boolean(document.querySelector(".inspector-textarea.readonly"));
    await closeInspector();
    const topbarActionButtonsWorked = threadNoteActionWorked && sessionInstructionsActionWorked && memoryActionWorked;

    if (!document.querySelector(".thread-note-panel")) {
      byLabel("Open thread note")?.click();
    }
    const noteTextarea = await ensureThreadNoteEditor();
    const beforeChart = noteTextarea?.value ?? "";
    noteTextarea?.focus();
    noteTextarea?.setSelectionRange(beforeChart.length, beforeChart.length);
    Array.from(document.querySelectorAll("button")).find((button) => button.textContent.includes("Insert chart"))?.click();
    await waitFor(() => document.querySelector(".chart-template-popover button"), "chart template menu");
    const chartOptions = Array.from(document.querySelectorAll(".chart-template-popover button")).map((button) => button.innerText.trim());
    const richNoteToolbarWorked = ["Heading", "Bold", "Italic", "Table"].every((title) =>
      Boolean(document.querySelector('.thread-note-editor .note-format-toolbar button[title="' + title + '"]'))
    ) && chartOptions.length >= 8;
    document.querySelector(".chart-template-popover button")?.click();
    const afterChart = await waitFor(() => {
      const value = document.querySelector(".thread-note-editor textarea")?.value ?? "";
      return value.includes("mermaid") && value !== beforeChart ? value : "";
    }, "chart insertion");
    const setTextareaValue = (textarea, nextValue, cursor = nextValue.length) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")?.set;
      if (setter) setter.call(textarea, nextValue);
      else textarea.value = nextValue;
      textarea.setSelectionRange(cursor, cursor);
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
    };
    const beforeSlashCommand = document.querySelector(".thread-note-editor textarea")?.value ?? afterChart;
    const slashTextarea = document.querySelector(".thread-note-editor textarea");
    if (!slashTextarea) throw new Error("Thread note textarea missing before slash command probe.");
    slashTextarea?.focus();
    setTextareaValue(slashTextarea, beforeSlashCommand + "\\n/gantt");
    await waitFor(() => document.querySelector(".slash-command-popover button"), "slash command menu");
    const slashCommandOptions = Array.from(document.querySelectorAll(".slash-command-popover button strong"))
      .map((node) => node.textContent.trim());
    const ganttSlashButton = Array.from(document.querySelectorAll(".slash-command-popover button"))
      .find((button) => button.textContent.includes("Gantt"));
    ganttSlashButton?.click();
    const afterSlashCommand = await waitFor(() => {
      const value = document.querySelector(".thread-note-editor textarea")?.value ?? "";
      return value.includes("gantt") && value !== beforeSlashCommand ? value : "";
    }, "slash command insertion");
    const viewerProbeMarkdown = [
      "",
      "| Column | Value |",
      "| --- | --- |",
      "| Markdown library | ReactMarkdown + GFM |",
      "",
      "- [x] GFM task list",
      "",
      "\`\`\`ts",
      "const markdownViewerWorks = true;",
      "\`\`\`"
    ].join("\\n");
    const viewerTextarea = document.querySelector(".thread-note-editor textarea");
    if (!viewerTextarea) throw new Error("Thread note textarea missing before markdown viewer probe.");
    setTextareaValue(viewerTextarea, afterSlashCommand + viewerProbeMarkdown);
    Array.from(document.querySelectorAll(".thread-note-editor .note-format-toolbar button"))
      .find((button) => button.textContent.trim() === "Preview")?.click();
    const richNotePreviewWorked = await waitFor(() => {
      const preview = document.querySelector(".thread-note-editor .markdown-preview-rich");
      return Boolean(
        preview
        && preview.querySelector("table")
        && preview.querySelector('input[type="checkbox"]')
        && preview.querySelector(".note-code-block-wrapper")
      );
    }, "thread note markdown preview");
    const mermaidPreviewWorked = await waitFor(() =>
      Boolean(document.querySelector(".thread-note-editor .note-mermaid-preview svg")),
      "thread note mermaid preview"
    );

    const state = await window.openAssistElectron.loadAppState();
    const providerRoundTripThread = state.threads?.find((thread) => thread.activeProvider);
    let providerRoundTrip = { skipped: true };
    if (providerRoundTripThread && window.openAssistElectron.setThreadProvider) {
      const originalProvider = providerRoundTripThread.activeProvider;
      const runtimeProviders = ["codex", "copilot", "claudeCode", "antigravityCLI", "ollamaLocal"];
      const originalRuntimeProvider = runtimeProviders.includes(originalProvider) ? originalProvider : "codex";
      const targetProvider = originalRuntimeProvider === "ollamaLocal" ? "codex" : "ollamaLocal";
      const updated = await window.openAssistElectron.setThreadProvider(providerRoundTripThread.id, targetProvider);
      const externalSanitized = await window.openAssistElectron.setThreadProvider(providerRoundTripThread.id, "xAI");
      const restored = await window.openAssistElectron.setThreadProvider(providerRoundTripThread.id, originalRuntimeProvider);
      providerRoundTrip = {
        skipped: false,
        threadID: providerRoundTripThread.id,
        originalProvider,
        originalRuntimeProvider,
        targetProvider,
        updated: updated?.activeProvider === targetProvider,
        externalSanitized: externalSanitized?.activeProvider !== "xAI",
        restored: restored?.activeProvider === originalRuntimeProvider
      };
    }
    let voiceProbe = { skipped: true };
    if (window.openAssistElectron.startVoiceInput && window.openAssistElectron.stopVoiceInput) {
      const originalVoiceState = await window.openAssistElectron.loadAppState();
      const forcedAppleSpeech = await applySettingAndConfirm("transcriptionEngine", "Apple Speech");
      let voiceStart = { ok: false, error: "Apple Speech was not selected" };
      let voiceStop = { ok: false, text: "", error: "not stopped" };
      try {
        if (forcedAppleSpeech) {
          voiceStart = await window.openAssistElectron.startVoiceInput();
          if (voiceStart?.ok) {
            await sleep(420);
            voiceStop = await window.openAssistElectron.stopVoiceInput();
          }
        }
      } finally {
        await applySettingAndConfirm("transcriptionEngine", originalVoiceState.settings.transcriptionEngine);
      }
      voiceProbe = {
        skipped: /permission|macOS prompt|did not become ready/i.test(voiceStart?.error || ""),
        forcedAppleSpeech,
        startOk: Boolean(voiceStart?.ok),
        startError: voiceStart?.error || "",
        stopOk: Boolean(voiceStop?.ok),
        stopError: voiceStop?.error || ""
      };
    }
    const note = state.notes?.[0];
    let saveRoundTrip = { skipped: true };
    if (note) {
      const detail = await window.openAssistElectron.loadNote(note.projectID, note.id);
      const original = detail.markdown || "";
      const probe = original + "\\n\\n<!-- electron-react-verify-probe -->";
      await window.openAssistElectron.saveNote(note.projectID, note.id, probe);
      const updated = await window.openAssistElectron.loadNote(note.projectID, note.id);
      await window.openAssistElectron.saveNote(note.projectID, note.id, original);
      const restored = await window.openAssistElectron.loadNote(note.projectID, note.id);
      saveRoundTrip = {
        skipped: false,
        path: detail.path,
        persisted: (updated.markdown || "").includes("electron-react-verify-probe"),
        restored: !(restored.markdown || "").includes("electron-react-verify-probe")
      };
    }

    const transcriptHistoryPopup = { bridge: Boolean(window.openAssistElectron?.openTranscriptHistoryWindow), opened: false };
    if (transcriptHistoryPopup.bridge) {
      const popupResult = await window.openAssistElectron.openTranscriptHistoryWindow();
      transcriptHistoryPopup.opened = Boolean(popupResult?.ok);
    }

    if (!document.querySelector(".app-shell")?.className.includes("compact-mode")) {
      byLabel("Open sidebar assistant")?.click();
      await sleep(450);
    }
    byLabel("Hide assistant")?.click();
    await sleep(450);
    const shell = document.querySelector(".app-shell");
    const edge = document.querySelector(".edge-handle")?.getBoundingClientRect();

    return {
      title: document.title,
      hasBridge: Boolean(window.openAssistElectron),
      hasVoiceShortcutBridge: Boolean(window.openAssistElectron?.onVoiceShortcut),
      settingsProvider: state.settings.assistantBackend,
      availableBackends: state.settings.availableAssistantBackends,
      assistantSidebarUpdateHidden,
      settingsUpdateCardScoped,
      assistantHistoryNavHidden,
      transcriptHistoryPopup,
	      providers,
	      topbarProviderRemoved,
	      forbiddenVisible: ${JSON.stringify(forbiddenProviders)}.filter((name) => providerMenuText.includes(name)),
	      editorMenuWorked,
	      composerModelSelectorWorked,
	      permissionMenuWorked,
	      permissionSelectionWorked,
	      providerBrandColors,
	      providerMarkImagesWorked,
	      selectedProviderLabel,
	      profilePillText,
	      usageFooterText,
	      usageFooterWorked,
	      workingStatusIndicatorWorked,
      projectFilter: {
        selectedProjectName,
        threadProjectLabels,
        worked: projectFilterWorked
      },
      projectContextMenuWorked,
      projectContextText,
      threadContextMenuWorked,
      threadContextText,
      sidebarNavigationChecks,
      projectCreatePanelWorked,
      temporaryThreadButtonWorked,
      sidebarSingleSelectionWorked,
      sidebarSelectionProbe: {
        activeProjectRowCount,
        activeThreadRowCount,
        activeThreadShadow,
        activeNavShadow
      },
	      temporaryThreadLifecycleWorked,
	      temporaryThreadLifecycle,
      codeTrackingBridgeProbe,
      codexRuntimeParityWorked,
      codexRuntimeParityProbe,
      codexDefaultPermissionProbe,
      codexAutoReviewPermissionProbe,
      codexCustomPermissionProbe,
      codexNoProjectRuntimeProbe,
      forbiddenRuntimeHints,
	      hideProjectProbe,
	      hiddenProjectContextMenuProbe,
	      archivedToggleWorked,
      compactStyleGuardWorked,
      compactToggleClickable,
      codeTrackingClickable,
      voiceOutputClickable,
      voiceEngineControlWorked,
      voiceShortcutRowsWorked,
      shortcutRecorderRoundTrip,
      modelSettingControlsWorked,
      cloudProviderControlsWorked,
      settingsNavigationChecks,
      settingsRoundTrips,
      appearanceControlsWorked,
      providerKeyRoundTrips,
      voiceConfigurationProbe,
      telegramSetupWorked,
      telegramNoTokenProbe,
      diagnosticsButtonsWorked,
      automationCreatePanelWorked,
      skillCreatePanelWorked,
      skillGitHubPanelWorked,
      pluginFilter: {
        installedPluginStatuses,
        worked: pluginFilterWorked
      },
      starterPromptWorked,
      topbarActionButtonsWorked,
      chartOptions,
      slashCommandOptions,
      chartInserted: afterChart.includes("mermaid") && afterChart !== beforeChart,
      slashCommandsWorked: slashCommandOptions.includes("Gantt") && afterSlashCommand.includes("gantt"),
      richNoteToolbarWorked,
      richNotePreviewWorked,
      mermaidPreviewWorked,
      voiceProbe,
      providerRoundTrip,
      saveRoundTrip,
      collapsedClass: shell?.className,
      collapsedGridColumns: shell ? getComputedStyle(shell).gridTemplateColumns : "",
      edge: edge && { width: edge.width, height: edge.height }
    };
  })()`);

  assert(result.title === "Open Assist", "Renderer title should be Open Assist.");
  assert(result.hasBridge, "window.openAssistElectron bridge should exist.");
  assert(result.hasVoiceShortcutBridge, "Configured voice shortcuts should be bridged from Electron main to the renderer.");
		  assert(JSON.stringify(result.providers) === JSON.stringify(expectedProviders), `Provider menu mismatch: ${JSON.stringify(result.providers)}`);
		  assert(result.topbarProviderRemoved, "Provider selector should not be duplicated in the top bar.");
		  assert(result.forbiddenVisible.length === 0, `Wrong providers visible in runtime menu: ${result.forbiddenVisible.join(", ")}`);
	  assert(result.editorMenuWorked, "Top code menu should expose real open-workspace actions, not model choices.");
	  assert(result.composerModelSelectorWorked, "Model selector should live in the bottom composer controls.");
	  assert(result.permissionMenuWorked && result.permissionSelectionWorked, "Codex permission menu should expose official permission modes and update the composer pill.");
	  assert(JSON.stringify(result.providerBrandColors) === JSON.stringify({ Codex: "#7f94ff", Copilot: "#c898fd", Claude: "#ffb36b", Antigravity: "#3186ff", Ollama: "#61bf73" }), `Provider brand colors should match native backend hues: ${JSON.stringify(result.providerBrandColors)}`);
	  assert(result.providerMarkImagesWorked, "Runtime provider menu should render provider mark image assets for every provider.");
	  assert(result.assistantSidebarUpdateHidden, "Assistant sidebar should not show the app update card.");
	  assert(result.settingsUpdateCardScoped, "App update card should stay scoped to the Settings sidebar.");
  assert(result.assistantHistoryNavHidden, "Transcript History should open as a separate popup, not as an assistant sidebar page.");
  assert(result.transcriptHistoryPopup.bridge && result.transcriptHistoryPopup.opened, `Transcript History popup bridge failed: ${JSON.stringify(result.transcriptHistoryPopup)}`);
	  assert(result.usageFooterWorked, `Usage footer should match the selected provider and not show fake static 0% limits: selected=${result.selectedProviderLabel}, profile=${result.profilePillText}, footer=${result.usageFooterText}`);
  assert(result.workingStatusIndicatorWorked, "Assistant pending turn should show only the provider mark and working text, without a waveform.");
  assert(result.sidebarNavigationChecks.every((item) => item.worked), `Sidebar navigation failed: ${JSON.stringify(result.sidebarNavigationChecks)}`);
  assert(result.projectFilter.worked, `Project selection should filter sidebar threads: ${JSON.stringify(result.projectFilter)}`);
  assert(result.projectContextMenuWorked, `Project right-click menu should expose the native sidebar actions: ${result.projectContextText}`);
  assert(result.threadContextMenuWorked, `Thread right-click menu should expose the native sidebar actions: ${result.threadContextText}`);
  assert(result.sidebarSingleSelectionWorked, `Sidebar should show one selected project/thread without left ribbon stripes: ${JSON.stringify(result.sidebarSelectionProbe)}`);
  assert(result.projectCreatePanelWorked, "Project create button should open the project/group creation panel.");
  assert(result.temporaryThreadButtonWorked, "Sidebar should expose a first-class temporary chat action.");
  assert(result.temporaryThreadLifecycleWorked, `Temporary chat should be transient and locally cleaned up: ${JSON.stringify(result.temporaryThreadLifecycle)}`);
  assert(
    result.codeTrackingBridgeProbe.hasLoad
    && result.codeTrackingBridgeProbe.hasOpenReview
    && result.codeTrackingBridgeProbe.hasRestore,
    `Code tracking bridge should expose load/review/restore APIs: ${JSON.stringify(result.codeTrackingBridgeProbe)}`
  );
  assert(
    result.codeTrackingBridgeProbe.noProjectState?.availability === "unavailable"
    && !result.codeTrackingBridgeProbe.noProjectState?.repoRootPath,
    `No-project code tracking should not fall back to the OpenAssist repo: ${JSON.stringify(result.codeTrackingBridgeProbe.noProjectState)}`
  );
  assert(result.codexRuntimeParityWorked, `Codex runtime params should match clean Swift parity: ${JSON.stringify({
    runtime: result.codexRuntimeParityProbe,
    defaultPermissions: result.codexDefaultPermissionProbe,
    autoReviewPermissions: result.codexAutoReviewPermissionProbe,
    customPermissions: result.codexCustomPermissionProbe,
    noProject: result.codexNoProjectRuntimeProbe,
    forbiddenRuntimeHints: result.forbiddenRuntimeHints
  })}`);
	  assert(result.hideProjectProbe.skipped || (
	    result.hideProjectProbe.createdVisible
	    && result.hideProjectProbe.hiddenFromProjects
	    && result.hideProjectProbe.listedAsHidden
	    && result.hideProjectProbe.unhideReturned
	    && result.hideProjectProbe.restoredVisible
	  ), `Project hide/unhide should move projects between visible and hidden lists: ${JSON.stringify(result.hideProjectProbe)}`);
	  assert(result.hiddenProjectContextMenuProbe.skipped || (
	    result.hiddenProjectContextMenuProbe.hadUnhideSubmenu
	    && result.hiddenProjectContextMenuProbe.restoredVisible
	    && result.hiddenProjectContextMenuProbe.cleanedUp
	  ), `Projects right-click menu should expose and run unhide choices: ${JSON.stringify(result.hiddenProjectContextMenuProbe)}`);
	  assert(result.archivedToggleWorked, "Archived sidebar item should switch the thread list into archived mode.");
  assert(result.compactStyleGuardWorked, "Orb/Notch settings should be disabled because this port only implements Sidebar mode.");
  assert(result.compactToggleClickable, "Sidebar mode controls should stay available after settings cleanup.");
  assert(result.codeTrackingClickable, "Track code changes should be a real settings toggle.");
  assert(result.voiceOutputClickable, "Assistant voice output should be a real settings toggle.");
  assert(result.voiceEngineControlWorked, "Assistant voice engine should be a real persisted selector.");
  assert(result.voiceShortcutRowsWorked, "Voice shortcut rows should use native shortcut values instead of hard-coded placeholder text.");
  assert(
    result.shortcutRecorderRoundTrip.rendered
    && result.shortcutRecorderRoundTrip.changed
    && result.shortcutRecorderRoundTrip.restored,
    `Voice shortcut recorder should save and restore a real shortcut: ${JSON.stringify(result.shortcutRecorderRoundTrip)}`
  );
  assert(result.modelSettingControlsWorked, "Model/provider settings should expose real editable controls.");
  assert(result.cloudProviderControlsWorked, "Cloud transcription provider settings should expose real editable controls.");
  assert(result.settingsNavigationChecks.every((item) => item.worked), `Settings navigation failed: ${JSON.stringify(result.settingsNavigationChecks)}`);
  assert(result.settingsRoundTrips.every((item) => item.changed && item.restored), `Settings round-trip failed: ${JSON.stringify(result.settingsRoundTrips)}`);
  assert(result.appearanceControlsWorked, "Appearance color and waveform controls should update the visible preview.");
  for (const item of result.providerKeyRoundTrips) {
    if (!item.wasConfigured && item.saved && !item.cleared && !hasProviderKeychainAccount(item.providerKey, item.targetProvider)) {
      item.cleared = true;
      item.clearedByExternalKeychainCheck = true;
    }
  }
  assert(result.providerKeyRoundTrips.every((item) => item.providerChanged && item.saved && item.cleared && item.restoredProvider), `Provider key round-trip failed: ${JSON.stringify(result.providerKeyRoundTrips)}`);
  assert(result.telegramSetupWorked, "Telegram setup should expose real token, test, BotFather, and pairing controls.");
  assert(result.telegramNoTokenProbe.skipped || result.telegramNoTokenProbe.ok === false, `Telegram no-token probe should return a real failure message: ${JSON.stringify(result.telegramNoTokenProbe)}`);
  assert(result.diagnosticsButtonsWorked, "Diagnostics buttons should be available in App & Permissions settings.");
  assert(result.automationCreatePanelWorked, "New scheduled job should open the real creation panel.");
  assert(result.skillCreatePanelWorked, "New Skill should open the skill creation panel.");
  assert(result.skillGitHubPanelWorked, "Import GitHub should open the GitHub skill import panel.");
  assert(result.pluginFilter.worked, `Installed plugin filter should filter plugin rows: ${JSON.stringify(result.pluginFilter)}`);
  assert(result.starterPromptWorked, "Plugin starter prompt should open chat and fill the composer.");
  assert(result.topbarActionButtonsWorked, "Top-bar thread note, session instructions, and memory buttons should open the correct panels.");
  assert(result.chartInserted, "Thread-note chart insertion should update the note draft.");
  assert(result.slashCommandsWorked, `Thread-note slash commands should insert real note blocks: ${JSON.stringify(result.slashCommandOptions)}`);
  assert(result.richNoteToolbarWorked, `Thread-note rich toolbar should expose native-like markdown/chart controls: ${JSON.stringify(result.chartOptions)}`);
  assert(result.richNotePreviewWorked, "Thread-note preview should render GFM tables, tasks, and code with the real Markdown viewer.");
  assert(result.mermaidPreviewWorked, "Thread-note preview should render Mermaid diagrams with the real Markdown viewer.");
  assert(result.voiceConfigurationProbe.skipped || (
    result.voiceConfigurationProbe.cloudEngineChanged
    && result.voiceConfigurationProbe.cloudProviderChanged
    && result.voiceConfigurationProbe.cloudReflected
    && result.voiceConfigurationProbe.whisperChanged
    && result.voiceConfigurationProbe.whisperReflected
    && result.voiceConfigurationProbe.whisperHandled
    && result.voiceConfigurationProbe.restoredProvider
    && result.voiceConfigurationProbe.restoredEngine
  ), `Configured voice behavior failed: ${JSON.stringify(result.voiceConfigurationProbe)}`);
  assert(result.voiceProbe.skipped || (result.voiceProbe.startOk && result.voiceProbe.stopOk), `Voice input start/stop failed: ${JSON.stringify(result.voiceProbe)}`);
  assert(result.providerRoundTrip.skipped || (result.providerRoundTrip.updated && result.providerRoundTrip.externalSanitized && result.providerRoundTrip.restored), `Thread provider round-trip failed: ${JSON.stringify(result.providerRoundTrip)}`);
  assert(result.saveRoundTrip.skipped || (result.saveRoundTrip.persisted && result.saveRoundTrip.restored), "Project note save round-trip failed.");
  const voiceHUDProbe = await client.evaluate(`(async () => {
    const bridge = Boolean(window.openAssistElectron?.updateVoiceHUD);
    const showResult = bridge
      ? await window.openAssistElectron.updateVoiceHUD({
          visible: true,
          status: "listening",
          theme: "Vibrant Spectrum",
          colorTheme: "Forest",
          chromeStyle: "Classic",
          level: 0.55
        })
      : null;
    await new Promise((resolve) => setTimeout(resolve, 500));
    return {
      bridge,
      showOk: Boolean(showResult?.ok),
      embeddedPillPresent: Boolean(document.querySelector(".voice-activity-pill")),
      composerVoiceTextPresent: Boolean(document.querySelector(".composer-voice-status:not(.warning)"))
    };
  })()`);
  const voiceHUDBounds = macWindowBounds("Open Assist Voice HUD");
  if (voiceHUDBounds) {
    voiceHUDProbe.bounds = voiceHUDBounds;
  }
  const processingResult = await client.evaluate(`window.openAssistElectron?.updateVoiceHUD?.({ visible: true, status: "processing", theme: "Vibrant Spectrum", colorTheme: "Forest", chromeStyle: "Classic" })`);
  await new Promise((resolve) => setTimeout(resolve, 250));
  const processingVoiceHUDBounds = macWindowBounds("Open Assist Voice HUD");
  if (processingVoiceHUDBounds) {
    voiceHUDProbe.processingBounds = processingVoiceHUDBounds;
    voiceHUDProbe.processingShowOk = Boolean(processingResult?.ok);
  }
  const errorResult = await client.evaluate(`window.openAssistElectron?.updateVoiceHUD?.({ visible: true, status: "error", text: "Microphone permission is not granted.", theme: "Vibrant Spectrum", colorTheme: "Rose", chromeStyle: "Glass (High Contrast)" })`);
  await new Promise((resolve) => setTimeout(resolve, 250));
  const errorVoiceHUDBounds = macWindowBounds("Open Assist Voice HUD");
  if (errorVoiceHUDBounds) {
    voiceHUDProbe.errorBounds = errorVoiceHUDBounds;
    voiceHUDProbe.errorShowOk = Boolean(errorResult?.ok);
  }
  const correctionResult = await client.evaluate(`window.openAssistElectron?.updateVoiceHUD?.({ visible: true, status: "correction", source: "helo", replacement: "hello", theme: "Vibrant Spectrum", colorTheme: "Ocean", chromeStyle: "Glass (High Contrast)" })`);
  await new Promise((resolve) => setTimeout(resolve, 250));
  const correctionVoiceHUDBounds = macWindowBounds("Open Assist Voice HUD");
  if (correctionVoiceHUDBounds) {
    voiceHUDProbe.correctionBounds = correctionVoiceHUDBounds;
    voiceHUDProbe.correctionShowOk = Boolean(correctionResult?.ok);
  }
  await client.evaluate(`window.openAssistElectron?.updateVoiceHUD?.({ visible: false, status: "idle" })`);
  assert(
    voiceHUDProbe.bridge
    && voiceHUDProbe.showOk
	    && !voiceHUDProbe.embeddedPillPresent
	    && !voiceHUDProbe.composerVoiceTextPresent
	    && voiceHUDBounds
	    && voiceHUDBounds.width >= 64
	    && voiceHUDBounds.width <= 190
    && voiceHUDBounds.height >= 32
    && voiceHUDBounds.height <= 48
    && processingVoiceHUDBounds
    && processingVoiceHUDBounds.width <= 48
    && processingVoiceHUDBounds.height <= 48
    && errorVoiceHUDBounds
    && errorVoiceHUDBounds.width >= 290
    && errorVoiceHUDBounds.width <= 380
    && errorVoiceHUDBounds.height <= 44
    && correctionVoiceHUDBounds
    && correctionVoiceHUDBounds.width >= 410
    && correctionVoiceHUDBounds.width <= 540
    && correctionVoiceHUDBounds.height <= 48,
    `Voice HUD should be a separate compact macOS HUD window with listening, processing, message, and correction states: ${JSON.stringify(voiceHUDProbe)}`
  );
  result.voiceHUDProbe = voiceHUDProbe;
  assert(result.collapsedClass.includes("sidebar-collapsed"), "Sidebar should enter collapsed mode.");
  assert(/^34px 0px 0px$|^0px 0px 34px$/.test(result.collapsedGridColumns), `Collapsed grid should keep only the larger arrow track visible, got ${result.collapsedGridColumns}.`);
  assert(result.edge?.width === 34 && result.edge?.height === 92, `Collapsed edge handle size mismatch: ${JSON.stringify(result.edge)}`);
  const bounds = macWindowBounds();
  if (bounds) {
    assert(bounds.width >= 500 && bounds.height <= 112, `Collapsed macOS window should keep panel width for slide-in/out and only short arrow height, got ${JSON.stringify(bounds)}.`);
    result.macWindowBounds = bounds;
  }
  const historyBounds = macWindowBounds("Transcript History");
  if (historyBounds) {
    assert(historyBounds.width >= 520 && historyBounds.height >= 360, `Transcript History should be a separate resizable popup window, got ${JSON.stringify(historyBounds)}.`);
    result.transcriptHistoryPopup.bounds = historyBounds;
  }
  const menuItems = macMenuBarItems();
  if (menuItems) {
    for (const label of ["Open Assist", "Edit", "View", "Window", "Help"]) {
      assert(menuItems.includes(label), `Mac menu should include ${label}, got ${JSON.stringify(menuItems)}.`);
    }
    result.macMenuBarItems = menuItems;
  }
  const viewMenuItems = macViewMenuItems();
  if (viewMenuItems) {
    assert(viewMenuItems.includes("Show / Hide Assistant"), `View menu should expose the hide/show shortcut, got ${JSON.stringify(viewMenuItems)}.`);
    result.macViewMenuItems = viewMenuItems;
  }
  assertNoLocalChatStores();
  assertProviderMarkAssets();

  console.log(JSON.stringify({ ok: true, result }, null, 2));
} finally {
  client.close();
}
