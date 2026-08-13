# shellcheck shell=bash
# Shared primitives for the autonomous-run engine (bin/fm-run.sh) and the quota
# reserve governor (bin/fm-run-governor.sh).
# Usage: . bin/fm-run-lib.sh
#
# This file owns run-root layout, manifest and run-state file identities, the
# frozen-manifest hash contract, the append-only receipt writer, lane resolution,
# and the glob/path primitives the gates are built from. It owns no policy: which
# tool, path, lane, or state transition is permitted is decided by bin/fm-run.sh,
# and the quota thresholds are decided by bin/fm-run-governor.sh.
#
# Run root layout, per run id, under the active FM_HOME:
#   data/runs/<run-id>/manifest.json      the run manifest; immutable once frozen
#   data/runs/<run-id>/manifest.sha256    hash written at freeze; drift detector
#   data/runs/<run-id>/run.state          key=value engine state and custody
#   data/runs/<run-id>/receipts.jsonl     append-only receipt log
#   data/runs/<run-id>/evidence/          the only write area a read-only run has
#   data/runs/<run-id>/checkpoints/       durable checkpoint snapshots
#
# `data/runs/` is namespaced away from `data/<task-id>/` so a run id can never
# collide with a crewmate task's brief or report directory.

FM_RUN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_RUN_DEFAULT_ROOT="$(cd "$FM_RUN_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_RUN_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_RUN_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# Consumed by bin/fm-run-governor.sh for its per-lane day baselines.
# shellcheck disable=SC2034
FM_RUN_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_RUN_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_RUN_ROOTS="$FM_RUN_DATA/runs"

# The schema version the engine writes and accepts. A manifest carrying any other
# version is refused rather than best-effort parsed, so a future schema cannot be
# silently reinterpreted by an older engine.
# shellcheck disable=SC2034 # Consumed by bin/fm-run.sh, which sources this file.
FM_RUN_SCHEMA_VERSION=afk-run.v1

fm_run_fail() {
  printf 'fm-run: %s\n' "$*" >&2
  return 1
}

fm_run_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  fm_run_fail 'jq is required for run manifests (install: brew install jq)'
}

# A run id is a filesystem- and receipt-safe slug. Rejecting anything else keeps
# a run id from escaping data/runs/ or from carrying a separator that would break
# the key=value run-state or the TSV-shaped receipt fields.
fm_run_validate_id() {  # <run-id>
  case "${1:-}" in
    ''|.|..) fm_run_fail "run id must be a non-empty slug: '${1:-}'" ;;
    *[!A-Za-z0-9._-]*) fm_run_fail "run id must be a privacy-safe slug: $1" ;;
    *) return 0 ;;
  esac
}

fm_run_root() {  # <run-id>
  printf '%s/%s\n' "$FM_RUN_ROOTS" "$1"
}

fm_run_manifest_path() { printf '%s/manifest.json\n' "$(fm_run_root "$1")"; }
fm_run_hash_path()     { printf '%s/manifest.sha256\n' "$(fm_run_root "$1")"; }
fm_run_state_path()    { printf '%s/run.state\n' "$(fm_run_root "$1")"; }
fm_run_receipts_path() { printf '%s/receipts.jsonl\n' "$(fm_run_root "$1")"; }

fm_run_exists() {  # <run-id>
  [ -f "$(fm_run_manifest_path "$1")" ]
}

fm_run_sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fm_run_fail 'shasum or sha256sum is required'
  fi
}

fm_run_now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# --- manifest reads ---------------------------------------------------------

# fm_run_manifest_get <run-id> <jq-filter>: print a raw (unquoted) scalar, or the
# array's members one per line. An absent key prints nothing and still succeeds,
# so a caller distinguishes "absent" from "malformed" by emptiness, not by exit
# code noise.
fm_run_manifest_get() {  # <run-id> <jq-filter>
  local manifest
  manifest=$(fm_run_manifest_path "$1")
  [ -f "$manifest" ] || return 1
  jq -r "
    ($2) as \$v
    | if \$v == null then empty
      elif (\$v | type) == \"array\" then \$v[]
      else \$v end
  " "$manifest" 2>/dev/null
}

