# shellcheck shell=bash
# Shared backlog backend selection (tasks-axi, beads, or manual) and tasks-axi
# compatibility probe for bootstrap, teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations; `config/backlog-backend=beads` uses the federated task store
# instead. Validated secondmate handoffs always use `tasks-axi mv` when on the
# tasks-axi backend. Absent or invalid values keep the default tasks-axi backend
# path, falling back to manual mutation when the tool is not compatible.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.

FM_TASKS_AXI_MIN=0.2.4

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  [ "$(fm_backlog_backend_value "$config_dir")" = beads ] && return 1
  fm_tasks_axi_compatible
}

fm_beads_backend_available() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = beads ] || return 1
  command -v task >/dev/null 2>&1 || return 1
  task list --limit 1 >/dev/null 2>&1
}

# --- Beads store provisioning and Dolt sync (config/backlog-backend=beads only) ---
#
# Every function below is inert on the tasks-axi and manual backends: callers
# gate on fm_backlog_backend_value before invoking them, and none of them runs
# unless a `task` CLI is on PATH. The beads store stays the single write
# authority throughout; provisioning only creates a store where none answers,
# and sync only moves that store's own commits to and from a Dolt remote the
# operator configured, exactly the availability-not-authority doctrine
# bin/fm-beads-resilience-lib.sh states for the mirror and write queue.
#
# STORE RESOLUTION IS THE CLI'S JOB, NOT FIRSTMATE'S. The `task` wrapper pins
# BEADS_DIR for the whole federation, so firstmate never derives, guesses, or
# hardcodes a store path; it asks the CLI whether the store answers and reports
# what it says. That is why a home with no local .beads/ directory is not
# evidence of a missing store: the shared store the wrapper points at can live
# anywhere, including a Dolt sql-server this host merely connects to.

# fm_beads_store_reachable - true when the beads store answers a cheap read.
# This, not the presence of a .beads/ directory, is the store-usable test.
#
# The optional bound is for callers running under a deadline. A Dolt sql-server
# that accepts the connection and then never answers makes this read hang, so a
# caller whose whole budget this probe precedes must pass a bound or the budget
# is not the bound it claims to be. A store that does not answer within it is a
# store that does not answer, which is exactly what an unbounded false means.
# shellcheck disable=SC2120 # The bound comes from callers outside this library.
fm_beads_store_reachable() { # [bound seconds]
  command -v task >/dev/null 2>&1 || return 1
  if [ -n "${1:-}" ]; then
    # A caller that asked for a bound gets a bound or gets nothing: without
    # fm_run_timed the read cannot be held to it, and answering unbounded would
    # hand back the stall the bound exists to prevent.
    fm_beads_require_timeout_lib || return 1
    fm_run_timed "$1" task list --limit 1 >/dev/null 2>&1
    return
  fi
  task list --limit 1 >/dev/null 2>&1
}

# fm_beads_bootstrap_store - provision a store non-destructively with
# `task bootstrap`, the verb whose own help documents that it never deletes
# existing issues (unlike the forbidden `bd init --force`).
#
# REFUSES WHEN THE STORE ALREADY ANSWERS. This guard is the whole safety
# margin, because bootstrap's own auto-detection reads the .beads/ directory
# and does NOT see a store served by a Dolt sql-server: against a healthy
# server-mode store it reports `"action":"init","has_existing":false` and would
# create a fresh empty database beside the live one. Firstmate therefore
# decides reachability itself and only ever bootstraps a store that is
# genuinely not answering, so a working home can never be bootstrapped over.
fm_beads_bootstrap_store() {
  command -v task >/dev/null 2>&1 || return 1
  if fm_beads_store_reachable; then
    printf 'BEADS_STORE: store already reachable; bootstrap refused (never bootstrap over a live store)\n'
    return 1
  fi
  BD_NON_INTERACTIVE=1 task bootstrap --yes >/dev/null 2>&1 || return 1
  fm_beads_store_reachable
}

# fm_beads_sync_remote_state - what the machine-readable Dolt remote listing
# says, as exactly one of:
#   configured        at least one remote exists
#   none              the listing answered and is empty (`[]`)
#   unreadable: <why> the listing could not be read at all
#
# "No remote is configured" and "this host cannot tell whether one is
# configured" are opposite facts and must never collapse into one another. An
# empty listing is the intended steady state today and is reported as a benign
# no-op, so folding a missing jq or a failing `task dolt remote list` into it
# would turn a home that silently stopped syncing into a line the diagnostics
# skill documents as expected. Every unreadable case therefore keeps its own
# reason, and no caller ever guesses a destination from it.
#
# The optional bound exists for the same reason fm_beads_store_reachable's does:
# this listing is the sync sweep's first command, so leaving it unbounded lets a
# stalled Dolt server spend more wall clock than the whole sweep budget before a
# single bounded step runs. A listing that does not answer in time is one more
# unreadable case, never a home that has no remote.
fm_beads_sync_remote_state() { # [bound seconds]
  local out count rc=0 bound=${1:-}
  command -v task >/dev/null 2>&1 || { printf 'unreadable: task CLI not found\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unreadable: jq is not on PATH\n'; return 0; }
  if [ -n "$bound" ]; then
    fm_beads_require_timeout_lib || { printf 'unreadable: timeout library unavailable\n'; return 0; }
    out=$(fm_run_timed "$bound" task dolt remote list --json 2>&1) || rc=$?
  else
    out=$(task dolt remote list --json 2>&1) || rc=$?
  fi
  if [ "$rc" -eq 124 ] && [ -n "$bound" ]; then
    printf "unreadable: 'task dolt remote list --json' timed out after %ss\n" "$bound"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf "unreadable: 'task dolt remote list --json' failed: %s\n" "$(fm_beads_diag_line "$out")"
    return 0
  fi
  count=$(printf '%s' "$out" | jq -r 'if type=="array" then length else "" end' 2>/dev/null) || count=
  case "$count" in
    '' | *[!0-9]*) printf 'unreadable: the Dolt remote listing was not a JSON array\n' ;;
    0) printf 'none\n' ;;
    *) printf 'configured\n' ;;
  esac
}

# fm_beads_diag_line - collapse captured command output into one bounded line,
# so a multi-line CLI error still fits the single-line BEADS_SYNC: diagnostic
# vocabulary the bootstrap-diagnostics skill parses.
fm_beads_diag_line() { # <captured output>
  local line
  line=$(printf '%s' "${1:-}" | tr '\n\t' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-200)
  printf '%s' "${line:-no output}"
}

FM_BEADS_SYNC_TIMEOUT=${FM_BEADS_SYNC_TIMEOUT:-45}
case "$FM_BEADS_SYNC_TIMEOUT" in '' | *[!0-9]* | 0) FM_BEADS_SYNC_TIMEOUT=45 ;; esac

# FM_BEADS_SYNC_BUDGET bounds the WHOLE sweep, not each step. Per-step bounds
# alone let the three steps sum past whatever budget the caller is itself
# running under, so a blackholed remote could starve every other sweep sharing
# that budget. The caller that has a stage budget sets this from it; the
# default is deliberately smaller than 3 x FM_BEADS_SYNC_TIMEOUT so the sum can
# never be the thing that decides.
FM_BEADS_SYNC_BUDGET=${FM_BEADS_SYNC_BUDGET:-40}
case "$FM_BEADS_SYNC_BUDGET" in '' | *[!0-9]* | 0) FM_BEADS_SYNC_BUDGET=40 ;; esac

