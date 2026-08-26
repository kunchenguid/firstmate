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
# task held for the captain (`tasks-axi hold <id> --kind captain`), and its
# identity is simply the task id. Older installs created derived
# `<origin>-decision-<key>` identities through bin/fm-decision-hold.sh; those
# rows are already plain task ids, so they keep working here unchanged, and
# the legacy inputs noted below resolve them without a migration.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the call.
#
# Usage:
#   fm-captain-hold.sh hold <task-id> --reason <reason> \
#     [--title <title>] [--repo <repo>] [--origin <origin-id>] [--until YYYY-MM-DD] \
#     [--vorfuehrung [--begehung <docs/begehungen/...>]]
#   fm-captain-hold.sh answer <task-id> --decision-file <path> [--release]
#   fm-captain-hold.sh answers [<legacy-origin> | --any-origin] --source <provenance>   (keyed answers on stdin)
#   fm-captain-hold.sh bind <source-id> [<legacy-origin> | --any-origin]
#   fm-captain-hold.sh unbind <source-id>
#   fm-captain-hold.sh binding <source-id>
#   fm-captain-hold.sh complete <origin-id> (--none | <task-id>...)
#   fm-captain-hold.sh verify <origin-id>
#   fm-captain-hold.sh diverged
#
# `hold` places an existing task under an active captain hold, or creates the
# task first when no work item exists to hold (--title required to create; the
# optional --origin records provenance in the new task's body and supplies the
# default repo from that origin's metadata). Prefer holding the work item the
# question gates over minting a new row. Repeating `hold` with the same id is
# idempotent; a task already closed is refused rather than reopened. `--until`
# records the captain's own deferral date through `tasks-axi hold --until`, so
# a "revisit later" answer is stored as a date instead of a live card.
#
# THE VORFUEHRUNGSWEG AND ITS BEGEHUNG.
# A card that puts a product SURFACE in front of the captain - a Vorfuehrung -
# is the one card kind that must not be created out of a reading of the code.
# The captain's standing complaint is that surfaces were shown to him that
# nobody had walked, so his own click became the first walk (plan
# crispy-launching-cookie Z.89: "Vorfuehrungsweg verweigert ohne
# `begehung:`-Feld"; "Captain-Fund auf begangener Flaeche = Pruefbefund GEGEN
# die Begehung").
#
# Cards carry NO type today - the board's contract is the filename-is-task-id
# rule and nothing else (bin/fm-brett-karten-vollstaendigkeit.sh), and no
# existing field distinguishes a Vorfuehrung from any other captain call. So
# the kind is declared, not guessed: the optional flag `--vorfuehrung` on
# `hold` marks the card being created as a Vorfuehrungs-Karte. Without the
# flag nothing here changes for any existing caller.
#
#   --vorfuehrung             this captain call shows the captain a surface.
#   --begehung <pfad>         the walk that was actually done, as the artifact
#                             path RELATIVE TO THE PRODUCT REPO, under
#                             docs/begehungen/ (the plan's artifact location:
#                             docs/begehungen/<datum>-<persona>.md). It is
#                             recorded verbatim in the card body as a
#                             "Begehung:" line beneath "Vorfuehrung: ja", so
#                             the card itself carries the walk it rests on and
#                             a later captain finding can be measured against
#                             it. Repeating the same hold is idempotent: an
#                             already recorded path is not written twice.
#   Passing --begehung without --vorfuehrung is refused - a walk with no
#   demonstration is a mislabelled call, not a silently ignored flag.
#
# ARMING: state/.tor-begehung-scharf. Armed, `--vorfuehrung` WITHOUT
# `--begehung` is refused loudly and nothing is created or held; the refusal
# names its exit (walk the core path, file the artifact in the product repo,
# repeat the same command with --begehung - the call is never lost, only
# deferred). Unarmed, the same call passes with one warning on stderr, because
# docs/begehungen/ does not exist in a single product repo yet and a gate that
# blocks on day one would be routed around instead of obeyed. Both outcomes -
# green, warned, refused - are written as one line via fm_tor_log to
# state/tor-log/begehung.jsonl, so "did the gate look?" stays answerable.
#
# `answer` records the captain's exact words and closes the call in the same
# act. It requires a non-empty captain decision file of at most 8192 bytes,
# writes a resolution block at the top of the task body (the previous body is
# preserved below the block and archived through tasks-axi --archive-body),
# then closes the task with `tasks-axi done` - or, with `--release`, lifts the
# hold with `tasks-axi unhold` so a captain-gated WORK item resumes instead of
# closing. An exact retry is idempotent only when its requested close mode
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
# `<task-id>\t<answer>\t<label>[\t<mode>[\t<bemerkung>]]` lines on stdin and
# closes each named task through the very same `answer` path above, so every
# guard applies identically no matter which channel the answer arrived on. The
# key IS the task id - no identity arithmetic. The optional fourth field selects
# the close: empty or `done` completes the task, `release` lifts the hold so
# held work resumes; anything else is skipped. The optional fifth field is the
# captain's free-text remark (Bemerkung); when non-empty it is recorded in the
# durable decision as its own "Bemerkung des Captains:" line, because the
# captain's free text is often more important than the clicked answer (order
# O-0054) and must never be dropped from the booking. A remark longer than
# 4000 bytes is skipped loudly rather than truncated. An empty fifth field
# leaves the decision text - and therefore every existing digest - unchanged.
# A key that names no task, a task that is
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
# passes may add ids, and `hold` itself adds the id it holds under `--origin`
# to that origin's inventory, so a call found by a later pass is checked here
# without waiting to be named again; holding never writes the attestation.
# A post-teardown visual review can complete against the
# surviving report and tasks without recreating task state.
# `verify` is read-only and is called by scout teardown, so teardown cannot
# erase a source before this gate has succeeded: every recorded inventory
# entry must still be durable and no keyed status decision may be open.
#
# WHERE AN ENTRY IS LOOKED UP. tasks-axi prunes a closed task out of the live
# backlog on every close once `done_keep` is full and keeps it permanently in
# the archive named by the home's `.tasks.toml`, so an origin with more captain
# calls than that window has answered ones in the archive from the moment they
# are answered. Every read-only inspection here - both attestations, `verify`,
# the keyed intake, and the retry check that makes `answer` idempotent - reads
# the live backlog first and that archive second, and `answer` records a
# retroactive block on an archived task in place. Reaching the archive only
# widens what is FOUND, never what is accepted: an entry missing from both, one
# carrying no recorded captain answer, an archived id reused for a new call, an
# archived task never held for the captain, and a release against a closed task
# all still refuse. `--none` unions the stored inventory rather than replacing
# it, so an empty attestation cannot wave through a registered call.
# Metadata compatibility: the attestation keeps the historical
# `decisions_reviewed=1` and `decision_keys=` keys, and an inventory entry that
# names no existing task resolves through the legacy `<origin>-decision-<entry>`
# identity, so pre-collapse metadata written by fm-decision-hold.sh verifies
# unchanged. An entry that exists as a task id is always that task.
#
# `diverged` is the read-only guard over the seam between the two records of
# one captain call. See "record divergence" beside command_diverged below.
#
# Resolution records: the block written into the body names this script, the
# decision digest, and a `Resolution mode:` of answered, released, or repaired.
# Records written by the retired fm-decision-hold.sh (routed, declined,
# answered, repaired) are recognized everywhere a record is read, so nothing
# already closed needs rewriting.
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
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tor-log-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tor-log-lib.sh"

