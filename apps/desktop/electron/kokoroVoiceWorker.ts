import fs from "node:fs";
import path from "node:path";
import { parentPort } from "node:worker_threads";

type KokoroWorkerMessage = {
  type: "prewarm" | "generate";
  requestID: string;
  modelID: string;
  cacheDir: string;
  text?: string;
  voiceID?: string;
  outputPath?: string;
};

let ttsPromise: Promise<import("kokoro-js").KokoroTTS> | null = null;

async function loadTTS(modelID: string, cacheDir: string) {
  if (!ttsPromise) {
    ttsPromise = (async () => {
      fs.mkdirSync(cacheDir, { recursive: true });
      const transformers = await import("@huggingface/transformers");
      transformers.env.cacheDir = cacheDir;
      transformers.env.useFSCache = true;
      transformers.env.allowLocalModels = true;
      transformers.env.allowRemoteModels = true;
      const { KokoroTTS } = await import("kokoro-js");
      return KokoroTTS.from_pretrained(modelID, {
        dtype: "q8",
        device: "cpu"
      });
    })();
  }
  return ttsPromise;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.stack ?? error.message : String(error);
}

parentPort?.on("message", async (message: KokoroWorkerMessage) => {
  try {
    const tts = await loadTTS(message.modelID, message.cacheDir);
    if (message.type === "generate") {
      if (!message.text?.trim() || !message.voiceID?.trim() || !message.outputPath?.trim()) {
        throw new Error("Kokoro voice worker received an incomplete generation request.");
      }
      fs.mkdirSync(path.dirname(message.outputPath), { recursive: true });
      const audio = await tts.generate(message.text, {
        voice: message.voiceID as NonNullable<import("kokoro-js").GenerateOptions["voice"]>,
        speed: 1
      });
      await audio.save(message.outputPath);
      parentPort?.postMessage({ requestID: message.requestID, ok: true, outputPath: message.outputPath });
      return;
    }
    parentPort?.postMessage({ requestID: message.requestID, ok: true });
  } catch (error) {
    parentPort?.postMessage({ requestID: message.requestID, ok: false, error: errorMessage(error) });
  }
});