# fm_beads_now - epoch seconds without depending on `date` being on PATH.
#
# The sync path runs under callers that restrict PATH, and its own tests strip
# whole PATH directories to simulate one missing dependency. On a host where
# `date` shares a directory with the stripped command - jq and date are both in
# /usr/bin on Linux - it disappears too. A bare `$(date +%s)` then expands to
# nothing, so `$(( + FM_BEADS_SYNC_BUDGET ))` silently evaluates to the budget
# alone: a 1970 deadline that makes every bounded step report the budget as
# already spent. That is an unreadable clock masquerading as an exhausted
# budget, exactly the collapse of two distinct causes that
# fm_beads_sync_remote_state's header forbids for the remote listing.
#
# EPOCHSECONDS is a shell variable and needs no PATH at all; `date` remains the
# fallback for a shell that does not export it. A clock that cannot be read is
# reported as a failure and never rendered as a number, because a wrong number
# here is indistinguishable downstream from a legitimately spent budget.
fm_beads_now() {
  local now
  if [ -n "${EPOCHSECONDS:-}" ]; then
    printf '%s' "$EPOCHSECONDS"
    return 0
  fi
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$now"
}

# fm_beads_sync_step_bound - seconds the next step may take: whatever remains of
# the sweep budget, capped at the per-step bound. Non-zero when the budget is
# spent, so a caller reports the skipped step rather than starting one it has
# no time for.
fm_beads_sync_step_bound() { # <deadline epoch>
  local remaining now
  now=$(fm_beads_now) || return 1
  remaining=$(( $1 - now ))
  [ "$remaining" -gt 0 ] || return 1
  [ "$remaining" -le "$FM_BEADS_SYNC_TIMEOUT" ] || remaining=$FM_BEADS_SYNC_TIMEOUT
  printf '%s' "$remaining"
}

# fm-timeout-lib.sh is loaded lazily by the sync path alone. Every other
# consumer of this library (bootstrap's detect-only pass, teardown, the
# secondmate handoff, the remote doctor) must not pay for a library it never
# calls, the same discipline fm-beads-resilience-lib.sh applies to its own
# lazily-sourced lock library.
_FM_BEADS_TIMEOUT_LIB_LOADED=0
fm_beads_require_timeout_lib() {
  [ "$_FM_BEADS_TIMEOUT_LIB_LOADED" = 1 ] && return 0
  # Already provided - by this library's own eager source, or by a consumer that
  # loaded fm-timeout-lib.sh first. Re-sourcing would be pointless work, and in
  # a partially-synced remote code root that carries this library without its
  # siblings it would abort the caller under `set -e` on a file that is absent
  # precisely because nothing needs to be loaded.
  if declare -f fm_run_timed >/dev/null 2>&1; then
    _FM_BEADS_TIMEOUT_LIB_LOADED=1
    return 0
  fi
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$lib_dir/fm-timeout-lib.sh" ] || return 1
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$lib_dir/fm-timeout-lib.sh"
  _FM_BEADS_TIMEOUT_LIB_LOADED=1
}

# fm-wake-lib.sh's lock primitives are loaded the same lazy way, and by the one
# sweep that mutates the store on a schedule rather than on request. It is not
# sourced eagerly because it unconditionally mkdir -p's $STATE, which would make
# merely sourcing this library create a home's state directory.
_FM_BEADS_LOCK_LIB_LOADED=0
fm_beads_require_lock_lib() {
  [ "$_FM_BEADS_LOCK_LIB_LOADED" = 1 ] && return 0
  # Already provided by a consumer that sourced fm-wake-lib.sh first, so
  # re-sourcing would be pointless work and, in a partially-synced remote code
  # root, a failure on a file nothing needs.
  if declare -f fm_lock_try_acquire >/dev/null 2>&1; then
    _FM_BEADS_LOCK_LIB_LOADED=1
    return 0
  fi
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$lib_dir/fm-wake-lib.sh" ] || return 1
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$lib_dir/fm-wake-lib.sh"
  _FM_BEADS_LOCK_LIB_LOADED=1
}

# fm_beads_sync_backup_bin - the approved Dolt publisher this sweep delegates
# its remote leg to.
#
# There is exactly one destination, one credential path, and one head test, and
# they live in bin/fm-beads-remote-backup.sh alone: the remote name, its URL, and
# the mesh user are resolved inside that script, so the routine sweep holds no
# second definition of them that could drift away from the approved copy.
#
# FM_BEADS_SYNC_BACKUP_BIN overrides the path for tests and for a home that pins
# a different publisher; it is this sweep's own knob, deliberately distinct from
# the publisher's own FM_BEADS_BACKUP_* environment.
#
# A path that cannot be resolved is reported by the caller rather than guessed at,
# because silently skipping the remote leg is the failure this whole delegation
# exists to end.
#
# The directory is resolved from this library's own location, the same way
# fm_beads_require_timeout_lib resolves its sibling, so a partially-synced remote
# code root cannot make the sweep reach for a publisher it does not have.
fm_beads_sync_backup_bin() {
  local lib_dir
  if [ -n "${FM_BEADS_SYNC_BACKUP_BIN:-}" ]; then
    printf '%s\n' "$FM_BEADS_SYNC_BACKUP_BIN"
    return 0
  fi
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  printf '%s/fm-beads-remote-backup.sh\n' "$lib_dir"
}

