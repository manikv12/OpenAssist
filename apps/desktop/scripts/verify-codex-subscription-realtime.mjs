import assert from "node:assert/strict";
import fs from "node:fs";
import ts from "typescript";
import {
  classifyCodexSubscriptionFailure,
  codexSubscriptionAutomaticFallbackProvider,
  codexSubscriptionCallIDFromLocation,
  codexSubscriptionCompatibilityDescriptors,
  codexSubscriptionConnectionHeaders,
  codexSubscriptionDirectCallHeaders,
  codexSubscriptionRealtimeCallURL,
  codexSubscriptionReadiness,
  findCodexSubscriptionEndpoint,
  findCodexSubscriptionWebRTCCompatibility,
  normalizeCodexSubscriptionOfferSdp,
  providerUsesCodexSubscription,
  redactCodexSubscriptionValue,
  compareCodexVersions,
  pickNewestCodexRuntime,
  selectCodexSubscriptionRuntime,
  validateCodexSubscriptionRealtimeCallURL,
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

const bridgeSource = fs.readFileSync(new URL("../electron/openassistBridge.ts", import.meta.url), "utf8");
const subscriptionStartParams = bridgeSource.match(
  /const realtimeStartParams:[\s\S]*?realtimeVoiceProvider === "codexSubscription"[\s\S]*?\? \{([\s\S]*?)\n\s*\}\n\s*: \{/
)?.[1] || "";
assert.ok(subscriptionStartParams, "Codex Voice realtime start parameters should remain discoverable.");
assert.doesNotMatch(
  subscriptionStartParams,
  /\bmodel\s*:/,
  "Codex Voice realtime start must omit the model field because the subscription endpoint rejects session.model."
);
assert.match(
  subscriptionStartParams,
  /transport:\s*\{\s*type:\s*"webrtc",\s*sdp:\s*codexSubscriptionOfferSdp\s*\}/,
  "Codex Voice must send the renderer SDP offer through the current app-server WebRTC transport."
);
assert.doesNotMatch(
  subscriptionStartParams,
  /existingCall|callId|subscriptionCall/,
  "Codex Voice must not use the removed existingCall transport."
);
for (const forbiddenField of ["prompt", "includeStartupContext", "initialItems", "delegationAckFiller"]) {
  assert.doesNotMatch(
    subscriptionStartParams,
    new RegExp(`\\b${forbiddenField}\\s*:`),
    `Codex Voice WebRTC start must not include ${forbiddenField}.`
  );
}
// `voice` IS supported on the WebRTC transport (validate_realtime_voice, v3 →
// engine v1 voice list) — but only as a validated, conditional field: an
// unknown voice ID makes the engine reject the whole session start.
assert.match(
  subscriptionStartParams,
  /\.\.\.\(normalizedCodexSubscriptionVoice\(settings\.realtimeCodexVoice\) \? \{ voice: normalizedCodexSubscriptionVoice\(settings\.realtimeCodexVoice\) \} : \{\}\),/,
  "Codex Voice must send the user's voice pick only when it passes the allowed-voice check."
);
assert.match(
  bridgeSource,
  /const codexSubscriptionRealtimeVoiceIDs = \["cove", "juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol"\];/,
  "The allowed Codex realtime voice list must match RealtimeVoicesList::builtin() v1."
);
assert.match(
  subscriptionStartParams,
  /realtimeStartInstructions:\s*realtimeStartPrompt/,
  "Codex Voice should preserve OpenAssist controller instructions."
);
assert.doesNotMatch(
  bridgeSource,
  /async function createCodexSubscriptionRealtimeCall\(/,
  "The production bridge must let app-server negotiate the subscription WebRTC call."
);
assert.match(
  bridgeSource,
  /eventSink\?\.\(\{ type: method, payload \}\)/,
  "The bridge should forward app-server realtime notifications, including the SDP answer."
);

const threadStartParams = bridgeSource.match(
  /function codexThreadStartParams\([\s\S]*?\n}\n\nfunction codexThreadResumeParams/
)?.[0] || "";
assert.ok(threadStartParams, "Codex controller thread start parameters should remain discoverable.");
assert.match(
  threadStartParams,
  /if\s*\(options\.controllerOnly\)\s*params\.model\s*=\s*null/,
  "The hidden Codex Voice controller must explicitly clear the worker model before realtime starts."
);

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
  expiresAt: "2099-08-23T00:00:00.000Z"
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
assert.equal(
  selectCodexSubscriptionRuntime({
    chatGPTBundled: "/Applications/ChatGPT.app/Contents/Resources/codex",
    regular: "/Users/test/.npm-global/bin/codex"
  }),
  "/Applications/ChatGPT.app/Contents/Resources/codex",
  "Static fallback order (used only when version probing fails) prefers the ChatGPT-bundled runtime."
);
// Version-aware selection: the NEWEST installed build speaks the live server
// protocol. Stable outranks the same base version's alphas; missing versions lose.
assert.ok(compareCodexVersions("codex-cli 0.150.1", "codex-cli 0.149.0-alpha.4.3") > 0);
assert.ok(compareCodexVersions("0.149.0", "0.149.0-alpha.4.3") > 0, "A stable release must outrank its own alphas.");
assert.ok(compareCodexVersions("0.151.0-alpha.4", "0.150.1") > 0);
assert.ok(compareCodexVersions("0.149.0-alpha.4.3", "0.149.0-alpha.4") > 0);
assert.equal(compareCodexVersions("0.150.1", "codex-cli 0.150.1"), 0);
assert.ok(compareCodexVersions("", "0.1.0") < 0, "An unprobeable version must lose to any real version.");
assert.equal(
  pickNewestCodexRuntime([
    { path: "/Applications/ChatGPT.app/Contents/Resources/codex", version: "codex-cli 0.149.0-alpha.4.3" },
    { path: "/Users/test/.npm-global/bin/codex", version: "codex-cli 0.150.1" }
  ]),
  "/Users/test/.npm-global/bin/codex",
  "The newest-version runtime must win regardless of install location."
);
assert.equal(
  pickNewestCodexRuntime([{ path: "/only/codex", version: "" }]),
  "/only/codex",
  "A single candidate wins even when its version probe failed."
);
const bridgeResolver = bridgeSource.match(/function resolveCodexSubscriptionExecutable\(\)[\s\S]*?\n}/)?.[0] || "";
assert.match(
  bridgeResolver,
  /pickNewestCodexRuntime/,
  "The bridge must resolve the subscription runtime by newest probed version, not a fixed order."
);
assert.match(
  bridgeResolver,
  /codexExecutableCandidatePaths\(\)/,
  "The subscription resolver must probe EVERY codex install location — resolveCodexExecutable()'s first hit hid a newer npm install and re-broke voice."
);
assert.match(
  bridgeResolver,
  /realpathSync/,
  "Candidates must be deduped by realpath (~/.local/bin/codex symlinks to the standalone binary)."
);
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

assert.equal(validateCodexSubscriptionRealtimeCallURL(), true);
assert.equal(
  validateCodexSubscriptionRealtimeCallURL("https://evil.example/backend-api/codex/realtime/calls"),
  false
);
assert.match(codexSubscriptionRealtimeCallURL, /^https:\/\/chatgpt\.com\/backend-api\/codex\/realtime\/calls\?/);
assert.equal(
  codexSubscriptionCallIDFromLocation("https://chatgpt.com/backend-api/codex/realtime/calls/rtc_test-call?x=1"),
  "rtc_test-call"
);
const testCallUUID = "123e4567-e89b-12d3-a456-426614174000";
assert.equal(
  codexSubscriptionCallIDFromLocation(`https://chatgpt.com/backend-api/codex/realtime/calls/${testCallUUID}`),
  testCallUUID
);
assert.equal(
  codexSubscriptionCallIDFromLocation("https://evil.example/backend-api/codex/realtime/calls/rtc_test-call"),
  ""
);
const directCallHeaders = codexSubscriptionDirectCallHeaders({
  accessToken: "secret-token",
  accountID: "account-123"
});
assert.equal(directCallHeaders.Authorization, "Bearer secret-token");
assert.equal(directCallHeaders["ChatGPT-Account-Id"], "account-123");
assert.equal(directCallHeaders["Content-Type"], "application/sdp");

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
  now: Date.parse("2100-09-01T00:00:00.000Z"),
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
