#!/usr/bin/env bash
# tests/fm-spawn-win32-herdr.test.sh - coverage for the fm-spawn.sh native
# Windows herdr-pane worktree arm (spawn_herdr_win32_acquire_worktree and the
# fm_backend_herdr_foreground_cwd_supported capability probe in
# bin/backends/herdr.sh).
#
# Herdr on native Windows cannot report a pane's live foreground cwd: the
# .result.pane.foreground_cwd field is absent from `pane get` there (verified
# against herdr 0.9.1 for Windows; live-cwd reporting is prompt-integration
# only). The interactive `treehouse get` + cwd-poll acquisition can therefore
# never observe the pane landing in its slot, and the staged exports plus the
# sourced launch file could never run in the pane's native powershell/cmd
# shell at all. The Windows arm reverses the information flow: firstmate
# takes Treehouse's durable lease itself (`get --lease --json`, the same
# acquisition bin/fm-home-seed.sh uses for secondmate homes), enters Git Bash
# in the pane, and drives the pane's shell to the leased slot behind an
# output marker the echoed command line cannot fake.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-win32-herdr)

# A herdr pane id the fake CLI answers for; the spawn resolves it through the
# adopted home workspace and `tab create`, never through a real server.
FAKE_PANE_ID=w9:p2

# make_win32_fakebin <dir> -> fakebin with:
#   herdr     - logs every invocation to $FM_HERDR_LOG (unit-separated args)
#               and answers the exact subcommands the spawn path makes
#   treehouse - logs to $FM_TREEHOUSE_LOG and answers `get --lease --json`
#               with $FM_FAKE_LEASE_PATH
#   cygpath   - minimal drive-letter converter (real cygpath exists only on
#               MSYS hosts; the test must also run on POSIX CI)
#   devin     - executable stub (the launch itself is sent to the fake pane,
#               never exec'd)
#   sleep     - no-op so waits/polls cost nothing
make_win32_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{ for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_HERDR_LOG:?}"
# The adapter appends `--session <name>`; dispatch on the leading subcommand.
case "$*" in
  "--version"|"version"*) printf 'herdr 0.9.1\n' ;;
  "status --json"*) printf '{"client":{"version":"0.9.1","protocol":22},"server":{"running":true}}\n' ;;
  "workspace list"*) printf '%s\n' "${FM_FAKE_WS_LIST:-{\"result\":{\"workspaces\":[{\"workspace_id\":\"w9\",\"label\":\"firstmate\"}]}}}" ;;
  "workspace create"*) printf '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"}}}\n' ;;
  "tab list"*) printf '%s\n' "${FM_FAKE_TAB_LIST:-{\"result\":{\"tabs\":[]}}}" ;;
  "tab create"*) printf '{"result":{"tab":{"tab_id":"w9:t2"},"root_pane":{"pane_id":"w9:p2"}}}\n' ;;
  "pane process-info"*) printf '%s\n' "${FM_FAKE_SHELL_JSON:?}" ;;
  "pane get"*) printf '%s\n' "${FM_FAKE_PANE_GET:?}" ;;
  "pane wait-output"*)
    case "$*" in *"FM_WT_"*) [ "${FM_FAKE_CD_PROOF_FAIL:-0}" = 1 ] && exit 1 ;; esac
    printf '{"result":{"type":"output_matched","matched_line":"m"}}\n' ;;
  "pane read"*) printf '%s\n' "${FM_FAKE_PANE_TEXT:-}" ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
case "$*" in
  "get --lease --json"*) printf '{"path":"%s"}\n' "${FM_FAKE_LEASE_PATH:?}" ;;
  "return --force "*) : ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse"
  # cygpath must delegate to the real binary when one exists (MSYS hosts):
  # the lock code's junction fallback (mklink //J) needs real drive-letter
  # translation, and the emulation below is only a POSIX-CI stand-in.
  local real_cygpath
  real_cygpath=$(command -v cygpath 2>/dev/null || true)
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf 'if [ -n "%s" ] && [ -x "%s" ]; then exec "%s" "$@"; fi\n' \
      "$real_cygpath" "$real_cygpath" "$real_cygpath"
    cat <<'SH'
