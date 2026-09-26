#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI selects
# canonical partitions; no-mistakes invokes the context-selected default, so
# both use this owner without duplicating lint configuration.
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
# Every root runs in its own ShellCheck process, at most two at a time, and
# diagnostics replay in canonical root order, so FM_LINT_JOBS=1 changes
# concurrency, not diagnostics or exit selection.
# Memory bounds that schedule. ShellCheck re-reads and re-analyzes a library at
# every source site, so a root costs about its expanded source tree: with
# 0.11.0, roughly 2.6 KB of RSS per expanded source byte locally and about 1.8x
# that on GitHub's runners. A root weighing more than half the run's heaviest
# root runs alone with the whole memory budget; lighter roots share two workers
# with half the budget each, and one that overruns its half is retried alone.
# The heaviest canonical root needs about 7 GB locally and 13 GB on CI, so a
# full-rigor partition assumes a 16 GB runner.
# The memory budget is FM_LINT_MEMORY_MB when set (64 or more), otherwise
# MemAvailable minus 1024 MB (at least 512 MB) where /proc/meminfo exists.
# Linux enforces it on each ShellCheck process through RLIMIT_AS, so a root
# that needs more fails with "fm-lint.sh: ShellCheck exceeded <N> MB on <root>"
# instead of exhausting the host; on an 8 GB machine a full-rigor run stops
# there rather than starving it.
# --partition 1of2/2of2 splits the entire canonical inventory across
# two CI runners, each with those same bounded workers. Partitions are complete,
# disjoint, and byte-weight balanced; --list-files exposes their actual roots.
# Partition mode is always full source-aware analysis, never changed-only or
# --fast, and does not accept explicit paths. Each partition also runs workflow
# lint and backend-purity checks, keeping either invocation independently useful.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, worker load, memory budget, the heaviest root,
# and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --partition <1of2|2of2> lint one full-rigor canonical CI partition
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
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
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

# Each manifest root gets its own ShellCheck process and its own output and
# "<status><TAB><enforced MB>" result, so replay never depends on scheduling.
# GHC reserves two thirds of RLIMIT_AS for its heap, so the address-space limit
# is 3/2 of the memory budget, and an overrun exits 251 with "shellcheck: out
# of memory". A host that cannot set the limit (macOS) runs uncapped.
fm_lint_worker() {  # <manifest> <output-dir>
  local manifest=$1 output_dir=$2 tab index path invocation_rc i memory_mb='' memory_kib=''
  local -a indexes roots shellcheck_args
  indexes=()
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    indexes+=("$index")
    roots+=("$path")
  done < "$manifest"
  [ "${#roots[@]}" -gt 0 ] || return 0
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
  if [ -n "${FM_LINT_INTERNAL_MEMORY_MB:-}" ] \
    && (ulimit -v "$((FM_LINT_INTERNAL_MEMORY_MB * 1536))") 2>/dev/null; then
    memory_mb=$FM_LINT_INTERNAL_MEMORY_MB
    memory_kib=$((memory_mb * 1536))
  fi
  trap 'fm_lint_worker_stop; exit 129' HUP
  trap 'fm_lint_worker_stop; exit 130' INT
  trap 'fm_lint_worker_stop; exit 143' TERM
  i=0
  while [ "$i" -lt "${#roots[@]}" ]; do
    invocation_rc=0
    (
      [ -z "$memory_kib" ] || ulimit -v "$memory_kib"
      exec "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "${roots[i]}"
    ) > "$output_dir/root.${indexes[i]}.out" 2>&1 < /dev/null &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || invocation_rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
    printf '%s\t%s\n' "$invocation_rc" "$memory_mb" > "$output_dir/root.${indexes[i]}.rc"
    i=$((i + 1))
  done
  trap - HUP INT TERM
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 3 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3"
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
FAST=0
ANALYSIS_MODE=full
PARTITION=
PARTITION_REQUESTED=0
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
    --partition)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --partition requires 1of2 or 2of2.\n' >&2; exit 2; }
      PARTITION=$2
      PARTITION_REQUESTED=1
      shift 2
      ;;
    --partition=*)
      PARTITION=${1#*=}
      PARTITION_REQUESTED=1
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

MEMORY_BUDGET=${FM_LINT_MEMORY_MB:-}
if [ -n "$MEMORY_BUDGET" ]; then
  case "$MEMORY_BUDGET" in
    0*|*[!0-9]*|??????????*) MEMORY_BUDGET=0 ;;
  esac
  [ "$MEMORY_BUDGET" -ge 64 ] || {
    printf 'fm-lint.sh: FM_LINT_MEMORY_MB must be a whole number of MB, 64 or more, got %s.\n' \
      "$FM_LINT_MEMORY_MB" >&2
    exit 2
  }
