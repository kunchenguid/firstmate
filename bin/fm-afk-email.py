#!/usr/bin/env python3
# fm-afk-email.py - private state and trust rules for Pi away-email reach.
#
# The mail transport remains bin/fm-mail.sh / bin/fm-mail.py. This helper owns
# the away-email opt-in, per-outcome correlation tokens, batching state, and
# the one-time verified-reply handoff into bin/fm-inbox.sh.
import fcntl
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
from contextlib import contextmanager
from email.utils import getaddresses






from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or ROOT)
STATE = Path(os.environ.get("FM_STATE_OVERRIDE") or HOME / "state")
AFK_DIR = STATE / "afk-email"
PENDING = AFK_DIR / "pending"
SENT = AFK_DIR / "sent"
LOCK = AFK_DIR / ".lock"
TOKEN_TTL = 7 * 24 * 60 * 60
SEND_INTERVAL = 60
MAX_BATCH_ITEMS = 25
MAX_BATCH_BYTES = 24000
MAX_REPLY_CHARS = 8000
OWNER_EMAIL = Path(__file__).resolve().with_name("fm-afk-owner-email").read_text(encoding="ascii").strip()

TOKEN_RE = re.compile(r"^FM-AFK-[A-Za-z0-9_-]{16}$")


class AfkContractLockError(RuntimeError):
    pass




NOTE_ID_RE = re.compile(r"^(?!.*\.\.)[A-Za-z0-9._-]+$")
REPLY_LINE_RE = re.compile(r"^FM-AFK-REPLY (FM-AFK-[A-Za-z0-9_-]{16})$")
QUOTED_HEADER_RE = re.compile(r"^(?:From|Sent|To|Subject):", re.IGNORECASE)
EMAIL_RE = re.compile(r"^[^\s@<>]+@[^\s@<>]+$")
SECRET_ENV_RE = re.compile(
    r"(?:^|_)(?:PASS(?:WORD)?|TOKEN|SECRET|API.?KEY|CREDENTIALS?)(?:_|$)",
    re.IGNORECASE,
)


def valid_mail_port(value):
    if not value.isascii() or not value.isdigit():
        return False
    normalized = value.lstrip("0")
    return bool(normalized) and (
        len(normalized) < 5 or len(normalized) == 5 and normalized <= "65535"
    )





def mail_configuration():
    required = ["FM_MAIL_USER", "FM_MAIL_PASS", "FM_IMAP_HOST", "FM_SMTP_HOST"]
    if any(not os.environ.get(name, "").strip() for name in required):
        return None
    if os.environ.get("FM_IMAP_HOST", "").casefold() != "imap.gmail.com":
        return None
    if not valid_mail_port(os.environ.get("FM_IMAP_PORT", "993")) or not valid_mail_port(
        os.environ.get("FM_SMTP_PORT", "465")
    ):
        return None
    recipient = os.environ.get("FM_AFK_EMAIL_TO", "").strip()
    addresses = getaddresses([recipient])
    if (
        not recipient
        or recipient != OWNER_EMAIL



        or not EMAIL_RE.fullmatch(recipient)
        or len(addresses) != 1
        or addresses[0][1].casefold() != recipient.casefold()
    ):
        return None


    return {"recipient": recipient}


def contract_value(command, field=None):
    script = ROOT / "bin" / "fm-afk-contract.sh"
    args = [str(script), command]
    if field:
        args.append(field)
    result = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=os.environ.copy(),
    )
    return result.stdout.strip() if result.returncode == 0 else None


def live_record():
    if contract_value("validate") is None:
        return None
    try:
        entered = int(contract_value("field", "entered_epoch") or "")
    except ValueError:
        return None
    if contract_value("field", "reach_channels") != "email":
        return None
    return {"entered_epoch": entered}


@contextmanager
def afk_state_lock():
    AFK_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(AFK_DIR, 0o700)
    with LOCK.open("a", encoding="utf-8") as lock_handle:
        os.chmod(LOCK, 0o600)
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        yield


