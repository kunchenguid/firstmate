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

# make_lease_case <name> [harness] [slot]: a home, a project, and the leased
# task copy at <case-dir>/<slot> (default `slot`).
# The fake herdr models the two cwd fields: `cd` sent to the pane moves the
# restorable top-level cwd ($D/cwd) and, unless a nested shell is running,
# the foreground cwd with it. The fake treehouse opens that nested shell for
# the interactive form, which is exactly what must not be used.
make_lease_case() {
  local name=$1 harness=${2:-codex} dir home proj wt fb d
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/${3:-slot}"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" "$harness"
  fm_git_init_commit "$proj"
  git clone -q "$proj" "$wt"
  fm_test_spawn_brief "$home" "$name" "Exercise the Herdr task-copy lease for $name."
  printf '%s' "$wt" > "$d/slot"
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
  'session list')
    [ ! -f "$D/session-lockable" ] || printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$D"
    exit 0 ;;
  'pane close') : > "$D/pane-gone"; exit 0 ;;
  'pane get')
    [ ! -f "$D/pane-gone" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 0; }
    if [ -f "$D/cd-sent" ] && [ -f "$D/delay-reads" ]; then
      reads=$(cat "$D/reads" 2>/dev/null || printf 0)
      reads=$((reads + 1)); printf '%s' "$reads" > "$D/reads"
      if [ "$reads" -ge "$(cat "$D/delay-reads")" ]; then
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$FM_FAKE_SLOT" "$D/fg"
      fi
    fi
    if [ -f "$D/windows" ]; then
      # Native Windows Herdr: no foreground_cwd, and a cwd frozen at launch.
      printf '{"result":{"pane":{"pane_id":"%s","cwd":"C:\\\\project","foreground_cwd":null}}}\n' "${3:-}"
      exit 0
    fi
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "$(cat "$D/cwd")" "$(cat "$D/fg")"
    exit 0 ;;
  'pane read')
    # A 120-column pane: the recent source hard-wraps a longer line across
    # rows, and only recent-unwrapped joins it back.
    case " $* " in
      *' --source recent-unwrapped '*) cat "$D/screen" 2>/dev/null ;;
      *) fold -w 120 "$D/screen" 2>/dev/null ;;
    esac
    exit 0 ;;
  'pane run' | 'pane send-text')
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      'cd -- '*) path=${payload#cd -- }; path=${path#\'}; path=${path%\'}
        sends=$(cat "$D/cd-sends" 2>/dev/null || printf 0)
        sends=$((sends + 1)); printf '%s' "$sends" > "$D/cd-sends"
        : > "$D/cd-sent"
        [ ! -f "$D/never-moves" ] || exit 0
        [ ! -f "$D/delay-reads" ] || exit 0
        [ ! -f "$D/drop-first-cd" ] || [ "$sends" -gt 1 ] || exit 0
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$path" "$D/cwd"
        cp "$D/cwd" "$D/fg" ;;
      "printf '__FM_CWD_"*)
        # The shell answers the folder probe: Git Bash with its POSIX folder,
        # PowerShell with a drive-letter $PWD.
        printf '%s\n' "$payload" >> "$D/probes"
        nonce=${payload#"printf '__FM_CWD_"}; nonce=${nonce%%__*}
        printf '$ %s\n' "$payload" >> "$D/screen"
        if [ -f "$D/pwsh-pane" ]; then
          printf '__FM_CWD_%s__C:\\project__\n' "$nonce" >> "$D/screen"
        elif [ -f "$D/silent-pane" ]; then
          :
        elif [ -f "$D/malformed-answer" ]; then
          printf '__FM_CWD_%s__%s\n' "$nonce" "$(cat "$D/cwd")" >> "$D/screen"
        else
          printf '__FM_CWD_%s__%s__\n' "$nonce" "$(cat "$D/cwd")" >> "$D/screen"
        fi ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        [ ! -f "$D/launch-send-fails" ] || exit 1
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'agent get')
    if [ -f "$D/agent-gone" ]; then
      printf '{"error":{"code":"agent_not_found"}}\n'
    elif [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"result":{"agent":{"agent_status":"shell-starting"}}}\n'
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
  cat > "$fb/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"print models"*) printf 'zai/glm-5.3-flash\nzai/glm-5.3-flash(low)\n' ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr" "$fb/polytoken"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_lease_spawn() {  # <case-dir> <id> [extra spawn args...]
  local dir=$1 id=$2
  shift 2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$(cat "$dir/fake/slot")" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$dir/project" --backend herdr --mode no-mistakes --yolo off "$@" 2>&1
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
  [ "$(cat "$dir/fake/cd-sends")" = 1 ] || fail "an immediately ready pane received a redundant cd"
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

test_rolled_back_spawn_after_launch_names_the_lease_it_keeps() {
  local id=lease-after-launch dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/launch-send-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_contains "$out" "stays leased to $id" "a rolled-back spawn after its launch left the lease unnamed"
  assert_contains "$out" "treehouse return --force $dir/slot" "a rolled-back spawn after its launch did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "a spawn rolled back after its launch keeps the lease and names the command that releases it"
}

# abort_polytoken_spawn <id> <dirty|launch-fails> [session-lockable]: a
# polytoken spawn aborts, either before its launch into a dirty copy or after a
# launch that was not delivered into a clean copy, and asks Herdr to close its
# own pane. Herdr closes it only when the session's presentation lock can be
# taken, which needs the session's socket; without it the kill refuses and the
# pane stays.
abort_polytoken_spawn() {
  local id=$1 dir
  dir=$(make_lease_case "$id" polytoken)
  case "$2" in
    dirty) echo dirty >> "$dir/slot/README.md" ;;
    launch-fails) : > "$dir/fake/launch-send-fails" ;;
  esac
  [ -z "${3:-}" ] || : > "$dir/fake/session-lockable"
  LEASE_OUT=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  LEASE_STATUS=$?
  LEASE_DIR=$dir
}