fm_run_frozen() {  # <run-id>
  [ -f "$(fm_run_hash_path "$1")" ]
}

# fm_run_manifest_verify <run-id>: the frozen manifest still hashes to the value
# recorded at freeze. This is the whole no-self-expansion invariant: any edit to a
# frozen manifest, by the run or by anything else, changes the hash and every
# engine command that requires a verified manifest then refuses.
fm_run_manifest_verify() {  # <run-id>
  local manifest hash_file recorded actual
  manifest=$(fm_run_manifest_path "$1")
  hash_file=$(fm_run_hash_path "$1")
  [ -f "$manifest" ] || { fm_run_fail "run $1 has no manifest"; return 1; }
  [ -f "$hash_file" ] || { fm_run_fail "run $1 is not frozen"; return 1; }
  recorded=$(cat "$hash_file")
  actual=$(fm_run_sha256_file "$manifest") || return 1
  [ "$recorded" = "$actual" ] || {
    fm_run_fail "run $1 manifest changed after freeze (recorded $recorded, found $actual)"
    return 1
  }
  return 0
}

# --- run state (key=value) --------------------------------------------------

fm_run_state_get() {  # <run-id> <key>
  local file
  file=$(fm_run_state_path "$1")
  [ -f "$file" ] || return 0
  grep "^$2=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Rewrite-in-place so run.state stays a small current-truth record rather than an
# append log; the durable history of what happened lives in receipts.jsonl.
fm_run_state_set() {  # <run-id> <key> <value>
  local file tmp
  file=$(fm_run_state_path "$1")
  tmp="$file.tmp.$$"
  case "$3" in
    *$'\n'*) fm_run_fail "run state value must be one line: $2"; return 1 ;;
  esac
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ]; then
    grep -v "^$2=" "$file" > "$tmp" 2>/dev/null || : > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$2" "$3" >> "$tmp"
  LC_ALL=C sort "$tmp" -o "$tmp"
  mv -f "$tmp" "$file"
}

# --- run-scoped locking -----------------------------------------------------
#
# run.state is a multi-key record rewritten through a temp file, and `claim` has
# to read the owner and generation, decide, and write both as one step. Without a
# lock two concurrent claims each read generation 0, each decide they may take
# it, and both write - which is how two owners were observed on one run. Every
# state-changing command takes the run lock, so the read-decide-write is atomic.
#
# `mkdir` is the primitive: it is atomic on POSIX, needs no flock, and needs none
# of the steal-and-recover machinery a long-lived singleton lock carries. These
# critical sections are short and frequent, which is a different problem.
#
# The wait is BOUNDED. A lock that can spin forever turns a crashed command into
# a wedged run, so waiting past the timeout fails loudly and names the holder
# instead of hanging the engine.

FM_RUN_LOCK_TIMEOUT=${FM_RUN_LOCK_TIMEOUT:-30}

fm_run_lock_path() {  # <run-id>
  printf '%s/.run.lock\n' "$(fm_run_root "$1")"
}

fm_run_pid_alive() {  # <pid>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null
}

# Held locks are recorded as "<subshell-depth>:<path>". The depth matters: bash
# runs an inherited EXIT trap when a command substitution's subshell ends, and
# `$$` is identical there, so an unqualified release would hand back a lock the
# PARENT still holds and thinks it owns. Only the depth that took a lock releases
# it.
FM_RUN_HELD_LOCKS=()

