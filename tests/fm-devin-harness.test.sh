#!/usr/bin/env bash
# Tests for Devin harness detection, launch wiring, hooks, and lock liveness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-devin-harness.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
SPAWN="$ROOT/bin/fm-spawn.sh"

test_detection_marker() {
  local out
  out=$(DEVIN_CLI=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = devin ] || fail "DEVIN_CLI marker resolved '$out', expected devin"
  out=$(DEVIN_CLI=1 CLAUDECODE=1 PI_CODING_AGENT=true "$ROOT/bin/fm-harness.sh")
  [ "$out" = devin ] || fail "DEVIN_CLI marker lost precedence to inherited harness markers: $out"
  pass "fm-harness detects the verified Devin launch marker"
}

test_primary_hook_wiring() {
  local config session pre stop matcher
  config="$ROOT/.devin/config.json"
  [ -f "$config" ] || fail "tracked .devin/config.json is missing"
  jq -e '.read_config_from.claude == false' "$config" >/dev/null \
    || fail "tracked Devin config does not disable Claude compatibility import"
  session=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$config")
  assert_contains "$session" 'fm-sessionstart-nudge.sh' "Devin SessionStart hook omitted session-start nudge"
  assert_contains "$session" 'DEVIN_PROJECT_DIR' "Devin SessionStart hook omitted the native project root"
  assert_contains "$session" 'git rev-parse --show-toplevel' "Devin SessionStart hook omitted the Git-root fallback"
  assert_contains "$session" 'add_context' "Devin SessionStart hook does not return Devin context JSON"
  [ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("fm-sessionstart-nudge.sh"))] | length' "$config")" -eq 1 ] \
    || fail "tracked Devin config does not have exactly one SessionStart owner"
  matcher=$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$config")
  [ "$matcher" = exec ] || fail "Devin PreToolUse matcher is '$matcher', expected exec"
  pre=$(jq -r '.hooks.PreToolUse[0].hooks[].command' "$config")
  assert_contains "$pre" 'fm-arm-pretool-check.sh' "Devin hook omitted watcher-arm checker"
  assert_contains "$pre" 'fm-cd-pretool-check.sh' "Devin hook omitted cd checker"
  assert_contains "$pre" '--claude' "Devin hook did not select stderr-only deny output"
  stop=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$config")
  assert_contains "$stop" 'DEVIN_PROJECT_DIR' "Devin Stop hook omitted the native project root"
  assert_contains "$stop" 'git rev-parse --show-toplevel' "Devin Stop hook omitted the Git-root fallback"
  assert_contains "$stop" 'fm-turnend-guard.sh' "Devin Stop hook omitted shared guard"
  [ "$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("fm-turnend-guard.sh"))] | length' "$config")" -eq 1 ] \
    || fail "tracked Devin config does not have exactly one Devin Stop owner"
  pass "tracked Devin config owns exactly one Stop hook and disables Claude import"
}

test_primary_pretool_hook_blocks() {
  local config command payload out err rc
  config="$ROOT/.devin/config.json"
  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$config")
  payload="$TMP_ROOT/devin-pretool.json"
  out="$TMP_ROOT/devin-pretool.out"
  err="$TMP_ROOT/devin-pretool.err"
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"bin/fm-watch-arm.sh &"}}' > "$payload"
  (trap - EXIT; cd "$ROOT" && bash -c "$command") < "$payload" >"$out" 2>"$err"
  rc=$?
  expect_code 2 "$rc" "Devin tracked PreToolUse adapter must preserve checker denial"
  [ ! -s "$out" ] || fail "Devin deny must keep stdout empty: $(cat "$out")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("[watcher-background]"))' "$err" >/dev/null \
    || fail "Devin deny did not preserve the stable checker response: $(cat "$err")"
  pass "tracked Devin PreToolUse adapter blocks unsafe watcher commands with stderr-only output"
}

