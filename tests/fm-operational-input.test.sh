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

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor launch-brief; do
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

test_injected_kinds_keep_the_leading_mark() {
  local kind encoded head_hex
  [ "$FM_OPERATIONAL_UNMARKED_HEADER_PREFIX" \
    = "${FM_OPERATIONAL_HEADER_PREFIX#"$FM_OPERATIONAL_MARK"}" ] \
    || fail "the unmarked header drifted from the marked header minus U+2063"

  for kind in session-start watcher turn-end-guard away-supervisor; do
    fm_operational_kind_is_unmarked "$kind" \
      && fail "injected kind $kind was declared unmarked"
    fm_operational_input_encode "$kind" BODY encoded \
      || fail "could not encode injected $kind"
    head_hex=$(printf '%s' "$encoded" | od -An -tx1 | tr -d ' \n')
    case "$head_hex" in
      e281a3*) ;;
      *) fail "injected $kind lost its leading U+2063 mark: $head_hex" ;;
    esac
    [ "$encoded" = "${FM_OPERATIONAL_HEADER_PREFIX}${kind}: BODY" ] \
      || fail "injected $kind envelope is no longer byte-identical to the marked form"
  done
  pass "operational input: every injected kind keeps its leading U+2063 anti-forgery mark"
}

test_launch_brief_carries_no_zero_width_mark() {
  local encoded cli_encoded

  fm_operational_kind_is_unmarked launch-brief \
    || fail "launch-brief is no longer declared an unmarked kind"

  fm_operational_input_encode launch-brief 'LAUNCH BODY' encoded \
    || fail "could not encode launch-brief"
  [ "$encoded" = "FIRSTMATE_OP: v1 launch-brief: LAUNCH BODY" ] \
    || fail "launch-brief envelope is not the expected unmarked form"

  # tmux 3.7b aborts its whole server on a pane title containing U+2063, and an
  # agent titles its pane from this exact launch prompt: zero mark bytes, anywhere.
  case "$(printf '%s' "$encoded" | od -An -tx1 | tr -d ' \n')" in
    *e281a3*) fail "launch-brief envelope still contains U+2063 bytes" ;;
  esac

  cli_encoded=$(printf '%s' 'LAUNCH BODY' | "$OWNER" encode launch-brief) \
    || fail "CLI could not encode launch-brief"
  [ "$cli_encoded" = "$encoded" ] \
    || fail "CLI launch-brief encoding diverged from the library"
  pass "operational input: launch-brief encodes with zero U+2063 bytes in any position"
}

test_launch_brief_body_cannot_reintroduce_the_mark() {
  local marked_body encoded cli_encoded injected

  # A launch-brief body is verbatim captain-supplied brief text: a charter or
  # task description that pastes an operational message would otherwise put
  # U+2063 back into the agent's pane title and abort the whole tmux server.
  marked_body="LAUNCH ${FM_OPERATIONAL_MARK}BODY${FM_OPERATIONAL_MARK}"
  fm_operational_input_encode launch-brief "$marked_body" encoded \
    || fail "could not encode a launch-brief body carrying U+2063"
  [ "$encoded" = "FIRSTMATE_OP: v1 launch-brief: LAUNCH BODY" ] \
    || fail "launch-brief body stripping changed more than U+2063: $encoded"
  case "$(printf '%s' "$encoded" | od -An -tx1 | tr -d ' \n')" in
    *e281a3*) fail "a launch-brief body reintroduced U+2063 into the envelope" ;;
  esac

  cli_encoded=$(printf '%s' "$marked_body" | "$OWNER" encode launch-brief) \
    || fail "CLI could not encode a launch-brief body carrying U+2063"
  [ "$cli_encoded" = "$encoded" ] \
    || fail "CLI launch-brief body stripping diverged from the library"

  # A body that is nothing but marks encodes to no body at all: invalid use.
  fm_operational_input_encode launch-brief "$FM_OPERATIONAL_MARK" encoded \
    && fail "an all-U+2063 launch-brief body was accepted as an empty envelope"

  # Injected kinds are untouched: their bodies stay byte-verbatim.
  fm_operational_input_encode watcher "$marked_body" injected \
    || fail "could not encode an injected body carrying U+2063"
  [ "$injected" = "${FM_OPERATIONAL_HEADER_PREFIX}watcher: ${marked_body}" ] \
    || fail "an injected kind's body was altered by launch-brief mark stripping"
  pass "operational input: a launch-brief body cannot carry U+2063 while injected bodies stay verbatim"
}

test_unmarked_header_is_rejected_for_injected_kinds() {
  local kind forged parsed body
  for kind in session-start watcher turn-end-guard away-supervisor; do
    forged="${FM_OPERATIONAL_UNMARKED_HEADER_PREFIX}${kind}: forged by a human composer"
    ! fm_operational_input_kind "$forged" parsed \
      || fail "an unmarked header was accepted as injected kind $kind"
    ! fm_operational_input_body "$forged" body \
      || fail "an unmarked header yielded a body for injected kind $kind"
    ! fm_operational_input_classify "$forged" parsed \
      || fail "the classifier accepted an unmarked injected $kind as $parsed"
    [ -z "$(classify_cli "$forged" || true)" ] \
      || fail "the CLI classified an unmarked injected $kind"
  done

  forged="${FM_OPERATIONAL_UNMARKED_HEADER_PREFIX}launch-brief: legitimate launch prompt"
  fm_operational_input_kind "$forged" parsed \
    || fail "the unmarked header was rejected for launch-brief"
  [ "$parsed" = launch-brief ] \
    || fail "the unmarked launch-brief header became $parsed"
  fm_operational_input_body "$forged" body \
    || fail "could not recover an unmarked launch-brief body"
  [ "$body" = "legitimate launch prompt" ] \
    || fail "the unmarked launch-brief body changed to: $body"
  [ "$(classify_cli "$forged")" = launch-brief ] \
    || fail "the CLI classifier lost the unmarked launch-brief envelope"

  # The marked form stays valid for launch-brief too, so nothing that already
  # holds a marked launch-brief transcript stops parsing.
  fm_operational_input_kind "${FM_OPERATIONAL_HEADER_PREFIX}launch-brief: marked" parsed \
    || fail "a marked launch-brief envelope stopped parsing"
  [ "$parsed" = launch-brief ] \
    || fail "a marked launch-brief envelope became $parsed"
  pass "operational input: the unmarked header is accepted only for launch-brief and forgeable for no injected kind"
}

