#!/usr/bin/env bash
# Regression tests for the fail-closed legacy Herdr endpoint-binding repair.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPAIR="$ROOT/bin/fm-repair-legacy-endpoint-binding.sh"
TMP_ROOT=$(fm_test_tmproot fm-repair-legacy-endpoint-binding)

make_case() {  # <name> [task-id]
  local id=${2:-legacy-task} dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  dir=$(cd "$dir" && pwd -P)
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  fm_git_worktree "$dir/project" "$dir/worktree" "fm/$id"
  mkdir -p "$dir/home/data/$id"
  printf 'durable report\n' > "$dir/home/data/$id/report.md"
  printf 'needs-decision: [key=preserve-me] captain-held answer\n' > "$dir/home/state/$id.status"
  : > "$dir/herdr.log"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
if [ "${FM_HERDR_MUTATE_META_ON_CALL:-0}" = 1 ]; then
  calls=$(wc -l < "${FM_HERDR_LOG:?}" | tr -d ' ')
  if [ "$calls" = 2 ]; then
    printf 'concurrent=keep\n' >> "${FM_HERDR_META:?}"
  fi
fi
calls=$(wc -l < "${FM_HERDR_LOG:?}" | tr -d ' ')
if [ "$calls" = 2 ] && [ -n "${FM_HERDR_RESPONSE_2:-}" ]; then
  printf '%s\n' "$FM_HERDR_RESPONSE_2"
else
  printf '%s\n' "${FM_HERDR_RESPONSE:?}"
fi
SH
  chmod +x "$dir/fakebin/herdr"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    "harness=claude" \
    "kind=ship" \
    "backend=herdr" \
    "herdr_session=lab" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" \
    "herdr_pane_id=w1:p2"
  printf '%s\n' "$dir"
}

pane_response() {  # <worktree> [workspace] [tab] [pane]
  jq -cn \
    --arg cwd "$1" \
    --arg workspace "${2:-w1}" \
    --arg tab "${3:-w1:t2}" \
    --arg pane "${4:-w1:p2}" \
    '{result:{pane:{pane_id:$pane,tab_id:$tab,workspace_id:$workspace,foreground_cwd:$cwd}}}'
}

run_repair() {  # <case> [task-id]
  local dir=$1 id=${2:-legacy-task}
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HERDR_LOG="$dir/herdr.log" \
    FM_HERDR_META="$dir/home/state/$id.meta" \
    FM_HERDR_RESPONSE="${FM_HERDR_RESPONSE:?}" \
    FM_HERDR_RESPONSE_2="${FM_HERDR_RESPONSE_2:-}" \
    FM_HERDR_MUTATE_META_ON_CALL="${FM_HERDR_MUTATE_META_ON_CALL:-0}" \
    PATH="$dir/fakebin:$PATH" \
    "$REPAIR" "$id"
}

assert_refused_unchanged() {  # <case> <description> [task-id]
  local dir=$1 description=$2 id=${3:-legacy-task} before rc
  before=$(cat "$dir/home/state/$id.meta")
  set +e
  run_repair "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: repair unexpectedly succeeded"
  [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] \
    || fail "$description: metadata changed despite refusal"
  case "$before" in
    *endpoint_task_id=*) : ;;
    *)
      assert_no_grep "endpoint_task_id=" "$dir/home/state/$id.meta" \
        "$description: refusal published a task binding"
      ;;
  esac
}

test_legacy_record_reproduces_the_metadata_only_refusal() {
  local dir rc
  dir=$(make_case initial-refusal)
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$2" legacy-task' \
      _ "$ROOT" "$dir/home/state/legacy-task.meta" \
      > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "legacy metadata without an exact binding unexpectedly validated"
  assert_contains "$(cat "$dir/stderr")" \
    "legacy Herdr endpoint metadata for task legacy-task lacks an exact task binding" \
    "legacy metadata should reproduce the teardown validator's safe refusal"
  [ ! -s "$dir/herdr.log" ] || fail "metadata-only refusal queried Herdr"
  pass "legacy endpoint repair: the original metadata-only teardown refusal is reproducible without runtime access"
}

