#!/usr/bin/env bash
# Canonical current and isolated legacy operational-input protocol matrices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-operational-input.sh"
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

set_age_secs() {  # <file> <age-seconds>
  local at=$(( $(date +%s) - $2 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$at" '+%Y%m%d%H%M.%S')" "$1"
  else touch -m -d "@$at" "$1"; fi
}

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind fixture"
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind fixture"
    [ "$parsed" = "$kind" ] \
      || fail "current $kind fixture became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "cross-language CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] \
      || fail "classifier lost current $kind"
    fm_operational_input_body "$encoded" stripped \
      || fail "could not recover current $kind body"
    [ "$stripped" = "$body" ] \
      || fail "current $kind body changed during encode/parse"
  done
  pass "operational input: every current generic envelope retains its exact structured kind"
}

test_current_from_firstmate_carrier() {
  local encoded parsed separator
  separator=$(printf '\342\201\243')
  fm_message_mark_from_firstmate "corr=0123456789abcdef inspect the report" encoded
  [ "${encoded#"[fm-from-firstmate]$separator"}" != "$encoded" ] \
    || fail "from-firstmate lost its live-charter-compatible leading carrier"
  fm_operational_input_kind "$encoded" parsed \
    || fail "from-firstmate current carrier did not parse"
  [ "$parsed" = from-firstmate ] \
    || fail "from-firstmate current carrier became $parsed"
  [ "$(classify_cli "$encoded")" = from-firstmate ] \
    || fail "cross-language classifier lost from-firstmate"
  pass "operational input: the established from-firstmate carrier remains structurally typed and byte-compatible"
}

test_landed_untyped_prefix_is_explicitly_legacy() {
  local untyped parsed
  untyped="${FM_OPERATIONAL_PREFIX}body whose historical subtype is unknowable"
  fm_legacy_operational_input_kind "$untyped" parsed \
    || fail "landed untyped FIRSTMATE_OP input was not retained"
  [ "$parsed" = legacy-operational ] \
    || fail "landed untyped FIRSTMATE_OP input falsely became $parsed"
  ! fm_operational_input_kind "$untyped" parsed \
    || fail "untyped FIRSTMATE_OP input passed the current typed parser"
  [ "$(classify_cli "$untyped")" = legacy-operational ] \
    || fail "CLI did not expose the untyped prefix as legacy-operational"
  pass "operational input: untyped landed FIRSTMATE_OP transcripts are explicit legacy-operational input"
}

test_isolated_legacy_matrix() {
  local watcher turnend away parsed
  watcher="${FM_LEGACY_WATCHER_PREFIX}signal: legacy${FM_LEGACY_WATCHER_SUFFIX}"
  turnend="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
  away="${FM_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"

  for fixture in \
    "session-start|$FM_LEGACY_SESSIONSTART" \
    "watcher|$watcher" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture leaked into the current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture was not recognized"
    [ "$parsed" = "$expected" ] \
      || fail "legacy $expected fixture became $parsed"
  done
  pass "operational input: historical prose compatibility is isolated from current parsing"
}

test_genuine_near_misses_remain_unclassified() {
  local marker fixture parsed
  marker=$FM_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Captain quote: ${FM_OPERATIONAL_PREFIX}v1 watcher
FIRSTMATE_OP: v1 watcher
$marker arbitrary captain text
Captain quote: $FM_LEGACY_SESSIONSTART
${FM_LEGACY_SESSIONSTART} Please explain this sentence.
FIRSTMATE WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
[fm-from-firstmate] inspect this visible label
EOF
  pass "operational input: quoted, ASCII-only, arbitrary-U+2063, altered-legacy, and label-only near misses stay genuine"
}

