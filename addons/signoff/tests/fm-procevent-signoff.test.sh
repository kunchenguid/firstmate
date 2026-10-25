#!/usr/bin/env bash
# The sign-off adapter, driven through the process-event runner in a throwaway
# HOME with the process-event claim root redirected. Section A uses a stub
# sign-off-axi and a stub keyed-answer intake: a transient intake failure is
# offered again until the intake takes it, and a task held again after an
# answered card gets a live card of its own. Section B runs the real arm, hold
# and keyed-answer intake on a markdown-backed home: a hold raises its card with the
# right title, reason and close, a dated deferral raises none, and the reserved
# reconcile answer is refused for good, acked once, and leaves the hold open.
# Section A also follows the feedback trail: an answered card is marked Read once
# its captured result is handled (Main or the lead picked up the note), never
# before; NOT_FOUND counts as done and a sign-off-axi without the feedback
# command skips with one log line.
set -u

# The Firstmate checkout owns tests/lib.sh; FM_CODE_ROOT names that checkout.
CODE_ROOT=${FM_CODE_ROOT:-}
[ -n "$CODE_ROOT" ] && [ -f "$CODE_ROOT/tests/lib.sh" ] \
  || { echo "skip: set FM_CODE_ROOT to a Firstmate checkout"; exit 0; }
ADDONS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ADAPTER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fm-procevent-signoff.sh"
# shellcheck source=/dev/null
. "$CODE_ROOT/tests/lib.sh"

if ! command -v jq >/dev/null 2>&1; then echo "skip: jq not found"; exit 0; fi

TMP_ROOT=$(fm_test_tmproot fm-procevent-signoff)
export HOME="$TMP_ROOT/home" XDG_DATA_HOME="$TMP_ROOT/xdg-data" \
  XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

ROOTCOPY="$TMP_ROOT/root"
mkdir -p "$ROOTCOPY"
cp -R "$ROOT/bin" "$ROOTCOPY/bin"

FAKEBIN="$TMP_ROOT/fake-bin"
FM_HOME_DIR="$TMP_ROOT/fmhome"
mkdir -p "$FAKEBIN" "$FM_HOME_DIR/state"
export SIGNOFF_BOARD="$TMP_ROOT/board.json" HOLD_FILE="$TMP_ROOT/hold" \
  INTAKE_LOG="$TMP_ROOT/intake.log" INTAKE_RC="$TMP_ROOT/intake.rc" FEEDBACK_LOG="$TMP_ROOT/feedback.log"
printf '{}\n' > "$SIGNOFF_BOARD"
printf '0' > "$INTAKE_RC"

cat > "$FAKEBIN/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) echo 'sign-off-axi stub' ;;
  raise)
    shift
    key='' title='' about='' close='' askref='' why='' yes='' no='' rec='' recwhy='' dflt=''
    while [ "$#" -gt 1 ]; do
      case "$1" in
        --key) key=$2 ;;
        --title) title=$2 ;;
        --about) about=$2 ;;
        --close) close=$2 ;;
        --ask-ref) askref=$2 ;;
        --why) why=$2 ;;
        --outcome) case "$2" in yes=*) yes=$2 ;; no=*) no=$2 ;; esac ;;
        --recommend) rec=$2 ;;
        --recommend-reason) recwhy=$2 ;;
        --default) dflt=$2 ;;
      esac
      shift 2
    done
    if [ -z "$askref" ]; then
      echo "VALIDATION_ERROR: a new Decide card needs a captain ask reference. Pass --ask-ref <captain-message-id-or-hold-id>"
      exit 1
    fi
    case "$title" in *\?) ;; *) echo 'VALIDATION_ERROR: --title must be a question ending in "?"'; exit 1 ;; esac
    [ "$(wc -w <<<"$title")" -le 12 ] || { echo 'VALIDATION_ERROR: Write one plain question, 12 words or fewer; put the rest in --why'; exit 1; }
    for need in why yes no rec recwhy dflt; do
      [ -n "${!need}" ] || { echo "VALIDATION_ERROR: key $key: --$need is required"; exit 1; }
    done
    if jq -e --arg k "$key" '.[$k].answer != null' "$SIGNOFF_BOARD" >/dev/null; then
      echo 'already answered'
      exit 0
    fi
    jq --arg k "$key" --arg t "$title" --arg a "$about" --arg c "$close" --arg r "$askref" \
      '.[$k] = {answer: null, label: "", close: $c, at: null, title: $t, about: $a, ask_ref: $r}' \
      "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
    echo raised
    ;;
  answers) jq -c 'with_entries(select(.value.answer != null))' "$SIGNOFF_BOARD" ;;
  wait) exit 0 ;;
  status) jq -n --arg b "$SIGNOFF_BOARD" '{board: $b, status: "not running"}' ;;
  # feedback as sign-off-axi 0.6.1 answers it, or as an older one (old) that lacks it.
  feedback)
    printf '%s\n' "$*" >> "$FEEDBACK_LOG"
    case ${FEEDBACK_MODE:-ok} in
      old) printf 'error: "Unknown command: feedback"\ncode: VALIDATION_ERROR\n'; exit 2 ;;
      notfound) printf 'error: "nothing was sent on %s yet"\ncode: NOT_FOUND\n' "$2"; exit 1 ;;
    esac
    echo 'shows: Read' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/sign-off-axi"

