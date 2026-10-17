#!/usr/bin/env bash
# fm-sos-intake.sh - firstmate intake for the SOS dispatch loop.
#
# The loop: Portal files an SOS ticket as a GitHub issue and fires one PHI-free
# event at stack-monitor's typed event bridge (POST /ingest/event, kind=sos,
# dedupe_key = the SOS message UUID). This intake turns that event - or, as a
# heal for lost events and pre-bridge tickets, an open sos-labeled GitHub
# issue - into durable work: one task row (a bead on a beads backend) per SOS,
# one lifecycle comment on the GitHub issue, one close watch per issue, and
# one dispatched crewmate per new ticket. Every step is idempotent, so a
# retry, a replayed event, a lost cursor, or a re-armed consumer can never
# double-dispatch.
#
# Usage:
#   fm-sos-intake.sh reconcile [--mode <m>] [--yolo on|off] [--dry-run]
#   fm-sos-intake.sh comment <issue-number> <transition> [note...]
#   fm-sos-intake.sh watch-condition <issue-number>
#   fm-sos-intake.sh watch-fire <issue-number> <sos-key>
#   fm-sos-intake.sh status
#
# reconcile     Idempotent intake pass. Pulls bridge events past the durable
#               cursor, folds in open sos-labeled GitHub issues (the heal
#               path), and per ticket: ensures the task row, posts the one
#               "dispatched" lifecycle comment, arms the close watch, then
#               scaffolds the brief and spawns the crewmate. The TASK ROW ID
#               is the idempotency record: it is
#               exactly `fm-sos-<SOS message UUID>`, and tasks-axi's add is
#               idempotent on the id, so a replayed event can never mint a
#               second row. The cursor is only a fast-path over the bridge.
#               Auto-dispatch is opt-in: the captain grants it by creating
#               $FM_HOME/config/sos-autodispatch. Without that grant a ticket
#               gets its task row and close watch but no dispatched comment
#               or crewmate (a dispatch-held line reports it). With it, every
#               SOS dispatches: no confidence gate, no triage. --mode/--yolo set the spawned task's
#               delivery contract (defaults FM_SOS_MODE=no-mistakes,
#               FM_SOS_YOLO=on); they are posture, not selection.
# comment       Post one canonical lifecycle comment on the GitHub issue.
#               Transitions: dispatched, repro-confirmed, fix-up, deployed,
#               verified, captain-closed. Dispatched workers use this at each
#               transition so the reporter-facing thread reads the same way
#               for every ticket.
# watch-condition   Exit 0 iff the issue is CLOSED (for fm-procevent-when.sh).
#               Any GitHub failure exits 2: a failure is NEVER a close.
# watch-fire    The close watch's action: post the captain-closed comment,
#               close the task row (never the GitHub issue), and record the
#               reporter-notification handoff. Runs at most once per watch -
#               fm-procevent-when.sh claims a durable fired marker before the
#               action - and the ledger line makes manual re-runs safe too.
#
# THE LOOP NEVER CLOSES A GITHUB ISSUE. The captain closes it after
# verification; watch-fire fires only because the captain already closed it.
#
# Backlog writes go through bin/fm-tasks-axi.sh like every other core script
# (fm-lint.sh's backend-purity check rejects direct Beads CLI calls in bin/),
# so a beads-configured home gets beads and a markdown home gets backlog rows.
#
# Env: FM_HOME (default /opt/ra/firstmate), FM_SOS_BRIDGE_URL (default
# http://127.0.0.1:8791), FM_SOS_GH_REPO (default ArcsHealth/Portal),
# FM_SOS_PROJECT (default $FM_HOME/projects/portal), FM_SOS_MODE, FM_SOS_YOLO,
# FM_SOS_PRIORITY (default 1), FM_SOS_DUE (default +2w), FM_SOS_GH (gh
# command), FM_SOS_CURL (curl),
# FM_SOS_TASKS / FM_SOS_SPAWN / FM_SOS_BRIEF / FM_SOS_WHEN /
# FM_SOS_RESOLVE (the sibling firstmate commands, overridable so tests can
# substitute a stub).
#
# State (all under $FM_HOME/state/): fm-sos-intake.cursor (bridge event id),
# fm-sos-intake.log (append-only ledger of handled effects),
# .fm-sos-intake.lock (single-writer lock) and .fm-sos-intake.err (a tasks-axi
# diagnostic, removed as soon as it is read),
# when/when-sos-<n>.* (close watches).
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-/opt/ra/firstmate}"
BRIDGE_URL="${FM_SOS_BRIDGE_URL:-http://127.0.0.1:8791}"
GH_REPO="${FM_SOS_GH_REPO:-ArcsHealth/Portal}"
AUTODISPATCH_GRANT="$FM_HOME/config/sos-autodispatch"
PROJECT_DIR="${FM_SOS_PROJECT:-$FM_HOME/projects/portal}"
MODE="${FM_SOS_MODE:-no-mistakes}"
YOLO="${FM_SOS_YOLO:-on}"
PRIORITY="${FM_SOS_PRIORITY:-1}"
DUE="${FM_SOS_DUE:-+2w}"
GH="${FM_SOS_GH:-gh}"
CURL="${FM_SOS_CURL:-curl}"
TASKS="${FM_SOS_TASKS:-$BIN/fm-tasks-axi.sh}"
SPAWN="${FM_SOS_SPAWN:-$BIN/fm-spawn.sh}"
BRIEF="${FM_SOS_BRIEF:-$BIN/fm-brief.sh}"
WHEN="${FM_SOS_WHEN:-$BIN/fm-procevent-when.sh}"
RESOLVE="${FM_SOS_RESOLVE:-$BIN/fm-dispatch-resolve.sh}"

