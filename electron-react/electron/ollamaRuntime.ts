import { execFile, execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const RUNTIME_HEALTH_URL = "http://127.0.0.1:11434/api/tags";
const RUNTIME_VERSION_URL = "http://127.0.0.1:11434/api/version";
const GITHUB_LATEST_RELEASE_URL = "https://api.github.com/repos/ollama/ollama/releases/latest";
const MANAGED_RUNTIME_ARCHIVE_URL = "https://ollama.com/download/Ollama-darwin.zip";
export const OLLAMA_DOWNLOAD_URL = "https://ollama.com/download";

export type OllamaInstallKind =
  | "homebrew-formula"
  | "homebrew-cask"
  | "native-app"
  | "managed"
  | "unknown"
  | "none";

export type OllamaRuntimeStatus = {
  installed: boolean;
  isHealthy: boolean;
  installKind: OllamaInstallKind;
  installLabel: string;
  currentVersion?: string;
  latestVersion?: string;
  updateAvailable: boolean;
  canAutoUpdate: boolean;
  updateActionLabel: string;
  updateCheckError?: string;
  statusMessage: string;
  installMessage?: string;
  downloadURL: string;
};

export type OllamaRuntimeUpdateProgress = {
  status: string;
  error?: string;
  done?: boolean;
};

type OllamaRuntimeDetection = {
  installed: boolean;
  isHealthy: boolean;
  installKind: OllamaInstallKind;
  installLabel: string;
  appPath?: string;
  cliPath?: string;
  brewPath?: string;
  currentVersion?: string;
};

type LatestOllamaRelease = {
  version: string;
  darwinZipURL?: string;
  darwinDmgURL?: string;
};

let latestReleaseCache: { expiresAt: number; value: LatestOllamaRelease | null; error?: string } | null = null;

function managedRuntimeAppPath(): string {
  return path.join(os.homedir(), "Library", "Application Support", "OpenAssist", "LocalAI", "Ollama.app");
}

function runtimeAppCandidates(): string[] {
  return [
    managedRuntimeAppPath(),
    "/Applications/Ollama.app",
    path.join(os.homedir(), "Applications", "Ollama.app")
  ];
}

function brewExecutableCandidates(): string[] {
  return ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"];
}

function installLabelForKind(kind: OllamaInstallKind): string {
  switch (kind) {
    case "homebrew-formula":
      return "Homebrew CLI";
    case "homebrew-cask":
      return "Homebrew app";
    case "native-app":
      return "Ollama.app";
    case "managed":
      return "OpenAssist-managed";
    case "unknown":
      return "Unknown install";
    default:
      return "Not installed";
  }
}

function updateActionLabelForKind(kind: OllamaInstallKind): string {
  switch (kind) {
    case "homebrew-formula":
    case "homebrew-cask":
      return "Update with Homebrew";
    case "native-app":
      return "Update Ollama.app";
    case "managed":
      return "Update managed Ollama";
    default:
      return "Open installer";
  }
}

export function parseOllamaVersion(raw: string | null | undefined): string | null {
  if (!raw?.trim()) return null;
  const match = raw.match(/(\d+\.\d+\.\d+)/);
  return match?.[1] ?? null;
}

export function compareVersions(left: string, right: string): number {
  const leftParts = left.split(".").map((part) => Number.parseInt(part, 10) || 0);
  const rightParts = right.split(".").map((part) => Number.parseInt(part, 10) || 0);
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const diff = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
    if (diff !== 0) return diff > 0 ? 1 : -1;
  }
  return 0;
}

export function isOllamaVersionUpgradeError(message: string): boolean {
  const normalized = message.toLowerCase();
  return normalized.includes("requires a newer version of ollama")
    || normalized.includes("pull model manifest: 412")
    || normalized.includes("manifest: 412");
}

export function classifyOllamaCliPath(cliPath: string | null | undefined): OllamaInstallKind {
  const normalized = cliPath?.trim();
  if (!normalized) return "unknown";
  const resolved = path.resolve(normalized);
  if (resolved.includes(`${path.sep}Cellar${path.sep}ollama${path.sep}`)) {
    return "homebrew-formula";
  }
  if (resolved.includes("Ollama.app")) {
    if (resolved.startsWith(path.resolve(managedRuntimeAppPath()))) return "managed";
    return "native-app";
  }
  return "unknown";
}

