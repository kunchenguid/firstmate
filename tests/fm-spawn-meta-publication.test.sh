#!/usr/bin/env bash
# Behavior tests for atomic task-metadata publication in bin/fm-spawn.sh.
#
# state/<id>.meta is the only handle teardown and crew-state reconciliation
# have on a spawned endpoint, so a half-written record is worse than none: a
# meta missing window= or worktree= is still read as authoritative. Publication
# therefore stages the record, verifies the bytes landed, and only then renames
# it into place. These tests drive the real script with a fake tmux and assert
# the outcomes that matter to an operator: a successful spawn leaves a
# complete record and no staging debris; a failed publication leaves no record
# at all, no staging debris, an accurate message, and no endpoint that nothing
# names; and a failed relaunch, which republishes over a record already at the
# final path, reports the earlier record that survives there rather than
# denying that any record exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-meta-publication)

# make_meta_fakebin <dir> <worktree>: a fake tmux that reports the settled
# worktree for pane_current_path and appends every kill-window invocation to
# FM_FAKE_KILL_LOG, so a test can observe whether the spawn discarded the
# window it created.
#
# It also models window PRESENCE, because that is what the spawn now reads to
# decide whether its endpoint is gone. A created window is recorded under
# FM_FAKE_LIVE_DIR and listed by `list-windows`, which is the inventory the
# tmux adapter's confirmed-absence check reads; a killed window is removed from
# it and recorded under FM_FAKE_GONE_DIR, so the `#{pane_id}` probe fails for it
# too, exactly as real tmux answers for a window that no longer exists.
#
# Two failure shapes the spawn must tell apart:
#   FM_FAKE_KILL_NOOP=1     kill-window still succeeds while the window
#                           survives - the real shape of every adapter's
#                           best-effort kill, which reports success even when
#                           the close was refused or silently dropped.
#   FM_FAKE_INVENTORY_ERR=1 every inventory read fails the way a busy or
#                           half-dead server does (a message that is NOT one of
#                           tmux's definitive missing-session/no-server
#                           replies), so nothing can be confirmed about the
#                           window either way.
make_meta_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# The window half of the `-t` target, with tmux's exact-match `=` prefix
# stripped, or empty when this invocation carries no target.
fake_target_window() {
  local arg prev= win=
  for arg in "$@"; do
    [ "$prev" = "-t" ] && win=$arg
    prev=$arg
  done
  win=${win##*:}
  printf '%s' "${win#=}"
}
# The value of the `-n` flag (a new window's name), or empty.
fake_window_name() {
  local arg prev= name=
  for arg in "$@"; do
    [ "$prev" = "-n" ] && name=$arg
    prev=$arg
  done
  printf '%s' "$name"
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*)
    win=$(fake_target_window "$@")
    if [ -n "${FM_FAKE_GONE_DIR:-}" ] && [ -n "$win" ] && [ -e "$FM_FAKE_GONE_DIR/$win" ]; then
      echo "can't find window: $win" >&2
      exit 1
    fi
    printf '%%1\n'
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_INVENTORY_ERR:-0}" = 1 ]; then
      echo "server exited unexpectedly" >&2
      exit 1
    fi
    [ -z "${FM_FAKE_LIVE_DIR:-}" ] || ls "$FM_FAKE_LIVE_DIR" 2>/dev/null
    exit 0
    ;;
  new-window)
    name=$(fake_window_name "$@")
    if [ -n "${FM_FAKE_LIVE_DIR:-}" ] && [ -n "$name" ]; then
      : > "$FM_FAKE_LIVE_DIR/$name"
    fi
    exit 0
    ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    if [ "${FM_FAKE_KILL_NOOP:-0}" != 1 ]; then
      win=$(fake_target_window "$@")
      if [ -n "$win" ]; then
        [ -z "${FM_FAKE_GONE_DIR:-}" ] || : > "$FM_FAKE_GONE_DIR/$win"
        [ -z "${FM_FAKE_LIVE_DIR:-}" ] || rm -f "$FM_FAKE_LIVE_DIR/$win"
      fi
    fi
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# add_failing_mv <fakebin>: shadow mv so that committing a staged task record
# fails the way a full or quota-exhausted filesystem would, while every other
# rename in the spawn still runs for real.
add_failing_mv() {
  local fakebin=$1
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *.meta.tmp.*) echo "mv: simulated publication failure" >&2; exit 1 ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
}

# make_meta_case <name> <id>: a home, a real project with a real worktree, and
# the fake toolchain the spawn needs.
make_meta_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_meta_fakebin "$case_dir/fake" "$wt")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/gone" "$case_dir/live"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/kill-log|$case_dir/gone|$case_dir/live"
}

read_meta_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR KILL_LOG GONE_DIR LIVE_DIR <<EOF
$1
EOF
}