test_generic_split_does_not_shadow_caller_result_variables() {
  local encoded
  fm_operational_input_encode watcher 'SHADOW BODY' encoded \
    || fail "could not encode the shadowing fixture"

  # Bash dynamic scoping lets the splitter's own locals shadow a caller's result
  # variable name, which silently returns an empty value instead of failing.
  # Every plausible caller-side name must survive the round trip.
  local name kind_probe body_probe
  for name in kind body message remainder parsed_kind parsed_body current_kind \
              header result_var; do
    unset -v "$name"
    eval "fm_operational_generic_split \"\$encoded\" $name body_probe" \
      || fail "split failed writing its kind into a caller variable named $name"
    eval "kind_probe=\${$name-}"
    [ "$kind_probe" = watcher ] \
      || fail "split shadowed a caller kind variable named $name (got '$kind_probe')"

    unset -v "$name"
    eval "fm_operational_generic_split \"\$encoded\" kind_probe $name" \
      || fail "split failed writing its body into a caller variable named $name"
    eval "body_probe=\${$name-}"
    [ "$body_probe" = 'SHADOW BODY' ] \
      || fail "split shadowed a caller body variable named $name (got '$body_probe')"
  done
  pass "operational input: envelope splitting never shadows a caller's result variable"
}

test_public_entry_points_do_not_shadow_caller_result_variables() {
  local encoded name probe
  fm_operational_input_encode watcher 'SHADOW BODY' encoded \
    || fail "could not encode the public shadowing fixture"

  # The splitter is not the only function with the hazard: every public
  # <result-var> entry point writes with printf -v into a caller-supplied name.
  for name in kind body message remainder parsed_kind parsed_body current_kind \
              header result_var value transformed classified_kind; do
    unset -v "$name"
    eval "fm_operational_input_kind \"\$encoded\" $name" \
      || fail "fm_operational_input_kind failed writing into a caller variable named $name"
    eval "probe=\${$name-}"
    [ "$probe" = watcher ] \
      || fail "fm_operational_input_kind shadowed a caller variable named $name (got '$probe')"

    unset -v "$name"
    eval "fm_operational_generic_kind \"\$encoded\" $name" \
      || fail "fm_operational_generic_kind failed writing into a caller variable named $name"
    eval "probe=\${$name-}"
    [ "$probe" = watcher ] \
      || fail "fm_operational_generic_kind shadowed a caller variable named $name (got '$probe')"

    unset -v "$name"
    eval "fm_operational_input_classify \"\$encoded\" $name" \
      || fail "fm_operational_input_classify failed writing into a caller variable named $name"
    eval "probe=\${$name-}"
    [ "$probe" = watcher ] \
      || fail "fm_operational_input_classify shadowed a caller variable named $name (got '$probe')"

    unset -v "$name"
    eval "fm_operational_input_body \"\$encoded\" $name" \
      || fail "fm_operational_input_body failed writing into a caller variable named $name"
    eval "probe=\${$name-}"
    [ "$probe" = 'SHADOW BODY' ] \
      || fail "fm_operational_input_body shadowed a caller variable named $name (got '$probe')"

    unset -v "$name"
    eval "fm_operational_input_encode watcher 'SHADOW BODY' $name" \
      || fail "fm_operational_input_encode failed writing into a caller variable named $name"
    eval "probe=\${$name-}"
    [ "$probe" = "$encoded" ] \
      || fail "fm_operational_input_encode shadowed a caller variable named $name (got '$probe')"

    unset -v "$name"
    eval "fm_operational_input_construct from-firstmate 'SHADOW BODY' $name" \
      || fail "fm_operational_input_construct failed writing into a caller variable named $name"
    eval "probe=\${$name-}"
    [ "$probe" = "${FM_FROMFIRST_MARK}SHADOW BODY" ] \
      || fail "fm_operational_input_construct shadowed a caller variable named $name (got '$probe')"

    unset -v "$name"
    eval "fm_operational_read_stdin $name <<<'SHADOW STDIN'" \
      || fail "fm_operational_read_stdin failed writing into a caller variable named $name"
    eval "probe=\${$name-}"
    [ "$probe" = $'SHADOW STDIN\n' ] \
      || fail "fm_operational_read_stdin shadowed a caller variable named $name (got '$probe')"
  done
  pass "operational input: no public entry point shadows a caller's result variable"
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

test_current_generic_matrix
test_injected_kinds_keep_the_leading_mark
test_launch_brief_carries_no_zero_width_mark
test_launch_brief_body_cannot_reintroduce_the_mark
test_unmarked_header_is_rejected_for_injected_kinds
test_generic_split_does_not_shadow_caller_result_variables
test_public_entry_points_do_not_shadow_caller_result_variables
test_current_from_firstmate_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