elif [ -r /proc/meminfo ]; then
  MEMORY_BUDGET=$(awk '/^MemAvailable:/ {mb = int($2 / 1024) - 1024; print (mb < 512 ? 512 : mb); exit}' /proc/meminfo)
fi

case "$PARTITION" in
  '')
    if [ "$PARTITION_REQUESTED" -eq 1 ]; then
      printf 'fm-lint.sh: --partition requires 1of2 or 2of2.\n' >&2
      exit 2
    fi
    ;;
  1of2|2of2)
    if [ "$FAST" -eq 1 ] || [ "$#" -gt 0 ]; then
      printf 'fm-lint.sh: --partition requires full canonical lint; omit --fast and explicit paths.\n' >&2
      exit 2
    fi
    ;;
  *) printf 'fm-lint.sh: --partition must be 1of2 or 2of2, got %s.\n' "$PARTITION" >&2; exit 2 ;;
esac

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
  if [ -z "$PARTITION" ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
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
# Stable largest-first packing of direct bytes selects cross-runner partitions;
# the workers below schedule by expanded source weight instead. Weights are a
# scheduling proxy, never a skip rule.
TAB=$(printf '\t')
fm_lint_root_weights() {
  local index=1 path weight
  for path in "${ROOTS[@]}"; do
    case "$path" in
      *"$TAB"*|*$'\n'*)
        printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
        return 2
        ;;
    esac
    weight=1
    if [ -f "$path" ]; then
      weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
    printf '%s\t%s\t%s\n' "$weight" "$index" "$path"
    index=$((index + 1))
  done
}