cat > "$ROOTCOPY/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  open) [ -f "$HOLD_FILE" ] || exit 1; cat "$HOLD_FILE" ;;
  answers) cat >> "$INTAKE_LOG"; exit "$(cat "$INTAKE_RC")" ;;
  binding) echo origin ;;
  bind) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ROOTCOPY/bin/fm-captain-hold.sh"

adapter() {
  PATH="$FAKEBIN:$PATH" FM_CODE_ROOT="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ADAPTER" "$@"
}

runner() {
  PATH="$FAKEBIN:$PATH" FM_CODE_ROOT="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ROOTCOPY/bin/fm-procevent.sh" "$@"
}

hold_as() { printf '%s\n' "$1" > "$HOLD_FILE"; }

answer_card() {  # <key> <answer> <at>
  jq --arg k "$1" --arg a "$2" --arg at "$3" '.[$k] += {answer: $a, label: "", close: "done", at: $at}' \
    "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
}

delivered() { cat "$FM_HOME_DIR/state/signoff-delivered" 2>/dev/null || true; }

# picked_up <task-id>: the handler concludes the latest captured result carrying that task's answer.
picked_up() {
  local result
  result=$(grep -lF "\"key\":\"$1\"" "$FM_HOME_DIR/state/procevent-inbox"/signoff.*.result | sort -t. -k2 -n | tail -n 1)
  result=${result%.result}
  runner handled signoff "${result##*.}" >/dev/null || fail "the handler could not conclude the result for $1"
}

runner register signoff signoff -- "$ADAPTER" poll >/dev/null 2>&1 \
  || fail "could not register the sign-off source for the runner"
hold_as '2026-10-12T10:00:00Z#0'
if adapter raise internal-call '[captain-ask] Main42: Run a proof?' 'Needs a key from Main' release >/dev/null 2>&1; then
  fail 'a team call without an authored owner ask reached the board'
fi
[ "$(jq 'length' "$SIGNOFF_BOARD")" = 0 ] || fail 'the refused call left a card'
author() {
  FM_HOME="$1" python3 "$ADDONS/ask-default/bin/fm-captain-ask.py" add "$2" "${3:-Can you sign in to the release account?}" \
    --owner-must login --about 'The release account needs your sign in.' --why 'Publishing waits for your account access.' \
    --already 'The release checks passed.' --option 'Yes=Publishing continues after you sign in.' \
    --option 'No=The release stays unpublished.' --recommend Yes --reason 'The release checks passed.' --default No
}
for ask_id in T1 T2 T3 T4; do author "$FM_HOME_DIR" "$ask_id"; done
adapter raise T1 'Ship T1' 'needs a call' release >/dev/null 2>&1 || fail "first hold raised no card"
first=$(jq -r 'keys[0]' "$SIGNOFF_BOARD")
answer_card "$first" 'use the cheap plan' '2026-10-12T10:05:00Z'
rm -f "$HOLD_FILE"
hold_as '2026-10-12T11:00:00Z#0'
adapter raise T1 'Ship T1' 'needs a call again' release >/dev/null 2>&1 \
  || fail "a task held again after an answered card got no live card"
