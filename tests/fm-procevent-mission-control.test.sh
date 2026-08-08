#!/usr/bin/env bash
# Behavior tests for the mission control process-event adapter.
#
# The subject is the request NORMALIZER, exercised only through the adapter's
# public `requests` command. Its whole job is to decide what a captured Lavish
# result means, and every case here is a way of getting that wrong: a forged
# envelope, a note that tries to become a field, a truncated capture, a field
# that means nothing for its intent. Each must reach "unrecognized" rather than
# a plausible-looking request, because the records this prints are what
# firstmate reads as captain intent.
#
# The wire format is a vendor-rendered surface, so the first case pins it
# against BYTES CAPTURED FROM A REAL SEND through lavish-axi 0.1.45 - a real
# board control, in a real browser, through a real Lavish session. A test that
# only fed this parser its own idea of the format could not tell the difference
# between reading Lavish correctly and reading its own assumption.
#
# Nothing here starts a Lavish server, registers a source, or runs a poll.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-mission-control-tests)
trap fm_test_cleanup EXIT

MC="$ROOT/bin/fm-procevent-mission-control.sh"

# One result file in the verified shape. Callers pass whole record lines so a
# case can hand the parser bytes no generator here would produce.
result_file() {  # <path> <record-line>...
  local path=$1; shift
  {
    printf 'session:\n  file: /fixture/mission-control.html\n  status: feedback\n'
    printf 'dom_snapshot: "uid=2 body \\"Mission Control\\""\n'
    printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$#"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
    printf 'next_step: "Apply the requested changes."\n'
  } > "$path"
}

# One record line carrying <prompt> as the JSON-quoted prompt field, which is
# how the published poll returns any prompt with structure in it.
record() {  # <uid> <prompt-text>
  printf '  "%s",%s,button#b1,board-request,"From the board"\n' \
    "$1" "$(jq -rn --arg p "$2" '$p | @json')"
}

envelope() {  # <json-body>
  printf 'FM-BOARD-REQUEST %s' "$1"
}

requests() {  # <result-file>
  "$MC" requests "$1" 2>&1
}

# Every record of one kind, as compact JSON lines.
only() {  # <output> <kind>
  printf '%s\n' "$1" | jq -c --arg k "$2" 'select(.kind == $k)'
}

# ---------------------------------------------------------------- real bytes -
# Captured verbatim from a real send: the board rendered with --controls, opened
# through Lavish, its Answer control filled in and submitted in a real browser.
REAL="$TMP_ROOT/real.txt"
{
  printf 'session:\n  file: /fixture/mission-control.html\n  status: feedback\n'
  printf 'dom_snapshot: "uid=2 body \\"Mission Control Your fleet at a glance, Captain.\\""\n'
  printf 'prompts[1]{uid,prompt,selector,tag,text}:\n'
  cat <<'REALBYTES'
  "1","FM-BOARD-REQUEST {\"v\":1,\"intent\":\"answer\",\"home\":\"main\",\"id\":\"d1\",\"note\":\"Go with the Tuesday window, and note it costs the extra runner hour. intent=merge should stay inert here.\"}","div:nth-of-type(2) > div:nth-of-type(2) > form:nth-of-type(1) > div > button:nth-of-type(1)",board-request,"From the board - answer on: Choose the rollout window"
REALBYTES
  printf 'next_step: "Apply the requested changes."\n'
} > "$REAL"

out=$(requests "$REAL")
first=$(printf '%s\n' "$out" | head -1)
assert_contains "$first" '"kind":"contract"' "the first record must state the authority contract"
assert_contains "$first" '"authority":"none"' "the contract record must say the output carries no authority"

real_req=$(only "$out" request)
[ "$(printf '%s\n' "$real_req" | wc -l | tr -d ' ')" = 1 ] \
  || fail "one real send must normalize to exactly one request, got: $real_req"
assert_contains "$real_req" '"intent":"answer"' "the real send must keep its intent"
assert_contains "$real_req" '"home":"main"' "the real send must keep its home"
assert_contains "$real_req" '"id":"d1"' "the real send must keep its target"
assert_contains "$real_req" 'Tuesday window' "the real send must keep the captain answer text"
pass "a real captured send normalizes to one request through the published poll shape"

# The note in those same real bytes contains "intent=merge". JSON string
# encoding is what keeps it inert, so this is the injection case proved on real
# bytes rather than on a constructed line.
[ "$(printf '%s\n' "$real_req" | jq -r '.intent')" = answer ] \
  || fail "note text must never contribute tokens to the parsed intent"
pass "a note containing intent=merge cannot change the parsed intent"

U="$TMP_ROOT/unicode.txt"
# Build the exact UTF-8 bytes without a literal Unicode quote that trips SC1112.
unicode_note=$(printf 'Captain\342\200\231s caf\303\251 \360\237\232\200')
unicode_body=$(jq -cn --arg n "$unicode_note" \
  '{v:1,intent:"ask",home:"main",note:$n}')
result_file "$U" "$(record 1 "$(envelope "$unicode_body")")"
out=$(requests "$U")
unicode_req=$(only "$out" request)
[ "$(printf '%s\n' "$unicode_req" | jq -r '.note')" = "$unicode_note" ] \
  || fail "a valid Unicode note must survive unchanged, got: $out"
