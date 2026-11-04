#!/usr/bin/env bash
# fm-merge-queue.sh - land queued, already-verified pull requests on a timer,
# with no agent turn in the loop.
#
# WHY THIS EXISTS. A pull request that is green, QA-passed, and merge-ready
# still waits for a firstmate turn today, because the merge queue is a
# hand-written file and its batch script is run by hand. Every such merge
# therefore costs a routing turn serialized behind the rest of the fleet. This
# script is the same batch on a timer: a systemd timer runs `run` every ten
# minutes, and a queued pull request lands without anyone being woken.
#
# THE QUEUE FILE. One row per pull request, whitespace separated:
#
#   <repo> <number> <expected-head> <task-id> <squash|merge|rebase>
#
# <repo>      "owner/repo", or a bare repository name, which then uses the owner
#             named by a "# owner: <login>" directive in the same file, or
#             FM_MERGE_QUEUE_OWNER.
# <number>    the pull request number.
# <expected-head>
#             the head commit the row was written against, at least 7 hex
#             characters. A head that moved retires the row instead of merging
#             a commit nobody queued.
# <task-id>   the firstmate task this merge is recorded against, so the merge
#             metadata and the landed-work check keep working.
# <method>    the merge method handed to the forge.
#
# Comment (#) and blank lines are preserved exactly as they are written.
# Default queue: <FM_HOME>/data/go-queue.txt. With no queue file this home has
# not opted in, and `run` does nothing at all.
#
# A ROW LEAVES THE QUEUE ONLY ON A TERMINAL VERDICT: merged, already merged,
# closed, fenced, a moved head, superseded by a newer row for the same pull
# request, or FM_MERGE_QUEUE_MAX_ATTEMPTS consecutive refused merge attempts
# (default 6).
# A row that is merely not ready - checks not green, the QA review not posted on
# this head, or the forge unreadable - stays queued and is retried on the next
# tick, and so does a row this home cannot read at all (no repository owner, an
# unknown merge method, too many fields): a configuration mistake must never
# delete the queue it was given, so such a row is kept and the daily line reports
# how many rows need the file fixed. Every row is read live on every tick; nothing in the queue file is
# trusted as current. A row is identified by its pull request AND the head it
# was written against, so re-queueing after a push is a new row rather than a
# duplicate: the newest row for a pull request supersedes the older-head row,
# which is recorded with its own verdict instead of being dropped, and an exact
# duplicate of one row is attempted once.
#
# WHAT KEEPS IT SAFE. The merge is always bin/fm-pr-merge.sh, so that script's
# own refusal rules, merge verification, metadata recording, and durable wake
# still apply; this script only decides what to hand it. It never merges a red
# head, a draft, a head the row did not name, or a change whose labels carry
# FENCE_WORDS (money, credentials, Cloudflare, customer copy, irreversible),
# and it fences a title or body that names production DDL. Those stay with a
# decider rather than an unattended timer. A passing qa-review on the exact
# head is always required, so no home can turn it off by configuration.
#
# THE ONE EXEMPTION. A check named credit-approval-guard is red by design on a
# credit-impact change, where the credit review itself is the real gate, so a
# failing instance of that one check does not block. A guard that has not
# finished holds the row, and a failing instance anywhere in the list is the
# waiver. Every merge that relied on that exemption says so on its own line and
# in the daily detail file, so the waiver is never silent.
#
# RECORDS, all under <FM_HOME>/state/merge-queue/:
#   ledger.tsv   one line per verdict:
#                <epoch> <owner/repo#number@head> <verdict> <reason> <url>
#   daily-<day>.txt  every merged and retired row of the summary window, one
#                line each with its full pull request URL and verdict
#   last-run     the verdict counts of the most recent run
#   .summary     the day of the last daily line and the epoch it covered from
#   .lock/       single-instance lock, so two ticks never merge at once
#
# THE DAILY LINE. The first run of each UTC day appends ONE durable check wake
# giving the counts and the detail file that names every row, so the queue is
# one line a day in firstmate's chat instead of a wake per merge and no row is
# ever silently truncated away. No run pages anyone directly: every other
# verdict is a journal line.
#
# INSTALL, once per home, from the home's code root:
#   printf '# owner: <github-login>\n' | cat - data/go-queue.txt > /tmp/q \
#     && mv /tmp/q data/go-queue.txt            # only for bare repository rows
#   mkdir -p ~/.config/systemd/user
#   bin/fm-merge-queue.sh unit service > ~/.config/systemd/user/fm-merge-queue.service
#   bin/fm-merge-queue.sh unit timer   > ~/.config/systemd/user/fm-merge-queue.timer
#   systemctl --user daemon-reload
#   systemctl --user enable --now fm-merge-queue.timer
# `bin/fm-merge-queue.sh run --dry-run` prints the decisions the timer would
# make without changing anything, which is the way to check a new queue file.
#
# Usage:
#   fm-merge-queue.sh run [--queue <file>] [--dry-run]
#   fm-merge-queue.sh status [--queue <file>]
#   fm-merge-queue.sh unit service|timer
#   fm-merge-queue.sh --help
#
# run     Process the queue once: read each row, decide, merge what is ready,
#         retire what is terminal, and emit the daily line when its day turns.
#         --dry-run prints the same decisions and changes no queue row, ledger
#         line, or summary record, and merges nothing.
# status  Print the queue size and the most recent run from records only. No
#         network call at all.
# unit    Print one systemd unit file for this home, ready to redirect into
#         ~/.config/systemd/user/.
#
# Environment:
#   FM_HOME                  operational home whose state/ and data/ are used.
#   FM_MERGE_QUEUE           queue file path.
#   FM_MERGE_QUEUE_OWNER     GitHub owner for bare repository rows, overriding
#                            the queue file's own "# owner:" directive.
#   FM_MERGE_QUEUE_MAX_ATTEMPTS
#                            consecutive failed merge attempts before a row is
#                            retired (default 6).
#
# Exit status is 0 for a completed run whatever the individual verdicts were,
# because nothing about one unready pull request is a failure of the timer. It
# is non-zero only when the run itself could not proceed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

