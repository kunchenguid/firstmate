#!/usr/bin/env bash
# fm-captain-hold.sh - deterministic mechanics for tasks held for the captain.
#
# The semantic policy is owned once by
# .agents/skills/captain-hold-lifecycle/SKILL.md. This script never reads
# report, visual-review, chat, or terminal prose to guess whether the captain
# owes an answer. The invoking agent decides what is genuinely waiting on the
# captain; this script supplies guarded creation, a durable record of what the
# captain actually said, the investigation completion gate, and the one
# keyed-answer intake every channel feeds.
#
# There is no separate decision type. A captain call is an ordinary backlog
# task held for the captain through this script's mandatory `hold` subcommand,
# and its identity is simply the task id. Older installs created derived
# `<origin>-decision-<key>` identities through bin/fm-decision-hold.sh; those
# rows are already plain task ids, so they keep working here unchanged, and
# the legacy inputs noted below resolve them without a migration.
# All backlog reads and mutations address the active home's configured data
# directory the way bin/fm-backlog-transition-lib.sh does, which keeps main-home
# and secondmate-home ownership aligned with the work that discovered the call.
#
# Usage:
#   fm-captain-hold.sh hold <task-id> --reason <reason> \
#     [--title <title>] [--repo <repo>] [--origin <origin-id>] [--until YYYY-MM-DD]
#   fm-captain-hold.sh answer <task-id> --decision-file <path> [--release]
#   fm-captain-hold.sh answers [<legacy-origin> | --any-origin] --source <provenance>   (keyed answers on stdin)
#   fm-captain-hold.sh reconcile-requests --source-id <source-id> --source <provenance>   (task ids on stdin)
#   fm-captain-hold.sh bind <source-id> [<legacy-origin> | --any-origin]
#   fm-captain-hold.sh unbind <source-id>
#   fm-captain-hold.sh binding <source-id>
#   fm-captain-hold.sh complete <origin-id> (--none | <task-id>...)
#   fm-captain-hold.sh verify <origin-id>
#   fm-captain-hold.sh open <task-id>
#   fm-captain-hold.sh diverged
#   fm-captain-hold.sh reconcile list
#   fm-captain-hold.sh reconcile close <task-id> --evidence-file <path>
#   fm-captain-hold.sh reconcile note <task-id> --note-file <path>
#
# `hold` places an existing task under an active captain hold, or creates the
# task first when no work item exists to hold (--title required to create; the
# optional --origin records provenance in the new task's body and supplies the
# default repo from that origin's metadata). Prefer holding the work item the
# question gates over minting a new row. The command records a UTC `Captain
# hold set:` timestamp in the task body: repeating an active hold preserves the
# existing timestamp, while re-holding released work starts a new lifecycle.
# A task already closed is refused rather than reopened. `--until` records the
# captain's own deferral date through `tasks-axi hold --until`, so a "revisit
# later" answer is stored as a date instead of a live card.
#
# `answer` records the captain's exact words and closes the call in the same
# act. It requires a non-empty captain decision file of at most 8192 bytes and
# writes a resolution block while preserving the leading hold-set stamp until
# the close succeeds (the previous body is preserved and archived through
# tasks-axi --archive-body). It then closes the task with `tasks-axi done` - or,
# with `--release`, lifts the hold with `tasks-axi unhold` so a captain-gated
# WORK item resumes instead of closing - and restores resolution-first body
# ordering. An exact retry also completes unfinished ordering normalization and
# is idempotent only when its requested close mode
# matches the newest record; a changed decision or a mode mismatch is rejected.
# A re-held task may record a new answer on top. On a task already closed outside this script,
# `answer` records the missing resolution block (the old `repair` path) only
# when the task still carries the captain-hold provenance tasks-axi preserves
# through a close, so an ordinary finished task cannot be dressed up as an
# answered captain call. A hold that expired by date (`--until` in the past) is
# still answerable: the surviving hold annotations, not tasks-axi's live
# `held:` bit, prove the captain owned it.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer closes its matching captain-held task" is a single
# capability, owned here and nowhere else. `answers` reads
# `<task-id>\t<answer>\t<label>[\t<mode>]` lines on stdin and closes each named
# task through the very same `answer` path above, so every guard applies
# identically no matter which channel the answer arrived on. The key IS the
# task id - no identity arithmetic. The optional fourth field selects the close:
# empty or `done` completes the task, `release` lifts the hold so held work
# resumes; anything else is skipped. A key that names no task, a task that is
# not held for the captain, or a task already closed is reported as `skipped:`
# and feeds nothing. A replayed delivery whose answer digest and requested
# close mode both match the newest record is reported `closed:` and is a no-op;
# a mode mismatch is skipped. The command exits nonzero when any key was
# skipped. `--source` is provenance text recorded in the
# durable decision, never a behavior switch: this command has no per-channel
# branch and no knowledge of chat, review decks, or any transport.
# Legacy input: an optional positional origin (or a stored concrete-origin
# binding) makes a key that names no task fall back to the old
# `<origin>-decision-<key>` identity, so an in-flight pre-collapse channel
# keeps closing its rows; `--any-origin` and the stored `(any)` marker mean
# what an absent origin means and are accepted for the same reason.
#
# RECONCILE IS RESERVED AT THIS INTAKE, NOT FILTERED IN A CHANNEL.
# The exact answer value `reconcile` means "go re-check reality", never "the
# captain answered". `answers` matches it before it reads the close mode,
# visibly refuses it, and never passes it to `answer`, so no channel and no
# card-declared mode can turn it into a close, release, or request. A separate
# `reconcile-requests` intake verifies a captured source's binding before it
# records a durable request under `state/reconcile-requests/`.
#
# `reconcile` is the verify-then-decide half. Both outcomes require the pending
# request created by the captain's board selection. `close` is the moot outcome:
# it requires the evidence that made the call moot, writes a `reconciled` resolution record
# under a `Reconciliation evidence:` label so it can never read as the
# captain's words, and closes the task. `note` is the still-active outcome: it
# appends one dated `Captain hold reconciled:` note and leaves the hold in
# place. A normal answer also retires the request because the call is settled.
# `list` is the read-only enumeration.
# docs/captain-hold-lifecycle.md owns the semantics.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines
# and pipe them here. It must never map keys to tasks, build decision records,
# choose a close mode beyond what its card declared, or close anything itself.
#
# `bind`, `unbind`, and `binding` record that a captured-answer SOURCE feeds
# this intake, for any channel whose answers arrive detached from their origin
# (a process-event source id, for example). The binding is a private record
# under `state/decision-bindings/`; a source with no binding feeds nothing, so
# this whole path is opt-in per source and an unbound source behaves as if it
# did not exist. `bind` deliberately does not require the source to exist yet,
# so a channel can be bound BEFORE it is armed. The optional second argument
# exists only for legacy pre-collapse records and callers: a concrete origin is
# stored verbatim and used as the composition fallback above, and
# `--any-origin` stores the same `(any)` marker a plain `bind <source-id>`
# stores. `binding` prints the stored value verbatim and `answers` accepts it,
# so the process-event runner's feed seam is unchanged.
#
# `complete` is the shared investigation and visual-review completion gate.
# It attests, in the origin task's metadata, the reviewed inventory of
# captain-held tasks that carry the origin's unresolved captain calls.
# `--none` is an explicit semantic attestation that the just-reviewed surface
# has no unresolved captain call, and is refused while the origin still has an
# open keyed status decision. With a non-empty inventory, every listed task is
# verified durable (actively captain-held, or closed with a recorded answer),
# the inventory is unioned idempotently into the metadata, and every still-open
# keyed status decision is transferred to its durable owner with a
# `captain-held [key=...]` status close naming the inventory. Later review
# passes may add ids. A post-teardown visual review can complete against the
# surviving report and tasks without recreating task state.
# `verify` is read-only and is called by scout teardown, so teardown cannot
# erase a source before this gate has succeeded: every recorded inventory
# entry must still be durable and no keyed status decision may be open.
# Metadata compatibility: the attestation keeps the historical
# `decisions_reviewed=1` and `decision_keys=` keys, and an inventory entry that
# names no existing task resolves through the legacy `<origin>-decision-<entry>`
# identity, so pre-collapse metadata written by fm-decision-hold.sh verifies
# unchanged. An entry that exists as a task id is always that task. On the
# Beads backend an attested legacy markdown id that resolves to no task is
# accepted through the migrated row fm-hold-migration produced, found by the
# authoritative evidence first: a row whose notes carry the marker line
# "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>". Only when no row carries that line is the legacy id tried under
# the configured beads prefix, and that name-only guess is accepted solely for
# a single row still held for the captain; two such rows refuse rather than
# attest, and `complete` names each prefix-resolved row beside its attested
# legacy id so the guess stays auditable.
#
# `open` is the read-only predicate a mechanical closer asks before it may
# retire a task's row: is this task still an open captain call? Exit 0 means it
# is (not Done, hold kind captain), 1 means it is not, and 2 means the answer
# could not be established, so a caller that must never close a live call can
# treat "cannot tell" as its own case instead of as a no. With
# `--distinguish-absent`, an absent local task returns 3 instead of 1. It prints
# nothing on these predicate results and mutates nothing. bin/fm-teardown.sh asks it before its automatic
# backlog close and, on 0, returns the row to Queued with its deliverable
# recorded instead (bin/fm-backlog-transition-lib.sh owns that transition), so
# holding the very work item a question gates is safe; only `answer` with the
# captain's words or evidence-backed `reconcile close` closes the call.
# bin/fm-watch.sh asks it for the same
# reason a closer does - the hold is a fact no status line carries - and bounds
# a stale alarm on a 0 rather than re-alarming for the length of the decision.
#
# `diverged` is the read-only guard over the seam between the two records of
# one captain call. See "record divergence" beside command_diverged below.
#
# Resolution records: the block written into the body names this script, the
# decision digest, and a `Resolution mode:` of answered, released, repaired, or
# reconciled. Records written by the retired fm-decision-hold.sh (routed,
# declined, answered, repaired) are recognized everywhere a record is read, so
# nothing already closed needs rewriting.
#
# Parent channel: inside a secondmate home a task held for the captain, and its
# answer, are captain-facing facts the moment they are recorded, so `hold`
# publishes `needs-decision [key=captain-hold-<task>-<n>]` and `answer` (and
# `answers`) the matching `resolved` line on the parent channel through
# bin/fm-parent-channel-lib.sh, whether or not the mate model appends anything.
# <n> is the count of resolution records the body already carries plus one, so
# a released and re-held task opens and closes a distinct parent decision with
# no new persisted state, and an exact retry republishes the same line, which
# the channel deduplicates. A main home has no channel and publishes nothing.
# The hold or answer is already durable in the backlog, so a channel that
# cannot be written is reported as `actionable:` on stderr rather than undoing
# the record; bin/fm-inactive-reconcile.sh's diagnostics name a broken binding.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

