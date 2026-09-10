#!/usr/bin/env python3
"""Bounded live Discord activation layer for the offline workspace core.

This module owns the minimum live path authorized by the captain: secret
decryption into process memory, authenticated read-only health, idempotent
category/forum setup apply, live outbound replies with existing receipt
idempotency, a live inbound source that feeds the existing external-id inbox
seam, and one round-trip verification command.

Out of scope by contract: retirement/deletion of Discord resources, voice
capture, hosted transcription, webhooks, arbitrary guilds, and generalized
transports. The bot token is never printed, logged, or written to disk; every
error message is redacted before display. Per captain correction: forum
channels are created and reused directly; no Community-mode or related
guild-setting prerequisite is inspected, enabled, or managed here.

Usage (via bin/fm-discord-live.sh):
    fm-discord-live.sh health --config <json>
    fm-discord-live.sh setup-apply --config <json>
    fm-discord-live.sh live-reply --config <json> --request-id <id> --text-file <f> [--nonce <n>]
    fm-discord-live.sh live-source --config <json>
    fm-discord-live.sh live-roundtrip --config <json> --request-id <id> --text-file <f>

Test seams: FM_DISCORD_LIVE_API_BASE overrides the API base URL and
FM_DISCORD_LIVE_SOPS overrides the sops binary; FM_DISCORD_LIVE_RETRY_SLEEP
bounds retry backoff. These never change what is redacted.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent

_spec = importlib.util.spec_from_file_location("fwl", SCRIPT_DIR / "fm_discord_workspace_lib.py")
fwl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fwl)

FMError = fwl.FMError
API_BASE_DEFAULT = "https://discord.com/api/v10"
CHANNEL_TYPE_CATEGORY = 4
CHANNEL_TYPE_FORUM = 15
TOKEN_KEY = "FIRSTMATE_DISCORD_BOT_TOKEN"
MAX_RETRIES = 3
USER_AGENT = "firstmate-discord-workspace (bounded activation layer, +https://localhost)"


def redact(text: str, token: str) -> str:
    if not token:
        return text
    return text.replace(token, "[REDACTED]")


def decrypt_token(env: "fwl.Env", cfg: "fwl.WorkspaceConfig") -> str:
    """Decrypt only the bot token into process memory. Never printed."""
    secret_ref = str((cfg.transcription or {}).get("secret_file") or "config/discord-workspace.secrets.sops.yaml")
    path = Path(secret_ref).expanduser()
    if not path.is_absolute():
        path = env.home / path
    if not path.is_file():
        raise FMError(f"secret file is missing: {path}")
    sops = os.environ.get("FM_DISCORD_LIVE_SOPS", "sops")
    proc = subprocess.run(
        [sops, "-d", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise FMError("secret decryption failed; the secret file was not modified")
    token = ""
    for line in proc.stdout.splitlines():
        match = re.fullmatch(rf"{TOKEN_KEY}:\s*(\S+)\s*", line)
        if match:
            token = match.group(1)
            break
    if not token:
        raise FMError(f"decrypted secret file does not contain {TOKEN_KEY}")
    for bad in ("\n", "\r"):
        if bad in token:
            raise FMError("decrypted token contains a newline; refusing")
    proc.stdout = ""
    return token


class DiscordError(FMError):
    pass


class DiscordClient:
    def __init__(self, token: str, base: Optional[str] = None):
        self.token = token
        self.base = (base or os.environ.get("FM_DISCORD_LIVE_API_BASE") or API_BASE_DEFAULT).rstrip("/")

    def request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None, params: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        url = f"{self.base}{path}"
        if params:
            query = "&".join(f"{k}={v}" for k, v in params.items())
            url = f"{url}?{query}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {
            "Authorization": f"Bot {self.token}",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        }
        if data is not None:
            headers["Content-Type"] = "application/json"
        last_error = ""
        for attempt in range(MAX_RETRIES + 1):
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req) as resp:
                    payload = resp.read().decode("utf-8")
                    return json.loads(payload) if payload else {}
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")
                if exc.code == 429 and attempt < MAX_RETRIES:
                    time.sleep(self._retry_after(detail, exc.headers))
                    continue
                if 500 <= exc.code < 600 and attempt < MAX_RETRIES:
                    time.sleep(float(os.environ.get("FM_DISCORD_LIVE_RETRY_SLEEP", "1")))
                    continue
                raise DiscordError(redact(f"Discord API {method} {path} failed with HTTP {exc.code}: {detail}", self.token))
            except urllib.error.URLError as exc:
                last_error = redact(f"Discord API {method} {path} transport failure: {exc.reason}", self.token)
                if attempt < MAX_RETRIES:
                    time.sleep(float(os.environ.get("FM_DISCORD_LIVE_RETRY_SLEEP", "1")))
                    continue
                raise DiscordError(last_error)
        raise DiscordError(last_error or f"Discord API {method} {path} failed")

    @staticmethod
    def _retry_after(detail: str, headers: Any) -> float:
        sleep_default = float(os.environ.get("FM_DISCORD_LIVE_RETRY_SLEEP", "1"))
        try:
            parsed = json.loads(detail)
            retry = parsed.get("retry_after")
            if isinstance(retry, (int, float)) and retry >= 0:
                return min(float(retry), 30.0)
        except (json.JSONDecodeError, ValueError):
            pass
        try:
            header_value = headers.get("Retry-After")
            if header_value:
                return min(float(header_value) / 1000.0, 30.0)
        except (TypeError, ValueError):
            pass
        return sleep_default


def require_live_flag(cfg: "fwl.WorkspaceConfig", flag: bool, what: str) -> None:
    if not flag:
        raise FMError(f"{what} requires its live approval flag in the workspace config")


def cmd_health(args: Any, env: "fwl.Env") -> int:
    cfg = fwl.load_config(env, args.config)
    client = DiscordClient(decrypt_token(env, cfg))
    me = client.request("GET", "/users/@me")
    if str(me.get("id") or "") != cfg.bot_user_id:
        raise FMError(f"authenticated bot id {me.get('id')} does not match the configured bot user id")
    guild = client.request("GET", f"/guilds/{cfg.guild_id}")
    if str(guild.get("id") or "") != cfg.guild_id:
        raise FMError(f"guild lookup returned id {guild.get('id')} instead of the configured operations guild")
    print(f"bot identity ok: {me.get('username')}")
    print(f"operations guild ok: {guild.get('name')}")
    print("live health ok")
    return 0


def _match_channel(channels: List[Dict[str, Any]], name: str, ctype: int, parent_id: str) -> Optional[Dict[str, Any]]:
    for channel in channels:
        if channel.get("name") != name:
            continue
        if int(channel.get("type") or -1) != ctype:
            return None
        if str(channel.get("parent_id") or "") != parent_id:
            return None
        return channel
    return None


def _name_owner(channels: List[Dict[str, Any]], name: str) -> Optional[str]:
    for channel in channels:
        if channel.get("name") == name:
            return f"type {channel.get('type')} parent {channel.get('parent_id')}"
    return None


def cmd_setup_apply(args: Any, env: "fwl.Env") -> int:
    cfg = fwl.load_config(env, args.config)
    client = DiscordClient(decrypt_token(env, cfg))
    # Forum channels are created and reused directly; no Community-mode or
    # other guild-setting prerequisite is inspected, enabled, or managed.
    channels = client.request("GET", f"/guilds/{cfg.guild_id}/channels")
    if not isinstance(channels, list):
        raise FMError("guild channel listing was malformed")
    created: List[str] = []
    for key in fwl.ACTIVE_PROFILE_KEYS:
        p = cfg.profiles[key]
        plans = [
            (CHANNEL_TYPE_CATEGORY, "", p["category_name"]),
            (CHANNEL_TYPE_FORUM, p["category_name"], p["exchange_forum_name"]),
            (CHANNEL_TYPE_FORUM, p["category_name"], p["artifact_forum_name"]),
        ]
        ids: Dict[str, str] = {}
        for ctype, parent_name, name in plans:
            parent_id = ""
            if parent_name:
                parent = _match_channel(channels, parent_name, CHANNEL_TYPE_CATEGORY, "")
                if parent is None:
                    raise FMError(f"category {parent_name!r} is not available for {name!r}")
                parent_id = str(parent["id"])
            existing = _match_channel(channels, name, ctype, parent_id)
            if existing is not None:
                ids[name] = str(existing["id"])
                continue
            owner = _name_owner(channels, name)
            if owner is not None:
                raise FMError(f"channel {name!r} already exists with mismatched shape ({owner}); refusing to substitute")
            body: Dict[str, Any] = {"name": name, "type": ctype}
            if parent_id:
                body["parent_id"] = parent_id
            if ctype == CHANNEL_TYPE_FORUM:
                tags = cfg.exchange_tags if name == p["exchange_forum_name"] else cfg.artifact_tags
                body["available_tags"] = [{"name": tag} for tag in tags]
            channel = client.request("POST", f"/guilds/{cfg.guild_id}/channels", body)
            ids[name] = str(channel["id"])
            channels.append(channel)
            created.append(f"{name} -> {channel['id']}")
            _write_profile_ids(env, cfg.raw, key, ids, p, name)
        _write_profile_ids(env, cfg.raw, key, ids, p, None)
    for item in created:
        print(f"created {item}")
    print("setup apply complete; non-secret ids written to the workspace config")
    return 0


def _write_profile_ids(env: "fwl.Env", raw: Dict[str, Any], key: str, ids: Dict[str, str], p: Dict[str, Any], only: Optional[str]) -> None:
    profile_raw = raw["profiles"][key]
    changed = False
    category_id = ids.get(p["category_name"])
    exchange_id = ids.get(p["exchange_forum_name"])
    artifact_id = ids.get(p["artifact_forum_name"])
    if only is None:
        for slot, value in (("category_id", category_id), ("exchange_forum_id", exchange_id), ("artifact_forum_id", artifact_id)):
            if value and str(profile_raw.get(slot) or "") != value:
                profile_raw[slot] = value
                changed = True
    else:
        slot = {p["exchange_forum_name"]: "exchange_forum_id", p["artifact_forum_name"]: "artifact_forum_id", p["category_name"]: "category_id"}.get(only)
        value = ids.get(only)
        if slot and value and str(profile_raw.get(slot) or "") != value:
            profile_raw[slot] = value
            changed = True
    if not changed:
        return
    atomic_write_config(env, raw)


def atomic_write_config(env: "fwl.Env", raw: Dict[str, Any]) -> None:
    path = Path(env.home) / "config" / "discord-workspace.json"
    fwl.atomic_json(path, raw)


def cmd_live_reply(args: Any, env: "fwl.Env", verify: bool = False) -> int:
    cfg = fwl.load_config(env, args.config)
    require_live_flag(cfg, cfg.live_posting_enabled, "live reply")
    text = fwl.read_text_file(args.text_file).strip()
    guild_id, channel_id, message_id, profile_key, forum_kind = fwl.resolve_request_id(cfg, env, args.request_id)
    if forum_kind != "exchange":
        raise FMError("replies must target an exchange forum thread")
    text_digest = fwl.sha256_text(text)
    nonce = args.nonce or f"reply:{args.request_id}:{text_digest}"
    target = {"guild_id": guild_id, "channel_id": channel_id, "message_id": message_id, "request_id": args.request_id}
    receipt = fwl.base_receipt("reply", profile_key, target, text_digest)
    client = DiscordClient(decrypt_token(env, cfg))
    result, discord_message_id = send_outbound_once(
        env, client, nonce, receipt, cfg.guild_id, channel_id, text_digest, text
    )
    if result == "shared":
        print("matching delivery exists; no second delivery")
        return 0
    if result == "receipt exists":
        print(f"receipt exists for nonce {nonce}; no second delivery")
    else:
        print(result)
    if verify:
        back = client.request("GET", f"/channels/{channel_id}/messages/{discord_message_id}")
        if str(back.get("id") or "") != discord_message_id:
            raise FMError("round-trip verification could not read back the recorded message")
        if result == "receipt exists":
            print("round-trip verified against the recorded message id")
        else:
            print("round-trip verified against the posted message id")
    return 0


def handoff_event(env: "fwl.Env", event: Dict[str, Any]) -> int:
    """Feed one normalized event through the existing external-id inbox seam."""
    cls = fwl.event_class(event)
    if cls == "malformed":
        raise FMError("event is malformed")
    if cls == "ignored":
        return 0
    request = fwl.request_record_from_event(event)
    with fwl.state_transaction(env):
        fwl.write_same_or_refuse(fwl.request_record_path(env, str(event.get("external_id"))), request, "request record")
    body = fwl.note_body_for_event(event)
    metadata_dir = fwl.discord_state_path(env, "metadata-staging")
    metadata_dir.mkdir(parents=True, exist_ok=True)
    fd, meta_tmp = tempfile.mkstemp(prefix=".metadata.", suffix=".json", dir=str(metadata_dir))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(fwl.event_metadata(event), f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(meta_tmp, 0o600)
        inbox_cmd = [
            str(env.script_dir / "fm-inbox.sh"),
            "note",
            "--source",
            "discord-workspace",
            "--external-id",
            str(event.get("external_id")),
            "--metadata-file",
            meta_tmp,
            "-",
        ]
        proc = subprocess.run(inbox_cmd, input=body, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode != 0:
            if proc.stdout:
                print(proc.stdout, end="")
            if proc.stderr:
                print(proc.stderr, end="", file=sys.stderr)
            return proc.returncode
    finally:
        try:
            os.unlink(meta_tmp)
        except FileNotFoundError:
            pass
    return 0


def live_source_pass(env: "fwl.Env", cfg: "fwl.WorkspaceConfig", client: "DiscordClient") -> int:
    """One inbound pass: guild-scoped active threads, cursor-filtered handoff.

    Returns the number of messages scanned. Raises FMError on failure; failed
    messages never advance their cursors because each cursor is written only
    after its message's handoff succeeded.
    """
    forum_ids = {p["exchange_forum_id"] for p in cfg.profiles.values() if p["exchange_forum_id"]}
    profile_by_forum = {p["exchange_forum_id"]: key for key, p in cfg.profiles.items() if p["exchange_forum_id"]}
    listing = client.request("GET", f"/guilds/{cfg.guild_id}/threads/active")
    threads = listing.get("threads") if isinstance(listing.get("threads"), list) else []
    ingested = 0
    for thread in threads:
        if not isinstance(thread, dict):
            continue
        thread_id = str(thread.get("id") or "")
        parent_id = str(thread.get("parent_id") or "")
        if not thread_id.isdigit() or parent_id not in forum_ids:
            continue
        key = profile_by_forum[parent_id]
        last = fwl.read_cursor(env, key, thread_id)
        params = {"limit": "100"}
        if last:
            params["after"] = str(last)
        messages = client.request("GET", f"/channels/{thread_id}/messages", params=params)
        if not isinstance(messages, list):
            raise FMError(f"message listing for thread {thread_id} was malformed")
        for message in reversed(messages):
            if not isinstance(message, dict):
                continue
            normalized = {
                "id": message.get("id"),
                "guild_id": cfg.guild_id,
                "channel_id": thread_id,
                "parent_id": parent_id,
                "author": message.get("author"),
                "author_id": message.get("author_id"),
                "content": message.get("content"),
                "timestamp": message.get("timestamp"),
                "flags": message.get("flags"),
                "attachments": message.get("attachments"),
            }
            event = fwl.message_to_event(cfg, normalized)
            status = handoff_event(env, event)
            if status != 0:
                return status
            if str(message.get("id") or "").isdigit():
                fwl.write_cursor(env, key, thread_id, str(message["id"]))
                ingested += 1
    return ingested


def cmd_live_source(args: Any, env: "fwl.Env") -> int:
    """Human-facing one-shot pass; progress goes to stdout."""
    cfg = fwl.load_config(env, args.config)
    require_live_flag(cfg, cfg.live_polling_enabled, "live inbound source")
    client = DiscordClient(decrypt_token(env, cfg))
    scanned = live_source_pass(env, cfg, client)
    print(f"live source pass complete; {scanned} messages scanned")
    return 0


def _receipt_shares_text_and_channel(env: "fwl.Env", digest: str, channel_id: str) -> bool:
    receipts_dir = fwl.discord_state_path(env, "receipts")
    if not receipts_dir.is_dir():
        return False
    for path in receipts_dir.glob("*.json"):
        try:
            receipt = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if str(receipt.get("text_sha256") or "") != digest:
            continue
        target = receipt.get("target") if isinstance(receipt.get("target"), dict) else {}
        if str(target.get("channel_id") or "") == channel_id:
            return True
    return False


def outbound_discord_nonce(guild_id: str, channel_id: str, digest: str) -> str:
    return fwl.sha256_text(f"{guild_id}:{channel_id}:{digest}")[:24]


def send_outbound_once(
    env: "fwl.Env",
    client: DiscordClient,
    receipt_nonce: str,
    receipt: Dict[str, Any],
    guild_id: str,
    channel_id: str,
    digest: str,
    content: str,
    *,
    typing: bool = False,
) -> Tuple[str, str]:
    with fwl.state_transaction(env):
        existing = fwl.load_existing_json(fwl.receipt_path(env, receipt_nonce))
        if existing is not None:
            recorded = str(existing.get("discord_message_id") or "")
            comparable = dict(existing)
            comparable.pop("recorded_at", None)
            if comparable != fwl.receipt_record(receipt_nonce, receipt, recorded):
                raise FMError("refusing to overwrite a different Discord outbound receipt for the same nonce")
            return "receipt exists", recorded
        if _receipt_shares_text_and_channel(env, digest, channel_id):
            return "shared", ""
        if typing:
            client.request("POST", f"/channels/{channel_id}/typing")
        sent = client.request(
            "POST",
            f"/channels/{channel_id}/messages",
            {
                "content": content,
                "allowed_mentions": {"parse": []},
                "nonce": outbound_discord_nonce(guild_id, channel_id, digest),
                "enforce_nonce": True,
            },
        )
        discord_message_id = str(sent.get("id") or "")
        if not discord_message_id.isdigit():
            raise FMError("Discord did not return a usable message id")
        result = fwl.record_receipt_unlocked(env, receipt_nonce, receipt, discord_message_id)
        return result, discord_message_id


def cmd_live_post(args: Any, env: "fwl.Env") -> int:
    """Post one mirrored conversational item with single-owner idempotency.

    Same text to the same thread converges on one durable delivery identity:
    both the mirror and any explicit reply share the text digest, so neither
    path can issue a second post for content already delivered to the thread.
    """
    cfg = fwl.load_config(env, args.config)
    require_live_flag(cfg, cfg.live_posting_enabled, "live mirror")
    thread_id = fwl.validate_snowflake(args.thread, "--thread") or ""
    allowed = any(
        thread_id in p["exchange_thread_ids"] or thread_id in p["artifact_thread_ids"]
        for p in cfg.profiles.values()
    )
    if not allowed:
        raise FMError("mirror target thread is outside the configured allowlist")
    text = fwl.read_text_file(args.text_file).strip()
    if not text:
        return 0
    # Discord-origin and operational text never mirrors: the caller passes only
    # terminal-origin conversation, and these markers are machinery evidence.
    for marker in ("FIRSTMATE WATCHER WAKE", "FIRSTMATE_OP:", "\u2063", "\u26f5"):
        if marker in text:
            raise FMError("refusing to mirror operational text")
    digest = fwl.sha256_text(text)
    tag = "main" if args.tag == "main" else "captain"
    nonce = f"mirror:{thread_id}:{digest}"
    target = {"guild_id": cfg.guild_id, "channel_id": thread_id}
    receipt = fwl.base_receipt("mirror", tag, target, digest)
    client = DiscordClient(decrypt_token(env, cfg))
    result, _discord_message_id = send_outbound_once(
        env,
        client,
        nonce,
        receipt,
        cfg.guild_id,
        thread_id,
        digest,
        f"[{tag}] {text}",
        typing=True,
    )
    if result == "shared":
        print("matching delivery exists; no second post")
        return 0
    if result == "receipt exists":
        print("receipt exists; no second post")
        return 0
    record_mirror_cursor(env, digest, thread_id, result)
    print(result)
    return 0


def record_mirror_cursor(env: "fwl.Env", digest: str, thread_id: str, recorded: str) -> None:
    cursor_path = fwl.discord_state_path(env, "mirror-cursor.json")
    try:
        cursor = json.loads(cursor_path.read_text(encoding="utf-8")) if cursor_path.exists() else []
    except (OSError, json.JSONDecodeError):
        cursor = []
    if not isinstance(cursor, list):
        cursor = []
    cursor.append({"digest": digest, "thread": thread_id, "result": recorded})
    with fwl.state_transaction(env):
        fwl.atomic_json(cursor_path, cursor[-100:])


def registered_source_pass(env: "fwl.Env", cfg: "fwl.WorkspaceConfig", client: "DiscordClient") -> int:
    """Wire contract for the registered process-event source.

    A successful scan is silent and exits nonzero with empty stdout so the
    runner records no-result and keeps the source armed; durable effects
    already went through fm-inbox. A genuine failure prints one bounded
    redacted actionable line (captured as a result) and exits nonzero so the
    failed pass stays visible and retryable without advancing cursors.
    """
    try:
        live_source_pass(env, cfg, client)
    except FMError as exc:
        print(redact(f"discord live source failed: {exc}", client.token))
        return 1
    return fwl.EXIT_NO_RESULT


def main(argv: List[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="fm-discord-live.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("health")
    fwl.add_config_argument(p)
    p = sub.add_parser("setup-apply")
    fwl.add_config_argument(p)
    p = sub.add_parser("live-reply")
    fwl.add_config_argument(p)
    p.add_argument("--request-id", required=True)
    p.add_argument("--text-file", required=True)
    p.add_argument("--nonce")
    p = sub.add_parser("live-source")
    fwl.add_config_argument(p)
    p = sub.add_parser("live-roundtrip")
    fwl.add_config_argument(p)
    p.add_argument("--request-id", required=True)
    p.add_argument("--text-file", required=True)
    p.add_argument("--nonce")
    p = sub.add_parser("live-post")
    fwl.add_config_argument(p)
    p.add_argument("--thread", required=True)
    p.add_argument("--tag", choices=("captain", "main"), required=True)
    p.add_argument("--text-file", required=True)
    args = parser.parse_args(argv[2:])
    env = fwl.Env(argv[1])
    handlers = {
        "health": cmd_health,
        "setup-apply": cmd_setup_apply,
        "live-reply": cmd_live_reply,
        "live-source": cmd_live_source,
        "live-roundtrip": lambda a, e: cmd_live_reply(a, e, verify=True),
        "live-post": cmd_live_post,
    }
    return handlers[args.command](args, env)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except FMError as exc:
        print(f"fm-discord-live: {exc}", file=sys.stderr)
        sys.exit(1)
