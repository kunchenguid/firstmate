#!/usr/bin/env bash
# fm-browser.sh - sole public Firstmate browser lifecycle owner.
#
# Owns the disabled-by-default browser custody command surface, private state
# records, value-redacted receipts, and refusal boundaries for browser work.
# This command never exposes raw engine arguments, CDP endpoints, profile
# secrets, cookies, storage, DOM dumps, screenshots, HAR, video, or arbitrary
# JavaScript.
#
# Supported v1 production mode is disabled by default and limited to public
# ephemeral planning until config/browser-policy.json enables public mock or
# later verified real execution.
# Real browser launch is intentionally refused by this initial core unless a
# future verified engine adapter replaces the guarded refusal.
# Tests may set FM_BROWSER_MOCK_ENGINE=1 with an enabled test policy to exercise
# the lifecycle without launching a browser.
#
# Usage:
#   fm-browser.sh capabilities [--json]
#   fm-browser.sh plan --task <id> --origin <url> [--allow-origin <url>] [--ttl <seconds>] [--json]
#   fm-browser.sh open --task <id> --plan <receipt> [--json]
#   fm-browser.sh status (--task <id>|--handle <handle>) [--json]
#   fm-browser.sh navigate --handle <handle> --url <url> [--json]
#   fm-browser.sh snapshot --handle <handle> [--json]
#   fm-browser.sh interact --handle <handle> --kind <click|press|select|type> --target <ref> [--json]
#   fm-browser.sh request-action --handle <handle> --kind <kind> --effect <summary> [--json]
#   fm-browser.sh close --handle <handle> [--reason <reason>] [--json]
#   fm-browser.sh inspect --all [--json]
#   fm-browser.sh reconcile --all --inspect-only [--json]
#   fm-browser.sh expire --due [--json]
#
# Policy file:
#   config/browser-policy.json, schema fm-browser-policy.v1.
#   Absent means {"enabled": false}; enabled production still refuses real
#   launches until the verified real-engine stage lands.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

export FM_ROOT FM_HOME STATE DATA CONFIG
python3 - "$@" <<'PY'
import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

SCHEMA_POLICY = "fm-browser-policy.v1"
SCHEMA_PLAN = "fm-browser-plan.v1"
SCHEMA_SESSION = "fm-browser-session.v1"
SCHEMA_RECEIPT = "fm-browser-receipt.v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]+$")
LIVE_STATES = {"creating", "visible-ready", "active", "paused", "closing", "closed", "cleaning", "crashed", "recovering", "incident", "quarantined"}
SUPPORTED_MODE = "public_ephemeral"
SUPPORTED_AUTH = "anonymous"
ROOT = Path(os.environ["FM_ROOT"]).resolve()
HOME = Path(os.environ["FM_HOME"]).resolve()
STATE = Path(os.environ["STATE"]).resolve()
DATA = Path(os.environ["DATA"]).resolve()
CONFIG = Path(os.environ["CONFIG"]).resolve()
BROOT = STATE / "browser" / "v1"
PLANS = BROOT / "plans"
SESSIONS = BROOT / "sessions"
BINDINGS = BROOT / "task-bindings"
INCIDENTS = BROOT / "incidents"
DATA_RECEIPTS = DATA / "browser" / "v1" / "receipts"
RUNTIME_ROOT = Path(os.environ.get("FM_BROWSER_RUNTIME_OVERRIDE") or (Path.home() / "Library" / "Caches" / "Firstmate" / "browser-v1"))
MOCK = os.environ.get("FM_BROWSER_MOCK_ENGINE") == "1"


def die(message, code="error", rc=1, as_json=False, **extra):
    if as_json:
        obj = {"schema": SCHEMA_RECEIPT, "result": "error", "code": code, "message": message}
        obj.update(extra)
        print(json.dumps(obj, sort_keys=True))
    else:
        print(f"error: {message}", file=sys.stderr)
    raise SystemExit(rc)


def ensure_dirs():
    for path in (PLANS, SESSIONS, BINDINGS, INCIDENTS, DATA_RECEIPTS):
        path.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(path, 0o700)
        except OSError:
            pass


def safe_id(value, label="id"):
    if not value or not SAFE_ID.match(value):
        die(f"invalid {label}", "invalid-id", 2)
    return value


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def digest_obj(obj):
    return "sha256:" + hashlib.sha256(canonical(obj).encode()).hexdigest()


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def month():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m")


