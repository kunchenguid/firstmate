#!/usr/bin/env bash
# fm-issue-intake.sh - firstmate intake for the fleet issue dispatch loop.
#
# The loop: a producer (today Portal's SOS ticket firing one PHI-free event at
# stack-monitor's typed event bridge, POST /ingest/event kind=sos, dedupe_key =
# the SOS message UUID; tomorrow the catalog watcher in step 3) hands over an
# issue. This intake turns that event - or, as a heal for lost events and
# pre-bridge tickets, an open sos-labeled GitHub issue - into durable work: one
# task row (a bead on a beads backend) per ticket, one lifecycle comment on the
# GitHub issue, one close watch per issue, and one dispatched crewmate per new
# ticket. Every step is idempotent, so a retry, a replayed event, a lost cursor,
# or a re-armed consumer can never double-dispatch.
#
# Usage:
#   fm-issue-intake.sh reconcile [--no-dispatch] [--no-verdict] [--mode <m>] [--yolo on|off] [--dry-run]
#   fm-issue-intake.sh comment <issue-number> <transition> [note...]
#   fm-issue-intake.sh watch-condition <issue-number>
#   fm-issue-intake.sh watch-fire <issue-number> <sos-key>
#   fm-issue-intake.sh status
#
# reconcile     Idempotent intake pass. Pulls bridge events past the durable
#               cursor, folds in open sos-labeled GitHub issues (the heal
#               path), and per ticket: ensures the task row, arms the close
#               watch, and - unless --no-dispatch - posts the one
#               "dispatched" lifecycle comment, scaffolds the brief, and
#               spawns the crewmate, but only while the issue is still open:
#               a closed ticket gets no comment, no watch, and no spawn, and
#               a ticket with an earlier recorded close that GitHub no longer
#               confirms is held for the captain instead - never dispatched,
#               never declined. The TASK ROW ID is the idempotency record:
#               it is `fm-iss-<key>`, where `key` is the ticket's SOS message
#               UUID or `gh-issue-<n>` (legacy `fm-sos-` rows still resolve),
#               and tasks-axi's add is idempotent on the id, so a replayed
#               event can never mint a second row. The cursor is only a
#               fast-path over the bridge.
#               Every candidate passes the worth-supporting verdict gate
#               (`jev verdict`) first: supported_bug dispatches as below,
#               not_supported is declined and closed here (a ticket already
#               dispatched to a crewmate is reported for the captain instead
#               - work in flight is never declined or closed; a ticket the
#               captain already closed is left untouched (no decline comment,
#               no close)), captain_review
#               is held for the captain and never spawns. --no-verdict skips
#               new classification for an ops run; ledgered verdict and
#               decline decisions still bind. --mode/--yolo set the spawned task's
#               delivery contract (defaults FM_ISSUE_MODE=no-mistakes,
#               FM_ISSUE_YOLO=on); they are posture, not selection.
# comment       Post one canonical lifecycle comment on the GitHub issue.
#               Transitions: dispatched, declined, repro-confirmed, fix-up,
#               deployed, verified, captain-closed. Dispatched workers use
#               this at each transition so the reporter-facing thread reads
#               the same way for every ticket.
# watch-condition   Exit 0 iff the issue is CLOSED (for fm-procevent-when.sh).
#               Any GitHub failure exits 2: a failure is NEVER a close.
# watch-fire    The close watch's action: post the captain-closed comment,
#               close the task row (never the GitHub issue), and record the
#               reporter-notification handoff. Runs at most once per watch -
#               fm-procevent-when.sh claims a durable fired marker before the
#               action - and the ledger line makes manual re-runs safe too.
#
# THE LOOP CLOSES A GITHUB ISSUE ONLY FOR A NOT_SUPPORTED DECLINE, at intake.
# The captain closes every other issue after verification; watch-fire fires
# only because the captain already closed it.
#
# Backlog writes go through bin/fm-tasks-axi.sh like every other core script
# (fm-lint.sh's backend-purity check rejects direct Beads CLI calls in bin/),
# so a beads-configured home gets beads and a markdown home gets backlog rows.
#
# Env: FM_HOME (default /opt/ra/firstmate), FM_ISSUE_BRIDGE_URL (default
# http://127.0.0.1:8791), FM_ISSUE_GH_REPO (default ArcsHealth/Portal),
# FM_ISSUE_PROJECT (default $FM_HOME/projects/portal), FM_ISSUE_MODE, FM_ISSUE_YOLO,
# FM_ISSUE_PRIORITY (default 1), FM_ISSUE_GH (gh command), FM_ISSUE_CURL (curl),
# FM_ISSUE_TASKS / FM_ISSUE_SPAWN / FM_ISSUE_BRIEF / FM_ISSUE_WHEN (the sibling
# firstmate commands, overridable so tests can substitute a stub), FM_ISSUE_JEV
# (the `jev verdict` CLI, default `jev`), FM_ISSUE_INTENT (worth-supporting
# intent file passed as --intent-file, default $FM_HOME/data/issue-intent.md),
# FM_ISSUE_DECLINE_LABEL (default not-supported), FM_ISSUE_VERDICT (on|off;
# off makes every run behave like --no-verdict).
#
# State (all under $FM_HOME/state/): fm-issue-intake.cursor (bridge event id),
# fm-issue-intake.log (append-only ledger of handled effects),
# when/when-sos-<n>.* (close watches). The pre-rename fm-sos-intake.cursor and
# fm-sos-intake.log are adopted into these names once, so a deploy never
# resets the cursor or drops the ledger.
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-/opt/ra/firstmate}"
BRIDGE_URL="${FM_ISSUE_BRIDGE_URL:-http://127.0.0.1:8791}"
GH_REPO="${FM_ISSUE_GH_REPO:-ArcsHealth/Portal}"
PROJECT_DIR="${FM_ISSUE_PROJECT:-$FM_HOME/projects/portal}"
MODE="${FM_ISSUE_MODE:-no-mistakes}"
YOLO="${FM_ISSUE_YOLO:-on}"
PRIORITY="${FM_ISSUE_PRIORITY:-1}"
GH="${FM_ISSUE_GH:-gh}"
CURL="${FM_ISSUE_CURL:-curl}"
TASKS="${FM_ISSUE_TASKS:-$BIN/fm-tasks-axi.sh}"
SPAWN="${FM_ISSUE_SPAWN:-$BIN/fm-spawn.sh}"
BRIEF="${FM_ISSUE_BRIEF:-$BIN/fm-brief.sh}"
WHEN="${FM_ISSUE_WHEN:-$BIN/fm-procevent-when.sh}"
JEV="${FM_ISSUE_JEV:-jev}"
INTENT="${FM_ISSUE_INTENT:-$FM_HOME/data/issue-intent.md}"
DECLINE_LABEL="${FM_ISSUE_DECLINE_LABEL:-not-supported}"
VERDICT="${FM_ISSUE_VERDICT:-on}"

