#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's non-worktree launch refusals - both which
# ones are immediate and, just as importantly, which ones must stay slow.
#
# A ship/scout spawn only ever runs in an isolated git worktree of the project
# (bin/fm-spawn.sh's spawn_worktree_ok / validate_spawn_worktree). Refusing that
# launch correctly is what keeps project work out of the primary checkout, so a
# WRONG refusal is worse than a slow one. That splits the behavior in two, and
# this file pins both halves:
#
#   - Provable up front: the project argument fm-spawn was handed cannot yield a
#     worktree (it names no directory, or names one that is not inside a git
#     repository). Nothing that happens later changes that, so fm-spawn refuses
#     immediately, before creating any window, naming the path and the reason.
#   - NOT provable up front: the launched pane has not reached a worktree YET.
#     A live shell can cd at any moment, so an existing pane path that is not a
#     worktree is a fact about right now, never a proof about the future. Those
#     keep polling for the whole settle window, however stable they look.
#
# Test seam: drive the real bin/fm-spawn.sh against a fake tmux whose
# `#{pane_current_path}` answers are scripted per call, and assert only on what
# a caller observes - exit code, the refusal text on stderr, wall-clock, whether
# state/<id>.meta was published, and whether a window was ever created. No
# assertions on fm-spawn's internal variables, helper names, or call order.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-nonworktree-refusal)
fm_git_identity fmtest fmtest@example.invalid

# An immediate refusal must not cost a poll window. Measured cost of the whole
# fm-spawn process up to these checks is well under 100ms; the bound below is a
# deliberately generous multiple of that so a loaded CI runner cannot flake it,
# while still being two orders of magnitude below the 60s settle window it
# exists to distinguish from.
IMMEDIATE_MS=2000

# The stable window id the fake tmux hands back from new-window. Refusals that
# reclaim a window must address it by this id, never by the fm-<id> name.
FAKE_WINDOW_ID='@7'

# make_fakebin <dir> builds a fake tmux that answers `#{pane_current_path}` from
# a scripted per-call sequence and records every invocation, plus a no-op
# treehouse. The sequence is FM_FAKE_PANE_EARLY for the first
# FM_FAKE_PANE_EARLY_READS calls and FM_FAKE_PANE_PATH forever after, which is
# enough to model both a pane that settles late and one that never moves.
#
# It also models the created window's LIFETIME in FM_FAKE_WINDOW_FILE: new-window
# records the stable id, the window-id inventory answers from that record, and
# kill-window removes it only when addressed by that exact id (an unknown target
# fails, exactly as tmux does). That is what lets a test observe whether a
# refusal left its window behind, without reading any of fm-spawn's internals.
# The per-target `#{pane_id}` read deliberately does NOT report the closure, for
# the same reason real tmux does not: it exits 0 with empty output on a window
# that is gone, so only the inventory can confirm a removal.
#
# The name-form lookup ('#{window_id} #{window_name}' against a session:name
# target) models real tmux's most dangerous habit: a target naming a window that
# is gone does not fail, it silently answers about the ACTIVE client's window.
# FM_FAKE_OTHER_WINDOW_NAME/_ID name one additional window that really does
# resolve, and every other name falls back to the created window under its own
# name, so a caller that trusts the answer without cross-checking the name is
# observably wrong.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
winfile="${FM_FAKE_WINDOW_FILE:-}"
namefile="$winfile.name"
flagvalue() {  # <flag> <args...> - the value tmux was given for <flag>
  local want=$1 prev=
  shift
  for a in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s' "$a"; return 0; }
    prev=$a
  done
  return 1
}
case "$*" in
  list-windows*"#{window_id}"*)
    # The window-id inventory. This is the only tmux read that can actually
    # observe a closed window, which is why the absence probe uses it.
    [ -n "$winfile" ] && [ -f "$winfile" ] && cat "$winfile"
    exit 0
    ;;
  list-windows*)
    exit 0
    ;;
  *"#{window_id} #{window_name}"*)
    target=$(flagvalue -t "$@") || target=
    want=${target##*:}
    if [ -n "${FM_FAKE_OTHER_WINDOW_NAME:-}" ] && [ "$want" = "$FM_FAKE_OTHER_WINDOW_NAME" ]; then
      printf '%s %s\n' "${FM_FAKE_OTHER_WINDOW_ID:-@9}" "$want"
      exit 0
    fi
    # tmux's fallback: an unresolvable name answers about the active window.
    [ -n "$winfile" ] && [ -f "$namefile" ] || exit 1
    printf '%s %s\n' "$(cat "$winfile")" "$(cat "$namefile")"
    exit 0
    ;;
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_EARLY_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_EARLY:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
  *"#{window_id}"*)
    if [ -n "$winfile" ]; then
      printf '%s\n' "${FM_FAKE_WINDOW_ID:-@7}" > "$winfile"
      printf '%s\n' "$(flagvalue -n "$@" || printf '')" > "$namefile"
    fi
    printf '%s\n' "${FM_FAKE_WINDOW_ID:-@7}"
    exit 0
    ;;
  *"#{pane_id}"*)
    # Real tmux (verified on 3.6): a target naming a window that is GONE does
    # not fail here - it exits 0 with EMPTY output. Modelled exactly, so an
    # exit-status-only existence probe is observably unable to tell a removed
    # window from a live one.
    [ -n "$winfile" ] || { printf '%%0\n'; exit 0; }
    [ -f "$winfile" ] && printf '%%0\n'
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  kill-window)
    [ -n "$winfile" ] && [ -f "$winfile" ] || exit 1
    [ "${3:-}" = "$(cat "$winfile")" ] || exit 1
    rm -f "$winfile" "$namefile"
    exit 0
    ;;
  has-session|new-session|new-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

