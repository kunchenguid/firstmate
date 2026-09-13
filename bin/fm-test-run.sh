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
#   --json <path>   write a deterministic timing artifact after the run. The
#                   artifact is written after the FM_TEST_SUMMARY verdict and
#                   an unwritable artifact is reported without changing the
#                   exit status.
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
#                   record it as exit 124. Every nonempty selection defaults to
#                   900s; pass 0 explicitly to preserve an unbounded run.
#                   --max-wall-ms is checked
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
# Placement refusal:
#   A task worker is assigned an isolated worktree, and that placement is
#   checked only when its task starts. When FM_TASK_ID marks such a worker and
#   this runner resolves to the repository's PRIMARY checkout, every executing
#   mode refuses before selecting a suite: the suite creates and switches
#   branches, and the primary is the checkout every linked worktree resolves
#   against. Inspection modes execute nothing and stay available, and a run with
#   no FM_TASK_ID set is unchanged.
#
# Exit status is non-zero if any selected script exits non-zero, a configured
# --fail-on-gate-skip token appears, the measured duration exceeds
# --max-wall-ms, timing-artifact finalization fails, or a concurrent worker
# violates its isolation check. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate; each one
# is logged with its reason and recorded in the timing artifact.
#
# expected_gate_skip classes name why a family is allowed to skip: herdr (the
# pinned real-Herdr lane), optional-binary (a backend whose binary is optional),
# live-capability (a live-harness guard governed by fm_live_gate, which records
# unavailable tools and explicit policy skips; see tests/lib.sh), or none.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are
# duration-balanced orders of that exact set (see docs/fm-test-portable-shards.md).
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

# Keep child diagnostics out of captured protocol output on hosts that do not
# provide the caller's inherited locale, WITHOUT changing what the suite reads as
# a character. Pinning plain C would do the first at the cost of the second: the
# suite asserts on multibyte content (the composer prompt glyphs ❯/›, the U+2063
# injection sentinel, codepoint-bounded outcome text), and under a byte-oriented
# locale ${#s}, ${s:0:1} and ${s#?} all count bytes, so those assertions read a
# split UTF-8 sequence instead of a character. So: take the first candidate that
# the host actually resolves to UTF-8, and fall back to C only when it has none.
fm_test_run_utf8_locale() {
  local candidate
  for candidate in "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}" C.UTF-8 en_US.UTF-8; do
    case "$candidate" in
      *[Uu][Tt][Ff]-8|*[Uu][Tt][Ff]8) ;;
      *) continue ;;
    esac
    # env, not a shell assignment: assigning an unavailable locale makes the
    # shell itself warn, which is the very noise this normalization exists to
    # keep out of the protocol stream.
    [ "$(env LC_ALL="$candidate" locale charmap 2>/dev/null)" = UTF-8 ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
LC_ALL=$(fm_test_run_utf8_locale || printf C)
export LC_ALL

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

RUN_STARTED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_STARTED_MS=$(now_ms)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
FM_DISABLED_ADAPTERS_CONFIG="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$ROOT}/config}/disabled-adapters"

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
CHANGED_REASONS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=1
JOBS_EXPLICIT=0
JOBS_MAX=8
MAX_WALL_MS=
PER_SCRIPT_TIMEOUT_SECS=0
PER_SCRIPT_TIMEOUT_EXPLICIT=0
# Bound applied automatically to every nonempty selection, derived from measured
# healthy runtimes with margin rather than picked: the slowest measured behavior
# test is the 341s Herdr presentation E2E, and the slowest script in a runner-file
# changed selection is tests/fm-calm-pi-extension.test.sh at 77s once its Chrome
# reap terminates. 900s leaves roughly 2.6x headroom over the slowest real script,
# so this can only ever fire on a script that is genuinely stuck. It is a guard,
# not a speed control: a HUNG script becomes a bounded failure instead of an
# unbounded suite, which is the shape that silently outruns a caller's budget.
DEFAULT_PER_SCRIPT_TIMEOUT_SECS=900

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

# Enforce the placement refusal described in this script's header.
#
# The primary checkout is the working tree whose own git dir IS the repository's
# common git dir; every linked worktree has a git dir under it instead. That is
# the same predicate bin/fm-spawn.sh uses to keep a launch out of the primary,
# and unlike comparing top-level paths it still holds when the primary is
# reached through a different path. When git resolves neither directory - a
# non-repository fixture, a detached copy - nothing proves this is the primary,
# so the run proceeds.
refuse_primary_checkout_for_task() {
  local task_id git_dir common_dir top
  task_id=${FM_TASK_ID:-}
  [ -n "$task_id" ] || return 0
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) \
    && git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=
  common_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 0
  [ "$git_dir" = "$common_dir" ] || return 0
  top=$(cd "$ROOT" && pwd -P)
  die "refusing to run in the repository primary checkout $top while FM_TASK_ID=$task_id is set; run from the assigned task worktree instead"
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
    fm-capture-visual-evidence-mechanism.test.sh|\
    fm-pr-body.test.sh|fm-pr-body-template-mechanism.test.sh|fm-pr-context.test.sh|\
    fm-calm-pi-extension.test.sh|fm-cd-pretool-check.test.sh|fm-idea.test.sh|\
    fm-ci-load-guard.test.sh|fm-canonical-guard-benchmark.test.sh|\
    fm-classify-decision-key.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|fm-daily.test.sh|\
    fm-crew-state.test.sh|fm-captain-hold-lifecycle.test.sh|fm-decision-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-search.test.sh|fm-grok-harness.test.sh|\
    fm-kimi-harness.test.sh|fm-muse-harness.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|fm-lint-workflows.test.sh|\
    fm-macos-scope.test.sh|\
    fm-model-telemetry.test.sh|fm-model-usage.test.sh|fm-session-digest.test.sh|fm-tachikoma.test.sh|fm-marvin.test.sh|fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-ci-water7.test.sh|fm-install-chrome.test.sh|\
    fm-quota-utilization.test.sh|\
    fm-harness-adapter-references.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|fm-skill-bugfix-pair-room.test.sh|fm-skill-war-room.test.sh|\
    fm-supervision-fault.test.sh|fm-supervision-instructions.test.sh|fm-supervision-oracle.test.sh|fm-task-delivery.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-transition-lib.test.sh|fm-unadvanceable-work.test.sh|\
    fm-record-contradictions-lib.test.sh|fm-worktree-unique-content.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh|fm-room.test.sh|test-changed.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-heavy-suite.test.sh|fm-pi-watch-extension.test.sh|\
    fm-session-lock-ancestry.test.sh|fm-cursor-primary.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-drain-unread-status.test.sh|fm-pr-context-watch.test.sh|fm-pr-fix-seat.test.sh|\
    fm-review-watches.test.sh|\
    fm-tool-update-check.test.sh|\
    fm-auto-quota-drain.test.sh|fm-wake-queue.test.sh|fm-watch-arm.test.sh|fm-watch-checkpoint.test.sh|fm-watch-recovery-loop.test.sh|\
    fm-pipeline.test.sh|\
    fm-watch-triage.test.sh|fm-task-inbox.test.sh|fm-inactive-reconcile.test.sh|\
    fm-wait-premise.test.sh|fm-wait-premise-shadow.test.sh|fm-watcher-lock.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-focus-flash-e2e.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh|\
    fm-control-herdr-smoke.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-herdr-guard.test.sh|fm-remote-job.test.sh|fm-remote-job-orphan-reap.test.sh|\
    fm-remote-transport-lanes.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-liveness-scan.test.sh|fm-secondmate-reconcile.test.sh|fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|fm-memory-doctor.test.sh|fm-stow-cascade.test.sh|\
    fm-model-catalog-inheritance.test.sh|fm-stow-cadence-lab.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-backlog-atomicity.test.sh|\
    fm-bootstrap.test.sh|fm-bootstrap-network-parallel.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-startup-network.test.sh|fm-tangle-guard.test.sh|\
    fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-claude-account-profile-live-e2e.test.sh|\
    fm-cmux-claude-composer-live-e2e.test.sh|\
    fm-composer-matrix-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-cursor-primary-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|\
    fm-harness-adapter-instructions-live-e2e.test.sh|\
    fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-muse-signals-live-e2e.test.sh|fm-rovo-signals-live-e2e.test.sh|\
    fm-herdr-version-floor-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-branch-live-e2e.test.sh|\
    fm-pi-branch-responsiveness-live-e2e.test.sh|\
    fm-pi-primary-live-e2e.test.sh|fm-pi-codex-native.test.sh|fm-omp-primary-live-e2e.test.sh|\
    fm-sessionstart-hook-live-e2e.test.sh|fm-sessionstart-instruction-refresh-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh|\
    fm-turnend-captain-comms-live-e2e.test.sh|\
    fm-stow-cadence-live-e2e.test.sh|fm-moiras-live.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-tmux-agent-liveness.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-strict.test.sh|fm-spawn-batch.test.sh|\
    fm-control.test.sh|fm-control-relaunch.test.sh|\
    fm-send-resolve-key.test.sh|fm-send-inbox.test.sh|fm-peer-message.test.sh|\
    fm-quota-cooldown.test.sh|fm-spawn-dispatch-profile.test.sh|\
    fm-agent-coauthor.test.sh|fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-check-register.test.sh|fm-check-unregister.test.sh|fm-pr-check-security.test.sh|fm-pr-merge.test.sh|fm-review-diff.test.sh|\
    fm-pr-comment-watch.test.sh|fm-pr-comment-watch-mechanism.test.sh|\
    fm-auto-retire.test.sh|fm-teardown.test.sh|fm-teardown-custody.test.sh|fm-x-mode.test.sh|fm-slack-captain-channel.test.sh|fm-slack-socket.test.sh|\
    fm-slack-captain-comms-guard.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-contract.test.sh|fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
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
    fm-live-gate.test.sh|\
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
    live-harness-optin) printf '%s\n' live-capability ;;
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
  cat <<'EOF' | filter_enabled_tests
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
tests/fm-slack-captain-channel.test.sh
EOF
}

