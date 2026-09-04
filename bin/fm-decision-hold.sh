#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and requires a durable captain decision
# record before it closes or repairs a hold.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...) \
#     [--resolved <decision-key>]... [-- <option-shaped-decision-key>...]
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh answer <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh answers <origin-id> --source <provenance>   (keyed answers on stdin)
#   fm-decision-hold.sh bind <source-id> <origin-id>
#   fm-decision-hold.sh unbind <source-id>
#   fm-decision-hold.sh binding <source-id>
#   fm-decision-hold.sh decline <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh repair <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh migrate-legacy <origin-id> <decision-key> \
#     --decision-file <path> [--identity-file <path>]
#   fm-decision-hold.sh migrate-retention <origin-id> <decision-key> \
#     --authorization-file <path>
#   fm-decision-hold.sh task-done <task-id> [tasks-axi done flags]
#   fm-decision-hold.sh retention-prune
#   fm-decision-hold.sh tasks-axi <retention-affecting tasks-axi arguments>
#
# `complete` is the shared investigation and visual-review completion gate.
# Positional keys are the unresolved decisions in the just-reviewed surface and
# must have active holds on first completion; `--none` explicitly attests that
# there are none. An exact positional retry after resolution is accepted when
# completion provenance records that this review verified the key as current.
# `--resolved` identifies an older key that must have exact durable resolution
# proof, which lets post-teardown reviews carry historical provenance without
# consulting status text. Later review passes may add keys; completion provenance
# is unioned idempotently with current-versus-historical ownership. Released-version
# metadata is upgraded automatically only for source-verifiable active or retained
# Done records; archive-only generations require explicit current or `--resolved`
# classification. A resolved historical key
# may be proven by its structured record in the effective backlog's configured
# archive after normal bounded Done retention prunes it through the public
# `bin/tasks-axi` boundary (also used by `task-done` and `retention-prune`), which
# binds the exact archived bytes to that transition; the gate never restores
# archived rows. Pre-boundary archives require an explicit, exact
# `migrate-retention` authorization before they can prove history.
# A missing key with no valid archived resolution still fails. A post-teardown
# visual review can complete against the surviving report and holds without
# recreating task state. `verify` is called by scout teardown so teardown cannot
# erase a source before this gate has succeeded.
#
# `resolve`, `answer`, and `decline` close active holds; `repair` attests a hold
# already closed outside this script. All four paths require a non-empty captain
# decision file of at most 8192 bytes, record the same durable resolution block in
# the hold body, and store the origin, decision key, decision digest, and routed
# identities so an exact retry is idempotent while a changed identity, decision,
# or, for `resolve`, routed set is rejected. New records include a `Resolution
# mode:` naming their path. A legacy record remains valid when its composed hold
# id has one possible origin/key decomposition or an exact durable identity
# attestation already matches the complete record. An ambiguous unattested legacy
# identity requires `migrate-legacy` with an independently authored identity file
# contained in the active home. That file's exact content is:
#
# schema=fm-decision-legacy-identity.v1
# hold_id=<composed-hold-id>
# origin=<origin-id>
# decision_key=<decision-key>
# record_digest=<sha256-of-the-complete-decoded-resolution-body>
#
# The command validates that mapping against the retained record and captain
# decision before publishing the durable attestation. Claimant metadata and a
# replayed decision file alone never establish ambiguous ownership.
#
# An archive created before the project-scoped retention boundary requires an
# independently authored `migrate-retention` authorization with this exact
# content before its record can become historical proof:
#
# schema=fm-decision-retention-migration.v1
# owner=<configured-retention-owner-token>
# backlog=<physical-effective-backlog-path>
# archive=<physical-effective-archive-path>
# hold_id=<composed-hold-id>
# origin=<origin-id>
# decision_key=<decision-key>
# record_digest=<sha256-of-the-canonical-archived-task-record>
#
# Migration checks that complete mapping against an ordinary, contained archive
# record and publishes only its authenticated provenance marker under the
# effective backlog lock. It does not restore or rewrite the archived task.
#
# `resolve` is the routed path. It requires every --routed-to task to exist and to
# be blocked by the hold. It writes the captain decision and routed identities into
# the hold body, clears those dependency edges, and only then marks the hold Done.
# A failure before the final step leaves the captain hold open.
#
# `answer` is the answer-time closure path, the hold ledger's counterpart to
# `fm-send.sh --resolve-key`: it exists so the act that carries the captain's
# answer is the act that closes the hold, instead of leaving closure to a
# separate later call nobody is forced to make. It records the captain's answer
# on an actively held hold, records `(none)` as the routed identities because no
# follow-up work has been routed behind the hold yet, and closes it. It shares
# every guard `decline` has, including the refusal while any task is still
# blocked by the hold, so a decision whose follow-up work is already routed still
# goes through `resolve` and the routed-vs-unrouted distinction survives. It says
# only that the captain answered; `decline` still says the captain answered with
# no follow-up work at all.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer closes its matching hold" is a single capability, owned here
# and nowhere else. `answers` is its channel-agnostic entry point: it reads
# `<decision-key>\t<answer>\t<label>` lines on stdin, maps each key to this
# origin's `<origin-id>-decision-<key>` hold, and closes it through the very same
# `answer` path above, so every guard applies identically no matter which channel
# the answer arrived on. `--source` is provenance text recorded in the durable
# decision, never a behavior switch: this command has no per-channel branch and
# no knowledge of chat, review decks, or any transport.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines and
# pipe them here. It must never map keys to holds, build decision records, decide
# resolve-versus-decline, or close a hold itself. A future channel needs no change
# here at all.
#
# The decision text is a pure function of (source, key, answer, label), which is
# what makes a replayed delivery an idempotent no-op rather than a rejected
# "different captain decision". A key whose hold is absent, already closed, or
# still blocking routed work is reported as `skipped:` and left for `resolve`;
# skipping is never forced closure, and the command exits nonzero when any key
# was skipped.
#
# `bind`, `unbind`, and `binding` record which origin a captured-answer SOURCE
# belongs to, for any channel whose answers arrive detached from the origin (a
# process-event source id, for example). The binding is a private record under
# `state/decision-bindings/`; a source with no binding feeds nothing, so this
# whole path is opt-in per source and an unbound source behaves as if it did not
# exist. `bind` deliberately does not require the source to exist yet, so a
# channel can be bound BEFORE it is armed and never produce an answer that has
# nowhere to go.
#
# `decline` is the unrouted path for a decision the captain answered with no
# follow-up work. It takes no --routed-to task, records `(none)` as the routed
# identities, and closes an actively held hold. It refuses while any task is still
# blocked by the hold, because releasing routed work without recording it is
# `resolve`'s job.
#
# `repair` records the missing resolution block on a hold that was already closed
# outside this script, so `verify` stops failing on an origin whose decision was
# genuinely answered. It never reopens a hold, never clears a dependency edge, and
# refuses a hold that is still actively held, so an unanswered decision keeps
# blocking teardown until `resolve` or `decline` closes it with the captain's word.
# It also refuses an identity that does not carry surviving captain-hold
# provenance, so an ordinary captain-kind task cannot be repaired into a decision.
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

DECISION_META_LOCK=
DECISION_META_LOCK_HELD=0
DECISION_INVENTORY_LOCK=
DECISION_INVENTORY_LOCK_HELD=0
DECISION_ATTESTATION_LOCK=
DECISION_ATTESTATION_LOCK_HELD=0
DECISION_RETENTION_LOCK=
DECISION_RETENTION_LOCK_HELD=0
DECISION_RETENTION_HOOK_DIR=''
DECISION_ARCHIVE_CACHE_ENABLED=1
DECISION_ARCHIVE_CACHE_DIR=''
DECISION_ARCHIVE_CACHE_PATH=''
decision_hold_cleanup() {
  if [ -n "$DECISION_RETENTION_HOOK_DIR" ] && [ -d "$DECISION_RETENTION_HOOK_DIR" ] \
    && [ ! -L "$DECISION_RETENTION_HOOK_DIR" ]; then
    rm -rf -- "$DECISION_RETENTION_HOOK_DIR"
  fi
  if [ "$DECISION_RETENTION_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_RETENTION_LOCK" || true
    DECISION_RETENTION_LOCK_HELD=0
  fi
  if [ "$DECISION_ATTESTATION_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_ATTESTATION_LOCK" || true
    DECISION_ATTESTATION_LOCK_HELD=0
  fi
  if [ "$DECISION_INVENTORY_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_INVENTORY_LOCK" || true
    DECISION_INVENTORY_LOCK_HELD=0
  fi
  if [ "$DECISION_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK" || true
    DECISION_META_LOCK_HELD=0
  fi
  if [ -n "$DECISION_ARCHIVE_CACHE_DIR" ] && [ -d "$DECISION_ARCHIVE_CACHE_DIR" ] \
    && [ ! -L "$DECISION_ARCHIVE_CACHE_DIR" ]; then
    rm -rf -- "$DECISION_ARCHIVE_CACHE_DIR"
  fi
}
trap decision_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

slug_valid() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  slug_valid "$value" || fail "$label must be a non-empty privacy-safe slug: $value"
}

task_id_valid() {
  case "$1" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_task_id() {
  local label=$1 value=$2
  task_id_valid "$value" || fail "$label must be a valid task id: $value"
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

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

# The routed-identity token recorded when a close path routes no work. Slug
# validation rejects parentheses, so no real task identity can collide with it.
ROUTED_NONE='(none)'

DECISION_TEXT=''
DECISION_DIGEST=''
DECISION_MAX_BYTES=8192

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le "$DECISION_MAX_BYTES" ] \
    || fail "decision file exceeds $DECISION_MAX_BYTES bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

tasks_axi() {
  (
    cd "$FM_HOME"
    unset TASKS_AXI_FILE TASKS_AXI_BACKEND
    "${FM_TASKS_AXI_REAL:-tasks-axi}" "$@"
  )
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  command -v node >/dev/null 2>&1 || fail "node is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

TASK_SHOW_OUTPUT=''
task_show_optional() {  # <id>
  local id=$1 code detail
  TASK_SHOW_OUTPUT=''
  if TASK_SHOW_OUTPUT=$(tasks_axi show "$id" --full 2>&1); then
    return 0
  fi
  code=$(printf '%s\n' "$TASK_SHOW_OUTPUT" | sed -n 's/^code: //p' | head -1)
  [ "$code" = NOT_FOUND ] && return 1
  detail=$(printf '%s\n' "$TASK_SHOW_OUTPUT" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  fail "could not read backlog item $id${detail:+: $detail}"
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  local origin=$1 meta report_dir report physical_report_dir has_meta=0 has_report=0
  authoritative_state_path
  authoritative_archive_path
  meta="$DECISION_STATE/$origin.meta"
  report_dir="$DECISION_DATA/$origin"
  report="$report_dir/report.md"

  if [ -e "$meta" ] || [ -L "$meta" ]; then
    require_safe_origin_metadata_file "$meta"
    has_meta=1
  fi
  if [ -e "$report_dir" ] || [ -L "$report_dir" ]; then
    [ -d "$report_dir" ] && [ ! -L "$report_dir" ] \
      || fail "origin report directory is unsafe: $report_dir"
    physical_report_dir=$(cd "$report_dir" && pwd -P) \
      || fail "could not resolve origin report directory: $report_dir"
    [ "$physical_report_dir" = "$DECISION_DATA/$origin" ] \
      || fail "origin report directory escapes the active home: $report_dir"
    if [ -e "$report" ] || [ -L "$report" ]; then
      require_safe_origin_report_file "$report"
      has_report=1
    fi
  fi
  [ "$has_meta" -eq 1 ] && return 0
  [ "$has_report" -eq 1 ] && return 0
  task_show_optional "$origin"
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
  local origin=$1 state=${DECISION_STATE:-$STATE} meta status_file open kind last verb
  meta="$state/$1.meta"
  status_file="$state/$1.status"
  require_safe_status_file "$status_file"
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

RESOLUTION_ORIGIN=''
RESOLUTION_KEY=''
RESOLUTION_DIGEST=''
RESOLUTION_ROUTES=''
RESOLUTION_MODE=''
RESOLUTION_RECORD_DIGEST=''

decode_json_string() {
  printf '%s' "$1" | node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(0, "utf8"));
      if (typeof value !== "string") process.exit(1);
      process.stdout.write(value);
    } catch (_) {
      process.exit(1);
    }
  '
}

parse_resolution_record() {  # <hold-body>
  local encoded=$1 body rest metadata tail line digest routes decision routed_work
  local captain_marker=$'\n\nCaptain decision:\n' routed_marker=$'\n\nRouted work:\n'
  local expected_work='' canonical_routes route
  RESOLUTION_ORIGIN=''
  RESOLUTION_KEY=''
  RESOLUTION_DIGEST=''
  RESOLUTION_ROUTES=''
  RESOLUTION_MODE=''
  RESOLUTION_RECORD_DIGEST=''

  case "$encoded" in
    \"*) body=$(decode_json_string "$encoded") || return 1 ;;
    *) body=$encoded ;;
  esac
  case "$body" in
    'Resolution recorded by fm-decision-hold.'$'\n'*)
      rest=${body#'Resolution recorded by fm-decision-hold.'$'\n'}
      ;;
    *) return 1 ;;
  esac
  case "$rest" in *"$captain_marker"*) : ;; *) return 1 ;; esac
  metadata=${rest%%"$captain_marker"*}
  tail=${rest#*"$captain_marker"}
  case "$tail" in *"$routed_marker"*) : ;; *) return 1 ;; esac
  decision=${tail%"$routed_marker"*}
  routed_work=${tail##*"$routed_marker"}
  [ -n "$decision" ] || return 1
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le "$DECISION_MAX_BYTES" ] || return 1

  line=${metadata%%$'\n'*}
  if [ "$line" != "$metadata" ]; then metadata=${metadata#*$'\n'}; else metadata=''; fi
  case "$line" in
    'Origin: '*)
      RESOLUTION_ORIGIN=${line#'Origin: '}
      case "$RESOLUTION_ORIGIN" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      [ -n "$metadata" ] || return 1
      line=${metadata%%$'\n'*}
      if [ "$line" != "$metadata" ]; then metadata=${metadata#*$'\n'}; else metadata=''; fi
      case "$line" in 'Decision key: '*) RESOLUTION_KEY=${line#'Decision key: '} ;; *) return 1 ;; esac
      case "$RESOLUTION_KEY" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      [ -n "$metadata" ] || return 1
      line=${metadata%%$'\n'*}
      if [ "$line" != "$metadata" ]; then metadata=${metadata#*$'\n'}; else metadata=''; fi
      ;;
    'Decision digest: '*) : ;;
    *) return 1 ;;
  esac
  case "$line" in 'Decision digest: '*) digest=${line#'Decision digest: '} ;; *) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac

  [ -n "$metadata" ] || return 1
  line=${metadata%%$'\n'*}
  if [ "$line" != "$metadata" ]; then metadata=${metadata#*$'\n'}; else metadata=''; fi
  case "$line" in 'Routed identities: '*) routes=${line#'Routed identities: '} ;; *) return 1 ;; esac
  [ -n "$routes" ] || return 1
  if [ -n "$metadata" ]; then
    case "$metadata" in *$'\n'*) return 1 ;; esac
    case "$metadata" in
      'Resolution mode: routed') RESOLUTION_MODE=routed ;;
      'Resolution mode: answered') RESOLUTION_MODE=answered ;;
      'Resolution mode: declined') RESOLUTION_MODE=declined ;;
      'Resolution mode: repaired') RESOLUTION_MODE=repaired ;;
      *) return 1 ;;
    esac
  fi

  if [ "$routes" = "$ROUTED_NONE" ]; then
    [ "$routed_work" = "$ROUTED_NONE" ] || return 1
  else
    case "$routes" in ,*|*,|*,,*) return 1 ;; esac
    while IFS= read -r route; do
      task_id_valid "$route" || return 1
      expected_work="${expected_work}${expected_work:+$'\n'}- $route"
    done <<EOF