FAKEBIN=$(make_fakebin "$TMP_ROOT/fake")

# make_home <id> builds a task home with a brief for <id> and echoes its path.
make_home() {
  local id=$1 home
  home="$TMP_ROOT/home-$id"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home"
}

# run_spawn <home> <id> <project> - runs the real fm-spawn against the fake
# backend and leaves the elapsed milliseconds in SPAWN_MS, the exit code in
# SPAWN_STATUS, and the merged output in SPAWN_OUT. Per-run pane scripting comes
# from the FM_FAKE_PANE_* environment the caller exports.
run_spawn() {
  local home=$1 id=$2 proj=$3 start end
  start=$(date +%s%N)
  set +e
  SPAWN_OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_COUNTFILE="$TMP_ROOT/pane-calls-$id" \
    FM_FAKE_WINDOW_FILE="$TMP_ROOT/window-$id" \
    FM_FAKE_WINDOW_ID="$FAKE_WINDOW_ID" \
    FM_TMUX_REC="$TMP_ROOT/tmux-calls-$id" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$proj" codex 2>&1)
  SPAWN_STATUS=$?
  set -e
  end=$(date +%s%N)
  SPAWN_MS=$(( (end - start) / 1000000 ))
}

# --- immediate refusals: the project path can never yield a worktree ---------

# A project argument that names nothing at all is decided before any window
# exists. Pre-fix this aborted with bash's own raw "cd: ...: No such file or
# directory", which names the path but neither what fm-spawn expected nor what
# to do about it.
test_missing_project_path_refuses_immediately() {
  local id=refuse-missing-a1 home missing
  home=$(make_home "$id")
  missing="$TMP_ROOT/no-such-project"

  run_spawn "$home" "$id" "$missing"
  expect_code 1 "$SPAWN_STATUS" "spawn into a nonexistent project path should refuse"
  assert_contains "$SPAWN_OUT" "$missing" "refusal did not name the project path"
  assert_contains "$SPAWN_OUT" "not an existing directory" \
    "refusal did not name the concrete reason"
  assert_contains "$SPAWN_OUT" "Check the path" "refusal did not say what to do"
  [ "$SPAWN_MS" -lt "$IMMEDIATE_MS" ] \
    || fail "nonexistent project path took ${SPAWN_MS}ms to refuse - expected an immediate refusal, not a poll window"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  pass "fm-spawn: a project path that does not exist is refused immediately, naming the path and reason"
}

# A project directory outside any git repository can never yield a git worktree,
# by treehouse get in the pane or by Orca directly. That is decided from the
# project path in fm-spawn's own process, so it must not reach the backend at
# all: no window is created and nothing is sent into a pane.
test_non_git_project_refuses_immediately() {
  local id=refuse-notgit-b2 home proj
  home=$(make_home "$id")
  proj="$TMP_ROOT/plain-directory"
  mkdir -p "$proj"

  run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "spawn into a non-git project dir should refuse"
  assert_contains "$SPAWN_OUT" "$proj" "refusal did not name the project path"
  assert_contains "$SPAWN_OUT" "not inside a git repository" \
    "refusal did not name the concrete reason"
  assert_contains "$SPAWN_OUT" "no isolated worktree can ever be created" \
    "refusal did not say what was expected"
  [ "$SPAWN_MS" -lt "$IMMEDIATE_MS" ] \
    || fail "non-git project took ${SPAWN_MS}ms to refuse - expected an immediate refusal, not a poll window"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  if [ -f "$TMP_ROOT/tmux-calls-$id" ]; then
    assert_no_grep "new-window" "$TMP_ROOT/tmux-calls-$id" \
      "a provably-hopeless spawn created a window before refusing"
  fi
  pass "fm-spawn: a project outside any git repository is refused before any window is created"
}

# --- the slow path stays slow ------------------------------------------------

# The refusals above must not have been bought by giving up on a pane that is
# merely slow. Here the pane sits in the project directory for six polls - the
# ordinary treehouse-get startup shape, and exactly what a naive "this is not a
# worktree, refuse" check would kill - before landing in the real isolated
# worktree. The spawn must succeed, record the real worktree, and be observably
# slower than the immediate refusals above.
test_slow_but_valid_worktree_still_succeeds() {
  local id=slow-valid-c3 home proj wt early_reads=6
  home=$(make_home "$id")
  proj="$TMP_ROOT/slow-project"
  wt="$TMP_ROOT/slow-worktree"
  fm_git_worktree "$proj" "$wt" "wt-$id"

  FM_FAKE_PANE_EARLY="$proj" FM_FAKE_PANE_EARLY_READS="$early_reads" \
    FM_FAKE_PANE_PATH="$wt" \
    run_spawn "$home" "$id" "$proj"
  expect_code 0 "$SPAWN_STATUS" "a slow-but-valid worktree launch should still succeed"
  assert_contains "$SPAWN_OUT" "spawned $id" "slow launch did not report success"
  assert_not_contains "$SPAWN_OUT" "did not enter an isolated worktree" \
    "slow-but-valid launch was wrongly refused"
  assert_grep "worktree=$wt" "$home/state/$id.meta" \
    "meta did not record the settled worktree"
  [ "$SPAWN_MS" -ge $((early_reads * 1000)) ] \
    || fail "slow launch concluded in ${SPAWN_MS}ms - it cannot have waited out the ${early_reads} project-directory polls, so this case no longer proves the slow path survives"
  pass "fm-spawn: a pane that only reaches its worktree after several polls still succeeds"
}

