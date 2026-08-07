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

# Snapshot prose is bounded on the text a reader sees, not on its escaped form,
# so a summary dense in characters that expand when escaped is not cut short of
# its own budget and a cut can never land inside an entity.
ENTITY_HOME="$TMP_ROOT/entity-home"
mkdir -p "$ENTITY_HOME/state" "$ENTITY_HOME/data" "$ENTITY_HOME/config" "$ENTITY_HOME/projects/tung"
printf '## In flight\n- [ ] dense-h - Dense summary (repo: tung) (kind: ship) (since 2026-07-11)\n' \
  > "$ENTITY_HOME/data/backlog.md"
fm_write_meta "$ENTITY_HOME/state/dense-h.meta" \
  "window=firstmate:fm-dense-h" \
  "worktree=$ENTITY_HOME/projects/tung" \
  "project=$ENTITY_HOME/projects/tung" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes"
record_claude_state "$ENTITY_HOME/state" dense-h idle
DENSE=$(awk 'BEGIN{for(i=0;i<300;i++) printf "&"}')
printf 'needs-decision [key=dense]: %s TAILMARK\n' "$DENSE" > "$ENTITY_HOME/state/dense-h.status"
OUT_DENSE="$TMP_ROOT/board-dense.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$ENTITY_HOME" "$BOARD" --out "$OUT_DENSE" >/dev/null \
  || fail "the board did not render an entity-dense summary"
assert_grep "TAILMARK" "$OUT_DENSE" \
  "an entity-dense summary was cut short of its own character budget"
assert_no_grep "&am…" "$OUT_DENSE" "a truncation landed inside an HTML entity"
assert_no_grep "&amp…" "$OUT_DENSE" "a truncation landed inside an HTML entity"
pass "snapshot prose is bounded before escaping, so no cut splits an entity"

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
# The option value is an identifier that has to survive into the answer payload
# unchanged, so a value the payload could not carry back is refused at parse time
# rather than mis-rendered.
refuses "an option value that is not a slug" '[decision]
key: a
title: t
option: a|b | Label'
refuses "an option value carrying a space" '[decision]
key: a
title: t
option: two words | Label'
pass "malformed authored input is refused rather than half-rendered"

# A label may itself contain the separator; only the first one splits the line.
printf '[decision]\nkey: a\ntitle: t\noption: x | left | right\n' > "$TMP_ROOT/pipe.txt"
render "$TMP_ROOT/pipe.html" --cards "$TMP_ROOT/pipe.txt" >/dev/null \
  || fail "an option label containing the separator was rejected"
assert_grep 'value="x"' "$TMP_ROOT/pipe.html" "the option value did not survive a label containing the separator"
assert_grep ">left | right" "$TMP_ROOT/pipe.html" "the option label lost everything after its own separator"
pass "an option splits on its first separator and the label keeps the rest"

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
# The durable decision an answer resolves travels with the click, so the answer
# maps back to the identity that was validated rather than to a card key alone.
assert_grep 'data-binds="listen-b:blind-src"' "$OUT2" \
  "an answer carries no link to the durable decision it answers"
assert_grep "getAttribute('data-binds')" "$OUT2" \
  "the answer payload drops the durable decision identity"
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

# --- the empty state cannot outrank a card that is there ---------------------
#
# On an otherwise empty fleet the only thing in the column is one authored chores
# card, so this is exactly the case where a separately kept counter would let the
# column claim nothing is waiting while a card sits under it. Each chore counts
# as its own act, so the pill reports items and not cards.
CHORES_ONLY="$TMP_ROOT/chores-only.txt"
cat > "$CHORES_ONLY" <<'EOF'
[chores]
title: Only you can do these
item: **Tier-2 listening session.** 22 clips staged.
item: Sign the release note.
item: Re-pair the bench radio.
EOF
OUT8="$TMP_ROOT/chores-only.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$EMPTY" "$BOARD" --out "$OUT8" --cards "$CHORES_ONLY" >/dev/null \
  || fail "the board did not render a chores-only column"
assert_grep "Only you can do these" "$OUT8" "the only card in the column is missing"
assert_no_grep "Nothing is waiting on you." "$OUT8" \
  "the column claimed nothing is waiting while a card was rendered under it"
