import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../../../lib/demo-session';
import { assertSameOrigin, readJsonObject, safeRoute } from '../../../../../../../lib/http';
import { stopJudgeVoiceSession } from '../../../../../../../lib/judge-voice-store';
import { requireOwner } from '../../../../../../../lib/server-auth';
import { callVoiceGateway, demoVoiceUserId } from '../../../../../../../lib/voice-gateway';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireOwner();
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request);
    const sessionId = typeof body.sessionId === 'string' ? body.sessionId : '';
    const toolCalls = typeof body.toolCalls === 'number' ? body.toolCalls : 0;
    const response = await callVoiceGateway(
      request,
      demoVoiceUserId(session.workspaceId),
      '/session/stop',
      { method: 'POST', body: '{}' },
      'demo',
    );
    if (sessionId) await stopJudgeVoiceSession('subscription_session', sessionId, toolCalls);
    return attachDemoCookie(new Response(response.body, {
      status: response.status,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    }), session);
  });
}
