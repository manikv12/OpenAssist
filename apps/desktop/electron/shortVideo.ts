import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import sharp from "sharp";

const execFileAsync = promisify(execFile);

export type ShortVideoFormat = "mp4" | "gif";
export type ShortVideoAspectRatio = "9:16" | "1:1" | "16:9";
export type ShortVideoMotionMode = "generated_motion" | "ui_motion" | "camera_motion";

export type MotionValidationPair = {
  fromIndex: number;
  toIndex: number;
  difference: number;
  status: "ok" | "duplicate" | "scene_drift";
};

export type MotionValidationReport = {
  valid: boolean;
  actualMotion: boolean;
  pairs: MotionValidationPair[];
};

export type RenderShortVideoRequest = {
  imagePaths: string[];
  outputPath: string;
  helperPath: string;
  format: ShortVideoFormat;
  aspectRatio: ShortVideoAspectRatio;
  durationSeconds: number;
  fps: number;
  motionMode?: ShortVideoMotionMode;
  loop?: boolean;
  ffmpegPath?: string;
  onProgress?: (message: string) => void;
};

export type RenderShortVideoResult = {
  outputPath: string;
  format: ShortVideoFormat;
  width: number;
  height: number;
  durationSeconds: number;
  fps: number;
  frameCount: number;
  keyframeCount: number;
  interpolatedFrameCount: number;
  motionMode: ShortVideoMotionMode;
  actualSubjectMotion: boolean;
  validationReport: MotionValidationReport;
};

const dimensionsByAspectRatio: Record<ShortVideoAspectRatio, { width: number; height: number }> = {
  "9:16": { width: 720, height: 1280 },
  "1:1": { width: 1080, height: 1080 },
  "16:9": { width: 1280, height: 720 }
};

export function normalizeShortVideoFormat(value: unknown): ShortVideoFormat {
  return String(value ?? "").trim().toLowerCase() === "gif" ? "gif" : "mp4";
}

export function normalizeShortVideoAspectRatio(value: unknown): ShortVideoAspectRatio {
  const normalized = String(value ?? "").trim().toLowerCase().replace(/\s+/g, "");
  if (["1:1", "square"].includes(normalized)) return "1:1";
  if (["16:9", "landscape", "wide"].includes(normalized)) return "16:9";
  return "9:16";
}

export function normalizeShortVideoMotionMode(value: unknown): ShortVideoMotionMode {
  const normalized = String(value ?? "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (normalized === "ui_motion") return "ui_motion";
  if (normalized === "camera_motion" || normalized === "animate_reference") return "camera_motion";
  return "generated_motion";
}

export function shortVideoDimensions(aspectRatio: ShortVideoAspectRatio) {
  return dimensionsByAspectRatio[aspectRatio];
}

function clampNumber(value: unknown, minimum: number, maximum: number, fallback: number) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(minimum, Math.min(maximum, parsed));
}

export function normalizeShortVideoDuration(value: unknown) {
  return clampNumber(value, 2, 8, 3);
}

export function normalizeShortVideoFPS(value: unknown) {
  return Math.round(clampNumber(value, 8, 24, 24));
}

export function normalizeShortVideoAnchorCount(value: unknown) {
  return Math.round(clampNumber(value, 3, 8, 5));
}

function centeredCropPosition(frameIndex: number, frameCount: number, width: number, height: number, scale: number) {
  const progress = frameCount <= 1 ? 0 : frameIndex / (frameCount - 1);
  const scaledWidth = Math.ceil(width * scale);
  const scaledHeight = Math.ceil(height * scale);
  const horizontalRoom = Math.max(0, scaledWidth - width);
  const verticalRoom = Math.max(0, scaledHeight - height);
  return {
    scaledWidth,
    scaledHeight,
    left: Math.round(horizontalRoom * (0.35 + progress * 0.3)),
    top: Math.round(verticalRoom * (0.58 - progress * 0.16))
  };
}

