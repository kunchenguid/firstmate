#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cleanup)
STATE="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$TMP_ROOT/providers"
export FM_STATE_OVERRIDE="$STATE"
export FM_HOME="$TMP_ROOT/home"
export FM_FAKE_KILL_LOG="$TMP_ROOT/kill.log"
export FM_ORCA_STATE="$TMP_ROOT/orca-state"
mkdir -p "$FM_ORCA_STATE"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window)
    printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    [ -z "${FM_TMUX_STATE_FILE:-}" ] || rm -f "$FM_TMUX_STATE_FILE"
    ;;
  list-windows)
    [ "${FM_TMUX_QUERY:-missing}" != error ] || { printf 'query failed\n' >&2; exit 1; }
    if [ -n "${FM_TMUX_STATE_FILE:-}" ]; then
      [ ! -e "$FM_TMUX_STATE_FILE" ] || printf '%s\n' "${FM_TMUX_LIVE_WINDOW:-fm-live}"
    elif [ "${FM_TMUX_QUERY:-missing}" = present ]; then
      printf '%s\n' "${FM_TMUX_LIVE_WINDOW:-fm-live}"
    fi
    ;;
  display-message) printf 'bash\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '{"error":{"code":"pane_not_found"}}\n'
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/zellij" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-sessions ] && exit 0
printf '[]\n'
SH
chmod +x "$FAKEBIN/zellij"

cat > "$FAKEBIN/cmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ping) printf 'PONG\n' ;;
  workspace) printf '{"workspaces":[]}\n' ;;
  list-panes) printf '{"panes":[]}\n' ;;
  *) printf 'OK\n' ;;
esac
SH
chmod +x "$FAKEBIN/cmux"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = return ] && [ "${2:-}" = --force ] || exit 1
[ "${FM_TREEHOUSE_FAIL:-0}" != 1 ] || exit 1
rm -rf -- "$3"
SH
chmod +x "$FAKEBIN/treehouse"

cat > "$FAKEBIN/orca" <<'SH'
#!/usr/bin/env bash
kind=${1:-}
verb=${2:-}
case "$kind:$verb" in
  terminal:close)
    rm -f "$FM_ORCA_STATE/terminal"
    printf '{"ok":true}\n'
    ;;
  terminal:read)
    if [ -e "$FM_ORCA_STATE/terminal" ]; then printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n'
    else printf '{"ok":false,"error":{"code":"terminal_not_found"}}\n'; exit 1; fi
    ;;
  worktree:show)
    if [ -e "$FM_ORCA_STATE/worktree" ]; then
      path=$(cat "$FM_ORCA_STATE/path")
      printf '{"ok":true,"result":{"worktree":{"id":"owt-1","path":"%s"}}}\n' "$path"
    else printf '{"ok":false,"error":{"code":"worktree_not_found"}}\n'; exit 1; fi
    ;;
  worktree:rm)
    path=$(cat "$FM_ORCA_STATE/path")
    rm -f "$FM_ORCA_STATE/worktree"
    rm -rf -- "$path"
    printf '{"ok":true}\n'
    ;;
  *) printf '{"ok":false,"error":{"code":"unsupported"}}\n'; exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/orca"

export PATH="$FAKEBIN:$PATH"