export function classifyRunningCommand(command: string | null | undefined): OllamaInstallKind {
  const normalized = command?.trim();
  if (!normalized) return "unknown";
  if (normalized.includes(`${path.sep}Cellar${path.sep}ollama${path.sep}`)) return "homebrew-formula";
  if (normalized.includes(managedRuntimeAppPath())) return "managed";
  if (normalized.includes("Ollama.app")) return "native-app";
  if (/\/opt\/homebrew\/bin\/ollama\b/.test(normalized) || /\/usr\/local\/bin\/ollama\b/.test(normalized)) {
    return "homebrew-formula";
  }
  return "unknown";
}

function resolveBrewExecutable(): string | null {
  for (const candidate of brewExecutableCandidates()) {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      continue;
    }
  }
  return null;
}

function detectBrewOllama(): { brewPath?: string; installKind?: "homebrew-formula" | "homebrew-cask" } {
  const brewPath = resolveBrewExecutable();
  if (!brewPath) return {};
  try {
    execFileSync(brewPath, ["list", "--formula", "ollama"], {
      encoding: "utf8",
      stdio: ["ignore", "ignore", "ignore"]
    });
    return { brewPath, installKind: "homebrew-formula" };
  } catch {
    // fall through
  }
  try {
    execFileSync(brewPath, ["list", "--cask", "ollama"], {
      encoding: "utf8",
      stdio: ["ignore", "ignore", "ignore"]
    });
    return { brewPath, installKind: "homebrew-cask" };
  } catch {
    return {};
  }
}

function resolveOllamaCliPath(): string | null {
  try {
    const output = execFileSync("/usr/bin/which", ["ollama"], { encoding: "utf8", timeout: 5000 }).trim();
    return output || null;
  } catch {
    return null;
  }
}

function findRuntimeAppPath(): string | null {
  for (const candidate of runtimeAppCandidates()) {
    try {
      if (fs.statSync(candidate).isDirectory()) return candidate;
    } catch {
      continue;
    }
  }
  return null;
}

async function findListeningOllamaCommand(): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync("/usr/sbin/lsof", ["-nP", "-iTCP:11434", "-sTCP:LISTEN", "-F", "pcn"], {
      maxBuffer: 1_000_000
    });
    const lines = stdout.split(/\r?\n/);
    let command = "";
    for (const line of lines) {
      if (line.startsWith("p")) command = "";
      if (line.startsWith("c")) command = line.slice(1).trim();
      if (line.startsWith("n") && command.toLowerCase().includes("ollama")) return command;
    }
    return command || null;
  } catch {
    return null;
  }
}

function resolveInstallKind(
  runningCommand: string | null,
  cliPath: string | null,
  brewInstallKind: "homebrew-formula" | "homebrew-cask" | undefined,
  appPath: string | null
): OllamaInstallKind {
  const runningKind = classifyRunningCommand(runningCommand);
  if (runningKind !== "unknown") return runningKind;

  if (brewInstallKind) return brewInstallKind;

  const cliKind = classifyOllamaCliPath(cliPath);
  if (cliKind !== "unknown") return cliKind;

  if (appPath) {
    if (path.resolve(appPath) === path.resolve(managedRuntimeAppPath())) return "managed";
    return "native-app";
  }

  return "unknown";
}

async function healthCheck(): Promise<boolean> {
  try {
    const response = await fetch(RUNTIME_HEALTH_URL, {
      method: "GET",
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(3000)
    });
    return response.ok;
  } catch {
    return false;
  }
}

async function fetchApiVersion(): Promise<string | null> {
  try {
    const response = await fetch(RUNTIME_VERSION_URL, {
      method: "GET",
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(3000)
    });
    if (!response.ok) return null;
    const payload = await response.json() as { version?: string };
    return parseOllamaVersion(payload.version);
  } catch {
    return null;
  }
}

function runPathVersion(): string | null {
  try {
    const output = execFileSync("ollama", ["--version"], {
      encoding: "utf8",
      timeout: 5000
    });
    return parseOllamaVersion(output);
  } catch {
    return null;
  }
}