def load_json(path, default=None):
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def atomic_write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}-{int(time.time() * 1000000)}")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(obj, fh, sort_keys=True, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def load_policy(as_json=False):
    path = CONFIG / "browser-policy.json"
    if not path.exists():
        return {"schema": SCHEMA_POLICY, "enabled": False, "maxActiveSessions": 1, "anonymousIdleSeconds": 1200, "anonymousHardSeconds": 7200, "defaultExpiry": "alert-only", "allowedAuthClasses": ["anonymous"]}
    try:
        policy = load_json(path, {})
    except Exception as exc:
        die(f"invalid config/browser-policy.json - {exc}", "policy-invalid", as_json=as_json)
    if policy.get("schema") != SCHEMA_POLICY:
        die("invalid config/browser-policy.json - schema must be fm-browser-policy.v1", "policy-invalid", as_json=as_json)
    if not isinstance(policy.get("enabled", False), bool):
        die("invalid config/browser-policy.json - enabled must be boolean", "policy-invalid", as_json=as_json)
    max_active = policy.get("maxActiveSessions", 1)
    if not isinstance(max_active, int) or max_active < 1:
        die("invalid config/browser-policy.json - maxActiveSessions must be positive integer", "policy-invalid", as_json=as_json)
    return policy


def public_host_ok(host):
    h = host.rstrip(".").lower()
    if h in {"localhost", "localhost.localdomain"} or h.endswith(".local"):
        return False, "private-local-host"
    try:
        ip = ipaddress.ip_address(h.strip("[]"))
    except ValueError:
        return True, "public-name"
    if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or ip.is_reserved:
        return False, "private-address"
    return True, "public-address"


def canonical_origin(url):
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return None, "unsupported-scheme"
    if parsed.username or parsed.password:
        return None, "userinfo-forbidden"
    if not parsed.hostname:
        return None, "missing-host"
    ok, reason = public_host_ok(parsed.hostname)
    if not ok:
        return None, reason
    port = parsed.port
    default = 443 if parsed.scheme == "https" else 80
    port_part = "" if port in (None, default) else f":{port}"
    return f"{parsed.scheme}://{parsed.hostname.rstrip('.').lower()}{port_part}", "ok"


def plan_path(receipt):
    return PLANS / (receipt.replace("sha256:", "") + ".json")


def session_path(handle):
    safe_id(handle, "handle")
    return SESSIONS / f"{handle}.json"


def binding_path(task):
    safe_id(task, "task")
    return BINDINGS / f"{task}.json"


def load_session(handle, as_json=False):
    path = session_path(handle)
    if not path.exists():
        die("browser session not found", "session-not-found", as_json=as_json)
    try:
        return load_json(path)
    except Exception as exc:
        die(f"browser session unreadable - {exc}", "session-unreadable", as_json=as_json)


def save_session(session):
    atomic_write(session_path(session["handle"]), session)
    atomic_write(binding_path(session["task"]), {"schema": "fm-browser-task-binding.v1", "task": session["task"], "handle": session["handle"], "state": session["state"], "cleaned": session["state"] == "cleaned", "updatedAt": now()})


