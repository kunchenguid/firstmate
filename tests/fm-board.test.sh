#!/usr/bin/env bash
# Behavior tests for the operator board renderer.
# Every case runs against fixture state rather than a live fleet: one real
# fm-fleet-snapshot.sh run over a fixture home produces the snapshot the render
# cases then consume, so the file-to-artifact path is exercised end to end while
# each column is asserted from its own source.
# Covers the four columns and their sources, a blocked and a date-gated queued
# item, an unelaborated decision key surviving into the board, refusal of
# malformed authored input, the answer-identification contract, a well-formed
# and self-contained artifact, and the leak boundary.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
SNAPSHOT_CMD="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SECRET=fmx-pairing-token-must-not-leak-9d1

# The fixture stubs only what the canonical snapshot reaches for locally; the
# board itself makes no network or backend call of its own.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh must not be called" >&2
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh"
  printf '%s\n' "$fb"
}

record_claude_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 semantic=$3 gen event
  case "$semantic" in
    busy) event=user-prompt-submit ;;
    *) event=stop ;;
  esac
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$semantic" --gen "$gen" \
    --source claude-hook --event "$event"
}

# One fixture home carrying, deliberately, one of each thing a column reads:
# a working ship task with a recorded pull request, a parked task holding an
# unresolved decision key, a queued item blocked by another item, a queued item
# behind a date gate, a captain-held queued item, and two landings whose
# delivery artifacts differ (a pull request and a recorded set of findings).
write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/state" "$home/data/scout-b" "$home/config" "$home/projects/wt" "$home/projects/tung"
  printf 'FMX_PAIRING_TOKEN=%s\n' "$SECRET" > "$home/.env"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-a - Ship the mating corners (repo: tung) (kind: ship) (since 2026-07-11)
- [ ] listen-b - Sitting surface: collapse answered clips (repo: tung) (kind: ship) (since 2026-07-11)

## Queued
- [ ] carrier-c - Carrier question redesign blocked-by: listen-b (repo: tung) (kind: ship)
- [ ] winlane-d - Revisit the Windows build lane (repo: litany) (kind: ship) (hold: time gate: revisit on/after 2026-08-20) (hold-until: 2026-08-20)
- [ ] meshnote-e - Ship the mesh accuracy note (repo: tung) (kind: captain) (hold: waiting on the captain's word) (hold-kind: captain)

## Done
- [x] corners-f - Tile mating corners https://github.com/notno/tung/pull/13 (repo: tung) (kind: ship) (merged 2026-07-10)
- [x] scout-b - Grasshopper verdict data/scout-b/report.md (repo: tung) (kind: scout) (reported 2026-07-10)
EOF
  printf '# Grasshopper\n' > "$home/data/scout-b/report.md"
  fm_write_meta "$home/state/ship-a.meta" \
    "window=firstmate:fm-ship-a" \
    "worktree=$home/projects/wt" \
    "project=$home/projects/tung" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/notno/tung/pull/13"
  record_claude_state "$home/state" ship-a busy
  fm_write_meta "$home/state/listen-b.meta" \
    "window=firstmate:fm-listen-b" \
    "worktree=$home/projects/wt" \
    "project=$home/projects/tung" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_state "$home/state" listen-b idle
  printf 'needs-decision [key=blind-src]: a filename naming the target renders on a blind row\n' \
    > "$home/state/listen-b.status"
}

HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(make_fakebin "$TMP_ROOT")
write_fixture "$HOME_DIR"

SNAP="$TMP_ROOT/snap.json"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$SNAPSHOT_CMD" --json > "$SNAP" \
  || fail "the fixture snapshot could not be taken"

render() {  # <out> [args...]
  local out=$1; shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$BOARD" --snapshot "$SNAP" --out "$out" "$@"
}

# --- the four columns render from their sources ------------------------------

OUT="$TMP_ROOT/board.html"
PRINTED=$(render "$OUT") || fail "the board did not render from fixture state"
[ "$PRINTED" = "$OUT" ] || fail "the board must print the artifact path it wrote (got '$PRINTED')"
assert_present "$OUT" "the board wrote no artifact"
BOARD_HTML=$(cat "$OUT")

