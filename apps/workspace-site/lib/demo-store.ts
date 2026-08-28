import { env } from 'cloudflare:workers';
import {
  DEMO_ACTIVITY,
  DEMO_ACCOUNTS,
  DEMO_EVENTS,
  DEMO_MAIL,
  DEMO_MEMORY,
  DEMO_NOTES,
  DEMO_TASKS,
  type DemoActivityItem,
  type DemoEvent,
  type DemoMemoryFact,
  type DemoMessage,
  type DemoNote,
  type DemoTask,
  type DemoWorkspaceState,
} from './demo-data';
import { randomBase64Url } from './security';
import type { WorkspaceToolName } from './tool-registry';

const DEMO_LIFETIME_MS = 24 * 60 * 60 * 1000;
const MAX_TASKS = 50;
const MAX_EVENTS = 50;
const MAX_NOTES = 25;
const MAX_MEMORY_FACTS = 30;
const MAX_ACTIVITY_ITEMS = 100;
const FUNDED_VOICE_ACTOR = 'OpenAI demo voice';
const FUNDED_VOICE_ACTION = 'Started a funded judge voice session';

type Arguments = Record<string, unknown>;

type DemoWorkspaceRow = {
  workspace_id: string;
  expires_at: number;
};

function database(): D1Database {
  if (!env.DB) throw new Error('The demo database is unavailable.');
  return env.DB;
}

function clippedText(value: unknown, fallback: string, maxLength: number): string {
  const text = typeof value === 'string' ? value.trim() : '';
  return (text || fallback).slice(0, maxLength);
}

function optionalText(value: unknown, maxLength: number): string | null {
  if (typeof value !== 'string' || !value.trim()) return null;
  return value.trim().slice(0, maxLength);
}

function safeIdentifier(value: unknown, label: string): string {
  const id = clippedText(value, '', 160);
  if (!id || !/^[A-Za-z0-9_:@.-]+$/.test(id)) throw new Error(`${label} is invalid.`);
  return id;
}

function stringArray(value: unknown, maxItems = 10, itemLength = 40): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is string => typeof item === 'string')
    .map((item) => item.trim().slice(0, itemLength))
    .filter(Boolean)
    .slice(0, maxItems);
}

function parseStringArray(value: string): string[] {
  try {
    return stringArray(JSON.parse(value));
  } catch {
    return [];
  }
}

function preview(content: string): string {
  return content.replace(/\s+/g, ' ').trim().slice(0, 150) || 'Empty note';
}

function displayTime(value: string, timeZone: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value.slice(0, 40);
  try {
    return new Intl.DateTimeFormat('en-US', {
      timeZone,
      hour: 'numeric',
      minute: '2-digit',
    }).format(date);
  } catch {
    return new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' }).format(date);
  }
}

function displayDay(value: string, timeZone: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'Upcoming';
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  const today = formatter.format(new Date());
  const tomorrow = formatter.format(new Date(Date.now() + 24 * 60 * 60 * 1000));
  const target = formatter.format(date);
  if (target === today) return 'Today';
  if (target === tomorrow) return 'Tomorrow';
  return new Intl.DateTimeFormat('en-US', { timeZone, month: 'short', day: 'numeric' }).format(date);
}

async function deleteExpiredWorkspaces(now: number): Promise<void> {
  await database().prepare('DELETE FROM demo_workspaces WHERE expires_at <= ?').bind(now).run();
}

