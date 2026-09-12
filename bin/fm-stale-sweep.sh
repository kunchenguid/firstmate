#!/usr/bin/env bash
# fm-stale-sweep.sh - reclaim stale in_progress claims whose endpoint is dead.
#
# The Beads graph this home's .tasks.toml points at records claims, but bd 1.2.2
# never reclaims one on its own: a task whose worker endpoint died stays
# in_progress forever, so the in_progress count only grows and dispatch
# capacity silently shrinks. This sweep makes stale claims reclaim themselves.
#
# Usage:
#   fm-stale-sweep.sh [sweep] [--apply] [--apply-orphans] [--older-than <hours>]
#   fm-stale-sweep.sh check
#   fm-stale-sweep.sh arm
#   fm-stale-sweep.sh disarm
#   fm-stale-sweep.sh --help
#
# Default is a dry run: it prints a table (id, home, age, verdict, action,
# actor, provenance) and a summary line with the count of rows it would
# reclaim. `--apply` performs the reclaims. `--older-than <hours>` overrides
# the default 24-hour staleness threshold (measured from the row's updated_at
# - the last recorded graph activity - so an actively-touched claim is never
# stale however old its started_at is; the AGE column always shows the row's
# true age against the same clock, never threshold-shifted). No-home rows
# additionally carry the row's own ownership evidence in the ACTOR column
# (the tasks-axi claim marker's kind/repo) and the PROV column (the first 40
# characters of its provenance line), so a reviewer can rule on orphans
# without opening each bead. `--apply-orphans` (default off) reclaims a
# no-home row only when it is older than 48 hours, carries no claim marker,
# and has no landing URL in its description; without the flag orphan rows are
# listed and kept.
#
# Selection and reclaim, per row:
#   1. `bd list --all --json` reads the shared graph to a temp file (never
#      piped into a subshell) and selects in_progress rows older than the
#      threshold. FM_STALE_SWEEP_BD_TIMEOUT (default 120) bounds the read and
#      is cut down to the remaining budget in check mode.
#   2. The owning home is resolved from whichever registered home has
#      state/<id>.meta (this home plus the local routes in data/secondmates.md,
#      the current-ownership signal), falling back to the row's provenance line
#      ("... from secondmate home <id> (<home>)" in the description). A row no
#      local home owns is listed as no-home and kept: a remote route owns its
#      own liveness and no local verdict may reclaim it.
#   3. That home's current state is asked with
#      `FM_HOME=<home> timeout <FM_STALE_SWEEP_STATE_TIMEOUT, default 90>
#      bin/fm-crew-state.sh <id>`; in check mode the timeout is capped to the
#      remaining FM_STALE_SWEEP_BUDGET_SECS so one probe stays bounded.
#   4. Only POSITIVE death reclaims: `state: unknown` with source none and a
#      missing/dead endpoint detail (no metadata, worktree gone, backend target
#      gone, no backend target recorded), or source remote-endpoint with a
#      remote dead/missing verdict. Everything else - any live state, an
#      unproven pane verdict, an unreachable remote - is kept, because none of
#      those is proof the endpoint is dead.
#   5. `--apply` reclaims through the OWNING home's tasks-axi when that
#      home's backend reaches the swept graph (a home whose backlog lives
#      elsewhere cannot reopen a beads row, so the graph-owning sweep home
#      performs the reclaim instead, still naming the resolved owner as the
#      actor): under the owning home's per-task record lock - the same lock
#      every completion path (teardown's meta removal plus `tasks-axi done`,
#      and the captain-hold answer's resolution record plus close) holds
#      - it appends "reclaimed <date>: endpoint dead, previous claim by
#      <actor>" to the row's body, then reopens the row (back to Queued) only
#      after re-proving the row is still in flight and unheld, so a row that
#      finished between the sweep's read and its write is never resurrected.
#      A completion running concurrently holds the lock first: the sweep then
#      refuses the row outright instead of racing the close. A pending
#      backlog-close replay record counts the same way. The sweep never
#      touches a row whose endpoint is live and never removes a meta,
#      worktree, or pane; the dead endpoint's records are left exactly where
#      they are for stuck-crewmate recovery to inspect.
#
# `check` composes with the watcher's state-check contract: it runs the sweep
# dry at most once per FM_STALE_SWEEP_INTERVAL (default 86400, 0 disables the
# gate, otherwise 900..604800) inside FM_STALE_SWEEP_BUDGET_SECS (default 25,
# 1..3600, cut down to what FM_CHECK_TIMEOUT allows), stays silent when nothing
# is reclaimable, and prints one line when rows are reclaimable. A failed graph
# read reports one line on the same interval instead of every poll, and writes
# its probe record either way, so a killed probe is retried rather than
# suppressed.
#
# Register it as a daily check with bin/fm-check-register.sh via `arm`:
#   fm-stale-sweep.sh arm
# writes state/stale-sweep.check.sh (a single-link 0700 shim that execs this
# script's `check` mode with this home pinned) and binds its bytes through
# bin/fm-check-register.sh, so the existing watcher polls it on its normal
# FM_CHECK_INTERVAL cadence and turns its one line into a `check:` wake; no
# separate schedule is involved. `disarm` removes the shim, its trust binding,
# and the report record. docs/configuration.md "Stale-claim sweep" owns the
# operator-facing contract.
#
# The reclaim note keeps its parentheses because it lives in the row body;
# tasks-axi hold reasons cannot carry them, but no hold is recorded here.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CHECK_ID=stale-sweep
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.stale-sweep"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-stale-sweep-v1

