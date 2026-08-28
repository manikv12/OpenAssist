import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../lib/demo-session';
import { assertSameOrigin, readJsonObject, safeRoute } from '../../../../../../lib/http';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request, 310_000);
    const sdp = typeof body.sdp === 'string' ? body.sdp : '';
    const threadId = body.threadId == null || body.threadId === '' ? null : body.threadId;
    if (!sdp) throw new Response('A WebRTC offer is required.', { status: 400 });
    if (threadId != null && (typeof threadId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f-]{27,40}$/i.test(threadId))) {
      throw new Response('The selected voice conversation is invalid.', { status: 400 });
    }
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/session',
      { method: 'POST', body: JSON.stringify({ sdp, threadId }) },
      'demo',
    );
    return attachDemoCookie(new Response(response.body, {
      status: response.status,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    }), session);
  });
}