export async function detectOllamaRuntime(): Promise<OllamaRuntimeDetection> {
  const [isHealthy, runningCommand, brewInfo] = await Promise.all([
    healthCheck(),
    findListeningOllamaCommand(),
    Promise.resolve(detectBrewOllama())
  ]);
  const cliPath = resolveOllamaCliPath();
  const appPath = findRuntimeAppPath();
  const installKind = resolveInstallKind(runningCommand, cliPath, brewInfo.installKind, appPath);
  const runningVersion = isHealthy ? await fetchApiVersion() : null;
  const cliVersion = runPathVersion();
  const currentVersion = runningVersion || cliVersion || undefined;
  const installed = installKind !== "none" && Boolean(appPath || cliPath || currentVersion || isHealthy || brewInfo.installKind);

  if (!installed) {
    return {
      installed: false,
      isHealthy: false,
      installKind: "none",
      installLabel: installLabelForKind("none")
    };
  }

  return {
    installed: true,
    isHealthy,
    installKind,
    installLabel: installLabelForKind(installKind),
    appPath: appPath ?? undefined,
    cliPath: cliPath ?? undefined,
    brewPath: brewInfo.brewPath,
    currentVersion
  };
}

async function fetchLatestOllamaRelease(): Promise<LatestOllamaRelease | null> {
  const now = Date.now();
  if (latestReleaseCache && latestReleaseCache.expiresAt > now) {
    if (latestReleaseCache.error) throw new Error(latestReleaseCache.error);
    return latestReleaseCache.value;
  }

  try {
    const response = await fetch(GITHUB_LATEST_RELEASE_URL, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "OpenAssist"
      },
      signal: AbortSignal.timeout(12_000)
    });
    if (!response.ok) {
      throw new Error(`Could not check latest Ollama release (HTTP ${response.status}).`);
    }
    const payload = await response.json() as {
      tag_name?: string;
      assets?: Array<{ name?: string; browser_download_url?: string }>;
    };
    const version = parseOllamaVersion(payload.tag_name);
    if (!version) {
      throw new Error("Latest Ollama release did not include a version number.");
    }
    const assets = Array.isArray(payload.assets) ? payload.assets : [];
    const value = {
      version,
      darwinZipURL: assets.find((asset) => asset.name === "Ollama-darwin.zip")?.browser_download_url,
      darwinDmgURL: assets.find((asset) => asset.name === "Ollama.dmg")?.browser_download_url
    };
    latestReleaseCache = { expiresAt: now + 60 * 60_000, value };
    return value;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not check latest Ollama release.";
    latestReleaseCache = { expiresAt: now + 5 * 60_000, value: null, error: message };
    throw new Error(message);
  }
}

function buildInstallMessage(
  detection: OllamaRuntimeDetection,
  latestVersion: string
): string {
  const current = detection.currentVersion || "your installed version";
  const via = detection.installLabel;
  switch (detection.installKind) {
    case "homebrew-formula":
    case "homebrew-cask":
      return `Ollama ${current} (${via}) is too old for newer models. Click Update with Homebrew to install ${latestVersion}, then retry the model download.`;
    case "native-app":
    case "managed":
      return `Ollama ${current} (${via}) is too old for newer models. Click ${updateActionLabelForKind(detection.installKind)} to install ${latestVersion}, then retry the model download.`;
    default:
      return `Ollama ${current} is too old for newer models. Install Ollama ${latestVersion} from ollama.com, then quit and reopen Ollama.`;
  }
}