setup_cleanup_attempt() {  # <suffix> [backend]
  local suffix=$1 backend=${2:-tmux} project copy id aid gen endpoint provider
  project="$TMP_ROOT/project-$suffix"
  copy="$TMP_ROOT/copy-$suffix"
  id="task-$suffix"
  fm_git_init_commit "$project"
  git -C "$project" worktree add -q -b "fm/$id" "$copy" HEAD
  aid=$(fm_attempt_alloc pi "dos-$suffix" holu) || fail alloc
  gen=$(fm_attempt_generation "$aid") || fail generation
  provider=$(jq -nc --arg p "$backend" --arg c "$copy" '{provider:$p,copy:$c}')
  fm_attempt_freeze_allocation "$aid" "$gen" "$provider" \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail freeze
  fm_attempt_effect_observe "$aid" "$gen" launch "$(jq -nc --arg e "endpoint-$suffix" '{endpoint:$e}')" || fail launch
  case "$backend" in
    orca)
      endpoint="oterm-1"
      printf '%s\n' "$copy" > "$FM_ORCA_STATE/path"
      : > "$FM_ORCA_STATE/worktree"
      : > "$FM_ORCA_STATE/terminal"
      printf 'window=fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nbackend=orca\nterminal=%s\norca_worktree_id=owt-1\nattempt=%s\nkind=ship\n' \
        "$id" "$id" "$copy" "$project" "$endpoint" "$aid" > "$STATE/$id.meta"
      ;;
    herdr)
      endpoint="hs-$suffix:hp-$suffix"
      printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nbackend=herdr\nherdr_session=hs-%s\nherdr_workspace_id=hw-%s\nherdr_tab_id=ht-%s\nherdr_pane_id=hp-%s\nattempt=%s\nkind=ship\n' \
        "$endpoint" "$id" "$copy" "$project" "$suffix" "$suffix" "$suffix" "$suffix" "$aid" > "$STATE/$id.meta"
      ;;
    zellij)
      endpoint="zs-$suffix:41"
      printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nbackend=zellij\nzellij_session=zs-%s\nzellij_tab_id=40\nzellij_pane_id=41\nattempt=%s\nkind=ship\n' \
        "$endpoint" "$id" "$copy" "$project" "$suffix" "$aid" > "$STATE/$id.meta"
      ;;
    cmux)
      endpoint="cw-$suffix:cs-$suffix"
      printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nbackend=cmux\ncmux_workspace_id=cw-%s\ncmux_surface_id=cs-%s\nattempt=%s\nkind=ship\n' \
        "$endpoint" "$id" "$copy" "$project" "$suffix" "$suffix" "$aid" > "$STATE/$id.meta"
      ;;
    *)
      endpoint="s:fm-$id"
      printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nattempt=%s\nkind=ship\n' \
        "$endpoint" "$id" "$copy" "$project" "$aid" > "$STATE/$id.meta"
      ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$aid" "$id" "$project" "$copy"
}

run_cleanup() {  # <attempt> <disposition> [env...]
  local aid=$1 disposition=$2
  shift 2
  env "$@" FM_TERMINAL_QUIET_SECS=0 "$ROOT/bin/fm-cleanup-lib.sh" --run "$aid" "$disposition" 2>&1 || true
}

test_preflight_refuses_exact_identity_mismatch_before_effects() {
  local row aid id project copy out
  row=$(setup_cleanup_attempt identity)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  printf 'window=s:fm-%s\nendpoint_task_id=%s\nworktree=%s-other\nproject=%s\nattempt=%s\n' \
    "$id" "$id" "$copy" "$project" "$aid" > "$STATE/$id.meta"
  : > "$FM_FAKE_KILL_LOG"
  out=$(run_cleanup "$aid" landed)
  assert_contains "$out" "identity mismatch" "copy mismatch was not refused"
  [ ! -s "$FM_FAKE_KILL_LOG" ] || fail "endpoint was stopped before identity preflight"
  pass "provider, copy, task, and endpoint identity are validated before effects"
}

test_endpoint_stop_requires_authoritative_absence() {
  local row aid id project copy out
  row=$(setup_cleanup_attempt endpoint)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  out=$(run_cleanup "$aid" landed FM_TMUX_QUERY=present FM_TMUX_LIVE_WINDOW="fm-$id")
  assert_contains "$out" "absence is present" "still-live endpoint was accepted as absent"
  out=$(run_cleanup "$aid" landed FM_TMUX_QUERY=error)
  assert_contains "$out" "absence is unknown" "backend query error counted as absence"
  jq -e '.receipts["cleanup.endpoint"] == null' "$STATE/attempts/$aid.json" >/dev/null || fail "endpoint receipt published on query error"
  [ -d "$copy" ] || fail "provider ran after endpoint refusal"
  assert_contains "$(cat "$FM_FAKE_KILL_LOG")" "fm-$id" "exact validated endpoint was not passed to fm_backend_kill"
  pass "the exact endpoint is stopped and query errors never prove absence"
}