RECORDS="$STATE/merge-queue"
LEDGER="$RECORDS/ledger.tsv"
LAST_RUN="$RECORDS/last-run"
SUMMARY_RECORD="$RECORDS/.summary"
LOCK_DIR="$RECORDS/.lock"

MERGE_CMD="$FM_ROOT/bin/fm-pr-merge.sh"
DEFAULT_QUEUE="$FM_HOME/data/go-queue.txt"

# Merge methods the forge accepts through bin/fm-pr-merge.sh.
METHODS="squash merge rebase"

# Labels that keep a change away from an unattended merge: these name money,
# credentials, vendor consoles, customer-facing copy, or work that cannot be
# undone, and each one belongs to a decider.
# Matched against labels and label words with every separator removed, so a
# label spelled "secret", "secrets", "customer copy" or "customer-copy" all
# land on the same fence.
FENCE_WORDS="monies money credentials credential secrets secret cloudflare customercopy irreversible productionddl prodddl"

# The one check whose failure does not block, because the credit review it
# stands for is the real gate on a credit-impact change.
CREDIT_GUARD_CHECK="credit-approval-guard"

CHECK_TIMEOUT_SECS=60
MERGE_TIMEOUT_SECS=240

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'fm-merge-queue: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

now_epoch() { date -u +%s; }
today_utc() { date -u +%Y-%m-%d; }

max_attempts() {
  local n=${FM_MERGE_QUEUE_MAX_ATTEMPTS:-6}
  case "$n" in ''|*[!0-9]*|0) n=6 ;; esac
  printf '%s\n' "$n"
}

# task_usable <task-id>: a row may only be handed to the merge helper when its
# task id is well formed and this home still knows that task, because a row
# whose id is a typo would otherwise spend the retry budget and delete a
# merge-ready pull request. bin/fm-pr-lib.sh owns the id shape.
task_usable() {
  fm_pr_task_id_valid "$1" || return 1
  [ -f "$STATE/$1.meta" ]
}

# --- records -------------------------------------------------------------

record() {  # <key> <verdict> <reason> [url]
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" "$3" "${4:-}" \
    >>"$LEDGER" || return 1
}

# fail_streak <key>: how many refused merge attempts in a row the ledger ends
# with for this row, so a permanently refused merge retires instead of retrying
# forever. Only a refusal the forge itself returned counts: an unreadable forge
# is a transient outage and must never spend a row's budget.
fail_streak() {
  local key=$1
  [ -f "$LEDGER" ] || { printf '0\n'; return 0; }
  awk -F '\t' -v k="$key" '
    $2 == k { if ($3 == "merge-refused") c++; else c = 0 }
    END { print c + 0 }
  ' "$LEDGER" 2>/dev/null || printf '0\n'
}

format_epoch() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

write_last_run() {  # <merged> <retired> <skipped> <queued>
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" "$3" "$4" \
    >"$LAST_RUN.tmp" 2>/dev/null && mv -f "$LAST_RUN.tmp" "$LAST_RUN" 2>/dev/null
  return 0
}

# --- lock ----------------------------------------------------------------

lock_acquire() {
  mkdir -p "$RECORDS" 2>/dev/null || return 1
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "${BASHPID:-$$}" >"$LOCK_DIR/pid" 2>/dev/null
    return 0
  fi
  local pid
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    return 1
  fi
  # No live owner: an interrupted run left the lock behind.
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "${BASHPID:-$$}" >"$LOCK_DIR/pid" 2>/dev/null
  return 0
}

lock_release() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# Staged files this run created, so an interrupted run leaves nothing behind.
run_temps=()
cleanup_temps() {
  local f
  for f in ${run_temps[@]+"${run_temps[@]}"}; do
    rm -f "$f" 2>/dev/null || true
  done
  return 0
}