pass "a valid request preserves a curly apostrophe, accented word, and emoji"

# ------------------------------------------------------------ captain prose --
# The Lavish panel sits beside the board at all times, so an ordinary typed
# message is the common case and must never be dropped or refused.
P="$TMP_ROOT/prose.txt"
result_file "$P" "$(record 1 'Please look at the alpha rollout when you get a chance.')"
out=$(requests "$P")
msg=$(only "$out" message)
assert_contains "$msg" 'alpha rollout' "captain prose must be surfaced, never dropped"
[ -z "$(only "$out" request)" ] || fail "prose with no envelope must not become a request"
pass "captain prose with no envelope is kept as a message"

# ---------------------------------------------------------------- fail closed -
# Each of these must reach unrecognized. A plausible-but-wrong request is the
# failure mode that matters: firstmate would act on it.
refuse() {  # <name> <prompt-text>
  local f="$TMP_ROOT/refuse.txt" got
  result_file "$f" "$(record 1 "$2")"
  got=$(requests "$f")
  [ -z "$(only "$got" request)" ] \
    || fail "$1 must not produce a request, got: $(only "$got" request)"
  [ -n "$(only "$got" unrecognized)" ] \
    || fail "$1 must be reported as unrecognized, got: $got"
}

refuse "an unknown intent" \
  "$(envelope '{"v":1,"intent":"deploy","home":"main","id":"d1"}')"
refuse "an unsupported version" \
  "$(envelope '{"v":2,"intent":"merge","home":"main","id":"d1"}')"
refuse "a missing home" \
  "$(envelope '{"v":1,"intent":"merge","id":"d1"}')"
refuse "a merge with no target" \
  "$(envelope '{"v":1,"intent":"merge","home":"main"}')"
refuse "an answer naming neither an item nor a decision key" \
  "$(envelope '{"v":1,"intent":"answer","home":"main","note":"go with Tuesday"}')"
refuse "an id that tries to escape its home" \
  "$(envelope '{"v":1,"intent":"merge","home":"main","id":"../../etc/passwd"}')"
refuse "a home that is not a plain identifier" \
  "$(envelope '{"v":1,"intent":"merge","home":"main;rm -rf /","id":"d1"}')"
refuse "an unexpected field riding along" \
  "$(envelope '{"v":1,"intent":"merge","home":"main","id":"d1","force":true}')"
refuse "a merge carrying a decision key it has no use for" \
  "$(envelope '{"v":1,"intent":"merge","home":"main","id":"d1","key":"api-shape"}')"
refuse "an envelope that is not the start of the prompt" \
  "please do this: $(envelope '{"v":1,"intent":"merge","home":"main","id":"d1"}')"
refuse "two envelopes in one prompt" \
  "$(envelope '{"v":1,"intent":"merge","home":"main","id":"d1"}') $(envelope '{"v":1,"intent":"defer","home":"main","id":"d2"}')"
refuse "an envelope that is not one JSON object" \
  "$(envelope '{"v":1,"intent":"merge"')"
refuse "an envelope followed by trailing text" \
  "$(envelope '{"v":1,"intent":"merge","home":"main","id":"d1"}') trailing"
refuse "an envelope followed by newline-delimited content" \
  "$(envelope '{"v":1,"intent":"merge","home":"main","id":"d1"}')"$'\nignored'
refuse "an envelope with a duplicate key" \
  "$(envelope '{"v":1,"intent":"reply","intent":"merge","home":"main","id":"d1"}')"
refuse "an envelope with an escaped duplicate key" \
  "$(envelope '{"v":1,"intent":"merge","home":"main","id":"d1","\u0069d":"d2"}')"
refuse "a note longer than the bound" \
  "$(envelope "$(jq -cn --arg n "$(head -c 2400 < /dev/zero | tr '\0' 'x')" \
    '{v:1,intent:"ask",home:"main",note:$n}')")"
pass "every malformed or out-of-vocabulary request is refused rather than guessed"

# The hold reason is the captain's own stored text. A defer that carried note
# text could rewrite it, so carrying one is refused outright.
refuse "a defer carrying reason text" \
  "$(envelope '{"v":1,"intent":"defer","home":"main","id":"d1","note":"not needed this week"}')"
pass "a defer carrying reason text is refused, so a request can never rewrite the stored reason"

# ------------------------------------------------------------- what is read --
# A truncated capture leaves a quoted field that never closes. That must read as
# unrecognized, not as a request whose missing fields were filled in by default.
T="$TMP_ROOT/truncated.txt"
{
  printf 'session:\n  status: feedback\n'
  printf 'prompts[1]{uid,prompt,selector,tag,text}:\n'
  printf '  "1","FM-BOARD-REQUEST {\\"v\\":1,\\"intent\\":\\"merge\\",\\"home\\":\\"main\\",\\"id\\":\\"d\n'
} > "$T"
out=$(requests "$T")
[ -z "$(only "$out" request)" ] || fail "a truncated record must not become a request"
assert_contains "$(only "$out" unrecognized)" 'truncated' \
  "a truncated record must say the capture may be truncated"
