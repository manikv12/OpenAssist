import assert from "node:assert/strict";
import fs from "node:fs";
import ts from "typescript";
import {
  classifyCodexSubscriptionFailure,
  codexSubscriptionAutomaticFallbackProvider,
  codexSubscriptionCompatibilityDescriptors,
  codexSubscriptionConnectionHeaders,
  codexSubscriptionReadiness,
  findCodexSubscriptionEndpoint,
  findCodexSubscriptionWebRTCCompatibility,
  normalizeCodexSubscriptionOfferSdp,
  providerUsesCodexSubscription,
  redactCodexSubscriptionValue,
  selectCodexSubscriptionRuntime,
  validateCodexSubscriptionEndpointDescriptor,
  verifiedCodexSubscriptionEndpoints,
  verifiedCodexSubscriptionWebRTC,
  withOneCodexSubscriptionAuthRefresh
} from "../dist-electron/liveVoice/codexSubscriptionRealtime.js";

const rendererWebRTCSource = fs.readFileSync(new URL("../src/codexSubscriptionWebRTC.ts", import.meta.url), "utf8");
const rendererWebRTCModuleSource = ts.transpileModule(rendererWebRTCSource, {
  compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 }
}).outputText;
const rendererWebRTCModule = await import(`data:text/javascript;base64,${Buffer.from(rendererWebRTCModuleSource).toString("base64")}`);
const normalizeSessionDescriptionSdp = rendererWebRTCModule.normalizeCodexSubscriptionSessionDescriptionSdp;

const descriptor = {
  id: "codex-0.145.0-test",
  websocketURL: "wss://chatgpt.com/backend-api/codex/realtime",
  protocolVersion: "test-v1",
  wireProtocol: "openai-realtime-v1",
  model: "managed-by-codex",
  requiredHeaders: { "OpenAI-Beta": "realtime=v1" },
  codexVersion: "0.145.0",
  chatGPTBuild: "2026.190",
  verifiedAt: "2026-07-23T00:00:00.000Z",
  expiresAt: "2026-08-23T00:00:00.000Z"
};
const now = Date.parse("2026-07-24T00:00:00.000Z");

assert.equal(providerUsesCodexSubscription("codexSubscription"), true);
assert.equal(providerUsesCodexSubscription("openaiRealtime"), false);
assert.equal(codexSubscriptionAutomaticFallbackProvider, null);
assert.deepEqual(verifiedCodexSubscriptionEndpoints, []);
assert.equal(verifiedCodexSubscriptionWebRTC.length, 1);
assert.equal(findCodexSubscriptionWebRTCCompatibility("codex-cli 0.146.0-alpha.3")?.protocolVersion, "v3");
assert.equal(
  findCodexSubscriptionWebRTCCompatibility("codex-cli 0.147.0")?.codexVersion,
  "0.146.0",
  "An unlisted Codex version should try the latest verified WebRTC transport."
);
assert.equal(selectCodexSubscriptionRuntime({
  chatGPTBundled: "/Applications/ChatGPT.app/Contents/Resources/codex",
  regular: "/Users/test/.npm-global/bin/codex"
}), "/Applications/ChatGPT.app/Contents/Resources/codex");
assert.equal(selectCodexSubscriptionRuntime({
  override: "/tmp/test-codex",
  chatGPTBundled: "/Applications/ChatGPT.app/Contents/Resources/codex",
  regular: "/Users/test/.npm-global/bin/codex"
}), "/tmp/test-codex");

const completeOffer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n";
assert.equal(normalizeCodexSubscriptionOfferSdp(completeOffer), completeOffer);
assert.equal(
  normalizeCodexSubscriptionOfferSdp("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111"),
  completeOffer
);
assert.equal(normalizeCodexSubscriptionOfferSdp("   "), "");
assert.equal(normalizeSessionDescriptionSdp(completeOffer), completeOffer);
assert.equal(
  normalizeSessionDescriptionSdp("v=0\r\na=ice-pwd:test-password"),
  "v=0\r\na=ice-pwd:test-password\r\n"
);
assert.equal(normalizeSessionDescriptionSdp("  "), "");

const nativeReady = codexSubscriptionReadiness({
  codexVersion: "codex-cli 0.146.0-alpha.3",
  signedIn: true,
  planName: "ChatGPT Plus",
  descriptors: [],
  now
});
assert.equal(nativeReady.available, true);
assert.equal(nativeReady.status, "ready");
assert.match(nativeReady.message, /existing ChatGPT\/Codex sign-in/i);

const nativeSignedOut = codexSubscriptionReadiness({
  codexVersion: "0.146.0",
  signedIn: false,
  descriptors: [],
  now
});
assert.equal(nativeSignedOut.available, false);
assert.equal(nativeSignedOut.status, "signed_out");

const compatibleNewVersion = codexSubscriptionReadiness({
  codexVersion: "codex-cli 0.147.0",
  signedIn: true,
  planName: "ChatGPT Plus",
  descriptors: [],
  now
});
assert.equal(compatibleNewVersion.available, true);
assert.equal(compatibleNewVersion.status, "ready");
assert.match(compatibleNewVersion.message, /test compatibility/i);