usage() {
  cat <<'EOF'
Usage:
  fm-stale-sweep.sh [sweep] [--apply] [--apply-orphans] [--older-than <hours>]   sweep the shared Beads graph for dead-endpoint claims
  fm-stale-sweep.sh check    watcher check mode: silent unless rows are reclaimable
  fm-stale-sweep.sh arm      write and register state/stale-sweep.check.sh
  fm-stale-sweep.sh disarm   remove the check shim, its trust binding, and the record
  fm-stale-sweep.sh --help   print this help

Default is a dry run; --apply performs reclaims through each owning home's tasks-axi.
See docs/configuration.md "Stale-claim sweep" for thresholds and the check contract.
EOF
}

die_usage() {
  printf 'fm-stale-sweep: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# --- configuration -----------------------------------------------------------

OLDER_THAN_HOURS=24
STATE_TIMEOUT=${FM_STALE_SWEEP_STATE_TIMEOUT:-90}
case "$STATE_TIMEOUT" in ''|*[!0-9]*|0) STATE_TIMEOUT=90 ;; esac
BD_TIMEOUT=${FM_STALE_SWEEP_BD_TIMEOUT:-120}
case "$BD_TIMEOUT" in ''|*[!0-9]*|0) BD_TIMEOUT=120 ;; esac

INTERVAL=${FM_STALE_SWEEP_INTERVAL:-86400}
case "$INTERVAL" in
  ''|*[!0-9]*)
    printf 'fm-stale-sweep: FM_STALE_SWEEP_INTERVAL must be 0 or a whole number from 900 to 604800\n' >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 900 ] || [ "$INTERVAL" -gt 604800 ]; }; then
  printf 'fm-stale-sweep: FM_STALE_SWEEP_INTERVAL must be 0 or a whole number from 900 to 604800\n' >&2
  exit 2
fi

BUDGET_SECS=${FM_STALE_SWEEP_BUDGET_SECS:-25}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-stale-sweep: FM_STALE_SWEEP_BUDGET_SECS must be a whole number from 1 to 3600\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -gt 3600 ]; then
  printf 'fm-stale-sweep: FM_STALE_SWEEP_BUDGET_SECS must be a whole number from 1 to 3600\n' >&2
  exit 2
fi

# The watcher's per-check bound, read from this check's own environment exactly
# as bin/fm-tool-update-check.sh does: a probe the watcher kills prints nothing
# and writes no record, so the sweep budget must fit inside it. Cut rather than
# refuse, and let the sweep summary report the cut.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt $((CHECK_TIMEOUT - 3)) ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$((CHECK_TIMEOUT - 3))
  [ "$BUDGET_SECS" -ge 1 ] || BUDGET_SECS=1
fi

# The record epoch is overridable so a test can drive both the cadence gate
# and the staleness cutoff; the liveness verdicts themselves always come from
# fm-crew-state.sh and cannot be faked from here.
record_epoch_now() {
  case "${FM_STALE_SWEEP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_STALE_SWEEP_NOW" ;;
  esac
}

# --- graph read --------------------------------------------------------------