# --- queue file ----------------------------------------------------------

# queue_owner <file>: the owner for bare repository rows, from the environment
# first and the file's own "# owner:" directive second. Empty means no owner is
# configured, which retires nothing and simply leaves bare rows unreadable.
queue_owner() {
  if [ -n "${FM_MERGE_QUEUE_OWNER:-}" ]; then
    printf '%s\n' "$FM_MERGE_QUEUE_OWNER"
    return 0
  fi
  sed -n 's/^#[[:space:]]*[Oo][Ww][Nn][Ee][Rr][[:space:]]*:[[:space:]]*\([^[:space:]]*\).*$/\1/p' "$1" 2>/dev/null | head -1
}

valid_owner() {
  case "$1" in
    ''|-*|*-|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  return 0
}

valid_repo_name() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

valid_sha_prefix() {
  case "$1" in
    ''|*[!0-9A-Fa-f]*) return 1 ;;
  esac
  [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]
}

# valid_pr_number <column>: the number column is digits and nothing else, so a
# pasted row like "12," is a broken row the daily line reports rather than a
# pull request the forge is asked about on every tick forever.
valid_pr_number() {
  case "$1" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 12 ]
}

# row_key <owner> <repo> <number>: one identity per row. The owner is part of
# it, so acme/widgets#12 and beta/widgets#12 are two rows that dedupe and retire
# independently instead of one silently absorbing the other.
row_key() {
  if [ -n "$1" ]; then printf '%s/%s#%s\n' "$1" "$2" "$3"
  else printf '%s#%s\n' "$2" "$3"; fi
}

# row_identity <key> <expected-head>: the full identity of a queued row, which
# is what duplicate detection and retirement key on. Two rows for one pull
# request differ by head, so the newer one is a row of its own instead of a
# duplicate that silently absorbs the other.
row_identity() {
  printf '%s@%s\n' "$1" "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
}

# row_decidable <method> <task>: whether this run can decide a row at all, as
# opposed to a row the operator must fix in the file. A row this home cannot read
# never supersedes a readable row for the same pull request, and is never
# superseded by one either: it stays queued and is reported as unusable.
row_decidable() {
  case " $METHODS " in
    *" $1 "*) ;;
    *) return 1 ;;
  esac
  task_usable "$2"
}

# queue_fingerprint <file>: the content of the queue file, so a run can tell
# whether the file changed underneath it before it publishes its rewrite.
queue_fingerprint() {
  cksum <"$1" 2>/dev/null
}

# supersede_map <queue> <owner> <out>: one line per pull request that appears in
# the queue with more than one head, giving the identity of its newest row.
# Every other head for that pull request is superseded by it, and the superseded
# row is recorded with a verdict of its own rather than dropped.
supersede_map() {
  local queue=$1 owner=$2 out=$3 line repo number expected task method extra owner_name slug key
  : >"$out"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    repo=
    number=
    expected=
    task=
    method=
    extra=
    read -r repo number expected task method extra <<<"$line"
    case "$repo" in
      */*) owner_name=${repo%%/*} ;;
      *) owner_name=$owner ;;
    esac
    slug=${repo##*/}
    [ -z "$extra" ] || continue
    valid_owner "$owner_name" || continue
    valid_repo_name "$slug" || continue
    valid_pr_number "$number" || continue
    valid_sha_prefix "$expected" || continue
    row_decidable "$method" "$task" || continue
    key=$(row_key "$owner_name" "$slug" "$number")
    printf '%s\t%s\n' "$key" "$(row_identity "$key" "$expected")" >>"$out"
  done <"$queue"
  awk -F '\t' '
    {
      if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
      if ($2 != last[$1]) { heads[$1]++; last[$1] = $2 }
    }
    END { for (i = 1; i <= n; i++) if (heads[order[i]] > 1) print order[i] "\t" last[order[i]] }
  ' "$out" >"$out.awk" && mv -f "$out.awk" "$out"
  return 0
}

# queue_unusable_count <queue> <owner>: how many queued rows this home cannot
# read at all. Read from the file only, with no forge call, so the daily line
# can report a broken queue instead of staying quiet about it.
queue_unusable_count() {
  local queue=$1 owner=$2 count=0 line repo number expected task method extra owner_name
  [ -f "$queue" ] || { printf '0\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    repo=
    number=
    expected=
    task=
    method=
    extra=
    read -r repo number expected task method extra <<<"$line"
    case "$repo" in
      */*)
        owner_name=${repo%%/*}
        repo=${repo#*/}
        ;;
      *) owner_name=$owner ;;
    esac
    if [ -n "$extra" ] || ! valid_sha_prefix "$expected" \
      || ! valid_owner "$owner_name" || ! valid_repo_name "$repo" \
      || ! valid_pr_number "$number" || ! task_usable "$task"; then
      count=$((count + 1))
      continue
    fi
    case " $METHODS " in
      *" $method "*) ;;
      *) count=$((count + 1)) ;;
    esac
  done <"$queue"
  printf '%s\n' "$count"
}