# The Begehung gate; see "THE VORFUEHRUNGSWEG AND ITS BEGEHUNG" above.
BEGEHUNG_FLAG="$STATE/.tor-begehung-scharf"
BEGEHUNG_TOR="begehung"
BEGEHUNG_ORT="docs/begehungen/"

CAPTAIN_META_LOCK=
CAPTAIN_META_LOCK_HELD=0
captain_hold_cleanup() {
  if [ "$CAPTAIN_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_META_LOCK" || true
    CAPTAIN_META_LOCK_HELD=0
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

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
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

# Read-only lookup of a task that may no longer be in the live backlog.
# tasks-axi retention prunes a closed task out of the live backlog on every
# close once `done_keep` is full, and the record persists permanently in the
# archive. A lookup that stopped at the live backlog therefore reported an
# answered captain call as absent, which made its origin permanently
# uncompletable once the first answer aged past that window. Only read-only
# inspection falls back here; a path that must hold, create, or release a live
# task keeps the live lookup, because an archived row is not a live task.
hold_lookup() {  # <task-id>
  local show
  if show=$(task_show "$1"); then
    printf '%s\n' "$show"
    return 0
  fi
  fm_tasks_axi_show_archived "$FM_HOME" "$1"
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

resolution_block() {  # <mode>
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n' \
    "$DECISION_DIGEST" "$1" "$DECISION_TEXT"
}

# Durable state of one captain call: an active captain hold (annotations
# surviving even when a date gate has expired) or a recorded captain answer.
verify_hold_durable() {  # <task-id>
  local id=$1 show state hold_kind body
  show=$(hold_lookup "$id") \
    || fail "captain-held task $id is absent from the backlog and the archive of $FM_HOME"
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

# Resolve one inventory entry or channel key to the task that carries it: the
# exact task id when it exists, else the legacy derived identity.
resolve_entry() {  # <origin-or-empty> <entry>; prints the resolved id or fails
  local origin=$1 entry=$2 legacy
  if hold_lookup "$entry" >/dev/null 2>&1; then
    printf '%s' "$entry"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if hold_lookup "$legacy" >/dev/null 2>&1; then
      printf '%s' "$legacy"
      return 0
    fi
    fail "no captain-held task $entry and no legacy identity $legacy in the backlog or archive of $FM_HOME"
  fi
  fail "no captain-held task $entry in the backlog or archive of $FM_HOME"
}

# The attested inventory is the exact set of tasks the completion gate
# re-verifies, so it has to grow with the captain calls themselves. A task held
# for the captain by a later review pass belongs to this origin whether or not
# a subsequent `complete` names it, and an inventory frozen at its first store
# silently stopped checking those entries. This records the inventory only and
# never `decisions_reviewed`: holding a task for the captain is not attesting
# that the origin's review is complete.
record_hold_in_inventory() {  # <origin-id> <task-id>
  local meta="$STATE/$1.meta" id=$2 previous keys
  [ -f "$meta" ] || return 0
  CAPTAIN_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
  fm_lock_acquire_wait "$CAPTAIN_META_LOCK"
  CAPTAIN_META_LOCK_HELD=1
  if [ -f "$meta" ]; then
    previous=$(meta_value "$meta" decision_keys)
    keys=$(sorted_key_union "$previous" "$id")
    [ "$previous" = "$keys" ] || printf 'decision_keys=%s\n' "$keys" >> "$meta"
  fi
  fm_lock_release "$CAPTAIN_META_LOCK"
  CAPTAIN_META_LOCK_HELD=0
}

# The walk artifact lives in the PRODUCT repo, so this validates the shape of
# a repo-relative path, never the presence of a file in this home.
validate_begehung_path() {  # <path>
  local path=$1
  validate_one_line --begehung "$path"
  case "$path" in
    /*) fail "--begehung must be relative to the product repo, not absolute: $path" ;;
    *'..'*) fail "--begehung must not walk out of the product repo: $path" ;;
    "$BEGEHUNG_ORT"*) : ;;
    *) fail "--begehung must name an artifact under $BEGEHUNG_ORT (plan: ${BEGEHUNG_ORT}<datum>-<persona>.md): $path" ;;
  esac
  [ "$path" != "$BEGEHUNG_ORT" ] \
    || fail "--begehung must name the walk artifact itself, not just $BEGEHUNG_ORT"
  case "$path" in
    */) fail "--begehung must name a file, not a directory: $path" ;;
  esac
}

# The gate itself. Runs BEFORE anything is created or held, so a refusal leaves
# no half-made card behind.
gate_begehung() {  # <task-id> <vorfuehrung-0-or-1> <begehung>
  local id=$1 vorfuehrung=$2 begehung=$3
  if [ "$vorfuehrung" != 1 ]; then
    [ -z "$begehung" ] \
      || fail "--begehung belongs to a Vorfuehrungs-Karte; pass --vorfuehrung with it or drop it"
    return 0
  fi
  if [ -n "$begehung" ]; then
    fm_tor_log "$BEGEHUNG_TOR" - gruen - "hold $id vorfuehrung begehung=$begehung"
    return 0
  fi
  if [ -f "$BEGEHUNG_FLAG" ]; then
    fm_tor_log "$BEGEHUNG_TOR" - rot begehung-nachreichen \
      "hold $id vorfuehrung ohne begehung; nichts angelegt"
    fail "$(printf '%s\n%s\n%s' \
      "REFUSED: the Vorfuehrungs-Karte $id would show the captain a surface nobody walked - no card was created." \
      "Walk the core path yourself as the named persona and file the artifact in the PRODUCT repo under ${BEGEHUNG_ORT}<datum>-<persona>.md." \
      "Then repeat this exact command with --begehung ${BEGEHUNG_ORT}<datum>-<persona>.md; the call is deferred, never lost.")"
  fi
  fm_tor_log "$BEGEHUNG_TOR" - warn tor-nicht-scharf \
    "hold $id vorfuehrung ohne begehung; Tor nicht scharf"
  printf 'fm-captain-hold: WARNING: %s is a Vorfuehrungs-Karte without a --begehung. The gate (%s) is not armed yet, so it passes - file the walk under %s and record it.\n' \
    "$id" "$BEGEHUNG_FLAG" "$BEGEHUNG_ORT" >&2
  return 0
}

# Write the declared kind and its walk into the card body, above whatever the
# body already carried. Idempotent: an already recorded path is left alone.
record_vorfuehrung() {  # <task-id> <begehung>
  local id=$1 begehung=$2 show body new_body tmp
  show=$(task_show "$id") || fail "task $id disappeared while recording its Begehung"
  body=$(show_field_value "$show" body)
  if printf '%s\n' "$body" | grep -Fxq "Begehung: $begehung"; then
    return 0
  fi
  new_body=$(printf 'Vorfuehrung: ja\nBegehung: %s' "$begehung")
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-vorfuehrung.XXXXXX") \
    || fail "cannot stage the Begehung record"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the Begehung record for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the Begehung on $id"
  fi
  rm -f -- "$tmp"
}

command_hold() {
  local id=${1:-} title='' reason='' repo='' origin='' until='' show state existing_title body='' hold_kind
  local vorfuehrung=0 begehung=''
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --origin) shift; origin=${1:-} ;;
      --until) shift; until=${1:-} ;;
      --vorfuehrung) vorfuehrung=1 ;;
      --begehung) shift; begehung=${1:-} ;;
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
  [ -z "$begehung" ] || validate_begehung_path "$begehung"
  gate_begehung "$id" "$vorfuehrung" "$begehung"
  require_tasks_axi
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    [ "$state" != "done" ] \
      || fail "task $id is already closed; a new captain call needs its own task"
    if [ -n "$title" ]; then
      existing_title=$(show_field_value "$show" title)
      [ "$existing_title" = "$title" ] || fail "existing task $id has a different title"
    fi
  else
    # Retention moves a closed task out of the live backlog, so the refusal
    # above has to follow it into the archive; otherwise an already-answered
    # captain call silently becomes a brand-new task under the same id.
    if fm_tasks_axi_show_archived "$FM_HOME" "$id" >/dev/null; then
      fail "task $id is already closed and archived; a new captain call needs its own task"
    fi
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
  [ -z "$begehung" ] || record_vorfuehrung "$id" "$begehung"
  [ -z "$origin" ] || record_hold_in_inventory "$origin" "$id"
  printf '%s\n' "$id"
}

