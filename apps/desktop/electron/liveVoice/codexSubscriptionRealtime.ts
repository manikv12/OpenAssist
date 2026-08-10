export type CodexSubscriptionVoiceStatus =
  | "ready"
  | "signed_out"
  | "unsupported_version"
  | "not_available"
  | "rate_limited"
  | "endpoint_changed";

export type CodexSubscriptionWireProtocol = "openai-realtime-v1";

export type CodexSubscriptionEndpointDescriptor = {
  id: string;
  websocketURL: string;
  protocolVersion: string;
  wireProtocol: CodexSubscriptionWireProtocol;
  model: string;
  requiredHeaders: Record<string, string>;
  codexVersion: string;
  chatGPTBuild?: string;
  verifiedAt: string;
  expiresAt: string;
};

export type CodexSubscriptionAuthContext = {
  accessToken: string;
  accountID?: string;
  planName?: string;
  expiresAt?: number;
};

export type CodexSubscriptionReadiness = {
  status: CodexSubscriptionVoiceStatus;
  available: boolean;
  message: string;
  codexVersion: string;
  planName?: string;
  descriptor?: CodexSubscriptionEndpointDescriptor;
};

export type CodexSubscriptionWebRTCCompatibility = {
  codexVersion: string;
  protocolVersion: "v3";
  model: "gpt-live-1-boulder-alpha";
  voice: "sol";
  verifiedAt: string;
};

export type CodexSubscriptionProbeResult = {
  ok: boolean;
  status: CodexSubscriptionVoiceStatus;
  message: string;
  statusCode?: number;
};

const allowedHosts = new Set([
  "api.openai.com",
  "chatgpt.com"
]);

// The old direct-websocket experiment remains empty. Subscription voice uses
// Codex app-server's WebRTC transport, so OpenAssist never reads or handles the
// user's ChatGPT access token in this path.
export const verifiedCodexSubscriptionEndpoints: readonly CodexSubscriptionEndpointDescriptor[] = Object.freeze([]);

// Add a version only after a full microphone -> assistant transcript ->
// assistant audio round trip succeeds while API-key environment variables are
// removed. New Codex versions may try the latest verified transport; the real
// handshake remains authoritative and no API-key provider is used as fallback.
export const verifiedCodexSubscriptionWebRTC: readonly CodexSubscriptionWebRTCCompatibility[] = Object.freeze([
  {
    codexVersion: "0.146.0",
    protocolVersion: "v3",
    model: "gpt-live-1-boulder-alpha",
    voice: "sol",
    verifiedAt: "2026-07-24T06:00:00.000Z"
  }
]);

// Subscription voice must fail closed. The user can explicitly choose another
// provider, but a failed beta connection never spends money through an API key.
export const codexSubscriptionAutomaticFallbackProvider = null;

export function codexSubscriptionCompatibilityDescriptors(
  environment: Record<string, string | undefined> = process.env
) {
  const entries = [...verifiedCodexSubscriptionEndpoints];
  if (environment.OPENASSIST_CODEX_VOICE_LIVE_TEST !== "1") return entries;
  const raw = environment.OPENASSIST_CODEX_VOICE_DESCRIPTOR?.trim();
  if (!raw) return entries;
  try {
    const descriptor = JSON.parse(raw) as CodexSubscriptionEndpointDescriptor;
    if (validateCodexSubscriptionEndpointDescriptor(descriptor).ok) entries.push(descriptor);
  } catch {
    // The optional live-test descriptor is invalid. Fail closed.
  }
  return entries;
}

export function normalizeCodexVersion(value: unknown) {
  const match = String(value || "").match(/(?:codex(?:-cli)?\s+)?(\d+\.\d+\.\d+)/i);
  return match?.[1] || "";
}

export function selectCodexSubscriptionRuntime(input: {
  override?: string;
  chatGPTBundled?: string;
  codexBundled?: string;
  regular: string;
}) {
  return input.override?.trim()
    || input.chatGPTBundled?.trim()
    || input.codexBundled?.trim()
    || input.regular;
}

// WebRTC SDP is line-oriented and the Codex parser expects the final CRLF.
// Validate content separately so we never strip that protocol delimiter.
export function normalizeCodexSubscriptionOfferSdp(value: unknown) {
  const raw = typeof value === "string" ? value : "";
  if (!raw.trim()) return "";
  if (raw.endsWith("\r\n")) return raw;
  return `${raw.replace(/(?:\r?\n)+$/, "")}\r\n`;
}

