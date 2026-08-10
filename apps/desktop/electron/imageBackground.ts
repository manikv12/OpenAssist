import sharp from "sharp";

export type CodexImageBackgroundMode = "auto" | "opaque" | "transparent";

export type GeneratedImagePayload = {
  dataURL: string;
  mimeType: string;
  name: string;
  prompt?: string;
};

export type PreparedImageBackground = {
  image: GeneratedImagePayload;
  backgroundMode: CodexImageBackgroundMode;
  hasAlpha: boolean;
  backgroundRemovalMethod: "none" | "native_alpha" | "apple_vision_mask";
};

export type ImageBackgroundPreparationOptions = {
  onProgress?: (message: string) => void;
  removeBackground?: (buffer: Buffer) => Promise<Buffer>;
};

const usefulAlphaRatio = 0.001;
let backgroundRemovalQueue: Promise<void> = Promise.resolve();

export function normalizeCodexImageBackgroundMode(value: unknown): CodexImageBackgroundMode {
  const normalized = String(value ?? "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (["transparent", "alpha", "cutout", "transparent_background"].includes(normalized)) return "transparent";
  if (["opaque", "normal", "solid"].includes(normalized)) return "opaque";
  return "auto";
}

export function codexImageBackgroundInstructions(mode: CodexImageBackgroundMode) {
  if (mode === "transparent") {
    return [
      "Source background: ordinary opaque, plain light-neutral-gray studio background.",
      "Return the source image exactly as generated. Do not remove, replace, or process the background.",
      "Keep the subject separated from the background with clean edges and generous padding.",
      "Preserve every natural subject color exactly, including food, plants, clothing, and reflections."
    ];
  }
  if (mode === "opaque") {
    return ["Background output: normal opaque image. Do not return a transparent canvas."];
  }
  return ["Background output: follow the user's request."];
}

export function codexImageSourcePrompt(prompt: string, mode: CodexImageBackgroundMode) {
  if (mode !== "transparent") return prompt;
  return prompt
    .replace(/\b(?:fully\s+)?transparent(?:\s+(?:background|canvas|png|image))?\b/gi, "plain light-neutral-gray background")
    .replace(/\b(?:real|native|true)?\s*alpha(?:\s+channel)?\b/gi, "clean subject edges")
    .replace(/\b(?:green|blue|magenta)\s*screen\b/gi, "plain light-neutral-gray background")
    .replace(/\bchroma(?:\s*-?\s*)key(?:ing)?\b/gi, "plain light-neutral-gray background")
    .replace(/\bcut\s*-?\s*out\b/gi, "isolated subject")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function decodeImageDataURL(dataURL: string) {
  const match = dataURL.trim().match(/^data:(image\/[a-zA-Z0-9+.-]+);base64,(.+)$/s);
  if (!match) throw new Error("OpenAssist could not decode the generated image.");
  return Buffer.from(match[2].replace(/\s+/g, ""), "base64");
}

function pngPayload(image: GeneratedImagePayload, buffer: Buffer): GeneratedImagePayload {
  const baseName = image.name.replace(/\.[a-z0-9]+$/i, "") || "codex-image";
  return {
    ...image,
    name: `${baseName}.png`,
    mimeType: "image/png",
    dataURL: `data:image/png;base64,${buffer.toString("base64")}`
  };
}

function hasUsefulAlpha(data: Buffer, width: number, height: number, channels: number) {
  let transparentPixels = 0;
  const pixelCount = width * height;

  for (let index = 0; index < pixelCount; index += 1) {
    const offset = index * channels;
    const alpha = channels >= 4 ? data[offset + 3] ?? 255 : 255;
    if (alpha < 250) transparentPixels += 1;
  }
  return transparentPixels / Math.max(1, pixelCount) >= usefulAlphaRatio;
}

async function rawRGBA(buffer: Buffer) {
  return sharp(buffer, { limitInputPixels: false })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
}

async function transparentCutout(buffer: Buffer) {
  const { data, info } = await rawRGBA(buffer);
  if (!hasUsefulAlpha(data, info.width, info.height, info.channels)) {
    throw new Error("Transparent output was requested, but the generated PNG did not contain real alpha transparency. No colors were removed.");
  }
  return sharp(buffer, { limitInputPixels: false }).png().toBuffer();
}

async function withBackgroundRemovalSlot<T>(task: () => Promise<T>) {
  const previous = backgroundRemovalQueue;
  let release!: () => void;
  backgroundRemovalQueue = new Promise<void>((resolve) => {
    release = resolve;
  });
  await previous;
  try {
    return await task();
  } finally {
    release();
  }
}

export async function prepareCodexImageBackground(
  image: GeneratedImagePayload,
  requestedMode: unknown,
  options: ImageBackgroundPreparationOptions = {}
): Promise<PreparedImageBackground> {
  const backgroundMode = normalizeCodexImageBackgroundMode(requestedMode);
  const original = decodeImageDataURL(image.dataURL);

  if (backgroundMode === "transparent") {
    const originalPixels = await rawRGBA(original);
    const nativeAlpha = hasUsefulAlpha(
      originalPixels.data,
      originalPixels.info.width,
      originalPixels.info.height,
      originalPixels.info.channels
    );
    if (!nativeAlpha && !options.removeBackground) {
      throw new Error("Transparent output needs the local macOS Vision background remover, but it is unavailable.");
    }
    const png = nativeAlpha
      ? await transparentCutout(original)
      : await withBackgroundRemovalSlot(async () => {
        options.onProgress?.("Removing the background locally with macOS Vision.");
        return options.removeBackground!(original);
      });
    const { data, info } = await rawRGBA(png);
    if (!hasUsefulAlpha(data, info.width, info.height, info.channels)) {
      throw new Error("macOS Vision did not produce a usable transparent background. The source image was not changed.");
    }
    return {
      image: pngPayload(image, png),
      backgroundMode,
      hasAlpha: true,
      backgroundRemovalMethod: nativeAlpha ? "native_alpha" : "apple_vision_mask"
    };
  }

  const { data, info } = await rawRGBA(original);
  return {
    image,
    backgroundMode,
    hasAlpha: hasUsefulAlpha(data, info.width, info.height, info.channels),
    backgroundRemovalMethod: "none"
  };
}
