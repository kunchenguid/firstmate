#!/usr/bin/env bash
# Behavior tests for the cursor (cursor-agent) and agy (Antigravity) harness
# adapters: launch-command threading, turn-end hook install/exclude/teardown,
# harness detection, tmux agent-liveness classification, busy signatures, and the
# horizontal-rule composer-box classification agy's "> " prompt needs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-agy-harness)

# --- spawn harness (fake tmux logs the -l launch command) -------------------

make_spawn_fakebin() {
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
  send-keys)
    prev=
    for a in "$@"; do
      [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "${FM_FAKE_SENDKEYS_LOG:-/dev/null}"
      prev=$a
    done
    exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> -> "case_dir|home|proj|wt|fakebin|id|launchlog"
make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="$name-x1"
  launchlog="$case_dir/launch.log"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id|$launchlog"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> <launchlog> <harness> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 launchlog=$6 harness=$7
  shift 7
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_SENDKEYS_LOG="$launchlog" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --harness "$harness" "$@" 2>&1
}

test_cursor_spawn_launch_and_stop_hook() {
  local rec case_dir home proj wt fakebin id launchlog out status excl
  rec=$(make_spawn_case cursor-spawn)
  IFS='|' read -r case_dir home proj wt fakebin id launchlog <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$launchlog" cursor --model gpt-5.6-sol-medium)
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"

  # Launch command threads --force and --model, and no separate effort flag.
  assert_grep 'cursor-agent --force' "$launchlog" "cursor launch missing autonomy flag"
  assert_grep "--model 'gpt-5.6-sol-medium'" "$launchlog" "cursor launch did not thread --model"
  assert_no_grep '--effort' "$launchlog" "cursor launch must not pass a separate --effort flag"
  assert_no_grep '--thinking' "$launchlog" "cursor launch must not pass --thinking"

  # Per-worktree stop hook installed, points at the turn-end file, and is excluded.
  assert_present "$wt/.cursor/hooks.json" "cursor stop hook was not installed"
  assert_grep '"stop"' "$wt/.cursor/hooks.json" "cursor hook is not a stop hook"
  assert_grep "$home/state/$id.turn-ended" "$wt/.cursor/hooks.json" "cursor hook does not touch the turn-end file"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_grep '.cursor/hooks.json' "$excl" "cursor hook was not git-excluded"
  pass "cursor spawn threads --force/--model and installs an excluded stop hook"
}

test_cursor_teardown_removes_hook() {
  local rec case_dir home proj wt fakebin id launchlog
  rec=$(make_spawn_case cursor-teardown)
  IFS='|' read -r case_dir home proj wt fakebin id launchlog <<EOF
$rec
EOF
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$launchlog" cursor >/dev/null 2>&1
  assert_present "$wt/.cursor/hooks.json" "cursor hook missing before teardown"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "cursor teardown failed"
  assert_absent "$wt/.cursor/hooks.json" "cursor hook survived teardown"
  pass "cursor teardown removes the stop hook"
}

test_agy_spawn_launch_and_no_hook() {
  local rec case_dir home proj wt fakebin id launchlog out status
  rec=$(make_spawn_case agy-spawn)
  IFS='|' read -r case_dir home proj wt fakebin id launchlog <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$launchlog" agy --model 'Gemini 3.1 Pro (High)')
  status=$?
  expect_code 0 "$status" "agy spawn should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  assert_grep 'agy --dangerously-skip-permissions' "$launchlog" "agy launch missing autonomy flag"
  assert_grep "--model 'Gemini 3.1 Pro (High)'" "$launchlog" "agy launch did not thread --model"
  # The launch string embeds the literal `-i "$(cat <brief>)"`; match it verbatim.
  # shellcheck disable=SC2016
  assert_grep '-i "$(cat' "$launchlog" "agy launch did not use interactive -i for the brief"
  assert_no_grep '--effort' "$launchlog" "agy launch must not pass --effort"

  # agy uses stale-pane detection, so no per-worktree turn-end hook file exists.
  assert_absent "$wt/.cursor/hooks.json" "agy must not install a cursor hook"
  assert_absent "$wt/.claude/settings.local.json" "agy must not install a claude hook"
  pass "agy spawn threads autonomy/-i/--model and installs no turn-end hook"
}

# --- harness detection ------------------------------------------------------

test_harness_detection_env_markers() {
  local out
  # Unset any earlier-precedence markers (this suite may run under a real harness).
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT CURSOR_AGENT=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 should detect cursor, got '$out'"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT ANTIGRAVITY_AGENT=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT=1 should detect agy, got '$out'"
  pass "fm-harness detects cursor and agy from their env markers"
}

# --- tmux agent-liveness ----------------------------------------------------

