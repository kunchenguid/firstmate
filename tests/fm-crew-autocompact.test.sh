#!/usr/bin/env bash
# tests/fm-crew-autocompact.test.sh - config/crew-autocompact-pct: the local,
# gitignored knob that sets Claude's real CLAUDE_AUTOCOMPACT_PCT_OVERRIDE env var
# as a per-launch prefix on bin/fm-spawn.sh's claude launch template.
#
# Under test:
#   - Absent: the launch command is byte-identical to before this knob existed
#     (no CLAUDE_AUTOCOMPACT_PCT_OVERRIDE prefix).
#   - A valid value (1-99) prefixes a claude crewmate launch and a claude scout
#     launch, but never a claude secondmate launch (a secondmate is a firstmate
#     peer and keeps Claude's default threshold) and never a non-claude harness.
#   - Malformed or out-of-range values refuse the spawn with an actionable error
#     naming the file and the accepted range, rather than launching with the
#     value silently dropped or passed through unvalidated.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-autocompact)

write_ship_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise the crew auto-compaction threshold knob for $2.

## Firstmate spec
Verify the spawned process receives the expected launch environment.
EOF
}

# Fake tmux: answers the pane-path query and logs every literal `send-keys -l`
# payload (the GOTMPDIR export and the launch command) one per line, in send
# order, into FM_FAKE_LAUNCH_LOG. Modeled on tests/fm-trace-context-spawn.test.sh.
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
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

# make_spawn_case <name> <harness>: a ship-ready home/project/worktree with
# config/crew-harness set to <harness>. config/crew-autocompact-pct is left for
# the caller to write (or not) directly under the returned home.
make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  write_ship_brief "$home/data/$id/brief.md" "$id"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

# run_spawn <home> <wt> <fakebin> <launchlog> <id> <proj> [extra fm-spawn.sh args...]
# A claude spawn pre-registers workspace trust in the launching user's own store
# (bin/fm-claude-trust.sh), so it runs against a throwaway HOME to avoid writing
# the developer's real ~/.claude.json. Ship-only: appends --mode/--yolo, which a
# scout spawn refuses.
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  run_spawn_raw "$home" "$wt" "$fakebin" "$launchlog" "$@" --mode no-mistakes --yolo off
}

# run_spawn_raw: same as run_spawn but appends nothing, so scout/secondmate
# spawns (which refuse --mode/--yolo) can pass their own flags.
run_spawn_raw() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  mkdir -p "$home/user-home"
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

launch_line() {  # <log> <needle-fragment>
  grep -m1 "$2" "$1" 2>/dev/null || true
}

