import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../lib/demo-session';
import { recordDemoVoiceSession } from '../../../../../../lib/demo-store';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../../../lib/http';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request, 310_000);
    const sdp = typeof body.sdp === 'string' ? body.sdp : '';
    if (!sdp) throw new Response('A WebRTC offer is required.', { status: 400 });
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/demo/realtime',
      { method: 'POST', body: JSON.stringify({ sdp }) },
      'demo',
    );
    const result = await response.json().catch(() => ({})) as Record<string, unknown>;
    if (!response.ok) return attachDemoCookie(json(result, { status: response.status }), session);
    await recordDemoVoiceSession(session.workspaceId);
    return attachDemoCookie(json(result), session);
  });
}
