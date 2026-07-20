import { execFileSync } from "node:child_process";
import WebSocket from "ws";
import {
  buildOpenAIRealtimeURL,
  openAIRealtimeModels,
  readableOpenAIRealtimeConnectionError
} from "../dist-electron/openAIRealtimeModels.js";

const keychainService = "com.developingadventures.OpenAssist";
const keychainAccounts = [
  "realtime-openai-api-key",
  "cloud-transcription-provider-api-key.openai",
  "prompt-rewrite-provider-api-key.openai"
];

function savedAPIKey() {
  const environmentKey = process.env.OPENAI_API_KEY?.trim();
  if (environmentKey) return environmentKey;
  for (const account of keychainAccounts) {
    try {
      const value = execFileSync(
        "security",
        ["find-generic-password", "-s", keychainService, "-a", account, "-w"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 2_000 }
      ).trim();
      if (value) return value;
    } catch {
      // Try the next OpenAssist keychain account.
    }
  }
  return "";
}

function checkModel(model, apiKey) {
  return new Promise((resolve) => {
    let settled = false;
    let statusCode = 0;
    let timer;
    const socket = new WebSocket(buildOpenAIRealtimeURL(model), {
      headers: { Authorization: `Bearer ${apiKey}` }
    });
    const finish = (available, message) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket.close();
      } catch {
        // Best effort after a rejected handshake.
      }
      resolve({ model, available, message });
    };
    timer = setTimeout(() => finish(false, "Connection timed out."), 12_000);
    socket.on("message", (data) => {
      try {
        const event = JSON.parse(data.toString());
        if (event?.type === "session.created") finish(true, "Available");
        else if (event?.type === "error") {
          finish(false, readableOpenAIRealtimeConnectionError({ model, detail: event?.error?.message }));
        }
      } catch {
        // Wait for a structured session event.
      }
    });
    socket.on("unexpected-response", (_request, response) => {
      statusCode = response.statusCode || 0;
      response.resume();
      finish(false, readableOpenAIRealtimeConnectionError({
        model,
        statusCode,
        statusMessage: response.statusMessage
      }));
    });
    socket.on("error", (error) => {
      finish(false, readableOpenAIRealtimeConnectionError({
        model,
        statusCode,
        detail: error instanceof Error ? error.message : String(error)
      }));
    });
    socket.on("close", () => {
      if (!settled) finish(false, readableOpenAIRealtimeConnectionError({ model, statusCode }));
    });
  });
}

const apiKey = savedAPIKey();
if (!apiKey) {
  console.log("Skipped live OpenAI Realtime model access check: no OpenAssist or OPENAI_API_KEY credential was found.");
  process.exit(0);
}

const results = [];
for (const definition of openAIRealtimeModels) {
  results.push(await checkModel(definition.id, apiKey));
}

for (const result of results) {
  console.log(`${result.available ? "PASS" : "NO ACCESS"} ${result.model}: ${result.message}`);
}
console.log(`Checked ${results.length} OpenAI Realtime conversation models without generating a response.`);
