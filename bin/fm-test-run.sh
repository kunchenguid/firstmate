#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for proven-concurrent work,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-scheduled --family <name>
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-concurrent-safe-families
#   fm-test-run.sh --concurrent-safe-family-jobs-max <name>
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --check-herdr-leaks
#                   snapshot fm-remote and fm-lab-* Herdr servers before and
#                   after the suite. Fail for new identities and warn for
#                   pre-existing identities that remain. Read-only; never stops
#                   a server.
#   --list          print selected script paths (one per line) and exit 0
#   --list-scheduled
#                   print selected paths longest-hint-first and exit 0
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Plain --changed and a plain list of script paths use
#                   min(4, cpus) workers when multiple selected scripts are
#                   admissible; --lane, --family, and --all stay serial unless
#                   asked for concurrency explicitly.
#                   N>1 is allowed only when every selected script is proven
#                   safe to run concurrently: individually in the proven-isolated
#                   set (bin/fm-test-isolation-proof.sh --list), or in a family
#                   carrying a recorded concurrent proof
#                   (list_concurrent_safe_families below). Overall cap is 8;
#                   family proofs may impose a lower cap. Individually proven
#                   scripts share one phase; scripts admitted only by a family
#                   proof run in a separate phase for each family. Concurrent
#                   phases are ordered longest-hint-first. Unproven stateful
#                   scripts run serially after all concurrent phases. Default is
#                   1 (serial) except for plain --changed and a plain list of
#                   script paths, which use the bounded automatic scheduler.
#   --per-script-timeout-secs N
#                   terminate a script that runs longer than N seconds and
#                   record it as exit 124 (0 disables, the default). The
#                   --changed applies 900s automatically: no real script
#                   approaches it, so it only converts a HUNG
#                   script into a bounded failure. --max-wall-ms is checked
#                   after the run and so cannot catch a hang on its own.
#                   External interruption cleanup is outside this runner's
#                   guarantee; configured per-script bounds remain authoritative.
#   --max-wall-ms N fail the run when its measured invocation wall clock exceeds
#                   N milliseconds, including an empty selection. It is
#                   evaluated after selection and suite execution and cannot
#                   interrupt a running script; per-script hangs are
#                   bounded by --per-script-timeout-secs. Pathological output
#                   sinks that block finalization are explicitly out of scope.
#   -h, --help      print this header
#
# Environment:
#   FM_TEST_TIMEOUT_SCALE  integer 1..100 (default 1) multiplying cooperating
#                          fixtures' condition-wait and operation budgets on
#                          loaded runners. Poll cadence and production defaults
#                          stay fixed; timeout-specific cases retain their
#                          explicit deadlines. Set only from measured runner
#                          slowdown (e.g. FM_TEST_TIMEOUT_SCALE=3), not to hide
#                          a failing condition. The automatic --changed script
#                          limit scales too. Explicit whole-script and wall
#                          budgets remain independent hard limits.
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#   FM_TEST_BUDGET max_wall_ms=<n> duration_ms=<n>   (only with --max-wall-ms)
#
# Exit status is non-zero if any selected script exits non-zero, a configured
# --fail-on-gate-skip token appears, the measured duration exceeds
# --max-wall-ms, timing-artifact finalization fails, or a concurrent worker
# violates its isolation check. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set (see docs/fm-test-portable-shards.md).
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all. The one
# place it is deliberately narrow is a bin/ path with no curated family: a test
# that names it is selected as that SCRIPT, because the reference is per-script
# evidence. Consumer bin/ scripts still resolve through the curated map, so
# recorded family-level coupling still expands to the whole family.
set -eu

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.monotonic() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

herdr_portable_identity_from_ps() { # <pid> <session>
  awk -v pid="$1" -v expected="$2" '
    $1 == pid && $7 !~ /^Z/ && $8 ~ /(^|\/)herdr$/ && $9 == "server" {
      for (i = 10; i <= NF; i++) {
        name = ""
        if ($i == "--session") name = $(i + 1)
        else if ($i ~ /^--session=/) { name = $i; sub(/^--session=/, "", name) }
        if (name == expected) {
          printf "%s %s %s %s %s\t%s\n", $2, $3, $4, $5, $6, name
          exit
        }
      }
    }
  '
}

herdr_candidate_from_ps() { # <pid> <session>
  awk -v pid="$1" -v expected="$2" '
    $1 == pid && $2 !~ /^Z/ && $3 ~ /(^|\/)herdr$/ && $4 == "server" {
      for (i = 5; i <= NF; i++) {
        name = ""
        if ($i == "--session") name = $(i + 1)
        else if ($i ~ /^--session=/) { name = $i; sub(/^--session=/, "", name) }
        if (name == expected) found = 1
      }
    }
    END { exit !found }
  '
}

herdr_portable_candidate_status() { # <pid> <session>
  local pid=$1 session=$2 listing
  if ! listing=$(LC_ALL=C ps -ww -p "$pid" -o pid=,stat=,args= 2>/dev/null); then
    LC_ALL=C ps -p "$pid" -o pid= >/dev/null 2>&1 && return 1
    return 2
  fi
  printf '%s\n' "$listing" | herdr_candidate_from_ps "$pid" "$session" && return 0
  return 1
}

herdr_portable_process_identity() { # <pid> <session>
  local pid=$1 session=$2 listing identity confirmed cwd lsof_bin status
  if ! listing=$(LC_ALL=C TZ=UTC0 ps -ww -p "$pid" -o pid=,lstart=,stat=,args= 2>/dev/null); then
    status=0
    herdr_portable_candidate_status "$pid" "$session" || status=$?
    [ "$status" -eq 2 ] && return 2
    return 1
  fi
  identity=$(printf '%s\n' "$listing" | herdr_portable_identity_from_ps "$pid" "$session")
  if [ -z "$identity" ]; then
    status=0
    herdr_portable_candidate_status "$pid" "$session" || status=$?
    [ "$status" -eq 2 ] && return 2
    return 1
  fi
  lsof_bin=$(command -v lsof 2>/dev/null) || return 1
  if ! listing=$(LC_ALL=C "$lsof_bin" -a -p "$pid" -d cwd -Fn 2>/dev/null); then
    status=0
    herdr_portable_candidate_status "$pid" "$session" || status=$?
    [ "$status" -eq 2 ] && return 2
    return 1
  fi
  cwd=$(printf '%s\n' "$listing" | awk 'substr($0, 1, 1) == "n" { print substr($0, 2); exit }')
  if [ -z "$cwd" ]; then
    status=0
    herdr_portable_candidate_status "$pid" "$session" || status=$?
    [ "$status" -eq 2 ] && return 2
    return 1
  fi
  if ! listing=$(LC_ALL=C TZ=UTC0 ps -ww -p "$pid" -o pid=,lstart=,stat=,args= 2>/dev/null); then
    status=0
    herdr_portable_candidate_status "$pid" "$session" || status=$?
    [ "$status" -eq 2 ] && return 2
    return 1
  fi
  confirmed=$(printf '%s\n' "$listing" | herdr_portable_identity_from_ps "$pid" "$session")
  if [ -z "$confirmed" ]; then
    status=0
    herdr_portable_candidate_status "$pid" "$session" || status=$?
    [ "$status" -eq 2 ] && return 2
    return 1
  fi
  [ "$confirmed" = "$identity" ] || return 1
  printf 'portable-unverified:%s\t%s\n' "${identity%%$'\t'*}" "$cwd"
}