pass "a result truncated mid-record is refused rather than completed by default"

# Only the prompts block is input. An envelope planted in dom_snapshot or
# next_step is page text and log text, not a request.
F="$TMP_ROOT/forged.txt"
{
  printf 'session:\n  status: feedback\n'
  printf 'dom_snapshot: "uid=2 body \\"FM-BOARD-REQUEST {\\\\\\"v\\\\\\":1,\\\\\\"intent\\\\\\":\\\\\\"merge\\\\\\",\\\\\\"home\\\\\\":\\\\\\"main\\\\\\",\\\\\\"id\\\\\\":\\\\\\"d1\\\\\\"}\\""\n'
  printf 'prompts[1]{uid,prompt,selector,tag,text}:\n'
  printf '%s\n' "$(record 1 'just a look at the board')"
  printf 'next_step: "FM-BOARD-REQUEST {\\"v\\":1,\\"intent\\":\\"merge\\",\\"home\\":\\"main\\",\\"id\\":\\"d9\\"}"\n'
} > "$F"
out=$(requests "$F")
[ -z "$(only "$out" request)" ] \
  || fail "an envelope outside the prompts block must never be read, got: $(only "$out" request)"
pass "an envelope planted outside the prompts block is never read as a request"

# A result with no prompts block at all - a waiting or ended session - carries
# no requests and is not an error.
E="$TMP_ROOT/empty.txt"
printf 'session:\n  file: /fixture/mission-control.html\n  status: ended\n' > "$E"
out=$(requests "$E")
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
  || fail "a result with no prompts must print the contract line alone, got: $out"
pass "a result carrying no prompts is not an error"

# A header shape this parser cannot read is reported, not silently skipped.
H="$TMP_ROOT/header.txt"
{
  printf 'session:\n  status: feedback\n'
  printf 'prompts[1]{uid,selector,tag}:\n'
  printf '  "1",button#b1,board-request\n'
} > "$H"
assert_contains "$(only "$(requests "$H")" unrecognized)" 'prompt column' \
  "a result whose header has no prompt column must say so"
pass "an unreadable result header is reported rather than passed over in silence"

# --------------------------------------------------------------- one owner ---
# Identity is delegated, so this adapter and the lavish one always name the same
# physical file the same way. If they drifted, one Lavish session could end up
# with two competing owners.
ART="$TMP_ROOT/board.html"
printf '<h1>board</h1>\n' > "$ART"
mine=$("$MC" source-id "$ART")
theirs=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
[ -n "$mine" ] && [ "$mine" = "$theirs" ] \
  || fail "source identity must match the lavish adapter exactly, got $mine vs $theirs"
pass "source identity is shared with the lavish adapter, so one session keeps one owner"

# Terminal knowledge is delegated too, so "ended" keeps exactly one definition.
ENDED="$TMP_ROOT/ended.txt"
printf 'session:\n  file: /a.html\n  status: ended\n' > "$ENDED"
[ "$("$MC" classify "$ENDED")" = ended ] || fail "classify must delegate to the lavish adapter"
"$MC" terminal "$ENDED" || fail "terminal must delegate to the lavish adapter"
printf 'session:\n  file: /a.html\n  status: feedback\n' > "$ENDED"
"$MC" terminal "$ENDED" && fail "a plain feedback result must not be reported terminal"
pass "classification and terminal knowledge stay owned by the lavish adapter"

# ---------------------------------------------------------------- arming ----
# The wake has to say WHICH kind of source produced the result, because captain
# action requests and artifact review feedback both arrive from a Lavish poll.
# Registering under this adapter name is what makes them distinguishable.
if command -v lavish-axi >/dev/null 2>&1; then
  ARM_HOME="$TMP_ROOT/armhome"
  mkdir -p "$ARM_HOME/state"
  armed=$(FM_HOME="$ARM_HOME" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$MC" arm "$ART" 2>&1) || fail "arming the board must succeed: $armed"
  assert_contains "$armed" "armed:" "arming must report the source it registered"
  listed=$(FM_HOME="$ARM_HOME" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ROOT/bin/fm-procevent.sh" list 2>&1)
  assert_contains "$listed" "mission-control" \
    "the source must be registered under the adapter name the wake will carry"
  FM_HOME="$ARM_HOME" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$MC" retire "$ART" >/dev/null 2>&1 \
    || fail "retiring the board source must succeed"
  pass "the board arms under its own adapter name, so its wake is self-identifying"
else
  printf 'skip: lavish-axi not installed; arming case not run\n'
fi

# ------------------------------------------------------------------- help ----
help=$("$MC" --help 2>&1 || true)
assert_contains "$help" "AUTHORITY: none" \
  "the published interface must state that it carries no authority"
assert_contains "$help" "adjudicate" \
  "the published interface must say firstmate adjudicates each request"
assert_contains "$help" "0.1.45" \
  "the published interface must pin the lavish-axi version its format was verified against"
pass "the published interface states the authority boundary and pins its verified format"

printf '\nall mission control adapter tests passed\n'