async function renderedCameraFrame(
  imagePath: string,
  width: number,
  height: number,
  localFrameIndex: number,
  localFrameCount: number
) {
  const progress = localFrameCount <= 1 ? 0 : localFrameIndex / (localFrameCount - 1);
  const scale = 1.035 + progress * 0.055;
  const crop = centeredCropPosition(localFrameIndex, localFrameCount, width, height, scale);
  return sharp(imagePath, { limitInputPixels: false })
    .rotate()
    .resize(crop.scaledWidth, crop.scaledHeight, { fit: "cover", position: "centre" })
    .extract({ left: crop.left, top: crop.top, width, height })
    .removeAlpha()
    .png()
    .toBuffer();
}

async function normalizedFrame(imagePath: string, width: number, height: number) {
  return sharp(imagePath, { limitInputPixels: false })
    .rotate()
    .resize(width, height, { fit: "cover", position: "centre" })
    .removeAlpha()
    .png()
    .toBuffer();
}

async function withOpacity(buffer: Buffer, opacity: number) {
  const { data, info } = await sharp(buffer, { limitInputPixels: false })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const alpha = Math.max(0, Math.min(255, Math.round(opacity * 255)));
  for (let index = 3; index < data.length; index += info.channels) data[index] = alpha;
  return sharp(data, { raw: info }).png().toBuffer();
}

async function frameDifference(leftPath: string, rightPath: string) {
  const [left, right] = await Promise.all([
    sharp(leftPath, { limitInputPixels: false }).resize(64, 64, { fit: "fill" }).grayscale().raw().toBuffer(),
    sharp(rightPath, { limitInputPixels: false }).resize(64, 64, { fit: "fill" }).grayscale().raw().toBuffer()
  ]);
  let total = 0;
  for (let index = 0; index < left.length; index += 1) {
    total += Math.abs(left[index] - right[index]);
  }
  return total / Math.max(1, left.length * 255);
}

export async function validateMotionKeyframes(imagePaths: string[]): Promise<MotionValidationReport> {
  const pairs: MotionValidationPair[] = [];
  for (let index = 1; index < imagePaths.length; index += 1) {
    const difference = await frameDifference(imagePaths[index - 1], imagePaths[index]);
    const status: MotionValidationPair["status"] = difference < 0.008
      ? "duplicate"
      : difference > 0.65
        ? "scene_drift"
        : "ok";
    pairs.push({
      fromIndex: index - 1,
      toIndex: index,
      difference: Number(difference.toFixed(4)),
      status
    });
  }
  return {
    valid: pairs.length > 0 && pairs.every((pair) => pair.status === "ok"),
    actualMotion: pairs.length > 0 && pairs.every((pair) => pair.difference >= 0.008),
    pairs
  };
}

async function writeCameraMotionFrames(options: {
  imagePaths: string[];
  framesDirectory: string;
  width: number;
  height: number;
  frameCount: number;
  onProgress?: (message: string) => void;
}) {
  const { imagePaths, framesDirectory, width, height, frameCount, onProgress } = options;
  fs.mkdirSync(framesDirectory, { recursive: true });
  const sceneCount = imagePaths.length;
  const framesPerScene = Math.ceil(frameCount / sceneCount);
  const transitionStart = 0.78;

  for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
    const sceneIndex = Math.min(sceneCount - 1, Math.floor(frameIndex / framesPerScene));
    const sceneStart = sceneIndex * framesPerScene;
    const localFrameIndex = frameIndex - sceneStart;
    const localFrameCount = Math.min(framesPerScene, frameCount - sceneStart);
    const localProgress = localFrameCount <= 1 ? 0 : localFrameIndex / (localFrameCount - 1);
    let frame = await renderedCameraFrame(imagePaths[sceneIndex], width, height, localFrameIndex, localFrameCount);

    if (sceneIndex < sceneCount - 1 && localProgress > transitionStart) {
      const opacity = (localProgress - transitionStart) / (1 - transitionStart);
      const next = await renderedCameraFrame(
        imagePaths[sceneIndex + 1],
        width,
        height,
        Math.max(0, Math.round(opacity * Math.max(1, localFrameCount - 1))),
        localFrameCount
      );
      const overlay = await withOpacity(next, opacity);
      frame = await sharp(frame).composite([{ input: overlay, blend: "over" }]).png().toBuffer();
    }

    const fileName = `${String(frameIndex).padStart(5, "0")}.png`;
    fs.writeFileSync(path.join(framesDirectory, fileName), frame);
    if (frameIndex === 0 || frameIndex === frameCount - 1 || frameIndex % Math.max(1, Math.round(frameCount / 4)) === 0) {
      onProgress?.(`Rendering camera-motion frames (${frameIndex + 1}/${frameCount}).`);
    }
  }
}

