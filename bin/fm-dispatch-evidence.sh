#!/usr/bin/env bash
# fm-dispatch-evidence.sh - inspect a declared local Pi lane and append task-scoped routing evidence.
#
# Usage:
#   fm-dispatch-evidence.sh check-local <provider/model> --expected-url <base-url> [--catalog <models.json>]
#   fm-dispatch-evidence.sh record <task-id> <shadow|outcome> < <one JSON object>
#
# check-local emits one readiness JSON object; it never picks a model or retries.
# docs/configuration.md#local-pi-readiness-and-task-outcome-evidence owns
# readiness requirements and the evidence record contract.
# record appends one bounded, allow-listed JSON object to the existing task's
# private data/<id>/dispatch-evidence.jsonl and fsyncs it.
# This is evidence, not a router.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
if [ "${1:-}" = record ]; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_task_id_creation_valid "${2:-}" || {
    echo "error: invalid task id" >&2
    exit 2
  }
fi
exec python3 -c "$(cat <<'PY'
import datetime
import ipaddress
import json
import math
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def die(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        die("local endpoint redirected the request")


local_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def get_json(url, timeout=5, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with local_opener.open(request, timeout=timeout) as response:
        if response.status != 200:
            die(f"{url} returned HTTP {response.status}")
        body = response.read(65537)
        if len(body) > 65536:
            die("local endpoint response exceeds 64 KiB")
        return json.loads(body)


def local_url(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http" or parsed.username or parsed.password or parsed.query or parsed.fragment:
        die("local base URL must be plain HTTP without credentials or query")
    try:
        address = ipaddress.ip_address(parsed.hostname or "")
        port = parsed.port
    except ValueError:
        die("local base URL must use a literal IP address and port")
    tailnet = ipaddress.ip_network("100.64.0.0/10")
    if not (address.is_loopback or address in tailnet) or not port or parsed.path.rstrip("/") != "/v1":
        die("local base URL must be loopback or Tailnet IP:port ending in /v1")
    return url.rstrip("/"), address


def require_tailnet_peer(address):
    if address.is_loopback:
        return
    try:
        result = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5, check=True)
        status = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        die("cannot verify local endpoint as a Tailnet peer")
    if not isinstance(status, dict) or status.get("BackendState") != "Running" or not isinstance(status.get("Peer"), dict):
        die("cannot verify local endpoint as a Tailnet peer")
    matches = 0
    for peer in status["Peer"].values():
        if not isinstance(peer, dict) or not isinstance(peer.get("TailscaleIPs"), list):
            continue
        for value in peer["TailscaleIPs"]:
            try:
                matches += ipaddress.ip_address(value) == address
            except ValueError:
                continue
    if matches != 1:
        die("local endpoint is not a verified Tailnet peer")


def check_local(args):
    if not args or "/" not in args[0]:
        die("check-local needs provider/model")
    selector = args.pop(0)
    catalog = pathlib.Path.home() / ".pi/agent/models.json"
    expected = None
    while args:
        flag = args.pop(0)
        if flag in ("--catalog", "--expected-url"):
            if not args:
                die(f"{flag} needs a value")
            value = args.pop(0)
            if flag == "--catalog":
                catalog = pathlib.Path(value)
            else:
                expected = value
        else:
            die(f"unknown flag {flag}")
    provider, model = selector.split("/", 1)
    if not provider or not model or expected is None:
        die("selector must name provider and model, with --expected-url")
    try:
        config = json.loads(catalog.read_text())
        lane = config["providers"][provider]
        matches = [entry for entry in lane["models"] if entry.get("id") == model]
    except (OSError, AttributeError, KeyError, TypeError, ValueError) as exc:
        die(f"Pi catalog unavailable or malformed: {exc}")
    if len(matches) != 1 or lane.get("api") != "openai-completions":
        die("Pi catalog does not contain exactly one OpenAI-completions model tuple")
    base, address = local_url(lane.get("baseUrl", ""))
    if local_url(expected)[0] != base:
        die("Pi catalog base URL differs from expected URL")
    require_tailnet_peer(address)
    try:
        health = get_json(base[:-3] + "/health")
        listing = get_json(base + "/models")
    except (OSError, urllib.error.URLError, ValueError) as exc:
        die(f"local endpoint unavailable: {exc}")
    if not isinstance(health, dict) or health.get("status") not in ("ok", "healthy"):
        die("local endpoint health is not ready")
    if not isinstance(listing, dict) or not isinstance(listing.get("data"), list):
        die("local endpoint model listing is malformed")
    listed = [entry for entry in listing["data"] if isinstance(entry, dict) and entry.get("id") == model]
    if len(listed) != 1:
        die("local endpoint does not advertise the exact Pi model alias")
    advertised = listed[0]
    meta = advertised.get("meta")
    if meta is not None and not isinstance(meta, dict):
        die("local endpoint model metadata is malformed")
    served_context = advertised.get("context_length") or advertised.get("n_ctx") or (meta or {}).get("n_ctx")
    configured_context = matches[0].get("contextWindow")
    if not isinstance(served_context, int) or isinstance(served_context, bool) or not isinstance(configured_context, int) or isinstance(configured_context, bool) or served_context < configured_context:
        die("local endpoint context is absent or below the Pi catalog window")
    request = {
        "model": model,
        "messages": [{"role": "user", "content": "Call the probe tool with value ready."}],
        "tools": [{"type": "function", "function": {"name": "probe", "description": "Readiness probe", "parameters": {"type": "object", "properties": {"value": {"type": "string"}}, "required": ["value"]}}}],
        "tool_choice": {"type": "function", "function": {"name": "probe"}},
        "max_tokens": 256,
        "stream": False,
    }
    try:
        response = get_json(base + "/chat/completions", timeout=120, payload=request)
    except (OSError, urllib.error.URLError, ValueError) as exc:
        die(f"local tool canary failed: {exc}")
    choice = (response.get("choices") or [{}])[0]
    calls = (choice.get("message") or {}).get("tool_calls") or []
    function = calls[0].get("function", {}) if calls else {}
    try:
        arguments = json.loads(function.get("arguments", ""))
    except (TypeError, ValueError):
        arguments = None
    if choice.get("finish_reason") != "tool_calls" or function.get("name") != "probe" or arguments != {"value": "ready"}:
        die("local endpoint did not return a complete structured tool call")
    result = {
        "selector": selector,
        "base_url": base,
        "context_window": matches[0].get("contextWindow"),
        "served_context_window": served_context,
        "max_tokens": matches[0].get("maxTokens"),
        "health": health["status"],
        "served_model": listed[0].get("id"),
        "served_revision": listed[0].get("revision") or (listed[0].get("meta") or {}).get("revision"),
        "tool_canary": "passed",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


def record(args, home):
    if len(args) != 2:
        die("record needs task-id and shadow|outcome")
    task, kind = args
    if kind not in ("shadow", "outcome"):
        die("record kind must be shadow or outcome")
    directory = pathlib.Path(home) / "data" / task
    if not directory.is_dir() or directory.is_symlink():
        die("task data directory must already exist and must not be a symlink")
    try:
        raw = sys.stdin.read(65537)
        if len(raw) > 65536:
            die("row exceeds 64 KiB")
        row = json.loads(raw, parse_constant=lambda value: die(f"invalid JSON constant {value}"))
    except (ValueError, UnicodeError) as exc:
        die(f"invalid JSON row: {exc}")
    if not isinstance(row, dict):
        die("row must be a JSON object")
    common = {"run_id", "task_class", "proposed", "selected", "basis", "confidence", "status", "reason", "provider", "model", "endpoint", "checkpoint_revision", "runtime_revision", "spec_sha256", "verifier_sha256", "head", "accepted", "elapsed_seconds", "interventions", "rework_minutes", "failure_class", "cost_usd", "input_tokens", "output_tokens", "cached_tokens", "context_tokens", "ttft_seconds", "decode_tps", "verifier_score", "cloud_egress", "evidence"}
    if set(row) - common:
        die("row contains a field outside the dispatch-evidence allowlist")
    required = {"task_class", "proposed", "selected"} if kind == "shadow" else {"run_id", "task_class", "provider", "model", "accepted", "elapsed_seconds", "interventions", "rework_minutes"}
    if not required <= set(row):
        die("row omits required dispatch-evidence fields")
    if any(isinstance(value, (dict, list)) or (isinstance(value, str) and len(value) > 500) for value in row.values()):
        die("row values must be bounded JSON scalars")
    if any(isinstance(row[key], (int, float)) and not math.isfinite(row[key]) for key in row):
        die("row numbers must be finite")
    optional_numbers = {"cost_usd", "input_tokens", "output_tokens", "cached_tokens", "context_tokens", "ttft_seconds", "decode_tps", "verifier_score"}
    if any(key in row and (not isinstance(row[key], (int, float)) or isinstance(row[key], bool) or row[key] < 0) for key in optional_numbers):
        die("optional measurements must be nonnegative numbers")
    if "cloud_egress" in row and not isinstance(row["cloud_egress"], bool):
        die("cloud_egress must be boolean")
    text_fields = required - {"accepted", "elapsed_seconds", "interventions", "rework_minutes"}
    if any(not isinstance(row[key], str) or not row[key] for key in text_fields):
        die("required identity fields must be nonempty strings")
    if kind == "outcome" and (not isinstance(row["accepted"], bool) or any(not isinstance(row[key], (int, float)) or isinstance(row[key], bool) or row[key] < 0 for key in ("elapsed_seconds", "interventions", "rework_minutes"))):
        die("outcome acceptance and durations have invalid types")
    if "confidence" in row and (not isinstance(row["confidence"], (int, float)) or not 0 <= row["confidence"] <= 1):
        die("confidence must be between 0 and 1")
    event = {"schema": "fm-dispatch-evidence.v1", "at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "kind": kind, "task": task, **row}
    target = directory / "dispatch-evidence.jsonl"
    if target.is_symlink():
        die("dispatch evidence target must not be a symlink")
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    print(target)


if len(sys.argv) < 3:
    die("usage: fm-dispatch-evidence.sh check-local|record ...")
home = sys.argv[1]
command = sys.argv[2]
if command == "check-local":
    check_local(sys.argv[3:])
elif command == "record":
    record(sys.argv[3:], home)
else:
    die(f"unknown command {command}")
PY
)" "$FM_HOME" "$@"