# Record a resolution block at the top of the task body, preserving the
# previous body below it and archiving the pristine original.
write_resolution_record() {  # <task-id> <mode> <shown-body> [archived]
  local id=$1 mode=$2 body=$3 archived=${4:-0} new_body tmp
  new_body=$(resolution_block "$mode")
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-body.XXXXXX") \
    || fail "cannot stage the resolution record"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the resolution record for $id"
  fi
  if [ "$archived" = 1 ]; then
    if ! fm_tasks_axi_update_archived_body_file "$FM_HOME" "$id" "$tmp"; then
      rm -f -- "$tmp"
      fail "could not record the captain decision on archived $id"
    fi
  elif ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the captain decision on $id"
  fi
  rm -f -- "$tmp"
}

close_answered() {  # <task-id> <release-0-or-1>
  if [ "$2" = 1 ]; then
    tasks_axi unhold "$1" >/dev/null || fail "could not release captain-held task $1"
  else
    tasks_axi "done" "$1" >/dev/null || fail "could not close answered captain-held task $1"
  fi
}

command_answer() {
  local id=${1:-} decision_file='' release=0 show state hold_kind body outcome recorded_mode archived=0
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
  require_tasks_axi
  # An answer must still reach a task retention has moved into the archive:
  # this is the retroactive-record path, and it is the only way an origin whose
  # answer was recorded outside this script gets past the completion gate.
  if ! show=$(task_show "$id"); then
    show=$(fm_tasks_axi_show_archived "$FM_HOME" "$id") \
      || fail "captain-held task $id is absent from the backlog and the archive of $FM_HOME"
    archived=1
  fi
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$release" = 1 ]; then outcome=released; else outcome=answered; fi

  if [ "$state" = "done" ]; then
    if body_has_resolution_record "$body"; then
      # An exact compatible retry is an idempotent no-op; drift is rejected.
      [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
        || fail "captain-held task $id records a different captain decision"
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      [ "$recorded_mode" != released ] \
        || fail "task $id records this answer with mode released; a closed task cannot replay that release"
      [ "$release" = 0 ] \
        || fail "task $id records this answer with mode ${recorded_mode:-unknown}; --release cannot reopen a closed task"
      printf 'answered: %s\n' "$id"
      return 0
    fi
    [ "$release" = 0 ] || fail "task $id is already closed; --release cannot reopen it"
    # Closed outside this script: record the captain's answer retroactively.
    # tasks-axi keeps hold_kind through a close, so it is the surviving proof
    # this really was the captain's item rather than ordinary finished work.
    [ "$hold_kind" = captain ] \
      || fail "task $id was never held for the captain; nothing to record an answer on"
    write_resolution_record "$id" repaired "$body" "$archived"
    if [ "$archived" = 1 ]; then
      show=$(fm_tasks_axi_show_archived "$FM_HOME" "$id") \
        || fail "task $id disappeared while recording the answer"
    else
      show=$(task_show "$id") || fail "task $id disappeared while recording the answer"
    fi
    [ "$(show_field "$show" state)" = "done" ] || fail "recording the answer reopened closed task $id"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
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
        answered) [ "$release" = 0 ] || fail "task $id records this answer as a close; retry without --release" ;;
      esac
      close_answered "$id" "$release"
      printf '%s: %s\n' "$outcome" "$id"
      return 0
    fi
    write_resolution_record "$id" "$outcome" "$body"
    close_answered "$id" "$release"
    show=$(task_show "$id") || fail "task $id disappeared after closing"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
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
keyed_decision_text() {  # <source> <task-id> <answer> <label> [bemerkung]
  printf 'Captain answered this call through %s.\n' "$1"
  printf 'Task: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
  [ -z "${5:-}" ] || printf 'Bemerkung des Captains: %s\n' "$5"
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

# The captain's remark travels uncut: a truncated remark is exactly the silent
# loss O-0054 forbids, so the length guard in command_answers refuses loudly
# instead and this only strips what the record format cannot carry.
sanitize_bemerkung() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177'
}

command_answers() {
  local origin='' source='' row rest key answer label mode bem id show state hold_kind body digest legacy_digest legacy_key
  local recorded_digest recorded_mode tmp err closed=0 skipped=0 reason release_flag tab=$'\t'
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
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    mode=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) bem=${rest#*"$tab"} ;; *) bem='' ;; esac
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 128 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    bem=$(sanitize_bemerkung "${bem:-}")
    if [ "$(printf '%s' "$bem" | LC_ALL=C wc -c | tr -d ' ')" -gt 4000 ]; then
      printf 'skipped: %s (bemerkung longer than 4000 bytes)\n' "$key"
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
    if ! id=$(resolve_entry "$origin" "$key" 2>/dev/null); then
      printf 'skipped: %s (no captain-held task with that id)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    keyed_decision_text "$source" "$id" "$answer" "$label" "$bem" > "$tmp" \
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
    show=$(hold_lookup "$id") || { printf 'skipped: %s (absent)\n' "$id"; skipped=$((skipped + 1)); continue; }
    state=$(show_field "$show" state)
    hold_kind=$(show_field_value "$show" hold_kind)
    body=$(show_field "$show" body)
    recorded_digest=$(recorded_decision_digest "$body" || true)
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    if body_has_resolution_record "$body" \
      && { [ "$recorded_digest" = "$digest" ] \
        || { case "$body" in *"Resolution recorded by fm-decision-hold."*) true ;; *) false ;; esac \
          && [ -n "$legacy_digest" ] && [ "$recorded_digest" = "$legacy_digest" ]; }; }; then
      if { [ -z "$release_flag" ] && [ "$state" = "done" ] && [ "$recorded_mode" != released ]; } \
        || { [ "$release_flag" = --release ] && [ "$state" != "done" ] \
          && [ "$hold_kind" != captain ] && [ "$recorded_mode" = released ]; }; then
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

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' entry key status_file open raw_open has_meta=0 transfer_rc
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
      verify_hold_durable "$(resolve_entry "$origin" "$entry")"
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
  printf 'complete: %s captain-call inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys entry key open
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
      verify_hold_durable "$(resolve_entry "$origin" "$entry")"
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
  tasks_axi list 2>/dev/null | awk -F, '
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

case "${1:-}" in
  hold) shift; command_hold "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  diverged) shift; command_diverged "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
