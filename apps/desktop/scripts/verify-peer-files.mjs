import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  PeerFileError,
  applyStagedPeerFile,
  classifyPeerFetchTarget,
  decodePeerFilePayload,
  peerFileExcluded,
  peerFileFetchMaxBytes,
  peerFileMatchScore,
  peerFileSafeRelativePath,
  peerFileSearchMaxDepth,
  peerFileSearchMaxResults,
  readPeerProjectFile,
  searchPeerProjectFiles,
  sha256OfBuffer,
  walkPeerProjectFiles
} from "../dist-electron/peerFilesCore.js";

const repositoryRoot = process.cwd();
const bridge = fs.readFileSync(path.join(repositoryRoot, "electron", "openassistBridge.ts"), "utf8");
const app = fs.readFileSync(path.join(repositoryRoot, "src", "App.tsx"), "utf8");
const types = fs.readFileSync(path.join(repositoryRoot, "src", "types.ts"), "utf8");

function includes(source, value, label) {
  assert.ok(source.includes(value), `${label}: expected ${value}`);
}

function extractBetween(source, startText, endText) {
  const start = source.indexOf(startText);
  assert.ok(start >= 0, `Missing start marker: ${startText}`);
  const end = source.indexOf(endText, start + startText.length);
  assert.ok(end > start, `Missing end marker: ${endText}`);
  return source.slice(start, end);
}

assert.equal(peerFileFetchMaxBytes, 25 * 1024 * 1024);
assert.equal(peerFileSearchMaxResults, 100);
assert.equal(peerFileSearchMaxDepth, 12);
assert.equal(peerFileSafeRelativePath("src\\index.ts"), "src/index.ts");
assert.equal(peerFileSafeRelativePath("./src/index.ts"), "src/index.ts");
for (const unsafePath of ["", "/absolute", "../outside", "a/../../outside", "a/../inside", "C:\\outside", "a\0b"]) {
  assert.equal(peerFileSafeRelativePath(unsafePath), "", `must reject ${JSON.stringify(unsafePath)}`);
}
for (const excludedPath of [
  ".env",
  ".ENV.local",
  "certs/x.PEM",
  ".ssh/id_rsa",
  "keys/ID_ED25519.pub",
  "node_modules/pkg/index.js",
  ".Git/config",
  ".DS_Store"
]) {
  assert.equal(peerFileExcluded(excludedPath), true, `must exclude ${excludedPath}`);
}
for (const allowedPath of ["src/index.ts", "env.example", ".ssh/config", "docs/public-key.txt"]) {
  assert.equal(peerFileExcluded(allowedPath), false, `must allow ${allowedPath}`);
}
assert.ok(peerFileMatchScore("docs/report.md", "report.md") > peerFileMatchScore("old/report.md.bak", "report.md"));
assert.ok(peerFileMatchScore("docs/annual-report.md", "annual report") > 0);
assert.equal(peerFileMatchScore("docs/report.md", "   "), 0);

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-peer-files-"));
process.on("exit", () => fs.rmSync(temporaryRoot, { recursive: true, force: true }));
const sourceRoot = path.join(temporaryRoot, "source");
const destinationRoot = path.join(temporaryRoot, "destination");
const outsideRoot = path.join(temporaryRoot, "outside");
fs.mkdirSync(path.join(sourceRoot, "docs"), { recursive: true, mode: 0o700 });
fs.mkdirSync(destinationRoot, { recursive: true, mode: 0o700 });
fs.mkdirSync(outsideRoot, { recursive: true, mode: 0o700 });
fs.writeFileSync(path.join(sourceRoot, "docs", "report.md"), "peer report\n");
fs.writeFileSync(path.join(sourceRoot, "docs", "annual-report.md"), "annual\n");
fs.writeFileSync(path.join(sourceRoot, ".env"), "SECRET=yes\n");
fs.mkdirSync(path.join(sourceRoot, "node_modules"));
fs.writeFileSync(path.join(sourceRoot, "node_modules", "hidden.js"), "hidden\n");
fs.writeFileSync(path.join(outsideRoot, "secret.txt"), "outside\n");
fs.symlinkSync(outsideRoot, path.join(sourceRoot, "linked-outside"));
fs.symlinkSync(path.join(outsideRoot, "secret.txt"), path.join(sourceRoot, "secret-link.txt"));

const walked = walkPeerProjectFiles(sourceRoot);
assert.ok(walked.files.some((file) => file.relativePath === "docs/report.md"));
assert.ok(!walked.files.some((file) => file.relativePath.includes("node_modules") || file.relativePath.includes(".env")));
assert.ok(!walked.files.some((file) => file.relativePath.includes("linked-outside") || file.relativePath === "secret-link.txt"));
const searched = searchPeerProjectFiles(sourceRoot, "report", 1);
assert.equal(searched.results.length, 1);
assert.equal(searched.results[0].relativePath, "docs/report.md");
assert.throws(() => searchPeerProjectFiles(sourceRoot, "   "), (error) => error instanceof PeerFileError && error.code === "invalid_query");
assert.throws(() => readPeerProjectFile(sourceRoot, "linked-outside/secret.txt"), (error) => error instanceof PeerFileError && error.code === "unsafe_symlink");
assert.throws(() => readPeerProjectFile(sourceRoot, "secret-link.txt"), (error) => error instanceof PeerFileError && error.code === "unsafe_symlink");
assert.throws(() => readPeerProjectFile(sourceRoot, ".env"), (error) => error instanceof PeerFileError && error.code === "excluded");

