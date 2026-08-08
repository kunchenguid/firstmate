#!/usr/bin/env bash
# Behavior tests for atomic task-metadata publication in bin/fm-spawn.sh.
#
# state/<id>.meta is the only handle teardown and crew-state reconciliation
# have on a spawned endpoint, so a half-written record is worse than none: a
# meta missing window= or worktree= is still read as authoritative. Publication
# therefore stages the record, verifies the bytes landed, and only then renames
# it into place. These tests drive the real script with a fake tmux and assert
# the two outcomes that matter to an operator: a successful spawn leaves a
# complete record and no staging debris, and a failed publication leaves no
# record at all, no staging debris, an accurate message, and no endpoint that
# nothing names.
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
# decide whether its endpoint is gone: a killed window is recorded under
# FM_FAKE_GONE_DIR and its `-t <session>:<window> #{pane_id}` probe then fails,
# exactly as real tmux answers for a window that no longer exists. Setting
# FM_FAKE_KILL_NOOP=1 keeps kill-window succeeding while the window survives -
# the real shape of every adapter's best-effort kill, which reports success
# even when the close was refused or silently dropped.
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
  list-windows) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    if [ "${FM_FAKE_KILL_NOOP:-0}" != 1 ] && [ -n "${FM_FAKE_GONE_DIR:-}" ]; then
      win=$(fake_target_window "$@")
      [ -z "$win" ] || : > "$FM_FAKE_GONE_DIR/$win"
    fi
    exit 0
    ;;
  has-session|new-session|new-window) exit 0 ;;
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
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/gone"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/kill-log|$case_dir/gone"
}

read_meta_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR KILL_LOG GONE_DIR <<EOF
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
    FM_FAKE_GONE_DIR="$GONE_DIR" FM_FAKE_KILL_NOOP="${FM_FAKE_KILL_NOOP:-0}" \
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

# The failure path must not claim a cleanup it did not perform: it either
# discards the endpoint it created or says the endpoint outlived the spawn.
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
    *"outlived the failed spawn"*)
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
  assert_contains "$out" "outlived the failed spawn" \
    "a surviving endpoint was not reported after a success-shaped kill: $out"
  assert_contains "$out" "$id" "the stranded-endpoint warning did not name the task"
  pass "an endpoint that survives a success-shaped kill is reported as stranded"
}

test_successful_publication_is_complete_and_leaves_no_staging_file
test_failed_publication_publishes_no_record
test_failed_publication_discards_its_endpoint
test_surviving_endpoint_is_reported_despite_a_successful_kill

echo "# all fm-spawn-meta-publication tests passed"