# Portable parallel shard 1: duration-balanced order for the current partition,
# using the measured timings in docs/fm-test-isolation-proof.json. Keep this
# order aligned with that archive because --jobs 2 assigns each next script to
# the worker that becomes available first.
list_portable_parallel_1() {
  cat <<'EOF' | filter_enabled_tests
tests/fm-x-mode.test.sh
tests/fm-test-run.test.sh
tests/fm-slack-captain-channel.test.sh
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-lint.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-grok-harness.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-brief.test.sh
tests/fm-review-diff.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Portable parallel shard 2: the complementary half of that fixed partition.
list_portable_parallel_2() {
  cat <<'EOF' | filter_enabled_tests
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
# secondmate lifecycle, bootstrap, the live-harness-optin family, GUI-backend,
# and other unproven work stays here. Derived rather than enumerated so a newly added test
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
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-afk-inject-e2e.test.sh 430
tests/fm-afk-inject-herdr-e2e.test.sh 544
tests/fm-afk-launch.test.sh 961
tests/fm-afk-pi-herdr-return-e2e.test.sh 297
tests/fm-afk-return.test.sh 283
tests/fm-afk-start.test.sh 31
tests/fm-agent-coauthor.test.sh 404
tests/fm-arm-pretool-check.test.sh 501
tests/fm-ask-user-authority.test.sh 58
tests/fm-auto-quota-drain.test.sh 1040
tests/fm-auto-retire.test.sh 120000
tests/fm-backend-autodetect-smoke.test.sh 176
tests/fm-backend-cmux-smoke.test.sh 188
tests/fm-backend-cmux.test.sh 1170
tests/fm-backend-herdr-eventwait-smoke.test.sh 136
tests/fm-backend-herdr-focus-flash-e2e.test.sh 410
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh 437
tests/fm-backend-herdr-presentation-e2e.test.sh 1580
tests/fm-backend-herdr-prune-safety-e2e.test.sh 180
tests/fm-backend-herdr-respawn-idem-e2e.test.sh 182
tests/fm-backend-herdr-smoke.test.sh 355
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh 251
tests/fm-backend-herdr.test.sh 4611
tests/fm-backend-hometag-lib.test.sh 48
tests/fm-backend-orca.test.sh 1364
tests/fm-backend-tmux-smoke.test.sh 173
tests/fm-backend-zellij-smoke.test.sh 205
tests/fm-backend-zellij.test.sh 1365
tests/fm-backend.test.sh 1183
tests/fm-backlog-atomicity.test.sh 7130
tests/fm-backlog-handoff.test.sh 1360
tests/fm-backlog-receive.test.sh 83
tests/fm-bearings-board-render.test.sh 135
tests/fm-bearings-board.test.sh 414
tests/fm-bearings-snapshot.test.sh 2025
tests/fm-bootstrap-network-parallel.test.sh 316
tests/fm-bootstrap.test.sh 1391
tests/fm-branch-supervision.test.sh 552
tests/fm-brief.test.sh 1693
tests/fm-busy-adapter-wiring.test.sh 422
tests/fm-busy-event.test.sh 55
tests/fm-busy-lib.test.sh 29
tests/fm-busy-state.test.sh 419
tests/fm-calm-pi-extension.test.sh 3755
tests/fm-captain-hold-lifecycle.test.sh 1194
tests/fm-capture-visual-evidence-mechanism.test.sh 349
tests/fm-cd-pretool-check.test.sh 401
tests/fm-check-lib.test.sh 45
tests/fm-check-register.test.sh 111
tests/fm-check-unregister.test.sh 28
tests/fm-ci-load-guard.test.sh 35
tests/fm-ci-water7.test.sh 1031
tests/fm-ci.test.sh 19
tests/fm-classify-corr-token.test.sh 543
tests/fm-classify-decision-key.test.sh 340
tests/fm-classify-lib.test.sh 44
tests/fm-claude-account-profile-lib.test.sh 35
tests/fm-claude-account-profile-live-e2e.test.sh 93
tests/fm-claude-stop-autoarm-live-e2e.test.sh 164
tests/fm-claude-stop-autoarm.test.sh 1190
tests/fm-cmux-claude-composer-live-e2e.test.sh 110
tests/fm-codex-continuity-live-e2e.test.sh 55
tests/fm-composer-ghost.test.sh 716
tests/fm-composer-lib.test.sh 676
tests/fm-composer-matrix-live-e2e.test.sh 220
tests/fm-config-inherit-lib.test.sh 32
tests/fm-config-push.test.sh 31
tests/fm-control-herdr-smoke.test.sh 149
tests/fm-control-relaunch.test.sh 1360
tests/fm-control.test.sh 910
tests/fm-crew-state.test.sh 1652
tests/fm-cursor-harness.test.sh 404
tests/fm-cursor-primary-live-e2e.test.sh 217
tests/fm-cursor-primary.test.sh 708
tests/fm-daemon.test.sh 2241
tests/fm-daily.test.sh 366
tests/fm-decision-hold-lifecycle.test.sh 719
tests/fm-decision-hold.test.sh 27
tests/fm-diagnostic-report.test.sh 347
tests/fm-doc-audience-check.test.sh 43
tests/fm-documentation-audiences.test.sh 269
tests/fm-ensure-agents-md.test.sh 371
tests/fm-extension-binding.test.sh 431
tests/fm-ff-lib.test.sh 36
tests/fm-fleet-dashboard.test.sh 3259
tests/fm-fleet-snapshot-view.test.sh 884
tests/fm-fleet-snapshot.test.sh 310
tests/fm-fleet-sync.test.sh 721
tests/fm-fleet-view.test.sh 43
tests/fm-gate-refuse-lib.test.sh 29
tests/fm-gate-refuse.test.sh 380
tests/fm-gh-pr-body.test.sh 82
tests/fm-gitignore-config.test.sh 89
tests/fm-gotmp.test.sh 256
tests/fm-grok-continuity-live-e2e.test.sh 112
tests/fm-grok-harness.test.sh 146
tests/fm-grok-stop-live-e2e.test.sh 219
tests/fm-guard-stale-banner.test.sh 709
tests/fm-guard.test.sh 31
tests/fm-harness-adapter-instructions-live-e2e.test.sh 1
tests/fm-harness-adapter-references.test.sh 3
tests/fm-harness-escalation.test.sh 405
tests/fm-harness-liveness-drift-live-e2e.test.sh 151
tests/fm-harness.test.sh 50
tests/fm-heavy-suite.test.sh 51
tests/fm-herdr-ci-cleanup.test.sh 108
tests/fm-herdr-lab.test.sh 394
tests/fm-herdr-session-cleanup-e2e.test.sh 146
tests/fm-herdr-session-cleanup.test.sh 330
tests/fm-herdr-submit-confirm-live-e2e.test.sh 125
tests/fm-herdr-version-floor-live-e2e.test.sh 144
tests/fm-home-seed.test.sh 48
tests/fm-home-summary-refresh.test.sh 2029
tests/fm-inactive-reconcile.test.sh 484
tests/fm-install-chrome.test.sh 163
tests/fm-install-shellcheck.test.sh 70
tests/fm-kimi-harness.test.sh 883
tests/fm-kimi-trust-check.test.sh 53
tests/fm-kimi-turnend-hook.test.sh 32
tests/fm-launch-axis-lib.test.sh 30
tests/fm-lint-workflows.test.sh 532
tests/fm-lint.test.sh 1113
tests/fm-lock-lib.test.sh 64
tests/fm-lock.test.sh 29
tests/fm-macos-scope.test.sh 200
tests/fm-marker-lib.test.sh 28
tests/fm-memory-doctor.test.sh 1129
tests/fm-model-catalog-inheritance.test.sh 448
tests/fm-model-catalog-lib.test.sh 65
tests/fm-model-telemetry.test.sh 1141
tests/fm-model-usage.test.sh 69
tests/fm-moiras.test.sh 101520
tests/fm-modules.test.sh 2541
tests/fm-muse-harness.test.sh 935
tests/fm-muse-signals-live-e2e.test.sh 205
tests/fm-nm-home-isolation.test.sh 59
tests/fm-nm-prepare-home.test.sh 228
tests/fm-nm-run-lib.test.sh 62
tests/fm-no-mistakes-required.test.sh 22
tests/fm-on.test.sh 504
tests/fm-opencode-primary-live-e2e.test.sh 357
tests/fm-operational-input.test.sh 164
tests/fm-peek-remote.test.sh 110
tests/fm-peek.test.sh 56
tests/fm-pending-reply-lib.test.sh 131
tests/fm-pending-reply.test.sh 1345
tests/fm-pi-branch-extension.test.sh 3118
tests/fm-pi-branch-live-e2e.test.sh 527
tests/fm-pi-primary-live-e2e.test.sh 345
tests/fm-pi-primary-types.test.sh 68
tests/fm-pi-watch-extension.test.sh 2899
tests/fm-pr-body-template-mechanism.test.sh 223
tests/fm-pr-body.test.sh 570
tests/fm-pr-check-security.test.sh 3778
tests/fm-pr-comment-watch-mechanism.test.sh 205
tests/fm-pr-comment-watch.test.sh 890
tests/fm-pr-context.test.sh 2322
tests/fm-pr-context-watch.test.sh 26639
tests/fm-pr-fix-seat.test.sh 75000
tests/fm-pr-lib.test.sh 35
tests/fm-pr-merge.test.sh 2675
tests/fm-primary-scope-lib.test.sh 65
tests/fm-procevent-quota.test.sh 114
tests/fm-procevent-when.test.sh 406
tests/fm-procevent.test.sh 1506
tests/fm-project-origin.test.sh 110
tests/fm-public-followup.test.sh 2315
tests/fm-quota-array-dispatch-live-e2e.test.sh 526
tests/fm-quota-axi-lib.test.sh 49
tests/fm-quota-choose.test.sh 85
tests/fm-quota-cooldown.test.sh 316
tests/fm-quota-utilization.test.sh 790
tests/fm-record-contradictions-lib.test.sh 138
tests/fm-remote-backlog-handoff.test.sh 453
tests/fm-remote-doctor.test.sh 626
tests/fm-remote-entrypoint.test.sh 59
tests/fm-remote-job-orphan-reap.test.sh 205
tests/fm-remote-job.test.sh 889
tests/fm-remote-reply.test.sh 972
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 1254
tests/fm-remote-secondmate-parent-binding.test.sh 295
tests/fm-remote-secondmate-trace-context.test.sh 308
tests/fm-remote-transport-lanes.test.sh 425
tests/fm-review-diff.test.sh 176
tests/fm-robin.test.sh 78204
tests/fm-search.test.sh 318
tests/fm-secondmate-charter-lib.test.sh 41
tests/fm-secondmate-harness.test.sh 2741
tests/fm-secondmate-lifecycle-e2e.test.sh 259
tests/fm-secondmate-liveness.test.sh 577
tests/fm-secondmate-reconcile.test.sh 722
tests/fm-secondmate-safety.test.sh 3238
tests/fm-secondmate-sync.test.sh 908
tests/fm-send-inbox-doorbell-live-e2e.test.sh 206
tests/fm-send-inbox.test.sh 352
tests/fm-send-popup-settle.test.sh 167
tests/fm-send-remote-delivery.test.sh 796
tests/fm-send-resolve-key.test.sh 552
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 187
tests/fm-send-secondmate-marker.test.sh 298
tests/fm-send-settle.test.sh 169
tests/fm-send-strict.test.sh 277
tests/fm-session-digest.test.sh 869
tests/fm-session-lock-ancestry.test.sh 479
tests/fm-session-lock-lib.test.sh 41
tests/fm-session-start.test.sh 3102
tests/fm-sessionstart-hook-live-e2e.test.sh 364
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 230
tests/fm-sessionstart-nudge.test.sh 644
tests/fm-shared-captain-inheritance.test.sh 404
tests/fm-slack-captain-channel.test.sh 1120
tests/fm-slack-captain-comms-guard.test.sh 330
tests/fm-slack-retry-harness.test.sh 144
tests/fm-slack-socket.test.sh 583
tests/fm-spawn-batch.test.sh 186
tests/fm-spawn-dispatch-profile.test.sh 3709
tests/fm-spawn-meta-header.test.sh 36
tests/fm-spawn-pool-base-freshen.test.sh 480
tests/fm-spawn-worktree-settle.test.sh 294
tests/fm-startup-memory-budget-lib.test.sh 37
tests/fm-startup-memory-budget.test.sh 353
tests/fm-startup-network.test.sh 712
tests/fm-stow-cadence-lab.test.sh 603
tests/fm-stow-cadence-live-e2e.test.sh 41
tests/fm-stow-cascade.test.sh 370
tests/fm-subagent-pretool-check.test.sh 291
tests/fm-supervision-events.test.sh 156
tests/fm-supervision-instructions.test.sh 190
tests/fm-tangle-guard.test.sh 345
tests/fm-tangle-lib.test.sh 41
tests/fm-task-delivery.test.sh 321
tests/fm-task-inbox.test.sh 513
tests/fm-teardown-custody.test.sh 1039
tests/fm-teardown-endpoint-safety.test.sh 398
tests/fm-teardown.test.sh 4368
tests/fm-test-fixture-cleanup.test.sh 186
tests/fm-test-fixtures.test.sh 9
tests/fm-test-isolation-proof.test.sh 107
tests/fm-test-run.test.sh 1077
tests/fm-tmux-agent-liveness.test.sh 257
tests/fm-tmux-submit-busy.test.sh 509
tests/fm-tool-update-check.test.sh 1039
tests/fm-trace-context-lib.test.sh 253
tests/fm-trace-context-spawn.test.sh 603
tests/fm-transition-lib.test.sh 54
tests/fm-turnend-captain-comms-live-e2e.test.sh 273
tests/fm-turnend-guard.test.sh 2676
tests/fm-unadvanceable-work.test.sh 263
tests/fm-update.test.sh 304
tests/fm-vendor-auth-probe.test.sh 395
tests/fm-voice-relay.test.sh 4741
tests/fm-wake-daemon-lifecycle-e2e.test.sh 162
tests/fm-wake-drain-open-decisions-cursor.test.sh 356
tests/fm-wake-drain-open-decisions.test.sh 226
tests/fm-wake-drain-outcome-backstop.test.sh 886
tests/fm-wake-drain-unread-status.test.sh 321
tests/fm-wake-drain.test.sh 45
tests/fm-wake-queue.test.sh 1229
tests/fm-watch-arm.test.sh 822
tests/fm-watch-checkpoint.test.sh 93
tests/fm-watch-recovery-loop.test.sh 223
tests/fm-watch-triage.test.sh 3169
tests/fm-watcher-lock.test.sh 1152
tests/fm-worktree-unique-content.test.sh 427
tests/fm-x-dismiss.test.sh 56
tests/fm-x-mode.test.sh 3041
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
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | filter_enabled_tests | LC_ALL=C sort -u >"$tmp/proof_list"
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
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.stderr.write(
            f"fm-test-run: aggregate input is not valid timing JSON: {path}: {exc}\n"
        )
        raise SystemExit(2)
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

disabled_adapter_for_test() {  # <test-path>
  case "$(basename "$1")" in
    fm-opencode-primary-live-e2e.test.sh) printf '%s\n' opencode ;;
    fm-grok-continuity-live-e2e.test.sh|fm-grok-harness.test.sh|fm-grok-stop-live-e2e.test.sh) printf '%s\n' grok ;;
    fm-kimi-harness.test.sh|fm-kimi-trust-check.test.sh|fm-kimi-turnend-hook.test.sh) printf '%s\n' kimi ;;
    fm-gemini-harness.test.sh) printf '%s\n' gemini ;;
    fm-muse-harness.test.sh|fm-muse-signals-live-e2e.test.sh) printf '%s\n' muse ;;
    fm-rovo-harness.test.sh|fm-rovo-signals-live-e2e.test.sh) printf '%s\n' rovo ;;
    fm-omp-harness.test.sh|fm-omp-primary-live-e2e.test.sh) printf '%s\n' omp ;;
    fm-cursor-harness.test.sh|fm-cursor-primary.test.sh|fm-cursor-primary-live-e2e.test.sh|fm-wake-drain-open-decisions-cursor.test.sh) printf '%s\n' cursor ;;
    fm-backend-zellij-smoke.test.sh|fm-backend-zellij.test.sh) printf '%s\n' zellij ;;
    fm-backend-orca.test.sh) printf '%s\n' orca ;;
    fm-backend-cmux-smoke.test.sh|fm-backend-cmux.test.sh|fm-cmux-claude-composer-live-e2e.test.sh) printf '%s\n' cmux ;;
    *) return 1 ;;
  esac
}

