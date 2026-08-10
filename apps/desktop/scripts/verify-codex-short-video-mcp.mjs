import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import sharp from "sharp";
import {
  normalizeShortVideoAspectRatio,
  normalizeShortVideoAnchorCount,
  normalizeShortVideoDuration,
  normalizeShortVideoFormat,
  normalizeShortVideoFPS,
  normalizeShortVideoMotionMode,
  renderShortVideo,
  resolveShortVideoFFmpeg,
  validateMotionKeyframes
} from "../dist-electron/shortVideo.js";

const execFileAsync = promisify(execFile);
const bridge = await fs.promises.readFile(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");

assert.equal(
  [...bridge.matchAll(/name:\s*"oa_request_codex_short_video"/g)].length,
  1,
  "the short-video request tool must have exactly one public MCP schema"
);
assert.equal(
  [...bridge.matchAll(/name:\s*"oa_get_codex_short_video"/g)].length,
  1,
  "the short-video status tool must have exactly one public MCP schema"
);

const requestToolIndex = bridge.indexOf('name: "oa_request_codex_short_video"');
assert.ok(requestToolIndex >= 0, "Knowledge MCP must advertise the short-video request tool.");
const requestTool = bridge.slice(requestToolIndex, requestToolIndex + 7_000);
assert.match(requestTool, /required:\s*\["prompt"\]/);
assert.match(requestTool, /"mp4",\s*"gif"/);
assert.match(requestTool, /"9:16",\s*"1:1",\s*"16:9"/);
assert.match(requestTool, /"auto",\s*"generated_motion",\s*"ui_motion",\s*"camera_motion"/);
assert.match(requestTool, /motionDescription/);
assert.match(requestTool, /anchorCount/);
assert.match(requestTool, /camera/);
assert.match(requestTool, /loop/);
assert.match(requestTool, /referenceArtifactIds/);
assert.match(requestTool, /referenceImagePaths/);
assert.match(requestTool, /referenceImages/);
assert.match(requestTool, /useLatestImage/);

assert.match(bridge, /case "oa_request_codex_short_video":\s*\n\s*case "knowledge_request_codex_short_video":\s*\n\s*return startCodexShortVideoForExternalMCP\(args\)/);
assert.match(bridge, /case "oa_get_codex_short_video":\s*\n\s*case "knowledge_get_codex_short_video":\s*\n\s*return getCodexShortVideoForExternalMCP\(args\)/);
assert.match(bridge, /name !== "oa_request_codex_short_video"/);
assert.match(bridge, /const externalMCPShortVideoJobPromises = new Map/);
assert.match(bridge, /path\.join\(supportRoot\(\), "Knowledge", "Generated Videos"\)/);
assert.match(bridge, /path\.join\(supportRoot\(\), "Knowledge", "Short Video Jobs"\)/);
assert.match(bridge, /fs\.rmSync\(path\.join\(externalMCPGeneratedVideosDirectory\(\), "Keyframes", jobID\)/);
assert.match(bridge, /ephemeral:\s*true/);
assert.match(bridge, /serviceName:\s*"OpenAssist Codex Short Video Worker"/);
assert.match(bridge, /The subject or action pixels must genuinely change position or state/);
assert.match(bridge, /Do not fake motion by zooming, panning, cropping/);
assert.match(bridge, /Do not make a collage, storyboard, contact sheet, split screen, pet atlas, sprite sheet/);
assert.match(bridge, /Video request: \$\{options\.prompt\}/);
assert.match(bridge, /type:\s*"resource_link"/);
assert.match(bridge, /pathToFileURL\(resolved\.path\)/);

const simpleToolsIndex = bridge.indexOf("const simpleKnowledgeMCPToolNames");
const simpleTools = bridge.slice(simpleToolsIndex, simpleToolsIndex + 1_300);
assert.match(simpleTools, /oa_request_codex_short_video/);
assert.match(simpleTools, /oa_get_codex_short_video/);

assert.equal(normalizeShortVideoFormat("GIF"), "gif");
assert.equal(normalizeShortVideoAspectRatio("wide"), "16:9");
assert.equal(normalizeShortVideoDuration(50), 8);
assert.equal(normalizeShortVideoFPS(2), 8);
assert.equal(normalizeShortVideoAnchorCount(20), 8);
assert.equal(normalizeShortVideoMotionMode("generated-motion"), "generated_motion");
assert.equal(normalizeShortVideoMotionMode("animate_reference"), "camera_motion");

const temporaryDirectory = await fs.promises.mkdtemp(path.join(os.tmpdir(), "openassist-short-video-verify-"));
try {
  const sourcePath = new URL("../electron/helpers/short-video-helper.swift", import.meta.url).pathname;
  const helperPath = path.join(temporaryDirectory, "short-video-helper");
  const architecture = process.arch === "x64" ? "x86_64" : "arm64";
  await execFileAsync("/usr/bin/xcrun", [
    "swiftc",
    "-target", `${architecture}-apple-macos13.0`,
    "-framework", "AVFoundation",
    "-framework", "CoreGraphics",
    "-framework", "CoreVideo",
    "-framework", "ImageIO",
    "-framework", "UniformTypeIdentifiers",
    sourcePath,
    "-o", helperPath
  ], { timeout: 120_000 });

  const motionPaths = [];
  for (let index = 0; index < 3; index += 1) {
    const framePath = path.join(temporaryDirectory, `motion-${index}.png`);
    const square = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" rx="18" fill="#f2693d"/></svg>`);
    const orientationMarker = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="25"><rect width="100" height="25" fill="#ffd43b"/></svg>');
    await sharp({ create: { width: 320, height: 320, channels: 3, background: "#101820" } })
      .composite([
        { input: square, left: 30 + index * 70, top: 110 },
        { input: orientationMarker, left: 110, top: 10 }
      ])
      .png()
      .toFile(framePath);
    motionPaths.push(framePath);
  }
  const validation = await validateMotionKeyframes(motionPaths);
  assert.equal(validation.valid, true);
  assert.equal(validation.actualMotion, true);

  for (const format of ["mp4", "gif"]) {
    const outputPath = path.join(temporaryDirectory, `generic-ad.${format}`);
    const result = await renderShortVideo({
      imagePaths: motionPaths,
      outputPath,
      helperPath,
      format,
      aspectRatio: "9:16",
      durationSeconds: 2,
      fps: 8,
      motionMode: "generated_motion"
    });
    assert.equal(result.frameCount, 16);
    assert.equal(result.keyframeCount, 3);
    assert.equal(result.motionMode, "generated_motion");
    assert.equal(result.actualSubjectMotion, true);
    assert.equal(result.validationReport.valid, true);
    assert.ok(result.interpolatedFrameCount >= 12);
    assert.ok((await fs.promises.stat(outputPath)).size > 1_000);
    const header = await fs.promises.readFile(outputPath).then((buffer) => buffer.subarray(0, 12));
    if (format === "gif") assert.equal(header.subarray(0, 4).toString("ascii"), "GIF8");
    else {
      assert.equal(header.subarray(4, 8).toString("ascii"), "ftyp");
      const previewPath = path.join(temporaryDirectory, "mp4-orientation.png");
      const ffmpegPath = resolveShortVideoFFmpeg();
      assert.ok(ffmpegPath, "MP4 orientation verification requires the same FFmpeg used for interpolation.");
      await execFileAsync(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-i", outputPath,
        "-frames:v", "1",
        previewPath
      ], { timeout: 30_000 });
      const averageBrightness = async (top) => {
        const { data, info } = await sharp(previewPath)
          .extract({ left: 360, top, width: 360, height: 100 })
          .removeAlpha()
          .raw()
          .toBuffer({ resolveWithObject: true });
        let total = 0;
        for (let index = 0; index < data.length; index += info.channels) {
          total += data[index] + data[index + 1] + data[index + 2];
        }
        return total / Math.max(1, data.length / info.channels);
      };
      const topBrightness = await averageBrightness(25);
      const bottomBrightness = await averageBrightness(955);
      assert.ok(topBrightness > bottomBrightness + 100, "MP4 frames must keep the source image upright.");
    }
  }

  const uiOutputPath = path.join(temporaryDirectory, "ui-motion.mp4");
  const uiResult = await renderShortVideo({
    imagePaths: [motionPaths[0]],
    outputPath: uiOutputPath,
    helperPath,
    format: "mp4",
    aspectRatio: "16:9",
    durationSeconds: 2,
    fps: 8,
    motionMode: "ui_motion"
  });
  assert.equal(uiResult.motionMode, "ui_motion");
  assert.equal(uiResult.actualSubjectMotion, true);
  assert.equal(uiResult.interpolatedFrameCount, 0);

  const cameraOutputPath = path.join(temporaryDirectory, "camera-motion.mp4");
  const cameraResult = await renderShortVideo({
    imagePaths: [motionPaths[0]],
    outputPath: cameraOutputPath,
    helperPath,
    format: "mp4",
    aspectRatio: "1:1",
    durationSeconds: 2,
    fps: 8,
    motionMode: "camera_motion"
  });
  assert.equal(cameraResult.motionMode, "camera_motion");
  assert.equal(cameraResult.actualSubjectMotion, false);
} finally {
  await fs.promises.rm(temporaryDirectory, { recursive: true, force: true });
}

console.log("Codex generic short-video MCP and native encoder checks passed.");