run_meta_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_KILL_LOG="$KILL_LOG" \
    FM_FAKE_GONE_DIR="$GONE_DIR" FM_FAKE_LIVE_DIR="$LIVE_DIR" \
    FM_FAKE_KILL_NOOP="${FM_FAKE_KILL_NOOP:-0}" \
    FM_FAKE_INVENTORY_ERR="${FM_FAKE_INVENTORY_ERR:-0}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

staging_files() {
  find "$HOME_DIR/state" -name '*.meta.tmp.*' 2>/dev/null
}

# A normal spawn publishes one complete record and leaves no staging file
# behind, so the staged-then-renamed path is invisible to every reader of
# state/<id>.meta.
test_successful_publication_is_complete_and_leaves_no_staging_file() {
  local rec id out status meta_project
  id=meta-publish-ok-z1
  rec=$(make_meta_case meta-publish-ok "$id")
  read_meta_record "$rec"

  out=$(run_meta_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when metadata publishes cleanly"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "window=" "$HOME_DIR/state/$id.meta" "published meta lost window="
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "published meta lost worktree="
  meta_project=$(sed -n 's/^project=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$meta_project" ] && [ "$(cd "$meta_project" 2>/dev/null && pwd -P)" = "$(cd "$PROJ_DIR" && pwd -P)" ] \
    || fail "published meta recorded project='$meta_project', expected $PROJ_DIR"
  assert_grep "kind=ship" "$HOME_DIR/state/$id.meta" "published meta lost kind="
  [ -z "$(staging_files)" ] || fail "a staged metadata file survived a successful spawn: $(staging_files)"
  pass "a successful spawn publishes a complete record and leaves no staging file"
}

# A publication that cannot be committed must publish nothing. Anything else
# hands teardown and crew-state reconciliation a truncated record they would
# treat as authoritative.
test_failed_publication_publishes_no_record() {
  local rec id out status
  id=meta-publish-fail-z2
  rec=$(make_meta_case meta-publish-fail "$id")
  read_meta_record "$rec"
  add_failing_mv "$FAKEBIN_DIR"

  out=$(run_meta_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn reported success despite a failed metadata publication: $out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "a task record was published despite the failed publication: $(cat "$HOME_DIR/state/$id.meta")"
  [ -z "$(staging_files)" ] || fail "the staged metadata file survived the failure: $(staging_files)"
  assert_contains "$out" "no task record was written for $id" \
    "the failure did not state that no task record exists"
  pass "a failed metadata publication leaves no task record and no staging file"
}

# Publication renames over whatever is already at state/<id>.meta and never
# unlinks it first, so a relaunch whose rename fails leaves the EARLIER record
# in place - readable by the operator and still counted as a task by
# bin/fm-crew-state.sh. Telling that operator "no task record was written"
# sends them looking for a record they are in fact still being served, while
# the endpoint the surviving record names has just been discarded by this run.
test_failed_republication_reports_the_surviving_record() {
  local rec id out status published
  id=meta-republish-stale-z7
  rec=$(make_meta_case meta-republish-stale "$id")
  read_meta_record "$rec"

  out=$(run_meta_spawn "$id")
  status=$?
  expect_code 0 "$status" "the first spawn should publish a record cleanly"
  published=$(cat "$HOME_DIR/state/$id.meta")

  # The worker dies; its record stays. That is exactly the state a relaunch
  # starts from, and the only state in which the spawn republishes over a
  # record that is already at the final path.
  rm -f "$LIVE_DIR/fm-$id"
  : > "$GONE_DIR/fm-$id"

  add_failing_mv "$FAKEBIN_DIR"
  out=$(run_meta_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "the relaunch reported success despite a failed publication: $out"
  [ "$(cat "$HOME_DIR/state/$id.meta")" = "$published" ] \
    || fail "the failed relaunch altered the earlier record: $(cat "$HOME_DIR/state/$id.meta")"
  case "$out" in
    *"no task record was written"*)
      fail "the failed relaunch denied a record that survives at the final path: $out" ;;
  esac
  assert_contains "$out" "an earlier task record for $id survives at that path" \
    "the failed relaunch did not name the surviving earlier record"
  pass "a failed relaunch reports the earlier record that survives at the final path"
}

# The stranded-endpoint warning has the same honesty problem from the other
# side. When a relaunch's publication fails and the discard cannot be
# confirmed, the surviving earlier record is precisely what names an endpoint
# for this task id - so "no task record names it" would send the operator
# hunting for an unnamed window while state/<id>.meta names one.
test_stranded_endpoint_on_a_relaunch_names_the_surviving_record() {
  local rec id out status
  id=meta-republish-stranded-z8
  rec=$(make_meta_case meta-republish-stranded "$id")
  read_meta_record "$rec"

  out=$(run_meta_spawn "$id")
  status=$?
  expect_code 0 "$status" "the first spawn should publish a record cleanly"
  rm -f "$LIVE_DIR/fm-$id"
  : > "$GONE_DIR/fm-$id"

  add_failing_mv "$FAKEBIN_DIR"
  out=$(FM_FAKE_KILL_NOOP=1 run_meta_spawn "$id") || true
  assert_contains "$out" "was not confirmed gone" \
    "the relaunch's surviving endpoint was not reported as stranded"
  case "$out" in
    *"no task record names it"*)
      fail "the stranded-endpoint warning denied a record that names this task: $out" ;;
  esac
  assert_contains "$out" "only an earlier task record for $id names it" \
    "the stranded-endpoint warning did not point at the surviving earlier record"
  pass "a stranded endpoint on a relaunch points at the record that still names it"
}

# The publication failure is one event, so the operator reads it once. Two
# owners printed it before: the abort path and the EXIT trap that alone knows
# whether an Orca recovery record survived. A duplicated line reads like two
# separate failures and invites a search for the second one.
test_failed_publication_reports_the_failure_once() {
  local rec id out count
  id=meta-publish-once-z5
  rec=$(make_meta_case meta-publish-once "$id")
  read_meta_record "$rec"
  add_failing_mv "$FAKEBIN_DIR"

  out=$(run_meta_spawn "$id") || true
  count=$(printf '%s\n' "$out" | grep -c "task metadata could not be published")
  [ "$count" -eq 1 ] \
    || fail "the publication failure was reported $count times, expected once: $out"
  pass "a failed metadata publication reports the failure exactly once"
}

# The failure path must not claim a cleanup it did not perform: it either
# discards the endpoint it created or says the endpoint was not confirmed gone.
test_failed_publication_discards_its_endpoint() {
  local rec id out
  id=meta-publish-discard-z3
  rec=$(make_meta_case meta-publish-discard "$id")
  read_meta_record "$rec"
  add_failing_mv "$FAKEBIN_DIR"

  out=$(run_meta_spawn "$id") || true
  [ -s "$KILL_LOG" ] || fail "the failed spawn left its tmux window behind: $out"
  assert_grep "fm-$id" "$KILL_LOG" "the failed spawn discarded some other window"
  case "$out" in
    *"cleaning up the incomplete spawn"*)
      fail "the failure message still claims an unverified complete cleanup: $out" ;;
  esac
  case "$out" in
    *"was not confirmed gone"*)
      fail "the failure reported a stranded endpoint after a close that worked: $out" ;;
  esac
  pass "a failed metadata publication discards the endpoint it created"
}

