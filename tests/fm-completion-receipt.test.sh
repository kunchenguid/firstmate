#!/usr/bin/env bash
# Behavioral coverage for observation-only completion and exact-child exit receipts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMPLETE="$ROOT/bin/fm-complete.sh"
RUNNER="$ROOT/bin/fm-harness-run.sh"
SHADOW="$ROOT/bin/fm-completion-shadow.sh"
TMP_ROOT=$(fm_test_tmproot fm-completion-receipt)

make_world() {  # <name> <id> <kind> <mode> [harness] [backend]
  local name=$1 id=$2 kind=$3 mode=$4 harness=${5:-codex} backend=${6:-tmux}
  WORLD="$TMP_ROOT/$name"
  HOME_DIR="$WORLD/home"
  WT="$WORLD/worktree"
  mkdir -p "$HOME_DIR"/{state,data,config} "$HOME_DIR/data/$id"
  fm_git_init_commit "$WT"
  git -C "$WT" checkout -qb "fm/$id"
  GEN="s-test-$name"
  if [ "$backend" = tmux ]; then
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$WT" "project=$WT" \
      "harness=$harness" "kind=$kind" "mode=$mode" "spawn_gen=$GEN"
  else
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=opaque-$id" "endpoint_task_id=$id" "worktree=$WT" "project=$WT" \
      "harness=$harness" "kind=$kind" "mode=$mode" "spawn_gen=$GEN" "backend=$backend"
  fi
  : > "$HOME_DIR/state/$id.status"
  cat > "$WORLD/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CURRENT_STATE:-unknown}"
SH
  chmod +x "$WORLD/crew-state"
}

run_complete() {  # <id> <gen> <outcome> <summary> [extra...]
  local id=$1 gen=$2 outcome=$3 summary=$4
  shift 4
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_SHADOW_CREW_STATE_BIN="$WORLD/crew-state" \
    "$COMPLETE" "$id" --spawn-gen "$gen" --outcome "$outcome" --summary "$summary" "$@"
}

run_runner() {  # <id> <gen> <harness> <backend> -- <command...>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_SHADOW_CREW_STATE_BIN="$WORLD/crew-state" "$RUNNER" "$@"
}