STATE_DIR="$FM_HOME/state"
CURSOR_FILE="$STATE_DIR/fm-sos-intake.cursor"
LEDGER="$STATE_DIR/fm-sos-intake.log"
INTAKE_LOCK="$STATE_DIR/.fm-sos-intake.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$BIN/fm-wake-lib.sh"

TRANSITIONS="dispatched repro-confirmed fix-up deployed verified captain-closed"

log_line() {
  mkdir -p "$STATE_DIR"
  printf '%s at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LEDGER"
}

ledger_has() {
  [ -f "$LEDGER" ] && grep -qF "$1" "$LEDGER"
}

# last_dispatch_class <key>: print the class of the key's latest dispatch-class
# ledger line (dispatch, dispatch-blocked, dispatch-skipped), or nothing when
# the key never reached a dispatch state.
last_dispatch_class() {
  local key="$1"
  [ -f "$LEDGER" ] || return 0
  awk -v k="key=$key" '
    ($1 == "dispatch" || $1 == "dispatch-blocked" || $1 == "dispatch-skipped") && $2 == k { c = $1 }
    END { if (c != "") print c }
  ' "$LEDGER"
}

# lock_intake: take the single-writer lock over the ledger and its guards for
# this process; the EXIT trap releases it on every path.
lock_intake() {
  mkdir -p "$STATE_DIR"
  fm_lock_acquire_wait "$INTAKE_LOCK" || die "cannot lock the intake"
  trap 'fm_lock_release "$INTAKE_LOCK" || true' EXIT
}

# redact_secrets: read text on stdin and print it as one line with
# credential-shaped substrings masked.
redact_secrets() {
  python3 -c '
import re, sys
text = " ".join(sys.stdin.read().split())
text = re.sub(r"\bgh[pousr]_[A-Za-z0-9]{16,}\b", "<redacted>", text)
text = re.sub(r"(?i)\b(token|secret|passwd|password|apikey|api_key|credential|authorization|bearer)\b[=: ]*\S*", r"\1=<redacted>", text)
text = re.sub(r"[A-Za-z0-9+/_=.]{32,}", "<redacted>", text)
sys.stdout.write(text)
'
}

die() {
  echo "error: $1" >&2
  exit 1
}

read_cursor() {
  local c=""
  [ -f "$CURSOR_FILE" ] && c=$(cat "$CURSOR_FILE" 2>/dev/null || echo "")
  case "$c" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$c" ;;
  esac
}

write_cursor() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$CURSOR_FILE"
}

# --- GitHub (issue state is read-only here; only comment ever writes) --------

gh_state() {
  # 0 = closed, 1 = open, 2 = could not tell (never treat as closed).
  local out
  if ! out=$("$GH" issue view "$1" --repo "$GH_REPO" --json state 2>/dev/null); then
    return 2
  fi
  local state
  state=$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("state", ""))