# fm_beads_sync_once - best-effort commit, publish, and head verification
# against the approved Dolt remote, printing one BEADS_SYNC: line per outcome.
#
# BEST-EFFORT IS THE CONTRACT, NOT A WEAKNESS. The remote leg is hard-bounded by
# fm_run_timed (exit 124 means the bound was hit), the whole sweep by
# FM_BEADS_SYNC_BUDGET, and every failure is a reported diagnostic, so an
# unreachable remote, a stalled network, or a broken Dolt server degrades to a
# printed line and never wedges the caller or eats a budget it shares. The
# function returns non-zero only to tell the caller a step failed; the caller's
# own work continues either way, and the non-zero status it returns is the
# publisher's own: the sweep relays both, so no outcome is re-classified here.
#
# THE REMOTE LEG IS DELEGATED, NEVER REIMPLEMENTED. A bare `task dolt push`
# resolves to Dolt's implicit default remote (`origin`), which this store has
# never had, so the sweep used to fail every session with `remote 'origin' not
# found`. Naming the approved remote explicitly on the client side is not the fix
# either: the client holds no mesh credential, so it fails with `root has not
# been granted CLONE_ADMIN`. The only path that authenticates is the server-side
# one bin/fm-beads-remote-backup.sh already uses, where the credential comes from
# the Dolt server's own environment through
# `call dolt_push('<remote>','main','--user','<mesh-user>')`. This sweep therefore
# hands its whole remote leg to that publisher's --repair mode and relays its
# BEADS_BACKUP: outcomes unchanged, so the routine path and the approved publisher
# cannot disagree about the destination, the credential, or the head test.
# firstmate never holds the mesh password, and no `origin` remote is ever added.
#
# The old client-side pull leg is deliberately GONE rather than reimplemented. It
# carried the same authorization problem, and pulling remote commits into a store
# documented as the single write authority is the direction the topology forbids.
# The publisher's own post-push `dolt_fetch` is the fetch-only verification that
# replaces it, and the sweep prints one explicit line saying so rather than
# dropping the leg silently.
#
# Order is the publisher's: commit, push, then fetch-and-compare. The commit comes
# first because the default `--dolt-auto-commit` policy is `off`, so a home's
# writes sit in the Dolt working set and a push without it would publish nothing,
# and durability - getting this home's own commits off this machine - is the gap
# being closed.
#
# The deadline is established before the FIRST command runs, and the caller may
# supply one it has already been spending against, so every probe and every step
# the sweep runs is inside one budget rather than the budget covering only the
# steps it happens to name.
fm_beads_sync_once() { # [deadline epoch]
  local rc=0 step_rc remote_state deadline bound now
  local backup_bin backup_name backup_out relayed line
  command -v task >/dev/null 2>&1 || {
    echo "BEADS_SYNC: skipped: task CLI not found"
    return 1
  }
  fm_beads_require_timeout_lib || { echo "BEADS_SYNC: skipped: timeout library unavailable"; return 1; }
  # The clock is read once, up front, and its own failure gets its own line. A
  # caller-supplied deadline skips the read entirely, so this is also the only
  # place the default path can discover an unreadable clock before
  # fm_beads_sync_step_bound would report it as a spent budget instead.
  deadline=${1:-}
  if [ -z "$deadline" ]; then
    if now=$(fm_beads_now); then
      deadline=$(( now + FM_BEADS_SYNC_BUDGET ))
    else
      echo "BEADS_SYNC: skipped: the clock is unreadable, so the ${FM_BEADS_SYNC_BUDGET}s sync budget cannot be bounded"
      return 1
    fi
  fi
  if ! bound=$(fm_beads_sync_step_bound "$deadline"); then
    echo "BEADS_SYNC: skipped: the ${FM_BEADS_SYNC_BUDGET}s sync budget was spent before the Dolt remote list could be read"
    return 1
  fi
  remote_state=$(fm_beads_sync_remote_state "$bound")
  case "$remote_state" in
    configured) ;;
    none)
      echo "BEADS_SYNC: skipped: no Dolt remote configured, so this store is single-machine only"
      return 0
      ;;
    *)
      # Not the benign single-machine posture: this host cannot tell whether a
      # remote exists, so it must not be reported as one that has none.
      echo "BEADS_SYNC: skipped: could not read the Dolt remote list, so a configured remote is indistinguishable from none (${remote_state#unreadable: })"
      return 1
      ;;
  esac

  # The publisher is resolved before the budget is spent on it, so a missing or
  # non-executable publisher is one named line rather than a bare 127 from
  # fm_run_timed that reads like the remote itself failed.
  backup_bin=$(fm_beads_sync_backup_bin) || backup_bin=
  if [ -z "$backup_bin" ] || [ ! -x "$backup_bin" ]; then
    echo "BEADS_SYNC: skipped: the approved Dolt publisher is not executable at ${backup_bin:-<unresolved>}, so the remote leg cannot run"
    return 1
  fi
  backup_name=${backup_bin##*/}

  # One bounded call carries the whole remote leg, because that is what the
  # publisher is: it commits the working set, pushes through the mesh user,
  # fetches, and compares heads, reporting each of those as a BEADS_BACKUP:
  # outcome. Its status is captured with `|| step_rc=$?` rather than a bare call
  # followed by `$?`, so a failing publisher is exempt from `set -e` no matter
  # which caller sourced this library. Best-effort must not depend on the caller
  # happening to invoke this function inside an `if` or a `|| true`.
  if bound=$(fm_beads_sync_step_bound "$deadline"); then
    step_rc=0
    backup_out=$(fm_run_timed "$bound" "$backup_bin" --repair 2>&1) || step_rc=$?

    # Every publisher outcome becomes one BEADS_SYNC: line, with the payload
    # carried verbatim: the publisher's header is the single owner of that
    # vocabulary, so re-spelling it here would be the second copy that drifts.
    # Output that is not a publisher outcome is never relayed line by line; it
    # is folded into one bounded diagnostic below, so a broken publisher cannot
    # flood a session-start digest.
    relayed=0
    while IFS= read -r line; do
      case "$line" in
        'BEADS_BACKUP: '*)
          printf 'BEADS_SYNC: %s\n' "${line#BEADS_BACKUP: }"
          relayed=1
          ;;
      esac
    done <<< "$backup_out"

    if [ "$step_rc" -eq 124 ]; then
      echo "BEADS_SYNC: remote leg failed: timed out after ${bound}s"
      rc=1
    elif [ "$step_rc" -ne 0 ]; then
      rc=1
      if [ "$relayed" -eq 0 ]; then
        echo "BEADS_SYNC: remote leg failed: '$backup_name' exited $step_rc: $(fm_beads_diag_line "$backup_out")"
      fi
    elif [ "$relayed" -eq 0 ]; then
      echo "BEADS_SYNC: remote leg failed: '$backup_name' exited 0 without reporting an outcome"
    fi
  else
    echo "BEADS_SYNC: remote leg skipped: the ${FM_BEADS_SYNC_BUDGET}s sync budget was spent"
    rc=1
  fi

  # The dropped pull leg is reported rather than silently absent: a reader who
  # remembers the old commit/push/pull shape must be able to tell an intentional
  # removal from a step that quietly stopped running.
  echo "BEADS_SYNC: pull dropped: the approved publisher fetches to verify one shared head, and this store is the single write authority, so the sweep never pulls remote commits into it"

  return "$rc"
}

# fm_beads_fleet_label - the label firstmate's own dispatched-work beads are
# meant to carry once bead creation is wired to it (beads-authority migration
# Stage 0; see data/beads-authority-migration-scout/report.md section 4 and
# docs/configuration.md "Backlog backend"). A `task list --label <this>` call
# scopes to firstmate's fleet instead of the shared federated store's full
# cross-project set. Multiple bin/ scripts call fm_beads_resolve_or_create to
# mint fleet-labeled beads: fm-decision-hold.sh (captain-hold anchor), fm-brief.sh
# (intake capture), and fm-spawn.sh (dispatch). fm-fleet-snapshot.sh and
# fm-bearings-snapshot.sh read it.
# FM_BEADS_FLEET_LABEL is an override for test fixtures; production code
# should call this function rather than hardcoding the label.
fm_beads_fleet_label() {
  printf '%s\n' "${FM_BEADS_FLEET_LABEL:-fleet:firstmate}"
}