$(printf '%s\n' "$routes" | tr ',' '\n')
EOF
    canonical_routes=$(printf '%s\n' "$routes" | tr ',' '\n' | LC_ALL=C sort -u | paste -sd, -)
    [ "$routes" = "$canonical_routes" ] || return 1
    [ "$routed_work" = "$expected_work" ] || return 1
  fi
  case "$RESOLUTION_MODE" in
    routed) [ "$routes" != "$ROUTED_NONE" ] || return 1 ;;
    answered|declined|repaired) [ "$routes" = "$ROUTED_NONE" ] || return 1 ;;
    '')
      [ -z "$RESOLUTION_ORIGIN" ] && [ -z "$RESOLUTION_KEY" ] \
        && [ "$routes" != "$ROUTED_NONE" ] || return 1
      ;;
  esac
  [ "$(sha256_text "$decision")" = "$digest" ] || return 1

  RESOLUTION_DIGEST=$digest
  RESOLUTION_ROUTES=$routes
  RESOLUTION_RECORD_DIGEST=$(sha256_text "$body")
}

legacy_resolution_identity_unambiguous() {  # <hold-id> <origin-id> <decision-key>
  local id=$1 origin=$2 key=$3 remainder prefix='' part candidate_origin candidate_key
  local count=0 matched=0
  [ "$id" = "${origin}-decision-${key}" ] || return 1
  remainder=$id
  while [[ "$remainder" == *-decision-* ]]; do
    part=${remainder%%-decision-*}
    candidate_origin="$prefix$part"
    candidate_key=${remainder#*-decision-}
    if slug_valid "$candidate_origin" && slug_valid "$candidate_key"; then
      count=$((count + 1))
      if [ "$candidate_origin" = "$origin" ] && [ "$candidate_key" = "$key" ]; then
        matched=1
      fi
    fi
    prefix="${candidate_origin}-decision-"
    remainder=$candidate_key
  done
  [ "$count" -eq 1 ] && [ "$matched" -eq 1 ]
}

legacy_resolution_identity_valid() {  # <origin-id> <decision-key>
  local origin=$1 key=$2 id
  authoritative_state_path
  id="${origin}-decision-${key}"
  legacy_resolution_attestation_valid "$id" "$origin" "$key" "$RESOLUTION_RECORD_DIGEST" \
    && return 0
  legacy_resolution_identity_unambiguous "$id" "$origin" "$key"
}

resolution_record_valid() {  # <hold-body> [<origin-id> <decision-key>]
  parse_resolution_record "$1" || return 1
  if [ "$#" -eq 3 ]; then
    if [ -n "$RESOLUTION_ORIGIN" ] || [ -n "$RESOLUTION_KEY" ]; then
      [ "$RESOLUTION_ORIGIN" = "$2" ] && [ "$RESOLUTION_KEY" = "$3" ] || return 1
    else
      legacy_resolution_identity_valid "$2" "$3" || return 1
    fi
  fi
}

body_has_resolution_record() {  # <hold-body> [<origin-id> <decision-key>]
  resolution_record_valid "$@"
}

active_hold_body_valid() {  # <hold-body> <origin-id> <decision-key>
  local expected
  expected="\"Origin: $2\\nDecision key: $3\\nState: awaiting captain decision.\""
  [ "$1" = "$expected" ] || resolution_record_valid "$1" "$2" "$3"
}

queued_hold_body_valid() {  # <hold-body> <origin-id> <decision-key>
  local expected
  expected="\"Origin: $2\\nDecision key: $3\\nState: awaiting captain decision.\""
  [ "$1" = "$expected" ] && return 0
  resolution_record_valid "$1" "$2" "$3" || return 1
  [ "$RESOLUTION_MODE" != repaired ]
}

require_safe_origin_metadata_file() {
  local path=$1 links
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
    || fail "decision owner metadata is unsafe: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect decision owner metadata link count: $path"
  [ "$links" = 1 ] || fail "decision owner metadata is hardlinked: $path"
}

require_safe_origin_report_file() {
  local path=$1 links
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
    || fail "origin report is not an ordinary readable file: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect origin report link count: $path"
  [ "$links" = 1 ] || fail "origin report is hardlinked: $path"
}

COMPLETION_INVENTORY_SCHEMA=fm-decision-completion.v1
META_DECISION_KEYS=''
META_DECISION_CURRENT_KEYS=''
META_DECISION_HISTORICAL_KEYS=''
META_DECISION_LAST_CURRENT_KEYS=''
META_DECISION_LAST_HISTORICAL_KEYS=''
META_DECISION_LAST_INVENTORY_KNOWN=0
META_DECISION_INVENTORY_VERSIONED=0
META_DECISIONS_REVIEWED=''

validate_metadata_decision_keys() {  # <meta-path> <field> <comma-list>
  local path=$1 field=$2 keys=$3 key canonical
  case "$keys" in ,*|*,|*,,*) fail "decision owner metadata has malformed $field: $path" ;; esac
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) fail "decision owner metadata has malformed $field: $path" ;; esac
  done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  canonical=$(printf '%s\n' "$keys" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -)
  [ "$keys" = "$canonical" ] \
    || fail "decision owner metadata has noncanonical $field: $path"
}

completion_metadata_inventory() {  # <meta-path>
  local path=$1 schema current historical last_current last_historical last_known key union
  META_DECISION_KEYS=''
  META_DECISION_CURRENT_KEYS=''
  META_DECISION_HISTORICAL_KEYS=''
  META_DECISION_LAST_CURRENT_KEYS=''
  META_DECISION_LAST_HISTORICAL_KEYS=''
  META_DECISION_LAST_INVENTORY_KNOWN=0
  META_DECISION_INVENTORY_VERSIONED=0
  META_DECISIONS_REVIEWED=''
  require_safe_origin_metadata_file "$path" || return 1
  META_DECISIONS_REVIEWED=$(meta_value "$path" decisions_reviewed)
  case "$META_DECISIONS_REVIEWED" in ''|1) : ;; *) fail "decision owner metadata has malformed review state: $path" ;; esac
  META_DECISION_KEYS=$(meta_value "$path" decision_keys)
  validate_metadata_decision_keys "$path" decision_keys "$META_DECISION_KEYS"
  schema=$(meta_value "$path" decision_inventory_schema)
  if [ -z "$schema" ]; then
    if grep -qE '^decision_((current|historical)_keys|last_(current|historical)_keys|last_inventory_known)=' "$path"; then
      fail "decision owner metadata has provenance fields without an inventory schema: $path"
    fi
    return 0
  fi
  [ "$schema" = "$COMPLETION_INVENTORY_SCHEMA" ] \
    || fail "decision owner metadata has an unsupported inventory schema: $path"
  [ "$META_DECISIONS_REVIEWED" = 1 ] \
    || fail "decision owner metadata has provenance without a completed review: $path"
  if ! grep -q '^decision_current_keys=' "$path" \
    || ! grep -q '^decision_historical_keys=' "$path" \
    || ! grep -q '^decision_last_current_keys=' "$path" \
    || ! grep -q '^decision_last_historical_keys=' "$path" \
    || ! grep -q '^decision_last_inventory_known=' "$path"; then
    fail "decision owner metadata lacks its completion provenance: $path"
  fi
  current=$(meta_value "$path" decision_current_keys)
  historical=$(meta_value "$path" decision_historical_keys)
  last_current=$(meta_value "$path" decision_last_current_keys)
  last_historical=$(meta_value "$path" decision_last_historical_keys)
  last_known=$(meta_value "$path" decision_last_inventory_known)
  case "$last_known" in 0|1) : ;; *) fail "decision owner metadata has malformed last-inventory provenance: $path" ;; esac
  if [ "$last_known" = 0 ] && { [ -n "$last_current" ] || [ -n "$last_historical" ]; }; then
    fail "decision owner metadata invents a last inventory for legacy provenance: $path"
  fi
  validate_metadata_decision_keys "$path" decision_current_keys "$current"
  validate_metadata_decision_keys "$path" decision_historical_keys "$historical"
  validate_metadata_decision_keys "$path" decision_last_current_keys "$last_current"
  validate_metadata_decision_keys "$path" decision_last_historical_keys "$last_historical"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    list_has_key "$current" "$key" \
      && fail "decision owner metadata classifies $key as both current and historical: $path"
  done <<EOF
$(printf '%s\n' "$historical" | tr ',' '\n')
EOF
  union=$(sorted_key_union "$current" "$(printf '%s' "$historical" | tr ',' ' ')")
  [ "$union" = "$META_DECISION_KEYS" ] \
    || fail "decision owner metadata provenance does not match its decision keys: $path"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    list_has_key "$current" "$key" \
      || fail "decision owner metadata last completion has a noncurrent key $key: $path"
  done <<EOF
$(printf '%s\n' "$last_current" | tr ',' '\n')
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    list_has_key "$META_DECISION_KEYS" "$key" \
      || fail "decision owner metadata last completion has an unknown historical key $key: $path"
    list_has_key "$last_current" "$key" \
      && fail "decision owner metadata last completion duplicates key $key: $path"
  done <<EOF
$(printf '%s\n' "$last_historical" | tr ',' '\n')
EOF
  META_DECISION_CURRENT_KEYS=$current
  META_DECISION_HISTORICAL_KEYS=$historical
  META_DECISION_LAST_CURRENT_KEYS=$last_current
  META_DECISION_LAST_HISTORICAL_KEYS=$last_historical
  META_DECISION_LAST_INVENTORY_KNOWN=$last_known
  META_DECISION_INVENTORY_VERSIONED=1
}

reviewed_decision_inventory() {  # <meta-path>
  completion_metadata_inventory "$1"
  [ "$META_DECISIONS_REVIEWED" = 1 ]
}

append_completion_inventory() {  # <path> <keys> <current> <historical> <last-current> <last-historical> <last-known>
  printf 'decisions_reviewed=1\ndecision_keys=%s\ndecision_inventory_schema=%s\ndecision_current_keys=%s\ndecision_historical_keys=%s\ndecision_last_current_keys=%s\ndecision_last_historical_keys=%s\ndecision_last_inventory_known=%s\n' \
    "$2" "$COMPLETION_INVENTORY_SCHEMA" "$3" "$4" "$5" "$6" "$7" >> "$1"
}

file_link_count() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

require_safe_status_file() {
  local path=$1 links
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] \
    || fail "origin status is not an ordinary file: $path"
  [ -r "$path" ] || fail "origin status is unreadable: $path"
  links=$(file_link_count "$path") || fail "could not inspect origin status link count: $path"
  [ "$links" = 1 ] || fail "origin status is hardlinked: $path"
}

tasks_config_string() {  # <config-path> <table> <key>
  local path=$1 table=$2 key=$3
  [ -e "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 3
  awk -v wanted_table="$table" -v wanted_key="$key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function uncomment(value, i, ch, quote) {
      quote = ""
      for (i = 1; i <= length(value); i++) {
        ch = substr(value, i, 1)
        if (quote != "") {
          if (ch == quote) quote = ""
        } else if (ch == "\"" || ch == sprintf("%c", 39)) {
          quote = ch
        } else if (ch == "#") {
          return substr(value, 1, i - 1)
        }
      }
      return value
    }
    BEGIN { current = "root"; found = 0; bad = 0 }
    {
      line = trim(uncomment($0))
      if (line == "") next
      if (line ~ /^\[[^]]+\]$/) {
        current = trim(substr(line, 2, length(line) - 2))
        next
      }
      if (current != wanted_table) next
      equals = index(line, "=")
      if (equals == 0) next
      name = trim(substr(line, 1, equals - 1))
      if (name != wanted_key) next
      raw = trim(substr(line, equals + 1))
      quote = substr(raw, 1, 1)
      if (length(raw) <= 1 || (quote != "\"" && quote != sprintf("%c", 39)) \
        || substr(raw, length(raw), 1) != quote) {
        bad = 1
        next
      }
      value = substr(raw, 2, length(raw) - 2)
      found = 1
    }
    END {
      if (bad) exit 2
      if (!found) exit 1
      print value
    }
  ' "$path"
}

