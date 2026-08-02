#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --pool (multi-account dispatch pool).
#
# These drive fm-spawn through meta writing and launch construction with a fake
# tmux pane and a real isolated git worktree, exactly like the dispatch-profile
# suite. The fake tmux captures the literal launch command, so assertions pin the
# command firstmate would run without starting any real harness or agent account.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool)
mkdir -p "$TMP_ROOT"

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
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Builds a case dir with a home, project, worktree, fake bins, and a brief.
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/keys"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  # CASE_DIR is part of the shared record layout; this file does not consume it.
  # shellcheck disable=SC2034
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

write_pool_config() {
  local home=$1
  cat > "$home/config/dispatch-pool.json" <<JSON
{
  "backends": [
    { "id": "claude-1", "harness": "claude", "env": { "CLAUDE_CONFIG_DIR": "$home/dot-claude-1" } },
    { "id": "claude-2", "harness": "claude", "env": { "CLAUDE_CONFIG_DIR": "$home/dot-claude-2" } },
    { "id": "cursor-1", "harness": "cursor", "key_env": "CURSOR_API_KEY" }
  ]
}
JSON
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
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The core backward-compatibility proof: with no pool config, a --pool spawn must
# produce the SAME launch command and the SAME meta as a plain spawn. Not
# asserted in prose - the two runs are compared byte for byte.
test_absent_config_is_byte_identical() {
  local rec_a rec_b id_a id_b out_a out_b launch_a launch_b meta_a meta_b
  id_a=pool-off-plain-a1
  id_b=pool-off-flag-b1
  rec_a=$(make_spawn_case pool-off-plain "$id_a")
  read_case_record "$rec_a"
  out_a=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR")
  expect_code 0 $? "plain spawn should succeed: $out_a"
  # Normalize only the three things that legitimately differ between two runs: the
  # task id, the per-case directory name, and the busy-state generation token
  # (timestamp.pid.random, fresh per spawn). The KEY is kept so a meta that loses
  # busy_gen entirely still fails. Everything else must match exactly.
  launch_a=$(sed "s/$id_a/TASKID/g; s|pool-off-plain|CASE|g" "$LAUNCH_LOG")
  meta_a=$(sed "s/$id_a/TASKID/g; s|pool-off-plain|CASE|g; s/^busy_gen=.*/busy_gen=GEN/" "$HOME_DIR/state/$id_a.meta")

  rec_b=$(make_spawn_case pool-off-flag "$id_b")
  read_case_record "$rec_b"
  # No config/dispatch-pool.json in this home either.
  out_b=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" --pool)
  expect_code 0 $? "--pool with no config should still succeed: $out_b"
  launch_b=$(sed "s/$id_b/TASKID/g; s|pool-off-flag|CASE|g" "$LAUNCH_LOG")
  meta_b=$(sed "s/$id_b/TASKID/g; s|pool-off-flag|CASE|g; s/^busy_gen=.*/busy_gen=GEN/" "$HOME_DIR/state/$id_b.meta")

  [ "$launch_a" = "$launch_b" ] \
    || fail "--pool with no config changed the launch command"$'\n'"plain: $launch_a"$'\n'"pool:  $launch_b"
  [ "$meta_a" = "$meta_b" ] \
    || fail "--pool with no config changed the meta"$'\n'"plain: $meta_a"$'\n'"pool:  $meta_b"
  case "$meta_b" in
    *pool_backend=*) fail "an unpooled spawn must not write pool_backend=" ;;
  esac
  case "$out_b" in
    *"no dispatch pool is configured"*) ;;
    *) fail "--pool with no config should warn once, got: $out_b" ;;
  esac
  pass "with no pool config, --pool produces a byte-identical launch and meta"
}

