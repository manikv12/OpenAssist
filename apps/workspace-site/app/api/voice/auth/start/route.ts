import { assertSameOrigin, safeRoute } from '../../../../../lib/http';
import { requireOwner } from '../../../../../lib/server-auth';
import { saveVoiceAuthState } from '../../../../../lib/site-db';
import { callVoiceGateway, voiceAuthPointer } from '../../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const user = await requireOwner();
    const response = await callVoiceGateway(request, user.userId, '/auth/start', { method: 'POST', body: '{}' });
    if (response.ok) await saveVoiceAuthState(user.userId, await voiceAuthPointer(user.userId), 'pending');
    return new Response(response.body, { status: response.status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
  });
}
