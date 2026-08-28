import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../../lib/demo-session';
import { assertSameOrigin, safeRoute } from '../../../../../../../lib/http';
import { recordJudgeVoiceSignIn } from '../../../../../../../lib/judge-voice-store';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/auth/start',
      { method: 'POST', body: '{}' },
      'demo',
    );
    await recordJudgeVoiceSignIn(session.workspaceId, response.status);
    return attachDemoCookie(new Response(response.body, {
      status: response.status,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    }), session);
  });
}
