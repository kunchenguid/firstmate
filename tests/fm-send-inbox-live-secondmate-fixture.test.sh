#!/usr/bin/env bash
# Deterministic checks of the live doorbell guard's dedicated secondmate
# fixture (tests/fixtures.sh: fm_live_sm_fixture_check / _prepare / _cleanup).
# No live Codex and no tokens: this is NOT live secondmate proof. It pins the
# untested report when no fixture is supplied, the preflight refusals, the
# documented state/ cleanup list and its refusal of anything else, that
# repeated prepare/spawn/simulated-run/cleanup cycles leave a valid fixture
# reusable and clean, the read-only readiness decision over a fake Codex
# rollout tree and composer (fm_test_codex_turn_state /
# fm_test_wait_codex_idle) with a fake send counter, and the executed
# secondmate command (fm_test_codex_secondmate_cmd).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-sm-fixture)

git_t() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

# A stand-in firstmate root, and consented standalone clones of it as fixtures.
SRC="$TMP_ROOT/src"
mkdir -p "$SRC/.codex" "$SRC/bin"
printf '# Firstmate\n' > "$SRC/AGENTS.md"
printf 'hooks\n' > "$SRC/.codex/hooks.json"
: > "$SRC/bin/keep"
cp "$ROOT/.gitignore" "$SRC/.gitignore"
git -C "$SRC" init -q -b main
git -C "$SRC" add -A
git_t -C "$SRC" commit -qm initial

new_fixture() {  # <name> -> echoes the clone's path
  local dir="$TMP_ROOT/$1"
  git clone -q "$SRC" "$dir"
  printf '%s\n' "$dir" > "$dir/.git/fm-live-secondmate-fixture"
  printf '%s\n' "$dir"
}

check_rc() {  # <expected-rc> <reason-substring> <label> <dir> [root]
  local want_rc=$1 want=$2 label=$3 dir=$4 root=${5:-$SRC} out rc
  out=$(fm_live_sm_fixture_check "$dir" "$root")
  rc=$?
  expect_code "$want_rc" "$rc" "$label"
  assert_contains "$out" "$want" "$label: report names its reason"
  pass "$label"
}

check_rc 2 'untested: no dedicated fixture supplied' 'unset fixture is untested, not a pass' ''

FIX=$(new_fixture good)
check_rc 1 'not an absolute path' 'relative path refused' good
ln -s "$FIX" "$TMP_ROOT/link"
check_rc 1 'is a symlink' 'symlink refused' "$TMP_ROOT/link"
git -C "$SRC" worktree add -q --detach "$TMP_ROOT/linked"
check_rc 1 'not a standalone clone' 'linked worktree refused' "$TMP_ROOT/linked"
NOS=$(new_fixture nosentinel)
rm "$NOS/.git/fm-live-secondmate-fixture"
check_rc 1 'no consent sentinel' 'missing sentinel refused' "$NOS"
WRONG=$(new_fixture wrongsentinel)
printf '%s\n' "$FIX" > "$WRONG/.git/fm-live-secondmate-fixture"
check_rc 1 'no consent sentinel' 'wrong sentinel refused' "$WRONG"
DIRTY=$(new_fixture dirty)
printf 'x\n' >> "$DIRTY/AGENTS.md"
check_rc 1 'work tree is not clean' 'dirty tree refused' "$DIRTY"
MARK=$(new_fixture marker)
printf 'codex-live\n' > "$MARK/.fm-secondmate-home"
check_rc 1 "stale fixture state; remove manually: $MARK/.fm-secondmate-home" 'pre-existing marker refused' "$MARK"
out=$(FM_HOME="$FIX" fm_live_sm_fixture_check "$FIX" "$SRC") && fail "fixture equal to FM_HOME accepted"
assert_contains "$out" 'equal to or inside' 'fixture equal to FM_HOME refused'
pass 'fixture equal to FM_HOME refused'
out=$(HOME="$FIX" fm_live_sm_fixture_check "$FIX" "$SRC") && fail "fixture equal to HOME accepted"
assert_contains "$out" 'equal to or inside' 'fixture equal to HOME refused'
pass 'fixture equal to HOME refused'
DRIFT=$(new_fixture drift)
git_t -C "$DRIFT" commit -q --allow-empty -m drift
check_rc 1 'HEAD differs' 'HEAD mismatch refused' "$DRIFT"
OTHER=$(new_fixture other-root)
printf 'other\n' > "$OTHER/.codex/hooks.json"
check_rc 1 'hooks.json is missing or differs' 'hooks.json mismatch refused' "$FIX" "$OTHER"