except Exception:
    print("")' 2>/dev/null || true)
  case "$state" in
    CLOSED) return 0 ;;
    OPEN) return 1 ;;
    *) return 2 ;;
  esac
}

gh_comment() {
  local issue="$1" body="$2"
  "$GH" issue comment "$issue" --repo "$GH_REPO" --body "$body" >/dev/null
}

gh_open_sos_issues() {
  # [{number,url,title,body}]; body is only parsed for the SOS ID marker and
  # never copied into task rows, briefs, or logs. Fails when GitHub cannot be
  # read, so an outage is never mistaken for an empty backlog.
  # ponytail: gh paginates internally up to --limit; raise it if the open SOS
  # backlog ever approaches 10000.
  "$GH" issue list --repo "$GH_REPO" --label sos --state open --limit 10000 \
    --json number,url,title,body 2>/dev/null
}

# --- task rows (beads on a beads backend) -----------------------------------
#
# The row id IS the idempotency key: `fm-sos-<SOS message UUID>`.
# tasks-axi's add is idempotent on the id and never reopens a closed row, so
# replay safety does not depend on any side table.

task_id_for_key() {
  printf 'fm-sos-%s\n' "$1"
}

# key_for_issue <issue> <derived-key>: print the key the ledger recorded for
# this issue, else the derived key when no record exists.
key_for_issue() {
  local issue="$1" derived="$2" known=""
  if [ -f "$LEDGER" ]; then
    known=$(awk -v want="$issue" \
      '$2 ~ /^key=/ && $3 == "issue=" want { print substr($2, 5); exit }' \
      "$LEDGER") || known=""
  fi
  printf '%s\n' "${known:-$derived}"
}

tasks_axi() {
  FM_HOME="$FM_HOME" "$TASKS" "$@"
}

# task_ensure <key> <issue> <url>: create the row if missing; prints
# new|existing|failed (a failed line carries tasks-axi's own diagnostic,
# redacted). A failed ensure leaves the ticket owed for the next pass (and
# the GH heal path), never silently skipped.
task_ensure() {
  local key="$1" issue="$2" url="$3" id short out errf detail
  id=$(task_id_for_key "$key")
  short="${key%%-*}"
  case "$key" in
    gh-issue-*) short="(no sos id)" ;;
  esac
  local -a args
  args=(
    add "$id" "SOS ticket $short - GH #$issue"
    --kind ship --repo portal --priority "$PRIORITY" --due "$DUE"
    --body "SOS key: $key
GitHub issue: ${url:-https://github.com/$GH_REPO/issues/$issue}
Site: see the GitHub issue (kept out of this graph on purpose).
The captain closes the GitHub issue after verification; the loop never does."
  )
  case "$PRIORITY" in
    0|1) args+=(--why "staff SOS report awaiting fix") ;;
  esac
  mkdir -p "$STATE_DIR"
  errf="$STATE_DIR/.fm-sos-intake.err"
  (umask 077; : >"$errf") || die "cannot stage the tasks-axi error capture"
  if ! out=$(tasks_axi "${args[@]}" --json 2>"$errf"); then
    detail=$(redact_secrets <"$errf" 2>/dev/null || true)
    rm -f "$errf"
    printf 'failed: %s\n' "${detail:-tasks-axi add failed with no diagnostic}"
    return 1
  fi
  if [ -s "$errf" ]; then
    printf '%s\n' "$(redact_secrets <"$errf")" >&2
  fi
  rm -f "$errf"
  case "$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    print("yes" if json.load(sys.stdin).get("already") else "no")
except Exception:
    print("?")' 2>/dev/null || echo "?")" in
    no) echo new ;;
    yes) echo existing ;;
    *) echo failed ;;
  esac
}

# --- candidate folding ------------------------------------------------------
# Prints one line per candidate: key<TAB>issue<TAB>url<TAB>event_id<TAB>listed
# No column is empty: an absent url or event id travels as "-".
# Keyed on the SOS message UUID when the body carries it; a sos-labeled issue
# with no marker still gets dispatched under a stable gh-issue-<n> key, because
# never dispatching a live ticket is worse than a non-UUID idempotency key.

