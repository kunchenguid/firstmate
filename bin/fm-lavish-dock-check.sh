#!/usr/bin/env bash
# fm-lavish-dock-check.sh - copy Lavish dock Send notes into this home's captain
# inbox without calling `lavish-axi poll`.
#
# Usage:
#   fm-lavish-dock-check.sh [check]
#   fm-lavish-dock-check.sh arm
#   fm-lavish-dock-check.sh --help
#
# The failure this exists to close: captain markups sit in lavish-axi session
# `pending_prompts` until a worker `poll` consumes them. Helm does not poll, and
# the published poll destructively clears feedback before returning it, so that
# path misses notes when nobody is blocked on poll and needs its own pre-poll
# recovery boundary when someone is.
# This check never polls.
# It reads lavish-axi's session store
# (`$LAVISH_AXI_STATE_DIR/state.json`, default `~/.lavish-axi/state.json`), the
# same store the published session listing is built from, copies unseen prompts
# into `bin/fm-inbox.sh note`, and leaves the session's pending prompts in
# place.
#
# `check` is the watcher action. It composes with the existing watcher
# state-check contract: a printed line becomes a `check:` wake. Successful
# delivery also queues one captain-inbox note per session that had new prompts,
# and that note is itself a `check:` wake. A proven no-op (no new prompts, or
# the same failure already reported) prints nothing.
#
# `arm` writes state/lavish-dock.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher dispatches it on its normal
# FM_CHECK_INTERVAL cadence.
#
# Session Open URLs in queued notes rewrite inner HTTP `:4387` to the HTTPS
# wrap on `:4389` on the same host. Never emit a `:4387` Open.
#
# Mutable bootstrap automatically arms it in the primary human-facing home.
# It does not author artifacts, open a browser, or touch Library `:3000`.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.lavish-dock-check"
SEEN="$STATE/.lavish-dock-seen"
LOCK="$STATE/.lavish-dock.lock"
CHECK_ID=lavish-dock
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
INBOX_BIN="$SCRIPT_DIR/fm-inbox.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-lavish-dock-check-v1
MAX_LINE=240

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-lavish-dock-check.sh [check]   copy unseen dock prompts into this home's inbox
  fm-lavish-dock-check.sh arm       write and register state/lavish-dock.check.sh
  fm-lavish-dock-check.sh --help    print this help

Reads lavish-axi session state non-destructively. Never runs `lavish-axi poll`.
Queued notes rewrite session Opens from :4387 to https :4389 on the same host.
EOF
}

