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
#   fm-sos-intake.sh reconcile [--no-dispatch] [--mode <m>] [--yolo on|off] [--dry-run]
#   fm-sos-intake.sh comment <issue-number> <transition> [note...]
#   fm-sos-intake.sh watch-condition <issue-number>
#   fm-sos-intake.sh watch-fire <issue-number> <sos-key>
#   fm-sos-intake.sh status
#
# reconcile     Idempotent intake pass. Pulls bridge events past the durable
#               cursor, folds in open sos-labeled GitHub issues (the heal
#               path), and per ticket: ensures the task row, posts the one
#               "dispatched" lifecycle comment, arms the close watch, and -
#               unless --no-dispatch - scaffolds the brief and spawns the
#               crewmate. The TASK ROW ID is the idempotency record: it is
#               exactly `sos-<SOS message UUID>`, and tasks-axi's add is
#               idempotent on the id, so a replayed event can never mint a
#               second row. The cursor is only a fast-path over the bridge.
#               Auto-dispatch is every SOS: there is no confidence gate, no
#               triage, and no hold. --mode/--yolo set the spawned task's
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
# FM_SOS_PRIORITY (default 1), FM_SOS_GH (gh command), FM_SOS_CURL (curl),
# FM_SOS_TASKS / FM_SOS_SPAWN / FM_SOS_BRIEF / FM_SOS_WHEN (the sibling
# firstmate commands, overridable so tests can substitute a stub).
#
# State (all under $FM_HOME/state/): fm-sos-intake.cursor (bridge event id),
# fm-sos-intake.log (append-only ledger of handled effects),
# when/when-sos-<n>.* (close watches).
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-/opt/ra/firstmate}"
BRIDGE_URL="${FM_SOS_BRIDGE_URL:-http://127.0.0.1:8791}"
GH_REPO="${FM_SOS_GH_REPO:-ArcsHealth/Portal}"
PROJECT_DIR="${FM_SOS_PROJECT:-$FM_HOME/projects/portal}"
MODE="${FM_SOS_MODE:-no-mistakes}"
YOLO="${FM_SOS_YOLO:-on}"
PRIORITY="${FM_SOS_PRIORITY:-1}"
GH="${FM_SOS_GH:-gh}"
CURL="${FM_SOS_CURL:-curl}"
TASKS="${FM_SOS_TASKS:-$BIN/fm-tasks-axi.sh}"
SPAWN="${FM_SOS_SPAWN:-$BIN/fm-spawn.sh}"
BRIEF="${FM_SOS_BRIEF:-$BIN/fm-brief.sh}"
WHEN="${FM_SOS_WHEN:-$BIN/fm-procevent-when.sh}"

STATE_DIR="$FM_HOME/state"
CURSOR_FILE="$STATE_DIR/fm-sos-intake.cursor"
LEDGER="$STATE_DIR/fm-sos-intake.log"

TRANSITIONS="dispatched repro-confirmed fix-up deployed verified captain-closed"

log_line() {
  mkdir -p "$STATE_DIR"
  printf '%s at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LEDGER"
}

ledger_has() {
  [ -f "$LEDGER" ] && grep -qF "$1" "$LEDGER"
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
  # never copied into task rows, briefs, or logs.
  "$GH" issue list --repo "$GH_REPO" --label sos --state open --limit 200 \
    --json number,url,title,body 2>/dev/null || echo "[]"
}

# --- task rows (beads on a beads backend) -----------------------------------
#
# The row id IS the idempotency key: `sos-<SOS message UUID>`.
# tasks-axi's add is idempotent on the id and never reopens a closed row, so
# replay safety does not depend on any side table.

task_id_for_key() {
  printf 'sos-%s\n' "$1"
}

tasks_axi() {
  FM_HOME="$FM_HOME" "$TASKS" "$@"
}

# task_ensure <key> <issue> <url>: create the row if missing; prints
# new|existing|failed. A failed ensure leaves the ticket owed for the next
# pass (and the GH heal path), never silently skipped.
task_ensure() {
  local key="$1" issue="$2" url="$3" id short out
  id=$(task_id_for_key "$key")
  short="${key%%-*}"
  case "$key" in
    gh-issue-*) short="(no sos id)" ;;
  esac
  local -a args
  args=(
    add "$id" "SOS ticket $short - GH #$issue"
    --kind ship --repo portal --priority "$PRIORITY"
    --body "SOS key: $key
GitHub issue: ${url:-https://github.com/$GH_REPO/issues/$issue}
Site: see the GitHub issue (kept out of this graph on purpose).
The captain closes the GitHub issue after verification; the loop never does."
  )
  case "$PRIORITY" in
    0|1) args+=(--why "staff SOS report awaiting fix") ;;
  esac
  if ! out=$(tasks_axi "${args[@]}" --json 2>/dev/null); then
    return 1
  fi
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

