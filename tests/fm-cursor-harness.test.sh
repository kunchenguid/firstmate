#!/usr/bin/env bash
# Behavior tests for the verified Cursor Agent CLI (cursor-agent) adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SUPERVISION="$ROOT/bin/fm-supervision-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# --- deterministic contract tests ------------------------------------------

test_cursor_launch_template_is_pinned() {
  grep -Fq "    cursor) printf '%s' 'cursor-agent --force --trust __MODELFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;" "$SPAWN" \
    || fail "cursor launch template changed or missing"
  # cursor carries --model but no effort flag (effort is encoded in the model slug).
  grep -Eq 'claude\|codex\|opencode\|pi\|pi-signed\|grok\|kimi\|cursor\)' "$SPAWN" \
    || fail "cursor missing from model_flag_for_harness"
  if awk '/^effort_flag_for_harness\(\)/{f=1;next} f&&/^}/{f=0} f&&/cursor\)/{print "FOUND"}' "$SPAWN" | grep -q FOUND; then
    fail "cursor must NOT appear as an effort_flag_for_harness case (no --effort flag)"
  fi
  pass "fm-spawn: cursor launch template pinned, model flag present, no effort flag"
}

test_cursor_detection_marker_and_ancestry() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  # The CURSOR_AGENT marker resolves to cursor before ancestry.
  out=$(env -u CLAUDECODE -u CODEX_THREAD_ID -u PI_CODING_AGENT -u GROK_AGENT \
    CURSOR_AGENT=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "CURSOR_AGENT marker did not resolve to cursor, got '$out'"
  # A verified env marker still wins over cursor ancestry precedence.
  out=$(CLAUDECODE=1 CURSOR_AGENT=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  # Markerless cursor-agent is detected by process ancestry command name.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= ; pid= ; prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '/opt/cursor/bin/cursor-agent\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u CODEX_THREAD_ID -u CURSOR_AGENT -u CURSOR_AGENT_SESSION_ID \
    -u CURSOR_CONVERSATION_ID -u CURSOR_TRACE_ID -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "markerless cursor-agent ancestry detection returned '$out'"
  pass "fm-harness: cursor detected by marker and by cursor-agent ancestry, marker precedence preserved"
}

test_cursor_session_lock_identity() {
  local home out
  # Marker identity: CURSOR_CONVERSATION_ID gives a stable holder even without ancestry.
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$ROOT/bin/fm-session-lock-lib.sh"
  case "$FM_HARNESS_RE" in
    *cursor-agent*) : ;;
    *) fail "FM_HARNESS_RE does not include cursor-agent" ;;
  esac
  out=$(CURSOR_CONVERSATION_ID=c8822d4c fm_harness_marker_identity)
  [ "$out" = "cursor:c8822d4c" ] || fail "cursor marker identity wrong, got '$out'"

  # Ancestry: a cursor-agent process is recognized as a live lock holder.
  home="$TMP_ROOT/session-lock-home"
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/cursor/bin/cursor-agent'; exit 0 ;;
  *"args="*) printf '%s\n' 'cursor-agent'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from cursor-agent ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the cursor-agent ancestor pid" ;;
  esac
  pass "session-lock: cursor-agent ancestry and CURSOR_CONVERSATION_ID marker identity are recognized"
}

test_cursor_busy_signature_is_scoped() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  tmux() { case "${1:-}" in capture-pane) cat "$capture" ;; *) return 0 ;; esac; }
  printf '  \xe2\xa0\xa0\xe2\xa0\x9b Working\n  \xe2\x86\x92 Plan, search, build anything\n' > "$capture"
  fm_pane_is_busy fake cursor || fail "cursor busy spinner frame was not recognized as busy"
  printf '  \xe2\x86\x92 Plan, search, build anything\n  GPT-5.6 Sol 272K Low   Run Everything\n' > "$capture"
  if fm_pane_is_busy fake cursor; then fail "cursor idle frame was misread as busy"; fi
  printf 'I am Working on the fix and it is going well\n' > "$capture"
  if fm_pane_is_busy fake cursor; then fail "ordinary prose containing Working was misread as busy"; fi
  printf '  \xe2\xa0\xa0\xe2\xa0\x9b Working\n' > "$capture"
  if fm_pane_is_busy fake codex; then fail "cursor busy signature leaked into another harness"; fi
  printf 'esc to interrupt\n' > "$capture"
  if fm_pane_is_busy fake cursor; then fail "another harness busy token leaked into cursor"; fi
  pass "busy detection: cursor Working-spinner requires its harness while idle and prose stay idle"
}

test_cursor_supervision_protocol_renders() {
  local out
  out=$("$SUPERVISION" --harness cursor 2>&1)
  assert_contains "$out" "primary harness: cursor" "supervision block header wrong for cursor"
  assert_contains "$out" "Cursor foreground checkpoint" "cursor supervision mode line missing"
  # shellcheck disable=SC2016  # literal rendered checkpoint command, not shell expansion
  assert_contains "$out" 'bin/fm-watch-checkpoint.sh --seconds "${FM_CURSOR_WATCH_CHECKPOINT:-180}"' \
    "cursor checkpoint command missing"
  assert_contains "$out" "bin/fm-guard.sh" "cursor fail-open backstop not documented in the block"
  out=$("$SUPERVISION" --harness cursor --repair-line 2>&1)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 180" "cursor repair line missing checkpoint"
  pass "supervision: cursor renders the bounded foreground checkpoint protocol and repair line"
}

