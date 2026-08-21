#!/usr/bin/env bash
# GPT Deep Research adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-gpt-deep-research.sh arm <watch-id> [--interval-seconds N]
#   fm-procevent-gpt-deep-research.sh classify <result-file>
#   fm-procevent-gpt-deep-research.sh terminal <result-file>
#   fm-procevent-gpt-deep-research.sh source-id <watch-id>
#   fm-procevent-gpt-deep-research.sh retire <watch-id>
#
# arm       Validate and bind one existing gpt_deep_research_report_watch.v1
#           record, register its exact binding as a blocking process-event
#           source, and ask the generic runner to supervise it immediately.
#           A second arm of that same live binding is idempotent and never
#           starts a second child. --interval-seconds is a positive integer
#           and defaults to 15.
# classify  Print the bounded terminal status in a captured result.
# terminal  Exit 0 only for one valid terminal result this adapter emitted.
# source-id Print the canonical source id derived from this watch's resolved
#           state directory and path-safe watch id.
# retire    Stop the source and remove its private exact-watch binding.
#
# The blocking child reads only its already-bound watch record and emits one
# redacted result when that exact record reaches COLLECTED,
# COLLECTED_CLEANUP_PENDING, NEEDS_COLLECTION, BLOCKED, or
# COLLECTION_UNCERTAIN. It never starts, configures, or calls the standalone
# report watcher, touches Chrome, opens a tab, or writes to skill state.
#
# A COLLECTED or COLLECTED_CLEANUP_PENDING result is successful only after its
# report-watcher-verified archive path still names an existing regular archive.
# A missing archive is surfaced as COLLECTION_UNCERTAIN. Cleanup-pending keeps
# its verified archive reviewable while the standalone watcher retries only tab
# cleanup. Result payloads contain only watch identity, terminal status, the
# verified archive path when available, the bound ChatGPT conversation URL, and
# a fixed bounded detail. They never carry briefs, report text, slugs, cookies,
# browser state, credentials, or the watcher's raw diagnostic text.
#
# The installed GPT Deep Research skill owns watch-directory resolution through
# state_paths.py. Set GPT_DEEP_RESEARCH_SKILL_DIR only to locate that installed
# skill explicitly, for example in an isolated test. This adapter never
# reimplements its XDG or legacy migration policy.
#
# Ownership, capture, durable publication, restart recovery, acknowledgement,
# and runner process lifetime belong to bin/fm-procevent.sh. This adapter owns
# only exact-watch binding and its terminal result semantics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DEFAULT_INTERVAL=15
BINDING_SCHEMA='fm-gpt-deep-research-binding.v1'
RESULT_SCHEMA='fm-gpt-deep-research-result.v1'

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

positive_int() {
  case "${1-}" in ''|*[!0-9]*|0) return 1 ;; esac
}

watch_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id" && [ "${#id}" -le 120 ]
}

skill_scripts_dir() {
  local candidate
  if [ -n "${GPT_DEEP_RESEARCH_SKILL_DIR:-}" ]; then
    candidate=$GPT_DEEP_RESEARCH_SKILL_DIR
    [ -f "$candidate/scripts/state_paths.py" ] \
      || die "GPT_DEEP_RESEARCH_SKILL_DIR has no scripts/state_paths.py"
    printf '%s\n' "$candidate/scripts"
    return 0
  fi
  for candidate in "$HOME/.agents/skills/gpt-deep-research" "$HOME/.claude/skills/gpt-deep-research"; do
    if [ -f "$candidate/scripts/state_paths.py" ]; then
      printf '%s\n' "$candidate/scripts"
      return 0
    fi
  done
  die "cannot locate the installed GPT Deep Research skill; set GPT_DEEP_RESEARCH_SKILL_DIR"
}

watches_dir() {
  local scripts dir
  scripts=$(skill_scripts_dir) || return 1
  dir=$(PYTHONPATH="$scripts" python3 -c 'from state_paths import resolve_watches_dir; print(resolve_watches_dir())' 2>/dev/null) \
    || die "could not resolve the GPT Deep Research watches directory"
  [ -n "$dir" ] || die "the GPT Deep Research watches directory is empty"
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "GPT Deep Research watches directory is unavailable: $dir"
  dir=$(cd "$dir" && pwd -P) || die "cannot resolve GPT Deep Research watches directory: $dir"
  case "$dir" in *$'\n'*|*$'\t'*) die "GPT Deep Research watches directory has unsafe whitespace" ;; esac
  printf '%s\n' "$dir"
}

watch_path_for() {  # <watch-id>
  local id=$1 dir
  watch_id_valid "$id" || die "watch id must be path-safe and at most 120 characters: $id"
  dir=$(watches_dir) || return 1
  printf '%s/%s.json\n' "$dir" "$id"
}

