#!/usr/bin/env bash
# tests/fm-captain-bead-loop.test.sh - the captain-request loop: hold->bead,
# answer->close, and close->requester delivery, all through a fake bd on PATH.
# The real board is never touched: every run points config/beads-board at a
# scratch directory, and the no-config case proves no bd call happens at all.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-bead-loop)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

HOLD="$ROOT/bin/fm-captain-hold.sh"
ASK="$ROOT/bin/fm-captain-ask.sh"
CHECK="$ROOT/bin/fm-captain-beads-check.sh"

# --- fixture world ----------------------------------------------------------

make_home() {  # <name> -> home dir with backlog + fakebin (bd fixture added separately)
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# Recording fake bd: appends one line per call to the home's bd.log and serves
# the small surface the loop consumes - `create` answers a JSON object with a
# fresh id, `close` succeeds, and `list` copies the fixture-staged bd-list.json.
# The log file is the suite's authoritative record of exactly which bd calls
# happened, in which order, with which bytes.
make_fake_bd() {  # <home>
  local home=$1
  printf '0\n' > "$home/bd-counter"
  printf '[]\n' > "$home/bd-list.json"
  cat > "$home/fakebin/bd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/bd.log"
case "\$1" in
  create)
    n=\$(( \$(cat "$home/bd-counter") + 1 ))
    printf '%s\n' "\$n" > "$home/bd-counter"
    printf '{"id":"bd-fake-%s","status":"open"}\n' "\$n"
    ;;
  close)
    exit 0
    ;;
  list)
    [ -f "$home/bd-list.json" ] && cat "$home/bd-list.json" || printf '[]\n'
    ;;
  *)
    printf 'fake bd: unknown subcommand: %s\n' "\$1" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$home/fakebin/bd"
}

board_dir() {  # <home> -> writes config/beads-board pointing at a scratch board
  local home=$1
  mkdir -p "$home/board/.beads"
  printf '%s\n' "$home/board" > "$home/config/beads-board"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$HOLD" "$@"
}

run_ask() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ASK" "$@"
}

run_check() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$CHECK"
}

decision_file() {  # <dir> <text...> -> writes and echoes a decision file
  local dir=$1
  shift
  printf '%s\n' "$*" > "$dir/decision"
  printf '%s\n' "$dir/decision"
}

# --- 1. no-config home makes no bd calls -------------------------------------

home_a=$(make_home a)
make_fake_bd "$home_a"
# Deliberately NO config/beads-board; a scratch .beads at a plausible spot
# proves nothing sniffs for boards implicitly.
mkdir -p "$home_a/board/.beads"

run_captain "$home_a" hold t-no-config --title 'No-config hold' \
  --reason 'decide without a board' --repo sample >/dev/null \
  || fail 'hold failed on an unconfigured home'
df=$(decision_file "$TMP_ROOT" 'ship it without beads')
run_captain "$home_a" answer t-no-config --decision-file "$df" >/dev/null \
  || fail 'answer failed on an unconfigured home'
[ ! -f "$home_a/bd.log" ] || fail 'an unconfigured home called bd'
[ ! -e "$home_a/state/t-no-config.captain-bead" ] \
  || fail 'an unconfigured home recorded a captain bead'
pass 'no-config home: hold and answer make no bd calls and record nothing'

# --- 2. hold creates the captain bead ----------------------------------------

home_b=$(make_home b)
make_fake_bd "$home_b"
board_dir "$home_b"

run_captain "$home_b" hold t-fix-loop --title 'Fix the loop' \
  --reason 'merge or rewrite the backlog plumbing?' --repo sample >/dev/null \
  || fail 'hold failed on a configured home'
grep -q '^create Fix the loop -l captain -a captain -p 1 ' "$home_b/bd.log" \
  || fail 'hold did not create the captain bead'
grep -q 'fm-requester: t-fix-loop' "$home_b/bd.log" \
  || fail 'the bead body did not name its requester'
grep -q 'merge or rewrite the backlog plumbing?' "$home_b/bd.log" \
  || fail 'the bead body did not carry the hold reason'
bead_id=$(sed -n 's/^v1 //p' "$home_b/state/t-fix-loop.captain-bead")
[ "$bead_id" = bd-fake-1 ] \
  || fail "the bead id was not recorded next to the hold (got: $bead_id)"
pass 'hold creates one captain bead with reason and requester, and records its id'

# A repeat hold of the same task never mints a second bead.
run_captain "$home_b" hold t-fix-loop --title 'Fix the loop' \
  --reason 'merge or rewrite the backlog plumbing?' --repo sample >/dev/null \
  || fail 'idempotent re-hold failed'