# ===========================================================================
# Absent: byte-identical to today.
# ===========================================================================
test_absent_file_leaves_launch_unchanged() {
  local rec out status ll
  rec=$(make_spawn_case absent-ship claude)
  read_case_record "$rec"
  # No config/crew-autocompact-pct written.

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "absent-knob spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "absent-knob spawn should report success"

  ll=$(launch_line "$LAUNCH_LOG" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION')
  [ -n "$ll" ] || fail "expected the claude launch line in the log"
  assert_not_contains "$ll" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" \
    "absent config/crew-autocompact-pct must not add an env prefix"
  assert_contains "$ll" \
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions' \
    "absent-knob launch line changed shape unexpectedly"
  pass "absent config/crew-autocompact-pct leaves the claude launch command unchanged"
}

# ===========================================================================
# Valid value: crewmate (ship) and scout launches carry the prefix.
# ===========================================================================
test_valid_value_prefixes_claude_crewmate_launch() {
  local rec out status ll
  rec=$(make_spawn_case valid-ship claude)
  read_case_record "$rec"
  printf '60\n' > "$HOME_DIR/config/crew-autocompact-pct"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "valid-knob crewmate spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "valid-knob crewmate spawn should report success"

  ll=$(launch_line "$LAUNCH_LOG" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION')
  assert_contains "$ll" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60" \
    "a claude crewmate launch must carry the resolved threshold"
  pass "config/crew-autocompact-pct=60 prefixes a claude crewmate launch with CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60"
}

test_valid_value_prefixes_claude_scout_launch() {
  local rec out status ll
  rec=$(make_spawn_case valid-scout claude)
  read_case_record "$rec"
  printf '60\n' > "$HOME_DIR/config/crew-autocompact-pct"

  out=$(run_spawn_raw "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "valid-knob scout spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "valid-knob scout spawn should report success"
  assert_contains "$out" "kind=scout" "the spawn must actually be a scout"

  ll=$(launch_line "$LAUNCH_LOG" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION')
  assert_contains "$ll" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60" \
    "a claude scout launch must carry the resolved threshold"
  pass "config/crew-autocompact-pct=60 prefixes a claude scout launch with CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60"
}

# ===========================================================================
# Secondmate unaffected: a secondmate is a firstmate peer and keeps the default
# threshold even when the primary's config/crew-autocompact-pct is set.
# ===========================================================================
make_seeded_secondmate_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

test_secondmate_launch_never_gets_the_prefix() {
  local w prim sm id fakebin launchlog out status ll
  w="$TMP_ROOT/secondmate-unaffected"
  prim="$w/primary"
  sm="$w/sm"
  id=sm-noautocompact
  launchlog="$w/launch.log"
  mkdir -p "$prim/config" "$prim/data/$id" "$prim/state" "$prim/projects"
  printf '60\n' > "$prim/config/crew-autocompact-pct"
  printf 'charter brief\n' > "$prim/data/$id/brief.md"
  touch "$prim/state/.last-watcher-beat"
  make_seeded_secondmate_home "$sm" "$id"
  fakebin=$(make_spawn_fakebin "$w/fake")
  : > "$launchlog"

  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$prim" \
    FM_STATE_OVERRIDE="$prim/state" FM_DATA_OVERRIDE="$prim/data" \
    FM_PROJECTS_OVERRIDE="$prim/projects" FM_CONFIG_OVERRIDE="$prim/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$sm" claude --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed"
  assert_contains "$out" "spawned $id" "secondmate spawn should report success"
  assert_contains "$out" "kind=secondmate" "the spawn must actually be a secondmate"

  ll=$(launch_line "$launchlog" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION')
  [ -n "$ll" ] || fail "expected the claude launch line in the secondmate log"
  assert_not_contains "$ll" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" \
    "a claude secondmate must keep Claude's default auto-compaction threshold"
  pass "a claude secondmate launch never carries CLAUDE_AUTOCOMPACT_PCT_OVERRIDE even when the primary's config/crew-autocompact-pct is set"
}

# ===========================================================================
# Non-claude harness unaffected.
# ===========================================================================
test_non_claude_harness_never_gets_the_prefix() {
  local rec out status ll
  rec=$(make_spawn_case valid-codex codex)
  read_case_record "$rec"
  printf '60\n' > "$HOME_DIR/config/crew-autocompact-pct"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex crewmate spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "codex crewmate spawn should report success"

  assert_not_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" \
    "a non-claude harness must never see the claude-only env prefix"
  pass "config/crew-autocompact-pct is ignored entirely for a non-claude harness"
}

# ===========================================================================
# Malformed / out-of-range values refuse the spawn with an actionable error.
# ===========================================================================
assert_refuses() {  # <value-description> <file-content>
  local desc=$1 content=$2 rec out status
  rec=$(make_spawn_case "refuse-$(printf '%s' "$desc" | tr -c 'a-zA-Z0-9' '-')" claude)
  read_case_record "$rec"
  printf '%s' "$content" > "$HOME_DIR/config/crew-autocompact-pct"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "malformed value ($desc) must refuse the spawn (got exit 0): $out"
  assert_contains "$out" "config/crew-autocompact-pct" \
    "the refusal must name the offending file ($desc)"
  assert_contains "$out" "1 to 99" \
    "the refusal must state the accepted range ($desc)"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn ($desc) must never send a launch command"
  [ ! -f "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused spawn ($desc) must not publish a task record"
  pass "config/crew-autocompact-pct holding $desc refuses the spawn with an actionable error"
}

test_zero_is_refused() { assert_refuses "zero" $'0\n'; }
test_hundred_is_refused() { assert_refuses "one-hundred" $'100\n'; }
test_negative_is_refused() { assert_refuses "negative" $'-5\n'; }
test_non_numeric_is_refused() { assert_refuses "non-numeric" $'abc\n'; }
test_empty_file_is_refused() { assert_refuses "empty" ''; }
test_multiline_is_refused() { assert_refuses "multiline" $'60\n70\n'; }
test_decimal_is_refused() { assert_refuses "decimal" $'60.5\n'; }

test_absent_file_leaves_launch_unchanged
test_valid_value_prefixes_claude_crewmate_launch
test_valid_value_prefixes_claude_scout_launch
test_secondmate_launch_never_gets_the_prefix
test_non_claude_harness_never_gets_the_prefix
test_zero_is_refused
test_hundred_is_refused
test_negative_is_refused
test_non_numeric_is_refused
test_empty_file_is_refused
test_multiline_is_refused
test_decimal_is_refused

echo "# all fm-crew-autocompact tests passed"