test_completion_schema_and_dual_status() {
  local id=receipt-schema-r1 receipt shadow
  make_world schema "$id" ship no-mistakes
  receipt=$(FM_FAKE_CURRENT_STATE=working run_complete "$id" "$GEN" "done" 'PR ready' --pr https://github.com/example/repo/pull/12)
  [ "$receipt" = "$HOME_DIR/state/$id.completion-receipt" ] || fail "completion helper did not print its receipt path"
  assert_grep 'schema=fm-completion-receipt.v1' "$receipt" "completion schema version missing"
  assert_grep "task_id=$id" "$receipt" "completion receipt lost task identity"
  assert_grep "spawn_gen=$GEN" "$receipt" "completion receipt lost incarnation identity"
  assert_grep 'kind=ship' "$receipt" "completion receipt lost task kind"
  assert_grep 'mode=no-mistakes' "$receipt" "completion receipt lost delivery mode"
  assert_grep 'outcome=done' "$receipt" "completion receipt lost outcome"
  assert_grep 'artifact_path=' "$receipt" "completion receipt did not retain an explicit empty artifact binding"
  assert_grep "worktree_head=$(git -C "$WT" rev-parse HEAD)" "$receipt" "completion receipt lost exact HEAD"
  assert_grep 'pr_url=https://github.com/example/repo/pull/12' "$receipt" "completion receipt lost canonical PR identity"
  [ "$(cat "$HOME_DIR/state/$id.status")" = 'done: PR ready' ] || fail "completion helper did not dual-write the legacy status event"
  shadow=$(cat "$HOME_DIR/state/$id.completion-shadow")
  assert_contains "$shadow" "harness=codex backend=tmux trigger=completion completion=done" \
    "completion shadow row did not carry harness/backend and receipt verdict"
  assert_contains "$shadow" "shadow=ready current=working comparison=different" \
    "completion shadow row did not preserve the current-system disagreement"
  find "$HOME_DIR/state" -name ".$id.completion-receipt.*" -print | grep -q . \
    && fail "completion publication left a temporary file"
  pass "completion receipt is versioned, identity-bound, atomic, and status-compatible"
}

test_schema_validation_rejects_malformed_receipt() {
  local id=receipt-invalid-r2
  make_world invalid "$id" ship direct-PR
  FM_FAKE_CURRENT_STATE="done" run_complete "$id" "$GEN" "done" 'ready' >/dev/null
  printf 'unknown_field=1\n' >> "$HOME_DIR/state/$id.completion-receipt"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_SHADOW_CREW_STATE_BIN="$WORLD/crew-state" "$SHADOW" record "$id"
  assert_contains "$(tail -n 1 "$HOME_DIR/state/$id.completion-shadow")" 'completion=invalid-or-stale' \
    "shadow reader accepted a receipt outside the strict schema"
  pass "completion reader rejects malformed schema instead of trusting it"
}

test_incarnation_binding_and_stale_rejection() {
  local id=receipt-stale-r3 before out status
  make_world stale "$id" ship direct-PR
  run_complete "$id" "$GEN" "done" 'first incarnation' >/dev/null
  before=$(cat "$HOME_DIR/state/$id.completion-receipt")
  sed "s/^spawn_gen=.*/spawn_gen=s-new-incarnation/" "$HOME_DIR/state/$id.meta" > "$HOME_DIR/state/$id.meta.new"
  mv "$HOME_DIR/state/$id.meta.new" "$HOME_DIR/state/$id.meta"
  out=$(run_complete "$id" "$GEN" failed 'stale writer' 2>&1)
  status=$?
  expect_code 1 "$status" "stale completion writer must be refused"
  assert_contains "$out" 'stale spawn generation' "stale completion refusal did not name the incarnation mismatch"
  [ "$(cat "$HOME_DIR/state/$id.completion-receipt")" = "$before" ] || fail "stale writer replaced the prior receipt"

  out=$(run_runner --task "$id" --spawn-gen "$GEN" --harness codex --backend tmux -- /bin/sh -c 'exit 0' 2>&1)
  status=$?
  expect_code 0 "$status" "receipt observation failure must not change a successful harness exit"
  assert_contains "$out" 'process-exit receipt was not published' "stale process exit was not visibly rejected"
  assert_absent "$HOME_DIR/state/$id.process-exit-receipt" "stale process exit published a receipt"
  pass "both receipt writers reject a stale spawn incarnation"
}

test_investigation_requires_report_path() {
  local id=receipt-scout-r4 out status report
  make_world scout "$id" scout scout
  out=$(run_complete "$id" "$GEN" "done" 'investigation complete' 2>&1)
  status=$?
  expect_code 1 "$status" "investigation completion without a report path must fail"
  assert_contains "$out" 'investigation completion requires --artifact' "missing report refusal was not actionable"
  assert_absent "$HOME_DIR/state/$id.completion-receipt" "report-less investigation published a receipt"
  report="$HOME_DIR/data/$id/report.md"
  printf '# report\n' > "$report"
  run_complete "$id" "$GEN" "done" 'investigation complete' --artifact "$report" >/dev/null
  report="$(cd "$(dirname "$report")" && pwd -P)/$(basename "$report")"
  assert_grep "artifact_path=$report" "$HOME_DIR/state/$id.completion-receipt" \
    "investigation receipt did not bind the report path"
  pass "investigation receipts refuse a missing report path"
}

test_local_only_requires_clean_task_branch() {
  local id=receipt-local-r5 out status
  make_world local "$id" ship local-only
  printf 'dirty\n' >> "$WT/README.md"
  out=$(run_complete "$id" "$GEN" "done" 'ready in branch' 2>&1)
  status=$?
  expect_code 1 "$status" "dirty local-only worktree must be refused"
  assert_contains "$out" 'requires a clean worktree' "dirty local-only refusal was not actionable"
  git -C "$WT" checkout -- README.md
  git -C "$WT" checkout -qb wrong-branch
  out=$(run_complete "$id" "$GEN" "done" 'ready in branch' 2>&1)
  status=$?
  expect_code 1 "$status" "wrong local-only branch must be refused"
  assert_contains "$out" "requires task branch fm/$id" "wrong-branch refusal did not name the task branch"
  assert_absent "$HOME_DIR/state/$id.completion-receipt" "unsafe local-only state published a receipt"
  pass "local-only receipt refuses dirty and wrong-branch worktrees"
}

test_process_exit_normal_and_killed() {
  local id=receipt-exit-r6 status pidfile child wrapper i
  make_world exit-normal "$id" ship direct-PR claude herdr
  run_runner --task "$id" --spawn-gen "$GEN" --harness claude --backend herdr -- /bin/sh -c 'exit 0'
  status=$?
  expect_code 0 "$status" "normal harness exit status changed"
  assert_grep 'schema=fm-process-exit-receipt.v1' "$HOME_DIR/state/$id.process-exit-receipt" \
    "normal exit did not publish the process receipt schema"
  assert_grep 'wait_status=0' "$HOME_DIR/state/$id.process-exit-receipt" \
    "normal exit did not retain the kernel-derived wait status"
  grep -Eq '^process_identity=[0-9a-f]+$' "$HOME_DIR/state/$id.process-exit-receipt" \
    || fail "normal exit did not retain process incarnation identity"

  # shellcheck disable=SC2100 # id is a literal task-id suffix, not arithmetic.
  id=receipt-killed-r7
  make_world exit-killed "$id" ship direct-PR muse cmux
  pidfile="$WORLD/child.pid"
  # shellcheck disable=SC2016 # child shell must expand $$ and $1 inside the literal script.
  run_runner --task "$id" --spawn-gen "$GEN" --harness muse --backend cmux -- \
    /bin/sh -c 'printf "%s\n" "$$" > "$1"; while :; do sleep 1; done' _ "$pidfile" &
  wrapper=$!
  i=0
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ -s "$pidfile" ] || fail "killed-process fixture did not publish its child pid"
  child=$(cat "$pidfile")
  kill -KILL "$child"
  set +e
  wait "$wrapper"
  status=$?
  set -e
  expect_code 137 "$status" "killed harness wait status was not preserved"
  assert_grep 'wait_status=137' "$HOME_DIR/state/$id.process-exit-receipt" \
    "killed process receipt did not retain the wait status"
  assert_grep "process_pid=$child" "$HOME_DIR/state/$id.process-exit-receipt" \
    "killed process receipt did not name the exact harness child"
  assert_contains "$(tail -n 1 "$HOME_DIR/state/$id.completion-shadow")" \
    'harness=muse backend=cmux trigger=process-exit completion=absent process=exited-nonzero shadow=abnormal-exit' \
    "killed child did not produce an inspectable abnormal-exit comparison"
  find "$HOME_DIR/state" -name ".$id.process-exit-receipt.*" -print | grep -q . \
    && fail "process-exit publication left a temporary file"
  pass "exact-child exit receipts capture normal and killed wait statuses"
}