test_is_disabled() {  # <test-path>
  local adapter
  adapter=$(disabled_adapter_for_test "$1") || return 1
  [ -e "$FM_DISABLED_ADAPTERS_CONFIG" ] || return 1
  [ -f "$FM_DISABLED_ADAPTERS_CONFIG" ] && [ ! -L "$FM_DISABLED_ADAPTERS_CONFIG" ] \
    || die "config/disabled-adapters must be a regular file"
  grep -Fqx "$adapter" "$FM_DISABLED_ADAPTERS_CONFIG"
}

filter_enabled_tests() {
  local test rc
  while IFS= read -r test; do
    [ -n "$test" ] || continue
    if test_is_disabled "$test"; then
      continue
    else
      rc=$?
      [ "$rc" -eq 1 ] || die "cannot apply disabled-adapters policy"
    fi
    printf '%s\n' "$test"
  done
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | filter_enabled_tests | LC_ALL=C sort
}

# Behavior-area fixture helpers (tests/*-helpers.sh). They are not suites, so
# all_repo_tests skips them, but a suite that sources one inherits every name it
# mentions - which is how a changed source path still resolves to a family after
# a fixture is extracted out of the suite that used to own it.
all_repo_test_helpers() {
  local f
  # shellcheck disable=SC2035
  for f in tests/*-helpers.sh tests/*-fixture.sh; do
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

# Preserve the evidence chain for --changed inspection without changing the
# path-only contract of other selection modes.
add_changed_script() {
  local script=$1 reason=$2 pair
  add_script "$script"
  pair="$(normalize_script_path "$script")"$'\t'"$reason"
  for existing in "${CHANGED_REASONS[@]+"${CHANGED_REASONS[@]}"}"; do
    [ "$existing" = "$pair" ] && return 0
  done
  CHANGED_REASONS+=("$pair")
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

# Emit the families of every suite that names $needle, following one level of
# shared-fixture indirection: when no suite names it directly, a tests/*-helpers.sh
# that does stands in for the suites which source that helper. Without that hop,
# extracting a fixture out of a suite silently unmaps every source path only that
# fixture named, and --changed dies on it.
families_for_test_reference() {
  local needle=$1 s h helper_name
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 0 ] || return 0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    helper_name=$(basename "$h")
    [ "$helper_name" != "$needle" ] || continue
    grep -Fq "$needle" "$h" || continue
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if grep -Fq "$helper_name" "$s"; then
        family_for_basename "$(basename "$s")"
        found=1
      fi
    done < <(all_repo_tests)
  done < <(all_repo_test_helpers)
  [ "$found" -eq 1 ]
}

# Tests that name <needle>, selected as individual scripts rather than widened
# to each referencing test's whole family. A direct reference is per-script
# evidence, so it selects per script: one real-Herdr E2E sourcing a shared
# helper must not drag in every other script of that expensive family.
scripts_for_test_reference() {
  local needle=$1 s h helper_name
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      printf '__script__:%s\n' "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 0 ] || return 0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    helper_name=$(basename "$h")
    [ "$helper_name" != "$needle" ] || continue
    grep -Fq "$needle" "$h" || continue
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if grep -Fq "$helper_name" "$s"; then
        printf '__script__:%s\n' "$(basename "$s")"
        found=1
      fi
    done < <(all_repo_tests)
  done < <(all_repo_test_helpers)
  [ "$found" -eq 1 ]
}

# bin/ scripts other than <path> itself that source <path>.
bin_consumers_of() {
  local path=$1 b edge
  for b in bin/*.sh bin/backends/*.sh; do
    [ -f "$b" ] || continue
    [ "$b" != "$path" ] || continue
    edge=$(dependency_edge "$b" "$path" || true)
    [ "$edge" = source ] && printf '%s\n' "$b"
  done
}

# An unmapped bin/ path has no curated family of its own. Its blast radius is
# the tests that name it, plus the curated families of the bin/ scripts that
# consume it.
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
    done < <(bin_consumers_of "$path")
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
    scripts/test-changed.sh)
      printf '%s\n' __script__:test-changed.test.sh
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
    bin/fm-auto-quota-drain.sh|bin/fm-auto-quota-drain.mjs)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' backend-dispatch
      ;;
    bin/fm-watch*|bin/fm-wake*|bin/fm-wait-premise.sh|bin/fm-inactive-reconcile.sh|\
    bin/fm-classify-lib.sh|bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-stow-cadence-lab.sh)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
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
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh|\
    bin/fm-model-catalog-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-memory-doctor.sh|bin/fm-crew-dispatch-lib.sh|bin/fm-home-layout-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-x-lib.sh)
      printf '%s\n' pr-forge
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-public-followup-lib.sh)
      printf '%s\n' __script__:fm-public-followup.test.sh
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-procevent-lib.sh)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      printf '%s\n' __script__:fm-procevent.test.sh
      printf '%s\n' __script__:fm-procevent-when.test.sh
      printf '%s\n' __script__:fm-remote-reply.test.sh
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-slack-lib.sh)
      printf '%s\n' pr-forge
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-pending-reply-lib.sh)
      printf '%s\n' __script__:fm-pending-reply.test.sh
      printf '%s\n' __script__:fm-pending-reply-lib.test.sh
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate-report.sh)
      printf '%s\n' __script__:fm-pending-reply-lib.test.sh
      printf '%s\n' secondmate
      ;;
    bin/fm-secondmate*|bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*|\
    bin/fm-stow-cascade.sh)
      printf '%s\n' secondmate
      ;;
    bin/fm-heavy-suite.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-session-start.sh|bin/fm-bootstrap.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-startup-network.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-quota-utilization.sh|bin/fm-quota-utilization.mjs)
      printf '%s\n' pure-contract-unit
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-pr-body.sh)
      # Explicit entry ahead of the bin/fm-pr-* glob: its tests live in
      # pure-contract-unit, not pr-forge.
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    bin/fm-procevent-quota.sh)
      printf '%s\n' "__script__:fm-procevent-quota.test.sh"
      ;;
    bin/fm-quota-choose.sh)
      printf '%s\n' "__script__:fm-quota-choose.test.sh"
      ;;
    .pi/extensions/fm-branch-supervision.ts|.pi/extensions/lib/fm-async-exec.ts|\
    .pi/extensions/lib/fm-branch-dispatch.ts|.pi/extensions/lib/fm-native-contract.ts)
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
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
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
      printf '%s\n' __script__:fm-pi-windows-shell-invocation.test.sh
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-extension.mjs|bin/fm-extension.sh|docs/examples/process-event-extension/*)
      printf '%s\n' __script__:fm-extension-binding.test.sh
      ;;
    bin/fm-procevent.sh|bin/fm-procevent-extension-capture.pl)
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
    bin/fm-claude-account-profile-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      # Its auth predicate reads vendor-emitted fields, so a change here also
      # selects the opt-in guard that re-checks them against the installed CLI.
      printf '%s\n' live-harness-optin
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
    bin/fm-commit-msg-sanitize.sh|bin/fm-quota-cooldown.sh|bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-launch-axis-lib.sh|bin/fm-peek.sh|bin/fm-composer*)
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
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-install-chrome.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-model-telemetry.sh|bin/fm-model-usage.mjs|bin/fm-session-digest.sh|bin/fm-session-digest.mjs|bin/fm-tachikoma.sh|modules/tachikoma/*)
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-canonical-guard-benchmark.sh|scripts/canonical-guard-benchmark/*)
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-lint.sh|bin/fm-lint-workflows.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-install-actionlint.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-search.sh|bin/fm-crew-state.sh|\
    bin/fm-unadvanceable-work.sh|bin/fm-record-contradictions-lib.sh|\
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
    .agents/skills/graph-board/assets/graph-server-page.html)
      # The page the graph server serves is part of that server's behavior: its
      # suite asserts on what a browser actually receives, so a page change has
      # to re-run it rather than resolve to nothing.
      printf '%s\n' __script__:fm-graph-server.test.sh
      ;;
    .agents/skills/*/assets/*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/*/SKILL.md|.agents/skills/war-room/templates/*)
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
    .opencode/plugins/fm-primary-cd-check.js)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.gitattributes|.backpassrc.json|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|README.md|docs/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/lib.sh|tests/*-helpers.sh|tests/*-fixture.sh|tests/fixtures.sh)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/fm-marvin.sh|modules/marvin/*)
      printf '%s\n' __script__:fm-marvin.test.sh
      ;;
    bin/fm-moiras.sh|modules/moiras/*)
      printf '%s\n' __script__:fm-moiras.test.sh
      ;;
    modules/TEMPLATE.md|modules/fm-tui-core/*|modules/fm-state-reader/*)
      printf '%s\n' __script__:fm-modules.test.sh
      ;;
    modules/fm-robin/*|bin/fm-robin.sh)
      printf '%s\n' __script__:fm-robin.test.sh
      ;;
    tests/assets/board-render-harness.mjs)
      printf '%s\n' __script__:fm-bearings-board-render.test.sh
      ;;
    tests/fixtures/*)
      fixture_ref=$path
      while case "$fixture_ref" in tests/fixtures/*/*) true ;; *) false ;; esac; do
        families_for_test_reference "$fixture_ref" && return 0
        fixture_ref=${fixture_ref%/*}
      done
      families_for_test_reference "$fixture_ref" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/*)
      # Unknown live scripts combine the precise reverse dependency graph with
      # direct test and curated-consumer coverage. A deleted script can only
      # keep coverage through a remaining direct test reference.
      if [ -e "$path" ]; then
        printf '%s\n' "__dependency__:$path"
        families_for_unmapped_bin "$path" \
          || printf '%s\n' "__unmapped__:$path"
      else
        families_for_test_reference "$path" || true
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    LICENSE|assets/*|.gitignore|gnhf-score.txt|gnhf-night-report.md|rejected/*)
      # gnhf-score.txt, gnhf-night-report.md, and rejected/* are autonomous-run
      # artifacts, not source paths; like .gitignore they select no test family.
      ;;
    *)
      if [ -e "$path" ]; then
        families_for_test_reference "$path" \
          || printf '%s\n' "__unmapped__:$path"
      else
        # A retired source path with no remaining test consumer cannot select
        # a runnable suite. Known source paths above retain their mappings,
        # and a still-referenced removal is found by the same reference scan.
        families_for_test_reference "$path" || true
      fi
      ;;
  esac
}

# Files that can carry a dependency edge. Tests are the selectable leaves;
# helpers, fixtures, and executable scripts make the graph transitive.
dependency_nodes() {
  local f
  all_repo_tests
  all_repo_test_helpers
  for f in tests/fixtures/* tests/fixtures/*/* bin/*.sh bin/backends/*.sh; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done | LC_ALL=C sort -u
}

# Emit the kind of edge from $1 to $2 when the file names the target through a
# source, invocation, or fixture reference. Repository-relative references are
# exact; SCRIPT_DIR forms use the target basename because their directory is
# established by the caller.
dependency_edge() {
  local node=$1 target=$2 base
  base=$(basename "$target")
  [ -f "$node" ] || return 1
  if grep -E '(^|[[:space:];])([.]|source)[[:space:]]+' "$node" | grep -Fq "$target" ||
    grep -E '(^|[[:space:];])([.]|source)[[:space:]]+' "$node" | grep -Eq '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/.*'"$base"'([[:space:]"'"'"'\047;]|$)'; then
    printf 'source\n'
  elif grep -Fq "$target" "$node" || grep -Eq '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/.*'"$base"'([[:space:]"'"'"'\047;]|$)' "$node"; then
    case "$node" in
      tests/fixtures/*|tests/*-helpers.sh) printf 'fixture\n' ;;
      *) printf 'invoke\n' ;;
    esac
  else
    return 1
  fi
}

# Follow reverse references until every test leaf depending on $1 is found.
# Load each candidate once: the old grep-per-node walk made large upstream syncs
# quadratic in filesystem reads even when most changed paths had curated maps.
select_dependency_dependents() {
  local changed=$1 test_path chain found=0
  while IFS=$(printf '\t') read -r test_path chain; do
    [ -n "$test_path" ] || continue
    add_changed_script "$test_path" "changed=$changed via $chain"
    found=1
  done < <(dependency_nodes | python3 -c '
import pathlib
import re
import sys
from collections import deque

changed = sys.argv[1]
nodes = sorted(filter(None, (line.rstrip("\n") for line in sys.stdin)))
contents = {}
source_lines = {}
source_prefix = re.compile(r"(^|[\s;])(\.|source)\s+")
for node in nodes:
    try:
        text = pathlib.Path(node).read_text(encoding="utf-8", errors="replace")
    except OSError:
        continue
    contents[node] = text
    source_lines[node] = [line for line in text.splitlines() if source_prefix.search(line)]

variable_patterns = {}

def edge(node, target):
    text = contents.get(node)
    if text is None:
        return None
    variable = variable_patterns.get(target)
    if variable is None:
        base = pathlib.PurePosixPath(target).name
        variable = re.compile(
            r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/.*"
            + re.escape(base)
            + r"([\s\"\x27;]|$)"
        )
        variable_patterns[target] = variable
    if any(target in line or variable.search(line) for line in source_lines[node]):
        return "source"
    if target in text or variable.search(text):
        if node.startswith("tests/fixtures/") or node.endswith(("-helpers.sh", "-fixture.sh")):
            return "fixture"
        return "invoke"
    return None

queue = deque([(changed, changed)])
seen = {changed}
emitted = set()
while queue:
    current, chain = queue.popleft()
    for node in nodes:
        if node == current:
            continue
        kind = edge(node, current)
        if kind is None:
            continue
        if node.startswith("bin/") and kind != "source":
            continue
        next_chain = f"{chain} --{kind}--> {node}"
        if node.startswith("tests/") and node.endswith(".test.sh"):
            if node not in emitted:
                print(f"{node}\t{next_chain}")
                emitted.add(node)
            continue
        if node not in seen:
            seen.add(node)
            queue.append((node, next_chain))
' "$changed")
  [ "$found" -eq 1 ]
}

select_changed() {
  local base=$1 path entry fam script_name s changed_path dependency_selected
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      tests/*.test.sh)
        add_changed_script "$path" "changed=$path via changed-test"
        continue
        ;;
    esac
    dependency_selected=0
    case "$path" in
      bin/backends/*)
        if [ -f "$path" ] && select_dependency_dependents "$path"; then
          dependency_selected=1
        fi
        ;;
    esac
    if [ "$dependency_selected" -eq 1 ]; then
      # Keep explicit behavioral checks that source references cannot reveal.
      while IFS= read -r entry; do
        case "$entry" in
          __script__:*)
            script_name=${entry#__script__:}
            wanted_scripts+=("$path"$'\t'"$script_name")
            ;;
        esac
      done < <(families_for_changed_path "$path")
      continue
    fi
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __dependency__:*)
          if select_dependency_dependents "$path"; then
            dependency_selected=1
          fi
          ;;
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$path"$'\t'"$script_name")
          ;;
        __unmapped__:*)
          [ "$dependency_selected" -eq 1 ] \
            || die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$path"$'\t'"$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
    [ "$dependency_selected" -eq 0 ] || continue
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # One representative changed path per family is enough: selected scripts are
  # unique and --list prints only the first reason for each one.
  local f fam_for_f seen_f u
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    fam_for_f=${f#*$'\t'}
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "${u#*$'\t'}" = "$fam_for_f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    changed_path=${f%%$'\t'*}
    fam=${f#*$'\t'}
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$fam" ]; then
        add_changed_script "$s" "changed=$changed_path via family=$fam"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    changed_path=${script_name%%$'\t'*}
    script_name=${script_name#*$'\t'}
    if [ -f "tests/$script_name" ]; then
        add_changed_script "tests/$script_name" "changed=$changed_path via script=$script_name"
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

# Echo the reason a gate skip gave, i.e. the first meaningful output line with
# its leading "skip:" removed. Tabs and stray whitespace are folded so the
# reason stays one field of the tab-separated record the JSON artifact is built
# from. Callers only use this once detect_gate_skip has already said yes.
gate_skip_reason() {
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  first=${first#skip:}
  printf '%s\n' "$first" | tr '\t' ' ' | sed -e 's/^ *//' -e 's/ *$//'
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
        path, family, expected, exit_s, dur_s, gate, reason = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
            "gate_skip_reason": reason,
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

# The FM_TEST_SUMMARY trailer is the run's verdict and the timing artifact is
# written after it, so an unwritable artifact is reported and contained rather
# than reclassifying a finished run. The subshell keeps a die() inside the
# writer from taking the run with it, and disables set -e for its own body, so
# every step here reports its own failure.
emit_timing_artifact() {
  local out=$1
  shift
  if (
    mkdir -p "$(dirname "$out")" || exit 1
    write_json_artifact "$out" "$@"
  ); then
    log "wrote timing artifact: $out"
  else
    log "could not write timing artifact: $out"
  fi
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
      PER_SCRIPT_TIMEOUT_EXPLICIT=1
      shift 2
      ;;
    --per-script-timeout-secs=*)
      PER_SCRIPT_TIMEOUT_SECS=${1#--per-script-timeout-secs=}
      PER_SCRIPT_TIMEOUT_EXPLICIT=1
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

if [ -e "$FM_DISABLED_ADAPTERS_CONFIG" ] && { [ ! -f "$FM_DISABLED_ADAPTERS_CONFIG" ] || [ -L "$FM_DISABLED_ADAPTERS_CONFIG" ]; }; then
  die "config/disabled-adapters must be a regular file"
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

# Refuse before any suite is selected or run. The inspection modes execute
# nothing: --list-families, --list-concurrent-safe-families, --list-lanes,
# --check-coverage, --concurrent-safe-family-jobs-max and --aggregate-json have
# already exited above, and --list/--list-scheduled print their selection and
# exit below. An unset MODE still falls through to the usage error, so a caller
# who named no selection mode is told that rather than this.
if [ -n "${MODE:-}" ] && [ "$LIST_ONLY" -eq 0 ] && [ "$LIST_SCHEDULED" -eq 0 ]; then
  refuse_primary_checkout_for_task
fi

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
      if [ "$MODE" = changed ]; then
        reason=
        for entry in "${CHANGED_REASONS[@]+"${CHANGED_REASONS[@]}"}"; do
          [ "${entry%%$'\t'*}" = "$s" ] || continue
          reason=${entry#*$'\t'}
          break
        done
        printf '%s\t%s\n' "$s" "${reason:-changed selection}"
      else
        printf '%s\n' "$s"
      fi
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
    emit_timing_artifact "$JSON_PATH" "$RUN_STARTED_ISO" "$empty_finished_iso" \
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
if [ "${#SCRIPTS[@]}" -gt 0 ] && [ "$PER_SCRIPT_TIMEOUT_SECS" -eq 0 ] \
  && [ "$PER_SCRIPT_TIMEOUT_EXPLICIT" -eq 0 ]; then
  PER_SCRIPT_TIMEOUT_SECS=$DEFAULT_PER_SCRIPT_TIMEOUT_SECS
fi
if { [ "$MODE" = changed ] || [ "$MODE" = scripts ]; } && [ "$JOBS_EXPLICIT" -eq 0 ]; then
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
  local base family expected gate_skip gate_reason fail_delta
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  gate_reason=
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    gate_reason=$(gate_skip_reason "$out")
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
    # A capability skip is the runner's only record of what this host could not
    # exercise, so name it rather than leaving a silent green.
    log "gate skip: $script: ${gate_reason:-<no reason given>}"
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" "$gate_reason" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

# Run <script>, capturing output to <out>. <stream> 1 replays it after completion.
# <id> only has to be unique within this run. When PER_SCRIPT_TIMEOUT_SECS is
# positive, a script that outruns it is terminated and reported as exit 124: a
# hung script must become a bounded failure rather than an unbounded suite,
# because an unbounded suite is what silently outruns its caller's budget.
run_script_bounded() {  # <script> <out> <stream> <id>
  local script=$1 out=$2 stream=$3 id=$4
  local rc
  : "$id"
  set +e
  # Never put the bounded command on a pipeline. A timed-out script can leave
  # a descendant holding the pipeline's input open after the direct child exits,
  # which strands tee and prevents the suite trailer from being emitted. Capture
  # to the regular output file, then replay it for serial callers.
  if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ]; then
    fm_run_timed "$PER_SCRIPT_TIMEOUT_SECS" bash "$script" >"$out" 2>&1
    rc=$?
  else
    bash "$script" >"$out" 2>&1
    rc=$?
  fi
  [ "$stream" -eq 1 ] && cat "$out"
  if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ] && [ "$rc" -eq 124 ]; then
    printf 'FM_TEST_TIMEOUT script=%s after=%ss\n' "$script" "$PER_SCRIPT_TIMEOUT_SECS" >>"$out"
    printf 'not ok - %s exceeded the per-script bound of %ss and was terminated\n' \
      "$script" "$PER_SCRIPT_TIMEOUT_SECS" >>"$out"
    [ "$stream" -eq 1 ] && tail -2 "$out"
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
  # Replay captured output while retaining a copy for gate-skip detection.
  # Preserve the fork's clean-home contract around the upstream bounded runner.
  (
    unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
      FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
    cd "$ROOT" || exit 1
    run_script_bounded "$script" "$out" 1 "s$TOTAL"
  )
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
  # private mode-0700 TMPDIR so mktemp roots cannot collide. Native Windows
  # Bash layers report synthetic POSIX modes, so retain chmod there but enforce
  # its observed mode only where the host reports real POSIX permissions.
  # Retries are never used as a green strategy.
  worker_n=0
  active_workers=0

  worker_root_mode_is_enforceable() {
    case "$(uname -s)" in
      MINGW*|MSYS*) return 1 ;;
      *) return 0 ;;
    esac
  }

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
    if worker_root_mode_is_enforceable; then
      mode=$(stat -c %a "$work" 2>/dev/null || /usr/bin/stat -f %Lp "$work" 2>/dev/null || echo unknown)
      case "$mode" in
        700|0700) ;;
        *)
          log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
          rc=1
          ;;
      esac
    fi
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
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV" || true
  else
    : >"$FAMILIES_TSV" || true
  fi
  emit_timing_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
fi

if [ -n "$MAX_WALL_MS" ]; then
  printf 'FM_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$RUN_DURATION"
  if [ "$RUN_DURATION" -gt "$MAX_WALL_MS" ]; then
    log "wall-clock budget exceeded: ${RUN_DURATION}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
    AGG_RC=1
  fi
fi

exit "$AGG_RC"