if [ -n "$PARTITION" ]; then
  PARTITION_ROOTS=()
  partition_weights=$(fm_lint_root_weights) || exit $?
  while IFS="$TAB" read -r index path; do
    PARTITION_ROOTS+=("$path")
  done < <(printf '%s\n' "$partition_weights" | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n | awk -F '\t' -v want="${PARTITION%%of*}" '
    { shard=(load[2] < load[1]) ? 2 : 1; load[shard]+=$1; if (shard == want) print $2 "\t" $3 }
  ' | LC_ALL=C sort -t "$TAB" -k1,1n)
  ROOTS=("${PARTITION_ROOTS[@]}")
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

WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
fm_lint_root_weights > "$WEIGHTS" || exit $?

# Weigh each root by the source tree ShellCheck analyzes: its own bytes plus,
# when sources are followed, every non-/dev/null `# shellcheck source=` target
# again at each site, recursively, stopping only at a file already on the
# include stack as ShellCheck does.
fm_lint_expanded_weights() {  # <direct-weights-file>
  LC_ALL=C awk -F '\t' -v follow="$FOLLOW_SOURCES" '
    function load(file,    line, target, status) {
      if (file in size) return
      size[file] = 0
      deps[file] = 0
      while ((status = (getline line < file)) > 0) {
        size[file] += length(line) + 1
        if (line ~ /^[[:space:]]*# shellcheck source=/) {
          target = line
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          if (target != "/dev/null") dep[file, ++deps[file]] = target
        }
      }
      if (status == 0) close(file)
    }
    function expand(file, stack,    i, total, outer_cut) {
      if (index(stack, SUBSEP file SUBSEP)) {
        cut = 1
        return 0
      }
      if (file in memo) return memo[file]
      load(file)
      outer_cut = cut
      cut = 0
      total = size[file]
      for (i = 1; i <= deps[file]; i++) total += expand(dep[file, i], stack SUBSEP file SUBSEP)
      # A recursion cut makes this total depend on the include stack.
      if (!cut) memo[file] = total
      cut = cut || outer_cut
      return total
    }
    { print (follow ? expand($3, "") : $1) "\t" $2 "\t" $3 }
  ' "$1"
}

# Concurrent roots together weigh no more than the heaviest root: a root
# heavier than half of it runs alone, and the rest are packed largest-first
# across two workers. Replay order never depends on this assignment.
fm_lint_expanded_weights "$WEIGHTS" | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n > "$WEIGHTS.sorted"
HEAVIEST_WEIGHT=0
HEAVIEST_ROOT=
IFS="$TAB" read -r HEAVIEST_WEIGHT _ HEAVIEST_ROOT < "$WEIGHTS.sorted" || true
: > "$TMP_ROOT/manifest.alone"
: > "$TMP_ROOT/manifest.0"
: > "$TMP_ROOT/manifest.1"
ALONE_COUNT=0
ALONE_LOAD=0
WORKER_LOADS=(0 0)
while IFS="$TAB" read -r weight index path; do
  if [ $((weight * 2)) -gt "$HEAVIEST_WEIGHT" ]; then
    printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.alone"
    ALONE_COUNT=$((ALONE_COUNT + 1))
    ALONE_LOAD=$((ALONE_LOAD + weight))
    continue
  fi
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"

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

fm_lint_run_worker() {  # <manifest-name> <memory-mb>
  local manifest="$TMP_ROOT/manifest.$1" timing="$TMP_ROOT/timing.$1"
  local -a invocation
  invocation=(env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST"
    FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES"
    FM_LINT_INTERNAL_MEMORY_MB="$2" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN"
    "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR")
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" "${invocation[@]}"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        "${invocation[@]}"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      "${invocation[@]}"
  fi
}

fm_lint_start_worker() {  # <manifest-name> <memory-mb>
  [ -s "$TMP_ROOT/manifest.$1" ] || return 0
  fm_lint_run_worker "$@" &
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

# Heaviest roots first, one at a time, so an overrun fails fast.
fm_lint_start_worker alone "$MEMORY_BUDGET"
fm_lint_wait_workers
RETRY_COUNT=0
if [ "$JOBS" -eq 1 ] || [ -z "$MEMORY_BUDGET" ]; then
  worker=0
  while [ "$worker" -lt 2 ]; do
    fm_lint_start_worker "$worker" "$MEMORY_BUDGET"
    [ "$JOBS" -eq 2 ] || fm_lint_wait_workers
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
else
  fm_lint_start_worker 0 "$((MEMORY_BUDGET / 2))"
  fm_lint_start_worker 1 "$((MEMORY_BUDGET / 2))"
  fm_lint_wait_workers
  # A shared root that overran its half of the budget reruns alone with all of it.
  : > "$TMP_ROOT/manifest.retry"
  while IFS="$TAB" read -r index path; do
    rc=
    [ ! -f "$OUTPUT_DIR/root.$index.rc" ] || IFS="$TAB" read -r rc _ < "$OUTPUT_DIR/root.$index.rc" || true
    [ "$rc" = 251 ] || continue
    printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.retry"
    RETRY_COUNT=$((RETRY_COUNT + 1))
  done < <(cat "$TMP_ROOT/manifest.0" "$TMP_ROOT/manifest.1")
  fm_lint_start_worker retry "$MEMORY_BUDGET"
  fm_lint_wait_workers
fi

# Replay every root in canonical order and select the first nonzero status.
# GHC exits 251 when ShellCheck runs out of heap.
overall_rc=0
index=1
for path in "${ROOTS[@]}"; do
  output="$OUTPUT_DIR/root.$index"
  [ ! -f "$output.out" ] || cat "$output.out"
  rc=
  memory_mb=
  [ ! -f "$output.rc" ] || IFS="$TAB" read -r rc memory_mb < "$output.rc" || true
  case "$rc" in
    '')
      printf 'fm-lint.sh: worker produced no result for %s.\n' "$path" >&2
      rc=2
      ;;
    *[!0-9]*) rc=2 ;;
  esac
  if [ "$rc" -eq 251 ]; then
    if [ -n "$memory_mb" ]; then
      printf 'fm-lint.sh: ShellCheck exceeded %s MB on %s\n' "$memory_mb" "$path" >&2
    else
      printf 'fm-lint.sh: ShellCheck ran out of memory on %s\n' "$path" >&2
    fi
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  index=$((index + 1))
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
    printf 'partition\t%s\n' "${PARTITION:-all}"
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
    printf 'alone_root_count\t%s\n' "$ALONE_COUNT"
    printf 'alone_weight_bytes\t%s\n' "$ALONE_LOAD"
    printf 'heaviest_root\t%s\n' "$HEAVIEST_ROOT"
    printf 'heaviest_root_weight_bytes\t%s\n' "$HEAVIEST_WEIGHT"
    printf 'memory_budget_mb\t%s\n' "${MEMORY_BUDGET:-unlimited}"
    printf 'memory_retry_count\t%s\n' "$RETRY_COUNT"
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