[ "$(grep -c '^create ' "$home_b/bd.log")" = 1 ] \
  || fail 'a repeat hold minted a second bead'
pass 'idempotent re-hold keeps one bead'

# --- 3. resolving the hold closes the bead with the captain's answer ---------

df=$(decision_file "$TMP_ROOT" 'go with merge, no rewrite')
run_captain "$home_b" answer t-fix-loop --decision-file "$df" >/dev/null \
  || fail 'answer failed on a configured home'
grep -q '^close bd-fake-1 -r Captain answered: go with merge, no rewrite$' \
  "$home_b/bd.log" \
  || fail 'the answer did not close the bead with the captain answer'
[ ! -e "$home_b/state/t-fix-loop.captain-bead" ] \
  || fail 'the bead record survived its close'
pass 'resolving the hold closes the bead with the captain answer as reason'

# A release close carries the released wording too.
run_captain "$home_b" hold t-release-me --title 'Release lane' \
  --reason 'approve the release' --repo sample >/dev/null \
  || fail 'release lane hold failed'
df=$(decision_file "$TMP_ROOT" 'approved, land it')
run_captain "$home_b" answer t-release-me --release --decision-file "$df" >/dev/null \
  || fail 'release answer failed'
grep -q '^close bd-fake-2 -r Captain released: approved, land it$' \
  "$home_b/bd.log" \
  || fail 'the release did not close the bead with released wording'
pass 'release closes the bead with released wording'

# The keyed-answer intake every channel feeds (fm-send --resolve-key lands
# here) closes the bead through the same `answer` path: pipe the keyed line to
# `answers` and the same close bytes reach the fake board.
run_captain "$home_b" hold t-keyed --title 'Keyed answer lane' \
  --reason 'keyed or direct?' --repo sample >/dev/null \
  || fail 'keyed lane hold failed'
printf 't-keyed\ttake the keyed branch\tkeyed-test\n' \
  | run_captain "$home_b" answers --source keyed-test >/dev/null \
  || fail 'the keyed answer intake failed'
grep -q '^close bd-fake-3 -r Captain answered: Captain answered this call through keyed-test\. Task: t-keyed Answer: take the keyed branch Answer as shown to the captain: keyed-test$' \
  "$home_b/bd.log" \
  || fail 'the keyed lane closed the bead without the composite captain answer'
pass 'the keyed-answer intake (the fm-send --resolve-key lane) closes the bead'

# --- 4. firstmate's own asks -------------------------------------------------

home_c=$(make_home c)
make_fake_bd "$home_c"
board_dir "$home_c"

ask_out=$(run_ask "$home_c" 'Which shell lane owns the work?' --tldr 'pick tmux or herdr') \
  || fail 'fm-captain-ask create failed'
grep -q '^create Which shell lane owns the work? -l captain -a captain -p 1 ' \
  "$home_c/bd.log" || fail 'the ask did not create a captain bead'
grep -q 'fm-requester: firstmate' "$home_c/bd.log" \
  || fail 'the ask did not record requester firstmate'
grep -q 'pick tmux or herdr' "$home_c/bd.log" \
  || fail 'the ask dropped its tldr'
ask_id=${ask_out%% *}
[ -f "$home_c/state/captain-asks/$ask_id.rec" ] \
  || fail 'the ask record was not filed'
pass 'fm-captain-ask files the captain bead with requester firstmate'

run_ask "$home_c" --answer "$ask_id" 'herdr owns the lane' >/dev/null \
  || fail 'fm-captain-ask --answer failed'
grep -q '^close bd-fake-1 -r Captain answered: herdr owns the lane$' \
  "$home_c/bd.log" || fail 'the ask answer did not close the bead'
[ ! -e "$home_c/state/captain-asks/$ask_id.rec" ] \
  || fail 'the answered ask record survived its close'
pass 'fm-captain-ask --answer closes the ask bead with the answer'

# An ask in a home with no board config refuses instead of touching a board.
home_c2=$(make_home c2)
make_fake_bd "$home_c2"
if run_ask "$home_c2" 'no board ask' >/dev/null 2>&1; then
  fail 'an ask without config/beads-board succeeded'
fi
[ ! -f "$home_c2/bd.log" ] || fail 'the refused ask still called bd'
pass 'fm-captain-ask refuses and calls no bd without a board config'

# --- 5. close notifies each requester exactly once -----------------------------

home_d=$(make_home d)
make_fake_bd "$home_d"
board_dir "$home_d"