task_state() {
  tasks_axi show "$(task_id_for_key "$1")" 2>/dev/null \
    | sed -n 's/^  state: //p' | head -1
}

# --- candidate folding ------------------------------------------------------
# Prints one line per candidate: key<TAB>issue<TAB>url<TAB>event_id(or "-")
# Keyed on the SOS message UUID when the body carries it; a sos-labeled issue
# with no marker still gets dispatched under a stable gh-issue-<n> key, because
# never dispatching a live ticket is worse than a non-UUID idempotency key.

collect_candidates_py() {
  local events_json="$1"
  local gh_json="$2"
  # shellcheck disable=SC2016  # single quotes are deliberate: the python script expands nothing.
  python3 -c '
import json, re, sys

try:
    events = json.loads(sys.argv[1]).get("events", []) or []
except Exception:
    events = []
try:
    gh = json.loads(sys.argv[2]) if sys.argv[2] else []
except Exception:
    gh = []

SOS_ID_RE = re.compile(r"SOS ID:\**\s*`([0-9a-fA-F-]{8,64})`")
FALLBACK = "gh-issue-{}"

cands = {}
order = []

def ensure(key, issue, url, event_id):
    if not key or not issue:
        return
    if key not in cands:
        cands[key] = {"key": key, "issue": issue, "url": url, "event_id": event_id}
        order.append(key)
    else:
        c = cands[key]
        c["issue"] = c["issue"] or issue
        c["url"] = c["url"] or url
        if c["event_id"] == "-":
            c["event_id"] = event_id

for ev in events:
    payload = ev.get("payload") or {}
    issue = payload.get("gh_issue")
    ensure(
        str(ev.get("dedupeKey") or ""),
        int(issue) if isinstance(issue, int) or (isinstance(issue, str) and str(issue).isdigit()) else None,
        str(payload.get("gh_issue_url") or ""),
        str(ev.get("id")),
    )

for item in gh:
    body = item.get("body") or ""
    m = SOS_ID_RE.search(body)
    key = m.group(1).lower() if m else FALLBACK.format(item.get("number"))
    ensure(key, int(item.get("number") or 0), str(item.get("url") or ""), "-")

for k in order:
    c = cands[k]
    print("\t".join([c["key"], str(c["issue"]), c["url"], c["event_id"]]))
' "$events_json" "$gh_json"
}

# --- canonical comments -----------------------------------------------------

comment_body() {
  local transition="$1" key="$2" issue="$3" note="$4"
  local task_id="$5"
  case "$transition" in
    dispatched)
      # shellcheck disable=SC2016  # single quotes hold literal markdown backticks.
      printf ':robot: **SOS dispatch** - firstmate intake picked up ticket `%s` (task `%s`). Auto-dispatched to a crewmate; lifecycle comments (repro confirmed / fix up / deployed / verified) will follow on this issue. **The captain closes this issue after verification - the dispatch loop never closes it.**' "$key" "$task_id"
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
  key="gh-issue-$issue"
  body=$(comment_body "$transition" "$key" "$issue" "$note" "")
  [ -n "$body" ] || die "empty comment body"
  gh_comment "$issue" "$body"
  log_line "comment key=$key issue=$issue transition=$transition"
  echo "commented: $issue $transition"
}

# --- close watch ------------------------------------------------------------

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
  if ledger_has "closed key=$key issue=$issue"; then
    echo "already-closed-recorded: $issue"
    return 0
  fi
  gh_comment "$issue" "$(comment_body captain-closed "$key" "$issue" "" "")"
  log_line "comment key=$key issue=$issue transition=captain-closed"
  if ! tasks_axi "done" "$(task_id_for_key "$key")" \
      --note "captain verified and closed GitHub issue #$issue" >/dev/null 2>&1; then
    echo "warn: task row not closed for key=$key (may not exist)" >&2
  else
    log_line "task-closed key=$key issue=$issue"
  fi
  # The handoff marker the reporter-notification leg reads: the close is now
  # known and announced on the issue the reporter's ticket view renders.
  log_line "closed key=$key issue=$issue"
  echo "captain-closed: $issue"
}

# --- reconcile --------------------------------------------------------------

cmd_status() {
  local cursor
  cursor=$(read_cursor)
  echo "cursor: $cursor"
  echo "bridge: $BRIDGE_URL"
  echo "repo:   $GH_REPO"
  echo "ledger: $LEDGER"
  echo "sos task rows:"
  tasks_axi list 2>/dev/null | grep -E '^  sos-' || true
  echo "armed close watches:"
  local f
  for f in "$STATE_DIR"/when/when-sos-*.spec; do
    [ -e "$f" ] && echo "  $(basename "$f" .spec)"
  done
}

