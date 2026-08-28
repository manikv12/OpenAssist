import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../../lib/demo-session';
import { safeRoute } from '../../../../../../../lib/http';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../../lib/voice-gateway';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    const session = await getOrCreateDemoSession(request);
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/auth/status',
      { method: 'GET' },
      'demo',
    );
    return attachDemoCookie(new Response(response.body, {
      status: response.status,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    }), session);
  });
}
