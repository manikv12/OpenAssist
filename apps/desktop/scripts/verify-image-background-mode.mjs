import assert from "node:assert/strict";
import sharp from "sharp";
import {
  codexImageBackgroundInstructions,
  codexImageSourcePrompt,
  normalizeCodexImageBackgroundMode,
  prepareCodexImageBackground
} from "../dist-electron/imageBackground.js";

function dataURL(buffer) {
  return `data:image/png;base64,${buffer.toString("base64")}`;
}

function imagePayload(buffer, name = "subject.png") {
  return { dataURL: dataURL(buffer), mimeType: "image/png", name };
}

const width = 8;
const height = 8;
const pixels = Buffer.alloc(width * height * 4);
for (let y = 2; y < 6; y += 1) {
  for (let x = 2; x < 6; x += 1) {
    const offset = (y * width + x) * 4;
    pixels[offset] = 12;
    pixels[offset + 1] = 190;
    pixels[offset + 2] = 35;
    pixels[offset + 3] = 255;
  }
}
const nativeAlphaPNG = await sharp(pixels, { raw: { width, height, channels: 4 } }).png().toBuffer();
const prepared = await prepareCodexImageBackground(imagePayload(nativeAlphaPNG), "transparent");
assert.equal(prepared.backgroundMode, "transparent");
assert.equal(prepared.hasAlpha, true);
assert.equal(prepared.backgroundRemovalMethod, "native_alpha");
assert.equal(prepared.image.mimeType, "image/png");
const preparedBuffer = Buffer.from(prepared.image.dataURL.split(",")[1], "base64");
const { data: preparedPixels, info } = await sharp(preparedBuffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
assert.equal(preparedPixels[3], 0, "Transparent background must remain transparent.");
const centerOffset = (3 * info.width + 3) * info.channels;
assert.deepEqual(
  [...preparedPixels.subarray(centerOffset, centerOffset + 4)],
  [12, 190, 35, 255],
  "Real green subject colors must not be keyed out or changed."
);

const opaqueNeutralPNG = await sharp(pixels, { raw: { width, height, channels: 4 } })
  .flatten({ background: { r: 225, g: 225, b: 225 } })
  .png()
  .toBuffer();
const locallyMasked = await prepareCodexImageBackground(imagePayload(opaqueNeutralPNG), "transparent", {
  removeBackground: async (buffer) => {
    const { data, info } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    for (let y = 0; y < info.height; y += 1) {
      for (let x = 0; x < info.width; x += 1) {
        data[(y * info.width + x) * info.channels + 3] = x >= 2 && x < 6 && y >= 2 && y < 6 ? 255 : 0;
      }
    }
    return sharp(data, { raw: info }).png().toBuffer();
  }
});
assert.equal(locallyMasked.backgroundRemovalMethod, "apple_vision_mask");
const locallyMaskedBuffer = Buffer.from(locallyMasked.image.dataURL.split(",")[1], "base64");
const locallyMaskedPixels = await sharp(locallyMaskedBuffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
const greenOffset = (3 * locallyMaskedPixels.info.width + 3) * locallyMaskedPixels.info.channels;
assert.deepEqual(
  [...locallyMaskedPixels.data.subarray(greenOffset, greenOffset + 4)],
  [12, 190, 35, 255],
  "Object-mask removal must preserve the original green subject pixels."
);

assert.equal(normalizeCodexImageBackgroundMode("cutout"), "transparent");
assert.equal(normalizeCodexImageBackgroundMode("green_screen"), "auto");
assert.match(codexImageBackgroundInstructions("transparent").join(" "), /plain light-neutral-gray/);
const sourcePrompt = codexImageSourcePrompt(
  "Make a transparent PNG cut-out on a green screen with a real alpha channel.",
  "transparent"
);
assert.doesNotMatch(sourcePrompt, /transparent|green screen|alpha|cut-out/i);
assert.match(sourcePrompt, /light-neutral-gray background/i);

console.log("Native-alpha and macOS Vision image background checks passed.");