test_abort_returns_a_clean_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone
  abort_polytoken_spawn "$id" launch-fails session-lockable
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ -e "$LEASE_DIR/fake/returned" ] || fail "the abort kept a clean lease although its pane is gone"$'\n'"$LEASE_OUT"
  pass "an abort whose pane Herdr reports gone returns a clean lease"
}

test_abort_keeps_a_dirty_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone-dirty
  abort_polytoken_spawn "$id" dirty session-lockable
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned a copy holding uncommitted work"
  assert_grep dirty "$LEASE_DIR/slot/README.md" "the abort discarded the copy's uncommitted work"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort that kept a dirty copy did not name the lease it keeps"
  pass "an abort whose pane Herdr reports gone keeps a copy with uncommitted work leased"
}

test_abort_keeps_the_lease_while_the_pane_is_present() {
  local id=lease-close-refused
  abort_polytoken_spawn "$id" dirty
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  ! grep -q 'pane close' "$LEASE_DIR/fake/herdr-log" || fail "the kill closed the pane without its presentation lock"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned the lease while its pane is still present"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort with its pane still present did not name the lease it keeps"
  pass "an abort whose pane is still present keeps the lease and names it"
}

test_delayed_worktree_entry() {
  local id=lease-delayed-cd dir out status
  dir=$(make_lease_case "$id")
  printf 25 > "$dir/fake/delay-reads"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "delayed cwd should settle after the old 20-read limit"$'\n'"$out"
  [ "$(cat "$dir/fake/reads")" -ge 25 ] || fail "the delay was not exercised"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr waits past the former deadline for a delayed shell cwd"
}

test_dropped_worktree_entry() {
  local id=lease-dropped-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/drop-first-cd"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "a dropped first cd should recover"$'\n'"$out"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr recovers a dropped initial cd with one resend"
}