test_linked_worktree_preservation_is_verified() {
  local row aid id project copy out head
  row=$(setup_cleanup_attempt preserve)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  head=$(git -C "$copy" rev-parse HEAD)
  out=$(run_cleanup "$aid" preserved_unlanded)
  git -C "$project" rev-parse "refs/fm-preserve/$aid" 2>/dev/null | grep -qx "$head" || fail "exact preservation ref/head missing: $out"
  jq -e '.receipts["cleanup.preservation"][0].evidence.verified == true' "$STATE/attempts/$aid.json" >/dev/null || fail "preservation verification not recorded"
  pass "linked git worktrees preserve and verify the exact ref/head"
}

test_branch_failure_stops_provider_and_runtime() {
  local row aid id project copy out
  row=$(setup_cleanup_attempt branchfail)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  out=$(run_cleanup "$aid" landed FM_BRANCH_DELETE_FAIL=1)
  assert_contains "$out" "branch disposition failed" "branch failure not surfaced"
  jq -e '.receipts["cleanup.branch"][-1].state == "pending" and .receipts["cleanup.provider"] == null and .receipts["cleanup.runtime"] == null' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "later effects ran after branch failure"
  [ -d "$copy" ] && [ -f "$STATE/$id.meta" ] || fail "branch failure did not preserve provider/runtime resources"
  pass "branch failure is pending and stops before provider/runtime effects"
}

test_provider_return_crash_reconciles_before_receipt() {
  local row aid id project copy out
  row=$(setup_cleanup_attempt providercrash)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  run_cleanup "$aid" landed FM_CLEANUP_CRASH_AFTER_PROVIDER_RETURN=1 >/dev/null
  [ ! -e "$copy" ] || fail "provider crash fixture did not return copy"
  jq -e '.receipts["cleanup.provider"] == null' "$STATE/attempts/$aid.json" >/dev/null || fail "provider receipt unexpectedly published"
  out=$(run_cleanup "$aid" landed)
  jq -e '.receipts["cleanup.provider"][0].evidence.returned == true and .receipts["cleanup.runtime"][0].evidence.confirmed_absent == true' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "provider replay did not reconcile: $out"
  pass "replay reconciles a provider return that crashed before receipt publication"
}

test_endpoint_stop_crash_reconciles_before_receipt() {
  local row aid id project copy out endpoint_state
  row=$(setup_cleanup_attempt endpointcrash)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  endpoint_state="$TMP_ROOT/endpoint-alive"
  : > "$endpoint_state"
  run_cleanup "$aid" landed FM_TMUX_STATE_FILE="$endpoint_state" \
    FM_TMUX_LIVE_WINDOW="fm-$id" FM_CLEANUP_CRASH_AFTER_ENDPOINT_STOP=1 >/dev/null
  [ ! -e "$endpoint_state" ] || fail "endpoint crash fixture did not stop the endpoint"
  jq -e '.receipts["cleanup.endpoint"] == null' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "endpoint receipt unexpectedly published"
  : > "$FM_FAKE_KILL_LOG"
  out=$(run_cleanup "$aid" landed FM_TMUX_STATE_FILE="$endpoint_state" FM_TMUX_LIVE_WINDOW="fm-$id")
  jq -e '.receipts["cleanup.endpoint"][0].evidence.confirmed_gone == true' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "endpoint replay did not reconcile: $out"
  [ ! -s "$FM_FAKE_KILL_LOG" ] || fail "endpoint replay tried to stop an already-absent endpoint"
  pass "replay reconciles an endpoint stop that crashed before receipt publication"
}

test_runtime_remove_crash_reconciles_each_effect_independently() {
  local row aid id project copy out
  row=$(setup_cleanup_attempt runtimecrash)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  run_cleanup "$aid" landed FM_CLEANUP_CRASH_AFTER_RUNTIME_REMOVE=1 >/dev/null
  [ ! -e "$STATE/$id.meta" ] || fail "runtime crash fixture retained meta"
  jq -e '.receipts["cleanup.runtime"] == null' "$STATE/attempts/$aid.json" >/dev/null || fail "runtime receipt unexpectedly published"
  out=$(run_cleanup "$aid" landed)
  jq -e '.receipts["cleanup.runtime"][0].evidence.confirmed_absent == true' "$STATE/attempts/$aid.json" >/dev/null || fail "runtime replay did not reconcile: $out"
  pass "runtime replay proves exact absence before publishing its missing receipt"
}