cmd_reconcile() {
  local do_dispatch=1 dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-dispatch) do_dispatch=0; shift ;;
      --dispatch) do_dispatch=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --mode) [ $# -ge 2 ] || die "--mode requires a value"; MODE="$2"; shift 2 ;;
      --yolo) [ $# -ge 2 ] || die "--yolo requires a value"; YOLO="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  local cursor events_json gh_json
  cursor=$(read_cursor)
  events_json=$("$CURL" -fsS --max-time 10 \
    "$BRIDGE_URL/api/events?kind=sos&after=$cursor" 2>/dev/null \
    || echo '{"events":[],"cursor":'"$cursor"',"backlog":-1}')
  gh_json=$(gh_open_sos_issues)

  local candidates
  candidates=$(collect_candidates_py "$events_json" "$gh_json")

  local new_cursor="$cursor" cursor_blocked=0
  local created=0 dispatched=0 ensured=0

  if [ -z "$candidates" ]; then
    echo "reconcile: no open SOS work (cursor=$cursor)"
    return 0
  fi

  local key issue url event_id ensured_state
  while IFS=$'\t' read -r key issue url event_id; do
    [ -n "$key" ] || continue
    [ -n "$issue" ] || { echo "skip: key=$key carries no GitHub issue" >&2; continue; }

    if [ "$dry_run" -eq 1 ]; then
      if tasks_axi show "$(task_id_for_key "$key")" >/dev/null 2>&1; then
        echo "would-ensure: task $(task_id_for_key "$key") exists (GH #$issue)"
      else
        echo "would-create: task $(task_id_for_key "$key") (GH #$issue)"
      fi
      continue
    fi

    ensured_state=$(task_ensure "$key" "$issue" "$url") || ensured_state=failed
    case "$ensured_state" in
      failed)
        echo "failed: task ensure sos:$key" >&2
        cursor_blocked=1
        continue
        ;;
      new)
        log_line "task key=$key issue=$issue task=$(task_id_for_key "$key")"
        created=$((created + 1))
        ;;
    esac
    ensured=$((ensured + 1))

    if ! ledger_has "comment key=$key issue=$issue transition=dispatched"; then
      gh_comment "$issue" "$(comment_body dispatched "$key" "$issue" "" "$(task_id_for_key "$key")")" \
        || { echo "failed: dispatched comment on #$issue" >&2; cursor_blocked=1; continue; }
      log_line "comment key=$key issue=$issue transition=dispatched"
    fi

    if [ ! -f "$STATE_DIR/when/when-sos-$issue.spec" ]; then
      FM_HOME="$FM_HOME" "$WHEN" arm "sos-$issue" \
        --condition "$BIN/fm-sos-intake.sh" watch-condition "$issue" \
        --action "$BIN/fm-sos-intake.sh" watch-fire "$issue" "$key" >/dev/null \
        || { echo "failed: arm close watch for #$issue" >&2; cursor_blocked=1; continue; }
      log_line "watch key=$key issue=$issue"
    fi

    if [ "$do_dispatch" -eq 1 ] && ! ledger_has "dispatch key=$key issue=$issue"; then
      dispatch_ticket "$key" "$issue" || { echo "failed: dispatch for #$issue" >&2; cursor_blocked=1; continue; }
      dispatched=$((dispatched + 1))
    fi

    # The cursor may only advance through a contiguous prefix of handled
    # events: a candidate whose idempotent steps failed stays owed and is
    # retried on the next pass (the GH heal path covers it too).
    if [ "$event_id" != "-" ] && [ "$cursor_blocked" -eq 0 ]; then
      new_cursor="$event_id"
    fi
  done <<< "$candidates"

  if [ "$dry_run" -eq 0 ] && [ "$new_cursor" != "$cursor" ]; then
    write_cursor "$new_cursor"
  fi
  echo "reconcile: ensured=$ensured task_created=$created dispatched=$dispatched cursor=$cursor->$new_cursor"
}

dispatch_ticket() {
  local key="$1" issue="$2"
  local task_id
  task_id=$(task_id_for_key "$key")
  if [ ! -f "$FM_HOME/data/$task_id/brief.md" ]; then
    FM_HOME="$FM_HOME" "$BRIEF" "$task_id" portal --mode "$MODE" >/dev/null
  fi
  fill_brief "$FM_HOME/data/$task_id/brief.md" "$key" "$issue"
  FM_HOME="$FM_HOME" "$SPAWN" "$task_id" "$PROJECT_DIR" \
    --mode "$MODE" --yolo "$YOLO" >/dev/null
  log_line "dispatch key=$key issue=$issue task=$task_id"
  echo "dispatched: $task_id (GH #$issue)"
}

fill_brief() {
  local brief="$1" key="$2" issue="$3"
  [ -f "$brief" ] || die "brief missing: $brief"
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
