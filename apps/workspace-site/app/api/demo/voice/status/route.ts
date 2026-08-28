import { json, safeRoute } from '../../../../../lib/http';
import { getPublicJudgeVoicePolicy } from '../../../../../lib/judge-voice-policy';
import { requireDemoAccess } from '../../../../../lib/server-auth';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireDemoAccess(request);
    return json(await getPublicJudgeVoicePolicy());
  });
}
