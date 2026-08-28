import { getJudgeVoiceUsage } from '../../../../../lib/judge-voice-store';
import { safeRoute } from '../../../../../lib/http';
import { requireOwner } from '../../../../../lib/server-auth';

export async function GET(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireOwner();
    const days = Number(new URL(request.url).searchParams.get('days') ?? 7);
    return getJudgeVoiceUsage(days);
  });
}
