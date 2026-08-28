import { clearJudgeAccessCookie } from '../../../../lib/judge-access';
import { assertSameOrigin, json, safeRoute } from '../../../../lib/http';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    return json({ status: 'signed_out' }, { headers: { 'set-cookie': clearJudgeAccessCookie(request) } });
  });
}