# --- forge reads ---------------------------------------------------------

# read_pr <url>: one line of "<state>\x1f<head>\x1f<labels>\x1f<title and body>".
# The fields are separated by the unit separator rather than a tab, because a
# tab is IFS whitespace and an empty label list would silently shift the body
# into the labels.
# A failed read prints nothing and exits non-zero, which the caller reports as
# unreadable rather than as a verdict about the pull request.
read_pr() {
  fm_run_timed "$CHECK_TIMEOUT_SECS" gh pr view "$1" \
    --json state,isDraft,headRefOid,labels,title,body \
    --jq '[ (if .isDraft then "DRAFT" else .state end), .headRefOid, ([.labels[].name] | join("\u001f")), ((.title // "") + " " + (.body // "")) ] | join("\u001f")' \
    2>/dev/null
}

# read_checks <url>: one line per check as "<name>\t<bucket>". An empty result
# is reported by the caller as "no checks reported", which is not green.
read_checks() {
  fm_run_timed "$CHECK_TIMEOUT_SECS" gh pr checks "$1" \
    --json name,bucket --jq '.[] | [.name, .bucket] | @tsv' 2>/dev/null
}

# fenced_reason <labels> <title-and-body>: print the fence label that keeps this
# change off the timer, or nothing when it may merge unattended.
fenced_reason() {
  local labels body word plain
  labels=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  body=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  # A label may contain spaces, and its author may spell it with a hyphen or an
  # underscore, so the fence compares spellings with separators removed.
  plain=$(printf '%s' "$labels" | tr -cd 'a-z0-9')
  for word in $FENCE_WORDS; do
    case "$plain" in
      *"$word"*) printf '%s\n' "$word"; return 0 ;;
    esac
  done
  case "$body" in
    *prod-ddl*|*prod_ddl*|*"prod ddl"*|*production-ddl*|*production_ddl*|*"production ddl"*)
      printf 'prod-ddl\n' ;;
  esac
  return 0
}

# --- one row -------------------------------------------------------------

# process_row <repo> <number> <expected-head> <task> <method> <owner> <dry-run>
# Prints one line and sets ROW_VERDICT to a ledger verdict: "keep" means the row
# stays queued, anything else retires it.
ROW_VERDICT=keep
ROW_REASON=

