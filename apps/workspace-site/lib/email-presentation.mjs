const NAMED_ENTITIES = Object.freeze({
  amp: '&',
  apos: "'",
  gt: '>',
  lt: '<',
  nbsp: '\u00a0',
  quot: '"',
});

const EMAIL_DISPLAY_FIELDS = Object.freeze([
  'from',
  'fromName',
  'preview',
  'sender',
  'snippet',
  'subject',
  'to',
]);

function codePointCharacter(value) {
  if (
    !Number.isInteger(value)
    || value <= 0
    || value > 0x10ffff
    || (value >= 0xd800 && value <= 0xdfff)
    || value === 0x7f
    || (value >= 0x01 && value <= 0x1f)
    || (value >= 0x80 && value <= 0x9f)
  ) return null;
  return String.fromCodePoint(value);
}

/**
 * Decode one layer of common HTML entities for email presentation only.
 * The result must still be rendered as an ordinary React text node.
 */
export function decodeEmailDisplayText(value) {
  if (typeof value !== 'string' || value.length === 0) return '';
  return value
    .replace(/&(?:#([0-9]{1,7})|#x([0-9a-f]{1,6})|([a-z]{2,5}));/gi, (match, decimal, hexadecimal, named) => {
      if (decimal) return codePointCharacter(Number.parseInt(decimal, 10)) ?? match;
      if (hexadecimal) return codePointCharacter(Number.parseInt(hexadecimal, 16)) ?? match;
      return NAMED_ENTITIES[String(named).toLowerCase()] ?? match;
    })
    .replace(/\u00a0/g, ' ')
    .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, ' ')
    .replace(/[\t\r\n ]+/g, ' ')
    .trim();
}

/** Decode only human-facing mail fields. Opaque IDs, URLs, account selectors,
 * and attachment references remain byte-for-byte unchanged. */
export function normalizeEmailDisplayFields(record) {
  const normalized = { ...record };
  for (const field of EMAIL_DISPLAY_FIELDS) {
    if (typeof normalized[field] === 'string') normalized[field] = decodeEmailDisplayText(normalized[field]);
  }
  return normalized;
}

/** Prefer an explicit boolean/read state, otherwise use Gmail's UNREAD label. */
export function resolveEmailUnread(record) {
  if (typeof record?.unread === 'boolean') return record.unread;
  const statusValue = typeof record?.readState === 'string' ? record.readState : record?.status;
  const status = typeof statusValue === 'string' ? statusValue.trim().toLowerCase() : '';
  if (status === 'read' || status === 'unread') return status === 'unread';
  const labels = Array.isArray(record?.labels)
    ? record.labels.filter((label) => typeof label === 'string').map((label) => label.toUpperCase())
    : [];
  return labels.includes('UNREAD');
}

/** Split `Display Name <address@example.com>` without losing either part. */
export function parseEmailSender(value) {
  const text = typeof value === 'string'
    ? value
      .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, ' ')
      .replace(/[\t\r\n ]+/g, ' ')
      .trim()
    : '';
  const mailboxCount = (text.match(/<[^<>\s]+@[^<>\s]+>/g) ?? []).length;
  if (mailboxCount > 1) return { name: text || 'Multiple senders', email: '' };
  const match = text.match(/^\s*(.*?)\s*<([^<>\s]+@[^<>\s]+)>\s*$/);
  if (!match) {
    const emailOnly = /^[^<>\s]+@[^<>\s]+$/.test(text);
    return { name: emailOnly ? text.split('@')[0] : text || 'Unknown sender', email: emailOnly ? text : '' };
  }
  const name = match[1].replace(/^['"]|['"]$/g, '').trim();
  return { name: name || match[2], email: match[2] };
}