test_launch_templates_preserve_workspace_trust() {
  local source
  source=$(cat "$SPAWN")
  [ "$(printf '%s' "$source" | grep -o -- '--respect-workspace-trust true' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "Devin ordinary and secondmate launch templates do not both preserve workspace trust"
  assert_not_contains "$source" '--respect-workspace-trust false' "a Devin launch template still bypasses workspace trust"
  pass "ordinary and secondmate Devin launches preserve once-per-worktree trust"
}

test_primary_hooks_anchor_from_nested_cwd() {
  local fixture nested command script marker mode
  fixture="$TMP_ROOT/root with spaces"
  nested="$fixture/nested/cwd"
  marker="$fixture/hook-invocations"
  mkdir -p "$fixture/.devin" "$fixture/bin" "$nested"
  cp "$ROOT/.devin/config.json" "$fixture/.devin/config.json"
  git -C "$fixture" init -q
  for script in fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-turnend-guard.sh fm-sessionstart-nudge.sh; do
    # shellcheck disable=SC2016  # fixture script expands these values when its hook runs
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$(basename "$0")" >> "$FM_DEVIN_HOOK_MARKER"' '[ "$(basename "$0")" = fm-sessionstart-nudge.sh ] && printf "%s\n" "FIRSTMATE_OP: v1 session-start: probe"' > "$fixture/bin/$script"
    chmod +x "$fixture/bin/$script"
  done
  for mode in env fallback; do
    : > "$marker"
    while IFS= read -r command; do
      if [ "$mode" = env ]; then
        out=$(trap - EXIT; cd "$nested" && DEVIN_PROJECT_DIR="$fixture" FM_DEVIN_HOOK_MARKER="$marker" bash -c "$command")
      else
        out=$(trap - EXIT; cd "$nested" && DEVIN_PROJECT_DIR='' FM_DEVIN_HOOK_MARKER="$marker" bash -c "$command")
      fi
      case "$command" in
        *fm-sessionstart-nudge.sh*)
          jq -e '.add_context == "FIRSTMATE_OP: v1 session-start: probe"' <<<"$out" >/dev/null \
            || fail "Devin $mode SessionStart hook did not return add_context JSON: $out" ;;
      esac
    done < <(jq -r '.hooks.SessionStart[].hooks[].command, .hooks.PreToolUse[].hooks[].command, .hooks.Stop[].hooks[].command' "$fixture/.devin/config.json")
    [ "$(wc -l < "$marker" | tr -d ' ')" -eq 4 ] \
      || fail "Devin $mode root resolution did not invoke all four hooks from a nested cwd: $(cat "$marker")"
  done
  pass "all Devin hooks resolve quoted project roots from nested working directories"
}