CONTAINED_OPERATIONAL_PATH=''
resolve_contained_operational_directory() {
  local label=$1 input=$2 physical_home=$3 logical_home input_path physical_input cwd
  CONTAINED_OPERATIONAL_PATH=''
  [ -d "$input" ] && [ ! -L "$input" ] \
    || fail "$label directory is unsafe: $input"
  physical_input=$(cd "$input" && pwd -P) \
    || fail "could not resolve $label directory: $input"
  case "$physical_input" in
    "$physical_home"/*) ;;
    *) fail "$label directory is outside the active home: $input" ;;
  esac
  cwd=$(pwd -P) || fail "could not resolve the current directory"
  case "$FM_HOME" in /*) logical_home=$FM_HOME ;; *) logical_home="$cwd/$FM_HOME" ;; esac
  case "$input" in /*) input_path=$input ;; *) input_path="$cwd/$input" ;; esac
  normalize_home_owned_path "$input_path" "$logical_home" "$physical_home" \
    || fail "$label directory is outside the active home: $input"
  [ "$NORMALIZED_HOME_PATH" = "$physical_input" ] \
    || fail "$label directory has an unsafe symlink path: $input"
  CONTAINED_OPERATIONAL_PATH=$physical_input
}

DECISION_STATE=''
authoritative_state_path() {
  local physical_home expected_state
  DECISION_STATE=''
  [ -d "$FM_HOME" ] || fail "active home is not a directory: $FM_HOME"
  physical_home=$(cd "$FM_HOME" && pwd -P) \
    || fail "could not resolve active home: $FM_HOME"
  expected_state="$FM_HOME/state"
  if [ "$STATE" = "$expected_state" ]; then
    [ -d "$expected_state" ] && [ ! -L "$expected_state" ] \
      || fail "authoritative state directory is unsafe: $expected_state"
  fi
  resolve_contained_operational_directory "configured state" "$STATE" "$physical_home"
  DECISION_STATE=$CONTAINED_OPERATIONAL_PATH
}

NORMALIZED_HOME_PATH=''
normalize_home_owned_path() {  # <path> <logical-home> <physical-home>
  local path=$1 logical_home=$2 physical_home=$3 relative component last_index joined
  local -a components=()
  NORMALIZED_HOME_PATH=''
  [ "$logical_home" = / ] || logical_home=${logical_home%/}
  case "$path" in
    /*)
      case "$path" in
        "$logical_home") relative='' ;;
        "$logical_home"/*) relative=${path#"$logical_home"/} ;;
        "$physical_home") relative='' ;;
        "$physical_home"/*) relative=${path#"$physical_home"/} ;;
        *) return 1 ;;
      esac
      ;;
    *) relative=$path ;;
  esac
  while [ -n "$relative" ]; do
    component=${relative%%/*}
    if [ "$component" = "$relative" ]; then relative=''; else relative=${relative#*/}; fi
    case "$component" in
      ''|.) ;;
      ..)
        [ "${#components[@]}" -gt 0 ] || return 1
        last_index=$((${#components[@]} - 1))
        unset "components[$last_index]"
        ;;
      *) components+=("$component") ;;
    esac
  done
  [ "${#components[@]}" -gt 0 ] || return 1
  joined=$(IFS=/; printf '%s' "${components[*]}")
  NORMALIZED_HOME_PATH="$physical_home/$joined"
}

LEGACY_IDENTITY_AUTHORIZATION_SCHEMA=fm-decision-legacy-identity.v1

legacy_identity_authorization_content() {  # <hold-id> <origin-id> <decision-key> <record-digest>
  printf 'schema=%s\nhold_id=%s\norigin=%s\ndecision_key=%s\nrecord_digest=%s\n' \
    "$LEGACY_IDENTITY_AUTHORIZATION_SCHEMA" "$1" "$2" "$3" "$4"
}

require_legacy_identity_authorization() {  # <path> <hold-id> <origin-id> <decision-key> <record-digest>
  local input=$1 id=$2 origin=$3 key=$4 record_digest=$5 cwd physical_home logical_home input_path
  local normalized input_parent physical_parent expected_parent links expected actual expected_bytes actual_bytes
  [ -n "$input" ] || fail "ambiguous legacy ownership requires an independent --identity-file authorization"
  [ -d "$FM_HOME" ] || fail "active home is not a directory: $FM_HOME"
  cwd=$(pwd -P) || fail "could not resolve the current directory"
  physical_home=$(cd "$FM_HOME" && pwd -P) || fail "could not resolve active home: $FM_HOME"
  case "$FM_HOME" in /*) logical_home=$FM_HOME ;; *) logical_home="$cwd/$FM_HOME" ;; esac
  case "$input" in /*) input_path=$input ;; *) input_path="$cwd/$input" ;; esac
  normalize_home_owned_path "$input_path" "$logical_home" "$physical_home" \
    || fail "legacy identity authorization is outside the active home: $input"
  normalized=$NORMALIZED_HOME_PATH
  input_parent=${input_path%/*}
  expected_parent=${normalized%/*}
  [ -d "$input_parent" ] && [ ! -L "$input_parent" ] \
    || fail "legacy identity authorization directory is unsafe: $input"
  physical_parent=$(cd "$input_parent" && pwd -P) \
    || fail "could not resolve legacy identity authorization directory: $input"
  [ "$physical_parent" = "$expected_parent" ] \
    || fail "legacy identity authorization has an unsafe symlink path: $input"
  [ -f "$input_path" ] && [ ! -L "$input_path" ] && [ -r "$input_path" ] \
    || fail "legacy identity authorization is not an ordinary readable file: $input"
  links=$(file_link_count "$input_path") \
    || fail "could not inspect legacy identity authorization link count: $input"
  [ "$links" = 1 ] || fail "legacy identity authorization is hardlinked: $input"
  expected=$(legacy_identity_authorization_content "$id" "$origin" "$key" "$record_digest")
  expected_bytes=$(printf '%s\n' "$expected" | LC_ALL=C wc -c | tr -d ' ')
  actual_bytes=$(LC_ALL=C wc -c < "$input_path" | tr -d ' ')
  [ "$actual_bytes" = "$expected_bytes" ] \
    || fail "legacy identity authorization does not match $origin/$key: $input"
  actual=$(cat "$input_path") \
    || fail "could not read legacy identity authorization: $input"
  [ "$actual" = "$expected" ] \
    || fail "legacy identity authorization does not match $origin/$key: $input"
}

contained_archive_parent_safe() {  # <physical-home> <archive-parent>
  local physical_home=$1 archive_parent=$2 relative component current
  case "$archive_parent" in
    "$physical_home") return 0 ;;
    "$physical_home"/*) relative=${archive_parent#"$physical_home"/} ;;
    *) return 1 ;;
  esac
  current=$physical_home
  while [ -n "$relative" ]; do
    component=${relative%%/*}
    if [ "$component" = "$relative" ]; then relative=''; else relative=${relative#*/}; fi
    current="$current/$component"
    if [ -e "$current" ] || [ -L "$current" ]; then
      [ -d "$current" ] && [ ! -L "$current" ] || return 1
    fi
  done
}

DECISION_ARCHIVE=''
DECISION_BACKLOG=''
DECISION_DATA=''
paths_physically_alias() {
  [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}

paths_destination_alias() {
  local rc
  paths_physically_alias "$1" "$2" && return 0
  if node - "$1" "$2" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

function destination(value) {
  const missing = [];
  const followed = new Set();
  let current = path.resolve(value);
  while (true) {
    try {
      return path.join(fs.realpathSync.native(current), ...missing);
    } catch (error) {
      if (!error || error.code !== "ENOENT") process.exit(2);
    }
    try {
      const stat = fs.lstatSync(current);
      if (!stat.isSymbolicLink() || followed.has(current)) process.exit(2);
      followed.add(current);
      current = path.resolve(path.dirname(current), fs.readlinkSync(current));
    } catch (error) {
      if (!error || error.code !== "ENOENT") process.exit(2);
      const parent = path.dirname(current);
      if (parent === current) process.exit(2);
      missing.unshift(path.basename(current));
      current = parent;
    }
  }
}

function toggled(value) {
  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i];
    if (/[a-z]/.test(ch)) return value.slice(0, i) + ch.toUpperCase() + value.slice(i + 1);
    if (/[A-Z]/.test(ch)) return value.slice(0, i) + ch.toLowerCase() + value.slice(i + 1);
  }
  return value;
}

function caseInsensitiveAt(value) {
  let current = fs.realpathSync.native(value);
  while (true) {
    const parent = path.dirname(current);
    const base = path.basename(current);
    const alternate = toggled(base);
    if (alternate !== base) {
      try {
        const left = fs.statSync(current);
        const right = fs.statSync(path.join(parent, alternate));
        return left.dev === right.dev && left.ino === right.ino;
      } catch (_) {
        return false;
      }
    }
    if (parent === current) return false;
    current = parent;
  }
}

const left = destination(process.argv[2]);
const right = destination(process.argv[3]);
if (left === right) process.exit(0);
if (left.toLocaleLowerCase("en-US") !== right.toLocaleLowerCase("en-US")) process.exit(1);
let existing = path.dirname(left);
while (!fs.existsSync(existing)) existing = path.dirname(existing);
process.exit(caseInsensitiveAt(existing) ? 0 : 1);
NODE
  then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] && return 1
  fail "could not compare configured archive destinations safely"
}

authoritative_archive_path() {
  local physical_home expected_data physical_data project_config home_config
  local archive_value='' backlog_value='' configured_backlog configured_archive archive_dir archive_name
  local configured_backlog_dir physical_backlog_dir note_archive links rc
  DECISION_ARCHIVE=''
  DECISION_BACKLOG=''
  DECISION_DATA=''
  [ -d "$FM_HOME" ] || fail "active home is not a directory: $FM_HOME"
  physical_home=$(cd "$FM_HOME" && pwd -P) \
    || fail "could not resolve active home: $FM_HOME"
  expected_data="$FM_HOME/data"
  if [ "$DATA" = "$expected_data" ]; then
    [ -d "$expected_data" ] && [ ! -L "$expected_data" ] \
      || fail "authoritative data directory is unsafe: $expected_data"
  fi
  resolve_contained_operational_directory "configured data" "$DATA" "$physical_home"
  physical_data=$CONTAINED_OPERATIONAL_PATH
  DECISION_DATA=$physical_data

  project_config="$FM_HOME/.tasks.toml"
  home_config="${HOME:-}/.tasks-axi/config.toml"
  if archive_value=$(tasks_config_string "$project_config" markdown archive); then
    :
  else
    rc=$?
    [ "$rc" -eq 1 ] || fail "tasks-axi project configuration is unsafe or has an invalid markdown.archive"
    if archive_value=$(tasks_config_string "$home_config" markdown archive); then
      :
    else
      rc=$?
      [ "$rc" -eq 1 ] || fail "tasks-axi home configuration is unsafe or has an invalid markdown.archive"
      archive_value=''
    fi
  fi
  if backlog_value=$(tasks_config_string "$project_config" markdown path); then
    :
  else
    rc=$?
    [ "$rc" -eq 1 ] || fail "tasks-axi project configuration is unsafe or has an invalid markdown.path"
    if backlog_value=$(tasks_config_string "$home_config" markdown path); then
      :
    else
      rc=$?
      [ "$rc" -eq 1 ] || fail "tasks-axi home configuration is unsafe or has an invalid markdown.path"
      if [ -e "$FM_HOME/backlog.md" ]; then backlog_value=backlog.md; else backlog_value=data/backlog.md; fi
    fi
  fi

  normalize_home_owned_path "$backlog_value" "$FM_HOME" "$physical_home" \
    || fail "configured backlog is outside the active home: $backlog_value"
  configured_backlog=$NORMALIZED_HOME_PATH
  configured_backlog_dir=${configured_backlog%/*}
  contained_archive_parent_safe "$physical_home" "$configured_backlog_dir" \
    || fail "configured backlog directory is unsafe: $configured_backlog_dir"
  [ -d "$configured_backlog_dir" ] && [ ! -L "$configured_backlog_dir" ] \
    || fail "configured backlog directory is unsafe: $configured_backlog_dir"
  physical_backlog_dir=$(cd "$configured_backlog_dir" && pwd -P) \
    || fail "could not resolve configured backlog directory: $configured_backlog_dir"
  [ "$physical_backlog_dir" = "$configured_backlog_dir" ] \
    || fail "configured backlog directory escapes the active home: $configured_backlog_dir"
  [ -f "$configured_backlog" ] && [ ! -L "$configured_backlog" ] && [ -r "$configured_backlog" ] \
    || fail "configured backlog is not an ordinary readable file: $configured_backlog"
  links=$(file_link_count "$configured_backlog") \
    || fail "could not inspect configured backlog link count: $configured_backlog"
  [ "$links" = 1 ] || fail "configured backlog is hardlinked: $configured_backlog"
  DECISION_BACKLOG=$configured_backlog

  if [ -n "$archive_value" ]; then
    normalize_home_owned_path "$archive_value" "$FM_HOME" "$physical_home" \
      || fail "configured decision archive is outside the active home: $archive_value"
    configured_archive=$NORMALIZED_HOME_PATH
  else
    configured_archive="$physical_backlog_dir/done-archive.md"
  fi
  archive_dir=${configured_archive%/*}
  archive_name=${configured_archive##*/}
  [ -n "$archive_name" ] \
    || fail "configured decision archive directory is unsafe: $archive_dir"
  contained_archive_parent_safe "$physical_home" "$archive_dir" \
    || fail "configured decision archive directory is unsafe: $archive_dir"
  DECISION_ARCHIVE="$archive_dir/$archive_name"
  if [ "$DECISION_ARCHIVE" = "$configured_backlog" ] \
    || paths_destination_alias "$DECISION_ARCHIVE" "$configured_backlog"; then
    fail "configured decision archive aliases the active backlog: $DECISION_ARCHIVE"
  fi
  note_archive="$physical_backlog_dir/note-archive.md"
  if [ "$DECISION_ARCHIVE" = "$note_archive" ] \
    || paths_destination_alias "$DECISION_ARCHIVE" "$note_archive"; then
    fail "configured decision archive aliases the tasks-axi note archive: $DECISION_ARCHIVE"
  fi
}

RETENTION_OWNER_SCHEMA=fm-decision-retention-owner.v2
RETENTION_RECORD_SCHEMA=fm-decision-retention-record.v1
RETENTION_PROVENANCE_DIR=''
RETENTION_OWNER_TOKEN=''
RETENTION_OWNER_SECRET=''

retention_provenance_dir() {
  local create=$1 dir physical_dir
  RETENTION_PROVENANCE_DIR=''
  authoritative_archive_path
  dir="$DECISION_DATA/decision-retention-provenance"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    [ "$create" = 1 ] || return 1
    if ! (umask 077; mkdir "$dir") && [ ! -d "$dir" ]; then
      fail "could not create decision retention provenance directory: $dir"
    fi
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] \
    || fail "decision retention provenance directory is unsafe: $dir"
  physical_dir=$(cd "$dir" && pwd -P) \
    || fail "could not resolve decision retention provenance directory: $dir"
  [ "$physical_dir" = "$DECISION_DATA/decision-retention-provenance" ] \
    || fail "decision retention provenance directory escapes the active home: $dir"
  RETENTION_PROVENANCE_DIR=$physical_dir
}

retention_owner_content() {
  printf 'schema=%s\nbacklog=%s\narchive=%s\nowner=%s\nsecret=%s\n' \
    "$RETENTION_OWNER_SCHEMA" "$DECISION_BACKLOG" "$DECISION_ARCHIVE" "$1" "$2"
}

retention_owner_path() {
  local token
  token=$(sha256_text "${DECISION_BACKLOG}"$'\n'"${DECISION_ARCHIVE}")
  printf '%s/%s.owner\n' "$1" "$token"
}

require_safe_retention_file() {
  local label=$1 path=$2 links
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
    || fail "$label is unsafe: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect $label link count: $path"
  [ "$links" = 1 ] || fail "$label is hardlinked: $path"
}

require_safe_decision_archive() {
  local path=$1 links
  [ ! -L "$path" ] && [ -f "$path" ] && [ -r "$path" ] \
    || fail "decision archive is not an ordinary file: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect decision archive link count: $path"
  [ "$links" = 1 ] || fail "decision archive is hardlinked: $path"
}

retention_owner_load() {
  local dir=$1 owner token secret actual expected
  RETENTION_OWNER_TOKEN=''
  RETENTION_OWNER_SECRET=''
  owner=$(retention_owner_path "$dir")
  [ -e "$owner" ] || [ -L "$owner" ] || return 1
  require_safe_retention_file "decision retention owner" "$owner"
  token=$(meta_value "$owner" owner)
  secret=$(meta_value "$owner" secret)
  [ "${#token}" -eq 64 ] && [ "${#secret}" -eq 64 ] \
    || fail "decision retention owner is malformed: $owner"
  case "$token$secret" in *[!0-9a-f]*) fail "decision retention owner is malformed: $owner" ;; esac
  [ "$token" = "$(sha256_text "$RETENTION_RECORD_SCHEMA"$'\n'"$DECISION_BACKLOG"$'\n'"$DECISION_ARCHIVE")" ] \
    || fail "decision retention owner is malformed: $owner"
  expected=$(retention_owner_content "$token" "$secret")
  actual=$(cat "$owner") || fail "could not read decision retention owner: $owner"
  [ "$actual" = "$expected" ] || fail "decision retention owner is malformed: $owner"
  RETENTION_OWNER_TOKEN=$token
  RETENTION_OWNER_SECRET=$secret
}

ensure_retention_owner() {
  local dir owner lock path_token owner_token secret tmp
  retention_provenance_dir 1
  dir=$RETENTION_PROVENANCE_DIR
  if retention_owner_load "$dir"; then
    return 0
  fi
  owner=$(retention_owner_path "$dir")
  path_token=$(sha256_text "${DECISION_BACKLOG}"$'\n'"${DECISION_ARCHIVE}")
  lock="$dir/.owner-$path_token.lock"
  DECISION_RETENTION_LOCK=$lock
  fm_lock_acquire_wait "$DECISION_RETENTION_LOCK"
  DECISION_RETENTION_LOCK_HELD=1
  if retention_owner_load "$dir"; then
    fm_lock_release "$DECISION_RETENTION_LOCK"
    DECISION_RETENTION_LOCK_HELD=0
    return 0
  fi
  owner_token=$(sha256_text "$RETENTION_RECORD_SCHEMA"$'\n'"$DECISION_BACKLOG"$'\n'"$DECISION_ARCHIVE")
  secret=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))') \
    || fail "could not generate decision retention owner secret"
  tmp=$(umask 077; mktemp "$dir/.retention-owner.XXXXXX") \
    || fail "could not stage decision retention owner"
  if ! retention_owner_content "$owner_token" "$secret" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$owner"; then
    rm -f -- "$tmp"
    fail "could not persist decision retention owner"
  fi
  fm_lock_release "$DECISION_RETENTION_LOCK"
  DECISION_RETENTION_LOCK_HELD=0
  retention_owner_load "$dir" \
    || fail "could not validate decision retention owner"
}

