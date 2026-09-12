#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes both invoke this script with no arguments, so this owner selects
# the context-appropriate rule set without duplicating lint configuration.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks and source
# following. CI, main, and merge-base-less runs keep --norc --external-sources
# with full dataflow over the whole canonical set. An ordinary local branch
# (changed-file mode, including the no-mistakes lint step) drops
# --external-sources, keeps dataflow, and excludes SC1091, SC2034, SC2153,
# and SC2329, the codes that need library context. Those codes still run in
# CI over the whole set. Explicit paths keep --external-sources with the
# selected dataflow mode.
# Tests stop source analysis at imported production modules because CI analyzes
# every production shell separately as a canonical, source-aware root.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# With no explicit paths, the file set and source-following posture depend
# on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh, with
#     --external-sources and full dataflow. This is what CI always runs, so
#     CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). That local pass drops --external-sources and excludes SC1091,
#     SC2034, SC2153, and SC2329. A branch with zero matching changed files
#     skips ShellCheck and prints a "no changed lint targets" note, then
#     still runs the backend-purity check and validates workflows.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
# Explicit core bin/ and bin/backends/ scripts still receive the
# backend-purity check. The backend-purity check rejects direct Beads CLI
# invocations in the core bin/ and bin/backends/ scripts so every configured
# backlog backend follows the same tasks-axi lifecycle path.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. FM_LINT_JOBS=1
# runs the same shards serially with byte-identical diagnostics and exit selection.
#
# Each shard runs ShellCheck one file at a time, under a per-file wall-clock
# timeout (FM_LINT_FILE_TIMEOUT, default 120 seconds) and a per-file memory
# ceiling (FM_LINT_FILE_MEM_KB, default a 6 GiB target capped by this host's
# own memory divided across concurrent shards - fm_lint_default_file_mem_kb's
# own comment - applied by running ShellCheck in its own `systemd-run --user
# --scope` cgroup on a host that has one, or left unenforced there otherwise).
# A file that hits either limit retries once without `--external-sources`
# (fm_lint_run_one_file's own comment) and, only if that also fails, is
# reported as a named lint failure while the shard moves on to its next file,
# so one pathological file (a huge here-doc or deep nesting defeating
# ShellCheck's extended analysis) can never starve the host or block the rest
# of the run.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
#
# Env:
#   FM_LINT_FILE_TIMEOUT   per-file ShellCheck wall-clock timeout in seconds (default 120)
#   FM_LINT_FILE_MEM_KB    per-file ShellCheck memory ceiling in KiB (default: 6291456 target, capped by host memory / FM_LINT_JOBS)
set -u

REQUIRED_SHELLCHECK=0.11.0
# Cross-file codes that need --external-sources. Local changed-file mode
# cannot judge them, so they stay CI-only.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# The pseudo exit status `wait` reports for a process that a signal
# interrupted (128 + the signal number), used to detect when the per-file
# deadline alarm raced a file's own clean exit and masked its real status.
FM_LINT_ALRM_WAIT_STATUS=$((128 + $(kill -l ALRM)))
# Resolved once per process by fm_lint_resolve_mem_mechanism: "systemd" once
# a live `systemd-run --user --scope` is confirmed available, "none" once
# confirmed absent, empty until first resolved.
FM_LINT_MEM_MECHANISM=