test_process_wrapper_preserves_child_io_and_status() {
  local id=receipt-io-r7b out status
  make_world process-io "$id" ship direct-PR opencode zellij
  # shellcheck disable=SC2016 # child shell must expand $line inside the literal script.
  out=$(printf 'hello\n' | run_runner --task "$id" --spawn-gen "$GEN" --harness opencode --backend zellij -- \
    /bin/sh -c 'IFS= read -r line; [ "$line" = hello ]; printf "child-output\n"')
  status=$?
  expect_code 0 "$status" "process wrapper changed child stdin or success status"
  [ "$out" = child-output ] || fail "process wrapper changed child stdout"
  assert_grep 'wait_status=0' "$HOME_DIR/state/$id.process-exit-receipt" \
    "process wrapper did not publish the successful child status"
  pass "process wrapper preserves the harness child I/O and exit status"
}

test_shadow_records_every_harness_and_backend_axis() {
  local harness backend id rows
  rows="$TMP_ROOT/shadow-axis.rows"
  : > "$rows"
  for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
    for backend in tmux herdr zellij orca cmux; do
      id="axis-${harness//[^A-Za-z0-9]/-}-$backend"
      make_world "axis-$id" "$id" ship direct-PR "$harness" "$backend"
      FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
        FM_SHADOW_CREW_STATE_BIN="$WORLD/crew-state" "$SHADOW" record "$id"
      tail -n 1 "$HOME_DIR/state/$id.completion-shadow" >> "$rows"
    done
  done
  [ "$(wc -l < "$rows" | tr -d ' ')" -eq 45 ] || fail "shadow matrix did not record every harness/backend pair"
  for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
    assert_contains "$(cat "$rows")" "harness=$harness " "shadow matrix omitted harness $harness"
  done
  for backend in tmux herdr zellij orca cmux; do
    assert_contains "$(cat "$rows")" "backend=$backend " "shadow matrix omitted backend $backend"
  done
  pass "shadow ledger records comparisons per supported harness and backend"
}

