export type OpenAIRealtimeModelGroup = "recommended" | "older";

export type OpenAIRealtimeModelDefinition = {
  id: string;
  label: string;
  description: string;
  group: OpenAIRealtimeModelGroup;
};

export const defaultOpenAIRealtimeModel = "gpt-realtime-2.1";

export const openAIRealtimeModels: readonly OpenAIRealtimeModelDefinition[] = Object.freeze([
  {
    id: "gpt-realtime-2.1",
    label: "GPT Realtime 2.1",
    description: "Best voice quality and interruption handling",
    group: "recommended"
  },
  {
    id: "gpt-realtime-2.1-mini",
    label: "GPT Realtime 2.1 mini",
    description: "Faster and more affordable",
    group: "recommended"
  },
  {
    id: "gpt-realtime-2",
    label: "GPT Realtime 2",
    description: "Older compatible model",
    group: "older"
  },
  {
    id: "gpt-realtime-1.5",
    label: "GPT Realtime 1.5",
    description: "Older compatible model",
    group: "older"
  },
  {
    id: "gpt-realtime",
    label: "GPT Realtime",
    description: "Legacy compatible model",
    group: "older"
  },
  {
    id: "gpt-realtime-mini",
    label: "GPT Realtime mini",
    description: "Legacy lower-cost model",
    group: "older"
  }
]);

const supportedModels = new Set(openAIRealtimeModels.map((model) => model.id));

export type OpenAIRealtimeModelValidation =
  | { ok: true; model: string }
  | { ok: false; model: string; message: string };

export function validateOpenAIRealtimeConversationModel(value: unknown): OpenAIRealtimeModelValidation {
  const model = typeof value === "string" ? value.trim() : "";
  if (!model) {
    return {
      ok: false,
      model,
      message: "Choose an OpenAI Realtime conversation model in Settings > Voice & Dictation."
    };
  }
  if (supportedModels.has(model)) return { ok: true, model };
  if (/whisper/i.test(model)) {
    return {
      ok: false,
      model,
      message: `${model} is transcription-only and cannot run the Live Voice assistant. Choose a GPT Realtime conversation model.`
    };
  }
  if (/translate/i.test(model)) {
    return {
      ok: false,
      model,
      message: `${model} uses the translation workflow and cannot run the Live Voice assistant. Choose a GPT Realtime conversation model.`
    };
  }
  if (/gpt-4o-realtime-preview/i.test(model)) {
    return {
      ok: false,
      model,
      message: `${model} is no longer supported. Choose GPT Realtime 2.1 or another model from Settings.`
    };
  }
  return {
    ok: false,
    model,
    message: `${model} is not a supported Live Voice conversation model. Choose a model from Settings.`
  };
}

export function requireOpenAIRealtimeConversationModel(value: unknown) {
  const validation = validateOpenAIRealtimeConversationModel(value);
  if (!validation.ok) throw new Error(validation.message);
  return validation.model;
}

export function buildOpenAIRealtimeURL(value: unknown) {
  const model = requireOpenAIRealtimeConversationModel(value);
  const url = new URL("wss://api.openai.com/v1/realtime");
  url.searchParams.set("model", model);
  return url.toString();
}

export function liveVoiceSettingsAreLocked(status: unknown) {
  return status !== "idle" && status !== "error";
}

export function readableOpenAIRealtimeConnectionError(input: {
  model: string;
  statusCode?: number;
  statusMessage?: string;
  detail?: string;
}) {
  const model = input.model.trim() || "the selected model";
  const detail = String(input.detail || "").toLowerCase();
  const statusCode = Number(input.statusCode) || 0;
  if (statusCode === 401 || /invalid api key|incorrect api key|authentication/.test(detail)) {
    return "OpenAI rejected the Realtime API key. Check the key in Settings > Voice & Dictation.";
  }
  if (statusCode === 403 || /permission|forbidden|not authorized|not enabled/.test(detail)) {
    return `This OpenAI API project does not have access to ${model}. Check the project or choose another Realtime model.`;
  }
  if (statusCode === 404 || /model_not_found|model not found|does not exist|unsupported model/.test(detail)) {
    return `${model} is not available to this OpenAI API project. Choose another Realtime model in Settings.`;
  }
  if (statusCode === 429 || /rate limit|quota|billing|insufficient_quota/.test(detail)) {
    return "OpenAI Realtime is currently rate limited for this API project. Check usage and billing, then try again.";
  }
  if (statusCode >= 500 || /temporar|overloaded|service unavailable/.test(detail)) {
    return "OpenAI Realtime is temporarily unavailable. Please try again in a moment.";
  }
  if (statusCode === 400 || /invalid_request|invalid argument/.test(detail)) {
    return `OpenAI rejected the Live Voice configuration for ${model}. Choose another model or restart Live Voice.`;
  }
  const status = statusCode
    ? ` (${statusCode}${input.statusMessage ? ` ${input.statusMessage}` : ""})`
    : "";
  return `OpenAI Realtime could not connect using ${model}${status}. Check the API key, project access, and internet connection.`;
}
