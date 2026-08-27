#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for the proven-isolated set,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, --compare-commits, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#   fm-test-run.sh --compare-commits <base> <head> --output-dir <dir>
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Base/head partition (isolated execution):
#   fm-test-run.sh --compare-commits <base> <head> --output-dir <dir> [--script-timeout <seconds>]
#   Resolves both refs once, checks each out detached in an independent local
#   clone, and writes base.json, head.json, and partition.json. Every independently
#   enumerated script receives passed, failed, timed_out, skipped, or errored;
#   an interrupted in-flight row remains running. Each script runs in its own
#   process group under a hard bound (default: 300s). Candidate introduced and
#   regressed transitions are re-run once on both sides before classification.
#   The command exits non-zero for confirmed introduced/regressed outcomes,
#   deleted or skipped coverage, inventory refusal, or checkout-integrity error;
#   inherited failures and explicitly recorded flakes do not fail by themselves.
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --list          print selected script paths (one per line) and exit 0
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
#                   Default is 1 (serial). N>1 is allowed only when every
#                   selected script is in the proven-isolated set
#                   (bin/fm-test-isolation-proof.sh --list). Cap is 8. Stateful
#                   families never schedule under --jobs.
#   --script-timeout N
#                   per-script bound in seconds for --compare-commits (default: 300).
#   --output-dir D  fresh artifact directory for --compare-commits.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#
# Exit status is non-zero if any selected script exits non-zero or a configured
# --fail-on-gate-skip token appears. Other gate skips (first meaningful line
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
# under-selecting, and never expands to the complete suite unless --all.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
COMPARE_BASE=
COMPARE_HEAD=
COMPARE_OUTPUT_DIR=
SCRIPT_TIMEOUT=300
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=1
JOBS_MAX=8

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
PORTABLE_SERIAL_SHARDS=4