herdr_server_snapshot() { # <output> <processes> <candidates>
  local output=$1 processes=$2 candidates=$3 proc_root pid session stat_line confirmed_stat
  local start confirmed_start cwd identity listing status
  local -a stat_fields=()
  proc_root=${FM_TEST_RUN_PROC_ROOT:-/proc}
  ps -ww -u "$(id -u)" -o pid=,stat=,args= > "$processes" || return 1
  awk '
    $2 !~ /^Z/ && $3 ~ /(^|\/)herdr$/ && $4 == "server" {
      for (i = 5; i <= NF; i++) {
        name = ""
        if ($i == "--session") name = $(i + 1)
        else if ($i ~ /^--session=/) { name = $i; sub(/^--session=/, "", name) }
        if (name == "fm-remote" || name ~ /^fm-lab-/) print $1, name
      }
    }
  ' "$processes" > "$candidates" || return 1
  : > "$output"
  while read -r pid session; do
    [ -n "$pid" ] && [ -n "$session" ] || continue
    if [ ! -d "$proc_root" ]; then
      status=0
      identity=$(herdr_portable_process_identity "$pid" "$session") || status=$?
      [ "$status" -ne 2 ] || continue
      [ "$status" -eq 0 ] || return 1
      start=${identity%%$'\t'*}
      cwd=${identity#*$'\t'}
      printf '%s\t%s\t%s\t%s\n' "$pid" "$start" "$session" "$cwd" >> "$output"
      continue
    fi
    if ! IFS= read -r stat_line < "$proc_root/$pid/stat"; then
      [ ! -d "$proc_root/$pid" ] && continue
      return 1
    fi
    stat_fields=()
    read -r -a stat_fields <<< "${stat_line##*) }"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    start=${stat_fields[19]}
    if ! cwd=$(readlink "$proc_root/$pid/cwd" 2>/dev/null); then
      [ ! -d "$proc_root/$pid" ] && continue
      return 1
    fi
    if ! listing=$(LC_ALL=C ps -ww -p "$pid" -o pid=,stat=,args= 2>/dev/null); then
      [ ! -d "$proc_root/$pid" ] && continue
      return 1
    fi
    if ! printf '%s\n' "$listing" | herdr_candidate_from_ps "$pid" "$session"; then
      [ ! -d "$proc_root/$pid" ] && continue
      return 1
    fi
    if ! IFS= read -r confirmed_stat < "$proc_root/$pid/stat"; then
      [ ! -d "$proc_root/$pid" ] && continue
      return 1
    fi
    stat_fields=()
    read -r -a stat_fields <<< "${confirmed_stat##*) }"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    confirmed_start=${stat_fields[19]}
    [ "$confirmed_start" = "$start" ] || return 1
    printf '%s\t%s\t%s\t%s\n' "$pid" "$start" "$session" "$cwd" >> "$output"
  done < "$candidates"
  LC_ALL=C sort -t$'\t' -k1,1n -k2,2n "$output" -o "$output"
}

herdr_baseline_has_identity() { # <baseline> <pid> <start>
  case "$3" in portable-unverified:*) return 1 ;; esac
  awk -F '\t' -v pid="$2" -v start="$3" '
    $1 == pid && $2 == start { found = 1 }
    END { exit !found }
  ' "$1"
}

RUN_STARTED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_STARTED_MS=$(now_ms)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=tests/timing-helpers.sh
. "$ROOT/tests/timing-helpers.sh"

MODE=
LIST_ONLY=0
LIST_SCHEDULED=0
LIST_FAMILIES=0
LIST_CONCURRENT_SAFE_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
CHECK_HERDR_LEAKS=0
JOBS=1
JOBS_EXPLICIT=0
JOBS_MAX=8
MAX_WALL_MS=
PER_SCRIPT_TIMEOUT_SECS=0
# Bound applied automatically on the automatic --changed path, derived from
# measured healthy runtimes with margin rather than picked: the slowest measured
# behavior test is the 341s Herdr presentation E2E, and the slowest script in a
# runner-file changed selection is tests/fm-calm-pi-extension.test.sh at 77s
# once its Chrome reap terminates. 900s leaves roughly 2.6x headroom over the
# slowest real script, so this can only ever fire on a script that is genuinely
# stuck. It is a guard, not a speed control: a HUNG script becomes a bounded
# failure instead of an unbounded suite, which is the shape that silently
# outruns a caller's invocation budget.
CHANGED_DEFAULT_TIMEOUT_SECS=$((900 * FM_TEST_TIMEOUT_SCALE))

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
PORTABLE_SERIAL_SHARDS=5

# Balance hint for a portable-serial script with no measured duration, close to
# the measured per-script mean so a newly added test neither starves nor
# overloads the shard it lands in.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=27000

# Largest share of the serial lane allowed to run on the default weight above.
# Hints are what keep the shards balanced, so once too much of the lane is
# unmeasured the balance is guesswork and one shard can reach its CI job cap
# while another sits idle. The coverage guard refuses past this share, which
# leaves room for newly added tests while making a stale hint table fail loudly
# instead of silently. docs/fm-test-portable-shards.md owns the refresh.
PORTABLE_SERIAL_MAX_UNHINTED_PERCENT=15

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