# fm_beads_home_scope - the stable per-home scope that keeps the task:<id>
# idempotency label distinct across firstmate homes sharing one beads store.
#
# WHY IT EXISTS. The beads store is machine-wide: the federation `task` wrapper
# pins one BEADS_DIR for every home, and config/backlog-backend is inherited by
# secondmate homes, so the primary and every secondmate resolve against one
# store while picking task slugs from independent per-home backlogs. A label
# keyed only on the task slug (task:<id>) is therefore identical across homes:
# home B reusing a slug home A already used adopts A's bead, and A closing its
# bead marks B's live work done. Home-scoping the label is the only fix that
# keeps two homes' beads distinct, which is also why ANDing the shared
# fleet:firstmate label into the lookup is NOT sufficient - every home shares
# that label too.
#
# DERIVATION. The home path is the home's own durable identity, read fresh from
# FM_HOME exactly as fm_backend_herdr_workspace_label does: it is stable across
# restarts and distinct per FM_HOME by construction. SHA-256 of that path,
# truncated to 16 hex chars, keeps the label short and readable while making a
# collision across a small fleet effectively impossible. The shasum/sha256sum
# fallback matches the established pattern in fm-decision-hold.sh and
# fm-remote-home-provision.sh, and the scope is lowercase hex so it is a legal
# label character class and never contains a comma (labels are comma-separated).
#
# NORMALIZATION. The hash is taken over the home's PHYSICAL path, not the string
# a caller happened to pass. FM_HOME reaches this library through several call
# paths that do not canonicalize it (fm-brief.sh and fm-spawn.sh pass an absolute
# path through unchanged, fm-backlog-import-beads.sh does not resolve it at all),
# so '/x/home', '/x/home/', a relative spelling, and a symlinked spelling all name
# one home while hashing to four different scopes - which would strand the intake
# bead fm-brief.sh minted where fm-spawn.sh cannot find it, mint a duplicate, and
# leave the first bead open forever because teardown only closes the meta's id.
# This function is the single owner of the derivation, so the normalization lives
# here rather than in each caller. A home path that cannot be resolved (it does
# not exist yet, or is unreadable) falls back to the lexically stripped string so
# the scope stays deterministic; only an empty home or a missing hash tool fails.
#
# FM_BEADS_HOME_SCOPE is a test-fixture override (mirroring FM_BEADS_FLEET_LABEL)
# so suites can pin a deterministic scope; production code calls this function
# rather than hardcoding a scope.
fm_beads_home_scope() { # [home] - echo the home's 16-hex scope, or fail (return 1, print nothing)
  local home=${1:-${FM_HOME:-}} resolved scope
  if [ -n "${FM_BEADS_HOME_SCOPE:-}" ]; then
    printf '%s\n' "$FM_BEADS_HOME_SCOPE"
    return 0
  fi
  [ -n "$home" ] || return 1
  resolved=$(CDPATH='' cd -P -- "$home" 2>/dev/null && pwd -P) || resolved=
  if [ -z "$resolved" ]; then
    resolved=$home
    while [ "${#resolved}" -gt 1 ] && [ "${resolved%/}" != "$resolved" ]; do
      resolved=${resolved%/}
    done
  fi
  if command -v shasum >/dev/null 2>&1; then
    scope=$(printf '%s' "$resolved" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    scope=$(printf '%s' "$resolved" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$scope" in
    '' | *[!0-9a-fA-F]*) return 1 ;;
  esac
  printf '%s\n' "${scope:0:16}"
}

# fm_beads_task_label <task_id> - the home-scoped idempotency label for a task:
# task:<home-scope>:<task_id>. Prints nothing and returns 1 when the scope
# cannot be derived (missing home or hash tool) so callers fail open.
fm_beads_task_label() { # <task_id>
  local task_id=$1 scope
  scope=$(fm_beads_home_scope) || return 1
  printf 'task:%s:%s\n' "$scope" "$task_id"
}

# fm_beads_task_label_legacy <task_id> - the pre-home-scoping idempotency label
# task:<task_id>. It is never minted, and the dispatch path never resolves
# against it: the only reader is fm_beads_migrate_legacy_task_labels, the
# one-shot sweep that re-tags this home's own pre-migration beads.
fm_beads_task_label_legacy() { # <task_id>
  printf 'task:%s\n' "$1"
}

# fm_beads_home_recorded_bead <task_id> - echo the bead id this home's own
# durable record already links <task_id> to, or print nothing and return 1 when
# the record is absent, unreadable, or carries no beads_id=. Single owner of that
# read. The migration sweep uses it as a disqualifier: a home whose own record
# already names a DIFFERENT bead for that slug has its own bead and must not
# claim the unscoped one.
fm_beads_home_recorded_bead() { # <task_id>
  local task_id=$1 meta recorded
  [ -n "$task_id" ] || return 1
  # Same resolution order the callers use: an already-resolved STATE, else the
  # FM_STATE_OVERRIDE a caller may have set without exporting STATE, else the
  # home's own state dir.
  meta="${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}}/$task_id.meta"
  [ -f "$meta" ] || return 1
  recorded=$(grep '^beads_id=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$recorded" ] || return 1
  printf '%s\n' "$recorded"
}

# fm_beads_home_repoint_recorded_bead <task_id> <bead_id> - point THIS home's own
# state/<task_id>.meta at <bead_id>, replacing its beads_id= line in place and
# preserving every other line and the file's ordering. Returns 0 without writing
# when the record already names that bead, so a re-run is a no-op, and 1 when
# there is no record, no beads_id= line to replace, another process is writing
# that record right now, or the rewrite fails.
#
# This is the only meta the beads code ever rewrites, and only ever this home's
# own. The migration sweep needs it because an ALREADY-DISPATCHED task is pinned
# to its bead by this recorded id, not by the label: bin/fm-crew-state.sh and
# bin/fm-teardown.sh both read beads_id= directly and never re-resolve, so a home
# that loses the sweep race for a shared pre-migration bead would keep closing
# that bead even after the winner scoped it. Repointing this home's own record at
# a bead of its own is what actually separates the two homes. The other home's
# bead is never rewritten, re-tagged, or closed.
#
# The write goes through the same per-task meta lock and tmp-then-rename that
# fm-spawn.sh and fm-x-lib.sh use, so it can never interleave with a concurrent
# full-meta rewrite. A lock a live writer holds is reported as a failure rather
# than waited on, because the caller runs inside a time budget and its failure
# path already retries next session.
fm_beads_home_repoint_recorded_bead() { # <task_id> <bead_id>
  local task_id=$1 bead_id=$2 meta recorded lock tmp rc
  [ -n "$task_id" ] && [ -n "$bead_id" ] || return 1
  meta="${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}}/$task_id.meta"
  [ -f "$meta" ] || return 1
  # Skip if the task's endpoint is still alive — the live worker carries the old
  # bead ID in its brief and would act on a stale reference if meta were rewritten
  # under it. Retry in a later session once the task completes.
  local _ep_backend _ep_window
  _ep_backend=$(grep '^backend=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || _ep_backend=
  _ep_window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || _ep_window=
  if [ -n "$_ep_window" ]; then
    if declare -f fm_backend_target_exists >/dev/null 2>&1; then
      if fm_backend_target_exists "${_ep_backend:-tmux}" "$_ep_window" 2>/dev/null; then
        printf 'diagnostic: skipping repoint of %s — endpoint still live, will retry in a later session\n' "$task_id" >&2
        return 1
      fi
    else
      case "${_ep_backend:-tmux}" in
        tmux)
          if tmux display-message -p -t "$_ep_window" '#{pane_id}' >/dev/null 2>&1; then
            printf 'diagnostic: skipping repoint of %s — endpoint still live, will retry in a later session\n' "$task_id" >&2
            return 1
          fi
          ;;
        *)
          printf 'diagnostic: skipping repoint of %s — cannot check %s endpoint without fm_backend_target_exists, will retry in a later session\n' \
            "$task_id" "${_ep_backend:-unknown}" >&2
          return 1
          ;;
      esac
    fi
  fi
  recorded=$(fm_beads_home_recorded_bead "$task_id") || recorded=
  [ "$recorded" = "$bead_id" ] && return 0
  [ -n "$recorded" ] || return 1
  fm_beads_require_lock_lib || return 1
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_try_acquire "$lock" || return 1
  rc=1
  tmp="$meta.beads-repoint.$$"
  if FM_BEADS_REPOINT_ID="$bead_id" awk '
      /^beads_id=/ { print "beads_id=" ENVIRON["FM_BEADS_REPOINT_ID"]; next }
      { print }
    ' "$meta" >"$tmp" 2>/dev/null && mv -f -- "$tmp" "$meta"; then
    rc=0
  fi
  rm -f -- "$tmp"
  fm_lock_release "$lock"
  return "$rc"
}

# fm_beads_bead_labels <bead_id> [list_payload] [bound] - echo the bead's labels
# as a compact JSON array, or print nothing and return 1 when they cannot be
# read. The `task list --json` payload the caller already fetched is used when it
# carries a labels field, so no extra store call is paid; the real CLI omits
# labels from list rows, so the fallback is `task label list <id> --json`, which
# returns a flat array of label strings. An unreadable answer is reported as
# such (return 1) rather than as "no labels", because the caller uses it to
# decide whether re-tagging a bead is SAFE and must not read a failed store as
# proof that nothing else claims it.
#
# The optional bound follows fm_beads_store_reachable's rule: a caller running
# under a deadline gets a bounded read or gets nothing, because a Dolt server
# that accepts the connection and never answers would otherwise hold that
# caller open for as long as the store cares to stall. A read cut off at the
# bound is an unreadable answer, which is already what return 1 means.
fm_beads_bead_labels() { # <bead_id> [list_payload] [bound]
  local bead_id=$1 payload=${2:-} bound=${3:-} labels
  [ -n "$bead_id" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [ -n "$payload" ]; then
    labels=$(printf '%s' "$payload" | jq -c '
      if type=="array" and length>0 and (.[0]|type=="object") and (.[0]|has("labels"))
      then (.[0].labels // []) else empty end' 2>/dev/null) || labels=
    if [ -n "$labels" ]; then
      printf '%s\n' "$labels"
      return 0
    fi
  fi
  command -v task >/dev/null 2>&1 || return 1
  if [ -n "$bound" ]; then
    declare -f fm_run_timed >/dev/null 2>&1 || return 1
    labels=$(fm_run_timed "$bound" task label list "$bead_id" --json 2>/dev/null) || return 1
  else
    labels=$(task label list "$bead_id" --json 2>/dev/null) || return 1
  fi
  labels=$(printf '%s' "$labels" | jq -c 'if type=="array" then . else empty end' 2>/dev/null) || labels=
  [ -n "$labels" ] || return 1
  printf '%s\n' "$labels"
}

# fm_beads_bead_has_label <labels_json> <label> - true when the bead already
# carries that exact label. Used to keep the migration sweep idempotent: a bead
# already carrying this home's scoped label needs no second re-tag.
#
# An empty jq result here is a genuine "no" rather than a swallowed failure: the
# labels argument is the compact array fm_beads_bead_labels already validated,
# jq's presence is checked before the read, and the filter cannot fail against a
# well-formed array, so there is no unreadable case left for this to conflate.
fm_beads_bead_has_label() { # <labels_json> <label>
  local labels=$1 label=$2 hit
  [ -n "$labels" ] && [ -n "$label" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  hit=$(printf '%s' "$labels" | jq -r --arg l "$label" \
    '[ .[]? | select(type=="string") | select(. == $l) ] | length' 2>/dev/null) || hit=
  case "$hit" in
    '' | 0) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_beads_bead_has_foreign_scope <task_id> <scope> <labels_json> - true when the
# bead already carries some OTHER home's scoped task:<scope>:<task_id> label.
# That is the exclusivity check the migration sweep owes: the legacy task:<id>
# label records no home, so two homes that both used the slug can both see one
# pre-migration bead as a candidate. The first home to sweep keeps it and stamps
# its scope on it; the second sees that foreign scope, leaves the bead alone, and
# mints its own bead on its next resolve, so the two stop sharing.
#
# Its labels argument carries the same guarantee fm_beads_bead_has_label relies
# on, so an empty jq result means the bead really carries no other home's scope.
fm_beads_bead_has_foreign_scope() { # <task_id> <scope> <labels_json>
  local task_id=$1 scope=$2 labels=$3 foreign
  [ -n "$task_id" ] && [ -n "$scope" ] && [ -n "$labels" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  foreign=$(printf '%s' "$labels" | jq -r --arg tid "$task_id" --arg scope "$scope" '
    [ .[]?
      | select(type=="string")
      | split(":")
      | select(length==3 and .[0]=="task" and .[2]==$tid and .[1]!=$scope)
    ] | length' 2>/dev/null) || foreign=
  case "$foreign" in
    '' | 0) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_beads_home_task_ids - echo, one per line and deduplicated, every task id
# this home holds a durable local record for: a dispatched task's
# state/<id>.meta, or a scaffolded task's data/<id>/brief.md. Those two records
# are made by THIS home when it takes the task on, which is the evidence the
# migration sweep needs and what the unscoped task:<id> label itself never
# recorded.
#
# A data/backlog.md item id is deliberately NOT evidence. Every home that ever
# queued a slug carries that line, including a home that never dispatched it, so
# treating it as ownership let a home claim a bead a DIFFERENT home had already
# minted and recorded in its own state/<id>.meta - the exact shared-bead bug the
# home-scoped label exists to eliminate. This function enumerates candidates;
# fm_beads_home_claims_bead decides whether a candidate's record actually names
# the bead in hand.
fm_beads_home_task_ids() {
  local state data entry name
  state=${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}}
  data=${DATA:-${FM_DATA_OVERRIDE:-${FM_HOME:-}/data}}
  {
    if [ -d "$state" ]; then
      for entry in "$state"/*.meta; do
        [ -f "$entry" ] || continue
        name=${entry##*/}
        printf '%s\n' "${name%.meta}"
      done
    fi
    if [ -d "$data" ]; then
      for entry in "$data"/*/brief.md; do
        [ -f "$entry" ] || continue
        name=${entry%/brief.md}
        printf '%s\n' "${name##*/}"
      done
    fi
  } | LC_ALL=C sort -u
}

# fm_beads_home_claims_bead <task_id> <bead_id> [recorded_bead] - true when THIS
# home's own durable records claim <bead_id> as its bead for <task_id>. The two
# evidence classes are exhaustive and each is a record this home wrote itself:
#
#   1. state/<task_id>.meta records beads_id=<bead_id> exactly. The strongest
#      evidence there is: this home dispatched the task against that bead.
#   2. data/<task_id>/brief.md exists AND no meta names a bead at all. The task
#      was scaffolded here and never dispatched, so the pre-migration bead the
#      slug carries is this home's own intake bead.
#
# A meta naming a DIFFERENT bead is a disqualifier rather than merely absent
# evidence: this home already has its own bead for that slug, so the unscoped one
# is someone else's. The optional third argument passes an already-read
# beads_id= through so a caller that needed it for its own diagnostic does not
# pay a second read; omit it and this reads the meta itself.
fm_beads_home_claims_bead() { # <task_id> <bead_id> [recorded_bead]
  local task_id=$1 bead_id=$2 recorded data
  [ -n "$task_id" ] && [ -n "$bead_id" ] || return 1
  if [ "$#" -ge 3 ]; then
    recorded=$3
  else
    recorded=$(fm_beads_home_recorded_bead "$task_id") || recorded=
  fi
  [ "$recorded" = "$bead_id" ] && return 0
  [ -z "$recorded" ] || return 1
  data=${DATA:-${FM_DATA_OVERRIDE:-${FM_HOME:-}/data}}
  [ -f "$data/$task_id/brief.md" ]
}

# fm_beads_legacy_labelled_task_ids [bound] - echo every task id the store still
# has an unscoped task:<task_id> label for, one per line. One store call
# (`task label list-all`) answers for the whole store, so the sweep pays a
# per-candidate call only for the ids this home actually knows. Returns 1 when
# the label list cannot be read, so the caller can report "unmigrated" rather
# than mistake an unreadable store for a clean one. An exit-0 answer that is not
# a JSON array is an unreadable one and takes that same path, because the empty
# result it would otherwise parse to is indistinguishable from a clean store and
# would let the caller write its permanent one-shot marker over a migration that
# never ran. The optional bound carries the same contract as
# fm_beads_bead_labels': a bounded read or none at all, and a read cut off at
# the bound is an unreadable one.
fm_beads_legacy_labelled_task_ids() { # [bound]
  local bound=${1:-} all
  command -v task >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [ -n "$bound" ]; then
    declare -f fm_run_timed >/dev/null 2>&1 || return 1
    all=$(fm_run_timed "$bound" task label list-all --json 2>/dev/null) || return 1
  else
    all=$(task label list-all --json 2>/dev/null) || return 1
  fi
  [ -n "$all" ] || return 1
  printf '%s' "$all" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  printf '%s' "$all" | jq -r '
    .[]?
    | (if type=="object" then (.label // empty) else . end)
    | select(type=="string")
    | split(":")
    | select(length==2 and .[0]=="task" and (.[1] | length) > 0)
    | .[1]' 2>/dev/null || return 1
}

# fm_beads_migrate_legacy_task_labels - the ONE-SHOT migration off the
# pre-home-scoping task:<task_id> label onto task:<home-scope>:<task_id>.
#
# WHY A SWEEP AND NOT A COMPATIBILITY READ. Resolving the legacy label on the
# dispatch path cannot work: it would have to decide, per resolve, whether an
# unscoped bead belongs to THIS home, and the label records no home. The only
# home-local ownership record - state/<task_id>.meta's beads_id= - does not exist
# yet at either point a bead is minted (fm-brief.sh mints at scaffold time and
# fm-spawn.sh resolves before it writes the meta), and fm-backlog-import-beads.sh
# writes no metas at all, so a meta-gated read is unreachable for exactly the
# in-flight beads it would exist to rescue, while an ungated one re-adopts other
# homes' beads and reinstates the cross-home bug. Moving the migration out of
# resolve settles both: the dispatch path is a single scoped-label lookup with no
# migration write, and the rescue happens once, deliberately, with the whole
# home-local record set available as evidence.
#
# WHAT IT DOES. For every unscoped task:<id> label in the store whose id this
# home holds a durable record for (fm_beads_home_task_ids), it re-tags the OPEN
# bead carrying that label onto this home's scoped label, and only then.
# fm_beads_home_claims_bead is the claim test: this home's own meta must name
# that exact bead, or this home must hold the task's brief with no meta naming
# any bead. It skips a bead this home's own record contradicts (the meta names a
# different bead), a bead no such record claims, a bead some other home has
# already scoped for that id (fm_beads_bead_has_foreign_scope), and a bead whose
# labels cannot be read at all. Closed beads are excluded by the store's own
# default filter, so a finished task's surviving label is never touched. No label
# is ever removed and no bead is ever closed, and the only bead this sweep writes
# to is one this home can show is its own.
#
# LOSING THE RACE IS NOT ENOUGH. A bead another home has already scoped is left
# alone, but leaving it there is only safe for a task this home has not yet
# dispatched, which simply mints its own bead on its next resolve. An
# ALREADY-DISPATCHED task is pinned to that shared bead by its own
# state/<id>.meta beads_id=, which bin/fm-crew-state.sh and bin/fm-teardown.sh
# read directly and never re-resolve, so it would keep acting on the other home's
# bead forever. For exactly that case the sweep gives this home a bead of its own
# (resolving this home's scoped label first, so a retry after a partial pass
# reuses the bead it already minted) and repoints this home's OWN meta at it
# through fm_beads_home_repoint_recorded_bead. The other home's bead is untouched.
#
# A LOOKUP THAT FAILED IS NOT A LOOKUP THAT FOUND NOTHING. The per-candidate
# `task list` is checked for both its exit status and an array-shaped payload,
# because collapsing a store failure into an empty result would take the benign
# "the surviving label belongs to a closed record" path, write the permanent
# one-shot marker, and leave that bead unmigrated forever.
#
# RESIDUAL AMBIGUITY, stated rather than hidden: when two homes both hold a
# claiming record for one slug and only one pre-migration bead exists, the label
# cannot say which home minted it, so the first home to sweep keeps that bead and
# the second ends up on a bead of its own - minted on its next resolve if it never
# dispatched the task, or minted and repointed by its own sweep if it did. What
# genuinely remains is that the surviving bead's history stays with the winning
# home while the losing home's replacement starts empty, and that the separation
# happens only when the losing home actually runs its sweep, so a home that never
# starts a session, or whose sweep keeps failing against an unreachable store,
# stays pinned to the shared bead until it does.
#
# IDEMPOTENCE. A durable marker records a completed sweep, so later sessions cost
# nothing; the marker is written only when no candidate failed, so a transient
# store failure retries next session. The sweep is also intrinsically idempotent:
# a bead already carrying this home's scoped label is skipped on its own evidence
# even with the marker removed.
#
# SERIALIZATION. The sweep body runs under its own non-blocking lock, the same
# way fm_beads_write_queue_reconcile guards its replay, so two processes in one
# home can never sweep the same store at once. Bootstrap's phase gating already
# keeps the local and network-only passes apart; the lock is what makes that
# safe rather than merely arranged, and it holds if the gating is ever changed.
# A held lock means another process is already doing this one-shot work, so the
# caller returns success silently rather than waiting inside a budgeted phase.
# The whole sweep runs under one budget, and every store call within it under
# whatever of that budget is left, capped at the same per-read bound the
# heartbeat status read uses. A Dolt sql-server that accepts the connection and
# then never answers would otherwise hold the bootstrap phase this sweep runs in
# open on a probe nobody bounded, and a home with many candidates could hold it
# open on their sum even when each call answers. Exhausting the budget leaves the
# marker unwritten, so the sweep resumes next session instead of declaring a
# partial pass complete.
FM_BEADS_LABEL_MIGRATION_BUDGET=${FM_BEADS_LABEL_MIGRATION_BUDGET:-60}
case "$FM_BEADS_LABEL_MIGRATION_BUDGET" in
  '' | *[!0-9]*) FM_BEADS_LABEL_MIGRATION_BUDGET=60 ;;
  *) [ "$FM_BEADS_LABEL_MIGRATION_BUDGET" -gt 0 ] 2>/dev/null || FM_BEADS_LABEL_MIGRATION_BUDGET=60 ;;
esac

# fm_beads_migrate_step_bound <deadline epoch> - echo the bound the next store
# call gets, or return 1 when the sweep's budget is spent.
fm_beads_migrate_step_bound() { # <deadline epoch>
  local remaining
  remaining=$(( ${1:-0} - $(date +%s) ))
  [ "$remaining" -gt 0 ] || return 1
  [ "$remaining" -le "$FM_BEADS_STATUS_TIMEOUT" ] || remaining=$FM_BEADS_STATUS_TIMEOUT
  printf '%s\n' "$remaining"
}

fm_beads_migrate_legacy_task_labels() {
  local state_dir marker lock rc
  state_dir=${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}}
  marker=${FM_BEADS_LABEL_MIGRATION_MARKER:-$state_dir/.beads-label-migration-v1}
  # The marker check is deliberately outside the lock: once the sweep is done,
  # every later session must cost one stat and must not create a lock directory
  # in a home that has nothing left to migrate.
  [ ! -e "$marker" ] || return 0
  lock=${FM_BEADS_LABEL_MIGRATION_LOCK:-$state_dir/.beads-label-migration.lock}
  if ! fm_beads_require_lock_lib; then
    echo "BEADS_LABEL_MIGRATION: the lock library is unavailable, so pre-migration task labels stay unmigrated"
    return 1
  fi
  # Another process in this home is already sweeping. The work is one-shot and
  # idempotent, so the right answer is to leave it to that process rather than
  # wait for a lock inside a phase that is itself on a budget.
  fm_lock_try_acquire "$lock" || return 0
  fm_beads_migrate_legacy_task_labels_body "$marker"
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# fm_beads_migrate_legacy_task_labels_body <marker path> - the sweep proper,
# separated so every one of its exit paths releases the lock its caller holds
# without each having to remember to.
fm_beads_migrate_legacy_task_labels_body() { # <marker path>
  local marker=$1
  local scope known legacy id payload status bead labels recorded scoped_label
  local deadline bound replacement
  local migrated=0 repointed=0 skipped=0 failed=0
  if ! command -v task >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "BEADS_LABEL_MIGRATION: task CLI or jq not found, so pre-migration task labels stay unmigrated"
    return 1
  fi
  if ! fm_beads_require_timeout_lib; then
    echo "BEADS_LABEL_MIGRATION: timeout library unavailable, so pre-migration task labels stay unmigrated"
    return 1
  fi
  # The deadline is set before the first probe, so the reachability read is
  # inside the same budget as the re-tags it precedes.
  deadline=$(( $(date +%s) + FM_BEADS_LABEL_MIGRATION_BUDGET ))
  bound=$(fm_beads_migrate_step_bound "$deadline") || bound=$FM_BEADS_STATUS_TIMEOUT
  if ! fm_beads_store_reachable "$bound"; then
    echo "BEADS_LABEL_MIGRATION: store unreachable, so pre-migration task labels stay unmigrated"
    return 1
  fi
  if ! scope=$(fm_beads_home_scope) || [ -z "$scope" ]; then
    echo "BEADS_LABEL_MIGRATION: this home's scope could not be derived, so pre-migration task labels stay unmigrated"
    return 1
  fi
  if ! bound=$(fm_beads_migrate_step_bound "$deadline") \
    || ! legacy=$(fm_beads_legacy_labelled_task_ids "$bound"); then
    echo "BEADS_LABEL_MIGRATION: the store's label list could not be read, so pre-migration task labels stay unmigrated"
    return 1
  fi
  if [ -z "$legacy" ]; then
    : >"$marker" 2>/dev/null || true
    return 0
  fi
  known=$(fm_beads_home_task_ids)

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$known" | grep -qxF -- "$id" || continue
    if ! bound=$(fm_beads_migrate_step_bound "$deadline"); then
      failed=$((failed + 1))
      echo "BEADS_LABEL_MIGRATION: the ${FM_BEADS_LABEL_MIGRATION_BUDGET}s budget was spent, so the rest stays unmigrated and retries next session"
      break
    fi
    scoped_label="task:$scope:$id"
    payload=$(fm_run_timed "$bound" task list --label "$(fm_beads_task_label_legacy "$id")" \
      --limit 1 --json 2>/dev/null)
    status=$?
    # An unreadable lookup is counted as a failure so the marker is held back and
    # the next session retries. Only a lookup that succeeded AND returned a real
    # array may fall through to the benign "nothing open carries this label"
    # case below; jq -e distinguishes a parsed array from an absent, truncated,
    # or non-JSON payload, which a plain `.[0].id` read cannot.
    if [ "$status" -ne 0 ] \
      || ! printf '%s' "$payload" | jq -e 'type=="array"' >/dev/null 2>&1; then
      failed=$((failed + 1))
      echo "BEADS_LABEL_MIGRATION: could not look up $id's pre-migration bead, so it stays unmigrated and retries next session"
      continue
    fi
    bead=$(printf '%s' "$payload" \
      | jq -r 'if length>0 then (.[0].id // empty) else empty end' 2>/dev/null) || bead=
    # No OPEN bead carries the legacy label, so the surviving label belongs to a
    # closed record and there is nothing to migrate.
    [ -n "$bead" ] || continue
    recorded=$(fm_beads_home_recorded_bead "$id") || recorded=
    if [ -n "$recorded" ] && [ "$recorded" != "$bead" ]; then
      skipped=$((skipped + 1))
      echo "BEADS_LABEL_MIGRATION: left $bead alone: this home's own record for $id names $recorded"
      continue
    fi
    if ! fm_beads_home_claims_bead "$id" "$bead" "$recorded"; then
      skipped=$((skipped + 1))
      echo "BEADS_LABEL_MIGRATION: left $bead alone: no record here claims it for $id"
      continue
    fi
    if ! bound=$(fm_beads_migrate_step_bound "$deadline") \
      || ! labels=$(fm_beads_bead_labels "$bead" "$payload" "$bound"); then
      failed=$((failed + 1))
      echo "BEADS_LABEL_MIGRATION: could not read $bead's labels, so $id stays unmigrated and retries next session"
      continue
    fi
    fm_beads_bead_has_label "$labels" "$scoped_label" && continue
    if fm_beads_bead_has_foreign_scope "$id" "$scope" "$labels"; then
      if [ "$recorded" != "$bead" ]; then
        skipped=$((skipped + 1))
        echo "BEADS_LABEL_MIGRATION: left $bead alone: another home already claimed it for $id"
        continue
      fi
      if ! bound=$(fm_beads_migrate_step_bound "$deadline"); then
        failed=$((failed + 1))
        echo "BEADS_LABEL_MIGRATION: the ${FM_BEADS_LABEL_MIGRATION_BUDGET}s budget was spent, so the rest stays unmigrated and retries next session"
        break
      fi
      replacement=$(fm_beads_lookup "$id" "$bound")
      case $? in
        0) : ;;
        1) replacement= ;;
        *)
          failed=$((failed + 1))
          echo "BEADS_LABEL_MIGRATION: could not look up $id's replacement bead, so it stays pinned to $bead and retries next session"
          continue
          ;;
      esac
      if [ -z "$replacement" ]; then
        if ! bound=$(fm_beads_migrate_step_bound "$deadline") \
          || ! replacement=$(fm_beads_mint_task_bead "$id" "" "$bound") \
          || [ -z "$replacement" ]; then
          failed=$((failed + 1))
          echo "BEADS_LABEL_MIGRATION: could not mint $id a bead of its own, so it stays pinned to $bead and retries next session"
          continue
        fi
      fi
      if ! fm_beads_home_repoint_recorded_bead "$id" "$replacement"; then
        failed=$((failed + 1))
        echo "BEADS_LABEL_MIGRATION: could not repoint $id's own record onto $replacement, so it stays pinned to $bead and retries next session"
        continue
      fi
      repointed=$((repointed + 1))
      echo "BEADS_LABEL_MIGRATION: repointed $id onto its own bead $replacement: another home already claimed $bead"
      continue
    fi
    if bound=$(fm_beads_migrate_step_bound "$deadline") \
      && fm_run_timed "$bound" task tag "$bead" "$scoped_label" >/dev/null 2>&1; then
      migrated=$((migrated + 1))
      echo "BEADS_LABEL_MIGRATION: re-tagged $bead onto $scoped_label"
    else
      failed=$((failed + 1))
      echo "BEADS_LABEL_MIGRATION: re-tagging $bead onto $scoped_label failed; it retries next session"
    fi
  done <<EOF
$legacy
EOF

  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  : >"$marker" 2>/dev/null || true
  if [ "$migrated" -gt 0 ] || [ "$repointed" -gt 0 ] || [ "$skipped" -gt 0 ]; then
    echo "BEADS_LABEL_MIGRATION: complete: $migrated bead(s) re-tagged, $repointed task(s) repointed onto their own bead, $skipped left alone"
  fi
  return 0
}

# fm_beads_lookup <task_id> - echo the id of the OPEN bead this home resolves
# <task_id> to, or print nothing and fail. Read-only: it never mints and
# never writes, and it asks exactly one question - does an open bead carry this
# home's scoped task:<home-scope>:<task_id> label - so the common dispatch path
# (every brief scaffold and every spawn, permanently) is one store call with no
# migration write. Pre-migration beads carrying the old unscoped label are
# rescued by fm_beads_migrate_legacy_task_labels instead, not here.
# The default store filter excludes closed beads server side, so a closed
# predecessor is never adopted. This is the single lookup both
# fm_beads_resolve_or_create and fm-backlog-import-beads.sh's
# resolve_existing_bead share, so the importer's "(exists)" annotation and
# blocked-by edges always name the same bead the apply path resolves to.
#
# The optional bound carries the same contract as fm_beads_bead_labels': the
# dispatch path passes none and reads unbounded as it always has, while a caller
# running inside a time budget (the migration sweep) passes what is left of it
# and gets a bounded read or a refusal rather than an unbounded one.
#
# EXIT STATUS, which every caller must distinguish. 0 echoes the bead id. 1 means
# the store answered and no open bead carries this home's label. 2 means the
# question could not be asked or its answer could not be read at all: a missing
# tool, an underivable scope, a failed or bounded-out call, or a payload that is
# not a JSON array. Collapsing 2 into 1 is what lets a transient read failure
# read as "this home has no bead yet" and mint a second bead beside one that
# already exists, so a caller that mints must treat 2 as a refusal rather than a
# miss.
fm_beads_lookup() { # <task_id> [bound]
  local task_id=$1 bound=${2:-} task_label existing id
  [ -n "$task_id" ] || return 2
  task_label=$(fm_beads_task_label "$task_id") || return 2
  if [ -n "$bound" ]; then
    declare -f fm_run_timed >/dev/null 2>&1 || return 2
    existing=$(fm_run_timed "$bound" task list --label "$task_label" --limit 1 --json 2>/dev/null) || return 2
  else
    existing=$(task list --label "$task_label" --limit 1 --json 2>/dev/null) || return 2
  fi
  printf '%s' "$existing" | jq -e 'type=="array"' >/dev/null 2>&1 || return 2
  id=$(printf '%s' "$existing" \
    | jq -r 'if length>0 then (.[0].id // empty) else empty end' 2>/dev/null) || id=
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# fm_beads_resolve_or_create <task_id> [title] - beads-authority migration
# Stage 3 (see data/beads-authority-migration-scout/report.md section "Stage
# 3"): under config/backlog-backend=beads, every firstmate task must have a
# linked bead without requiring an explicit --beads flag. Resolves an existing
# OPEN bead via fm_beads_lookup (the home-scoped task:<scope>:<task_id> label) so
# fm-brief.sh and fm-spawn.sh converge on the same bead regardless of call order,
# and mints one with that scoped label plus the fleet label
# (fm_beads_fleet_label) only if none is found. Echoes the resolved bead id on
# success. It never writes to the store on the resolve path, because it runs at
# every brief scaffold and every spawn.
# Fails open like the rest of the beads integration: prints nothing and
# returns 1 on any missing tool or failure, never blocking dispatch.
#
# A CLOSED bead is never adopted. Task ids are reusable slugs, and
# fm-teardown.sh closes a task's bead without stripping its label, so that
# record outlives the task in the federated store forever. Adopting it would
# link brand-new work to a bead that was already closed before the task
# existed - and a closed bead is the authoritative "task complete" signal
# bin/fm-crew-state.sh reads under this backend, so the fresh crew would
# reconcile as done before its worker made a single commit. Omitting --all
# leaves the store's own default filter in place, so closed predecessors are
# excluded server side and no client-side ordering or page depth can decide
# the match.
fm_beads_resolve_or_create() {
  local task_id=$1 title=${2:-"firstmate: $1"} id status
  command -v task >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  id=$(fm_beads_lookup "$task_id")
  status=$?
  if [ "$status" -eq 0 ] && [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  # An unreadable store is not an answer, so minting here would be minting
  # blind beside a bead that may already exist and would then stay open forever.
  # Failing open with no bead keeps the dispatch path unblocked and leaves the
  # next resolve free to find the real one.
  [ "$status" -eq 2 ] && return 1
  fm_beads_mint_task_bead "$task_id" "$title"
}

# fm_beads_mint_task_bead <task_id> [title] [bound] - the single owner of the
# SHAPE a firstmate bead is minted in: the fleet label (fm_beads_fleet_label) so
# `task list --label <fleet>` scopes to firstmate's fleet, plus this home's
# scoped task:<home-scope>:<task_id> idempotency label so the next resolve in
# this home finds it and no other home's resolve does. Echoes the new bead id, or
# prints nothing and returns 1 on any missing tool, unbuildable scope, or store
# failure. An empty title falls back to the same default fm_beads_resolve_or_create
# has always used. The optional bound follows fm_beads_lookup's rule, so the
# migration sweep can mint a task its own replacement bead without escaping the
# budget it runs under.
fm_beads_mint_task_bead() { # <task_id> [title] [bound]
  local task_id=$1 title=${2:-} bound=${3:-} task_label id
  [ -n "$task_id" ] || return 1
  [ -n "$title" ] || title="firstmate: $task_id"
  command -v task >/dev/null 2>&1 || return 1
  task_label=$(fm_beads_task_label "$task_id") || return 1
  if [ -n "$bound" ]; then
    declare -f fm_run_timed >/dev/null 2>&1 || return 1
    id=$(fm_run_timed "$bound" task create --title "$title" \
      --labels "$(fm_beads_fleet_label),$task_label" --silent 2>/dev/null) || return 1
  else
    id=$(task create --title "$title" --labels "$(fm_beads_fleet_label),$task_label" --silent 2>/dev/null) || return 1
  fi
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# fm_beads_status <bead-id> - the single owner of reading one bead's status.
# `task show <id> --json` returns a JSON ARRAY ([{...}]), so the status lives at
# .[0].status; every other bin/ reader of a single bead unwraps it the same way
# (fm-decision-hold.sh, fm-backlog-import-beads.sh). Prints the status token to
# stdout, or nothing when the bead is absent, unreadable, or the tools are
# missing. The read is bounded by FM_BEADS_STATUS_TIMEOUT so a wedged Dolt store
# can never stall a caller on the fleet-snapshot/heartbeat path - the same
# bounded-read discipline as FM_CREW_STATE_NM_TIMEOUT / FM_SNAPSHOT_BEADS_TIMEOUT.
#
# The EXIT STATUS distinguishes the three outcomes a caller must not conflate,
# because "the bead is gone" and "the read never completed" are opposite evidence:
#   0                            the read completed; stdout is the status token
#                                (empty when the record carries none)
#   FM_BEADS_STATUS_RC_ABSENT    the read completed and the bead is not there
#   FM_BEADS_STATUS_RC_UNREADABLE  no answer: timeout, missing tool, missing
#                                bound, unparseable output, or a store that could
#                                not be reached to confirm the bead is gone
#
# `task show` exits non-zero for a missing bead AND for a store that is down,
# locked, or unauthenticated, so a failed read alone cannot distinguish them. Only
# a reachable store turns a failed read into ABSENT: fm_beads_store_reachable
# re-probes with the same `task list --limit 1` liveness predicate the write-queue
# reconcile uses, and an unreachable store keeps the outcome UNREADABLE. The probe
# is paid only on the failure path, never on a successful read.
# Stdout still fails open in every non-zero case (nothing printed), so a caller
# that only reads stdout sees "not closed" / "no evidence" rather than a
# completion; a caller deciding whether a write is already applied must check the
# status too.
#
# The bound comes from fm-timeout-lib.sh, sourced only when it is co-located:
# this library is copied on its own into partially-synced remote code roots
# (bin/fm-remote-doctor.sh, bin/fm-backlog-receive.sh both run there under
# `set -eu`), and an unguarded source would abort those scripts at load time
# instead of letting them reach the report that names what is missing. Without
# the bound, fm_beads_status refuses the read rather than running it unbounded.
_FM_TASKS_AXI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f fm_run_timed >/dev/null 2>&1 && [ -f "$_FM_TASKS_AXI_LIB_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$_FM_TASKS_AXI_LIB_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound
fi
FM_BEADS_STATUS_TIMEOUT=${FM_BEADS_STATUS_TIMEOUT:-4}
case "$FM_BEADS_STATUS_TIMEOUT" in
  ''|*[!0-9]*) FM_BEADS_STATUS_TIMEOUT=4 ;;
  *) [ "$FM_BEADS_STATUS_TIMEOUT" -gt 0 ] 2>/dev/null || FM_BEADS_STATUS_TIMEOUT=4 ;;
esac
FM_BEADS_STATUS_RC_ABSENT=1
FM_BEADS_STATUS_RC_UNREADABLE=2

# fm_beads_store_reachable is defined once, above, as the single owner of the
# `task list --limit 1` liveness predicate that fm_beads_write_queue_reconcile
# gates its whole replay on. It takes an OPTIONAL bound rather than always
# applying one, because its two callers need opposite defaults: the read below
# must never stall the heartbeat and so passes FM_BEADS_STATUS_TIMEOUT
# explicitly, while fm_beads_bootstrap_store's refuse-over-a-live-store guard
# must not read a merely slow store as absent and so stays unbounded. Making
# the bound explicit per call site keeps both guarantees instead of picking a
# default that silently breaks one of them.

fm_beads_status() { # <bead-id> - print the bead's status token, empty if unreadable
  local id=${1:-} out rc status
  [ -n "$id" ] || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  command -v task >/dev/null 2>&1 || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  command -v jq >/dev/null 2>&1 || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  declare -f fm_run_timed >/dev/null 2>&1 || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  out=$(fm_run_timed "$FM_BEADS_STATUS_TIMEOUT" task show "$id" --json 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    fm_beads_store_reachable "$FM_BEADS_STATUS_TIMEOUT" \
      || return "$FM_BEADS_STATUS_RC_UNREADABLE"
    return "$FM_BEADS_STATUS_RC_ABSENT"
  fi
  status=$(printf '%s' "$out" | jq -r '.[0].status // empty' 2>/dev/null) \
    || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  printf '%s\n' "$status"
}

# fm_beads_is_closed <bead-id> - true ONLY when the bead exists and its status is
# closed. This is the authoritative task-completion signal read by
# bin/fm-crew-state.sh under config/backlog-backend=beads: the worker closes its
# linked bead as the terminal lifecycle step before reporting done, and
# fm-teardown.sh/fm-ledger.sh close it on confirmed landing or drop-recovery, so a
# closed bead means the task is complete regardless of a stale status-event tail.
# Distinct from fm-beads-resilience-lib.sh's fm_beads_close_already_applied, which
# treats an ABSENT bead as "already applied" for idempotent write-queue replay:
# here an absent, open, or unreadable bead is NOT closed, so reconciliation falls
# through to the existing pane/run-step logic rather than inventing a completion.
# Reads status through fm_beads_status (the one array-unwrap owner) and treats
# every non-zero read - absent bead as much as an unanswered one - as "not
# closed", so it fails open the same way and never marks live work done.
fm_beads_is_closed() { # <bead-id>
  local id=${1:-} status
  [ -n "$id" ] || return 1
  status=$(fm_beads_status "$id") || return 1
  [ "$status" = closed ]
}