test_spawn_control_character_state_path() {
  local d home proj wt state fakebin id log out config
  d="$TMP_ROOT/control-path"
  home="$d/home"
  proj="$d/project"
  wt="$d/wt"
  state="$d/state"$'\n'"control"
  id=devin-control-x1
  log="$d/tmux.log"
  fakebin=$(fm_fakebin "$d/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/config" "$state"
  state=$(cd "$state" && pwd -P)
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|send-keys|set-buffer|paste-buffer|delete-buffer|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  out=$(XDG_CONFIG_HOME="$d/xdg" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LOG="$log" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" \
    --harness devin 2>&1)
  assert_contains "$out" "spawned $id harness=devin" "Devin spawn with a control-character state path did not succeed"
  config="$state/$id.devin-config.json"
  jq -e --arg state "$state" \
    '[.hooks.Stop[].hooks[] | select(.command | contains($state))] | length == 1' "$config" >/dev/null \
    || fail "Devin config did not preserve a control-character state path as valid JSON: $(cat "$config")"
  pass "Devin config JSON-escapes control characters in state paths"
}

test_spawn_launch_and_turnend_config() {
  local d home proj wt fakebin id out log config project_config user_config user_config_before task_command config_mode
  d="$TMP_ROOT/spawn"
  home="$d/home"
  proj="$d/project"
  wt="$d/wt"
  id=devin-spawn-x1
  log="$d/tmux.log"
  fakebin=$(fm_fakebin "$d/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  home=$(cd "$home" && pwd -P)
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  project_config="$wt/.devin/config.json"
  mkdir -p "$(dirname "$project_config")"
  printf '%s\n' '{"version":1,"model":"repo-model","hooks":{"PreToolUse":[{"matcher":"exec","hooks":[{"type":"command","command":"repo-safety-hook"}]}],"Stop":[{"hooks":[{"type":"command","command":"repo-stop-hook"}]}]}}' > "$project_config"
  user_config="$d/xdg/devin/config.json"
  user_config_before="$d/user-config.before.jsonc"
  mkdir -p "$(dirname "$user_config")"
  task_command="touch '$home/state/$id.turn-ended'"
  printf '%s\n' \
    '{' \
    '  // Devin documents line comments in user configuration.' \
    '  "version": 1,' \
    '  "theme_mode": "dark",' \
    '  "literal": "keep // and /* comment-like */ text",' \
    '  "read_config_from": {"claude": true},' \
    '  /* Block comments and trailing commas are accepted JSONC syntax. */' \
    '  "hooks": {' \
    '    "PreToolUse": [{"matcher":"exec","hooks":[{"type":"command","command":"user-safety-hook"},],},],' \
    "    \"Stop\": [{\"hooks\":[{\"type\":\"command\",\"command\":\"user-stop-hook\"},],},{\"hooks\":[{\"type\":\"command\",\"command\":\"$task_command\"},],},]," \
    '  },' \
    '}' > "$user_config"
  cp "$user_config" "$user_config_before"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|send-keys|set-buffer|paste-buffer|delete-buffer|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 97
SH
  chmod +x "$fakebin/jq"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  out=$(XDG_CONFIG_HOME="$d/xdg" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LOG="$log" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" \
    --harness devin --model swe-1.6 2>&1)
  assert_contains "$out" "spawned $id harness=devin" "Devin spawn did not succeed"
  assert_grep 'DEVIN_CLI=1 devin' "$log" "Devin launch marker/command missing"
  assert_grep '--permission-mode dangerous' "$log" "Devin launch is not autonomous"
  assert_grep '--respect-workspace-trust true' "$log" "Devin launch bypassed workspace trust"
  assert_not_contains "$(cat "$log")" '--respect-workspace-trust false' "Devin launch explicitly disabled workspace trust"
  assert_grep "--model 'swe-1.6'" "$log" "Devin model flag missing"
  assert_grep '--prompt-file' "$log" "Devin prompt-file launch missing"
  config="$home/state/$id.devin-config.json"
  [ -f "$config" ] || fail "Devin per-task config was not created"
  if [ "$(uname)" = Darwin ]; then config_mode=$(stat -f '%Lp' "$config"); else config_mode=$(stat -c '%a' "$config"); fi
  [ "$config_mode" = 600 ] || fail "Devin per-task config permissions are not 0600"
  jq -e '.theme_mode == "dark"
    and .literal == "keep // and /* comment-like */ text"
    and .read_config_from.claude == false
    and .hooks.PreToolUse[0].matcher == "exec"
    and .hooks.PreToolUse[0].hooks[0].command == "user-safety-hook"
    and .hooks.Stop[0].hooks[0].command == "user-stop-hook"
    and ([.hooks.Stop[].hooks[] | select(.command | contains(".turn-ended"))] | length == 1)
    and (has("model") | not)' "$config" >/dev/null \
    || fail "Devin task config did not preserve only user settings and the task hook: $(cat "$config")"
  jq -e '.model == "repo-model" and (.hooks.Stop | length == 1)' "$project_config" >/dev/null \
    || fail "spawn modified the project-local Devin config: $(cat "$project_config")"
  cmp -s "$user_config_before" "$user_config" \
    || fail "spawn modified the JSONC user-level Devin config"
  pass "fm-spawn composes JSONC user config with one task hook and preserves native project config"
}

test_invalid_user_config_remains_recoverable() {
  local name contents expected d home proj wt fakebin id out rc log config
  for name in malformed unterminated-comment root-null root-array import-null import-array hooks-null hooks-array stop-null stop-shape; do
    case "$name" in
      malformed) contents='{"hooks":' ; expected='Unexpected end of JSON input' ;;
      unterminated-comment) contents='{"version":1, /* unfinished' ; expected='unterminated block comment' ;;
      root-null) contents='null' ; expected='config root must be an object' ;;
      root-array) contents='[]' ; expected='config root must be an object' ;;
      import-null) contents='{"read_config_from":null}' ; expected='read_config_from must be an object' ;;
      import-array) contents='{"read_config_from":[]}' ; expected='read_config_from must be an object' ;;
      hooks-null) contents='{"hooks":null}' ; expected='hooks must be an object' ;;
      hooks-array) contents='{"hooks":[]}' ; expected='hooks must be an object' ;;
      stop-null) contents='{"hooks":{"Stop":null}}' ; expected='hooks.Stop must be an array' ;;
      stop-shape) contents='{"hooks":{"Stop":{}}}' ; expected='hooks.Stop must be an array' ;;
    esac
    d="$TMP_ROOT/$name"
    home="$d/home"
    proj="$d/project"
    wt="$d/wt"
    id="devin-$name-x1"
    log="$d/tmux.log"
    fakebin=$(fm_fakebin "$d/fake")
    mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
    printf 'brief\n' > "$home/data/$id/brief.md"
    fm_git_worktree "$proj" "$wt" "fm/$id"
    config="$d/xdg/devin/config.json"
    mkdir -p "$(dirname "$config")"
    printf '%s\n' "$contents" > "$config"
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|send-keys|set-buffer|paste-buffer|delete-buffer|kill-window) exit 0 ;;
esac
exit 0
SH
    chmod +x "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" treehouse gh-axi gh
    out=$(XDG_CONFIG_HOME="$d/xdg" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LOG="$log" \
      TMUX='fake,1,0' PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" \
      --harness devin 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "$name Devin config unexpectedly spawned"
    assert_contains "$out" "error: invalid Devin config at $config: $expected" "$name diagnostic was not actionable"
    [ -f "$home/state/$id.meta" ] || fail "$name failure did not persist recoverable task metadata"
    grep '^worktree=/' "$home/state/$id.meta" >/dev/null || fail "$name metadata omitted the isolated worktree"
  done
  pass "invalid Devin user configs leave endpoints and worktrees recoverable"
}

