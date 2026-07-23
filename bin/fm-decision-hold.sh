#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
# Resolved decisions remain verifiable after normal retention moves them from the
# active backlog to data/done-archive.md. Archive reads reject unsafe files,
# duplicate identities, concurrent changes, and records that do not exactly match
# the durable resolution format written by this command.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ARCHIVE_VIEW=''

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

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

cleanup_archive_view() {
  if [ -n "$ARCHIVE_VIEW" ]; then
    rm -f -- "$ARCHIVE_VIEW"
    ARCHIVE_VIEW=''
  fi
}

trap cleanup_archive_view EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

sha256_digest_from_output() {  # <hash-output>
  local output=$1 digest
  digest=${output%%[[:space:]]*}
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  printf '%s\n' "$digest"
}

sha256_text() {  # <text>
  local output
  if command -v shasum >/dev/null 2>&1; then
    output=$(printf '%s' "$1" | shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(printf '%s' "$1" | sha256sum) || return 1
  else
    fail "shasum or sha256sum is required"
  fi
  sha256_digest_from_output "$output"
}

sha256_file() {  # <path>
  local output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$1") || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$1") || return 1
  else
    fail "shasum or sha256sum is required"
  fi
  sha256_digest_from_output "$output"
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
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

decode_json_string() {  # <json-string>
  command -v node >/dev/null 2>&1 || fail "node is required to decode tasks-axi output"
  printf '%s' "$1" | node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => { input += chunk; });
    process.stdin.on("end", () => {
      try {
        const value = JSON.parse(input);
        if (typeof value !== "string" || value.includes("\u0000")) process.exit(1);
        process.stdout.write(value);
      } catch (_) {
        process.exit(1);
      }
    });
  '
}

valid_date() {  # <YYYY-MM-DD>
  command -v node >/dev/null 2>&1 || fail "node is required to validate tasks-axi output"
  node -e '
    const value = process.argv[1];
    if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) process.exit(1);
    const [year, month, day] = value.split("-").map(Number);
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1]) process.exit(1);
  ' "$1"
}

read_canonical_decision_file() {  # <path>
  local path=$1 status
  command -v node >/dev/null 2>&1 || fail "node is required to validate captain decision text"
  if node -e '
    const fs = require("fs");
    const { TextDecoder } = require("util");
    let bytes;
    try {
      bytes = fs.readFileSync(process.argv[1]);
    } catch (_) {
      process.exit(2);
    }
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      process.exit(3);
    }
    if (bytes.includes(0)) process.exit(4);
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch (_) {
      process.exit(1);
    }
    if (text.split("\n").some(line => line.length > 0 && line.trim().length === 0)) {
      process.exit(5);
    }
    process.stdout.write(bytes);
  ' -- "$path"; then
    return 0
  else
    status=$?
  fi
  case "$status" in
    1) fail "decision file must contain valid UTF-8" ;;
    2) fail "could not read decision file: $path" ;;
    3) fail "decision file must not start with a UTF-8 BOM" ;;
    4) fail "decision file must not contain NUL bytes" ;;
    5) fail "decision file contains a whitespace-only line; remove its whitespace or use an empty line" ;;
    *) fail "could not validate decision file: $path" ;;
  esac
}

