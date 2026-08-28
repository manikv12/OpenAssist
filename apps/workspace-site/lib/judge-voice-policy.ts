import { env } from 'cloudflare:workers';

export type PublicJudgeVoicePolicy = {
  available: boolean;
  sessionSeconds: number;
  maxToolCalls: number;
  dailySessionLimit: number;
};

export async function getPublicJudgeVoicePolicy(): Promise<PublicJudgeVoicePolicy> {
  const unavailable: PublicJudgeVoicePolicy = {
    available: false,
    sessionSeconds: 300,
    maxToolCalls: 12,
    dailySessionLimit: 25,
  };
  if (!env.VOICE_GATEWAY_URL) return unavailable;
  try {
    const response = await fetch(`${env.VOICE_GATEWAY_URL.replace(/\/$/, '')}/health`, {
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(3_000),
    });
    const body = await response.json() as {
      cappedDemoConfigured?: boolean;
      sessionSeconds?: number;
      maxToolCalls?: number;
      dailySessionLimit?: number;
    };
    return {
      available: response.ok && body.cappedDemoConfigured === true,
      sessionSeconds: bounded(body.sessionSeconds, 300, 60, 300),
      maxToolCalls: bounded(body.maxToolCalls, 12, 1, 25),
      dailySessionLimit: bounded(body.dailySessionLimit, 25, 1, 100),
    };
  } catch {
    return unavailable;
  }
}

function bounded(value: unknown, fallback: number, minimum: number, maximum: number): number {
  const parsed = typeof value === 'number' ? value : Number(value);
  if (!Number.isInteger(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, parsed));
}
