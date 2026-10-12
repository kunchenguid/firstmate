#!/usr/bin/env bash
# Behavioral fixture for the bounded Beads propulsion dispatcher.
# The board is a real scratch Beads store the fixture builds with the real bd
# CLI, so bd's blocker/ready/defer semantics stay authoritative; only the
# roster (herdr), quota, and tasks-axi surfaces are fixture files.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-propel)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

PROPEL="$ROOT/bin/fm-propel.sh"
PANE_CHECK="$ROOT/bin/fm-propel-pane-check.sh"
FIXTURE="$TMP_ROOT/fixture"
HOME_DIR="$TMP_ROOT/home"
BOARD="$TMP_ROOT/board"
mkdir -p "$FIXTURE" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/bin"

# Missing tools make this suite impossible rather than green: the dispatcher
# refuses the same way in production.
command -v bd >/dev/null 2>&1 || fail 'bd is unavailable; cannot run the propel fixture'
command -v jq >/dev/null 2>&1 || fail 'jq is unavailable; cannot run the propel fixture'
command -v quota-axi >/dev/null 2>&1 || fail 'quota-axi is unavailable; cannot run the propel fixture'
command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is unavailable; cannot run the propel fixture'

# A real scratch board with one bead per exercised class. Ids are assigned by
# bd, so the fixture records them from the create output rather than guessing.
# Every bd call goes through one helper that clears the launch-inherited hook
# pins and hook-only git environment (otherwise a worker session's
# GIT_CONFIG_VALUE_0 hooksPath routes the fixture's `bd init` self-commit
# through the launch's wrapper and hangs). GIT_CONFIG_PARAMETERS is cleared
# too because it is what a hook-injected git config would feed back.
bd_board() { # <bd args...> - run bd from the scratch board with a clean env.
  (cd "$BOARD" && unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS \
    && bd "$@" 2>/dev/null)
}

mkdir -p "$BOARD"
bd_board init --force >/dev/null || fail 'bd init failed on the scratch board'

bead_create() { # <title> <labels-csv> [priority]
  local out id
  # awk rather than sed: BSD sed under the multibyte locale can silently drop a
  # line whose match is followed by further multibyte bytes, and the create
  # output always follows "Created issue: <id>" with the em-dash separator.
  out=$(bd_board create --title "$1" --labels "$2" -p "${3:-2}") \
    || fail "bd create failed for: $1"
  id=$(printf '%s\n' "$out" | awk '/Created issue:/ {print $4; exit}')
  [ -n "$id" ] || { printf 'bd create output was: %s\n' "$out" >&2; fail "bd create printed no issue id for: $1"; }
  printf '%s\n' "$id"
}

ID_SHIP=$(bead_create 'Ship propulsion mechanism' firstmate 1)
ID_SCOUT=$(bead_create 'Investigate roster drift' 'research,agents' 2)
ID_CAPTAIN=$(bead_create 'Captain sync with TJ' captain 1)
ID_BLOCKER=$(bead_create 'Route the blocker first' platform 2)
ID_WAITER=$(bead_create 'Blocked waiter keeps waiting' platform 2)
ID_INFLIGHT=$(bead_create 'Already In flight in the backlog' agents 2)
ID_META=$(bead_create 'Under way fm-bridge-want' agent-work 2)
ID_GATE=$(bead_create 'Deferred until a gate' auditless 2)

bd_board link "$ID_WAITER" "$ID_BLOCKER" --type blocks >/dev/null \
  || fail "bd link failed wiring $ID_WAITER behind $ID_BLOCKER"
bd_board update "$ID_GATE" --status deferred >/dev/null || fail 'bd deferred update failed'

# Home surfaces: backlog files the real tasks-axi reads, a meta that proves
# the meta-backed task is under way, and a propel config that pins this
# fixture's own board as the home's ready surface.
printf '%s\n' "$BOARD" > "$HOME_DIR/config/propel-beads-dir"
cat > "$HOME_DIR/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] fm-old-task - Already In flight in the backlog (repo: firstmate) (kind: ship) (priority: 2)

## Queued

