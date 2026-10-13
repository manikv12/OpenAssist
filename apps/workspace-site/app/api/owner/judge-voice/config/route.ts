import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../../lib/http';
import { requireOwner } from '../../../../../lib/server-auth';
import { callVoiceGateway } from '../../../../../lib/voice-gateway';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    const owner = await requireOwner();
    const response = await callVoiceGateway(request, owner.userId, '/admin/demo-config');
    const body = await response.json().catch(() => ({}));
    return json(body, { status: response.status });
  });
}

export async function PUT(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const owner = await requireOwner();
    const body = await readJsonObject(request, 8_192);
    const response = await callVoiceGateway(request, owner.userId, '/admin/demo-config', {
      method: 'PUT',
      body: JSON.stringify({
        enabled: body.enabled === true,
        apiKey: typeof body.apiKey === 'string' ? body.apiKey : '',
        dailySessionLimit: body.dailySessionLimit,
        sessionSeconds: body.sessionSeconds,
        maxToolCalls: body.maxToolCalls,
      }),
    });
    const result = await response.json().catch(() => ({}));
    return json(result, { status: response.status });
  });
}

export async function DELETE(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const owner = await requireOwner();
    const response = await callVoiceGateway(request, owner.userId, '/admin/demo-config/key', { method: 'DELETE' });
    const body = await response.json().catch(() => ({}));
    return json(body, { status: response.status });
  });
}