RETENTION_MIGRATION_SCHEMA=fm-decision-retention-migration.v1

retention_migration_authorization_content() {  # <hold-id> <origin-id> <decision-key> <record-digest>
  printf 'schema=%s\nowner=%s\nbacklog=%s\narchive=%s\nhold_id=%s\norigin=%s\ndecision_key=%s\nrecord_digest=%s\n' \
    "$RETENTION_MIGRATION_SCHEMA" "$RETENTION_OWNER_TOKEN" "$DECISION_BACKLOG" \
    "$DECISION_ARCHIVE" "$1" "$2" "$3" "$4"
}

require_retention_migration_authorization() {  # <path> <hold-id> <origin-id> <decision-key> <record-digest>
  local input=$1 id=$2 origin=$3 key=$4 record_digest=$5
  local cwd physical_home logical_home input_path normalized input_parent expected_parent
  local physical_parent links expected expected_bytes actual_bytes actual
  [ -n "$input" ] || fail "pre-boundary retention history requires an independent --authorization-file"
  [ -d "$FM_HOME" ] || fail "active home is not a directory: $FM_HOME"
  cwd=$(pwd -P) || fail "could not resolve the current directory"
  physical_home=$(cd "$FM_HOME" && pwd -P) || fail "could not resolve active home: $FM_HOME"
  case "$FM_HOME" in /*) logical_home=$FM_HOME ;; *) logical_home="$cwd/$FM_HOME" ;; esac
  case "$input" in /*) input_path=$input ;; *) input_path="$cwd/$input" ;; esac
  normalize_home_owned_path "$input_path" "$logical_home" "$physical_home" \
    || fail "retention migration authorization is outside the active home: $input"
  normalized=$NORMALIZED_HOME_PATH
  input_parent=${input_path%/*}
  expected_parent=${normalized%/*}
  [ -d "$input_parent" ] && [ ! -L "$input_parent" ] \
    || fail "retention migration authorization directory is unsafe: $input"
  physical_parent=$(cd "$input_parent" && pwd -P) \
    || fail "could not resolve retention migration authorization directory: $input"
  [ "$physical_parent" = "$expected_parent" ] \
    || fail "retention migration authorization has an unsafe symlink path: $input"
  [ -f "$input_path" ] && [ ! -L "$input_path" ] && [ -r "$input_path" ] \
    || fail "retention migration authorization is not an ordinary readable file: $input"
  links=$(file_link_count "$input_path") \
    || fail "could not inspect retention migration authorization link count: $input"
  [ "$links" = 1 ] || fail "retention migration authorization is hardlinked: $input"
  expected=$(retention_migration_authorization_content "$id" "$origin" "$key" "$record_digest")
  expected_bytes=$(printf '%s\n' "$expected" | LC_ALL=C wc -c | tr -d ' ')
  actual_bytes=$(LC_ALL=C wc -c < "$input_path" | tr -d ' ')
  [ "$actual_bytes" = "$expected_bytes" ] \
    || fail "retention migration authorization does not match $origin/$key: $input"
  actual=$(cat "$input_path") \
    || fail "could not read retention migration authorization: $input"
  [ "$actual" = "$expected" ] \
    || fail "retention migration authorization does not match $origin/$key: $input"
}

retention_record_marker() {  # <hold-id> <record-digest>
  FM_DECISION_RETENTION_OWNER=$RETENTION_OWNER_TOKEN \
  FM_DECISION_RETENTION_SECRET=$RETENTION_OWNER_SECRET \
  FM_DECISION_RETENTION_BACKLOG=$DECISION_BACKLOG \
  FM_DECISION_RETENTION_ARCHIVE=$DECISION_ARCHIVE \
  FM_DECISION_RETENTION_SCHEMA=$RETENTION_RECORD_SCHEMA \
  node - "$1" "$2" <<'NODE'
const crypto = require("node:crypto");
const id = process.argv[2];
const digest = process.argv[3];
const owner = process.env.FM_DECISION_RETENTION_OWNER;
const secret = process.env.FM_DECISION_RETENTION_SECRET;
const backlog = process.env.FM_DECISION_RETENTION_BACKLOG;
const archive = process.env.FM_DECISION_RETENTION_ARCHIVE;
const schema = process.env.FM_DECISION_RETENTION_SCHEMA;
const payload = `${schema}\n${owner}\n${backlog}\n${archive}\n${id}\n${digest}`;
const mac = crypto.createHmac("sha256", secret).update(payload).digest("hex");
process.stdout.write(`<!-- fm-decision-retention:v1 owner=${owner} id=${id} record=${digest} mac=${mac} -->`);
NODE
}

publish_retention_migration_marker() {  # <marker> <expected-archive-digest>
  local marker=$1 expected_digest=$2 stamp
  stamp=$(date +%Y-%m-%d) || fail "could not determine retention migration date"
  node - "$DECISION_ARCHIVE" "$DECISION_BACKLOG" "$expected_digest" "$marker" "$stamp" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const archive = process.argv[2];
const backlog = process.argv[3];
const expectedDigest = process.argv[4];
const marker = process.argv[5];
const stamp = process.argv[6];
const lock = `${backlog}.lock`;
const token = `fm-decision-retention-migration:${process.pid}:${crypto.randomBytes(16).toString("hex")}`;
let locked = false;
function ordinarySingle(path) {
  const stat = fs.lstatSync(path);
  return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1;
}
function digest(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}
try {
  if (!ordinarySingle(backlog) || !ordinarySingle(archive)) throw new Error("unsafe retention owner");
  const fd = fs.openSync(lock, "wx", 0o600);
  fs.writeFileSync(fd, token, "utf8");
  fs.closeSync(fd);
  locked = true;
  if (!ordinarySingle(backlog) || !ordinarySingle(archive)) throw new Error("retention owner changed while locking");
  const before = fs.readFileSync(archive);
  if (digest(before) !== expectedDigest || !before.toString("utf8").endsWith("\n")) {
    throw new Error("retention archive changed before migration");
  }
  try {
    fs.appendFileSync(archive, `\n## Archived ${stamp}\n${marker}\n`, "utf8");
  } catch (error) {
    fs.truncateSync(archive, before.length);
    throw error;
  }
} finally {
  if (locked) {
    let observed = "";
    try { observed = fs.readFileSync(lock, "utf8"); } catch (_) {}
    if (observed === token) fs.unlinkSync(lock);
  }
}
NODE
}

tasks_axi_with_retention_provenance() {
  local hook hook_dir rc=0 prior_node_options=${NODE_OPTIONS:-}
  ensure_retention_owner
  hook_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-decision-retention.XXXXXX") \
    || fail "could not stage decision retention hook"
  hook="$hook_dir/hook.cjs"
  DECISION_RETENTION_HOOK_DIR=$hook_dir
  if [ -e "$DECISION_ARCHIVE" ] || [ -L "$DECISION_ARCHIVE" ]; then
    require_safe_decision_archive "$DECISION_ARCHIVE"
  fi
  cat > "$hook" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const moduleApi = require("node:module");
const path = require("node:path");

const originalAppendFileSync = fs.appendFileSync;
const archive = path.resolve(process.env.FM_DECISION_RETENTION_ARCHIVE);
const backlog = path.resolve(process.env.FM_DECISION_RETENTION_BACKLOG);
const owner = process.env.FM_DECISION_RETENTION_OWNER;
const secret = process.env.FM_DECISION_RETENTION_SECRET;
const schema = process.env.FM_DECISION_RETENTION_SCHEMA;

function archivedRecords(text) {
  const lines = String(text).split("\n");
  if (String(text).endsWith("\n")) lines.pop();
  const records = [];
  let archived = false;
  let current = null;
  function finish() {
    if (!current) return;
    while (current.body.length && current.body[current.body.length - 1] === "") current.body.pop();
    const match = /^- \[x\] ([^ ]+) - /.exec(current.header);
    if (match && match[1].includes("-decision-")) {
      records.push({ id: match[1], text: `${current.header}\n${current.body.join("\n")}` });
    }
    current = null;
  }
  for (const line of lines) {
    if (/^## Archived [0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(line)) {
      finish();
      archived = true;
      continue;
    }
    if (/^- \[[ x]\] /.test(line)) {
      finish();
      if (!archived) throw new Error("retention append lacks its archive section");
      current = { header: line, body: [] };
      continue;
    }
    if (current) {
      if (line === "") current.body.push("");
      else if (line.startsWith("  ")) current.body.push(line.slice(2));
      else throw new Error("retention append contains malformed task bytes");
      continue;
    }
    if (line !== "") throw new Error("retention append contains unexpected bytes");
  }
  finish();
  return records;
}

function marker(record) {
  const digest = crypto.createHash("sha256").update(record.text).digest("hex");
  const payload = `${schema}\n${owner}\n${backlog}\n${archive}\n${record.id}\n${digest}`;
  const mac = crypto.createHmac("sha256", secret).update(payload).digest("hex");
  return `<!-- fm-decision-retention:v1 owner=${owner} id=${record.id} record=${digest} mac=${mac} -->`;
}

fs.appendFileSync = function retentionAppend(target, data, ...rest) {
  if (path.resolve(String(target)) !== archive) return originalAppendFileSync.call(fs, target, data, ...rest);
  let restorePoint = { existed: false, size: 0 };
  try {
    const archiveStat = fs.lstatSync(target);
    if (!archiveStat.isFile() || archiveStat.isSymbolicLink() || archiveStat.nlink !== 1) {
      throw new Error("decision archive is not an ordinary single-linked file");
    }
    restorePoint = { existed: true, size: archiveStat.size };
  } catch (error) {
    if (!error || error.code !== "ENOENT") throw error;
  }
  const records = archivedRecords(data);
  if (records.length === 0) return originalAppendFileSync.call(fs, target, data, ...rest);
  const lock = `${backlog}.lock`;
  const lockStat = fs.lstatSync(lock);
  if (!lockStat.isFile() || lockStat.isSymbolicLink() || lockStat.nlink !== 1) throw new Error("decision retention append lacks the effective backlog lock");
  const suffix = `${records.map(marker).join("\n")}\n`;
  try {
    return originalAppendFileSync.call(fs, target, `${String(data)}${suffix}`, ...rest);
  } catch (error) {
    try {
      if (restorePoint.existed) fs.truncateSync(target, restorePoint.size);
      else fs.unlinkSync(target);
    } catch (_) {}
    throw error;
  }
};
moduleApi.syncBuiltinESMExports();
NODE
  if (
    export FM_DECISION_RETENTION_ARCHIVE=$DECISION_ARCHIVE
    export FM_DECISION_RETENTION_BACKLOG=$DECISION_BACKLOG
    export FM_DECISION_RETENTION_OWNER=$RETENTION_OWNER_TOKEN
    export FM_DECISION_RETENTION_SECRET=$RETENTION_OWNER_SECRET
    export FM_DECISION_RETENTION_SCHEMA=$RETENTION_RECORD_SCHEMA
    export FM_DECISION_RETENTION_ACTIVE=1
    export NODE_OPTIONS="--require=$hook${prior_node_options:+ $prior_node_options}"
    tasks_axi "$@"
  ); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && { [ -e "$DECISION_ARCHIVE" ] || [ -L "$DECISION_ARCHIVE" ]; }; then
    require_safe_decision_archive "$DECISION_ARCHIVE"
  fi
  rm -rf -- "$hook_dir"
  DECISION_RETENTION_HOOK_DIR=''
  return "$rc"
}

COMPLETION_INVENTORY_DIR=''
COMPLETION_INVENTORY_PATH=''

completion_inventory_dir() {  # <create: 0|1>
  local create=$1 dir physical_dir
  COMPLETION_INVENTORY_DIR=''
  authoritative_archive_path
  dir="$DECISION_DATA/decision-completion-inventories"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    [ "$create" = 1 ] || return 1
    if ! (umask 077; mkdir "$dir") && [ ! -d "$dir" ]; then
      fail "could not create decision completion inventory directory: $dir"
    fi
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] \
    || fail "decision completion inventory directory is unsafe: $dir"
  physical_dir=$(cd "$dir" && pwd -P) \
    || fail "could not resolve decision completion inventory directory: $dir"
  [ "$physical_dir" = "$DECISION_DATA/decision-completion-inventories" ] \
    || fail "decision completion inventory directory escapes the active home: $dir"
  COMPLETION_INVENTORY_DIR=$physical_dir
}

completion_inventory_path() {  # <directory> <origin-id>
  local token
  token=$(sha256_text "$2")
  printf '%s/%s.inventory\n' "$1" "$token"
}

completion_inventory_content() {  # <origin-id> <keys> <current> <historical> <last-current> <last-historical> <last-known>
  printf 'origin=%s\ndecisions_reviewed=1\ndecision_keys=%s\ndecision_inventory_schema=%s\ndecision_current_keys=%s\ndecision_historical_keys=%s\ndecision_last_current_keys=%s\ndecision_last_historical_keys=%s\ndecision_last_inventory_known=%s\n' \
    "$1" "$2" "$COMPLETION_INVENTORY_SCHEMA" "$3" "$4" "$5" "$6" "$7"
}

completion_inventory_lock_acquire() {  # <origin-id>
  local token
  completion_inventory_dir 1
  token=$(sha256_text "$1")
  COMPLETION_INVENTORY_PATH=$(completion_inventory_path "$COMPLETION_INVENTORY_DIR" "$1")
  DECISION_INVENTORY_LOCK="$COMPLETION_INVENTORY_DIR/.completion-$token.lock"
  fm_lock_acquire_wait "$DECISION_INVENTORY_LOCK"
  DECISION_INVENTORY_LOCK_HELD=1
}

completion_inventory_load_locked() {  # <origin-id>
  local origin=$1 path=$COMPLETION_INVENTORY_PATH links expected actual
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
    || fail "decision completion inventory is unsafe: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect decision completion inventory link count: $path"
  [ "$links" = 1 ] || fail "decision completion inventory is hardlinked: $path"
  completion_metadata_inventory "$path"
  [ "$META_DECISIONS_REVIEWED" = 1 ] && [ "$META_DECISION_INVENTORY_VERSIONED" = 1 ] \
    || fail "decision completion inventory is malformed: $path"
  [ "$(meta_value "$path" origin)" = "$origin" ] \
    || fail "decision completion inventory has mismatched origin ownership: $path"
  expected=$(completion_inventory_content "$origin" "$META_DECISION_KEYS" \
    "$META_DECISION_CURRENT_KEYS" "$META_DECISION_HISTORICAL_KEYS" \
    "$META_DECISION_LAST_CURRENT_KEYS" "$META_DECISION_LAST_HISTORICAL_KEYS" \
    "$META_DECISION_LAST_INVENTORY_KNOWN")
  actual=$(cat "$path") || fail "could not read decision completion inventory: $path"
  [ "$actual" = "$expected" ] || fail "decision completion inventory is malformed: $path"
}

completion_inventory_persist_locked() {  # <origin-id> <keys> <current> <historical> <last-current> <last-historical> <last-known>
  local origin=$1 path=$COMPLETION_INVENTORY_PATH tmp links
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] \
      || fail "decision completion inventory is unsafe: $path"
    links=$(file_link_count "$path") \
      || fail "could not inspect decision completion inventory link count: $path"
    [ "$links" = 1 ] || fail "decision completion inventory is hardlinked: $path"
  fi
  tmp=$(umask 077; mktemp "$COMPLETION_INVENTORY_DIR/.completion.XXXXXX") \
    || fail "could not stage decision completion inventory for $origin"
  if ! completion_inventory_content "$origin" "$2" "$3" "$4" "$5" "$6" "$7" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    fail "could not persist decision completion inventory for $origin"
  fi
  [ -f "$path" ] && [ ! -L "$path" ] \
    || fail "decision completion inventory is unsafe: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect decision completion inventory link count: $path"
  [ "$links" = 1 ] || fail "decision completion inventory is hardlinked: $path"
}

CURRENT_GENERATION_SCHEMA=fm-decision-current-generation.v2
CURRENT_GENERATION_OWNER=''
CURRENT_GENERATION_BACKLOG=''

current_generation_dir() {
  local dir physical_dir
  authoritative_archive_path
  dir="$DECISION_DATA/decision-current-generations"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if ! (umask 077; mkdir "$dir") && [ ! -d "$dir" ]; then
      fail "could not create decision generation directory: $dir"
    fi
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] \
    || fail "decision generation directory is unsafe: $dir"
  physical_dir=$(cd "$dir" && pwd -P) \
    || fail "could not resolve decision generation directory: $dir"
  [ "$physical_dir" = "$DECISION_DATA/decision-current-generations" ] \
    || fail "decision generation directory escapes the active home: $dir"
  printf '%s' "$physical_dir"
}

current_generation_path() {  # <origin-id> <decision-key>
  local dir token
  dir=$(current_generation_dir)
  token=$(sha256_text "$1"$'\n'"$2")
  printf '%s/%s.generation' "$dir" "$token"
}

current_generation_content() {  # <origin-id> <decision-key> <retention-owner>
  printf 'schema=%s\norigin=%s\ndecision_key=%s\nretention_owner=%s\nbacklog=%s\n' \
    "$CURRENT_GENERATION_SCHEMA" "$1" "$2" "$3" "$DECISION_BACKLOG"
}

current_generation_load() {  # <origin-id> <decision-key>
  local origin=$1 key=$2 path links schema owner backlog expected actual
  CURRENT_GENERATION_OWNER=''
  CURRENT_GENERATION_BACKLOG=''
  path=$(current_generation_path "$origin" "$key")
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
    || fail "decision generation binding is unsafe: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect decision generation binding link count: $path"
  [ "$links" = 1 ] || fail "decision generation binding is hardlinked: $path"
  schema=$(meta_value "$path" schema)
  owner=$(meta_value "$path" retention_owner)
  [ "${#owner}" -eq 64 ] || fail "decision generation binding is malformed: $path"
  case "$owner" in *[!0-9a-f]*) fail "decision generation binding is malformed: $path" ;; esac
  case "$schema" in
    fm-decision-current-generation.v1)
      expected=$(printf 'schema=%s\norigin=%s\ndecision_key=%s\nretention_owner=%s\n' \
        "$schema" "$origin" "$key" "$owner")
      backlog=''
      ;;
    "$CURRENT_GENERATION_SCHEMA")
      backlog=$(meta_value "$path" backlog)
      [ -n "$backlog" ] || fail "decision generation binding is malformed: $path"
      expected=$(printf 'schema=%s\norigin=%s\ndecision_key=%s\nretention_owner=%s\nbacklog=%s\n' \
        "$schema" "$origin" "$key" "$owner" "$backlog")
      ;;
    *) fail "decision generation binding is malformed: $path" ;;
  esac
  actual=$(cat "$path") || fail "could not read decision generation binding: $path"
  [ "$actual" = "$expected" ] || fail "decision generation binding is malformed: $path"
  CURRENT_GENERATION_OWNER=$owner
  CURRENT_GENERATION_BACKLOG=$backlog
}

persist_current_generation_owner() {  # <origin-id> <decision-key> [replace]
  local origin=$1 key=$2 replace=${3:-0} path dir tmp links
  ensure_retention_owner
  if [ "$replace" != 1 ] && current_generation_load "$origin" "$key" \
    && [ "$CURRENT_GENERATION_OWNER" != "$RETENTION_OWNER_TOKEN" ]; then
    [ -n "$CURRENT_GENERATION_BACKLOG" ] \
      && [ "$CURRENT_GENERATION_BACKLOG" = "$DECISION_BACKLOG" ] \
      || fail "captain decision $origin/$key belongs to a different retention generation"
  fi
  path=$(current_generation_path "$origin" "$key")
  dir=${path%/*}
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] \
      || fail "decision generation binding is unsafe: $path"
    links=$(file_link_count "$path") \
      || fail "could not inspect decision generation binding link count: $path"
    [ "$links" = 1 ] || fail "decision generation binding is hardlinked: $path"
  fi
  tmp=$(umask 077; mktemp "$dir/.generation.XXXXXX") \
    || fail "could not stage decision generation binding for $origin/$key"
  if ! current_generation_content "$origin" "$key" "$RETENTION_OWNER_TOKEN" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    fail "could not persist decision generation binding for $origin/$key"
  fi
}

require_current_generation_owner() {  # <origin-id> <decision-key>
  ensure_retention_owner
  current_generation_load "$1" "$2" \
    || fail "current decision $1/$2 lacks durable generation provenance"
  [ "$CURRENT_GENERATION_OWNER" = "$RETENTION_OWNER_TOKEN" ] \
    || fail "current decision $1/$2 belongs to a different retention generation"
}

check_current_generation_owner_if_present() {  # <origin-id> <decision-key>
  ensure_retention_owner
  if current_generation_load "$1" "$2"; then
    [ "$CURRENT_GENERATION_OWNER" = "$RETENTION_OWNER_TOKEN" ] \
      || fail "captain decision $1/$2 belongs to a different retention generation"
  fi
}

persist_visible_resolved_generation_owner() {  # <origin-id> <decision-key>
  local origin=$1 key=$2
  ensure_retention_owner
  if current_generation_load "$origin" "$key" \
    && [ "$CURRENT_GENERATION_OWNER" != "$RETENTION_OWNER_TOKEN" ]; then
    [ -n "$CURRENT_GENERATION_BACKLOG" ] \
      && [ "$CURRENT_GENERATION_BACKLOG" = "$DECISION_BACKLOG" ] \
      || fail "captain decision $origin/$key belongs to a different retention generation"
  fi
  persist_current_generation_owner "$origin" "$key"
}

LEGACY_ATTESTATION_SCHEMA=fm-decision-legacy-resolution.v1
LEGACY_ATTESTATION_DIR=''

legacy_resolution_attestation_dir() {  # <create: 0|1>
  local create=$1 dir physical_dir
  LEGACY_ATTESTATION_DIR=''
  authoritative_archive_path
  dir="$DECISION_DATA/decision-resolution-attestations"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    [ "$create" = 1 ] || return 1
    if ! (umask 077; mkdir "$dir") && [ ! -d "$dir" ]; then
      fail "could not create decision resolution attestation directory: $dir"
    fi
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] \
    || fail "decision resolution attestation directory is unsafe: $dir"
  physical_dir=$(cd "$dir" && pwd -P) \
    || fail "could not resolve decision resolution attestation directory: $dir"
  [ "$physical_dir" = "$DECISION_DATA/decision-resolution-attestations" ] \
    || fail "decision resolution attestation directory escapes the active home: $dir"
  LEGACY_ATTESTATION_DIR=$physical_dir
}

legacy_resolution_attestation_content() {  # <hold-id> <origin-id> <decision-key> <record-digest>
  printf 'schema=%s\nhold_id=%s\norigin=%s\ndecision_key=%s\nrecord_digest=%s\n' \
    "$LEGACY_ATTESTATION_SCHEMA" "$1" "$2" "$3" "$4"
}

legacy_resolution_attestation_path() {  # <directory> <hold-id>
  local token
  token=$(sha256_text "$2")
  printf '%s/%s.attestation\n' "$1" "$token"
}

legacy_resolution_attestation_lock_acquire() {  # <directory> <hold-id>
  local token
  token=$(sha256_text "$2")
  DECISION_ATTESTATION_LOCK="$1/.attestation-$token.lock"
  fm_lock_acquire_wait "$DECISION_ATTESTATION_LOCK"
  DECISION_ATTESTATION_LOCK_HELD=1
}

legacy_resolution_attestation_lock_release() {
  fm_lock_release "$DECISION_ATTESTATION_LOCK"
  DECISION_ATTESTATION_LOCK_HELD=0
}

legacy_resolution_attestation_canonicalize() {  # <directory> <path> <content> <origin-id> <decision-key>
  local dir=$1 path=$2 expected=$3 origin=$4 key=$5 tmp links actual
  tmp=$(umask 077; mktemp "$dir/.attestation-finalize.XXXXXX") \
    || fail "could not finalize decision resolution attestation for $origin/$key"
  if ! printf '%s\n' "$expected" > "$tmp" || ! chmod 0600 "$tmp" \
    || ! mv -f "$tmp" "$path"; then
    rm -f -- "$tmp"
    fail "could not finalize decision resolution attestation for $origin/$key"
  fi
  [ -f "$path" ] && [ ! -L "$path" ] \
    || fail "decision resolution attestation is not an ordinary file: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect decision resolution attestation link count: $path"
  [ "$links" = 1 ] || fail "decision resolution attestation is hardlinked: $path"
  actual=$(cat "$path") || fail "could not read decision resolution attestation: $path"
  [ "$actual" = "$expected" ] \
    || fail "decision resolution attestation does not match $origin/$key: $path"
}

legacy_resolution_attestation_valid_locked() {  # <directory> <path> <hold-id> <origin-id> <decision-key> <record-digest>
  local dir=$1 path=$2 id=$3 origin=$4 key=$5 record_digest=$6
  local links actual expected prefix stage_name suffix stage stage_links
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] \
    || fail "decision resolution attestation is not an ordinary file: $path"
  links=$(file_link_count "$path") \
    || fail "could not inspect decision resolution attestation link count: $path"
  actual=$(cat "$path") || fail "could not read decision resolution attestation: $path"
  expected=$(legacy_resolution_attestation_content "$id" "$origin" "$key" "$record_digest")
  if [ "$actual" = "$expected" ]; then
    [ "$links" = 1 ] || fail "decision resolution attestation is hardlinked: $path"
    return 0
  fi
  prefix="${expected}"$'\n''publication_stage='
  case "$actual" in
    "$prefix"*) stage_name=${actual#"$prefix"} ;;
    *) fail "decision resolution attestation does not match $origin/$key: $path" ;;
  esac
  case "$stage_name" in .attestation.??????) : ;; *) fail "decision resolution attestation has invalid publication provenance: $path" ;; esac
  suffix=${stage_name#.attestation.}
  case "$suffix" in *[!A-Za-z0-9]*) fail "decision resolution attestation has invalid publication provenance: $path" ;; esac
  [ "$actual" = "${expected}"$'\n'"publication_stage=$stage_name" ] \
    || fail "decision resolution attestation does not match $origin/$key: $path"
  if [ "$links" = 2 ]; then
    stage="$dir/$stage_name"
    [ -f "$stage" ] && [ ! -L "$stage" ] && [ "$stage" -ef "$path" ] \
      || fail "decision resolution attestation has unauthenticated publication link: $path"
    stage_links=$(file_link_count "$stage") \
      || fail "could not inspect staged decision resolution attestation: $stage"
    [ "$stage_links" = 2 ] \
      || fail "decision resolution attestation has unauthenticated publication link: $path"
    rm -f -- "$stage" \
      || fail "could not recover staged decision resolution attestation: $stage"
    links=$(file_link_count "$path") \
      || fail "could not inspect decision resolution attestation link count: $path"
  fi
  [ "$links" = 1 ] || fail "decision resolution attestation is hardlinked: $path"
  legacy_resolution_attestation_canonicalize "$dir" "$path" "$expected" "$origin" "$key"
}

legacy_resolution_attestation_valid() {  # <hold-id> <origin-id> <decision-key> <record-digest>
  local id=$1 origin=$2 key=$3 record_digest=$4 dir path rc=0
  legacy_resolution_attestation_dir 0 || return 1
  dir=$LEGACY_ATTESTATION_DIR
  path=$(legacy_resolution_attestation_path "$dir" "$id")
  [ -e "$path" ] || [ -L "$path" ] || return 1
  legacy_resolution_attestation_lock_acquire "$dir" "$id"
  legacy_resolution_attestation_valid_locked "$dir" "$path" "$id" "$origin" "$key" "$record_digest" || rc=$?
  legacy_resolution_attestation_lock_release
  return "$rc"
}

persist_legacy_resolution_attestation() {  # <hold-id> <origin-id> <decision-key> <record-digest>
  local id=$1 origin=$2 key=$3 record_digest=$4 dir path tmp stage rc=0
  legacy_resolution_attestation_valid "$id" "$origin" "$key" "$record_digest" && return 0
  legacy_resolution_attestation_dir 1
  dir=$LEGACY_ATTESTATION_DIR
  path=$(legacy_resolution_attestation_path "$dir" "$id")
  legacy_resolution_attestation_lock_acquire "$dir" "$id"
  if legacy_resolution_attestation_valid_locked "$dir" "$path" "$id" "$origin" "$key" "$record_digest"; then
    legacy_resolution_attestation_lock_release
    return 0
  fi
  tmp=$(umask 077; mktemp "$dir/.attestation.XXXXXX") \
    || fail "could not stage decision resolution attestation for $origin/$key"
  stage=${tmp##*/}
  if ! legacy_resolution_attestation_content "$id" "$origin" "$key" "$record_digest" > "$tmp" \
    || ! printf 'publication_stage=%s\n' "$stage" >> "$tmp" \
    || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    fail "could not stage decision resolution attestation for $origin/$key"
  fi
  if ! ln "$tmp" "$path" 2>/dev/null; then
    rm -f -- "$tmp"
    if legacy_resolution_attestation_valid_locked "$dir" "$path" "$id" "$origin" "$key" "$record_digest"; then
      legacy_resolution_attestation_lock_release
      return 0
    fi
    rc=1
  elif ! legacy_resolution_attestation_valid_locked "$dir" "$path" "$id" "$origin" "$key" "$record_digest"; then
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    legacy_resolution_attestation_lock_release
    fail "could not record decision resolution attestation for $origin/$key"
  fi
  legacy_resolution_attestation_lock_release
}