let deepDirectory = sourceRoot;
for (let depth = 0; depth < peerFileSearchMaxDepth + 2; depth += 1) {
  deepDirectory = path.join(deepDirectory, `depth-${depth}`);
  fs.mkdirSync(deepDirectory);
}
assert.equal(walkPeerProjectFiles(sourceRoot).truncated, true, "depth budget must report truncation");

const fetched = readPeerProjectFile(sourceRoot, "docs/report.md");
assert.equal(Buffer.from(fetched.contentBase64, "base64").toString("utf8"), "peer report\n");
assert.equal(fetched.sha256, sha256OfBuffer(Buffer.from("peer report\n")));
const decoded = decodePeerFilePayload(fetched, "docs/report.md");
assert.equal(decoded.buffer.toString("utf8"), "peer report\n");
assert.throws(() => decodePeerFilePayload({ ...fetched, size: fetched.size + 1 }, "docs/report.md"), /integrity check/);
assert.throws(() => decodePeerFilePayload({ ...fetched, contentBase64: "%%%" }, "docs/report.md"), /invalid file content/);
assert.throws(() => decodePeerFilePayload(fetched, "docs/other.md"), /unexpected relative path/);

const oversizedPath = path.join(sourceRoot, "oversized.bin");
fs.closeSync(fs.openSync(oversizedPath, "w"));
fs.truncateSync(oversizedPath, peerFileFetchMaxBytes + 1);
assert.throws(() => readPeerProjectFile(sourceRoot, "oversized.bin"), (error) => error instanceof PeerFileError && error.code === "too_large");

const stagedPath = path.join(temporaryRoot, "staged-report");
fs.writeFileSync(stagedPath, decoded.buffer, { mode: 0o600 });
const applied = applyStagedPeerFile(stagedPath, decoded.sha256, destinationRoot, "nested/report.md");
assert.equal(applied.overwrote, false);
assert.equal(fs.readFileSync(path.join(destinationRoot, "nested", "report.md"), "utf8"), "peer report\n");
assert.equal(fs.statSync(path.join(destinationRoot, "nested", "report.md")).mode & 0o777, 0o600);
assert.ok(!fs.readdirSync(path.join(destinationRoot, "nested")).some((name) => name.includes(".openassist-")));
assert.equal(classifyPeerFetchTarget(destinationRoot, "nested/report.md").overwrites, true);

fs.writeFileSync(stagedPath, "replacement\n", { mode: 0o600 });
const replacementHash = sha256OfBuffer(Buffer.from("replacement\n"));
assert.equal(applyStagedPeerFile(stagedPath, replacementHash, destinationRoot, "nested/report.md").overwrote, true);
assert.equal(fs.readFileSync(path.join(destinationRoot, "nested", "report.md"), "utf8"), "replacement\n");
assert.throws(() => applyStagedPeerFile(stagedPath, decoded.sha256, destinationRoot, "nested/report.md"), /changed after download/);
fs.rmSync(stagedPath);
assert.throws(() => applyStagedPeerFile(stagedPath, replacementHash, destinationRoot, "nested/report.md"), /no longer staged/);

fs.symlinkSync(outsideRoot, path.join(destinationRoot, "outside-link"));
assert.throws(() => classifyPeerFetchTarget(destinationRoot, "outside-link/new.txt"), (error) => error instanceof PeerFileError && error.code === "unsafe_symlink");
assert.throws(() => classifyPeerFetchTarget(destinationRoot, "../escape.txt"), (error) => error instanceof PeerFileError && error.code === "invalid_path");

includes(bridge, '"peer-files-v1"', "health capability");
includes(bridge, "Promise.allSettled(hints.map", "parallel peer search");
includes(bridge, "maxResponseBytes", "bounded peer responses");
includes(bridge, "request_peer_file_fetch", "peer fetch write request");
includes(bridge, 'kind: "peer_file_fetch"', "backend preview type");
includes(bridge, 'if (preview?.kind === "peer_file_fetch") return !preview.overwrites;', "new file auto-apply");
includes(bridge, 'name: "oa_peer_search_files"', "search tool");
includes(bridge, 'name: "oa_peer_fetch_file"', "fetch tool");
includes(bridge, '"oa_peer_search_files",', "advanced search tool");
includes(bridge, '"oa_peer_fetch_file",', "advanced fetch tool");
includes(bridge, "Peer Mac file access for projectID", "agent peer instructions");
includes(bridge, 'path.join(knowledgeRoot(), "peer-file-staging")', "private staging folder");

const searchRoute = extractBetween(bridge, 'url.pathname === "/remote/v1/files/search"', 'url.pathname === "/remote/v1/files/fetch"');
includes(searchRoute, 'device.kind !== "peer-mac"', "search peer-only gate");
includes(searchRoute, "sharedWithRequester", "search project gate");
const fetchRoute = extractBetween(bridge, 'url.pathname === "/remote/v1/files/fetch"', 'url.pathname === "/remote/v1/actions"');
includes(fetchRoute, 'device.kind !== "peer-mac"', "fetch peer-only gate");
includes(fetchRoute, "sharedWithRequester", "fetch project gate");

includes(types, 'kind: "peer_file_fetch"', "renderer preview type");
includes(app, 'preview.kind === "peer_file_fetch"', "Review Inbox peer preview");
includes(app, "This will replace the existing local file.", "overwrite warning");

console.log("Peer files verification passed.");