function cursorSVG(size: number) {
  return Buffer.from([
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 64 64">`,
    '<path d="M8 5 L8 49 L20 38 L29 58 L39 53 L30 34 L47 33 Z" fill="#ffffff" stroke="#111111" stroke-width="4" stroke-linejoin="round"/>',
    "</svg>"
  ].join(""));
}

function clickPulseSVG(size: number, opacity: number) {
  const stroke = Math.max(2, Math.round(size * 0.06));
  return Buffer.from([
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">`,
    `<circle cx="${size / 2}" cy="${size / 2}" r="${Math.max(1, size / 2 - stroke)}" fill="none" stroke="#33d6c7" stroke-width="${stroke}" opacity="${opacity.toFixed(3)}"/>`,
    "</svg>"
  ].join(""));
}

function easeInOut(value: number) {
  return value < 0.5 ? 2 * value * value : 1 - Math.pow(-2 * value + 2, 2) / 2;
}

async function writeUIMotionFrames(options: {
  imagePaths: string[];
  framesDirectory: string;
  width: number;
  height: number;
  frameCount: number;
  loop: boolean;
  onProgress?: (message: string) => void;
}) {
  const { imagePaths, framesDirectory, width, height, frameCount, loop, onProgress } = options;
  fs.mkdirSync(framesDirectory, { recursive: true });
  const normalized = await Promise.all(imagePaths.map((imagePath) => normalizedFrame(imagePath, width, height)));
  const cursorSize = Math.max(38, Math.round(Math.min(width, height) * 0.065));
  const cursor = cursorSVG(cursorSize);

  for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
    let progress = frameCount <= 1 ? 0 : frameIndex / (frameCount - 1);
    if (loop) progress = progress <= 0.5 ? progress * 2 : (1 - progress) * 2;
    const eased = easeInOut(progress);
    const imageIndex = normalized.length <= 1
      ? 0
      : Math.min(normalized.length - 1, Math.floor(eased * normalized.length));
    const startX = width * 0.82;
    const startY = height * 0.78;
    const endX = width * 0.62;
    const endY = height * 0.39;
    const cursorX = Math.round(startX + (endX - startX) * eased);
    const cursorY = Math.round(startY + (endY - startY) * eased);
    const overlays: sharp.OverlayOptions[] = [{
      input: cursor,
      left: Math.max(0, Math.min(width - cursorSize, cursorX)),
      top: Math.max(0, Math.min(height - cursorSize, cursorY))
    }];
    const clickDistance = Math.abs(progress - 0.72);
    if (clickDistance < 0.12) {
      const pulseProgress = clickDistance / 0.12;
      const pulseSize = Math.round(cursorSize * (1.1 + pulseProgress * 1.4));
      overlays.unshift({
        input: clickPulseSVG(pulseSize, 1 - pulseProgress),
        left: Math.max(0, Math.min(width - pulseSize, cursorX - Math.round(pulseSize / 2))),
        top: Math.max(0, Math.min(height - pulseSize, cursorY - Math.round(pulseSize / 2)))
      });
    }
    const frame = await sharp(normalized[imageIndex]).composite(overlays).png().toBuffer();
    fs.writeFileSync(path.join(framesDirectory, `${String(frameIndex).padStart(5, "0")}.png`), frame);
    if (frameIndex === 0 || frameIndex === frameCount - 1 || frameIndex % Math.max(1, Math.round(frameCount / 4)) === 0) {
      onProgress?.(`Rendering UI animation frames (${frameIndex + 1}/${frameCount}).`);
    }
  }
}