persist_parsed_legacy_resolution() {  # <hold-id> <origin-id> <decision-key>
  [ -z "$RESOLUTION_ORIGIN" ] && [ -z "$RESOLUTION_KEY" ] || return 0
  persist_legacy_resolution_attestation "$1" "$2" "$3" "$RESOLUTION_RECORD_DIGEST"
}

archived_header_has_captain_provenance() {  # <header> <hold-id>
  local header=$1 id=$2 rest kind='' hold_kind='' value
  local kind_seen=0 hold_kind_seen=0 hold_seen=0 repo_seen=0
  local re_dep='^(.*)[[:space:]]+(blocked-by|parent|discovered-from):[[:space:]]+[A-Za-z0-9][A-Za-z0-9._-]*([[:space:]]+-[[:space:]].*)?[[:space:]]*$'
  local re_repo='^(.*)[[:space:]]+\(repo:[[:space:]]*([^)]*)\)[[:space:]]*$'
  local re_kind='^(.*)[[:space:]]+\(kind:[[:space:]]*([^)]*)\)[[:space:]]*$'
  local re_priority='^(.*)[[:space:]]+\(priority:[[:space:]]*[0-4]\)[[:space:]]*$'
  local re_since='^(.*)[[:space:]]+\(since[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\)[[:space:]]*$'
  local re_closed='^(.*)[[:space:]]+\((merged|reported|done|closed)[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\)[[:space:]]*$'
  local re_hold_until='^(.*)[[:space:]]+\(hold-until:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}\)[[:space:]]*$'
  local re_hold_kind='^(.*)[[:space:]]+\(hold-kind:[[:space:]]*(captain|external|load|parked|future)\)[[:space:]]*$'
  local re_hold='^(.*)[[:space:]]+\(hold:[[:space:]]*([^()]*)\)[[:space:]]*$'
  case "$header" in "- [x] $id - "*) rest=${header#"- [x] $id - "} ;; *) return 1 ;; esac
  while :; do
    if [[ "$rest" =~ $re_dep ]]; then
      rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ $re_repo ]]; then
      [ "$kind_seen" -eq 1 ] && [ "$hold_kind_seen" -eq 1 ] && [ "$hold_seen" -eq 1 ] \
        || return 1
      repo_seen=1
      rest=${BASH_REMATCH[1]}
      break
    elif [[ "$rest" =~ $re_kind ]]; then
      [ "$kind_seen" -eq 0 ] || return 1
      value=${BASH_REMATCH[2]}
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      kind=$value
      kind_seen=1
      [ "$kind" = captain ] && [ "$hold_kind_seen" -eq 1 ] && [ "$hold_seen" -eq 1 ] \
        || return 1
      rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ $re_priority ]]; then
      rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ $re_since ]]; then
      rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ $re_closed ]]; then
      rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ $re_hold_until ]]; then
      rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ $re_hold_kind ]]; then
      if [ "$hold_kind_seen" -eq 0 ]; then
        hold_kind=${BASH_REMATCH[2]}
        hold_kind_seen=1
      fi
      rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ $re_hold ]]; then
      value=${BASH_REMATCH[2]}
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [ -n "$value" ] || return 1
      [ "$hold_seen" -eq 1 ] || hold_seen=1
      rest=${BASH_REMATCH[1]}
    else
      break
    fi
  done
  [ "$repo_seen" -eq 1 ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ] \
    && [ "$hold_seen" -eq 1 ]
}