cpu_count() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$n" in
    ''|*[!0-9]*) n=1 ;;
  esac
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
#
# `standalone` is the residual family: scripts that belong to no subsystem
# family above but each own their own surface. Its membership is enumerated
# rather than inherited from the `*)` catch-all precisely because the catch-all
# also swallows every test nobody has classified yet. Keeping the two separate
# is what lets `standalone` carry a concurrent proof while a brand-new test
# lands in `unclassified` and stays serial until someone proves it.
family_for_basename() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|\
    fm-bearings-board.test.sh|\
    fm-brief.test.sh|fm-vendor-auth-probe.test.sh|\
    fm-calm-pi-extension.test.sh|fm-cd-pretool-check.test.sh|\
    fm-classify-decision-key.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-crew-state.test.sh|fm-captain-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-grok-harness.test.sh|\
    fm-kimi-harness.test.sh|fm-muse-harness.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|\
    fm-lint-workflows.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-harness-adapter-references.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-task-delivery.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-session-lock-ancestry.test.sh|fm-cursor-primary.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-drain-unread-status.test.sh|\
    fm-tool-update-check.test.sh|\
    fm-wake-queue.test.sh|fm-watch-arm.test.sh|fm-watch-checkpoint.test.sh|fm-watch-recovery-loop.test.sh|\
    fm-watch-triage.test.sh|fm-task-inbox.test.sh|\
    fm-watcher-lock.test.sh|fm-inactive-reconcile.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-backend-herdr-focus-flash-e2e.test.sh|\
    fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh|\
    fm-control-herdr-smoke.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-job.test.sh|fm-remote-job-orphan-reap.test.sh|\
    fm-remote-transport-lanes.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-reconcile.test.sh|\
    fm-secondmate-restart.test.sh|\
    fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|fm-stow-cascade.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-backlog-atomicity.test.sh|\
    fm-bootstrap.test.sh|fm-bootstrap-network-parallel.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-startup-network.test.sh|\
    fm-tangle-guard.test.sh|fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-claude-stop-autoarm-live-e2e.test.sh|\
    fm-cmux-claude-composer-live-e2e.test.sh|\
    fm-composer-matrix-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-cursor-primary-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-adapter-instructions-live-e2e.test.sh|\
    fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-muse-signals-live-e2e.test.sh|\
    fm-herdr-version-floor-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-branch-live-e2e.test.sh|\
    fm-pi-branch-responsiveness-live-e2e.test.sh|\
    fm-pi-primary-live-e2e.test.sh|fm-procevent-lavish-live-e2e.test.sh|\
    fm-sessionstart-hook-live-e2e.test.sh|fm-sessionstart-instruction-refresh-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh|\
    fm-send-inbox-doorbell-live-e2e.test.sh|\
    fm-herdr-submit-confirm-live-e2e.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-tmux-agent-liveness.test.sh|\
    fm-control.test.sh|fm-control-relaunch.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-resolve-key.test.sh|fm-send-strict.test.sh|\
    fm-send-inbox.test.sh|fm-spawn-batch.test.sh|\
    fm-spawn-dispatch-profile.test.sh|fm-claude-trust.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-check-unregister.test.sh|fm-pr-check-security.test.sh|fm-pr-merge.test.sh|\
    fm-review-diff.test.sh|fm-teardown.test.sh|fm-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-board-render.test.sh|fm-bearings-snapshot.test.sh|\
    fm-fleet-snapshot-view.test.sh|fm-home-summary-refresh.test.sh)
      printf '%s\n' snapshot-bearings
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' cmux
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' zellij
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' orca
      ;;
    fm-branch-supervision.test.sh|fm-busy-adapter-wiring.test.sh|\
    fm-busy-state.test.sh|fm-classify-corr-token.test.sh|\
    fm-claude-stop-autoarm.test.sh|fm-cursor-harness.test.sh|\
    fm-extension-binding.test.sh|fm-gitignore-config.test.sh|\
    fm-no-mistakes-required.test.sh|fm-peek-remote.test.sh|\
    fm-pending-reply.test.sh|fm-pi-branch-extension.test.sh|\
    fm-procevent-quota.test.sh|fm-procevent-when.test.sh|fm-procevent.test.sh|\
    fm-project-origin.test.sh|fm-public-followup.test.sh|fm-quota-choose.test.sh|\
    fm-remote-entrypoint.test.sh|fm-remote-secondmate-parent-binding.test.sh|\
    fm-send-remote-delivery.test.sh|fm-spawn-pool-base-freshen.test.sh|\
    fm-test-fixture-cleanup.test.sh|fm-test-fixtures.test.sh|\
    fm-voice-relay.test.sh|fm-wake-drain-open-decisions-cursor.test.sh|\
    fm-wake-drain-open-decisions.test.sh|fm-wake-drain-outcome-backstop.test.sh)
      printf '%s\n' standalone
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' optin-env ;;
    cmux|zellij|orca) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
standalone
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
}

# Exact proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Portable parallel shard 1: LPT balance of the proven-isolated set using the
# current concurrent-proof durations in docs/fm-test-isolation-proof.json.
# Execution order is longest first so wall-clock stays near the balanced sum.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-x-mode.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-test-run.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-grok-harness.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-review-diff.test.sh
tests/fm-brief.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-backend-herdr.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-crew-state.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-pr-merge.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-composer-lib.test.sh
EOF
}

# Families whose scripts are proven safe to run concurrently WITH EACH OTHER
# under the bounded local scheduler. Deliberately separate from the
# proven-isolated set, which must stay exactly equal to the portable CI shard
# union (see the coverage guard); these families keep their serial CI lane and
# only gain concurrency for a local run.
#
# Membership is empirical, never assumed:
# `bin/fm-test-isolation-proof.sh --pool <family> --jobs 4` is the owner of the
# proof, and docs/fm-test-isolation-proof.md records the dated result.
list_concurrent_safe_families() {
  cat <<'EOF'
watcher-wake-lock
pure-contract-unit
pr-forge
secondmate
session-bootstrap
standalone
EOF
}

family_is_concurrent_safe() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_concurrent_safe_families)
  return 1
}

concurrent_safe_family_jobs_max() {
  case "$1" in
    watcher-wake-lock|pure-contract-unit|pr-forge) printf '4\n' ;;
    secondmate|session-bootstrap|standalone) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}

# A script may run under --jobs when it is individually proven isolated or is
# an exact repository member of a family carrying a recorded concurrent proof.
script_allows_concurrency() {
  local s=$1 family repo_script
  is_proven_isolated_script "$s" && return 0
  family=$(family_for_basename "$(basename "$s")")
  family_is_concurrent_safe "$family" || return 1
  while IFS= read -r repo_script; do
    [ "$repo_script" = "$s" ] && return 0
  done < <(all_repo_tests)
  return 1
}