# The guard against a future "clever" fast refusal on pane paths: a pane parked
# on a real, existing, perfectly stable non-worktree directory looks exactly
# like a hopeless launch, and is still not one - the shell owning it can cd at
# any moment. fm-spawn must poll it for the whole configured window and only
# then refuse, naming the path and the concrete reason.
test_stable_existing_non_worktree_is_not_fast_refused() {
  local id=stable-nonwt-d4 home proj parked polls=5
  home=$(make_home "$id")
  proj="$TMP_ROOT/stable-project"
  parked="$TMP_ROOT/stable-parked"
  fm_git_init_commit "$proj" >/dev/null
  mkdir -p "$parked"

  FM_FAKE_PANE_PATH="$parked" FM_SPAWN_WORKTREE_POLLS="$polls" \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane that never reaches a worktree should refuse"
  [ "$SPAWN_MS" -ge $(( (polls - 1) * 1000 )) ] \
    || fail "a stable existing non-worktree pane path was refused after only ${SPAWN_MS}ms - fm-spawn must keep polling it, because a live shell can still cd into the worktree"
  assert_contains "$SPAWN_OUT" "did not enter an isolated worktree" \
    "timeout refusal changed shape"
  assert_contains "$SPAWN_OUT" "$parked" "timeout refusal did not name the parked path"
  assert_contains "$SPAWN_OUT" "not inside a git repository" \
    "timeout refusal did not name the concrete reason"
  assert_contains "$SPAWN_OUT" "$proj" "timeout refusal did not name the primary checkout it must stay out of"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  pass "fm-spawn: a stable existing non-worktree pane path is polled to the end, never fast-refused"
}

# A pane that reaches its isolated worktree on the very last poll leaves no room
# for the confirming read, so the launch is still refused - but the refusal must
# say that, not accuse a genuine isolated worktree of not being one. The reason
# has to state the rule the poll actually enforces (no two CONSECUTIVE reads
# agreed), which is also true of a worktree seen twice but never twice running.
test_worktree_reached_on_final_poll_is_reported_as_unconfirmed() {
  local id=final-poll-f6 home proj wt polls=2
  home=$(make_home "$id")
  proj="$TMP_ROOT/finalpoll-project"
  wt="$TMP_ROOT/finalpoll-worktree"
  fm_git_worktree "$proj" "$wt" "wt-$id"

  FM_FAKE_PANE_EARLY="$proj" FM_FAKE_PANE_EARLY_READS=1 \
    FM_FAKE_PANE_PATH="$wt" FM_SPAWN_WORKTREE_POLLS="$polls" \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "an unconfirmed final-poll worktree should refuse"
  assert_contains "$SPAWN_OUT" "$wt" "refusal did not name the path the window reached"
  assert_contains "$SPAWN_OUT" "no two consecutive reads agreed on it" \
    "refusal did not report the missing confirming read"
  assert_not_contains "$SPAWN_OUT" "it is not an isolated worktree" \
    "refusal described a genuine isolated worktree as not being one"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  pass "fm-spawn: a worktree reached only on the final poll is refused as unconfirmed, not as a non-worktree"
}

# --- the one pane path that IS fast-refused ----------------------------------

# The other half of the contract pinned in tests/fm-spawn-worktree-race.test.sh,
# which asserts a nonexistent path seen BEFORE the pane ever reached the project
# directory must not refuse. Once the pane HAS been seen at the project
# directory, shell init is finished and treehouse get has had its chance, so a
# path that does not exist is a real parked pane and no worktree can ever appear
# there. That one is refused early, naming the path, without waiting out the
# window. Neither half of the pair may be relaxed to make the other pass.
test_nonexistent_pane_path_after_project_sighting_is_refused_early() {
  local id=fast-missing-i9 home proj missing polls=40 window_ms
  home=$(make_home "$id")
  proj="$TMP_ROOT/fastmissing-project"
  fm_git_init_commit "$proj" >/dev/null
  # Deliberately never created: the pane moved somewhere that does not exist.
  missing="$TMP_ROOT/fastmissing-gone"
  window_ms=$((polls * 200))

  FM_FAKE_PANE_EARLY="$proj" FM_FAKE_PANE_EARLY_READS=1 \
    FM_FAKE_PANE_PATH="$missing" FM_SPAWN_WORKTREE_POLLS="$polls" \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.2 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane parked on a nonexistent path should refuse"
  assert_contains "$SPAWN_OUT" "parked on nonexistent path" \
    "the gated nonexistent-path refusal did not fire after a confirmed project sighting"
  assert_contains "$SPAWN_OUT" "$missing" "refusal did not name the nonexistent path"
  assert_contains "$SPAWN_OUT" "$proj" \
    "refusal did not name the project directory whose sighting unlocked it"
  assert_not_contains "$SPAWN_OUT" "did not enter an isolated worktree within" \
    "the refusal came from the window timeout, not the early nonexistent-path abort"
  [ "$SPAWN_MS" -lt $((window_ms / 2)) ] \
    || fail "a pane parked on a nonexistent path took ${SPAWN_MS}ms of a ${window_ms}ms window - the refusal must not wait the window out"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  pass "fm-spawn: a pane parked on a nonexistent path after reaching the project is refused early, naming the path"
}

