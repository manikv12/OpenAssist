export const REALTIME_VOICES = [
  { id: 'sol', label: 'Sol', description: 'Savvy and relaxed' },
  { id: 'arbor', label: 'Arbor', description: 'Warm and grounded' },
  { id: 'breeze', label: 'Breeze', description: 'Light and conversational' },
  { id: 'cove', label: 'Cove', description: 'Clear and composed' },
  { id: 'ember', label: 'Ember', description: 'Rich and expressive' },
  { id: 'juniper', label: 'Juniper', description: 'Friendly and natural' },
  { id: 'maple', label: 'Maple', description: 'Calm and thoughtful' },
  { id: 'spruce', label: 'Spruce', description: 'Direct and confident' },
  { id: 'vale', label: 'Vale', description: 'Smooth and measured' },
] as const;

export type RealtimeVoice = (typeof REALTIME_VOICES)[number]['id'];

export const DEFAULT_REALTIME_VOICE: RealtimeVoice = 'sol';

const REALTIME_VOICE_IDS = new Set<string>(REALTIME_VOICES.map((voice) => voice.id));

export function parseRealtimeVoice(value: unknown): RealtimeVoice {
  if (typeof value === 'string' && REALTIME_VOICE_IDS.has(value)) return value as RealtimeVoice;
  return DEFAULT_REALTIME_VOICE;
}
