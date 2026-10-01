#!/usr/bin/env bash
# repro-check.sh - disposable-worktree acceptance checks for issue-tracer v3.
set -eu
export LC_ALL=C

to_shell_path() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*) if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; return; fi ;;
  esac
  printf '%s\n' "$1"
}

to_native_path() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*)
      command -v cygpath >/dev/null 2>&1 || return 1
      cygpath -w "$1"
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "repro-check: not inside a git work tree" >&2; exit 2; }
root="$(to_shell_path "$root")"
root_real="$(cd "$root" && pwd -P)"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
trace_root_real=""

usage() { echo "usage: repro-check.sh {run|checkpoint|verify-checkpoint|verify-semantics|anchor|verify-anchor} --slug <slug> ..." >&2; exit 2; }
valid_slug() { case "$1" in ''|*[!a-z0-9-]*) return 1;; *) return 0;; esac; }
valid_id() {
  local suffix
  case "$1" in
    C[0-9]*) suffix="${1#C}"; case "$suffix" in ''|*[!0-9]*) return 1;; esac; return 0;;
    *) return 1;;
  esac
}
has_bad_field() { case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 0;; *) return 1;; esac; }
# Unlike a shell option, a regex beginning with `--` is valid input. Keep it
# as data for grep by using `--` at the option/operand boundary. Reject control
# bytes before echoing the regex in the result artifact.
has_bad_control() {
  # Shell variables can carry newlines, but grep treats them as record
  # separators; reject those explicitly before scanning the remaining bytes.
  case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 0;; esac
  local matches
  # grep -c drains stdin. A terminal grep -q can make printf receive SIGPIPE
  # under inherited pipefail, turning a real control byte into a false miss.
  matches="$(LC_ALL=C printf '%s' "$1" | LC_ALL=C grep -c '[[:cntrl:]]' || true)"
  [ "${matches:-0}" -gt 0 ]
}
# POSIX pathnames may contain tabs/newlines, but trace paths are also rendered
# in diagnostics. Reject every C0/DEL byte at the checkpoint boundary so an
# ANSI escape or other control byte cannot become terminal-visible evidence.
has_bad_path() {
  has_bad_control "$1"
}
is_sha1() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }
is_inside_root() {
  case "$1" in /*|[A-Za-z]:*|*\\*) return 1;; esac
  case "/$1/" in */../*|*/./*) return 1;; esac
  return 0
}

# Resolve a repository-relative path without following a symlink or junction in
# any component. `-f`, `cp`, and `git hash-object` all follow links, so checking
# only the parent directory is insufficient: a link leaf could copy or freeze
# bytes from outside the repository and later make verification report a false
# match. Use the canonical repository root as the walk anchor so a symlinked
# checkout path does not weaken the component checks.
repo_path_safe() {
  local rel="$1" current part
  is_inside_root "$rel" || return 1
  current="$root_real"
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    current="$current/$part"
    [ -L "$current" ] && return 1
  done <<EOF
$(printf '%s' "$rel" | tr '/' '\n')
EOF
  [ -e "$current" ] || return 1
  return 0
}

repo_file_safe() {
  local rel="$1"
  repo_path_safe "$rel" || return 1
  [ -f "$root_real/$rel" ] || return 1
  return 0
}
issue_traces_base="$root_real/.agents/issue-traces"

# Path-only preflight: trace_dir (default or --trace-dir override) must be
# textually rooted at <repo>/.agents/issue-traces/ before we touch the
# filesystem. Runs before any mkdir/write, so a caller cannot point the
# script at an arbitrary path via that flag.
validate_trace_dir_prefix() {
  has_bad_path "$trace_dir" && {
    echo "repro-check: --trace-dir cannot contain control bytes" >&2
    exit 2
  }
  case "$trace_dir/" in
    "$root"/.agents/issue-traces/*) ;;
    *)
      echo "repro-check: --trace-dir must be inside .agents/issue-traces" >&2
      exit 2
      ;;
  esac
}

# Symlink-escape guard: resolve the deepest EXISTING ancestor of trace_dir
# (it may not exist yet) and require it to land inside the repo root. Must
# run before any mkdir -p, since mkdir -p happily follows an existing
# symlinked ancestor before any later check on the final path can catch it.
refuse_ancestor_symlink_escape() {
  local check="${1:-$trace_dir}" resolved parent
  while :; do
    # `-e` is false for a dangling link. Test `-L` before deciding whether to
    # ascend so a broken link cannot be skipped and later followed by mkdir -p.
    if [ -L "$check" ]; then
      echo "repro-check: --trace-dir must be inside .agents/issue-traces" >&2
      exit 2
    fi
    [ -e "$check" ] && break
    parent="$(dirname "$check")"
    [ "$parent" != "$check" ] || break
    check="$parent"
  done
  resolved="$(cd "$check" && pwd -P)"
  case "$resolved/" in
    "$root_real"/*) ;;
    *)
      echo "repro-check: --trace-dir must be inside .agents/issue-traces" >&2
      exit 2
      ;;
  esac
}

# Post-mkdir, strict resolution check: once a path under trace_dir exists,
# its pwd -P form must land inside <repo-root>/.agents/issue-traces/. Also
# refuses the path itself being a symlink (created between the ancestor
# check above and this call).
require_contained() {
  local dir="$1" resolved
  [ -e "$dir" ] || return 0
  if [ -L "$dir" ]; then
    echo "repro-check: refusing symlinked path: $dir" >&2
    exit 2
  fi
  resolved="$(cd "$dir" && pwd -P)"
  case "$resolved/" in
    "$issue_traces_base"/*) ;;
    *)
      echo "repro-check: refusing path outside .agents/issue-traces: $dir" >&2
      exit 2
      ;;
  esac
}

# Validate a trace artifact immediately before reading or hashing it.  Shell
# tests such as `[ -f ]` and `git hash-object` follow symlinks, so walk every
# component first and require the canonical parent to remain beneath the
# canonical trace root.  This rejects both POSIX symlinks and Windows
# junctions surfaced by MSYS as `test -L`, including dangling leaf links.
trace_path_safe() {
  local path="$1" kind="${2:-file}" ancestor parent resolved
  [ -n "$trace_root_real" ] || { echo "repro-check: trace root is not initialized" >&2; exit 2; }
  case "$path/" in
    "$trace_root_real/"*) ;;
    *) echo "repro-check: refusing path outside canonical trace root: $path" >&2; exit 2;;
  esac
  case "$path/" in
    */../*|*/./*) echo "repro-check: refusing ambiguous trace path: $path" >&2; exit 2;;
  esac
  ancestor="$path"
  while [ "$ancestor" != "$trace_root_real" ] && [ "$ancestor" != "/" ]; do
    if [ -L "$ancestor" ]; then
      echo "repro-check: refusing symlinked trace component: $ancestor" >&2
      exit 2
    fi
    ancestor="$(dirname "$ancestor")"
  done
  [ "$ancestor" = "$trace_root_real" ] || { echo "repro-check: trace path is not rooted at canonical trace directory: $path" >&2; exit 2; }
  [ "$path" = "$trace_root_real" ] && { [ "$kind" = dir ] && [ -d "$path" ]; return $?; }
  parent="$(dirname "$path")"
  [ -d "$parent" ] || return 1
  resolved="$(cd "$parent" 2>/dev/null && pwd -P)" || { echo "repro-check: could not resolve trace artifact parent: $path" >&2; exit 2; }
  case "$resolved/" in
    "$trace_root_real/"*) ;;
    *) echo "repro-check: trace artifact parent resolves outside canonical trace root: $path" >&2; exit 2;;
  esac
  case "$kind" in
    file) [ -f "$path" ] || return 1;;
    dir) [ -d "$path" ] || return 1;;
    *) echo "repro-check: internal invalid trace path kind: $kind" >&2; exit 2;;
  esac
}

set_trace_root() {
  require_contained "$trace_dir"
  [ -d "$trace_dir" ] || { echo "repro-check: trace directory is missing: $trace_dir" >&2; exit 2; }
  trace_root_real="$(cd "$trace_dir" 2>/dev/null && pwd -P)" || { echo "repro-check: could not resolve trace directory: $trace_dir" >&2; exit 2; }
  trace_path_safe "$trace_root_real" dir >/dev/null
}

trace_for() {
  [ -n "$trace_dir" ] || trace_dir="$root/.agents/issue-traces/$slug"
  validate_trace_dir_prefix
  refuse_ancestor_symlink_escape
}
manifest_for() { trace_for; printf '%s\n' "$trace_dir/repro/checkpoint.manifest"; }

# Structural integrity of the checkpoint manifest, shared by `checkpoint` and
# `verify-checkpoint` so both refuse the same mangled file. Three properties:
# line 1 is the version header AND records the expected data-row count; every
# later line carries exactly 10 TAB-separated fields; the seq column counts
# 1..N with no gaps.
#
# The recorded count is what makes this total rather than a PREFIX invariant.
# Seq contiguity alone is satisfied by any prefix of a valid file, so `head -3`
# (or deleting just the last row) would still validate - silently dropping
# those checks from the replay set AND un-freezing their paths, so a plain
# `checkpoint` could then re-baseline a weakened check to green through the
# very guard below. Comparing the header count against the rows actually
# present closes the tail; seq closes the middle. Together they refuse deletion
# anywhere, reordering, duplication, and field mangling.
#
# The legacy header with no `rows=` count (`... v1`) is REJECTED rather than
# accepted for compatibility: accepting it would itself be a one-line bypass
# (write the old header, then truncate freely). Existing v3 manifests can,
# however, contain an AMEND row with the historical FORMAT_ONLY reason. That
# reason is accepted only by verification (and by a later, newly reasoned
# amendment while recovering such a trace); do_checkpoint never accepts it as
# a new reason, so FORMAT_ONLY cannot be introduced through this script.
#
# This is tamper-EVIDENCE, not tamper-proofing: the trace directory is the
# agent's own write surface, so a rewriter that renumbers every row AND
# restamps the header count still gets through, and so does deleting the
# manifest outright and re-running `checkpoint` (nothing binds the file's
# existence or completeness to anything outside it). What it stops is a
# partial write or a hand edit that leaves the file internally inconsistent.
validate_manifest() {
  local file="$1" allow_conflicts="${2:-}" allow_legacy_format_only="${3:-}" problem counts header
  trace_path_safe "$file" file || { echo "repro-check: checkpoint manifest missing or unsafe" >&2; exit 2; }
  # `awk` on some supported shells normalizes CRLF records, so inspect the
  # raw header first. A CRLF manifest is not byte-valid for the checkpoint
  # format and must fail as a malformed header rather than reaching replay and
  # reporting a stale digest.
  header=""
  IFS= read -r header < "$file" || true
  case "$header" in
    *$'\r'*) problem="header" ;;
    *) problem="$(awk -F '\t' -v allow_conflicts="$allow_conflicts" -v allow_legacy_format_only="$allow_legacy_format_only" '
    NR == 1 {
      if ($0 !~ /^# issue-tracer checkpoint manifest v1 rows=[0-9]+$/) { bad = "header"; exit }
      declared = $0
      sub(/^.*rows=/, "", declared)
      declared = declared + 0
      next
    }
    {
      rows += 1
      if (NF != 10) { bad = "fields " NR; exit }
      if ($1 "" != rows "") { bad = "seq " NR; exit }
      if ($3 ~ /[[:cntrl:]]/) { bad = "unsafe-path"; exit }
      if ($2 != "CHECKPOINT" && $2 != "AMEND") { bad = "kind " NR; exit }
      if (($2 == "CHECKPOINT" && $10 != "-") || ($2 == "AMEND" && $10 != "CHECK_WRONG" && $10 != "AC_CHANGED_BY_USER" && !(allow_legacy_format_only == "allow-legacy-format-only" && $10 == "FORMAT_ONLY"))) { bad = "reason " NR; exit }
      # A pair is frozen by its first row; every later row for that exact
      # (path, check-id) pair must be a reasoned AMEND. A path may legitimately
      # carry multiple checks, so path alone is not an identity key here.
      # Length-prefix the path so the composite key remains injective even if
      # a legal path contains the awk SUBSEP byte.
      pair = length($3) ":" $3 ":" $6
      if ($2 == "CHECKPOINT" && seen_pair[pair]) { bad = "duplicate " NR; exit }
      if ($2 == "AMEND" && !seen_pair[pair]) { bad = "orphan " NR; exit }
      seen_pair[pair] = 1
      latest_path[pair] = $3
      latest_blob[pair] = $4
    }
    END {
      if (bad != "") { print bad; exit }
      if (NR == 0) { print "header"; exit }
      # The effective manifest is one latest row per pair. A checkpoint tree
      # has one blob per path, so identical blobs for multiple checks are
      # safely deduplicable but divergent effective blobs are invalid rather
      # than silently becoming last-writer-wins by path.
      for (pair in latest_path) {
        path = latest_path[pair]
        if (effective_seen[path] && effective_blob[path] != latest_blob[pair] && allow_conflicts != "allow-conflicts") {
          print "conflict " path
          exit
        }
        effective_seen[path] = 1
        effective_blob[path] = latest_blob[pair]
      }
      if (declared != rows + 0) { print "count " declared " " rows + 0 }
    }
  ' "$file")" ;;
  esac
  case "$problem" in
    '') return 0 ;;
    'fields '*) echo "repro-check: checkpoint manifest line ${problem#fields } does not have 10 tab-separated fields" >&2 ;;
    'seq '*) echo "repro-check: checkpoint manifest seq is not contiguous (row deleted or reordered) at line ${problem#seq }" >&2 ;;
    'duplicate '*) echo "repro-check: checkpoint manifest line ${problem#duplicate } duplicates an existing CHECKPOINT pair (re-freezes without an AMEND reason)" >&2 ;;
    'orphan '*) echo "repro-check: checkpoint manifest line ${problem#orphan } AMENDs an unknown path/check-id pair" >&2 ;;
    'unsafe-path') echo "repro-check: checkpoint manifest contains a path with control bytes" >&2 ;;
    'conflict '*) echo "repro-check: checkpoint manifest has conflicting effective blobs for path ${problem#conflict }" >&2 ;;
    'kind '*) echo "repro-check: checkpoint manifest line ${problem#kind } has an invalid kind (use CHECKPOINT or AMEND)" >&2 ;;
    'reason '*) echo "repro-check: checkpoint manifest line ${problem#reason } has an invalid reason for its kind" >&2 ;;
    'count '*)
      counts="${problem#count }"
      echo "repro-check: checkpoint manifest header records ${counts%% *} rows, found ${counts#* } (rows deleted or truncated)" >&2
      ;;
    *) echo "repro-check: invalid manifest header (want '# issue-tracer checkpoint manifest v1 rows=<N>' on line 1)" >&2 ;;
  esac
  exit 2
}

# True when an exact (path, check-id) pair already appears in the manifest.
# Multiple checks may share a path, but a pair can only be introduced once and
# then superseded by an AMEND row.
manifest_has_pair() {
  trace_path_safe "$1" file || return 1
  awk -F '\t' -v want_path="$2" -v want_check="$3" \
    'NR > 1 && $3 == want_path && $6 == want_check { found = 1; exit } END { exit !found }' "$1"
}

# Append one data row and restamp the header's recorded count in a single
# temp-file swap, so the manifest is never observable in a state where the
# count and the rows disagree - a mid-loop `exit` (an invalid later path, an
# already-frozen repeat) leaves a consistent file rather than bricking it.
# Mirrors bound_log's `$log.truncate.tmp` pattern; refuse_nonregular_target
# guards the temp name as well as the manifest, and `mv` renames over the
# destination rather than writing through a symlink planted there.
append_manifest_row() {
  local file="$1" count="$2" row="$3" temp
  temp="$file.append.tmp"
  trace_path_safe "$(dirname "$file")" dir || { echo "repro-check: manifest directory is missing or unsafe" >&2; exit 2; }
  trace_path_safe "$file" file || true
  refuse_nonregular_target "$file"
  open_exclusive_target "$temp" || { echo "repro-check: could not create manifest temp file safely" >&2; exit 2; }
  {
    printf '# issue-tracer checkpoint manifest v1 rows=%s\n' "$count"
    awk 'NR > 1' "$file"
    printf '%s\n' "$row"
  } >&"$exclusive_fd"
  close_exclusive_target
  mv "$temp" "$file"
}

# Refuse to redirect/append into a pre-existing path that is not a regular
# file (a symlink, device, fifo, directory, ...). Must run immediately before
# every `>`/`>>` into a leaf artifact path (base/head logs, checkpoint
# manifest), since a pre-existing symlink there would otherwise be silently
# followed by the shell redirection, writing through it to an arbitrary
# target.
refuse_nonregular_target() {
  local path="$1"
  if { [ -e "$path" ] && [ ! -f "$path" ]; } || [ -L "$path" ]; then
    echo "repro-check: refusing non-regular target: $path" >&2
    exit 2
  fi
}

# Open a new regular file and retain a descriptor. `exec {var}>...` would be
# convenient, but automatic brace descriptor allocation is Bash 4+ syntax and
# breaks the system Bash 3.2 shipped with macOS. Probe a small reserved range
# of descriptors instead; callers write through $exclusive_fd and close it
# before publishing the path with rename/mv. The parent directory is checked
# by the caller; portable shell code cannot hold an open directory descriptor
# across all supported Bash/MSYS environments, so the final rename remains
# the containment boundary.
open_exclusive_target() {
  local path="$1" fd
  refuse_nonregular_target "$path"
  set -C
  for fd in 9 10 11 12 13 14 15 16 17 18 19; do
    # A successful duplication means the descriptor is already in use; leave
    # it untouched and try the next reserved descriptor.
    if true >&"$fd" 2>/dev/null; then
      continue
    fi
    case "$fd" in
      9) exec 9>"$path" && exclusive_fd=9 && set +C && return 0 ;;
      10) exec 10>"$path" && exclusive_fd=10 && set +C && return 0 ;;
      11) exec 11>"$path" && exclusive_fd=11 && set +C && return 0 ;;
      12) exec 12>"$path" && exclusive_fd=12 && set +C && return 0 ;;
      13) exec 13>"$path" && exclusive_fd=13 && set +C && return 0 ;;
      14) exec 14>"$path" && exclusive_fd=14 && set +C && return 0 ;;
      15) exec 15>"$path" && exclusive_fd=15 && set +C && return 0 ;;
      16) exec 16>"$path" && exclusive_fd=16 && set +C && return 0 ;;
      17) exec 17>"$path" && exclusive_fd=17 && set +C && return 0 ;;
      18) exec 18>"$path" && exclusive_fd=18 && set +C && return 0 ;;
      19) exec 19>"$path" && exclusive_fd=19 && set +C && return 0 ;;
    esac
  done
  set +C
  return 1
}

close_exclusive_target() {
  case "${exclusive_fd:-}" in
    9) exec 9>&- ;;
    10) exec 10>&- ;;
    11) exec 11>&- ;;
    12) exec 12>&- ;;
    13) exec 13>&- ;;
    14) exec 14>&- ;;
    15) exec 15>&- ;;
    16) exec 16>&- ;;
    17) exec 17>&- ;;
    18) exec 18>&- ;;
    19) exec 19>&- ;;
  esac
  exclusive_fd=""
}

bound_log() {
  local log="$1" total kept=1048576 omitted temp
  total="$(wc -c < "$log" | tr -d ' ')"
  [ "$total" -le 2097152 ] && return
  temp="$log.truncate.tmp"
  open_exclusive_target "$temp" || { echo "repro-check: could not create log temp file safely" >&2; exit 2; }
  { head -c "$kept" "$log"; printf '\n[... truncated %s bytes ...]\n' "$((total - (kept * 2)))"; tail -c "$kept" "$log"; } >&"$exclusive_fd"
  close_exclusive_target
  mv "$temp" "$log"
}

run_one() {
  local cwd="$1" log="$2" seconds="$3"; shift 3
  local status=0 pid started timed=0 waited=0 temp parent
  parent="$(dirname "$log")"
  trace_path_safe "$parent" dir || { echo "repro-check: log parent is missing or unsafe" >&2; exit 2; }
  refuse_nonregular_target "$log"
  temp="$log.run.tmp.$$.$RANDOM"
  open_exclusive_target "$temp" || { echo "repro-check: could not create log temp file safely" >&2; exit 2; }
  if [ "${REPRO_CHECK_FORCE_FALLBACK:-0}" != "1" ] && command -v timeout >/dev/null 2>&1; then
    ( cd "$cwd" && timeout --foreground -k 5 "${seconds}s" "$@" ) >&"$exclusive_fd" 2>&1 || status=$?
  else
    # POSIX watchdog fallback: run the child in its own process group so the
    # whole group (not just the immediate child) can be killed on timeout.
    if command -v setsid >/dev/null 2>&1; then
      ( cd "$cwd" && exec setsid "$@" ) >&"$exclusive_fd" 2>&1 &
    else
      set -m
      ( cd "$cwd" && "$@" ) >&"$exclusive_fd" 2>&1 &
      set +m
    fi
    pid=$!
    started=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$((SECONDS - started))" -ge "$seconds" ]; then
        timed=1
        kill -TERM -- "-$pid" >/dev/null 2>&1 || kill -TERM "$pid" >/dev/null 2>&1 || true
        waited=0
        while [ "$waited" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
        kill -KILL -- "-$pid" >/dev/null 2>&1 || kill -KILL "$pid" >/dev/null 2>&1 || true
        break
      fi
      sleep 1
    done
    wait "$pid" 2>/dev/null || status=$?
    [ "$timed" -eq 0 ] || status=124
  fi
  close_exclusive_target
  trace_path_safe "$parent" dir || { echo "repro-check: log parent became unsafe" >&2; exit 2; }
  refuse_nonregular_target "$log"
  mv "$temp" "$log"
  bound_log "$log"
  printf '%s\n' "$status"
}

worktree_path_safe() {
  local rel="$1" current part resolved target
  is_inside_root "$rel" || return 1
  [ -n "${worktree_real:-}" ] || return 1
  current="$worktree_real"
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    current="$current/$part"
    [ -L "$current" ] && return 1
    if [ -e "$current" ]; then
      if [ -d "$current" ]; then
        resolved="$(cd "$current" 2>/dev/null && pwd -P)" || return 1
        case "$resolved/" in
          "$worktree_real/"*) ;;
          *) return 1 ;;
        esac
      elif [ "$current" != "$worktree_real/$rel" ] || [ ! -f "$current" ]; then
        return 1
      fi
    fi
  done <<EOF
$(printf '%s' "$rel" | tr '/' '\n')
EOF
  target="$worktree_real/$rel"
  [ ! -L "$target" ] || return 1
  return 0
}

copy_path() {
  local rel="$1" source target source_dir target_parent
  is_inside_root "$rel" || { echo "repro-check: --copy path must be repo-relative without ..: $rel" >&2; exit 2; }
  repo_path_safe "$rel" || { echo "repro-check: --copy path must remain inside repo without symlink components: $rel" >&2; exit 2; }
  source="$root_real/$rel"
  source_dir="$(cd "$(dirname "$source")" && pwd -P)"
  case "$source_dir" in "$root_real"|"$root_real"/*) ;; *) echo "repro-check: --copy path resolves outside repo: $rel" >&2; exit 2;; esac
  target="$worktree_real/$rel"
  target_parent="$(dirname "$target")"
  worktree_path_safe "$rel" || { echo "repro-check: --copy target must remain inside disposable worktree: $rel" >&2; exit 2; }
  mkdir -p -- "$target_parent"
  worktree_path_safe "$rel" || { echo "repro-check: --copy target became unsafe while preparing destination: $rel" >&2; exit 2; }
  rm -rf -- "$target"
  worktree_path_safe "$rel" || { echo "repro-check: --copy target became unsafe before copy: $rel" >&2; exit 2; }
  cp -R -- "$source" "$target"
  worktree_path_safe "$rel" || { echo "repro-check: --copy target became unsafe after copy: $rel" >&2; exit 2; }
}

link_deps() {
  [ "$deps" = link ] || return 0
  [ -e "$root/node_modules" ] || return 0
  local source_real linked_real
  source_real="$(cd "$root/node_modules" 2>/dev/null && pwd -P)" || { echo "repro-check: dependency source cannot be resolved" >&2; return 1; }
  # An existing directory, junction, or symlink is not silently accepted: it
  # must resolve to the exact dependency source this run would have linked.
  # This also rejects dangling links, which otherwise look absent to `-e`.
  if [ -e "$worktree/node_modules" ] || [ -L "$worktree/node_modules" ]; then
    linked_real="$(cd "$worktree/node_modules" 2>/dev/null && pwd -P)" || {
      echo "repro-check: existing dependency target cannot be resolved" >&2
      return 1
    }
    if [ "$source_real" = "$linked_real" ]; then
      return 0
    fi
    echo "repro-check: existing dependency target resolves to '$linked_real', expected '$source_real'" >&2
    return 1
  fi
  case "$(uname -s 2>/dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*)
      local destination source
      destination="$(to_native_path "$worktree/node_modules")" || { echo "repro-check: cygpath is required to create a Windows dependency junction" >&2; return 1; }
      source="$(to_native_path "$root/node_modules")" || { echo "repro-check: cygpath is required to create a Windows dependency junction" >&2; return 1; }
      if ! command -v cmd >/dev/null 2>&1 || ! cmd //c mklink //J "$destination" "$source" >/dev/null 2>&1; then
        echo "repro-check: could not create dependency junction: $destination -> $source" >&2
        return 1
      fi
      ;;
    *)
      ln -s "$root/node_modules" "$worktree/node_modules" || { echo "repro-check: could not link dependency directory" >&2; return 1; }
      ;;
  esac
  linked_real="$(cd "$worktree/node_modules" 2>/dev/null && pwd -P)" || { echo "repro-check: dependency link cannot be resolved" >&2; return 1; }
  if [ "$source_real" != "$linked_real" ]; then
    echo "repro-check: dependency link resolved to '$linked_real', expected '$source_real'" >&2
    return 1
  fi
}

quoted_argv() { local arg; for arg in "$@"; do printf '%q ' "$arg"; done; }

do_run() {
  local base="" class="" check_id="" expect="" timeout_seconds=600 deps=link arg base_status head_status base_result head_result verdict exit_code=0
  local copies=()
  trace_dir=""; slug=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -ge 2 ] || usage; base="$2"; shift 2;;
      --class) [ "$#" -ge 2 ] || usage; class="$2"; shift 2;;
      --id) [ "$#" -ge 2 ] || usage; check_id="$2"; shift 2;;
      --expect) [ "$#" -ge 2 ] || usage; expect="$2"; shift 2;;
      --copy) [ "$#" -ge 2 ] || usage; copies+=("$2"); shift 2;;
      --deps) [ "$#" -ge 2 ] || usage; deps="$2"; shift 2;;
      --timeout) [ "$#" -ge 2 ] || usage; timeout_seconds="$2"; shift 2;;
      --slug) [ "$#" -ge 2 ] || usage; slug="$2"; shift 2;;
      --trace-dir) [ "$#" -ge 2 ] || usage; trace_dir="$2"; shift 2;;
      --) shift; break;;
      *) usage;;
    esac
  done
  [ "$#" -gt 0 ] || usage
  valid_slug "$slug" && valid_id "$check_id" || { echo "repro-check: invalid slug or check id" >&2; exit 2; }
  case "$base" in ''|-*) echo "repro-check: --base must name a commit" >&2; exit 2;; esac
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "repro-check: --base does not resolve to a commit" >&2; exit 2; }
  case "$class" in DISCRIMINATING|PRESERVING|NEW-SURFACE) ;; *) echo "repro-check: unknown class" >&2; exit 2;; esac
  case "$deps" in link|none) ;; *) echo "repro-check: --deps must be link or none" >&2; exit 2;; esac
  case "$timeout_seconds" in ''|*[!0-9]*|0) echo "repro-check: --timeout must be a positive integer" >&2; exit 2;; esac
  case "$class" in DISCRIMINATING|NEW-SURFACE) [ -n "$expect" ] || { echo "repro-check: --expect is required for $class" >&2; exit 2; };; esac
  has_bad_control "$expect" && { echo "repro-check: --expect cannot contain control bytes" >&2; exit 2; }
  trace_for
  require_contained "$trace_dir"
  require_contained "$trace_dir/repro"
  refuse_ancestor_symlink_escape "$trace_dir/repro"
  mkdir -p "$trace_dir/repro"
  require_contained "$trace_dir/repro"
  set_trace_root
  trace_path_safe "$trace_dir/repro" dir || { echo "repro-check: repro directory is missing or unsafe" >&2; exit 2; }
  worktree="$(mktemp -d "${TMPDIR:-/tmp}/issue-tracer-repro.XXXXXX")"
  cleanup() { git worktree remove --force "$worktree" >/dev/null 2>&1 || true; rm -rf "$worktree"; }
  trap cleanup EXIT HUP INT TERM
  git worktree add --detach "$worktree" "$base" >/dev/null 2>&1 || { echo "repro-check: could not create disposable worktree" >&2; exit 2; }
  worktree_real="$(cd "$worktree" 2>/dev/null && pwd -P)" || { echo "repro-check: disposable worktree cannot be resolved" >&2; exit 2; }
  for arg in ${copies[@]+"${copies[@]}"}; do copy_path "$arg"; done
  link_deps
  base_status="$(run_one "$worktree" "$trace_dir/repro/$check_id.base.log" "$timeout_seconds" "$@")"
  trace_path_safe "$trace_dir/repro/$check_id.base.log" file || { echo "repro-check: base log was not created safely" >&2; exit 2; }
  head_status="$(run_one "$root" "$trace_dir/repro/$check_id.head.log" "$timeout_seconds" "$@")"
  trace_path_safe "$trace_dir/repro/$check_id.head.log" file || { echo "repro-check: head log was not created safely" >&2; exit 2; }
  if [ "$base_status" -eq 124 ] || [ "$head_status" -eq 124 ]; then
    base_result="TIMEOUT"; head_result="TIMEOUT"; verdict="FAIL"; exit_code=6
  elif [ "$class" = DISCRIMINATING ]; then
    if [ "$base_status" -eq 0 ]; then base_result="VACUOUS"; verdict="VACUOUS"; exit_code=4
    elif trace_path_safe "$trace_dir/repro/$check_id.base.log" file && grep -Eq -- "$expect" "$trace_dir/repro/$check_id.base.log"; then
      base_result="RED"
      if [ "$head_status" -eq 0 ]; then head_result="GREEN"; verdict="PASS"; else head_result="FAIL"; verdict="FAIL"; exit_code=5; fi
    else base_result="ERROR"; verdict="ERROR"; exit_code=3; fi
  elif [ "$class" = PRESERVING ]; then
    base_result="$( [ "$base_status" -eq 0 ] && echo GREEN || echo FAIL )"
    head_result="$( [ "$head_status" -eq 0 ] && echo GREEN || echo FAIL )"
    if [ "$base_status" -eq 0 ] && [ "$head_status" -eq 0 ]; then verdict=PASS; else verdict=FAIL; exit_code=5; fi
  else
    if [ "$base_status" -ne 0 ] && trace_path_safe "$trace_dir/repro/$check_id.base.log" file && grep -Eq -- "$expect" "$trace_dir/repro/$check_id.base.log"; then
      base_result="ERROR"
      if [ "$head_status" -eq 0 ]; then head_result="GREEN"; verdict=PASS; else head_result="FAIL"; verdict=FAIL; exit_code=5; fi
    else base_result="FAIL"; head_result="$( [ "$head_status" -eq 0 ] && echo GREEN || echo FAIL )"; verdict=FAIL; exit_code=5; fi
  fi
  [ -n "${head_result:-}" ] || head_result="$( [ "$head_status" -eq 0 ] && echo GREEN || echo FAIL )"
  printf '### Check %s (%s)\n- base: %s exit=%s result=%s log=repro/%s.base.log\n- head: %s exit=%s result=%s log=repro/%s.head.log\n- argv: %s\n- expect: %s\n- verdict: %s\n' "$check_id" "$class" "$base" "$base_status" "$base_result" "$check_id" "$(git rev-parse HEAD)" "$head_status" "$head_result" "$check_id" "$(quoted_argv "$@")" "${expect:--}" "$verdict"
  exit "$exit_code"
}

acceptance_rows() {
  local file="$trace_dir/02-reproduction.md"
  trace_path_safe "$file" file || return 1
  awk -F '|' '
    # Acceptance tables deliberately accept LF and CRLF files. Remove only
    # the record terminator CR; an embedded CR remains a rejected control byte.
    { sub(/\r$/, "", $0) }
    /^## Acceptance checks$/ { in_table = 1; next }
    /^## / { if (in_table) in_table = 0 }
    !in_table { next }
    $0 == "| AC | class | check | argv | expect | pre-fix | post-fix | notes |" { header = 1; next }
    /^\|[-[:space:]|]+\|[[:space:]]*$/ { next }
    /^\|[[:space:]]*AC[0-9]+[[:space:]]*\|/ {
      if (NF != 10) { bad = 1; next }
      for (i = 2; i <= 9; i++) {
        cell = $i
        sub(/^[ \t]+/, "", cell)
        sub(/[ \t]+$/, "", cell)
        if (cell ~ /[[:cntrl:]]/) bad = 1
        cells[i] = cell
      }
      print cells[2] "\t" cells[3] "\t" cells[4] "\t" cells[5] "\t" cells[6]
      count += 1
      next
    }
    /^\|/ { bad = 1 }
    END { if (!header || bad || count == 0) exit 1 }
  ' "$file"
}

semantic_digest() {
  local canonical
  canonical="$(acceptance_rows)" || {
    echo "repro-check: acceptance table is missing or malformed" >&2
    return 1
  }
  printf '%s\n' "$canonical" | git hash-object --stdin
}

verify_manifest_semantics() {
  local manifest="$1" rows table_exec manifest_exec manifest_semantics
  trace_path_safe "$manifest" file || return 1
  validate_manifest "$manifest" "" allow-legacy-format-only
  rows="$(acceptance_rows)" || {
    echo "repro-check: acceptance table is missing or malformed" >&2
    return 1
  }
  table_exec="$(printf '%s\n' "$rows" | awk -F '\t' '$2 != "NON-EXECUTABLE" { print $3 "\t" $4 "\t" $5 }' | LC_ALL=C sort)"
  # A single acceptance check may freeze multiple files. The manifest keeps
  # one row per (path, check-id) pair for file-integrity replay, while the
  # acceptance table has one semantic row per check. Collapse the effective
  # manifest by check-id here, but reject a hand-edited manifest that gives one
  # check divergent argv/expect semantics on different paths.
  if ! manifest_semantics="$(awk -F '\t' '
    NR > 1 {
      pair = length($3) ":" $3 ":" $6
      latest_seq[pair] = $1
      latest_check[pair] = $6
      latest_argv[pair] = $7
      latest_expect[pair] = $8
    }
    END {
      for (pair in latest_check) {
        check = latest_check[pair]
        if (seen[check] && (check_argv[check] != latest_argv[pair] || check_expect[check] != latest_expect[pair])) {
          exit 1
        }
        seen[check] = 1
        check_argv[check] = latest_argv[pair]
        check_expect[check] = latest_expect[pair]
      }
      for (check in seen) print check "\t" check_argv[check] "\t" check_expect[check]
    }
  ' "$manifest")"; then
    echo "repro-check: checkpoint manifest has divergent semantics for one check" >&2
    return 1
  fi
  manifest_exec="$(printf '%s\n' "$manifest_semantics" | LC_ALL=C sort)"
  if [ "$table_exec" = "$manifest_exec" ]; then
    return 0
  fi
  echo "repro-check: acceptance table semantics do not match checkpoint manifest" >&2
  return 1
}

do_checkpoint() {
  local reason="-" check_id="" argv="" expect="" base="" path manifest seq kind mode blob row
  trace_dir=""; slug=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slug) [ "$#" -ge 2 ] || usage; slug="$2"; shift 2;; --trace-dir) [ "$#" -ge 2 ] || usage; trace_dir="$2"; shift 2;;
      --reason) [ "$#" -ge 2 ] || usage; reason="$2"; shift 2;; --id) [ "$#" -ge 2 ] || usage; check_id="$2"; shift 2;;
      --argv) [ "$#" -ge 2 ] || usage; argv="$2"; shift 2;; --expect) [ "$#" -ge 2 ] || usage; expect="$2"; shift 2;; --base) [ "$#" -ge 2 ] || usage; base="$2"; shift 2;;
      --) shift; break;; *) break;;
    esac
  done
  [ "$#" -gt 0 ] || usage
  valid_slug "$slug" && valid_id "$check_id" || { echo "repro-check: invalid slug or check id" >&2; exit 2; }
  case "$reason" in -) kind=CHECKPOINT;; CHECK_WRONG|AC_CHANGED_BY_USER) kind=AMEND;; *) echo "repro-check: invalid amendment reason (use CHECK_WRONG or AC_CHANGED_BY_USER)" >&2; exit 2;; esac
  case "$base" in ''|-*) echo "repro-check: --base must name a commit" >&2; exit 2;; esac
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "repro-check: --base does not resolve to a commit" >&2; exit 2; }
  if has_bad_control "$argv" || has_bad_control "$expect"; then
    echo "repro-check: manifest fields cannot contain control bytes" >&2
    exit 2
  fi
  trace_for
  require_contained "$trace_dir"
  require_contained "$trace_dir/repro"
  refuse_ancestor_symlink_escape "$trace_dir/repro"
  mkdir -p "$trace_dir/repro"
  require_contained "$trace_dir/repro"
  set_trace_root
  manifest="$trace_dir/repro/checkpoint.manifest"
  trace_path_safe "$trace_dir/repro" dir || { echo "repro-check: repro directory is missing or unsafe" >&2; exit 2; }
  trace_path_safe "$manifest" file || true
  refuse_nonregular_target "$manifest"
  if [ ! -f "$manifest" ]; then
    open_exclusive_target "$manifest" || { echo "repro-check: could not create checkpoint manifest safely" >&2; exit 2; }
    printf '# issue-tracer checkpoint manifest v1 rows=0\n' >&"$exclusive_fd"
    close_exclusive_target
  fi
  # validate_manifest owns the header check: it is strictly stronger than the
  # old `grep -Fx` (which matched the string on ANY line) and additionally
  # proves the recorded count, the seq run, and the field count.
  if [ "$kind" = AMEND ]; then
    # An amendment may be the next step in reconciling two same-path checks
    # that captured different bytes. Strict verification still rejects the
    # intermediate manifest; permit only this targeted append to proceed. The
    # legacy FORMAT_ONLY exception is validation-only: the reason parser above
    # still rejects a newly requested FORMAT_ONLY amendment.
    validate_manifest "$manifest" allow-conflicts allow-legacy-format-only
  else
    validate_manifest "$manifest"
  fi
  seq="$(awk 'END {print NR - 1}' "$manifest")"
  for path in "$@"; do
    is_inside_root "$path" || { echo "repro-check: checkpoint path must be repo-relative without ..: $path" >&2; exit 2; }
    has_bad_path "$path" && { echo "repro-check: checkpoint path cannot contain control bytes" >&2; exit 2; }
    repo_file_safe "$path" || { echo "repro-check: checkpoint path must be a regular in-repository file: $path" >&2; exit 2; }
    # Re-running the sanctioned `checkpoint` command on an already-frozen pair
    # would append a fresh CHECKPOINT row that last-writer-wins re-baselines a
    # weakened check to green in do_verify. Refuse it: superseding a frozen
    # pair requires an AMEND row that names a reason and stays in the file.
    # The manifest is re-read per path, so a pair frozen by an earlier
    # iteration of this same invocation is already recorded and also refused.
    if [ "$kind" = CHECKPOINT ] && manifest_has_pair "$manifest" "$path" "$check_id"; then
      echo "repro-check: $path ($check_id) is already frozen; supersede it with --reason CHECK_WRONG|AC_CHANGED_BY_USER" >&2
      exit 2
    fi
    if [ "$kind" = AMEND ] && ! manifest_has_pair "$manifest" "$path" "$check_id"; then
      echo "repro-check: $path ($check_id) cannot be amended before it is checkpointed" >&2
      exit 2
    fi
    # Always capture the current bytes for a new pair. Do not inherit the blob
    # from another check that happens to use the same path.
    blob="$(git hash-object "$root_real/$path")"
    mode="$(git ls-files -s -- "$path" | awk 'NR==1 {print $1}')"
    [ -n "$mode" ] || { [ -x "$root_real/$path" ] && mode=100755 || mode=100644; }
    seq=$((seq + 1))
    # $seq is post-increment, so it is also the new total row count that the
    # header must record. Row and header land together in one temp-file swap.
    row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$seq" "$kind" "$path" "$blob" "$mode" "$check_id" "$argv" "$expect" "$(git rev-parse "$base^{commit}")" "$reason")"
    append_manifest_row "$manifest" "$seq" "$row"
    echo "checkpoint: $kind $path"
  done
}

do_verify() {
  local manifest line path old check_id new changed=0
  trace_dir=""; slug=""
  while [ "$#" -gt 0 ]; do case "$1" in --slug) [ "$#" -ge 2 ] || usage; slug="$2"; shift 2;; --trace-dir) [ "$#" -ge 2 ] || usage; trace_dir="$2"; shift 2;; *) usage;; esac; done
  valid_slug "$slug" || { echo "repro-check: invalid slug" >&2; exit 2; }
  trace_for
  set_trace_root
  manifest="$trace_dir/repro/checkpoint.manifest"
  trace_path_safe "$manifest" file || { echo "repro-check: checkpoint manifest missing or invalid" >&2; exit 2; }
  # Iterating only the surviving rows would silently drop a frozen check when a
  # row is deleted OR the tail is truncated, so structure - header count, seq
  # run, field count - is proven before any row is replayed.
  validate_manifest "$manifest" "" allow-legacy-format-only
  while IFS=$'\t' read -r path old check_id; do
    if [ -z "$path" ] || ! is_inside_root "$path" || ! valid_id "$check_id"; then
      echo "repro-check: checkpoint manifest contains an unsafe path or invalid check id" >&2
      exit 2
    fi
    if ! repo_file_safe "$path"; then
      echo "CHANGED $path $old MISSING"; changed=1; continue
    fi
    new="$(git hash-object "$root_real/$path")"
    if [ "$old" = "$new" ]; then echo "OK $path ($check_id)"; else echo "CHANGED $path $old $new ($check_id)"; changed=1; fi
  done < <(awk -F '\t' '
    NR > 1 {
      pair = length($3) ":" $3 ":" $6
      latest_seq[pair] = $1
      latest_path[pair] = $3
      latest_blob[pair] = $4
      latest_check[pair] = $6
    }
    END {
      for (pair in latest_path) print latest_seq[pair] "\t" latest_path[pair] "\t" latest_blob[pair] "\t" latest_check[pair]
    }
  ' "$manifest" | sort -n -k1,1 | cut -f2-)
  [ "$changed" -eq 0 ] || exit 1
}

do_verify_semantics() {
  local manifest
  trace_dir=""; slug=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slug) [ "$#" -ge 2 ] || usage; slug="$2"; shift 2;;
      --trace-dir) [ "$#" -ge 2 ] || usage; trace_dir="$2"; shift 2;;
      *) usage;;
    esac
  done
  valid_slug "$slug" || { echo "repro-check: invalid slug" >&2; exit 2; }
  trace_for
  set_trace_root
  manifest="$trace_dir/repro/checkpoint.manifest"
  trace_path_safe "$manifest" file || { echo "repro-check: checkpoint manifest missing or invalid" >&2; exit 2; }
  verify_manifest_semantics "$manifest"
  echo "semantics: OK"
}

state_value() {
  local key="$1" state_file="$trace_dir/state.md"
  [ -n "$trace_dir" ] || state_file="$root/.agents/issue-traces/$slug/state.md"
  state_file="$(to_shell_path "$state_file")"
  trace_path_safe "$state_file" file || return 0
  awk -F ': ' -v key="$key" '$1 == key { print substr($0, length(key) + 3); exit }' "$state_file" 2>/dev/null || true
}

receipt_for() {
  local manifest="$1" digest semantics tree
  trace_path_safe "$manifest" file || { echo "repro-check: checkpoint manifest missing or unsafe" >&2; exit 2; }
  digest="$(git hash-object --no-filters "$manifest")"
  semantics="$(semantic_digest)" || exit 2
  tree="$(state_value checkpoint-tree-id)"
  is_sha1 "$tree" || { echo "repro-check: state.md has no valid checkpoint-tree-id" >&2; exit 2; }
  printf 'issue-tracer-checkpoint-v1 slug=%s manifest=%s semantics=%s tree=%s\n' "$slug" "$digest" "$semantics" "$tree"
}

do_anchor() {
  local manifest
  trace_dir=""; slug=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slug) [ "$#" -ge 2 ] || usage; slug="$2"; shift 2;;
      --trace-dir) [ "$#" -ge 2 ] || usage; trace_dir="$2"; shift 2;;
      *) usage;;
    esac
  done
  valid_slug "$slug" || { echo "repro-check: invalid slug" >&2; exit 2; }
  trace_for
  set_trace_root
  manifest="$trace_dir/repro/checkpoint.manifest"
  trace_path_safe "$manifest" file || { echo "repro-check: checkpoint manifest missing or invalid" >&2; exit 2; }
  # Verification diagnostics are intentionally kept on stderr by do_verify;
  # anchor's stdout is a machine-readable, single-line receipt for reviewers
  # to copy without filtering replay output.
  do_verify --slug "$slug" --trace-dir "$trace_dir" >/dev/null
  verify_manifest_semantics "$manifest" >/dev/null
  receipt_for "$manifest"
}

do_verify_anchor() {
  local receipt="" manifest expected_digest expected_semantics expected_tree parsed_slug parsed_manifest parsed_semantics parsed_tree
  trace_dir=""; slug=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slug) [ "$#" -ge 2 ] || usage; slug="$2"; shift 2;;
      --trace-dir) [ "$#" -ge 2 ] || usage; trace_dir="$2"; shift 2;;
      --receipt) [ "$#" -ge 2 ] || usage; receipt="$2"; shift 2;;
      *) usage;;
    esac
  done
  valid_slug "$slug" || { echo "repro-check: invalid slug" >&2; exit 2; }
  case "$receipt" in *$'\n'*|*$'\r'*|*$'\t'*) echo "repro-check: anchor receipt must be one single line" >&2; exit 2;; esac
  if ! printf '%s\n' "$receipt" | grep -Eq '^issue-tracer-checkpoint-v1 slug=[a-z0-9-]+ manifest=[0-9a-f]{40} semantics=[0-9a-f]{40} tree=[0-9a-f]{40}$'; then
    echo "repro-check: malformed anchor receipt" >&2
    exit 2
  fi
  parsed_slug="${receipt#*slug=}"; parsed_slug="${parsed_slug%% manifest=*}"
  parsed_manifest="${receipt#*manifest=}"; parsed_manifest="${parsed_manifest%% semantics=*}"
  parsed_semantics="${receipt#*semantics=}"; parsed_semantics="${parsed_semantics%% tree=*}"
  parsed_tree="${receipt##* tree=}"
  [ "$parsed_slug" = "$slug" ] || { echo "repro-check: anchor receipt slug does not match --slug" >&2; exit 2; }
  trace_for
  set_trace_root
  manifest="$trace_dir/repro/checkpoint.manifest"
  trace_path_safe "$manifest" file || { echo "repro-check: checkpoint manifest missing or invalid" >&2; exit 2; }
  do_verify --slug "$slug" --trace-dir "$trace_dir"
  trace_path_safe "$manifest" file || { echo "repro-check: checkpoint manifest became unsafe" >&2; exit 2; }
  verify_manifest_semantics "$manifest" >/dev/null
  expected_digest="$(git hash-object --no-filters "$manifest")"
  expected_semantics="$(semantic_digest)"
  expected_tree="$(state_value checkpoint-tree-id)"
  [ "$expected_digest" = "$parsed_manifest" ] || { echo "repro-check: anchor manifest digest does not match checkpoint manifest" >&2; exit 1; }
  [ "$expected_semantics" = "$parsed_semantics" ] || { echo "repro-check: anchor semantic digest does not match acceptance table" >&2; exit 1; }
  [ "$expected_tree" = "$parsed_tree" ] || { echo "repro-check: anchor tree does not match state.md checkpoint-tree-id" >&2; exit 1; }
}

command="${1:-}"; shift || true
case "$command" in
  run) do_run "$@";;
  checkpoint) do_checkpoint "$@";;
  verify-checkpoint) do_verify "$@";;
  verify-semantics) do_verify_semantics "$@";;
  anchor) do_anchor "$@";;
  verify-anchor) do_verify_anchor "$@";;
  *) usage;;
esac