process_row() {
  local repo=$1 number=$2 expected=$3 task=$4 method=$5 owner=$6 dry_run=$7
  local owner_name slug url key fields state head labels body
  local fenced checks name bucket bad qa_line qa_fail out rc last
  local credit_hold waived expected_lc head_lc

  ROW_VERDICT=keep
  ROW_REASON=

  case "$repo" in
    */*)
      owner_name=${repo%%/*}
      slug=${repo#*/}
      ;;
    *)
      owner_name=$owner
      slug=$repo
      ;;
  esac
  if valid_owner "$owner_name"; then
    key=$(row_key "$owner_name" "$slug" "$number")
  else
    key=$(row_key '' "$slug" "$number")
  fi

  # A row this home cannot read is never deleted: a configuration mistake must
  # not destroy the operator's queue. It stays queued, says so on every tick,
  # and the daily line reports how many such rows the queue holds.
  if ! valid_owner "$owner_name"; then
    ROW_VERDICT=unusable
    ROW_REASON="no repository owner for $slug (write '# owner: <login>' in the queue file)"
    printf 'keep %s unusable row: %s\n' "$key" "$ROW_REASON"
    return 0
  fi
  if ! valid_repo_name "$slug"; then
    ROW_VERDICT=unusable
    ROW_REASON="repository name is not usable: $slug"
    printf 'keep %s unusable row: %s\n' "$key" "$ROW_REASON"
    return 0
  fi
  case " $METHODS " in
    *" $method "*) ;;
    *)
      ROW_VERDICT=unusable
      ROW_REASON="unknown merge method: $method"
      printf 'keep %s unusable row: %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
  esac

  # A typo in the task column is a configuration mistake, not a refused merge:
  # it stays queued and never spends the row's retry budget.
  if ! task_usable "$task"; then
    ROW_VERDICT=unusable
    ROW_REASON="no such task in this home: $task"
    printf 'keep %s unusable row: %s\n' "$key" "$ROW_REASON"
    return 0
  fi

  url="https://github.com/$owner_name/$slug/pull/$number"

  if ! fields=$(read_pr "$url") || [ -z "$fields" ]; then
    ROW_VERDICT=unreadable
    ROW_REASON="the forge did not answer for $url"
    printf 'keep %s %s\n' "$key" "$ROW_REASON"
    return 0
  fi
  # read stops at the first newline, so flatten the record before splitting it:
  # a title or body that names production DDL on a later line must reach the
  # fence, and not just its first line.
  fields=$(printf '%s' "$fields" | tr '\n\r' '  ')
  IFS=$'\x1f' read -r state head labels body <<<"$fields"

  case "$state" in
    MERGED)
      ROW_VERDICT='already-merged'
      ROW_REASON="already merged"
      printf 'retire %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
    CLOSED)
      ROW_VERDICT=closed
      ROW_REASON="closed without merging"
      printf 'retire %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
    DRAFT)
      printf 'keep %s draft\n' "$key"
      return 0
      ;;
    OPEN) ;;
    *)
      ROW_VERDICT=unreadable
      ROW_REASON="unreadable pull request state: ${state:-none}"
      printf 'keep %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
  esac

  head_lc=$(printf '%s' "$head" | tr '[:upper:]' '[:lower:]')
  expected_lc=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
  case "$head_lc" in
    "$expected_lc"*) ;;
    *)
      ROW_VERDICT='head-moved'
      ROW_REASON="head moved to ${head:0:12} (queue expected ${expected:0:12})"
      printf 'retire %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
  esac

  fenced=$(fenced_reason "$labels" "$body")
  if [ -n "$fenced" ]; then
    ROW_VERDICT=fenced
    ROW_REASON="fenced for a decider: $fenced"
    printf 'retire %s %s\n' "$key" "$ROW_REASON"
    return 0
  fi

  # gh pr checks reports pending checks with exit 8 and "no checks" with exit
  # 1, so the output decides and the status never does. No output at all reads
  # as nothing proven, which keeps the row queued rather than merging it.
  checks=$(read_checks "$url" || true)

  bad=
  qa_line=
  qa_fail=
  credit_hold=
  waived=0
  while IFS=$'\t' read -r name bucket; do
    [ -n "$name" ] || continue
    case "$name" in
      "$CREDIT_GUARD_CHECK")
        # A failing instance is the waiver the captain ruled for; a guard that
        # is still running holds the row. Any instance decides, so a passing
        # duplicate can never hide a failing one.
        case "$bucket" in
          pass|skipping) ;;
          fail) waived=1 ;;
          *) credit_hold=$bucket ;;
        esac
        continue
        ;;
      qa-review)
        qa_line=$bucket
        case "$bucket" in
          pass|skipping) ;;
          *) qa_fail=$bucket ;;
        esac
        ;;
    esac
    case "$bucket" in
      pass|skipping) ;;
      *) bad="$bad $name=$bucket" ;;
    esac
  done <<<"$checks"

  if [ -n "$bad" ]; then
    printf 'keep %s not green:%s\n' "$key" "$bad"
    return 0
  fi
  # Two checks may share the qa-review name, so one failing instance is enough
  # to hold the row: the listing order never decides the verdict.
  if [ -n "$qa_fail" ]; then
    printf 'keep %s qa-review %s\n' "$key" "$qa_fail"
    return 0
  fi
  if [ -z "$qa_line" ]; then
    printf 'keep %s no qa-review on this head\n' "$key"
    return 0
  fi
  if [ "$qa_line" != pass ]; then
    printf 'keep %s qa-review %s\n' "$key" "$qa_line"
    return 0
  fi
  if [ -n "$credit_hold" ]; then
    printf 'keep %s %s %s\n' "$key" "$CREDIT_GUARD_CHECK" "$credit_hold"
    return 0
  fi

  if [ "$dry_run" = 1 ]; then
    if [ "$waived" = 1 ]; then
      printf 'merge %s %s (%s, head %s, credit-guard waived)\n' \
        "$key" "$url" "$method" "${head:0:12}"
    else
      printf 'merge %s %s (%s, head %s)\n' "$key" "$url" "$method" "${head:0:12}"
    fi
    return 0
  fi

  out=$(fm_run_timed "$MERGE_TIMEOUT_SECS" "$MERGE_CMD" "$task" "$url" \
    -- --"$method" --admin --match-head-commit "$head" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    ROW_VERDICT=merged
    if [ "$waived" = 1 ]; then
      ROW_REASON="$method (credit-guard waived)"
      printf 'merged %s %s (credit-guard waived)\n' "$key" "$url"
    else
      ROW_REASON=$method
      printf 'merged %s %s\n' "$key" "$url"
    fi
    return 0
  fi

  last=$(printf '%s\n' "$out" | awk 'NF { line = $0 } END { print line }')
  last=$(printf '%s' "$last" | cut -c1-160)
  ROW_VERDICT='merge-refused'
  ROW_REASON=${last:-"merge attempt exited $rc"}
  printf 'keep %s merge refused: %s\n' "$key" "$ROW_REASON"
  return 0
}

# --- run -----------------------------------------------------------------

