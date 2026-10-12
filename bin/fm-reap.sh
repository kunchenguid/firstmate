#!/usr/bin/env bash
# fm-reap.sh - classify this home's finished or dead worker records and clear
# the safe ones through the existing guarded owners, so stale records and
# their panes stop piling up and jamming the spawn cap.
#
# Usage:
#   fm-reap.sh scan [--act] [--actionable] [--task <id>]
#   fm-reap.sh report <task-id>
#
# `scan` is a dry run by default: one line per record, `<id> <class> <text>`,
# where <text> is the action the reaper WOULD take or the reason it takes none.
# `--act` performs the action for every actionable record and appends one
# `check: reap <id> <action> <result>` wake per attempt (bin/fm-wake-lib.sh
# owns the queue). `--actionable` prints only records and staleness rows with a
# pending action, so a caller can test "is there anything to reap" cheaply.
# `--task <id>` restricts both passes to one task id. `report <id>` prints the
# evidence the classifier read for one record, one `key: value` per line, then
# its class. Every mode exits 0 unless the arguments are invalid (2); a refused
# or failed action is reported on stdout and in the wake, never as an exit code,
# so a supervision caller is never aborted by one bad record.
#
# Scope and skips. Only `$FM_HOME/state/*.meta` records are read - never another
# home's. A record is skipped (class SKIP) when it is kind=secondmate, when its
# newest meta or status mtime is younger than FM_REAP_MIN_AGE_SECS (default 600),
# when its last status verb is captain-held, when its task is leased to the
# other supervision actor (bin/fm-lease-lib.sh), or when its meta lock is held
# (bin/fm-wake-lib.sh fm_meta_lock_path). Classification runs under that meta
# lock and releases it before any action, because every action owner takes the
# lock itself.
#
# Evidence, in order: endpoint, ledger, worktree, PR, slot.
#   - endpoint: bin/fm-backend.sh's recovery-grade classifier on the recorded
#     backend and target. `alive` is final: class ALIVE, nothing is touched.
#     dead or missing continues; ambiguous, unreadable, and unverified are
#     class UNSURE. A tmux record with no window names no endpoint (missing).
#   - ledger: the last event line of state/<id>.status and its verb.
#   - worktree: dirty = `git status --porcelain` minus the harness leftovers
#     teardown ignores (.claude/ and .fm-*-turnend untracked files);
#     unpushed = commits on HEAD not reachable from any FORGE remote-tracking
#     ref, where every refs/remotes/* ref except refs/remotes/no-mistakes/*
#     counts as a forge ref and a repo with no forge ref counts every commit.
#     This is deliberately stricter than teardown's own landed test.
#   - PR: the record's pr= line, read first through the durable merge marker
#     (bin/fm-pr-lib.sh fm_pr_poll_merge_already_notified) and otherwise through
#     gh-axi for GitHub (fm_pr_github_read_record_with_gh_axi). An unreadable
#     PR is class UNSURE. Checks are read only for a MERGE-DUE candidate, from
#     `gh-axi pr view`'s `checks: "N passed, M failed, T total"` line, and are
#     green only when failed is 0, passed equals total, and total is positive.
#   - slot: the pool-slot owner claim (fm_treehouse_slot_owner_state):
#     mine, other, absent, or unsafe (unreadable claim, class UNSURE).
#
# Classes and actions (--act):
#   ALIVE          agent running at the endpoint; never touched.
#   GHOST          slot claim names another task whose record exists in this
#                  home, endpoint dead or missing, and HEAD is off this task's
#                  branch or has no unpushed commits ->
#                  `fm-teardown.sh <id> --record-only` (that script's header
#                  owns the record-only contract).
#   LANDED         PR merged and worktree clean with no unpushed commits, or
#                  PR merged and worktree already gone -> `fm-teardown.sh <id>`
#                  with no flags, so teardown's own landed test runs again.
#   SCOUT-DONE     kind=scout, verb done, data/<id>/report.md present, and
#                  `fm-captain-hold.sh verify <id>` passes -> plain teardown;
#                  a failed verify is reported only.
#   MERGE-DUE      kind=ship, verb done, PR open. yolo=on and no open captain
#                  hold and checks green -> `fm-pr-merge.sh <id> <url>` (that
#                  script remains the merge authority); yolo=off -> one
#                  `fm-captain-hold.sh hold <id> --reason ...` naming the URL,
#                  recorded in the sidecar so it is filed once; never a merge.
#   PR-CLOSED      PR closed without merging; reported only.
#   DEAD-UNLANDED  endpoint dead or missing with work not proven landed. Dirty
#                  -> reported only. Clean with verb done, working, paused, or
#                  no status -> `fm-control.sh <id> relaunch --note ...` at most
#                  once per record; a later dead reading after that relaunch is
#                  reported and escalated through one wake, never relaunched
#                  again; once escalated it is report-only (no pending action,
#                  absent from --actionable) until its evidence changes.
#   BLOCKED, FAILED, NEEDS-DECISION  the ledger verb; reported only.
#   UNSURE         any evidence the reaper cannot read; reported only.
#   SKIP           see the skips above.
# Classes are tested in the order listed, after SKIP, so ALIVE outranks every
# other reading and a reassigned slot (GHOST) is never read as this task's
# dirty worktree.
#
# Invariants: no action ever passes --force; nothing here touches a worktree,
# slot, pane, or PR directly - every mutation goes through fm-teardown.sh,
# fm-control.sh, fm-pr-merge.sh, fm-captain-hold.sh, or `staleness close`,
# each with its own refusals intact. A refusal (non-zero exit) records its
# first REFUSED or error line and the evidence fingerprint in the sidecar
# state/<id>.reap, and the record is reported, not retried, until that
# fingerprint changes. A lease refusal (exit FM_LEASE_REFUSE_EXIT) is a skip,
# not a refusal. The sidecar also carries relaunch_at, hold_filed, and
# escalated; teardown removes it with the record's other per-task files.
#
# Staleness rows (second pass). When the staleness command and `jq` exist, the scan
# reads `staleness list --json -n 0` as untrusted data and joins each row to a
# task id by title (`Stale task <id>: ...` or `Stale agent shut down: <id>`),
# using the description's worktree, branch, and project fields as evidence.
# Row lines read `<row-id> ROW-<class> <text> task=<id>`:
#   ROW-FOLLOWS       the task's record exists here; the row is closed only
#                     after this scan's teardown or record-only action for that
#                     record succeeded.
#   ROW-ORPHAN-CLEAR  no record; the worktree is gone and the branch is absent
#                     from the project, or the branch exists with no unpushed
#                     commits and is merged into the default branch (ancestor or
#                     merge-tree content proof) -> `staleness close <row>`.
#   ROW-ORPHAN-HOLDS  no record, but the worktree is dirty on that branch, the
#                     branch has unpushed commits, or it is pushed and not
#                     merged; never closed.
#   ROW-UNMATCHED     the title names no task; never touched.
#   ROW-UNSURE        evidence that cannot be read; never closed.
# Rows are closed only with --act. Without the two tools the row pass is
# skipped and the scan says so on stderr.
#
# Environment: FM_HOME (default: this checkout's parent), FM_STATE_OVERRIDE,
# FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE, FM_REAP_MIN_AGE_SECS, and the tool
# overrides FM_REAP_TEARDOWN_BIN, FM_REAP_CONTROL_BIN, FM_REAP_PR_MERGE_BIN,
# FM_REAP_CAPTAIN_HOLD_BIN (defaults: the sibling scripts in bin/).
#
# Callers: AGENTS.md section 8 runs `scan --act` on a heartbeat; bin/fm-watch.sh
# fires a heartbeat when `scan --actionable` prints anything; bin/fm-spawn.sh's
# spend-cap refusal prints the dry run as evidence. FM_REAP_STALENESS_BIN names
# the staleness command (default: `staleness` on PATH).
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TEARDOWN_BIN="${FM_REAP_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
CONTROL_BIN="${FM_REAP_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
PR_MERGE_BIN="${FM_REAP_PR_MERGE_BIN:-$SCRIPT_DIR/fm-pr-merge.sh}"
CAPTAIN_HOLD_BIN="${FM_REAP_CAPTAIN_HOLD_BIN:-$SCRIPT_DIR/fm-captain-hold.sh}"
STALENESS_BIN="${FM_REAP_STALENESS_BIN:-staleness}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

