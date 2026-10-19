#!/usr/bin/env bash
# The sign-off adapter, driven through the process-event runner in a throwaway
# HOME with the process-event claim root redirected. Section A uses a stub
# sign-off-axi and a stub keyed-answer intake: a transient intake failure is
# offered again until the intake takes it, and a task held again after an
# answered card gets a live card of its own. Section B runs the real arm, hold
# and keyed-answer intake on a beads-backed home: a hold raises its card with the
# right title, reason and close, a dated deferral raises none, and the reserved
# reconcile answer is refused for good, acked once, and leaves the hold open.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-procevent-signoff)
export HOME="$TMP_ROOT/home" XDG_DATA_HOME="$TMP_ROOT/xdg-data" \
  XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

ROOTCOPY="$TMP_ROOT/root"
mkdir -p "$ROOTCOPY"
cp -R "$ROOT/bin" "$ROOTCOPY/bin"

FAKEBIN="$TMP_ROOT/fakebin"
FM_HOME_DIR="$TMP_ROOT/fmhome"
mkdir -p "$FAKEBIN" "$FM_HOME_DIR/state"
export SIGNOFF_BOARD="$TMP_ROOT/board.json" HOLD_FILE="$TMP_ROOT/hold" \
  INTAKE_LOG="$TMP_ROOT/intake.log" INTAKE_RC="$TMP_ROOT/intake.rc"
printf '{}\n' > "$SIGNOFF_BOARD"
printf '0' > "$INTAKE_RC"

cat > "$FAKEBIN/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) echo 'sign-off-axi stub' ;;
  raise)
    shift
    [ -z "${SIGNOFF_REFUSE-}" ] || { echo 'error: refused by the stub'; exit 1; }
    key='' title='' about='' close='' why=''
    while [ "$#" -gt 1 ]; do
      case "$1" in
        --key) key=$2 ;;
        --title) title=$2 ;;
        --about) about=$2 ;;
        --why) why=$2 ;;
        --close) close=$2 ;;
      esac
      shift 2
    done
    if jq -e --arg k "$key" '.[$k].answer != null' "$SIGNOFF_BOARD" >/dev/null; then
      echo 'already answered'
      exit 0
    fi
    jq --arg k "$key" --arg t "$title" --arg a "$about" --arg c "$close" --arg w "$why" \
      '.[$k] = {answer: null, label: "", close: $c, at: null, title: $t, about: $a, why: $w}' \
      "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
    echo raised
    ;;
  answers) jq -c 'with_entries(select(.value.answer != null))' "$SIGNOFF_BOARD" ;;
  wait) exit 0 ;;
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
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ROOTCOPY/bin/fm-procevent-signoff.sh" "$@"
}

runner() {
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ROOTCOPY/bin/fm-procevent.sh" "$@"
}

hold_as() { printf '%s\n' "$1" > "$HOLD_FILE"; }

answer_card() {  # <key> <answer> <at>
  jq --arg k "$1" --arg a "$2" --arg at "$3" '.[$k] += {answer: $a, label: "", close: "done", at: $at}' \
    "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
}

delivered() { cat "$FM_HOME_DIR/state/signoff-delivered" 2>/dev/null || true; }

runner register signoff signoff -- "$ROOTCOPY/bin/fm-procevent-signoff.sh" poll >/dev/null 2>&1 \
  || fail "could not register the sign-off source for the runner"
hold_as '2026-10-12T10:00:00Z#0'
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
pass "a task held again after an answered card gets a live card of its own"

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

# The installed sign-off-axi is the contract: a raise it refuses must break here.
if command -v sign-off-axi >/dev/null 2>&1; then
  real_signoff=$(command -v sign-off-axi)
  mkdir -p "$TMP_ROOT/realbin"
  ln -s "$real_signoff" "$TMP_ROOT/realbin/sign-off-axi"
  hold_as '2026-10-12T13:00:00Z#0'
  # The tool is armed by the source file alone; $HOME is the throwaway one, so its default board is private.
  PATH="$TMP_ROOT/realbin:$PATH" FM_ROOT_OVERRIDE="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ROOTCOPY/bin/fm-procevent-signoff.sh" raise live 'Live contract' \
    'Does the live contract hold up? More detail follows.' 'done' >/dev/null 2>"$TMP_ROOT/real-stderr" \
    || fail "the installed sign-off-axi refused the card: $(cat "$TMP_ROOT/real-stderr")"
  grep -qF 'Does the live contract hold up?' "$HOME/.sign-off/decisions.json" \
    || fail "the installed sign-off-axi holds no card for the hold"
  pass "the installed sign-off-axi accepts the card a hold raises"

  raise_live() {  # <task-id> <reason>
    PATH="$TMP_ROOT/realbin:$PATH" FM_ROOT_OVERRIDE="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
      FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
      "$ROOTCOPY/bin/fm-procevent-signoff.sh" raise "$1" 'Live task' "$2" 'done' >/dev/null 2>"$TMP_ROOT/real-stderr"
  }
  card_titled() { jq -e --arg t "$1" '[.. | objects | select(.title? == $t)] | length > 0' "$HOME/.sign-off/decisions.json" >/dev/null; }

  hold_as '2026-10-12T14:00:00Z#0'
  raise_live noq 'needs a call' || fail "the installed sign-off-axi refused a card for a reason with no question: $(cat "$TMP_ROOT/real-stderr")"
  card_titled 'needs a call?' || fail "the card for a reason with no question has no title"
  pass "a reason with no question raises a card with a question title"

  hold_as '2026-10-12T14:01:00Z#0'
  raise_live long 'Should we move the card raise to the nightly job after the migration lands on main?' \
    || fail "the installed sign-off-axi refused a card for a question over 12 words: $(cat "$TMP_ROOT/real-stderr")"
  card_titled 'Should we move the card raise to the nightly job after the?' \
    || fail "the card for a question over 12 words kept more than 12 words in its title"
  pass "a question over 12 words raises a card whose title is cut to 12 words"
