import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  decodeEmailDisplayText,
  normalizeEmailDisplayFields,
  parseEmailSender,
  resolveEmailUnread,
} from '../lib/email-presentation.mjs';

test('decodes one safe display layer and removes control characters', () => {
  assert.equal(decodeEmailDisplayText('Sales &amp; Revenue &#38; &#x26;'), 'Sales & Revenue & &');
  assert.equal(decodeEmailDisplayText('&amp;lt;script&amp;gt;'), '&lt;script&gt;');
  assert.equal(decodeEmailDisplayText('hello&#1;world\u202E'), 'hello&#1;world');
  assert.equal(decodeEmailDisplayText('bad &#0; &#xD800; &#x110000;'), 'bad &#0; &#xD800; &#x110000;');
});

test('normalizes only human-facing email fields', () => {
  const source = {
    id: 'message&amp;id',
    accountEmail: 'owner&amp;selector@example.com',
    url: 'https://example.com/a&amp;b',
    attachmentRef: 'ref&amp;opaque',
    from: 'R&amp;D &lt;team@example.com&gt;',
    subject: 'Review &amp; approve',
    snippet: 'Budget &lt; target',
  };
  const result = normalizeEmailDisplayFields(source);
  assert.equal(result.from, 'R&D <team@example.com>');
  assert.equal(result.subject, 'Review & approve');
  assert.equal(result.snippet, 'Budget < target');
  assert.equal(result.id, source.id);
  assert.equal(result.accountEmail, source.accountEmail);
  assert.equal(result.url, source.url);
  assert.equal(result.attachmentRef, source.attachmentRef);
});

test('parses one mailbox without misattributing multiple senders', () => {
  assert.deepEqual(parseEmailSender('"Rachit Kothari" <rachit@example.com>'), { name: 'Rachit Kothari', email: 'rachit@example.com' });
  assert.deepEqual(parseEmailSender('hello@example.com'), { name: 'hello', email: 'hello@example.com' });
  assert.deepEqual(parseEmailSender('A <a@example.com>, B <b@example.com>'), { name: 'A <a@example.com>, B <b@example.com>', email: '' });
});

test('normalizes exactly one layer before parsing the sender', () => {
  const normalized = normalizeEmailDisplayFields({
    from: 'A &amp;lt;script&amp;gt; <a@example.com>',
    subject: '&amp;lt;b&amp;gt;',
  });
  assert.deepEqual(parseEmailSender(normalized.from), { name: 'A &lt;script&gt;', email: 'a@example.com' });
  assert.equal(normalized.subject, '&lt;b&gt;');
});

test('read state uses only recognized status values and falls back to Gmail labels', () => {
  assert.equal(resolveEmailUnread({ labels: ['UNREAD', 'IMPORTANT'] }), true);
  assert.equal(resolveEmailUnread({ status: 'archived', labels: ['UNREAD'] }), true);
  assert.equal(resolveEmailUnread({ status: 'read', labels: ['UNREAD'] }), false);
  assert.equal(resolveEmailUnread({ status: 'unread' }), true);
  assert.equal(resolveEmailUnread({ unread: false, labels: ['UNREAD'] }), false);
});

test('decoded markup stays escaped when rendered as React text', () => {
  const attack = decodeEmailDisplayText('&lt;img src=x onerror=alert(1)&gt;');
  const html = renderToStaticMarkup(React.createElement('p', null, attack));
  assert.equal(html, '<p>&lt;img src=x onerror=alert(1)&gt;</p>');
});

test('mail records stay raw until the final display boundary', async () => {
  const source = await readFile(new URL('../app/components/workspace-app.tsx', import.meta.url), 'utf8');
  assert.match(source, /function emailRowModel[\s\S]{0,180}normalizeEmailDisplayFields\(item\)/);
  assert.match(source, /value\.view === 'inbox' \? normalizeEmailDisplayFields\(value\.item\)/);
  assert.doesNotMatch(source, /\.\.\.normalizeEmailDisplayFields\(item\), _kind: '(?:Mail|Unread mail)'/);
  assert.doesNotMatch(source, /\.\.\.normalizeEmailDisplayFields\(message\)/);
  assert.match(source, /className="oa-mail-list"/);
  assert.doesNotMatch(source, /dangerouslySetInnerHTML/);
});