[ "$(jq 'keys | length' "$SIGNOFF_BOARD")" = 2 ] || fail "the re-hold did not add its own card"
second=$(jq -r --arg k "$first" 'keys[] | select(. != $k)' "$SIGNOFF_BOARD")
answer_card "$second" 'use the other plan' '2026-10-12T11:05:00Z'
out=$(adapter poll 2>/dev/null) || fail "poll found no answer for the re-held task"
[ "$(printf '%s\n' "$out" | jq -s 'length')" = 1 ] || fail "poll offered more than the new answer: $out"
[ "$(printf '%s\n' "$out" | jq -r .answer)" = 'use the other plan' ] \
  || fail "poll offered the earlier card's answer: $out"
jq -e 'to_entries | all(.value.ask_ref == "T1" and (.value.title == "Can you sign in to the release account?"))' "$SIGNOFF_BOARD" >/dev/null \
  || fail "a raised card lacks the hold task id as its ask reference: $(cat "$SIGNOFF_BOARD")"
pass "a task held again after an answered card gets a live card of its own, each raised with the hold id as --ask-ref"

rm -f "$HOLD_FILE" "$SIGNOFF_BOARD" "$FM_HOME_DIR/state/signoff-delivered"
printf '{}\n' > "$SIGNOFF_BOARD"
rm -f "$HOLD_FILE" "$SIGNOFF_BOARD" "$FM_HOME_DIR/state/signoff-delivered"
printf '{}\n' > "$SIGNOFF_BOARD"
hold_as '2026-10-12T12:00:00Z#0'
adapter raise T2 'Ship T2' 'needs a call' "done" >/dev/null 2>&1 || fail "hold T2 raised no card"
key=$(jq -r 'keys[0]' "$SIGNOFF_BOARD")
answer_card "$key" 'ship it' '2026-10-12T12:05:00Z'

printf '1' > "$INTAKE_RC"
out=$(runner start signoff 2>&1) || true
[ -z "$(delivered)" ] || fail "an answer the intake failed on was marked delivered"
case "$out" in *"answers-fed: signoff"*) fail "a failed intake was reported as fed" ;; esac
printf '0' > "$INTAKE_RC"
out=$(runner start signoff 2>&1) || true
case "$out" in *"answers-fed: signoff"*) : ;; *) fail "the answer was not offered again and fed: $out" ;; esac
delivered | grep -qF "T2" || fail "an accepted answer was not acknowledged"
pass "an answer the intake fails on is offered again through the runner until the intake takes it"

hold_as '2026-10-12T13:00:00Z#0'
adapter raise T3 'Ship T3' 'needs a call' "done" >/dev/null 2>&1 || fail "hold T3 raised no card"
key3=$(jq -r --arg k "$key" 'keys[] | select(. != $k)' "$SIGNOFF_BOARD")
answer_card "$key3" 'not for the captain' '2026-10-12T13:05:00Z'
printf '3' > "$INTAKE_RC"
: > "$INTAKE_LOG"
out=$(runner start signoff 2>&1) || true
case "$out" in *"answers-fed: signoff"*) : ;; *) fail "a permanently skipped answer was not acknowledged: $out" ;; esac
delivered | grep -qF "T3" || fail "a permanently skipped answer was not recorded as delivered"
[ -z "$(adapter poll 2>/dev/null)" ] || fail "a permanently skipped answer was offered again"
printf '0' > "$INTAKE_RC"
pass "a batch whose every skip is permanent is acknowledged and not offered again"

