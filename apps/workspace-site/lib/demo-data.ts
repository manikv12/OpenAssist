export type WorkspaceView =
  | 'today'
  | 'inbox'
  | 'tasks'
  | 'calendar'
  | 'supplies'
  | 'notes'
  | 'memory'
  | 'work'
  | 'accounts'
  | 'activity';

export type DemoAccount = {
  id: string;
  label: string;
  email: string;
  type: string;
};

export type DemoMessage = {
  id: string;
  account: string;
  sender: string;
  subject: string;
  snippet: string;
  time: string;
  unread: boolean;
  urgent: boolean;
  hasAttachment: boolean;
};

export type DemoTask = {
  id: string;
  title: string;
  list: string;
  due: string;
  tags: string[];
  completed: boolean;
};

export type DemoEvent = {
  id: string;
  title: string;
  account: string;
  start: string;
  end: string;
  day: string;
  reminder: string;
};

export type DemoNote = {
  id: string;
  title: string;
  updated: string;
  preview: string;
  content: string;
};

export type DemoMemoryFact = {
  id: string;
  category: string;
  fact: string;
};

export type DemoActivityItem = {
  id: string;
  actor: string;
  action: string;
  time: string;
  type: 'read' | 'write';
};

export type DemoSupplyProduct = {
  id: string;
  variantId: string;
  title: string;
  description: string;
  category: string;
  price: number;
  currency: string;
  available: boolean;
  imageUrl?: string;
  productUrl?: string;
};

export type DemoSupplyCartLine = {
  id: string;
  variantId: string;
  title: string;
  quantity: number;
  price: number;
  currency: string;
};

export type DemoSupplyCart = {
  id: string | null;
  lines: DemoSupplyCartLine[];
  total: number;
  currency: string;
};

export type DemoWorkspaceState = {
  accounts: DemoAccount[];
  messages: DemoMessage[];
  tasks: DemoTask[];
  events: DemoEvent[];
  notes: DemoNote[];
  memory: DemoMemoryFact[];
  activity: DemoActivityItem[];
  supplies: DemoSupplyProduct[];
  supplyCart: DemoSupplyCart;
};

// A local, synthetic fallback keeps development and tests deterministic. The
// deployed judge experience replaces this list with the real Shopify dev-store
// catalog through Storefront UCP MCP.
export const DEMO_SUPPLIES: DemoSupplyProduct[] = [
  { id: 'supply-travel-kit', variantId: 'variant-travel-kit', title: 'Compact Travel Tech Kit', description: 'USB-C cable, compact charger, and cable organizer for the Friday trip.', category: 'Travel', price: 39, currency: 'USD', available: true, imageUrl: '/catalog/compact-travel-tech-kit.webp' },
  { id: 'supply-security-key', variantId: 'variant-security-key', title: 'USB-C Security Key', description: 'A hardware security key for the Northstar access review.', category: 'Security', price: 29, currency: 'USD', available: true, imageUrl: '/catalog/usb-c-security-key.webp' },
  { id: 'supply-desk-pad', variantId: 'variant-desk-pad', title: 'Recycled Felt Desk Pad', description: 'A calm, durable work surface made from recycled felt.', category: 'Workspace', price: 48, currency: 'USD', available: true, imageUrl: '/catalog/recycled-felt-desk-pad.webp' },
  { id: 'supply-notebook', variantId: 'variant-notebook', title: 'Project Field Notebook', description: 'Numbered pages for meeting notes and launch checklists.', category: 'Workspace', price: 16, currency: 'USD', available: true, imageUrl: '/catalog/project-field-notebook.webp' },
  { id: 'supply-bottle', variantId: 'variant-bottle', title: 'Insulated Travel Bottle', description: 'A leak-resistant bottle sized for carry-on bags.', category: 'Travel', price: 32, currency: 'USD', available: true, imageUrl: '/catalog/insulated-travel-bottle.webp' },
  { id: 'supply-labels', variantId: 'variant-labels', title: 'Cable Label Set', description: 'Reusable labels for chargers, adapters, and demo equipment.', category: 'Organization', price: 12, currency: 'USD', available: true, imageUrl: '/catalog/cable-label-set.webp' },
];

export const EMPTY_DEMO_SUPPLY_CART: DemoSupplyCart = { id: null, lines: [], total: 0, currency: 'USD' };

export const DEMO_ACCOUNTS: DemoAccount[] = [
  { id: 'demo-main', label: 'Main', email: 'alex@example.test', type: 'main' },
  { id: 'demo-work', label: 'Northstar Work', email: 'alex@northstar.test', type: 'work' },
  { id: 'demo-studio', label: 'Studio', email: 'hello@studio.test', type: 'business' },
];

export const DEMO_MAIL: DemoMessage[] = [
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

export const DEMO_TASKS: DemoTask[] = [
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

export const DEMO_EVENTS: DemoEvent[] = [
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

export const DEMO_NOTES: DemoNote[] = [
  {
    id: 'note-launch',
    title: 'Launch notes',
    updated: 'Today',
    preview: 'What worked, what to improve, and final links.',
    content: 'What worked\n\nThe visible approval flow was clear.\n\nNext\n\nVerify the final public demo link and add it to the submission.',
  },
  {
    id: 'note-travel',
    title: 'Travel plan',
    updated: 'Yesterday',
    preview: 'Flights, hotel, local transport, and confirmations.',
    content: 'Flights, hotel, local transport, and confirmation details for the synthetic demo trip.',
  },
];

export const DEMO_MEMORY: DemoMemoryFact[] = [
  { id: 'memory-account', category: 'Accounts', fact: 'Northstar Work is the default account for work tasks and calendar events.' },
  { id: 'memory-reminders', category: 'Preferences', fact: 'Ask for a reminder time when creating important calendar events.' },
  { id: 'memory-notes', category: 'Preferences', fact: 'Keep task notes short; create a Drive note only for genuinely long reference material.' },
];

export const DEMO_ACTIVITY: DemoActivityItem[] = [
  { id: 'activity-brief', actor: 'ChatGPT', action: 'Opened the daily brief', time: 'Just now', type: 'read' },
  { id: 'activity-scan', actor: 'Workspace', action: 'Scanned unread mail across 3 demo accounts', time: '2 minutes ago', type: 'read' },
  { id: 'activity-task', actor: 'You', action: 'Approved “Publish the workspace demo video”', time: 'Yesterday', type: 'write' },
];