collect_candidates_py() {
  local events_file="$1"
  local gh_file="$2"
  # shellcheck disable=SC2016  # single quotes are deliberate: the python script expands nothing.
  python3 -c '
import json, re, sys

try:
    events = json.load(open(sys.argv[1])).get("events", []) or []
except Exception:
    events = []
try:
    gh = json.load(open(sys.argv[2]))
    if not isinstance(gh, list):
        gh = []
except Exception:
    gh = []

SOS_ID_RE = re.compile(r"SOS ID:\**\s*`([0-9a-fA-F-]{8,64})`")
FALLBACK = "gh-issue-{}"

def norm(value):
    return str(value or "").strip().lower()

by_issue = {}
order = []

def ensure(issue, url, event_id, body_uuid="", event_key="", fallback="", listed=False):
    if not issue:
        return
    entry = by_issue.get(issue)
    if entry is None:
        entry = by_issue[issue] = {"body": "", "event": "", "fallback": "", "url": "", "event_id": "-", "listed": False}
        order.append(issue)
    for field, value in (("body", body_uuid), ("event", event_key), ("fallback", fallback)):
        if value and not entry[field]:
            entry[field] = value
    if url and not entry["url"]:
        entry["url"] = url
    if entry["event_id"] == "-" and event_id != "-":
        entry["event_id"] = event_id
    if listed:
        entry["listed"] = True

for ev in events:
    payload = ev.get("payload") or {}
    issue = payload.get("gh_issue")
    ensure(
        int(issue) if isinstance(issue, int) or (isinstance(issue, str) and str(issue).isdigit()) else None,
        str(payload.get("gh_issue_url") or ""),
        str(ev.get("id")),
        event_key=norm(ev.get("dedupeKey")),
    )

for item in gh:
    m = SOS_ID_RE.search(item.get("body") or "")
    ensure(
        int(item.get("number") or 0),
        str(item.get("url") or ""),
        "-",
        body_uuid=norm(m.group(1)) if m else "",
        fallback=FALLBACK.format(item.get("number")),
        listed=True,
    )

for issue in order:
    entry = by_issue[issue]
    key = entry["body"] or entry["event"] or entry["fallback"] or FALLBACK.format(issue)
    print("\t".join([key, str(issue), entry["url"] or "-", entry["event_id"], "open" if entry["listed"] else "-"]))
' "$events_file" "$gh_file"
}

# --- canonical comments -----------------------------------------------------

comment_body() {
  local transition="$1" key="$2" issue="$3" note="$4"
  local task_id="$5"
  case "$transition" in
    dispatched)
      # shellcheck disable=SC2016  # single quotes hold literal markdown backticks.
      printf ':robot: **SOS dispatch** - firstmate intake picked up ticket `%s` (task `%s`). Lifecycle comments (repro confirmed / fix up / deployed / verified) will follow on this issue. **The captain closes this issue after verification - the dispatch loop never closes it.**' "$key" "$task_id"
      ;;
    repro-confirmed)
      printf ':mag: **Repro confirmed** - %s' "${note:-reproduced end to end before any fix.}"
      ;;
    fix-up)
      printf ':wrench: **Fix up** - %s' "${note:-fix implemented with tests.}"
      ;;
    deployed)
      printf ':rocket: **Deployed** - %s' "${note:-fix deployed.}"
      ;;
    verified)
      printf ':white_check_mark: **Verified** - %s' "${note:-fix verified end to end. Awaiting captain close; this loop never closes the issue.}"
      ;;
    captain-closed)
      printf ':tada: **Closed by the captain** - verified and closed. Reporter notification: the reporter sees this resolution in their Portal ticket view.' ;;
    *)
      return 1 ;;
  esac
}

cmd_comment() {
  local issue="${1:-}" transition="${2:-}"
  shift 2 2>/dev/null || true
  local note="$*"
  [ -n "$issue" ] || die "comment requires <issue-number>"
  [ -n "$transition" ] || die "comment requires <transition: $TRANSITIONS>"
  case " $TRANSITIONS " in
    *" $transition "*) ;;
    *) die "unknown transition '$transition' (want one of: $TRANSITIONS)" ;;
  esac
  local key body
  lock_intake
  if ledger_has "issue=$issue transition=$transition"; then
    echo "already-commented: $issue $transition"
    return 0
  fi
  key=$(key_for_issue "$issue" "gh-issue-$issue")
  body=$(comment_body "$transition" "$key" "$issue" "$note" "$(task_id_for_key "$key")")
  [ -n "$body" ] || die "empty comment body"
  gh_comment "$issue" "$body"
  log_line "comment key=$key issue=$issue transition=$transition"
  echo "commented: $issue $transition"
}

