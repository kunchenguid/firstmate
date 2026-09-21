#!/usr/bin/env python3
# fm-mail.py - the IMAP/SMTP engine behind bin/fm-mail.sh.
#
# A small mail client used by fm-mail.sh:
#   read                   List unseen INBOX mail as a compact digest.
#   send <to> <subj> <body | ->   Send one SMTP message; "-" reads stdin.
#   send-template <to> <subj> <json-file | ->   Send text + HTML alternatives.
#   render-template <json-file | -> [html|text]   Offline template preview.
#                          fm-mail.sh --help owns the versioned JSON contract.
#   poll_list              Emit unseen mail as tab-separated rows for the bash
#                          poll, bounded to uids this home has not surfaced,
#                          plus a retry-set of previously unfetchable uids;
#                          persists the retry-scan position and cap-1 turn flag.
#   seen <cursor>          Print a cursor file (used by `status`).
#
# All configuration arrives through the environment, never through arguments,
# so credentials never appear in argv or logs. read/poll use BODY.PEEK so mail
# is never marked seen before firstmate answers it.
import imaplib
import html
import json
import os
import re
import socket
import ssl
import sys
import email
import smtplib
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import formatdate, make_msgid
from urllib.parse import urlsplit

# Offline rendering ignores mail configuration, including malformed ports.
OFFLINE = len(sys.argv) > 1 and sys.argv[1] == 'render-template'
USER = os.environ.get('FM_MAIL_USER', '')
PW = os.environ.get('FM_MAIL_PASS', '')
IMH = os.environ.get('FM_IMAP_HOST', '')
IMP = 993 if OFFLINE else int(os.environ.get('FM_IMAP_PORT', '993'))
STH = os.environ.get('FM_SMTP_HOST', '')
STP = 465 if OFFLINE else int(os.environ.get('FM_SMTP_PORT', '465'))
CTX = ssl.create_default_context()


def mail_timeout():
    """Seconds for IMAP/SMTP sockets. Invalid or non-positive values become 20."""
    raw = os.environ.get('FM_MAIL_TIMEOUT', '20')
    try:
        value = float(raw)
    except (TypeError, ValueError):
        value = 20.0
    if value <= 0:
        value = 20.0
    return value


MAIL_TIMEOUT = mail_timeout()
socket.setdefaulttimeout(MAIL_TIMEOUT)

MAX_PREVIEW = 200
READ_LIMIT = 20


def dec(s):
    """Decode an RFC-2047 header to display text, tolerating malformed input."""
    if not s:
        return ''
    try:
        return str(make_header(decode_header(s)))
    except Exception:
        return str(s)


def clean(s):
    """Collapse tabs/newlines/CR in a header value to single spaces so a
    crafted Subject/From can never split the tab-separated poll row or inject
    a fake uid line for the bash layer; strip surrounding whitespace too."""
    return re.sub(r'[\t\r\n]+', ' ', s or '').strip()


def connect_mailbox():
    m = imaplib.IMAP4_SSL(IMH, IMP, ssl_context=CTX, timeout=MAIL_TIMEOUT)
    m.login(USER, PW)
    return m


def body_preview(msg):
    """First non-empty text/plain line, else first non-empty text/html line,
    else empty. An empty plain-text alternative falls through to html so a
    valid message never loses its promised preview."""
    try:
        if msg is None:
            return ''
        for part in msg.walk():
            if part.get_content_type() == 'text/plain':
                text = (part.get_payload(decode=True) or b'').decode('utf-8', 'replace').strip()
                if text:
                    return text
        for part in msg.walk():
            if part.get_content_type() == 'text/html':
                raw = (part.get_payload(decode=True) or b'').decode('utf-8', 'replace')
                raw = re.sub(r'(?is)<(style|script)[^>]*>.*?</\1>', ' ', raw)
                preview = re.sub(r'<[^>]+>', ' ', raw)
                preview = ' '.join(preview.split())
                if preview:
                    return preview
    except Exception:
        return ''
    return ''