# `ulimit -v` was tried first and reverted: it caps virtual address space, not
# resident memory, and ShellCheck's GHC runtime reserves a very large virtual
# region up front regardless of a file's real memory use, so a 1 GiB `-v`
# ceiling killed nearly every file - including tiny ones - with "out of
# memory" (found by CI on this same change, 2026-09-06). The GHC runtime's own
# heap-limit flag (`+RTS -M<size> -RTS`) would measure the right thing, but
# the pinned 0.11.0 binary is not built with `-rtsopts`, so it refuses every
# RTS option outright rather than honoring or ignoring it. `systemd-run --user
# --scope -p MemoryMax=<bytes>` measures cgroup v2 `memory.max`, which is
# resident/heap memory the same way `MemoryMax` already bounds a whole
# crewmate's process tree (docs/configuration.md "Agent memory limits"), so it
# rejects a genuinely pathological file without touching a healthy one -
# confirmed against both a real hostile allocation (SIGKILL, cgroup
# Result=oom-kill) and this repo's largest real file (peak RSS well under the
# default ceiling, ordinary ShellCheck exit code preserved). `MemorySwapMax=0`
# is required alongside it: without it, a cgroup at `memory.max` overflows
# into swap and keeps running (correct cgroup v2 behavior, but it defeats a
# ceiling meant to stop a runaway file, letting it thrash instead of fail).
# A host with no `systemd --user` manager (some CI runners, non-Linux) gets no
# memory ceiling at all rather than a silently wrong one; the wall-clock
# timeout still bounds every file there, and fm_lint_resolve_mem_mechanism
# reports the gap once per process instead of claiming an enforcement that
# is not happening. A responsive user manager is not sufficient on its own:
# a host can have `systemd --user` running yet refuse the actual transient
# scope (no cgroup delegation, `MemoryMax`/`MemorySwapMax` not settable), in
# which case every per-file `systemd-run` launch would fail before ShellCheck
# ever starts. The probe launches a real, trivial scope with the same
# properties fm_lint_run_one_attempt uses, so a host that can respond to
# `systemctl --user show-environment` but cannot actually honor the ceiling
# still falls back to timeout-only linting instead of failing every file.
fm_lint_resolve_mem_mechanism() {
  [ -z "$FM_LINT_MEM_MECHANISM" ] || return 0
  if [ "$(uname -s)" = Linux ] && command -v systemd-run >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1 \
    && systemd-run --user --scope --quiet -p MemoryMax=64M -p MemorySwapMax=0 \
      -- true >/dev/null 2>&1
  then
    FM_LINT_MEM_MECHANISM=systemd
  else
    FM_LINT_MEM_MECHANISM=none
    printf 'fm-lint.sh: no systemd --user session on this host, so FM_LINT_FILE_MEM_KB has nothing to enforce it; only FM_LINT_FILE_TIMEOUT bounds ShellCheck here.\n' >&2
  fi
}

# The default per-file memory ceiling is capped by this host's own memory,
# divided across the concurrent shards that can each be running one ShellCheck
# at once (FM_LINT_JOBS), never the flat 6 GiB target alone: a CI runner with
# a few GiB total and two parallel shards would otherwise let the ceiling
# authorize more concurrent memory than the runner has, exactly the collateral
# damage this whole feature exists to prevent. Only ever narrows the DEFAULT;
# an explicit FM_LINT_FILE_MEM_KB always wins untouched (main() only calls
# this when the env var is unset). 70% of MemTotal matches this repo's other
# host-memory-safety convention (slice_memory_max_pct, Agent memory limits,
# docs/configuration.md), leaving headroom for the OS and everything else
# already running. An unreadable /proc/meminfo (non-Linux, a locked-down
# container) keeps the flat 6 GiB target rather than blocking the run over a
# number it cannot compute.
fm_lint_default_file_mem_kb() {  # <jobs>
  local jobs=$1 target=6291456 mem_total_kb cap
  mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  case "$mem_total_kb" in
    ''|*[!0-9]*) printf '%s\n' "$target"; return ;;
  esac
  cap=$((mem_total_kb * 70 / 100 / jobs))
  [ "$cap" -ge 1 ] || cap=1
  if [ "$cap" -lt "$target" ]; then
    printf '%s\n' "$cap"
  else
    printf '%s\n' "$target"
  fi
}
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

