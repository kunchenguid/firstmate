#!/usr/bin/env bash
# fm-spawn.sh on the Rex backend: a fresh task copy is leased durably and the
# block's top-level shell is moved into it.
#
# The interactive `treehouse get` holds a pool slot only through its live
# subshell, so a Rex Server stop frees the slot of a worker whose block is about
# to be relaunched. These cases pin the replacement: `treehouse get --lease`,
# then a cd into the copy, never the interactive form.
#
# The stateful rex fixture models the server; a thin wrapper adds the shell cwd
# a `cd` moves and the agent a delivered launch starts. Fakes only - never a
# real Rex server or a real pool.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/rex-fake-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/rex-fake-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the rex adapter)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-rex-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

make_lease_case() {  # <name> [harness]
  local name=$1 harness=${2:-codex} dir home proj wt d fb
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/rexbin" "$dir/user-home"
  fm_test_spawn_home "$home" "$harness"
  fm_git_init_commit "$proj"
  git clone -q "$proj" "$wt"
  fm_test_spawn_brief "$home" "$name" "Exercise the Rex task-copy lease for $name."
  mkdir -p "$d/process" "$d/status" "$d/capture" "$d/cursor"
  printf '%s' "$proj" > "$d/fg"
  : > "$d/treehouse-log"
  write_rex_fake_cli "$dir/rexreal/rex" "D='$d'"
  cat > "$dir/rexbin/rex" <<SH
#!/usr/bin/env bash
D='$d'
all="\$*"
case "\$all" in
  *'send -s '*)
    payload=\${all#* -- }
    case "\$payload" in
      'cd -- '*) path=\${payload#cd -- }; path=\${path#\\'}; path=\${path%\\'}
        printf '%s' "\$path" > "\$D/fg" ;;
      *'encode launch-brief'*|*'Firstmate operational input waiting: read'*)
        [ ! -f "\$D/launch-send-fails" ] || exit 1
        : > "\$D/agent-live" ;;
    esac ;;
  *'block call '*' process'*)
    if [ -f "\$D/agent-live" ]; then name=codex; else name=zsh; fi
    printf '{"foreground":{"pid":%s,"name":"%s","path":"/usr/bin/%s","argv0":"%s","cwd":"%s"},"ancestors":[{"pid":99,"name":"bash"}],"last_exit":null}\n' \
      "\$([ -f "\$D/agent-live" ] && echo \$\$ || echo 99999999)" "\$name" "\$name" "\$name" "\$(cat "\$D/fg")"
    exit 0 ;;
esac
exec '$dir/rexreal/rex' "\$@"
SH
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
case "$*" in
  'get --lease '*) [ ! -f "$D/lease-fails" ] || { echo 'lease failed' >&2; exit 1; }
    printf '%s\n' "$FM_FAKE_SLOT" ;;
  'return --force '*) : > "$D/returned" ;;
esac
exit 0
SH
  chmod +x "$dir/rexbin/rex" "$fb/treehouse"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_lease_spawn() {  # <case-dir> <id> [extra spawn args...]
  local dir=$1 id=$2
  shift 2
  env -u TERM_PROGRAM -u REX_SESSION -u REX_BLOCK -u REX_SERVER \
    PATH="$dir/fakebin:$PATH" REX_BIN_DIR="$dir/rexbin" FM_HOME="$dir/home" \
    FM_FAKE_DIR="$dir/fake" FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" \
    CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$dir/project" --backend rex --mode no-mistakes --yolo off "$@" 2>&1
}

test_fresh_spawn_leases_and_moves_the_top_level_shell() {
  local id=rex-lease-top-level dir out status
  dir=$(make_lease_case "$id")
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  assert_grep "get --lease --lease-holder $id" "$dir/fake/treehouse-log" \
    "the task copy was not leased durably under the task id"
  ! grep -qx 'get' "$dir/fake/treehouse-log" \
    || fail "the interactive treehouse get holds the slot only through its subshell"
  [ "$(cat "$dir/fake/fg")" = "$dir/slot" ] \
    || fail "the block's shell cwd is '$(cat "$dir/fake/fg")', not the task copy"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  assert_grep "backend=rex" "$dir/home/state/$id.meta" "meta did not record the Rex backend"
  pass "a fresh rex spawn leases the copy durably and moves the block's shell into it"
}

test_failed_lease_refuses_without_a_record() {
  local id=rex-lease-refused dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/lease-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on without a leased copy"$'\n'"$out"
  assert_contains "$out" "treehouse get --lease failed" "the refusal did not name the failed lease"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  ! grep -qx 'get' "$dir/fake/treehouse-log" || fail "a refused lease fell back to the interactive form"
  pass "a failed lease refuses the rex spawn and falls back to nothing"
}

test_aborted_spawn_names_the_lease_it_keeps() {
  local id=rex-lease-aborted dir out status
  dir=$(make_lease_case "$id")
  echo dirty >> "$dir/slot/README.md"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_contains "$out" "stays leased to $id" "an abort did not name the lease that outlives the block"
  assert_contains "$out" "treehouse return --force $dir/slot" "an abort did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the block still open returned a slot the operator may want to inspect"
  pass "an aborted rex spawn keeps the lease and names the command that releases it"
}

test_abort_returns_a_clean_lease_once_the_block_is_gone() {
  local id=rex-lease-block-gone dir out status
  dir=$(make_lease_case "$id" polytoken)
  cat > "$dir/fakebin/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"print models"*) printf 'zai/glm-5.3-flash\nzai/glm-5.3-flash(low)\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/polytoken"
  : > "$dir/fake/launch-send-fails"
  out=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  [ -e "$dir/fake/returned" ] || fail "the abort kept a clean lease although its block is gone"$'\n'"$out"
  pass "an abort whose rex block is confirmed gone returns a clean lease"
}

test_fresh_spawn_leases_and_moves_the_top_level_shell
test_failed_lease_refuses_without_a_record
test_aborted_spawn_names_the_lease_it_keeps
test_abort_returns_a_clean_lease_once_the_block_is_gone

echo "# all fm-spawn-rex-lease tests passed"