function executableFile(value?: string) {
  if (!value?.trim()) return null;
  const resolved = path.resolve(value.trim());
  try {
    fs.accessSync(resolved, fs.constants.X_OK);
    return resolved;
  } catch {
    return null;
  }
}

export function resolveShortVideoFFmpeg(explicitPath?: string) {
  const candidates = [
    explicitPath,
    process.env.OPENASSIST_FFMPEG_PATH,
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg"
  ];
  for (const candidate of candidates) {
    const resolved = executableFile(candidate);
    if (resolved) return resolved;
  }
  const pathDirectories = String(process.env.PATH ?? "").split(path.delimiter).filter(Boolean);
  for (const directory of pathDirectories) {
    const resolved = executableFile(path.join(directory, "ffmpeg"));
    if (resolved) return resolved;
  }
  return null;
}

async function writeGeneratedMotionFrames(options: {
  imagePaths: string[];
  anchorsDirectory: string;
  framesDirectory: string;
  width: number;
  height: number;
  durationSeconds: number;
  fps: number;
  frameCount: number;
  loop: boolean;
  ffmpegPath?: string;
  onProgress?: (message: string) => void;
}) {
  const { width, height, durationSeconds, fps, frameCount, onProgress } = options;
  if (options.imagePaths.length < 3) {
    throw new Error("Real generated motion needs at least three changing anchor frames.");
  }
  const imagePaths = options.loop && options.imagePaths.length >= 3
    ? [...options.imagePaths, ...options.imagePaths.slice(1, -1).reverse()]
    : options.imagePaths;
  fs.mkdirSync(options.anchorsDirectory, { recursive: true });
  fs.mkdirSync(options.framesDirectory, { recursive: true });
  for (let index = 0; index < imagePaths.length; index += 1) {
    const buffer = await normalizedFrame(imagePaths[index], width, height);
    fs.writeFileSync(path.join(options.anchorsDirectory, `anchor-${String(index).padStart(5, "0")}.png`), buffer);
  }
  const normalizedPaths = fs.readdirSync(options.anchorsDirectory)
    .filter((name) => name.endsWith(".png"))
    .sort()
    .map((name) => path.join(options.anchorsDirectory, name));
  const validationReport = await validateMotionKeyframes(normalizedPaths);
  const duplicate = validationReport.pairs.find((pair) => pair.status === "duplicate");
  if (duplicate) {
    throw new Error(`Generated motion validation rejected duplicate anchor frames ${duplicate.fromIndex + 1} and ${duplicate.toIndex + 1}.`);
  }
  const drift = validationReport.pairs.find((pair) => pair.status === "scene_drift");
  if (drift) {
    throw new Error(`Generated motion validation detected scene drift between anchor frames ${drift.fromIndex + 1} and ${drift.toIndex + 1}.`);
  }

  // minterpolate needs one look-ahead frame to render through the last real anchor.
  // This sentinel is added after validation so it is never mistaken for user-visible motion.
  fs.copyFileSync(
    normalizedPaths[normalizedPaths.length - 1],
    path.join(options.anchorsDirectory, `anchor-${String(normalizedPaths.length).padStart(5, "0")}.png`)
  );

  const ffmpegPath = resolveShortVideoFFmpeg(options.ffmpegPath);
  if (!ffmpegPath) {
    throw new Error("Real motion interpolation needs local FFmpeg. Set OPENASSIST_FFMPEG_PATH or install FFmpeg; OpenAssist will not substitute a zoom clip.");
  }
  const anchorRate = Math.max(0.5, (normalizedPaths.length - 1) / durationSeconds);
  onProgress?.("Interpolating real movement between the approved anchor frames.");
  try {
    await execFileAsync(ffmpegPath, [
      "-hide_banner",
      "-loglevel", "error",
      "-y",
      "-framerate", String(anchorRate),
      "-start_number", "0",
      "-i", path.join(options.anchorsDirectory, "anchor-%05d.png"),
      "-vf", `minterpolate=fps=${fps}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:me=epzs:vsbmc=1,format=rgb24`,
      "-frames:v", String(frameCount),
      path.join(options.framesDirectory, "%05d.png")
    ], { timeout: 240_000, maxBuffer: 4_000_000 });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`Real motion interpolation failed. OpenAssist did not create a camera-motion substitute. ${detail}`);
  }
  const renderedCount = fs.readdirSync(options.framesDirectory).filter((name) => name.endsWith(".png")).length;
  if (renderedCount < Math.max(2, Math.floor(frameCount * 0.8))) {
    throw new Error(`Real motion interpolation produced only ${renderedCount} of ${frameCount} expected frames.`);
  }
  return { validationReport, renderedCount };
}

