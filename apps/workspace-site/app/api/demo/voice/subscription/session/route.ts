import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../lib/demo-session';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../../../lib/http';
import { activateJudgeVoiceSession, failJudgeVoiceEvent, reserveJudgeVoiceSession } from '../../../../../../lib/judge-voice-store';
import { parseRealtimeVoice } from '../../../../../../lib/realtime-voices';
import { requireSignedInUser } from '../../../../../../lib/server-auth';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireSignedInUser();
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request, 310_000);
    const sdp = typeof body.sdp === 'string' ? body.sdp : '';
    const threadId = body.threadId == null || body.threadId === '' ? null : body.threadId;
    const voice = parseRealtimeVoice(body.voice);
    if (!sdp) throw new Response('A WebRTC offer is required.', { status: 400 });
    if (threadId != null && (typeof threadId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f-]{27,40}$/i.test(threadId))) {
      throw new Response('The selected voice conversation is invalid.', { status: 400 });
    }
    const reservation = await reserveJudgeVoiceSession(session.workspaceId, 'subscription_session', 1_800);
    if (!reservation) throw new Response('The judge voice session could not be reserved.', { status: 503 });
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/session',
      { method: 'POST', body: JSON.stringify({ sdp, threadId, voice }) },
      'demo',
    );
    const result = await response.json().catch(() => ({})) as Record<string, unknown>;
    if (!response.ok) {
      await failJudgeVoiceEvent(reservation.eventId, response.status);
      return attachDemoCookie(json(result, { status: response.status }), session);
    }
    const sessionId = typeof result.sessionId === 'string' ? result.sessionId : '';
    if (!sessionId) {
      await failJudgeVoiceEvent(reservation.eventId, 502);
      throw new Response('The judge subscription voice service did not return a session.', { status: 502 });
    }
    await activateJudgeVoiceSession(reservation.eventId, 'subscription_session', sessionId, 1_800);
    return attachDemoCookie(json(result), session);
  });
}