MIN_AGE=${FM_REAP_MIN_AGE_SECS:-600}
case "$MIN_AGE" in
  ''|*[!0-9]*)
    printf 'fm-reap: FM_REAP_MIN_AGE_SECS must be a whole number of seconds\n' >&2
    exit 2
    ;;
esac

usage() {
  cat <<'EOF'
Usage:
  fm-reap.sh scan [--act] [--actionable] [--task <id>]
  fm-reap.sh report <task-id>
Dry run by default: `<id> <class> <action-or-reason>` per record, then
`<row-id> ROW-<class> <text> task=<id>` per staleness row. --act performs the
listed actions through fm-teardown.sh, fm-control.sh, fm-pr-merge.sh,
fm-captain-hold.sh, and `staleness close`, never with --force, and appends a
`check: reap <id> <action> <result>` wake per attempt. --actionable prints only
pending actions. The script header owns the classes and evidence rules.
EOF
}

if [ "$(uname)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

now_epoch() { date +%s; }

clean_text() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-600
}

fingerprint() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 24)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 24)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

# --- sidecar state/<id>.reap ----------------------------------------------

sidecar_path() { printf '%s/%s.reap\n' "$STATE" "$1"; }

sidecar_get() {  # <id> <key>
  local f line value=''
  f=$(sidecar_path "$1")
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$f"
  printf '%s' "$value"
}

sidecar_set() {  # <id> <key> <value>
  local f tmp line
  f=$(sidecar_path "$1")
  tmp=$(mktemp "$STATE/.reap.XXXXXX") || return 1
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$2="*) continue ;; esac
      printf '%s\n' "$line" >> "$tmp"
    done < "$f"
  fi
  printf '%s=%s\n' "$2" "$(clean_text "$3")" >> "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
}