function validationForNonGeneratedMode(motionMode: ShortVideoMotionMode): MotionValidationReport {
  return {
    valid: true,
    actualMotion: motionMode === "ui_motion",
    pairs: []
  };
}

export async function renderShortVideo(request: RenderShortVideoRequest): Promise<RenderShortVideoResult> {
  const imagePaths = [...new Set(request.imagePaths.map((value) => path.resolve(value)))];
  if (!imagePaths.length) throw new Error("Short video generation needs at least one image.");
  for (const imagePath of imagePaths) {
    if (!fs.existsSync(imagePath) || !fs.statSync(imagePath).isFile()) {
      throw new Error(`Short video keyframe was not found: ${imagePath}`);
    }
  }
  if (!request.helperPath || !fs.existsSync(request.helperPath)) {
    throw new Error("The OpenAssist short-video helper is unavailable.");
  }

  const format = normalizeShortVideoFormat(request.format);
  const aspectRatio = normalizeShortVideoAspectRatio(request.aspectRatio);
  const durationSeconds = normalizeShortVideoDuration(request.durationSeconds);
  const fps = normalizeShortVideoFPS(request.fps);
  const motionMode = normalizeShortVideoMotionMode(request.motionMode);
  const { width, height } = shortVideoDimensions(aspectRatio);
  const frameCount = Math.max(2, Math.round(durationSeconds * fps));
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "openassist-short-video-"));
  const anchorsDirectory = path.join(temporaryDirectory, "anchors");
  const framesDirectory = path.join(temporaryDirectory, "frames");
  const outputPath = path.resolve(request.outputPath);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.rmSync(outputPath, { force: true });

  let validationReport = validationForNonGeneratedMode(motionMode);
  let interpolatedFrameCount = 0;
  try {
    request.onProgress?.("Preparing the short animation.");
    if (motionMode === "generated_motion") {
      const generated = await writeGeneratedMotionFrames({
        imagePaths,
        anchorsDirectory,
        framesDirectory,
        width,
        height,
        durationSeconds,
        fps,
        frameCount,
        loop: request.loop === true,
        ffmpegPath: request.ffmpegPath,
        onProgress: request.onProgress
      });
      validationReport = generated.validationReport;
      interpolatedFrameCount = generated.renderedCount;
    } else if (motionMode === "ui_motion") {
      await writeUIMotionFrames({
        imagePaths,
        framesDirectory,
        width,
        height,
        frameCount,
        loop: request.loop === true,
        onProgress: request.onProgress
      });
    } else {
      await writeCameraMotionFrames({ imagePaths, framesDirectory, width, height, frameCount, onProgress: request.onProgress });
    }
    request.onProgress?.(`Encoding the ${format.toUpperCase()} clip.`);
    await execFileAsync(request.helperPath, [
      "--frames-dir", framesDirectory,
      "--output", outputPath,
      "--fps", String(fps),
      "--format", format
    ], { timeout: 180_000, maxBuffer: 2_000_000 });
    if (!fs.existsSync(outputPath) || fs.statSync(outputPath).size < 1_000) {
      throw new Error("The short-video encoder did not create a usable output file.");
    }
    return {
      outputPath,
      format,
      width,
      height,
      durationSeconds,
      fps,
      frameCount,
      keyframeCount: imagePaths.length,
      interpolatedFrameCount,
      motionMode,
      actualSubjectMotion: validationReport.actualMotion,
      validationReport
    };
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