# write_daily_detail <day> <since-epoch>: the full, untruncated list of every
# merged and retired row in the window, one line each with its pull request URL
# and verdict, and print the file's path. The daily line points at it so no row
# is ever silently cut off a summary. The window starts strictly after the
# previous summary's epoch, so the merge recorded in that same second belongs to
# the earlier summary and is never reported twice.
write_daily_detail() {
  local day=$1 since=$2 path="$RECORDS/daily-$1.txt" epoch key verdict reason url
  {
    printf '# merge queue %s - merged and retired rows since %s\n' \
      "$day" "$(format_epoch "$since")"
    printf '# time\trow\tverdict\treason\turl\n'
    while IFS=$'\t' read -r epoch key verdict reason url; do
      [ -n "$key" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(format_epoch "$epoch")" "$key" "$verdict" "$reason" "${url:--}"
    done < <(awk -F '\t' -v since="$since" '
      BEGIN {
        n = split("merged abandoned already-merged closed fenced head-moved superseded", v, " ")
        for (i = 1; i <= n; i++) reported[v[i]] = 1
      }
      $1 > since && ($3 in reported) { print }
    ' "$LEDGER")
  } >"$path"
  printf '%s\n' "$path"
}

maybe_emit_daily() {  # <queue>
  local queue=$1 today last_day last_epoch merged retired payload unusable detail waived
  [ -f "$LEDGER" ] || : >"$LEDGER"
  today=$(today_utc)
  last_day=
  last_epoch=0
  if [ -f "$SUMMARY_RECORD" ]; then
    IFS=$'\t' read -r last_day last_epoch <"$SUMMARY_RECORD" 2>/dev/null || true
  fi
  case "${last_epoch:-}" in ''|*[!0-9]*) last_epoch=0 ;; esac
  [ "${last_day:-}" = "$today" ] && return 0

  local retired_verdicts=' already-merged abandoned closed fenced head-moved superseded '
  merged=$(awk -F '\t' -v since="$last_epoch" '$1 > since && $3 == "merged" { c++ } END { print c + 0 }' "$LEDGER")
  retired=$(awk -F '\t' -v since="$last_epoch" -v want="$retired_verdicts" '
    BEGIN { n = split(want, v, " "); for (i = 1; i <= n; i++) if (v[i] != "") is_retired[v[i]] = 1 }
    $1 > since && ($3 in is_retired) { c++ }
    END { print c + 0 }
  ' "$LEDGER")
  waived=$(awk -F '\t' -v since="$last_epoch" \
    '$1 > since && $3 == "merged" && $4 ~ /credit-guard waived/ { c++ } END { print c + 0 }' \
    "$LEDGER")
  detail=$(write_daily_detail "$today" "$last_epoch")

  unusable=$(queue_unusable_count "$queue" "$(queue_owner "$queue")")
  payload="check: merge queue $today - merged $merged"
  case "${waived:-0}" in
    0) ;;
    *) payload="$payload ($waived with credit-guard waived)" ;;
  esac
  payload="$payload, retired $retired since the last summary; detail: $detail"
  case "${unusable:-0}" in
    0) ;;
    *) payload="$payload; $unusable queued row(s) need the queue file fixed" ;;
  esac
  if fm_wake_append check "merge-queue:daily:$today" "$payload"; then
    printf '%s\t%s\n' "$today" "$(now_epoch)" >"$SUMMARY_RECORD"
    printf 'summary: %s\n' "$payload"
  else
    printf 'fm-merge-queue: daily summary could not be queued for %s\n' "$today" >&2
  fi
  return 0
}