test_lock_recognizes_devin_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/devin/bin/devin'; exit 0 ;;
  *"args="*) printf '%s\n' 'devin'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize Devin"
  pass "fm-lock recognizes Devin harness processes"
}

test_lock_rejects_unrelated_devin_argv() {
  local home fakebin out
  home="$TMP_ROOT/unrelated-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/unrelated-lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /srv/worker.js --cache /tmp/devin-state'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale" "fm-lock treated an unrelated Devin argv substring as a harness"
  pass "fm-lock rejects unrelated argv containing Devin"
}

test_lock_recognizes_devin_interpreter_script() {
  local home fakebin out
  home="$TMP_ROOT/interpreter-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/interpreter-lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /opt/devin/lib/devin'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize an interpreter-launched Devin script"
  pass "fm-lock recognizes Devin interpreter scripts"
}

test_busy_signature_is_scoped_to_devin() {
  source "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s\n' 'Working (3s - esc to interrupt)' | fm_busy_lines_match devin \
    || fail "Devin busy signature was not recognized"
  if printf '%s\n' 'Working...' | fm_busy_lines_match devin; then
    fail "Devin borrowed Pi's busy signature"
  fi
  pass "Devin busy detection uses its verified signature"
}

test_detection_marker
test_primary_hook_wiring
test_primary_pretool_hook_blocks
test_launch_templates_preserve_workspace_trust
test_primary_hooks_anchor_from_nested_cwd
test_spawn_launch_and_turnend_config
test_spawn_control_character_state_path
test_invalid_user_config_remains_recoverable
test_lock_recognizes_devin_holder
test_lock_rejects_unrelated_devin_argv
test_lock_recognizes_devin_interpreter_script
test_busy_signature_is_scoped_to_devin