# --- close watch ------------------------------------------------------------

# watch_verdicts <issue>: print the classify result of every captured verdict
# for this issue's close watch, one per line.
watch_verdicts() {
  local result status
  for result in "$STATE_DIR/procevent-inbox/when-sos-$1".*.result; do
    if [ -e "$result" ]; then
      status=$(FM_HOME="$FM_HOME" "$WHEN" classify "$result" 2>/dev/null) || status=unknown
      printf '%s\n' "$status"
    fi
  done
  return 0
}

# watch_blocks_rearm <issue>: this issue's close watch already captured an
# outcome whose run completed (fired, action-failed, never-true, ambiguous),
# so no new watch may be armed for it. A verdict from a run that died before
# completing (condition-error, rejected) still allows one.
watch_blocks_rearm() {
  watch_verdicts "$1" | grep -E '^(fired|action-failed|never-true|ambiguous)$' >/dev/null
}

# reopened_after_terminal <key> <issue>: the row is closed and this issue's
# close watch captured a fired verdict.
reopened_after_terminal() {
  local key="$1" issue="$2" state
  ledger_has "task-closed key=$key issue=$issue" || return 1
  state=$(tasks_axi show "$(task_id_for_key "$key")" 2>/dev/null | sed -n 's/^  state: //p' | head -1)
  [ "$state" = "done" ] || return 1
  watch_verdicts "$issue" | grep -x fired >/dev/null
}

cmd_watch_condition() {
  local issue="${1:-}"
  [ -n "$issue" ] || die "watch-condition requires <issue-number>"
  set +e
  gh_state "$issue"
  local rc=$?
  set -e
  exit "$rc"
}

cmd_watch_fire() {
  local issue="${1:-}" key="${2:-}"
  [ -n "$issue" ] || die "watch-fire requires <issue-number> <sos-key>"
  [ -n "$key" ] || die "watch-fire requires <sos-key>"
  lock_intake
  if ledger_has "closed key=$key issue=$issue"; then
    echo "already-closed-recorded: $issue"
    return 0
  fi
  if ! ledger_has "issue=$issue transition=captain-closed"; then
    gh_comment "$issue" "$(comment_body captain-closed "$key" "$issue" "" "")"
    log_line "comment key=$key issue=$issue transition=captain-closed"
  fi
  if tasks_axi "done" "$(task_id_for_key "$key")" \
      --note "captain verified and closed GitHub issue #$issue" >/dev/null 2>&1; then
    log_line "task-closed key=$key issue=$issue"
    # The handoff marker the reporter-notification leg reads: the close is now
    # known and announced on the issue the reporter's ticket view renders.
    log_line "closed key=$key issue=$issue"
    echo "captain-closed: $issue"
    return 0
  fi
  if tasks_axi show "$(task_id_for_key "$key")" >/dev/null 2>&1; then
    echo "failed: task row still open for key=$key; the close stays owed" >&2
  else
    echo "failed: task row for key=$key was not closed (row missing or backlog unavailable); the close stays owed" >&2
  fi
  return 1
}

# --- reconcile --------------------------------------------------------------

cmd_status() {
  local cursor
  cursor=$(read_cursor)
  echo "cursor: $cursor"
  echo "bridge: $BRIDGE_URL"
  echo "repo:   $GH_REPO"
  echo "ledger: $LEDGER"
  if [ -e "$AUTODISPATCH_GRANT" ]; then
    echo "autodispatch: granted ($AUTODISPATCH_GRANT)"
  else
    echo "autodispatch: not granted (create $AUTODISPATCH_GRANT to enable)"
  fi
  echo "sos task rows:"
  tasks_axi list 2>/dev/null | grep -E '^[[:space:]]+fm-sos-' || true
  echo "armed close watches:"
  local f name
  for f in "$STATE_DIR"/when/when-sos-*.spec; do
    if [ -e "$f" ]; then
      name=$(basename "$f" .spec)
      if [ -f "$STATE_DIR/procevent/$name.source" ]; then
        echo "  $name"
      fi
    fi
  done
  echo "reopened tickets:"
  grep -F "reopened key=" "$LEDGER" 2>/dev/null | sed 's/^/  /' || true
  echo "dispatch-blocked:"
  awk '
    $1 == "dispatch-blocked" || $1 == "dispatch-skipped" || ($1 == "dispatch" && $2 ~ /^key=/) {
      k = $2 SUBSEP $3
      last[k] = $1
      line[k] = $0
      dpos[k] = NR
      if (!(k in seen)) { order[++n] = k; seen[k] = 1 }
    }
    ($1 == "closed" || $1 == "task-closed") && $2 ~ /^key=/ {
      k = $2 SUBSEP $3
      tpos[k] = NR
      if (!(k in seen)) { order[++n] = k; seen[k] = 1 }
    }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (last[k] == "dispatch-blocked" && dpos[k] > tpos[k]) print "  " line[k]
      }
    }
  ' "$LEDGER" 2>/dev/null || true
}