# --- git evidence -----------------------------------------------------------

dirty_filter() { grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)'; }

forge_refs() {  # <repo> -> refnames, one per line
  git -C "$1" for-each-ref --format='%(refname)' refs/remotes/ 2>/dev/null \
    | grep -v '^refs/remotes/no-mistakes/' || true
}

# unpushed_count <repo> <rev>: commits on <rev> not on any forge ref; every
# commit when the repo has no forge ref. Prints a count or fails.
unpushed_count() {
  local repo=$1 rev=$2 refs count
  refs=$(forge_refs "$repo")
  if [ -n "$refs" ]; then
    # shellcheck disable=SC2086  # refnames are whitespace-free git refs.
    count=$(git -C "$repo" rev-list --count "$rev" --not $refs -- 2>/dev/null) || return 1
  else
    count=$(git -C "$repo" rev-list --count "$rev" -- 2>/dev/null) || return 1
  fi
  printf '%s' "$count"
}

default_ref() {  # <repo> -> a default-branch ref or failure
  local repo=$1 short ref
  short=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$short" ] && git -C "$repo" rev-parse --quiet --verify "refs/remotes/$short^{commit}" >/dev/null 2>&1; then
    printf 'refs/remotes/%s' "$short"
    return 0
  fi
  for ref in refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
    if git -C "$repo" rev-parse --quiet --verify "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}

# merged_into_default <repo> <rev>: 0 when <rev> is an ancestor of the default
# branch or merging it into the default branch changes nothing (squash proof).
merged_into_default() {
  local repo=$1 rev=$2 ref default_tree merged_tree
  ref=$(default_ref "$repo") || return 1
  git -C "$repo" merge-base --is-ancestor "$rev" "$ref" 2>/dev/null && return 0
  default_tree=$(git -C "$repo" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  merged_tree=$(git -C "$repo" merge-tree --write-tree "$ref" "$rev" 2>/dev/null) || return 1
  merged_tree=${merged_tree%%$'\n'*}
  [ -n "$merged_tree" ] && [ "$merged_tree" = "$default_tree" ]
}

# --- record evidence ----------------------------------------------------------

# Globals filled by read_record <meta> <id>; read by classify_record and report.
reset_evidence() {
  local v
  for v in E_KIND E_MODE E_YOLO E_BRANCH E_WT E_PROJ E_BACKEND E_TARGET \
      E_ENDPOINT E_STATUS E_VERB E_WT_STATE E_DIRTY E_UNPUSHED E_HEAD \
      E_PR_URL E_PR_STATE E_PR_CHECKS E_OWNER E_OWNER_ID E_OWNER_HOME \
      E_REPORT E_RELAUNCHED E_HOLD_FILED E_REFUSED CLASS TEXT ACTION ACTION_FP; do
    printf -v "$v" ''
  done
}

read_endpoint() {  # <meta> <id>
  local meta=$1 id=$2 window
  E_BACKEND=$(fm_backend_of_meta "$meta")
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ] && [ "$E_BACKEND" = tmux ]; then
    E_TARGET=
    E_ENDPOINT=missing
    return 0
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null; then
    E_ENDPOINT=unverified
    return 0
  fi
  E_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  E_TARGET=$FM_BACKEND_VALIDATED_TARGET
  E_ENDPOINT=$(fm_backend_agent_state "$E_BACKEND" "$E_TARGET")
  [ -n "$E_ENDPOINT" ] || E_ENDPOINT=unreadable
}

read_worktree() {
  local porcelain
  E_WT_STATE=absent E_DIRTY=0 E_UNPUSHED=0 E_HEAD=
  [ -n "$E_WT" ] && [ -d "$E_WT" ] || return 0
  if ! git -C "$E_WT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    E_WT_STATE=unreadable
    return 0
  fi
  if ! porcelain=$(git -C "$E_WT" status --porcelain 2>/dev/null); then
    E_WT_STATE=unreadable
    return 0
  fi
  E_WT_STATE=present
  if printf '%s\n' "$porcelain" | dirty_filter | grep -q .; then E_DIRTY=1; fi
  E_UNPUSHED=$(unpushed_count "$E_WT" HEAD) || { E_WT_STATE=unreadable; E_UNPUSHED=; }
  E_HEAD=$(git -C "$E_WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
}

read_pr() {  # <meta> <id>
  local meta=$1 id=$2
  E_PR_URL=''
  E_PR_STATE=none
  fm_pr_metadata_identity_parse "$meta" || {
    [ -z "$(fm_meta_get "$meta" pr)" ] || E_PR_STATE=unreadable
    return 0
  }
  [ -n "$FM_PR_META_URL" ] || return 0
  E_PR_URL=$FM_PR_META_URL
  if fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_META_PROVIDER" \
      "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER"; then
    E_PR_STATE=MERGED
    return 0
  fi
  if [ "$FM_PR_META_PROVIDER" = github ] \
     && fm_pr_github_read_record_with_gh_axi "${FM_PR_META_PATH%%/*}" "${FM_PR_META_PATH#*/}" "$FM_PR_META_NUMBER"; then
    E_PR_STATE=$FM_PR_RECORD_STATE
  else
    E_PR_STATE=unreadable
  fi
}

# read_pr_checks: fills E_PR_CHECKS with green, red, or unreadable from the
# `checks:` line of gh-axi pr view; called only for a MERGE-DUE candidate.
read_pr_checks() {
  local output line passed failed total
  E_PR_CHECKS=unreadable
  output=$(gh-axi pr view "$FM_PR_META_NUMBER" --repo "$FM_PR_META_PATH" 2>/dev/null) || return 0
  line=$(printf '%s\n' "$output" | awk '$1 == "checks:" { count++; $1=""; value=$0 } END { if (count == 1) print value }')
  line=${line//\"/}
  case "$line" in
    *passed,*failed,*total*) ;;
    *) return 0 ;;
  esac
  passed=$(printf '%s' "$line" | awk '{print $1}')
  failed=$(printf '%s' "$line" | awk '{print $3}')
  total=$(printf '%s' "$line" | awk '{print $5}')
  case "$passed$failed$total" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$failed" -eq 0 ] && [ "$total" -gt 0 ] && [ "$passed" -eq "$total" ]; then
    E_PR_CHECKS=green
  else
    E_PR_CHECKS="red:$passed/$total passed, $failed failed"
  fi
}

read_slot() {  # <id>
  E_OWNER=none
  E_OWNER_ID=''
  E_OWNER_HOME=''
  [ "$E_WT_STATE" = present ] || return 0
  fm_treehouse_pool_slot "$E_PROJ" "$E_WT" || return 0
  fm_treehouse_slot_owner_state "$E_WT" "$1"
  E_OWNER=$FM_TREEHOUSE_SLOT_OWNER
  E_OWNER_ID=$FM_TREEHOUSE_SLOT_OWNER_ID
  E_OWNER_HOME=$FM_TREEHOUSE_SLOT_OWNER_HOME
}

read_record() {  # <meta> <id>
  local meta=$1 id=$2
  E_KIND=$(fm_meta_get "$meta" kind)
  E_MODE=$(fm_meta_get "$meta" mode)
  E_YOLO=$(fm_meta_get "$meta" yolo)
  E_BRANCH=$(fm_meta_get "$meta" branch)
  E_WT=$(fm_meta_get "$meta" worktree)
  E_PROJ=$(fm_meta_get "$meta" project)
  E_STATUS=$(last_status_line "$STATE/$id.status")
  E_VERB=$(status_line_verb "$E_STATUS")
  E_REPORT=0
  [ ! -s "$DATA/$id/report.md" ] || E_REPORT=1
  E_RELAUNCHED=$(sidecar_get "$id" relaunch_at)
  E_HOLD_FILED=$(sidecar_get "$id" hold_filed)
  E_REFUSED=$(sidecar_get "$id" refused)
  read_endpoint "$meta" "$id"
  read_worktree
  read_pr "$meta" "$id"
  read_slot "$id"
}

set_class() {  # <class> <text> [<action>]
  CLASS=$1
  TEXT=$2
  ACTION=${3:-}
}

# classify_record <id>: sets CLASS, TEXT, ACTION from the evidence globals.
classify_record() {
  local id=$1 rc
  case "$E_ENDPOINT" in
    alive) set_class ALIVE "agent running at $E_BACKEND $E_TARGET; nothing to reap"; return 0 ;;
    dead|missing) ;;
    *) set_class UNSURE "endpoint reads $E_ENDPOINT; nothing touched"; return 0 ;;
  esac
  case "$E_WT_STATE" in
    unreadable) set_class UNSURE "worktree $E_WT cannot be inspected; nothing touched"; return 0 ;;
  esac
  case "$E_OWNER" in
    unsafe) set_class UNSURE "slot-owner claim beside $E_WT cannot be read; nothing touched"; return 0 ;;
    other)
      if fm_task_id_path_safe "$E_OWNER_ID" && [ -f "$STATE/$E_OWNER_ID.meta" ] && [ "$E_OWNER_ID" != "$id" ]; then
        if [ -n "$E_BRANCH" ] && [ "$E_HEAD" = "$E_BRANCH" ] && [ "${E_UNPUSHED:-1}" -gt 0 ]; then
          set_class UNSURE "slot reassigned to $E_OWNER_ID but HEAD is still this task's branch with $E_UNPUSHED unpushed commit(s); nothing touched"
          return 0
        fi
        set_class GHOST "slot now claimed by $E_OWNER_ID; endpoint $E_ENDPOINT -> fm-teardown.sh $id --record-only" record-only
        return 0
      fi
      set_class UNSURE "slot claimed by $E_OWNER_ID, which has no record in this home; nothing touched"
      return 0
      ;;
  esac
  case "$E_PR_STATE" in
    unreadable) set_class UNSURE "PR state for ${E_PR_URL:-recorded pr=} cannot be read; nothing touched"; return 0 ;;
    MERGED)
      if [ "$E_WT_STATE" = absent ]; then
        set_class LANDED "PR merged and worktree gone -> fm-teardown.sh $id" teardown
        return 0
      fi
      if [ "$E_DIRTY" -eq 0 ] && [ "$E_UNPUSHED" -eq 0 ]; then
        set_class LANDED "PR merged, worktree clean, nothing unpushed -> fm-teardown.sh $id" teardown
        return 0
      fi
      ;;
  esac
  case "$E_VERB" in
    failed) set_class FAILED "ledger reads failed; reported only"; return 0 ;;
    blocked) set_class BLOCKED "ledger reads blocked; reported only"; return 0 ;;
    needs-decision) set_class NEEDS-DECISION "ledger reads needs-decision; reported only"; return 0 ;;
  esac
  if [ "$E_KIND" = scout ] && [ "$E_VERB" = "done" ]; then
    if [ "$E_REPORT" -ne 1 ]; then
      set_class DEAD-UNLANDED "scout done without data/$id/report.md; reported only"
      return 0
    fi
    if "$CAPTAIN_HOLD_BIN" verify "$id" >/dev/null 2>&1; then
      set_class SCOUT-DONE "scout report present and captain calls verified -> fm-teardown.sh $id" teardown
    else
      set_class SCOUT-DONE "scout report present but fm-captain-hold.sh verify refused; reported only"
    fi
    return 0
  fi
  case "$E_PR_STATE" in
    CLOSED) set_class PR-CLOSED "PR $E_PR_URL closed without merging; reported only"; return 0 ;;
    OPEN)
      if [ "$E_KIND" = ship ] && [ "$E_VERB" = "done" ]; then
        if [ "$E_YOLO" = on ]; then
          "$CAPTAIN_HOLD_BIN" open "$id" >/dev/null 2>&1
          rc=$?
          case "$rc" in
            0) set_class MERGE-DUE "PR open but a captain hold is open; reported only"; return 0 ;;
            1) ;;
            *) set_class UNSURE "PR open but the captain-hold state cannot be read; nothing touched"; return 0 ;;
          esac
          read_pr_checks
          case "$E_PR_CHECKS" in
            green) set_class MERGE-DUE "PR open, checks green, yolo on -> fm-pr-merge.sh $id $E_PR_URL" merge ;;
            *) set_class MERGE-DUE "PR open, checks $E_PR_CHECKS; waiting" ;;
          esac
          return 0
        fi
        if [ "$E_HOLD_FILED" = 1 ]; then
          set_class MERGE-DUE "PR open, yolo off, captain hold already filed; waiting for the captain"
        else
          set_class MERGE-DUE "PR open, yolo off -> fm-captain-hold.sh hold $id for $E_PR_URL" hold
        fi
        return 0
      fi
      ;;
  esac
  # Dead or missing endpoint with nothing proving the work landed.
  if [ "$E_WT_STATE" = present ] && [ "$E_DIRTY" -eq 1 ]; then
    set_class DEAD-UNLANDED "endpoint $E_ENDPOINT with uncommitted changes in $E_WT; never torn down, reported only"
    return 0
  fi
  case "$E_VERB" in
    done|working|paused|'') ;;
    *) set_class DEAD-UNLANDED "endpoint $E_ENDPOINT, ledger reads $E_VERB; reported only"; return 0 ;;
  esac
  if [ -n "$E_RELAUNCHED" ] && [ "$(sidecar_get "$id" escalated)" = 1 ]; then
    set_class DEAD-UNLANDED "endpoint $E_ENDPOINT again after the one relaunch at $E_RELAUNCHED; already escalated, reported only"
    return 0
  fi
  if [ -n "$E_RELAUNCHED" ]; then
    set_class DEAD-UNLANDED "endpoint $E_ENDPOINT again after the one relaunch at $E_RELAUNCHED; escalated, not relaunched" escalate
    return 0
  fi
  set_class DEAD-UNLANDED "endpoint $E_ENDPOINT, ${E_UNPUSHED:-0} unpushed commit(s), ledger ${E_VERB:-empty} -> fm-control.sh $id relaunch (once)" relaunch
}