# --- spawn + teardown integration ------------------------------------------

make_cursor_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '3\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|select-window|set-option|rename-window) exit 0 ;;
  send-keys)
    prev= ; literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    [ -z "$literal" ] || printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
    exit 0
    ;;
  capture-pane) printf '  \xe2\x86\x92 Plan, search, build anything\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh cursor-agent
  printf '%s\n' "$fakebin"
}

make_cursor_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_cursor_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for cursor\n' > "$home/data/$id/brief.md"
  printf 'cursor\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_cursor_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness cursor "$@" 2>&1
}

read_cursor_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_cursor_teardown() {
  local home=$1 fakebin=$2 id=$3
  HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" "$id" --force
}

test_cursor_spawn_writes_turnend_hook_and_meta() {
  local id rec out rc meta launch excl
  id=cursor-spawn-a1
  rec=$(make_cursor_case spawn "$id")
  read_cursor_record "$rec"
  out=$(run_cursor_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -eq 0 ] || fail "cursor spawn failed ($rc): $out"
  meta="$HOME_DIR/state/$id.meta"
  grep -qx 'harness=cursor' "$meta" || fail "meta did not record harness=cursor"
  grep -qx 'kind=ship' "$meta" || fail "meta did not record kind=ship"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "cursor-agent --force --trust" "launch command did not include cursor autonomy flags"
  [ -f "$WT_DIR/.cursor/hooks.json" ] || fail "cursor turn-end hooks.json was not written"
  [ -x "$WT_DIR/.cursor/fm-turn-end.sh" ] || fail "cursor turn-end script missing or not executable"
  grep -qF '.cursor/fm-turn-end.sh' "$WT_DIR/.cursor/hooks.json" \
    || fail "hooks.json stop command does not reference the turn-end script"
  grep -qE "touch '.*/state/$id\.turn-ended'" "$WT_DIR/.cursor/fm-turn-end.sh" \
    || fail "turn-end script does not touch the task turn-ended marker"
  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  grep -qxF '.cursor/hooks.json' "$excl" || fail ".cursor/hooks.json was not git-excluded"
  grep -qxF '.cursor/fm-turn-end.sh' "$excl" || fail ".cursor/fm-turn-end.sh was not git-excluded"
  pass "fm-spawn: cursor worker launches with autonomy flags, records harness=cursor, installs an excluded turn-end hook"
}

test_cursor_teardown_removes_our_hook() {
  local id rec out rc
  id=cursor-teardown-b2
  rec=$(make_cursor_case teardown "$id")
  read_cursor_record "$rec"
  out=$(run_cursor_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -eq 0 ] || fail "cursor spawn failed before teardown: $out"
  [ -f "$WT_DIR/.cursor/hooks.json" ] || fail "precondition: hooks.json should exist after spawn"
  run_cursor_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$id" >/dev/null 2>&1 || fail "cursor teardown failed"
  assert_absent "$WT_DIR/.cursor/hooks.json" "our cursor hooks.json survived teardown"
  assert_absent "$WT_DIR/.cursor/fm-turn-end.sh" "cursor turn-end script survived teardown"
  pass "fm-teardown: the firstmate cursor turn-end hook is removed from a pooled worktree"
}

test_cursor_spawn_and_teardown_preserve_foreign_hook() {
  local id rec out rc foreign
  id=cursor-foreign-c3
  rec=$(make_cursor_case foreign "$id")
  read_cursor_record "$rec"
  mkdir -p "$WT_DIR/.cursor"
  printf '{"version":1,"hooks":{"stop":[{"command":"project-owned.sh"}]}}\n' > "$WT_DIR/.cursor/hooks.json"
  foreign=$(cat "$WT_DIR/.cursor/hooks.json")
  out=$(run_cursor_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -eq 0 ] || fail "cursor spawn failed with a pre-existing hook: $out"
  assert_contains "$out" "already has .cursor/hooks.json" "spawn did not warn about the pre-existing hook"
  [ "$(cat "$WT_DIR/.cursor/hooks.json")" = "$foreign" ] || fail "spawn overwrote a pre-existing .cursor/hooks.json"
  [ ! -e "$WT_DIR/.cursor/fm-turn-end.sh" ] || fail "spawn wrote its script despite a pre-existing hook"
  run_cursor_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$id" >/dev/null 2>&1 || fail "cursor teardown failed"
  [ "$(cat "$WT_DIR/.cursor/hooks.json")" = "$foreign" ] || fail "teardown removed a project-owned .cursor/hooks.json"
  pass "cursor: a pre-existing project .cursor/hooks.json is never overwritten by spawn or removed by teardown"
}

test_cursor_launch_template_is_pinned
test_cursor_detection_marker_and_ancestry
test_cursor_session_lock_identity
test_cursor_busy_signature_is_scoped
test_cursor_supervision_protocol_renders
test_cursor_spawn_writes_turnend_hook_and_meta
test_cursor_teardown_removes_our_hook
test_cursor_spawn_and_teardown_preserve_foreign_hook