STATE_DIR="$FM_HOME/state"
CURSOR_FILE="$STATE_DIR/fm-issue-intake.cursor"
LEDGER="$STATE_DIR/fm-issue-intake.log"

# The rename kept the same bytes: adopt pre-rename state once, so a deploy
# never resets the cursor (replay) or drops the ledger (duplicate comments).
for legacy_part in cursor log; do
  if [ -f "$STATE_DIR/fm-sos-intake.$legacy_part" ] && [ ! -f "$STATE_DIR/fm-issue-intake.$legacy_part" ]; then
    mv "$STATE_DIR/fm-sos-intake.$legacy_part" "$STATE_DIR/fm-issue-intake.$legacy_part" || true
  fi
done

TRANSITIONS="dispatched declined repro-confirmed fix-up deployed verified captain-closed"

log_line() {
  mkdir -p "$STATE_DIR"
  printf '%s at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LEDGER"
}

ledger_recorded() {  # <record pattern> -> 0 iff a ledger line matches ^<pattern> at=
  [ -f "$LEDGER" ] && grep -qE "^$1 at=" "$LEDGER"
}

task_key_for_issue() {  # <issue> -> the key first ledgered for this issue, else empty
  [ -f "$LEDGER" ] || return 0
  sed -n "s/^task key=\([^ ]*\) issue=$1 task=[^ ]* at=.*$/\1/p" "$LEDGER" | head -1
}

dispatch_recorded() {  # <issue> -> 0 iff the ledger shows the ticket already went out
  ledger_recorded "dispatch key=[^ ]* issue=$1( task=[^ ]*)?" \
    || ledger_recorded "comment key=[^ ]* issue=$1 transition=dispatched"
}