# Section-aware [beads] extraction from a .tasks.toml: comments stripped, only
# the keys inside the [beads] section, so a [markdown] path before or after it
# is never mistaken for the graph. Prints "BIN <value>" and "PATH <value>"
# lines.
fm_stale_beads_toml_entries() {  # <toml-file>
  LC_ALL=C awk '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    BEGIN { inbeads = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { inbeads = (line == "[beads]"); next }
      if (!inbeads) next
      if (line ~ /^binary[[:space:]]*=/) {
        sub(/^binary[[:space:]]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "BIN %s\n", line
      }
      if (line ~ /^path[[:space:]]*=/) {
        sub(/^path[[:space:]]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "PATH %s\n", line
      }
    }
  ' "$1"
}

# Resolve the shared Beads graph from this home's .tasks.toml. The beads
# backend's `path` and `binary` own the graph location and bd executable. A
# non-absolute `path` is resolved against this home exactly as
# fm_stale_home_beads_path resolves another home's, never against the process
# working directory: the armed check shim pins FM_HOME but not a working
# directory, so a CWD-relative read would let whatever directory the watcher
# happens to poll from decide which graph the sweep reads and --apply mutates.
FM_STALE_BD_BIN=
FM_STALE_BD_PATH=
fm_stale_read_beads_config() {
  local toml="$FM_HOME/.tasks.toml" parsed bin path home
  [ -f "$toml" ] || {
    printf 'fm-stale-sweep: no .tasks.toml at %s; a home without a backlog config has no graph to sweep\n' "$toml" >&2
    return 1
  }
  if [ "$(fm_tasks_axi_backend "$FM_HOME")" != beads ]; then
    printf 'fm-stale-sweep: this home'\''s backlog backend is not beads; the sweep reads the shared Beads graph .tasks.toml points at\n' >&2
    return 1
  fi
  parsed=$(fm_stale_beads_toml_entries "$toml") || return 1
  bin=$(printf '%s\n' "$parsed" | sed -n 's/^BIN //p' | head -1)
  path=$(printf '%s\n' "$parsed" | sed -n 's/^PATH //p' | head -1)
  FM_STALE_BD_BIN=${bin:-bd}
  FM_STALE_BD_PATH=$path
  [ -n "$FM_STALE_BD_PATH" ] || {
    printf 'fm-stale-sweep: .tasks.toml [beads] carries no graph path\n' >&2
    return 1
  }
  case "$FM_STALE_BD_PATH" in
    /*) ;;
    *)
      home=$(fm_capacity_resolve_dir "$FM_HOME" 2>/dev/null) || home=$FM_HOME
      FM_STALE_BD_PATH=$home/$FM_STALE_BD_PATH
      ;;
  esac
  [ -d "$FM_STALE_BD_PATH" ] || {
    printf 'fm-stale-sweep: beads graph path %s is not a directory\n' "$FM_STALE_BD_PATH" >&2
    return 1
  }
  # Canonicalized once so per-row owning-home graph comparisons are path-exact.
  FM_STALE_BD_PATH=$(fm_capacity_canonical_or_raw "$FM_STALE_BD_PATH")
  command -v "$FM_STALE_BD_BIN" >/dev/null 2>&1 || {
    printf 'fm-stale-sweep: beads binary %s not found on PATH\n' "$FM_STALE_BD_BIN" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-stale-sweep: jq is required to read the graph\n' >&2
    return 1
  }
  return 0
}

# --- owning-home resolution --------------------------------------------------

# Local secondmate routes from data/secondmates.md: "- <id> - ... (home: <path>; ...)".
# The literal "(" before "home: " is what excludes remote routes, and it is the
# only thing that does: bin/fm-secondmate-registry-lib.sh writes a remote record
# as one line whose suffix reads "(host: ...; root: ...; home: ...)", so its
# home field is preceded by "; ", never by "(". Remote homes are not local
# directories and their liveness is the remote transport's to own, so relaxing
# that anchor would admit them into this local-ownership scan.
fm_stale_registry_homes() {
  [ -f "$DATA/secondmates.md" ] || return 0
  sed -n 's/^- \([^ ]\{1,\}\) - .*(home: \([^);]*\);.*/\1\t\2/p' "$DATA/secondmates.md" 2>/dev/null || true
}

# The row's provenance line, whole. The description arrives @tsv-escaped, so
# the line's end reads as a literal backslash-n.
fm_stale_prov_line() {  # <escaped description>
  printf '%s\n' "$1" | sed -n 's/.*\(Provenance:[^\\]*\).*/\1/p' | head -1
}

# The provenance home named on a row's provenance line, if any. Only that line
# is read: any parenthesized path elsewhere in a description is prose, and
# accepting one would decide the row's fate rather than describe it, because a
# home that holds no state/<id>.meta answers "no metadata" and this sweep reads
# that as positive death evidence.
fm_stale_provenance_home() {  # <escaped description>
  local prov path
  prov=$(fm_stale_prov_line "$1")
  [ -n "$prov" ] || return 1
  path=$(printf '%s\n' "$prov" | sed -n 's/.*from secondmate home [^ ]* (\([^)]*\)).*/\1/p' | head -1)
  if [ -z "$path" ]; then
    path=$(printf '%s\n' "$prov" | sed -n 's/.*(\([^ ()][^()]*\/firstmate[^()]*\)).*/\1/p' | head -1)
  fi
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

# Resolve the owning home for <id> from <escaped description>: prefer the one
# registered home whose state/<id>.meta exists (current ownership), then the
# provenance home when it exists as a local directory. Prints the home path and
# sets FM_STALE_HOME_ACTOR; no output when unresolvable. The actor names the
# claim for the reclaim note: the registry id for meta rows, the secondmate id
# for provenance rows, "main home" for this home, and the directory basename
# when nothing better is known.
FM_STALE_HOME_ACTOR=
FM_STALE_RESOLVED_HOME=
fm_stale_resolve_home() {  # <id> <escaped description>
  local id=$1 desc=$2 rid home canon this_canon prov_home prov_rid
  local -a metas=()
  FM_STALE_HOME_ACTOR=
  FM_STALE_RESOLVED_HOME=
  this_canon=$(fm_capacity_resolve_dir "$FM_HOME" 2>/dev/null) || this_canon=$FM_HOME
  while IFS=$'\t' read -r rid home; do
    [ -n "$rid" ] && [ -n "$home" ] || continue
    canon=$(fm_capacity_resolve_dir "$home" 2>/dev/null) || continue
    if [ -f "$canon/state/$id.meta" ] || [ -L "$canon/state/$id.meta" ]; then
      metas+=("$canon"$'\t'"$rid")
    fi
  done <<EOF
$(printf 'main home\t%s\n' "$this_canon"; fm_stale_registry_homes)
EOF
  if [ "${#metas[@]}" -ge 1 ]; then
    # Several homes holding state/<id>.meta is a handoff seam; the first found
    # wins (this home is listed first) and the verdict below still governs.
    FM_STALE_RESOLVED_HOME=${metas[0]%%$'\t'*}
    FM_STALE_HOME_ACTOR=${metas[0]#*$'\t'}
    return 0
  fi
  if prov_home=$(fm_stale_provenance_home "$desc"); then
    # A firstmate home, not merely an existing directory. The provenance format
    # is prose no script in this repo writes, so the path is a guess until it
    # is proven; and an unproven guess is never harmless here, because
    # fm-crew-state.sh answers "no metadata" for any directory that holds no
    # state/<id>.meta and this sweep reads that as positive death evidence. A
    # directory with no state/ could therefore only ever turn an unowned row
    # into a reclaimable one, so it falls through to the no-home keep path.
    if [ -d "$prov_home" ] && [ -d "$prov_home/state" ]; then
      prov_rid=$(printf '%s\n' "$desc" | sed -n 's/.*from secondmate home \([^ ]*\) (.*/\1/p' | head -1)
      FM_STALE_HOME_ACTOR=${prov_rid:-$(basename "$prov_home")}
      FM_STALE_RESOLVED_HOME=$prov_home
      return 0
    fi
  fi
  return 1
}

# The [beads] graph path another home's .tasks.toml points at, canonicalized,
# or nothing when that home is not beads-backed.
fm_stale_home_beads_path() {  # <home>
  local home=$1 parsed path
  home=$(fm_capacity_resolve_dir "$home" 2>/dev/null) || return 1
  [ -f "$home/.tasks.toml" ] || return 1
  [ "$(fm_tasks_axi_backend "$home")" = beads ] || return 1
  parsed=$(fm_stale_beads_toml_entries "$home/.tasks.toml" 2>/dev/null) || return 1
  parsed=$(printf '%s\n' "$parsed" | sed -n 's/^PATH //p' | head -1)
  [ -n "$parsed" ] || return 1
  case "$parsed" in
    /*) ;;
    *) parsed=$home/$parsed ;;
  esac
  [ -d "$parsed" ] || return 1
  CDPATH='' cd -- "$parsed" 2>/dev/null && pwd -P
}

# --- verdict -----------------------------------------------------------------

# Classify one `fm-crew-state.sh` line. "dead" only on positive missing/dead
# endpoint evidence; everything else is live (a real current state) or
# unproven (never a reclaim).
fm_stale_verdict() {  # <crew-state-line>
  local line=$1 state source detail
  state=$(printf '%s\n' "$line" | sed -n 's/^state: \([^·]*\) ·.*/\1/p' | tr -d ' ')
  source=$(printf '%s\n' "$line" | sed -n 's/^state: [^·]*· source: \([^·]*\) ·.*/\1/p' | tr -d ' ')
  detail=$(printf '%s\n' "$line" | sed -n 's/^state: [^·]*· source: [^·]*· //p')
  case "$state" in
    working|parked|done|blocked|paused|failed)
      printf 'live'
      return 0
      ;;
  esac
  if [ "$state" = unknown ] && [ "$source" = none ]; then
    case "$detail" in
      "no metadata for "*|"worktree gone"*|"backend target gone"*|"no backend target recorded"*)
        printf 'dead'
        return 0
        ;;
    esac
  fi
  if [ "$state" = unknown ] && [ "$source" = remote-endpoint ]; then
    case "$detail" in
      "remote endpoint dead on "*|"remote endpoint missing on "*)
        printf 'dead'
        return 0
        ;;
    esac
  fi
  printf 'unproven'
}