else
  echo "skip: sign-off-axi is not installed; the live raise contract was not checked"
fi

# A refused raise must be loud: the adapter exits nonzero with the tool's own text.
cat > "$TMP_ROOT/refusebin-sign-off-axi" <<'SH'
#!/usr/bin/env bash
echo 'error: --why is required'; exit 1
SH
mkdir -p "$TMP_ROOT/refusebin"; mv "$TMP_ROOT/refusebin-sign-off-axi" "$TMP_ROOT/refusebin/sign-off-axi"; chmod +x "$TMP_ROOT/refusebin/sign-off-axi"
out=$(PATH="$TMP_ROOT/refusebin:$PATH" FM_ROOT_OVERRIDE="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
  FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
  "$ROOTCOPY/bin/fm-procevent-signoff.sh" raise T9 'Ship T9' 'needs a call' 'done' 2>&1) \
  && fail "a refused raise exited zero"
case "$out" in *"--why is required"*) : ;; *) fail "the refusal text was lost: $out" ;; esac
pass "a refused raise exits nonzero with the sign-off-axi error text"

cat > "$TMP_ROOT/refusebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
echo 'error: key already holds a different question'; exit 1
SH
out=$(PATH="$TMP_ROOT/refusebin:$PATH" FM_ROOT_OVERRIDE="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
  FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
  "$ROOTCOPY/bin/fm-procevent-signoff.sh" raise T9 'Ship T9' 'Changed reason?' 'done' 2>&1) \
  || fail "a re-raise of an existing card with a changed question exited nonzero: $out"
case "$out" in *"already exists with another question"*) : ;; *) fail "the kept card was not reported: $out" ;; esac
pass "a re-raise of an existing card with a changed question keeps the card and exits zero"

hold_as '2026-10-12T13:10:00Z#0'
adapter raise T10 'Ship T10' 'Pick route? Ship v1 or v2? Reply by Friday.' 'done' >/dev/null 2>&1 \
  || fail "a card for a reason with several questions was not raised"
jq -e '.[] | select(.title == "Ship v1 or v2?" and .why == "Pick route? Ship v1 or v2? Reply by Friday. Answer yes or no. The hold stays open until you answer.")' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the card dropped reason text: $(jq -c . "$SIGNOFF_BOARD")"
hold_as '2026-10-12T13:11:00Z#0'
adapter raise T11 'Ship T11' 'Captain hold:' 'done' >/dev/null 2>&1 \
  || fail "a card for a reason that is only the hold prefix was not raised"
jq -e '.[] | select(.why == "Captain hold: Answer yes or no. The hold stays open until you answer.")' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the card for a prefix-only reason has no why"
pass "a card keeps every sentence of the reason and falls back to the raw reason for why"

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "skip: tasks-axi is not installed; the refused-card hold was not checked"
else
  md_home="$TMP_ROOT/md-home"
  mkdir -p "$md_home/data" "$md_home/config" "$md_home/projects" "$md_home/state"
  printf '# Backlog\n\n## Backlog\n\n## In flight\n\n## Done\n' > "$md_home/data/backlog.md"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$md_home/.tasks.toml"
  md_env() {
    PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$md_home" FM_STATE_OVERRIDE="$md_home/state" \
      FM_DATA_OVERRIDE="$md_home/data" FM_CONFIG_OVERRIDE="$md_home/config" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/md-claims" "$@"
  }
  md_env "$ROOT/bin/fm-procevent-signoff.sh" arm >/dev/null || fail "the markdown home did not arm the sign-off adapter"
  (cd "$md_home" && BEADS_ACTOR=fixture tasks-axi add fm-sample-refused "Refused card") >/dev/null 2>&1 \
    || fail "could not create the refused-card work item"
  export SIGNOFF_REFUSE=1
  if err=$(md_env "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-refused --title "Refused card" --reason "needs a call" 2>&1 >/dev/null); then
    unset SIGNOFF_REFUSE
    fail "a hold whose card was refused exited zero"
  fi
  unset SIGNOFF_REFUSE
  case "$err" in *"refused by the stub"*) : ;; *) fail "the card refusal text was lost: $err" ;; esac
  show=$(cd "$md_home" && BEADS_ACTOR=fixture tasks-axi show fm-sample-refused --full 2>&1)
  case "$show" in *"held: yes"*) : ;; *) fail "a refused card released the hold: $show" ;; esac
  pass "a hold whose card is refused exits nonzero with the sign-off error and stays held"
