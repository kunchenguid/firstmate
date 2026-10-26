#!/usr/bin/env bash
# fm-spawn.sh on the Herdr backend: a fresh task copy is leased durably and the
# pane's TOP-LEVEL shell is moved into it.
#
# Herdr restores a pane from the cwd of its top-level shell, and the pane's
# `cwd` field does not follow a nested shell (only `foreground_cwd` does). The
# interactive `treehouse get` runs a subshell, so the later `cd` landed inside
# it and a host restart reopened every worker in the primary clone. These cases
# pin the replacement: `treehouse get --lease`, then a cd the stub applies to
# the top-level shell, never the interactive form.
#
# Canned/stateful fakes only - never a real herdr session or a real pool.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_lease_case <name>: a home, a project, and the leased task copy.
# The fake herdr models the two cwd fields: `cd` sent to the pane moves the
# restorable top-level cwd ($D/cwd) and, unless a nested shell is running,
# the foreground cwd with it. The fake treehouse opens that nested shell for
# the interactive form, which is exactly what must not be used.
make_lease_case() {
  local name=$1 dir home proj wt fb d
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "slot-$name"
  fm_test_spawn_brief "$home" "$name" "Exercise the Herdr task-copy lease for $name."
  printf '%s' "$proj" > "$d/cwd"
  printf '%s' "$proj" > "$d/fg"
  : > "$d/treehouse-log"
  : > "$d/herdr-log"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
case "$*" in
  'get --lease '*) [ ! -f "$D/lease-fails" ] || { echo 'lease failed' >&2; exit 1; }
    printf '%s\n' "$FM_FAKE_SLOT" ;;
  'get') printf '%s' "$FM_FAKE_SLOT" > "$D/fg" ;;
  'return --force '*) : > "$D/returned" ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
[ "${1:-}" != server ] || exit 0
case "${1:-} ${2:-}" in
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "$(cat "$D/cwd")" "$(cat "$D/fg")"
    exit 0 ;;
  'pane run' | 'pane send-text')
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      'cd -- '*) path=${payload#cd -- }; path=${path#\'}; path=${path%\'}
        printf '%s' "$path" > "$D/cwd"; printf '%s' "$path" > "$D/fg" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'workspace create')
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"},"root_pane":{"pane_id":"%%1"}}}\n'
    exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'tab create')
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_lease_spawn() {  # <case-dir> <id>
  local dir=$1 id=$2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$dir/project" --backend herdr --mode no-mistakes --yolo off 2>&1
}

test_fresh_spawn_leases_and_moves_the_top_level_shell() {
  local id=lease-top-level dir out status
  dir=$(make_lease_case "$id")
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  assert_grep "get --lease --lease-holder $id" "$dir/fake/treehouse-log" \
    "the task copy was not leased durably under the task id"
  ! grep -qx 'get' "$dir/fake/treehouse-log" \
    || fail "the interactive treehouse get opened a nested shell the restore cannot see"
  [ "$(cat "$dir/fake/cwd")" = "$dir/slot" ] \
    || fail "the pane's restorable top-level cwd is '$(cat "$dir/fake/cwd")', not the task copy"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  pass "a fresh herdr spawn leases the copy and moves the pane's top-level shell into it"
}

test_failed_lease_refuses_without_a_record() {
  local id=lease-refused dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/lease-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on without a leased copy"$'\n'"$out"
  assert_contains "$out" "treehouse get --lease failed" "the refusal did not name the failed lease"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  ! grep -qx 'get' "$dir/fake/treehouse-log" || fail "a refused lease fell back to the interactive form"
  pass "a failed lease refuses the spawn and falls back to nothing"
}

test_aborted_spawn_names_the_lease_it_keeps() {
  local id=lease-aborted dir out status
  dir=$(make_lease_case "$id")
  echo dirty >> "$dir/slot/README.md"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_contains "$out" "stays leased to $id" "an abort did not name the lease that outlives the pane"
  assert_contains "$out" "treehouse return --force $dir/slot" "an abort did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "an aborted spawn keeps the lease and names the command that releases it"
}

test_fresh_spawn_leases_and_moves_the_top_level_shell
test_failed_lease_refuses_without_a_record
test_aborted_spawn_names_the_lease_it_keeps

echo "# all fm-spawn-herdr-lease tests passed"
