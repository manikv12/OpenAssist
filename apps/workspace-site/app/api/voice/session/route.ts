import { assertSameOrigin, readJsonObject, safeRoute } from '../../../../lib/http';
import { parseRealtimeVoice } from '../../../../lib/realtime-voices';
import { requireOwner } from '../../../../lib/server-auth';
import { callVoiceGateway } from '../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const user = await requireOwner();
    const body = await readJsonObject(request, 310_000);
    const sdp = typeof body.sdp === 'string' ? body.sdp : '';
    const threadId = body.threadId == null || body.threadId === '' ? null : body.threadId;
    const voice = parseRealtimeVoice(body.voice);
    if (!sdp) throw new Response('A WebRTC offer is required.', { status: 400 });
    if (threadId != null && (typeof threadId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f-]{27,40}$/i.test(threadId))) {
      throw new Response('The selected voice conversation is invalid.', { status: 400 });
    }
    const response = await callVoiceGateway(request, user.userId, '/session', {
      method: 'POST',
      body: JSON.stringify({ sdp, threadId, voice }),
    });
    return new Response(response.body, { status: response.status, headers: { 'content-type': response.headers.get('content-type') ?? 'application/json', 'cache-control': 'no-store' } });
  });
}
