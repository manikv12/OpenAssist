export type WorkspaceView =
  | 'today'
  | 'inbox'
  | 'tasks'
  | 'calendar'
  | 'notes'
  | 'memory'
  | 'accounts'
  | 'activity';

export const DEMO_ACCOUNTS = [
  { id: 'demo-main', label: 'Main', email: 'alex@example.test', type: 'main' },
  { id: 'demo-work', label: 'Northstar Work', email: 'alex@northstar.test', type: 'work' },
  { id: 'demo-studio', label: 'Studio', email: 'hello@studio.test', type: 'business' },
];

export const DEMO_MAIL = [
  {
    id: 'mail-security-review',
    account: 'Northstar Work',
    sender: 'Cloud Console',
    subject: 'Security review needs your response',
    snippet: 'Please review the outstanding assessment questions before Friday.',
    time: '18 min',
    unread: true,
    urgent: true,
    hasAttachment: true,
  },
  {
    id: 'mail-itinerary',
    account: 'Main',
    sender: 'Atlas Travel',
    subject: 'Your itinerary has been updated',
    snippet: 'The return flight now departs at 2:10 PM local time.',
    time: '1 hr',
    unread: true,
    urgent: false,
    hasAttachment: true,
  },
  {
    id: 'mail-client',
    account: 'Studio',
    sender: 'River & Pine',
    subject: 'Approved: launch checklist',
    snippet: 'The final launch checklist is approved. No action is required.',
    time: '3 hr',
    unread: true,
    urgent: false,
    hasAttachment: false,
  },
  {
    id: 'mail-receipt',
    account: 'Main',
    sender: 'Paper & Pixel',
    subject: 'Receipt for your order',
    snippet: 'Your receipt is attached as a PDF.',
    time: 'Yesterday',
    unread: false,
    urgent: false,
    hasAttachment: true,
  },
];

export const DEMO_TASKS = [
  {
    id: 'task-security',
    title: 'Answer security review questions',
    list: 'My Tasks',
    due: 'Today',
    tags: ['#Northstar', '#Urgent'],
    completed: false,
  },
  {
    id: 'task-demo',
    title: 'Publish the workspace demo video',
    list: 'My Tasks',
    due: '11:00 AM',
    tags: ['#Launch'],
    completed: false,
  },
  {
    id: 'task-followup',
    title: 'Follow up with River & Pine',
    list: 'Backlog',
    due: 'Tomorrow',
    tags: ['#Studio'],
    completed: false,
  },
  {
    id: 'task-done',
    title: 'Confirm travel reservation',
    list: 'My Tasks',
    due: 'Yesterday',
    tags: ['#Travel'],
    completed: true,
  },
];

export const DEMO_EVENTS = [
  {
    id: 'event-review',
    title: 'Product review',
    account: 'Northstar Work',
    start: '10:30 AM',
    end: '11:15 AM',
    day: 'Today',
    reminder: '10 minutes before',
  },
  {
    id: 'event-client',
    title: 'River & Pine launch call',
    account: 'Studio',
    start: '2:00 PM',
    end: '2:45 PM',
    day: 'Today',
    reminder: '30 minutes before',
  },
  {
    id: 'event-planning',
    title: 'Weekly planning',
    account: 'Main',
    start: '9:00 AM',
    end: '9:30 AM',
    day: 'Tomorrow',
    reminder: '10 minutes before',
  },
];

export const DEMO_NOTES = [
  { id: 'note-launch', title: 'Launch notes', updated: 'Today', preview: 'What worked, what to improve, and final links.' },
  { id: 'note-travel', title: 'Travel plan', updated: 'Yesterday', preview: 'Flights, hotel, local transport, and confirmations.' },
];

export const DEMO_MEMORY = [
  { id: 'memory-account', category: 'Accounts', fact: 'Northstar Work is the default account for work tasks and calendar events.' },
  { id: 'memory-reminders', category: 'Preferences', fact: 'Ask for a reminder time when creating important calendar events.' },
  { id: 'memory-notes', category: 'Preferences', fact: 'Keep task notes short; create a Drive note only for genuinely long reference material.' },
];

export const DEMO_ACTIVITY = [
  { id: 'activity-brief', actor: 'ChatGPT', action: 'Opened the daily brief', time: 'Just now', type: 'read' },
  { id: 'activity-scan', actor: 'Workspace', action: 'Scanned unread mail across 3 demo accounts', time: '2 minutes ago', type: 'read' },
  { id: 'activity-task', actor: 'You', action: 'Approved “Publish the workspace demo video”', time: 'Yesterday', type: 'write' },
];