# fm_lint_run_one_file runs ShellCheck against exactly one file under a
# wall-clock timeout and, on a host with a live `systemd --user` session, a
# cgroup memory ceiling (fm_lint_resolve_mem_mechanism's own comment covers
# why the ceiling is a systemd scope rather than `ulimit -v` or ShellCheck's
# own runtime, and why it goes unenforced rather than substituted on a host
# with neither). Either bound is bounded on its own rather than able to stall
# or blow up a whole shard. A timeout or memory-ceiling hit is appended to the
# shard output as a named lint failure instead of propagating as a
# host-starving process; ordinary ShellCheck findings (exit 1) pass through
# unchanged.
#
# The wall-clock bound is a SIGALRM deadline this function drives itself, not
# coreutils `timeout`: `timeout` puts COMMAND in its own new process group so
# it can reliably kill COMMAND's whole subtree, but that same isolation takes
# ShellCheck out of the ambient process group the rest of fm-lint.sh's
# signal-based cleanup relies on (proven by test_worker_trees_stop_on_signal -
# an external interrupt to fm-lint.sh must still reach every running
# ShellCheck). A fixed once-a-second poll was tried and rejected too: `wait`
# on a specific pid only returns when THAT process exits, so polling with
# `kill -0` between sleeps forces every file - even an instant clean one - to
# pay up to a full poll tick, and the canonical set is hundreds of files.
# `wait PID` DOES return immediately when a signal with a real (even no-op)
# trap handler arrives, so a background `sleep "$timeout_s"; kill -ALRM $$`
# lets the common case return the instant ShellCheck exits, with the alarm as
# a deadline. Canceling that alarm early by killing its own pid only kills
# the wrapping subshell, not the `sleep` it is blocked on - the orphaned
# `sleep` keeps the shard's redirected stdout/stderr pipe open and hangs a
# caller capturing that output via `$(...)`, and could later deliver its
# ALRM into an unrelated file's wait. `pkill -P` targets the still-alive
# subshell's child before killing the subshell itself (killing parent first
# reparents the child to init, out of `pkill -P`'s reach) to avoid that; the
# elapsed-time check below (SECONDS, not the alarm's mere arrival) is the
# actual timeout verdict, so even an uncanceled stray alarm from an earlier
# file can only cause a harmless spurious re-wait here, never a false
# timeout. Since SECONDS only has 1-second resolution, a spurious wake can
# also land just short of the verdict on a genuine deadline; the loop then
# re-arms a fresh alarm for the remaining time before waiting again, so a
# hung file is still bounded rather than falling through to an unguarded
# `wait`. ShellCheck itself does not fork children, so a direct kill of its
# own pid is sufficient to stop it.
#
# Sets FM_LINT_ATTEMPT_RC and FM_LINT_ATTEMPT_TIMED_OUT instead of relying on
# $? alone, since a bare exit status cannot distinguish "ShellCheck exited 137
# on its own" from "the deadline forced a 137" - fm_lint_run_one_file needs
# that distinction to classify a failure, and calls this twice (full pass,
# then the --external-sources fallback), so its own return value is not the
# right channel for either attempt's result.
fm_lint_run_one_attempt() {  # <mem-kb> <timeout-s> <output-file> <path> <shellcheck-arg>...
  local mem_kb=$1 timeout_s=$2 output=$3 path=$4 rc=0 alarm_pid start timed_out=0 remaining
  shift 4
  local -a shellcheck_args=("$@")
  if [ "$FM_LINT_MEM_MECHANISM" = systemd ]; then
    systemd-run --user --scope --quiet -p "MemoryMax=${mem_kb}K" -p MemorySwapMax=0 \
      -- "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "$path" >> "$output" 2>&1 &
  else
    "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "$path" >> "$output" 2>&1 &
  fi
  FM_LINT_WORKER_SHELLCHECK_PID=$!
  ( sleep "$timeout_s"; kill -ALRM $$ 2>/dev/null ) > /dev/null 2>&1 &
  alarm_pid=$!
  # Disowned so bash's job control never announces "Terminated" to this
  # shard's captured output when the deadline alarm is canceled below.
  disown "$alarm_pid" 2>/dev/null || true
  # A standing no-op handler, never reset back to ALRM's default (terminate):
  # a stray alarm this function fails to cancel must only ever be able to
  # interrupt a `wait` early, never kill fm-lint.sh outright.
  trap : ALRM
  start=$SECONDS
  while :; do
    wait "$FM_LINT_WORKER_SHELLCHECK_PID"
    rc=$?
    if ! kill -0 "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null; then
      if [ "$rc" -eq "$FM_LINT_ALRM_WAIT_STATUS" ]; then
        # The deadline alarm fired within microseconds of the file's own
        # clean exit, so `wait` reported the alarm-interrupted pseudo-status
        # instead of ShellCheck's real one; the process is gone but its exit
        # status is still pending for us to reap, so re-collect it.
        wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null
        rc=$?
      fi
      break
    fi
    if [ $((SECONDS - start)) -ge "$timeout_s" ]; then
      timed_out=1
      kill -TERM "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
      wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null
      rc=$?
      break
    fi
    # A stray alarm from an earlier, already-finished file (or this file's
    # own alarm, whose one-shot `sleep` can race SECONDS' 1-second
    # resolution) woke this wait early; ShellCheck is still running and its
    # own deadline has not arrived, so re-arm a fresh alarm for the
    # remaining time and keep waiting on it - the fired alarm is one-shot,
    # so without this a genuinely hung file would otherwise wait unbounded.
    remaining=$((timeout_s - (SECONDS - start)))
    [ "$remaining" -ge 1 ] || remaining=1
    ( sleep "$remaining"; kill -ALRM $$ 2>/dev/null ) > /dev/null 2>&1 &
    alarm_pid=$!
    disown "$alarm_pid" 2>/dev/null || true
  done
  pkill -TERM -P "$alarm_pid" 2>/dev/null || true
  kill "$alarm_pid" 2>/dev/null || true
  wait "$alarm_pid" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
  FM_LINT_ATTEMPT_RC=$rc
  FM_LINT_ATTEMPT_TIMED_OUT=$timed_out
}