function buildStatusMessage(
  detection: OllamaRuntimeDetection,
  latestVersion?: string,
  updateAvailable = false,
  updateCheckError?: string
): { statusMessage: string; installMessage?: string } {
  if (updateCheckError) {
    return { statusMessage: updateCheckError };
  }
  if (!detection.installed) {
    return {
      statusMessage: latestVersion
        ? `Ollama is not installed. Latest release is ${latestVersion}.`
        : "Ollama is not installed.",
      installMessage: latestVersion
        ? `Install Ollama ${latestVersion} to use local models.`
        : "Install Ollama to use local models."
    };
  }
  if (!detection.currentVersion) {
    return {
      statusMessage: detection.isHealthy
        ? `Ollama is running (${detection.installLabel}), but its version could not be detected.`
        : `Ollama is installed (${detection.installLabel}), but the local runtime is not reachable.`
    };
  }
  if (updateAvailable && latestVersion) {
    return {
      statusMessage: `Ollama ${detection.currentVersion} is running via ${detection.installLabel}. Latest release is ${latestVersion}.`,
      installMessage: buildInstallMessage(detection, latestVersion)
    };
  }
  if (!detection.isHealthy) {
    return {
      statusMessage: `Ollama ${detection.currentVersion} (${detection.installLabel}) is installed, but the local runtime is not reachable.`
    };
  }
  return {
    statusMessage: `Ollama ${detection.currentVersion} (${detection.installLabel}) is up to date.`
  };
}

function canAutoUpdateForKind(kind: OllamaInstallKind): boolean {
  return kind === "homebrew-formula"
    || kind === "homebrew-cask"
    || kind === "native-app"
    || kind === "managed";
}

export async function getOllamaRuntimeStatus(): Promise<OllamaRuntimeStatus> {
  const detection = await detectOllamaRuntime();
  let latestVersion: string | undefined;
  let updateCheckError: string | undefined;
  try {
    const release = await fetchLatestOllamaRelease();
    latestVersion = release?.version;
  } catch (error) {
    updateCheckError = error instanceof Error ? error.message : "Could not check for Ollama updates.";
  }

  const updateAvailable = Boolean(
    detection.currentVersion
    && latestVersion
    && compareVersions(detection.currentVersion, latestVersion) < 0
  );
  const messaging = buildStatusMessage(detection, latestVersion, updateAvailable, updateCheckError);

  return {
    installed: detection.installed,
    isHealthy: detection.isHealthy,
    installKind: detection.installKind,
    installLabel: detection.installLabel,
    currentVersion: detection.currentVersion,
    latestVersion,
    updateAvailable,
    canAutoUpdate: canAutoUpdateForKind(detection.installKind),
    updateActionLabel: updateActionLabelForKind(detection.installKind),
    updateCheckError,
    statusMessage: messaging.statusMessage,
    installMessage: messaging.installMessage,
    downloadURL: OLLAMA_DOWNLOAD_URL
  };
}

async function stopRunningOllama(): Promise<void> {
  try {
    await execFileAsync("/usr/bin/osascript", ["-e", 'tell application "Ollama" to quit'], { timeout: 5000 });
  } catch {
    // ignore
  }
  try {
    await execFileAsync("/usr/bin/pkill", ["-x", "ollama"], { timeout: 5000 });
  } catch {
    // ignore when no process exists
  }
  await new Promise((resolve) => setTimeout(resolve, 800));
}

async function waitForHealthyOllama(timeoutMs = 30_000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await healthCheck()) return true;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return false;
}

async function startOllamaServe(cliPath?: string): Promise<void> {
  const executable = cliPath && fs.existsSync(cliPath) ? cliPath : "ollama";
  const child = spawn(executable, ["serve"], {
    detached: true,
    stdio: "ignore",
    env: { ...process.env, OLLAMA_HOST: "127.0.0.1:11434" }
  });
  child.unref();
}

export async function startOllamaRuntime(): Promise<{ ok: boolean; status: OllamaRuntimeStatus }> {
  const detection = await detectOllamaRuntime();
  if (!detection.installed) {
    throw new Error("Ollama is not installed. Install Ollama to use local models.");
  }
  if (detection.isHealthy) {
    return { ok: true, status: await getOllamaRuntimeStatus() };
  }

  if (detection.appPath || detection.installKind === "native-app" || detection.installKind === "managed" || detection.installKind === "homebrew-cask") {
    await openOllamaApplication(detection.appPath);
  } else {
    await startOllamaServe(detection.cliPath);
  }

  const healthy = await waitForHealthyOllama();
  if (!healthy) {
    throw new Error("Ollama was started, but the local server did not become reachable. Open Ollama manually or run `ollama serve`, then check again.");
  }
  return { ok: true, status: await getOllamaRuntimeStatus() };
}