# Load one normally pruned Done record without moving it back into the bounded
# backlog window. The archive path is the tracked tasks-axi configuration's
# durable history owner. Only an exact, single, ordinary captain-hold record with
# this owner's resolution body can prove a historical decision.
ARCHIVED_HOLD_BODY=''
ARCHIVED_HOLD_RECORD=''
ARCHIVED_HOLD_RECORD_DIGEST=''
ARCHIVED_HOLD_PROVENANCE=''

prepare_decision_archive_cache() {
  local archive=$1 id=$2 dir rc owner='' secret=''
  if [ -n "$DECISION_ARCHIVE_CACHE_DIR" ] \
    && [ "$DECISION_ARCHIVE_CACHE_PATH" = "$archive" ]; then
    return 0
  fi
  if [ -n "$DECISION_ARCHIVE_CACHE_DIR" ] && [ -d "$DECISION_ARCHIVE_CACHE_DIR" ] \
    && [ ! -L "$DECISION_ARCHIVE_CACHE_DIR" ]; then
    rm -rf -- "$DECISION_ARCHIVE_CACHE_DIR"
  fi
  DECISION_ARCHIVE_CACHE_DIR=''
  DECISION_ARCHIVE_CACHE_PATH=''
  if retention_provenance_dir 0 && retention_owner_load "$RETENTION_PROVENANCE_DIR"; then
    owner=$RETENTION_OWNER_TOKEN
    secret=$RETENTION_OWNER_SECRET
  fi
  dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-decision-archive.XXXXXX") \
    || fail "could not stage decision archive index"
  DECISION_ARCHIVE_CACHE_DIR=$dir
  if node - "$archive" "$dir" "$owner" "$secret" "$DECISION_BACKLOG" \
    "$DECISION_ARCHIVE" "$RETENTION_RECORD_SCHEMA" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const archive = process.argv[2];
const directory = process.argv[3];
const owner = process.argv[4];
const secret = process.argv[5];
const backlog = process.argv[6];
const configuredArchive = process.argv[7];
const schema = process.argv[8];

function read(source) {
  try {
    return fs.readFileSync(source, "utf8");
  } catch (_) {
    process.exit(4);
  }
}

function parse(text) {
  const lines = text.split("\n");
  if (text.endsWith("\n")) lines.pop();
  const records = [];
  const markers = [];
  let archived = false;
  let entry = false;
  let current = null;

  function finish() {
    if (!current) return;
    while (current.body.length && current.body[current.body.length - 1] === "") current.body.pop();
    const match = /^- \[x\] ([^ ]+) - /.exec(current.header);
    if (match && match[1].includes("-decision-")) {
      const text = `${current.header}\n${current.body.join("\n")}`;
      records.push({
        id: match[1],
        text,
        digest: crypto.createHash("sha256").update(text).digest("hex"),
      });
    }
    current = null;
  }

  for (const line of lines) {
    if (/^## Archived [0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(line)) {
      finish();
      entry = false;
      archived = true;
      continue;
    }
    if (/^## /.test(line)) {
      finish();
      entry = false;
      archived = false;
      continue;
    }
    if (/^- \[[ x]\] /.test(line)) {
      finish();
      entry = archived;
      if (archived) current = { header: line, body: [] };
      continue;
    }
    if (line.startsWith("<!-- fm-decision-retention:")) {
      finish();
      const match = /^<!-- fm-decision-retention:v1 owner=([0-9a-f]{64}) id=([A-Za-z0-9._-]+) record=([0-9a-f]{64}) mac=([0-9a-f]{64}) -->$/.exec(line);
      if (!archived || !match) throw new Error("malformed retention marker");
      markers.push({ owner: match[1], id: match[2], digest: match[3], mac: match[4] });
      entry = false;
      continue;
    }
    if (current) {
      if (line === "") {
        current.body.push("");
        continue;
      }
      if (line.startsWith("  ")) {
        current.body.push(line.slice(2));
        continue;
      }
      throw new Error("malformed archive");
    }
    if (archived && entry && line.startsWith("  ")) continue;
    if (archived && line !== "") throw new Error("malformed archive");
  }
  finish();
  return { records, markers };
}

let parsed;
try {
  parsed = parse(read(archive));
} catch (_) {
  process.exit(3);
}
const byRecord = new Map();
for (const current of parsed.records) byRecord.set(`${current.id}\0${current.digest}`, current);
const proven = new Map();
for (const marker of parsed.markers) {
  if (marker.owner !== owner) continue;
  const current = byRecord.get(`${marker.id}\0${marker.digest}`);
  if (!current || secret === "") process.exit(3);
  const payload = `${schema}\n${owner}\n${backlog}\n${configuredArchive}\n${marker.id}\n${marker.digest}`;
  const expected = crypto.createHmac("sha256", secret).update(payload).digest("hex");
  if (marker.mac !== expected) process.exit(3);
  const key = `${marker.id}\0${marker.digest}`;
  proven.set(key, (proven.get(key) ?? 0) + 1);
}
for (const current of parsed.records) {
  const token = crypto.createHash("sha256").update(current.id).digest("hex");
  const record = path.join(directory, `${token}.record`);
  const duplicate = path.join(directory, `${token}.duplicate`);
  const provenance = path.join(directory, `${token}.provenance`);
  if (fs.existsSync(record)) {
    fs.writeFileSync(duplicate, "", { mode: 0o600 });
  } else {
    fs.writeFileSync(record, current.text, { flag: "wx", mode: 0o600 });
  }
  const count = proven.get(`${current.id}\0${current.digest}`) ?? 0;
  if (count > 1) process.exit(3);
  if (count === 1) fs.writeFileSync(provenance, current.digest, { flag: "wx", mode: 0o600 });
}
NODE
  then
    DECISION_ARCHIVE_CACHE_PATH=$archive
    return 0
  else
    rc=$?
    rm -rf -- "$DECISION_ARCHIVE_CACHE_DIR"
    DECISION_ARCHIVE_CACHE_DIR=''
    DECISION_ARCHIVE_CACHE_PATH=''
    [ "$rc" -ne 3 ] || fail "captain decision $id has a malformed archived record"
    fail "could not index decision archive: $archive"
  fi
}

reset_decision_archive_cache() {
  if [ -n "$DECISION_ARCHIVE_CACHE_DIR" ] && [ -d "$DECISION_ARCHIVE_CACHE_DIR" ] \
    && [ ! -L "$DECISION_ARCHIVE_CACHE_DIR" ]; then
    rm -rf -- "$DECISION_ARCHIVE_CACHE_DIR"
  fi
  DECISION_ARCHIVE_CACHE_DIR=''
  DECISION_ARCHIVE_CACHE_PATH=''
}

archived_hold_record() {  # <hold-id>
  local id=$1 archive links record provenance header='' body='' token duplicate
  ARCHIVED_HOLD_BODY=''
  ARCHIVED_HOLD_RECORD=''
  ARCHIVED_HOLD_RECORD_DIGEST=''
  ARCHIVED_HOLD_PROVENANCE=''
  authoritative_archive_path
  archive=$DECISION_ARCHIVE
  [ -e "$archive" ] || [ -L "$archive" ] || return 1
  require_safe_decision_archive "$archive"
  [ "$DECISION_ARCHIVE_CACHE_ENABLED" = 1 ] \
    || fail "decision archive provenance index is disabled"
  prepare_decision_archive_cache "$archive" "$id"
  token=$(sha256_text "$id")
  record="$DECISION_ARCHIVE_CACHE_DIR/$token.record"
  duplicate="$DECISION_ARCHIVE_CACHE_DIR/$token.duplicate"
  provenance="$DECISION_ARCHIVE_CACHE_DIR/$token.provenance"
  [ ! -e "$duplicate" ] \
    || fail "captain decision $id has duplicate archived records"
  [ -e "$record" ] || return 1
  [ -f "$record" ] && [ ! -L "$record" ] \
    || fail "captain decision $id has an unsafe archived index record"
  links=$(file_link_count "$record") \
    || fail "could not inspect captain decision $id archived index record"
  [ "$links" = 1 ] \
    || fail "captain decision $id has a hardlinked archived index record"
  IFS= read -r header < "$record" \
    || fail "captain decision $id has a malformed archived record"
  body=$(tail -n +2 "$record") \
    || fail "captain decision $id has a malformed archived record"
  while [ "${body%$'\n'}" != "$body" ]; do body=${body%$'\n'}; done
  archived_header_has_captain_provenance "$header" "$id" \
    || fail "captain decision $id has mismatched archived captain-hold provenance"
  ARCHIVED_HOLD_RECORD=$(cat "$record") \
    || fail "could not read captain decision $id archived index record"
  ARCHIVED_HOLD_RECORD_DIGEST=$(sha256_text "$ARCHIVED_HOLD_RECORD")
  ARCHIVED_HOLD_PROVENANCE=$provenance
  ARCHIVED_HOLD_BODY=$body
}

archived_hold_body() {  # <hold-id>
  local id=$1 links provenance
  archived_hold_record "$id" || return 1
  provenance=$ARCHIVED_HOLD_PROVENANCE
  [ -f "$provenance" ] && [ ! -L "$provenance" ] \
    || fail "captain decision $id lacks provenance from its configured Done retention transition"
  links=$(file_link_count "$provenance") \
    || fail "could not inspect captain decision $id archived provenance"
  [ "$links" = 1 ] || fail "captain decision $id has hardlinked archived provenance"
}

archived_hold_resolved() {  # <hold-id> <origin-id> <decision-key>
  local id=$1 origin=$2 key=$3
  archived_hold_body "$id" || return 1
  resolution_record_valid "$ARCHIVED_HOLD_BODY" "$origin" "$key" \
    || fail "captain decision $id has a malformed or mismatched archived resolution"
}

reject_archived_generation_collision() {  # <hold-id>
  local id=$1
  if archived_hold_body "$id"; then
    fail "captain decision $id has both backlog and archived generations"
  fi
}

resolution_body() {  # <origin-id> <decision-key> <mode> <routed-csv> [routed-task-id...]
  local origin=$1 key=$2 mode=$3 routed_csv=$4 body dep
  shift 4
  # Command substitution strips the trailing newline, so restore it before the
  # routed-work list to keep each entry on its own durable backlog line.
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: %s\nDecision digest: %s\nRouted identities: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n\nRouted work:' \
    "$origin" "$key" "$DECISION_DIGEST" "$routed_csv" "$mode" "$DECISION_TEXT")
  body="${body}"$'\n'
  if [ "$#" -eq 0 ]; then
    body="${body}${ROUTED_NONE}"$'\n'
  else
    for dep in "$@"; do
      body="${body}- ${dep}"$'\n'
    done
  fi
  printf '%s' "$body"
}

# tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
normalized_blocked_by() {  # <show-output>
  local blocked
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  printf '%s' "$blocked"
}

# Space-separated ids of live work still blocked by <hold-id>. The listing is only
# a cheap prefilter whose first field is always an unquoted id; every candidate is
# confirmed against its own authoritative record before it is reported.
tasks_blocked_by() {  # <hold-id>
  local id=$1 rows row candidate show found=''
  rows=$(tasks_axi list --fields blocked_by) \
    || fail "could not read backlog work while checking what $id still blocks"
  while IFS= read -r row; do
    case "$row" in
      *"$id"*) : ;;
      *) continue ;;
    esac
    candidate=${row%%,*}
    candidate=${candidate// /}
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$id" ] || continue
    task_id_valid "$candidate" || continue
    show=$(task_show "$candidate") || continue
    list_has_key "$(normalized_blocked_by "$show")" "$id" || continue
    found="${found}${found:+ }$candidate"
  done <<EOF
$rows
EOF
  printf '%s' "$found"
}

verify_hold_active() {  # <hold-id> <origin-id> <decision-key> [new-generation]
  local id=$1 origin=$2 key=$3 new_generation=${4:-0} show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
  queued_hold_body_valid "$body" "$origin" "$key" \
    || fail "captain hold $id has malformed or mismatched active provenance"
  reject_archived_generation_collision "$id"
  persist_current_generation_owner "$origin" "$key" "$new_generation"
}

RESOLVED_HOLD_BODY=''
verify_hold_resolved() {  # <hold-id> <origin-id> <decision-key>
  local id=$1 origin=$2 key=$3 show state kind hold_kind body
  RESOLVED_HOLD_BODY=''
  if task_show_optional "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    hold_kind=$(show_field "$show" hold_kind)
    body=$(show_field "$show" body)
    [ "$state" = "done" ] || return 1
    [ "$kind" = captain ] || return 1
    [ "$hold_kind" = captain ] || return 1
    body_has_resolution_record "$body" "$origin" "$key" || return 1
    reject_archived_generation_collision "$id"
    persist_visible_resolved_generation_owner "$origin" "$key"
    RESOLVED_HOLD_BODY=$body
    return 0
  fi
  reset_decision_archive_cache
  archived_hold_resolved "$id" "$origin" "$key" || return 1
  check_current_generation_owner_if_present "$origin" "$key"
  RESOLVED_HOLD_BODY=$ARCHIVED_HOLD_BODY
}