# True when an attempt's (timed_out, rc, captured-output) triple is a bound
# hit - the per-file timeout, or (only when a mechanism is actually enforcing
# it) the memory ceiling, including ShellCheck's own "out of memory" message
# for an rc the raw signal check does not already cover - rather than an
# ordinary ShellCheck exit.
fm_lint_is_ceiling_failure() {  # <timed_out> <rc> <output-file>
  local timed_out=$1 rc=$2 outfile=$3
  [ "$timed_out" -ne 1 ] || return 0
  case "$rc" in
    137|139) [ "$FM_LINT_MEM_MECHANISM" != systemd ] || return 0 ;;
  esac
  [ "$rc" -le 1 ] || ! grep -qi 'out of memory' "$outfile" 2>/dev/null || return 0
  return 1
}

# fm_lint_run_one_file orchestrates one file's ShellCheck attempt(s) and
# reports the final classification; fm_lint_run_one_attempt above owns a
# single bounded attempt's own mechanics.
#
# `--external-sources` makes ShellCheck recursively analyze every file a
# script sources, so a heavily cross-sourcing hub script can need far more
# memory and time than its own size suggests even though it has no lint
# defect of its own (found 2026-09-06: 27 real files in this repo exceeded
# the per-file bounds under full analysis, and the 4 worst never stabilized
# even at 4 GiB / 180s). Always failing those files outright would make
# canonical lint permanently red, so a bound hit retries the SAME file once
# without `--external-sources` before reporting a failure - a narrower, purely
# local analysis that finishes cheaply for a file whose own body is healthy,
# at the cost of the recursive analysis for that one file on that one run.
# Only a fallback that ALSO hits a bound is reported as a real failure.
# docs/fm-lint-external-sources-fallback.md tracks which tracked files are
# currently known to need this so a newly pathological file stays visible in
# review instead of silently blending into routine lint noise.
#
# The fallback also excludes SC1091 and SC2329: both are guaranteed artifacts
# of dropping `--external-sources` rather than findings about the file's own
# body. Every `. "$SCRIPT_DIR/..."` line SC1091-fires the instant ShellCheck
# stops following it (confirmed 2026-09-06: bin/fm-teardown.sh's own sourced
# libraries are already annotated with `# shellcheck source=`, and it still
# fires without `-x`, because that directive only resolves the dynamic path,
# not whether ShellCheck follows it), and SC2329 false-fires on any function a
# sourced file calls back into (a test's mock override of a production
# function, the normal shape here) since the caller is no longer in view.
# Excluding them per-line instead would mean one `# shellcheck disable=SC1091`
# above every source line in every file this fallback ever reaches - the exact
# repetitive machinery this single flag replaces. SC2034 stays enforced: it
# catches genuine unused-variable defects (a bare `for i in ...` never reading
# `i`) as often as it catches the same cross-file blind spot, so a real
# instance of the latter (docs/fm-lint-external-sources-fallback.md's own
# example) is suppressed at its one call site instead.
fm_lint_run_one_file() {  # <mem-kb> <timeout-s> <output-file> <path> -- <shellcheck-arg>...
  local mem_kb=$1 timeout_s=$2 output=$3 path=$4 rc timed_out current arg has_external=0
  local fallback_current fallback_rc fallback_timed_out
  local -a shellcheck_args fallback_args
  shift 4
  [ "${1:-}" != -- ] || shift
  shellcheck_args=("$@")
  current="$output.current"
  : > "$current"
  fm_lint_resolve_mem_mechanism
  fm_lint_run_one_attempt "$mem_kb" "$timeout_s" "$current" "$path" "${shellcheck_args[@]}"
  rc=$FM_LINT_ATTEMPT_RC
  timed_out=$FM_LINT_ATTEMPT_TIMED_OUT

  for arg in "${shellcheck_args[@]}"; do
    [ "$arg" != --external-sources ] || { has_external=1; break; }
  done

  if [ "$has_external" -eq 1 ] && fm_lint_is_ceiling_failure "$timed_out" "$rc" "$current"; then
    fallback_args=(--exclude=SC1091 --exclude=SC2329)
    for arg in "${shellcheck_args[@]}"; do
      [ "$arg" = --external-sources ] || fallback_args+=("$arg")
    done
    fallback_current="$output.fallback"
    : > "$fallback_current"
    fm_lint_run_one_attempt "$mem_kb" "$timeout_s" "$fallback_current" "$path" "${fallback_args[@]}"
    fallback_rc=$FM_LINT_ATTEMPT_RC
    fallback_timed_out=$FM_LINT_ATTEMPT_TIMED_OUT
    if ! fm_lint_is_ceiling_failure "$fallback_timed_out" "$fallback_rc" "$fallback_current"; then
      printf 'fm-lint.sh: %s exceeded its bound analyzing every sourced file (--external-sources); retried without it and completed narrower analysis (see docs/fm-lint-external-sources-fallback.md).\n' \
        "$path" >> "$output"
      cat "$fallback_current" >> "$output"
      rm -f "$current" "$fallback_current"
      return "$fallback_rc"
    fi
    rc=$fallback_rc
    timed_out=$fallback_timed_out
    : > "$current"
    cat "$fallback_current" >> "$current"
    rm -f "$fallback_current"
  fi

  local fallback_note='' fallback_note_comma=''
  if [ "$has_external" -eq 1 ]; then
    fallback_note=' even after the --external-sources fallback'
    fallback_note_comma=', even after the --external-sources fallback'
  fi

  if [ "$timed_out" -eq 1 ]; then
    rc=124
    printf 'fm-lint.sh: %s exceeded the %ss per-file lint timeout (FM_LINT_FILE_TIMEOUT)%s; reported as a lint failure, continuing with the next file.\n' \
      "$path" "$timeout_s" "$fallback_note" >> "$current"
  else
    case "$rc" in
      137|139)
        # A raw SIGKILL/SIGPIPE only means the memory ceiling fired when a
        # ceiling was actually enforced; with no systemd mechanism this file
        # was killed by something else entirely, and mislabeling it here
        # would blame a ceiling that never applied.
        if [ "$FM_LINT_MEM_MECHANISM" = systemd ]; then
          printf 'fm-lint.sh: %s hit the %s KiB per-file memory ceiling (FM_LINT_FILE_MEM_KB) and was killed%s; reported as a lint failure, continuing with the next file.\n' \
            "$path" "$mem_kb" "$fallback_note_comma" >> "$current"
        fi
        ;;
      *)
        if [ "$rc" -gt 1 ] && grep -qi 'out of memory' "$current" 2>/dev/null; then
          printf 'fm-lint.sh: %s hit the %s KiB per-file memory ceiling (FM_LINT_FILE_MEM_KB)%s; reported as a lint failure, continuing with the next file.\n' \
            "$path" "$mem_kb" "$fallback_note_comma" >> "$current"
        fi
        ;;
    esac
  fi
  cat "$current" >> "$output"
  rm -f "$current"
  return "$rc"
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output shard_rc=0 file_rc
  local file_timeout=${FM_LINT_FILE_TIMEOUT:-120} file_mem_kb=${FM_LINT_FILE_MEM_KB:-6291456}
  local -a roots shellcheck_args
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  : > "$output.out"
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    shellcheck_args=(--norc)
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      shellcheck_args+=(--external-sources)
    fi
    if [ -n "${FM_LINT_INTERNAL_EXCLUDE:-}" ]; then
      shellcheck_args+=(--exclude="$FM_LINT_INTERNAL_EXCLUDE")
    fi
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      shellcheck_args+=(--extended-analysis=false)
    fi
    # Always one ShellCheck invocation per file, in both the combined
    # (FOLLOW_SOURCES=1, --external-sources) and local changed-file
    # (FOLLOW_SOURCES=0) modes: the 2026-09-05 host-starvation incident this
    # bounds was a single --external-sources invocation, and --external-sources
    # is exactly the combined-mode default, so combining files back into one
    # process here would reintroduce the same unbounded-blowup shape the
    # per-file timeout/memory ceiling below exists to prevent.
    for path in "${roots[@]}"; do
      file_rc=0
      fm_lint_run_one_file "$file_mem_kb" "$file_timeout" "$output.out" "$path" -- "${shellcheck_args[@]}" || file_rc=$?
      if [ "$shard_rc" -eq 0 ] && [ "$file_rc" -ne 0 ]; then
        shard_rc=$file_rc
      fi
    done
    trap - HUP INT TERM
  fi
  printf '%s\n' "$shard_rc" > "$output.rc"
  return "$shard_rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Backend adapters belong behind tasks-axi. Keep direct Beads CLI invocations
