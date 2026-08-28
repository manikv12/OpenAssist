import { json, safeRoute } from '../../../../../lib/http';
import { getPublicJudgeVoicePolicy } from '../../../../../lib/judge-voice-policy';
import { requireSignedInUser } from '../../../../../lib/server-auth';

export async function GET(): Promise<Response> {
  return safeRoute(async () => {
    await requireSignedInUser();
    return json(await getPublicJudgeVoicePolicy());
  });
}