def cmd_read():
    try:
        m = connect_mailbox()
        m.select('INBOX')
        typ, data = m.uid('search', None, 'UNSEEN')
        ids = (data[0] or b'').split()
        if not ids:
            print('(no unseen mail)')
            m.logout()
            return 0
        for i in ids[-READ_LIMIT:]:
            uid = i.decode() if isinstance(i, bytes) else str(i)
            typ, msg = m.uid('fetch', i, '(BODY.PEEK[])')
            if typ != 'OK' or not msg or not msg[0] or not msg[0][1]:
                print('---')
                print('Uid:', uid)
                print('From:', '(unfetchable)')
                print('Date:', '')
                print('Subj:', 'unfetchable body - see fm-mail read')
                print('Body:', '(body unavailable)')
                continue
            mi = email.message_from_bytes(msg[0][1])
            print('---')
            print('From:', dec(mi.get('From')))
            print('Date:', dec(mi.get('Date')))
            print('Subj:', dec(mi.get('Subject')))
            preview = body_preview(mi)
            if preview:
                first = preview.splitlines()[0]
                print('Body:', (first[:MAX_PREVIEW] if first else ''))
            else:
                print('Body:', '(body unavailable)')
        try:
            m.logout()
        except Exception:
            pass
        return 0
    except Exception as e:
        print('fm-mail read error:', e)
        return 1


def send_message(to, subj, body, html_body=None):
    """Both send surfaces share authentication, envelope handling, and TLS."""
    m = EmailMessage(policy=SMTP)
    m['From'] = USER
    m['To'] = to
    m['Subject'] = subj
    m['Date'] = formatdate(localtime=True)
    m['Message-ID'] = make_msgid()
    m.set_content(body)
    if html_body is not None:
        m.add_alternative(html_body, subtype='html')
    with smtplib.SMTP_SSL(STH, STP, context=CTX, timeout=MAIL_TIMEOUT) as s:
        s.login(USER, PW)
        s.send_message(m)
    print('sent to', to)


def cmd_send(to, subj, body):
    try:
        if body == '-':
            body = sys.stdin.read().rstrip('\n')
        send_message(to, subj, body)
        return 0
    except Exception as e:
        print('fm-mail send error:', e)
        return 1


def template_string(value, name, limit, multiline=False):
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError(f'{name} must be non-empty text of at most {limit} characters')
    if any((ord(c) < 32 and not (multiline and c == '\n')) or
           127 <= ord(c) <= 159 or 0xd800 <= ord(c) <= 0xdfff for c in value):
        raise ValueError(f'{name} contains unsupported control characters')
    return value


