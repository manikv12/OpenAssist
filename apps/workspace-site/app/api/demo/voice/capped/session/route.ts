import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../lib/demo-session';
import { recordDemoVoiceSession } from '../../../../../../lib/demo-store';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../../../lib/http';
import { getPublicJudgeVoicePolicy } from '../../../../../../lib/judge-voice-policy';
import { activateJudgeVoiceSession, failJudgeVoiceEvent, reserveJudgeVoiceSession } from '../../../../../../lib/judge-voice-store';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request, 310_000);
    const sdp = typeof body.sdp === 'string' ? body.sdp : '';
    if (!sdp) throw new Response('A WebRTC offer is required.', { status: 400 });
    const policy = await getPublicJudgeVoicePolicy();
    if (!policy.available) throw new Response('The funded judge voice demo is not enabled.', { status: 503 });
    const reservation = await reserveJudgeVoiceSession(
      session.workspaceId,
      'funded_session',
      policy.sessionSeconds,
      policy.dailySessionLimit,
    );
    if (!reservation) throw new Response('The funded judge voice daily limit has been reached. Use My ChatGPT instead.', { status: 429 });
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/demo/realtime',
      { method: 'POST', body: JSON.stringify({ sdp }) },
      'demo',
    );
    const result = await response.json().catch(() => ({})) as Record<string, unknown>;
    if (!response.ok) {
      await failJudgeVoiceEvent(reservation.eventId, response.status);
      return attachDemoCookie(json(result, { status: response.status }), session);
    }
    const callId = typeof result.callId === 'string' ? result.callId : '';
    if (!callId) {
      await failJudgeVoiceEvent(reservation.eventId, 502);
      throw new Response('The funded judge voice service did not return a session.', { status: 502 });
    }
    await activateJudgeVoiceSession(
      reservation.eventId,
      'funded_session',
      callId,
      typeof result.expiresAfterSeconds === 'number' ? result.expiresAfterSeconds : policy.sessionSeconds,
    );
    await recordDemoVoiceSession(session.workspaceId);
    return attachDemoCookie(json(result), session);
  });
}
