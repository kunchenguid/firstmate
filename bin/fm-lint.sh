#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes both invoke this script with no arguments, so the rule set,
# version, bounded execution, and diagnostics ordering cannot drift.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# With no explicit paths, the file set depends on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh. This is
#     what CI always runs, so CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). That selection is verified against a second git read before it is
#     acted on (see Selection below). A branch with zero matching changed files
#     skips ShellCheck and prints a "no changed lint targets" note, then still
#     validates workflows.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. FM_LINT_JOBS=1
# runs the same shards serially with byte-identical diagnostics and exit selection.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Exit status:
#   0  the selected file set is clean, or there were no changed lint targets
#   1  ShellCheck reported findings
#   2  invalid usage
#   3  the lint did not run to completion, so it carries no verdict at all
#      (see the refusal below)
#
# Two integrity checks stand between this gate and a clean exit. Each answers one
# question, and neither covers the other's:
#   - Execution: was every file in the selected set actually handed to ShellCheck?
#     Each worker records the number of roots it passed for its shard next to that
#     shard's result, and the parent refuses unless those counts sum to the
#     selected count. A shard that dropped roots, and a shard that recorded no
#     count at all, both refuse rather than being read as zero. This is the one
#     place that guarantee is asserted, end to end on what was really passed
#     rather than on an intermediate proxy.
#   - Selection, in changed-files mode only: is the selected set really the
#     changed set? The NUL-safe read that builds it runs in a process
#     substitution whose exit status is invisible, so a git or sort that failed
#     or was truncated there looks exactly like a smaller diff. The selection is
#     therefore compared against a second `git diff` whose status IS observable,
#     and a failed read or a differing count refuses. Full-lint mode needs no
#     such check - its set comes from a shell glob with no external command in
#     the path - and explicit-path mode lints exactly the caller's own list.
# A shard whose result never arrived refuses as well, because diagnostics that
# cannot be replayed cannot be turned into a verdict; that is replay integrity,
# not a second completeness guarantee.
#
# This gate refuses instead of passing when it cannot run. Both checks above, a
# missing ShellCheck, a ShellCheck that is not the pin, one that will not report
# its version, a missing perl, a repository root that cannot be resolved or
# entered, and a temporary directory that cannot be created all print an
# unmissable "LINT NOT RUN" line naming what is missing - plus, when ShellCheck
# is the missing piece, the exact version required and how to get it - then exit
# 3.
# 3 is deliberately not 127: 127 is the shell's own "command not found", so a
# caller that sees it cannot tell whether this script refused or was never found
# at all, and a gate that reads lint output for actionable findings sees none in
# a refusal and can record a clean step that in fact checked nothing.
#
# Provisioning is opt-in and never a side effect of linting, because a gate that
# reaches the network to validate is harder to trust and breaks on an offline
# host. A caller that deliberately wants it passes --provision-shellcheck <dir>
# (or sets FM_LINT_PROVISION_SHELLCHECK=<dir>) to ENSURE the pin is present in
# <dir>: an existing <dir>/shellcheck that already reports the pinned version is
# only put first on PATH, and bin/fm-install-shellcheck.sh installs the build
# only when <dir> does not already hold the pin, so a repeat run neither
# refetches nor breaks offline. A fresh install is checksum-verified; a binary
# already sitting in that caller-owned directory is taken at the version it
# reports of itself, so what holds for it is the pin, not the checksum. Either
# way the version enforcement below runs on whatever ends up on PATH, so a build
# that reports anything other than the pin is refused rather than used. A
# provisioning attempt that fails refuses exactly like a missing tool; it never
# degrades into a pass. That installer fetches the Linux x86_64 release, so on
# any other platform install the pinned build from the upstream ShellCheck
# release instead and put it first on PATH. CI provisions in its own step
# (.github/workflows/ci.yml) and never needs this.
#
# --required-version and --list-files answer with no ShellCheck present at all,
# because bin/fm-install-shellcheck.sh asks this script which version to fetch:
# breaking that would break the installer that repairs a missing tool.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --provision-shellcheck <dir>
#                                      opt in to ensuring the pin is in <dir>,
#                                      installing it only if it is not already
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
# The "checked nothing" status. Distinct from 0 (clean), 1 (findings), 2 (usage),
# and 127 (the shell's command-not-found), so no caller can confuse a refusal
# with a clean lint, a lint failure, or this script being absent.
REFUSED_EXIT=3
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
SELF="$SELF_DIR/fm-lint.sh"
ROOT=$(CDPATH='' cd -- "$SELF_DIR/.." 2>/dev/null && pwd -P)