cmd_reconcile() {
  local dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --mode) [ $# -ge 2 ] || die "--mode requires a value"; MODE="$2"; shift 2 ;;
      --yolo) [ $# -ge 2 ] || die "--yolo requires a value"; YOLO="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  lock_intake

  local cursor events_json gh_json sources_down=0 granted=0
  [ -e "$AUTODISPATCH_GRANT" ] && granted=1
  cursor=$(read_cursor)
  if ! events_json=$("$CURL" -fsS --max-time 10 \
    "$BRIDGE_URL/api/events?kind=sos&after=$cursor" 2>/dev/null); then
    echo "warn: SOS bridge unavailable at $BRIDGE_URL" >&2
    events_json='{"events":[]}'
    sources_down=$((sources_down + 1))
  fi
  if ! gh_json=$(gh_open_sos_issues); then
    echo "warn: cannot list open sos issues on $GH_REPO" >&2
    gh_json='[]'
    sources_down=$((sources_down + 1))
  fi
  [ "$sources_down" -lt 2 ] || die "reconcile: no SOS source reachable (bridge and GitHub both failed)"

  local candidates
  candidates=$(collect_candidates_py \
    <(printf '%s' "$events_json") \
    <(printf '%s' "$gh_json"))

  local new_cursor="$cursor" cursor_blocked=0 cursor_held=0
  local created=0 dispatched=0 ensured=0

  if [ -z "$candidates" ]; then
    echo "reconcile: no open SOS work (cursor=$cursor)"
    return 0
  fi

  local key issue url event_id listed issue_open reopened ensured_state state_rc held
  while IFS=$'\t' read -r key issue url event_id listed; do
    [ -n "$key" ] || continue
    [ -n "$issue" ] || { echo "skip: key=$key carries no GitHub issue" >&2; continue; }
    if [ "$url" = - ]; then
      url=""
    fi
    key=$(key_for_issue "$issue" "$key")

    if [ "$dry_run" -eq 1 ]; then
      if tasks_axi show "$(task_id_for_key "$key")" >/dev/null 2>&1; then
        echo "would-ensure: task $(task_id_for_key "$key") exists (GH #$issue)"
      else
        echo "would-create: task $(task_id_for_key "$key") (GH #$issue)"
      fi
      continue
    fi

    issue_open=1
    state_rc=1
    if [ "$listed" != open ]; then
      state_rc=0
      gh_state "$issue" || state_rc=$?
    fi
    if [ "$state_rc" -eq 2 ]; then
      # An unknown state is never read as open: the row and watch are still
      # ensured, but no comment or crewmate until the state is known.
      echo "failed: cannot read the state of #$issue; the ticket stays owed" >&2
      cursor_blocked=1
      issue_open=0
    elif [ "$state_rc" -eq 0 ]; then
      issue_open=0
      echo "skip: #$issue is closed; no dispatched comment or crewmate"
      if [ "$(last_dispatch_class "$key")" = dispatch-blocked ]; then
        log_line "dispatch-skipped key=$key issue=$issue reason=issue-closed"
        echo "dispatch-skipped key=$key issue=$issue reason=issue-closed"
      fi
    fi

    reopened=0
    if [ "$issue_open" -eq 1 ] && reopened_after_terminal "$key" "$issue"; then
      reopened=1
      if ! ledger_has "reopened key=$key issue=$issue"; then
        log_line "reopened key=$key issue=$issue"
        echo "reopened-after-terminal key=$key issue=$issue"
      fi
      if [ "$(last_dispatch_class "$key")" = dispatch-blocked ]; then
        log_line "dispatch-skipped key=$key issue=$issue reason=reopened-terminal"
        echo "dispatch-skipped key=$key issue=$issue reason=reopened-terminal"
      fi
    fi

    ensured_state=$(task_ensure "$key" "$issue" "$url") || ensured_state="${ensured_state:-failed}"
    case "$ensured_state" in
      failed*)
        echo "failed: task ensure sos:$key${ensured_state#failed}" >&2
        cursor_blocked=1
        ;;
      new)
        log_line "task key=$key issue=$issue task=$(task_id_for_key "$key")"
        created=$((created + 1))
        ensured=$((ensured + 1))
        ;;
      *)
        ensured=$((ensured + 1))
        ;;
    esac

    held=0
    if [ "$issue_open" -eq 1 ] && [ "$reopened" -eq 0 ] && [ "$granted" -eq 0 ] \
      && ! ledger_has "dispatch key=$key issue=$issue"; then
      echo "dispatch-held key=$key issue=$issue reason=autodispatch-not-granted"
      held=1
      # A held event stays owed: the bridge replays it once the grant lands,
      # even if the issue has since dropped out of the sos-labeled list.
      cursor_held=1
    fi

    if [ "$issue_open" -eq 1 ] && [ "$held" -eq 0 ] && ! ledger_has "issue=$issue transition=dispatched"; then
      gh_comment "$issue" "$(comment_body dispatched "$key" "$issue" "" "$(task_id_for_key "$key")")" \
        || { echo "failed: dispatched comment on #$issue" >&2; cursor_blocked=1; continue; }
      log_line "comment key=$key issue=$issue transition=dispatched"
    fi

    if [ ! -f "$STATE_DIR/procevent/when-sos-$issue.source" ] \
      && ! watch_blocks_rearm "$issue"; then
      if [ -e "$STATE_DIR/when/when-sos-$issue.spec" ] \
        || [ -e "$STATE_DIR/when/when-sos-$issue.trust" ] \
        || [ -e "$STATE_DIR/when/when-sos-$issue.fired" ]; then
        FM_HOME="$FM_HOME" "$WHEN" retire "sos-$issue" >/dev/null 2>&1 || true
      fi
      FM_HOME="$FM_HOME" "$WHEN" arm "sos-$issue" \
        --condition "$BIN/fm-sos-intake.sh" watch-condition "$issue" \
        --action "$BIN/fm-sos-intake.sh" watch-fire "$issue" "$key" >/dev/null \
        || { echo "failed: arm close watch for #$issue" >&2; cursor_blocked=1; continue; }
      log_line "watch key=$key issue=$issue"
    fi

    if [ "$issue_open" -eq 1 ] && [ "$reopened" -eq 0 ] && [ "$held" -eq 0 ] && ! ledger_has "dispatch key=$key issue=$issue"; then
      dispatch_ticket "$key" "$issue" || {
        echo "dispatch-blocked key=$key issue=$issue reason=${DISPATCH_BLOCKED_REASON:-failed}" >&2
        log_line "dispatch-blocked key=$key issue=$issue reason=${DISPATCH_BLOCKED_REASON:-failed}"
        cursor_blocked=1
        continue
      }
      dispatched=$((dispatched + 1))
    fi

    # The cursor may only advance through a contiguous prefix of handled
    # events: a candidate whose idempotent steps failed stays owed and is
    # retried on the next pass (the GH heal path covers it too).
    if [ "$event_id" != "-" ] && [ "$cursor_blocked" -eq 0 ] && [ "$cursor_held" -eq 0 ]; then
      new_cursor="$event_id"
    fi
  done <<< "$candidates"

  if [ "$dry_run" -eq 0 ] && [ "$new_cursor" != "$cursor" ]; then
    write_cursor "$new_cursor"
  fi
  echo "reconcile: ensured=$ensured task_created=$created dispatched=$dispatched cursor=$cursor->$new_cursor"
  if [ "$cursor_blocked" -ne 0 ]; then
    return 1
  fi
}

