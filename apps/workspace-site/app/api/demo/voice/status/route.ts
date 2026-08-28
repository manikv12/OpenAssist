import { env } from 'cloudflare:workers';
import { json, safeRoute } from '../../../../../lib/http';

export async function GET(): Promise<Response> {
  return safeRoute(async () => {
    if (!env.VOICE_GATEWAY_URL) return json({ available: false });
    try {
      const response = await fetch(`${env.VOICE_GATEWAY_URL.replace(/\/$/, '')}/health`, {
        headers: { accept: 'application/json' },
        signal: AbortSignal.timeout(3_000),
      });
      const body = await response.json() as { cappedDemoConfigured?: boolean };
      return json({ available: response.ok && body.cappedDemoConfigured === true });
    } catch {
      return json({ available: false });
    }
  });
}