evidence_fingerprint() {
  fingerprint "$CLASS|$ACTION|$E_VERB|$E_PR_STATE|$E_PR_CHECKS|$E_HEAD|$E_DIRTY|$E_UNPUSHED|$E_OWNER|$E_OWNER_ID|$E_ENDPOINT"
}

# --- actions ------------------------------------------------------------------

reap_wake() {  # <id> <action> <result>
  fm_wake_append check "reap:$1:$2" "check: reap $1 $2 $(clean_text "$3")" || return 1
}

first_refusal_line() {  # <stderr-text>
  local line
  line=$(printf '%s\n' "$1" | grep -m1 -E '^(REFUSED|error)' || true)
  [ -n "$line" ] || line=$(printf '%s\n' "$1" | grep -m1 . || true)
  printf '%s' "${line:-exited non-zero without a message}"
}

# run_action <id> <action> <command...>: runs the owner, records the outcome in
# the sidecar and a wake. Returns 0 when the owner succeeded.
run_action() {
  local id=$1 action=$2 err rc=0 line
  shift 2
  err=$("$@" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    reap_wake "$id" "$action" ok
    return 0
  fi
  if [ "$rc" -eq "$FM_LEASE_REFUSE_EXIT" ]; then
    printf '%s %s %s\n' "$id" "$CLASS" "$action skipped: task leased to the other supervision actor"
    return 1
  fi
  line=$(first_refusal_line "$err")
  if [ "$action" != escalate ] && [ -f "$STATE/$id.meta" ]; then
    sidecar_set "$id" refused_fp "$ACTION_FP" || true
    sidecar_set "$id" refused "$action: $line" || true
  fi
  printf '%s %s %s\n' "$id" "$CLASS" "$action refused: $(clean_text "$line")"
  reap_wake "$id" "$action" "refused: $line"
  return 1
}

act_on_record() {  # <id>
  local id=$1 note
  case "$ACTION" in
    teardown)
      run_action "$id" teardown env FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$TEARDOWN_BIN" "$id" && REAPED="$REAPED $id"
      ;;
    record-only)
      run_action "$id" record-only env FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$TEARDOWN_BIN" "$id" --record-only && REAPED="$REAPED $id"
      ;;
    merge)
      run_action "$id" merge "$PR_MERGE_BIN" "$id" "$E_PR_URL" || true
      ;;
    hold)
      if run_action "$id" hold "$CAPTAIN_HOLD_BIN" hold "$id" \
          --reason "PR ready for the captain's merge call: $E_PR_URL"; then
        sidecar_set "$id" hold_filed 1 || true
      fi
      ;;
    relaunch)
      note="fm-reap: your previous agent was found $E_ENDPOINT at its endpoint with the ledger reading ${E_VERB:-nothing}; resume from the worktree and append a status line"
      sidecar_set "$id" relaunch_at "$(now_epoch)" || true
      run_action "$id" relaunch env FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$CONTROL_BIN" "$id" relaunch --note "$note" || true
      ;;
    escalate)
      if [ "$(sidecar_get "$id" escalated)" != 1 ]; then
        sidecar_set "$id" escalated 1 || true
        reap_wake "$id" escalate "dead again after the one relaunch at $E_RELAUNCHED; needs firstmate" || true
      fi
      ;;
  esac
}