assert_contains "$BOARD_HTML" "Waiting on you" "the Waiting-on-you column is missing"
assert_contains "$BOARD_HTML" "Under way" "the Under-way column is missing"
assert_contains "$BOARD_HTML" "Queued" "the Queued column is missing"
assert_contains "$BOARD_HTML" "Landed" "the Landed column is missing"
pass "the board renders all four columns"

# Under way: one card per live report, carrying the state and the time it was read.
assert_contains "$BOARD_HTML" "Ship the mating corners" "the working task is missing from Under way"
assert_contains "$BOARD_HTML" "Sitting surface: collapse answered clips" "the parked task is missing from Under way"
assert_contains "$BOARD_HTML" "state as of " "an Under-way card does not carry the time its state was read"
UNDERWAY_CARDS=$(printf '%s' "$BOARD_HTML" | grep -o 'class="dot dot-' | wc -l | tr -d ' ')
[ "$UNDERWAY_CARDS" = 2 ] || fail "expected one Under-way card per live report, got $UNDERWAY_CARDS"
pass "Under way renders one stamped card per live report"

# Queued: the blocker and the date gate are both visible, so a reader can see why
# an item is not moving.
assert_contains "$BOARD_HTML" "Carrier question redesign" "the queued item is missing"
assert_contains "$BOARD_HTML" "waits on listen-b" "a blocked queued item does not show its blocker"
assert_contains "$BOARD_HTML" "held until 2026-08-20" "a date-gated queued item does not show its gate"
pass "Queued shows blockers and date gates"

# Landed: recent completions with the artifact each one delivered.
assert_contains "$BOARD_HTML" "Tile mating corners" "the landed item is missing"
assert_contains "$BOARD_HTML" "https://github.com/notno/tung/pull/13" "a landing does not carry its delivery artifact"
assert_contains "$BOARD_HTML" "data/scout-b/report.md" "a reported landing does not carry its findings"
pass "Landed carries each completion's delivery artifact"

# Waiting on you, the mechanical half.
assert_contains "$BOARD_HTML" "Waiting for your merge" "recorded work awaiting a merge is not surfaced"
assert_contains "$BOARD_HTML" "Held for your word" "a captain-held queued item is not surfaced"
pass "the mechanical half of Waiting on you comes from durable state"

# --- an unelaborated decision key still appears ------------------------------

assert_contains "$BOARD_HTML" "listen-b:blind-src" "an unresolved decision key was dropped from the board"
assert_contains "$BOARD_HTML" "Not written up yet" "an unelaborated decision is not marked as such"
pass "a decision key with no authored card still appears, marked unelaborated"

# --- authored cards merge into the same column -------------------------------

CARDS="$TMP_ROOT/cards.txt"
cat > "$CARDS" <<'EOF'
# authored by hand

[decision]
key: blind-prose
binds: listen-b:blind-src
title: Prose above blind clips
tag: listening screen
body: A natural title hands over the *withheld* answer set one line above clean rows.
warn: Three rounds on one theme.
option: audit | **A, done properly** - enumerate every authored string with `grep`.
option: split | **D** - split the two kinds of sitting.
recommend: audit
footnote: If you like D I would take A as the interim.

[chores]
title: Only you can do these
item: **Tier-2 listening session.** 22 clips staged.
footnote: Nothing else needs your hands.
EOF

OUT2="$TMP_ROOT/board-cards.html"
render "$OUT2" --cards "$CARDS" >/dev/null || fail "the board did not render with authored cards"
CARD_HTML=$(cat "$OUT2")

assert_contains "$CARD_HTML" "Prose above blind clips" "the authored decision card is missing"
assert_contains "$CARD_HTML" "<strong>A, done properly</strong>" "authored bold markup did not render"
assert_contains "$CARD_HTML" "<em>withheld</em>" "authored italic markup did not render"
assert_contains "$CARD_HTML" "<code>grep</code>" "authored code markup did not render"
assert_contains "$CARD_HTML" "my pick" "the authored recommendation is not marked"
assert_contains "$CARD_HTML" "Only you can do these" "the authored chores card is missing"
assert_contains "$CARD_HTML" "Ship the mating corners" "the mechanical cards were displaced by authored ones"
assert_not_contains "$CARD_HTML" "Not written up yet" \
  "a decision with an authored card is still marked unelaborated"
pass "authored cards merge into Waiting on you beside the mechanical ones"

