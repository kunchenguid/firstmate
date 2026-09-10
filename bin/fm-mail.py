#!/usr/bin/env python3
# fm-mail.py - the IMAP/SMTP engine behind bin/fm-mail.sh.
#
# A small mail client used by fm-mail.sh:
#   read                   List unseen INBOX mail as a compact digest.
#   send <to> <subj> <body | ->   Send one SMTP message; "-" reads stdin.
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
import os
import re
import socket
import ssl
import sys
import email
import smtplib
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import formatdate

USER = os.environ['FM_MAIL_USER']
PW = os.environ['FM_MAIL_PASS']
IMH = os.environ['FM_IMAP_HOST']
IMP = int(os.environ['FM_IMAP_PORT'])
STH = os.environ['FM_SMTP_HOST']
STP = int(os.environ['FM_SMTP_PORT'])
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


def cmd_send(to, subj, body):
    try:
        if body == '-':
            body = sys.stdin.read().rstrip('\n')
        m = EmailMessage()
        m['From'] = USER
        m['To'] = to
        m['Subject'] = subj
        m['Date'] = formatdate(localtime=True)
        m.set_content(body)
        with smtplib.SMTP_SSL(STH, STP, context=CTX, timeout=MAIL_TIMEOUT) as s:
            s.login(USER, PW)
            s.send_message(m)
        print('sent to', to)
        return 0
    except Exception as e:
        print('fm-mail send error:', e)
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
    if cmd == 'seen':
        return cmd_seen(sys.argv[2] if len(sys.argv) > 2 else '')
    if cmd == 'poll_list':
        return cmd_poll_list()
    raise SystemExit('unknown command')


if __name__ == '__main__':
    sys.exit(main())