fm_stale_ask_home() {  # <home> <id> <timeout>
  local home=$1 id=$2 timeout=$3 out
  out=$(FM_HOME="$home" timeout "$timeout" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) \
    || out='state: unknown · source: none · crew-state unreadable'
  printf '%s\n' "$out" | tail -1
}

# --- reclaim -----------------------------------------------------------------

# Run one tasks-axi command from the owning home's backlog root, with --file
# only for the markdown backend (mirroring fm_backlog_row_show's backend
# awareness in bin/fm-backlog-transition-lib.sh).
fm_stale_axi() {  # <home> <verb> <id> [flag...]
  local home=$1 verb=$2 id=$3
  shift 3
  home=$(fm_capacity_resolve_dir "$home") || return 1
  if [ "$(fm_tasks_axi_backend "$home")" = markdown ]; then
    (cd "$home" 2>/dev/null && tasks-axi "$verb" "$id" --file "$home/data/backlog.md" "$@")
  else
    (cd "$home" 2>/dev/null && tasks-axi "$verb" "$id" "$@")
  fi
}

# Decode the `body:` field tasks-axi show prints: "-" or empty for none, a
# JSON-encoded string when it contains newlines or quotes, plain otherwise.
fm_stale_decode_body() {  # <body-field-value>
  local shown=$1
  case "$shown" in
    ''|-|'"-"') return 0 ;;
    '"'*)
      printf '%s' "$shown" | jq -r . 2>/dev/null
      ;;
    *)
      printf '%s' "$shown"
      ;;
  esac
}

