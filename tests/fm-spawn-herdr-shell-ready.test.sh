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
# test drives the REAL fm-spawn.sh against a stateful fake Herdr capture that
# releases the rendered marker after a deterministic number of polls or never
# releases it. The cases prove delayed success ordering, permanent-busy refusal,
# and the absence of task metadata after a readiness failure.
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
#   - `pane read <pane> ...`        echoes the split-token command until the
#     configured poll releases the contiguous rendered marker.
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
    command=${4:-}
    printf '%s\n' "$command" >> "$FM_FAKE_PANE_RUN_LOG"
    case "$command" in
      "printf 'FMSHELLRDY%s\\n' "*) printf '%s\n' "${command##* }" > "$FM_FAKE_READY_TOKEN_FILE" ;;
    esac
    ;;
  "pane read")
    count=0
    [ ! -f "$FM_FAKE_READY_READ_COUNT_FILE" ] || count=$(cat "$FM_FAKE_READY_READ_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_READY_READ_COUNT_FILE"
    if [ -f "$FM_FAKE_READY_TOKEN_FILE" ]; then
      token=$(cat "$FM_FAKE_READY_TOKEN_FILE")
      printf "printf 'FMSHELLRDY%%s\\\\n' %s\n" "$token"
      if [ "${FM_FAKE_READY_AFTER_POLLS:--1}" -ge 0 ] 2>/dev/null \
        && [ "$count" -ge "$FM_FAKE_READY_AFTER_POLLS" ]; then
        printf 'FMSHELLRDY%s\n' "$token"
      fi
    fi
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
# record, including a real isolated worktree for the delayed-success case.
make_ready_case() {  # <name> <id> -> record
  local name=$1 id=$2 case_dir home proj wt fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  fb=$(make_ready_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  # Force the ordinary flat layout so the test does not depend on presentation
  # projection state; the barrier runs on both layouts.
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the herdr readiness barrier for $id.

## Firstmate spec
Never submit treehouse get before the pane shell is ready.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fb"
}

read_ready_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_ready_spawn() {  # <id> <ready-after-polls> <timeout-ms>
  local id=$1 ready_after=$2 timeout=$3
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
      -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_STATE="$FAKEBIN_DIR/../state.json" \
    FM_FAKE_PANE_RUN_LOG="$FAKEBIN_DIR/../pane-run.log" \
    FM_FAKE_READY_TOKEN_FILE="$FAKEBIN_DIR/../ready-token" \
    FM_FAKE_READY_READ_COUNT_FILE="$FAKEBIN_DIR/../ready-read-count" \
    FM_FAKE_READY_AFTER_POLLS="$ready_after" \
    FM_FAKE_FOREGROUND_CWD="$WT_DIR" \
    FM_BACKEND_HERDR_SHELL_READY_TIMEOUT_MS="$timeout" \
    FM_BACKEND_HERDR_SHELL_READY_POLL_MS=1 \
    FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --backend herdr --mode no-mistakes --yolo off 2>&1
}

test_delayed_shell_success_precedes_treehouse_get() {
  local rec id out status runlog ready_line treehouse_line
  id=herdr-ready-delayed-z0
  rec=$(make_ready_case ready-delayed "$id")
  read_ready_record "$rec"
  runlog="$FAKEBIN_DIR/../pane-run.log"
  : > "$runlog"

  out=$(run_ready_spawn "$id" 3 2000)
  status=$?
  expect_code 0 "$status" "spawn should succeed after delayed shell readiness"
  assert_contains "$out" "spawned $id" "spawn did not report success after readiness released"
  assert_grep "printf 'FMSHELLRDY" "$runlog" "the readiness probe was not submitted"
  grep -Fxq 'treehouse get' "$runlog" || fail "treehouse get was not submitted after readiness released"
  [ "$(cat "$FAKEBIN_DIR/../ready-read-count")" -ge 3 ] || fail "the fake did not hold readiness for the configured initial polls"
  ready_line=$(grep -n -m1 "printf 'FMSHELLRDY" "$runlog" | cut -d: -f1)
  treehouse_line=$(grep -n -m1 '^treehouse get$' "$runlog" | cut -d: -f1)
  [ "$ready_line" -lt "$treehouse_line" ] || fail "treehouse get was submitted before the readiness probe"
  pass "fm-spawn (herdr): delayed shell readiness releases treehouse get in order"
}

# The core safety property: a pane whose shell never renders the marker must
# fail the spawn and MUST NOT have `treehouse get` submitted.
test_permanent_busy_pane_never_receives_treehouse_get() {
  local rec id out status runlog
  id=herdr-ready-timeout-z1
  rec=$(make_ready_case ready-timeout "$id")
  read_ready_record "$rec"
  runlog="$FAKEBIN_DIR/../pane-run.log"
  : > "$runlog"

  out=$(run_ready_spawn "$id" -1 200)
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

  out=$(run_ready_spawn "$id" -1 200)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail closed on a readiness timeout"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a failed spawn must not record task metadata"
  pass "fm-spawn (herdr): a readiness-barrier failure propagates as a failed spawn with no recorded task"
}

test_delayed_shell_success_precedes_treehouse_get
test_permanent_busy_pane_never_receives_treehouse_get
test_barrier_failure_records_no_task

echo "# all fm-spawn-herdr-shell-ready tests passed"