# Balance hint for a portable-serial script with no measured duration, close to
# the measured per-script mean so a newly added test neither starves nor
# overloads the shard it lands in.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=20000

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

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    # Second precision only when python3 is unavailable.
    echo $(($(date +%s) * 1000))
  fi
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
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
    fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh|\
    fm-control-herdr-smoke.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-job.test.sh|fm-remote-job-orphan-reap.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-reconcile.test.sh|\
    fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|fm-stow-cascade.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-bootstrap.test.sh|fm-bootstrap-network-parallel.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-startup-network.test.sh|\
    fm-tangle-guard.test.sh|fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-cmux-claude-composer-live-e2e.test.sh|\
    fm-composer-matrix-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-cursor-primary-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-muse-signals-live-e2e.test.sh|\
    fm-herdr-version-floor-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-branch-live-e2e.test.sh|\
    fm-pi-primary-live-e2e.test.sh|\
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
    fm-spawn-dispatch-profile.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-pr-check-security.test.sh|fm-pr-merge.test.sh|fm-review-diff.test.sh|\
    fm-teardown.test.sh|fm-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-board-render.test.sh|fm-bearings-snapshot.test.sh|\
    fm-fleet-snapshot-view.test.sh)
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
# artifact recorded in docs/fm-test-portable-shards.md. These are balance hints
# only: the shard partition stays complete and disjoint whatever they say, so a
# stale hint costs balance rather than coverage. That doc owns the refresh
# procedure.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-afk-inject-e2e.test.sh 35900
tests/fm-afk-pi-herdr-return-e2e.test.sh 66
tests/fm-afk-return.test.sh 3974
tests/fm-ask-user-authority.test.sh 83
tests/fm-backend-cmux-smoke.test.sh 30
tests/fm-backend-cmux.test.sh 3351
tests/fm-backend-herdr-focus-flash-e2e.test.sh 21
tests/fm-backend-orca.test.sh 14681
tests/fm-backend-tmux-smoke.test.sh 361
tests/fm-backend-zellij-smoke.test.sh 22
tests/fm-backend-zellij.test.sh 8297
tests/fm-backend.test.sh 17169
tests/fm-backlog-handoff.test.sh 4157
tests/fm-bearings-board.test.sh 3385
tests/fm-bearings-snapshot.test.sh 68659
tests/fm-bootstrap-network-parallel.test.sh 8000
tests/fm-bootstrap.test.sh 38417
tests/fm-busy-adapter-wiring.test.sh 14880
tests/fm-busy-state.test.sh 714
tests/fm-calm-pi-extension.test.sh 464
tests/fm-classify-decision-key.test.sh 928
tests/fm-claude-stop-autoarm-live-e2e.test.sh 30
tests/fm-claude-stop-autoarm.test.sh 60633
tests/fm-cmux-claude-composer-live-e2e.test.sh 20
tests/fm-codex-continuity-live-e2e.test.sh 19
tests/fm-composer-matrix-live-e2e.test.sh 21
tests/fm-control-relaunch.test.sh 31881
tests/fm-control.test.sh 36712
tests/fm-cursor-harness.test.sh 30071
tests/fm-cursor-primary-live-e2e.test.sh 20
tests/fm-cursor-primary.test.sh 52324
tests/fm-daemon.test.sh 25834
tests/fm-documentation-audiences.test.sh 642
tests/fm-fleet-snapshot-view.test.sh 6995
tests/fm-fleet-sync.test.sh 20194
tests/fm-gate-refuse.test.sh 4071
tests/fm-gitignore-config.test.sh 63
tests/fm-gotmp.test.sh 762
tests/fm-grok-continuity-live-e2e.test.sh 19
tests/fm-grok-stop-live-e2e.test.sh 21
tests/fm-guard-stale-banner.test.sh 11280
tests/fm-harness-liveness-drift-live-e2e.test.sh 19
tests/fm-herdr-session-cleanup.test.sh 14120
tests/fm-herdr-submit-confirm-live-e2e.test.sh 20
tests/fm-herdr-version-floor-live-e2e.test.sh 20
tests/fm-inactive-reconcile.test.sh 41671
tests/fm-kimi-harness.test.sh 15092
tests/fm-lint-workflows.test.sh 744
tests/fm-muse-harness.test.sh 27414
tests/fm-muse-signals-live-e2e.test.sh 21
tests/fm-on.test.sh 8602
tests/fm-opencode-primary-live-e2e.test.sh 22
tests/fm-operational-input.test.sh 246
tests/fm-peek-remote.test.sh 848
tests/fm-pending-reply.test.sh 19488
tests/fm-pi-primary-live-e2e.test.sh 41
tests/fm-pi-watch-extension.test.sh 17979
tests/fm-pr-check-security.test.sh 250417
tests/fm-procevent-when.test.sh 15249
tests/fm-procevent.test.sh 53142
tests/fm-project-origin.test.sh 105
tests/fm-public-followup.test.sh 36301
tests/fm-quota-array-dispatch-live-e2e.test.sh 18
tests/fm-remote-backlog-handoff.test.sh 20389
tests/fm-remote-doctor.test.sh 4705
tests/fm-remote-entrypoint.test.sh 98
tests/fm-remote-job-orphan-reap.test.sh 2903
tests/fm-remote-job.test.sh 48068
tests/fm-remote-reply.test.sh 40906
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 170240
tests/fm-remote-secondmate-parent-binding.test.sh 13064
tests/fm-remote-secondmate-trace-context.test.sh 39927
tests/fm-secondmate-harness.test.sh 123471
tests/fm-secondmate-lifecycle-e2e.test.sh 6539
tests/fm-secondmate-liveness.test.sh 16365
tests/fm-secondmate-safety.test.sh 49011
tests/fm-secondmate-sync.test.sh 29236
tests/fm-send-remote-delivery.test.sh 4892
tests/fm-send-resolve-key.test.sh 13450
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 45
tests/fm-send-secondmate-marker.test.sh 4439
tests/fm-session-lock-ancestry.test.sh 1205
tests/fm-session-start.test.sh 144836
tests/fm-sessionstart-hook-live-e2e.test.sh 21
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 21
tests/fm-sessionstart-nudge.test.sh 26684
tests/fm-shared-captain-inheritance.test.sh 10672
tests/fm-spawn-dispatch-profile.test.sh 57765
tests/fm-spawn-pool-base-freshen.test.sh 13257
tests/fm-spawn-worktree-settle.test.sh 4828
tests/fm-startup-memory-budget.test.sh 6550
tests/fm-startup-network.test.sh 48888
tests/fm-stow-cascade.test.sh 2986
tests/fm-subagent-pretool-check.test.sh 1066
tests/fm-supervision-events.test.sh 1431
tests/fm-tangle-guard.test.sh 8364
tests/fm-task-delivery.test.sh 2414
tests/fm-teardown-endpoint-safety.test.sh 7295
tests/fm-teardown.test.sh 87400
tests/fm-test-fixture-cleanup.test.sh 532
tests/fm-test-isolation-proof.test.sh 451
tests/fm-tmux-agent-liveness.test.sh 4065
tests/fm-tool-update-check.test.sh 12846
tests/fm-trace-context-lib.test.sh 194
tests/fm-trace-context-spawn.test.sh 35325
tests/fm-turnend-guard.test.sh 34915
tests/fm-update.test.sh 5280
tests/fm-vendor-auth-probe.test.sh 43243
tests/fm-wake-daemon-lifecycle-e2e.test.sh 6219
tests/fm-wake-drain-open-decisions-cursor.test.sh 17357
tests/fm-wake-drain-open-decisions.test.sh 11300
tests/fm-wake-drain-unread-status.test.sh 25214
tests/fm-wake-queue.test.sh 30887
tests/fm-watch-arm.test.sh 53598
tests/fm-watch-checkpoint.test.sh 5293
tests/fm-watch-recovery-loop.test.sh 58721
tests/fm-watch-triage.test.sh 142409
tests/fm-watcher-lock.test.sh 54364
EOF
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
  local tmp missing extra a b shard
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
    printf '%s\n' "${SCRIPTS[@]}" >>"$tmp/serial_shards_raw"
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

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s serial=%s serial_shards=%s herdr=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
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

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/fm-test-run.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
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
    bin/fm-gate-refuse*|bin/fm-lock*|bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/fm-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
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
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh)
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
    tests/lib.sh|tests/*-helpers.sh)
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
        families_for_test_reference "$(basename "$path")" \
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
    for ex in "${EXCLUDE_FAMILIES[@]}"; do
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

compare_commits() {
  local base_ref=$1 head_ref=$2 output_dir=$3 script_timeout=$4
  command -v python3 >/dev/null 2>&1 || die "--compare-commits requires python3"
  python3 - "$ROOT" "$base_ref" "$head_ref" "$output_dir" "$script_timeout" <<'PY'
import collections
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1]).resolve()
base_ref, head_ref = sys.argv[2], sys.argv[3]
output_dir = pathlib.Path(sys.argv[4]).resolve()
timeout_seconds = int(sys.argv[5])
active_proc = None
inventories = []
confirmations = {}
temp_root = None
termination = None


def git(*args, cwd=root, check=True):
    return subprocess.run(
        ["git", *args], cwd=cwd, check=check, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )


def resolve_commit(ref):
    try:
        return git("rev-parse", "--verify", f"{ref}^{{commit}}").stdout.strip()
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"commit not found: {ref}: {exc.stderr.strip()}") from exc


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    stage = path.with_name(path.name + ".tmp")
    stage.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(stage, path)


def checkout_state(copy):
    head = git("rev-parse", "HEAD", cwd=copy).stdout.strip()
    detached = git("symbolic-ref", "-q", "HEAD", cwd=copy, check=False).returncode != 0
    clean = git("status", "--porcelain", "--untracked-files=all", cwd=copy).stdout == ""
    return head, detached, clean


def inventory_summary(rows):
    counts = collections.Counter(row["outcome"] for row in rows)
    return {
        "total": len(rows),
        "passed": counts["passed"],
        "failed": counts["failed"],
        "timed_out": counts["timed_out"],
        "skipped": counts["skipped"],
        "errored": counts["errored"],
        "running": counts["running"],
    }


def reconcile(doc):
    expected = doc["expected_scripts"]
    discovered = doc["discovered_scripts"]
    inventoried = [row["path"] for row in doc["scripts"]]
    missing = sorted(set(expected) - set(inventoried))
    extra = sorted(set(inventoried) - set(expected))
    missing_from_discovery = sorted(set(expected) - set(discovered))
    extra_in_discovery = sorted(set(discovered) - set(expected))
    duplicates = sorted(path for path, count in collections.Counter(inventoried).items() if count != 1)
    ok = bool(
        expected == discovered == inventoried
        and not missing and not extra
        and not missing_from_discovery and not extra_in_discovery
        and not duplicates
    )
    doc["reconciliation"] = {
        "accounted": ok,
        "expected_count": len(expected),
        "discovered_count": len(discovered),
        "inventory_count": len(inventoried),
        "missing": missing,
        "extra": extra,
        "missing_from_discovery": missing_from_discovery,
        "extra_in_discovery": extra_in_discovery,
        "duplicates": duplicates,
    }
    doc["summary"] = inventory_summary(doc["scripts"])
    return ok


def write_inventory(doc):
    reconcile(doc)
    atomic_json(output_dir / f"{doc['label']}.json", doc)


def first_meaningful_line(path):
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if line.strip():
                return line.strip()
    return ""


def stop_process_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=0.2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def tracked_test_scripts(copy, commit):
    tree = subprocess.run(
        ["git", "ls-tree", "-rz", "--name-only", commit, "--", "tests"],
        cwd=copy, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout
    scripts = set()
    for raw_path in tree.split(b"\0"):
        if not raw_path:
            continue
        path = os.fsdecode(raw_path)
        parts = pathlib.PurePosixPath(path).parts
        if len(parts) >= 2 and parts[0] == "tests" and parts[1].endswith(".test.sh"):
            scripts.add(f"tests/{parts[1]}")
    return sorted(scripts)


def make_inventory(label, requested_ref, commit, copy):
    expected_scripts = tracked_test_scripts(copy, commit)
    discovered_scripts = sorted(
        str(path.relative_to(copy))
        for path in (copy / "tests").glob("*.test.sh")
        if path.is_file()
    )
    rows = []
    for script in expected_scripts:
        rows.append({
            "path": script,
            "outcome": "errored",
            "exit_code": None,
            "duration_ms": 0,
            "detail": "not_run: runner interrupted before execution",
            "log": f"{label}/logs/{pathlib.Path(script).name}.log",
        })
    head, detached, clean = checkout_state(copy)
    doc = {
        "schema_version": 2,
        "label": label,
        "requested_ref": requested_ref,
        "commit": commit,
        "timeout_seconds": timeout_seconds,
        "checkout": {
            "path": str(copy),
            "initial_head": head,
            "final_head": None,
            "detached": detached,
            "clean_before": clean,
            "clean_after": None,
            "invariant_ok": head == commit and detached and clean,
        },
        "expected_scripts": expected_scripts,
        "discovered_scripts": discovered_scripts,
        "scripts": rows,
    }
    write_inventory(doc)
    return doc


def run_inventory(doc, copy):
    global active_proc
    compromised = not doc["checkout"]["invariant_ok"]
    for row in doc["scripts"]:
        if compromised:
            row["detail"] = "not_run: checkout invariant was already violated"
            write_inventory(doc)
            continue

        before_head, before_detached, before_clean = checkout_state(copy)
        if before_head != doc["commit"] or not before_detached or not before_clean:
            row["detail"] = (
                "not_run: checkout invariant violated before script "
                f"(head={before_head}, detached={before_detached}, clean={before_clean})"
            )
            compromised = True
            doc["checkout"]["invariant_ok"] = False
            write_inventory(doc)
            continue

        script_path = copy / row["path"]
        log_path = output_dir / row["log"]
        log_path.parent.mkdir(parents=True, exist_ok=True)
        if not script_path.is_file():
            row["detail"] = "not_run: tracked test path is not a regular file"
            write_inventory(doc)
            continue

        env = os.environ.copy()
        for name in (
            "FM_HOME", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_ROOT_OVERRIDE",
            "FM_PROJECTS_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_BACKEND",
        ):
            env.pop(name, None)
        script_tmp = pathlib.Path(tempfile.mkdtemp(prefix=f"fm-compare-{doc['label']}-"))
        env["TMPDIR"] = str(script_tmp)
        env["TMP"] = str(script_tmp)
        started = time.monotonic()
        try:
            with log_path.open("wb") as log_stream:
                proc = subprocess.Popen(
                    ["/bin/bash", row["path"]], cwd=copy, env=env,
                    stdout=log_stream, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                active_proc = proc
                row["outcome"] = "running"
                row["detail"] = "in flight"
                row["exit_code"] = None
                write_inventory(doc)
                try:
                    returncode = proc.wait(timeout=timeout_seconds)
                except subprocess.TimeoutExpired:
                    stop_process_group(proc)
                    returncode = 124
                    row["outcome"] = "timed_out"
                    row["detail"] = f"per-script timeout after {timeout_seconds}s"
                else:
                    if returncode == 0:
                        if first_meaningful_line(log_path).startswith("skip:"):
                            row["outcome"] = "skipped"
                            row["detail"] = "first meaningful output line is a gate skip"
                        else:
                            row["outcome"] = "passed"
                            row["detail"] = "exit 0"
                    elif returncode < 0:
                        row["outcome"] = "errored"
                        row["detail"] = f"terminated by signal {-returncode}"
                    else:
                        row["outcome"] = "failed"
                        row["detail"] = f"exit {returncode}"
                row["exit_code"] = returncode
                active_proc = None
        except OSError as exc:
            row["outcome"] = "errored"
            row["detail"] = f"runner error: {exc}"
            row["exit_code"] = None
        finally:
            active_proc = None
            row["duration_ms"] = max(0, int((time.monotonic() - started) * 1000))
            shutil.rmtree(script_tmp, ignore_errors=True)

        after_head, after_detached, after_clean = checkout_state(copy)
        if after_head != doc["commit"] or not after_detached or not after_clean:
            row["outcome"] = "errored"
            row["detail"] = (
                "checkout invariant violated by script "
                f"(head={after_head}, detached={after_detached}, clean={after_clean})"
            )
            compromised = True
            doc["checkout"]["invariant_ok"] = False
        write_inventory(doc)
        print(
            "FM_TEST_COMPARE_ROW "
            f"side={doc['label']} script={row['path']} outcome={row['outcome']} "
            f"exit={row['exit_code']} duration_ms={row['duration_ms']}",
            flush=True,
        )

    final_head, final_detached, final_clean = checkout_state(copy)
    doc["checkout"]["final_head"] = final_head
    doc["checkout"]["clean_after"] = final_clean
    doc["checkout"]["invariant_ok"] = bool(
        doc["checkout"]["invariant_ok"]
        and final_head == doc["commit"] and final_detached and final_clean
    )
    write_inventory(doc)


def run_confirmation(doc, copy, path, attempt):
    global active_proc
    if path not in doc["expected_scripts"]:
        confirmations[path][doc["label"]].append("absent")
        return "absent"
    script_path = copy / path
    if not script_path.is_file():
        confirmations[path][doc["label"]].append("errored")
        return "errored"
    before_head, before_detached, before_clean = checkout_state(copy)
    if before_head != doc["commit"] or not before_detached or not before_clean:
        doc["checkout"]["invariant_ok"] = False
        write_inventory(doc)
        confirmations[path][doc["label"]].append("errored")
        return "errored"
    log_path = output_dir / doc["label"] / "confirmations" / (
        f"{pathlib.Path(path).name}.attempt-{attempt}.log"
    )
    log_path.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for name in (
        "FM_HOME", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_ROOT_OVERRIDE",
        "FM_PROJECTS_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_BACKEND",
    ):
        env.pop(name, None)
    script_tmp = pathlib.Path(tempfile.mkdtemp(prefix=f"fm-confirm-{doc['label']}-"))
    env["TMPDIR"] = str(script_tmp)
    env["TMP"] = str(script_tmp)
    outcome = "errored"
    confirmations[path][doc["label"]].append("running")
    write_current_partition()
    try:
        with log_path.open("wb") as log_stream:
            proc = subprocess.Popen(
                ["/bin/bash", path], cwd=copy, env=env,
                stdout=log_stream, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            active_proc = proc
            try:
                returncode = proc.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                stop_process_group(proc)
                outcome = "timed_out"
            else:
                if returncode == 0:
                    outcome = (
                        "skipped" if first_meaningful_line(log_path).startswith("skip:")
                        else "passed"
                    )
                elif returncode < 0:
                    outcome = "errored"
                else:
                    outcome = "failed"
    except OSError:
        outcome = "errored"
    finally:
        active_proc = None
        shutil.rmtree(script_tmp, ignore_errors=True)
    after_head, after_detached, after_clean = checkout_state(copy)
    if after_head != doc["commit"] or not after_detached or not after_clean:
        doc["checkout"]["invariant_ok"] = False
        outcome = "errored"
        write_inventory(doc)
    confirmations[path][doc["label"]][-1] = outcome
    write_current_partition()
    print(
        "FM_TEST_COMPARE_CONFIRMATION "
        f"side={doc['label']} script={path} attempt={attempt} outcome={outcome}",
        flush=True,
    )
    return outcome


def outcome_map(doc):
    return {row["path"]: row["outcome"] for row in doc["scripts"]}


def transition_entry(path, base_outcome, head_outcome, confirmation=None):
    entry = {
        "path": path,
        "base_outcome": base_outcome,
        "head_outcome": head_outcome,
    }
    if confirmation is not None:
        entry["base_observations"] = confirmation["base"]
        entry["head_observations"] = confirmation["head"]
    return entry


def make_partition(base, head):
    base_rows = outcome_map(base)
    head_rows = outcome_map(head)
    all_paths = sorted(set(base["expected_scripts"]) | set(head["expected_scripts"]))
    inherited = []
    inherited_timeouts = []
    introduced = []
    regressed = []
    fixed = []
    now_passing = []
    no_longer_measured = []
    flaky = []
    comparable_outcomes = 0
    for path in all_paths:
        base_outcome = base_rows.get(path, "absent")
        head_outcome = head_rows.get(path, "absent")
        confirmation = confirmations.get(path)
        entry = transition_entry(path, base_outcome, head_outcome, confirmation)
        if base_outcome in {"passed", "failed"} and head_outcome in {"passed", "failed"}:
            comparable_outcomes += 1
        if base_outcome == head_outcome:
            if base_outcome in {"failed", "errored"}:
                inherited.append(entry)
            elif base_outcome == "timed_out":
                inherited_timeouts.append(entry)
            continue
        if head_outcome == "absent" and base_outcome != "absent":
            no_longer_measured.append(entry)
            continue
        if head_outcome == "skipped" and base_outcome not in {"absent", "skipped"}:
            no_longer_measured.append(entry)
            continue
        if base_outcome == "failed" and head_outcome == "passed":
            fixed.append(entry)
            continue
        if head_outcome == "passed" and base_outcome in {"timed_out", "errored", "skipped"}:
            now_passing.append(entry)
            continue
        candidate_bucket = None
        if base_outcome == "absent" and head_outcome in {"failed", "timed_out", "errored"}:
            candidate_bucket = introduced
        elif base_outcome != "absent" and head_outcome in {"failed", "timed_out", "errored"}:
            candidate_bucket = regressed
        if candidate_bucket is not None:
            retry_outcomes = [] if confirmation is None else (
                confirmation["base"][1:] + confirmation["head"][1:]
            )
            if (
                confirmation is not None
                and confirmation["head"][-1] == "passed"
                and not any(outcome in {"errored", "running", "skipped", "timed_out"}
                            for outcome in retry_outcomes)
            ):
                flaky.append(entry)
            else:
                candidate_bucket.append(entry)
    comparison_total = len(all_paths)
    return {
        "schema_version": 2,
        "base_commit": base["commit"],
        "head_commit": head["commit"],
        "inventory_reconciled": bool(
            base["reconciliation"]["accounted"]
            and head["reconciliation"]["accounted"]
        ),
        "checkout_invariants_ok": bool(
            base["checkout"]["invariant_ok"]
            and head["checkout"]["invariant_ok"]
        ),
        "inherited_failures": inherited,
        "inherited_timeouts": inherited_timeouts,
        "head_introduced_failures": introduced,
        "regressed": regressed,
        "fixed": fixed,
        "now_passing": now_passing,
        "no_longer_measured": no_longer_measured,
        "flaky_transitions": flaky,
        "summary": {
            "inherited": len(inherited),
            "inherited_timeouts": len(inherited_timeouts),
            "head_introduced": len(introduced),
            "regressed": len(regressed),
            "fixed": len(fixed),
            "now_passing": len(now_passing),
            "no_longer_measured": len(no_longer_measured),
            "flaky": len(flaky),
            "compared_outcomes": comparable_outcomes,
            "comparison_total": comparison_total,
            "coverage": f"{comparable_outcomes}/{comparison_total}",
        },
    }


def confirm_regression_candidates(partition, base, head, copies):
    paths = sorted(
        row["path"]
        for bucket in (partition["head_introduced_failures"], partition["regressed"])
        for row in bucket
    )
    base_rows = outcome_map(base)
    head_rows = outcome_map(head)
    for path in paths:
        observation = {
            "base": [base_rows.get(path, "absent")],
            "head": [head_rows.get(path, "absent")],
        }
        confirmations[path] = observation
        run_confirmation(base, copies["base"], path, 1)
        run_confirmation(head, copies["head"], path, 1)


def current_partition():
    if len(inventories) == 2:
        partition = make_partition(*inventories)
    else:
        partition = {
            "schema_version": 2,
            "base_commit": base_commit,
            "head_commit": head_commit,
            "inventory_reconciled": False,
            "checkout_invariants_ok": False,
            "incomplete": True,
            "inventories_available": len(inventories),
        }
    if termination is not None:
        partition["termination"] = termination
    return partition


def write_current_partition():
    atomic_json(output_dir / "partition.json", current_partition())


def handle_signal(signum, _frame):
    global termination
    termination = {
        "complete": False,
        "signal": signal.Signals(signum).name,
        "exit_code": 128 + signum,
    }
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if active_proc is not None:
        stop_process_group(active_proc)
    for doc in inventories:
        write_inventory(doc)
    write_current_partition()
    raise SystemExit(128 + signum)


base_commit = None
head_commit = None
try:
    if timeout_seconds < 1:
        raise RuntimeError("--script-timeout must be a positive integer")
    if output_dir.exists():
        if not output_dir.is_dir():
            raise RuntimeError(f"--output-dir must be a directory: {output_dir}")
        if any(output_dir.iterdir()):
            raise RuntimeError(f"--output-dir must be absent or empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    base_commit = resolve_commit(base_ref)
    head_commit = resolve_commit(head_ref)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    temp_root = pathlib.Path(tempfile.mkdtemp(prefix="fm-test-compare-"))
    copies = {}
    for label, commit in (("base", base_commit), ("head", head_commit)):
        copy = temp_root / label
        clone = subprocess.run(
            ["git", "clone", "--no-local", "--no-checkout", "--quiet", str(root), str(copy)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if clone.returncode != 0:
            raise RuntimeError(f"could not create isolated {label} copy: {clone.stderr.strip()}")
        checkout = git("checkout", "--detach", "--quiet", commit, cwd=copy, check=False)
        if checkout.returncode != 0:
            raise RuntimeError(f"could not detach {label} at {commit}: {checkout.stderr.strip()}")
        copies[label] = copy

    base = make_inventory("base", base_ref, base_commit, copies["base"])
    head = make_inventory("head", head_ref, head_commit, copies["head"])
    inventories.extend((base, head))
    run_inventory(base, copies["base"])
    run_inventory(head, copies["head"])
    partition = make_partition(base, head)
    write_current_partition()
    confirm_regression_candidates(partition, base, head, copies)
    partition = make_partition(base, head)
    write_current_partition()
    for doc in (base, head):
        summary = doc["summary"]
        print(
            "FM_TEST_COMPARE_INVENTORY "
            f"side={doc['label']} commit={doc['commit']} total={summary['total']} "
            f"passed={summary['passed']} failed={summary['failed']} "
            f"timed_out={summary['timed_out']} skipped={summary['skipped']} "
            f"errored={summary['errored']} running={summary['running']} "
            f"accounted={str(doc['reconciliation']['accounted']).lower()} "
            f"checkout_ok={str(doc['checkout']['invariant_ok']).lower()}",
            flush=True,
        )
    summary = partition["summary"]
    print(
        "FM_TEST_COMPARE_PARTITION "
        f"inherited={summary['inherited']} inherited_timeouts={summary['inherited_timeouts']} "
        f"head_introduced={summary['head_introduced']} regressed={summary['regressed']} "
        f"fixed={summary['fixed']} now_passing={summary['now_passing']} "
        f"no_longer_measured={summary['no_longer_measured']} flaky={summary['flaky']} "
        f"compared_outcomes={summary['compared_outcomes']} coverage={summary['coverage']} "
        f"output_dir={output_dir}",
        flush=True,
    )
    valid = partition["inventory_reconciled"] and partition["checkout_invariants_ok"]
    refused = bool(
        partition["head_introduced_failures"]
        or partition["regressed"]
        or partition["no_longer_measured"]
        or not valid
    )
    raise SystemExit(1 if refused else 0)
except BaseException as exc:
    for doc in inventories:
        write_inventory(doc)
    if output_dir.exists() and output_dir.is_dir():
        write_current_partition()
    if isinstance(exc, SystemExit):
        raise
    print(f"fm-test-run: compare failed: {exc}", file=sys.stderr)
    raise SystemExit(2)
finally:
    if temp_root is not None:
        shutil.rmtree(temp_root, ignore_errors=True)
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
    --compare-commits)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 2 ] || die "--compare-commits requires <base> <head>"
      MODE=compare
      COMPARE_BASE=$2
      COMPARE_HEAD=$3
      shift 3
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
    --script-timeout)
      [ "$#" -gt 1 ] || die "--script-timeout requires a positive integer"
      SCRIPT_TIMEOUT=$2
      shift 2
      ;;
    --script-timeout=*)
      SCRIPT_TIMEOUT=${1#--script-timeout=}
      shift
      ;;
    --output-dir)
      [ "$#" -gt 1 ] || die "--output-dir requires a path"
      COMPARE_OUTPUT_DIR=$2
      shift 2
      ;;
    --output-dir=*)
      COMPARE_OUTPUT_DIR=${1#--output-dir=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
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

if [ "${MODE:-}" = "compare" ]; then
  [ "$LIST_ONLY" -eq 0 ] || die "--list cannot be combined with --compare-commits"
  [ -n "$COMPARE_OUTPUT_DIR" ] || die "--compare-commits requires --output-dir <dir>"
  case "$SCRIPT_TIMEOUT" in
    ''|*[!0-9]*) die "--script-timeout must be a positive integer" ;;
  esac
  [ "$SCRIPT_TIMEOUT" -ge 1 ] || die "--script-timeout must be >= 1"
  compare_commits "$COMPARE_BASE" "$COMPARE_HEAD" "$COMPARE_OUTPUT_DIR" "$SCRIPT_TIMEOUT"
  exit $?
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

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
    raw=("${SCRIPTS[@]}")
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
if [ "$JOBS" -gt 1 ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\n'
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    started=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$started" "$started" "empty" 0 0 0 0 "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit 0
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# --jobs N>1 only for the proven-isolated set. Stateful families stay serial.
if [ "$JOBS" -gt 1 ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! is_proven_isolated_script "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list). Stateful families stay serial."
    fi
  done
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
trap 'rm -rf "$RUN_TMP"' EXIT

RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

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
  # PIPESTATUS[0] is the test script; tee's exit is ignored for aggregate.
  bash "$script" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
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
  # Bounded concurrent execution for proven-isolated scripts only. Each worker
  # gets a private mode-0700 TMPDIR so mktemp roots cannot collide. Retries are
  # never used as a green strategy.
  declare -a WORKER_PIDS=()
  declare -a WORKER_IDX=()
  declare -a WORKER_SCRIPTS=()
  worker_n=0
  active_workers=0

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    set +e
    wait "$pid"
    set -e
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

  for script in "${SCRIPTS[@]}"; do
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
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      bash "$script" >"$work/output" 2>&1
      rc=$?
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    WORKER_PIDS[worker_n]=$!
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
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
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  log "wrote timing artifact: $JSON_PATH"
fi

exit "$AGG_RC"
