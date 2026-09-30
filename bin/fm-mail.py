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
import json
import os
import re
import socket
import ssl
import signal
import subprocess
import sys
import time
import email
import smtplib
from contextlib import contextmanager
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import formatdate, getaddresses
from pathlib import Path

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
MAX_AFK_BODY_BYTES = 256 * 1024

ROOT = Path(__file__).resolve().parent.parent
STATE = Path(os.environ.get('FM_STATE_OVERRIDE') or Path(os.environ.get('FM_HOME') or ROOT) / 'state')
OWNER_EMAIL = Path(__file__).resolve().with_name('fm-afk-owner-email').read_text(encoding='ascii').strip()

class AfkBodyFetchError(Exception):
    pass

@contextmanager
def away_posture_operation():
    contract = Path(__file__).resolve().with_name('fm-afk-contract.sh')
    lock_script = (
        '. "$1"\n'
        "trap 'fm_afk_contract_lock_release || true' EXIT\n"
        'fm_afk_contract_lock_hold "$2" || exit 1\n'
        'printf "locked\\n"\n'
        'IFS= read -r release\n'
        '[ "$release" = release ]\n'
    )
    env = os.environ.copy()
    env.setdefault('FM_HOME', str(ROOT))
    try:
        process = subprocess.Popen(
            ['bash', '-c', lock_script, 'fm-mail-away-lock', str(contract), str(STATE)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            env=env,
        )
    except OSError as error:
        raise RuntimeError('could not start away-posture lock owner') from error
    if process.stdout.readline() != 'locked\n':
        result = process.wait()
        process.stdout.close()
        raise RuntimeError(f'could not acquire away-posture lock (exit {result})')
    old_posture = os.environ.get('FM_AFK_POSTURE')
    old_locked = os.environ.get('FM_AFK_CONTRACT_LOCK_HELD')

    try:
        try:
            (STATE / '.afk-contract').lstat()
            active = True
        except FileNotFoundError:
            active = False
        except OSError:
            active = True
        if active:
            try:
                validated = subprocess.run(
                    [str(contract), 'validate'], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, env=env,
                )
                if validated.returncode == 0:
                    posture = subprocess.run(
                        [str(contract), 'mode'], stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, env=env,
                    )
                    if posture.returncode == 0 and posture.stdout.strip() == 'quiet':
                        active = False
            except (OSError, subprocess.SubprocessError):
                active = True
        os.environ['FM_AFK_POSTURE'] = '1' if active else '0'
        os.environ['FM_AFK_CONTRACT_LOCK_HELD'] = '1'

        yield
    finally:
        if process.poll() is None:
            try:
                process.stdin.write('release\n')
                process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
            process.stdin.close()
            process.wait()
        process.stdout.close()
        if old_posture is None:
            os.environ.pop('FM_AFK_POSTURE', None)
        else:
            os.environ['FM_AFK_POSTURE'] = old_posture
        if old_locked is None:
            os.environ.pop('FM_AFK_CONTRACT_LOCK_HELD', None)
        else:
            os.environ['FM_AFK_CONTRACT_LOCK_HELD'] = old_locked

def afk_record_field(name):
    contract = os.path.join(os.path.dirname(__file__), 'fm-afk-contract.sh')
    env = os.environ.copy()
    env.setdefault('FM_HOME', os.path.dirname(os.path.dirname(__file__)))
    result = subprocess.run(
        [contract, 'field', name],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    return result.stdout.strip() if result.returncode == 0 else None

def afk_email_context():
    if os.environ.get('FM_AFK_POSTURE') != '1':
        return None, False, False

    contract = os.path.join(os.path.dirname(__file__), 'fm-afk-contract.sh')
    env = os.environ.copy()
    env.setdefault('FM_HOME', os.path.dirname(os.path.dirname(__file__)))
    try:
        validated = subprocess.run(
            [contract, 'validate'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        if validated.returncode != 0:
            return None, True, True
        reach = afk_record_field('reach_channels')
        if reach == 'none':
            return None, True, False
        if reach != 'email':
            return None, True, True
    except (OSError, subprocess.SubprocessError):
        return None, True, True
    helper = os.path.join(os.path.dirname(__file__), 'fm-afk-email.py')
    try:

        configured = subprocess.run(
            [sys.executable, helper, 'configured'],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None, True, False
    recipient = configured.stdout.strip()
    if configured.returncode != 0 or not recipient:
        return None, True, False
    if recipient.casefold() != OWNER_EMAIL.casefold():
        return None, True, True
    return recipient, True, False

def fetched_literal(data):
    for item in data or []:
        if isinstance(item, tuple) and len(item) > 1 and isinstance(item[1], bytes):
            return item[1]
    return None

def fetched_size(data):
    for item in data or []:
        if not isinstance(item, tuple) or not item or not isinstance(item[0], bytes):
            continue
        match = re.search(rb'\bRFC822\.SIZE\s+(\d+)', item[0], re.IGNORECASE)
        if match:
            return int(match.group(1))
    return None

def from_is_configured(header, recipient):
    addresses = getaddresses([header or ''])
    return len(addresses) == 1 and addresses[0][1].strip().casefold() == recipient.casefold()

def authentication_property(clause, name):
    match = re.search(
        rf'(?<![A-Za-z0-9_-]){re.escape(name)}=([^;\s]+)', clause, re.IGNORECASE
    )
    return match.group(1).strip("\"'") if match else None

def gmail_aligned(domain):
    domain = str(domain or '').strip().strip("\"'").casefold()
    if '@' in domain:
        domain = domain.rsplit('@', 1)[1]
    domain = domain.rstrip('.')
    return domain == 'gmail.com' or domain.endswith('.gmail.com')

def gmail_authentication_pass(message):
    if IMH.casefold() != 'imap.gmail.com':
        return False
    receiver_result = message.get('Authentication-Results')
    if receiver_result is None:
        return False
    clauses = str(receiver_result).split(';')

    authserv = clauses[0].strip().split()
    if not authserv or authserv[0].casefold() != 'mx.google.com':
        return False
    for clause in clauses[1:]:
        if re.match(r'\s*dkim=pass(?:\s|$)', clause, re.IGNORECASE):
            domain = authentication_property(clause, 'header.d')
            if domain is None:
                domain = authentication_property(clause, 'header.i')
            if gmail_aligned(domain):
                return True
        if re.match(r'\s*dmarc=pass(?:\s|$)', clause, re.IGNORECASE):
            if gmail_aligned(authentication_property(clause, 'header.from')):
                return True
    return False

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

def connect_mailbox(timeout=MAIL_TIMEOUT):
    m = imaplib.IMAP4_SSL(IMH, IMP, ssl_context=CTX, timeout=timeout)
    m.login(USER, PW)
    return m

def plain_body(msg):
    """Return inline text/plain content, excluding attachments and embedded mail."""
    chunks = []

    def collect(part):
        if part.get_content_disposition() == 'attachment' or part.get_filename():
            return
        if part.get_content_type() == 'message/rfc822':
            return
        payload = part.get_payload()
        if isinstance(payload, list):
            for child in payload:
                collect(child)
            return
        if part.get_content_type() != 'text/plain':
            return
        payload = part.get_payload(decode=True)
        if payload is None:
            return

        charset = part.get_content_charset() or 'utf-8'
        try:
            chunks.append(payload.decode(charset, 'replace'))
        except LookupError:
            chunks.append(payload.decode('utf-8', 'replace'))

    if msg is not None:
        collect(msg)
    return '\n'.join(chunks)

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
        away_posture = os.environ.get('FM_AFK_POSTURE') == '1'
        for i in ids[-READ_LIMIT:]:
            uid = i.decode() if isinstance(i, bytes) else str(i)
            message_bytes = None
            if away_posture:
                typ, headers = m.uid('fetch', i, '(BODY.PEEK[HEADER])')
                header_bytes = fetched_literal(headers) if typ == 'OK' else None
                if not header_bytes:
                    print('---')
                    print('Uid:', uid)
                    print('From:', '(unfetchable)')
                    print('Date:', '')
                    print('Subj:', 'unfetchable header - see fm-mail read')
                    print('Body:', '(body unavailable)')
                    continue
                mi = email.message_from_bytes(header_bytes)
                trusted_sender = (
                    from_is_configured(dec(mi.get('From')), OWNER_EMAIL)

                    and gmail_authentication_pass(mi)
                )
                if not trusted_sender:
                    print('---')
                    print('From:', dec(mi.get('From')))
                    print('Date:', dec(mi.get('Date')))
                    print('Subj:', dec(mi.get('Subject')))
                    print('Body:', '(away-mode message body not read)')
                    continue
                typ, body_data = m.uid('fetch', i, '(BODY.PEEK[])')
                message_bytes = fetched_literal(body_data) if typ == 'OK' else None
            else:
                typ, body_data = m.uid('fetch', i, '(BODY.PEEK[])')
                message_bytes = fetched_literal(body_data) if typ == 'OK' else None
            if not message_bytes:
                print('---')
                print('Uid:', uid)
                print('From:', '(unfetchable)')
                print('Date:', '')
                print('Subj:', 'unfetchable body - see fm-mail read')
                print('Body:', '(body unavailable)')
                continue
            mi = email.message_from_bytes(message_bytes)
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

def send_message(to, subj, body, timeout=MAIL_TIMEOUT):
    m = EmailMessage()
    m['From'] = USER
    m['To'] = to
    m['Subject'] = subj
    m['Date'] = formatdate(localtime=True)
    m.set_content(body)
    with smtplib.SMTP_SSL(STH, STP, context=CTX, timeout=timeout) as s:
        s.login(USER, PW)
        s.send_message(m)

def cmd_send(to, subj, body):
    try:
        if body == '-':
            body = sys.stdin.read().rstrip('\n')
        send_message(to, subj, body)
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

def poll_budget():
    """Seconds of IMAP work one poll may spend. Invalid or non-positive values become 6."""
    try:
        value = float(os.environ.get('FM_MAIL_POLL_BUDGET') or '6')
    except ValueError:
        value = 6.0
    return value if value > 0 else 6.0

class PollDeadline(TimeoutError):
    pass

def raise_poll_deadline(signum, frame):
    raise PollDeadline('mail poll budget exhausted')

def arm_poll_deadline(seconds):
    """Interrupt any blocking IMAP work once the poll's wall-clock budget ends."""
    if hasattr(signal, 'setitimer'):
        signal.signal(signal.SIGALRM, raise_poll_deadline)
        signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.001))

def disarm_poll_deadline():
    if hasattr(signal, 'setitimer'):
        signal.setitimer(signal.ITIMER_REAL, 0)

AWAY_READ_ATTEMPTS = 3

def load_away_scan(path, identity):
    """Return the highest uid already examined under this away posture and
    mailbox generation, plus failed reads awaiting retry as
    {uid: (attempts, owner)}; any other identity starts the scan afresh."""
    if not path:
        return 0, {}
    try:
        lines = open(path, encoding='utf-8').read().splitlines()
    except OSError:
        return 0, {}
    if len(lines) < 2 or lines[0] != identity or not lines[1].isdigit():
        return 0, {}
    pending = {}
    for line in lines[2:]:
        fields = line.split(' ')
        if len(fields) == 3 and all(field.isdigit() for field in fields):
            pending[fields[0]] = (int(fields[1]), fields[2] == '1')
    return int(lines[1]), pending

def save_away_scan(path, identity, high, pending):
    """Stage the next away-scan state; fm-mail.sh commits it only after every
    emitted row has been published."""
    if not path:
        return
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('%s\n%d\n' % (identity, high))
        for uid in sorted(pending, key=int):
            attempts, owner = pending[uid]
            f.write('%s %d %d\n' % (uid, attempts, 1 if owner else 0))
    os.replace(tmp, path + '.next')

def send_unreadable_reply_alert(recipient, uid, seconds):
    """Tell the owner one reply could not be read, without any message content."""
    try:
        arm_poll_deadline(seconds)
        send_message(
            recipient,
            'Firstmate away alert: one reply could not be read',
            'Firstmate could not read one of your email replies (mail UID %s) after %d attempts '
            'and stopped retrying it. It remains unread in the inbox; please resend your answer.'
            % (uid, AWAY_READ_ATTEMPTS),
            timeout=max(0.5, min(MAIL_TIMEOUT, seconds)),
        )
        return True
    except Exception as error:
        print('fm-mail: away unreadable-reply alert was not sent:', error, file=sys.stderr)
        return False
    finally:
        disarm_poll_deadline()

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
    budget = poll_budget()
    deadline = time.monotonic() + budget
    m = None
    try:
        arm_poll_deadline(budget)
        m = connect_mailbox(min(MAIL_TIMEOUT, budget))
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
        # Bound expensive header work to at most twenty fetches per poll,
        # including retries. The retry scan starts at a durable position; the
        # persist block below owns when that position advances.
        window = min(max(cap * 4, cap + 10), 20)
        retry_window = retry_scan_window(retry_order, retry_pos, window)
        retry_candidates = [u for u in retry_window if u in seen]
        recipient, afk_email_active, invalid_posture = afk_email_context()

        # While away, one persistent away-scan cursor walks unseen mail, new
        # and retry alike, in ascending uid order, so each uid is examined at
        # most once per away posture and ignored mail can never block a later
        # reply. Ignored mail stays unseen and out of the mail cursor, so
        # attended polling reports it after return.
        away_mode = afk_email_active and not invalid_posture
        away_scan_path = os.environ.get('FM_MAIL_AWAY_SCAN', '')
        away_scan_identity = ''
        away_high = 0
        away_pending = {}
        away_processed = []
        away_skipped = set()
        away_held = set()
        away_owner_failed = set()
        away_retained = set()
        if away_mode:
            away_scan_identity = 'away-scan\t%s\t%s' % (
                uidv, afk_record_field('entered_epoch') or '')
            away_high, away_pending = load_away_scan(away_scan_path, away_scan_identity)
            unseen_set = set(unseen)
            away_pending = {u: v for u, v in away_pending.items()
                            if u in unseen_set or v[0] >= AWAY_READ_ATTEMPTS}
            new_set = set(new_uids)
            new_candidates = sorted(
                (u for u, v in away_pending.items() if v[0] < AWAY_READ_ATTEMPTS), key=int)
            new_candidates += sorted(
                (u for u in unseen if u.isdigit() and int(u) > away_high), key=int)
            retry_window = []
            retry_candidates = []
        else:
            new_set = set()
            new_candidates = new_uids[:window]
        # Only a retry uid that is already surfaced (in the cursor) is a pure
        # retry re-fetch. A retry-set uid that is not yet in the cursor is a
        # degraded wake that failed to record - it stays a new candidate so
        # the next poll surfaces it again as degraded instead of silently
        # dropping it. The window itself (regardless of seen membership) is
        # kept so a scan window of only unseen uids can still advance the
        # durable cursor past itself, never stalling the march over the whole
        # retry set.
        afk_enabled = recipient is not None

        afk_messages = []
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
        header_fetches = 0
        try:
            for u in new_candidates + retry_candidates:
                is_retry = u in retry and u in seen
                if away_mode:
                    if new_emitted + retry_emitted >= cap:
                        break
                    away_processed.append(u)
                    if not is_retry and u not in new_set and u not in away_pending:
                        away_skipped.add(u)
                        continue
                elif is_retry:
                    retry_idx += 1
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
                if invalid_posture:
                    out.append((clean(u), '', '', '', 'deferred'))
                    if is_retry:
                        retry_emitted += 1
                        if first_retry_emitted_index == -1:
                            first_retry_emitted_index = retry_idx
                    else:
                        new_emitted += 1
                    continue

                if header_fetches >= 20:
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                sock = getattr(m, 'sock', None)
                if sock is not None:
                    sock.settimeout(min(MAIL_TIMEOUT, remaining))
                header_fetches += 1
                # A raised or empty header FETCH is treated as a failure for THIS uid only,
                # so one bad message can never abort the bounded scan: a new uid is
                # surfaced degraded, a retry uid is left for a later scan step, and
                # the scan advances.
                try:
                    fetch_spec = '(RFC822.SIZE BODY.PEEK[HEADER])' if afk_enabled else '(BODY.PEEK[HEADER])'
                    typ, msg = m.uid('fetch', u.encode(), fetch_spec)
                    if typ != 'OK' or not msg or not msg[0]:
                        raise ValueError('no header data')
                    header_bytes = fetched_literal(msg)
                    if not header_bytes:
                        raise ValueError('no header data')
                    mi = email.message_from_bytes(header_bytes)

                    uid = clean(u)
                    idate = clean(dec(mi.get('Date')))
                    subj = clean(dec(mi.get('Subject')))
                    fr = clean(dec(mi.get('From')))
                    ignored = afk_email_active and (
                        not from_is_configured(fr, OWNER_EMAIL)
                        or not gmail_authentication_pass(mi)
                    )
                    if afk_enabled and not ignored and from_is_configured(fr, recipient):

                        try:
                            message_size = fetched_size(msg)
                            if message_size is None:
                                raise AfkBodyFetchError('RFC822.SIZE was unavailable for the configured sender')
                            if message_size <= MAX_AFK_BODY_BYTES:
                                body_type, body_data = m.uid(
                                    'fetch', u.encode(), f'(BODY.PEEK[]<0.{MAX_AFK_BODY_BYTES}>)')
                                body_bytes = fetched_literal(body_data) if body_type == 'OK' else None
                                if body_bytes is None or len(body_bytes) != message_size:
                                    raise AfkBodyFetchError('configured sender body fetch was incomplete')
                                body_message = email.message_from_bytes(body_bytes)
                                afk_messages.append({
                                    'uidvalidity': uidv,
                                    'uid': uid,
                                    'from': fr,
                                    'subject': subj,
                                    'body': plain_body(body_message),
                                })
                            else:
                                subj = clean(
                                    f'[away-mode reply not processed: message body exceeds 256 KiB] {subj}')

                        except (AfkBodyFetchError, socket.timeout, TimeoutError):
                            raise
                        except Exception as error:
                            raise AfkBodyFetchError('configured sender body fetch failed') from error
                except AfkBodyFetchError:
                    away_held.add(u)
                    away_owner_failed.add(u)
                    if is_retry:
                        continue
                    out.append((uid, idate, fr, subj, 'degraded'))
                    new_emitted += 1
                    continue
                except (socket.timeout, TimeoutError):
                    break
                except Exception:
                    if afk_email_active:
                        away_held.add(u)
                        out.append((clean(u), '', '(unverified sender)', '', 'deferred'))
                        if is_retry:
                            retry_emitted += 1
                            if first_retry_emitted_index == -1:
                                first_retry_emitted_index = retry_idx
                        else:
                            new_emitted += 1
                        continue
                    if is_retry:
                        continue
                    out.append((clean(u), '', '(no header)',
                                'unfetchable header - see fm-mail read', 'degraded'))
                    new_emitted += 1
                    continue
                status = 'ignored' if ignored else ('retry' if is_retry else 'ok')
                if not ignored and afk_email_active and not afk_enabled:
                    status = 'degraded'
                    if away_mode and afk_record_field('reach_channels') == 'email':
                        away_retained.add(u)
                out.append((uid, idate, fr, subj, status))
                if status != 'ignored':
                    if is_retry:
                        retry_emitted += 1
                        if first_retry_emitted_index == -1:
                            first_retry_emitted_index = retry_idx
                    else:
                        new_emitted += 1
        except TimeoutError:
            pass
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
            remaining = max(0.1, deadline - time.monotonic())
            arm_poll_deadline(remaining)
            sock = getattr(m, 'sock', None)
            if sock is not None:
                sock.settimeout(min(MAIL_TIMEOUT, remaining))
            m.logout()
        except Exception:
            pass
        disarm_poll_deadline()
        m = None
        row_uids = {row[0] for row in out}
        afk_messages = [message for message in afk_messages if message['uid'] in row_uids]
        if afk_messages:
            helper = os.path.join(os.path.dirname(__file__), 'fm-afk-email.py')
            try:
                result = subprocess.run(
                    [sys.executable, helper, 'receive-batch'],
                    input=json.dumps(afk_messages, ensure_ascii=False),
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=os.environ.copy(),
                    timeout=max(0.5, deadline + 0.7 * budget - time.monotonic()),
                )
                handoff_failed = result.returncode != 0
            except (OSError, subprocess.SubprocessError):
                handoff_failed = True
            if handoff_failed:
                failed_uids = {message['uid'] for message in afk_messages}
                away_retained |= failed_uids
                out = [
                    (uid, idate, fr, subj, 'degraded' if uid in failed_uids else status)
                    for uid, idate, fr, subj, status in out
                ]
                print('fm-mail: away-email reply handoff failed; affected messages will retry', file=sys.stderr)
            else:
                rejected_uids = set()
                for line in result.stderr.splitlines():
                    fields = line.split('\t')
                    if (
                        len(fields) == 4
                        and fields[0] == 'fm-afk-event'
                        and fields[1] == 'reply-rejected'
                        and fields[2].isdigit()
                        and fields[3] == 'answer-too-long'
                    ):
                        rejected_uids.add(fields[2])
                if rejected_uids:
                    out = [
                        (
                            uid,
                            idate,
                            fr,
                            clean(f'[away-mode reply rejected: answer exceeds 8,000 characters] {subj}')
                            if uid in rejected_uids else subj,
                            status,
                        )
                        for uid, idate, fr, subj, status in out
                    ]
                if result.stderr:
                    sys.stderr.write(result.stderr)

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
        if away_mode:
            row_uids = {row[0] for row in out}
            high = away_high
            pending = dict(away_pending)
            for u in away_processed:
                if u in away_held:
                    attempts, owner = pending.get(u, (0, False))
                    pending[u] = (attempts + 1, owner or u in away_owner_failed)
                elif u in away_retained:
                    pending[u] = (pending.get(u, (0, True))[0], True)
                elif u in row_uids:
                    pending.pop(u, None)
                elif u not in away_skipped:
                    break
                if int(u) > high:
                    high = int(u)
            exhausted = sorted(
                (u for u, v in pending.items() if v[0] >= AWAY_READ_ATTEMPTS), key=int)
            for u in exhausted:
                if not pending[u][1] or recipient is None:
                    del pending[u]
            if high != away_high or pending != away_pending:
                save_away_scan(away_scan_path, away_scan_identity, high, pending)
            alerted = [
                u for u in exhausted if u in pending
                and send_unreadable_reply_alert(
                    recipient, u, deadline + 0.9 * budget - time.monotonic())
            ]
            if alerted:
                for u in alerted:
                    del pending[u]
                save_away_scan(away_scan_path, away_scan_identity, high, pending)
        return 0
    except Exception as e:
        # stderr, not stdout: the bash poll's command substitution captures
        # stdout, so a poll error printed to stdout is swallowed with the list
        # and the poll dies rc=1 with nothing left to report.
        print('fm-mail poll error:', e, file=sys.stderr)
        return 1
    finally:
        disarm_poll_deadline()
        if m is not None:
            try:
                m.logout()
            except Exception:
                pass

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd in ('read', 'poll_list'):
        try:
            with away_posture_operation():
                return cmd_read() if cmd == 'read' else cmd_poll_list()
        except Exception as error:
            print('fm-mail away-posture error:', error, file=sys.stderr)
            return 1
    if cmd == 'read':
        return cmd_read()
    if cmd == 'send':
        if len(sys.argv) < 5:
            return 1
        return cmd_send(sys.argv[2], sys.argv[3], sys.argv[4])
    if cmd == 'seen':
        return cmd_seen(sys.argv[2] if len(sys.argv) > 2 else '')
    raise SystemExit('unknown command')

if __name__ == '__main__':
    sys.exit(main())