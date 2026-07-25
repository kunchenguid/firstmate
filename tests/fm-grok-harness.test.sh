#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

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
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$grok_home"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" grok 2>&1
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

# Grok 0.2.112 mid-turn keybind bar uses Esc:cancel (not Ctrl+c:cancel). Both
# defaults must stay in lockstep: fm-watch.sh does not source fm-tmux-lib.sh.
# Fixtures use the real U+2502 separator and are the footers captured from live
# 0.2.112 panes: mid-turn carries Esc:cancel, and none of the non-busy overlays
# (idle bar, slash autocomplete, project-dir chooser) do. A false busy on any of
# those would suppress stuck detection for a pane blocked on a human.
test_grok_busy_regex_matches_realistic_footer_fixtures() {
  local watch_default tmux_default mid_footer perm_footer name footer
  watch_default=$(sed -n "s/^BUSY_REGEX=\${FM_BUSY_REGEX:-'\\(.*\\)'}/\\1/p" "$ROOT/bin/fm-watch.sh")
  tmux_default=$(sed -n "s/^FM_TMUX_BUSY_REGEX_DEFAULT='\\(.*\\)'/\\1/p" "$ROOT/bin/fm-tmux-lib.sh")
  [ -n "$watch_default" ] || fail "could not extract BUSY_REGEX default from fm-watch.sh"
  [ -n "$tmux_default" ] || fail "could not extract FM_TMUX_BUSY_REGEX_DEFAULT from fm-tmux-lib.sh"
  [ "$watch_default" = "$tmux_default" ] \
    || fail "BUSY_REGEX default and FM_TMUX_BUSY_REGEX_DEFAULT diverged: watch=[$watch_default] tmux=[$tmux_default]"
  printf '%s' "$watch_default" | grep -Fq 'Esc:cancel' \
    || fail "default busy regex missing Esc:cancel (Grok 0.2.112 mid-turn token)"
  # Source form is the ERE token Ctrl\+c:cancel (plus escaped for grep -E).
  printf '%s' "$watch_default" | grep -Fq 'Ctrl\+c:cancel' \
    || fail "default busy regex dropped Ctrl+c:cancel (older Grok installs)"

  # Exact mid-turn keybind bar shape from grok 0.2.112 (separators are U+2502).
  mid_footer=$'  Shift+Tab:mode  \u2502  Esc:cancel  \u2502  Ctrl+b:send to bg  \u2502  Ctrl+.:shortcuts\n'
  printf '%s' "$mid_footer" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "$watch_default" \
    || fail "default busy regex does not match realistic Grok mid-turn footer"

  # Captured non-busy 0.2.112 overlays: a match here is a false busy, which
  # would hide a pane that is actually blocked waiting on a human.
  while IFS='|' read -r name footer; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$footer" | grep -v '^[[:space:]]*$' | tail -6 \
      | grep -qiE "$watch_default"; then
      fail "default busy regex matches non-busy Grok overlay ($name): [$footer]"
    fi
  done <<'EOF'
idle keybind bar|  Shift+Tab:mode  \u2502  Ctrl+.:shortcuts
slash autocomplete|  Enter:send  \u2502  Shift+Tab:mode  \u2502  Ctrl+.:shortcuts
project-dir chooser|  Esc:unselect  \u2502  Tab:scrollback  \u2502  Shift+x:dismiss
EOF

  # The tool-permission dialog prints the legacy Ctrl+c:cancel, which this regex
  # has always matched. Pinned as known behaviour, not as a new regression.
  perm_footer=$'  1/4:select  \u2502  Ctrl+o:always-approve  \u2502  Ctrl+c:cancel\n'
  printf '%s' "$perm_footer" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "$watch_default" \
    || fail "legacy Ctrl+c:cancel token no longer matches the Grok permission dialog footer"

  pass "Grok busy regex matches mid-turn footer and rejects captured non-busy overlays"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_fm_lock_recognizes_grok_holder
test_grok_busy_regex_matches_realistic_footer_fixtures
