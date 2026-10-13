import { safeRoute } from '../../../../../lib/http';
import { requireOwner } from '../../../../../lib/server-auth';
import { saveVoiceAuthState } from '../../../../../lib/site-db';
import { callVoiceGateway, voiceAuthPointer } from '../../../../../lib/voice-gateway';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    const user = await requireOwner();
    const response = await callVoiceGateway(request, user.userId, '/auth/status');
    const clone = response.clone();
    const body = await clone.json().catch(() => ({})) as { status?: 'pending' | 'ready' | 'failed' };
    if (response.ok && (body.status === 'pending' || body.status === 'ready')) {
      await saveVoiceAuthState(user.userId, await voiceAuthPointer(user.userId), body.status);
    }
    return new Response(response.body, { status: response.status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
  });
}