def template_object(value, name, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys():
        raise ValueError(f'{name} is missing required fields: {", ".join(required)}')
    if value.keys() - set(required) - set(optional):
        raise ValueError(f'{name} contains unknown fields')


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('template contains duplicate JSON fields')
        result[key] = value
    return result


def load_template(source):
    """Validate the entire payload before rendering or connecting to SMTP."""
    if source == '-':
        raw = sys.stdin.buffer.read(32769)
    else:
        with open(source, 'rb') as stream:
            raw = stream.read(32769)
    if len(raw) > 32768:
        raise ValueError('template exceeds 32768 bytes')
    data = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_fields)
    template_object(data, 'template', ('version', 'kind', 'title', 'body'),
                    ('project', 'preheader', 'facts', 'action', 'question',
                     'options', 'recommendation', 'reply_hint'))
    if type(data['version']) is not int or data['version'] != 1:
        raise ValueError('template version must be 1')
    if data['kind'] not in ('notification', 'question'):
        raise ValueError('kind must be notification or question')
    for key, limit in (('title', 160), ('body', 6000), ('project', 100),
                       ('preheader', 200), ('question', 400),
                       ('recommendation', 1000), ('reply_hint', 400)):
        if key in data:
            template_string(data[key], key, limit, multiline=key == 'body')
    facts = data.get('facts', [])
    if not isinstance(facts, list) or len(facts) > 4:
        raise ValueError('facts must be a list of at most 4 items')
    for fact in facts:
        template_object(fact, 'fact', ('label', 'value'))
        template_string(fact['label'], 'fact label', 40)
        template_string(fact['value'], 'fact value', 200)
    if 'action' in data:
        action = data['action']
        template_object(action, 'action', ('label', 'url'))
        template_string(action['label'], 'action label', 80)
        url = template_string(action['url'], 'action url', 2048)
        parsed = urlsplit(url)
        if (parsed.scheme != 'https' or not parsed.hostname or
                parsed.username is not None or parsed.password is not None or
                any(c.isspace() or c in '\\<>"' for c in url)):
            raise ValueError('action url must be an absolute HTTPS URL without credentials')
        # Accessing port also rejects malformed and out-of-range values.
        try:
            port = parsed.port
        except ValueError:
            raise ValueError('action url has an invalid port') from None
        if port == 0:
            raise ValueError('action url port must be positive')
    question_fields = {'question', 'options', 'recommendation', 'reply_hint'}
    if data['kind'] == 'question':
        if not {'question', 'reply_hint'} <= data.keys():
            raise ValueError('question templates require question and reply_hint')
        options = data.get('options', [])
        if not isinstance(options, list) or not 0 <= len(options) <= 4 or len(options) == 1:
            raise ValueError('options must contain 2 to 4 choices, or be omitted/empty')
        for option in options:
            template_object(option, 'option', ('label', 'detail'))
            template_string(option['label'], 'option label', 100)
            template_string(option['detail'], 'option detail', 600)
    elif question_fields & data.keys():
        raise ValueError('question fields are only valid for kind=question')
    return data