test_exact_live_identity_repairs_only_the_binding() {
  local dir before expected calls head branch report status
  dir=$(make_case exact)
  before=$(cat "$dir/home/state/legacy-task.meta")
  head=$(git -C "$dir/worktree" rev-parse HEAD)
  branch=$(git -C "$dir/worktree" symbolic-ref --short HEAD)
  report=$(cat "$dir/home/data/legacy-task/report.md")
  status=$(cat "$dir/home/state/legacy-task.status")
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE

  run_repair "$dir" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "exact live Herdr and git identity should repair the missing binding: $(cat "$dir/stderr")"

  expected="$before
endpoint_task_id=legacy-task"
  [ "$(cat "$dir/home/state/legacy-task.meta")" = "$expected" ] \
    || fail "successful repair changed more than the missing endpoint binding"
  calls=$(cat "$dir/herdr.log")
  [ "$calls" = $'pane get w1:p2 --session lab\npane get w1:p2 --session lab' ] \
    || fail "repair must make exactly two read-only exact-pane calls, got: $calls"
  [ "$(git -C "$dir/worktree" rev-parse HEAD)" = "$head" ] \
    && [ "$(git -C "$dir/worktree" symbolic-ref --short HEAD)" = "$branch" ] \
    && [ -z "$(git -C "$dir/worktree" status --porcelain)" ] \
    || fail "successful binding repair changed the branch, commit, or worktree"
  [ "$(cat "$dir/home/data/legacy-task/report.md")" = "$report" ] \
    && [ "$(cat "$dir/home/state/legacy-task.status")" = "$status" ] \
    || fail "successful binding repair changed a report or captain-held status record"

  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_validate_task_endpoint "$dir/home/state/legacy-task.meta" legacy-task \
    || fail "repaired metadata should pass the teardown endpoint validator"
  pass "legacy endpoint repair: exact live endpoint and registered worktree proof append only the missing binding"
}

test_existing_binding_is_idempotent_without_runtime_access() {
  local dir before
  dir=$(make_case idempotent)
  printf 'endpoint_task_id=legacy-task\n' >> "$dir/home/state/legacy-task.meta"
  before=$(cat "$dir/home/state/legacy-task.meta")
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE

  run_repair "$dir" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "an already-valid exact binding should be idempotent"
  [ "$(cat "$dir/home/state/legacy-task.meta")" = "$before" ] \
    || fail "idempotent repair rewrote valid metadata"
  [ ! -s "$dir/herdr.log" ] || fail "idempotent repair should not query Herdr"
  pass "legacy endpoint repair: an existing exact binding is a no-op"
}

test_ambiguous_or_wrong_existing_bindings_refuse_without_runtime_access() {
  local dir
  dir=$(make_case wrong-binding)
  printf 'endpoint_task_id=other-task\n' >> "$dir/home/state/legacy-task.meta"
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "wrong existing binding"
  [ ! -s "$dir/herdr.log" ] || fail "wrong existing binding reached Herdr"

  dir=$(make_case duplicate-binding)
  printf 'endpoint_task_id=legacy-task\nendpoint_task_id=legacy-task\n' >> "$dir/home/state/legacy-task.meta"
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  before=$(cat "$dir/home/state/legacy-task.meta")
  set +e
  run_repair "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate existing binding unexpectedly succeeded"
  [ "$(cat "$dir/home/state/legacy-task.meta")" = "$before" ] \
    || fail "duplicate existing binding was rewritten"
  [ ! -s "$dir/herdr.log" ] || fail "duplicate existing binding reached Herdr"
  pass "legacy endpoint repair: wrong and ambiguous bindings fail closed before runtime access"
}

test_live_identity_mismatch_refuses() {
  local dir
  dir=$(make_case live-cwd-mismatch)
  FM_HERDR_RESPONSE=$(pane_response "$dir/project")
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "live foreground cwd mismatch"

  dir=$(make_case live-pane-mismatch)
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree" w1 w1:t2 w1:p9)
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "live pane identity mismatch"

  dir=$(make_case live-tab-mismatch)
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree" w1 w1:t9 w1:p2)
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "live tab identity mismatch"

  dir=$(make_case live-workspace-mismatch)
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree" w9 w1:t2 w1:p2)
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "live workspace identity mismatch"

  dir=$(make_case unstable-live-path)
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  FM_HERDR_RESPONSE_2=$(pane_response "$dir/project")
  export FM_HERDR_RESPONSE FM_HERDR_RESPONSE_2
  assert_refused_unchanged "$dir" "live identity changed between samples"
  unset FM_HERDR_RESPONSE_2
  pass "legacy endpoint repair: labels, shared workspaces, and stale pane ids cannot substitute for exact live identity"
}