is_proven_isolated_script() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated nor real-herdr-gated. Watcher, lock, AFK, real tmux, daemon,
# secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other
# unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial() {
  local s base fam
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "real-herdr-gated" ]; then
      continue
    fi
    if is_proven_isolated_script "$s"; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifacts recorded in docs/fm-test-portable-shards.md. Each value is the
# slowest of several green runs, so the balance holds on a slow runner rather
# than only on the fastest one measured. These are balance hints only: the shard
# partition stays complete and disjoint whatever they say, so a stale hint costs
# balance rather than coverage. That doc owns the refresh procedure.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-afk-inject-e2e.test.sh 35792
tests/fm-afk-pi-herdr-return-e2e.test.sh 100
tests/fm-afk-return.test.sh 1837
tests/fm-ask-user-authority.test.sh 128
tests/fm-backend-cmux-smoke.test.sh 33
tests/fm-backend-cmux.test.sh 3657
tests/fm-backend-orca.test.sh 19253
tests/fm-backend-tmux-smoke.test.sh 393
tests/fm-backend-zellij-smoke.test.sh 23
tests/fm-backend-zellij.test.sh 9418
tests/fm-backend.test.sh 20061
tests/fm-backlog-atomicity.test.sh 122256
tests/fm-backlog-handoff.test.sh 52291
tests/fm-bearings-board-render.test.sh 1528
tests/fm-bearings-board.test.sh 4195
tests/fm-bearings-snapshot.test.sh 79954
tests/fm-bootstrap-network-parallel.test.sh 8214
tests/fm-bootstrap.test.sh 25208
tests/fm-branch-supervision.test.sh 5729
tests/fm-busy-adapter-wiring.test.sh 17873
tests/fm-busy-state.test.sh 2926
tests/fm-calm-pi-extension.test.sh 256
tests/fm-check-unregister.test.sh 481
tests/fm-classify-corr-token.test.sh 38742
tests/fm-classify-decision-key.test.sh 1167
tests/fm-claude-stop-autoarm-live-e2e.test.sh 21
tests/fm-claude-stop-autoarm.test.sh 60709
tests/fm-cmux-claude-composer-live-e2e.test.sh 23
tests/fm-codex-continuity-live-e2e.test.sh 21
tests/fm-composer-matrix-live-e2e.test.sh 23
tests/fm-control-relaunch.test.sh 48210
tests/fm-control.test.sh 37798
tests/fm-cursor-harness.test.sh 30103
tests/fm-cursor-primary-live-e2e.test.sh 21
tests/fm-cursor-primary.test.sh 54947
tests/fm-daemon.test.sh 26870
tests/fm-documentation-audiences.test.sh 732
tests/fm-extension-binding.test.sh 7398
tests/fm-fleet-snapshot-view.test.sh 8547
tests/fm-fleet-sync.test.sh 37749
tests/fm-gate-refuse.test.sh 4977
tests/fm-gitignore-config.test.sh 62
tests/fm-gotmp.test.sh 1310
tests/fm-grok-continuity-live-e2e.test.sh 20
tests/fm-grok-stop-live-e2e.test.sh 21
tests/fm-guard-stale-banner.test.sh 11218
tests/fm-harness-adapter-instructions-live-e2e.test.sh 20
tests/fm-harness-adapter-references.test.sh 55
tests/fm-harness-liveness-drift-live-e2e.test.sh 21
tests/fm-herdr-session-cleanup.test.sh 6704
tests/fm-herdr-submit-confirm-live-e2e.test.sh 23
tests/fm-herdr-version-floor-live-e2e.test.sh 23
tests/fm-home-summary-refresh.test.sh 34793
tests/fm-inactive-reconcile.test.sh 41826
tests/fm-kimi-harness.test.sh 18015
tests/fm-lint-workflows.test.sh 855
tests/fm-muse-harness.test.sh 55572
tests/fm-muse-signals-live-e2e.test.sh 23
tests/fm-no-mistakes-required.test.sh 370
tests/fm-on.test.sh 11692
tests/fm-opencode-primary-live-e2e.test.sh 21
tests/fm-operational-input.test.sh 231
tests/fm-peek-remote.test.sh 1018
tests/fm-pending-reply.test.sh 24679
tests/fm-pi-branch-extension.test.sh 22239
tests/fm-pi-branch-live-e2e.test.sh 56
tests/fm-pi-branch-responsiveness-live-e2e.test.sh 21
tests/fm-pi-primary-live-e2e.test.sh 20
tests/fm-procevent-lavish-live-e2e.test.sh 5
tests/fm-pi-watch-extension.test.sh 42970
tests/fm-pr-check-security.test.sh 160475
tests/fm-procevent-quota.test.sh 1949
tests/fm-procevent-when.test.sh 17392
tests/fm-procevent.test.sh 69715
tests/fm-project-origin.test.sh 137
tests/fm-public-followup.test.sh 196745
tests/fm-quota-array-dispatch-live-e2e.test.sh 21
tests/fm-quota-choose.test.sh 1461
tests/fm-remote-backlog-handoff.test.sh 41432
tests/fm-remote-doctor.test.sh 5198
tests/fm-remote-entrypoint.test.sh 132
tests/fm-remote-job-orphan-reap.test.sh 2972
tests/fm-remote-job.test.sh 59603
tests/fm-remote-reply.test.sh 101690
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 209631
tests/fm-remote-secondmate-parent-binding.test.sh 29562
tests/fm-remote-secondmate-trace-context.test.sh 67096
tests/fm-remote-transport-lanes.test.sh 63140
tests/fm-secondmate-harness.test.sh 151589
tests/fm-secondmate-lifecycle-e2e.test.sh 8793
tests/fm-secondmate-liveness.test.sh 18146
tests/fm-secondmate-reconcile.test.sh 62726
tests/fm-secondmate-safety.test.sh 57689
tests/fm-secondmate-sync.test.sh 17183
tests/fm-send-inbox-doorbell-live-e2e.test.sh 22
tests/fm-send-inbox.test.sh 38956
tests/fm-send-remote-delivery.test.sh 27686
tests/fm-send-resolve-key.test.sh 19619
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 51
tests/fm-send-secondmate-marker.test.sh 6252
tests/fm-session-lock-ancestry.test.sh 1414
tests/fm-session-start.test.sh 156952
tests/fm-sessionstart-hook-live-e2e.test.sh 20
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 22
tests/fm-sessionstart-nudge.test.sh 66194
tests/fm-shared-captain-inheritance.test.sh 6108
tests/fm-spawn-dispatch-profile.test.sh 63996
tests/fm-spawn-pool-base-freshen.test.sh 34920
tests/fm-spawn-worktree-settle.test.sh 5687
tests/fm-startup-memory-budget.test.sh 6964
tests/fm-startup-network.test.sh 54700
tests/fm-stow-cascade.test.sh 3101
tests/fm-subagent-pretool-check.test.sh 1030
tests/fm-supervision-events.test.sh 719
tests/fm-tangle-guard.test.sh 9662
tests/fm-task-delivery.test.sh 5952
tests/fm-task-inbox.test.sh 25369
tests/fm-teardown-endpoint-safety.test.sh 4620
tests/fm-teardown.test.sh 97603
tests/fm-test-fixture-cleanup.test.sh 915
tests/fm-test-fixtures.test.sh 151
tests/fm-test-isolation-proof.test.sh 2567
tests/fm-tmux-agent-liveness.test.sh 1516
tests/fm-tool-update-check.test.sh 14176
tests/fm-trace-context-lib.test.sh 209
tests/fm-trace-context-spawn.test.sh 44702
tests/fm-turnend-guard.test.sh 42565
tests/fm-update.test.sh 5212
tests/fm-vendor-auth-probe.test.sh 43316
tests/fm-voice-relay.test.sh 28699
tests/fm-wake-daemon-lifecycle-e2e.test.sh 7381
tests/fm-wake-drain-open-decisions-cursor.test.sh 20629
tests/fm-wake-drain-open-decisions.test.sh 6240
tests/fm-wake-drain-outcome-backstop.test.sh 15182
tests/fm-wake-drain-unread-status.test.sh 35078
tests/fm-wake-queue.test.sh 56674
tests/fm-watch-arm.test.sh 58528
tests/fm-watch-checkpoint.test.sh 5779
tests/fm-watch-recovery-loop.test.sh 58731
tests/fm-watch-triage.test.sh 262626
tests/fm-watcher-lock.test.sh 88554
EOF
}

