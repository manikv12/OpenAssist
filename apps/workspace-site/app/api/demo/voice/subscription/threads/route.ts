import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../lib/demo-session';
import { safeRoute } from '../../../../../../lib/http';
import { requireSignedInUser } from '../../../../../../lib/server-auth';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../lib/voice-gateway';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireSignedInUser();
    const session = await getOrCreateDemoSession(request);
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/threads',
      { method: 'GET' },
      'demo',
    );
    return attachDemoCookie(new Response(response.body, {
      status: response.status,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    }), session);
  });
}