captain_closed_recorded() {  # <issue> -> 0 iff the loop announced the captain's close
  ledger_recorded "closed key=[^ ]* issue=$1" \
    || ledger_recorded "comment key=[^ ]* issue=$1 transition=captain-closed"
}

closed_reason_for() {  # <issue> -> why the issue is closed, "reopened" when a close is recorded but GitHub reports it open, "unknown" when GitHub cannot tell, else empty
  local rc=0
  gh_state "$1" || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf '%s\n' "unknown"
  elif captain_closed_recorded "$1"; then
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "the captain already closed it"
    else
      printf '%s\n' "reopened"
    fi
  elif [ "$rc" -eq 0 ]; then
    printf '%s\n' "GitHub reports it closed"
  fi
  return 0
}

issue_for_task_key() {  # <key> -> the issue first ledgered for this key, else empty
  [ -f "$LEDGER" ] || return 0
  sed -n "s/^task key=$1 issue=\([0-9]*\) task=[^ ]* at=.*$/\1/p" "$LEDGER" | head -1
}

close_task_row() {  # <key> <issue> <note> -> 0 once the row close is ledgered
  ledger_recorded "task-closed key=[^ ]* issue=$2" && return 0
  if ! tasks_axi "done" "$(task_id_for_key "$1")" --note "$3" >/dev/null 2>&1; then
    echo "warn: task row not closed for key=$1" >&2
    return 1
  fi
  log_line "task-closed key=$1 issue=$2"
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
# The row id IS the idempotency key: `fm-iss-<key>`; the candidate-folding
# section below owns how `key` is derived. Rows minted before the rename stay
# authoritative: resolve to `fm-sos-<key>` when it exists so a rename can never
# split one ticket across two rows.
task_id_for_key() {
  local legacy="fm-sos-$1"
  if tasks_axi show "$legacy" >/dev/null 2>&1; then
    printf '%s\n' "$legacy"
    return
  fi
  printf 'fm-iss-%s\n' "$1"
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
The captain closes the GitHub issue after verification; dispatch never closes it - only a not-supported decline does."
  )
  case "$PRIORITY" in
    0|1) args+=(--why "staff SOS report awaiting fix") ;;
  esac
  if ! out=$(tasks_axi "${args[@]}" --json 2>/dev/null); then
    # The published tasks-axi (npm 0.2.6, what CI installs) has no --why; the
    # fleet fork does. A metadata flag must never cost a ticket its row, so
    # retry once without it before giving up.
    local -a retry=()
    local skip=0 a
    for a in "${args[@]}"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      if [ "$a" = "--why" ]; then skip=1; continue; fi
      retry+=("$a")
    done
    if [ ${#retry[@]} -eq ${#args[@]} ]; then
      return 1
    fi
    out=$(tasks_axi "${retry[@]}" --json 2>/dev/null) || return 1
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

# --- candidate folding ------------------------------------------------------
# Prints one line per candidate: key<TAB>issue<TAB>url<TAB>event_id(or "-")
# One line per GitHub issue: keyed on the SOS message UUID when the body
# carries it and no other issue already owns that marker, else on the stable
# gh-issue-<n> identity (markerless and marker-sharing issues alike), because
# never dispatching a live ticket is worse than a non-UUID idempotency key.

collect_candidates_py() {  # <events-json> <gh-json>; never fails the caller
  # events_file/gh_file stay global (this function runs in a command-
  # substitution subshell) so the single-quoted EXIT trap still finds them in
  # scope when it fires at subshell exit.
  local events_json="$1" gh_json="$2" folded
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if ! events_file=$(umask 077; mktemp "$STATE_DIR/.cand-events.XXXXXX" 2>/dev/null); then
    echo "warn: could not stage candidate payloads; treating backlog as empty" >&2
    return 0
  fi
  if ! gh_file=$(umask 077; mktemp "$STATE_DIR/.cand-gh.XXXXXX" 2>/dev/null); then
    rm -f -- "$events_file"
    echo "warn: could not stage candidate payloads; treating backlog as empty" >&2
    return 0
  fi
  trap 'rm -f -- "$events_file" "$gh_file"' EXIT
  if ! printf '%s' "$events_json" > "$events_file" || ! printf '%s' "$gh_json" > "$gh_file"; then
    rm -f -- "$events_file" "$gh_file"
    echo "warn: could not stage candidate payloads; treating backlog as empty" >&2
    return 0
  fi
  # shellcheck disable=SC2016  # single quotes are deliberate: the python script expands nothing.
  if ! folded=$(python3 -c '
import json, re, sys

def load(path, what):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        print("warn: unreadable %s payload: %s" % (what, path), file=sys.stderr)
        return None

ev_doc = load(sys.argv[1], "bridge-events")
gh_doc = load(sys.argv[2], "github-issues")
events = ev_doc.get("events") if isinstance(ev_doc, dict) else None
if not isinstance(events, list):
    events = []
gh = gh_doc if isinstance(gh_doc, list) else []

SOS_ID_RE = re.compile(r"SOS ID:\**\s*`([0-9a-fA-F-]{8,64})`")
FALLBACK = "gh-issue-{}"
KEY_OK = re.compile(r"(?:[0-9a-f-]{8,64}|gh-issue-[0-9]+)")

cands = {}
order = []
key_owner = {}

def norm_key(key, issue):
    key = str(key or "").strip().lower()
    if KEY_OK.fullmatch(key):
        return key
    fallback = FALLBACK.format(issue)
    print("warn: malformed dedupe key %r for GH #%s; using %s"
          % (key, issue, fallback), file=sys.stderr)
    return fallback

def event_id_of(ev):
    eid = str(ev.get("id"))
    if not eid.isdigit():
        print("warn: non-numeric event id %r; cursor will not advance on it"
              % eid, file=sys.stderr)
        return "-"
    return eid

def ensure(key, issue, url, event_id):
    if not issue:
        return
    key = norm_key(key, issue)
    if issue in cands:
        c = cands[issue]
        c["url"] = c["url"] or url
        if c["event_id"] == "-":
            c["event_id"] = event_id
        return
    if key in key_owner:
        print("warn: GH #%s shares dedupe key %r with GH #%s; keeping the per-issue identity"
              % (issue, key, key_owner[key]), file=sys.stderr)
        key = FALLBACK.format(issue)
    key_owner[key] = issue
    cands[issue] = {"key": key, "issue": issue, "url": url, "event_id": event_id}
    order.append(issue)

for ev in events:
    if not isinstance(ev, dict):
        continue
    payload = ev.get("payload") or {}
    if not isinstance(payload, dict):
        payload = {}
    issue = payload.get("gh_issue")
    ensure(
        ev.get("dedupeKey") or "",
        int(issue) if isinstance(issue, int) or (isinstance(issue, str) and str(issue).isdigit()) else None,
        str(payload.get("gh_issue_url") or ""),
        event_id_of(ev),
    )

for item in gh:
    if not isinstance(item, dict):
        continue
    body = item.get("body")
    body = body if isinstance(body, str) else ""
    m = SOS_ID_RE.search(body)
    key = m.group(1) if m else FALLBACK.format(item.get("number"))
    try:
        number = int(item.get("number") or 0)
    except (TypeError, ValueError):
        continue
    ensure(key, number, str(item.get("url") or ""), "-")

for k in order:
    c = cands[k]
    print("\t".join([c["key"], str(c["issue"]), c["url"] or "-", c["event_id"]]))
' "$events_file" "$gh_file"); then
    echo "warn: candidate folding failed; treating backlog as empty" >&2
    return 0
  fi
  if [ -n "$folded" ]; then printf '%s\n' "$folded"; fi
  return 0
}

# --- canonical comments -----------------------------------------------------

comment_body() {
  local transition="$1" key="$2" issue="$3" note="$4"
  local task_id="$5"
  case "$transition" in
    dispatched)
      # shellcheck disable=SC2016  # single quotes hold literal markdown backticks.
      printf ':robot: **Issue intake** - firstmate intake picked up ticket `%s` (task `%s`). Auto-dispatched to a crewmate; lifecycle comments (repro confirmed / fix up / deployed / verified) will follow on this issue. **The captain closes this issue after verification - the dispatch loop never closes it.**' "$key" "$task_id"
      ;;
    declined)
      # shellcheck disable=SC2016  # single quotes hold literal markdown backticks.
      printf ':information_source: **Not supported** - thanks for the report. This is working as designed and is outside what Portal intends to support, so we are closing it instead of changing the product. If it is actually breaking something for you, reply here and we will reopen it.' ;;
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
  key=$(task_key_for_issue "$issue")
  if [ -z "$key" ]; then key="gh-issue-$issue"; fi
  body=$(comment_body "$transition" "$key" "$issue" "$note" "$(task_id_for_key "$key")")
  [ -n "$body" ] || die "empty comment body"
  gh_comment "$issue" "$body"
  log_line "comment key=$key issue=$issue transition=$transition"
  echo "commented: $issue $transition"
}

# --- worth-supporting verdict ----------------------------------------------
#
# `jev verdict` answers supported_bug | not_supported | captain_review against
# the product's stated intent. It fails open: any model, transport, or
# confidence failure already comes back as captain_review, so a broken
# classifier can never decline or dispatch on its own. The verdict is ledgered
# per key, so a replay never re-decides a ticket.

verdict_recorded() {  # <issue> -> the ledgered verdict, or empty
  [ -f "$LEDGER" ] || return 0
  sed -n "s/^verdict key=[^ ]* issue=$1 verdict=\([a-z_]*\) at=.*/\1/p" "$LEDGER" | tail -1
}

classify_issue() {  # <issue> -> verdict on stdout, or "unread" when the report could not be read; never fails
  local issue="$1" out parsed title="" body="" labels=""
  # A report that cannot be read is never judged: an empty title/body could
  # still come back declinable or dispatchable.
  if ! out=$("$GH" issue view "$issue" --repo "$GH_REPO" --json title,body,labels 2>/dev/null) \
      || ! parsed=$(printf '%s' "$out" | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(" ".join((d.get("title") or "").split()))
print(" ".join((d.get("body") or "").split()))
print(",".join(
    (x.get("name", "") if isinstance(x, dict) else str(x))
    for x in (d.get("labels") or [])
))' 2>/dev/null); then
    echo unread
    return 0
  fi
  title=$(printf '%s\n' "$parsed" | sed -n 1p)
  body=$(printf '%s\n' "$parsed" | sed -n 2p)
  labels=$(printf '%s\n' "$parsed" | sed -n 3p)
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  # body_file stays global (this function runs in a command-substitution
  # subshell) so the single-quoted EXIT trap still finds it in scope when it
  # fires at subshell exit.
  if ! body_file=$(umask 077; mktemp "$STATE_DIR/.issue-body.XXXXXX" 2>/dev/null); then
    echo captain_review
    return 0
  fi
  trap 'rm -f -- "$body_file"' EXIT
  printf '%s' "$body" > "$body_file"
  local -a vargs=(verdict --repo "$GH_REPO" --issue "$issue" --title "$title"
                  --body-file "$body_file" --labels "$labels" --json)
  if [ -f "$INTENT" ]; then
    vargs+=(--intent-file "$INTENT")
  fi
  out=$("$JEV" "${vargs[@]}" 2>/dev/null || true)
  printf '%s' "$out" \
    | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("verdict") or "captain_review")
except Exception:
    print("captain_review")' 2>/dev/null || echo captain_review
}

apply_decline() {  # <key> <issue> -> 0 only when the whole decline landed
  local key="$1" issue="$2"
  # Decline order: retire -> comment -> label (best-effort) -> close -> row close, then the
  # caller writes the declined record. The watch must be retired before the
  # close it watches for, so this close can never wake a watcher into posting
  # a captain-closed comment for a decline.
  if [ -f "$STATE_DIR/when/when-sos-$issue.spec" ]; then
    if ! FM_HOME="$FM_HOME" "$WHEN" retire "sos-$issue" >/dev/null; then
      echo "warn: failed to retire close watch for #$issue" >&2
      return 1
    fi
  fi
  if ! ledger_recorded "comment key=[^ ]* issue=$issue transition=declined"; then
    gh_comment "$issue" "$(comment_body declined "$key" "$issue" "" "$(task_id_for_key "$key")")" \
      || return 1
    log_line "comment key=$key issue=$issue transition=declined"
  fi
  "$GH" issue edit "$issue" --repo "$GH_REPO" --add-label "$DECLINE_LABEL" >/dev/null 2>&1 \
    || echo "warn: could not add label $DECLINE_LABEL to $GH_REPO#$issue; decline continues" >&2
  "$GH" issue close "$issue" --repo "$GH_REPO" >/dev/null 2>&1 || return 1
  close_task_row "$key" "$issue" "declined: not supported by design (GitHub issue #$issue)"
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
  if ledger_recorded "declined key=[^ ]* issue=$issue"; then
    echo "declined-recorded: $issue"
    return 0
  fi
  if ledger_recorded "closed key=[^ ]* issue=$issue"; then
    echo "already-closed-recorded: $issue"
    return 0
  fi
  if ! ledger_recorded "comment key=[^ ]* issue=$issue transition=captain-closed"; then
    gh_comment "$issue" "$(comment_body captain-closed "$key" "$issue" "" "")"
    log_line "comment key=$key issue=$issue transition=captain-closed"
  fi
  if ! tasks_axi "done" "$(task_id_for_key "$key")" \
      --note "captain verified and closed GitHub issue #$issue" >/dev/null 2>&1; then
    echo "warn: task row not closed for key=$key (may not exist)" >&2
  else
    log_line "task-closed key=$key issue=$issue"
  fi
  # The handoff marker the reporter-notification leg reads: the close is now
  # known and announced on the issue the reporter's ticket view renders.
  log_line "closed key=$key issue=$issue"
  # The state read runs after the records and is diagnostic only: the watch
  # fired because its condition saw CLOSED, and the when runner has already
  # claimed the terminal fired marker, so gating on an unreadable state would
  # lose the close for good. A reopen between the condition and this action is
  # covered by reconcile, which reports a close record over an open issue as
  # captain_review on the next pass.
  local state_rc=0
  gh_state "$issue" || state_rc=$?
  case "$state_rc" in
    1) echo "reopened-after-close: GH #$issue is open again; close recorded, next reconcile holds it for captain_review" ;;
    2) echo "warn: GH #$issue state unreadable after recording the close" >&2 ;;
  esac
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
  tasks_axi list 2>/dev/null | grep -E '^  (fm-)?(sos|iss)-' || true
  echo "armed close watches:"
  local f
  for f in "$STATE_DIR"/when/when-sos-*.spec; do
    [ -e "$f" ] && echo "  $(basename "$f" .spec)"
  done
}