test_pool_records_account_and_applies_its_env() {
  local rec id out launch meta
  id=pool-on-claude-c1
  rec=$(make_spawn_case pool-on-claude "$id")
  read_case_record "$rec"
  write_pool_config "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --pool)
  expect_code 0 $? "pooled spawn should succeed: $out"
  assert_contains "$out" "pool_backend=claude-1" "spawn output should name the chosen account"

  meta=$(cat "$HOME_DIR/state/$id.meta")
  case "$meta" in
    *"pool_backend=claude-1"*) ;;
    *) fail "meta should record pool_backend=claude-1, got: $meta" ;;
  esac
  # The account must NOT be written into backend=, which is the runtime-backend
  # key. Anchor to the line start: pool_backend= contains backend= as a substring.
  if grep -q '^backend=' "$HOME_DIR/state/$id.meta"; then
    fail "the account must never be written to backend=; that key is the runtime session provider"
  fi

  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "CLAUDE_CONFIG_DIR='$HOME_DIR/dot-claude-1' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude "*) ;;
    *) fail "pooled launch should be prefixed with the account env, got: $launch" ;;
  esac
  pass "--pool records the account in meta and applies its env to that launch only"
}

test_pool_rotates_across_spawns() {
  local rec id out first second
  rec=$(make_spawn_case pool-rotate pool-rotate-one-d1)
  read_case_record "$rec"
  write_pool_config "$HOME_DIR"
  printf 'k\n' > "$HOME_DIR/keys/cursor-1.key"

  for id in pool-rotate-one-d1 pool-rotate-two-d2; do
    mkdir -p "$HOME_DIR/data/$id"
    printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  done
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" pool-rotate-one-d1 "$PROJ_DIR" --pool)
  expect_code 0 $? "first pooled spawn should succeed: $out"
  first=$(sed -n 's/^pool_backend=//p' "$HOME_DIR/state/pool-rotate-one-d1.meta")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" pool-rotate-two-d2 "$PROJ_DIR" --pool)
  expect_code 0 $? "second pooled spawn should succeed: $out"
  second=$(sed -n 's/^pool_backend=//p' "$HOME_DIR/state/pool-rotate-two-d2.meta")

  [ "$first" = claude-1 ] || fail "first spawn should take claude-1, got $first"
  [ "$second" = claude-2 ] || fail "second spawn should rotate to claude-2, got $second"
  pass "consecutive pooled spawns land on different accounts"
}

test_pool_never_puts_a_key_on_the_command_line() {
  local rec id out launch meta secret
  id=pool-secret-e1
  rec=$(make_spawn_case pool-secret "$id")
  read_case_record "$rec"
  write_pool_config "$HOME_DIR"
  secret='sk-cursor-super-secret-do-not-leak'
  printf '%s\n' "$secret" > "$HOME_DIR/keys/cursor-1.key"
  # Pin the cursor account so the key path is definitely exercised.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --pool-backend cursor-1)
  expect_code 0 $? "pinned cursor spawn should succeed: $out"

  launch=$(cat "$LAUNCH_LOG")
  meta=$(cat "$HOME_DIR/state/$id.meta")
  case "$launch$meta$out" in
    *"$secret"*) fail "the key value must never reach the launch command, meta, or output" ;;
  esac
  case "$launch" in
    *"CURSOR_API_KEY=\"\$(cat '$HOME_DIR/keys/cursor-1.key')\""*) ;;
    *) fail "the launch should read the key from its file at launch time, got: $launch" ;;
  esac
  case "$meta" in
    *"pool_backend=cursor-1"*) ;;
    *) fail "meta should record the pinned account, got: $meta" ;;
  esac
  pass "a pooled launch carries the key PATH, never the key value"
}

test_pool_refuses_when_every_account_is_cooling() {
  local rec id out status
  id=pool-exhausted-f1
  rec=$(make_spawn_case pool-exhausted "$id")
  read_case_record "$rec"
  write_pool_config "$HOME_DIR"
  printf 'k\n' > "$HOME_DIR/keys/cursor-1.key"
  local b
  for b in claude-1 claude-2 cursor-1; do
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_POOL_KEY_DIR="$HOME_DIR/keys" \
      "$ROOT/bin/fm-pool.sh" cooldown "$b" --seconds 900 >/dev/null
  done
  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --pool)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a spawn with every account cooling must not succeed"
  case "$out" in
    *"refusing to launch on an exhausted account"*) ;;
    *) fail "the refusal should say why, got: $out" ;;
  esac
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "a refused pooled spawn must not leave task metadata"
  pass "a spawn is refused, not silently mis-routed, when every account is cooling"
}