test_agent_alive_classifies_cursor_agy() {
  local fakebin verdict
  fakebin=$(fm_fakebin "$TMP_ROOT/alive-fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# pane_current_command comes from FM_FAKE_COMMAND.
printf '%s\n' "${FM_FAKE_COMMAND:-}"
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Load the tmux backend the supported way (fm_backend_source sets the lib dir
  # and pulls in fm-tmux-lib.sh / fm-composer-lib.sh transitively).
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMMAND=cursor-agent fm_backend_tmux_agent_alive fake:1)
  [ "$verdict" = alive ] || fail "cursor-agent should be alive, got '$verdict'"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMMAND=agy fm_backend_tmux_agent_alive fake:1)
  [ "$verdict" = alive ] || fail "agy should be alive, got '$verdict'"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMMAND=bash fm_backend_tmux_agent_alive fake:1)
  [ "$verdict" = dead ] || fail "bash should be dead, got '$verdict'"
  pass "tmux agent-liveness classifies cursor-agent/agy alive and bash dead"
}

# --- busy signatures --------------------------------------------------------

test_busy_regex_matches_cursor_agy() {
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  local re="$FM_TMUX_BUSY_REGEX_DEFAULT"
  printf '%s' ' → Add a follow-up            ctrl+c to stop' | grep -qiE "$re" \
    || fail "cursor busy footer 'ctrl+c to stop' not matched"
  printf '%s' 'esc to cancel                 Gemini 3.1 Pro (High)' | grep -qiE "$re" \
    || fail "agy busy footer 'esc to cancel' not matched"
  printf '%s' '  → Add a follow-up' | grep -qiE "$re" \
    && fail "cursor idle footer must not match busy regex"
  printf '%s' '? for shortcuts' | grep -qiE "$re" \
    && fail "agy idle footer must not match busy regex"
  pass "busy regex matches cursor/agy busy footers, not their idle footers"
}

# --- composer classification ------------------------------------------------

test_row_is_rule() {
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s' '────────────────────' | fm_tmux_row_is_rule || fail "a box-drawing rule row should be a rule"
  printf '%s' '  ▀▀▀▀▀▀▀▀▀▀  ' | fm_tmux_row_is_rule || fail "a block rule row should be a rule"
  printf '%s' '> some real text' | fm_tmux_row_is_rule && fail "a text row must not be a rule"
  printf '%s' '──── heading ────' | fm_tmux_row_is_rule && fail "a rule with embedded text must not be a pure rule"
  printf '%s' '' | fm_tmux_row_is_rule && fail "a blank row must not be a rule"
  pass "fm_tmux_row_is_rule recognizes pure horizontal-rule rows only"
}

# A fake tmux whose capture-pane returns a different row per -S value, so the
# 3-row composer read (content at cy, borders at cy-1/cy+1) can be exercised
# hermetically. Rows are supplied via FM_ROW_<n> env vars (n = the -S value).
make_composer_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *cursor_y*) printf '%s\n' "${FM_CURSOR_Y:-10}"; exit 0 ;;
esac
case "${1:-}" in
  capture-pane)
    s=
    prev=
    for a in "$@"; do [ "$prev" = "-S" ] && s=$a; prev=$a; done
    var="FM_ROW_$s"
    printf '%b\n' "${!var:-}"
    exit 0 ;;
  display-message) printf '0\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

test_composer_agy_box_is_empty() {
  local fakebin state rule glyph
  fakebin=$(fm_fakebin "$TMP_ROOT/composer-agy")
  make_composer_tmux "$fakebin"
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  rule='────────────────────'
  glyph='\033[38;5;111m>\033[39m'   # agy's 256-colour ">" prompt (not dim, not stripped)
  state=$(PATH="$fakebin:$PATH" \
    FM_CURSOR_Y=10 FM_ROW_10="$glyph" FM_ROW_9="$rule" FM_ROW_11="$rule" \
    fm_tmux_composer_state fake:1)
  [ "$state" = empty ] || fail "agy '> ' inside a rule box should read empty, got '$state'"
  pass "agy horizontal-rule composer box classifies as empty"
}

test_composer_bare_prompt_without_rules_is_unknown() {
  local fakebin state glyph
  fakebin=$(fm_fakebin "$TMP_ROOT/composer-bare")
  make_composer_tmux "$fakebin"
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  glyph='\033[38;5;111m>\033[39m'
  # No rule rows around the glyph: a real dead-shell prompt, must stay unknown.
  state=$(PATH="$fakebin:$PATH" \
    FM_CURSOR_Y=10 FM_ROW_10="$glyph" FM_ROW_9="some command output" FM_ROW_11="" \
    fm_tmux_composer_state fake:1)
  [ "$state" = unknown ] || fail "a bare '>' not flanked by rules must read unknown, got '$state'"
  pass "a bare prompt glyph without rule borders stays unknown (dead-shell safety)"
}

test_cursor_spawn_launch_and_stop_hook
test_cursor_teardown_removes_hook
test_agy_spawn_launch_and_no_hook
test_harness_detection_env_markers
test_agent_alive_classifies_cursor_agy
test_busy_regex_matches_cursor_agy
test_row_is_rule
test_composer_agy_box_is_empty
test_composer_bare_prompt_without_rules_is_unknown