cmd_reconcile() {
  local do_dispatch=1 dry_run=0 do_verdict=1
  if [ "$VERDICT" = "off" ]; then do_verdict=0; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-dispatch) do_dispatch=0; shift ;;
      --no-verdict) do_verdict=0; shift ;;
      --dry-run) dry_run=1; shift ;;
      --mode) [ $# -ge 2 ] || die "--mode requires a value"; MODE="$2"; shift 2 ;;
      --yolo) [ $# -ge 2 ] || die "--yolo requires a value"; YOLO="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  # One pass at a time: the dispatch record is written after the spawn, so two
  # overlapping passes (periodic + SOS wake) could both spawn one ticket.
  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$STATE_DIR" . "$BIN/fm-wake-lib.sh"
  mkdir -p "$STATE_DIR"
  RECONCILE_LOCK="$STATE_DIR/.fm-issue-intake.lock"
  if ! fm_lock_try_acquire "$RECONCILE_LOCK"; then
    echo "reconcile: another pass holds $RECONCILE_LOCK; skipping"
    return 0
  fi
  trap 'fm_lock_release "$RECONCILE_LOCK" 2>/dev/null || true' EXIT

  local cursor events_json gh_json
  cursor=$(read_cursor)
  events_json=$("$CURL" -fsS --max-time 10 \
    "$BRIDGE_URL/api/events?kind=sos&after=$cursor" 2>/dev/null \
    || echo '{"events":[],"cursor":'"$cursor"',"backlog":-1}')
  gh_json=$(gh_open_sos_issues)

  local candidates
  if ! candidates=$(collect_candidates_py "$events_json" "$gh_json"); then
    echo "warn: candidate collection failed; treating backlog as empty" >&2
    candidates=""
  fi

  local new_cursor="$cursor" cursor_blocked=0
  local created=0 dispatched=0 ensured=0 declined=0 review=0

  if [ -z "$candidates" ]; then
    echo "reconcile: no open SOS work (cursor=$cursor)"
    return 0
  fi

  local key issue url event_id ensured_state verdict watch_spec canonical_key owner reopened new_work closed_reason handled close_note
  while IFS=$'\t' read -r key issue url event_id; do
    [ -n "$key" ] || continue
    [ -n "$issue" ] || { echo "skip: key=$key carries no GitHub issue" >&2; continue; }
    if [ "$url" = "-" ]; then url=""; fi
    canonical_key=$(task_key_for_issue "$issue")
    if [ -n "$canonical_key" ]; then
      key="$canonical_key"
    else
      owner=$(issue_for_task_key "$key")
      if [ -n "$owner" ] && [ "$owner" != "$issue" ]; then
        echo "warn: key=$key already bound to GH #$owner; GH #$issue keeps its own row" >&2
        key="gh-issue-$issue"
      fi
    fi

    if [ "$dry_run" -eq 1 ]; then
      if tasks_axi show "$(task_id_for_key "$key")" >/dev/null 2>&1; then
        echo "would-ensure: task $(task_id_for_key "$key") exists (GH #$issue)"
      else
        echo "would-create: task $(task_id_for_key "$key") (GH #$issue)"
      fi
      continue
    fi

    watch_spec="$STATE_DIR/when/when-sos-$issue.spec"
    if [ -f "$watch_spec" ] && grep -q "fm-sos-intake.sh" "$watch_spec"; then
      if ! FM_HOME="$FM_HOME" "$WHEN" retire "sos-$issue" >/dev/null; then
        echo "failed: retire pre-rename watch for #$issue" >&2
        cursor_blocked=1
        continue
      fi
    fi

    if [ -f "$watch_spec" ] && [ -f "${watch_spec%.spec}.fired" ]; then
      FM_HOME="$FM_HOME" "$WHEN" retire "sos-$issue" >/dev/null 2>&1 \
        || echo "warn: fired close watch for #$issue not retired yet; handle its wake first" >&2
    fi

    ensured_state=$(task_ensure "$key" "$issue" "$url") || ensured_state=failed
    case "$ensured_state" in
      failed)
        echo "failed: task ensure sos:$key" >&2
        cursor_blocked=1
        continue
        ;;
      new)
        created=$((created + 1))
        ;;
    esac
    ensured=$((ensured + 1))
    if [ -z "$(task_key_for_issue "$issue")" ]; then
      log_line "task key=$key issue=$issue task=$(task_id_for_key "$key")"
    fi

    # Worth-supporting gate: decide once, act once, never re-decide on replay.
    verdict=$(verdict_recorded "$issue")
    if [ -z "$verdict" ] && [ "$do_verdict" -eq 1 ]; then
      verdict=$(classify_issue "$issue")
      case "$verdict" in
        unread)
          echo "failed: could not read GH #$issue; verdict deferred" >&2
          cursor_blocked=1
          continue
          ;;
        supported_bug|not_supported|captain_review) ;;
        *) verdict=captain_review ;;
      esac
      log_line "verdict key=$key issue=$issue verdict=$verdict"
    fi
    # A decided ticket (declined or held) is handled: the cursor moves past
    # it, or one ambiguous ticket would wedge every later event. The GH heal
    # path keeps re-offering it as an open issue anyway.
    reopened=0
    handled=0
    if [ "$verdict" = "not_supported" ]; then
      if ledger_recorded "declined key=[^ ]* issue=$issue"; then
        if gh_state "$issue"; then
          declined=$((declined + 1))
          handled=1
        else
          reopened=1
        fi
      else
        closed_reason=$(closed_reason_for "$issue")
        if [ "$closed_reason" = "unknown" ]; then
          echo "failed: GitHub state unknown for #$issue; retried next pass" >&2
          cursor_blocked=1
          continue
        elif [ "$closed_reason" = "reopened" ]; then
          reopened=1
        elif [ -n "$closed_reason" ]; then
          echo "already-closed: key=$key GH #$issue $closed_reason; the not_supported verdict is not applied"
          close_task_row "$key" "$issue" "issue #$issue already closed at intake; no dispatch" \
            || { cursor_blocked=1; continue; }
          handled=1
        elif dispatch_recorded "$issue"; then
          review=$((review + 1))
          echo "review: key=$key GH #$issue already dispatched to a crewmate; verdict says not_supported - captain decides"
          handled=1
        else
          apply_decline "$key" "$issue" \
            || { echo "failed: decline for #$issue" >&2; cursor_blocked=1; continue; }
          log_line "declined key=$key issue=$issue"
          declined=$((declined + 1))
          handled=1
        fi
      fi
    fi
    if [ "$handled" -eq 0 ] && { [ "$verdict" = "captain_review" ] || [ "$reopened" -eq 1 ]; }; then
      review=$((review + 1))
      echo "review: key=$key GH #$issue held for the captain (no dispatch)"
      handled=1
    fi

    if [ "$handled" -eq 0 ]; then
      new_work=0
      if [ ! -f "$watch_spec" ] || [ -f "${watch_spec%.spec}.fired" ]; then new_work=1; fi
      if [ "$do_dispatch" -eq 1 ]; then
        if ! ledger_recorded "comment key=[^ ]* issue=$issue transition=dispatched"; then new_work=1; fi
        if ! ledger_recorded "dispatch key=[^ ]* issue=$issue( task=[^ ]*)?"; then new_work=1; fi
      fi
      if [ "$new_work" -eq 1 ]; then
        closed_reason=$(closed_reason_for "$issue")
        if [ "$closed_reason" = "unknown" ]; then
          echo "failed: GitHub state unknown for #$issue; spawn deferred" >&2
          cursor_blocked=1
          continue
        elif [ "$closed_reason" = "reopened" ]; then
          review=$((review + 1))
          echo "review: key=$key GH #$issue closed earlier and open again - held for the captain (no dispatch)"
          handled=1
        elif [ -n "$closed_reason" ]; then
          echo "skip: GH #$issue already closed - spawn skipped ($closed_reason)"
          if dispatch_recorded "$issue"; then
            close_note="issue #$issue already closed after dispatch; closing the row"
          else
            close_note="issue #$issue already closed at intake; no dispatch"
          fi
          close_task_row "$key" "$issue" "$close_note" || { cursor_blocked=1; continue; }
          handled=1
        fi
      fi
    fi

    if [ "$handled" -eq 0 ]; then
      if [ "$do_dispatch" -eq 1 ] && ! ledger_recorded "comment key=[^ ]* issue=$issue transition=dispatched"; then
        gh_comment "$issue" "$(comment_body dispatched "$key" "$issue" "" "$(task_id_for_key "$key")")" \
          || { echo "failed: dispatched comment on #$issue" >&2; cursor_blocked=1; continue; }
        log_line "comment key=$key issue=$issue transition=dispatched"
      fi

      if [ ! -f "$watch_spec" ]; then
        FM_HOME="$FM_HOME" "$WHEN" arm "sos-$issue" \
          --condition "$BIN/fm-issue-intake.sh" watch-condition "$issue" \
          --action "$BIN/fm-issue-intake.sh" watch-fire "$issue" "$key" >/dev/null \
          || { echo "failed: arm close watch for #$issue" >&2; cursor_blocked=1; continue; }
        log_line "watch key=$key issue=$issue"
      fi

      if [ "$do_dispatch" -eq 1 ] && ! ledger_recorded "dispatch key=[^ ]* issue=$issue( task=[^ ]*)?"; then
        dispatch_ticket "$key" "$issue" || { echo "failed: dispatch for #$issue" >&2; cursor_blocked=1; continue; }
        dispatched=$((dispatched + 1))
      fi
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
  echo "reconcile: ensured=$ensured task_created=$created dispatched=$dispatched declined=$declined review=$review cursor=$cursor->$new_cursor"
}

dispatch_ticket() {
  local key="$1" issue="$2"
  local task_id
  task_id=$(task_id_for_key "$key")
  if [ ! -f "$FM_HOME/data/$task_id/brief.md" ]; then
    FM_HOME="$FM_HOME" "$BRIEF" "$task_id" portal --mode "$MODE" >/dev/null || return 1
  fi
  fill_brief "$FM_HOME/data/$task_id/brief.md" "$key" "$issue" || return 1
  FM_HOME="$FM_HOME" "$SPAWN" "$task_id" "$PROJECT_DIR" \
    --mode "$MODE" --yolo "$YOLO" >/dev/null || return 1
  log_line "dispatch key=$key issue=$issue"
  echo "dispatched: $task_id (GH #$issue)"
}

fill_brief() {
  local brief="$1" key="$2" issue="$3"
  [ -f "$brief" ] || return 1
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
    "with `bin/fm-issue-intake.sh comment {issue} repro-confirmed|fix-up|deployed|verified \"<one line>\"`.\n"
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
  [ -n "$cmd" ] || die "usage: fm-issue-intake.sh reconcile|comment|watch-condition|watch-fire|status"
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
