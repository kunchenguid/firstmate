#!/usr/bin/env bash
# Portable public-interface regression for the task-scoped Herdr/Pi nested-shell
# exit recovery in bin/fm-control.sh.
#
# A stateful Herdr CLI fixture and a process-table fixture drive the real
# `fm-control exit|relaunch` entry points. The positive case proves two stable
# samples of pane-shell -> treehouse get -> nested shell release only the exact
# stale herdr:pi authority, then the existing relaunch transaction reuses the
# endpoint and managed Treehouse copy, rotates generations, starts one Pi, and
# verifies a distinct authority. Liveness cases prove a Pi that is positively
# running keeps the ORDINARY exit path - even when a tool child owns the pane's
# foreground process group, the engine presents as `pi-launcher`, the reported
# cwd is below the worktree, or the Treehouse copy cannot be proved - and that
# an ordinary relaunch on a fleet that only reports a process-detected Pi label
# still completes on its own dead-then-alive proof. Negative
# cases prove changing process evidence, an unknown descendant, a working
# authority, a different cwd, and endpoint/session identity mismatches all
# refuse before release or terminal input. Cross-runtime cases prove the
# cached Pi label Herdr keeps after the release can never stand in for the
# target runtime: a replacement on another harness is reported only once
# exactly one independent target process, with no Pi engine left, is stable
# below the same pane shell. The real-Herdr counterpart is
# tests/fm-control-herdr-pi-relaunch-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-herdr-pi-relaunch)
CASES=()

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_fakebin() {  # <case-dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=$FM_FAKE_HERDR_STATE
log=$FM_FAKE_HERDR_LOG
scenario=$(cat "$FM_FAKE_SCENARIO")
phase=$(cat "$state")
{
  for arg in "$@"; do printf '%s\x1f' "$arg"; done
  printf '\n'
} >> "$log"

# The pane's reported cwd, decided once so pane/agent/process views agree.
cwd=$FM_FAKE_WT
if [ "$phase" = stale ]; then
  case "$scenario" in
    wrong-cwd) cwd=$FM_FAKE_PROJECT ;;
    live-subdir-cwd) cwd=$FM_FAKE_WT/sub ;;
  esac
fi

json_agent() {
  local status=$1 session=$2 source=${3:-herdr:pi}
  jq -cn \
    --arg pane w1:p2 --arg tab w1:t2 --arg workspace w1 \
    --arg cwd "$cwd" --arg status "$status" --arg session "$session" --arg source "$source" '
      {id:"cli:agent:get",result:{type:"agent_info",agent:{
        agent:"pi",agent_status:$status,state_change_seq:7,pane_id:$pane,tab_id:$tab,workspace_id:$workspace,
        foreground_cwd:$cwd,agent_session:{agent:"pi",kind:"id",source:$source,value:$session}
      }}}
  '
}

json_released_agent() {
  jq -cn --arg cwd "$FM_FAKE_WT" '
    {id:"cli:agent:get",result:{type:"agent_info",agent:{
      agent:"pi",agent_status:"idle",state_change_seq:8,screen_detection_skipped:false,
      pane_id:"w1:p2",tab_id:"w1:t2",workspace_id:"w1",foreground_cwd:$cwd,agent_session:null
    }}}
  '
}