fi

TASKS_AXI_BIN=$(command -v tasks-axi || true)

probe_tasks_axi_beads() {
  local probe_home="$TMP_ROOT/.probe" probe_graph="$TMP_ROOT/.probe-fm"
  mkdir -p "$probe_home/data" "$probe_graph"
  git -C "$probe_graph" init -q
  (cd "$probe_graph" && bd init >/dev/null 2>&1) || return 1
  cat > "$probe_home/.tasks.toml" <<PROBEEOF
backend = "beads"

[beads]
path = "$probe_graph/.beads"
binary = "bd"
prefix = "fm"
PROBEEOF
  (cd "$probe_home" && tasks-axi list) >/dev/null 2>&1
}

if [ -z "$TASKS_AXI_BIN" ] || ! command -v bd >/dev/null 2>&1 || ! probe_tasks_axi_beads; then
  pass "skipped the real-hold section: no beads-capable tasks-axi and bd on this machine"
  echo "all fm-procevent-signoff tests passed"
  exit 0
fi

make_beads_home() {  # <name>; echoes the home
  local home="$TMP_ROOT/$1/home" graph="$TMP_ROOT/$1/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$graph" "$home/state"
  git -C "$graph" init -q
  (cd "$graph" && bd init >"$TMP_ROOT/$1-bd-init.log" 2>&1) || fail "fixture bd init failed"
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  printf '%s\n' "$home"
}

real_env() {  # <home> <command args...>; the real adapter, hold, runner and intake
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$@"
}

fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
real_home=$(make_beads_home real)
SIGNOFF_BOARD="$real_home/board.json"
export SIGNOFF_BOARD
printf '{}\n' > "$SIGNOFF_BOARD"
(cd "$real_home" && BEADS_ACTOR=fixture tasks-axi add fm-sample-work "Gated work") >/dev/null 2>&1 \
  || fail "could not create the existing work item"
real_env "$real_home" "$ROOT/bin/fm-procevent-signoff.sh" arm >/dev/null \
  || fail "the real sign-off adapter did not arm"

board_count() { jq 'length' "$SIGNOFF_BOARD"; }
card_for() { jq -r --arg t "$1" 'to_entries[] | select(.value.title == $t) | .key' "$SIGNOFF_BOARD"; }

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

q=$(card_for "Which route?")
[ -n "$q" ] || fail "the held question raised no card: $(cat "$SIGNOFF_BOARD")"
jq -e --arg k "$q" '.[$k] | .about == "Which route?" and .close == "done"' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the question card lost its reason or close: $(cat "$SIGNOFF_BOARD")"
w=$(card_for "captain approves the work")
[ -n "$w" ] || fail "the held existing work item raised no card: $(cat "$SIGNOFF_BOARD")"
jq -e --arg k "$w" '.[$k] | .about == "captain approves the work" and .close == "release"' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the work card lost its reason or close: $(cat "$SIGNOFF_BOARD")"
pass "a new question raises a done card and an existing work item a release card, each with its title and reason; a dated deferral raises none"


jq --arg k "$q" '.[$k] += {answer: "reconcile", label: "", close: "done", at: "2026-10-12T23:00:00Z"}' \
  "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
out=$(real_env "$real_home" "$ROOT/bin/fm-procevent.sh" start signoff 2>&1) || true
case "$out" in *"answers-fed: signoff"*) : ;; *) fail "a permanently refused answer was not acknowledged: $out" ;; esac
[ "$(grep -c 'refused: fm-sample-q' <<<"$out")" = 1 ] || fail "the refusal was not reported exactly once: $out"
show=$(cd "$real_home" && BEADS_ACTOR=fixture tasks-axi show fm-sample-q --full 2>&1)
case "$show" in *"held: yes"*) : ;; *) fail "a refused reconcile answer released the hold: $show" ;; esac
grep -qF 'fm-sample-q' "$real_home/state/signoff-delivered" || fail "the refused answer was not recorded as delivered"
[ -z "$(real_env "$real_home" "$ROOT/bin/fm-procevent-signoff.sh" poll 2>/dev/null)" ] \
  || fail "the refused answer was offered again"
pass "a permanently refused reserved answer is acked once, reported once, and leaves its hold open"

echo "all fm-procevent-signoff tests passed"
