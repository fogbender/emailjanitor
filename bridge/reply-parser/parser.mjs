import ReplyParser from 'email-reply-parser';
import ForwardParser from 'email-forward-parser';

const bytes = text => Buffer.byteLength(text, 'utf8');
const clarify = reason => ({status:'clarify', reason});
const bounded = (text, size) => typeof text === 'string' && bytes(text) <= size;

// Authentication belongs to Gmail Sent readback in Elixir. This package only
// separates authored text from untrusted evidence; it grants no capabilities.
export function parse(input) {
  if (!input || Array.isArray(input) || Object.keys(input).sort().join(',') !== 'body,reply_expected,subject' ||
      !bounded(input.body, 1_000_000) || !bounded(input.subject, 1024) || typeof input.reply_expected !== 'boolean' ||
      /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/u.test(input.body)) return clarify('unreadable');
  const forwarding = new ForwardParser();
  const bySubject = forwarding.read(input.body, input.subject);
  const forwarded = bySubject.forwarded ? bySubject : forwarding.read(input.body);
  if (forwarded.forwarded) {
    const original = forwarded.email;
    if (!bounded(forwarded.message, 16_000) || !forwarded.message.trim() ||
        !bounded(original?.body, 8000) || !original.body.trim()) return clarify('forward_ambiguous');
    const author = leadingReply(forwarded.message);
    if (!author || author.quoted) return clarify('forward_ambiguous');
    const sender = original.from?.address || original.from?.name || '';
    const subject = original.subject || '';
    if (!bounded(sender, 1024) || !bounded(subject, 1024)) return clarify('forward_ambiguous');
    return {status:'parsed',kind:'forward',authored:author.text,
      evidence:{sender,subject,body:original.body},evidence_omitted:false};
  }
  const author = leadingReply(input.body);
  if (!author || !author.text) return clarify('reply_ambiguous');
  const evidence = author.quote && bounded(author.quote, 8000)
    ? {sender:'',subject:input.subject,body:author.quote} : null;
  return {status:'parsed',kind:author.quoted || input.reply_expected?'reply':'direct',authored:author.text,
    evidence,evidence_omitted:!!author.quote && !evidence};
}

function leadingReply(body) {
  const fragments = new ReplyParser().read(body).getFragments();
  let boundary = false;
  let quoted = false;
  const author = [], quote = [];
  for (const fragment of fragments) {
    const text = fragment.getContent();
    if (fragment.isQuoted()) quoted = true;
    const hidden = fragment.isQuoted() || fragment.isHidden() || fragment.isSignature();
    if (hidden) boundary = true;
    if (boundary) {
      // Bottom/interleaved replies are ambiguous: never promote a visible line
      // after an untrusted quote into the user's command.
      if (!hidden && text.trim()) return null;
      if (fragment.isQuoted()) quote.push(text);
    } else author.push(text);
  }
  const text = author.join('\n').trim();
  if (!text || !bounded(text,16_000)) return null;
  return {text,quoted,quote:quote.join('\n').trim()};
}