scan_decision_identity() {  # <mode> <path> <id> [archive-view]
  command -v node >/dev/null 2>&1 || fail "node is required to inspect decision identities"
  node - "$@" <<'NODE'
const fs = require("fs");
const { TextDecoder } = require("util");

const [mode, path, id, view] = process.argv.slice(2);
if (!["active-count", "archive-count", "archive-extract"].includes(mode) || !path || !id) {
  process.exit(2);
}

let source;
try {
  source = new TextDecoder("utf-8", { fatal: true }).decode(fs.readFileSync(path));
} catch (_) {
  process.exit(1);
}
const body = source.endsWith("\n") ? source.slice(0, -1) : source;
const lines = body === "" ? [] : body.split("\n");
const semanticLine = line => line.endsWith("\r") ? line.slice(0, -1) : line;
const idChars = "[A-Za-z0-9][A-Za-z0-9._-]*";
const inFlight = new RegExp(`^- \\*\\*(${idChars})\\*\\* - (.*)$`);
const queued = new RegExp(`^- \\[ \\] (${idChars}) - (.*)$`);
const done = new RegExp(`^- \\[x\\] (${idChars}) - (.*)$`);

function taskHeader(line) {
  const semantic = semanticLine(line);
  let match = semantic.match(inFlight);
  if (match) return { id: match[1], form: "in_flight" };
  match = semantic.match(queued);
  if (match) return { id: match[1], form: "queued" };
  match = semantic.match(done);
  if (match) return { id: match[1], form: "done" };
  return undefined;
}

function isSectionHeading(line) {
  return /^##\s+/.test(semanticLine(line));
}

function isCanonicalArchiveHeading(line) {
  return /^## Archived [0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(line);
}

function extractRecord(start) {
  const record = [lines[start]];
  for (let index = start + 1; index < lines.length; index++) {
    const line = lines[index];
    const semantic = semanticLine(line);
    if (isSectionHeading(line) || taskHeader(line) !== undefined) break;
    if (semantic.trim().length === 0 || semantic.startsWith("  ")) {
      record.push(line);
      continue;
    }
    break;
  }
  return record;
}

let archived = false;
let total = 0;
let valid = 0;
let record;
for (let index = 0; index < lines.length; index++) {
  const line = lines[index];
  if (isSectionHeading(line)) {
    archived = isCanonicalArchiveHeading(line);
    continue;
  }
  const header = taskHeader(line);
  if (!header || header.id !== id) continue;
  total++;
  if (archived && header.form === "done") {
    valid++;
    if (record === undefined) record = extractRecord(index);
  }
}

if (mode === "active-count") {
  process.stdout.write(`${total}\n`);
  process.exit(0);
}
if (mode === "archive-count") {
  process.stdout.write(`${total} ${valid}\n`);
  process.exit(0);
}
if (!view || total !== 1 || valid !== 1 || record === undefined) process.exit(1);
try {
  fs.writeFileSync(view, ["## Done", "", ...record].join("\n") + "\n", "utf8");
} catch (_) {
  process.exit(1);
}
NODE
}

active_identity_count() {  # <id>
  local id=$1 backlog="$DATA/backlog.md"
  [ -f "$backlog" ] || { printf '0\n'; return 0; }
  scan_decision_identity active-count "$backlog" "$id"
}

archive_is_safe() {  # <archive>
  local archive=$1
  [ ! -L "$archive" ] || fail "decision archive must not be a symlink: $archive"
  [ -e "$archive" ] || return 1
  [ -f "$archive" ] || fail "decision archive is not a regular file: $archive"
  [ -r "$archive" ] || fail "decision archive is not readable: $archive"
}

archive_identity_counts() {  # <archive> <id>
  local archive=$1 id=$2
  scan_decision_identity archive-count "$archive" "$id"
}

verify_archive_unchanged() {  # <archive> <expected-digest>
  local archive=$1 expected=$2 current
  archive_is_safe "$archive" || fail "decision archive disappeared during verification: $archive"
  current=$(sha256_file "$archive") || fail "could not fingerprint decision archive: $archive"
  [ "$current" = "$expected" ] || fail "decision archive changed during verification: $archive"
}

verify_archive_identity_unchanged() {  # <archive> <id> <expected-digest> <expected-counts>
  local archive=$1 id=$2 expected_digest=$3 expected_counts=$4 current_counts
  verify_archive_unchanged "$archive" "$expected_digest"
  current_counts=$(archive_identity_counts "$archive" "$id") \
    || fail "could not recheck archived decision identity $id"
  verify_archive_unchanged "$archive" "$expected_digest"
  [ "$current_counts" = "$expected_counts" ] \
    || fail "decision archive identity changed during verification: $id"
}

verify_archive_absent() {  # <archive>
  local archive=$1
  [ ! -L "$archive" ] || fail "decision archive appeared during verification: $archive"
  [ ! -e "$archive" ] || fail "decision archive appeared during verification: $archive"
}

