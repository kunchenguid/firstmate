#!/usr/bin/env bash
# tests/fm-agent-loop-efficiency.test.sh - public-interface coverage for
# Firstmate agent-loop efficiency surfaces:
#   - bin/fm-prompt-stable-lib.sh deterministic id listing
#   - bin/fm-agent-loop-baseline.sh baseline schema and fixture measurement
#   - bin/fm-session-start.sh cache-stable task ordering and bounded-output reminder
#   - bin/fm-supervision-instructions.sh byte-stable renders under fixed inputs
#   - bin/fm-spawn.sh PI_CACHE_RETENTION default for pi launches
#
# Exercises real scripts through their public CLI / sourced helpers against
# isolated fake homes. Does not call model APIs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASELINE="$ROOT/bin/fm-agent-loop-baseline.sh"
SUPERVISION="$ROOT/bin/fm-supervision-instructions.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-agent-loop-efficiency-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-prompt-stable-lib.sh
. "$ROOT/bin/fm-prompt-stable-lib.sh"

new_world() {
  local name=$1 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

make_quiet_toolchain() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

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
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi pi-signed
  printf '%s\n' "$fakebin"
}

run_spawn_capture() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_prompt_stable_list_ids_sorted() {
  local dir="$TMP_ROOT/stable-ids"
  mkdir -p "$dir"
  : > "$dir/zulu.meta"
  : > "$dir/alpha.meta"
  : > "$dir/mike.meta"
  : > "$dir/noise.txt"
  got=$(fm_prompt_stable_list_ids "$dir" meta)
  expected=$'alpha\nmike\nzulu'
  [ "$got" = "$expected" ] || fail "expected sorted ids, got: $got"
  pass "fm-prompt-stable-lib lists state ids in LC_ALL=C order"
}

test_supervision_render_byte_stable() {
  local a b c
  a=$("$SUPERVISION" --harness pi --read-only 0 --afk 0 --x-mode 0)
  b=$("$SUPERVISION" --harness pi --read-only 0 --afk 0 --x-mode 0)
  [ "$a" = "$b" ] || fail "supervision render was not byte-stable under fixed flags"
  a=$("$SUPERVISION" --harness claude --read-only 1 --afk 0 --x-mode 0)
  b=$("$SUPERVISION" --harness claude --read-only 1 --afk 0 --x-mode 0)
  [ "$a" = "$b" ] || fail "claude supervision render was not byte-stable"
  c=$("$SUPERVISION" --harness claude --read-only 0 --afk 0 --x-mode 0)
  [ "$a" != "$c" ] || fail "read-only flag should change supervision render"
  pass "fm-supervision-instructions renders are byte-stable and input-sensitive"
}

test_session_start_sorted_and_bounded_reminder() {
  local root home fakebin out out2 path_alpha path_zulu
  IFS='|' read -r root home fakebin < <(new_world sess-order)
  make_quiet_toolchain "$fakebin"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'prefs\n' > "$home/data/captain.md"
  cat > "$home/state/zulu.meta" <<'EOF'
window=tmux:zulu
harness=pi
kind=ship
mode=no-mistakes
yolo=off
EOF
  cat > "$home/state/alpha.meta" <<'EOF'
window=tmux:alpha
harness=pi
kind=ship
mode=no-mistakes
yolo=off
EOF
  printf 'working: a\n' > "$home/state/alpha.status"
  printf 'working: z\n' > "$home/state/zulu.status"
  : > "$home/state/.last-watcher-beat"
  printf '%s\n' "$$" > "$home/state/.lock"

  out=$(
    env PATH="$fakebin:$BASE_PATH" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOOTSTRAP_DETECT_ONLY=1 \
      "$SESSION_START"
  ) || fail "session-start failed"

  path_alpha=$(printf '%s\n' "$out" | grep -n '^--- alpha ---$' | head -1 | cut -d: -f1)
  path_zulu=$(printf '%s\n' "$out" | grep -n '^--- zulu ---$' | head -1 | cut -d: -f1)
  [ -n "$path_alpha" ] && [ -n "$path_zulu" ] || fail "missing meta headers in digest"
  [ "$path_alpha" -lt "$path_zulu" ] || fail "meta order was not alpha before zulu ($path_alpha >= $path_zulu)"

  printf '%s\n' "$out" | grep -q 'fm-fleet-view.sh' \
    || fail "session-start closing reminder omitted fleet-view aggregate pointer"
  printf '%s\n' "$out" | grep -q 'fm-bearings-snapshot.sh' \
    || fail "session-start closing reminder omitted bearings aggregate pointer"

  out2=$(
    env PATH="$fakebin:$BASE_PATH" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOOTSTRAP_DETECT_ONLY=1 \
      "$SESSION_START"
  ) || fail "second session-start failed"
  [ "$out" = "$out2" ] || fail "session-start digest was not byte-identical across two fixed runs"

  pass "session-start orders tasks stably, reminds aggregates, and is byte-stable"
}

