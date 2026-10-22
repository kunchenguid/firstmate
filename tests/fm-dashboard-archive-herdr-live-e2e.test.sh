#!/usr/bin/env bash
# Real guarded-Herdr lifecycle proof for Dashboard archive cleanup.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_DASHBOARD_ARCHIVE_HERDR_LIVE herdr jq treehouse git

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name add-dashboard-task-archive-button-20261022)
ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-dashboard-archive-herdr-live)
HOME_FIXTURE="$TMP_ROOT/home"
SHIM="$TMP_ROOT/shim"
PROJECT=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
LEASED_WORKTREE=
LEASED_MANAGED_WORKTREE=
TEST_OWNER_BASHPID=$BASHPID

cleanup() {
  local status=$?
  [ "$BASHPID" = "$TEST_OWNER_BASHPID" ] || return 0
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  # A failed assertion deliberately leaves an unreturned lease for inspection.
  # Never force-return a path whose exact task ownership may already have changed.
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/data" "$HOME_FIXTURE/config" "$SHIM"
cat > "$SHIM/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$SHIM/herdr"
export HERDR_LAB_HELPER HERDR_LAB_SESSION ORIGINAL_PATH

lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

write_task_meta() { # <id> <generation> <worktree> <workspace-json>
  local id=$1 generation=$2 worktree=$3 workspace_json=$4 workspace tab pane
  workspace=$(printf '%s' "$workspace_json" | jq -er '.result.workspace.workspace_id')
  tab=$(printf '%s' "$workspace_json" | jq -er '.result.tab.tab_id')
  pane=$(printf '%s' "$workspace_json" | jq -er '.result.root_pane.pane_id')
  {
    printf 'backend=herdr\nharness=traex\n'
    printf 'window=%s:%s\nendpoint_task_id=%s\n' "$HERDR_LAB_SESSION" "$pane" "$id"
    printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
      "$HERDR_LAB_SESSION" "$workspace" "$tab" "$pane"
    printf 'worktree=%s\nproject=%s\nkind=ship\nmode=review-PR\nspawn_gen=%s\n' \
      "$worktree" "$PROJECT" "$generation"
  } > "$HOME_FIXTURE/state/$id.meta"
  printf '%s\t%s\t%s\n' "$workspace" "$tab" "$pane"
}

archive_task() { # <id> <generation>
  local id=$1 generation=$2 updated
  updated=$(jq -r '.updated_at' "$HOME_FIXTURE/data/$id/task.json")
  PATH="$SHIM:$ORIGINAL_PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-dashboard-archive.sh" "$id" --expect-state in_flight \
      --expect-updated-at "$updated" --expect-spawn-gen "$generation"
}

# A clean, exact Treehouse lease is returned after the exact lab pane closes.
LEASED_MANAGED_WORKTREE=$(cd "$PROJECT" && treehouse get --lease --lease-holder dashboard-archive-live)
LEASED_WORKTREE=$(cd "$LEASED_MANAGED_WORKTREE" && pwd -P)
clean_id=archive-clean-copy
clean_generation=archive-clean-g1
FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-tasks-axi.sh" add "$clean_id" 'Archive clean processing task' --kind ship --start >/dev/null
clean_workspace=$(lab workspace create --cwd "$LEASED_WORKTREE" --label archive-clean --no-focus)
IFS=$'\t' read -r _clean_workspace _clean_tab clean_pane <<< "$(write_task_meta "$clean_id" "$clean_generation" "$LEASED_WORKTREE" "$clean_workspace")"
FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" bash -c \
  '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" "$3" "$4" "$5"' \
  _ "$ROOT" "$LEASED_WORKTREE" "$clean_id" "$HOME_FIXTURE" "$clean_generation"
clean_result=$(archive_task "$clean_id" "$clean_generation")
printf '%s' "$clean_result" | jq -e '.archive=="archived" and .cleanup=="completed"' >/dev/null \
  || fail "clean archive did not report completed cleanup: $clean_result"
[ ! -e "$HOME_FIXTURE/state/$clean_id.meta" ] || fail 'clean archive retained execution metadata'
lab pane get "$clean_pane" >/dev/null 2>&1 && fail 'clean archive retained its exact Herdr pane'
clean_receipt=$(FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" FM_DATA_OVERRIDE="$HOME_FIXTURE/data" bash -c \
  '. "$1/bin/fm-cleanup-receipt-lib.sh"; fm_cleanup_receipt completion-read "$2" "$3"' \
  _ "$ROOT" "$clean_id" "$clean_generation")
printf '%s' "$clean_receipt" | jq -e '.facts.endpointConfirmedGone==true and .facts.copyDisposition=="returned-or-already-absent" and .facts.bookkeepingComplete==true' >/dev/null \
  || fail 'clean archive receipt did not prove endpoint cleanup and Treehouse return'
clean_status=$(cd "$PROJECT" && treehouse status --json)
printf '%s' "$clean_status" | jq -e --arg path "$LEASED_MANAGED_WORKTREE" '.[] | select(.path==$path) | .status=="available"' >/dev/null \
  || fail 'Treehouse did not report the clean task slot as returned'
LEASED_WORKTREE=
LEASED_MANAGED_WORKTREE=

# A primary/dirty task copy is retained while the exact endpoint and runtime
# records still retire, proving archive is not permission to discard work.
retained_id=archive-retained-copy
retained_generation=archive-retained-g1
FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-tasks-axi.sh" add "$retained_id" 'Archive retained processing task' --kind ship --start >/dev/null
retained_workspace=$(lab workspace create --cwd "$ROOT" --label archive-retained --no-focus)
IFS=$'\t' read -r _ _ retained_pane <<< "$(write_task_meta "$retained_id" "$retained_generation" "$ROOT" "$retained_workspace")"
retained_result=$(archive_task "$retained_id" "$retained_generation")
printf '%s' "$retained_result" | jq -e '.archive=="archived" and .cleanup=="retained"' >/dev/null \
  || fail "retained archive did not distinguish its copy result: $retained_result"
lab pane get "$retained_pane" >/dev/null 2>&1 && fail 'retained archive retained its exact Herdr pane'
[ -d "$ROOT" ] || fail 'retained archive removed the protected primary copy'
retained_receipt=$(FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" FM_DATA_OVERRIDE="$HOME_FIXTURE/data" bash -c \
  '. "$1/bin/fm-cleanup-receipt-lib.sh"; fm_cleanup_receipt completion-read "$2" "$3"' \
  _ "$ROOT" "$retained_id" "$retained_generation")
printf '%s' "$retained_receipt" | jq -e '.facts.endpointConfirmedGone==true and (.facts.copyDisposition | startswith("retained-")) and .facts.bookkeepingComplete==true' >/dev/null \
  || fail 'retained archive receipt did not preserve its no-loss copy disposition'

# A stale Dashboard revision refuses before the exact worker stop transaction.
stale_id=archive-stale-revision
stale_generation=archive-stale-g1
FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-tasks-axi.sh" add "$stale_id" 'Reject stale archive' --kind ship --start >/dev/null
stale_workspace=$(lab workspace create --cwd "$ROOT" --label archive-stale --no-focus)
IFS=$'\t' read -r _ _ stale_pane <<< "$(write_task_meta "$stale_id" "$stale_generation" "$ROOT" "$stale_workspace")"
if PATH="$SHIM:$ORIGINAL_PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-dashboard-archive.sh" "$stale_id" --expect-state in_flight \
    --expect-updated-at '2000-01-01T00:00:00Z' --expect-spawn-gen "$stale_generation" >/dev/null 2>&1; then
  fail 'stale archive unexpectedly succeeded'
fi
lab pane get "$stale_pane" >/dev/null 2>&1 || fail 'stale archive stopped its worker before refusing'
archive_task "$stale_id" "$stale_generation" | jq -e '.archive=="archived" and .cleanup=="retained"' >/dev/null \
  || fail 'stale fixture cleanup did not preserve the primary copy'

# A positively absent exact endpoint does not block canonical archive or safe
# resource retirement.
absent_id=archive-absent-endpoint
absent_generation=archive-absent-g1
FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-tasks-axi.sh" add "$absent_id" 'Archive absent endpoint' --kind ship --start >/dev/null
absent_workspace=$(lab workspace create --cwd "$ROOT" --label archive-absent --no-focus)
IFS=$'\t' read -r _ _ absent_pane <<< "$(write_task_meta "$absent_id" "$absent_generation" "$ROOT" "$absent_workspace")"
lab pane close "$absent_pane" >/dev/null
absent_result=$(archive_task "$absent_id" "$absent_generation")
printf '%s' "$absent_result" | jq -e '.archive=="archived" and .cleanup=="retained"' >/dev/null \
  || fail "absent endpoint archive did not retain its protected copy: $absent_result"

pass 'Dashboard archive closes exact lab panes, returns safe Treehouse copies and retains protected copies'