# fm_lint_refuse <reason> [shellcheck]: the single exit for "this gate could not
# run". Says so unmissably rather than letting a caller read silence as a clean
# lint, and with the second argument also names the pinned tool, its exact
# version, and both ways to get it. See the exit-status note in the header.
fm_lint_refuse() {
  printf 'fm-lint.sh: LINT NOT RUN: %s\n' "$1" >&2
  printf 'fm-lint.sh: nothing trustworthy was checked, so this is a failed lint gate, not a clean one.\n' >&2
  if [ "${2:-}" = shellcheck ]; then
    printf 'fm-lint.sh: required tool: ShellCheck, exactly version %s (pinned so local and CI cannot diverge).\n' \
      "$REQUIRED_SHELLCHECK" >&2
    printf 'fm-lint.sh: on Linux x86_64: bin/fm-install-shellcheck.sh <dir>, then put <dir> first on PATH.\n' >&2
    printf 'fm-lint.sh: or, same platform, for this run only: bin/fm-lint.sh --provision-shellcheck <dir>\n' >&2
    printf 'fm-lint.sh: on macOS or any other platform that installer does not cover: install the %s build from\n' \
      "$REQUIRED_SHELLCHECK" >&2
    printf 'fm-lint.sh: https://github.com/koalaman/shellcheck/releases/tag/v%s and put its directory first on PATH.\n' \
      "$REQUIRED_SHELLCHECK" >&2
  fi
  exit "$REFUSED_EXIT"
}

# The repository root every relative canonical root and worker manifest path is
# resolved against. Refuses on the same contract when it cannot be resolved or
# entered: the selected file set would be unreachable, so nothing could be
# checked. Resolution is only believed when this script is actually where it came
# out, because `cd ""` is a successful no-op in bash: an empty resolution - from a
# dirname that failed, or one that is not on PATH at all - would otherwise pass
# for the caller's own directory and lint a file set that is not this repository's.
if [ -z "$SELF_DIR" ] || [ -z "$ROOT" ] || [ ! -f "$SELF" ] \
  || ! CDPATH='' cd -- "$ROOT" 2>/dev/null; then
  fm_lint_refuse \
    "could not resolve and enter the repository root holding this script (this script '$SELF', root '$ROOT')"
fi

# fm_lint_provision_shellcheck <dir>: opt-in only, never reached by a default
# lint. ENSURES the pin is in <dir> and puts <dir> first on PATH for this run: a
# <dir>/shellcheck that already reports the pin is used as it stands, so a repeat
# run does not refetch and an offline host with the right binary already on disk
# still lints; anything else is installed, checksum-verified, by the installer. A
# failed install refuses; it never falls through to a lint that silently used
# some other ShellCheck, or to no lint at all. Skipping the download never skips
# the pin: the main flow still resolves and enforces the version on whatever this
# leaves on PATH, so a build here that reports any other version is refused. What
# an already-present binary is trusted for is that reported version, though - it
# is not re-verified against the pinned checksum the installer checks.
fm_lint_provision_shellcheck() {
  local dir=$1 log resolved_dir present=
  resolved_dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || resolved_dir=
  if [ -n "$resolved_dir" ] && [ -x "$resolved_dir/shellcheck" ]; then
    present=$("$resolved_dir/shellcheck" --version 2>/dev/null | awk '/^version:/ {print $2; exit}')
  fi
  if [ "$present" = "$REQUIRED_SHELLCHECK" ]; then
    PATH="$resolved_dir:$PATH"
    export PATH
    printf 'fm-lint.sh: ShellCheck %s is already provisioned in %s; not fetching.\n' \
      "$REQUIRED_SHELLCHECK" "$resolved_dir" >&2
    return 0
  fi
  log=$("$SELF_DIR/fm-install-shellcheck.sh" "$dir" 2>&1) || {
    printf '%s\n' "$log" >&2
    fm_lint_refuse "provisioning ShellCheck $REQUIRED_SHELLCHECK into $dir failed" shellcheck
  }
  resolved_dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) \
    || fm_lint_refuse "provisioning reported success but $dir is not a readable directory" shellcheck
  [ -x "$resolved_dir/shellcheck" ] \
    || fm_lint_refuse "provisioning reported success but $resolved_dir/shellcheck is not executable" shellcheck
  PATH="$resolved_dir:$PATH"
  export PATH
  printf 'fm-lint.sh: provisioned ShellCheck %s into %s on request.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved_dir" >&2
}

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output rc=0
  local -a roots
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    "$FM_LINT_SHELLCHECK" --norc --external-sources -- "${roots[@]}" > "$output.out" 2>&1 &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "${#roots[@]}" > "$output.checked"
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
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

