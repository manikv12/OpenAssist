import type { VoiceBackgroundTask, VoicePhase, VoiceSnapshot, VoiceTurn, VoiceTurnPhase } from "./contracts.js";

export type VoiceStateEvent =
  | { type: "session_connecting"; at: number }
  | { type: "session_opened"; at: number }
  | { type: "session_closed"; at: number }
  | { type: "session_failed"; error: string; at: number }
  | { type: "voice_phase_changed"; phase: VoicePhase; at: number }
  | { type: "turn_started"; turn: VoiceTurn; at: number }
  | { type: "turn_text_updated"; turnID: string; text: string; at: number }
  | { type: "turn_phase_changed"; turnID: string; phase: VoiceTurnPhase; at: number; error?: string }
  | { type: "turn_step_recorded"; turnID: string; callID: string; at: number }
  | { type: "turn_delivery_claimed"; turnID: string; deliveryID: string; at: number }
  | { type: "turn_interrupted"; turnID: string; at: number }
  | { type: "task_changed"; task: VoiceBackgroundTask; at: number }
  | { type: "task_removed"; taskID: string; at: number };

export function initialVoiceSnapshot(now = Date.now()): VoiceSnapshot {
  return {
    session: "connecting",
    voice: "listening",
    turns: {},
    backgroundTasks: {},
    lastEventAt: now
  };
}

const terminalTurnPhases = new Set<VoiceTurnPhase>(["completed", "interrupted", "failed"]);

function updateTurn(snapshot: VoiceSnapshot, turnID: string, update: (turn: VoiceTurn) => VoiceTurn, at: number) {
  const existing = snapshot.turns[turnID];
  if (!existing) return snapshot;
  return {
    ...snapshot,
    turns: { ...snapshot.turns, [turnID]: update(existing) },
    lastEventAt: at
  };
}

export function reduceVoiceSnapshot(snapshot: VoiceSnapshot, event: VoiceStateEvent): VoiceSnapshot {
  switch (event.type) {
    case "session_connecting":
      return { ...snapshot, session: "connecting", error: undefined, lastEventAt: event.at };
    case "session_opened":
      return { ...snapshot, session: "open", error: undefined, lastEventAt: event.at };
    case "session_closed":
      return { ...snapshot, session: "closed", voice: "stopped", activeTurnID: undefined, lastEventAt: event.at };
    case "session_failed":
      return { ...snapshot, session: "error", voice: "stopped", error: event.error, lastEventAt: event.at };
    case "voice_phase_changed":
      return { ...snapshot, voice: event.phase, lastEventAt: event.at };
    case "turn_started":
      return {
        ...snapshot,
        activeTurnID: event.turn.turnID,
        turns: { ...snapshot.turns, [event.turn.turnID]: event.turn },
        lastEventAt: event.at
      };
    case "turn_text_updated":
      return updateTurn(snapshot, event.turnID, (turn) => ({ ...turn, text: event.text, updatedAt: event.at }), event.at);
    case "turn_phase_changed":
      return updateTurn(snapshot, event.turnID, (turn) => {
        if (terminalTurnPhases.has(turn.phase) && turn.phase !== event.phase) return turn;
        return { ...turn, phase: event.phase, error: event.error, updatedAt: event.at };
      }, event.at);
    case "turn_step_recorded":
      return updateTurn(snapshot, event.turnID, (turn) => ({
        ...turn,
        toolSteps: turn.toolSteps + 1,
        ownerCallID: turn.ownerCallID || event.callID,
        updatedAt: event.at
      }), event.at);
    case "turn_delivery_claimed":
      return updateTurn(snapshot, event.turnID, (turn) => {
        if (turn.finalDeliveryID) return turn;
        return { ...turn, finalDeliveryID: event.deliveryID, phase: "delivering", updatedAt: event.at };
      }, event.at);
    case "turn_interrupted":
      return updateTurn(snapshot, event.turnID, (turn) => terminalTurnPhases.has(turn.phase)
        ? turn
        : {
            ...turn,
            interrupted: true,
            phase: "interrupted",
            updatedAt: event.at
          }, event.at);
    case "task_changed":
      return {
        ...snapshot,
        backgroundTasks: { ...snapshot.backgroundTasks, [event.task.taskID]: event.task },
        lastEventAt: event.at
      };
    case "task_removed": {
      const backgroundTasks = { ...snapshot.backgroundTasks };
      delete backgroundTasks[event.taskID];
      return { ...snapshot, backgroundTasks, lastEventAt: event.at };
    }
  }
}
