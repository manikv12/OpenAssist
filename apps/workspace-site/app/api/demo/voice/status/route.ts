import { json, safeRoute } from '../../../../../lib/http';
import { getPublicJudgeVoicePolicy } from '../../../../../lib/judge-voice-policy';

export async function GET(): Promise<Response> {
  return safeRoute(async () => {
    return json(await getPublicJudgeVoicePolicy());
  });
}