# --- record pass --------------------------------------------------------------

SCAN_ACT=0
SCAN_ACTIONABLE=0
SCAN_TASK=
REAPED=

emit() {  # <id> <class> <text>
  if [ "$SCAN_ACTIONABLE" -eq 1 ] && [ -z "$ACTION" ]; then return 0; fi
  printf '%s %s %s\n' "$1" "$2" "$3"
}

record_age() {  # <meta> <id> -> seconds since the newest of meta/status
  local newest m
  newest=$(file_mtime "$1") || newest=0
  m=$(file_mtime "$STATE/$2.status" 2>/dev/null || true)
  [ -z "$m" ] || [ "$m" -le "$newest" ] || newest=$m
  printf '%s' $(( $(now_epoch) - newest ))
}

lease_allows() {  # <id>
  ( fm_lease_guard "$1" "reap (fm-reap)" >/dev/null 2>&1 && fm_lease_guard_release )
}

scan_record() {  # <meta>
  local meta=$1 id lock age
  id=${meta##*/}
  id=${id%.meta}
  fm_task_id_path_safe "$id" || return 0
  [ -z "$SCAN_TASK" ] || [ "$SCAN_TASK" = "$id" ] || return 0
  reset_evidence
  if [ "$(fm_meta_get "$meta" kind)" = secondmate ]; then
    emit "$id" SKIP "secondmate record; never reaped"
    return 0
  fi
  age=$(record_age "$meta" "$id")
  if [ "$age" -lt "$MIN_AGE" ]; then
    emit "$id" SKIP "record changed ${age}s ago, younger than ${MIN_AGE}s"
    return 0
  fi
  if ! lease_allows "$id"; then
    emit "$id" SKIP "leased to the other supervision actor"
    return 0
  fi
  lock=$(fm_meta_lock_path "$meta") || return 0
  if ! fm_lock_try_acquire "$lock"; then
    emit "$id" SKIP "record lock held by another command"
    return 0
  fi
  read_record "$meta" "$id"
  fm_lock_release "$lock"
  if [ "$E_VERB" = captain-held ]; then
    emit "$id" SKIP "captain-held; never reaped"
    return 0
  fi
  classify_record "$id"
  if [ -n "$ACTION" ]; then
    ACTION_FP=$(evidence_fingerprint)
    if [ "$ACTION" != escalate ] && [ "$(sidecar_get "$id" refused_fp)" = "$ACTION_FP" ]; then
      ACTION=
      emit "$id" "$CLASS" "refused earlier ($E_REFUSED); skipped until the evidence changes"
      return 0
    fi
  fi
  emit "$id" "$CLASS" "$TEXT"
  [ "$SCAN_ACT" -eq 1 ] && [ -n "$ACTION" ] || return 0
  act_on_record "$id"
}

scan_records() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    scan_record "$meta"
  done
}

