import json
import os
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

CHANNEL_ID = "1551134713727426570"
BOT_ID = "1532391545356161094"
SOURCE_ID = "discord-claude-mentions"
API_BASE = "https://discord.com/api/v10"
LIMIT = 100
MAX_BODY = 4 * 1024 * 1024
MAX_FAILURES = 3
MAX_PAGES = 100


class PollError(Exception):
    def __init__(self, status, terminal=False):
        self.status = status
        self.terminal = terminal


def state_paths():
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or Path(os.environ["FM_HOME"]) / "state")
    return state / "procevent" / "discord-mention.cursor", state / "procevent-inbox"


def message_id(message):
    value = message.get("id")
    if not isinstance(value, str) or not value.isdecimal():
        raise PollError("invalid-message-id", terminal=True)
    return int(value)


def api_get(params):
    if os.environ.get("FM_DISCORD_TEST_MODE") == "1":
        raw = os.environ.get("FM_DISCORD_TEST_MESSAGES", "[]")
        try:
            fixture = json.loads(raw)
        except json.JSONDecodeError as error:
            raise PollError("invalid-test-fixture", terminal=True) from error
        if isinstance(fixture, dict) and "error" in fixture:
            status = fixture["error"]
            raise PollError(f"http-{status}" if isinstance(status, int) else str(status), status in {401, 403, 404})
        if not isinstance(fixture, list):
            raise PollError("invalid-test-fixture", terminal=True)
        messages = sorted(fixture, key=message_id, reverse=True)
        if "before" in params:
            messages = [item for item in messages if message_id(item) < int(params["before"])]
        return messages[:int(params["limit"])]
    token = os.environ.get("FM_DISCORD_BOT_TOKEN", "")
    if not token:
        raise PollError("missing-token", terminal=True)
    query = urlencode(params)
    request = Request(
        f"{API_BASE}/channels/{CHANNEL_ID}/messages?{query}",
        headers={"Authorization": f"Bot {token}", "User-Agent": "Firstmate process-event"},
    )
    for attempt in range(MAX_FAILURES):
        try:
            with urlopen(request, timeout=10) as response:
                raw = response.read(MAX_BODY + 1)
                if len(raw) > MAX_BODY:
                    raise PollError("oversized-response", terminal=True)
                result = json.loads(raw)
            break
        except HTTPError as error:
            if error.code != 429:
                raise PollError(f"http-{error.code}", error.code in {401, 403, 404}) from error
            try:
                payload = json.loads(error.read(4096))
                retry = float(payload.get("retry_after", 30)) if isinstance(payload, dict) else 30
            except (ValueError, TypeError, json.JSONDecodeError):
                retry = 30
            if attempt + 1 == MAX_FAILURES:
                raise PollError("http-429") from error
            time.sleep(min(max(retry, 1), 300))
        except (URLError, TimeoutError, OSError) as error:
            raise PollError(type(error).__name__) from error
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PollError("invalid-response", terminal=True) from error
    if not isinstance(result, list):
        raise PollError("invalid-response", terminal=True)
    return result


def read_checkpoint(path):
    if path.is_symlink():
        raise PollError("unsafe-cursor", terminal=True)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))["last_id"]
    except FileNotFoundError:
        return None
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise PollError("invalid-cursor", terminal=True) from error
    if not isinstance(value, str) or not value.isdecimal():
        raise PollError("invalid-cursor", terminal=True)
    return int(value)


def write_checkpoint(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise PollError("unsafe-cursor", terminal=True)
    fd, temporary = tempfile.mkstemp(prefix=".discord-mention.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump({"last_id": str(value)}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def captured_cursor(inbox):
    latest = None
    if not inbox.is_dir() or inbox.is_symlink():
        return None
    prefix = f"{SOURCE_ID}."
    for path in inbox.glob(f"{SOURCE_ID}.*.result"):
        if path.is_symlink() or not path.is_file():
            continue
        suffix = path.name[len(prefix):-len(".result")]
        if not suffix.isdecimal() or (latest and int(suffix) <= latest[0]):
            continue
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
            cursor = result.get("cursor_after")
            if isinstance(cursor, str) and cursor.isdecimal():
                latest = (int(suffix), int(cursor))
        except (OSError, ValueError, TypeError):
            continue
    return None if latest is None else latest[1]


def new_messages(cursor):
    page = api_get({"limit": LIMIT})
    messages = list(page)
    pages = 1
    while page and pages < MAX_PAGES:
        oldest = min(message_id(item) for item in page)
        if oldest <= cursor or len(page) < LIMIT:
            break
        page = api_get({"before": str(oldest), "limit": LIMIT})
        pages += 1
        if page and min(message_id(item) for item in page) >= oldest:
            raise PollError("pagination-did-not-advance", terminal=True)
        messages.extend(page)
    else:
        if page and min(message_id(item) for item in page) > cursor and len(page) >= LIMIT:
            raise PollError("pagination-cap-exceeded", terminal=True)
    unique = {item["id"]: item for item in messages if message_id(item) > cursor}
    return [unique[key] for key in sorted(unique, key=int)]


def matching_mention(message):
    author = message.get("author") or {}
    if author.get("bot") or message.get("webhook_id"):
        return False
    mentions = message.get("mentions")
    return isinstance(mentions, list) and any(
        isinstance(mention, dict) and mention.get("id") == BOT_ID for mention in mentions
    )


def captured_message(message):
    author = message.get("author") or {}
    attachments = message.get("attachments") or []
    return {
        "schema": "firstmate.discord-mention-result.v1",
        "status": "mention",
        "channel_id": CHANNEL_ID,
        "guild_id": message.get("guild_id"),
        "message_id": message["id"],
        "cursor_after": message["id"],
        "author_id": author.get("id"),
        "author_name": author.get("global_name") or author.get("username"),
        "timestamp": message.get("timestamp"),
        "content": (message.get("content") or "")[:1800],
        "attachments": [
            {key: item.get(key) for key in ("id", "filename", "content_type", "size")}
            for item in attachments[:10] if isinstance(item, dict)
        ],
    }


def emit(result):
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


def poll():
    cursor_path, inbox = state_paths()
    cursor = read_checkpoint(cursor_path)
    saved = captured_cursor(inbox)
    if saved is not None:
        cursor = max(cursor or 0, saved)
    if cursor is None:
        latest = api_get({"limit": 1})
        cursor = max((message_id(item) for item in latest), default=0)
        write_checkpoint(cursor_path, cursor)

    failures = 0
    while True:
        try:
            messages = new_messages(cursor)
            failures = 0
        except PollError as error:
            failures += 1
            if error.terminal or failures >= MAX_FAILURES:
                emit({"schema": "firstmate.discord-mention-result.v1", "status": "poll-error", "error": error.status})
                return
            if os.environ.get("FM_DISCORD_TEST_MODE") != "1":
                time.sleep(30)
            continue
        match = next((item for item in messages if matching_mention(item)), None)
        if match:
            emit(captured_message(match))
            return
        if messages:
            cursor = message_id(messages[-1])
            write_checkpoint(cursor_path, cursor)
        if os.environ.get("FM_DISCORD_TEST_MODE") == "1":
            emit({"schema": "firstmate.discord-mention-result.v1", "status": "no-result"})
            return
        time.sleep(30)


if __name__ == "__main__":
    try:
        poll()
    except PollError as error:
        emit({"schema": "firstmate.discord-mention-result.v1", "status": "poll-error", "error": error.status})