# The documented startup/hook residue a live secondmate leaves in state/.
simulate_run_state() {  # <fixture>
  local name
  mkdir -p "$1/state/terminal-outcomes"
  for name in $FM_LIVE_SM_STATE_FILES; do
    printf 'x\n' > "$1/state/$name"
  done
}

# An empty state/ is accepted by preflight; an absent one is covered below.
EMPTY=$(new_fixture emptystate)
mkdir "$EMPTY/state"
check_rc 0 "$EMPTY" 'empty state/ accepted' "$EMPTY"

# An unexpected state/ entry stops cleanup: nothing is removed and it is named.
EXTRA=$(new_fixture extra)
fm_live_sm_fixture_prepare "$EXTRA" codex-live || fail "extra: prepare failed"
simulate_run_state "$EXTRA"
printf 'x\n' > "$EXTRA/state/surprise"
out=$(fm_live_sm_fixture_cleanup) && fail "cleanup removed state with an unexpected entry"
assert_contains "$out" "$EXTRA/state/surprise" 'unexpected state entry named'
assert_present "$EXTRA/state/.lock" 'documented state file kept when cleanup refuses'
assert_present "$EXTRA/.fm-secondmate-home" 'marker kept when cleanup refuses'
pass 'unexpected state entry refused with nothing removed'
FM_LIVE_SM_FIXTURE=''
mkdir "$EXTRA/state/terminal-outcomes/x" 2>/dev/null || true
rm "$EXTRA/state/surprise"
fm_live_sm_fixture_prepare "$EXTRA" codex-live || fail "extra: prepare failed"
out=$(fm_live_sm_fixture_cleanup) && fail "cleanup accepted a non-empty terminal-outcomes/"
assert_contains "$out" "$EXTRA/state/terminal-outcomes" 'non-empty terminal-outcomes named'
pass 'non-empty terminal-outcomes refused'
FM_LIVE_SM_FIXTURE=''

# A valid fixture passes, twice, through the real fm-spawn secondmate path and
# the documented state/ residue of a run, with no manual repair in between.
for cycle in 1 2; do
  abs=$(fm_live_sm_fixture_check "$FIX" "$SRC") || fail "cycle $cycle: valid fixture refused: $abs"
  assert_equals "$FIX" "$abs" "cycle $cycle: check echoes the canonical fixture"
  fm_live_sm_fixture_prepare "$abs" codex-live || fail "cycle $cycle: prepare failed"
  launch=$(fm_test_capture_codex_launch "$TMP_ROOT/case-$cycle" "--secondmate=$abs")
  assert_contains "$launch" "FM_HOME='$abs'" "cycle $cycle: generated launch runs in the fixture home"
  assert_contains "$launch" '-c disable_paste_burst=true' "cycle $cycle: secondmate launch carries the paste-burst setting"
  assert_not_contains "$launch" '--disable hooks' "cycle $cycle: secondmate keeps hooks on"
  simulate_run_state "$abs"
  fm_live_sm_fixture_cleanup || fail "cycle $cycle: cleanup refused the documented state"
  assert_absent "$FIX/.fm-secondmate-home" "cycle $cycle: marker removed"
  assert_absent "$FIX/data" "cycle $cycle: created data/ removed"
  assert_absent "$FIX/state" "cycle $cycle: created state/ removed"
  assert_absent "$FIX/config" "cycle $cycle: spawn wrote no inherited config"
  assert_equals '' "$(git -C "$FIX" status --porcelain --ignored)" "cycle $cycle: fixture left clean"
  pass "cycle $cycle: valid fixture prepared, spawned into, and cleaned"
done