test_receipts_cannot_reach_cleanup() {
  local id=receipt-no-cleanup-r8 trapbin
  make_world no-cleanup "$id" ship direct-PR
  trapbin="$WORLD/trapbin"
  mkdir -p "$trapbin"
  cat > "$trapbin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
touch "${FM_CLEANUP_TRIPWIRE:?}"
exit 99
SH
  chmod +x "$trapbin/fm-teardown.sh"
  FM_CLEANUP_TRIPWIRE="$WORLD/cleanup-called" PATH="$trapbin:$PATH" \
    FM_TEARDOWN_BIN="$trapbin/fm-teardown.sh" run_complete "$id" "$GEN" "done" 'ready' >/dev/null
  FM_CLEANUP_TRIPWIRE="$WORLD/cleanup-called" PATH="$trapbin:$PATH" \
    FM_TEARDOWN_BIN="$trapbin/fm-teardown.sh" \
    run_runner --task "$id" --spawn-gen "$GEN" --harness codex --backend tmux -- /bin/sh -c 'exit 0'
  assert_absent "$WORLD/cleanup-called" "a receipt path invoked teardown"
  assert_present "$HOME_DIR/state/$id.meta" "receipt path removed task metadata"
  [ -d "$WT" ] || fail "receipt path removed the worktree"
  pass "completion and process-exit receipts expose no cleanup path"
}

test_shadow_read_interface_documents_disagreements() {
  local id=receipt-read-r9 help out
  make_world read "$id" ship direct-PR
  FM_FAKE_CURRENT_STATE=working run_complete "$id" "$GEN" "done" 'ready' >/dev/null
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$SHADOW" read "$id" --disagreements)
  assert_contains "$out" 'comparison=different' "shadow read did not expose the disagreement"
  help=$($SHADOW --help 2>&1 || true)
  assert_contains "$help" 'fm-completion-shadow.sh read' "shadow helper help did not document the read interface"
  pass "shadow comparisons have a documented disagreement reader"
}

test_completion_schema_and_dual_status
test_schema_validation_rejects_malformed_receipt
test_incarnation_binding_and_stale_rejection
test_investigation_requires_report_path
test_local_only_requires_clean_task_branch
test_process_exit_normal_and_killed
test_process_wrapper_preserves_child_io_and_status
test_shadow_records_every_harness_and_backend_axis
test_receipts_cannot_reach_cleanup
test_shadow_read_interface_documents_disagreements

echo "# all fm-completion-receipt tests passed"
