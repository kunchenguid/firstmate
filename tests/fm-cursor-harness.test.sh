#!/usr/bin/env bash
# Behavior tests for the verified `cursor` crewmate harness adapter.
#
# Facts pinned here were verified empirically on cursor-agent 2026.07.17-3e2a980
# (2026-07-21); the harness-adapters skill records the supervision knowledge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
mkdir -p "$TMP_ROOT"

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"; fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/keys"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POOL_KEY_DIR="$home/keys" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_cursor_launch_command() {
  local rec id out launch expected
  id=cursor-launch-a1
  rec=$(make_case cursor-launch "$id")
  read_case "$rec"
  out=$(CURSOR_API_KEY=present run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor)
  expect_code 0 $? "cursor spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=cursor" "spawn did not report cursor"
  launch=$(cat "$LAUNCH_LOG")
  expected="cursor agent --force \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] \
    || fail "cursor launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "cursor launches the interactive TUI with --force and the brief as its positional prompt"
}

test_cursor_turn_end_hook() {
  local rec id out hook
  id=cursor-hook-b1
  rec=$(make_case cursor-hook "$id")
  read_case "$rec"
  out=$(CURSOR_API_KEY=present run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor)
  expect_code 0 $? "cursor spawn should succeed: $out"

  hook="$WT_DIR/.cursor/hooks.json"
  [ -f "$hook" ] || fail "cursor needs a project stop hook at .cursor/hooks.json"
  grep -q '"stop"' "$hook" || fail "the hook should register the stop event, got: $(cat "$hook")"
  # Match the marker basename: fm-spawn records the PHYSICALLY resolved state dir,
  # which differs from $HOME_DIR under a symlinked temp root such as macOS's /var.
  grep -q "$id\.turn-ended" "$hook" \
    || fail "the hook should touch this task's turn-end marker, got: $(cat "$hook")"
  # Malformed JSON would make cursor ignore the hook and firstmate would never
  # see a turn boundary, so assert it actually parses.
  if command -v jq >/dev/null 2>&1; then
    jq -e '.hooks.stop[0].command' "$hook" >/dev/null \
      || fail "the hook file must be valid JSON with a stop command, got: $(cat "$hook")"
  fi
  # Kept out of git's view like every other harness's worktree hook file, so it
  # cannot block teardown's dirty check or ride along in a commit.
  grep -qxF '.cursor/hooks.json' "$(git -C "$WT_DIR" rev-parse --git-path info/exclude)" \
    || fail "the cursor hook file should be excluded from git"
  pass "cursor gets a project stop hook that touches the task's turn-end marker and is git-excluded"
}

# .cursor/hooks.json is a PROJECT config file, unlike .claude/settings.local.json.
# When the project commits it, firstmate must leave it exactly as it is: clobbering
# it disables the project's own hooks, dirties a tracked path for the whole task
# (which then blocks failover and teardown), and can ride along in a commit.
test_cursor_leaves_a_tracked_hook_file_alone() {
  local rec id out hook before
  id=cursor-tracked-hook-g1
  rec=$(make_case cursor-tracked-hook "$id")
  read_case "$rec"
  hook="$WT_DIR/.cursor/hooks.json"
  mkdir -p "$WT_DIR/.cursor"
  printf '{"version":1,"hooks":{"stop":[{"type":"command","command":"true"}]}}\n' > "$hook"
  fm_git_identity
  git -C "$WT_DIR" add .cursor/hooks.json
  git -C "$WT_DIR" commit --quiet -m 'project hooks'
  before=$(cat "$hook")

  out=$(CURSOR_API_KEY=present run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor)
  expect_code 0 $? "a tracked hooks.json must degrade supervision, not fail the spawn: $out"

  [ "$(cat "$hook")" = "$before" ] || fail "a tracked .cursor/hooks.json must never be rewritten, got: $(cat "$hook")"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "the worktree must stay clean; got: $(git -C "$WT_DIR" status --porcelain)"
  assert_contains "$out" "cursor turn-end detection is DISABLED" \
    "the spawn should say plainly that turn-end detection is off for this task"
  pass "a tracked .cursor/hooks.json is left untouched and the lost turn-end signal is announced"
}