test_never_moving_worktree_entry() {
  local id=lease-stuck-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/never-moves"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a pane that never moves was accepted"
  assert_contains "$out" "not its recorded worktree" "wrong cwd did not refuse"
  assert_contains "$out" "Herdr pane 'default:%9'" "refusal did not identify the pane"
  assert_contains "$out" "last foreground_cwd='$dir/project'" "refusal lost the last cwd"
  assert_contains "$out" "agent_status='shell-starting'" "refusal lost agent status"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "a stuck pane received more than one retry"
  [ ! -e "$dir/fake/launched-command" ] || fail "a harness started outside its copy"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published metadata"
  pass "Herdr refuses a never-moving pane with diagnostic context and no launch"
}

# windows_shape <case-dir> <uname>: native Windows Herdr output (no
# foreground_cwd, a frozen drive-letter cwd) on a host whose uname is <uname>.
# The fake uname and cygpath let every host drive the Windows-only branch.
windows_shape() {
  local dir=$1
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$2" > "$dir/fakebin/uname"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/cygpath"
  chmod +x "$dir/fakebin/uname" "$dir/fakebin/cygpath"
  : > "$dir/fake/windows"
}

test_windows_git_bash_pane_is_proven_by_its_folder_probe() {
  local id=lease-windows-bash dir out status
  dir=$(make_lease_case "$id")
  windows_shape "$dir" MINGW64_NT-10.0-26300
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "a Git Bash pane that answers the probe from its copy should spawn"$'\n'"$out"
  [ -s "$dir/fake/probes" ] || fail "no folder probe reached the pane"
  [ "$(cat "$dir/fake/cd-sends")" = 1 ] || fail "a pane already in its copy received a redundant cd"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  [ -e "$dir/fake/launched-command" ] || fail "the worker was not launched"
  pass "native Windows Herdr proves the pane's folder with a shell probe and launches"
}

test_windows_powershell_pane_refuses_before_launch() {
  local id=lease-windows-pwsh dir out status
  dir=$(make_lease_case "$id")
  windows_shape "$dir" MINGW64_NT-10.0-26300
  : > "$dir/fake/pwsh-pane"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a PowerShell pane was accepted"$'\n'"$out"
  [ "$(wc -l < "$dir/fake/probes" | tr -d '[:space:]')" = 1 ] \
    || fail "a drive-letter answer did not stop the wait at the first probe"
  assert_contains "$out" "not its recorded worktree" "the refusal did not name the folder"
  assert_contains "$out" "default_shell" "the refusal did not name the Herdr shell setting"
  [ ! -e "$dir/fake/launched-command" ] || fail "a POSIX launch line was typed into PowerShell"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published metadata"
  pass "native Windows Herdr refuses a PowerShell pane whose drive-letter answer proves no folder"
}

test_windows_pane_that_never_moves_refuses() {
  local id=lease-windows-stuck dir out status
  dir=$(make_lease_case "$id")
  windows_shape "$dir" MINGW64_NT-10.0-26300
  : > "$dir/fake/never-moves"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a probe answering the project folder was accepted"$'\n'"$out"
  [ -s "$dir/fake/probes" ] || fail "no folder probe reached the pane"
  [ ! -e "$dir/fake/launched-command" ] || fail "a harness started outside its copy"
  assert_not_contains "$out" "default_shell" "a Git Bash pane that answered the wrong folder was told to change its shell"
  pass "native Windows Herdr refuses a pane whose probe answers a folder other than its copy"
}

test_windows_probe_answer_wider_than_the_pane_is_accepted() {
  local id=lease-windows-wide dir out status long
  long=$(printf 'a-folder-name-long-enough-to-wrap-%.0s' 1 2 3)
  dir=$(make_lease_case "$id" codex "$long/slot")
  windows_shape "$dir" MINGW64_NT-10.0-26300
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "a Git Bash pane whose probe answer is wider than the pane should spawn"$'\n'"$out"
  [ "$(fold -w 120 "$dir/fake/screen" | wc -l)" -gt "$(wc -l < "$dir/fake/screen")" ] \
    || fail "the probe answer fit the pane, so this case proved nothing about wrapping"
  assert_grep "worktree=$dir/$long/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  [ -e "$dir/fake/launched-command" ] || fail "the worker was not launched"
  pass "native Windows Herdr accepts a folder probe answer the pane soft-wraps"
}