# --- the refused settle poll never leaves a SILENT orphan --------------------

# Every settle-poll refusal exits after the window exists and before
# state/<id>.meta is written, so nothing would record that window for cleanup -
# fm-teardown refuses outright without a task record, which makes the leftover
# window unreclaimable rather than merely untidy.
#
# What the refusal may do about that is split by what the pane can be proved to
# be doing. The nonexistent-path abort saw the pane reach the project and then
# sit on a path that does not exist, so nothing is mid-allocation and the window
# is removed. The timeout only knows the clock ran out: a slow-but-progressing
# `treehouse get` would be SIGHUPed by a kill, which can damage the PROJECT, and
# the refusal itself sends the operator to read that pane. So the timeout leaves
# the window alive and names the orphan instead. Both must still report why they
# refused, and neither may address the window by the fm-<id> name, which can
# resolve to a different window entirely.
assert_window_reclaimed() {
  local id=$1 home=$2 label=$3
  local rec="$TMP_ROOT/tmux-calls-$id"
  assert_grep "kill-window -t $FAKE_WINDOW_ID" "$rec" \
    "$label did not remove the window it created, leaving it with no task record for cleanup to find"
  assert_no_grep "kill-window -t firstmate:" "$rec" \
    "$label addressed the window by name instead of the stable id it captured at creation"
  assert_absent "$TMP_ROOT/window-$id" "$label left its window open"
  assert_contains "$SPAWN_OUT" "removed the tmux window this launch created" \
    "$label did not report what it reclaimed"
  # A removal that reports itself as a possible leak poisons the loud-report
  # channel the timeout path now depends on, and no other assertion here can see
  # that: the window really is gone either way.
  assert_not_contains "$SPAWN_OUT" "could not remove the window this launch created" \
    "$label warned that the window it did remove was still open"
  assert_not_contains "$SPAWN_OUT" "could not confirm that the window this launch created was removed" \
    "$label could not confirm a removal it provably made"
  assert_contains "$SPAWN_OUT" "never removes a worktree" \
    "$label did not report the worktree it deliberately left for a human"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
}

test_fast_refusal_reclaims_the_window_it_created() {
  local id=reclaim-fast-j1 home proj missing
  home=$(make_home "$id")
  proj="$TMP_ROOT/reclaimfast-project"
  fm_git_init_commit "$proj" >/dev/null
  missing="$TMP_ROOT/reclaimfast-gone"

  FM_FAKE_PANE_EARLY="$proj" FM_FAKE_PANE_EARLY_READS=1 \
    FM_FAKE_PANE_PATH="$missing" FM_SPAWN_WORKTREE_POLLS=40 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane parked on a nonexistent path should refuse"
  assert_contains "$SPAWN_OUT" "parked on nonexistent path" \
    "the refusal reason was lost behind the cleanup"
  assert_window_reclaimed "$id" "$home" "the nonexistent-path refusal"
  pass "fm-spawn: the nonexistent-path refusal removes the window it created and still reports why"
}

# The timeout is the one refusal that must NOT touch the pane: `treehouse get`
# may still be allocating in it, and killing the window would SIGHUP that
# mid-flight, which can leave a partial worktree or a stale lock in the project -
# damage to the project outranks tidiness. It also destroys the scrollback the
# refusal tells the operator to read. The orphan is acceptable only because it is
# named loudly, with the window, the path, and the exact commands to finish by
# hand.
test_timeout_refusal_leaves_the_window_alive_and_names_it() {
  local id=reclaim-timeout-j2 home proj parked
  home=$(make_home "$id")
  proj="$TMP_ROOT/reclaimtimeout-project"
  parked="$TMP_ROOT/reclaimtimeout-parked"
  fm_git_init_commit "$proj" >/dev/null
  mkdir -p "$parked"

  FM_FAKE_PANE_PATH="$parked" FM_SPAWN_WORKTREE_POLLS=3 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane that never reaches a worktree should refuse"
  assert_contains "$SPAWN_OUT" "did not enter an isolated worktree" \
    "the refusal reason was lost behind the orphan report"
  assert_no_grep "kill-window" "$TMP_ROOT/tmux-calls-$id" \
    "the timeout killed a pane that may still have been allocating a worktree in the project"
  assert_present "$TMP_ROOT/window-$id" \
    "the timeout closed the window the refusal tells the operator to go and read"
  assert_contains "$SPAWN_OUT" "$FAKE_WINDOW_ID" \
    "the orphan report did not name the window it left behind"
  assert_contains "$SPAWN_OUT" "$proj" "the orphan report did not name the path involved"
  assert_contains "$SPAWN_OUT" "tmux capture-pane -p -t $FAKE_WINDOW_ID" \
    "the orphan report did not give the command to read the window it left behind"
  assert_contains "$SPAWN_OUT" "tmux kill-window -t $FAKE_WINDOW_ID" \
    "the orphan report did not give the command to close the window it left behind"
  assert_contains "$SPAWN_OUT" "git -C $proj worktree list" \
    "the orphan report did not give the command to find a partial worktree"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  pass "fm-spawn: the settle-window timeout leaves its window alive and names the orphan with the commands to finish by hand"
}