[ -z "$(cat "$FEEDBACK_LOG" 2>/dev/null)" ] || fail "a card was marked Read before its note was picked up: $(cat "$FEEDBACK_LOG")"
picked_up T2
hold_as '2026-10-12T14:00:00Z#0'
adapter raise T4 'Ship T4' 'needs a call' "done" >/dev/null 2>&1 || fail "hold T4 raised no card"
key4=$(jq -r --arg a "$key" --arg b "$key3" 'keys[] | select(. != $a and . != $b)' "$SIGNOFF_BOARD")
answer_card "$key4" 'go ahead' '2026-10-12T14:05:00Z'
out=$(adapter poll 2>/dev/null) || fail "poll did not offer the next answer"
[ "$(jq -r .card <<<"$out")" = "$key4" ] || fail "poll did not carry the board card: $out"
[ "$(cat "$FEEDBACK_LOG")" = "feedback $key $SIGNOFF_BOARD --read" ] \
  || fail "the picked-up card was not marked Read on the board, or another was: $(cat "$FEEDBACK_LOG")"
adapter poll >/dev/null 2>&1
[ "$(wc -l < "$FEEDBACK_LOG")" = 1 ] || fail "a card was marked Read twice: $(cat "$FEEDBACK_LOG")"
pass "an answered card is marked Read on its board once the handler picks up its note, once, and never before"

picked_up T3
out=$(FEEDBACK_MODE=notfound adapter poll 2>"$TMP_ROOT/poll.err") || fail "NOT_FOUND broke the poll"
[ "$(jq -r .answer <<<"$out")" = 'go ahead' ] || fail "NOT_FOUND kept the poll from offering the answer: $out"
[ ! -s "$TMP_ROOT/poll.err" ] || fail "NOT_FOUND was reported: $(cat "$TMP_ROOT/poll.err")"
adapter poll >/dev/null 2>&1
[ "$(grep -c -- "feedback $key3 " "$FEEDBACK_LOG")" = 1 ] || fail "a NOT_FOUND card was asked again: $(cat "$FEEDBACK_LOG")"
pass "sign-off's NOT_FOUND counts as done and leaves the poll undisturbed"

runner start signoff >/dev/null 2>&1
delivered | grep -qF "T4" || fail "the T4 answer was not acknowledged"
picked_up T4
out=$(FEEDBACK_MODE=old adapter poll 2>&1 >/dev/null) || true
[ "$(grep -c 'no feedback command' <<<"$out")" = 1 ] || fail "an older sign-off-axi did not skip with one log line: $out"
out=$(FEEDBACK_MODE=old adapter poll 2>&1 >/dev/null) || true
[ -z "$out" ] && [ "$(grep -c -- "feedback $key4 " "$FEEDBACK_LOG")" = 1 ] \
  || fail "an older sign-off-axi was asked again or logged again: $out"
pass "a sign-off-axi without the feedback command skips with one log line and the poll goes on"

TASKS_AXI_BIN=$(command -v tasks-axi 2>/dev/null || :)

# Own minimal beads fixture: the upstream copy lives inside a test body, not in a
# sourceable helper, so no upstream function is shared here. Keep this small.
beads_probe() {
  local base="$TMP_ROOT/beads-probe"
  mkdir -p "$base/home" && git init -q "$base/graph" || return 1
  (cd "$base/graph" && bd init) >/dev/null 2>&1 || return 1
  printf 'backend = "beads"\n[beads]\npath = "%s/graph/.beads"\nbinary = "bd"\nprefix = "fm"\n' "$base" > "$base/home/.tasks.toml"
  (cd "$base/home" && tasks-axi list) >/dev/null 2>&1
}

BEADS_AVAILABLE=yes
if [ -z "$TASKS_AXI_BIN" ] || ! command -v bd >/dev/null 2>&1 || ! beads_probe; then
  BEADS_AVAILABLE=no
  echo "using markdown for the real-hold journey: beads is unavailable"
fi

make_beads_home() {  # <name>; prints the fixture home
  local base="$TMP_ROOT/$1" home graph
  home="$base/home"
  if [ "$BEADS_AVAILABLE" = no ]; then
    mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state"
    fm_test_tasks_toml "$home/.tasks.toml"
    printf '%s\n' "$home"
    return
  fi
  graph="$base/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state" "$graph"
  git init -q "$graph"
  (cd "$graph" && bd init) >"$base.init.log" 2>&1 || fail "fixture bd init failed for $1"
  printf 'backend = "beads"\n[beads]\npath = "%s/.beads"\nbinary = "bd"\nprefix = "fm"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' "$graph" > "$home/.tasks.toml"
  printf "%s\n" "$home"
}

