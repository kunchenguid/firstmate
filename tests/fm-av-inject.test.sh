#!/usr/bin/env bash
# tests/fm-av-inject.test.sh - unit tests for the Automic Vault secret-injection
# library (bin/fm-av-inject-lib.sh) plus a spawn-path integration regression that
# proves bin/fm-spawn.sh wraps a real worker launch in `av inject +KEY... --`
# only when the home opts in. Uses a fake `av`, a fake tmux, and a real isolated
# git worktree - no live harness and no real Automic Vault app required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-av-inject-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-av-inject)

# --- fm_av_inject_mode: default-off with truthy precedence -------------------

CFG_ON="$TMP_ROOT/cfg-on"; CFG_OFF="$TMP_ROOT/cfg-off"; CFG_GARBAGE="$TMP_ROOT/cfg-garbage"
mkdir -p "$CFG_ON" "$CFG_OFF" "$CFG_GARBAGE"
printf 'on\n' > "$CFG_ON/av-inject"
printf 'off\n' > "$CFG_OFF/av-inject"
printf 'maybe\n' > "$CFG_GARBAGE/av-inject"

unset FM_AV_INJECT
[ "$(fm_av_inject_mode "$TMP_ROOT/nope")" = off ] || fail "absent config/av-inject must be off by default"
[ "$(fm_av_inject_mode "$CFG_OFF")" = off ] || fail "explicit off must be off"
[ "$(fm_av_inject_mode "$CFG_GARBAGE")" = off ] || fail "an unrecognized value must fail safe to off"
[ "$(fm_av_inject_mode "$CFG_ON")" = on ] || fail "explicit on must enable"
for truthy in on true yes 1 ON True YES; do
  printf '%s\n' "$truthy" > "$CFG_ON/av-inject"
  [ "$(fm_av_inject_mode "$CFG_ON")" = on ] || fail "'$truthy' must enable"
done
printf 'on\n' > "$CFG_ON/av-inject"
[ "$(FM_AV_INJECT=off fm_av_inject_mode "$CFG_ON")" = off ] || fail "FM_AV_INJECT=off must override a present on file"
[ "$(FM_AV_INJECT=on fm_av_inject_mode "$CFG_OFF")" = on ] || fail "FM_AV_INJECT=on must override an off file"
[ "$(FM_AV_INJECT='' fm_av_inject_mode "$CFG_ON")" = on ] || fail "empty FM_AV_INJECT must defer to a present on file"
pass "fm_av_inject_mode is default-off; FM_AV_INJECT overrides with truthy/other precedence, unset/empty defers to the file"

# --- fm_av_inject_prefix: disabled is an empty, successful no-op --------------

out=$(fm_av_inject_prefix "$CFG_OFF"); rc=$?
expect_code 0 "$rc" "disabled prefix must succeed"
[ -z "$out" ] || fail "disabled prefix must be empty, got '$out'"
pass "fm_av_inject_prefix is a successful empty no-op when disabled"

# --- fm_av_inject_prefix: enabled but no av on PATH refuses (fail closed) -----

EMPTY_BIN="$TMP_ROOT/empty-bin"; mkdir -p "$EMPTY_BIN"
out=$(PATH="$EMPTY_BIN" fm_av_inject_prefix "$CFG_ON" 2>&1); rc=$?
expect_code 1 "$rc" "enabled-but-missing-av must refuse"
pass "fm_av_inject_prefix refuses when enabled but the av CLI is missing"

# --- fm_av_inject_prefix: enabled wraps in `<av> inject +KEY... -- ` ----------

FAKE_BIN=$(fm_fakebin "$TMP_ROOT/av")
cat > "$FAKE_BIN/av" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/av"

out=$(PATH="$FAKE_BIN:$PATH" fm_av_inject_prefix "$CFG_ON"); rc=$?
expect_code 0 "$rc" "enabled prefix with av present must succeed"
assert_contains "$out" "inject +EXA_API_KEY " "prefix must inject the first default key"
assert_contains "$out" "+BUZZ_XYZ_KEY " "prefix must inject the renamed buzz.xyz key"
assert_contains "$out" "$FAKE_BIN/av" "prefix must invoke the resolved absolute av path"
# Ends with `-- ` so the caller splices the agent binary immediately after it.
case "$out" in *' -- ') : ;; *) fail "prefix must end with '-- ', got '$out'" ;; esac
pass "fm_av_inject_prefix emits '<av> inject +KEY... -- ' for the default key set"

# --- fm_av_inject_prefix: an invalid key name refuses ------------------------

out=$(PATH="$FAKE_BIN:$PATH" FM_AV_INJECT_KEYS='GOOD_KEY bad-key' fm_av_inject_prefix "$CFG_ON" 2>&1); rc=$?
expect_code 1 "$rc" "an invalid key name must refuse"
out=$(PATH="$FAKE_BIN:$PATH" FM_AV_INJECT_KEYS='1LEADING_DIGIT' fm_av_inject_prefix "$CFG_ON" 2>&1); rc=$?
expect_code 1 "$rc" "a key name starting with a digit must refuse"
pass "fm_av_inject_prefix rejects key names outside [A-Za-z_][A-Za-z0-9_]*"

# --- spawn integration: opt-in wraps a real claude launch --------------------

SPAWN="$ROOT/bin/fm-spawn.sh"

# Fake tmux: answers the pane-path query and logs the literal launch command.
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
  # A fake `av` so the resolved absolute path exists for the wrapped launch.
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/av"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6
  : > "$launchlog"
  env -u FM_AV_INJECT -u FM_AV_INJECT_KEYS \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

# Opt in: the launch is wrapped, env prefixes stay before `av inject`, and the
# agent binary follows `-- `.
rec=$(make_spawn_case on)
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$rec
EOF
printf 'on\n' > "$HOME_DIR/config/av-inject"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
assert_contains "$out" "spawned $CASE_ID" "opt-in spawn should report success"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "inject +EXA_API_KEY" "wrapped launch must inject the secrets"
assert_contains "$launch" "-- claude --dangerously-skip-permissions" "the agent binary must follow the inject boundary"
# The claude prompt-suggestion env prefix must precede `av inject` so it is
# inherited into the injected child rather than being read as the exec target.
prefix_before_inject=${launch%%inject +*}
assert_contains "$prefix_before_inject" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" "env prefixes must sit before av inject"
pass "an opted-in home wraps the real claude launch in av inject with env prefixes preserved before it"

# Default (no config): the launch is unchanged, no inject wrapper.
rec=$(make_spawn_case off)
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$rec
EOF
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
assert_contains "$out" "spawned $CASE_ID" "default spawn should report success"
launch=$(cat "$LAUNCH_LOG")
assert_not_contains "$launch" "inject +" "a home that did not opt in must launch unwrapped"
pass "a home with no config/av-inject launches the worker unchanged"