def render_template(data):
    """Render validated content once for both delivery and offline review.

    Brand colors and the Cooper/Rockwell fallback follow myfirstmate.io's
    Firstmate design system. Inline table layout remains readable without the
    optional mobile media query; no network assets or active email content.
    """
    e = html.escape
    kind = 'Notification' if data['kind'] == 'notification' else 'Your decision'
    context = data.get('project', 'From your firstmate')
    plain = ['FIRSTMATE / ' + kind, context, '', data['title'], '', data['body']]
    facts_html = ''
    for fact in data.get('facts', []):
        plain.append(f"{fact['label']}: {fact['value']}")
        facts_html += (
            '<tr><th scope="row" align="left" valign="top" width="32%" '
            'style="padding:10px 12px 10px 0;border-bottom:1px solid #ddc89c;'
            'font-size:12px;font-weight:normal;color:#6f5e46;">'
            f'{e(fact["label"])}</th><td valign="top" '
            'style="padding:10px 0;border-bottom:1px solid #ddc89c;font-size:14px;">'
            f'{e(fact["value"])}</td></tr>')
    if facts_html:
        facts_html = ('<table width="100%" cellpadding="0" cellspacing="0" '
                      'style="border-collapse:collapse;table-layout:fixed;margin:24px 0;">'
                      f'{facts_html}</table>')
    question_html = ''
    if data['kind'] == 'question':
        plain.extend(['', data['question']])
        choices = ''
        for index, option in enumerate(data.get('options', [])):
            letter = chr(65 + index)
            plain.append(f'{letter}. {option["label"]}: {option["detail"]}')
            choices += (
                '<tr><td width="28" valign="top" style="padding:14px 0;'
                'border-top:1px solid #ddc89c;color:#c0452a;font-weight:bold;">'
                f'{letter}.</td><td style="padding:14px 0;border-top:1px solid #ddc89c;">'
                f'<strong>{e(option["label"])}</strong><br>'
                f'<span style="color:#6f5e46;font-size:14px;">{e(option["detail"])}</span>'
                '</td></tr>')
        recommendation = ''
        if 'recommendation' in data:
            plain.extend(['', 'Recommendation: ' + data['recommendation']])
            recommendation = (
                '<p style="margin:16px 0 24px;font-size:14px;line-height:1.6;">'
                '<strong>My recommendation</strong><br>'
                f'{e(data["recommendation"])}</p>')
        plain.extend(['', data['reply_hint']])
        question_html = f'''
<h2 style="margin:28px 0 16px;font-family:Georgia,serif;font-weight:normal;font-size:25px;line-height:1.25;color:#2a3656;">{e(data['question'])}</h2>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;table-layout:fixed;">{choices}</table>
{recommendation}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td bgcolor="#2a3656" style="padding:20px 24px;border-left:4px solid #e0a52e;color:#fffdf7;">
<p style="margin:0 0 8px;font-family:Consolas,'Courier New',monospace;font-size:11px;letter-spacing:1px;">REPLY TO FIRSTMATE</p>
<p style="margin:0;font-size:15px;line-height:1.6;">{e(data['reply_hint'])}</p>
</td></tr></table>'''
    action_html = ''
    if 'action' in data:
        action = data['action']
        plain.extend(['', f'{action["label"]}: {action["url"]}'])
        action_html = (
            '<p style="margin:28px 0 0;line-height:1.6;">'
            f'<a href="{e(action["url"])}" style="color:#a93a1f;font-weight:bold;'
            f'text-decoration:underline;">{e(action["label"])} &rarr;</a></p>')
    plain.extend(['', 'Your firstmate', 'Talk to one agent. Ship with a crew.'])
    body_html = ''.join(
        '<p style="margin:0 0 16px;font-size:16px;line-height:1.65;">'
        + e(paragraph).replace('\n', '<br>') + '</p>'
        for paragraph in data['body'].split('\n\n'))
    html_body = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{e(data['title'])}</title>