case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"version":"0.8.2","protocol":20}}'
    ;;
  "api schema")
    printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"pane.clear_agent_authority"}}}]}}}'
    ;;
  "session list")
    jq -cn --arg socket "$FM_FAKE_SOCKET" '{sessions:[{name:"lab",running:true,socket_path:$socket}]}'
    ;;
  "pane get")
    status=unknown
    session=
    source=herdr:pi
    case "$phase" in
      stale)
        status=idle
        session=$FM_FAKE_OLD_SESSION
        [ "$scenario" != working ] || status=working
        [ "$scenario" != identity-source ] || source=synthetic:pi
        ;;
      new)
        status=idle
        session=$FM_FAKE_NEW_SESSION
        [ "$scenario" != process-detected ] || session=
        ;;
    esac
    jq -cn \
      --arg cwd "$cwd" --arg status "$status" --arg session "$session" --arg source "$source" '
        {id:"cli:pane:get",result:{type:"pane_info",pane:{
          pane_id:"w1:p2",tab_id:"w1:t2",workspace_id:"w1",foreground_cwd:$cwd,
          agent_status:$status,
          agent_session:(if $session == "" then null else {agent:"pi",kind:"id",source:$source,value:$session} end)
        }}}
      '
    ;;
  "tab get")
    label=fm-rp1
    workspace=w1
    [ "$scenario" != identity-tab ] || label=fm-other
    [ "$scenario" != identity-workspace ] || workspace=w9
    jq -cn --arg label "$label" --arg workspace "$workspace" '
      {id:"cli:tab:get",result:{type:"tab_info",tab:{tab_id:"w1:t2",workspace_id:$workspace,label:$label}}}
    '
    ;;
  "agent get")
    case "$phase" in
      quit) printf '%s\n' '{"id":"cli:agent:get","error":{"code":"agent_not_found","message":"no agent in pane"}}' ;;
      released) json_released_agent ;;
      stale)
        status=idle
        source=herdr:pi
        session=$FM_FAKE_OLD_SESSION
        [ "$scenario" != working ] || status=working
        [ "$scenario" != identity-source ] || source=synthetic:pi
        # The relaunch reads the identity it must prove the replacement
        # distinct from once, as the first agent read after the transaction
        # reaches its `stopping` phase. Serving only that read an unvalidatable
        # generation leaves the release proof below intact, so the refusal it
        # produces is the identity gap alone.
        if [ "$scenario" = transient-unreadable-prior ] \
           && grep -q '^phase=stopping$' "${FM_FAKE_META%.meta}.control-relaunch" 2>/dev/null \
           && [ ! -s "$FM_FAKE_PRIOR_READ" ]; then
          printf '%s\n' read > "$FM_FAKE_PRIOR_READ"
          session=not-a-valid-generation
        fi
        json_agent "$status" "$session" "$source"
        ;;
      new)
        # A fleet that never anchors an official herdr:pi session reports only
        # its conservative process-detected Pi label.
        if [ "$scenario" = process-detected ]; then
          json_released_agent
        else
          json_agent idle "$FM_FAKE_NEW_SESSION"
        fi
        ;;
    esac
    ;;
  "pane process-info")
    count=$(($(cat "$FM_FAKE_PROCESS_COUNT" 2>/dev/null || echo 0) + 1))
    printf '%s\n' "$count" > "$FM_FAKE_PROCESS_COUNT"
    shell=101
    foreground=303
    name=zsh
    argv0=/bin/zsh
    if [ "$phase" = new ]; then
      foreground=404
      name=pi
      argv0=pi
    else
      case "$scenario" in
        # A fresh nested-shell pid on every sample, so the churn refusal never
        # depends on how many times the proof happens to read the pane.
        changing-process) foreground=$((300 + count)) ;;
        live-child) foreground=505; name=bash; argv0=/bin/bash ;;
        live-launcher) foreground=404; name=pi-launcher; argv0=pi-launcher ;;
        live-subdir-cwd) foreground=505; name=git; argv0=/usr/bin/git ;;
        process-detected) foreground=404; name=pi; argv0=pi ;;
      esac
    fi
    jq -cn \
      --argjson shell "$shell" --argjson foreground "$foreground" \
      --arg name "$name" --arg argv0 "$argv0" --arg cwd "$cwd" '
        {id:"cli:pane:process_info",result:{type:"pane_process_info",process_info:{
          pane_id:"w1:p2",shell_pid:$shell,foreground_process_group_id:$foreground,
          foreground_processes:[{pid:$foreground,name:$name,argv0:$argv0,cwd:$cwd}]
        }}}
    '
    ;;
  "pane send-text")
    printf '%s\n' "${4:-}" > "$FM_FAKE_PENDING_LAUNCH"
    ;;
  "pane send-keys")
    if [ "${4:-}" = enter ] && [ -s "$FM_FAKE_PENDING_LAUNCH" ]; then
      case "$(cat "$FM_FAKE_PENDING_LAUNCH")" in
        /quit*) printf '%s\n' quit > "$state" ;;
        *) printf '%s\n' new > "$state" ;;
      esac
    fi
    ;;
  "pane run") : ;;
  "pane read") printf '────────────────\n\n────────────────\n' ;;
  *) : ;;