dispatch_ticket() {
  local key="$1" issue="$2"
  local task_id brief brief_mode resolve_out profile_line
  local -a profile_args=()
  DISPATCH_BLOCKED_REASON=""
  task_id=$(task_id_for_key "$key")
  brief="$FM_HOME/data/$task_id/brief.md"
  if [ -f "$brief" ]; then
    brief_mode=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
    if [ -n "$brief_mode" ] && [ "$brief_mode" != "$MODE" ]; then
      rm -f "$brief" || return 1
    fi
  fi
  if [ ! -f "$brief" ]; then
    FM_HOME="$FM_HOME" "$BRIEF" "$task_id" portal --mode "$MODE" >/dev/null || return 1
  fi
  fill_brief "$brief" "$key" "$issue" || return 1
  if [ -f "$FM_HOME/config/crew-dispatch.json" ]; then
    resolve_out=$("$RESOLVE" "$brief" --project portal 2>&1 || true)
    profile_line=$(printf '%s\n' "$resolve_out" | sed -n 's/^  profile: //p' | head -n 1)
    if [ -z "$profile_line" ]; then
      DISPATCH_BLOCKED_REASON=$(printf '%s\n' "$resolve_out" | sed -n 's/^  status: //p' | head -n 1)
      [ -n "$DISPATCH_BLOCKED_REASON" ] || DISPATCH_BLOCKED_REASON=resolver-off
      return 1
    fi
    if ! eval "profile_args=($profile_line)"; then
      DISPATCH_BLOCKED_REASON=profile-parse-failed
      return 1
    fi
    if [ "${#profile_args[@]}" -lt 2 ] || [ "${profile_args[0]}" != "--harness" ]; then
      DISPATCH_BLOCKED_REASON=profile-incomplete
      return 1
    fi
  fi
  FM_HOME="$FM_HOME" "$SPAWN" "$task_id" "$PROJECT_DIR" \
    ${profile_args[@]+"${profile_args[@]}"} --mode "$MODE" --yolo "$YOLO" >/dev/null \
    || { DISPATCH_BLOCKED_REASON=spawn-failed; return 1; }
  log_line "dispatch key=$key issue=$issue task=$task_id" || return 1
  echo "dispatched: $task_id (GH #$issue)"
}