<style>@media screen and (max-width:480px){{.fm-outer{{padding:12px 8px!important}}.fm-content{{padding:28px 22px!important}}.fm-title{{font-size:30px!important}}}}</style>
</head><body style="margin:0;padding:0;background-color:#f6ecd3;color:#241c14;">
<div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;overflow:hidden;mso-hide:all;">{e(data.get('preheader', data['title']))}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#f6ecd3" style="border-collapse:collapse;"><tr><td class="fm-outer" align="center" style="padding:32px 16px;">
<!--[if mso]><table role="presentation" width="600" cellpadding="0" cellspacing="0"><tr><td><![endif]-->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#fffdf7" style="max-width:600px;border:1px solid #ddc89c;border-top:4px solid #c0452a;border-collapse:collapse;table-layout:fixed;">
<tr><td class="fm-content" style="padding:36px 40px;font-family:'Segoe UI',Helvetica,Arial,sans-serif;line-height:1.55;word-wrap:break-word;overflow-wrap:anywhere;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
<td style="padding-bottom:24px;border-bottom:2px solid #2a3656;">
<span style="font-family:'Cooper Black',Rockwell,Georgia,serif;font-size:30px;font-weight:bold;letter-spacing:-1px;color:#c0452a;">firstmate<span style="color:#2a3656;">.</span></span>
</td><td align="right" valign="middle" width="42" style="padding-bottom:24px;border-bottom:2px solid #2a3656;">
<span aria-hidden="true" style="font-size:26px;color:#c0452a;">&#9875;&#65038;</span>
</td></tr></table>
<p style="margin:24px 0 10px;font-family:Consolas,'Courier New',monospace;font-size:11px;line-height:1.6;letter-spacing:1px;color:#6f5e46;">{e(context)}</p>
<p style="margin:0 0 22px;"><span style="display:inline-block;padding:5px 9px;border:1px solid #241c14;border-radius:3px;background-color:#f6ecd3;font-size:10px;line-height:1.4;font-weight:bold;letter-spacing:1px;color:#2a3656;">{kind.upper()}</span></p>
<h1 class="fm-title" style="margin:0 0 22px;font-family:Georgia,'Times New Roman',serif;font-size:36px;line-height:1.15;font-weight:normal;letter-spacing:-0.5px;color:#2a3656;">{e(data['title'])}</h1>
{body_html}{facts_html}{question_html}{action_html}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:32px;"><tr><td style="padding-top:20px;border-top:1px solid #ddc89c;">
<p style="margin:0;font-family:Georgia,serif;font-size:18px;font-style:italic;color:#2a3656;">Your firstmate</p>
<p style="margin:8px 0 0;font-size:11px;line-height:1.5;color:#6f5e46;">Talk to one agent. Ship with a crew.</p>
</td></tr></table>
</td></tr></table>
<!--[if mso]></td></tr></table><![endif]-->
</td></tr></table></body></html>'''
    return '\n'.join(plain), html_body


def cmd_template(source, to=None, subj=None, output='html'):
    try:
        if output not in ('html', 'text'):
            raise ValueError('render format must be html or text')
        if to is not None:
            template_string(to, 'recipient', 320)
            template_string(subj, 'subject', 200)
            # The explicit template interface accepts one unambiguous mailbox.
            # Legacy send retains its existing address-list interface.
            if not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
                                r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", to):
                raise ValueError('recipient must be one bare email address')
            local, domain = to.rsplit('@', 1)
            if (len(local) > 64 or local.startswith('.') or local.endswith('.') or
                    '..' in to or any(not label or len(label) > 63 or
                                     label.startswith('-') or label.endswith('-')
                                     for label in domain.split('.'))):
                raise ValueError('recipient must be one bare email address')
        plain, markup = render_template(load_template(source))
        if to is None:
            print(markup if output == 'html' else plain)
        else:
            send_message(to, subj, plain, markup)
        return 0
    except (ValueError, OSError, RecursionError) as exc:
        # File/JSON errors must not echo a payload, credentials, or a path.
        reason = str(exc) if type(exc) is ValueError else 'cannot read valid UTF-8 template JSON'
        print('fm-mail template error:', reason, file=sys.stderr)
        return 1
    except Exception:
        print('fm-mail template error: SMTP delivery failed', file=sys.stderr)
        return 1


def cmd_seen(cursor_path):
    line = open(cursor_path).read().strip() if os.path.exists(cursor_path) else '(none)'
    print('cursor:', line)
    return 0


def load_cursor(cursor_path):
    """Return (stored_generation, seen_uids) from the local cursor file."""
    stored_gen = ''
    seen = set()
    if not os.path.exists(cursor_path):
        return stored_gen, seen
    with open(cursor_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('uidvalidity='):
                stored_gen = line.split('=', 1)[1]
            else:
                seen.add(line)
    return stored_gen, seen


def load_retry(retry_path):
    """Return (retry_set, retry_order) from the local retry file."""
    retry = set()
    ordered = []
    if not retry_path or not os.path.exists(retry_path):
        return retry, ordered
    with open(retry_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            uid = line.strip()
            if not uid or uid in retry:
                continue
            retry.add(uid)
            ordered.append(uid)
    return retry, ordered


def load_retry_pos(pos_path, n):
    """Return the durable retry-scan start position, clamped into range."""
    if not pos_path:
        return 0
    try:
        pos = int(open(pos_path).read().strip() or '0')
    except (OSError, ValueError):
        return 0
    if n <= 0:
        return 0
    return pos % n


def retry_scan_window(order, pos, window):
    """Take the bounded retry scan starting at the durable position, wrapping
    around the end of the retry file. cmd_poll_list owns when and by how much
    the durable position advances after this window is considered."""
    if not order:
        return []
    start = pos % len(order)
    rotated = order[start:] + order[:start]
    if len(order) <= window:
        return rotated
    return rotated[:window]


def save_retry_pos(pos_path, order_len, window, pos):
    """Persist the next retry-scan start position: (pos + window) mod order_len.
    cmd_poll_list owns what window means on each persist path. A failed write
    propagates so the poll fails closed rather than silently restarting the
    retry scan at the same head every poll."""
    if not pos_path:
        return
    if order_len <= 0:
        next_pos = 0
    else:
        next_pos = (pos + window) % order_len
    with open(pos_path, 'w', encoding='utf-8') as f:
        f.write(str(next_pos) + '\n')


def load_turn(path):
    """Return the durable alternating-turn flag (0=new,1=retry) for a single
    contended slot."""
    if not path:
        return 0
    try:
        return int(open(path).read().strip() or '0') % 2
    except (OSError, ValueError):
        return 0


def save_turn(path, turn):
    """Persist the alternating-turn flag. A failed write propagates so the
    poll fails closed rather than silently selecting the same class forever."""
    if not path:
        return
    with open(path, 'w', encoding='utf-8') as f:
        f.write(str(turn % 2) + '\n')


def cmd_poll_list():
    # Bound the expensive header fetches: only uids not already recorded in the
    # cursor are considered as new, then previously unfetchable retry-set uids
    # (already in the cursor) are fetched again so a transient IMAP failure
    # cannot permanently replace real metadata with degraded placeholders. A
    # bounded window of candidates is scanned to fill the per-poll cap, new
    # uids first so a large retry backlog can never starve new mail.
    cap = int(os.environ.get('FM_MAIL_POLL_MAX_WAKES') or '20')
    if cap < 1:
        cap = 20
    stored_gen, seen = load_cursor(os.environ.get('FM_MAIL_CURSOR', ''))
    retry, retry_order = load_retry(os.environ.get('FM_MAIL_RETRY', ''))
    retry_pos_path = os.environ.get('FM_MAIL_RETRY_POS', '')
    retry_pos = load_retry_pos(retry_pos_path, len(retry_order))
    m = None
    try:
        m = connect_mailbox()
        m.select('INBOX')
        ur = m.untagged_responses.get('UIDVALIDITY')
        uidv = clean(ur[-1].decode()) if ur else ''
        typ, data = m.uid('search', None, 'UNSEEN')
        unseen = []
        for x in (data[0] or b'').split():
            uid = x.decode() if isinstance(x, bytes) else str(x)
            unseen.append(uid)
        if uidv and uidv == stored_gen:
            # Same mailbox generation: skip uids this home already surfaced so
            # the fetch budget goes to genuinely new mail. Retry-set uids are
            # only meaningful for this generation.
            new_uids = [u for u in unseen if u not in seen]
        else:
            # On a generation change the cursor and retry set are stale, so
            # list everything as new and ignore retry membership; bash clears
            # both files before the wake loop.
            new_uids = list(unseen)
            retry = set()
            retry_order = []
        # Bound the expensive fetch work with a window, applied to each class
        # separately so a large new-mail backlog cannot slice retry candidates
        # out of the scan. The retry scan starts at a durable position; the
        # persist block below owns when that position advances.
        window = max(cap * 4, cap + 10)
        new_candidates = new_uids[:window]
        # Only a retry uid that is already surfaced (in the cursor) is a pure
        # retry re-fetch. A retry-set uid that is not yet in the cursor is a
        # degraded wake that failed to record - it stays a new candidate so
        # the next poll surfaces it again as degraded instead of silently
        # dropping it. The window itself (regardless of seen membership) is
        # kept so a scan window of only unseen uids can still advance the
        # durable cursor past itself, never stalling the march over the whole
        # retry set.
        retry_window = retry_scan_window(retry_order, retry_pos, window)
        retry_candidates = [u for u in retry_window if u in seen]
        turn_path = os.environ.get('FM_MAIL_TURN', '')
        next_turn = None
        if cap == 1 and new_candidates and retry_candidates:
            # A single contended slot alternates between new surfacing and
            # retry recovery, so a sustained new-mail flood can never starve
            # recovered metadata indefinitely, and a retry backlog can never
            # delay new mail for more than one poll.
            if load_turn(turn_path) == 0:
                new_budget, retry_budget = 1, 0
                next_turn = 1
            else:
                new_budget, retry_budget = 0, 1
                next_turn = 0
        else:
            # Reserve a quarter of the cap (at least one) for retry successes
            # so a sustained new-mail flood cannot starve recovered metadata,
            # but never let the reservation fully suppress new mail: when both
            # classes have candidates, new mail always keeps at least one slot.
            retry_budget = max(1, cap // 4) if retry_candidates else 0
            new_budget = cap - retry_budget
        out = []
        new_emitted = 0
        retry_emitted = 0
        retry_examined = 0
        retry_idx = -1
        first_retry_emitted_index = -1
        for u in new_candidates + retry_candidates:
            is_retry = u in retry and u in seen
            if is_retry:
                retry_idx += 1
            if is_retry:
                if retry_emitted >= retry_budget:
                    # Past the retry budget: leave this candidate in the scan
                    # (do not advance past it) so a later poll reaches it once
                    # budget frees up. Advancing the durable position by the
                    # full window while emitting only the budgeted prefix would
                    # revisit the same prefix forever and strand later
                    # recovered uids (a scan is a cursor over the whole retry
                    # set, and every uid must be reachable).
                    continue
                retry_examined += 1
            elif new_emitted >= new_budget:
                continue
            # A raised or empty FETCH is treated as a failure for THIS uid only,
            # so one bad message can never abort the bounded scan: a new uid is
            # surfaced degraded, a retry uid is left for a later scan step, and
            # the scan advances.
            try:
                typ, msg = m.uid('fetch', u.encode(), '(BODY.PEEK[HEADER])')
                if typ != 'OK' or not msg or not msg[0]:
                    raise ValueError('no header data')
                mi = email.message_from_bytes(msg[0][1])
                uid = clean(u)
                idate = clean(dec(mi.get('Date')))
                subj = clean(dec(mi.get('Subject')))
                fr = clean(dec(mi.get('From')))
            except Exception:
                if is_retry:
                    continue
                out.append((clean(u), '', '(no header)',
                            'unfetchable header - see fm-mail read', 'degraded'))
                new_emitted += 1
                continue
            status = 'retry' if is_retry else 'ok'
            out.append((uid, idate, fr, subj, status))
            if is_retry:
                retry_emitted += 1
                if first_retry_emitted_index == -1:
                    first_retry_emitted_index = retry_idx
            else:
                new_emitted += 1
        # Finish every IMAP round-trip before emit or persist so a hung
        # logout cannot run after the retry-scan position advances. Then emit
        # the mailbox generation guard and each message row (uid, date, from,
        # subject, status) so the bash layer diffs against the cursor and the
        # retry set. Flush stdout before persisting: under a pipe CPython
        # block-buffers, and a timeout kill would otherwise discard unflushed
        # rows after the position had already advanced. An interruption
        # between emission and the position write must never advance the
        # cursor over rows that never reached the bash wake layer. A failed
        # position write still fails the poll loudly, so the same bounded
        # window is re-scanned on the next poll rather than silently
        # restarting from the old head. The persist block below owns when the
        # retry-scan position advances, including under a new-mail flood.
        try:
            m.logout()
        except Exception:
            pass
        m = None
        print('uidvalidity\t%s' % uidv)
        for uid, idate, fr, subj, status in out:
            print('%s\t%s\t%s\t%s\t%s' % (uid, idate, fr, subj, status))
        sys.stdout.flush()
        # The retry-scan cursor must keep marching so every retry uid is
        # reachable, but it must never advance past a uid whose wake did not
        # durably publish. Rows are handed to the bash wake layer immediately
        # below; Python cannot observe whether every wake_for succeeded, so the
        # durable position advances only up to (never past) the first emitted
        # retry uid. If that uid's wake fails to publish, it stays at the head
        # of the scan for the next poll; if the wake succeeds, the bash layer
        # removes it from the retry set and the same numeric start scans the
        # next remaining uid. Advance is keyed off whether a retry row was
        # emitted (first_retry_emitted_index), never off whether `out` is
        # empty: new-mail rows filling the poll must not stall the retry
        # cursor (Greptile 'Retry window stops progressing'). When no retry
        # row was emitted, candidates were examined (unfetchable) or the
        # window held only unseen uids, and the position advances so the
        # scan does not stall. An emitted retry at index 0 leaves the
        # position unchanged, same as landing on that uid.
        # Three cases advance it:
        #  1. budget > 0 and a retry row was emitted past index 0 -> by the
        #     number of unfetchable retry candidates before the first emitted
        #     one, landing the cursor on that uid (never past it).
        #  2. budget > 0 but no retry row emitted -> by the candidates actually
        #     examined within budget (fetched or unfetchable), never the full
        #     window (Greptile 'Retry cursor skips candidates'), even when
        #     new-mail rows fill `out`.
        #  3. budget == 0 because the window held only unseen uids (none
        #      qualified as a seen retry) -> by the scanned window itself, so
        #      a leading stale window cannot stall the march and strand a
        #      later eligible retry uid (Greptile 'Retry cursor stalls
        #      permanently'), even when new-mail rows fill `out`.
        # A cap=1 new-mail turn (qualifiers exist but yield deliberately,
        # retry_budget 0 with retry_candidates non-empty) leaves the position
        # unchanged so an unexamined window is never skipped.
        if retry_budget > 0 and len(retry_candidates) > 0:
            if first_retry_emitted_index > 0:
                save_retry_pos(retry_pos_path, len(retry_order),
                               first_retry_emitted_index, retry_pos)
            elif first_retry_emitted_index < 0:
                save_retry_pos(retry_pos_path, len(retry_order),
                               max(1, retry_examined), retry_pos)
        elif len(retry_window) > 0 and len(retry_candidates) == 0:
            save_retry_pos(retry_pos_path, len(retry_order),
                           len(retry_window), retry_pos)
        # Persist the cap-one alternation turn only after the rows are emitted
        # and flushed, so a kill between the decision and the emit can never
        # skip an unspent turn.
        if next_turn is not None:
            save_turn(turn_path, next_turn)
        return 0
    except Exception as e:
        # stderr, not stdout: the bash poll's command substitution captures
        # stdout, so a poll error printed to stdout is swallowed with the list
        # and the poll dies rc=1 with nothing left to report.
        print('fm-mail poll error:', e, file=sys.stderr)
        return 1
    finally:
        if m is not None:
            try:
                m.logout()
            except Exception:
                pass


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'read':
        return cmd_read()
    if cmd == 'send':
        if len(sys.argv) < 5:
            return 1
        return cmd_send(sys.argv[2], sys.argv[3], sys.argv[4])
    if cmd == 'send-template' and len(sys.argv) == 5:
        return cmd_template(sys.argv[4], sys.argv[2], sys.argv[3])
    if cmd == 'render-template' and len(sys.argv) in (3, 4):
        return cmd_template(sys.argv[2], output=sys.argv[3] if len(sys.argv) == 4 else 'html')
    if cmd == 'seen':
        return cmd_seen(sys.argv[2] if len(sys.argv) > 2 else '')
    if cmd == 'poll_list':
        return cmd_poll_list()
    raise SystemExit('unknown command')


if __name__ == '__main__':
    sys.exit(main())