# out of firstmate's core scripts so every configured backend follows the same
# lifecycle path.
fm_lint_run_backend_purity() {
  local findings path canonical
  local -a purity_roots
  purity_roots=()
  if [ "$EXPLICIT_PATHS" -eq 0 ]; then
    purity_roots=(bin/*.sh bin/backends/*.sh)
  else
    for path in "${ROOTS[@]}"; do
      [ -f "$path" ] || continue
      # shellcheck disable=SC2016 # Perl, not the shell, expands $ARGV.
      canonical=$("$PERL_BIN" -MCwd=realpath -e '
        my $resolved = realpath($ARGV[0]);
        exit 1 unless defined $resolved;
        print $resolved;
      ' "$path" 2>/dev/null) || continue
      case "$canonical" in
        "$ROOT"/bin/*.sh|"$ROOT"/bin/backends/*.sh)
          purity_roots+=("$canonical")
          ;;
      esac
    done
  fi
  [ "${#purity_roots[@]}" -gt 0 ] || return 0
  findings=$(LC_ALL=C awk '
    function hex_value(character) {
      return index("0123456789abcdef", tolower(character)) - 1
    }
    function ansi_number(digits, base,    i, value) {
      value=0
      for (i=1; i <= length(digits); i++) value=value * base + hex_value(substr(digits, i, 1))
      return value
    }
    # Non-printable and non-ASCII bytes can never spell the bd command, so a
    # placeholder keeps them from colliding into it.
    function ansi_character(value) {
      if (value < 32 || value > 126) return "?"
      return sprintf("%c", value)
    }
    function invokes_bd(segment) {
      sub(/^[[:space:]]+/, "", segment)
      while (1) {
        previous=segment
        sub(/^(if|then|elif|else|while|until|do)[[:space:]]+/, "", segment)
        sub(/^![[:space:]]+/, "", segment)
        sub(/^(command|exec)[[:space:]]+/, "", segment)
        sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
        if (segment ~ /^env[[:space:]]+/) {
          sub(/^env[[:space:]]+/, "", segment)
          while (1) {
            if (segment ~ /^--[[:space:]]+/) {
              sub(/^--[[:space:]]+/, "", segment)
              break
            }
            if (segment ~ /^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/) {
              sub(/^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/) {
              sub(/^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/) {
              sub(/^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/) {
              sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            break
          }
        }
        if (segment == previous) break
      }
      command_word=""
      quote=""
      ansi=0
      for (position=1; position <= length(segment); position++) {
        character=substr(segment, position, 1)
        if (quote == "") {
          if (character ~ /[[:space:]]/) break
          if (character == "$" && position < length(segment)) {
            next_character=substr(segment, position + 1, 1)
            if (next_character == "\"" || next_character == sprintf("%c", 39)) {
              position++
              quote=next_character
              ansi=(next_character == sprintf("%c", 39)) ? 1 : 0
              continue
            }
          }
          if (character == "\"" || character == sprintf("%c", 39)) {
            quote=character
            ansi=0
            continue
          }
          if (character == "\\") {
            position++
            if (position > length(segment)) return 0
            character=substr(segment, position, 1)
          }
          command_word=command_word character
          continue
        }
        if (character == quote) {
          quote=""
          ansi=0
          continue
        }
        if (character == "\\" && (quote == "\"" || ansi)) {
          position++
          if (position > length(segment)) return 0
          escape=substr(segment, position, 1)
          if (ansi) {
            # ANSI-C quoting decodes escapes, so an encoded spelling of the
            # command still runs bd and must be decoded here to be caught.
            value=-1
            if (escape == "x" || escape == "u" || escape == "U") {
              max_digits=2
              if (escape == "u") max_digits=4
              if (escape == "U") max_digits=8
              digits=""
              while (length(digits) < max_digits && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-9A-Fa-f]/) break
                digits=digits digit
                position++
              }
              if (digits == "") {
                # An escape prefix with no digits yields the prefix character.
                command_word=command_word escape
                continue
              }
              value=ansi_number(digits, 16)
            } else if (escape ~ /[0-7]/) {
              digits=escape
              while (length(digits) < 3 && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-7]/) break
                digits=digits digit
                position++
              }
              value=ansi_number(digits, 8)
            }
            if (value >= 0) {
              if (value == 0) {
                # NUL truncates the bash word.
                quote=""
                break
              }
              command_word=command_word ansi_character(value)
              continue
            }
            if (escape == "c") {
              # Control characters can never spell the bd command.
              if (position < length(segment)) position++
              command_word=command_word "?"
              continue
            }
            if (escape ~ /^[abeEfnrtv]$/) {
              command_word=command_word "?"
              continue
            }
            # Remaining ANSI-C escapes keep their character, and bash drops
            # the backslash before any other character.
            command_word=command_word escape
            continue
          }
          character=escape
        }
        command_word=command_word character
      }
      if (quote != "") return 0
      return command_word ~ /(^|\/)bd$/
    }
    function split_commands(line, segments,   position, character, quote, current, count) {
      delete segments
      count=0
      current=""
      quote=""
      for (position=1; position <= length(line); position++) {
        character=substr(line, position, 1)
        if (quote != "") {
          current=current character
          if (character == quote) {
            quote=""
          } else if (quote == "\"" && character == "\\") {
            position++
            if (position <= length(line)) current=current substr(line, position, 1)
          }
          continue
        }
        if (character == "\\") {
          current=current character
          position++
          if (position <= length(line)) current=current substr(line, position, 1)
          continue
        }
        if (character == "\"" || character == sprintf("%c", 39)) {
          quote=character
          current=current character
          continue
        }
        if (character ~ /[();|&{}]/) {
          segments[++count]=current
          current=""
          continue
        }
        current=current character
      }
      if (quote != "") return split(line, segments, /[();|&{}]+/)
      segments[++count]=current
      return count
    }
    /^[[:space:]]*#/ { next }
    {
      count=split_commands($0, segments)
      for (i=1; i<=count; i++) {
        if (invokes_bd(segments[i])) {
          print FILENAME ":" FNR ": direct Beads CLI invocation bypasses tasks-axi"
          break
        }
      }
    }
  ' "${purity_roots[@]}")
  [ -z "$findings" ] || {
    printf '%s\n' "$findings" >&2
    return 1
  }
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FILE_TIMEOUT=${FM_LINT_FILE_TIMEOUT:-120}
case "$FILE_TIMEOUT" in
  ''|*[!0-9]*)
    printf 'fm-lint.sh: FM_LINT_FILE_TIMEOUT must be a positive integer number of seconds, got %s.\n' "$FILE_TIMEOUT" >&2
    exit 2
    ;;
esac
[ "$FILE_TIMEOUT" -gt 0 ] || {
  printf 'fm-lint.sh: FM_LINT_FILE_TIMEOUT must be greater than zero.\n' >&2
  exit 2
}
FAST=0
ANALYSIS_MODE=full
LIST_FILES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

# Resolved only now, after --jobs has had its final say: an explicit
# FM_LINT_FILE_MEM_KB always wins untouched, and the computed default must
# divide by the FINAL job count, not the pre-flag one.
if [ -n "${FM_LINT_FILE_MEM_KB:-}" ]; then
  FILE_MEM_KB=$FM_LINT_FILE_MEM_KB
else
  FILE_MEM_KB=$(fm_lint_default_file_mem_kb "$JOBS")
fi
case "$FILE_MEM_KB" in
  ''|*[!0-9]*)
    printf 'fm-lint.sh: FM_LINT_FILE_MEM_KB must be a positive integer number of KiB, got %s.\n' "$FILE_MEM_KB" >&2
    exit 2
    ;;
esac
[ "$FILE_MEM_KB" -gt 0 ] || {
  printf 'fm-lint.sh: FM_LINT_FILE_MEM_KB must be greater than zero.\n' >&2
  exit 2
}

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
FOLLOW_SOURCES=1
EXCLUDE_CODES=
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
if [ "$CHANGED_MODE" -eq 1 ] && [ "$FAST" -eq 0 ]; then
  FOLLOW_SOURCES=0
  EXCLUDE_CODES=$LOCAL_NOX_EXCLUDE
  ANALYSIS_MODE=local
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
elif [ "$FOLLOW_SOURCES" -eq 0 ]; then
  printf 'fm-lint.sh: local changed-file mode; ShellCheck source following disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_backend_purity || overall_rc=$?
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

index=1
: > "$WEIGHTS"
for path in "${ROOTS[@]}"; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
  if [ -f "$path" ]; then
    weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  else
    weight=1
  fi
  case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
  printf '%s\t%s\t%s\n' "$weight" "$index" "$path" >> "$WEIGHTS"
  index=$((index + 1))
done

# Largest-first deterministic greedy assignment keeps the two bounded workers
# balanced without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" FM_LINT_FILE_TIMEOUT="$FILE_TIMEOUT" FM_LINT_FILE_MEM_KB="$FILE_MEM_KB" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" FM_LINT_FILE_TIMEOUT="$FILE_TIMEOUT" FM_LINT_FILE_MEM_KB="$FILE_MEM_KB" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
      FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
      FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" FM_LINT_FILE_TIMEOUT="$FILE_TIMEOUT" FM_LINT_FILE_MEM_KB="$FILE_MEM_KB" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# Replay both stable shards in deterministic order and select the first nonzero
# shard status. ShellCheck processes every root in a shard after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in "${ROOTS[@]}"; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  if [ "$FOLLOW_SOURCES" -eq 1 ]; then
    source_followed=$((source_directives - source_boundaries))
  else
    source_followed=0
  fi
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

purity_rc=0
fm_lint_run_backend_purity || purity_rc=$?
if [ "$overall_rc" -eq 0 ] && [ "$purity_rc" -ne 0 ]; then
  overall_rc=$purity_rc
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