real_env() {  # <home> <command args...>; the real adapter, hold, runner and intake
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_CODE_ROOT="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_ADDONS_DIR="$ADDONS" FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$@"
}

fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
real_home=$(make_beads_home real)
SIGNOFF_BOARD="$real_home/board.json"
export SIGNOFF_BOARD
printf '{}\n' > "$SIGNOFF_BOARD"
(cd "$real_home" && BEADS_ACTOR=fixture tasks-axi add fm-sample-work "Gated work") >/dev/null 2>&1 \
  || fail "could not create the existing work item"
real_env "$real_home" "$ADAPTER" arm >/dev/null \
  || fail "the real sign-off adapter did not arm"

board_count() { jq 'length' "$SIGNOFF_BOARD"; }
card_for() { jq -r --arg t "$1" 'to_entries[] | select(.value.title == $t) | .key' "$SIGNOFF_BOARD"; }

if real_env "$real_home" "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-team --title 'Main picks' --reason 'Needs a key from Main' >/dev/null 2>&1; then
  fail 'the real hold caller posted a team call without an authored owner ask'
fi
[ "$(board_count)" = 0 ] || fail 'the real hold caller leaked a team card'
author "$real_home" fm-sample-q 'Can you sign in to the release account?'
author "$real_home" fm-sample-work 'Can you sign in to the test account?'
real_env "$real_home" "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-q \
  --title "Pick the route" --reason "Which route?" >/dev/null \
  || fail "the captain question was not held"
real_env "$real_home" "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-work \
  --title "Gated work" --reason "captain approves the work" >/dev/null \
  || fail "the existing work item was not held"
before=$(board_count)
real_env "$real_home" "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-later \
  --title "Deferred call" --reason "revisit later" --until 2026-12-01 >/dev/null \
  || fail "the dated deferral was not held"
[ "$(board_count)" = "$before" ] || fail "a dated deferral raised a card: $(cat "$SIGNOFF_BOARD")"

q=$(card_for "Can you sign in to the release account?")
[ -n "$q" ] || fail "the held question raised no card: $(cat "$SIGNOFF_BOARD")"
jq -e --arg k "$q" '.[$k] | .about == "The release account needs your sign in.\nPublishing waits for your account access.\nThe release checks passed." and .close == "done"' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the question card lost its reason or close: $(cat "$SIGNOFF_BOARD")"
w=$(card_for "Can you sign in to the test account?")
[ -n "$w" ] || fail "the held existing work item raised no card: $(cat "$SIGNOFF_BOARD")"
jq -e --arg k "$w" '.[$k] | .about == "The release account needs your sign in.\nPublishing waits for your account access.\nThe release checks passed." and .close == "release"' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the work card lost its reason or close: $(cat "$SIGNOFF_BOARD")"
pass "a new question raises a done card and an existing work item a release card, each with authored context; raw backlog titles are never published; a dated deferral raises none"

jq --arg k "$q" '.[$k] += {answer: "reconcile", label: "", close: "done", at: "2026-10-12T23:00:00Z"}' \
  "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
out=$(real_env "$real_home" "$ROOT/bin/fm-procevent.sh" start signoff 2>&1) || true
case "$out" in *"answers-fed: signoff"*) : ;; *) fail "a permanently refused answer was not acknowledged: $out" ;; esac
[ "$(grep -c 'refused: fm-sample-q' <<<"$out")" = 1 ] || fail "the refusal was not reported exactly once: $out"
show=$(cd "$real_home" && BEADS_ACTOR=fixture tasks-axi show fm-sample-q --full 2>&1)
case "$show" in *"held: yes"*) : ;; *) fail "a refused reconcile answer released the hold: $show" ;; esac
grep -qF 'fm-sample-q' "$real_home/state/signoff-delivered" || fail "the refused answer was not recorded as delivered"
[ -z "$(real_env "$real_home" "$ADAPTER" poll 2>/dev/null)" ] \
  || fail "the refused answer was offered again"
pass "a permanently refused reserved answer is acked once, reported once, and leaves its hold open"

echo "all fm-procevent-signoff tests passed"