# --- staleness rows -------------------------------------------------------------

row_task_id() {  # <title> -> task id or failure
  local title=$1 id
  case "$title" in
    "Stale task "*": "*) id=${title#Stale task }; id=${id%%: *} ;;
    "Stale agent shut down: "*) id=${title#Stale agent shut down: } ;;
    *) return 1 ;;
  esac
  fm_task_id_path_safe "$id" || return 1
  printf '%s' "$id"
}

row_field() {  # <description> <field> -> value of `field: v` or `field=v`
  local desc=$1 field=$2 line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in
      "$field: "*) value=${line#"$field: "} ;;
      "$field="*) value=${line#"$field="} ;;
      *)
        case "$line" in
          *"; $field="*) value=${line#*"; $field="}; value=${value%%;*} ;;
        esac
        ;;
    esac
  done <<EOF
$desc
EOF
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

# classify_orphan_row <worktree> <branch> <project>: sets ROW_CLASS/ROW_TEXT for
# a row whose task has no record in this home.
classify_orphan_row() {
  local wt=$1 branch=$2 proj=$3 repo='' head unpushed
  case "$branch" in HEAD|'') branch= ;; esac
  case "$wt" in
    '') ;;
    /*) [ -d "$wt" ] && repo=$wt ;;
    *) ROW_CLASS=ROW-UNSURE; ROW_TEXT="worktree field is not an absolute path"; return 0 ;;
  esac
  if [ -z "$repo" ]; then
    if [ -z "$branch" ]; then
      ROW_CLASS=ROW-ORPHAN-CLEAR; ROW_TEXT="worktree gone and no branch recorded -> staleness close"
      return 0
    fi
    if [ -z "$proj" ] || [ ! -d "$proj" ]; then
      ROW_CLASS=ROW-UNSURE; ROW_TEXT="worktree gone and project ${proj:-unrecorded} not found to check branch $branch"
      return 0
    fi
    repo=$proj
  fi
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ROW_CLASS=ROW-UNSURE; ROW_TEXT="$repo is not a readable git checkout"
    return 0
  fi
  if [ "$repo" = "$wt" ]; then
    head=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$branch" ] && [ "$head" = "$branch" ] || { [ -z "$branch" ] && [ -z "$head" ]; }; then
      if git -C "$wt" status --porcelain 2>/dev/null | dirty_filter | grep -q .; then
        ROW_CLASS=ROW-ORPHAN-HOLDS; ROW_TEXT="worktree dirty on ${branch:-detached HEAD}; never closed"
        return 0
      fi
      unpushed=$(unpushed_count "$wt" HEAD) || { ROW_CLASS=ROW-UNSURE; ROW_TEXT="cannot count unpushed commits in $wt"; return 0; }
      if [ "$unpushed" -gt 0 ]; then
        ROW_CLASS=ROW-ORPHAN-HOLDS; ROW_TEXT="$unpushed unpushed commit(s) on ${branch:-detached HEAD}; never closed"
        return 0
      fi
      if merged_into_default "$wt" HEAD; then
        ROW_CLASS=ROW-ORPHAN-CLEAR; ROW_TEXT="clean, pushed, merged into the default branch -> staleness close"
      else
        ROW_CLASS=ROW-ORPHAN-HOLDS; ROW_TEXT="pushed but not merged into the default branch; never closed"
      fi
      return 0
    fi
    if [ -z "$branch" ]; then
      ROW_CLASS=ROW-ORPHAN-CLEAR; ROW_TEXT="worktree moved off its detached HEAD and no branch recorded -> staleness close"
      return 0
    fi
  fi
  if ! git -C "$repo" rev-parse --quiet --verify "refs/heads/$branch^{commit}" >/dev/null 2>&1; then
    ROW_CLASS=ROW-ORPHAN-CLEAR; ROW_TEXT="branch $branch no longer exists in $repo -> staleness close"
    return 0
  fi
  unpushed=$(unpushed_count "$repo" "refs/heads/$branch") || { ROW_CLASS=ROW-UNSURE; ROW_TEXT="cannot count unpushed commits on $branch"; return 0; }
  if [ "$unpushed" -gt 0 ]; then
    ROW_CLASS=ROW-ORPHAN-HOLDS; ROW_TEXT="branch $branch holds $unpushed unpushed commit(s); never closed"
    return 0
  fi
  if merged_into_default "$repo" "refs/heads/$branch"; then
    ROW_CLASS=ROW-ORPHAN-CLEAR; ROW_TEXT="branch $branch pushed and merged into the default branch -> staleness close"
  else
    ROW_CLASS=ROW-ORPHAN-HOLDS; ROW_TEXT="branch $branch pushed but not merged into the default branch; never closed"
  fi
}

reaped_this_scan() {  # <id>
  case " $REAPED " in *" $1 "*) return 0 ;; esac
  return 1
}

close_row() {  # <row-id> <reason>
  local err rc=0
  err=$("$STALENESS_BIN" close "$1" --reason "$2" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    reap_wake "$1" staleness-close ok
    return 0
  fi
  printf '%s ROW-REFUSED %s\n' "$1" "staleness close failed: $(clean_text "$(first_refusal_line "$err")")"
  reap_wake "$1" staleness-close "refused: $(first_refusal_line "$err")"
  return 1
}

scan_rows() {
  local rows id title desc task wt branch proj pending
  command -v "$STALENESS_BIN" >/dev/null 2>&1 || { printf 'fm-reap: staleness rows skipped (no %s command)\n' "$STALENESS_BIN" >&2; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'fm-reap: staleness rows skipped (no jq on PATH)\n' >&2; return 0; }
  rows=$("$STALENESS_BIN" list --json -n 0 2>/dev/null) || { printf 'fm-reap: staleness rows skipped (list failed)\n' >&2; return 0; }
  rows=$(printf '%s' "$rows" | jq -r '.[]? | select(.status != "closed") | [.id, .title, ((.description // "") | gsub("\n"; "\u001f"))] | @tsv' 2>/dev/null) \
    || { printf 'fm-reap: staleness rows skipped (unparseable list)\n' >&2; return 0; }
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r id title desc; do
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    title=$(printf '%s' "$title" | sed 's/\\t/ /g')
    desc=$(printf '%s' "$desc" | sed 's/\\t/ /g' | tr '\037' '\n')
    ROW_CLASS=''
    ROW_TEXT=''
    pending=''
    if ! task=$(row_task_id "$title"); then
      [ "$SCAN_ACTIONABLE" -eq 1 ] || printf '%s ROW-UNMATCHED title names no task; never touched\n' "$id"
      continue
    fi
    [ -z "$SCAN_TASK" ] || [ "$SCAN_TASK" = "$task" ] || continue
    if [ -f "$STATE/$task.meta" ]; then
      if reaped_this_scan "$task"; then
        ROW_CLASS=ROW-FOLLOWS; ROW_TEXT="record reaped this scan -> staleness close"; pending=1
      else
        ROW_CLASS=ROW-FOLLOWS; ROW_TEXT="record present; closes when the record is reaped"
      fi
    else
      wt=$(row_field "$desc" worktree)
      branch=$(row_field "$desc" branch)
      proj=$(row_field "$desc" project)
      classify_orphan_row "$wt" "$branch" "$proj"
      [ "$ROW_CLASS" != ROW-ORPHAN-CLEAR ] || pending=1
    fi
    if [ "$SCAN_ACTIONABLE" -eq 1 ] && [ -z "$pending" ]; then continue; fi
    printf '%s %s %s task=%s\n' "$id" "$ROW_CLASS" "$ROW_TEXT" "$task"
    [ "$SCAN_ACT" -eq 1 ] && [ -n "$pending" ] || continue
    close_row "$id" "fm-reap: $ROW_TEXT (task $task)" || true
  done <<EOF
$rows
EOF
}

# --- report ---------------------------------------------------------------------

report_record() {  # <id>
  local id=$1 meta="$STATE/$1.meta"
  [ -f "$meta" ] || { printf 'fm-reap: no record %s\n' "$meta" >&2; return 1; }
  reset_evidence
  read_record "$meta" "$id"
  classify_record "$id"
  printf 'id: %s\nkind: %s\nmode: %s\nyolo: %s\nbranch: %s\nworktree: %s\nproject: %s\n' \
    "$id" "$E_KIND" "$E_MODE" "$E_YOLO" "$E_BRANCH" "$E_WT" "$E_PROJ"
  printf 'backend: %s\ntarget: %s\nendpoint: %s\n' "$E_BACKEND" "$E_TARGET" "$E_ENDPOINT"
  printf 'status: %s\nverb: %s\n' "$E_STATUS" "$E_VERB"
  printf 'worktree_state: %s\ndirty: %s\nunpushed: %s\nhead: %s\n' "$E_WT_STATE" "$E_DIRTY" "$E_UNPUSHED" "$E_HEAD"
  printf 'pr: %s\npr_state: %s\npr_checks: %s\n' "$E_PR_URL" "$E_PR_STATE" "$E_PR_CHECKS"
  printf 'slot_owner: %s\nslot_owner_id: %s\nslot_owner_home: %s\n' "$E_OWNER" "$E_OWNER_ID" "$E_OWNER_HOME"
  printf 'scout_report: %s\nrelaunched_at: %s\nhold_filed: %s\nrefused: %s\n' "$E_REPORT" "$E_RELAUNCHED" "$E_HOLD_FILED" "$E_REFUSED"
  printf 'class: %s\naction: %s\ntext: %s\n' "$CLASS" "${ACTION:-none}" "$TEXT"
}

# --- main -----------------------------------------------------------------------

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  scan)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --act) SCAN_ACT=1 ;;
        --actionable) SCAN_ACTIONABLE=1 ;;
        --task)
          shift
          fm_task_id_path_safe "${1:-}" || { usage >&2; exit 2; }
          SCAN_TASK=$1
          ;;
        *) usage >&2; exit 2 ;;
      esac
      shift
    done
    [ -d "$STATE" ] || exit 0
    scan_records
    scan_rows
    exit 0
    ;;
  report)
    if [ "$#" -ne 2 ] || ! fm_task_id_path_safe "$2"; then
      usage >&2
      exit 2
    fi
    report_record "$2"
    ;;
  *) usage >&2; exit 2 ;;
esac