sha256_text() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"
}

cmd_source_id() {
  local watch_id=${1-} path digest
  [ "$#" -eq 1 ] || usage
  path=$(watch_path_for "$watch_id") || return 1
  digest=$(sha256_text "$path") || die "cannot derive source identity"
  printf 'gpt-dr-%s\n' "${digest:0:40}"
}

binding_dir() { printf '%s/gpt-deep-research\n' "$STATE"; }
binding_path() { printf '%s/%s.binding\n' "$(binding_dir)" "$1"; }

# Print safe exact-watch binding fields separated by tabs:
# <path> <device:inode> <watch-id> <conversation-url> <session-digest> <page-id>
watch_binding_fields() {  # <watch-path> <watch-id>
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import os
import stat
import sys
from urllib.parse import urlsplit

path, expected_watch_id = sys.argv[1:]
try:
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
        raise ValueError("watch record is not a regular file")
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
    if not isinstance(state, dict) or state.get("schema") != "gpt_deep_research_report_watch.v1":
        raise ValueError("watch record schema is not supported")
    if state.get("watch_id") != expected_watch_id:
        raise ValueError("watch id does not match its record")
    session = state.get("session")
    page_id = state.get("page_id")
    url = state.get("expected_url")
    if not isinstance(session, str) or not session or not isinstance(page_id, int) or page_id < 1:
        raise ValueError("watch binding fields are invalid")
    if not isinstance(url, str) or any(ord(char) < 33 or ord(char) == 127 for char in url):
        raise ValueError("conversation URL is invalid")
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "chatgpt.com"
        or parsed.port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith("/c/")
        or not parsed.path[3:]
    ):
        raise ValueError("conversation URL is not a safe ChatGPT conversation URL")
    print("\t".join((
        path,
        f"{st.st_dev}:{st.st_ino}",
        expected_watch_id,
        url,
        hashlib.sha256(session.encode()).hexdigest(),
        str(page_id),
    )))
except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