fill_brief() {
  local brief="$1" key="$2" issue="$3"
  [ -f "$brief" ] || { echo "error: brief missing: $brief" >&2; return 1; }
  python3 - "$brief" "$key" "$issue" "$GH_REPO" <<'PY'
import sys

path, key, issue, repo = sys.argv[1:5]
text = open(path).read()
task = (
    "Resolve the staff SOS reported in {repo}#{issue} (ticket key `{key}`): "
    "reproduce the reported problem end to end before touching code, root-cause "
    "it, fix it, and validate the fix with the repo's canonical checks. Record "
    "each lifecycle transition as a comment on {repo}#{issue} as you go. The "
    "captain closes that issue after verification - never close it yourself."
).format(repo=repo, issue=issue, key=key)
spec = (
    "1. `gh issue view {issue} --repo {repo}` for the full report; the issue body "
    "is the working record (transcription and metadata) and may contain clinical "
    "speech - treat it as sensitive and keep it out of commits, logs, and task rows.\n"
    "2. Reproduce E2E first, aligned with how the reporter experienced it.\n"
    "3. Root-cause, fix, and add tests at the repo's usual bar.\n"
    "4. Post each transition comment from the repo root of the firstmate checkout "
    "with `bin/fm-sos-intake.sh comment {issue} repro-confirmed|fix-up|deployed|verified \"<one line>\"`.\n"
    "5. NEVER run `gh issue close` - the captain closes after verification. "
    "Do not comment states you have not reached.\n"
    "6. DoD: fix validated by the canonical checks, the transition comments that "
    "apply are posted on #{issue}, and the delivery contract is satisfied."
).format(issue=issue, repo=repo)
text = text.replace("{TASK}", task).replace("{FIRSTMATE_SPEC}", spec)
open(path, "w").write(text)
PY
}

# --- entry ------------------------------------------------------------------

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || die "usage: fm-sos-intake.sh reconcile|comment|watch-condition|watch-fire|status"
  shift || true
  case "$cmd" in
    reconcile) cmd_reconcile "$@" ;;
    comment) cmd_comment "$@" ;;
    watch-condition) cmd_watch_condition "$@" ;;
    watch-fire) cmd_watch_fire "$@" ;;
    status) cmd_status ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