test_windows_missing_or_malformed_probe_answer_refuses() {
  local id dir out status marker
  for marker in silent-pane malformed-answer; do
    id=lease-windows-$marker
    dir=$(make_lease_case "$id")
    windows_shape "$dir" MINGW64_NT-10.0-26300
    : > "$dir/fake/$marker"
    out=$(run_lease_spawn "$dir" "$id"); status=$?
    [ "$status" -ne 0 ] || fail "$marker: a pane with no well-formed probe answer was accepted"$'\n'"$out"
    [ -s "$dir/fake/probes" ] || fail "$marker: no folder probe reached the pane"
    assert_contains "$out" "not its recorded worktree" "$marker: the refusal did not name the folder"
    [ ! -e "$dir/fake/launched-command" ] || fail "$marker: a harness started in an unproven folder"
  done
  pass "native Windows Herdr refuses a missing or malformed folder probe answer"
}

test_windows_relaunch_refuses_without_probing() {
  local id=lease-windows-relaunch dir out status
  dir=$(make_lease_case "$id")
  rm -rf "$dir/slot"
  git -C "$dir/project" worktree add -q --detach "$dir/slot"
  windows_shape "$dir" MINGW64_NT-10.0-26300
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "the first Windows spawn should succeed"$'\n'"$out"
  rm -f "$dir/fake/probes" "$dir/fake/launched-command" "$dir/fake/herdr-agent-live"
  : > "$dir/fake/agent-gone"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 "$SPAWN" "$id" --relaunch 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a Windows relaunch with no passive folder read was accepted"$'\n'"$out"
  assert_contains "$out" "did not return to its recorded worktree" "the relaunch refusal did not name the folder check"
  [ ! -e "$dir/fake/probes" ] || fail "a relaunch typed a folder probe into an adopted pane"
  [ ! -e "$dir/fake/launched-command" ] || fail "a relaunch launched a worker into an unproven folder"
  pass "native Windows Herdr relaunch refuses on its passive folder read and never types a probe"
}

test_posix_host_never_probes() {
  local id=lease-posix-no-probe dir out status
  dir=$(make_lease_case "$id")
  windows_shape "$dir" Linux
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a pane with no folder read was accepted"$'\n'"$out"
  [ ! -e "$dir/fake/probes" ] || fail "a POSIX host typed a folder probe into the pane"
  assert_not_contains "$out" "default_shell" "a POSIX host refusal carried the Windows hint"
  pass "a POSIX host keeps the passive folder read and never types a probe"
}

test_windows_git_bash_pane_is_proven_by_its_folder_probe
test_windows_powershell_pane_refuses_before_launch
test_windows_pane_that_never_moves_refuses
test_windows_probe_answer_wider_than_the_pane_is_accepted
test_windows_missing_or_malformed_probe_answer_refuses
test_windows_relaunch_refuses_without_probing
test_posix_host_never_probes

test_delayed_worktree_entry
test_dropped_worktree_entry
test_never_moving_worktree_entry

test_fresh_spawn_leases_and_moves_the_top_level_shell
test_failed_lease_refuses_without_a_record
test_aborted_spawn_names_the_lease_it_keeps
test_rolled_back_spawn_after_launch_names_the_lease_it_keeps
test_abort_returns_a_clean_lease_once_the_pane_is_gone
test_abort_keeps_a_dirty_lease_once_the_pane_is_gone
test_abort_keeps_the_lease_while_the_pane_is_present

echo "# all fm-spawn-herdr-lease tests passed"
