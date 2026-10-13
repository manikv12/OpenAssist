import { env } from 'cloudflare:workers';
import { randomBase64Url, sha256 } from './security';

export type JudgeVoiceKind = 'funded_session' | 'subscription_session' | 'subscription_sign_in';
export type JudgeVoiceEventStatus = 'starting' | 'active' | 'stopped' | 'failed' | 'expired';

export type JudgeVoiceUsage = {
  periodDays: number;
  todaySessions: number;
  fundedToday: number;
  subscriptionToday: number;
  activeSessions: number;
  failures: number;
  uniqueJudges: number;
  totalMinutes: number;
  recent: Array<{
    eventId: string;
    judgeLabel: string;
    kind: JudgeVoiceKind;
    status: JudgeVoiceEventStatus;
    startedAt: number;
    endedAt: number | null;
    toolCalls: number;
    errorCode: string | null;
  }>;
};

function database(): D1Database {
  if (!env.DB) throw new Error('The site database is unavailable.');
  return env.DB;
}

async function visitorHash(workspaceId: string): Promise<string> {
  return sha256({ purpose: 'judge_voice_visitor', workspaceId });
}

async function externalIdHash(kind: JudgeVoiceKind, externalId: string): Promise<string> {
  return sha256({ purpose: 'judge_voice_external_id', kind, externalId });
}

function safeErrorCode(status: number): string {
  if (!Number.isInteger(status) || status < 400 || status > 599) return 'request_failed';
  return `http_${status}`;
}

async function expireStaleSessions(now = Date.now()): Promise<void> {
  await database().prepare(
    `UPDATE judge_voice_events
     SET status = 'expired', ended_at = COALESCE(ended_at, expires_at)
     WHERE status IN ('starting', 'active') AND expires_at IS NOT NULL AND expires_at <= ?`,
  ).bind(now).run();
}

/**
 * Reserve a judge session before contacting the voice gateway. A funded
 * session can be rejected when the owner-configured daily allowance is used.
 */
export async function reserveJudgeVoiceSession(
  workspaceId: string,
  kind: Exclude<JudgeVoiceKind, 'subscription_sign_in'>,
  expiresAfterSeconds: number,
  dailyLimit?: number,
): Promise<{ eventId: string } | null> {
  const db = database();
  const now = Date.now();
  await expireStaleSessions(now);
  if (kind === 'funded_session' && dailyLimit) {
    const todayStart = Date.UTC(new Date(now).getUTCFullYear(), new Date(now).getUTCMonth(), new Date(now).getUTCDate());
    const row = await db.prepare(
      `SELECT COUNT(*) AS count FROM judge_voice_events
       WHERE kind = 'funded_session' AND started_at >= ? AND status != 'failed'`,
    ).bind(todayStart).first<{ count: number }>();
    if (Number(row?.count ?? 0) >= dailyLimit) return null;
  }

  const eventId = randomBase64Url(18);
  await db.prepare(
    `INSERT INTO judge_voice_events
      (event_id, visitor_hash, kind, status, started_at, expires_at, tool_calls)
     VALUES (?, ?, ?, 'starting', ?, ?, 0)`,
  ).bind(
    eventId,
    await visitorHash(workspaceId),
    kind,
    now,
    now + Math.max(60, Math.min(expiresAfterSeconds, 30 * 60)) * 1_000,
  ).run();
  return { eventId };
}

export async function activateJudgeVoiceSession(
  eventId: string,
  kind: Exclude<JudgeVoiceKind, 'subscription_sign_in'>,
  externalId: string,
  expiresAfterSeconds: number,
): Promise<void> {
  const now = Date.now();
  await database().prepare(
    `UPDATE judge_voice_events
     SET status = 'active', external_id_hash = ?, expires_at = ?
     WHERE event_id = ? AND kind = ? AND status = 'starting'`,
  ).bind(
    await externalIdHash(kind, externalId),
    now + Math.max(60, Math.min(expiresAfterSeconds, 30 * 60)) * 1_000,
    eventId,
    kind,
  ).run();
}

export async function failJudgeVoiceEvent(eventId: string, responseStatus: number): Promise<void> {
  await database().prepare(
    `UPDATE judge_voice_events
     SET status = 'failed', ended_at = ?, error_code = ?
     WHERE event_id = ?`,
  ).bind(Date.now(), safeErrorCode(responseStatus), eventId).run();
}