# Prints the header block from line 2 up to the first non-comment line, so the
# usage text cannot drift out of a hardcoded line range when the header changes.
fm_lint_usage() {
  sed -n '2,${/^#/!q; s/^# \{0,1\}//; p;}' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
PROVISION_DIR=${FM_LINT_PROVISION_SHELLCHECK:-}
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
    --provision-shellcheck)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint.sh: --provision-shellcheck requires a directory.\n' >&2
        exit 2
      }
      PROVISION_DIR=$2
      shift 2
      ;;
    --provision-shellcheck=*)
      PROVISION_DIR=${1#*=}
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
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

[ -z "$PROVISION_DIR" ] || fm_lint_provision_shellcheck "$PROVISION_DIR"

if ! command -v shellcheck >/dev/null 2>&1; then
  fm_lint_refuse 'no shellcheck was found on PATH' shellcheck
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  fm_lint_refuse 'no perl was found on PATH, and it is required for bounded worker cleanup'
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
# Reported only once a version actually resolved: a banner with an empty version
# reads like a successful resolution directly above the refusal that follows it.
if [ -z "$resolved" ]; then
  fm_lint_refuse "the shellcheck at $SHELLCHECK_BIN did not report a version" shellcheck
fi
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  fm_lint_refuse "the shellcheck at $SHELLCHECK_BIN is version $resolved, not the pinned $REQUIRED_SHELLCHECK" \
    shellcheck
fi

if [ "$CHANGED_MODE" -eq 1 ]; then
  # Selection integrity: the read above cannot report its own failure, because a
  # process substitution's exit status is invisible, so a git or a sort that died
  # or was truncated there is indistinguishable from a smaller diff - whether that
  # leaves no roots or merely fewer. Ask git again through a plain substitution
  # whose status IS observable, count the same canonical existing paths, and act
  # only on a selection that answer agrees with.
  changed_recheck=$(git -c core.quotePath=false diff --name-only --diff-filter=ACMR "$merge_base" -- 2>&1) || {
    printf '%s\n' "$changed_recheck" >&2
    fm_lint_refuse "git could not report what changed since $merge_base, so the lint target set is unproven"
  }
  recheck_count=0
  changed_path=
  while IFS= read -r changed_path; do
    [ -n "$changed_path" ] || continue
    fm_lint_is_canonical_root "$changed_path" || continue
    [ -f "$changed_path" ] || continue
    recheck_count=$((recheck_count + 1))
  done <<CHANGED_RECHECK
$changed_recheck
CHANGED_RECHECK
  [ "$recheck_count" -eq "$ROOT_COUNT" ] || fm_lint_refuse \
    "git reports $recheck_count changed lint targets but reading them selected $ROOT_COUNT, so the selection is wrong"
  if [ "$ROOT_COUNT" -eq 0 ]; then
    printf 'fm-lint.sh: no changed lint targets\n'
    overall_rc=0
    fm_lint_run_workflows || overall_rc=$?
    exit "$overall_rc"
  fi
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") \
  || fm_lint_refuse "could not create a temporary working directory under ${TMPDIR:-/tmp}"
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
        env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
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
lost_shards=
uncounted_shards=
checked_total=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
    if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
      overall_rc=$rc
    fi
  else
    lost_shards="${lost_shards:+$lost_shards, }$worker"
  fi
  shard_checked=
  [ ! -f "$output.checked" ] || shard_checked=$(cat "$output.checked" 2>/dev/null)
  case "$shard_checked" in
    ''|*[!0-9]*) uncounted_shards="${uncounted_shards:+$uncounted_shards, }$worker" ;;
    *) checked_total=$((checked_total + shard_checked)) ;;
  esac
  worker=$((worker + 1))
done

# A shard whose result never arrived (a worker killed off, an out-of-memory host)
# leaves its diagnostics unreplayable, so this run has no verdict to report even if
# the surviving shard was clean. Refused after the replay above so whatever the
# other shard did find is still printed for whoever has to act on it.
[ -z "$lost_shards" ] || fm_lint_refuse \
  "a bounded lint worker produced no result for shard $lost_shards of $SHARD_COUNT, so those files were not checked"

# Execution integrity, asserted once for the whole run on what the workers really
# handed over: a shard that says nothing about what it checked cannot be counted as
# zero, and the roots ShellCheck actually received must be the selected set. Every
# selected path is weighted and assigned unconditionally, including one that does
# not exist, so a healthy run always balances here.
[ -z "$uncounted_shards" ] || fm_lint_refuse \
  "shard $uncounted_shards of $SHARD_COUNT recorded no count of what it checked, so this run cannot account for it"
[ "$checked_total" -eq "$ROOT_COUNT" ] || fm_lint_refuse \
  "ShellCheck was handed $checked_total of the $ROOT_COUNT selected files, so they were not all checked"

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
  source_followed=$((source_directives - source_boundaries))
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

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