@contextmanager
def afk_contract_lock():
    contract = ROOT / "bin" / "fm-afk-contract.sh"
    lock_script = (
        '. "$1"\n'
        "trap 'fm_afk_contract_lock_release || true' EXIT\n"
        'fm_afk_contract_lock_hold "$2" || exit 1\n'
        'printf "locked\\n"\n'
        'IFS= read -r release\n'
        '[ "$release" = release ]\n'
    )
    try:
        process = subprocess.Popen(
            ["bash", "-c", lock_script, "fm-afk-email-lock", str(contract), str(STATE)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            env=os.environ.copy(),
        )
    except OSError as error:
        raise AfkContractLockError("could not start the away-posture lock owner") from error
    ready = process.stdout.readline()
    if ready != "locked\n":
        result = process.wait()
        process.stdout.close()
        raise AfkContractLockError(f"could not acquire the away-posture lock (exit {result})")
    try:
        yield
    finally:
        if process.poll() is None:
            try:
                process.stdin.write("release\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
            process.stdin.close()
            process.wait()
        process.stdout.close()












def atomic_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            os.chmod(temporary, 0o600)
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def token_digest(token):
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def safe_text(value, limit=4000):
    value = re.sub(r"[\r\n\t]+", " ", str(value or ""))
    value = "".join(char for char in value if char >= " " and char != "\x7f")
    return value.strip()[:limit]


def redact_secrets(text):
    secret_values = {
        value for key, value in os.environ.items()
        if SECRET_ENV_RE.search(key) and value
    }
    replacement = next(
        (candidate for candidate in ("[redacted]", "[hidden]", "[removed]", "[withheld]")
         if not any(secret in candidate for secret in secret_values)),
        None,
    )
    if replacement is None:
        marker = next(
            chr(codepoint)
            for codepoint in (*range(0xE000, 0xF900), *range(0xF0000, 0xFFFFE))
            if all(chr(codepoint) not in secret for secret in secret_values)
        )
        replacement = marker * 3

    for secret in sorted(secret_values, key=len, reverse=True):
        text = text.replace(secret, replacement)





    return text


def outcomes_by_seq():
    result = subprocess.run(
        [str(ROOT / "bin" / "fm-branch-outcome.sh"), "list", "--all"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=os.environ.copy(),
    )
    if result.returncode != 0:
        return None
    rows = {}
    try:
        for line in result.stdout.splitlines():
            row = json.loads(line)
            if not isinstance(row, dict) or type(row.get("seq")) is not int:
                return None
            rows[row["seq"]] = row
    except ValueError:





        return None
    return rows


def outcome_marker(path):
    try:
        value = path.read_text(encoding="ascii")
    except FileNotFoundError:
        return 0
    except (OSError, UnicodeError) as error:
        raise ValueError("outcome marker could not be read") from error
    value = value.rstrip("\n")
    if (
        not value
        or any(char < "0" or char > "9" for char in value)
        or len(value) > 1 and value.startswith("0")
    ):
        raise ValueError("outcome marker is malformed")
    try:
        marker = int(value)
    except ValueError as error:
        raise ValueError("outcome marker is out of range") from error
    if marker > 9007199254740991:
        raise ValueError("outcome marker is out of range")
    return marker


def live_mail_context():
    posture = live_record()
    if posture is None:
        return None, None
    config = mail_configuration()
    if config is None:
        print("fm-afk-email: mail configuration is missing for live email away posture", file=sys.stderr)
    return posture, config


def queue_unprocessed():
    posture, config = live_mail_context()
    if posture is None:
        return 0
    if config is None:
        return 1






    rows = outcomes_by_seq()
    if rows is None:
        print("fm-afk-email: outcome store is unreadable; pending email was not queued", file=sys.stderr)
        return 1
    store_last = max(rows, default=0)
    try:
        cursor = outcome_marker(STATE / ".branch-outcomes-cursor")
        processed = outcome_marker(STATE / ".branch-outcomes-processed")
        if cursor > store_last or processed > cursor:
            raise ValueError("outcome markers are ahead of the validated store")
    except ValueError:
        print("fm-afk-email: outcome markers are invalid; pending email was not queued", file=sys.stderr)
        return 1





    PENDING.mkdir(mode=0o700, parents=True, exist_ok=True)
    SENT.mkdir(mode=0o700, parents=True, exist_ok=True)
    queued = 0
    for seq, row in sorted(rows.items()):
        if seq <= processed or row.get("verdict") != "captain":
            continue
        try:
            if int(row.get("epoch", 0)) < posture["entered_epoch"]:
                continue
        except (TypeError, ValueError):
            continue
        pending_path = PENDING / f"{seq}.json"
        sent_path = SENT / f"{seq}.json"
        prior = read_json(pending_path) or read_json(sent_path)
        if prior and prior.get("away_epoch") == posture["entered_epoch"]:
            continue
        token = "FM-AFK-" + secrets.token_urlsafe(12)
        item = {
            "seq": seq,
            "task": safe_text(redact_secrets(str(row.get("task", ""))), 160),
            "summary": safe_text(redact_secrets(str(row.get("summary", "")))),






            "token": token,
            "token_hash": token_digest(token),
            "away_epoch": posture["entered_epoch"],
        }
        if not item["task"] or not item["summary"]:
            continue
        atomic_json(pending_path, item)
        queued += 1
    print(f"queued {queued} away-email item(s)")
    return 0


def flush():
    try:
        with afk_contract_lock():
            return flush_while_contract_locked()
    except AfkContractLockError as error:
        print(f"fm-afk-email: {error}; no email was sent", file=sys.stderr)
        return 1


def flush_while_contract_locked():





    posture, config = live_mail_context()
    if posture is None:
        return 0
    if config is None:
        return 1
    with afk_state_lock():








        candidates = []
        for path in sorted(PENDING.glob("*.json"), key=lambda item: int(item.stem) if item.stem.isdigit() else 0):
            item = read_json(path)
            if not isinstance(item, dict):
                continue
            if item.get("away_epoch") != posture["entered_epoch"]:
                path.unlink(missing_ok=True)
                continue
            item["task"] = safe_text(redact_secrets(str(item.get("task", ""))), 160)
            item["summary"] = safe_text(redact_secrets(str(item.get("summary", ""))))
            sent_item = read_json(SENT / path.name)
            if isinstance(sent_item, dict) and sent_item.get("token_hash") == item.get("token_hash"):
                for field in (
                    "used_epoch", "used_mail_key", "used_request_id", "used_note_id",
                    "handoff_request_id", "handoff_mail_key", "handoff_body_hash",
                ):
                    if field in sent_item:
                        item[field] = sent_item[field]





            candidates.append((path, item))
            if len(candidates) >= MAX_BATCH_ITEMS:
                break
        if not candidates:
            return 0
        last_sent_path = AFK_DIR / ".last-sent"
        try:
            last_sent = int(last_sent_path.read_text(encoding="ascii").strip())
        except (OSError, ValueError):
            last_sent = 0
        remaining = SEND_INTERVAL - (int(time.time()) - last_sent)
        if remaining > 0:
            print(f"deferred {remaining}s")
            return 0
        lines = ["Firstmate away update", ""]
        included = []
        for path, item in candidates:
            token = item.get("token", "")
            if not TOKEN_RE.fullmatch(token):
                continue
            block = [
                f"[{item['seq']}] {item['task']}: {item['summary']}",
                f"Reply to this item by putting this exact line first in your reply:",
                f"FM-AFK-REPLY {token}",
                "",
            ]
            if len("\n".join(lines + block).encode("utf-8")) > MAX_BATCH_BYTES:
                break
            lines.extend(block)
            included.append((path, item))
        if not included:
            print("no sendable away-email items", file=sys.stderr)
            return 1
        send_started_epoch = int(time.time())
        for path, item in included:
            item["send_started_epoch"] = send_started_epoch
            item["send_expires_epoch"] = send_started_epoch + TOKEN_TTL
            atomic_json(path, item)





        lines.extend([
            "Replies from the configured address with an unexpired item code are treated as your words for that item only.",
            "Other messages are untrusted and cannot answer an item.",
            "",
            "Safety: Email replies never authorize destructive, irreversible, or security-sensitive actions; those always wait for your return or a trusted-channel confirmation.",
        ])
        body = "\n".join(lines) + "\n"
        subject = f"Firstmate away update ({len(included)} item{'s' if len(included) != 1 else ''})"
        command = [str(ROOT / "bin" / "fm-mail.sh"), "send", config["recipient"], subject, "-"]
        result = subprocess.run(command, input=body, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
        if result.returncode != 0:
            print("fm-afk-email: outbound message was not confirmed; it remains queued", file=sys.stderr)
            return 1
        sent_epoch = int(time.time())
        for path, item in included:
            sent_item = {
                "seq": item["seq"],
                "task": item["task"],
                "summary": item["summary"],
                "token_hash": item["token_hash"],
                "away_epoch": item["away_epoch"],
                "sent_epoch": sent_epoch,
                "expires_epoch": sent_epoch + TOKEN_TTL,
            }
            for field in (
                "used_epoch", "used_mail_key", "used_request_id", "used_note_id",
                "handoff_request_id", "handoff_mail_key", "handoff_body_hash",
            ):
                if field in item:
                    sent_item[field] = item[field]





            atomic_json(SENT / path.name, sent_item)
            path.unlink(missing_ok=True)
        temporary = AFK_DIR / f".last-sent.{os.getpid()}.tmp"
        temporary.write_text(f"{sent_epoch}\n", encoding="ascii")
        os.chmod(temporary, 0o600)
        os.replace(temporary, last_sent_path)
        print(f"sent {len(included)} away-email item(s)")
    return 0


def extract_reply(body):
    lines = str(body or "").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    first = next((index for index, line in enumerate(lines) if line.strip()), None)
    if first is None:
        return None, ""
    match = REPLY_LINE_RE.fullmatch(lines[first])
    if not match:
        return None, ""
    answer_lines = []
    for line in lines[first + 1:]:
        stripped = line.lstrip()
        if (
            stripped.startswith(">")
            or stripped.startswith("On ") and stripped.endswith("wrote:")
            or stripped == "-----Original Message-----"
            or QUOTED_HEADER_RE.match(stripped)
        ):





            break
        answer_lines.append(line)
    answer = "\n".join(answer_lines).strip()
    return match.group(1), answer


def inbox_identity(note_id):
    result = subprocess.run(
        [str(ROOT / "bin" / "fm-inbox.sh"), "identity", note_id],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=os.environ.copy(),
    )
    if result.returncode != 0:
        return None
    try:
        identity = json.loads(result.stdout)
    except ValueError:
        return None
    if (
        not isinstance(identity, dict)
        or identity.get("schema") != "fm-inbox-identity.v1"
        or identity.get("id") != note_id
    ):
        return None
    return identity


def inbox_note_body(note_id):
    result = subprocess.run(
        [str(ROOT / "bin" / "fm-inbox.sh"), "show", note_id],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=os.environ.copy(),
    )
    return result.stdout if result.returncode == 0 else None


def inbox_note(request_id, body):
    command = [str(ROOT / "bin" / "fm-inbox.sh"), "note", "--request-id", request_id, "--json", "-"]
    result = subprocess.run(command, input=body, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
    try:
        receipt = json.loads(result.stdout)
    except ValueError:
        receipt = None
    note_id = receipt.get("id") if isinstance(receipt, dict) else None
    valid_receipt = (
        result.returncode == 0
        and isinstance(receipt, dict)
        and receipt.get("schema") == "fm-inbox-note.v1"
        and receipt.get("request_id") == request_id
        and receipt.get("saved") is True
        and (receipt.get("announced") is True or receipt.get("acknowledged") is True)
        and isinstance(note_id, str)
        and NOTE_ID_RE.fullmatch(note_id)
    )
    identity = inbox_identity(note_id) if valid_receipt else None
    saved_body = inbox_note_body(note_id) if identity else None
    if (
        not identity
        or identity.get("request_id") != request_id
        or saved_body != body
    ):
        print("fm-afk-email: inbox handoff could not be confirmed; mail poll will retry", file=sys.stderr)
        return None
    return note_id


def validate_handoff_state_item(path, store):
    try:
        item = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError) as error:
        raise ValueError("away-email state could not be read") from error
    if not isinstance(item, dict):
        raise ValueError("away-email state is malformed")
    seq = item.get("seq")
    if (
        type(seq) is not int
        or seq <= 0
        or path.stem != str(seq)
        or not isinstance(item.get("task"), str)
        or not item["task"].strip()
        or not isinstance(item.get("summary"), str)
        or not item["summary"].strip()
        or type(item.get("away_epoch")) is not int
        or item["away_epoch"] <= 0
        or not isinstance(item.get("token_hash"), str)
        or not re.fullmatch(r"[a-f0-9]{64}", item["token_hash"])
    ):
        raise ValueError("away-email state is malformed")
    if store == "pending":
        token = item.get("token")
        if not isinstance(token, str) or not TOKEN_RE.fullmatch(token) or token_digest(token) != item["token_hash"]:
            raise ValueError("away-email state is malformed")
        send_fields = {"send_started_epoch", "send_expires_epoch"}
        present_send_fields = send_fields.intersection(item)
        if present_send_fields and present_send_fields != send_fields:
            raise ValueError("away-email state is malformed")
        if present_send_fields and (
            type(item["send_started_epoch"]) is not int
            or type(item["send_expires_epoch"]) is not int
            or item["send_started_epoch"] <= 0
            or item["send_expires_epoch"] <= item["send_started_epoch"]
        ):
            raise ValueError("away-email state is malformed")
        present_sent_fields = {"sent_epoch", "expires_epoch"}.intersection(item)
        if present_sent_fields and (
            present_sent_fields != {"sent_epoch", "expires_epoch"}
            or not present_send_fields
            or type(item["sent_epoch"]) is not int
            or type(item["expires_epoch"]) is not int
            or item["sent_epoch"] != item["send_started_epoch"]
            or item["expires_epoch"] != item["send_expires_epoch"]
        ):




            raise ValueError("away-email state is malformed")
    else:
        if (
            type(item.get("sent_epoch")) is not int
            or type(item.get("expires_epoch")) is not int
            or item["sent_epoch"] <= 0
            or item["expires_epoch"] <= item["sent_epoch"]
            or "send_started_epoch" in item
            or "send_expires_epoch" in item
        ):
            raise ValueError("away-email state is malformed")
    handoff_fields = {"handoff_request_id", "handoff_mail_key", "handoff_body_hash"}
    present_handoff_fields = handoff_fields.intersection(item)
    if present_handoff_fields and present_handoff_fields != handoff_fields:
        raise ValueError("away-email state is malformed")
    if present_handoff_fields:
        mail_key = item["handoff_mail_key"]
        if (
            not isinstance(mail_key, str)
            or not re.fullmatch(r"[a-f0-9]{24}", mail_key)
            or item["handoff_request_id"] != f"afk-email-{seq}-{mail_key}"
            or not isinstance(item["handoff_body_hash"], str)
            or not re.fullmatch(r"[a-f0-9]{64}", item["handoff_body_hash"])
        ):
            raise ValueError("away-email state is malformed")
    used_fields = {"used_epoch", "used_mail_key"}
    used_handoff_fields = {"used_request_id", "used_note_id"}
    present_used_fields = used_fields.intersection(item)
    present_used_handoff_fields = used_handoff_fields.intersection(item)
    if present_used_fields and present_used_fields != used_fields:
        raise ValueError("away-email state is malformed")
    if present_used_handoff_fields and present_used_handoff_fields != used_handoff_fields:
        raise ValueError("away-email state is malformed")
    if present_used_handoff_fields and present_used_fields != used_fields:
        raise ValueError("away-email state is malformed")
    if (
        present_used_fields
        and present_handoff_fields
        and item["used_mail_key"] != item["handoff_mail_key"]
    ):
        raise ValueError("away-email state is malformed")
    if present_used_fields:
        used_mail_key = item["used_mail_key"]
        if (
            type(item["used_epoch"]) is not int
            or item["used_epoch"] <= 0
            or not isinstance(used_mail_key, str)
            or not re.fullmatch(r"[a-f0-9]{24}", used_mail_key)
        ):
            raise ValueError("away-email state is malformed")
    if present_used_fields and present_handoff_fields and item["used_mail_key"] != item["handoff_mail_key"]:
        raise ValueError("away-email state is malformed")
    if present_used_handoff_fields:
        if (
            not present_handoff_fields
            or not isinstance(item["used_request_id"], str)
            or item["used_request_id"] != item["handoff_request_id"]
            or item["used_mail_key"] != item["handoff_mail_key"]
            or not isinstance(item["used_note_id"], str)
            or not NOTE_ID_RE.fullmatch(item["used_note_id"])
        ):
            raise ValueError("away-email state is malformed")
    return item


def handoff_record(request_id):
    requested_id = request_id if isinstance(request_id, str) and request_id else None
    matches = []
    with afk_state_lock():
        for store, directory in (("sent", SENT), ("pending", PENDING)):
            try:
                paths = sorted(directory.iterdir())
            except FileNotFoundError:
                continue
            except OSError as error:
                raise ValueError("away-email state directory could not be read") from error
            for path in paths:
                if path.suffix != ".json":
                    continue
                item = validate_handoff_state_item(path, store)
                if (
                    requested_id is not None
                    and item.get("handoff_request_id") == requested_id
                ):
                    matches.append(item)
    if not matches:
        return None
    reference = matches[0]
    for item in matches[1:]:
        if any(item[field] != reference[field] for field in (
            "seq", "task", "away_epoch", "handoff_request_id", "handoff_mail_key", "handoff_body_hash",
        )):
            raise ValueError("away-email handoff state is ambiguous")
    return reference






def verify_note(note_id):
    if not isinstance(note_id, str) or not NOTE_ID_RE.fullmatch(note_id):
        print(json.dumps({"email_handoff": False, "verified": False}, separators=(",", ":")))




        return 0
    identity = inbox_identity(note_id)
    if identity is None:
        print("fm-afk-email: inbox identity could not be read", file=sys.stderr)
        return 1
    request_id = identity.get("request_id")
    if not isinstance(request_id, str) or not re.fullmatch(r"afk-email-[1-9][0-9]*-[0-9a-f]{24}", request_id):
        print(json.dumps({"email_handoff": False, "verified": False}, separators=(",", ":")))
        return 0
    posture = live_record()
    if posture is None:
        print("fm-afk-email: away posture could not be validated for an email handoff", file=sys.stderr)
        return 1





    try:
        item = handoff_record(request_id)
    except (OSError, ValueError):
        print("fm-afk-email: verified reply state could not be read", file=sys.stderr)
        return 1
    if item is None:
        print(json.dumps({"email_handoff": False, "verified": False}, separators=(",", ":")))






        return 0
    body = inbox_note_body(note_id)
    if body is None:
        print("fm-afk-email: inbox note could not be read", file=sys.stderr)
        return 1
    body_hash = hashlib.sha256(body.encode("utf-8")).hexdigest()
    if body_hash != item["handoff_body_hash"]:
        print(json.dumps({"email_handoff": True, "verified": False}, separators=(",", ":")))
        return 0
    print(json.dumps({
        "email_handoff": True,




        "verified": True,
        "id": note_id,
        "request_id": request_id,
        "seq": item["seq"],
        "task": item["task"],
    }, separators=(",", ":")))
    return 0







def token_record(token):
    digest = token_digest(token)
    for store, directory in (("sent", SENT), ("pending", PENDING)):
        try:
            paths = sorted(directory.iterdir())
        except FileNotFoundError:
            continue
        except OSError as error:
            raise ValueError("away-email token state directory could not be read") from error
        matches = []
        for path in paths:
            if path.suffix != ".json":
                continue
            item = validate_handoff_state_item(path, store)
            if item.get("token_hash") != digest:
                continue
            if store == "pending":




                started = item.get("send_started_epoch")
                expires = item.get("send_expires_epoch")
                if not isinstance(started, int) or not isinstance(expires, int):
                    continue
                item = dict(item)
                item["sent_epoch"] = started
                item["expires_epoch"] = expires
            matches.append((path, item))
        if len(matches) > 1:
            raise ValueError("away-email token state is ambiguous")
        if matches:
            return matches[0]




    return None, None


def receive_batch():
    if os.environ.get("FM_AFK_CONTRACT_LOCK_HELD") == "1":
        return receive_batch_while_contract_locked()
    try:
        with afk_contract_lock():
            return receive_batch_while_contract_locked()
    except AfkContractLockError as error:
        print(f"fm-afk-email: {error}; reply was not handed off", file=sys.stderr)
        return 1


def receive_batch_while_contract_locked():





    posture, config = live_mail_context()
    if posture is None:
        return 0
    if config is None:
        return 1






    try:
        messages = json.load(sys.stdin)
    except (ValueError, OSError):
        print("fm-afk-email: mail message batch is malformed", file=sys.stderr)
        return 1
    if not isinstance(messages, list):
        print("fm-afk-email: mail message batch is malformed", file=sys.stderr)
        return 1
    with afk_state_lock():
        return receive_messages(messages, posture, config)


def receive_messages(messages, posture, config):





    accepted = 0
    untrusted = 0
    for message in messages:
        if not isinstance(message, dict):
            continue
        uidv = str(message.get("uidvalidity", ""))
        uid = str(message.get("uid", ""))
        if not uid.isdigit() or uidv and not uidv.isdigit():
            continue
        mail_key = hashlib.sha256(f"{uidv or 'unknown'}/{uid}".encode()).hexdigest()[:24]
        senders = getaddresses([str(message.get("from", ""))])
        sender = senders[0][1].strip().casefold() if len(senders) == 1 else ""
        configured_sender = config["recipient"].casefold()
        token, answer = extract_reply(str(message.get("body", ""))) if sender == configured_sender else (None, "")
        if token and len(answer) > MAX_REPLY_CHARS:
            print(f"fm-afk-event\treply-rejected\t{uid}\tanswer-too-long", file=sys.stderr)




            print(
                f"fm-afk-email: reply in mail UID {uid} rejected; answer exceeds {MAX_REPLY_CHARS} characters",
                file=sys.stderr,
            )
            untrusted += 1
            continue
        try:
            record_path, item = token_record(token) if token else (None, None)
        except (OSError, ValueError):
            print("fm-afk-email: away-email token state could not be checked; mail poll will retry", file=sys.stderr)
            return 1








        now = int(time.time())
        if item and item.get("used_mail_key") == mail_key:
            continue
        valid = (
            sender == configured_sender
            and item is not None
            and item.get("away_epoch") == posture["entered_epoch"]
            and isinstance(item.get("sent_epoch"), int)
            and isinstance(item.get("expires_epoch"), int)
            and item["sent_epoch"] <= now < item["expires_epoch"]
            and not item.get("used_epoch")
            and bool(answer.strip())
            and item.get("handoff_mail_key", mail_key) == mail_key





        )
        if valid:
            note = (
                f"Verified-format away-email reply; sender address and one-time code matched. "
                f"This is the captain's reply for outcome seq {item['seq']} on task {item['task']} only.\n"
                f"Captain's words:\n{answer.strip()}\n"
            )
            request_id = f"afk-email-{item['seq']}-{mail_key}"
            body_hash = hashlib.sha256(note.encode("utf-8")).hexdigest()
            if item.get("handoff_request_id") not in (None, request_id) or item.get("handoff_body_hash") not in (None, body_hash):
                print("fm-afk-email: verified reply handoff state conflicts; mail poll will retry", file=sys.stderr)
                return 1
            if "send_started_epoch" in item:
                item.pop("sent_epoch", None)
                item.pop("expires_epoch", None)




            item["handoff_request_id"] = request_id
            item["handoff_mail_key"] = mail_key
            item["handoff_body_hash"] = body_hash
            atomic_json(record_path, item)
            note_id = inbox_note(request_id, note)
            if note_id is None:
                return 1
            item["used_epoch"] = now
            item["used_mail_key"] = mail_key
            item["used_request_id"] = request_id
            item["used_note_id"] = note_id
            atomic_json(record_path, item)
            accepted += 1
            continue
        untrusted += 1
        continue





    print(f"received {accepted} verified and {untrusted} untrusted away-email message(s)")
    return 0


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "destination":
        print(os.environ.get("FM_AFK_EMAIL_TO", "").strip())
        return 0
    if command == "configured":
        config = mail_configuration()
        if not config:
            return 1
        print(config["recipient"])
        return 0






    if command == "queue-unprocessed":
        return queue_unprocessed()
    if command == "flush":
        return flush()
    if command == "receive-batch":
        return receive_batch()
    if command == "verify-note" and len(sys.argv) == 3:
        return verify_note(sys.argv[2])
    print("usage: fm-afk-email.py destination|configured|queue-unprocessed|flush|receive-batch|verify-note <id>", file=sys.stderr)







    return 2


if __name__ == "__main__":
    sys.exit(main())