const valid = validateCodexSubscriptionEndpointDescriptor(descriptor, {
  now,
  codexVersion: "codex-cli 0.145.0",
  chatGPTBuild: "2026.190"
});
assert.equal(valid.ok, true);
assert.equal(findCodexSubscriptionEndpoint("0.145.0", "2026.190", [descriptor], now)?.id, descriptor.id);
const unknownChatGPTBuild = validateCodexSubscriptionEndpointDescriptor(descriptor, {
  now,
  codexVersion: "0.145.0"
});
assert.equal(unknownChatGPTBuild.ok, false);
assert.equal(unknownChatGPTBuild.status, "unsupported_version");

for (const websocketURL of [
  "ws://chatgpt.com/backend-api/codex/realtime",
  "wss://example.com/backend-api/codex/realtime",
  "wss://chatgpt.com.evil.example/backend-api/codex/realtime"
]) {
  const rejected = validateCodexSubscriptionEndpointDescriptor({ ...descriptor, websocketURL }, { now, chatGPTBuild: "2026.190" });
  assert.equal(rejected.ok, false, `${websocketURL} must fail the endpoint allowlist.`);
  assert.equal(rejected.status, "endpoint_changed");
}

const unsupported = validateCodexSubscriptionEndpointDescriptor(descriptor, {
  now,
  codexVersion: "0.146.0",
  chatGPTBuild: "2026.190"
});
assert.equal(unsupported.ok, false);
assert.equal(unsupported.status, "unsupported_version");

const expired = validateCodexSubscriptionEndpointDescriptor(descriptor, {
  now: Date.parse("2026-09-01T00:00:00.000Z"),
  codexVersion: "0.145.0",
  chatGPTBuild: "2026.190"
});
assert.equal(expired.ok, false);
assert.equal(expired.status, "endpoint_changed");

const absent = codexSubscriptionReadiness({
  codexVersion: "0.145.0",
  chatGPTBuild: "2026.190",
  signedIn: true,
  descriptors: [],
  now
});
assert.equal(absent.available, true);
assert.equal(absent.status, "ready");
assert.match(absent.message, /test compatibility/i);

const signedOut = codexSubscriptionReadiness({
  codexVersion: "0.145.0",
  chatGPTBuild: "2026.190",
  signedIn: false,
  descriptors: [descriptor],
  now
});
assert.equal(signedOut.available, false);
assert.equal(signedOut.status, "signed_out");

const ready = codexSubscriptionReadiness({
  codexVersion: "0.145.0",
  chatGPTBuild: "2026.190",
  signedIn: true,
  planName: "Plus",
  descriptors: [descriptor],
  now
});
assert.equal(ready.available, true);
assert.equal(ready.status, "ready");
assert.equal(ready.planName, "Plus");

const optInDescriptors = codexSubscriptionCompatibilityDescriptors({
  OPENASSIST_CODEX_VOICE_LIVE_TEST: "1",
  OPENASSIST_CODEX_VOICE_DESCRIPTOR: JSON.stringify(descriptor)
});
assert.equal(optInDescriptors.length, 1);
assert.equal(codexSubscriptionCompatibilityDescriptors({
  OPENASSIST_CODEX_VOICE_DESCRIPTOR: JSON.stringify(descriptor)
}).length, 0, "An environment descriptor requires explicit live-test opt in.");

const headers = codexSubscriptionConnectionHeaders(descriptor, {
  accessToken: "secret-token",
  accountID: "account-123"
});
assert.equal(headers.Authorization, "Bearer secret-token");
assert.equal(headers["ChatGPT-Account-Id"], "account-123");
const redacted = redactCodexSubscriptionValue({ headers, accessToken: "secret-token", nested: { password: "secret" } });
assert.equal(redacted.accessToken, "[REDACTED]");
assert.equal(redacted.nested.password, "[REDACTED]");
assert.equal(redacted.headers.Authorization, "[REDACTED]");
assert.equal(redacted.headers["ChatGPT-Account-Id"], "[REDACTED]");
assert.doesNotMatch(JSON.stringify(redacted), /secret-token|account-123|secret/);

assert.equal(classifyCodexSubscriptionFailure({ statusCode: 401 }).status, "signed_out");
assert.equal(classifyCodexSubscriptionFailure({ statusCode: 429 }).status, "rate_limited");
assert.equal(classifyCodexSubscriptionFailure({ statusCode: 404 }).status, "endpoint_changed");
assert.equal(classifyCodexSubscriptionFailure({ statusCode: 503 }).status, "not_available");

const authCalls = [];
const connectCalls = [];
const result = await withOneCodexSubscriptionAuthRefresh({
  authenticate: async (forceRefresh) => {
    authCalls.push(forceRefresh);
    return { accessToken: forceRefresh ? "fresh" : "stale" };
  },
  connect: async (auth) => {
    connectCalls.push(auth.accessToken);
    if (auth.accessToken === "stale") throw Object.assign(new Error("Unauthorized"), { statusCode: 401 });
    return "connected";
  },
  isAuthenticationFailure: (error) => Number(error?.statusCode) === 401
});
assert.equal(result, "connected");
assert.deepEqual(authCalls, [false, true]);
assert.deepEqual(connectCalls, ["stale", "fresh"]);

console.log("Codex subscription realtime compatibility checks passed.");
