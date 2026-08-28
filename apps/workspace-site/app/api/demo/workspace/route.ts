import { attachDemoCookie, getOrCreateDemoSession, replaceDemoSession } from '../../../../lib/demo-session';
import { loadDemoWorkspace } from '../../../../lib/demo-store';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../lib/http';
import { requireDemoAccess } from '../../../../lib/server-auth';
import { callVoiceGateway, demoVoiceUserId } from '../../../../lib/voice-gateway';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireDemoAccess(request);
    const session = await getOrCreateDemoSession(request);
    return attachDemoCookie(json({ workspace: await loadDemoWorkspace(session.workspaceId), expiresAt: session.expiresAt }), session);
  });
}

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireDemoAccess(request);
    assertSameOrigin(request);
    const body = await readJsonObject(request);
    if (body.action !== 'reset') throw new Error('This demo workspace action is not available.');
    const current = await getOrCreateDemoSession(request);
    await callVoiceGateway(
      request,
      demoVoiceUserId(current.workspaceId),
      '/disconnect',
      { method: 'POST', body: '{}' },
      'demo',
    ).catch(() => undefined);
    const session = await replaceDemoSession(request, current.workspaceId);
    return attachDemoCookie(json({ workspace: await loadDemoWorkspace(session.workspaceId), expiresAt: session.expiresAt }), session);
  });
}