# The orphan report states only what it established. A stale record whose window
# was closed by hand lets a fresh window be created under the same name, so the
# timeout can land on a record that names the very window it is leaving behind -
# and cleanup CAN follow that record, so the report must not claim otherwise.
test_timeout_report_does_not_claim_a_recorded_window_is_unreachable() {
  local id=reclaim-recorded-j6 home proj parked meta
  home=$(make_home "$id")
  proj="$TMP_ROOT/reclaimrecorded-project"
  parked="$TMP_ROOT/reclaimrecorded-parked"
  fm_git_init_commit "$proj" >/dev/null
  mkdir -p "$parked"
  meta="$home/state/$id.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship"

  FM_FAKE_PANE_PATH="$parked" FM_SPAWN_WORKTREE_POLLS=3 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane that never reaches a worktree should refuse"
  assert_contains "$SPAWN_OUT" "did not enter an isolated worktree" \
    "the refusal reason was lost behind the orphan report"
  assert_contains "$SPAWN_OUT" "cleanup can still reach it through that record" \
    "the orphan report did not say the recorded window is still reachable"
  assert_not_contains "$SPAWN_OUT" "so cleanup will never find it" \
    "the orphan report claimed a recorded window is beyond cleanup's reach"
  assert_present "$TMP_ROOT/window-$id" "the timeout closed the window it reported"
  pass "fm-spawn: the orphan report does not claim a window an existing record names is unreachable"
}

# The safety rail on the reclaim. A task record is normally the proof that
# something owns the window, so its presence stops the cleanup dead: killing a
# window another task owns is far worse than leaving one behind. The refusal
# still has to say what it refused and what it left alone.
test_task_record_naming_this_window_suppresses_cleanup() {
  local id=reclaim-owned-j3 home proj missing meta
  home=$(make_home "$id")
  proj="$TMP_ROOT/reclaimowned-project"
  fm_git_init_commit "$proj" >/dev/null
  missing="$TMP_ROOT/reclaimowned-gone"
  meta="$home/state/$id.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" \
    "worktree=$missing" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  FM_FAKE_PANE_EARLY="$proj" FM_FAKE_PANE_EARLY_READS=1 \
    FM_FAKE_PANE_PATH="$missing" FM_SPAWN_WORKTREE_POLLS=40 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane parked on a nonexistent path should refuse"
  assert_contains "$SPAWN_OUT" "parked on nonexistent path" \
    "the refusal reason was lost behind the cleanup decision"
  assert_contains "$SPAWN_OUT" "$meta" \
    "the suppressed cleanup did not name the record it deferred to"
  assert_contains "$SPAWN_OUT" "names this same window" \
    "the suppressed cleanup did not state what it actually determined about the record"
  assert_contains "$SPAWN_OUT" "Nothing was removed" \
    "the suppressed cleanup did not say it left everything alone"
  assert_no_grep "kill-window" "$TMP_ROOT/tmux-calls-$id" \
    "a window covered by an existing task record was killed anyway"
  assert_present "$TMP_ROOT/window-$id" "a window covered by an existing task record was closed anyway"
  assert_grep "window=firstmate:fm-$id" "$meta" \
    "the pre-existing task record was overwritten by a refused spawn"
  pass "fm-spawn: a task record naming this same window stops the cleanup and is reported instead"
}

# The one case where an existing record does NOT protect the window: it names a
# DIFFERENT, resolvable window - a stale pointer that outlived its slot, the same
# class as a completed task's record. The window this launch created is then
# owned by nothing, so it is still reclaimed, and the report says which record
# was found stale.
test_stale_task_record_naming_another_window_still_reclaims() {
  local id=reclaim-stale-j4 home proj missing meta
  home=$(make_home "$id")
  proj="$TMP_ROOT/reclaimstale-project"
  fm_git_init_commit "$proj" >/dev/null
  missing="$TMP_ROOT/reclaimstale-gone"
  meta="$home/state/$id.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-other-owner" \
    "worktree=$missing" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  FM_FAKE_OTHER_WINDOW_NAME=fm-other-owner FM_FAKE_OTHER_WINDOW_ID='@9' \
    FM_FAKE_PANE_EARLY="$proj" FM_FAKE_PANE_EARLY_READS=1 \
    FM_FAKE_PANE_PATH="$missing" FM_SPAWN_WORKTREE_POLLS=40 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane parked on a nonexistent path should refuse"
  assert_contains "$SPAWN_OUT" "parked on nonexistent path" \
    "the refusal reason was lost behind the cleanup"
  assert_contains "$SPAWN_OUT" "is a different window than the $FAKE_WINDOW_ID this launch created" \
    "the reclaim did not report why the existing record failed to protect the window"
  assert_grep "kill-window -t $FAKE_WINDOW_ID" "$TMP_ROOT/tmux-calls-$id" \
    "a window left unowned by a stale record was not reclaimed"
  assert_no_grep "kill-window -t @9" "$TMP_ROOT/tmux-calls-$id" \
    "the reclaim killed the window the stale record named instead of the one this launch created"
  assert_absent "$TMP_ROOT/window-$id" "the unowned window was left open"
  pass "fm-spawn: a stale record naming a different window does not protect the window this launch created"
}