export function descriptorIsCurrent(
  descriptor: CodexSubscriptionEndpointDescriptor,
  now = Date.now()
) {
  const expiresAt = Date.parse(descriptor.expiresAt);
  return Number.isFinite(expiresAt) && expiresAt > now;
}

export function validateCodexSubscriptionEndpointDescriptor(
  descriptor: CodexSubscriptionEndpointDescriptor,
  options: { now?: number; codexVersion?: string; chatGPTBuild?: string } = {}
) {
  let url: URL;
  try {
    url = new URL(descriptor.websocketURL);
  } catch {
    return { ok: false as const, status: "endpoint_changed" as const, message: "The Codex Voice endpoint is invalid." };
  }
  if (url.protocol !== "wss:" || !allowedHosts.has(url.hostname.toLowerCase())) {
    return { ok: false as const, status: "endpoint_changed" as const, message: "The Codex Voice endpoint is not on the tested OpenAI allowlist." };
  }
  if (descriptor.wireProtocol !== "openai-realtime-v1" || !descriptor.protocolVersion.trim()) {
    return { ok: false as const, status: "endpoint_changed" as const, message: "The Codex Voice protocol changed and needs compatibility testing." };
  }
  const installedVersion = normalizeCodexVersion(options.codexVersion);
  if (installedVersion && normalizeCodexVersion(descriptor.codexVersion) !== installedVersion) {
    return { ok: false as const, status: "unsupported_version" as const, message: `Codex Voice has not been verified for Codex ${installedVersion}.` };
  }
  if (descriptor.chatGPTBuild && options.codexVersion && !options.chatGPTBuild) {
    return { ok: false as const, status: "unsupported_version" as const, message: "The installed ChatGPT build could not be verified for Codex Voice." };
  }
  // Compare builds only when the caller provides one (mirrors the version
  // check above). Parse-time sanity validation passes no environment options;
  // the connect path re-validates with the real installed build.
  if (descriptor.chatGPTBuild && options.chatGPTBuild && descriptor.chatGPTBuild !== options.chatGPTBuild) {
    return { ok: false as const, status: "unsupported_version" as const, message: `Codex Voice has not been verified for ChatGPT build ${options.chatGPTBuild}.` };
  }
  if (!descriptorIsCurrent(descriptor, options.now)) {
    return { ok: false as const, status: "endpoint_changed" as const, message: "The Codex Voice compatibility entry expired and needs a new live test." };
  }
  if (!descriptor.model.trim()) {
    return { ok: false as const, status: "endpoint_changed" as const, message: "The Codex Voice compatibility entry has no tested model." };
  }
  return { ok: true as const, descriptor };
}

export function findCodexSubscriptionEndpoint(
  codexVersion: string,
  chatGPTBuild = "",
  descriptors: readonly CodexSubscriptionEndpointDescriptor[] = verifiedCodexSubscriptionEndpoints,
  now = Date.now()
) {
  const installedVersion = normalizeCodexVersion(codexVersion);
  for (const descriptor of descriptors) {
    const validation = validateCodexSubscriptionEndpointDescriptor(descriptor, {
      now,
      codexVersion: installedVersion,
      chatGPTBuild
    });
    if (validation.ok) return descriptor;
  }
  return undefined;
}