PARENT_HOLD_PUBLISHED=0
publish_parent_hold() {  # <task-id> <occurrence> <verb> <note>
  local id=$1 occurrence=$2 verb=$3 note=$4 rc=0
  PARENT_HOLD_PUBLISHED=0
  fm_parent_channel_report "$FM_HOME" "$STATE" \
    "$verb [key=captain-hold-$id-$occurrence]: captain hold $id: $(fm_parent_channel_clean_note "$note")" || rc=$?
  case "$rc" in
    0|1) PARENT_HOLD_PUBLISHED=1 ;;
    *) printf 'actionable: task %s is held for the captain in this home but that did not reach the parent channel (rc=%s)\n' "$id" "$rc" >&2 ;;
  esac
}

CAPTAIN_META_LOCK=
CAPTAIN_META_LOCK_HELD=0
CAPTAIN_CONTROL_LOCK=
CAPTAIN_CONTROL_LOCK_HELD=0
captain_hold_cleanup() {
  if [ "$CAPTAIN_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_META_LOCK" || true
    CAPTAIN_META_LOCK_HELD=0
  fi
  if [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_CONTROL_LOCK" || true
    CAPTAIN_CONTROL_LOCK_HELD=0
  fi
}
trap captain_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

acquire_task_control_lock() {  # <task-id>
  CAPTAIN_CONTROL_LOCK="$STATE/.control-$1.lock"
  fm_lock_acquire_wait "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=1
}

release_task_control_lock() {
  [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=0
  CAPTAIN_CONTROL_LOCK=
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

# The legacy derived identity older installs minted for a captain call.
# Kept only to resolve pre-collapse rows, metadata entries, and channel keys.
legacy_hold_id() {  # <origin-id> <key>
  printf '%s-decision-%s' "$1" "$2"
}

# The legacy any-origin binding marker. Slug validation rejects parentheses, so
# no real origin id or task id can collide with it.
BINDING_ANY='(any)'

DECISION_TEXT=''
DECISION_DIGEST=''

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

# Mutations address the configured data directory's backlog from its root, the
# way bin/fm-backlog-transition-lib.sh addresses every transition, so a home
# with a relocated data directory keeps one backlog. The explicit --file file
# belongs to the markdown backend only; a non-markdown backend is addressed by
# the root's own tasks-axi configuration, exactly like the transition library's
# mutate path.
tasks_axi() {
  local data file root
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  root=$(fm_backlog_root "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    file=$(fm_backlog_file "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
    (cd "$root" && tasks-axi "$@" --file "$file")
  else
    (cd "$root" && tasks-axi "$@")
  fi
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  local data
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  fm_backlog_row_show "$data" "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

decode_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = decode_json(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Decode show-encoded scalar fields and normalize the empty marker.
show_field_value() {  # <show-output> <field>
  local value
  value=$(decode_shown_value "$(show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

# A resolution record written by this script or by the retired
# fm-decision-hold.sh. Both carry the same leader-then-captain-decision shape.
body_has_resolution_record() {  # <task-body>
  case "$1" in
    *"Resolution recorded by fm-captain-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-decision-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"Reconciliation evidence:"*) return 0 ;;
  esac
  return 1
}

# The recorded decision digest of either record format, from the show-escaped
# body (multi-line bodies print as one quoted line with \n escapes). Records
# are prepended, so the first match is the newest record.
recorded_decision_digest() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Decision digest: "*) rest=${rest#*"Decision digest: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

# How many resolution records the shown body carries, in either record format.
resolution_record_count() {  # <task-body>
  local body
  body=$(decode_shown_value "$1") || return 1
  printf '%s\n' "$body" \
    | grep -Ec '^Resolution recorded by fm-(captain|decision)-hold\.$' || true
}

# The newest record's `Resolution mode:` value; empty for a record predating it.
recorded_resolution_mode() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Resolution mode: "*) rest=${rest#*"Resolution mode: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

closed_answer_replay_mode_compatible() {  # <mode> <task-body>
  case "$1" in
    answered|repaired|routed) return 0 ;;
  esac
  return 1
}

# The record's label is what keeps an evidence-backed reconciliation from
# reading as the captain's own words. `reconciled` closes a call that went moot
# and carries verified evidence; every other mode carries what the captain said.
resolution_block() {  # <mode>
  local label='Captain decision:'
  [ "$1" != reconciled ] || label='Reconciliation evidence:'
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: %s\n\n%s\n%s\n' \
    "$DECISION_DIGEST" "$1" "$label" "$DECISION_TEXT"
}

# Durable state of one captain call: an active captain hold (annotations
# surviving even when a date gate has expired) or a recorded captain answer.
verify_hold_durable() {  # <task-id>
  local id=$1 show state hold_kind body
  show=$(task_show "$id") || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if body_has_resolution_record "$body"; then
    return 0
  fi
  if [ "$state" != "done" ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  fail "captain-held task $id is neither held for the captain nor closed with a recorded captain answer"
}

# --- migrated legacy-id resolution on the Beads backend ---------------------
#
# A home that moved its backlog from markdown to Beads no longer carries the
# legacy hold ids a scout report attested: the migration rehomed every held
# row under a prefixed fm- id and recorded its markdown identity in the row's
# notes as "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>" (fm-hold-migration wrote the dated form on 2026-09-04). When an
# attested legacy id resolves to no task, the beads backend accepts the row the
# migration produced, found by scanning the configured graph's notes for either
# form of that marker line, and only when no row carries the marker by
# prepending the configured prefix to the legacy id - a name-only guess, so it
# is accepted solely for a row still held for the captain and only when it is
# the single such row. A markdown home keeps its legacy rows verbatim, so its
# exact-id resolution is unchanged.

CAPTAIN_MIGRATION_SCAN_LOADED=0
CAPTAIN_MIGRATION_SCAN_JSON=
NL_SEP=$'\n'

# Section-aware [beads] extraction from a .tasks.toml: only keys inside the
# [beads] section, comments stripped. Prints "<key> <value>" lines.
captain_beads_toml_entries() {  # <toml-file>
  [ -f "$1" ] || return 0
  LC_ALL=C awk '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    BEGIN { inbeads = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { inbeads = (line == "[beads]"); next }
      if (!inbeads) next
      if (line ~ /^(prefix|path|binary)[[:space:]]*=/) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "%s %s\n", key, line
      }
    }
  ' "$1"
}

captain_beads_setting() {  # <entries-output> <setting>
  printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1
}

# Read the configured beads graph's row listing for a migration-note scan.
# The listing is deliberately re-read per unresolvable key: the cache below
# lives and dies with the command-substitution subshell every resolve_entry
# call site runs in, so it cannot persist across keys - bounded by a scout
# report's handful of attested ids. Returns 0 when the listing loads, and 2
# with the reason on stderr when the graph cannot be read.
captain_migration_scan_load() {  # <resolved-data-dir>
  local data=$1 root entries bd_bin bd_path
  [ "$CAPTAIN_MIGRATION_SCAN_LOADED" = 1 ] && return 0
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the configured data directory cannot be resolved for a migration scan: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  }
  if [ "$(fm_tasks_axi_backend "$root")" != beads ]; then
    CAPTAIN_MIGRATION_SCAN_LOADED=1
    return 0
  fi
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  bd_bin=$(captain_beads_setting "$entries" binary)
  bd_path=$(captain_beads_setting "$entries" path)
  bd_bin=${bd_bin:-bd}
  if [ -z "$bd_path" ]; then
    printf 'fm-captain-hold: the beads backend carries no graph path in %s, so a migrated hold cannot be found\n' "$root/.tasks.toml" >&2
    return 2
  fi
  # A relative [beads] path resolves against the backlog root, the same rule
  # every other .tasks.toml path consumer uses, never against the process CWD.
  case "$bd_path" in
    /*) ;;
    *) bd_path="$root/$bd_path" ;;
  esac
  command -v "$bd_bin" >/dev/null 2>&1 || {
    printf 'fm-captain-hold: the beads binary %s is not on PATH, so a migrated hold cannot be found\n' "$bd_bin" >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-captain-hold: jq is required to scan the beads graph for a migrated hold\n' >&2
    return 2
  }
  local bd_err
  bd_err=$(mktemp "${TMPDIR:-/tmp}/fm-captain-hold-bd.XXXXXX") || {
    printf 'fm-captain-hold: cannot stage the beads graph read diagnostics\n' >&2
    return 2
  }
  if ! CAPTAIN_MIGRATION_SCAN_JSON=$(BEADS_DIR="$bd_path" "$bd_bin" list --all --json 2>"$bd_err"); then
    printf 'fm-captain-hold: reading the beads graph at %s failed (%s), so a migrated hold cannot be found\n' \
      "$bd_path" "$(sanitize_field "$(head -c 200 "$bd_err" | tr '\n' ' ')")" >&2
    rm -f "$bd_err"
    return 2
  fi
  rm -f "$bd_err"
  CAPTAIN_MIGRATION_SCAN_LOADED=1
  return 0
}

# Resolve one attested legacy id to the migrated row that carries it on the
# beads backend. Prints "<row id> <how>" and returns 0 when exactly one
# migration matches, returns 1 when none does, and returns 2 with the reason on
# stderr when the scan itself cannot run or is ambiguous. The marker note is the
# authoritative evidence and is scanned first; the bare configured prefix is a
# guess, so it only runs when no marker line matches any identity and it accepts
# a row solely when that row is itself still held for the captain.
resolve_migrated_entry() {  # <origin-or-empty> <entry>
  local origin=$1 entry=$2 data root entries prefix derived show
  local candidate candidate_matches prefixed matches count prefixed_matches prefixed_count
  data=$(fm_backlog_data_absolute "$DATA") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  [ "$(fm_tasks_axi_backend "$root")" = beads ] || return 1
  # Every identity this entry could have been migrated under: the raw entry,
  # and - for a pre-collapse channel key - the derived legacy identity its
  # origin would have minted, because fm-hold-migration recorded the DERIVED
  # id in each migrated row's marker note.
  CAPTAIN_MIGRATION_IDENTITIES=$entry
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    derived=$(legacy_hold_id "$origin" "$entry")
    if [ "$derived" != "$entry" ]; then
      CAPTAIN_MIGRATION_IDENTITIES="$CAPTAIN_MIGRATION_IDENTITIES $derived"
    fi
  fi
  captain_migration_scan_load "$data" || return 2
  matches=
  if [ -n "$CAPTAIN_MIGRATION_SCAN_JSON" ]; then
    for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
      candidate_matches=$(printf '%s\n' "$CAPTAIN_MIGRATION_SCAN_JSON" | jq -r \
        --arg exact "migrated from data/backlog.md id $candidate" \
        --arg dated "migrated from data/backlog.md id $candidate on " \
        '.[] | select(((.notes // "") | split("\n")) | any(. == $exact or startswith($dated))) | .id' 2>/dev/null) || {
        printf 'fm-captain-hold: the beads graph scan for the migrated hold of %s could not be parsed\n' "$candidate" >&2
        return 2
      }
      matches="${matches}${matches:+$NL_SEP}${candidate_matches}"
    done
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$count" in
      0) : ;;
      1) printf '%s migrated-note' "$(printf '%s\n' "$matches" | sed '/^$/d' | sed -n 1p)"; return 0 ;;
      *)
        printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s rows carry its marker line (identities tried: %s)\n' \
          "$entry" "$count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
        return 2
        ;;
    esac
  fi
  # No marker line anywhere: a mechanical migration keeps the legacy id under
  # the configured prefix, but that name alone is evidence of nothing, so only
  # a row still held for the captain - and only one of them - is accepted.
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  prefix=$(captain_beads_setting "$entries" prefix)
  [ -n "$prefix" ] || return 1
  prefixed_matches=
  for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
    case "$prefix" in
      *-) prefixed="$prefix$candidate" ;;
      *) prefixed="$prefix-$candidate" ;;
    esac
    show=$(task_show "$prefixed" 2>/dev/null) || continue
    [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
    prefixed_matches="${prefixed_matches}${prefixed_matches:+$NL_SEP}$prefixed"
  done
  prefixed_count=$(printf '%s\n' "$prefixed_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$prefixed_count" in
    0) return 1 ;;
    1) printf '%s migrated-prefix' "$prefixed_matches"; return 0 ;;
  esac
  printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s captain-held rows carry the configured prefix (identities tried: %s)\n' \
    "$entry" "$prefixed_count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
  return 2
}

# Resolve one inventory entry or channel key to the task that carries it: the
# exact task id when it exists, else the legacy derived identity, else - on the
# beads backend - the migrated row the markdown-to-beads hold migration wrote.
# Prints "<resolved id> <how>", where <how> is exact, legacy, migrated-note or
# migrated-prefix, so a caller can record which evidence carried the attestation.
resolve_entry() {  # <origin-or-empty> <entry>; prints "<id> <how>" or fails
  local origin=$1 entry=$2 legacy migrated rc
  if task_show "$entry" >/dev/null 2>&1; then
    printf '%s exact' "$entry"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if task_show "$legacy" >/dev/null 2>&1; then
      printf '%s legacy' "$legacy"
      return 0
    fi
  fi
  rc=0
  migrated=$(resolve_migrated_entry "$origin" "$entry") || rc=$?
  case "$rc" in
    0) printf '%s' "$migrated"; return 0 ;;
    2) return 2 ;;
  esac
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA); the nearest legacy identity $legacy also resolves to nothing"
  fi
  fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA)"
}

body_hold_set_timestamp() {  # <decoded-task-body>
  printf '%s\n' "$1" \
    | sed -n \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\)$/\1/p' \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | head -1
}

write_hold_set_stamp() {  # <task-id> <shown-body> <timestamp> <preserve-existing-0-or-1>
  local id=$1 body=$2 hold_set=$3 preserve=$4 existing new_body tmp
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  existing=$(body_hold_set_timestamp "$body")
  if [ "$preserve" = 1 ] && [ -n "$existing" ]; then
    return 0
  fi
  if [ -n "$existing" ]; then
    body=${body#"Captain hold set: $existing"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
  fi
  new_body=$(printf 'Captain hold set: %s' "$hold_set")
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-stamp.XXXXXX") \
    || fail "cannot stage the hold-set stamp"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold-set stamp for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the hold-set stamp on $id"
  fi
  rm -f -- "$tmp"
}

command_hold() {
  local id=${1:-} title='' reason='' repo='' origin='' until='' show state existing_title body='' hold_kind hold_set occurrence
  local existing_hold_kind='' existing_held='' preserve_hold_set=0
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --origin) shift; origin=${1:-} ;;
      --until) shift; until=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  if [ -n "$origin" ]; then
    validate_slug origin-id "$origin"
  fi
  if [ -n "$until" ]; then
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) fail "--until must be a YYYY-MM-DD date: $until" ;;
    esac
  fi
  hold_set=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$hold_set" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "FM_CAPTAIN_HOLD_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  acquire_task_control_lock "$id"
  require_tasks_axi
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    [ "$state" != "done" ] \
      || fail "task $id is already closed; a new captain call needs its own task"
    existing_hold_kind=$(show_field_value "$show" hold_kind)
    existing_held=$(show_field_value "$show" held)
    if [ "$existing_hold_kind" = captain ] && [ "$existing_held" = yes ]; then
      preserve_hold_set=1
    fi
    if [ -n "$title" ]; then
      existing_title=$(show_field_value "$show" title)
      [ "$existing_title" = "$title" ] || fail "existing task $id has a different title"
    fi
  else
    [ -n "$title" ] || fail "--title is required to create task $id"
    validate_one_line title "$title"
    if [ -z "$repo" ] && [ -n "$origin" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    [ -z "$origin" ] || body=$(printf 'Origin: %s' "$origin")
    if [ -n "$body" ]; then
      tasks_axi add "$id" "$title" --repo "$repo" --body "$body" >/dev/null \
        || fail "could not create task $id"
    else
      tasks_axi add "$id" "$title" --repo "$repo" >/dev/null \
        || fail "could not create task $id"
    fi
  fi
  # Publish the timestamp before the captain-hold annotation. A concurrent
  # snapshot may see the harmless stamp by itself, but can never see a newly
  # held task without the timestamp that defines this hold lifecycle's age.
  show=$(task_show "$id") || fail "task $id disappeared before recording its hold-set stamp"
  write_hold_set_stamp "$id" "$(show_field "$show" body)" "$hold_set" "$preserve_hold_set"
  show=$(task_show "$id") || fail "task $id disappeared while recording its hold-set stamp"
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id did not retain its hold-set stamp"
  if [ -n "$until" ]; then
    tasks_axi hold "$id" --reason "$reason" --kind captain --until "$until" >/dev/null \
      || fail "could not hold task $id for the captain"
  else
    tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
      || fail "could not hold task $id for the captain"
  fi
  show=$(task_show "$id") || fail "task $id disappeared while holding it"
  hold_kind=$(show_field_value "$show" hold_kind)
  [ "$hold_kind" = captain ] || fail "task $id did not retain its captain hold"
  occurrence=$(( $(resolution_record_count "$(show_field "$show" body)") + 1 ))
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id lost its hold-set stamp while being held"
  publish_parent_hold "$id" "$occurrence" needs-decision "$reason"
  printf '%s\n' "$id"
}

# Record a resolution block beneath any leading active hold-set stamp,
# preserving the previous body below it and archiving the pristine original.
# Successful closure removes the stamp to restore resolution-first ordering.
write_resolution_record() {  # <task-id> <mode> <shown-body>
  local id=$1 mode=$2 body=$3 new_body tmp hold_set
  new_body=$(resolution_block "$mode")
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  hold_set=$(body_hold_set_timestamp "$body")
  if [ -n "$hold_set" ]; then
    body=${body#"Captain hold set: $hold_set"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
    new_body=$(printf 'Captain hold set: %s\n\n%s' "$hold_set" "$new_body")
  fi
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-body.XXXXXX") \
    || fail "cannot stage the resolution record"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the resolution record for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the captain decision on $id"
  fi
  rm -f -- "$tmp"
}

close_answered() {  # <task-id> <release-0-or-1>
  if [ "$2" = 1 ]; then
    tasks_axi unhold "$1" >/dev/null
  else
    tasks_axi "done" "$1" >/dev/null
  fi
}

remove_interrupted_answer_stamp() {  # <task-id>
  local id=$1 show body existing tmp
  show=$(task_show "$id") || fail "task $id disappeared after closing"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the closed body for $id"
  existing=$(body_hold_set_timestamp "$body")
  [ -n "$existing" ] || return 0
  body=${body#"Captain hold set: $existing"}
  case "$body" in
    $'\n\n'*) body=${body#$'\n\n'} ;;
    $'\n'*) body=${body#$'\n'} ;;
  esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-normalize.XXXXXX") \
    || fail "cannot stage the closed body for $id"
  if ! printf '%s\n' "$body" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not restore the resolution record ordering for $id"
  fi
  rm -f -- "$tmp"
}

command_answer() {
  local id=${1:-} decision_file='' release=0 show state hold_kind body outcome recorded_mode occurrence
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --release) release=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  load_decision "$decision_file"
  acquire_task_control_lock "$id"
  require_tasks_axi
  show=$(task_show "$id") || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$release" = 1 ]; then outcome=released; else outcome=answered; fi
  # The occurrence the parent line names: the record about to be written is
  # one past those already in the body, and a retry names the newest one.
  occurrence=$(( $(resolution_record_count "$body") + 1 ))

  if [ "$state" = "done" ]; then
    if body_has_resolution_record "$body"; then
      # An exact compatible retry is an idempotent no-op; drift is rejected.
      [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
        || fail "captain-held task $id records a different captain decision"
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      closed_answer_replay_mode_compatible "$recorded_mode" "$body" \
        || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay"
      [ "$release" = 0 ] \
        || fail "task $id records this answer with mode ${recorded_mode:-unknown}; --release cannot reopen a closed task"
      remove_interrupted_answer_stamp "$id"
      if [ "$recorded_mode" = repaired ]; then
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "answered (repaired)"
      else
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) answered
      fi
      printf 'answered: %s\n' "$id"
      return 0
    fi
    [ "$release" = 0 ] || fail "task $id is already closed; --release cannot reopen it"
    # Closed outside this script: record the captain's answer retroactively.
    # tasks-axi keeps hold_kind through a close, so it is the surviving proof
    # this really was the captain's item rather than ordinary finished work.
    [ "$hold_kind" = captain ] \
      || fail "task $id was never held for the captain; nothing to record an answer on"
    write_resolution_record "$id" repaired "$body"
    remove_interrupted_answer_stamp "$id"
    show=$(task_show "$id") || fail "task $id disappeared while recording the answer"
    [ "$(show_field "$show" state)" = "done" ] || fail "recording the answer reopened closed task $id"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)"
    printf 'repaired: %s\n' "$id"
    return 0
  fi

  if [ "$hold_kind" = captain ]; then
    # Actively the captain's item (a date-expired hold keeps its annotations
    # and stays answerable). A matching record means an interrupted close to
    # finish; a different digest is a NEW answer on a re-held task and gets
    # its own record on top. Either way the close mode is the caller's flag,
    # checked against an interrupted close's recorded mode so a retry cannot
    # silently flip a release into a close.
    if body_has_resolution_record "$body" \
      && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      case "$recorded_mode" in
        released) [ "$release" = 1 ] || fail "task $id records this answer as a release; retry with --release" ;;
        answered|routed) [ "$release" = 0 ] || fail "task $id records this answer as a close; retry without --release" ;;
        *) fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay" ;;
      esac
      if ! close_answered "$id" "$release"; then
        fail "could not close answered captain-held task $id"
      fi
      remove_interrupted_answer_stamp "$id"
      publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "$outcome"
      printf '%s: %s\n' "$outcome" "$id"
      return 0
    fi
    write_resolution_record "$id" "$outcome" "$body"
    if ! close_answered "$id" "$release"; then
      fail "could not close answered captain-held task $id"
    fi
    remove_interrupted_answer_stamp "$id"
    show=$(task_show "$id") || fail "task $id disappeared after closing"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "$outcome"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi

  # Not held and not closed: only an already-recorded release replays cleanly.
  if body_has_resolution_record "$body"; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different captain decision with mode ${recorded_mode:-unknown}"
    [ "$recorded_mode" = released ] && [ "$release" = 1 ] \
      || fail "task $id records this answer with mode ${recorded_mode:-unknown}; replay requires matching --release"
    remove_interrupted_answer_stamp "$id"
    publish_parent_resolution_then_retire "$id" $((occurrence - 1)) released
    printf 'released: %s\n' "$id"
    return 0
  fi
  fail "task $id is not held for the captain; hold it first or name the right task"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The stored binding value, or empty when the source is unbound. An unreadable
# or wrong-schema record is a hard error rather than a silent "unbound":
# feeding nothing is the safe direction only when it is a deliberate choice,
# never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  if [ "$origin" != "$BINDING_ANY" ]; then
    case "$origin" in
      ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
    esac
  fi
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  if [ -z "$origin" ] || [ "$origin" = --any-origin ]; then
    origin=$BINDING_ANY
  else
    validate_slug legacy-origin "$origin"
  fi
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <task-id> <answer> <label>
  printf 'Captain answered this call through %s.\n' "$1"
  printf 'Task: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

legacy_keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

sanitize_reconcile_provenance() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-1024
}

command_answers() {
  local origin='' source='' row rest key answer label mode id show state hold_kind body digest legacy_digest legacy_key
  local recorded_digest recorded_mode occurrence tmp err closed=0 skipped=0 reason release_flag tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      --any-origin) origin=$BINDING_ANY ;;
      --*) usage >&2; exit 2 ;;
      *)
        [ -z "$origin" ] || { usage >&2; exit 2; }
        origin=$1
        ;;
    esac
    shift
  done
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    validate_slug legacy-origin "$origin"
  fi
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS= read -r row; do
    key=${row%%"$tab"*}
    rest=''
    case "$row" in *"$tab"*) rest=${row#*"$tab"} ;; esac
    answer=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    label=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) mode=${rest#*"$tab"} ;; *) mode='' ;; esac
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 128 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    if [ "$answer" = "$RECONCILE_VALUE" ]; then
      printf 'refused: %s (reconcile requests require a bound captured source)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    release_flag=''
    case "${mode:-}" in
      ''|done) : ;;
      release) release_flag=--release ;;
      *)
        printf 'skipped: %s (unknown close mode %s)\n' "$key" "$(sanitize_field "$mode")"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    resolve_rc=0
    id=$(resolve_entry "$origin" "$key" 2>"$err") || resolve_rc=$?
    id=${id%% *}
    if [ "$resolve_rc" = 2 ]; then
      reason=$(tr -d '\n' < "$err")
      printf 'skipped: %s (migrated-hold scan refused%s)\n' "$key" "${reason:+: $reason}"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$resolve_rc" -ne 0 ]; then
      printf 'skipped: %s (no captain-held task with that id)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    keyed_decision_text "$source" "$id" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $id"
    digest=$(sha256_text "$(cat "$tmp")")
    legacy_digest=''
    if [ "$id" != "$key" ]; then
      legacy_key=$key
    elif { [ -z "$origin" ] || [ "$origin" = "$BINDING_ANY" ]; } \
      && [ "${id#*-decision-}" != "$id" ]; then
      legacy_key=${id#*-decision-}
    else
      legacy_key=''
    fi
    if [ -n "$legacy_key" ]; then
      legacy_digest=$(sha256_text "$(legacy_keyed_decision_text "$source" "$legacy_key" "$answer" "$label")")
    fi
    show=$(task_show "$id") || { printf 'skipped: %s (absent)\n' "$id"; skipped=$((skipped + 1)); continue; }
    state=$(show_field "$show" state)
    hold_kind=$(show_field_value "$show" hold_kind)
    body=$(show_field "$show" body)
    recorded_digest=$(recorded_decision_digest "$body" || true)
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    if body_has_resolution_record "$body" \
      && { [ "$recorded_digest" = "$digest" ] \
        || { case "$body" in *"Resolution recorded by fm-decision-hold."*) true ;; *) false ;; esac \
          && [ -n "$legacy_digest" ] && [ "$recorded_digest" = "$legacy_digest" ]; }; }; then
      if { [ -z "$release_flag" ] && [ "$state" = "done" ] \
          && closed_answer_replay_mode_compatible "$recorded_mode" "$body"; } \
        || { [ "$release_flag" = --release ] && [ "$state" != "done" ] \
          && [ "$hold_kind" != captain ] && [ "$recorded_mode" = released ]; }; then
        occurrence=$(resolution_record_count "$body")
        case "$recorded_mode" in
          repaired) publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)" ;;
          released) publish_parent_resolution_then_retire "$id" "$occurrence" released ;;
          *) publish_parent_resolution_then_retire "$id" "$occurrence" answered ;;
        esac
        printf 'closed: %s\n' "$id"
        closed=$((closed + 1))
        continue
      fi
    fi
    if [ "$state" = "done" ]; then
      printf 'skipped: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$hold_kind" != captain ]; then
      printf 'skipped: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    # shellcheck disable=SC2086  # release_flag is empty or a single literal flag.
    if "$0" answer "$id" --decision-file "$tmp" $release_flag </dev/null >/dev/null 2>"$err"; then
      # A parent-channel delivery problem is reported on stderr by the answer
      # path even when the close succeeded; keep it visible.
      [ ! -s "$err" ] || cat "$err" >&2
      printf 'closed: %s\n' "$id"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-captain-hold: //')
      printf 'skipped: %s (%s)\n' "$id" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s skipped=%s\n' "$closed" "$skipped"
  [ "$skipped" -eq 0 ]
}

# --- reconcile: verify latest state, then close with evidence or annotate ----
#
# The semantics are owned by docs/captain-hold-lifecycle.md; this section owns
# the durable record and the two terminal operations that retire it. Nothing
# here closes a captain call on the strength of a reconcile alone: `close`
# demands the evidence that made the call moot, and `note` leaves it open.

RECONCILE_DIR="$STATE/reconcile-requests"
RECONCILE_SCHEMA=fm-reconcile-request.v1
RECONCILE_VALUE=reconcile

reconcile_request_path() { printf '%s/%s.request\n' "$RECONCILE_DIR" "$1"; }

# Idempotent per task: a repeated reconcile keeps the one request and its
# original timestamp, so a re-delivered board answer never resets the clock on
# an obligation that is already open.
reconcile_request_record() {  # <task-id> <provenance>
  local id=$1 source=$2 path tmp
  path=$(reconcile_request_path "$id")
  [ ! -e "$path" ] || return 0
  (umask 077; mkdir -p "$RECONCILE_DIR") || return 1
  [ -d "$RECONCILE_DIR" ] && [ ! -L "$RECONCILE_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$RECONCILE_DIR/.request.XXXXXX") || return 1
  if {
    printf 'schema=%s\n' "$RECONCILE_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'requested=%s\n' "${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf 'source=%s\n' "$(sanitize_reconcile_provenance "$source")"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

reconcile_request_read() {  # <task-id>; sets RECONCILE_REQUESTED/RECONCILE_SOURCE
  local id=$1 path schema task
  path=$(reconcile_request_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$RECONCILE_SCHEMA" ] || fail "reconcile request has an incompatible schema: $path"
  task=$(sed -n 's/^task=//p' "$path" | head -1)
  [ "$task" = "$id" ] || fail "reconcile request names a different task: $path"
  RECONCILE_REQUESTED=$(sed -n 's/^requested=//p' "$path" | head -1)
  RECONCILE_SOURCE=$(sed -n 's/^source=//p' "$path" | head -1)
}

reconcile_request_retire() {  # <task-id>
  rm -f -- "$(reconcile_request_path "$1")" \
    || fail "could not retire the pending reconcile request for $1"
}

publish_parent_resolution_then_retire() {  # <task-id> <occurrence> <note>
  local id=$1 occurrence=$2 note=$3 request
  request=$(reconcile_request_path "$id")
  publish_parent_hold "$id" "$occurrence" resolved "$note"
  if [ -e "$request" ] && [ "$PARENT_HOLD_PUBLISHED" != 1 ]; then
    fail "could not publish the answered captain-held task $id to its parent"
  fi
  reconcile_request_retire "$id"
}

command_reconcile_requests() {
  local source_id='' source='' origin row id note provenance show created=0 skipped=0 tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) shift; source_id=${1:-} ;;
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_source_id "$source_id"
  [ -n "$source" ] || fail "--source provenance is required"
  origin=$(read_binding "$source_id") || fail "cannot verify the binding for source $source_id"
  [ -n "$origin" ] || fail "source $source_id is not bound; no reconcile requests were created"
  require_tasks_axi
  while IFS= read -r row; do
    id=${row%%"$tab"*}
    note=''
    case "$row" in *"$tab"*) note=${row#*"$tab"} ;; esac
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*) printf 'refused: %s (invalid task id)\n' "$id"; skipped=$((skipped + 1)); continue ;;
    esac
    [ "${#id}" -le 128 ] \
      || { printf 'refused: %s (task id is too long)\n' "$id"; skipped=$((skipped + 1)); continue; }
    acquire_task_control_lock "$id"
    show=$(task_show "$id") || true
    if [ -z "$show" ]; then
      printf 'refused: %s (absent)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field "$show" state)" = "done" ]; then
      printf 'refused: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field_value "$show" hold_kind)" != captain ]; then
      printf 'refused: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
    else
      provenance=$source
      [ -z "$note" ] || provenance="$source; captain note: $(sanitize_field "$note")"
      if reconcile_request_record "$id" "$provenance"; then
        printf 'reconcile: %s\n' "$id"
        created=$((created + 1))
      else
        printf 'refused: %s (cannot record the reconcile request)\n' "$id"
        skipped=$((skipped + 1))
      fi
    fi
    release_task_control_lock || fail "cannot release task control for $id"
  done
  printf 'reconcile-requests: created=%s skipped=%s\n' "$created" "$skipped"
  [ "$skipped" -eq 0 ]
}

command_reconcile() {
  local action=${1:-}
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$action" in
    list)    reconcile_list "$@" ;;
    close)   reconcile_close "$@" ;;
    note)    reconcile_note "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

reconcile_list() {
  local path id count=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$RECONCILE_DIR" ] || { printf 'reconcile-requests: 0\n'; return 0; }
  for path in "$RECONCILE_DIR"/*.request; do
    [ -e "$path" ] || continue
    id=${path##*/}; id=${id%.request}
    RECONCILE_REQUESTED=''
    RECONCILE_SOURCE=''
    reconcile_request_read "$id" || continue
    printf '%s\trequested=%s\tsource=%s\n' "$id" "$RECONCILE_REQUESTED" "$RECONCILE_SOURCE"
    count=$((count + 1))
  done
  printf 'reconcile-requests: %s\n' "$count"
}

# The moot outcome. The evidence is what closes the call, and the `reconciled`
# resolution mode is what keeps the record from claiming the captain answered.
reconcile_close() {
  local id=${1:-} evidence_file='' show state hold_kind body occurrence recorded_mode
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence-file) shift; evidence_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$evidence_file" ] || fail "--evidence-file is required; a moot call closes on evidence, never on assertion"
  load_decision "$evidence_file"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  show=$(task_show "$id") || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  occurrence=$(( $(resolution_record_count "$body") + 1 ))
  if [ "$state" = "done" ]; then
    # An exact retry finishes an interrupted close and stays idempotent; a
    # different evidence text on an already closed call is refused.
    body_has_resolution_record "$body" \
      || fail "task $id is already closed with no resolution record; use answer to record what closed it"
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different resolution; it cannot be reconciled again"
    [ "$(recorded_resolution_mode "$body" || true)" = reconciled ] \
      || fail "task $id was not closed by reconciliation"
    occurrence=$(resolution_record_count "$body")
    remove_interrupted_answer_stamp "$id"
    publish_parent_hold "$id" "$occurrence" resolved reconciled
    [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
      || fail "could not publish the reconciled captain-held task $id to its parent"
    reconcile_request_retire "$id"
    printf 'reconciled: %s\n' "$id"
    return 0
  fi
  [ "$hold_kind" = captain ] \
    || fail "task $id is not held for the captain; there is no captain call to reconcile"
  if body_has_resolution_record "$body" \
    && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$recorded_mode" = reconciled ] \
      || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a reconciliation retry"
    occurrence=$(resolution_record_count "$body")
  else
    write_resolution_record "$id" reconciled "$body"
  fi
  close_answered "$id" 0 || fail "could not close reconciled captain-held task $id"
  remove_interrupted_answer_stamp "$id"
  show=$(task_show "$id") || fail "task $id disappeared after closing"
  body_has_resolution_record "$(show_field "$show" body)" \
    || fail "captain-held task $id did not retain its durable resolution record"
  publish_parent_hold "$id" "$occurrence" resolved reconciled
  [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
    || fail "could not publish the reconciled captain-held task $id to its parent"
  reconcile_request_retire "$id"
  printf 'reconciled: %s\n' "$id"
}

# The still-active outcome. The hold survives, so the call stays the captain's
# and stays on Captain's Call, now carrying what the re-check found.
reconcile_note() {
  local id=${1:-} note_file='' note show body stamp tmp note_digest marker
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-file) shift; note_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$note_file" ] || fail "--note-file is required; leaving a call open records what the re-check found"
  [ -f "$note_file" ] || fail "note file does not exist: $note_file"
  note=$(cat "$note_file")
  [ -n "$note" ] || fail "note file must not be empty"
  [ "$(printf '%s' "$note" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "note file exceeds 8192 bytes"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  command_open "$id" \
    || fail "task $id is not an open captain call; a note cannot keep a closed call open"
  show=$(task_show "$id") || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  note_digest=$(sha256_text "$note")
  marker="Reconcile request: $RECONCILE_REQUESTED | $RECONCILE_SOURCE | note digest: $note_digest"
  case "$body" in
    *"$marker"*)
      reconcile_request_retire "$id" \
        || fail "could not retire the applied reconcile request for $id"
      command_open "$id" || fail "recording the reconcile note released captain-held task $id"
      printf 'still-open: %s\n' "$id"
      return 0
      ;;
  esac
  stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-note.XXXXXX") \
    || fail "cannot stage the reconcile note"
  if ! printf '%s\n\nCaptain hold reconciled: %s\n%s\n%s\n' "$body" "$stamp" "$marker" "$note" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the reconcile note for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the reconcile note on $id"
  fi
  rm -f -- "$tmp"
  reconcile_request_retire "$id" \
    || fail "could not retire the applied reconcile request for $id"
  command_open "$id" || fail "recording the reconcile note released captain-held task $id"
  printf 'still-open: %s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' entry key status_file open raw_open has_meta=0 transfer_rc resolved
  local resolved_how attested_by_prefix=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    CAPTAIN_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with task ids"
      validate_slug task-id "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if ! resolved=$(resolve_entry "$origin" "$entry"); then
        # resolve_entry has already refused on stderr naming the entry.
        exit 1
      fi
      resolved_how=${resolved##* }
      resolved=${resolved%% *}
      verify_hold_durable "$resolved"
      if [ "$resolved_how" = migrated-prefix ]; then
        attested_by_prefix="${attested_by_prefix}${attested_by_prefix:+ }$entry=$resolved"
      fi
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  if [ -n "$open" ] && [ -z "$keys" ]; then
    fail "origin $origin still has open captain decisions in its status stream; hold a captain task for what remains, or answer them, before attesting --none"
  fi

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    fm_lock_release "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=0

    # Transfer every still-open status decision to the durable captain-held
    # inventory so the live status fold does not duplicate the same Captain's
    # Call item. The transfer line is this home's own bookkeeping close,
    # written by the turn that just reviewed the inventory, so it uses the
    # guarded self-announced append (bin/fm-wake-lib.sh) and does not wake this
    # same session; an append failure still fails this command loudly.
    if [ -n "$keys" ]; then
      while IFS=$'\t' read -r key _verb _summary; do
        [ -n "$key" ] || continue
        transfer_rc=0
        fm_wake_status_append_self_announced "$STATE" "$status_file" \
          "captain-held [key=$key]: tracked by $keys" || transfer_rc=$?
        [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin/$key"
      done <<EOF
$raw_open
EOF
    fi
  fi
  printf 'complete: %s captain-call inventory reviewed%s%s\n' "$origin" "${keys:+ ($keys)}" \
    "${attested_by_prefix:+ [attested through the configured prefix: $attested_by_prefix]}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys entry key open resolved
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed captain-call inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if ! resolved=$(resolve_entry "$origin" "$entry"); then
        # resolve_entry has already refused on stderr naming the entry.
        exit 1
      fi
      verify_hold_durable "${resolved%% *}"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    fail "open captain decision $origin/$key is not transferred to the captain-held inventory; re-run complete"
  done <<EOF
$open
EOF
  printf 'verified: %s captain-call inventory\n' "$origin"
}

# --- record divergence ------------------------------------------------------
#
# A captain call can be written down twice, and until now nothing said when
# those two records disagreed. A `resolved [key=...]` line closes the status-log
# fold outright; the structured captain-held task is closed by a SEPARATE act
# (`answer` above). Closing only on the status side therefore looks complete
# there while the durable record still says the captain owes an answer and
# keeps resurfacing it. The defect was never the separation; it was the silence.
#
# `diverged` is a read-only report of that contradiction and nothing else. It
# closes NOTHING. A captain call closed wrongly disappears without review, which
# is strictly worse than the noise this prints, so reconciling a divergence stays
# a human-owned act - and it runs in either direction: record what the captain
# actually said with `answer`, or re-open the status decision when that
# resolution was not the captain's word.
#
# What it flags, and only this: a task that is still open and still carries the
# captain-hold annotations, whose key was closed on the status side by the
# RESOLVE verb. The other closing verb is not a divergence: a `captain-held`
# close is the VERIFIED transfer to that very task, written by command_complete
# only after verifying it, so the structured row staying open behind it is the
# correct state. Neither is a still-open status decision - the OPEN DECISIONS
# fold already owns that one.
#
# Routed work is deliberately irrelevant. When the decision IS the deliverable
# there is nothing to route, so the test is only whether the status side already
# declared this task's key resolved.
# Nor does the report interpret why that resolution exists. A call can turn out
# not to be a captain arbitration at all - a premise can dissolve, or a question
# of fact can prove its first reading wrong - so the report says only that the
# two records disagree and names both reconciliation directions above.
#
# Cost stays flat on a healthy home: one `tasks-axi list`, one key scan per
# status log, and the precise per-key fold only for a key that already names a
# still-open task. If tasks-axi is unavailable or its listing cannot be parsed,
# the guard cannot read the structured record and prints nothing.
#
# Output: one `<task-id>\t<origin>\t<key>\t<title>` line per divergence, in
# status-log then key order; nothing when the two records agree.

# Every still-open task id in this home's backlog, one per line. Only the first
# two comma-separated listing fields are read - both are slugs that precede any
# quoted title - so a title containing commas or quotes cannot shift them.
open_task_ids() {
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  fm_backlog_row_list "$data" 2>/dev/null | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      if ($2 != "done") print id
    }
  '
}

# Every key token stated anywhere in a status log. A cheap candidate scan: it
# over-includes tokens that are only prose, and status_key_closing_verb below is
# what actually decides what the stream says about a key.
status_log_key_tokens() {  # <status-file>
  grep -o '\[key=[A-Za-z0-9._-]*\]' "$1" 2>/dev/null |
    sed 's/^\[key=//; s/\]$//' | LC_ALL=C sort -u
}

list_has_line() {  # <newline-separated-list> <value>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

command_diverged() {
  local ids resolve f origin tokens id keys key show title
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # Both records must belong to the SAME home or the comparison is meaningless:
  # tasks-axi reads $FM_HOME's backlog, so a state dir pointed somewhere else
  # would report one home's status logs against another home's tasks. Every
  # production caller pairs the two; a mismatch stays silent rather than
  # inventing a cross-home divergence.
  [ "$STATE" = "$FM_HOME/state" ] || return 0
  # A read-only listing on a per-wake path, so it skips the mutation-oriented
  # compatibility floor and its extra probes: a listing this parser cannot read
  # simply yields no candidates and the report stays silent.
  command -v tasks-axi >/dev/null 2>&1 || return 0
  ids=$(open_task_ids) || return 0
  [ -n "$ids" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    origin=$(basename "$f"); origin=${origin%.status}
    tokens=$(status_log_key_tokens "$f")
    [ -n "$tokens" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # The keys that could name this task in THIS log: the collapsed identity
      # (the key IS the task id) and, for a pre-collapse row, the legacy derived
      # one this origin would have minted.
      keys=$id
      case "$id" in
        "$origin-decision-"?*) keys="$keys"$'\n'"${id#"$origin-decision-"}" ;;
      esac
      while IFS= read -r key; do
        list_has_line "$tokens" "$key" || continue
        [ "$(status_key_closing_verb "$f" "$key")" = "$resolve" ] || continue
        show=$(task_show "$id") || continue
        [ "$(show_field "$show" state)" != "done" ] || continue
        [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
        # The title is the only free-text field here, and the report is
        # TAB-separated, so it goes through the same sanitizer every other
        # emitted field uses rather than being trusted to stay one clean line.
        title=$(sanitize_field "$(show_field_value "$show" title)")
        printf '%s\t%s\t%s\t%s\n' "$id" "$origin" "$key" "$title"
        break
      done <<INNER
$keys
INNER
    done <<EOF
$ids
EOF
  done
}

# Still an open captain call? Exit 0 yes, 1 no, 2 cannot tell (see the header).
# A row this home does not carry is 3 when the caller requests the distinction;
# every other read failure is a 2, printed to stderr, because a mechanical
# closer must never read "cannot tell" as permission to close.
command_open() {  # <task-id> [--distinguish-absent]
  local id=${1:-} data state distinguish_absent=0
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  if [ "$#" -eq 2 ]; then
    [ "$2" = --distinguish-absent ] || { usage >&2; exit 2; }
    distinguish_absent=1
  fi
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      printf 'fm-captain-hold: task id must be a non-empty privacy-safe slug: %s\n' "$id" >&2
      exit 2
      ;;
  esac
  fm_tasks_axi_compatible || { printf 'fm-captain-hold: compatible tasks-axi is required\n' >&2; exit 2; }
  data=$(fm_backlog_data_absolute "$DATA") \
    || { printf 'fm-captain-hold: data directory cannot be resolved: %s\n' "$DATA" >&2; exit 2; }
  if fm_backlog_row_probe "$data" "$id"; then
    state=${FM_BACKLOG_ROW_STATE%% *}
    if [ "$state" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      return 0
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    [ "$distinguish_absent" = 0 ] || return 3
    return 1
  fi
  printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_ROW_ERROR" >&2
  exit 2
}

case "${1:-}" in
  hold) shift; command_hold "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  reconcile-requests) shift; command_reconcile_requests "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  open) shift; command_open "$@" ;;
  diverged) shift; command_diverged "$@" ;;
  reconcile) shift; command_reconcile "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