fm_run_lock_acquire() {  # <lock-path>
  local lock=$1 holder waited=0 limit
  limit=$((FM_RUN_LOCK_TIMEOUT * 10))
  mkdir -p "$(dirname "$lock")"
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "${BASHPID:-$$}" > "$lock/pid" 2>/dev/null || true
      FM_RUN_HELD_LOCKS+=("${BASH_SUBSHELL:-0}:$lock")
      return 0
    fi
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    # A holder that no longer exists crashed inside its critical section. Break
    # its lock rather than inheriting its wedge; an empty pid file is a lock
    # being taken right now, so that one is waited out instead.
    if [ -n "$holder" ] && ! fm_run_pid_alive "$holder"; then
      rm -rf "$lock" 2>/dev/null || true
      continue
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt "$limit" ]; then
      fm_run_fail "timed out after ${FM_RUN_LOCK_TIMEOUT}s waiting for $lock (held by pid ${holder:-unknown})"
      return 1
    fi
    sleep 0.1
  done
}

fm_run_lock_release() {  # <lock-path>
  local lock=$1 holder remaining=() held
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ "$holder" = "${BASHPID:-$$}" ]; then
    rm -rf "$lock" 2>/dev/null || true
  fi
  for held in "${FM_RUN_HELD_LOCKS[@]:-}"; do
    [ -n "$held" ] || continue
    [ "${held#*:}" = "$lock" ] && continue
    remaining+=("$held")
  done
  FM_RUN_HELD_LOCKS=("${remaining[@]:-}")
}

fm_run_lock_release_all() {
  local held depth path remaining=()
  for held in "${FM_RUN_HELD_LOCKS[@]:-}"; do
    [ -n "$held" ] || continue
    depth=${held%%:*}
    path=${held#*:}
    if [ "$depth" = "${BASH_SUBSHELL:-0}" ]; then
      rm -rf "$path" 2>/dev/null || true
    else
      remaining+=("$held")
    fi
  done
  FM_RUN_HELD_LOCKS=("${remaining[@]:-}")
}

# --- receipts ---------------------------------------------------------------

# Every gate decision writes one receipt line, allowed and refused alike. The
# refusal record is the load-bearing half: "prove no write occurred" is only
# provable when the log also carries the attempts that were turned away.
#
# The line is built first and appended with ONE write. A single short write in
# append mode is atomic, so concurrent gates cannot interleave halves of two
# receipts - which matters because this log is what prove-no-write reads. Piping
# jq straight into the file gave no such guarantee, and a lock around every gate
# call would serialize work that is meant to run concurrently.
fm_run_receipt_append() {  # <run-id> <kind> <subject> <verdict> [note]
  local file line
  file=$(fm_run_receipts_path "$1")
  mkdir -p "$(dirname "$file")"
  line=$(jq -cn \
    --arg at "$(fm_run_now_iso)" \
    --arg run "$1" \
    --arg kind "$2" \
    --arg subject "$3" \
    --arg verdict "$4" \
    --arg note "${5:-}" \
    --arg pid "${BASHPID:-$$}" \
    '{at: $at, run: $run, kind: $kind, subject: $subject, verdict: $verdict, note: $note, pid: $pid}')
  printf '%s\n' "$line" >> "$file"
}

# --- lanes ------------------------------------------------------------------
#
# A lane binds a name to a data class and an explicit config root. The engine
# never derives a lane from a model name, a harness name, or a path prefix: an
# unregistered lane is a preflight blocker naming the exact missing registration.
#
# Built-in defaults cover only the two Claude lanes the captain has named. Every
# other lane comes from the local, gitignored config/run-lanes.conf, one record
# per line: "<lane> <personal|company> <config-root>". '#' starts a comment.

fm_run_lane_builtin() {  # <lane> -> "<class> <config-root>"
  case "$1" in
    company-claude) printf 'company %s/.claude\n' "$HOME" ;;
    personal-claude) printf 'personal %s/.claude-personal\n' "$HOME" ;;
    *) return 1 ;;
  esac
}

fm_run_lane_lookup() {  # <lane> -> "<class> <config-root>"
  local lane=$1 file="$FM_RUN_CONFIG/run-lanes.conf" name class root
  if [ -f "$file" ]; then
    while read -r name class root; do
      case "$name" in ''|'#'*) continue ;; esac
      [ "$name" = "$lane" ] || continue
      [ -n "$class" ] && [ -n "$root" ] || {
        fm_run_fail "config/run-lanes.conf record for $lane needs '<lane> <personal|company> <config-root>'"
        return 1
      }
      case "$class" in
        personal|company) ;;
        *) fm_run_fail "config/run-lanes.conf class for $lane must be personal or company, got $class"; return 1 ;;
      esac
      printf '%s %s\n' "$class" "$root"
      return 0
    done < "$file"
  fi
  fm_run_lane_builtin "$lane" && return 0
  fm_run_fail "lane $lane is not registered; add it to $file as '<lane> <personal|company> <config-root>'"
  return 1
}