# Reclaim one dead-endpoint row through its owning home. The whole reclaim
# runs under the owning home's per-task record lock (state/.meta-<id>.lock) -
# the lock every completion path (teardown's meta removal plus `tasks-axi
# done`, and the captain-hold answer's resolution record plus close) holds
# across its own steps - so a completion either lands before the
# sweep's proof and the row reads done, or waits until the reopen has landed;
# the two can never interleave into a resurrected finished row. When that lock
# is already held, a completion is running right now and the row is refused
# rather than reopened. A pending backlog-close replay record means a recorded
# completion is still owed, so the row is refused too. Prints the failure
# reason and returns non-zero on any refusal.
fm_stale_reclaim() {  # <mutation-home> <record-home> <id> <actor>
  local home=$1 record_home=$2 id=$3 actor=$4 lock rc
  home=$(fm_capacity_resolve_dir "$home") || {
    printf 'mutation home unresolvable'
    return 1
  }
  # The record home's state dir may not exist (a provenance-only owner): then
  # no firstmate actor can be completing there and there is no lock to share.
  if [ -d "$record_home/state" ]; then
    lock=$(fm_meta_lock_path "$record_home/state/$id.meta") || {
      printf 'record lock unresolvable'
      return 1
    }
    if [ -e "$record_home/state/$id.backlog-close" ]; then
      printf 'completion replay pending'
      return 1
    fi
    if ! fm_lock_try_acquire "$lock"; then
      printf 'record locked by another actor'
      return 1
    fi
  else
    lock=
  fi
  rc=0
  fm_stale_reclaim_locked "$home" "$id" "$actor" || rc=$?
  [ -z "$lock" ] || fm_lock_release "$lock"
  return "$rc"
}

fm_stale_reclaim_locked() {  # <home> <id> <actor>
  local home=$1 id=$2 actor=$3 out state held blocked body note new_body date
  out=$(fm_stale_axi "$home" show "$id") || {
    printf 'row unreadable'
    return 1
  }
  state=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)
  held=$(printf '%s\n' "$out" | sed -n 's/^  held: *//p' | head -1)
  blocked=$(printf '%s\n' "$out" | sed -n 's/^  blocked: *//p' | head -1)
  if [ "$state" != in_flight ] || [ "${held:-no}" != no ] || [ "${blocked:-no}" != no ]; then
    printf 'row changed under the sweep (state=%s held=%s blocked=%s)' "$state" "${held:-?}" "${blocked:-?}"
    return 1
  fi
  date=$(date +%F)
  note="reclaimed $date: endpoint dead, previous claim by $actor"
  body=$(fm_stale_axi "$home" show "$id" --full | sed -n 's/^  body: //p' | head -1)
  if [ -n "$body" ] && ! body=$(fm_stale_decode_body "$body"); then
    printf 'body undecodable'
    return 1
  fi
  case "$body" in
    *"$note"*) ;;
    *)
      if [ -z "$body" ]; then
        new_body=$note
      else
        new_body=$(printf '%s\n\n%s' "$body" "$note")
      fi
      fm_stale_axi "$home" update "$id" --body "$new_body" >/dev/null || {
        printf 'note append failed'
        return 1
      }
      ;;
  esac
  # Second proof, immediately before the reopen: a row that finished or got
  # held between the first read and this write is skipped rather than
  # reopened, and the just-appended note is undone when the pre-note body can
  # be restored (tasks-axi cannot clear a body, so a bodyless row keeps it).
  out=$(fm_stale_axi "$home" show "$id") || {
    printf 'row unreadable'
    return 1
  }
  state=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)
  held=$(printf '%s\n' "$out" | sed -n 's/^  held: *//p' | head -1)
  blocked=$(printf '%s\n' "$out" | sed -n 's/^  blocked: *//p' | head -1)
  if [ "$state" != in_flight ] || [ "${held:-no}" != no ] || [ "${blocked:-no}" != no ]; then
    if [ -n "$body" ]; then
      fm_stale_axi "$home" update "$id" --body "$body" >/dev/null 2>&1 || true
    fi
    printf 'row changed under the sweep (state=%s held=%s blocked=%s)' "$state" "${held:-?}" "${blocked:-?}"
    return 1
  fi
  fm_stale_axi "$home" reopen "$id" >/dev/null || {
    printf 'reopen failed'
    return 1
  }
  return 0
}

# --- the sweep ---------------------------------------------------------------