verify_hold_current_resolved() {  # <origin-id> <decision-key>
  local origin=$1 key=$2 id
  id=$(hold_id "$origin" "$key")
  verify_hold_resolved "$id" "$origin" "$key" \
    || fail "captain decision $id is not durably resolved"
  require_current_generation_owner "$origin" "$key"
}

verify_hold_historical() {  # <origin-id> <decision-key>
  local origin=$1 key=$2 id show state kind hold_kind body
  id=$(hold_id "$origin" "$key")
  if task_show_optional "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    hold_kind=$(show_field "$show" hold_kind)
    body=$(show_field "$show" body)
    if [ "$state" = "done" ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ] \
      && body_has_resolution_record "$body" "$origin" "$key"; then
      reject_archived_generation_collision "$id"
      ensure_retention_owner
      persist_parsed_legacy_resolution "$id" "$origin" "$key"
      return 0
    fi
    fail "captain decision $id is not durably resolved"
  fi
  if archived_hold_resolved "$id" "$origin" "$key"; then
    persist_parsed_legacy_resolution "$id" "$origin" "$key"
    return 0
  fi
  fail "captain decision $id is absent from $FM_HOME/data/backlog.md and is not durably resolved in its archive"
}

verify_hold_durable() {  # <origin-id> <decision-key>
  local origin=$1 key=$2 id show state held kind hold_kind body
  id=$(hold_id "$origin" "$key")
  if task_show_optional "$id"; then
    show=$TASK_SHOW_OUTPUT
  else
    if archived_hold_resolved "$id" "$origin" "$key"; then
      require_current_generation_owner "$origin" "$key"
      persist_parsed_legacy_resolution "$id" "$origin" "$key"
      return 0
    fi
    fail "captain decision $id is absent from $FM_HOME/data/backlog.md and is not durably resolved in its archive"
  fi
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    queued_hold_body_valid "$body" "$origin" "$key" \
      || fail "captain decision $id has malformed or mismatched active provenance"
    reject_archived_generation_collision "$id"
    persist_current_generation_owner "$origin" "$key"
    if resolution_record_valid "$body" "$origin" "$key"; then
      persist_parsed_legacy_resolution "$id" "$origin" "$key"
    fi
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ] \
    && body_has_resolution_record "$body" "$origin" "$key"; then
    reject_archived_generation_collision "$id"
    persist_visible_resolved_generation_owner "$origin" "$key"
    persist_parsed_legacy_resolution "$id" "$origin" "$key"
    return 0
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

LEGACY_SOURCE_CURRENT_KEYS=''
LEGACY_SOURCE_UNCLASSIFIED_KEYS=''

classify_legacy_source_generations() {  # <origin-id> <comma-keys>
  local origin=$1 keys=$2 key id show state held kind hold_kind body
  LEGACY_SOURCE_CURRENT_KEYS=''
  LEGACY_SOURCE_UNCLASSIFIED_KEYS=''
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    id=$(hold_id "$origin" "$key")
    if ! task_show_optional "$id"; then
      LEGACY_SOURCE_UNCLASSIFIED_KEYS=$(sorted_key_union "$LEGACY_SOURCE_UNCLASSIFIED_KEYS" "$key")
      continue
    fi
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    held=$(show_field "$show" held)
    kind=$(show_field "$show" kind)
    hold_kind=$(show_field "$show" hold_kind)
    body=$(show_field "$show" body)
    if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] \
      && [ "$hold_kind" = captain ]; then
      queued_hold_body_valid "$body" "$origin" "$key" \
        || fail "captain decision $id has malformed or mismatched active provenance"
      reject_archived_generation_collision "$id"
      persist_current_generation_owner "$origin" "$key"
      if resolution_record_valid "$body" "$origin" "$key"; then
        persist_parsed_legacy_resolution "$id" "$origin" "$key"
      fi
    elif [ "$state" = "done" ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ] \
      && body_has_resolution_record "$body" "$origin" "$key"; then
      reject_archived_generation_collision "$id"
      persist_visible_resolved_generation_owner "$origin" "$key"
      persist_parsed_legacy_resolution "$id" "$origin" "$key"
    else
      fail "captain decision $id is not a source-verifiable active or retained Done generation"
    fi
    LEGACY_SOURCE_CURRENT_KEYS=$(sorted_key_union "$LEGACY_SOURCE_CURRENT_KEYS" "$key")
  done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
}

verify_resolution_identity() {  # <hold-id> <origin-id> <decision-key> <body> <digest> <routed-csv>
  local id=$1 origin=$2 key=$3 hold_body=$4 decision_digest=$5 routed_csv=$6
  resolution_record_valid "$hold_body" "$origin" "$key" \
    || fail "captain hold $id has an invalid or mismatched retry identity record"
  [ "$RESOLUTION_DIGEST" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$RESOLUTION_ROUTES" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_migrate_retention() {
  local origin=${1:-} key=${2:-} authorization_file='' id marker archive_digest
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --authorization-file) shift; authorization_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  ensure_retention_owner
  id=$(hold_id "$origin" "$key")
  archived_hold_record "$id" \
    || fail "captain decision $id is absent from the configured retention archive"
  if [ -f "$ARCHIVED_HOLD_PROVENANCE" ] && [ ! -L "$ARCHIVED_HOLD_PROVENANCE" ]; then
    archived_hold_resolved "$id" "$origin" "$key" \
      || fail "captain decision $id is not a valid archived resolution"
    printf 'migrated-retention: %s already proven\n' "$id"
    return 0
  fi
  resolution_record_valid "$ARCHIVED_HOLD_BODY" "$origin" "$key" \
    || fail "captain decision $id has a malformed or mismatched archived resolution"
  require_retention_migration_authorization "$authorization_file" "$id" "$origin" "$key" \
    "$ARCHIVED_HOLD_RECORD_DIGEST"
  archive_digest=$(sha256_file "$DECISION_ARCHIVE")
  marker=$(retention_record_marker "$id" "$ARCHIVED_HOLD_RECORD_DIGEST") \
    || fail "could not create retention migration provenance for $id"
  publish_retention_migration_marker "$marker" "$archive_digest" \
    || fail "could not publish retention migration provenance for $id"
  reset_decision_archive_cache
  archived_hold_resolved "$id" "$origin" "$key" \
    || fail "retention migration did not prove captain decision $id"
  persist_parsed_legacy_resolution "$id" "$origin" "$key"
  printf 'migrated-retention: %s\n' "$id"
}

command_migrate_legacy() {
  local origin=${1:-} key=${2:-} decision_file='' identity_file='' id meta show state held kind hold_kind body
  local has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --identity-file) shift; identity_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  authoritative_state_path
  meta="$DECISION_STATE/$origin.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    has_meta=1
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    reviewed_decision_inventory "$meta" \
      || fail "origin $origin has no surviving reviewed decision inventory"
    list_has_key "$META_DECISION_KEYS" "$key" \
      || fail "origin $origin does not review decision key $key"
  fi
  load_decision "$decision_file"
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if task_show_optional "$id"; then
    reject_archived_generation_collision "$id"
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    held=$(show_field "$show" held)
    kind=$(show_field "$show" kind)
    hold_kind=$(show_field "$show" hold_kind)
    body=$(show_field "$show" body)
    [ "$kind" = captain ] && [ "$hold_kind" = captain ] \
      || fail "backlog item $id does not retain captain-hold provenance"
    case "$state" in
      queued) [ "$held" = yes ] || fail "captain hold $id is not active" ;;
      done) : ;;
      *) fail "captain decision $id is not queued or done (state=$state)" ;;
    esac
  else
    archived_hold_record "$id" \
      || fail "captain decision $id is absent from the backlog and configured archive"
    state="done"
    body=$ARCHIVED_HOLD_BODY
  fi
  parse_resolution_record "$body" \
    || fail "captain decision $id has a malformed legacy resolution"
  [ -z "$RESOLUTION_ORIGIN" ] && [ -z "$RESOLUTION_KEY" ] \
    || fail "captain decision $id already has embedded identity"
  [ "$state" != queued ] || [ "$RESOLUTION_MODE" != repaired ] \
    || fail "queued captain decision $id has an impossible repaired resolution"
  [ "$RESOLUTION_DIGEST" = "$DECISION_DIGEST" ] \
    || fail "captain decision $id records a different captain decision"
  if [ -n "$identity_file" ]; then
    require_legacy_identity_authorization "$identity_file" "$id" "$origin" "$key" "$RESOLUTION_RECORD_DIGEST"
  elif ! legacy_resolution_identity_unambiguous "$id" "$origin" "$key"; then
    fail "captain decision $id has ambiguous legacy ownership and requires an independent --identity-file authorization"
  fi
  persist_legacy_resolution_attestation "$id" "$origin" "$key" "$RESOLUTION_RECORD_DIGEST"
  ensure_retention_owner
  if [ "$has_meta" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0
  fi
  printf 'migrated: %s\n' "$id"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  local new_generation=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if task_show_optional "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    body=$(show_field "$show" body)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
    queued_hold_body_valid "$body" "$origin" "$key" \
      || fail "existing captain hold $id has malformed or mismatched active provenance"
    reject_archived_generation_collision "$id"
  else
    if archived_hold_resolved "$id" "$origin" "$key"; then
      fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    fi
    if [ -z "$repo" ] && [ -f "$DECISION_STATE/$origin.meta" ]; then
      repo=$(meta_value "$DECISION_STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
    new_generation=1
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id" "$origin" "$key" "$new_generation"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' previous_current='' previous_historical=''
  local supplied='' resolved='' supplied_csv='' resolved_csv='' keys='' key
  local current_keys='' historical_keys='' previous_last_current='' previous_last_historical=''
  local previous_reviewed='' previous_last_known=0 inventory_versioned=0 exact_retry=0 legacy_classified=0
  local durable_keys='' durable_current='' durable_historical=''
  local durable_last_current='' durable_last_historical='' durable_last_known=0 metadata_needs_sync=0
  local status_file open raw_open key_seen=0 has_meta=0 durable_inventory=0 none=0 positional_only=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  authoritative_state_path
  shift
  meta="$DECISION_STATE/$origin.meta"
  status_file="$DECISION_STATE/$origin.status"
  require_safe_status_file "$status_file"
  { [ -e "$meta" ] || [ -L "$meta" ]; } && has_meta=1
  if [ "$has_meta" = 1 ]; then
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    require_safe_origin_metadata_file "$meta" \
      || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  DECISION_ARCHIVE_CACHE_ENABLED=1
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  completion_inventory_lock_acquire "$origin"
  durable_inventory=1
  while [ "$#" -gt 0 ]; do
    if [ "$positional_only" -eq 1 ]; then
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
    else
      case "$1" in
        --) positional_only=1 ;;
        --none) none=1 ;;
        --resolved)
          shift
          [ "$#" -gt 0 ] || { usage >&2; exit 2; }
          validate_slug decision-key "$1"
          resolved="${resolved}${resolved:+ }$1"
          ;;
        *)
          validate_slug decision-key "$1"
          supplied="${supplied}${supplied:+ }$1"
          ;;
      esac
    fi
    shift
  done
  [ "$none" -eq 0 ] || [ -z "$supplied" ] \
    || fail "--none cannot be combined with unresolved decision keys"
  [ "$none" -eq 1 ] || [ -n "$supplied" ] \
    || fail "use --none when the reviewed surface has no unresolved decision keys"
  supplied_csv=$(printf '%s\n' "$supplied" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -)
  resolved_csv=$(printf '%s\n' "$resolved" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -)
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    list_has_key "$supplied_csv" "$key" \
      && fail "decision key $key cannot be both unresolved and resolved"
  done <<EOF
$(printf '%s\n' "$resolved_csv" | tr ',' '\n')
EOF
  if [ "$has_meta" = 1 ]; then
    completion_metadata_inventory "$meta"
    previous=$META_DECISION_KEYS
    previous_current=$META_DECISION_CURRENT_KEYS
    previous_historical=$META_DECISION_HISTORICAL_KEYS
    previous_last_current=$META_DECISION_LAST_CURRENT_KEYS
    previous_last_historical=$META_DECISION_LAST_HISTORICAL_KEYS
    previous_last_known=$META_DECISION_LAST_INVENTORY_KNOWN
    previous_reviewed=$META_DECISIONS_REVIEWED
    inventory_versioned=$META_DECISION_INVENTORY_VERSIONED
    if [ "$previous_reviewed" != 1 ] || [ "$inventory_versioned" -ne 1 ]; then
      metadata_needs_sync=1
    fi
  fi
  if [ "$inventory_versioned" -eq 0 ] && [ -n "$previous" ]; then
    classify_legacy_source_generations "$origin" "$previous"
    legacy_classified=1
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if list_has_key "$resolved_csv" "$key"; then
        previous_historical=$(sorted_key_union "$previous_historical" "$key")
      elif list_has_key "$LEGACY_SOURCE_CURRENT_KEYS" "$key"; then
        previous_current=$(sorted_key_union "$previous_current" "$key")
      elif list_has_key "$supplied_csv" "$key"; then
        previous_current=$(sorted_key_union "$previous_current" "$key")
      else
        fail "legacy decision inventory key $key requires explicit current or --resolved provenance"
      fi
    done <<EOF
$(printf '%s\n' "$previous" | tr ',' '\n')
EOF
    previous_last_current=''
    previous_last_historical=''
    previous_last_known=0
  fi
  if completion_inventory_load_locked "$origin"; then
    durable_keys=$META_DECISION_KEYS
    durable_current=$META_DECISION_CURRENT_KEYS
    durable_historical=$META_DECISION_HISTORICAL_KEYS
    durable_last_current=$META_DECISION_LAST_CURRENT_KEYS
    durable_last_historical=$META_DECISION_LAST_HISTORICAL_KEYS
    durable_last_known=$META_DECISION_LAST_INVENTORY_KNOWN
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      list_has_key "$previous_historical" "$key" \
        && fail "decision completion provenance conflicts for current key $key"
      if [ "$has_meta" = 1 ] && ! list_has_key "$previous_current" "$key"; then
        metadata_needs_sync=1
      fi
      previous_current=$(sorted_key_union "$previous_current" "$key")
    done <<EOF
$(printf '%s\n' "$durable_current" | tr ',' '\n')
EOF
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      list_has_key "$previous_current" "$key" \
        && fail "decision completion provenance conflicts for historical key $key"
      if [ "$has_meta" = 1 ] && ! list_has_key "$previous_historical" "$key"; then
        metadata_needs_sync=1
      fi
      previous_historical=$(sorted_key_union "$previous_historical" "$key")
    done <<EOF
$(printf '%s\n' "$durable_historical" | tr ',' '\n')
EOF
    previous=$(sorted_key_union "$previous" "$(printf '%s' "$durable_keys" | tr ',' ' ')")
    if [ "$previous_last_known" -ne 1 ] && [ "$durable_last_known" -eq 1 ]; then
      previous_last_current=$durable_last_current
      previous_last_historical=$durable_last_historical
      previous_last_known=1
      [ "$has_meta" != 1 ] || metadata_needs_sync=1
    fi
    previous_reviewed=1
    inventory_versioned=1
  fi
  keys=$(sorted_key_union "$previous" "$supplied $resolved")
  current_keys=$previous_current
  historical_keys=$previous_historical
  if [ "$inventory_versioned" -eq 1 ] && [ "$previous_last_known" -eq 1 ] \
    && [ "$supplied_csv" = "$previous_last_current" ] \
    && [ "$resolved_csv" = "$previous_last_historical" ]; then
    exact_retry=1
  fi
  raw_open=$(status_open_decisions "$status_file")
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if list_has_key "$previous_current" "$key"; then
      if [ "$exact_retry" -eq 1 ] \
        || { [ "$inventory_versioned" -eq 1 ] && [ "$previous_last_known" -eq 0 ]; } \
        || { [ "$legacy_classified" -eq 1 ] && list_has_key "$LEGACY_SOURCE_CURRENT_KEYS" "$key"; }; then
        verify_hold_durable "$origin" "$key"
      else
        verify_hold_active "$(hold_id "$origin" "$key")" "$origin" "$key"
      fi
    else
      list_has_key "$previous_historical" "$key" \
        && fail "historical decision key $key cannot be reused as a current decision"
      verify_hold_active "$(hold_id "$origin" "$key")" "$origin" "$key"
      current_keys=$(sorted_key_union "$current_keys" "$key")
    fi
  done <<EOF