# The safety property, and the reason the comparison resolves the recorded name
# instead of trusting it: `tmux display-message -t <gone-name>` does not fail, it
# answers about the ACTIVE window. A record whose endpoint cannot be resolved to
# a window that still carries that name is ambiguous, and ambiguity must never
# authorize a kill. The same goes for a record with no endpoint in it at all.
test_unresolvable_task_record_does_not_authorize_a_kill() {
  local id home proj missing meta n=0
  for meta in ambiguous unreadable; do
    n=$((n + 1))
    id="reclaim-ambiguous-j5-$n"
    home=$(make_home "$id")
    proj="$TMP_ROOT/reclaimambiguous-project-$n"
    fm_git_init_commit "$proj" >/dev/null
    missing="$TMP_ROOT/reclaimambiguous-gone-$n"
    if [ "$meta" = ambiguous ]; then
      # A name no window carries: the lookup falls back to another window, so
      # nothing about ownership was established.
      fm_write_meta "$home/state/$id.meta" \
        "window=firstmate:fm-vanished-owner" \
        "project=$proj" \
        "harness=codex" \
        "kind=ship"
    else
      # A record with no endpoint at all: nothing to compare against.
      fm_write_meta "$home/state/$id.meta" \
        "project=$proj" \
        "harness=codex" \
        "kind=ship"
    fi

    FM_FAKE_PANE_EARLY="$proj" FM_FAKE_PANE_EARLY_READS=1 \
      FM_FAKE_PANE_PATH="$missing" FM_SPAWN_WORKTREE_POLLS=40 \
      FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
      run_spawn "$home" "$id" "$proj"
    expect_code 1 "$SPAWN_STATUS" "a pane parked on a nonexistent path should refuse"
    assert_contains "$SPAWN_OUT" "parked on nonexistent path" \
      "the $meta record lost the refusal reason"
    assert_contains "$SPAWN_OUT" "unreadable, malformed, or could not be compared" \
      "the $meta record was not reported as the reason nothing was removed"
    assert_no_grep "kill-window" "$TMP_ROOT/tmux-calls-$id" \
      "an $meta task record authorized killing the window anyway"
    assert_present "$TMP_ROOT/window-$id" "an $meta task record still let the window be closed"
  done
  pass "fm-spawn: a task record that cannot be resolved to another window never authorizes a kill"
}

# --- the settle-window override -----------------------------------------------

# expect_poll_override_refused <label> <value> <n> - runs a spawn whose only
# fault is FM_SPAWN_WORKTREE_POLLS=<value> and asserts the observable contract of
# an unusable window: refuse, say why, and do it before the launch, so no window
# and no worktree are left behind unrecorded (a refusal writes no meta, which is
# the only record cleanup reads).
expect_poll_override_refused() {
  local label=$1 value=$2 n=$3 id home proj
  id="bad-polls-e5-$n"
  home=$(make_home "$id")
  proj="$TMP_ROOT/badpolls-project-$n"
  fm_git_init_commit "$proj" >/dev/null

  FM_FAKE_PANE_PATH="$proj" FM_SPAWN_WORKTREE_POLLS="$value" \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "$label poll override '$value' should refuse"
  assert_contains "$SPAWN_OUT" "FM_SPAWN_WORKTREE_POLLS must be a whole number" \
    "$label poll override '$value' was not reported"
  assert_contains "$SPAWN_OUT" "two consecutive reads" \
    "$label poll override '$value' refusal did not state what makes the window unusable"
  assert_contains "$SPAWN_OUT" "'$value'" \
    "$label poll override refusal did not name the offending value '$value'"
  assert_contains "$SPAWN_OUT" "between 2 and 86400" \
    "$label poll override '$value' refusal did not name the accepted range"
  assert_not_contains "$SPAWN_OUT" "integer expected" \
    "$label poll override '$value' leaked the raw shell diagnostic this refusal exists to replace"
  [ "$SPAWN_MS" -lt "$IMMEDIATE_MS" ] \
    || fail "$label poll override '$value' took ${SPAWN_MS}ms to refuse - it must be decided before the launch, not from inside the poll"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  if [ -f "$TMP_ROOT/tmux-calls-$id" ]; then
    assert_no_grep "new-window" "$TMP_ROOT/tmux-calls-$id" \
      "$label poll override '$value' created a window before refusing, leaving it and its worktree behind unrecorded"
  fi
}

# The settle window is tunable so tests and slow hosts can size it, but a
# malformed value must not silently collapse it into an accidental fast refusal
# - the exact wrong-refusal failure the poll exists to avoid.
test_invalid_poll_override_is_refused() {
  local n=0 value
  for value in nonsense 3.5 -1; do
    n=$((n + 1))
    expect_poll_override_refused malformed "$value" "$n"
  done
  pass "fm-spawn: a malformed settle-window override is refused before launching, never treated as a shorter window"
}

# A one-poll window is well-formed and still unusable: accepting a worktree takes
# two consecutive reads that agree on the same path, so a single poll can only
# ever time out, however correctly the pane settled. That must be reported as the
# misconfiguration it is, not discovered as a bogus "never reached a worktree".
test_poll_override_below_confirmation_floor_is_refused() {
  local n=10 value
  for value in 0 1; do
    n=$((n + 1))
    expect_poll_override_refused below-floor "$value" "$n"
  done
  pass "fm-spawn: a settle window too short to ever confirm a worktree is refused before launching"
}

# The other end of the range, which is where validating by comparison alone fails
# OPEN rather than closed. A value past the shell's integer range makes the
# arithmetic test error instead of answering, and that error status reads as "not
# below the floor", so the value is accepted - leaking the raw shell diagnostic
# and then arming a wait no operator asked for. An in-range fat-finger (an extra
# digit on a sane number) needs the same refusal for the same reason: the window
# is a real wait, so an absurd one is a misconfiguration, not a preference.
test_poll_override_above_ceiling_is_refused() {
  local n=20 value
  for value in 86401 6000000000 99999999999999999999999; do
    n=$((n + 1))
    expect_poll_override_refused above-ceiling "$value" "$n"
  done
  pass "fm-spawn: a settle window beyond the accepted ceiling is refused before launching, however large the number"
}