extract_archive_record() {  # <archive> <id>
  local archive=$1 id=$2
  cleanup_archive_view
  ARCHIVE_VIEW=$(
    umask 077
    mktemp "$DATA/.fm-decision-hold-archive.XXXXXX"
  ) || fail "could not create private archive parser view"
  scan_decision_identity archive-extract "$archive" "$id" "$ARCHIVE_VIEW" \
    || fail "could not extract exact archived decision $id"
}

verify_archived_resolution() {  # <id> <show-output> <raw-header>
  local id=$1 show=$2 header=$3 parsed_id state kind hold_kind hold_reason closed body_json body
  local marker rest digest routes route sorted_routes route_suffix expected_prefix decision recomputed_digest
  case "$header" in
    "- [x] $id - "*) : ;;
    *) fail "archived captain decision $id is not an exact terminal record" ;;
  esac
  parsed_id=$(show_field "$show" id)
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  hold_reason=$(show_field "$show" hold_reason)
  closed=$(show_field "$show" closed)
  body_json=$(show_field "$show" body)
  [ "$parsed_id" = "$id" ] || fail "archived captain decision has the wrong identity: $parsed_id"
  [ "$state" = "done" ] || fail "archived captain decision $id is not typed done"
  [ "$kind" = captain ] || fail "archived backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "archived backlog item $id is not held for the captain"
  [ -n "$hold_reason" ] && [ "$hold_reason" != '-' ] \
    || fail "archived captain decision $id has no hold reason"
  valid_date "$closed" || fail "archived captain decision $id has an invalid closure date: $closed"
  body=$(decode_json_string "$body_json" && printf '\034') \
    || fail "archived captain decision $id has an invalid structured body"
  body=${body%$'\034'}

  marker=$'Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$body" in
    "$marker"*) rest=${body#"$marker"} ;;
    *) fail "archived captain decision $id has no exact resolution record" ;;
  esac
  case "$rest" in
    *$'\n'*) digest=${rest%%$'\n'*}; rest=${rest#*$'\n'} ;;
    *) fail "archived captain decision $id has a truncated decision digest" ;;
  esac
  [ "${#digest}" -eq 64 ] || fail "archived captain decision $id has an invalid decision digest"
  case "$digest" in
    *[!0-9a-f]*) fail "archived captain decision $id has an invalid decision digest" ;;
  esac
  case "$rest" in
    'Routed identities: '*) rest=${rest#'Routed identities: '} ;;
    *) fail "archived captain decision $id has no exact routed identity record" ;;
  esac
  case "$rest" in
    *$'\n'*) routes=${rest%%$'\n'*} ;;
    *) fail "archived captain decision $id has a truncated routed identity record" ;;
  esac
  case "$routes" in
    ''|,*|*,|*,,*) fail "archived captain decision $id has invalid routed identities" ;;
  esac
  while IFS= read -r route; do
    validate_slug routed-identity "$route"
  done <<EOF
$(printf '%s\n' "$routes" | tr ',' '\n')
EOF
  sorted_routes=$(printf '%s\n' "$routes" | tr ',' '\n' | LC_ALL=C sort -u | paste -sd, -)
  [ "$routes" = "$sorted_routes" ] \
    || fail "archived captain decision $id has unsorted or duplicate routed identities"

  route_suffix=$'\n\nRouted work:'
  while IFS= read -r route; do
    if [ "$route_suffix" = $'\n\nRouted work:' ]; then
      route_suffix="${route_suffix}- $route"
    else
      route_suffix="${route_suffix}"$'\n'"- $route"
    fi
  done <<EOF