async function seedDemoWorkspace(workspaceId: string, expiresAt: number): Promise<void> {
  const db = database();
  const now = Date.now();
  const statements: D1PreparedStatement[] = [
    db.prepare(
      'INSERT INTO demo_workspaces (workspace_id, created_at, updated_at, expires_at) VALUES (?, ?, ?, ?)',
    ).bind(workspaceId, now, now, expiresAt),
  ];

  DEMO_MAIL.forEach((message, index) => {
    statements.push(db.prepare(
      `INSERT INTO demo_messages
        (workspace_id, message_id, account, sender, subject, snippet, time_label, unread, urgent, has_attachment, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      workspaceId,
      message.id,
      message.account,
      message.sender,
      message.subject,
      message.snippet,
      message.time,
      Number(message.unread),
      Number(message.urgent),
      Number(message.hasAttachment),
      now - index * 60_000,
    ));
  });

  DEMO_TASKS.forEach((task, index) => {
    statements.push(db.prepare(
      `INSERT INTO demo_tasks
        (workspace_id, task_id, title, list_name, due, tags_json, completed, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      workspaceId,
      task.id,
      task.title,
      task.list,
      task.due,
      JSON.stringify(task.tags),
      Number(task.completed),
      now - index * 60_000,
      now - index * 60_000,
    ));
  });

  DEMO_EVENTS.forEach((event, index) => {
    statements.push(db.prepare(
      `INSERT INTO demo_events
        (workspace_id, event_id, title, account, start, end, day_label, reminder, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      workspaceId,
      event.id,
      event.title,
      event.account,
      event.start,
      event.end,
      event.day,
      event.reminder,
      now - index * 60_000,
      now - index * 60_000,
    ));
  });

  DEMO_NOTES.forEach((note, index) => {
    statements.push(db.prepare(
      `INSERT INTO demo_notes
        (workspace_id, note_id, title, content, updated_label, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      workspaceId,
      note.id,
      note.title,
      note.content,
      note.updated,
      now - index * 60_000,
      now - index * 60_000,
    ));
  });

  DEMO_MEMORY.forEach((fact, index) => {
    statements.push(db.prepare(
      `INSERT INTO demo_memory
        (workspace_id, fact_id, category, fact, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).bind(
      workspaceId,
      fact.id,
      fact.category,
      fact.fact,
      now - index * 60_000,
      now - index * 60_000,
    ));
  });

  DEMO_ACTIVITY.forEach((item, index) => {
    statements.push(db.prepare(
      `INSERT INTO demo_activity
        (workspace_id, activity_id, actor, action, time_label, type, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      workspaceId,
      item.id,
      item.actor,
      item.action,
      item.time,
      item.type,
      now - index * 60_000,
    ));
  });

  await db.batch(statements);
}

export async function createDemoWorkspace(): Promise<{ workspaceId: string; expiresAt: number }> {
  const now = Date.now();
  await deleteExpiredWorkspaces(now);
  const workspaceId = randomBase64Url(24);
  const expiresAt = now + DEMO_LIFETIME_MS;
  await seedDemoWorkspace(workspaceId, expiresAt);
  return { workspaceId, expiresAt };
}

export async function ensureDemoWorkspace(workspaceId: string, expiresAt: number): Promise<boolean> {
  const now = Date.now();
  await deleteExpiredWorkspaces(now);
  const row = await database().prepare(
    'SELECT workspace_id, expires_at FROM demo_workspaces WHERE workspace_id = ?',
  ).bind(workspaceId).first<DemoWorkspaceRow>();
  if (row && row.expires_at > now) return true;
  if (expiresAt <= now) return false;
  await seedDemoWorkspace(workspaceId, expiresAt);
  return true;
}

export async function destroyDemoWorkspace(workspaceId: string): Promise<void> {
  await database().prepare('DELETE FROM demo_workspaces WHERE workspace_id = ?').bind(workspaceId).run();
}

export async function loadDemoWorkspace(workspaceId: string): Promise<DemoWorkspaceState> {
  const db = database();
  const [messageResult, taskResult, eventResult, noteResult, memoryResult, activityResult] = await Promise.all([
    db.prepare(
      `SELECT message_id, account, sender, subject, snippet, time_label, unread, urgent, has_attachment
       FROM demo_messages WHERE workspace_id = ? ORDER BY updated_at DESC`,
    ).bind(workspaceId).all<{
      message_id: string;
      account: string;
      sender: string;
      subject: string;
      snippet: string;
      time_label: string;
      unread: number;
      urgent: number;
      has_attachment: number;
    }>(),
    db.prepare(
      `SELECT task_id, title, list_name, due, tags_json, completed
       FROM demo_tasks WHERE workspace_id = ? ORDER BY updated_at DESC`,
    ).bind(workspaceId).all<{
      task_id: string;
      title: string;
      list_name: string;
      due: string;
      tags_json: string;
      completed: number;
    }>(),
    db.prepare(
      `SELECT event_id, title, account, start, end, day_label, reminder
       FROM demo_events WHERE workspace_id = ? ORDER BY updated_at DESC`,
    ).bind(workspaceId).all<{
      event_id: string;
      title: string;
      account: string;
      start: string;
      end: string;
      day_label: string;
      reminder: string;
    }>(),
    db.prepare(
      `SELECT note_id, title, content, updated_label
       FROM demo_notes WHERE workspace_id = ? ORDER BY updated_at DESC`,
    ).bind(workspaceId).all<{
      note_id: string;
      title: string;
      content: string;
      updated_label: string;
    }>(),
    db.prepare(
      `SELECT fact_id, category, fact
       FROM demo_memory WHERE workspace_id = ? ORDER BY updated_at DESC`,
    ).bind(workspaceId).all<{
      fact_id: string;
      category: string;
      fact: string;
    }>(),
    db.prepare(
      `SELECT activity_id, actor, action, time_label, type
       FROM demo_activity WHERE workspace_id = ? ORDER BY created_at DESC LIMIT ?`,
    ).bind(workspaceId, MAX_ACTIVITY_ITEMS).all<{
      activity_id: string;
      actor: string;
      action: string;
      time_label: string;
      type: 'read' | 'write';
    }>(),
  ]);

  const messages: DemoMessage[] = messageResult.results.map((row) => ({
    id: row.message_id,
    account: row.account,
    sender: row.sender,
    subject: row.subject,
    snippet: row.snippet,
    time: row.time_label,
    unread: Boolean(row.unread),
    urgent: Boolean(row.urgent),
    hasAttachment: Boolean(row.has_attachment),
  }));
  const tasks: DemoTask[] = taskResult.results.map((row) => ({
    id: row.task_id,
    title: row.title,
    list: row.list_name,
    due: row.due,
    tags: parseStringArray(row.tags_json),
    completed: Boolean(row.completed),
  }));
  const events: DemoEvent[] = eventResult.results.map((row) => ({
    id: row.event_id,
    title: row.title,
    account: row.account,
    start: row.start,
    end: row.end,
    day: row.day_label,
    reminder: row.reminder,
  }));
  const notes: DemoNote[] = noteResult.results.map((row) => ({
    id: row.note_id,
    title: row.title,
    updated: row.updated_label,
    preview: preview(row.content),
    content: row.content,
  }));
  const memory: DemoMemoryFact[] = memoryResult.results.map((row) => ({
    id: row.fact_id,
    category: row.category,
    fact: row.fact,
  }));
  const activity: DemoActivityItem[] = activityResult.results.map((row) => ({
    id: row.activity_id,
    actor: row.actor,
    action: row.action,
    time: row.time_label,
    type: row.type,
  }));

  return { accounts: DEMO_ACCOUNTS, messages, tasks, events, notes, memory, activity };
}

async function itemCount(workspaceId: string, table: 'demo_tasks' | 'demo_events' | 'demo_notes' | 'demo_memory'): Promise<number> {
  const row = await database().prepare(
    `SELECT COUNT(*) AS count FROM ${table} WHERE workspace_id = ?`,
  ).bind(workspaceId).first<{ count: number }>();
  return Number(row?.count ?? 0);
}

async function addActivity(workspaceId: string, actor: string, action: string, type: 'read' | 'write'): Promise<void> {
  const db = database();
  const now = Date.now();
  await db.batch([
    db.prepare(
      `INSERT INTO demo_activity
        (workspace_id, activity_id, actor, action, time_label, type, created_at)
       VALUES (?, ?, ?, ?, 'Just now', ?, ?)`,
    ).bind(workspaceId, randomBase64Url(18), actor.slice(0, 60), action.slice(0, 240), type, now),
    db.prepare(
      `DELETE FROM demo_activity
       WHERE workspace_id = ? AND activity_id NOT IN (
         SELECT activity_id FROM demo_activity WHERE workspace_id = ? ORDER BY created_at DESC LIMIT ?
       )`,
    ).bind(workspaceId, workspaceId, MAX_ACTIVITY_ITEMS),
    db.prepare('UPDATE demo_workspaces SET updated_at = ? WHERE workspace_id = ?').bind(now, workspaceId),
  ]);
}

export async function recordDemoRead(workspaceId: string, title: string): Promise<void> {
  await addActivity(workspaceId, 'ChatGPT', `Read: ${title}`, 'read');
}

export async function recordDemoVoiceSession(workspaceId: string): Promise<void> {
  await addActivity(workspaceId, FUNDED_VOICE_ACTOR, FUNDED_VOICE_ACTION, 'write');
}

export type DemoWriteResult = {
  status: 'completed';
  verified: true;
  mode: 'synthetic_demo';
  itemId?: string;
};

export async function executeDemoWrite(
  workspaceId: string,
  name: WorkspaceToolName,
  args: Arguments,
  actor: string,
  title: string,
): Promise<DemoWriteResult> {
  const db = database();
  const now = Date.now();
  let itemId: string | undefined;

  switch (name) {
    case 'workspace_set_mail_read_state': {
      const ids = stringArray(args.messageIds, 20, 160);
      if (!ids.length) throw new Error('At least one demo message is required.');
      const unread = args.state === 'unread' ? 1 : 0;
      await db.batch(ids.map((id) => db.prepare(
        'UPDATE demo_messages SET unread = ?, updated_at = ? WHERE workspace_id = ? AND message_id = ?',
      ).bind(unread, now, workspaceId, id)));
      break;
    }
    case 'workspace_create_task': {
      if (await itemCount(workspaceId, 'demo_tasks') >= MAX_TASKS) throw new Error('This demo workspace already has the maximum number of tasks.');
      itemId = randomBase64Url(18);
      await db.prepare(
        `INSERT INTO demo_tasks
          (workspace_id, task_id, title, list_name, due, tags_json, completed, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`,
      ).bind(
        workspaceId,
        itemId,
        clippedText(args.title, 'New task', 200),
        clippedText(args.list, 'My Tasks', 80),
        clippedText(args.due, 'No date', 64),
        JSON.stringify(stringArray(args.tags)),
        now,
        now,
      ).run();
      break;
    }
    case 'workspace_update_task': {
      itemId = safeIdentifier(args.taskId, 'Task ID');
      const existing = await db.prepare(
        `SELECT title, list_name, due, tags_json, completed FROM demo_tasks
         WHERE workspace_id = ? AND task_id = ?`,
      ).bind(workspaceId, itemId).first<{
        title: string;
        list_name: string;
        due: string;
        tags_json: string;
        completed: number;
      }>();
      if (!existing) throw new Error('The demo task no longer exists.');
      const status = optionalText(args.status, 24);
      await db.prepare(
        `UPDATE demo_tasks SET title = ?, list_name = ?, due = ?, tags_json = ?, completed = ?, updated_at = ?
         WHERE workspace_id = ? AND task_id = ?`,
      ).bind(
        optionalText(args.title, 200) ?? existing.title,
        optionalText(args.list, 80) ?? existing.list_name,
        optionalText(args.due, 64) ?? existing.due,
        Array.isArray(args.tags) ? JSON.stringify(stringArray(args.tags)) : existing.tags_json,
        status ? Number(status === 'completed') : existing.completed,
        now,
        workspaceId,
        itemId,
      ).run();
      break;
    }
    case 'workspace_delete_task': {
      itemId = safeIdentifier(args.taskId, 'Task ID');
      await db.prepare('DELETE FROM demo_tasks WHERE workspace_id = ? AND task_id = ?').bind(workspaceId, itemId).run();
      break;
    }
    case 'workspace_create_calendar_event': {
      if (await itemCount(workspaceId, 'demo_events') >= MAX_EVENTS) throw new Error('This demo workspace already has the maximum number of events.');
      itemId = randomBase64Url(18);
      const timeZone = clippedText(args.timeZone, 'America/Chicago', 80);
      const start = clippedText(args.start, 'Upcoming', 100);
      const end = clippedText(args.end, start, 100);
      const reminder = Array.isArray(args.reminderMinutes) && Number.isInteger(args.reminderMinutes[0])
        ? `${args.reminderMinutes[0]} minutes before`
        : '10 minutes before';
      await db.prepare(
        `INSERT INTO demo_events
          (workspace_id, event_id, title, account, start, end, day_label, reminder, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        workspaceId,
        itemId,
        clippedText(args.summary, 'New event', 200),
        clippedText(args.account, 'Main', 80),
        displayTime(start, timeZone),
        displayTime(end, timeZone),
        displayDay(start, timeZone),
        reminder,
        now,
        now,
      ).run();
      break;
    }
    case 'workspace_update_calendar_event': {
      itemId = safeIdentifier(args.eventId, 'Event ID');
      const existing = await db.prepare(
        `SELECT title, account, start, end, day_label, reminder FROM demo_events
         WHERE workspace_id = ? AND event_id = ?`,
      ).bind(workspaceId, itemId).first<{
        title: string;
        account: string;
        start: string;
        end: string;
        day_label: string;
        reminder: string;
      }>();
      if (!existing) throw new Error('The demo event no longer exists.');
      const timeZone = clippedText(args.timeZone, 'America/Chicago', 80);
      const rawStart = optionalText(args.start, 100);
      const rawEnd = optionalText(args.end, 100);
      const reminder = Array.isArray(args.reminderMinutes) && Number.isInteger(args.reminderMinutes[0])
        ? `${args.reminderMinutes[0]} minutes before`
        : existing.reminder;
      await db.prepare(
        `UPDATE demo_events SET title = ?, account = ?, start = ?, end = ?, day_label = ?, reminder = ?, updated_at = ?
         WHERE workspace_id = ? AND event_id = ?`,
      ).bind(
        optionalText(args.summary, 200) ?? existing.title,
        optionalText(args.account, 80) ?? existing.account,
        rawStart ? displayTime(rawStart, timeZone) : existing.start,
        rawEnd ? displayTime(rawEnd, timeZone) : existing.end,
        rawStart ? displayDay(rawStart, timeZone) : existing.day_label,
        reminder,
        now,
        workspaceId,
        itemId,
      ).run();
      break;
    }
    case 'workspace_delete_calendar_event': {
      itemId = safeIdentifier(args.eventId, 'Event ID');
      await db.prepare('DELETE FROM demo_events WHERE workspace_id = ? AND event_id = ?').bind(workspaceId, itemId).run();
      break;
    }
    case 'workspace_save_note': {
      const requestedId = optionalText(args.noteId, 160);
      const titleValue = clippedText(args.title, 'Untitled note', 200);
      const contentValue = clippedText(args.content, '', 20_000);
      if (requestedId) {
        itemId = safeIdentifier(requestedId, 'Note ID');
        const result = await db.prepare(
          `UPDATE demo_notes SET title = ?, content = ?, updated_label = 'Just now', updated_at = ?
           WHERE workspace_id = ? AND note_id = ?`,
        ).bind(titleValue, contentValue, now, workspaceId, itemId).run();
        if (!Number(result.meta.changes ?? 0)) throw new Error('The demo note no longer exists.');
      } else {
        if (await itemCount(workspaceId, 'demo_notes') >= MAX_NOTES) throw new Error('This demo workspace already has the maximum number of notes.');
        itemId = randomBase64Url(18);
        await db.prepare(
          `INSERT INTO demo_notes
            (workspace_id, note_id, title, content, updated_label, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'Just now', ?, ?)`,
        ).bind(workspaceId, itemId, titleValue, contentValue, now, now).run();
      }
      break;
    }
    case 'workspace_trash_note': {
      itemId = safeIdentifier(args.noteId, 'Note ID');
      await db.prepare('DELETE FROM demo_notes WHERE workspace_id = ? AND note_id = ?').bind(workspaceId, itemId).run();
      break;
    }
    case 'workspace_remember_fact': {
      if (await itemCount(workspaceId, 'demo_memory') >= MAX_MEMORY_FACTS) throw new Error('This demo workspace already has the maximum number of memory facts.');
      itemId = randomBase64Url(18);
      await db.prepare(
        `INSERT INTO demo_memory
          (workspace_id, fact_id, category, fact, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
      ).bind(
        workspaceId,
        itemId,
        clippedText(args.category, 'General', 80),
        clippedText(args.fact, 'New demo preference', 500),
        now,
        now,
      ).run();
      break;
    }
    case 'workspace_update_memory': {
      itemId = safeIdentifier(args.factId, 'Memory fact ID');
      const result = await db.prepare(
        'UPDATE demo_memory SET fact = ?, updated_at = ? WHERE workspace_id = ? AND fact_id = ?',
      ).bind(clippedText(args.fact, '', 500), now, workspaceId, itemId).run();
      if (!Number(result.meta.changes ?? 0)) throw new Error('The demo memory fact no longer exists.');
      break;
    }
    case 'workspace_forget_fact': {
      itemId = safeIdentifier(args.factId, 'Memory fact ID');
      await db.prepare('DELETE FROM demo_memory WHERE workspace_id = ? AND fact_id = ?').bind(workspaceId, itemId).run();
      break;
    }
    default:
      throw new Error('This demo write is not supported.');
  }

  await addActivity(workspaceId, actor, `Approved: ${title}`, 'write');
  return { status: 'completed', verified: true, mode: 'synthetic_demo', ...(itemId ? { itemId } : {}) };
}