export async function recordJudgeVoiceSignIn(workspaceId: string, responseStatus: number): Promise<void> {
  const now = Date.now();
  await database().prepare(
    `INSERT INTO judge_voice_events
      (event_id, visitor_hash, kind, status, started_at, ended_at, tool_calls, error_code)
     VALUES (?, ?, 'subscription_sign_in', ?, ?, ?, 0, ?)`,
  ).bind(
    randomBase64Url(18),
    await visitorHash(workspaceId),
    responseStatus >= 200 && responseStatus < 400 ? 'stopped' : 'failed',
    now,
    now,
    responseStatus >= 200 && responseStatus < 400 ? null : safeErrorCode(responseStatus),
  ).run();
}

export async function stopJudgeVoiceSession(
  kind: Exclude<JudgeVoiceKind, 'subscription_sign_in'>,
  externalId: string,
  toolCalls: number,
): Promise<void> {
  await database().prepare(
    `UPDATE judge_voice_events
     SET status = 'stopped', ended_at = ?, tool_calls = ?
     WHERE kind = ? AND external_id_hash = ? AND status IN ('starting', 'active')`,
  ).bind(
    Date.now(),
    Math.max(0, Math.min(Number.isInteger(toolCalls) ? toolCalls : 0, 1_000)),
    kind,
    await externalIdHash(kind, externalId),
  ).run();
}

export async function getJudgeVoiceUsage(periodDays = 7): Promise<JudgeVoiceUsage> {
  const db = database();
  const now = Date.now();
  await expireStaleSessions(now);
  const days = Math.max(1, Math.min(Number.isInteger(periodDays) ? periodDays : 7, 30));
  const since = now - days * 24 * 60 * 60 * 1_000;
  const todayStart = Date.UTC(new Date(now).getUTCFullYear(), new Date(now).getUTCMonth(), new Date(now).getUTCDate());

  const [totals, recentResult] = await Promise.all([
    db.prepare(
      `SELECT
         SUM(CASE WHEN kind != 'subscription_sign_in' AND started_at >= ? AND status != 'failed' THEN 1 ELSE 0 END) AS today_sessions,
         SUM(CASE WHEN kind = 'funded_session' AND started_at >= ? AND status != 'failed' THEN 1 ELSE 0 END) AS funded_today,
         SUM(CASE WHEN kind = 'subscription_session' AND started_at >= ? AND status != 'failed' THEN 1 ELSE 0 END) AS subscription_today,
         SUM(CASE WHEN kind != 'subscription_sign_in' AND status = 'active' AND expires_at > ? THEN 1 ELSE 0 END) AS active_sessions,
         SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failures,
         COUNT(DISTINCT visitor_hash) AS unique_judges,
         SUM(CASE WHEN kind != 'subscription_sign_in' AND status != 'failed'
           THEN MAX(0, COALESCE(ended_at, MIN(?, expires_at), ?) - started_at) ELSE 0 END) AS duration_ms
       FROM judge_voice_events WHERE started_at >= ?`,
    ).bind(todayStart, todayStart, todayStart, now, now, now, since).first<{
      today_sessions: number | null;
      funded_today: number | null;
      subscription_today: number | null;
      active_sessions: number | null;
      failures: number | null;
      unique_judges: number | null;
      duration_ms: number | null;
    }>(),
    db.prepare(
      `SELECT event_id, visitor_hash, kind, status, started_at, ended_at, tool_calls, error_code
       FROM judge_voice_events WHERE started_at >= ?
       ORDER BY started_at DESC LIMIT 30`,
    ).bind(since).all<{
      event_id: string;
      visitor_hash: string;
      kind: JudgeVoiceKind;
      status: JudgeVoiceEventStatus;
      started_at: number;
      ended_at: number | null;
      tool_calls: number;
      error_code: string | null;
    }>(),
  ]);

  return {
    periodDays: days,
    todaySessions: Number(totals?.today_sessions ?? 0),
    fundedToday: Number(totals?.funded_today ?? 0),
    subscriptionToday: Number(totals?.subscription_today ?? 0),
    activeSessions: Number(totals?.active_sessions ?? 0),
    failures: Number(totals?.failures ?? 0),
    uniqueJudges: Number(totals?.unique_judges ?? 0),
    totalMinutes: Math.round(Number(totals?.duration_ms ?? 0) / 60_000),
    recent: recentResult.results.map((row) => ({
      eventId: row.event_id,
      judgeLabel: `Judge ${row.visitor_hash.slice(0, 6).toUpperCase()}`,
      kind: row.kind,
      status: row.status,
      startedAt: row.started_at,
      endedAt: row.ended_at,
      toolCalls: row.tool_calls,
      errorCode: row.error_code,
    })),
  };
}
