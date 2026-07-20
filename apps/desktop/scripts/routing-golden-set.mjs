// Golden set of real utterances and the route each MUST take.
// When a misroute happens in real use, add ONE line here — that misroute can
// then never come back. Kinds come from voiceRouting.ts VoiceRouteKind:
// control | recall | write | read | parallel | delegate | ignore.

export const goldenCases = [
  // Real misroutes we actually hit (see memory notes) — locked in forever.
  { utterance: "Check the completed reminders.", expect: "read", note: "was delegated to Codex + osascript; must stay a local read" },
  { utterance: "What memory do I have about the client launch plan?", expect: "recall", note: "was vetoed by conversationRecallRoute regex" },
  { utterance: "What's still open from my voice sessions?", expect: "read", note: "Open Loops ledger is a note read" },

  // Reads
  { utterance: "Do I have any reminder for paying off credit cards?", expect: "read" },
  { utterance: "What is on my Today list?", expect: "read" },
  { utterance: "Read my grocery note.", expect: "read" },
  { utterance: "Is there anything in the backlog?", expect: "read" },

  // Writes
  { utterance: "Add buy milk to my Today list.", expect: "write" },
  { utterance: "Mark the trash reminder as done.", expect: "write" },
  { utterance: "Re-open the pay off credit cards reminder.", expect: "write" },
  { utterance: "Move the dentist task to tomorrow.", expect: "write" },

  // Recall
  { utterance: "What did we decide about the home renovation last week?", expect: "recall" },

  // Delegation (genuine agent work)
  { utterance: "Can you check online for the latest USCIS guidance?", expect: "delegate" },
  { utterance: "Use the terminal to check the build logs.", expect: "delegate" },
  { utterance: "Ask Codex to review the release script.", expect: "delegate" },

  // Parallel
  { utterance: "Check downloads and summarize the note at the same time.", expect: "parallel" },

  // Control / ignore
  { utterance: "Stop listening.", expect: "control" },
  { utterance: "Okay thanks.", expect: "ignore" },
  { utterance: "Yes please.", expect: "ignore" }
];

// quick_read targets that must resolve to the real Apple Reminders store
// (parseAppleRemindersQuickReadTarget), and ones that must NOT.
export const appleReminderTargetCases = [
  { target: "check the completed reminders", routes: true, completedOnly: true },
  { target: "apple reminders", routes: true },
  { target: "reminders", routes: true },
  { target: "pay off the credit cards reminders app", routes: true, queryIncludes: "pay off" },
  { target: "today", routes: false },
  { target: "my grocery notes", routes: false },
  { target: "backlog", routes: false }
];