# Readiness decision over a fake Codex sessions tree and a fake composer
# (deterministic, no Codex). A fake send counts input; it must stay zero
# whenever readiness does not proceed.
SESS="$TMP_ROOT/sessions/2026/10/01"
mkdir -p "$SESS"
rollout() {  # <name> <cwd> <timestamp> <event...>
  local f="$SESS/rollout-$1.jsonl" ev
  shift
  printf '{"type":"session_meta","payload":{"cwd":"%s","timestamp":"%s"}}\n' "$1" "$2" > "$f"
  shift 2
  for ev in "$@"; do
    printf '{"type":"event_msg","payload":{"type":"%s"}}\n' "$ev" >> "$f"
  done
}
SINCE=2026-10-01T12:00:00
state() { fm_test_codex_turn_state "$TMP_ROOT/sessions" "$FIX" "$SINCE"; }
assert_equals none "$(state)" 'no session yet reads none'
rollout old "$FIX" 2026-10-01T11:59:59.900Z task_started
rollout elsewhere /tmp/other 2026-10-01T12:00:01.000Z task_started
assert_equals none "$(state)" 'sessions started before launch or at another cwd are ignored'
rollout live "$FIX" 2026-10-01T12:00:00.500Z
assert_equals none "$(state)" 'session with no turn reads none'
rollout live "$FIX" 2026-10-01T12:00:00.500Z task_started
assert_equals active "$(state)" 'started turn without task_complete reads active'
rollout live "$FIX" 2026-10-01T12:00:00.500Z task_started task_complete
assert_equals completed "$(state)" 'completed turn reads completed'
rollout live "$FIX" 2026-10-01T12:00:00.500Z task_started task_complete task_started
assert_equals active "$(state)" 'a follow-up turn reads active again'
printf '{"type":"event_msg","payload":\n' >> "$SESS/rollout-live.jsonl"
assert_equals invalid "$(state)" 'unparsable event in this session reads invalid'
printf 'not json\n' > "$SESS/rollout-live.jsonl"
assert_equals invalid "$(state)" 'unparsable session header reads invalid'
rm "$SESS/rollout-live.jsonl"
assert_equals invalid "$(fm_test_codex_turn_state "$SESS/rollout-old.jsonl" "$FIX" "$SINCE")" 'unreadable sessions dir reads invalid'
pass 'rollout turn state: none, active, completed, invalid from the session at this cwd after launch'

SENT=0
fake_send() { SENT=$((SENT + 1)); }
# ready <expected-rc> <expected-report> <label> <timeout> <probe...>
# Mirrors the guard: input is sent only when readiness returns 0.
ready() {
  local want_rc=$1 want=$2 label=$3 budget=$4 out rc
  shift 4
  SENT=0
  out=$(fm_test_wait_codex_idle "$budget" 2 "$@")
  rc=$?
  [ "$rc" -ne 0 ] || fake_send
  expect_code "$want_rc" "$rc" "$label"
  assert_equals "$want" "$out" "$label: report"
  assert_equals "$((1 - want_rc))" "$SENT" "$label: input sent only after verified idle"
  pass "$label"
}
probe_fixed() { printf '%s\n' "$1"; }
ready 0 'verified idle: no turn started' 'no turn, empty composer proceeds after the quiet window' 3 probe_fixed 'empty none'
ready 0 'verified idle: initial turn completed' 'completed turn, empty composer proceeds' 3 probe_fixed 'empty completed'
ready 1 'inconclusive: turn active' 'active turn never proceeds' 2 probe_fixed 'empty active'
ready 1 'inconclusive: composer not readable or not empty (unknown)' 'unknown composer never proceeds' 2 probe_fixed 'unknown none'
ready 1 'inconclusive: composer not readable or not empty (pending)' 'non-empty composer never proceeds' 2 probe_fixed 'pending completed'
ready 1 'inconclusive: turn evidence unreadable or invalid' 'invalid rollout never proceeds' 2 probe_fixed 'empty invalid'
TICK="$TMP_ROOT/tick"
probe_flap() {  # alternates idle and active, so it is never quiet for 2 polls
  if [ -s "$TICK" ]; then : > "$TICK"; printf 'empty active\n'; else printf 'x\n' > "$TICK"; printf 'empty none\n'; fi
}
: > "$TICK"
ready 1 'inconclusive: not quiet for 2 consecutive polls' 'never-quiet window never proceeds' 2 probe_flap
ready 1 'inconclusive: not quiet for 2 consecutive polls' 'window shorter than the quiet bound never proceeds' 0 probe_fixed 'empty none'

# The executed secondmate command: generated env prefix, codex, the daemon
# option and generated flags, hooks on, and no positional launch brief.
launch=$(fm_test_capture_codex_launch "$TMP_ROOT/case-cmd" --secondmate)
cmd=$(fm_test_codex_secondmate_cmd "$launch" '--no-daemon ')
assert_contains "$cmd" "FM_HOME='$TMP_ROOT/case-cmd/secondmate-home'" 'executed command keeps the generated env prefix'
assert_contains "$cmd" 'codex --no-daemon --dangerously-bypass-approvals-and-sandbox -c disable_paste_burst=true' 'executed command carries --no-daemon and the paste-burst setting'
assert_not_contains "$cmd" '--disable hooks' 'executed secondmate command keeps hooks on'
assert_not_contains "$cmd" 'launch-brief' 'executed secondmate command has no positional brief'
assert_not_contains "$cmd" 'charter.md' 'executed secondmate command delivers no charter'
pass 'executed secondmate command: env prefix, --no-daemon, generated flags, no positional brief'
