#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
# Its capture-pane prints FM_FAKE_PANE_SCREEN as the pane's text.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
window_file="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.window"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ -n "${FM_FAKE_CWD_PROBE:-}" ]; then
      printf '__FM_%s_CWD_BEGIN__\n%s\n__FM_%s_CWD_END__\n' \
        "$FM_FAKE_CWD_PROBE" "$FM_FAKE_PANE_STALE" "$FM_FAKE_CWD_PROBE" >> "$countfile.screen"
    fi
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  capture-pane)
    lines=200
    previous=
    for arg in "$@"; do
      [ "$previous" != -S ] || lines=${arg#-}
      previous=$arg
    done
    {
      printf '%s\n' "${FM_FAKE_PANE_SCREEN:-}"
      [ ! -f "$FM_FAKE_PANE_COUNTFILE.screen" ] || cat "$FM_FAKE_PANE_COUNTFILE.screen"
    } | tail -n "$lines"
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0 ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_contains "$out" "within 60s" "the default wait was not 60 seconds"
  [ "$(cat "$COUNTFILE")" -eq 60 ] || fail "default wait polled the pane $(cat "$COUNTFILE") times, expected 60"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# A pool at its slot cap, or a slot that takes minutes to create, leaves the
# only explanation in the pane. FM_SPAWN_TREEHOUSE_TIMEOUT sets the wait, and
# the refusal carries treehouse's own output after the typed command, because
# the refusal closes the window that holds it.
test_treehouse_wait_is_configurable_and_reports_pane_output() {
  local rec id out status screen format command_echo diagnostic expected typed_line parent timeout polls
  diagnostic=$'treehouse: all 24 worktrees are in use (max_trees=24)\nuser@host mate %'
  for format in single wrapped-word wrapped-space missing repeated root zero; do
    id="settle-pool-cap-$format-z6"
    rec=$(make_primary_case "settle-pool-cap-$format" "$id" 100000)
    read_settle_record "$rec"
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"
    expected="treehouse: all 24 worktrees are in use (max_trees=24) | user@host mate %"
    typed_line='treehouse get'
    timeout=4
    polls=4
    case "$format" in
      single|zero) command_echo='user@host mate % treehouse get' ;;
      wrapped-word) command_echo=$'user@host mate % treeho\nuse g\net' ;;
      wrapped-space) command_echo=$'user@host mate % treehouse\nget' ;;
      missing) command_echo='partial command echo'; expected="partial command echo | $expected" ;;
      repeated) command_echo=$'user@host mate % treehouse get\nearlier output\nuser@host mate % treehouse g\net' ;;
      root)
        parent="$TMP_ROOT/pool-cap-parent"
        mkdir -p "$parent/state" "$parent/config"
        printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$HOME_DIR/.fm-secondmate-parent"
        typed_line="treehouse --root '$TREEHOUSE_ROOT/fm-secondmate/$(printf '%s' "$HOME_DIR" | git hash-object --stdin)' get"
        command_echo=$'user@host mate % treehouse --ro\not '"${typed_line#treehouse --root }"
        ;;
    esac
    if [ "$format" = zero ]; then timeout=00; polls=60; fi
    screen="$command_echo"$'\n'"$diagnostic"
    [ "$format" = missing ] || screen=$'earlier output\n'"$screen"

    out=$(FM_SPAWN_TREEHOUSE_TIMEOUT="$timeout" FM_FAKE_PANE_SCREEN="$screen" run_settle_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "$format: spawn accepted a pane that never left the primary checkout"$'\n'"$out"
    assert_contains "$out" "within ${polls}s" "the refusal did not report the effective wait"
    [ "$(cat "$COUNTFILE")" -eq "$polls" ] || fail "configured wait polled the pane $(cat "$COUNTFILE") times, expected $polls"
    assert_contains "$out" "pane output after '$typed_line': $expected" \
      "$format: the refusal did not carry treehouse's own pane output"$'\n'"$out"
    assert_not_contains "$out" "earlier output" "$format: the refusal carried pane output from before treehouse get"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  done
  pass "the configured treehouse wait preserves diagnostics with wrapped, missing, or repeated echoes"
}

test_treehouse_diagnostic_survives_poll_output() {
  local probe rec id out status screen final_capture
  screen=$'user@host mate % treehouse get\ntreehouse: all 24 worktrees are in use (max_trees=24)\nuser@host mate %'
  for probe in CMUX PASEO ZELLIJ; do
    id="settle-probe-${probe}-z7"
    rec=$(make_primary_case "settle-probe-$probe" "$id" 100000)
    read_settle_record "$rec"
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"
    out=$(FM_FAKE_CWD_PROBE="$probe" FM_FAKE_PANE_SCREEN="$screen" run_settle_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "$probe: spawn accepted a pane that never settled"
    [ "$(cat "$COUNTFILE")" -eq 60 ] || fail "$probe: the default wait did not run all polls"
    final_capture=$(FM_FAKE_PANE_SCREEN="$screen" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
      "$FAKEBIN_DIR/tmux" capture-pane -p -S -120)
    assert_not_contains "$final_capture" 'all 24 worktrees are in use' "$probe: the fixture did not displace the diagnostic"
    assert_contains "$out" 'all 24 worktrees are in use (max_trees=24)' "$probe: poll output erased the refusal diagnostic"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$probe: refused spawn published task metadata"
  done
  pass 'directory probes cannot erase the treehouse refusal diagnostic'
}

test_unborn_head_project_is_refused_at_once() {
  local rec id out status started elapsed
  id=settle-unborn-head-z5
  rec=$(make_settle_case settle-unborn "$id" 0)
  read_settle_record "$rec"
  PROJ_DIR="$TMP_ROOT/settle-unborn/unborn-project"
  git init -q "$PROJ_DIR"

  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "spawn into a project with no commit should be refused"
  assert_contains "$out" "unborn HEAD" "the refusal did not name the unborn HEAD cause"
  assert_contains "$out" "make one commit" "the refusal did not name the remedy"
  [ "$elapsed" -lt 30 ] || fail "refusal took ${elapsed}s instead of failing before the treehouse wait"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ -z "$(git -C "$PROJ_DIR" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the project"
  pass "a project with an unborn HEAD is refused at once with its cause named"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_treehouse_wait_is_configurable_and_reports_pane_output
test_treehouse_diagnostic_survives_poll_output
test_unborn_head_project_is_refused_at_once

echo "# all fm-spawn-worktree-settle tests passed"
