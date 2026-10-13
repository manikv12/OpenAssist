import { createJudgeAccess } from '../../../../lib/judge-access';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../lib/http';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const body = await readJsonObject(request, 4_096);
    const username = typeof body.username === 'string' ? body.username : '';
    const code = typeof body.code === 'string' ? body.code : '';
    const result = await createJudgeAccess(request, username, code);
    return json(
      { status: 'judge_authenticated', expiresAt: result.access.expiresAt },
      { headers: { 'set-cookie': result.setCookie } },
    );
  });
}