test_session_start_single_variable_changes_expected_region() {
  local root home fakebin out_a out_b
  IFS='|' read -r root home fakebin < <(new_world sess-var)
  make_quiet_toolchain "$fakebin"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'stable-captain\n' > "$home/data/captain.md"
  cat > "$home/state/only.meta" <<'EOF'
window=tmux:only
harness=pi
kind=ship
mode=no-mistakes
yolo=off
EOF
  printf 'working: one\n' > "$home/state/only.status"
  : > "$home/state/.last-watcher-beat"
  printf '%s\n' "$$" > "$home/state/.lock"

  out_a=$(
    env PATH="$fakebin:$BASE_PATH" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOOTSTRAP_DETECT_ONLY=1 \
      "$SESSION_START"
  )

  printf 'stable-captain-changed\n' > "$home/data/captain.md"
  out_b=$(
    env PATH="$fakebin:$BASE_PATH" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOOTSTRAP_DETECT_ONLY=1 \
      "$SESSION_START"
  )

  [ "$out_a" != "$out_b" ] || fail "captain.md change should alter digest"
  printf '%s\n' "$out_a" | grep -q 'stable-captain' || fail "original captain content missing"
  printf '%s\n' "$out_b" | grep -q 'stable-captain-changed' || fail "updated captain content missing"
  printf '%s\n' "$out_a" | grep -q '^--- only ---$' || fail "task header missing in a"
  printf '%s\n' "$out_b" | grep -q '^--- only ---$' || fail "task header missing in b"
  pass "session-start single-variable captain change affects digest without dropping tasks"
}

test_baseline_schema_and_fixture() {
  local json kv
  json=$("$BASELINE" --json --with-session-fixture) \
    || fail "baseline --json --with-session-fixture failed"
  printf '%s\n' "$json" | grep -q '"schema": "fm-agent-loop-baseline.v1"' \
    || fail "baseline json missing schema"
  printf '%s\n' "$json" | grep -q '"agents_md_bytes"' \
    || fail "baseline json missing agents_md_bytes"
  printf '%s\n' "$json" | grep -q '"code_mode_embedded_runtime": "absent"' \
    || fail "baseline must report Code Mode runtime absent"
  printf '%s\n' "$json" | grep -q '"session_start_fixture_deterministic": "true"' \
    || fail "fixture digest was not deterministic: $json"
  printf '%s\n' "$json" | grep -q '"session_start_fixture_sorted_ids": "true"' \
    || fail "fixture digest did not sort ids: $json"

  kv=$("$BASELINE") || fail "baseline kv mode failed"
  printf '%s\n' "$kv" | grep -q '^schema=fm-agent-loop-baseline.v1$' \
    || fail "kv baseline missing schema line"
  printf '%s\n' "$kv" | grep -q '^openai_server_compaction=' \
    || fail "kv baseline missing compaction discovery"

  pass "fm-agent-loop-baseline reports schema, fixture determinism, and boundaries"
}

test_spawn_pi_cache_retention_default() {
  local case_dir home proj wt fakebin launchlog id out status launch
  id=loop-eff-pi-cache
  case_dir="$TMP_ROOT/spawn-pi-cache"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/data/${id}-keep" "$home/projects" "$home/state" "$home/config"
  printf 'pi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-pi-cache"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf 'brief for %s\n' "${id}-keep" > "$home/data/${id}-keep/brief.md"

  out=$(
    unset PI_CACHE_RETENTION
    run_spawn_capture "$home" "$wt" "$fakebin" "$launchlog" \
      "$id" "$proj" pi
  )
  status=$?
  expect_code 0 "$status" "pi spawn for cache-retention default should succeed: $out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "PI_CACHE_RETENTION=long" \
    "pi launch missing default PI_CACHE_RETENTION=long"
  assert_contains "$launch" "FM_PI_HARNESS=pi" \
    "pi launch missing FM_PI_HARNESS"

  out=$(
    PI_CACHE_RETENTION=short \
      run_spawn_capture "$home" "$wt" "$fakebin" "$launchlog" \
      "${id}-keep" "$proj" pi
  )
  status=$?
  expect_code 0 "$status" "pi spawn with operator retention should succeed: $out"
  launch=$(cat "$launchlog")
  assert_not_contains "$launch" "PI_CACHE_RETENTION=long" \
    "operator PI_CACHE_RETENTION must not be overridden to long"
  assert_contains "$launch" "FM_PI_HARNESS=pi" \
    "pi launch missing FM_PI_HARNESS when retention preset"

  pass "fm-spawn defaults PI_CACHE_RETENTION=long for pi and preserves operator overrides"
}

test_prompt_stable_list_ids_sorted
test_supervision_render_byte_stable
test_session_start_sorted_and_bounded_reminder
test_session_start_single_variable_changes_expected_region
test_baseline_schema_and_fixture
test_spawn_pi_cache_retention_default

echo "ALL TESTS PASSED"