async function openOllamaApplication(appPath?: string): Promise<void> {
  const target = appPath && fs.existsSync(appPath) ? appPath : "/Applications/Ollama.app";
  if (fs.existsSync(target)) {
    await execFileAsync("/usr/bin/open", ["-a", target], { timeout: 10_000 });
    return;
  }
  await execFileAsync("/usr/bin/open", ["-a", "Ollama"], { timeout: 10_000 });
}

export async function stopOllamaRuntime(): Promise<{ ok: boolean; status: OllamaRuntimeStatus }> {
  await stopRunningOllama();
  const stopped = !(await healthCheck());
  const status = await getOllamaRuntimeStatus();
  if (!stopped) {
    throw new Error("Tried to stop Ollama, but the local server is still reachable. Quit Ollama from the menu bar or stop any Homebrew service, then check again.");
  }
  return { ok: true, status };
}

async function unzipArchive(zipPath: string, destinationPath: string): Promise<void> {
  await execFileAsync("/usr/bin/unzip", ["-o", zipPath, "-d", destinationPath], { maxBuffer: 4_000_000 });
}

function findAppUnder(rootPath: string, appName: string): string | null {
  const queue = [rootPath];
  while (queue.length) {
    const current = queue.shift();
    if (!current) continue;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === appName) return entryPath;
        queue.push(entryPath);
      }
    }
  }
  return null;
}

async function replaceAppBundle(destinationPath: string, sourcePath: string): Promise<void> {
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
  if (fs.existsSync(destinationPath)) {
    fs.rmSync(destinationPath, { recursive: true, force: true });
  }
  await execFileAsync("/usr/bin/ditto", [sourcePath, destinationPath], { maxBuffer: 4_000_000 });
}

async function installAppFromArchive(
  destinationPath: string,
  archiveURL: string,
  onProgress?: (progress: OllamaRuntimeUpdateProgress) => void
): Promise<void> {
  const emit = (status: string) => onProgress?.({ status });
  const tempZipPath = path.join(os.tmpdir(), `openassist-ollama-${Date.now()}.zip`);
  const extractionRoot = path.join(os.tmpdir(), `openassist-ollama-runtime-${Date.now()}`);

  try {
    emit("Downloading latest Ollama for macOS...");
    const response = await fetch(archiveURL, { signal: AbortSignal.timeout(20 * 60_000) });
    if (!response.ok) {
      throw new Error(`Ollama download failed with HTTP ${response.status}.`);
    }
    fs.writeFileSync(tempZipPath, Buffer.from(await response.arrayBuffer()));

    emit("Unpacking Ollama...");
    fs.mkdirSync(extractionRoot, { recursive: true });
    await unzipArchive(tempZipPath, extractionRoot);

    const extractedApp = findAppUnder(extractionRoot, "Ollama.app");
    if (!extractedApp) {
      throw new Error("Downloaded Ollama package did not contain Ollama.app.");
    }

    emit("Installing updated Ollama...");
    await stopRunningOllama();
    await replaceAppBundle(destinationPath, extractedApp);
  } finally {
    try { fs.rmSync(tempZipPath, { force: true }); } catch { /* ignore */ }
    try { fs.rmSync(extractionRoot, { recursive: true, force: true }); } catch { /* ignore */ }
  }
}

async function upgradeHomebrewOllama(
  detection: OllamaRuntimeDetection,
  onProgress?: (progress: OllamaRuntimeUpdateProgress) => void
): Promise<void> {
  const brewPath = detection.brewPath || resolveBrewExecutable();
  if (!brewPath) {
    throw new Error("Homebrew was not found. Install Homebrew or update Ollama manually from ollama.com.");
  }

  const emit = (status: string) => onProgress?.({ status });
  emit("Stopping the running Ollama server...");
  await stopRunningOllama();

  emit("Updating Ollama with Homebrew...");
  if (detection.installKind === "homebrew-cask") {
    await execFileAsync(brewPath, ["upgrade", "--cask", "ollama"], {
      maxBuffer: 8_000_000,
      timeout: 20 * 60_000
    });
  } else {
    await execFileAsync(brewPath, ["upgrade", "ollama"], {
      maxBuffer: 8_000_000,
      timeout: 20 * 60_000
    });
  }

  emit("Restarting Ollama...");
  try {
    await execFileAsync(brewPath, ["services", "restart", "ollama"], { timeout: 60_000 });
  } catch {
    if (detection.appPath || detection.installKind === "homebrew-cask") {
      await openOllamaApplication(detection.appPath);
    } else {
      await startOllamaServe(detection.cliPath);
    }
  }

  const healthy = await waitForHealthyOllama();
  if (!healthy) {
    throw new Error("Homebrew updated Ollama, but the local runtime did not come back online. Quit and reopen Ollama, then click Check version.");
  }
}

