#!/usr/bin/env bash
# tests/fm-spawn-herdr-shell-ready.test.sh - end-to-end ordering regression for
# the herdr fresh-pane execution-readiness barrier in bin/fm-spawn.sh.
#
# A newly created herdr pane's zsh can still be running its startup when fm-spawn
# reaches the treehouse-get step (pyenv init contends on a global rehash lock for
# up to ~57s). Before this barrier, fm-spawn submitted `treehouse get` into that
# still-busy pane; it sat queued past the 60s worktree-detection window and the
# unverified pane/Space was torn down (herdr issue #3208).
#
# fm-spawn now calls fm_backend_herdr_wait_shell_ready first, and only submits
# `treehouse get` once the pane's shell is proven to be executing commands. This
# test drives the REAL fm-spawn.sh against a stateful fake herdr whose
# wait-output can be forced to time out, and asserts the safety property that is
# awkward to force with a real shell (you cannot easily make a real shell stay
# busy on demand): when readiness cannot be confirmed, `treehouse get` is NEVER
# submitted and the spawn fails.
#
# The happy path (a shell that DOES become ready) is covered deterministically by
# the adapter unit tests in tests/fm-backend-herdr.test.sh and end to end against
# the real binary by the real-herdr-gated launcher E2E suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-shell-ready)

# make_ready_fakebin: a stateful fake `herdr` that models exactly the flat
# spawn path fm-spawn walks before the readiness barrier (version/server check,
# workspace create, task tab create, seeded-default-tab prune) and then the
# barrier itself:
#   - `pane run <pane> <command>`   appends <command> to FM_FAKE_PANE_RUN_LOG,
#     so the test can prove what was and was not submitted, and in what order.
#   - `pane wait-output ...`        exits with FM_FAKE_WAIT_OUTPUT_EXIT, so the
#     test can force a readiness timeout.
# It reuses the same JSON shapes tests/fm-backend-herdr.test.sh's statefake
# asserts against the real binary in docs/herdr-backend.md.
make_ready_fakebin() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab=${3:-}
    jq_state --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent get")
    # No agent ever registers in this fake; every pane is a husk, which is what
    # the seeded-default-tab prune needs to proceed.
    pane=${3:-}
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    ;;
  "pane run")
    printf '%s\n' "${4:-}" >> "$FM_FAKE_PANE_RUN_LOG"
    ;;
  "pane wait-output")
    exit "${FM_FAKE_WAIT_OUTPUT_EXIT:-0}"
    ;;
  "pane get")
    pane=${3:-}
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
      "$pane" "${FM_FAKE_FOREGROUND_CWD:-/tmp}"
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_ready_case builds a home + a real git project and returns a pipe-joined
# record. No worktree is created: the barrier fails before treehouse get and the
# worktree-detection loop, so none is needed.
make_ready_case() {  # <name> <id> -> record
  local name=$1 id=$2 case_dir home proj fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  fb=$(make_ready_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  # Force the ordinary flat layout so the test does not depend on presentation
  # projection state; the barrier runs on both layouts.
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_init_commit "$proj"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the herdr readiness barrier for $id.

## Firstmate spec
Never submit treehouse get before the pane shell is ready.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$fb"
}

read_ready_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_ready_spawn() {  # <id> <wait-output-exit>
  local id=$1 wait_exit=$2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
      -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_STATE="$FAKEBIN_DIR/../state.json" \
    FM_FAKE_PANE_RUN_LOG="$FAKEBIN_DIR/../pane-run.log" \
    FM_FAKE_WAIT_OUTPUT_EXIT="$wait_exit" \
    FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --backend herdr --mode no-mistakes --yolo off 2>&1
}

# The core safety property: a pane whose shell never becomes ready (wait-output
# times out) must fail the spawn and MUST NOT have `treehouse get` submitted.
test_permanent_busy_pane_never_receives_treehouse_get() {
  local rec id out status runlog
  id=herdr-ready-timeout-z1
  rec=$(make_ready_case ready-timeout "$id")
  read_ready_record "$rec"
  runlog="$FAKEBIN_DIR/../pane-run.log"
  : > "$runlog"

  out=$(run_ready_spawn "$id" 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when the pane shell never becomes ready"$'\n'"$out"
  assert_contains "$out" "did not become ready before treehouse get" \
    "spawn did not report the readiness barrier as the failure cause"
  assert_grep "printf 'FMSHELLRDY" "$runlog" \
    "the readiness probe printf was never submitted to the pane"
  assert_no_grep "treehouse get" "$runlog" \
    "treehouse get was submitted into a pane whose shell never became ready - the exact race this barrier prevents"
  pass "fm-spawn (herdr): a permanently busy pane fails the spawn and never receives treehouse get"
}

# Error propagation is authoritative: the barrier's non-zero return becomes a
# non-zero spawn exit, and no task metadata is recorded for the failed spawn.
test_barrier_failure_records_no_task() {
  local rec id out status
  id=herdr-ready-timeout-z2
  rec=$(make_ready_case ready-notask "$id")
  read_ready_record "$rec"

  out=$(run_ready_spawn "$id" 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail closed on a readiness timeout"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a failed spawn must not record task metadata"
  pass "fm-spawn (herdr): a readiness-barrier failure propagates as a failed spawn with no recorded task"
}

test_permanent_busy_pane_never_receives_treehouse_get
test_barrier_failure_records_no_task

echo "# all fm-spawn-herdr-shell-ready tests passed"