# Authored text is escaped before markup, so it cannot inject markup of its own.
INJECT="$TMP_ROOT/inject.txt"
cat > "$INJECT" <<'EOF'
[chores]
item: <script>alert(1)</script> and <b>bold</b>
EOF
OUT3="$TMP_ROOT/board-inject.html"
render "$OUT3" --cards "$INJECT" >/dev/null || fail "the board did not render the escaping case"
assert_grep "&lt;script&gt;alert(1)&lt;/script&gt;" "$OUT3" "authored markup was not escaped"
assert_no_grep "<b>bold</b>" "$OUT3" "authored markup reached the page unescaped"
pass "authored text cannot inject markup"

# --- malformed authored input is refused, never half-rendered ----------------

refuses() {  # <label> <cards-body>
  local label=$1 body=$2 out="$TMP_ROOT/refused.html" code
  printf '%s\n' "$body" > "$TMP_ROOT/bad.txt"
  rm -f "$out"
  render "$out" --cards "$TMP_ROOT/bad.txt" >/dev/null 2>"$TMP_ROOT/bad.err"
  code=$?
  expect_code 2 "$code" "$label"
  assert_absent "$out" "$label: an artifact was written despite refusing the input"
  grep -q "$TMP_ROOT/bad.txt:" "$TMP_ROOT/bad.err" || fail "$label: the refusal did not name the file and line"
}

