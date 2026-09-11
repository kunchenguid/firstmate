#!/usr/bin/env bash
# tests/fm-agent-memory-spawn.test.sh - spawn-path integration regressions for
# per-worker memory throttling (bin/fm-agent-memory-lib.sh). Drives the real
# bin/fm-spawn.sh against a fake tmux pane and a real isolated git worktree,
# capturing the exact literal launch command it types into the pane.
#
# Two branches:
#   - not-available (deterministic, every host): a fake `uname` reports a
#     non-Linux OS, forcing fm_agent_memory_systemd_user_available false
#     regardless of what is really installed. The launch must stay bare and
#     meta must record no memory_scope= line - the byte-identical default path
#     every non-systemd host keeps.
#   - available (opportunistic, self-skips without a real `systemd --user`):
#     uses this host's REAL systemd-run/systemctl, since the launch is only
#     ever typed into the fake tmux pane, never executed - proving the wiring
#     against the real tool rather than a stub of it. The launch must be
#     wrapped in systemd-run --user --scope naming the recorded unit, and meta
#     must record memory_scope=/memory_high=/memory_max=/memory_swap_max=.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-memory-lib.sh"

# This file exists to exercise the real wrapper, so its own self-skip check
# below must see real detection rather than tests/lib.sh's global test-suite
# exemption (FM_AGENT_MEMORY_DISABLE=1); run_spawn separately overrides it for
# the spawned fm-spawn.sh child.
unset FM_AGENT_MEMORY_DISABLE

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-memory-spawn)

# fake_spawn_tmux <fakebin>: fake tmux that captures each `send-keys -l`
# payload (the literal launch command) one per line, in order.
fake_spawn_tmux() {
  local fakebin=$1
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
}

# fakebin_not_linux <dir>: fake tmux plus a fake `uname` that reports Darwin,
# so availability is deterministically false no matter what this test host
# really has installed.
fakebin_not_linux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fake_spawn_tmux "$fakebin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -s ] && { printf 'Darwin\n'; exit 0; }
exit 1
SH
  chmod +x "$fakebin/uname"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# fakebin_linux_real_systemd <dir>: same fake tmux, but no uname override, so
# fm_agent_memory_systemd_user_available consults this host's real uname,
# systemd-run, and systemctl through the appended real PATH. `systemctl` is
# still shimmed for its ONE mutating call in this path
# (fm_agent_memory_slice_configure's `set-property` on the real, shared
# firstmate-agents.slice) so this test never reconfigures a live host's
# production slice out from under whatever crews it already has running;
# every other systemctl invocation (the read-only availability probe, etc.)
# still falls through to the real binary.
fakebin_linux_real_systemd() {
  local dir=$1 fakebin real_systemctl
  fakebin=$(fm_fakebin "$dir")
  fake_spawn_tmux "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  real_systemctl=$(command -v systemctl) || real_systemctl=
  if [ -n "$real_systemctl" ]; then
    cat > "$fakebin/systemctl" <<SH
#!/usr/bin/env bash
case "\$*" in
  "--user set-property "*) exit 0 ;;
esac
exec "$real_systemctl" "\$@"
SH
    chmod +x "$fakebin/systemctl"
  fi
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 fakebin_fn=$2 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$("$fakebin_fn" "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the agent-memory spawn wrapping for $id.

## Firstmate spec
Verify the spawned launch command and meta reflect memory throttling.
EOF
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # FM_AGENT_MEMORY_DISABLE=0 overrides tests/lib.sh's global test-suite
  # exemption: this file exists specifically to exercise the real wrapper.
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_AGENT_MEMORY_DISABLE=0 \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

# --- not-available: deterministic, every host -------------------------------

REC1=$(make_spawn_case notlinux fakebin_not_linux)
read_case_record "$REC1"
OUT1=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR") \
  || fail "spawn failed on the not-available branch: $OUT1"
LAUNCH1=$(tail -1 "$LAUNCH_LOG")
case "$LAUNCH1" in
  systemd-run*) fail "launch was wrapped in systemd-run even though availability was forced false: $LAUNCH1" ;;
esac
[ -n "$LAUNCH1" ] || fail "no launch command was captured at all on the not-available branch"
pass "the launch stays bare (unwrapped) when fm_agent_memory_systemd_user_available is false"

META1="$HOME_DIR/state/$CASE_ID.meta"
[ -f "$META1" ] || fail "no meta file was written for $CASE_ID"
grep -q '^memory_scope=' "$META1" && fail "meta recorded memory_scope= on the not-available branch (must stay byte-identical to the pre-feature default path)"
pass "meta records no memory_scope= (or memory_high=/memory_max=/memory_swap_max=) on the not-available branch"

# --- available: opportunistic, self-skips without real systemd --user -------

if ! fm_agent_memory_systemd_user_available; then
  echo "skip: this test host has no real systemd --user session, so the available-branch assertions were skipped"
else
  REC2=$(make_spawn_case linuxreal fakebin_linux_real_systemd)
  read_case_record "$REC2"
  OUT2=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR") \
    || fail "spawn failed on the available branch: $OUT2"
  LAUNCH2=$(tail -1 "$LAUNCH_LOG")
  case "$LAUNCH2" in
    "systemd-run --user --scope --slice='firstmate-agents.slice' --unit='fm-$CASE_ID-"*) ;;
    *) fail "launch was not wrapped as expected on the available branch: $LAUNCH2" ;;
  esac
  pass "the launch is wrapped in systemd-run --user --scope --slice=firstmate-agents.slice --unit=fm-<id>-<gen>.scope when systemd --user is available"

  META2="$HOME_DIR/state/$CASE_ID.meta"
  SCOPE=$(sed -n 's/^memory_scope=//p' "$META2")
  [ -n "$SCOPE" ] || fail "meta recorded no memory_scope= on the available branch"
  case "$LAUNCH2" in *"--unit='$SCOPE' "*) ;; *) fail "recorded memory_scope=$SCOPE does not match the unit named in the launch: $LAUNCH2" ;; esac
  grep -q "^memory_high=$FM_AGENT_MEMORY_WORKER_HIGH_DEFAULT\$" "$META2" || fail "meta memory_high= did not record the default worker high"
  grep -q "^memory_max=$FM_AGENT_MEMORY_WORKER_MAX_DEFAULT\$" "$META2" || fail "meta memory_max= did not record the default worker max"
  grep -q "^memory_swap_max=$FM_AGENT_MEMORY_WORKER_SWAP_MAX_DEFAULT\$" "$META2" || fail "meta memory_swap_max= did not record the default worker swap max"
  pass "meta records memory_scope=/memory_high=/memory_max=/memory_swap_max= matching the launch's unit and configured defaults"
fi

echo "# fm-agent-memory-spawn.test.sh: all assertions passed"
