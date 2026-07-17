#!/usr/bin/env bash
# Behavior tests for the kimi harness's post-launch brief injection: kimi has
# no positional/stdin initial-prompt injection that keeps its interactive
# session alive (see .agents/skills/harness-adapters/SKILL.md), so fm-spawn.sh
# starts it bare and types the brief into the composer once it reports ready.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)

# make_kimi_fakebin: a fake tmux that logs every invocation (one line per call,
# space-joined args) to <dir>/calls.log, answers #{pane_current_path} with
# FM_FAKE_PANE_PATH (ends the treehouse-get wait immediately, matching the
# grok/pi harness tests' pattern), and answers the composer-state pair
# (#{cursor_y} + capture-pane -e -S -E on that row) as an always-empty
# composer, so fm_tmux_composer_state reads "empty" both before typing and
# right after the injected Enter, needing no retry.
make_kimi_fakebin() {
  local dir=$1 fakebin log
  fakebin=$(fm_fakebin "$dir")
  log="$dir/calls.log"
  : > "$log"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '7\n'; exit 0 ;;
  *"capture-pane -e"*"-S 7 -E 7"*) printf '\n'; exit 0 ;;
  *"capture-pane"*) printf '\n'; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_kimi_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_kimi_fakebin "$case_dir/fake")
  id="kimi-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'KIMI_TEST_BRIEF_CONTENT_MARKER\nsecond line of the brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_kimi_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" kimi 2>&1
}

test_kimi_spawn_injects_brief_after_bare_launch() {
  local rec case_dir home proj wt fakebin id out status log launch_line brief_line
  rec=$(make_kimi_case inject)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin")
  status=$?
  expect_code 0 "$status" "kimi spawn should succeed"
  assert_contains "$out" "spawned $id harness=kimi" "kimi spawn did not report success"

  log="$(dirname "$fakebin")/calls.log"
  assert_present "$log" "fake tmux call log was not written"

  launch_line=$(grep -n -- "send-keys.*-l.*kimi --yolo --afk" "$log" | head -1 | cut -d: -f1)
  [ -n "$launch_line" ] || fail "kimi launch command was never typed into the pane"$'\n'"--- log ---"$'\n'"$(cat "$log")"

  brief_line=$(grep -n -- "send-keys.*-l.*KIMI_TEST_BRIEF_CONTENT_MARKER" "$log" | head -1 | cut -d: -f1)
  [ -n "$brief_line" ] || fail "kimi brief was never typed into the composer as the first message"$'\n'"--- log ---"$'\n'"$(cat "$log")"

  [ "$brief_line" -gt "$launch_line" ] \
    || fail "kimi brief was typed before (or same call as) the launch command, not after it started (launch=$launch_line brief=$brief_line)"

  assert_no_grep '__BRIEF__' "$log" "an unsubstituted __BRIEF__ placeholder reached the pane"
  pass "kimi spawn starts bare then injects the brief into the composer as the first message"
}

test_kimi_launch_has_no_positional_brief() {
  local rec case_dir home proj wt fakebin id out status log brief_call
  rec=$(make_kimi_case no-positional)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin")
  expect_code 0 $? "kimi spawn should succeed"
  log="$(dirname "$fakebin")/calls.log"

  # The LAUNCH line itself (the one containing "kimi --yolo --afk") must not
  # also carry the brief content on the same tmux call: kimi's launch command
  # never embeds the brief (unlike claude/grok/pi's "$(cat __BRIEF__)"
  # positional pattern), because -p/stdin injection exits the process instead
  # of leaving it interactive (see the harness-adapters skill).
  brief_call=$(grep -F 'KIMI_TEST_BRIEF_CONTENT_MARKER' "$log" || true)
  [ -n "$brief_call" ] || fail "brief injection call not found in log"$'\n'"--- log ---"$'\n'"$(cat "$log")"
  case "$brief_call" in
    *'kimi --yolo --afk'*) fail "the launch command and the brief injection landed in the same tmux call: $brief_call" ;;
  esac
  pass "kimi's launch command and its brief injection are two distinct tmux calls"
}

test_kimi_spawn_injects_brief_after_bare_launch
test_kimi_launch_has_no_positional_brief