# Reads the graph, classifies candidates, prints the table. Sets the counters
# used by the summary line. APPLY=1 performs reclaims; BUDGET>0 stops
# considering new candidates once the elapsed time exceeds it.
FM_STALE_COUNT_DEAD=0
FM_STALE_COUNT_LIVE=0
FM_STALE_COUNT_UNPROVEN=0
FM_STALE_COUNT_NOHOME=0
FM_STALE_RECLAIMED=0
FM_STALE_APPLY_FAILED=0
FM_STALE_UNCONSIDERED=0
FM_STALE_ORPHANS_RECLAIMED=0
FM_STALE_ORPHANS_ELIGIBLE=0

fm_stale_sweep() {  # <apply 0|1> <budget-secs 0-unbounded> <cutoff-epoch>
  local apply=$1 budget=$2 cutoff=$3 tmp rows start now id age_h desc ask_timeout remaining bd_timeout
  bd_timeout=$BD_TIMEOUT
  start=$(date +%s)
  if [ "$budget" -gt 0 ] && [ "$BD_TIMEOUT" -gt "$budget" ]; then
    bd_timeout=$budget
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-stale-sweep.XXXXXX") || return 1
  if ! BEADS_DIR="$FM_STALE_BD_PATH" timeout "$bd_timeout" "$FM_STALE_BD_BIN" list --all --json > "$tmp" 2>/dev/null; then
    printf 'fm-stale-sweep: bd list failed on %s\n' "$FM_STALE_BD_PATH" >&2
    rm -f -- "$tmp"
    return 1
  fi
  if ! rows=$(jq -r --argjson cutoff "$cutoff" --argjson now "$(record_epoch_now)" '
    .[] | select(.status == "in_progress") | select(.updated_at)
        | (.updated_at | fromdateiso8601?) as $epoch
        | select($epoch != null) | select($epoch < $cutoff)
        | [(.id // ""), (((($now - $epoch) / 3600) | floor) | tostring), (.description // "")]
        | @tsv' "$tmp" 2>/dev/null); then
    rm -f -- "$tmp"
    printf 'fm-stale-sweep: graph read failed on %s\n' "$FM_STALE_BD_PATH" >&2
    return 1
  fi
  rm -f -- "$tmp"
  [ -n "$rows" ] || return 0
  printf '%-42s %-18s %-7s %-9s %-24s %-13s %s\n' ID HOME AGE VERDICT ACTION ACTOR PROV
  while IFS=$'\t' read -r id age_h desc; do
    [ -n "$id" ] || continue
    ask_timeout=$STATE_TIMEOUT
    if [ "$budget" -gt 0 ]; then
      now=$(date +%s)
      if [ $((now - start)) -ge "$budget" ]; then
        FM_STALE_UNCONSIDERED=$((FM_STALE_UNCONSIDERED + 1))
        continue
      fi
      remaining=$((start + budget - now))
      [ "$remaining" -lt "$ask_timeout" ] && ask_timeout=$remaining
    fi
    fm_stale_consider "$apply" "$id" "$age_h" "$desc" "$ask_timeout"
  done <<EOF
$rows
EOF
  return 0
}

fm_stale_consider() {  # <apply> <id> <age-hours> <escaped description> <ask-timeout>
  local apply=$1 id=$2 age_h=$3 desc=$4 ask_timeout=$5 home actor state_line verdict action reason
  local mutation_home row_actor="" row_prov=""
  if fm_stale_resolve_home "$id" "$desc"; then
    home=$FM_STALE_RESOLVED_HOME
    actor=$FM_STALE_HOME_ACTOR
    [ -n "$actor" ] || actor=$(basename "$home")
    state_line=$(fm_stale_ask_home "$home" "$id" "$ask_timeout")
    verdict=$(fm_stale_verdict "$state_line")
  else
    home=-
    actor=-
    verdict=no-home
    # Orphan rows carry their own ownership evidence for the reviewer: the
    # claim marker tasks-axi embedded and the provenance line, if any.
    row_actor=$(fm_stale_row_actor "$desc")
    row_prov=$(fm_stale_row_prov "$desc")
  fi
  case "$verdict" in
    dead) FM_STALE_COUNT_DEAD=$((FM_STALE_COUNT_DEAD + 1)) ;;
    live) FM_STALE_COUNT_LIVE=$((FM_STALE_COUNT_LIVE + 1)) ;;
    unproven) FM_STALE_COUNT_UNPROVEN=$((FM_STALE_COUNT_UNPROVEN + 1)) ;;
    no-home) FM_STALE_COUNT_NOHOME=$((FM_STALE_COUNT_NOHOME + 1)) ;;
  esac
  action=keep
  if [ "$verdict" = dead ]; then
    if [ "$apply" = 1 ]; then
      # The mutation runs through the OWNING home when its backend reaches the
      # swept graph; a home whose backlog lives elsewhere (a markdown home a
      # row was imported from) cannot reopen a beads row, so the graph-ownning
      # sweep home performs the reclaim instead. The actor still names the
      # resolved owner.
      mutation_home=$home
      if [ "$(fm_stale_home_beads_path "$home" 2>/dev/null || true)" != "$FM_STALE_BD_PATH" ]; then
        mutation_home=$FM_HOME
      fi
      if reason=$(fm_stale_reclaim "$mutation_home" "$home" "$id" "$actor"); then
        action=reclaimed
        FM_STALE_RECLAIMED=$((FM_STALE_RECLAIMED + 1))
      else
        action="reclaim failed: $reason"
        FM_STALE_APPLY_FAILED=$((FM_STALE_APPLY_FAILED + 1))
      fi
    else
      action='would reclaim'
    fi
  elif [ "$verdict" = no-home ] && [ "$APPLY_ORPHANS" = 1 ] \
       && fm_stale_orphan_eligible "$age_h" "$desc"; then
    # An orphan row has no home to ask, so its own recorded evidence decides:
    # 48h+ of age, no claim marker, and no landing URL. The graph-owning sweep
    # home performs the reclaim; the note names the unknown claimant.
    if [ "$apply" = 1 ]; then
      if reason=$(fm_stale_reclaim "$FM_HOME" "$FM_HOME" "$id" unknown); then
        action='reclaimed (orphan)'
        FM_STALE_RECLAIMED=$((FM_STALE_RECLAIMED + 1))
        FM_STALE_ORPHANS_RECLAIMED=$((FM_STALE_ORPHANS_RECLAIMED + 1))
      else
        action="reclaim failed: $reason"
        FM_STALE_APPLY_FAILED=$((FM_STALE_APPLY_FAILED + 1))
      fi
    else
      action='would reclaim (orphan)'
      FM_STALE_ORPHANS_ELIGIBLE=$((FM_STALE_ORPHANS_ELIGIBLE + 1))
    fi
  fi
  printf '%-42s %-18s %-7s %-9s %-24s %-13s %s\n' "$id" "$(fm_stale_home_label "$home" "$actor")" "${age_h}h" "$verdict" "$action" "${row_actor:--}" "${row_prov:--}"
}