esac
SH
  chmod +x "$fb/herdr"

  cat > "$fb/ps-fixture" <<'SH'
#!/usr/bin/env bash
set -u
scenario=$(cat "$FM_FAKE_SCENARIO")
phase=$(cat "$FM_FAKE_HERDR_STATE")
ps_count=$(($(cat "$FM_FAKE_PS_COUNT" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$ps_count" > "$FM_FAKE_PS_COUNT"

# One row set (pid ppid pgid stat comm args) projected into whichever columns
# the caller asked for, so every ps view of this fixture agrees with the pane
# process-info the herdr fixture reports for the same sample.
rows() {
  if [ "$phase" = new ] && [ "$scenario" = signed ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S pi-signed pi-signed
405 404 404 S pi pi
EOF
  elif [ "$phase" = new ] && [ "$scenario" = cross-target ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S codex /usr/local/bin/codex
EOF
  elif [ "$phase" = new ] && [ "$scenario" = cross-target-nested ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S codex /usr/local/bin/codex
405 404 404 S codex /usr/local/bin/codex
EOF
  elif [ "$phase" = new ] && [ "$scenario" = cross-target-duplicate ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S codex /usr/local/bin/codex
406 303 406 S codex /usr/local/bin/codex
EOF
  elif [ "$phase" = new ] && [ "$scenario" = cross-lingering-pi ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S codex /usr/local/bin/codex
405 303 405 S pi pi
EOF
  elif [ "$phase" = new ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S pi pi
EOF
  elif [ "$phase" = stale ] && [ "$scenario" = live-child ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S pi pi
505 404 505 S bash /bin/bash
EOF
  elif [ "$phase" = stale ] && [ "$scenario" = live-launcher ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S pi-launcher /opt/pi/bin/pi-launcher
EOF
  elif [ "$phase" = stale ] && [ "$scenario" = live-subdir-cwd ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
404 303 404 S pi pi
505 404 505 S git /usr/bin/git status
EOF
  elif [ "$scenario" = late-descendant ] && [ "$phase" = released ] \
       && grep -q '^control_relaunch_tx=' "$FM_FAKE_META" 2>/dev/null; then
    # The replacement record is published, so this is the launch-boundary
    # recheck rather than the pre-launch admission read.
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
999 303 999 S mystery mystery
EOF
  elif [ "$scenario" = unknown-descendant ]; then
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
999 303 999 S mystery mystery
EOF
  elif [ "$scenario" = changing-process ]; then
    nested=$((300 + $(cat "$FM_FAKE_PROCESS_COUNT" 2>/dev/null || echo 0)))
    cat <<EOF
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
$nested 202 $nested S zsh /bin/zsh
EOF
  else
    cat <<'EOF'
101 1 101 S zsh -zsh
202 101 202 S treehouse treehouse get
303 202 303 S zsh /bin/zsh
EOF
  fi
}

if printf '%s\n' "$*" | grep -Fq 'args='; then
  rows
elif printf '%s\n' "$*" | grep -Fq 'stat=,comm='; then
  rows | awk '{ print $1, $2, $4, $5 }'
else
  rows | awk '{ print $1, $2, $5 }'
fi
SH
  chmod +x "$fb/ps-fixture"

  cat > "$fb/authority-clear" <<'SH'
#!/usr/bin/env bash
set -u
printf 'authority-clear\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" >> "$FM_FAKE_HERDR_LOG"
printf '%s\n' released > "$FM_FAKE_HERDR_STATE"
SH
  chmod +x "$fb/authority-clear"

  cat > "$fb/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf 'Usage: pi [options]\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/pi"
  cp "$fb/pi" "$fb/pi-signed"
  cp "$fb/pi" "$fb/codex"
  cp "$fb/pi" "$fb/muse"
}

new_case() {  # <name> <scenario> [harness]
  local name=$1 scenario=$2 harness=${3:-pi} dir project pool wt home gen
  dir="$TMP_ROOT/$name"
  project="$dir/project"
  pool="$dir/pool"
  wt="$pool/1/repo"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data/rp1" "$pool/1"
  git -C "$dir" init -q project
  printf '# fixture\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$project" worktree add --quiet -b "case-$name" "$wt"
  printf '%s\n' '{}' > "$pool/treehouse-state.json"
  mkdir -p "$wt/sub"
  printf '%s\n' "$scenario" > "$dir/scenario"
  printf '%s\n' stale > "$dir/herdr-state"
  : > "$dir/herdr.log"
  : > "$dir/process-count"
  : > "$dir/ps-count"
  : > "$dir/pending-launch"
  : > "$dir/prior-read"
  : > "$dir/herdr.sock"
  printf '%s\n' '11111111-1111-7111-8111-111111111111' > "$dir/old-session-id"
  printf '%s\n' '22222222-2222-7222-8222-222222222222' > "$dir/new-session-id"
  cat > "$home/data/rp1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the Herdr Pi relaunch regression.

## Firstmate spec
Preserve the exact endpoint and copy.

Delivery contract: mode=no-mistakes
EOF
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" rp1)
  cat > "$home/state/rp1.meta" <<EOF
window=lab:w1:p2
endpoint_task_id=rp1
worktree=$wt
project=$project
harness=$harness
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=lab
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
busy_gen=$gen
spawn_gen=old-generation
EOF
  make_fakebin "$dir"
  CASES+=("$dir")
  printf '%s\n' "$dir"
}

run_control() {  # <case-dir> <control args...>
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_STATE="$dir/herdr-state" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
    FM_FAKE_SCENARIO="$dir/scenario" FM_FAKE_PROCESS_COUNT="$dir/process-count" \
    FM_FAKE_PS_COUNT="$dir/ps-count" \
    FM_FAKE_PENDING_LAUNCH="$dir/pending-launch" FM_FAKE_SOCKET="$dir/herdr.sock" \
    FM_FAKE_PRIOR_READ="$dir/prior-read" \
    FM_FAKE_PROJECT="$dir/project" FM_FAKE_WT="$dir/pool/1/repo" \
    FM_FAKE_META="$dir/home/state/rp1.meta" \
    FM_FAKE_OLD_SESSION="$(cat "$dir/old-session-id")" FM_FAKE_NEW_SESSION="$(cat "$dir/new-session-id")" \
    FM_HERDR_PS_BIN="$dir/fakebin/ps-fixture" \
    FM_CONTROL_HERDR_PI_AUTHORITY_CLEARER="$dir/fakebin/authority-clear" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.03 \
    FM_CONTROL_LAUNCH_WAIT="${FM_TEST_LAUNCH_WAIT:-1}" \
    FM_CONTROL_HERDR_SAMPLE_WAIT=0 \
    "$CONTROL" "$@" 2>&1
}

assert_no_terminal_or_release() {  # <case-dir> <label>
  local calls
  calls=$(cat "$1/herdr.log")
  assert_not_contains "$calls" 'authority-clear' "$2 unexpectedly cleared Herdr authority"
  assert_not_contains "$calls" $'pane\x1fsend-text' "$2 typed lifecycle text into the endpoint"
  assert_not_contains "$calls" $'pane\x1fsend-keys' "$2 submitted lifecycle input into the endpoint"
  assert_not_contains "$calls" $'pane\x1frun' "$2 ran lifecycle input in the endpoint"
}

# The complete positive path goes through the public relaunch entry point.
dir=$(new_case positive stable)
gen_before=$(grep '^busy_gen=' "$dir/home/state/rp1.meta" | cut -d= -f2-)
out=$(run_control "$dir" rp1 relaunch --note 'continue after the real Pi exit')
rc=$?
expect_code 0 "$rc" "the exact stable nested-shell exit should relaunch safely"$'\n'"$out"
assert_contains "$out" 'relaunched rp1 harness=pi from=pi' "the relaunch did not report the replacement"
[ "$(grep '^window=' "$dir/home/state/rp1.meta" | cut -d= -f2-)" = 'lab:w1:p2' ] \
  || fail "the relaunch changed the exact endpoint"
[ "$(grep '^worktree=' "$dir/home/state/rp1.meta" | cut -d= -f2-)" = "$dir/pool/1/repo" ] \
  || fail "the relaunch changed the managed Treehouse copy"
gen_after=$(grep '^busy_gen=' "$dir/home/state/rp1.meta" | cut -d= -f2-)
[ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] || fail "the relaunch did not rotate the busy generation"
[ "$(cat "$dir/herdr-state")" = new ] || fail "the replacement never acquired new Herdr authority"
release_count=$(grep -c '^authority-clear' "$dir/herdr.log" || true)
launch_count=$(grep -c 'encode launch-brief' "$dir/herdr.log" || true)
[ "$release_count" -eq 1 ] || fail "the stable exit should release exactly one stale authority, saw $release_count"
[ "$launch_count" -eq 1 ] || fail "the relaunch should start exactly one replacement Pi, saw $launch_count"
assert_not_contains "$(cat "$dir/herdr.log")" '/quit' "an already-exited Pi caused /quit to be typed into the nested shell"
[ "$(grep -c $'pane\x1fprocess-info' "$dir/herdr.log" || true)" -ge 4 ] \
  || fail "the old exit and new authority were not each sampled stably"
pass "fm-control Herdr/Pi: two stable nested-shell samples release one stale authority and relaunch one Pi in the same endpoint and copy"

# pi-signed retains its wrapper while the Pi engine runs below it. The same
# recovery accepts exactly one wrapper plus exactly one engine, not one of each
# in isolation or a generic interpreter process.
dir=$(new_case positive-signed signed pi-signed)
out=$(run_control "$dir" rp1 relaunch --note 'continue after the signed Pi exit')
rc=$?
expect_code 0 "$rc" "the exact signed-wrapper replacement should relaunch safely"$'\n'"$out"
assert_contains "$out" 'relaunched rp1 harness=pi-signed from=pi-signed' "the signed relaunch did not preserve its adapter"
[ "$(grep -c 'encode launch-brief' "$dir/herdr.log" || true)" -eq 1 ] \
  || fail "the signed relaunch should start exactly one replacement"
pass "fm-control Herdr/Pi: pi-signed replacement requires one signed wrapper and one Pi engine"

# A recovered stale Pi may be relaunched onto another supported runtime. The
# release proof describes the harness that was RELEASED, so it must keep
# validating against that after fm-spawn republishes the record on the target.
dir=$(new_case cross-harness signed pi)
out=$(run_control "$dir" rp1 relaunch --harness pi-signed --note 'resume on the signed wrapper')
rc=$?
expect_code 0 "$rc" "a released Pi should relaunch onto another supported harness"$'\n'"$out"
assert_contains "$out" 'relaunched rp1 harness=pi-signed from=pi' "the cross-harness relaunch did not retarget the adapter"
[ "$(grep '^harness=' "$dir/home/state/rp1.meta" | cut -d= -f2-)" = pi-signed ] \
  || fail "the cross-harness relaunch did not republish the target harness"
[ "$(grep -c '^authority-clear' "$dir/herdr.log" || true)" -eq 1 ] \
  || fail "the cross-harness relaunch should release exactly one stale authority"
[ "$(grep -c 'encode launch-brief' "$dir/herdr.log" || true)" -eq 1 ] \
  || fail "the cross-harness relaunch should start exactly one replacement"
pass "fm-control Herdr/Pi: a released stale authority still admits a relaunch onto another supported harness"

# Releasing the authority leaves Herdr's cached process-detected `pi` label in
# place, so the generic `alive` verdict describes the agent that already
# exited. A cross-runtime replacement is reported only once the TARGET runtime
# itself is stable in the recorded pane and copy.
dir=$(new_case cross-runtime-verified cross-target pi)
out=$(run_control "$dir" rp1 relaunch --harness codex --note 'resume on another runtime')
rc=$?
expect_code 0 "$rc" "a proven target-runtime replacement should relaunch"$'\n'"$out"
assert_contains "$out" 'relaunched rp1 harness=codex from=pi' "the cross-runtime relaunch did not retarget the adapter"
assert_contains "$(cat "$dir/home/state/rp1.control-relaunch")" 'herdr_pi_authority=released-target-engine' \
  "the completed transaction did not record which proof accepted the replacement"

# The same shape with the harness running its own nested worker chain: two
# contiguous target processes are ONE replacement, not two.
dir=$(new_case cross-runtime-nested cross-target-nested pi)
out=$(run_control "$dir" rp1 relaunch --harness codex --note 'resume on another runtime')
rc=$?
expect_code 0 "$rc" "a target runtime's own nested worker chain is one replacement"$'\n'"$out"
assert_contains "$out" 'relaunched rp1 harness=codex from=pi' "the nested-chain replacement was not accepted"
pass "fm-control Herdr/Pi: a cross-runtime replacement is proved from the target runtime's own processes, nested chain included"

# The regression this proof exists for: nothing started, but Herdr still
# reports the released Pi label as `alive`. Reporting that as a relaunch would
# leave the record published on the new harness with no agent.
# These three proofs can never succeed, so they only need long enough to prove
# they time out rather than the full default launch budget.
FM_TEST_LAUNCH_WAIT=0.05
dir=$(new_case cross-runtime-vacuous cross-none pi)
out=$(run_control "$dir" rp1 relaunch --harness codex --note 'resume on another runtime')
rc=$?
[ "$rc" -ne 0 ] || fail "a cached Pi label must not prove a codex replacement launched: $out"
assert_contains "$out" 'could not be verified as exactly one stable codex process' \
  "the refusal did not name the postcondition it could not prove"
assert_not_contains "$out" 'relaunched rp1' "an unproven replacement was reported as relaunched"

# A Pi engine still running below the pane shell is a duplicate-worker risk,
# never evidence for the target runtime.
dir=$(new_case cross-runtime-lingering-pi cross-lingering-pi pi)
out=$(run_control "$dir" rp1 relaunch --harness codex --note 'resume on another runtime')
rc=$?
[ "$rc" -ne 0 ] || fail "a surviving Pi engine must refuse the cross-runtime replacement: $out"
assert_not_contains "$out" 'relaunched rp1' "a surviving Pi engine was reported as a completed relaunch"

# Two independent target processes in one pane is exactly the duplicate worker
# this whole recovery exists to prevent.
dir=$(new_case cross-runtime-duplicate cross-target-duplicate pi)
out=$(run_control "$dir" rp1 relaunch --harness codex --note 'resume on another runtime')
rc=$?
[ "$rc" -ne 0 ] || fail "two independent target processes must refuse: $out"
assert_not_contains "$out" 'relaunched rp1' "a duplicated replacement was reported as a completed relaunch"
pass "fm-control Herdr/Pi: no replacement, a surviving Pi engine, and a duplicated target all refuse instead of riding the cached Pi label"
FM_TEST_LAUNCH_WAIT=

# An adapter whose process identity the proof cannot read is ambiguity, so the
# relaunch refuses rather than accepting the cached Pi label as evidence.
dir=$(new_case cross-runtime-unnameable cross-target pi)
mkdir -p "$dir/user-home/.config/muse"
printf '%s\n' '{"api_key":"fixture"}' > "$dir/user-home/.config/muse/auth.json"
out=$(run_control "$dir" rp1 relaunch --harness muse --note 'resume on an unreadable runtime')
rc=$?
[ "$rc" -ne 0 ] || fail "an unnameable target runtime must refuse: $out"
assert_contains "$out" 'no process identity this proof can read' \
  "the refusal did not name why the target runtime could not be proved"
assert_not_contains "$out" 'relaunched rp1' "an unprovable target runtime was reported as relaunched"
pass "fm-control Herdr/Pi: a target runtime with no readable process identity refuses instead of being reported as relaunched"

# Not every Herdr fleet anchors an official herdr:pi session; some only ever
# expose the conservative process-detected Pi label. An ordinary relaunch there
# reads its endpoint `dead` before launching, so the following `alive` is its
# own proof, and the stale-authority identity postcondition must not be imposed
# on a replacement that is demonstrably running.
dir=$(new_case healthy-process-detected process-detected)
out=$(run_control "$dir" rp1 relaunch --note 'ordinary relaunch of a live Pi')
rc=$?
expect_code 0 "$rc" "an ordinary relaunch must not require an official herdr:pi session"$'\n'"$out"
assert_contains "$out" 'relaunched rp1 harness=pi from=pi' "the ordinary relaunch did not report the replacement"
assert_contains "$(cat "$dir/herdr.log")" '/quit' "the live worker never received the ordinary harness exit command"
assert_not_contains "$(cat "$dir/herdr.log")" 'authority-clear' \
  "a live Pi's ordinary relaunch released Herdr authority"
[ "$(grep -c 'encode launch-brief' "$dir/herdr.log" || true)" -eq 1 ] \
  || fail "the ordinary relaunch should start exactly one replacement"
pass "fm-control Herdr/Pi: a healthy Pi relaunch on a process-detected fleet keeps its own dead-then-alive proof"

# An unvalidatable Pi session generation is ambiguity inside the release proof
# itself, so the relaunch refuses before any authority is cleared or any
# lifecycle text is typed.
dir=$(new_case negative-invalid-session-generation stable)
printf '%s\n' 'not-a-valid-generation' > "$dir/old-session-id"
out=$(run_control "$dir" rp1 relaunch --note 'exercise the unvalidatable generation')
rc=$?
[ "$rc" -ne 0 ] || fail "an unvalidatable Pi session generation should refuse: $out"
assert_contains "$out" 'could not be proved stable' \
  "the refusal did not name the conservative proof"
assert_no_terminal_or_release "$dir" "invalid-session-generation"
pass "fm-control Herdr/Pi: an unvalidatable Pi session generation refuses before release or terminal input"

# The postcondition for a RELEASED authority is "a DISTINCT valid herdr:pi
# generation". If the identity that was released could not be read, that test
# is vacuous, so no replacement is launched rather than any session being
# accepted as new.
dir=$(new_case negative-unreadable-prior-session transient-unreadable-prior)
out=$(run_control "$dir" rp1 relaunch --note 'exercise the ambiguous prior identity')
rc=$?
[ "$rc" -ne 0 ] || fail "an unreadable prior Pi session identity should refuse: $out"
assert_contains "$out" 'DISTINCT herdr:pi generation' \
  "the refusal did not name the postcondition it could not have proved"
[ "$(grep -c '^authority-clear' "$dir/herdr.log" || true)" -eq 1 ] \
  || fail "the fixture should have released exactly the stale authority before the identity gap refused"
[ "$(grep -c 'encode launch-brief' "$dir/herdr.log" || true)" -eq 0 ] \
  || fail "a replacement was launched with no readable prior identity to prove it distinct from"
assert_not_contains "$(cat "$dir/herdr.log")" '/quit' \
  "the ambiguous prior identity path typed /quit into the nested shell"
[ ! -e "$dir/home/state/rp1.herdr-pi-release-proof" ] \
  || fail "a refused replacement left its private release capability behind"
pass "fm-control Herdr/Pi: an unreadable prior Pi session identity refuses instead of weakening the distinctness proof"

for scenario in changing-process unknown-descendant working wrong-cwd identity-source identity-tab identity-workspace; do
  dir=$(new_case "negative-$scenario" "$scenario")
  out=$(run_control "$dir" rp1 exit)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$scenario should refuse rather than infer that Pi exited: $out"
  assert_contains "$out" 'could not be proved stable' "$scenario refusal did not name the conservative proof"
  assert_no_terminal_or_release "$dir" "$scenario"
done
pass "fm-control Herdr/Pi: churn, an unknown descendant, working state, cwd drift, and identity mismatches all refuse without mutation or terminal input"

# A Pi engine that is positively running keeps the ORDINARY exit path. The
# recovery exception only ever replaces a refusal it would otherwise have to
# make, so none of these shapes may turn `exit` into a hard stop: a tool child
# owning the pane's foreground process group, an engine that presents as
# `pi-launcher`, or a reported cwd below the worktree because that child holds
# the foreground group.
for scenario in live-child live-launcher live-subdir-cwd; do
  dir=$(new_case "live-$scenario" "$scenario")
  out=$(run_control "$dir" rp1 exit)
  rc=$?
  expect_code 0 "$rc" "a visibly running Pi ($scenario) should take the ordinary exit path"$'\n'"$out"
  assert_contains "$out" 'stopped rp1' "$scenario did not report an ordinary stop"
  assert_contains "$(cat "$dir/herdr.log")" '/quit' "$scenario never submitted the harness exit command"
  assert_not_contains "$(cat "$dir/herdr.log")" 'authority-clear' \
    "$scenario released Herdr authority for a Pi that is still running"
done
pass "fm-control Herdr/Pi: a foreground tool child, a pi-launcher process name, and a nested foreground cwd all keep the ordinary live exit"

# Treehouse ownership is a precondition for RELEASING someone else's authority,
# never for typing into a pane that provably still hosts Pi. A copy whose
# managed identity cannot be proved must not take ordinary exit away from a
# worker that is running normally.
dir=$(new_case live-unprovable-copy live-child)
rm "$dir/pool/treehouse-state.json"
out=$(run_control "$dir" rp1 exit)
rc=$?
expect_code 0 "$rc" "an unprovable Treehouse copy must not block a live Pi's ordinary exit"$'\n'"$out"
assert_contains "$out" 'stopped rp1' "the live worker did not report an ordinary stop"
assert_not_contains "$(cat "$dir/herdr.log")" 'authority-clear' \
  "an unprovable copy gained stale-authority release rights"
pass "fm-control Herdr/Pi: ownership is proved before release, not before ordinary lifecycle control"

# The launch half re-runs the complete process proof after the release proof is
# published. A descendant that appears in that final gap prevents terminal
# submission even though the stale authority was already cleared.
dir=$(new_case negative-late-descendant late-descendant)
out=$(run_control "$dir" rp1 relaunch --note 'exercise the pre-launch race')
rc=$?
[ "$rc" -ne 0 ] || fail "a descendant appearing before replacement launch should refuse: $out"
assert_contains "$out" 'could not be launched' "the late descendant did not stop at the launch boundary"
[ "$(grep -c '^authority-clear' "$dir/herdr.log" || true)" -eq 1 ] \
  || fail "the race fixture should clear exactly the stale authority before the late descendant appears"
[ "$(grep -c 'encode launch-brief' "$dir/herdr.log" || true)" -eq 0 ] \
  || fail "a late descendant was allowed to receive replacement launch text"
[ ! -e "$dir/home/state/rp1.herdr-pi-release-proof" ] \
  || fail "a refused replacement left its private release capability behind"
assert_not_contains "$(cat "$dir/herdr.log")" '/quit' "the race path typed /quit into the nested shell"
pass "fm-control Herdr/Pi: the replacement launch boundary rechecks the full process tree and refuses a late descendant"

# Missing Treehouse ownership is also ambiguity, not a generic shell-is-dead rule.
dir=$(new_case negative-missing-copy stable)
rm "$dir/pool/treehouse-state.json"
out=$(run_control "$dir" rp1 exit)
rc=$?
[ "$rc" -ne 0 ] || fail "a copy with no managed Treehouse identity should refuse: $out"
assert_no_terminal_or_release "$dir" "missing-copy"
pass "fm-control Herdr/Pi: a linked worktree without exact Treehouse ownership never gains stale-agent release authority"