die_usage() {
  printf 'fm-lavish-dock-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

report_line() {
  local line=$1
  fm_cap_line_var "lavish-dock: $line" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}

record_read() {
  local line first=1
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

emit_failure() {
  local line=$1
  record_read
  if [ -n "$line" ] && [ "$line" != "$RECORD_REPORTED" ]; then
    report_line "$line"
    record_write "$line" || true
  fi
}

lavish_state_json() {
  local dir=${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}
  printf '%s/state.json\n' "$dir"
}

extract_new_sessions() {
  local state_json=$1 seen_file=$2
  python3 - "$state_json" "$seen_file" <<'PY'
import hashlib
import json
import os
import sys

state_json, seen_file = sys.argv[1], sys.argv[2]
seen = {}
if os.path.isfile(seen_file):
    try:
        with open(seen_file, encoding="utf-8") as fh:
            saved = json.load(fh)
        if saved.get("schema") == "fm-lavish-dock-seen-v2" and isinstance(saved.get("sessions"), dict):
            seen = saved["sessions"]
    except (OSError, json.JSONDecodeError, AttributeError):
        pass

try:
    with open(state_json, encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    print("[]")
    raise SystemExit(0)
except (OSError, json.JSONDecodeError) as exc:
    sys.stderr.write("unreadable lavish session store: %s\n" % exc)
    raise SystemExit(2)

sessions = data.get("sessions")
if not isinstance(sessions, dict):
    sys.stderr.write("unreadable lavish session store: sessions is not an object\n")
    raise SystemExit(2)

out = []
for sid, sess in sessions.items():
    if not isinstance(sid, str) or not sid or not isinstance(sess, dict):
        continue
    prompts = sess.get("prompts")
    if not isinstance(prompts, list):
        prompts = []
    entries = []
    fingerprints = []
    for prompt in prompts:
        if not isinstance(prompt, dict):
            continue
        canonical = json.dumps(prompt, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        fingerprints.append(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
        text = prompt.get("prompt")
        if not isinstance(text, str):
            text = ""
        context = prompt.get("text")
        if not isinstance(context, str):
            context = ""
        attachments = prompt.get("attachments")
        if not isinstance(attachments, list):
            attachments = []
        if not text.strip() and not context.strip() and not attachments:
            entries.append(None)
            continue
        entries.append({"prompt": text, "text": context, "attachments": attachments})
    previous = seen.get(sid)
    if not isinstance(previous, list) or not all(isinstance(value, str) for value in previous):
        previous = []
    overlap = min(len(previous), len(fingerprints))
    while overlap and previous[-overlap:] != fingerprints[:overlap]:
        overlap -= 1
    if previous == fingerprints:
        new_items = []
    else:
        new_items = [entry for entry in entries[overlap:] if entry is not None]
    url = sess.get("url")
    if not isinstance(url, str):
        url = ""
    path = sess.get("file")
    if not isinstance(path, str):
        path = ""
    out.append({
        "id": sid,
        "url": url,
        "file": os.path.basename(path.rstrip("/")) if path else "",
        "prompts": new_items,
        "fingerprints": fingerprints,
    })
json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
print()
PY
}

format_note_body() {
  python3 -c '
import json
import sys
from urllib.parse import urlparse, urlunparse

session = json.loads(sys.argv[1])

def wrap(url):
    url = (url or "").strip()
    if not url:
        return ""
    parsed = urlparse(url)
    host = parsed.hostname or ""
    if not host:
        return url
    port = parsed.port
    if port is None and parsed.scheme in ("http", "https"):
        port = 80 if parsed.scheme == "http" else 443
    if port != 4387:
        return url
    userinfo = ""
    if parsed.username:
        userinfo = parsed.username
        if parsed.password is not None:
            userinfo += ":" + parsed.password
        userinfo += "@"
    netloc = userinfo + host + ":4389"
    return urlunparse(("https", netloc, parsed.path, parsed.params, parsed.query, parsed.fragment))

lines = ["Lavish dock reply"]
open_url = wrap(session.get("url") or "")
if open_url:
    if urlparse(open_url).port == 4387:
        raise SystemExit("refusing an unwrapped Lavish Open URL")
    lines.append("Open: " + open_url)
name = session.get("file") or ""
if name:
    lines.append("Board: " + name)
lines.append("")
for item in session.get("prompts") or []:
    prompt = (item.get("prompt") or "").strip()
    context = (item.get("text") or "").strip()
    if prompt:
        lines.append("- " + prompt)
        if context:
            lines.append("  (" + context + ")")
    elif context:
        lines.append("- " + context)
    for attachment in item.get("attachments") or []:
        if not isinstance(attachment, dict):
            continue
        path = str(attachment.get("path") or "").strip()
        name = str(attachment.get("name") or "").strip()
        mime = str(attachment.get("mime") or "").strip()
        detail = path or name or str(attachment.get("id") or "").strip()
        if detail:
            lines.append("  Attachment: " + detail + ((" (" + mime + ")") if mime else ""))
print("\n".join(lines))
' "$1"
}

seen_replace_session() {
  local sid=$1 fingerprints=$2
  python3 - "$SEEN" "$sid" "$fingerprints" <<'PY'
import json, os, sys, tempfile
path, sid, encoded = sys.argv[1:]
data = {"schema": "fm-lavish-dock-seen-v2", "sessions": {}}
try:
    with open(path, encoding="utf-8") as fh:
        loaded = json.load(fh)
    if loaded.get("schema") == data["schema"] and isinstance(loaded.get("sessions"), dict):
        data = loaded
except (OSError, json.JSONDecodeError, AttributeError):
    pass
data["sessions"][sid] = json.loads(encoded)
fd, temporary = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=os.path.dirname(path))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, separators=(",", ":"))
        fh.write("\n")
    os.replace(temporary, path)
except BaseException:
    try: os.close(fd)
    except OSError: pass
    try: os.unlink(temporary)
    except OSError: pass
    raise
PY
}

lock_release() {
  rm -rf -- "$LOCK"
}

lock_acquire() {
  local pid
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true
    return 0
  fi
  pid=$(cat "$LOCK/pid" 2>/dev/null) || pid=
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  rm -rf -- "$LOCK"
  mkdir "$LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true
  return 0
}

action_check() {
  local state_json extracted rc=0 queued=0 idx count body sid session_json extract_err fingerprints prompt_count
  mkdir -p "$STATE" || return 1
  if ! lock_acquire; then
    return 0
  fi
  trap lock_release EXIT HUP INT TERM

  if ! command -v python3 >/dev/null 2>&1; then
    emit_failure "python3 is not installed"
    return 0
  fi
  if [ ! -x "$INBOX_BIN" ]; then
    emit_failure "fm-inbox.sh is missing next to this check ($INBOX_BIN)"
    return 0
  fi

  state_json=$(lavish_state_json)
  extract_err=$(mktemp "$STATE/.fm-lavish-dock-extract.XXXXXX" 2>/dev/null) || extract_err=
  if [ -n "$extract_err" ]; then
    extracted=$(extract_new_sessions "$state_json" "$SEEN" 2>"$extract_err") || rc=$?
  else
    extracted=$(extract_new_sessions "$state_json" "$SEEN" 2>/dev/null) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if [ -n "$extract_err" ] && [ -s "$extract_err" ]; then
      emit_failure "$(tr '\n' ' ' < "$extract_err" | sed 's/[[:space:]]*$//')"
    else
      emit_failure "unreadable lavish session store"
    fi
    [ -z "$extract_err" ] || rm -f -- "$extract_err"
    return 0
  fi
  [ -z "$extract_err" ] || rm -f -- "$extract_err"

  count=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$extracted") || count=0
  if [ "$count" = 0 ]; then
    record_write "" || true
    return 0
  fi

  idx=0
  while [ "$idx" -lt "$count" ]; do
    sid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["id"])' "$extracted" "$idx") || {
      emit_failure "could not read a pending dock session"
      return 0
    }
    session_json=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])], ensure_ascii=False, separators=(",", ":")))' "$extracted" "$idx") || {
      emit_failure "could not read a pending dock session"
      return 0
    }
    fingerprints=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["fingerprints"], separators=(",", ":")))' "$session_json") || return 0
    prompt_count=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["prompts"]))' "$session_json") || return 0
    if [ "$prompt_count" -eq 0 ]; then
      seen_replace_session "$sid" "$fingerprints" || { emit_failure "could not update a dock cursor"; return 0; }
      idx=$((idx + 1))
      continue
    fi
    body=$(format_note_body "$session_json") || {
      emit_failure "could not format a dock note"
      return 0
    }
    if ! printf '%s\n' "$body" | FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$INBOX_BIN" note - >/dev/null; then
      emit_failure "could not queue a captain inbox note for session $sid"
      return 0
    fi
    seen_replace_session "$sid" "$fingerprints" || {
      emit_failure "queued a dock note but could not record its cursor"
      return 0
    }
    queued=$((queued + 1))
    idx=$((idx + 1))
  done

  record_write "" || true
  if [ "$queued" -eq 0 ]; then
    return 0
  elif [ "$queued" -eq 1 ]; then
    report_line "queued 1 dock note"
  else
    report_line "queued $queued dock notes"
  fi
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-lavish-dock-check.sh - Lavish dock-reply shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-lavish-dock-check.sh") check"
}

SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-lavish-dock-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-lavish-dock-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-lavish-dock-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -x "$INBOX_BIN" ]; then
    printf 'fm-lavish-dock-check: fm-inbox.sh is missing at %s; cannot arm\n' "$INBOX_BIN" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-lavish-dock-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-lavish-dock-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-lavish-dock-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-lavish-dock-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