# --- the poll-interval override ----------------------------------------------

# The interval is the other half of the poll pair (FM_KIMI_READY_POLLS /
# FM_KIMI_POLL_INTERVAL is the same shape elsewhere in fm-spawn.sh), and it
# reaches `sleep` directly. An unchecked value would abort mid-poll with the
# shell's own raw diagnostic - after the window exists - and a zero interval
# would busy-spin the backend path query with no wait at all. Both must be
# refused up front, on the same evidence as the count: named value, stated range,
# no raw shell error, and no window left behind.
expect_interval_override_refused() {
  local label=$1 value=$2 n=$3 id home proj
  id="bad-interval-g7-$n"
  home=$(make_home "$id")
  proj="$TMP_ROOT/badinterval-project-$n"
  fm_git_init_commit "$proj" >/dev/null

  FM_FAKE_PANE_PATH="$proj" FM_SPAWN_WORKTREE_POLL_INTERVAL="$value" \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "$label interval override '$value' should refuse"
  assert_contains "$SPAWN_OUT" "FM_SPAWN_WORKTREE_POLL_INTERVAL must be a positive number" \
    "$label interval override '$value' was not reported"
  assert_contains "$SPAWN_OUT" "'$value'" \
    "$label interval override refusal did not name the offending value '$value'"
  assert_not_contains "$SPAWN_OUT" "integer expected" \
    "$label interval override '$value' leaked the raw shell diagnostic this refusal exists to replace"
  assert_not_contains "$SPAWN_OUT" "invalid time interval" \
    "$label interval override '$value' reached sleep instead of being refused up front"
  [ "$SPAWN_MS" -lt "$IMMEDIATE_MS" ] \
    || fail "$label interval override '$value' took ${SPAWN_MS}ms to refuse - it must be decided before the launch, not from inside the poll"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  if [ -f "$TMP_ROOT/tmux-calls-$id" ]; then
    assert_no_grep "new-window" "$TMP_ROOT/tmux-calls-$id" \
      "$label interval override '$value' created a window before refusing, leaving it and its worktree behind unrecorded"
  fi
}

test_invalid_poll_interval_override_is_refused() {
  local n=0 value
  # nonsense, 1.2.3, a bare dot and a trailing dot are unusable shapes; 0, 0.0
  # and 0.0009 are the busy-spin values below the millisecond floor; 61 is past
  # the ceiling; the long digit string is the fail-open case where comparing
  # before checking the shape would accept it.
  for value in nonsense 1.2.3 . 1. -1 0 0.0 0.0009 61 99999999999999999999999; do
    n=$((n + 1))
    expect_interval_override_refused malformed "$value" "$n"
  done
  pass "fm-spawn: an unusable poll-interval override is refused before launching, never passed to sleep"
}

# The other side of that contract: every shape the refusal text and
# docs/configuration.md advertise has to be accepted, or the advertised range is
# a lie. The leading-dot form is a legal sleep argument, and a long-but-in-range
# decimal is a legal 60 - neither may be rejected as malformed.
test_advertised_poll_interval_shapes_are_accepted() {
  local id=good-interval-k4 home proj parked
  home=$(make_home "$id")
  proj="$TMP_ROOT/goodinterval-project"
  parked="$TMP_ROOT/goodinterval-parked"
  fm_git_init_commit "$proj" >/dev/null
  mkdir -p "$parked"

  FM_FAKE_PANE_PATH="$parked" FM_SPAWN_WORKTREE_POLLS=2 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=.5 \
    run_spawn "$home" "$id" "$proj"
  assert_not_contains "$SPAWN_OUT" "FM_SPAWN_WORKTREE_POLL_INTERVAL must be" \
    "the leading-dot interval '.5' was rejected, though the refusal text and docs advertise it"
  assert_contains "$SPAWN_OUT" "did not enter an isolated worktree" \
    "the leading-dot interval did not reach the ordinary settle window"

  # A long in-range decimal must reach the WINDOW check, not the shape check:
  # pairing it with the maximum poll count refuses on the wall-clock product,
  # which is only possible once the value itself was accepted as 60 seconds.
  # Pinning that exact refusal is what makes this case fail if a parse regression
  # turned '60.000000' into some other duration - "exit 1 and no shape refusal"
  # alone would still be satisfied by an eventual timeout.
  id=good-interval-k5
  home=$(make_home "$id")
  FM_FAKE_PANE_PATH="$parked" FM_SPAWN_WORKTREE_POLLS=86400 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=60.000000 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "86400 polls 60s apart should refuse"
  assert_not_contains "$SPAWN_OUT" "FM_SPAWN_WORKTREE_POLL_INTERVAL must be" \
    "the in-range decimal '60.000000' was rejected as malformed for being long"
  assert_contains "$SPAWN_OUT" "86400-second ceiling" \
    "'60.000000' did not reach the wall-clock product refusal, so it was not parsed as 60 seconds"
  pass "fm-spawn: every advertised poll-interval shape is accepted, including .5 and a long in-range decimal"
}