# The portable-serial scripts with no measured hint, one per line. These fall
# back to PORTABLE_SERIAL_DEFAULT_WEIGHT_MS, so they are balanced on a guess
# rather than on evidence; the coverage guard bounds how many there may be.
portable_serial_unhinted() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-unhinted.XXXXXX") || return 1
  portable_serial_weight_hints | awk 'NF { print $1 }' | LC_ALL=C sort -u >"$tmp/hinted"
  list_portable_serial | LC_ALL=C sort -u >"$tmp/serial"
  comm -23 "$tmp/serial" "$tmp/hinted"
  rm -rf "$tmp"
}

portable_serial_weight_for() {
  local want=$1 path ms
  while read -r path ms; do
    if [ "$path" = "$want" ]; then
      printf '%s\n' "$ms"
      return 0
    fi
  done < <(portable_serial_weight_hints)
  printf '%s\n' "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS"
}

# Longest-processing-time assignment of the serial remainder to
# PORTABLE_SERIAL_SHARDS bins, printing "<shard>\t<script>" for every script.
# Deterministic: candidates are ordered by hint descending then path, and ties
# between equally loaded bins always take the lowest bin index.
portable_serial_assignments() {
  local ms script i best best_load
  local -a loads=()
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    loads[i]=0
    i=$((i + 1))
  done
  while IFS=$'\t' read -r ms script; do
    [ -n "$script" ] || continue
    best=1
    best_load=${loads[1]}
    i=2
    while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
      if [ "${loads[i]}" -lt "$best_load" ]; then
        best_load=${loads[i]}
        best=$i
      fi
      i=$((i + 1))
    done
    loads[best]=$((best_load + ms))
    printf '%s\t%s\n' "$best" "$script"
  done < <(
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      printf '%s\t%s\n' "$(portable_serial_weight_for "$script")" "$script"
    done < <(list_portable_serial) | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2
  )
}