test_replay_after_each_observed_effect_converges() {
  local effect row aid id project copy out
  for effect in endpoint branch provider runtime; do
    row=$(setup_cleanup_attempt "replay-$effect")
    IFS=$'\t' read -r aid id project copy <<< "$row"
    run_cleanup "$aid" landed FM_CLEANUP_CRASH_AFTER_RECEIPT="$effect" >/dev/null
    out=$(run_cleanup "$aid" landed)
    jq -e '["cleanup.endpoint","cleanup.branch","cleanup.provider","cleanup.runtime"] as $n | . as $root | all($n[]; $root.receipts[.][0].state == "observed")' \
      "$STATE/attempts/$aid.json" >/dev/null || fail "replay after $effect did not converge: $out"
  done
  pass "each cleanup effect resumes independently from observed receipts"
}

test_treehouse_provider_matrix_uses_public_cleanup_operation() {
  local backend row aid id project copy endpoint gen out
  for backend in tmux herdr zellij cmux; do
    row=$(setup_cleanup_attempt "matrix-$backend" "$backend")
    IFS=$'\t' read -r aid id project copy <<< "$row"
    endpoint=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_target_of_meta "$2"' _ "$ROOT" "$STATE/$id.meta")
    gen=$(fm_attempt_generation "$aid")
    fm_attempt_effect_observe "$aid" "$gen" cleanup.endpoint \
      "$(jq -nc --arg b "$backend" --arg e "$endpoint" --arg id "$id" --arg c "$copy" \
        '{backend:$b,endpoint:$e,task_id:$id,copy:$c,confirmed_gone:true}')" || fail "seed $backend endpoint"
    out=$(run_cleanup "$aid" landed)
    jq -e --arg backend "$backend" '.receipts["cleanup.provider"][0].evidence.provider == $backend and .receipts["cleanup.runtime"][0].state == "observed"' \
      "$STATE/attempts/$aid.json" >/dev/null || fail "$backend structured cleanup failed: $out"
  done
  pass "tmux, Herdr, Zellij, and cmux return Treehouse copies through one public cleanup operation"
}

test_orca_uses_exact_recorded_id_path_and_provider_removal() {
  local row aid id project copy out
  row=$(setup_cleanup_attempt orca orca)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  out=$(run_cleanup "$aid" landed)
  jq -e '.receipts["cleanup.endpoint"][0].evidence.orca_worktree_id == "owt-1" and .receipts["cleanup.provider"][0].evidence.worktree_id == "owt-1"' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "Orca exact identity/removal evidence missing: $out"
  pass "Orca cleanup uses its exact recorded worktree id/path and provider-owned removal"
}

test_differing_observed_receipt_is_never_rewritten() {
  local row aid id project copy gen before out after
  row=$(setup_cleanup_attempt differing)
  IFS=$'\t' read -r aid id project copy <<< "$row"
  gen=$(fm_attempt_generation "$aid")
  fm_attempt_effect_observe "$aid" "$gen" cleanup.endpoint '{"backend":"tmux","endpoint":"wrong","task_id":"wrong","copy":"wrong","confirmed_gone":true}' || fail seed
  before=$(jq -c '.receipts["cleanup.endpoint"]' "$STATE/attempts/$aid.json")
  out=$(run_cleanup "$aid" landed)
  after=$(jq -c '.receipts["cleanup.endpoint"]' "$STATE/attempts/$aid.json")
  [ "$before" = "$after" ] || fail "differing receipt was rewritten"
  assert_contains "$out" "differing endpoint receipt" "receipt contradiction not surfaced"
  pass "differing observed receipts remain immutable"
}

test_preflight_refuses_exact_identity_mismatch_before_effects
test_endpoint_stop_requires_authoritative_absence
test_linked_worktree_preservation_is_verified
test_branch_failure_stops_provider_and_runtime
test_endpoint_stop_crash_reconciles_before_receipt
test_provider_return_crash_reconciles_before_receipt
test_runtime_remove_crash_reconciles_each_effect_independently
test_replay_after_each_observed_effect_converges
test_treehouse_provider_matrix_uses_public_cleanup_operation
test_orca_uses_exact_recorded_id_path_and_provider_removal
test_differing_observed_receipt_is_never_rewritten