# The back-compat POSITIONAL harness is as explicit an override as --harness, so
# it must narrow rotation the same way. Rotation starts at claude-1 here, so a
# pool that ignored the positional would launch claude and silently drop the
# caller's "cursor".
test_positional_harness_narrows_the_pool() {
  local rec id out backend launch
  id=pool-positional-h1
  rec=$(make_spawn_case pool-positional "$id")
  read_case_record "$rec"
  write_pool_config "$HOME_DIR"
  printf 'k\n' > "$HOME_DIR/keys/cursor-1.key"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" cursor --pool)
  expect_code 0 $? "a pooled spawn with a positional harness should succeed: $out"

  backend=$(sed -n 's/^pool_backend=//p' "$HOME_DIR/state/$id.meta")
  [ "$backend" = cursor-1 ] || fail "the positional harness should narrow rotation to a cursor account, got $backend"
  case "$(sed -n 's/^harness=//p' "$HOME_DIR/state/$id.meta")" in
    cursor) ;;
    *) fail "meta should record the caller's harness, got: $(cat "$HOME_DIR/state/$id.meta")" ;;
  esac
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *'cursor agent '*) ;;
    *) fail "the launch should be the caller's harness, not the pool's default, got: $launch" ;;
  esac
  pass "a positional harness narrows the pool and is never overridden by it"
}

# An account may pin the model and effort it should run on, and docs/dispatch-pool.md
# promises an explicit --model/--effort still wins. Both halves are asserted here:
# the pool's defaults reach the launch when the caller names none, and they are
# dropped the moment the caller does.
test_account_model_defaults_yield_to_explicit_flags() {
  local rec id out meta launch
  id=pool-model-i1
  rec=$(make_spawn_case pool-model "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/config/dispatch-pool.json" <<'JSON'
{
  "backends": [
    { "id": "claude-1", "harness": "claude", "model": "opus", "effort": "high" }
  ]
}
JSON

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --pool)
  expect_code 0 $? "a pooled spawn on a model-pinning account should succeed: $out"
  meta=$(cat "$HOME_DIR/state/$id.meta")
  assert_contains "$meta" "model=opus" "the account's model should reach meta"
  assert_contains "$meta" "effort=high" "the account's effort should reach meta"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'opus'" "the account's model should reach the launch"
  assert_contains "$launch" "--effort 'high'" "the account's effort should reach the launch"

  id=pool-model-j1
  rec=$(make_spawn_case pool-model-explicit "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/config/dispatch-pool.json" <<'JSON'
{
  "backends": [
    { "id": "claude-1", "harness": "claude", "model": "opus", "effort": "high" }
  ]
}
JSON
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --pool --model sonnet --effort low)
  expect_code 0 $? "a pooled spawn with explicit model/effort should succeed: $out"
  meta=$(cat "$HOME_DIR/state/$id.meta")
  assert_contains "$meta" "model=sonnet" "an explicit --model must outrank the account's default"
  assert_contains "$meta" "effort=low" "an explicit --effort must outrank the account's default"
  assert_not_contains "$meta" "model=opus" "the account's model must not survive an explicit --model"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'sonnet'" "the launch should carry the caller's model"
  assert_not_contains "$launch" "opus" "the account's model must not reach the launch"
  pass "an account's model/effort defaults apply, and an explicit flag still wins"
}

test_pool_rejects_secondmate() {
  local rec id out status
  id=pool-secondmate-g1
  rec=$(make_spawn_case pool-secondmate "$id")
  read_case_record "$rec"
  write_pool_config "$HOME_DIR"
  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --pool --secondmate)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "--pool --secondmate should be refused"
  case "$out" in
    *"--pool does not apply to --secondmate"*) ;;
    *) fail "the refusal should name the reason, got: $out" ;;
  esac
  pass "--pool is refused for a secondmate spawn"
}

test_absent_config_is_byte_identical
test_pool_records_account_and_applies_its_env
test_pool_rotates_across_spawns
test_pool_never_puts_a_key_on_the_command_line
test_pool_refuses_when_every_account_is_cooling
test_positional_harness_narrows_the_pool
test_account_model_defaults_yield_to_explicit_flags
test_pool_rejects_secondmate

echo "# all fm-spawn-pool tests passed"