$(printf '%s\n' "$routes" | tr ',' '\n')
EOF
  case "$body" in
    *"$route_suffix") rest=${body%"$route_suffix"} ;;
    *) fail "archived captain decision $id has invalid or truncated routed work" ;;
  esac
  expected_prefix="${marker}${digest}"$'\n'"Routed identities: ${routes}"$'\n\nCaptain decision:\n'
  case "$rest" in
    "$expected_prefix"*) decision=${rest#"$expected_prefix"} ;;
    *) fail "archived captain decision $id has an invalid resolution body" ;;
  esac
  [ -n "$decision" ] || fail "archived captain decision $id has an empty captain decision"
  recomputed_digest=$(sha256_text "$decision") \
    || fail "could not recompute archived captain decision digest: $id"
  [ "$recomputed_digest" = "$digest" ] \
    || fail "archived captain decision $id does not match its decision digest"
}

DECISION_SHOW=''

decision_lookup() {  # <decision-id>
  local id=$1 archive="$DATA/done-archive.md" active_count counts archive_count=0 archive_valid=0
  local archive_digest='' current_active header
  validate_slug decision-id "$id"
  DECISION_SHOW=''
  active_count=$(active_identity_count "$id") || fail "could not inspect active decision identity $id"
  [ "$active_count" -le 1 ] || fail "duplicate active captain decision identity: $id"
  if archive_is_safe "$archive"; then
    archive_digest=$(sha256_file "$archive") || fail "could not fingerprint decision archive: $archive"
    counts=$(archive_identity_counts "$archive" "$id") \
      || fail "could not inspect archived decision identity $id"
    archive_count=${counts%% *}
    archive_valid=${counts##* }
    verify_archive_unchanged "$archive" "$archive_digest"
    [ "$archive_count" = "$archive_valid" ] \
      || fail "captain decision $id appears outside a canonical archive section"
    [ "$archive_count" -le 1 ] || fail "duplicate archived captain decision identity: $id"
  fi
  [ "$active_count" -eq 0 ] || [ "$archive_count" -eq 0 ] \
    || fail "captain decision $id exists in both active backlog and archive"

  if [ "$active_count" -eq 1 ]; then
    DECISION_SHOW=$(task_show "$id") || fail "active captain decision $id changed during verification"
    current_active=$(active_identity_count "$id") \
      || fail "could not recheck active decision identity $id"
    [ "$current_active" -eq 1 ] || fail "active captain decision $id changed during verification"
    if [ -n "$archive_digest" ]; then
      verify_archive_unchanged "$archive" "$archive_digest"
    else
      verify_archive_absent "$archive"
    fi
    return 0
  fi
  if [ "$archive_count" -eq 1 ]; then
    extract_archive_record "$archive" "$id"
    verify_archive_unchanged "$archive" "$archive_digest"
    header=$(sed -n '3p' "$ARCHIVE_VIEW")
    DECISION_SHOW=$(tasks_axi show "$id" --full --file "$ARCHIVE_VIEW" 2>/dev/null) \
      || fail "could not parse exact archived captain decision $id"
    cleanup_archive_view
    verify_archive_unchanged "$archive" "$archive_digest"
    current_active=$(active_identity_count "$id") \
      || fail "could not recheck active decision identity $id"
    [ "$current_active" -eq 0 ] \
      || fail "captain decision $id appeared in the active backlog during verification"
    verify_archived_resolution "$id" "$DECISION_SHOW" "$header"
    verify_archive_identity_unchanged "$archive" "$id" "$archive_digest" "$counts"
    return 0
  fi
  if [ -n "$archive_digest" ]; then
    verify_archive_unchanged "$archive" "$archive_digest"
  else
    verify_archive_absent "$archive"
  fi
  return 1
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

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  decision_lookup "$id" || fail "captain hold $id is absent from the active backlog and decision archive"
  show=$DECISION_SHOW
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  decision_lookup "$id" || return 1
  show=$DECISION_SHOW
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  decision_lookup "$id" \
    || fail "captain decision $id is absent from the active backlog and decision archive"
  show=$DECISION_SHOW
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
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
  if decision_lookup "$id"; then
    show=$DECISION_SHOW
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(read_canonical_decision_file "$decision_file") || exit 1
  case "$decision" in *$'\r'*) fail "decision file must use LF line endings" ;; esac
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision") || fail "could not digest captain decision"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$DECISION_SHOW
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$DECISION_SHOW
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
