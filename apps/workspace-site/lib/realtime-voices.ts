export const REALTIME_VOICES = [
  { id: 'marin', label: 'Marin', description: 'Warm and natural' },
  { id: 'cedar', label: 'Cedar', description: 'Clear and grounded' },
  { id: 'coral', label: 'Coral', description: 'Friendly and expressive' },
  { id: 'sage', label: 'Sage', description: 'Calm and measured' },
  { id: 'verse', label: 'Verse', description: 'Balanced and conversational' },
  { id: 'ash', label: 'Ash', description: 'Bright and direct' },
  { id: 'sol', label: 'Sol', description: 'Savvy and relaxed' },
] as const;

export type RealtimeVoice = (typeof REALTIME_VOICES)[number]['id'];

export const DEFAULT_REALTIME_VOICE: RealtimeVoice = 'marin';

const REALTIME_VOICE_IDS = new Set<string>(REALTIME_VOICES.map((voice) => voice.id));

export function parseRealtimeVoice(value: unknown): RealtimeVoice {
  if (typeof value === 'string' && REALTIME_VOICE_IDS.has(value)) return value as RealtimeVoice;
  return DEFAULT_REALTIME_VOICE;
}