export function codexSubscriptionReadiness(input: {
  codexVersion: string;
  chatGPTBuild?: string;
  signedIn: boolean;
  planName?: string;
  descriptors?: readonly CodexSubscriptionEndpointDescriptor[];
  now?: number;
}): CodexSubscriptionReadiness {
  const codexVersion = normalizeCodexVersion(input.codexVersion);
  if (!codexVersion) {
    return {
      status: "not_available",
      available: false,
      message: "Install Codex before using Codex Voice.",
      codexVersion: "Not installed"
    };
  }
  const exactNativeWebRTC = verifiedCodexSubscriptionWebRTC.find((entry) => entry.codexVersion === codexVersion);
  const nativeWebRTC = findCodexSubscriptionWebRTCCompatibility(codexVersion);
  const descriptor = findCodexSubscriptionEndpoint(codexVersion, input.chatGPTBuild, input.descriptors, input.now);
  if (!nativeWebRTC && !descriptor) {
    return {
      status: "unsupported_version",
      available: false,
      message: `Codex Voice is not yet verified for Codex ${codexVersion}. OpenAI Realtime and Gemini Live remain available.`,
      codexVersion,
      planName: input.planName
    };
  }
  if (!input.signedIn) {
    return {
      status: "signed_out",
      available: false,
      message: "Sign in to Codex with your ChatGPT account, then retry.",
      codexVersion,
      planName: input.planName,
      descriptor
    };
  }
  return {
    status: "ready",
    available: true,
    message: exactNativeWebRTC
      ? "Codex Voice is ready through your existing ChatGPT/Codex sign-in. Plan limits apply."
      : nativeWebRTC
        ? `Codex Voice will test compatibility with Codex ${codexVersion} when it connects. Plan limits apply.`
      : "Codex Voice is ready. ChatGPT or Codex plan limits apply.",
    codexVersion,
    planName: input.planName,
    descriptor
  };
}

export function findCodexSubscriptionWebRTCCompatibility(codexVersion: string) {
  const normalized = normalizeCodexVersion(codexVersion);
  if (!normalized) return undefined;
  const exact = verifiedCodexSubscriptionWebRTC.find((entry) => entry.codexVersion === normalized);
  if (exact) return exact;
  return verifiedCodexSubscriptionWebRTC.reduce<CodexSubscriptionWebRTCCompatibility | undefined>(
    (latest, entry) => !latest || Date.parse(entry.verifiedAt) > Date.parse(latest.verifiedAt) ? entry : latest,
    undefined
  );
}

export function codexSubscriptionConnectionHeaders(
  descriptor: CodexSubscriptionEndpointDescriptor,
  auth: CodexSubscriptionAuthContext
) {
  const headers: Record<string, string> = {
    ...descriptor.requiredHeaders,
    Authorization: `Bearer ${auth.accessToken}`
  };
  if (auth.accountID) headers["ChatGPT-Account-Id"] = auth.accountID;
  return headers;
}

export function classifyCodexSubscriptionFailure(input: {
  statusCode?: number;
  detail?: string;
}): CodexSubscriptionProbeResult {
  const detail = String(input.detail || "").toLowerCase();
  const statusCode = Number(input.statusCode) || 0;
  if (statusCode === 401 || statusCode === 403 || /sign.?in|authentication|unauthorized|forbidden/.test(detail)) {
    return { ok: false, status: "signed_out", message: "Codex Voice could not verify the signed-in ChatGPT account.", statusCode };
  }
  if (statusCode === 429 || /rate.?limit|usage limit|quota/.test(detail)) {
    return { ok: false, status: "rate_limited", message: "Codex Voice reached a ChatGPT or Codex plan limit. Try again later.", statusCode };
  }
  if (statusCode === 404 || statusCode === 410 || /protocol|endpoint|unsupported|not found/.test(detail)) {
    return { ok: false, status: "endpoint_changed", message: "The Codex Voice beta endpoint changed and needs compatibility testing.", statusCode };
  }
  return { ok: false, status: "not_available", message: "Codex Voice is temporarily unavailable.", statusCode };
}

export async function withOneCodexSubscriptionAuthRefresh<T>(input: {
  authenticate: (forceRefresh: boolean) => Promise<CodexSubscriptionAuthContext>;
  connect: (auth: CodexSubscriptionAuthContext) => Promise<T>;
  isAuthenticationFailure: (error: unknown) => boolean;
}) {
  const first = await input.authenticate(false);
  try {
    return await input.connect(first);
  } catch (error) {
    if (!input.isAuthenticationFailure(error)) throw error;
  }
  const refreshed = await input.authenticate(true);
  return input.connect(refreshed);
}

const sensitiveKeyPattern = /(authorization|token|secret|password|cookie|account.?id)/i;

export function redactCodexSubscriptionValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redactCodexSubscriptionValue);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, entry]) => [
    key,
    sensitiveKeyPattern.test(key) ? "[REDACTED]" : redactCodexSubscriptionValue(entry)
  ]));
}

export function providerUsesCodexSubscription(value: unknown): value is "codexSubscription" {
  return value === "codexSubscription";
}