refuses "an unknown card type" '[whatever]
title: x'
refuses "an unknown field" '[decision]
key: a
title: t
option: x | X
nope: y'
refuses "a decision with no option" '[decision]
key: a
title: t'
refuses "a decision with no key" '[decision]
title: t
option: x | X'
refuses "a chores card with no item" '[chores]
title: t'
refuses "a recommendation naming no option" '[decision]
key: a
title: t
option: x | X
recommend: zzz'
refuses "a duplicate key" '[decision]
key: a
title: t
option: x | X
[decision]
key: a
title: u
option: y | Y'
refuses "a field outside any card" 'title: orphan'
refuses "an unbalanced backtick" '[chores]
item: a `b'
refuses "a binding to no open decision" '[decision]
key: a
title: t
option: x | X
binds: listen-b:no-such-key'
pass "malformed authored input is refused rather than half-rendered"

# A binding that names a real decision is accepted, so the refusal above is about
# the binding being wrong and not about bindings being rejected wholesale.
printf '[decision]\nkey: a\ntitle: t\noption: x | X\nbinds: listen-b:blind-src\n' > "$TMP_ROOT/ok.txt"
render "$TMP_ROOT/ok.html" --cards "$TMP_ROOT/ok.txt" >/dev/null \
  || fail "a binding to a real open decision was rejected"
pass "a binding to a real open decision is accepted"

# --- answers arrive identified by question -----------------------------------

assert_grep 'name="blind-prose"' "$OUT2" "an answer is not identified by its question key"
assert_grep 'data-question="Prose above blind clips"' "$OUT2" "an answer carries no readable question"
assert_grep 'value="audit"' "$OUT2" "an option carries no answer value"
SEND_CONTROLS=$(grep -c 'id="send"' "$OUT2")
[ "$SEND_CONTROLS" = 1 ] || fail "expected exactly one send control, found $SEND_CONTROLS"
assert_grep "sendQueuedPrompts" "$OUT2" "the send control queues nothing"
assert_grep "sendBtn.disabled = true" "$OUT2" "the send control does not reset for a further round"
pass "answers are identified by question and one send control carries them"

# The page's own script has to parse, or none of the interaction above exists.
if command -v node >/dev/null 2>&1; then
  awk '/^<script>/{on=1;next} /^<\/script>/{on=0} on' "$OUT2" > "$TMP_ROOT/board.js"
  [ -s "$TMP_ROOT/board.js" ] || fail "the artifact carries no script"
  node --check "$TMP_ROOT/board.js" || fail "the artifact's script does not parse"
  pass "the artifact's script parses"
else
  echo "skip: node not found, artifact script not parsed"
fi

# --- the snapshot's age is visible and honest --------------------------------

assert_grep 'id="age"' "$OUT" "the artifact does not show its age"
assert_grep "too old to trust" "$OUT" "the artifact never admits to being too stale to trust"
assert_grep "a snapshot, not a live feed" "$OUT" "the artifact does not say what it is"
GEN=$(jq -r '.generated | sub("T.*"; "")' "$SNAP")
[ -n "$GEN" ] || fail "the fixture snapshot recorded no generation time"
pass "the artifact states its age and when it stops being trustworthy"

# --- well-formed and self-contained ------------------------------------------

balanced() {  # <tag> <file>
  local tag=$1 file=$2 open close
  open=$(grep -o "<${tag}[ >]" "$file" | wc -l | tr -d ' ')
  close=$(grep -o "</$tag>" "$file" | wc -l | tr -d ' ')
  [ "$open" = "$close" ] || fail "unbalanced <$tag>: $open opened, $close closed"
}
for tag in html head body header main section article div ul li p label span code strong em a button style script h1 h2 h3 title; do
  balanced "$tag" "$OUT2"
done
assert_grep "<!doctype html>" "$OUT2" "the artifact has no doctype"
pass "the emitted HTML is well-formed"

assert_no_grep "<link " "$OUT2" "the artifact loads an external stylesheet"
assert_no_grep "<script src" "$OUT2" "the artifact loads an external script"
assert_no_grep "@import" "$OUT2" "the artifact imports an external stylesheet"
assert_no_grep "url(http" "$OUT2" "the artifact fetches a remote asset"
assert_no_grep "<img" "$OUT2" "the artifact loads a remote image"
pass "the artifact is self-contained"

# --- nothing private leaks ---------------------------------------------------

assert_no_grep "$SECRET" "$OUT2" "a token from the home reached the artifact"
assert_no_grep "$HOME_DIR" "$OUT2" "an absolute private path reached the artifact"
assert_no_grep "$TMP_ROOT" "$OUT2" "an absolute fixture path reached the artifact"
assert_no_grep "firstmate:fm-ship-a" "$OUT2" "an internal endpoint address reached the artifact"
pass "no token or absolute private path reaches the artifact"

# Home-path redaction, proved by rendering with the fixture home AS the operator
# home: an absolute path carried in state prose comes out reduced.
cat >> "$HOME_DIR/data/backlog.md" <<EOF
- [x] pathy-g - Retire $HOME_DIR/projects/tung (repo: tung) (kind: ship) (done 2026-07-10)
EOF
SNAP2="$TMP_ROOT/snap2.json"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$SNAPSHOT_CMD" --json > "$SNAP2" \
  || fail "the redaction snapshot could not be taken"
OUT4="$TMP_ROOT/board-redact.html"
PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" FM_HOME="$HOME_DIR" "$BOARD" \
  --snapshot "$SNAP2" --landed 20 --out "$OUT4" >/dev/null \
  || fail "the board did not render the redaction case"
assert_grep "Retire ~/projects/tung" "$OUT4" "an operator-home path was not reduced"
assert_no_grep "$HOME_DIR/projects/tung" "$OUT4" "an operator-home path survived into the artifact"
pass "paths under the operator home are reduced before rendering"

# --- bounds and the live path ------------------------------------------------

OUT5="$TMP_ROOT/board-bounded.html"
render "$OUT5" --landed 1 >/dev/null || fail "the board did not render with a landing bound"
assert_grep "older landings not shown" "$OUT5" "a bounded Landed column hides what it dropped"
pass "a bounded Landed column discloses what it left out"

OUT6="$TMP_ROOT/live.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$BOARD" --out "$OUT6" >/dev/null \
  || fail "the board did not render by taking its own snapshot"
assert_grep "Ship the mating corners" "$OUT6" "the self-snapshotting path rendered no work"
pass "the board takes its own snapshot when none is supplied"

# An empty home is a legitimate board, not an error.
EMPTY="$TMP_ROOT/empty-home"
mkdir -p "$EMPTY/state" "$EMPTY/data" "$EMPTY/config" "$EMPTY/projects"
OUT7="$TMP_ROOT/empty.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$EMPTY" "$BOARD" --out "$OUT7" >/dev/null \
  || fail "the board refused to render an empty home"
assert_grep "Nothing is waiting on you." "$OUT7" "an empty board does not say so"
assert_grep "Nothing under way." "$OUT7" "an empty board does not say so"
pass "an empty fleet renders an honest empty board"

echo "all fm-board tests passed"