# One readable home label for the table: the actor id when known, else the
# home basename, with "-" for unresolvable rows.
fm_stale_home_label() {  # <home> <actor>
  local home=$1 actor=$2
  if [ "$home" = - ] || [ -z "$home" ]; then
    printf '%s' '-'
    return 0
  fi
  if [ -n "$actor" ] && [ "$actor" != "-" ]; then
    printf '%s' "$actor"
    return 0
  fi
  printf '%s' "$(basename "$home")"
}

# Does the row carry a claim marker at all, decodable or not? A truncated or
# over-captured payload still records that something claimed this row, so the
# orphan guard keys on this and only the ACTOR column keys on the decode.
fm_stale_row_has_marker() {  # <escaped description>
  case "$1" in
    *'tasks-axi:beads/v1:'*) return 0 ;;
  esac
  return 1
}

# The row's own recorded claim actor: the tasks-axi marker embedded in its
# description decodes to {"kind":...,"repo":...}. Empty when the row was
# created outside tasks-axi and nothing else recorded who claimed it, and also
# when a marker IS present but its payload will not decode - which is why the
# orphan guard above reads presence rather than calling this.
fm_stale_row_actor() {  # <escaped description>
  local marker
  marker=$(printf '%s\n' "$1" | sed -n 's/.*tasks-axi:beads\/v1:\([A-Za-z0-9+/=]*\).*/\1/p' | head -1)
  [ -n "$marker" ] || return 0
  printf '%s\n' "$marker" | jq -Rr '
    . + ((4 - (length % 4)) % 4) * "="
    | @base64d
    | (try fromjson catch null)
    | if . == null then empty
      else ((.kind // "?") + "/" + (.repo // "-"))
      end' 2>/dev/null
}

# The first 40 characters of the row's provenance line, if any, for reviewers
# ruling on orphan rows without opening each bead.
fm_stale_row_prov() {  # <escaped description>
  fm_stale_prov_line "$1" | cut -c1-40
}

# A no-home row is orphan-reclaimable only when ALL THREE guards pass: older
# than 48 hours against the sweep clock, no claim marker, and no landing URL in
# its description (a PR or merge link means the work may have landed even though
# no home claims the row). The marker guard reads presence, not decodability: a
# marker whose payload will not decode still records a claim, and only the ACTOR
# column has to give up on it.
FM_STALE_ORPHAN_MIN_AGE_HOURS=48
fm_stale_orphan_eligible() {  # <age-hours> <escaped description>
  local age_h=$1 desc=$2
  case "$age_h" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age_h" -ge "$FM_STALE_ORPHAN_MIN_AGE_HOURS" ] || return 1
  ! fm_stale_row_has_marker "$desc" || return 1
  printf '%s\n' "$desc" | grep -q 'https\{0,1\}://' && return 1
  return 0
}

fm_stale_budget_cut_note() {
  [ -n "$BUDGET_CUT_FROM" ] || return 0
  printf 'note: FM_STALE_SWEEP_BUDGET_SECS %s cut to %s to fit FM_CHECK_TIMEOUT\n' "$BUDGET_CUT_FROM" "$BUDGET_SECS"
}

fm_stale_summary() {  # <apply 0|1>
  local apply=$1 reclaim_word reclaim_count
  reclaim_word='would reclaim'
  reclaim_count=$((FM_STALE_COUNT_DEAD + FM_STALE_ORPHANS_ELIGIBLE))
  if [ "$apply" = 1 ]; then
    reclaim_word=reclaimed
    reclaim_count=$FM_STALE_RECLAIMED
  fi
  printf '%d stale candidates: %d dead, %d live, %d unproven, %d no-home; %s %s\n' \
    "$((FM_STALE_COUNT_DEAD + FM_STALE_COUNT_LIVE + FM_STALE_COUNT_UNPROVEN + FM_STALE_COUNT_NOHOME + FM_STALE_UNCONSIDERED))" \
    "$FM_STALE_COUNT_DEAD" "$FM_STALE_COUNT_LIVE" "$FM_STALE_COUNT_UNPROVEN" "$FM_STALE_COUNT_NOHOME" \
    "$reclaim_word" "$reclaim_count"
  if [ "$FM_STALE_UNCONSIDERED" -gt 0 ]; then
    printf 'budget stopped the sweep with %d candidates unconsidered; raise FM_STALE_SWEEP_BUDGET_SECS or run without the check gate\n' "$FM_STALE_UNCONSIDERED"
  fi
  if [ -n "$BUDGET_CUT_FROM" ]; then
    fm_stale_budget_cut_note
  fi
}

# --- check / arm / disarm ----------------------------------------------------

fm_stale_gate_open() {
  local last
  [ "$INTERVAL" -eq 0 ] && return 0
  [ -f "$RECORD" ] || return 0
  last=$(sed -n 's/^epoch //p' "$RECORD" | head -1)
  case "$last" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ $(( $(record_epoch_now) - last )) -ge "$INTERVAL" ]
}

fm_stale_write_record() {  # <now-epoch>
  printf '%s\nepoch %s\n' "$RECORD_SCHEMA" "$1" > "$RECORD" 2>/dev/null || true
}

action_check() {
  local now cutoff out count
  fm_stale_gate_open || return 0
  now=$(record_epoch_now)
  if ! fm_stale_read_beads_config; then
    fm_stale_write_record "$now"
    printf 'fm-stale-sweep: graph config unreadable\n'
    return 0
  fi
  fm_stale_budget_cut_note
  cutoff=$((now - OLDER_THAN_HOURS * 3600))
  if ! fm_stale_sweep 0 "$BUDGET_SECS" "$cutoff" >/dev/null; then
    # A failed graph read is reported once per interval rather than every
    # poll, and the probe record is still written, so the next poll stays
    # quiet while the one after retries.
    fm_stale_write_record "$now"
    printf 'fm-stale-sweep: graph read failed\n'
    return 0
  fi
  if [ "$FM_STALE_UNCONSIDERED" -gt 0 ]; then
    printf 'budget stopped the sweep with %d candidates unconsidered; raise FM_STALE_SWEEP_BUDGET_SECS or run without the check gate\n' "$FM_STALE_UNCONSIDERED"
  fi
  count=$FM_STALE_COUNT_DEAD
  fm_stale_write_record "$now"
  [ "$count" -gt 0 ] || return 0
  printf 'stale-sweep: %d dead-endpoint in_progress rows reclaimable - run bin/fm-stale-sweep.sh --apply\n' "$count"
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-stale-sweep.sh - stale-claim reclaim poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-stale-sweep.sh") check"
}

# Write the shim the way this repo writes its other trusted check shim: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-stale-sweep-check.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

action_arm() {
  local want home
  fm_stale_read_beads_config || return 1
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-stale-sweep: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  if ! shim_write "$want"; then
    printf 'fm-stale-sweep: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-stale-sweep: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

# --- entry -------------------------------------------------------------------

ACTION=sweep
APPLY=0
APPLY_ORPHANS=0
while [ $# -gt 0 ]; do
  case "$1" in
    sweep|check|arm|disarm)
      [ "$ACTION" = sweep ] || die_usage "one action only"
      ACTION=$1
      ;;
    --apply) APPLY=1 ;;
    --apply-orphans) APPLY_ORPHANS=1 ;;
    --older-than)
      [ $# -ge 2 ] || die_usage "--older-than needs <hours>"
      case "$2" in ''|*[!0-9]*|0) die_usage "--older-than needs a positive whole number of hours" ;; esac
      OLDER_THAN_HOURS=$2
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

case "$ACTION" in
  sweep)
    fm_stale_read_beads_config || exit 1
    cutoff=$(( $(record_epoch_now) - OLDER_THAN_HOURS * 3600 ))
    fm_stale_sweep "$APPLY" 0 "$cutoff" || exit 1
    fm_stale_summary "$APPLY"
    [ "$FM_STALE_APPLY_FAILED" -eq 0 ] || exit 1
    ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
esac