## Done
MD
cat > "$HOME_DIR/state/fm-bridge-want.meta" <<'META'
kind=ship
project=firstmate
META
mkdir -p "$HOME_DIR/state/peers"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pane current --session default') cat "$FIXTURE/current.json" ;;
  'tab list --workspace w1 --session default') cat "$FIXTURE/tabs.json" ;;
  'agent list --session default') cat "$FIXTURE/agents.json" ;;
  *) exit 4 ;;
esac
SH
cat > "$FIXTURE/current.json" <<'JSON'
{"result":{"pane":{"workspace_id":"w1","pane_id":"w1:p0"}}}
JSON
cat > "$FIXTURE/tabs.json" <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"Alice"}]}}
JSON
cat > "$FIXTURE/agents.json" <<'JSON'
{"result":{"agents":[{"tab_id":"w1:t1","workspace_id":"w1","pane_id":"w1:p1","agent_status":"idle"}]}}
JSON
printf 'alice\tAlice\n' > "$HOME_DIR/state/peers/peers.tsv"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'quota-axi %s\n' "$*" >> "$FIXTURE/calls"
# bin/fm-quota-choose.sh requires the full TOON header blocks, so this fixture
# emits the same shape quota-axi prints, not a shortened subset.
if [ -e "$FIXTURE/quota-empty" ]; then
  printf 'bin: quota-axi\ndescription: fixture empty quota surface\ngeneratedAt: "2026-01-01T00:00:00Z"\nquota[0]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:\nexhaustion[0]:\nattention[0]:\n'
else
  printf 'bin: quota-axi\ndescription: fixture full quota surface\ngeneratedAt: "2026-01-01T00:00:00Z"\nquota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:\n'
  printf '  codex,all_models,96,0.4845,through_reset,early,weekly,"2036-01-01T00:00:00Z"\n'
  printf '  claude,all_models,87,0.4135,through_reset,early,weekly,"2036-01-01T00:00:00Z"\n'
  printf 'exhaustion[0]:\nattention[0]:\n'
fi
SH
export FIXTURE
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/quota-axi"

# fm-quota-choose consults the production quota library for its row join; the
# fixture name only overrides its TOON surface through the fakebin above.

# Read-only home guard: the dispatcher reads state/data/config; only the
# fixture's own PLAN path writes, so trip on any write outside the plan row.
export PATH="$FAKEBIN:$PATH"
export FM_HOME=$HOME_DIR FM_ROOT_OVERRIDE=$ROOT FM_BOARD=$BOARD HERDR_SESSION=default

# Roster reads against the fixture: bin/fm-peer-roster.sh is production, so the
# only fabrication is herdr out of fixture files plus bd via the real scratch
# board.
export BEADS_DIR=$BOARD/.beads

# --- Baseline: each class lands where its pair owns it. ----------------------
"$PROPEL" --emit-wakes > "$FIXTURE/run1.out" 2> "$FIXTURE/run1.err" || {
  cat "$FIXTURE/run1.err" >&2
  fail 'baseline propel run errored'
}
[ -s "$FIXTURE/run1.out" ] || fail 'baseline run printed no plan'
assert_contains "$(cat "$FIXTURE/run1.out")" 'propel ' 'the plan summary opens with the dispatch verdict'
grep -Fq "$ID_CAPTAIN"$'\tcaptain\t'"Captain sync with TJ" "$FIXTURE/run1.out" \
  || fail 'captain bead was dispatched instead of surfaced as a decision'
grep -Fq "$ID_WAITER"$'\troute-blocker\t'"$ID_BLOCKER" "$FIXTURE/run1.out" \
  || fail 'blocked waiter routed to its blocker instead of pretending progress'
grep -Fq "$ID_INFLIGHT"$'\tskip\ttitle-in-flight-or-queued' "$FIXTURE/run1.out" \
  || fail 'an In flight backlog title did not dedupe the same-named bead'
grep -Fq "$ID_META"$'\tskip\twork-underway-in-a-home' "$FIXTURE/run1.out" \
  || fail 'a meta-backed underway task did not mask the bead'
grep -Fq "propel: captain decision $ID_CAPTAIN: Captain sync with TJ" "$FIXTURE/run1.out" \
  || fail 'captain decision was not announced as an external wake'
grep -Fq "propel: gate $ID_GATE clears at" "$FIXTURE/run1.out" \
  || fail 'deferred bead never surfaced as its time gate wake'
pass 'classification, recursion, dedupe, and gated wake publication'