cmd_run() {
  local queue=$DEFAULT_QUEUE dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --queue)
        [ "$#" -gt 1 ] || die "--queue requires a file path"
        queue=$2
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *) die "unknown option for run: $1" ;;
    esac
  done

  if [ ! -f "$queue" ]; then
    printf 'fm-merge-queue: no queue file at %s, nothing to do\n' "$queue"
    return 0
  fi
  if [ "$dry_run" = 0 ]; then
    [ -x "$MERGE_CMD" ] || die "merge entrypoint is not runnable: $MERGE_CMD (set FM_ROOT_OVERRIDE to the home's code root)"
    # A timer runs with a bare systemd PATH, so say plainly when the forge tools
    # are not on it instead of reporting every row as an unanswered forge.
    for tool in gh gh-axi; do
      command -v "$tool" >/dev/null 2>&1 \
        || die "$tool is not on PATH ($PATH); add its directory to the unit's Environment=PATH"
    done
    lock_acquire || { printf 'fm-merge-queue: another run is in progress, skipping this tick\n'; return 0; }
    # A terminated run must stop rather than keep merging with the lock gone,
    # because the next tick would then read the same queue file concurrently.
    trap 'lock_release; cleanup_temps' EXIT
    trap 'lock_release; cleanup_temps; exit 1' INT TERM
    mkdir -p "$RECORDS"
    : >>"$LEDGER"
  fi

  local owner tmp keep seen gone newest queue_before line repo number expected task method extra
  local owner_name key ident superseded_by unmergeable row_url
  local merged=0 retired=0 skipped=0 queued=0
  owner=$(queue_owner "$queue")
  # The rewrite is published over the file the operator hand-edits, so remember
  # what the file held when this tick read it: a row added mid-tick must never be
  # overwritten by this run's rewrite.
  queue_before=$(queue_fingerprint "$queue")

  if [ "$dry_run" = 0 ]; then
    tmp=$(mktemp "$queue.XXXXXX") || die "cannot stage the queue rewrite next to $queue"
    run_temps+=("$tmp")
    # The staged file must start empty: a failed copy that left the old rows
    # behind would publish every kept row twice.
    cp -p "$queue" "$tmp" 2>/dev/null \
      || die "cannot stage the queue rewrite next to $queue (mode copy failed)"
    : >"$tmp"
    keep=$tmp
  else
    keep=
  fi
  seen=$(mktemp "${TMPDIR:-/tmp}/fm-merge-queue-seen.XXXXXX") || die "cannot stage the dedupe record"
  run_temps+=("$seen")
  gone=$(mktemp "${TMPDIR:-/tmp}/fm-merge-queue-gone.XXXXXX") || die "cannot stage the retirement record"
  run_temps+=("$gone")
  newest=$(mktemp "${TMPDIR:-/tmp}/fm-merge-queue-supersede.XXXXXX") || die "cannot stage the supersede record"
  run_temps+=("$newest" "$newest.awk")
  supersede_map "$queue" "$owner" "$newest"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        [ -z "$keep" ] || printf '%s\n' "$line" >>"$keep"
        continue
        ;;
    esac
    repo=
    number=
    expected=
    task=
    method=
    extra=
    read -r repo number expected task method extra <<<"$line"

    case "$repo" in
      */*) owner_name=${repo%%/*} ;;
      *) owner_name=$owner ;;
    esac
    if valid_owner "$owner_name"; then
      key=$(row_key "$owner_name" "${repo##*/}" "${number:-0}")
    else
      key=$(row_key '' "${repo##*/}" "${number:-0}")
    fi

    unmergeable=
    [ -z "$extra" ] || unmergeable=1
    valid_pr_number "$number" || unmergeable=1
    valid_sha_prefix "$expected" || unmergeable=1
    valid_repo_name "${repo##*/}" || unmergeable=1
    # A bad task id stays for process_row to name precisely: it reports the
    # unusable row with its own reason and never reaches the forge.

    row_url=
    if [ -z "$unmergeable" ]; then
      row_url="https://github.com/$owner_name/${repo##*/}/pull/$number"
    fi

    if [ -n "$unmergeable" ]; then
      printf 'keep %s unusable row: %s\n' "$key" "${line:0:80}"
      [ "$dry_run" = 1 ] || record "$key" unusable "unusable queue row"
      skipped=$((skipped + 1))
      [ -z "$keep" ] || printf '%s\n' "$line" >>"$keep"
      continue
    fi

    ident=$(row_identity "$key" "$expected")

    # A row re-queued after a push supersedes the older-head row for the same
    # pull request. The superseded row gets its own verdict instead of being
    # dropped, and the newest row is the one that decides.
    if row_decidable "$method" "$task"; then
      superseded_by=$(awk -F '\t' -v k="$key" '$1 == k { print $2 }' "$newest" 2>/dev/null)
      if [ -n "$superseded_by" ] && [ "$superseded_by" != "$ident" ]; then
        printf 'retire %s superseded by the newer row at %s\n' \
          "$ident" "${superseded_by##*@}"
        [ "$dry_run" = 1 ] || record "$ident" superseded \
          "superseded by the newer row at ${superseded_by##*@}" "$row_url"
        retired=$((retired + 1))
        continue
      fi
    fi

    if grep -qxF "$ident" "$gone" 2>/dev/null; then
      # A retired row's exact duplicate goes with the row that retired it.
      continue
    fi

    if grep -qxF "$ident" "$seen" 2>/dev/null; then
      [ -z "$keep" ] || printf '%s\n' "$line" >>"$keep"
      continue
    fi
    printf '%s\n' "$ident" >>"$seen"

    process_row "$repo" "$number" "$expected" "$task" "$method" "$owner" "$dry_run"

    if [ "$dry_run" = 1 ]; then
      continue
    fi

    case "$ROW_VERDICT" in
      keep)
        skipped=$((skipped + 1))
        printf '%s\n' "$line" >>"$keep"
        ;;
      'merge-refused')
        record "$ident" "$ROW_VERDICT" "$ROW_REASON" "$row_url"
        if [ "$(fail_streak "$ident")" -ge "$(max_attempts)" ]; then
          printf 'retire %s after %s failed merge attempts\n' "$ident" "$(fail_streak "$ident")"
          # Its own verdict, so the abandoned row is counted and listed as retired.
          record "$ident" abandoned "gave up after repeated merge refusals" "$row_url"
          printf '%s\n' "$ident" >>"$gone"
          retired=$((retired + 1))
        else
          skipped=$((skipped + 1))
          printf '%s\n' "$line" >>"$keep"
        fi
        ;;
      unreadable)
        record "$ident" "$ROW_VERDICT" "$ROW_REASON" "$row_url"
        skipped=$((skipped + 1))
        printf '%s\n' "$line" >>"$keep"
        ;;
      unusable)
        # Not part of a failure budget: a bad row is fixed in the file, not by
        # retrying, and it must never consume the merge-attempt allowance.
        record "$ident" "$ROW_VERDICT" "$ROW_REASON" "$row_url"
        skipped=$((skipped + 1))
        printf '%s\n' "$line" >>"$keep"
        ;;
      *)
        record "$ident" "$ROW_VERDICT" "$ROW_REASON" "$row_url"
        printf '%s\n' "$ident" >>"$gone"
        if [ "$ROW_VERDICT" = merged ]; then
          merged=$((merged + 1))
        else
          retired=$((retired + 1))
        fi
        ;;
    esac
  done <"$queue"

  queued=$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "${keep:-$queue}" 2>/dev/null || true)
  case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  rm -f "$seen" "$gone" 2>/dev/null || true

  if [ "$dry_run" = 1 ]; then
    printf 'dry run: nothing changed; %s row(s) in %s\n' "$queued" "$queue"
    return 0
  fi

  if [ -n "$keep" ]; then
    if [ "$(queue_fingerprint "$queue")" != "$queue_before" ]; then
      printf 'fm-merge-queue: %s changed during this run; leaving the rewrite for the next tick\n' "$queue"
      rm -f "$keep" 2>/dev/null || true
    elif cmp -s "$queue" "$keep"; then
      rm -f "$keep" 2>/dev/null || true
    else
      mv -f "$keep" "$queue" || die "cannot publish the queue rewrite to $queue"
    fi
  fi

  write_last_run "$merged" "$retired" "$skipped" "$queued"
  maybe_emit_daily "$queue"
  printf 'run: merged %s, retired %s, still queued/skipped %s\n' "$merged" "$retired" "$skipped"
  return 0
}