# Every adapter's kill is best-effort: it reports success even when the close
# was refused (a herdr pane close without its session presentation lock) or
# silently dropped. If the spawn read that exit status as proof, the operator
# would be told only that no record was written, while a live pane no record
# names keeps running. The verdict must come from re-reading the endpoint.
test_surviving_endpoint_is_reported_despite_a_successful_kill() {
  local rec id out
  id=meta-publish-survivor-z4
  rec=$(make_meta_case meta-publish-survivor "$id")
  read_meta_record "$rec"
  add_failing_mv "$FAKEBIN_DIR"

  out=$(FM_FAKE_KILL_NOOP=1 run_meta_spawn "$id") || true
  [ -s "$KILL_LOG" ] || fail "the failed spawn never attempted to discard its endpoint: $out"
  assert_contains "$out" "was not confirmed gone" \
    "a surviving endpoint was not reported after a success-shaped kill: $out"
  assert_contains "$out" "$id" "the stranded-endpoint warning did not name the task"
  pass "an endpoint that survives a success-shaped kill is reported as stranded"
}

# A runtime that cannot answer is not a removed endpoint. When the kill really
# ran but the inventory read fails the way a busy or half-dead server does, the
# spawn knows nothing about the window - so it must warn rather than report a
# cleanup it never confirmed. This is the case a plain presence probe gets
# wrong: that probe fails identically for a gone window and an unreachable
# server, so it would call this a clean discard.
test_unreadable_runtime_is_not_read_as_a_removed_endpoint() {
  local rec id out
  id=meta-publish-unreadable-z6
  rec=$(make_meta_case meta-publish-unreadable "$id")
  read_meta_record "$rec"
  add_failing_mv "$FAKEBIN_DIR"

  out=$(FM_FAKE_INVENTORY_ERR=1 run_meta_spawn "$id") || true
  [ -s "$KILL_LOG" ] || fail "the failed spawn never attempted to discard its endpoint: $out"
  assert_contains "$out" "was not confirmed gone" \
    "an unreadable runtime was reported as a successful cleanup: $out"
  assert_contains "$out" "$id" "the stranded-endpoint warning did not name the task"
  pass "an unreadable runtime is not mistaken for a removed endpoint"
}

test_successful_publication_is_complete_and_leaves_no_staging_file
test_failed_publication_publishes_no_record
test_failed_republication_reports_the_surviving_record
test_stranded_endpoint_on_a_relaunch_names_the_surviving_record
test_failed_publication_reports_the_failure_once
test_failed_publication_discards_its_endpoint
test_surviving_endpoint_is_reported_despite_a_successful_kill
test_unreadable_runtime_is_not_read_as_a_removed_endpoint

echo "# all fm-spawn-meta-publication tests passed"