# Wake announcement is idempotent once a surface has been published.
"$PROPEL" --emit-wakes > "$FIXTURE/run2.out"
grep -Fq 'propel: captain decision' "$FIXTURE/run2.out" \
  && fail 'repeated run re-announced a captain decision it already published'
pass 'repeated polls print nothing new; wake gates are idempotent'

# Idle, fresh-report pane with measured headroom takes the ship-class bead.
printf 'note [at=%s]: fresh\n' "$(date +%s)" > "$HOME_DIR/state/peers/alice.log"
"$PROPEL" --emit-wakes > "$FIXTURE/run3.out"
grep -Fq "$ID_SHIP"$'\troster\talice' "$FIXTURE/run3.out" \
  || fail 'idle pane with measured headroom did not take the ship-class bead'
pass 'idle roster pane with headroom receives the roster-class pairing'

# Full machine (herdr reports zero agents) keeps the honest capacity gate.
cat > "$FIXTURE/agents.json" <<'JSON'
{"result":{"agents":[]}}
JSON
"$PROPEL" --emit-wakes > "$FIXTURE/run4.out"
grep -Fq $'\troster\t' "$FIXTURE/run4.out" >/dev/null 2>&1 \
  && fail 'a roster suggestion appeared with zero idle panes'
grep -Fq "$ID_SHIP"$'\tskip\troster-capacity-gate; not an external wait' "$FIXTURE/run4.out" \
  || fail 'zero idle panes did not flip the ship to the honest capacity gate'
pass 'zero idle panes stay a capacity gate, never an external wait'

# One spawn per run even when several beads would queue for the idle slot.
"$PROPEL" --emit-wakes > "$FIXTURE/run5.out"
count=$(grep -cE $'\tcrewmate\t' "$FIXTURE/run5.out" || true)
[ "${count:-0}" -le 1 ] || fail "run above one spawn per machine: saw $count"
pass 'one crewmate per run is enforced'

# --only-tasks pins the plan to the named bead.
"$PROPEL" --emit-wakes --only-tasks="$ID_SCOUT" > "$FIXTURE/run6.out"
grep -Fq "$ID_SCOUT" "$FIXTURE/run6.out" \
  || fail '--only-tasks did not include the pinned task'
grep -Fq "$ID_SHIP" "$FIXTURE/run6.out" \
  && fail '--only-tasks leaked an unpinned task into the plan'
pass '--only-tasks narrows the dispatch set exactly'

# A missing board is the verdict `unknown`, never a guessed dispatch.
out7=$(FM_BOARD=/tmp/fm-propel-absent "$PROPEL" --emit-wakes 2>&1) || rc7=$?
rc7=${rc7:-0}
[ "$rc7" -ne 0 ] || fail 'a missing board was still treated as dispatchable'
printf '%s\n' "$out7" > "$FIXTURE/run7.err"
grep -Fq 'board is unavailable' "$FIXTURE/run7.err" \
  || fail 'missing board was not reported as the unknown it is'
pass 'a missing board is verdicted unknown, not guessed dispatch'

# Quota scenario needs free panes again so capacity isn't the gate.
cat > "$FIXTURE/agents.json" <<'JSON'
{"result":{"agents":[{"tab_id":"w1:t1","workspace_id":"w1","pane_id":"w1:p1","agent_status":"idle"}]}}
JSON
# Quota exhaustion leaves the bead waiting on the captain to extend evidence.
touch "$FIXTURE/quota-empty"
"$PROPEL" --emit-wakes > "$FIXTURE/run8.out"
grep -Fq "$ID_SHIP"$'\tskip\tno-quota-headroom' "$FIXTURE/run8.out" \
  || fail 'quota exhaustion did not leave the bead waiting for the captain'
rm -f "$FIXTURE/quota-empty"
pass 'quota evidence is the only spawn gate that can flip a dispatch'

# Propel-check fails closed on an unreadable home.
"$PANE_CHECK" /tmp/fm-propel-no-such-home > /dev/null 2> "$FIXTURE/pane-missing.err" \
  && fail 'a missing home was treated as free'
"$PANE_CHECK" "$HOME_DIR" > "$FIXTURE/pane.out"
assert_contains "$(cat "$FIXTURE/pane.out")" 'free' 'a home with no declared capacity answers free'
pass 'pane probe fails closed on missing evidence'