$(printf '%s\n' "$supplied_csv" | tr ',' '\n')
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if list_has_key "$previous_current" "$key"; then
      verify_hold_current_resolved "$origin" "$key"
    else
      verify_hold_historical "$origin" "$key"
      historical_keys=$(sorted_key_union "$historical_keys" "$key")
    fi
  done <<EOF
$(printf '%s\n' "$resolved_csv" | tr ',' '\n')
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    list_has_key "$supplied_csv" "$key" && continue
    list_has_key "$resolved_csv" "$key" && continue
    verify_hold_durable "$origin" "$key"
  done <<EOF
$(printf '%s\n' "$previous_current" | tr ',' '\n')
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    list_has_key "$supplied_csv" "$key" && continue
    list_has_key "$resolved_csv" "$key" && continue
    verify_hold_historical "$origin" "$key"
  done <<EOF
$(printf '%s\n' "$previous_historical" | tr ',' '\n')
EOF

  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
    list_has_key "$current_keys" "$key" \
      || fail "open structured decision $origin/$key is not classified as current"
    verify_hold_active "$(hold_id "$origin" "$key")" "$origin" "$key"
  done <<EOF
$open
EOF

  if [ "$durable_inventory" = 1 ]; then
    completion_inventory_persist_locked "$origin" "$keys" "$current_keys" "$historical_keys" \
      "$supplied_csv" "$resolved_csv" 1
  fi
  if [ "$has_meta" = 1 ]; then
    if [ "$metadata_needs_sync" -eq 1 ] || [ "$previous_reviewed" != 1 ] \
      || [ "$previous" != "$keys" ] || [ "$inventory_versioned" -ne 1 ] \
      || [ "$previous_current" != "$current_keys" ] \
      || [ "$previous_historical" != "$historical_keys" ] \
      || [ "$previous_last_current" != "$supplied_csv" ] \
      || [ "$previous_last_historical" != "$resolved_csv" ] \
      || [ "$previous_last_known" -ne 1 ]; then
      append_completion_inventory "$meta" "$keys" "$current_keys" "$historical_keys" \
        "$supplied_csv" "$resolved_csv" 1
    fi
  fi
  if [ "$has_meta" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0
  fi
  if [ "$durable_inventory" = 1 ]; then
    fm_lock_release "$DECISION_INVENTORY_LOCK"
    DECISION_INVENTORY_LOCK_HELD=0
  fi
  if [ "$has_meta" = 1 ]; then
    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    # The transfer line is this home's own bookkeeping close, written by the
    # turn that just reviewed the decision, so it uses the guarded
    # self-announced append (bin/fm-wake-lib.sh) and does not wake this same
    # session; an append failure still fails this command loudly.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$supplied_csv" "$key" || continue
      transfer_rc=0
      fm_wake_status_append_self_announced "$STATE" "$status_file" \
        "captain-held [key=$key]: tracked by $(hold_id "$origin" "$key")" || transfer_rc=$?
      [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin/$key"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta status_file keys current_keys historical_keys key open
  local metadata_keys metadata_current metadata_historical metadata_last_current
  local metadata_last_historical metadata_last_known metadata_versioned
  local durable_keys='' durable_current='' durable_historical=''
  local durable_last_current='' durable_last_historical='' durable_last_known=0
  local last_current='' last_historical='' last_known=0 durable_loaded=0
  local metadata_needs_sync=0 durable_needs_sync=0
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  authoritative_state_path
  meta="$DECISION_STATE/$origin.meta"
  status_file="$DECISION_STATE/$origin.status"
  [ -e "$meta" ] || [ -L "$meta" ] || fail "origin metadata is absent: $meta"
  require_safe_status_file "$status_file"
  DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
  if [ "$(cat "$DECISION_META_LOCK/pid" 2>/dev/null || true)" != "$PPID" ]; then
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
  fi
  require_safe_origin_metadata_file "$meta" \
    || fail "origin metadata disappeared while verifying completion"
  require_tasks_axi
  DECISION_ARCHIVE_CACHE_ENABLED=1
  completion_metadata_inventory "$meta"
  [ "$META_DECISIONS_REVIEWED" = 1 ] \
    || fail "origin $origin has no completed unresolved-decision inventory"
  metadata_keys=$META_DECISION_KEYS
  metadata_current=$META_DECISION_CURRENT_KEYS
  metadata_historical=$META_DECISION_HISTORICAL_KEYS
  metadata_last_current=$META_DECISION_LAST_CURRENT_KEYS
  metadata_last_historical=$META_DECISION_LAST_HISTORICAL_KEYS
  metadata_last_known=$META_DECISION_LAST_INVENTORY_KNOWN
  metadata_versioned=$META_DECISION_INVENTORY_VERSIONED
  keys=$metadata_keys
  if [ "$metadata_versioned" -ne 1 ] && [ -n "$keys" ]; then
    classify_legacy_source_generations "$origin" "$keys"
    [ -z "$LEGACY_SOURCE_UNCLASSIFIED_KEYS" ] \
      || fail "origin $origin has a legacy decision inventory with archive-only generations; rerun complete with each such key as current or --resolved"
    current_keys=$LEGACY_SOURCE_CURRENT_KEYS
    historical_keys=''
    metadata_needs_sync=1
  else
    current_keys=$metadata_current
    historical_keys=$metadata_historical
    last_current=$metadata_last_current
    last_historical=$metadata_last_historical
    last_known=$metadata_last_known
  fi

  completion_inventory_lock_acquire "$origin"
  if completion_inventory_load_locked "$origin"; then
    durable_loaded=1
    durable_keys=$META_DECISION_KEYS
    durable_current=$META_DECISION_CURRENT_KEYS
    durable_historical=$META_DECISION_HISTORICAL_KEYS
    durable_last_current=$META_DECISION_LAST_CURRENT_KEYS
    durable_last_historical=$META_DECISION_LAST_HISTORICAL_KEYS
    durable_last_known=$META_DECISION_LAST_INVENTORY_KNOWN
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      list_has_key "$historical_keys" "$key" \
        && fail "decision completion provenance conflicts for current key $key"
      current_keys=$(sorted_key_union "$current_keys" "$key")
    done <<EOF
$(printf '%s\n' "$durable_current" | tr ',' '\n')
EOF
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      list_has_key "$current_keys" "$key" \
        && fail "decision completion provenance conflicts for historical key $key"
      historical_keys=$(sorted_key_union "$historical_keys" "$key")
    done <<EOF
$(printf '%s\n' "$durable_historical" | tr ',' '\n')
EOF
    keys=$(sorted_key_union "$keys" "$(printf '%s' "$durable_keys" | tr ',' ' ')")
    last_current=$durable_last_current
    last_historical=$durable_last_historical
    last_known=$durable_last_known
  else
    durable_needs_sync=1
  fi
  if [ "$durable_loaded" -eq 1 ] \
    && { [ "$durable_keys" != "$keys" ] \
      || [ "$durable_current" != "$current_keys" ] \
      || [ "$durable_historical" != "$historical_keys" ]; }; then
    durable_needs_sync=1
  fi
  if [ "$metadata_versioned" -ne 1 ] \
    || [ "$metadata_keys" != "$keys" ] \
    || [ "$metadata_current" != "$current_keys" ] \
    || [ "$metadata_historical" != "$historical_keys" ] \
    || [ "$metadata_last_current" != "$last_current" ] \
    || [ "$metadata_last_historical" != "$last_historical" ] \
    || [ "$metadata_last_known" != "$last_known" ]; then
    metadata_needs_sync=1
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    verify_hold_durable "$origin" "$key"
  done <<EOF
$(printf '%s\n' "$current_keys" | tr ',' '\n')
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    verify_hold_historical "$origin" "$key"
  done <<EOF
$(printf '%s\n' "$historical_keys" | tr ',' '\n')
EOF
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    list_has_key "$current_keys" "$key" \
      || fail "open structured decision $origin/$key is not classified as current"
    verify_hold_active "$(hold_id "$origin" "$key")" "$origin" "$key"
  done <<EOF
$open
EOF
  if [ "$durable_needs_sync" = 1 ]; then
    completion_inventory_persist_locked "$origin" "$keys" "$current_keys" "$historical_keys" \
      "$last_current" "$last_historical" "$last_known"
  fi
  if [ "$metadata_needs_sync" = 1 ]; then
    append_completion_inventory "$meta" "$keys" "$current_keys" "$historical_keys" \
      "$last_current" "$last_historical" "$last_known"
  fi
  fm_lock_release "$DECISION_INVENTORY_LOCK"
  DECISION_INVENTORY_LOCK_HELD=0
  if [ "$DECISION_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0
  fi
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_task_id routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  [ -n "$routed" ] || fail "at least one --routed-to task is required; use decline when the captain's answer routes no work"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id" "$origin" "$key"; then
    hold_body=$RESOLVED_HOLD_BODY
    verify_resolution_identity "$id" "$origin" "$key" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id" "$origin" "$key"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$origin" "$key" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    blocked=$(normalized_blocked_by "$show")
    if ! list_has_key "$blocked" "$id"; then
      case "$hold_body" in
        *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
        *) fail "routed task $dep is not durably blocked by $id" ;;
      esac
    fi
  done

  # shellcheck disable=SC2086  # routed is a validated space-separated slug list.
  body=$(resolution_body "$origin" "$key" routed "$routed_csv" $routed)
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    if list_has_key "$(normalized_blocked_by "$show")" "$id"; then
      tasks_axi unblock "$dep" --by "$id" >/dev/null \
        || fail "could not route the recorded decision to $dep"
    fi
  done
  tasks_axi_with_retention_provenance "done" "$id" >/dev/null \
    || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" "$origin" "$key" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

parse_decision_only_flags() {  # <args...>; prints the --decision-file value
  local decision_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  printf '%s' "$decision_file"
}

# The one unrouted close path, shared by `answer` and `decline`. They differ only
# in the resolution mode they record and the outcome word they print; every
# guard - the captain decision file, the active-hold requirement, the retry
# identity, and the refusal to release still-routed work - is identical, so
# neither can drift into a weaker close than the other.
close_unrouted_hold() {  # <mode> <outcome-word> <origin-id> <decision-key> <flag-args...>
  local mode=$1 outcome=$2 origin=$3 key=$4 decision_file id body hold_show hold_body state dependents
  shift 4
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id" "$origin" "$key"; then
    hold_body=$RESOLVED_HOLD_BODY
    verify_resolution_identity "$id" "$origin" "$key" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi
  hold_show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$hold_show" state)
  [ "$state" != "done" ] \
    || fail "captain hold $id was closed outside fm-decision-hold; use repair to record the captain decision"
  verify_hold_active "$id" "$origin" "$key"
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$origin" "$key" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
      ;;
  esac
  dependents=$(tasks_blocked_by "$id") || exit 1
  [ -z "$dependents" ] \
    || fail "captain hold $id still blocks routed work ($dependents); use resolve to record that work"
  body=$(resolution_body "$origin" "$key" "$mode" "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  tasks_axi_with_retention_provenance "done" "$id" >/dev/null \
    || fail "could not close $mode captain hold $id"
  verify_hold_resolved "$id" "$origin" "$key" || fail "captain hold $id did not retain its durable resolution record"
  printf '%s: %s\n' "$outcome" "$id"
}

command_answer() {
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  close_unrouted_hold answered answered "$@"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The origin a captured-answer source belongs to, or empty when it is unbound.
# An unreadable or wrong-schema record is a hard error rather than a silent
# "unbound": feeding nothing is the safe direction only when it is a deliberate
# choice, never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  case "$origin" in
    ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
  esac
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  validate_slug origin-id "$origin"
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
keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

command_answers() {
  local origin=${1:-} source='' key answer label hold tmp err closed=0 skipped=0 reason
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS=$'\t' read -r key answer label; do
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 64 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    hold="$origin-decision-$key"
    keyed_decision_text "$source" "$key" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $hold"
    if "$0" answer "$origin" "$key" --decision-file "$tmp" >/dev/null 2>"$err"; then
      printf 'closed: %s\n' "$hold"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-decision-hold: //')
      printf 'skipped: %s (%s)\n' "$hold" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s skipped=%s origin=%s\n' "$closed" "$skipped" "$origin"
  [ "$skipped" -eq 0 ]
}

command_decline() {
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  close_unrouted_hold declined declined "$@"
}

command_retention_tasks_axi() {
  local arg
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  for arg in "$@"; do
    case "$arg" in
      --file|--file=*|--backend|--backend=*) fail "retention commands use the active home's configured tasks-axi backlog" ;;
    esac
  done
  require_tasks_axi
  tasks_axi_with_retention_provenance "$@"
}

command_task_done() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  command_retention_tasks_axi "done" "$@"
}

command_retention_prune() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  command_retention_tasks_axi prune --state "done"
}

command_repair() {
  local origin=${1:-} key=${2:-} decision_file id body show state kind hold_kind hold_body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  reject_archived_generation_collision "$id"
  kind=$(show_field "$show" kind)
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  # tasks-axi keeps hold_kind after a close, so it is the surviving proof that
  # this identity really was a captain hold rather than an ordinary captain-kind
  # task that was never held for the captain at all.
  hold_kind=$(show_field "$show" hold_kind)
  [ "$hold_kind" = captain ] \
    || fail "backlog item $id was never held for the captain; repair records a captain decision only on a captain hold"
  state=$(show_field "$show" state)
  hold_body=$(show_field "$show" body)
  active_hold_body_valid "$hold_body" "$origin" "$key" \
    || fail "captain hold $id has malformed or mismatched repair provenance"
  if [ "$state" = "done" ] && body_has_resolution_record "$hold_body" "$origin" "$key"; then
    verify_resolution_identity "$id" "$origin" "$key" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
    printf 'repaired: %s\n' "$id"
    return 0
  fi
  [ "$state" = "done" ] \
    || fail "captain hold $id is still open (state=$state); use resolve or decline to close it with the captain's decision"
  body=$(resolution_body "$origin" "$key" repaired "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  show=$(task_show "$id") || fail "captain decision $id disappeared while recording the repair"
  [ "$(show_field "$show" state)" = "done" ] || fail "repairing $id reopened a closed captain decision"
  verify_hold_resolved "$id" "$origin" "$key" || fail "captain hold $id did not retain its durable resolution record"
  printf 'repaired: %s\n' "$id"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  decline) shift; command_decline "$@" ;;
  repair) shift; command_repair "$@" ;;
  migrate-legacy) shift; command_migrate_legacy "$@" ;;
  migrate-retention) shift; command_migrate_retention "$@" ;;
  task-done) shift; command_task_done "$@" ;;
  retention-prune) shift; command_retention_prune "$@" ;;
  tasks-axi) shift; command_retention_tasks_axi "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