cmd_status() {
  local queue=$DEFAULT_QUEUE queued=0 line when merged retired skipped queued_at_end unusable
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --queue)
        [ "$#" -gt 1 ] || die "--queue requires a file path"
        queue=$2
        shift 2
        ;;
      *) die "unknown option for status: $1" ;;
    esac
  done
  if [ -f "$queue" ]; then
    queued=$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$queue" 2>/dev/null || true)
    case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  fi
  if [ ! -f "$queue" ]; then
    printf 'merge queue: no queue file at %s (this home has not opted in)\n' "$queue"
    return 0
  fi
  printf 'merge queue: %s row(s) in %s\n' "$queued" "$queue"
  unusable=$(queue_unusable_count "$queue" "$(queue_owner "$queue")")
  case "${unusable:-0}" in
    0) ;;
    *) printf 'unusable rows: %s (kept in the queue; the file needs fixing)\n' "$unusable" ;;
  esac
  if [ -f "$LAST_RUN" ]; then
    IFS=$'\t' read -r when merged retired skipped queued_at_end <<<"$(cat "$LAST_RUN" 2>/dev/null)" || true
    case "${when:-}" in
      ''|*[!0-9]*) ;;
      *) printf 'last run: %s - merged %s, retired %s, skipped %s, %s left queued\n' \
        "$(format_epoch "$when")" \
        "${merged:-0}" "${retired:-0}" "${skipped:-0}" "${queued_at_end:-0}" ;;
    esac
  else
    printf 'last run: none recorded\n'
  fi
  if [ -f "$SUMMARY_RECORD" ]; then
    line=$(cat "$SUMMARY_RECORD" 2>/dev/null)
    printf 'daily summary: last written %s\n' "${line%%$'\t'*}"
  fi
  return 0
}

cmd_unit() {
  [ "$#" -eq 1 ] || die "unit requires one of: service, timer"
  case "$1" in
    service)
      cat <<UNIT
[Unit]
Description=firstmate merge queue: land queued, verified pull requests
Documentation=file://$FM_ROOT/docs/merge-queue.md

[Service]
Type=oneshot
WorkingDirectory=$FM_HOME
Environment=FM_HOME=$FM_HOME
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$SCRIPT_DIR/fm-merge-queue.sh run
TimeoutStartSec=600
UNIT
      ;;
    timer)
      cat <<UNIT
[Unit]
Description=firstmate merge queue every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=30s
Unit=fm-merge-queue.service

[Install]
WantedBy=timers.target
UNIT
      ;;
    *) die "unit requires one of: service, timer" ;;
  esac
  return 0
}

main() {
  [ "$#" -gt 0 ] || {
    usage
    exit 2
  }
  local cmd=$1
  shift
  case "$cmd" in
    run) cmd_run "$@" ;;
    status) cmd_status "$@" ;;
    unit) cmd_unit "$@" ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