test_cursor_model_flag_but_no_effort_flag() {
  local rec id out launch meta
  id=cursor-model-c1
  rec=$(make_case cursor-model "$id")
  read_case "$rec"
  out=$(CURSOR_API_KEY=present run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor --model claude-sonnet-5-thinking-high --effort xhigh)
  expect_code 0 $? "cursor spawn with a model should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *"--model 'claude-sonnet-5-thinking-high'"*) ;;
    *) fail "cursor should carry --model, got: $launch" ;;
  esac
  # Cursor bakes effort into the model id and has no effort flag; the requested
  # value is still recorded for traceability, exactly like other capped harnesses.
  case "$launch" in
    *--effort*|*--thinking*|*--reasoning-effort*) fail "cursor has no effort flag; none should be emitted, got: $launch" ;;
  esac
  meta=$(cat "$HOME_DIR/state/$id.meta")
  case "$meta" in
    *"effort=xhigh"*) ;;
    *) fail "the requested effort should still be recorded in meta, got: $meta" ;;
  esac
  pass "cursor emits --model, emits no effort flag, and still records the requested effort"
}

test_cursor_refuses_secondmate() {
  local rec id out status
  id=cursor-secondmate-d1
  rec=$(make_case cursor-secondmate "$id")
  read_case "$rec"
  mkdir -p "$CASE_DIR/sub/bin" "$CASE_DIR/sub/data"
  printf '# Firstmate\n' > "$CASE_DIR/sub/AGENTS.md"
  printf '%s\n' "$id" > "$CASE_DIR/sub/.fm-secondmate-home"
  printf 'charter\n' > "$CASE_DIR/sub/data/charter.md"
  set +e
  out=$(CURSOR_API_KEY=present run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$CASE_DIR/sub" --harness cursor --secondmate)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "cursor must be refused for a secondmate spawn"
  case "$out" in
    *"crewmate and scout spawns only"*) ;;
    *) fail "the refusal should say cursor is crewmate/scout only, got: $out" ;;
  esac
  pass "cursor is refused for a secondmate, which needs a primary-capable harness"
}

test_cursor_refuses_without_a_key() {
  local rec id out status
  id=cursor-nokey-e1
  rec=$(make_case cursor-nokey "$id")
  read_case "$rec"
  set +e
  # No pool account and no CURSOR_API_KEY: cursor would park on a login prompt.
  # The $1..$6 below deliberately expand in the child bash from its positional args.
  # shellcheck disable=SC2016
  out=$(env -u CURSOR_API_KEY bash -c '
    FM_ROOT_OVERRIDE="" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$2" TMUX="fake,1,0" PATH="$3:$PATH" \
    "$4" "$5" "$6" --harness cursor 2>&1
  ' _ "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SPAWN" "$id" "$PROJ_DIR")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a keyless cursor spawn must be refused"
  case "$out" in
    *"needs an API key"*) ;;
    *) fail "the refusal should name the missing key, got: $out" ;;
  esac
  case "$out" in
    *"parks on a login prompt"*) ;;
    *) fail "the refusal should explain the consequence, got: $out" ;;
  esac
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "a refused cursor spawn must not leave task metadata"
  pass "a cursor spawn with no key is refused up front instead of parking on a login prompt"
}

test_cursor_busy_signature_is_recognized() {
  # Recorded task state comes from the semantic contract in bin/fm-busy-lib.sh,
  # which keeps an unverified harness at unknown rather than guessing from text.
  # The rendered signature here is the DELIVERY guard: without it, fm-send would
  # type into a mid-turn cursor pane instead of waiting for the composer.
  local busy_line
  busy_line=' → Add a follow-up                                            ctrl+c to stop'
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s\n' "$busy_line" | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "the tmux busy regex should match cursor's mid-turn hint"
  printf '%s\n' "$busy_line" | fm_busy_lines_match cursor \
    || fail "cursor's own registered signature should match its mid-turn hint"
  # An idle cursor pane must NOT read busy.
  printf '%s\n' '  → Add a follow-up                                            Run Everything' \
    | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    && fail "an idle cursor pane must not match the busy regex"
  pass "cursor's busy signature is recognized by the tmux delivery guard"
}

test_cursor_launch_command
test_cursor_turn_end_hook
test_cursor_leaves_a_tracked_hook_file_alone
test_cursor_model_flag_but_no_effort_flag
test_cursor_refuses_secondmate
test_cursor_refuses_without_a_key
test_cursor_busy_signature_is_recognized

echo "# all fm-cursor-harness tests passed"
