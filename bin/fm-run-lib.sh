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
fm_run_evidence_path() { printf '%s/evidence\n' "$(fm_run_root "$1")"; }

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

# --- receipts ---------------------------------------------------------------

# Every gate decision writes one receipt line, allowed and refused alike. The
# refusal record is the load-bearing half: "prove no write occurred" is only
# provable when the log also carries the attempts that were turned away.
fm_run_receipt_append() {  # <run-id> <kind> <subject> <verdict> [note]
  local file
  file=$(fm_run_receipts_path "$1")
  mkdir -p "$(dirname "$file")"
  jq -cn \
    --arg at "$(fm_run_now_iso)" \
    --arg run "$1" \
    --arg kind "$2" \
    --arg subject "$3" \
    --arg verdict "$4" \
    --arg note "${5:-}" \
    --arg pid "${BASHPID:-$$}" \
    '{at: $at, run: $run, kind: $kind, subject: $subject, verdict: $verdict, note: $note, pid: $pid}' \
    >> "$file"
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

# Resolve to a physical path without requiring the leaf to exist: the deepest
# existing ancestor is resolved with `cd -P`, so a symlinked parent cannot smuggle
# a write past an allowed-path check by pointing outside the run's write area.
fm_run_resolve_path() {  # <path>
  local path=$1 dir base tail='' resolved
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  while :; do
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