test_other_metadata_claims_refuse_before_runtime_access() {
  local dir other
  dir=$(make_case shared-worktree)
  other="$dir/home/state/other-task.meta"
  fm_write_meta "$other" \
    "window=lab:w9:p9" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w9" \
    "herdr_tab_id=w9:t9" "herdr_pane_id=w9:p9"
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "worktree claimed by another task"
  [ ! -s "$dir/herdr.log" ] || fail "shared-worktree ambiguity reached Herdr"

  dir=$(make_case shared-endpoint)
  other="$dir/home/state/other-task.meta"
  fm_write_meta "$other" \
    "window=lab:w1:p2" "worktree=$dir/project" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "endpoint claimed by another task"
  [ ! -s "$dir/herdr.log" ] || fail "shared-endpoint ambiguity reached Herdr"

  dir=$(make_case shared-structured-pane)
  other="$dir/home/state/other-task.meta"
  fm_write_meta "$other" \
    "window=lab:w9:p9" "worktree=$dir/project" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t9" "herdr_pane_id=w1:p2"
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "structured pane claimed by another task"
  [ ! -s "$dir/herdr.log" ] || fail "structured-pane ambiguity reached Herdr"
  pass "legacy endpoint repair: another metadata claim makes ownership ambiguous and refuses"
}

test_unregistered_or_cross_project_worktrees_refuse() {
  local dir replacement
  dir=$(make_case unregistered)
  replacement="$dir/unregistered"
  fm_git_init_commit "$replacement"
  perl -0pi -e "s|^worktree=.*\$|worktree=$replacement|m" "$dir/home/state/legacy-task.meta"
  FM_HERDR_RESPONSE=$(pane_response "$replacement")
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "unregistered git worktree"
  [ ! -s "$dir/herdr.log" ] || fail "unregistered worktree reached Herdr"

  dir=$(make_case cross-project)
  replacement="$dir/other-project"
  fm_git_init_commit "$replacement"
  perl -0pi -e "s|^project=.*\$|project=$replacement|m" "$dir/home/state/legacy-task.meta"
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  assert_refused_unchanged "$dir" "cross-project worktree"
  [ ! -s "$dir/herdr.log" ] || fail "cross-project worktree reached Herdr"
  pass "legacy endpoint repair: only an exact linked worktree registered to the recorded project is eligible"
}

test_metadata_drift_refuses_without_overwriting_concurrent_state() {
  local dir rc
  dir=$(make_case drift)
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  FM_HERDR_MUTATE_META_ON_CALL=1
  export FM_HERDR_RESPONSE FM_HERDR_MUTATE_META_ON_CALL
  set +e
  run_repair "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  unset FM_HERDR_MUTATE_META_ON_CALL
  [ "$rc" -ne 0 ] || fail "metadata drift during proof unexpectedly succeeded"
  assert_grep "concurrent=keep" "$dir/home/state/legacy-task.meta" \
    "repair overwrote concurrent metadata state"
  assert_no_grep "endpoint_task_id=" "$dir/home/state/legacy-task.meta" \
    "repair published a binding after metadata drift"
  pass "legacy endpoint repair: metadata drift fails closed without overwriting concurrent state"
}

test_control_lock_contention_refuses_before_runtime_access() {
  local dir lock ready release holder i=0 rc before
  dir=$(make_case control-lock)
  lock="$dir/home/state/.control-legacy-task.lock"
  ready="$dir/ready"
  release="$dir/release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do sleep 0.01; done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$ready" ] || fail "could not stage lifecycle lock contention"
  before=$(cat "$dir/home/state/legacy-task.meta")
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  set +e
  run_repair "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  : > "$release"
  wait "$holder" || fail "lifecycle lock holder failed"
  [ "$rc" -ne 0 ] || fail "repair unexpectedly succeeded under lifecycle lock contention"
  [ "$(cat "$dir/home/state/legacy-task.meta")" = "$before" ] \
    || fail "contended repair changed metadata"
  [ ! -s "$dir/herdr.log" ] || fail "contended repair reached Herdr"
  pass "legacy endpoint repair: lifecycle lock contention refuses before proof or mutation"
}