def append_receipt(session, operation, result="ok", postconditions=None, **extra):
    receipts = session.setdefault("receipts", [])
    previous = receipts[-1]["receipt"] if receipts else None
    record = {"schema": SCHEMA_RECEIPT, "sequence": len(receipts) + 1, "operation": operation, "result": result, "handle": session["handle"], "generation": session.get("generation", 1), "task": session["task"], "project": session.get("project", "unknown"), "state": session["state"], "timestamp": now(), "previousReceipt": previous, "postconditions": postconditions or []}
    record.update(extra)
    record["receipt"] = digest_obj(record)
    receipts.append(record)
    DATA_RECEIPTS.mkdir(parents=True, exist_ok=True)
    with (DATA_RECEIPTS / f"{month()}.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(canonical(record) + "\n")
    return record


def active_sessions():
    if not SESSIONS.exists():
        return []
    sessions = []
    for path in SESSIONS.glob("*.json"):
        try:
            sess = load_json(path)
        except Exception:
            continue
        if sess.get("state") in LIVE_STATES and sess.get("state") != "cleaned":
            sessions.append(sess)
    return sessions


def print_obj(obj, as_json=False):
    if as_json:
        print(json.dumps(obj, sort_keys=True))
    else:
        for key, value in obj.items():
            print(f"{key}: {value}")


def cmd_capabilities(args):
    policy = load_policy(as_json=args.json)
    obj = {"schema": "fm-browser-capabilities.v1", "enabled": bool(policy.get("enabled", False)), "primaryEngine": "agent-browser", "publicLightEngine": "chrome-devtools-axi", "realEngineEnabled": False, "mockEngine": MOCK, "supportedModes": [SUPPORTED_MODE], "supportedAuthClasses": [SUPPORTED_AUTH], "forbiddenByDefault": ["personal-profile", "cookie-import-export", "cdp-auto-connect", "private-local-origin", "upload-download-capture", "credential-plugin", "extension", "write-capable"]}
    print_obj(obj, args.json)


def cmd_plan(args):
    ensure_dirs()
    safe_id(args.task, "task")
    if args.mode != SUPPORTED_MODE:
        die("only public_ephemeral mode is supported in v1", "mode-disabled", as_json=args.json)
    if args.auth != SUPPORTED_AUTH:
        die("only anonymous auth is supported in v1", "auth-disabled", as_json=args.json)
    if args.tier not in (0, 1):
        die("only public observe and synthetic interaction tiers are supported", "tier-disabled", as_json=args.json)
    origin, reason = canonical_origin(args.origin)
    if not origin:
        die(f"origin refused before engine execution: {reason}", reason, as_json=args.json)
    allowed = [origin]
    for item in args.allow_origin or []:
        extra, extra_reason = canonical_origin(item)
        if not extra:
            die(f"allowed origin refused before engine execution: {extra_reason}", extra_reason, as_json=args.json)
        if extra not in allowed:
            allowed.append(extra)
    ttl = int(args.ttl)
    if ttl < 1:
        die("ttl must be positive", "invalid-ttl", as_json=args.json)
    created = now()
    plan = {"schema": SCHEMA_PLAN, "task": args.task, "project": args.project or "unknown", "mode": args.mode, "auth": args.auth, "tier": args.tier, "initialUrl": args.origin, "allowedOrigins": allowed, "createdAt": created, "ttlSeconds": ttl, "expiryAction": args.expiry_action, "engine": "agent-browser", "state": "planned"}
    receipt = digest_obj(plan)
    plan["receipt"] = receipt
    atomic_write(plan_path(receipt), plan)
    out = {"schema": SCHEMA_RECEIPT, "operation": "plan", "result": "ok", "receipt": receipt, "task": args.task, "allowedOrigins": allowed, "mode": args.mode, "auth": args.auth, "tier": args.tier}
    print_obj(out, args.json)


def cmd_open(args):
    ensure_dirs()
    policy = load_policy(as_json=args.json)
    if not policy.get("enabled", False):
        die("browser capability disabled by config/browser-policy.json", "browser-disabled", as_json=args.json)
    ppath = plan_path(args.plan)
    if not ppath.exists():
        die("plan receipt not found", "plan-not-found", as_json=args.json)
    plan = load_json(ppath)
    if plan.get("task") != args.task:
        die("plan task does not match open task", "task-mismatch", as_json=args.json)
    if plan.get("mode") != SUPPORTED_MODE or plan.get("auth") != SUPPORTED_AUTH:
        die("plan mode/auth is not enabled", "mode-disabled", as_json=args.json)
    if not MOCK:
        die("real browser engine is disabled in this core; run the opt-in real smoke after verified engine support lands", "real-engine-disabled", as_json=args.json)
    max_active = int(policy.get("maxActiveSessions", 1))
    if len(active_sessions()) >= max_active:
        die("browser capacity reached", "capacity-reached", as_json=args.json)
    seed = f"{args.task}:{args.plan}:{time.time_ns()}"
    handle = "br-" + hashlib.sha256(seed.encode()).hexdigest()[:16]
    profile = RUNTIME_ROOT / "profiles" / hashlib.sha256(str(HOME).encode()).hexdigest()[:16] / handle / "1"
    profile.mkdir(parents=True, exist_ok=False)
    session = {"schema": SCHEMA_SESSION, "handle": handle, "task": args.task, "project": plan.get("project", "unknown"), "state": "active", "generation": 1, "mode": plan["mode"], "auth": plan["auth"], "tier": plan["tier"], "allowedOrigins": plan["allowedOrigins"], "engine": {"name": "agent-browser", "mock": True, "realEnabled": False}, "profile": {"class": "ephemeral", "path": str(profile), "removed": False}, "processIdentity": {"mock": True, "pid": os.getpid(), "birth": "mock"}, "windowIdentity": {"mock": True, "visibleReceipt": "mock-frontmost-onscreen"}, "createdAt": now(), "idleDeadlineEpoch": int(time.time()) + int(plan.get("ttlSeconds", 900)), "hardDeadlineEpoch": int(time.time()) + int(plan.get("ttlSeconds", 900)), "expiryAction": plan.get("expiryAction", "alert-only"), "currentUrl": plan["initialUrl"], "receipts": []}
    receipt = append_receipt(session, "open", postconditions=["mock-engine-active", "visible-ready", "profile-created"], originAlias=session["allowedOrigins"][0])
    save_session(session)
    out = dict(receipt)
    print_obj(out, args.json)


def resolve_handle_from_task(task, as_json=False):
    path = binding_path(task)
    if not path.exists():
        die("browser task binding not found", "binding-not-found", as_json=as_json)
    binding = load_json(path)
    return binding.get("handle")


def cmd_status(args):
    handle = args.handle or resolve_handle_from_task(args.task, as_json=args.json)
    session = load_session(handle, as_json=args.json)
    out = {"schema": "fm-browser-status.v1", "handle": session["handle"], "task": session["task"], "state": session["state"], "mode": session["mode"], "auth": session["auth"], "tier": session["tier"], "allowedOrigins": session["allowedOrigins"], "cleaned": session["state"] == "cleaned"}
    print_obj(out, args.json)


def require_active(handle, as_json=False):
    session = load_session(handle, as_json=as_json)
    if session.get("state") != "active":
        die("browser session is not active", "not-active", as_json=as_json)
    return session


def cmd_navigate(args):
    session = require_active(args.handle, as_json=args.json)
    origin, reason = canonical_origin(args.url)
    if not origin:
        die(f"origin refused before engine execution: {reason}", reason, as_json=args.json)
    if origin not in session.get("allowedOrigins", []):
        die("origin not in session allowlist", "origin-not-allowed", as_json=args.json)
    session["currentUrl"] = args.url
    receipt = append_receipt(session, "navigate", postconditions=["origin-allowed", "mock-navigation-recorded"], originAlias=origin)
    save_session(session)
    print_obj(receipt, args.json)


def cmd_snapshot(args):
    session = require_active(args.handle, as_json=args.json)
    out = {"schema": "fm-browser-snapshot.v1", "handle": session["handle"], "result": "ok", "currentOrigin": canonical_origin(session.get("currentUrl", ""))[0], "elements": [], "redacted": True, "mock": bool(session.get("engine", {}).get("mock"))}
    print_obj(out, args.json)


def cmd_interact(args):
    session = require_active(args.handle, as_json=args.json)
    if args.kind not in {"click", "press", "select", "type"}:
        die("interaction kind is forbidden in v1", "verb-forbidden", as_json=args.json)
    if session.get("tier", 0) > 1:
        die("interaction tier is disabled", "tier-disabled", as_json=args.json)
    if args.kind == "type" and not args.value_file:
        die("type requires --value-file so text is not passed in argv", "value-file-required", as_json=args.json)
    receipt = append_receipt(session, "interact", postconditions=["tier-allowed", "mock-interaction-recorded"], actionKind=args.kind, target="redacted")
    save_session(session)
    print_obj(receipt, args.json)


def cmd_request_action(args):
    session = require_active(args.handle, as_json=args.json)
    die("write-capable browser actions are disabled in v1", "action-tier-disabled", as_json=args.json, handle=session["handle"])


def remove_profile(session):
    profile_path = Path(session.get("profile", {}).get("path", ""))
    if not profile_path:
        return False
    try:
        resolved_profile = profile_path.resolve()
        resolved_root = RUNTIME_ROOT.resolve()
    except OSError:
        return False
    if resolved_profile == resolved_root or resolved_root not in resolved_profile.parents:
        return False
    if resolved_profile.exists():
        shutil.rmtree(resolved_profile)
    session.setdefault("profile", {})["removed"] = True
    return True


def cmd_close(args):
    session = load_session(args.handle, as_json=args.json)
    if session.get("state") == "cleaned":
        receipt = append_receipt(session, "close", result="ok", postconditions=["already-cleaned"], reason=args.reason)
        save_session(session)
        print_obj(receipt, args.json)
        return
    session["state"] = "closing"
    removed = remove_profile(session)
    session["state"] = "cleaned" if removed else "quarantined"
    post = ["engine-inactive", "endpoint-gone", "process-gone", "lease-removed"]
    post.append("profile-removed" if removed else "profile-quarantined")
    receipt = append_receipt(session, "close", result="ok" if removed else "error", postconditions=post, reason=args.reason)
    save_session(session)
    if not removed:
        die("profile cleanup postcondition failed; session quarantined", "cleanup-quarantined", as_json=args.json, handle=session["handle"])
    print_obj(receipt, args.json)


def cmd_inspect(args):
    sessions = []
    if SESSIONS.exists():
        for path in sorted(SESSIONS.glob("*.json")):
            try:
                sess = load_json(path)
            except Exception as exc:
                sessions.append({"path": str(path), "state": "unreadable", "error": str(exc)})
                continue
            sessions.append({"handle": sess.get("handle"), "task": sess.get("task"), "state": sess.get("state"), "mode": sess.get("mode"), "auth": sess.get("auth"), "cleaned": sess.get("state") == "cleaned"})
    out = {"schema": "fm-browser-inspect.v1", "sessions": sessions, "activeCount": sum(1 for s in sessions if s.get("state") in LIVE_STATES and s.get("state") != "cleaned")}
    print_obj(out, args.json)


def cmd_reconcile(args):
    if not args.inspect_only:
        die("reconcile is inspect-only in v1", "inspect-only-required", as_json=args.json)
    cmd_inspect(args)


def cmd_expire(args):
    due = []
    now_epoch = int(time.time())
    for sess in active_sessions():
        if sess.get("hardDeadlineEpoch", now_epoch + 1) <= now_epoch:
            due.append({"handle": sess.get("handle"), "task": sess.get("task"), "expiryAction": sess.get("expiryAction", "alert-only"), "eligible": sess.get("expiryAction") == "close-exact" and sess.get("mode") == SUPPORTED_MODE and sess.get("auth") == SUPPORTED_AUTH})
    out = {"schema": "fm-browser-expire.v1", "due": due, "actionTaken": "none-alert-only"}
    print_obj(out, args.json)


def build_parser():
    parser = argparse.ArgumentParser(prog="fm-browser.sh", add_help=False)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("capabilities")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_capabilities)
    p = sub.add_parser("plan")
    p.add_argument("--task", required=True)
    p.add_argument("--project")
    p.add_argument("--origin", required=True)
    p.add_argument("--allow-origin", action="append")
    p.add_argument("--mode", default=SUPPORTED_MODE)
    p.add_argument("--auth", default=SUPPORTED_AUTH)
    p.add_argument("--tier", type=int, default=0)
    p.add_argument("--ttl", default="900")
    p.add_argument("--expiry-action", default="alert-only", choices=["alert-only", "close-exact"])
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_plan)
    p = sub.add_parser("open")
    p.add_argument("--task", required=True)
    p.add_argument("--plan", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_open)
    p = sub.add_parser("status")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--task")
    g.add_argument("--handle")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("navigate")
    p.add_argument("--handle", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_navigate)
    p = sub.add_parser("snapshot")
    p.add_argument("--handle", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_snapshot)
    p = sub.add_parser("interact")
    p.add_argument("--handle", required=True)
    p.add_argument("--kind", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--value-file")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_interact)
    p = sub.add_parser("request-action")
    p.add_argument("--handle", required=True)
    p.add_argument("--kind", required=True)
    p.add_argument("--effect", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_request_action)
    p = sub.add_parser("close")
    p.add_argument("--handle", required=True)
    p.add_argument("--reason", default="operator")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_close)
    p = sub.add_parser("inspect")
    p.add_argument("--all", action="store_true", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_inspect)
    p = sub.add_parser("reconcile")
    p.add_argument("--all", action="store_true", required=True)
    p.add_argument("--inspect-only", action="store_true", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_reconcile)
    p = sub.add_parser("expire")
    p.add_argument("--due", action="store_true", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_expire)
    return parser


try:
    ns = build_parser().parse_args()
    ns.func(ns)
except BrokenPipeError:
    pass
PY