# Parse "<k>of<n>" from a portable-serial shard lane and echo <k>, refusing when
# <n> disagrees with this script's configured count so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
portable_serial_shard_index() {
  local lane=$1 spec index count
  spec=${lane#portable-serial-}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' asks for $count portable serial shards but this runner is configured for $PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' shard index is outside 1..$PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(portable_serial_shard_index "$want")
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(portable_serial_assignments)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard unhinted serial_total
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + Herdr lane listings without
  # disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  : >"$tmp/serial_shards_raw"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    SCRIPTS=()
    select_lane "portable-serial-${shard}of${PORTABLE_SERIAL_SHARDS}"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" >>"$tmp/serial_shards_raw"
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Hint drift is what makes a balanced-looking partition run unbalanced: the
  # shards are packed from hints, so every unmeasured script is balanced on a
  # guess and enough of them let one shard reach its CI job cap while another
  # runner sits idle. Bound the unmeasured share here rather than waiting for a
  # shard to time out.
  portable_serial_unhinted >"$tmp/unhinted"
  unhinted=$(wc -l <"$tmp/unhinted" | tr -d ' ')
  serial_total=$(wc -l <"$tmp/serial" | tr -d ' ')
  if [ "$serial_total" -gt 0 ] &&
    [ "$((unhinted * 100))" -gt "$((serial_total * PORTABLE_SERIAL_MAX_UNHINTED_PERCENT))" ]; then
    log "coverage guard: $unhinted of $serial_total portable serial scripts have no measured duration hint (max ${PORTABLE_SERIAL_MAX_UNHINTED_PERCENT}%)"
    log "refresh the hints from a green run's timing artifacts: docs/fm-test-portable-shards.md"
    cat "$tmp/unhinted" >&2
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s serial=%s serial_shards=%s serial_unhinted=%s herdr=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$unhinted" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Tests that name <needle>, selected as individual scripts rather than widened
# to each referencing test's whole family. A direct reference is per-script
# evidence, so it selects per script: one real-Herdr E2E sourcing a shared
# helper must not drag in every other script of that expensive family.
scripts_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      printf '__script__:%s\n' "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# bin/ scripts other than <needle> itself that name <needle>.
bin_consumers_of() {
  local needle=$1 b
  for b in bin/*.sh bin/backends/*.sh; do
    [ -f "$b" ] || continue
    [ "$(basename "$b")" = "$needle" ] || ! grep -Fq "$needle" "$b" || printf '%s\n' "$b"
  done
}

# An unmapped bin/ path has no curated family of its own. Its blast radius is
# the tests that name it, plus the curated families of the bin/ scripts that
# consume it. Direct test references resolve per script (above) while consumer
# scripts resolve back through the curated map, so genuine family-level
# coupling a maintainer recorded is preserved while an incidental single-script
# reference no longer selects that script's whole family.
BIN_FALLBACK_DEPTH=0
families_for_unmapped_bin() {
  local path=$1 needle consumer out found=0
  needle=$(basename "$path")
  if out=$(scripts_for_test_reference "$needle"); then
    printf '%s\n' "$out"
    found=1
  fi
  if [ "$BIN_FALLBACK_DEPTH" -lt 2 ]; then
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH + 1))
    while IFS= read -r consumer; do
      [ -n "$consumer" ] || continue
      out=$(families_for_changed_path "$consumer" | grep -v '^__unmapped__:' || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        found=1
      fi
    done < <(bin_consumers_of "$needle")
    BIN_FALLBACK_DEPTH=$((BIN_FALLBACK_DEPTH - 1))
  fi
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh)
      # Deliberately the WHOLE family, not just the two contract tests. This
      # runner executes every pure-contract-unit script, so a change to it is
      # only proven by running them: its own contract test passing says the
      # runner's logic is right, not that the suite it drives still runs.
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-watch*|bin/fm-wake*|bin/fm-inactive-reconcile.sh|\
    bin/fm-classify-lib.sh|bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate*|bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*|\
    bin/fm-stow-cascade.sh)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-bootstrap.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-startup-network.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-procevent-quota.sh)
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-procevent-lavish.sh)
      printf '%s\n' "__script__:fm-procevent.test.sh"
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-quota-choose.sh)
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    .pi/extensions/fm-branch-supervision.ts|.pi/extensions/lib/fm-async-exec.ts|\
    .pi/extensions/lib/fm-branch-dispatch.ts)
      # The portable suites that actually load these files, named one by one.
      # Left unmapped, a Pi extension library resolves through the reference
      # scan, which widens to each referencing suite's WHOLE family - and
      # these suites sit in four different families, so that pulls in dozens
      # of suites with nothing to do with Pi.
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-wake-queue.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      # Whether an arriving outcome still lets the captain type is a fact only
      # a real Pi TUI can answer, so the live guards are selected too.
      printf '%s\n' live-harness-optin
      ;;
    .pi/extensions/lib/fm-operational-input.ts)
      # The same rule for the operational-input library, whose reach is wider:
      # every Pi extension that classifies or encodes operational text.
      printf '%s\n' __script__:fm-pi-branch-extension.test.sh
      printf '%s\n' __script__:fm-pi-watch-extension.test.sh
      printf '%s\n' __script__:fm-calm-pi-extension.test.sh
      printf '%s\n' __script__:fm-watch-recovery-loop.test.sh
      printf '%s\n' __script__:fm-turnend-guard.test.sh
      printf '%s\n' __script__:fm-sessionstart-nudge.test.sh
      printf '%s\n' __script__:fm-pi-primary-types.test.sh
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/fm-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-extension.mjs|bin/fm-extension.sh|docs/examples/process-event-extension/*)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      ;;
    bin/fm-procevent.sh|bin/fm-procevent-lib.sh|bin/fm-procevent-extension-capture.pl)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      printf '%s\n' __script__:fm-procevent.test.sh
      printf '%s\n' __script__:fm-procevent-when.test.sh
      printf '%s\n' __script__:fm-remote-reply.test.sh
      ;;
    bin/fm-timeout-lib.sh)
      # The shared hard bound: session start's runtime bound, the fleet/bearings
      # snapshots, the vendor auth probe, the stow cascade's per-home step, and
      # the wedge detector's worktree write probe all depend on it.
      printf '%s\n' session-bootstrap
      printf '%s\n' snapshot-bearings
      printf '%s\n' pure-contract-unit
      printf '%s\n' secondmate
      printf '%s\n' watcher-wake-lock
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-nm-run-lib.sh)
      # Shared no-mistakes run-attribution primitives, sourced by both
      # bin/fm-crew-state.sh (pure-contract-unit) and bin/fm-teardown.sh's
      # pre-teardown run abort (pr-forge).
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      ;;
    bin/fm-control-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-composer-lib.sh)
      # The shared shape catalogue is vendor-rendered signal; a change to it
      # re-selects the live guard (fm-composer-matrix-live-e2e) alongside the
      # portable families.
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-task-inbox-lib.sh)
      # The steering-inbox record/doorbell/ladder owner: fm-send's data plane
      # (backend-dispatch), the watcher's re-ring check (watcher-wake-lock),
      # and the live doorbell guard against real harnesses.
      printf '%s\n' backend-dispatch
      printf '%s\n' watcher-wake-lock
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh|\
    bin/fm-home-summary-refresh.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-lint-workflows.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-install-actionlint.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-captain-hold.sh|bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-vendor-auth-probe.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/harness-adapters/SKILL.md|.agents/skills/harness-adapters/references/*)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/lib.sh|tests/*-helpers.sh|tests/fixtures.sh)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_unmapped_bin "$path" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      families_for_test_reference "$path" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]+"${EXCLUDE_FAMILIES[@]}"}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      JOBS_EXPLICIT=1
      shift
      ;;
    --max-wall-ms)
      [ "$#" -gt 1 ] || die "--max-wall-ms requires a positive integer"
      MAX_WALL_MS=$2
      shift 2
      ;;
    --max-wall-ms=*)
      MAX_WALL_MS=${1#--max-wall-ms=}
      shift
      ;;
    --per-script-timeout-secs)
      [ "$#" -gt 1 ] || die "--per-script-timeout-secs requires a whole number of seconds"
      PER_SCRIPT_TIMEOUT_SECS=$2
      shift 2
      ;;
    --per-script-timeout-secs=*)
      PER_SCRIPT_TIMEOUT_SECS=${1#--per-script-timeout-secs=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-scheduled)
      LIST_SCHEDULED=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-concurrent-safe-families)
      LIST_CONCURRENT_SAFE_FAMILIES=1
      shift
      ;;
    --concurrent-safe-family-jobs-max)
      [ "$#" -gt 1 ] || die "--concurrent-safe-family-jobs-max requires a family name"
      concurrent_safe_family_jobs_max "$2"
      exit 0
      ;;
    --concurrent-safe-family-jobs-max=*)
      concurrent_safe_family_jobs_max "${1#--concurrent-safe-family-jobs-max=}"
      exit 0
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --check-herdr-leaks)
      CHECK_HERDR_LEAKS=1
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_CONCURRENT_SAFE_FAMILIES" -eq 1 ]; then
  list_concurrent_safe_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

if [ -n "$MAX_WALL_MS" ]; then
  case "$MAX_WALL_MS" in
    ''|*[!0-9]*) die "--max-wall-ms requires a positive integer" ;;
  esac
  [ "$MAX_WALL_MS" -gt 0 ] || die "--max-wall-ms requires a positive integer"
fi

case "$PER_SCRIPT_TIMEOUT_SECS" in
  ''|*[!0-9]*) die "--per-script-timeout-secs requires a whole number of seconds (0 disables)" ;;
esac

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$LIST_ONLY" -eq 1 ] || [ "$LIST_SCHEDULED" -eq 1 ]; then
  if [ "$LIST_SCHEDULED" -eq 1 ]; then
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      printf '%s\t%s\n' "$(portable_serial_weight_for "$s")" "$s"
    done | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
  else
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      printf '%s\n' "$s"
    done
  fi
  exit 0
fi

# An empty selection is a clean result, not a no-op that falls through. Exiting
# here also keeps every array expansion below off the empty-array path: under
# `set -u`, bash 3.2 (the stock macOS shell) treats "${arr[@]}" on an empty
# array as an unbound-variable error, while bash 4.4+ makes it a harmless no-op.
# A contributor on stock macOS who changes only documentation must still get
# total=0 and exit 0 rather than a crash.
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  empty_finished_ms=$(now_ms)
  empty_duration=$((empty_finished_ms - RUN_STARTED_MS))
  [ "$empty_duration" -ge 0 ] || empty_duration=0
  empty_rc=0
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=%s\n' "$empty_duration"
  # The budget covers the whole invocation, so a selection phase that outran it
  # still fails - reporting zero work is not the same as reporting no time.
  if [ -n "$MAX_WALL_MS" ]; then
    printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$empty_duration"
    if [ "$empty_duration" -gt "$MAX_WALL_MS" ]; then
      log "wall-clock budget exceeded: ${empty_duration}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
      empty_rc=1
    fi
  fi
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    empty_finished_iso=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$RUN_STARTED_ISO" "$empty_finished_iso" \
      "fm-test-run-${RUN_STARTED_MS}-$$" 0 0 0 "$empty_duration" \
      "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit "$empty_rc"
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# Plain --changed and a plain list of script paths both use the bounded
# representative-suite scheduler; numeric --jobs retains the strict all-script
# admission rule below. Naming scripts is how a local verification round asks
# for exactly those subjects, so it gets bounded concurrency rather than a
# serial chain of separate runs.
# The curated selections stay untouched: --lane composes CI shards whose serial
# lane must stay strictly serial, --family is what the required Herdr lane runs,
# and --all is a deliberate complete regression.
AUTO_CONCURRENCY=0
if { [ "$MODE" = changed ] || [ "$MODE" = scripts ]; } && [ "$JOBS_EXPLICIT" -eq 0 ]; then
  if [ "$MODE" = changed ] && [ "${#SCRIPTS[@]}" -gt 0 ] && [ "$PER_SCRIPT_TIMEOUT_SECS" -eq 0 ]; then
    PER_SCRIPT_TIMEOUT_SECS=$CHANGED_DEFAULT_TIMEOUT_SECS
  fi
  auto_admissible=0
  for s in "${SCRIPTS[@]}"; do
    script_allows_concurrency "$s" && auto_admissible=$((auto_admissible + 1))
  done
  if [ "$auto_admissible" -gt 1 ]; then
    JOBS=$(cpu_count)
    [ "$JOBS" -le 4 ] || JOBS=4
    [ "$JOBS" -ge 1 ] || JOBS=1
    [ "$JOBS" -eq 1 ] || AUTO_CONCURRENCY=1
  fi
fi
if [ "$JOBS" -gt 1 ] || [ "$MODE" = changed ] || [ "$MODE" = scripts ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

# An explicit --jobs names a concurrency for exactly the selection given, so an
# unproven script in it is a refusal rather than something to schedule around.
if [ "$JOBS" -gt 1 ] && [ "$AUTO_CONCURRENCY" -eq 0 ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! script_allows_concurrency "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list) and its family has no recorded concurrent proof. Unproven stateful scripts stay serial."
    fi
    if ! is_proven_isolated_script "$s"; then
      family=$(family_for_basename "$(basename "$s")")
      family_jobs_max=$(concurrent_safe_family_jobs_max "$family")
      [ "$JOBS" -le "$family_jobs_max" ] \
        || die "--jobs $JOBS refused: family $family is proven only up to $family_jobs_max concurrent workers"
    fi
  done
fi

# Split the run into proven concurrent phases and an unproven remainder.
# Individually proven scripts share one phase. Scripts admitted only by a family
# proof get a separate phase per family, because that proof establishes safety
# only among members of that family. The serial remainder runs after every
# concurrent phase, never beside another test.
CONCURRENT_SCRIPTS=()
SERIAL_TAIL_SCRIPTS=()
CONCURRENT_PHASE_BREAK=__fm_test_concurrent_phase_break__
if [ "$JOBS" -gt 1 ]; then
  SCHEDULE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-test-sched.XXXXXX")
  : >"$SCHEDULE_TMP"
  for s in "${SCRIPTS[@]}"; do
    if script_allows_concurrency "$s"; then
      if is_proven_isolated_script "$s"; then
        phase=0
      else
        family=$(family_for_basename "$(basename "$s")")
        phase=1
        while IFS= read -r admitted_family; do
          [ "$family" = "$admitted_family" ] && break
          phase=$((phase + 1))
        done < <(list_concurrent_safe_families)
      fi
      # Longest first within each isolation phase: workers are handed scripts
      # in order, so starting the longest last strands it at the tail.
      printf '%s\t%s\t%s\n' "$phase" "$(portable_serial_weight_for "$s")" "$s" >>"$SCHEDULE_TMP"
    else
      SERIAL_TAIL_SCRIPTS+=("$s")
    fi
  done
  previous_phase=
  while IFS=$'\t' read -r phase _weight s; do
    [ -n "$s" ] || continue
    if [ -n "$previous_phase" ] && [ "$phase" != "$previous_phase" ]; then
      CONCURRENT_SCRIPTS+=("$CONCURRENT_PHASE_BREAK")
    fi
    CONCURRENT_SCRIPTS+=("$s")
    previous_phase=$phase
  done < <(LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2nr -k3,3 "$SCHEDULE_TMP")
  rm -f "$SCHEDULE_TMP"
fi

if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
  [ -r "$ROOT/bin/fm-timeout-lib.sh" ] || die "per-script timeout helper not found: bin/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
declare -a WORKER_PIDS=()
declare -a WORKER_IDX=()
declare -a WORKER_SCRIPTS=()

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_run() {
  rm -rf "$RUN_TMP"
}

trap cleanup_run EXIT

RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0
HERDR_BASELINE_OK=1

if [ "$CHECK_HERDR_LEAKS" -eq 1 ]; then
  if ! herdr_server_snapshot "$RUN_TMP/herdr-baseline" \
    "$RUN_TMP/herdr-processes-before" "$RUN_TMP/herdr-candidates-before"; then
    log "could not inspect Herdr server processes before the suite"
    : > "$RUN_TMP/herdr-baseline"
    HERDR_BASELINE_OK=0
    AGG_RC=1
  fi
fi

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local base family expected gate_skip fail_delta
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

# Run <script>, capturing output to <out>. <stream> 1 also echoes it live.
# <id> only has to be unique within this run. When PER_SCRIPT_TIMEOUT_SECS is
# positive, a script that outruns it is terminated and reported as exit 124: a
# hung script must become a bounded failure rather than an unbounded suite,
# because an unbounded suite is what silently outruns its caller's budget.
run_script_bounded() {  # <script> <out> <stream> <id>
  local script=$1 out=$2 stream=$3 id=$4
  local rc
  : "$id"
  set +e
  if [ "$stream" -eq 1 ]; then
    if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
      # Expansion is intentionally deferred to the child bash passed to -c.
      # shellcheck disable=SC2016
      fm_run_timed "$PER_SCRIPT_TIMEOUT_SECS" bash -c \
        'bash "$1" 2>&1 | tee "$2"; exit "${PIPESTATUS[0]}"' _ "$script" "$out"
      rc=$?
    else
      bash "$script" 2>&1 | tee "$out"
      rc=${PIPESTATUS[0]}
    fi
  elif [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
    fm_run_timed "$PER_SCRIPT_TIMEOUT_SECS" bash "$script" >"$out" 2>&1
    rc=$?
  else
    bash "$script" >"$out" 2>&1
    rc=$?
  fi
  if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ] && [ "$rc" -eq 124 ]; then
    printf 'not ok - %s exceeded the per-script bound of %ss and was terminated\n' \
      "$script" "$PER_SCRIPT_TIMEOUT_SECS" >>"$out"
    [ "$stream" -eq 1 ] && tail -1 "$out"
  fi
  return "$rc"
}

run_one_serial() {
  local script=$1
  local base family expected out begin_iso begin_ms end_ms end_iso duration rc
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  out="$RUN_TMP/out.$TOTAL"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set +e
  # Stream live output while retaining a copy for gate-skip detection.
  run_script_bounded "$script" "$out" 1 "s$TOTAL"
  rc=$?
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for admitted scripts. Each worker gets a
  # private mode-0700 TMPDIR so mktemp roots cannot collide. Retries are never
  # used as a green strategy.
  worker_n=0
  active_workers=0

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    set +e
    wait "$pid"
    set -e
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    mode=$(stat -c %a "$work" 2>/dev/null || stat -f %Lp "$work" 2>/dev/null || echo unknown)
    case "$mode" in
      700|0700) ;;
      *)
        log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
        rc=1
        ;;
    esac
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${CONCURRENT_SCRIPTS[@]+"${CONCURRENT_SCRIPTS[@]}"}"; do
    if [ "$script" = "$CONCURRENT_PHASE_BREAK" ]; then
      while [ "$active_workers" -gt 0 ]; do
        wait_one_completed_job_worker
      done
      continue
    fi
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    (
      trap - EXIT HUP INT TERM
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      set +e
      run_script_bounded "$script" "$work/output" 0 "w$worker_n"
      rc=$?
      set -e
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    worker_pid=$!
    WORKER_PIDS[worker_n]=$worker_pid
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
  # Unproven remainder, after every concurrent worker has finished.
  for script in "${SERIAL_TAIL_SCRIPTS[@]+"${SERIAL_TAIL_SCRIPTS[@]}"}"; do
    run_one_serial "$script"
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  set +e
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  json_rc=$?
  set -e
  if [ "$json_rc" -eq 0 ]; then
    log "wrote timing artifact: $JSON_PATH"
  else
    log "timing artifact finalization failed: $JSON_PATH"
    AGG_RC=1
  fi
fi

if [ -n "$MAX_WALL_MS" ]; then
  printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$RUN_DURATION"
  if [ "$RUN_DURATION" -gt "$MAX_WALL_MS" ]; then
    log "wall-clock budget exceeded: ${RUN_DURATION}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
    AGG_RC=1
  fi
fi

if [ "$CHECK_HERDR_LEAKS" -eq 1 ]; then
  if herdr_server_snapshot "$RUN_TMP/herdr-final" \
    "$RUN_TMP/herdr-processes-after" "$RUN_TMP/herdr-candidates-after"; then
    : > "$RUN_TMP/herdr-leaks"
    while IFS=$'\t' read -r pid start session cwd; do
      [ -n "$pid" ] || continue
      if [ "$HERDR_BASELINE_OK" -eq 1 ] &&
        herdr_baseline_has_identity "$RUN_TMP/herdr-baseline" "$pid" "$start"; then
        log "WARNING: pre-existing Herdr server remains after suite: pid=$pid start=$start cwd=$cwd session=$session"
      else
        printf '%s\t%s\t%s\t%s\n' "$pid" "$start" "$session" "$cwd" >> "$RUN_TMP/herdr-leaks"
      fi
    done < "$RUN_TMP/herdr-final"
    if [ -s "$RUN_TMP/herdr-leaks" ]; then
      log "Herdr servers started during the suite (pid start session cwd):"
      cat "$RUN_TMP/herdr-leaks" >&2
      AGG_RC=1
    elif [ "$HERDR_BASELINE_OK" -eq 1 ]; then
      log "no new fm-remote or fm-lab-* Herdr server survived the suite"
    fi
  else
    log "could not inspect Herdr server processes after the suite"
    AGG_RC=1
  fi
fi

exit "$AGG_RC"
