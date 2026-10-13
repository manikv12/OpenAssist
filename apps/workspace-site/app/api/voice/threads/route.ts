import { safeRoute } from '../../../../lib/http';
import { requireOwner } from '../../../../lib/server-auth';
import { callVoiceGateway } from '../../../../lib/voice-gateway';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    const user = await requireOwner();
    const response = await callVoiceGateway(request, user.userId, '/threads', { method: 'GET' });
    return new Response(response.body, {
      status: response.status,
      headers: {
        'content-type': response.headers.get('content-type') ?? 'application/json',
        'cache-control': 'no-store',
      },
    });
  });
}