test_task_inventory_lock_contention_refuses_before_runtime_access() {
  local dir lock ready release holder i=0 rc before
  dir=$(make_case task-set-lock)
  lock="$dir/home/state/.task-set.lock"
  ready="$dir/ready"
  release="$dir/release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do sleep 0.01; done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$ready" ] || fail "could not stage task-inventory lock contention"
  before=$(cat "$dir/home/state/legacy-task.meta")
  FM_HERDR_RESPONSE=$(pane_response "$dir/worktree")
  export FM_HERDR_RESPONSE
  set +e
  run_repair "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  : > "$release"
  wait "$holder" || fail "task-inventory lock holder failed"
  [ "$rc" -ne 0 ] || fail "repair unexpectedly succeeded while the task inventory was changing"
  [ "$(cat "$dir/home/state/legacy-task.meta")" = "$before" ] \
    || fail "task-inventory contention changed metadata"
  [ ! -s "$dir/herdr.log" ] || fail "task-inventory contention reached Herdr"
  pass "legacy endpoint repair: task-inventory changes refuse before proof or mutation"
}

test_no_mistakes_gate_agent_cannot_drive_repair() {
  local dir before rc
  dir=$(make_case gate-agent)
  before=$(cat "$dir/home/state/legacy-task.meta")
  set +e
  env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    "$REPAIR" legacy-task > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 3 "$rc" "gate-agent binding repair refusal"
  [ "$(cat "$dir/home/state/legacy-task.meta")" = "$before" ] \
    || fail "gate-agent refusal changed metadata"
  [ ! -s "$dir/herdr.log" ] || fail "gate-agent refusal reached Herdr"
  pass "legacy endpoint repair: no-mistakes gate agents cannot drive fleet recovery"
}

make_gate_checkout_with_repair() {  # <case-dir>
  local dir=$1 seed="$1/gate-seed" origin="$1/gate-origin.git" \
    bare="$1/.no-mistakes/repos/repair.git" \
    checkout="$1/.no-mistakes/worktrees/repair/run"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$origin"
  fm_git_init_commit "$seed"
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin HEAD:main
  git clone -q --bare "$origin" "$bare"
  git -C "$bare" worktree add --detach "$checkout" main >/dev/null 2>&1
  mkdir -p "$checkout/bin"
  cp "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-repair-legacy-endpoint-binding.sh" "$checkout/bin/"
  printf '%s\n' "$checkout"
}

test_gate_worktree_path_backstop_ignores_caller_root_override() {
  local dir gate_checkout repair normal_root before rc
  dir=$(make_case gate-path-backstop)
  gate_checkout=$(make_gate_checkout_with_repair "$dir")
  repair="$gate_checkout/bin/fm-repair-legacy-endpoint-binding.sh"
  normal_root="$dir/normal-root"
  fm_git_init_commit "$normal_root"
  mkdir -p "$dir/outside"
  before=$(cat "$dir/home/state/legacy-task.meta")
  set +e
  (
    cd "$dir/outside" || exit 111
    env -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$normal_root" PATH="$dir/fakebin:$PATH" \
      "$repair" legacy-task > "$dir/stdout" 2> "$dir/stderr"
  )
  rc=$?
  set -e
  expect_code 3 "$rc" "gate-worktree path backstop with a caller-controlled root override"
  [ "$(cat "$dir/home/state/legacy-task.meta")" = "$before" ] \
    || fail "gate-worktree path refusal changed metadata"
  [ ! -s "$dir/herdr.log" ] || fail "gate-worktree path refusal reached Herdr"
  pass "legacy endpoint repair: gate-worktree path backstop ignores a caller-controlled root override"
}

test_legacy_record_reproduces_the_metadata_only_refusal
test_exact_live_identity_repairs_only_the_binding
test_existing_binding_is_idempotent_without_runtime_access
test_ambiguous_or_wrong_existing_bindings_refuse_without_runtime_access
test_live_identity_mismatch_refuses
test_other_metadata_claims_refuse_before_runtime_access
test_unregistered_or_cross_project_worktrees_refuse
test_metadata_drift_refuses_without_overwriting_concurrent_state
test_control_lock_contention_refuses_before_runtime_access
test_task_inventory_lock_contention_refuses_before_runtime_access
test_no_mistakes_gate_agent_cannot_drive_repair
test_gate_worktree_path_backstop_ignores_caller_root_override