# A task-id requester known to this home (meta on disk proves the shape the
# check steers with bin/fm-send.sh; endpoint delivery is fm-send's own tested
# contract). A peers.sh recorder stands in for the home-private peer transport.
mkdir -p "$home_d/state/plat-decision-9.inbox" "$home_d/state/peers"
cat > "$home_d/state/plat-decision-9.meta" <<'META'
id=plat-decision-9
project=platform
backend=fixture
META
cat > "$home_d/state/peers/peers.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home_d/peers.log"
exit 0
SH
chmod +x "$home_d/state/peers/peers.sh"
: > "$home_d/peers.log"

# Stage what bd list returns: three closed captain beads - one peer requester
# via label, one firstmate requester via the fm-requester body line, one with
# NO requester (skipped).
cat > "$home_d/bd-list.json" <<'JSON'
[
  {"id": "bd-peer-1", "title": "Peer calls the captain", "status": "closed",
   "close_reason": "deploy on friday", "labels": ["captain", "requester:gitrank"],
   "description": "hand-filed peer bead"},
  {"id": "bd-fm-1", "title": "Firstmate's own ask", "status": "closed",
   "close_reason": "use the bridge", "labels": ["captain"],
   "description": "fm-requester: firstmate\nextra context"},
  {"id": "bd-none-1", "title": "Ordinary captain bead", "status": "closed",
   "close_reason": "answered offline", "labels": ["captain"],
   "description": "no marker anywhere"}
]
JSON

check_out=$(run_check "$home_d") || fail 'the close check errored'
printf '%s' "$check_out" | grep -q \
  'Captain bead closed: Firstmate'"'"'s own ask (bd-fm-1) - use the bridge' \
  || fail 'the firstmate-requested close produced no wake line'
grep -q 'send gitrank Captain bead closed: Peer calls the captain (bd-peer-1) - deploy on friday' \
  "$home_d/peers.log" \
  || fail 'the peer-requested close was not delivered through peers.sh'
[ "$(wc -l < "$home_d/peers.log" | tr -d ' ')" = 1 ] \
  || fail 'a requester-less bead was delivered somewhere'
[ -e "$home_d/state/.captain-bead-notified/bd-peer-1" ] \
  || fail 'the delivered close was not claimed'
[ -e "$home_d/state/.captain-bead-notified/bd-fm-1" ] \
  || fail 'the wake-line close was not claimed'
[ ! -e "$home_d/state/.captain-bead-notified/bd-none-1" ] \
  || fail 'the requester-less bead was claimed'
pass 'closed beads reach their requester; requester-less beads are skipped'

# Second full run: every delivered close stays silent (claimed before send),
# and no wake line repeats.
check_out2=$(run_check "$home_d") || fail 'the second close check errored'
[ -z "$check_out2" ] || fail 'a claimed close re-emitted its wake line'
[ "$(wc -l < "$home_d/peers.log" | tr -d ' ')" = 1 ] \
  || fail 'a claimed close was delivered twice'
pass 'each close notifies exactly once'

# The fm-send lane: a requester that IS a task in this home routes through
# bin/fm-send.sh rather than peers.sh. With no live endpoint the real
# fm-send.sh exits nonzero, and the check must surface one stderr line while
# keeping the claim (no duplicate storm, nothing through peers).
cat > "$home_d/bd-list.json" <<'JSON'
[
  {"id": "bd-task-1", "title": "Hold bead answered", "status": "closed",
   "close_reason": "take option two", "labels": ["captain"],
   "description": "fm-requester: plat-decision-9\nHold bead"}
]
JSON
check_err=$(run_check "$home_d" 2>&1 >/dev/null) || fail 'the task-lane check errored'
printf '%s' "$check_err" | grep -q \
  'could not deliver the close of bd-task-1 to plat-decision-9' \
  || fail 'a failed task-lane delivery surfaced nothing'
[ ! -e "$home_d/state/.captain-bead-notified/bd-task-1" ] \
  || fail 'a failed task-lane delivery kept its claim token and can never retry'
[ "$(wc -l < "$home_d/peers.log" | tr -d ' ')" = 1 ] \
  || fail 'a task-id requester was pushed through peers.sh'
pass 'a task-id requester routes through fm-send; a failed send surfaces and retries next poll'

# --- 6. the check is silent on an unconfigured home ----------------------------

home_e=$(make_home e)
make_fake_bd "$home_e"
check_out=$(run_check "$home_e") || fail 'the unconfigured check errored'
[ -z "$check_out" ] || fail 'the unconfigured check emitted a wake line'
[ ! -f "$home_e/bd.log" ] || fail 'the unconfigured check called bd'
[ ! -d "$home_e/state/.captain-bead-notified" ] \
  || fail 'the unconfigured check left claim state'
pass 'the close check is fully inert without a board config'

printf 'passes complete\n'