async function upgradeAppBundle(
  detection: OllamaRuntimeDetection,
  archiveURL: string,
  onProgress?: (progress: OllamaRuntimeUpdateProgress) => void
): Promise<void> {
  const destinationPath = detection.appPath
    || (detection.installKind === "managed" ? managedRuntimeAppPath() : "/Applications/Ollama.app");

  try {
    await installAppFromArchive(destinationPath, archiveURL, onProgress);
    onProgress?.({ status: "Launching updated Ollama..." });
    await openOllamaApplication(destinationPath);
  } catch (error) {
    const release = await fetchLatestOllamaRelease();
    const dmgURL = release?.darwinDmgURL || OLLAMA_DOWNLOAD_URL;
    onProgress?.({ status: `Could not replace ${destinationPath}. Opening the installer instead...` });
    await execFileAsync("/usr/bin/open", [dmgURL], { timeout: 10_000 });
    throw error instanceof Error
      ? new Error(`${error.message} Opened the Ollama installer so you can finish the update manually.`)
      : new Error("Could not update Ollama automatically. Opened the installer instead.");
  }

  const healthy = await waitForHealthyOllama();
  if (!healthy) {
    throw new Error("Ollama was updated, but the local runtime did not come back online. Open Ollama from Applications, then click Check version.");
  }
}

export async function updateOllamaRuntime(
  onProgress?: (progress: OllamaRuntimeUpdateProgress) => void
): Promise<{ ok: boolean; status: OllamaRuntimeStatus; openedExternal?: boolean }> {
  latestReleaseCache = null;
  const detection = await detectOllamaRuntime();
  const release = await fetchLatestOllamaRelease();
  const archiveURL = release?.darwinZipURL || MANAGED_RUNTIME_ARCHIVE_URL;

  try {
    switch (detection.installKind) {
      case "homebrew-formula":
      case "homebrew-cask":
        await upgradeHomebrewOllama(detection, onProgress);
        break;
      case "native-app":
      case "managed":
        await upgradeAppBundle(detection, archiveURL, onProgress);
        break;
      default:
        onProgress?.({ status: "Opening the Ollama installer..." });
        await execFileAsync("/usr/bin/open", [release?.darwinDmgURL || OLLAMA_DOWNLOAD_URL], { timeout: 10_000 });
        onProgress?.({
          status: "Opened the Ollama installer. Finish installing it, then quit and reopen Ollama.",
          done: true
        });
        return {
          ok: true,
          openedExternal: true,
          status: await getOllamaRuntimeStatus()
        };
    }

    const status = await getOllamaRuntimeStatus();
    if (status.currentVersion && release?.version && compareVersions(status.currentVersion, release.version) < 0) {
      throw new Error(`Ollama is still on ${status.currentVersion} after the update attempt. Quit and reopen Ollama, then click Check version.`);
    }
    onProgress?.({ status: status.statusMessage, done: true });
    return { ok: true, status };
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not update Ollama.";
    onProgress?.({ status: message, error: message, done: true });
    throw new Error(message);
  }
}

export function formatOllamaUpgradeHint(errorMessage: string, latestVersion?: string): string {
  if (!isOllamaVersionUpgradeError(errorMessage)) return errorMessage;
  const latest = latestVersion ? ` Install Ollama ${latestVersion}` : " Install the latest Ollama";
  return `${errorMessage}${latest} using Update with Homebrew or Update Ollama.app in Settings → Models & Connections.`;
}