test_cross_language_adapter_uses_the_owner() {
  local encoded parsed
  encoded=$(FM_TEST_ROOT="$ROOT" HELPER="$ROOT/.opencode/plugins/lib/fm-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const { encodeFirstmateOperationalInput } = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await encodeFirstmateOperationalInput(process.env.FM_TEST_ROOT, "watcher", "CROSS_LANGUAGE_BODY"));
JS
  ) || fail "OpenCode cross-language adapter could not invoke the canonical owner"
  fm_operational_input_kind "$encoded" parsed \
    || fail "OpenCode cross-language adapter returned an invalid current envelope"
  [ "$parsed" = watcher ] \
    || fail "OpenCode cross-language adapter changed watcher to $parsed"
  pass "operational input: the OpenCode adapter constructs through the canonical owner"
}

test_invalid_current_encodings_are_rejected() {
  local output
  output=$(printf 'body' | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy-operational was accepted as a current producer kind"
  [ -z "$output" ] || fail "invalid current kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty current operational body was accepted"
  [ -z "$output" ] || fail "empty current body printed protocol data"
  pass "operational input: current construction rejects legacy kinds and empty bodies"
}

test_record_backed_doorbell_carrier() {
  local tmp state other doorbell record kind body linked prefix_len old_record just_expired just_kept stray
  tmp=$(fm_test_tmproot fm-operational-input-record)
  state="$tmp/home/state"
  other="$tmp/other/state"
  mkdir -p "$state" "$other"
  fm_operational_harness_needs_record claude \
    || fail "the Claude Code harness does not select the record-backed carrier"
  for kind in pi pi-signed codex opencode grok cursor omp unknown ''; do
    fm_operational_harness_needs_record "$kind" \
      && fail "marker-preserving harness '$kind' was switched to the record-backed carrier"
  done

  doorbell=$(printf 'digest body\nsecond line' | FM_STATE_OVERRIDE="$state" "$OWNER" record away-supervisor) \
    || fail "the CLI could not publish an away-supervisor record"
  case "$doorbell" in
    *"$FM_OPERATIONAL_MARK"*) fail "the doorbell carries the invisible marker it exists to avoid" ;;
  esac
  printf '%s' "$doorbell" | LC_ALL=C grep -q '[^[:print:]]' \
    && fail "the doorbell is not one printable-ASCII line: $doorbell"
  fm_operational_doorbell_path "$doorbell" record || fail "the owner cannot parse its own doorbell"
  [ "$(cat "$record")" = "${FM_OPERATIONAL_PREFIX}v1 away-supervisor: digest body"$'\n''second line' ] \
    || fail "the record does not hold exactly the encoded envelope"
  [ "$(printf '%s' "$doorbell" | "$OWNER" doorbell-kind)" = away-supervisor ] \
    || fail "doorbell-kind lost the record's kind"
  body=$(FM_STATE_OVERRIDE="$state" "$OWNER" open "$record") || fail "open refused this home's own record"
  [ "$body" = "digest body"$'\n''second line' ] || fail "open did not print the record body: $body"
  linked="$tmp/linked-state"
  ln -s "$state" "$linked"
  FM_STATE_OVERRIDE="$linked" "$OWNER" open "$record" >/dev/null \
    || fail "open refused this home's record when the home is reached through a symlink"
  FM_STATE_OVERRIDE="$other" "$OWNER" open "$record" >/dev/null \
    && fail "open accepted another home's record"
  fm_operational_doorbell_kind "$doorbell" "$state" kind && [ "$kind" = away-supervisor ] \
    || fail "the home-bound check rejected this home's own doorbell"
  fm_operational_doorbell_kind "$doorbell" "$other" kind \
    && fail "the home-bound check accepted another home's doorbell"

  # A doorbell proves nothing without its record, and the classifier never reads one.
  [ -z "$(printf '%s' "$doorbell" | "$OWNER" classify)" ] \
    || fail "the pure text classifier recognized a doorbell"
  prefix_len=${#FM_OPERATIONAL_DOORBELL_PREFIX}
  for stray in \
    "${FM_OPERATIONAL_DOORBELL_PREFIX}$state/operational-inbox/0-missing.msg${FM_OPERATIONAL_DOORBELL_SUFFIX}" \
    "${FM_OPERATIONAL_DOORBELL_PREFIX}relative/operational-inbox/1-a.msg${FM_OPERATIONAL_DOORBELL_SUFFIX}" \
    "${FM_OPERATIONAL_DOORBELL_PREFIX}$state/other-dir/1-a.msg${FM_OPERATIONAL_DOORBELL_SUFFIX}" \
    "${FM_OPERATIONAL_DOORBELL_PREFIX}$state/operational-inbox/UPPER.msg${FM_OPERATIONAL_DOORBELL_SUFFIX}" \
    "${FM_OPERATIONAL_DOORBELL_PREFIX}$state/operational-inbox/1-a.txt${FM_OPERATIONAL_DOORBELL_SUFFIX}" \
    "$doorbell trailing" \
    " $doorbell" \
    "${doorbell:0:$prefix_len}" \
    'FIRSTMATE_OP: v1 away-supervisor: typed by a human'; do
    [ -z "$(printf '%s' "$stray" | "$OWNER" doorbell-kind)" ] \
      || fail "a malformed or unbacked doorbell was recognized: $stray"
  done
  printf 'FIRSTMATE_OP: v1 away-supervisor: ascii only' >"$state/operational-inbox/2-ascii.msg"
  [ -z "$(printf '%s' "${FM_OPERATIONAL_DOORBELL_PREFIX}$state/operational-inbox/2-ascii.msg${FM_OPERATIONAL_DOORBELL_SUFFIX}" | "$OWNER" doorbell-kind)" ] \
    || fail "a record without the U+2063 envelope was recognized"

  old_record="$state/operational-inbox/1-old.msg"
  printf '%s' "${FM_OPERATIONAL_PREFIX}v1 watcher: old" >"$old_record"
  touch -t 200001010000 "$old_record"
  just_expired="$state/operational-inbox/1-just-expired.msg"
  just_kept="$state/operational-inbox/1-just-kept.msg"
  printf '%s' "${FM_OPERATIONAL_PREFIX}v1 watcher: just expired" >"$just_expired"
  printf '%s' "${FM_OPERATIONAL_PREFIX}v1 watcher: just kept" >"$just_kept"
  set_age_secs "$just_expired" $((7 * 86400 + 5))
  set_age_secs "$just_kept" $((7 * 86400 - 60))
  printf 'x' | FM_STATE_OVERRIDE="$state" "$OWNER" record watcher >/dev/null || fail "second record write failed"
  [ ! -e "$old_record" ] || fail "a record older than the retention window was not pruned"
  [ ! -e "$just_expired" ] || fail "a record seconds past seven days survived a write"
  [ -f "$just_kept" ] || fail "a record a minute short of seven days was pruned"
  [ -f "$record" ] || fail "a fresh record was pruned"
  pass "record-backed carrier: Claude-only selection, an ASCII doorbell naming an exact envelope record, home-bound open, and no recognition without the record"
}

test_record_prune_outgrows_one_argument_list() {
  local tmp state pad left
  tmp=$(fm_test_tmproot fm-operational-input-flood)
  state="$tmp/state"
  mkdir -p "$state/operational-inbox"
  pad=$(printf '%0200d' 0)
  (cd "$state/operational-inbox" && seq 1 12000 | sed "s/\$/-$pad.msg/" | xargs touch -t 200001010000) \
    || fail "could not seed the expired record flood"
  printf 'x' | FM_STATE_OVERRIDE="$state" "$OWNER" record watcher >/dev/null || fail "record write over a flood failed"
  left=$(find "$state/operational-inbox" -maxdepth 1 -type f -name '*.msg' | wc -l | tr -d ' ')
  [ "$left" = 1 ] || fail "a write left $left records when only its own fresh record was within retention"
  pass "record pruning: expired records past one argument list are all pruned on a write"
}

test_current_generic_matrix
test_current_from_firstmate_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
test_record_backed_doorbell_carrier
test_record_prune_outgrows_one_argument_list