case "${1:-}" in
  -w)
    case "${2:-}" in
      */bash) printf 'C:\\Program Files\\Git\\bin\\bash.exe\n' ;;
      /?/*) d=${2:1:1}; printf '%s:%s\n' "$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')" "${2:2}" | tr '/' '\\' ;;
      *) printf '%s\n' "$2" ;;
    esac ;;
  -u)
    case "${2:-}" in
      ?:\\*) d=${2:0:1}; printf '/%s%s\n' "$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')" "${2:2}" | tr '\\' '/' ;;
      *) printf '%s\n' "$2" ;;
    esac ;;
  *) printf '%s\n' "${2:-}" ;;
esac
exit 0
SH
  } > "$fb/cygpath"
  chmod +x "$fb/cygpath"
  fm_fake_exit0 "$fb" devin
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$fb"
}

# make_win32_case <name> <id> builds a spawn home (devin harness, presentation
# off so the flat path is deterministic), a real project, and a real pooled
# worktree standing in for the lease treehouse will report.
make_win32_case() {
  local name=$1 id=$2 case_dir home proj pool wt fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  pool="$case_dir/pool"
  wt="$pool/1/firstmate"
  fb=$(make_win32_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" devin
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_test_spawn_brief "$home" "$id" "Exercise the Windows-pane worktree arm for $id."
  mkdir -p "$pool"
  printf '{}\n' > "$pool/treehouse-state.json"
  fm_git_worktree "$proj" "$wt" "slot-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fb"
}

run_win32_spawn() {
  local id=$1 fb=$2 home=$3 proj=$4
  FM_HERDR_LOG="$TMP_ROOT/herdr.$id.log" FM_TREEHOUSE_LOG="$TMP_ROOT/treehouse.$id.log" \
    FM_FAKE_LEASE_PATH="$WT_DIR" \
    FM_FAKE_PANE_GET='{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9","cwd":"D:\\proj","focused":false}}}' \
    FM_FAKE_SHELL_JSON='{"result":{"process_info":{"foreground_processes":[{"name":"powershell.exe","pid":42,"argv0":"powershell.exe","argv":["powershell.exe"],"cmdline":"powershell.exe","cwd":"D:\\proj"}],"foreground_process_group_id":42,"pane_id":"w9:p2","shell_pid":42}}}' \
    FM_FAKE_PANE_TEXT='Thinking · 3s (esc twice to interrupt)' \
    fm_test_run_spawn "$home" "$WT_DIR" "$fb" "$id" "$proj" --scout --harness devin --backend herdr
}

# A powershell pane with no foreground_cwd reporting must take the Windows arm:
# enter Git Bash, lease the worktree firstmate-side, and cd the pane to it.
test_windows_arm_leases_and_drives_bash_pane() {
  local rec id out status
  id=win32-arm-lease-z1
  rec=$(make_win32_case win32-arm "$id")
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF

  out=$(run_win32_spawn "$id" "$FAKEBIN_DIR" "$HOME_DIR" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should succeed through the Windows-pane arm"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the leased worktree"
  local hlog tlog
  hlog=$(cat "$TMP_ROOT/herdr.$id.log")
  tlog=$(cat "$TMP_ROOT/treehouse.$id.log")
  assert_contains "$tlog" "get --lease --json --lease-holder fm-$id" \
    "firstmate did not take the durable treehouse lease itself"
  assert_contains "$hlog" 'bash.exe" -l' \
    "the pane was never entered into Git Bash"
  assert_contains "$hlog" "cd -- " \
    "the pane was never driven to the leased worktree"
  [ -f "$(dirname "$WT_DIR")/.fm-slot-owner" ] \
    || fail "the leased slot was not claimed for task $id"
  pass "a foreground-cwd-blind herdr pane is driven through the Git Bash + lease arm"
}

# An unrecognized Windows pane shell must refuse loudly rather than guess.
test_unknown_shell_refuses() {
  local rec id out status
  id=win32-arm-shell-z2
  rec=$(make_win32_case win32-shell "$id")
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF

  out=$(FM_HERDR_LOG="$TMP_ROOT/herdr.$id.log" FM_TREEHOUSE_LOG="$TMP_ROOT/treehouse.$id.log" \
    FM_FAKE_LEASE_PATH="$WT_DIR" \
    FM_FAKE_PANE_GET='{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9","cwd":"D:\\proj","focused":false}}}' \
    FM_FAKE_SHELL_JSON='{"result":{"process_info":{"foreground_processes":[{"name":"fish.exe","pid":42,"argv0":"fish.exe","argv":["fish.exe"],"cmdline":"fish.exe","cwd":"D:\\proj"}],"foreground_process_group_id":42,"pane_id":"w9:p2","shell_pid":42}}}' \
    FM_FAKE_PANE_TEXT='Thinking · 3s (esc twice to interrupt)' \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --harness devin --backend herdr)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an unrecognized Windows pane shell"$'\n'"$out"
  assert_contains "$out" "fish.exe" \
    "the refusal did not name the unrecognized shell"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ ! -e "$TMP_ROOT/treehouse.$id.log" ] || ! grep -q 'get --lease' "$TMP_ROOT/treehouse.$id.log" \
    || fail "a lease was taken before the shell refusal"
  pass "an unrecognized Windows pane shell refuses before leasing"
}

# A pane that never proves it reached the leased worktree must release the
# lease and refuse, not launch blind into the project.
test_unproven_cd_releases_lease_and_refuses() {
  local rec id out status
  id=win32-arm-proof-z3
  rec=$(make_win32_case win32-proof "$id")
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF

  out=$(FM_HERDR_LOG="$TMP_ROOT/herdr.$id.log" FM_TREEHOUSE_LOG="$TMP_ROOT/treehouse.$id.log" \
    FM_FAKE_LEASE_PATH="$WT_DIR" FM_FAKE_CD_PROOF_FAIL=1 \
    FM_FAKE_PANE_GET='{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9","cwd":"D:\\proj","focused":false}}}' \
    FM_FAKE_SHELL_JSON='{"result":{"process_info":{"foreground_processes":[{"name":"powershell.exe","pid":42,"argv0":"powershell.exe","argv":["powershell.exe"],"cmdline":"powershell.exe","cwd":"D:\\proj"}],"foreground_process_group_id":42,"pane_id":"w9:p2","shell_pid":42}}}' \
    FM_FAKE_PANE_TEXT='Thinking · 3s (esc twice to interrupt)' \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --harness devin --backend herdr)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched with an unproven pane worktree"$'\n'"$out"
  assert_contains "$out" "did not reach leased worktree" \
    "the refusal did not name the unproven worktree"
  grep -q 'return --force' "$TMP_ROOT/treehouse.$id.log" \
    || fail "a lease taken before the proof failure was not released"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an unproven pane worktree releases the lease and refuses"
}

test_windows_arm_leases_and_drives_bash_pane
test_unknown_shell_refuses
test_unproven_cd_releases_lease_and_refuses

echo "# all fm-spawn-win32-herdr tests passed"