# The count ceiling was always justified as bounding a real WAIT, and the
# interval knob broke that: two independently in-range values multiply into a
# window nobody asked for. The ceiling therefore belongs to the product.
expect_settle_window_refused() {
  local polls=$1 interval=$2 n=$3 id home proj
  id="bad-window-k6-$n"
  home=$(make_home "$id")
  proj="$TMP_ROOT/badwindow-project-$n"
  fm_git_init_commit "$proj" >/dev/null

  FM_FAKE_PANE_PATH="$proj" FM_SPAWN_WORKTREE_POLLS="$polls" \
    FM_SPAWN_WORKTREE_POLL_INTERVAL="$interval" \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "$polls polls ${interval}s apart should refuse"
  assert_contains "$SPAWN_OUT" "FM_SPAWN_WORKTREE_POLLS=$polls" \
    "the settle-window refusal did not name the offending poll count"
  assert_contains "$SPAWN_OUT" "FM_SPAWN_WORKTREE_POLL_INTERVAL=$interval" \
    "the settle-window refusal did not name the offending interval"
  assert_contains "$SPAWN_OUT" "86400-second ceiling" \
    "the settle-window refusal did not name the ceiling it enforced"
  [ "$SPAWN_MS" -lt "$IMMEDIATE_MS" ] \
    || fail "$polls polls ${interval}s apart took ${SPAWN_MS}ms to refuse - the window must be decided before the launch"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  if [ -f "$TMP_ROOT/tmux-calls-$id" ]; then
    assert_no_grep "new-window" "$TMP_ROOT/tmux-calls-$id" \
      "an over-long settle window created a window before refusing"
  fi
}

test_settle_window_product_beyond_the_ceiling_is_refused() {
  local n=0 pair polls interval id home proj wt
  # Each pair is two values that pass their OWN range checks; only their product
  # is out of bounds. 86400x60 is the ~60-day window the count ceiling alone let
  # through.
  for pair in 86400:60 86400:2 3600:25; do
    n=$((n + 1))
    polls=${pair%%:*}
    interval=${pair#*:}
    expect_settle_window_refused "$polls" "$interval" "$n"
  done
  # The boundary a future ceiling change is most likely to break: the historical
  # count ceiling at the default interval is EXACTLY the wall-clock ceiling, so
  # it must still be accepted rather than caught by the product check. Only two
  # polls are actually spent - the pane reaches its worktree immediately - so
  # asserting the window was armed costs nothing.
  id='window-boundary-k7'
  home=$(make_home "$id")
  proj="$TMP_ROOT/windowboundary-project"
  wt="$TMP_ROOT/windowboundary-worktree"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  FM_FAKE_PANE_PATH="$wt" FM_SPAWN_WORKTREE_POLLS=86400 \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=1 \
    run_spawn "$home" "$id" "$proj"
  expect_code 0 "$SPAWN_STATUS" "86400 polls at the default interval is exactly the ceiling and must still be accepted"
  assert_not_contains "$SPAWN_OUT" "86400-second ceiling" \
    "the wall-clock ceiling refused the largest window it is supposed to allow"
  pass "fm-spawn: a settle window whose poll count and interval multiply past the wall-clock ceiling is refused before launching"
}

# The interval must actually shorten the real wait, which is what lets the
# isolation-abort cases in tests/fm-tangle-guard.test.sh stop costing two minutes
# of pure sleep. Same poll count as the default-interval case, so the only
# variable is the interval.
test_poll_interval_override_shortens_the_wait() {
  local id=fast-interval-h8 home proj parked polls=5
  home=$(make_home "$id")
  proj="$TMP_ROOT/fastinterval-project"
  parked="$TMP_ROOT/fastinterval-parked"
  fm_git_init_commit "$proj" >/dev/null
  mkdir -p "$parked"

  FM_FAKE_PANE_PATH="$parked" FM_SPAWN_WORKTREE_POLLS="$polls" \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    run_spawn "$home" "$id" "$proj"
  expect_code 1 "$SPAWN_STATUS" "a pane that never reaches a worktree should still refuse"
  assert_contains "$SPAWN_OUT" "did not enter an isolated worktree" "timeout refusal changed shape"
  assert_contains "$SPAWN_OUT" "$parked" "timeout refusal did not name the parked path"
  [ "$SPAWN_MS" -lt $(( (polls - 1) * 1000 )) ] \
    || fail "a ${polls}-poll window at 0.05s took ${SPAWN_MS}ms - the interval override did not shorten the real wait"
  assert_absent "$home/state/$id.meta" "refused spawn must not record meta"
  pass "fm-spawn: the poll-interval override shortens the real wait while the refusal is unchanged"
}

test_missing_project_path_refuses_immediately
test_non_git_project_refuses_immediately
test_invalid_poll_override_is_refused
test_invalid_poll_interval_override_is_refused
test_advertised_poll_interval_shapes_are_accepted
test_settle_window_product_beyond_the_ceiling_is_refused
test_poll_interval_override_shortens_the_wait
test_poll_override_below_confirmation_floor_is_refused
test_poll_override_above_ceiling_is_refused
test_worktree_reached_on_final_poll_is_reported_as_unconfirmed
test_nonexistent_pane_path_after_project_sighting_is_refused_early
test_fast_refusal_reclaims_the_window_it_created
test_timeout_refusal_leaves_the_window_alive_and_names_it
test_timeout_report_does_not_claim_a_recorded_window_is_unreachable
test_task_record_naming_this_window_suppresses_cleanup
test_stale_task_record_naming_another_window_still_reclaims
test_unresolvable_task_record_does_not_authorize_a_kill
test_slow_but_valid_worktree_still_succeeds
test_stable_existing_non_worktree_is_not_fast_refused

echo "# all fm-spawn-nonworktree-refusal tests passed"