# --- matching and path resolution -------------------------------------------

# Shell case globs, with '**' folded to '*'. A case-statement '*' already spans
# '/', so "**/tests/**" and "*/tests/*" select the same set here; folding keeps a
# manifest written in the design's doubled-star spelling behaving as written.
fm_run_glob_match() {  # <pattern> <string>
  local pattern=${1//\*\*/\*}
  # shellcheck disable=SC2254 # The pattern is the input; glob matching is the point.
  case "$2" in
    $pattern) return 0 ;;
    *) return 1 ;;
  esac
}

# Maximum symlink hops before a path is treated as a loop. The kernel's own limit
# is in this range, so a path needing more than this would not open anyway.
FM_RUN_SYMLINK_MAX_HOPS=${FM_RUN_SYMLINK_MAX_HOPS:-32}

# fm_run_symlink_leaf <path>: true when the final component exists AND is a
# symlink. A directory symlink is included: `cd -P` would resolve it silently,
# and a caller that needs to refuse a symlinked target must be told either way.
fm_run_symlink_leaf() {  # <path>
  [ -L "$1" ]
}

# Resolve to a physical path without requiring the leaf to exist.
#
# Ancestors resolve with `cd -P`, and the FINAL COMPONENT resolves too. That last
# part is the whole point: `cd -P` fails on a symlink to a file, so an earlier
# version appended the leaf unresolved and a symlink named inside the evidence
# directory pointed a write straight out of it. The leaf is followed here, with a
# hop limit, so the value every gate compares is the path the filesystem would
# actually open.
#
# Resolution alone is not race-safe: a leaf can be swapped between this call and
# the caller's write. Callers that must not lose that race refuse a symlinked
# leaf outright rather than resolving it (see bin/fm-run.sh's write gate).
fm_run_resolve_path() {  # <path>
  local path=$1 dir base tail='' resolved hops=0 target
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  while :; do
    # Follow an existing symlink leaf before treating the path as terminal, so
    # the comparison happens on the real target rather than on the link's name.
    if [ -L "$path" ] && [ "$hops" -lt "$FM_RUN_SYMLINK_MAX_HOPS" ]; then
      target=$(readlink "$path" 2>/dev/null) || target=
      if [ -n "$target" ]; then
        hops=$((hops + 1))
        case "$target" in
          /*) path=$target ;;
          *) path="${path%/*}/$target" ;;
        esac
        continue
      fi
    fi
    if [ -e "$path" ] && dir=$(cd -P "$path" 2>/dev/null && pwd); then
      resolved=$dir
      break
    fi
    base=${path##*/}
    dir=${path%/*}
    [ -n "$dir" ] || dir=/
    case "$base" in
      ''|.) : ;;
      ..) tail="../$tail" ;;
      *) tail="$base${tail:+/$tail}" ;;
    esac
    if [ "$dir" = "$path" ]; then
      resolved=/
      break
    fi
    path=$dir
  done
  if [ -n "$tail" ]; then
    case "$resolved" in
      /) printf '/%s\n' "${tail%/}" ;;
      *) printf '%s/%s\n' "$resolved" "${tail%/}" ;;
    esac
  else
    printf '%s\n' "$resolved"
  fi
}

# True when <path> is <root> or lives under it, compared on already-resolved
# physical paths so a prefix like /a/bc never counts as being inside /a/b.
fm_run_path_within() {  # <root> <path>
  local root=${1%/} path=$2
  [ -n "$root" ] || return 1
  [ "$path" = "$root" ] && return 0
  case "$path" in
    "$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}