binding_matches_watch() {  # <binding-file> <watch-path> <watch-id>
  python3 - "$1" "$2" "$3" "$BINDING_SCHEMA" <<'PY'
import hashlib
import json
import os
import stat
import sys
from urllib.parse import urlsplit

binding_path, watch_path, expected_watch_id, schema = sys.argv[1:]
try:
    st = os.lstat(binding_path)
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
        raise ValueError
    with open(binding_path, encoding="utf-8") as handle:
        binding = json.load(handle)
    watch_stat = os.lstat(watch_path)
    if not stat.S_ISREG(watch_stat.st_mode) or stat.S_ISLNK(watch_stat.st_mode):
        raise ValueError
    with open(watch_path, encoding="utf-8") as handle:
        state = json.load(handle)
    url = state.get("expected_url")
    parsed = urlsplit(url) if isinstance(url, str) else None
    valid_url = parsed and parsed.scheme == "https" and parsed.hostname == "chatgpt.com" and parsed.port is None and parsed.username is None and parsed.password is None and not parsed.query and not parsed.fragment and parsed.path.startswith("/c/") and bool(parsed.path[3:])
    if not valid_url:
        raise ValueError
    expected = {
        "schema": schema,
        "watch_path": watch_path,
        "watch_identity": f"{watch_stat.st_dev}:{watch_stat.st_ino}",
        "watch_id": expected_watch_id,
        "conversation_url": url,
        "session_sha256": hashlib.sha256(state.get("session", "").encode()).hexdigest(),
        "page_id": state.get("page_id"),
    }
    if state.get("schema") != "gpt_deep_research_report_watch.v1" or state.get("watch_id") != expected_watch_id or not isinstance(state.get("session"), str) or not state["session"] or not isinstance(state.get("page_id"), int) or state["page_id"] < 1 or binding != expected:
        raise ValueError
except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

write_binding() {  # <binding-file> <watch-path> <identity> <watch-id> <url> <session-hash> <page-id>
  local destination=$1 directory tmp
  shift
  directory=${destination%/*}
  (umask 077; mkdir -p "$directory") || return 1
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  tmp=$(umask 077; mktemp "$directory/.binding.XXXXXX") || return 1
  if python3 - "$tmp" "$BINDING_SCHEMA" "$@" <<'PY'
import json
import sys

path, schema, watch_path, identity, watch_id, url, session_sha256, page_id = sys.argv[1:]
payload = {
    "schema": schema,
    "watch_path": watch_path,
    "watch_identity": identity,
    "watch_id": watch_id,
    "conversation_url": url,
    "session_sha256": session_sha256,
    "page_id": int(page_id),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
  then
    chmod 0600 "$tmp" && mv -f -- "$tmp" "$destination"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

source_registration_is_ours() {  # <source-id>
  local source adapter
  source="$(fm_procevent_registry_dir "$STATE")/$1.source"
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  adapter=$(sed -n 's/^adapter=//p' "$source" | head -1)
  [ "$adapter" = gpt-deep-research ]
}

parse_arm() {
  WATCH_ID=${1-}
  [ -n "$WATCH_ID" ] || usage
  shift
  INTERVAL=$DEFAULT_INTERVAL
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval-seconds)
        positive_int "${2-}" || die "--interval-seconds needs a positive integer"
        INTERVAL=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
}

cmd_arm() {
  parse_arm "$@"
  local watch_path id binding fields identity bound_id url session_hash page_id pending
  watch_path=$(watch_path_for "$WATCH_ID") || return 1
  [ -f "$watch_path" ] && [ ! -L "$watch_path" ] || die "watch record does not exist: $watch_path"
  id=$(cmd_source_id "$WATCH_ID") || return 1
  binding=$(binding_path "$id")
  fields=$(watch_binding_fields "$watch_path" "$WATCH_ID") \
    || die "watch record is not a valid GPT Deep Research watch: $watch_path"
  IFS=$'\t' read -r _ identity bound_id url session_hash page_id <<< "$fields"
  [ "$bound_id" = "$WATCH_ID" ] || die "watch binding is inconsistent"

  fm_procevent_source_lock_acquire "$id" || die "cannot lock the watch source"
  trap 'fm_procevent_source_lock_release "$id"' EXIT
  if [ -e "$binding" ] || [ -L "$binding" ]; then
    binding_matches_watch "$binding" "$watch_path" "$WATCH_ID" \
      || die "existing binding does not match this exact watch; retire it before re-arming"
    if source_registration_is_ours "$id"; then
      fm_procevent_source_lock_release "$id"
      trap - EXIT
      "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null || die "cannot supervise the existing watch source"
      printf 'already armed: %s\n' "$id"
      return 0
    fi
    pending=$(fm_procevent_pending "$STATE" | grep -c "/$id\." || true)
    [ "$pending" -eq 0 ] \
      || die "an unhandled captured result exists for this watch; handle it before re-arming"
    die "watch was already completed or retired; retire it before re-arming"
  fi
  if source_registration_is_ours "$id"; then
    die "source exists without its exact-watch binding; retire it before re-arming"
  fi
  write_binding "$binding" "$watch_path" "$identity" "$WATCH_ID" "$url" "$session_hash" "$page_id" \
    || die "cannot create the private exact-watch binding"
  if ! fm_procevent_registration_publish_locked "$STATE" gpt-deep-research "$id" \
      "$SCRIPT_DIR/fm-procevent-gpt-deep-research.sh" wait "$binding" "$WATCH_ID" "$INTERVAL"; then
    rm -f -- "$binding"
    die "cannot register the watch source"
  fi
  fm_procevent_source_lock_release "$id"
  trap - EXIT
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null || die "cannot supervise the armed watch source"
  printf 'armed: %s\n' "$id"
}

# The private blocking child. It accepts only its private binding, never a
# caller-supplied watch path, and its Python reader emits an allowlisted result
# instead of forwarding any field from the watched JSON record.
cmd_wait() {  # <binding-file> <watch-id> <interval-seconds>
  local binding=${1-} watch_id=${2-} interval=${3-} result rc
  [ "$#" -eq 3 ] || usage
  watch_id_valid "$watch_id" || die "invalid bound watch id"
  positive_int "$interval" || die "invalid bound interval"
  while :; do
    rc=0
    result=$(python3 - "$binding" "$watch_id" "$BINDING_SCHEMA" "$RESULT_SCHEMA" <<'PY'
import json
import os
import stat
import sys
from pathlib import Path
from urllib.parse import urlsplit

binding_path, expected_watch_id, binding_schema, result_schema = sys.argv[1:]
terminal = {"COLLECTED", "COLLECTED_CLEANUP_PENDING", "NEEDS_COLLECTION", "BLOCKED", "COLLECTION_UNCERTAIN"}
details = {
    "COLLECTED_CLEANUP_PENDING": "archive saved; registered tab cleanup remains pending",
    "NEEDS_COLLECTION": "report requires manual collection",
    "BLOCKED": "watcher stopped collection safely; inspect the bound watch locally",
    "COLLECTION_UNCERTAIN": "collection outcome requires verification",
}

def emit(status, archive=None, detail=None):
    print(json.dumps({
        "schema": result_schema,
        "watch_id": expected_watch_id,
        "status": status,
        "archive_path": archive,
        "conversation_url": conversation_url,
        "detail": detail,
    }, separators=(",", ":"), sort_keys=True))

try:
    binding_stat = os.lstat(binding_path)
    if not stat.S_ISREG(binding_stat.st_mode) or stat.S_ISLNK(binding_stat.st_mode):
        raise ValueError
    with open(binding_path, encoding="utf-8") as handle:
        binding = json.load(handle)
    required = {"schema", "watch_path", "watch_identity", "watch_id", "conversation_url", "session_sha256", "page_id"}
    if not isinstance(binding, dict) or set(binding) != required or binding.get("schema") != binding_schema or binding.get("watch_id") != expected_watch_id:
        raise ValueError
    conversation_url = binding["conversation_url"]
    parsed = urlsplit(conversation_url) if isinstance(conversation_url, str) else None
    if not parsed or parsed.scheme != "https" or parsed.hostname != "chatgpt.com" or parsed.port is not None or parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment or not parsed.path.startswith("/c/") or not parsed.path[3:]:
        raise ValueError
    watch_path = binding["watch_path"]
    watch_stat = os.lstat(watch_path)
    if not stat.S_ISREG(watch_stat.st_mode) or stat.S_ISLNK(watch_stat.st_mode) or binding.get("watch_identity") != f"{watch_stat.st_dev}:{watch_stat.st_ino}":
        raise ValueError
    with open(watch_path, encoding="utf-8") as handle:
        state = json.load(handle)
    if state.get("schema") != "gpt_deep_research_report_watch.v1" or state.get("watch_id") != expected_watch_id or state.get("expected_url") != conversation_url:
        raise ValueError
    status = state.get("status")
    if status not in terminal:
        raise SystemExit(3)
    archive = state.get("archive_path")
    if status in {"COLLECTED", "COLLECTED_CLEANUP_PENDING"}:
        archive_path = Path(archive) if isinstance(archive, str) else None
        try:
            archive_stat = os.lstat(archive_path) if archive_path and archive_path.is_absolute() else None
            archive_ok = archive_stat is not None and stat.S_ISREG(archive_stat.st_mode) and not stat.S_ISLNK(archive_stat.st_mode) and archive_stat.st_size > 0
        except OSError:
            archive_ok = False
        if not archive_ok:
            emit("COLLECTION_UNCERTAIN", detail="recorded archive is unavailable")
            raise SystemExit(0)
        emit(status, archive=archive, detail=details.get(status))
        raise SystemExit(0)
    emit(status, detail=details.get(status))
except SystemExit:
    raise
except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
    conversation_url = ""
    try:
        with open(binding_path, encoding="utf-8") as handle:
            candidate = json.load(handle).get("conversation_url")
        parsed = urlsplit(candidate) if isinstance(candidate, str) else None
        if parsed and parsed.scheme == "https" and parsed.hostname == "chatgpt.com" and parsed.port is None and parsed.username is None and parsed.password is None and parsed.path.startswith("/c/") and parsed.path[3:] and not parsed.query and not parsed.fragment:
            conversation_url = candidate
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    print(json.dumps({
        "schema": result_schema,
        "watch_id": expected_watch_id,
        "status": "BLOCKED",
        "archive_path": None,
        "conversation_url": conversation_url,
        "detail": "bound watch record changed or is unavailable",
    }, separators=(",", ":"), sort_keys=True))
PY
) || rc=$?
    rc=${rc:-0}
    case "$rc" in
      0) printf '%s\n' "$result"; return 0 ;;
      3) sleep "$interval" ;;
      *) die "cannot read the bound GPT Deep Research watch" ;;
    esac
  done
}

result_status() {  # <result-file>
  python3 - "$1" "$RESULT_SCHEMA" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        result = json.load(handle)
    statuses = {"COLLECTED", "COLLECTED_CLEANUP_PENDING", "NEEDS_COLLECTION", "BLOCKED", "COLLECTION_UNCERTAIN"}
    required = {"schema", "watch_id", "status", "archive_path", "conversation_url", "detail"}
    if not isinstance(result, dict) or set(result) != required or result.get("schema") != sys.argv[2] or result.get("status") not in statuses or not isinstance(result.get("watch_id"), str):
        raise ValueError
    print(result["status"])
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

cmd_classify() {
  [ "$#" -eq 1 ] || usage
  result_status "$1" || die "result is not a valid GPT Deep Research terminal result"
}

cmd_terminal() {
  [ "$#" -eq 1 ] || usage
  result_status "$1" >/dev/null || return 1
}

cmd_retire() {
  local watch_id=${1-} id binding
  [ "$#" -eq 1 ] || usage
  id=$(cmd_source_id "$watch_id") || return 1
  binding=$(binding_path "$id")
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id" || return 1
  rm -f -- "$binding" || die "cannot remove the private exact-watch binding"
  printf 'retired: %s\n' "$id"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  wait)      shift; cmd_wait "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