assert_grep ">3 items<" "$OUT8" "the count does not report each chore as its own act"
pass "the empty state cannot render while a card exists, and chores count per item"

# --- delegated homes reach the same column -----------------------------------
#
# A decision held in a delegated home is a pending decision like any other. The
# board already rolls up delegated landings, so reading landings but not pending
# decisions would leave exactly the silence the unelaborated-key rule exists to
# prevent. This home is seeded for real and read through one live snapshot.
MATE="$TMP_ROOT/mate-home"
mkdir -p "$MATE/state" "$MATE/data" "$MATE/config" "$MATE/projects" "$MATE/bin"
printf 'sample-mate\n' > "$MATE/.fm-secondmate-home"
printf '# Agents\n' > "$MATE/AGENTS.md"
cat > "$MATE/data/backlog.md" <<'EOF'
## Queued
- [ ] mesh-note - Ship the mesh accuracy note (repo: tung) (kind: captain) (hold: waiting on the captain's word) (hold-kind: captain)

## Done
- [x] mate-land - Delegated landing https://github.com/notno/tung/pull/99 (repo: tung) (kind: ship) (merged 2026-07-20)
EOF
DELEGATING="$TMP_ROOT/delegating-home"
mkdir -p "$DELEGATING/state" "$DELEGATING/data" "$DELEGATING/config" "$DELEGATING/projects"
cat > "$DELEGATING/data/backlog.md" <<'EOF'
## Done
- [x] corners-f - Tile mating corners https://github.com/notno/tung/pull/13 (repo: tung) (kind: ship) (merged 2026-07-10)
EOF
printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
  "$MATE" > "$DELEGATING/data/secondmates.md"
fm_write_secondmate_meta "$DELEGATING/state/sample-mate.meta" "$MATE" \
  "firstmate:fm-sample-mate" sample

SNAP3="$TMP_ROOT/snap-delegated.json"
PATH="$FAKEBIN:$PATH" FM_HOME="$DELEGATING" "$SNAPSHOT_CMD" --json > "$SNAP3" \
  || fail "the delegated-home snapshot could not be taken"
printf '%s' "$(jq -r '.secondmate_current.records[0].provenance.selected' "$SNAP3")" \
  | grep -qx "structured-home" \
  || fail "the fixture delegated home was not read as a structured home"

OUT9="$TMP_ROOT/board-delegated.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$DELEGATING" "$BOARD" --snapshot "$SNAP3" --out "$OUT9" >/dev/null \
  || fail "the board did not render a fleet with a delegated home"
assert_grep "sample-mate/mesh-note:mesh-note" "$OUT9" \
  "a decision open in a delegated home never reached the board"
assert_grep "held in delegated home sample-mate" "$OUT9" \
  "a delegated decision is not marked with the home it came from"
assert_grep "Not written up yet" "$OUT9" \
  "a delegated decision with no authored card is not marked unelaborated"
assert_no_grep "Nothing is waiting on you." "$OUT9" \
  "a delegated decision was rendered under a claim that nothing is waiting"
pass "a decision held in a delegated home reaches Waiting on you, marked with its home"

# The same identity is bindable, so a delegated decision can be elaborated by an
# authored card exactly as a main-home one is.
DELEGATED_CARD="$TMP_ROOT/delegated-card.txt"
cat > "$DELEGATED_CARD" <<'EOF'
[decision]
key: mesh
binds: sample-mate/mesh-note:mesh-note
title: The mesh accuracy note
option: ship | **Ship it** as written.
option: hold | **Hold** for the next bench pass.
EOF
OUT10="$TMP_ROOT/board-delegated-card.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$DELEGATING" "$BOARD" --snapshot "$SNAP3" --out "$OUT10" \
  --cards "$DELEGATED_CARD" >/dev/null \
  || fail "an authored card binding a delegated decision was rejected"
assert_grep 'data-binds="sample-mate/mesh-note:mesh-note"' "$OUT10" \
  "the delegated decision identity did not travel with the answer"
assert_no_grep "Not written up yet" "$OUT10" \
  "an elaborated delegated decision is still marked unelaborated"
pass "an authored card binds a delegated decision by its durable identity"

# Landed merges two differently ordered sources - the main backlog in file order,
# a delegated home already newest-first - so the bound has to cut a sorted union
# or a recent delegated landing falls past it.
OUT11="$TMP_ROOT/board-delegated-landed.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$DELEGATING" "$BOARD" --snapshot "$SNAP3" --out "$OUT11" \
  --landed 1 >/dev/null || fail "the board did not render a bounded merged Landed column"
assert_grep "Delegated landing" "$OUT11" \
  "the newest landing fell past the bound because the merged sources were not sorted"
assert_no_grep "Tile mating corners" "$OUT11" \
  "an older landing displaced the newest one in a bounded Landed column"
assert_grep "older landings not shown" "$OUT11" \
  "a bounded merged Landed column hides what it dropped"
pass "merged landings are ordered newest-first before the bound is applied"

# A delegated home the snapshot could not read whole must not render as a home
# holding nothing.
UNREADABLE="$TMP_ROOT/unreadable-home"
mkdir -p "$UNREADABLE/state" "$UNREADABLE/data" "$UNREADABLE/config" "$UNREADABLE/projects"
printf '## Queued\n' > "$UNREADABLE/data/backlog.md"
printf -- '- broken-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
  "$TMP_ROOT/no-such-home" > "$UNREADABLE/data/secondmates.md"
fm_write_secondmate_meta "$UNREADABLE/state/broken-mate.meta" "$TMP_ROOT/no-such-home" \
  "firstmate:fm-broken-mate" sample
OUT12="$TMP_ROOT/board-unreadable.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$UNREADABLE" "$BOARD" --out "$OUT12" >/dev/null \
  || fail "the board did not render a fleet with an unreadable delegated home"
assert_grep "could not read whole" "$OUT12" "an unreadable delegated home was passed over in silence"
assert_grep "broken-mate" "$OUT12" "the unreadable delegated home is not named"
assert_no_grep "Nothing is waiting on you." "$OUT12" \
  "an unreadable delegated home rendered as a fleet with nothing waiting"
pass "an unreadable delegated home is named rather than reported as holding nothing"

# The delegated homes are on the same leak boundary as the operator's own.
assert_no_grep "$MATE" "$OUT9" "a delegated home path reached the artifact"
assert_no_grep "$TMP_ROOT" "$OUT9" "an absolute fixture path reached the artifact"
assert_no_grep "$TMP_ROOT" "$OUT12" "an absolute fixture path reached the artifact"
pass "delegated home paths do not reach the artifact"

# --- an entry of an unexpected shape is skipped, not fatal -------------------
#
# `--snapshot <file>` accepts any saved snapshot, so a record from an older
# schema can carry a decision list that is absent, null, or not a list at all.
# Such an entry must drop out of the column the way an unreadable home does,
# rather than killing the render. Decisions are read at two independent sites,
# the main home's tasks and each delegated home's record, so both are covered.
shape_case() {  # <label> <source-snapshot> <home> <survivor> <jq-program>
  local label=$1 source=$2 home=$3 survivor=$4 program=$5 snap out
  snap="$TMP_ROOT/snap-shape.json"
  out="$TMP_ROOT/board-shape.html"
  rm -f "$out"
  jq "$program" "$source" > "$snap" || fail "$label: the shape fixture could not be built"
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$BOARD" --snapshot "$snap" --out "$out" >/dev/null \
    || fail "$label: the board aborted instead of skipping the entry"
  assert_present "$out" "$label: no artifact was written"
  assert_grep "$survivor" "$out" "$label: the rest of the board was lost with the entry"
}
shape_case "a delegated home with a null decision list" \
  "$SNAP3" "$DELEGATING" "Tile mating corners" \
  '.secondmate_current.records[0].decisions_open = null'
shape_case "a delegated home with no decision list at all" \
  "$SNAP3" "$DELEGATING" "Tile mating corners" \
  'del(.secondmate_current.records[0].decisions_open)'
shape_case "a delegated home whose decision list is not a list" \
  "$SNAP3" "$DELEGATING" "Tile mating corners" \
  '.secondmate_current.records[0].decisions_open = "unavailable"'
shape_case "a delegated home with a null omission list" \
  "$SNAP3" "$DELEGATING" "Tile mating corners" \
  '.secondmate_current.records[0].omitted = null'

# The main home has its own guard on the same field, so it needs its own cases
# against a snapshot whose tasks are actually main-home ones. $SNAP carries
# ship-a and listen-b, both kind: ship, which the delegated filter keeps.
jq -e '[.tasks[] | select(.kind != "secondmate")] | length > 0' "$SNAP" >/dev/null \
  || fail "the main-home shape fixture carries no main-home task to guard"
shape_case "a main-home task with a null decision list" \
  "$SNAP" "$HOME_DIR" "Ship the mating corners" \
  '.tasks |= map(.hints.open_decisions = null)'
shape_case "a main-home task with no decision list at all" \
  "$SNAP" "$HOME_DIR" "Ship the mating corners" \
  '.tasks |= map(del(.hints.open_decisions))'
shape_case "a main-home task whose decision list is not a list" \
  "$SNAP" "$HOME_DIR" "Ship the mating corners" \
  '.tasks |= map(.hints.open_decisions = "unavailable")'
shape_case "a main-home decision list holding something that is not a decision" \
  "$SNAP" "$HOME_DIR" "Ship the mating corners" \
  '.tasks |= map(if .kind != "secondmate" then .hints.open_decisions = ["not-an-object"] else . end)'
pass "an entry of an unexpected shape is skipped rather than aborting the render"

# --- a delegated decision carries its full text ------------------------------
#
# A status-sourced decision carries its text in `summary` and nothing in
# `reason`. Clipping that text into the heading and dropping the rest would be
# the same silence in smaller form, so the body has to carry it.
LONG_SUMMARY="Prose above the blind clips needs a decision about which of the two sitting surfaces the answered set collapses into before the tier-2 session can be staged"
DELEGATED_LONG="$TMP_ROOT/snap-delegated-long.json"
jq --arg s "$LONG_SUMMARY" '
  .secondmate_current.records[0].decisions_open =
    [{id:"listen-b",key:"blind-src",verb:"needs-decision",summary:$s,reason:null,source:"status"}]
' "$SNAP3" > "$DELEGATED_LONG" || fail "the long-summary fixture could not be built"
OUT14="$TMP_ROOT/board-delegated-long.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$DELEGATING" "$BOARD" --snapshot "$DELEGATED_LONG" --out "$OUT14" >/dev/null \
  || fail "the board did not render a delegated status decision"
assert_grep "before the tier-2 session can be staged" "$OUT14" \
  "a delegated decision's text was clipped into its heading and the rest dropped"
assert_grep "sample-mate/listen-b:blind-src" "$OUT14" \
  "the delegated status decision carries no durable identity"
pass "a delegated decision's full text reaches the card body, not just its heading"

# Which slot a delegated entry's text belongs in follows from the kind of entry
# it is, not from comparing rendered strings: the snapshot puts the item title in
# `summary` for a captain hold and the decision text in `summary` for a status
# decision. Neither card may say the same thing twice, and a hold's reason has to
# stay on the card.
occurrences() {  # <needle> <file>
  grep -o -- "$1" "$2" | wc -l | tr -d ' '
}
HOLD_TITLE="Ship the mesh accuracy note"
[ "$(occurrences "$HOLD_TITLE" "$OUT9")" = 1 ] \
  || fail "a delegated captain hold rendered its title $(occurrences "$HOLD_TITLE" "$OUT9") times"
assert_grep "waiting on the captain" "$OUT9" \
  "a delegated captain hold dropped the reason it is being held for"
pass "a delegated captain hold shows its title once and its hold reason beside it"

# The same property for the other kind, whose text is long enough that a heading
# clip would make two near-copies rather than two identical ones.
[ "$(occurrences "which of the two sitting surfaces" "$OUT14")" = 1 ] \
  || fail "a delegated status decision rendered its text more than once"
pass "a delegated status decision shows its text once, in full"

# --- the count reports entries, not cards ------------------------------------
#
# Each pull request awaiting a merge and each held item is its own act, the same
# as each chore, so a card listing several of them counts as several.
MANY="$TMP_ROOT/many-home"
mkdir -p "$MANY/state" "$MANY/data" "$MANY/config" "$MANY/projects/tung"
cat > "$MANY/data/backlog.md" <<'EOF'
## In flight
- [ ] pr-one - First merge (repo: tung) (kind: ship) (since 2026-07-11)
- [ ] pr-two - Second merge (repo: tung) (kind: ship) (since 2026-07-11)

## Queued
- [ ] held-one - First held item (repo: tung) (kind: captain) (hold: waiting on the captain's word) (hold-kind: captain)
- [ ] held-two - Second held item (repo: tung) (kind: captain) (hold: waiting on the captain's word) (hold-kind: captain)
- [ ] held-three - Third held item (repo: tung) (kind: captain) (hold: waiting on the captain's word) (hold-kind: captain)
EOF
for id in pr-one pr-two; do
  fm_write_meta "$MANY/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$MANY/projects/tung" \
    "project=$MANY/projects/tung" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/notno/tung/pull/7"
  record_claude_state "$MANY/state" "$id" busy
done
MANY_CHORES="$TMP_ROOT/many-chores.txt"
cat > "$MANY_CHORES" <<'EOF'
[chores]
item: Sign the release note.
item: Re-pair the bench radio.
EOF
OUT15="$TMP_ROOT/board-many.html"
PATH="$FAKEBIN:$PATH" FM_HOME="$MANY" "$BOARD" --out "$OUT15" --cards "$MANY_CHORES" >/dev/null \
  || fail "the board did not render a fleet with several entries per card"
# Two pull requests, three held items and two chores are seven acts on three cards.
assert_grep ">7 items<" "$OUT15" \
  "the count reported cards rather than the entries waiting inside them"
assert_no_grep "Nothing is waiting on you." "$OUT15" \
  "the column claimed nothing is waiting while three cards were rendered under it"
pass "the count reports every waiting entry, not every card"

# --- the decision domain never fails into a false claim ----------------------
#
# The bind check is only as honest as the read behind it. If that read fails the
# refusal must name the read, because reporting "there are no open decisions"
# for a decision that is genuinely open is the one thing this board cannot say.
BROKEN_DOMAIN="$TMP_ROOT/snap-broken-domain.json"
jq '.tasks += ["not-a-task"]' "$SNAP" > "$BROKEN_DOMAIN" \
  || fail "the broken-domain fixture could not be built"
jq -e '[.tasks[] | select(type == "object") | (.hints.open_decisions // [])[]] | length > 0' \
  "$BROKEN_DOMAIN" >/dev/null \
  || fail "the broken-domain fixture carries no genuinely open decision"
printf '[decision]\nkey: a\ntitle: t\noption: x | X\nbinds: listen-b:blind-src\n' \
  > "$TMP_ROOT/genuine.txt"
DOMAIN_OUT="$TMP_ROOT/board-broken-domain.html"
DOMAIN_ERR="$TMP_ROOT/broken-domain.err"
rm -f "$DOMAIN_OUT"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$BOARD" --snapshot "$BROKEN_DOMAIN" \
  --out "$DOMAIN_OUT" --cards "$TMP_ROOT/genuine.txt" >/dev/null 2>"$DOMAIN_ERR"
DOMAIN_CODE=$?
[ "$DOMAIN_CODE" -ne 0 ] || fail "an unreadable decision domain was not a failure at all"
assert_absent "$DOMAIN_OUT" "an artifact was written from an unreadable decision domain"
grep -q "could not read the open decisions" "$DOMAIN_ERR" \
  || fail "the failure does not name what could not be read: $(cat "$DOMAIN_ERR")"
grep -q "there are no open decisions right now" "$DOMAIN_ERR" \
  && fail "an unreadable decision domain was reported as a fleet with no open decisions"
grep -q "binds names no open decision" "$DOMAIN_ERR" \
  && fail "an unreadable decision domain was blamed on the authored card instead"
pass "an unreadable decision domain fails loudly instead of claiming nothing is pending"

# --- counts are normalised where the flag is still named ---------------------

OUT13="$TMP_ROOT/board-zeros.html"
render "$OUT13" --landed 08 --stale-mins 030 >/dev/null \
  || fail "a zero-padded count was not accepted at the boundary that names the flag"
pass "zero-padded counts are normalised rather than failing inside the renderer"

BAD_ERR="$TMP_ROOT/badcount.err"
render "$TMP_ROOT/nope.html" --stale-mins 0 >/dev/null 2>"$BAD_ERR"
expect_code 2 $? "a zero --stale-mins"
grep -q -- "--stale-mins" "$BAD_ERR" || fail "the refusal did not name the flag it was about"
pass "a bad count is refused where the flag is still named"

echo "all fm-board tests passed"
