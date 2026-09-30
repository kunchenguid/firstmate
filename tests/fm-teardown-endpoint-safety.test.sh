#!/usr/bin/env bash
# Regression tests for cleanup endpoint and worktree-slot identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
# The fixture binds normal task records to Herdr; historical refusal is
# covered by fm-retired-backends.test.sh, without weakening these lock tests.
write_herdr_meta() {
  local file=$1 arg id window='' binding=0 generation=0
  shift
  id=$(basename "$file" .meta)
  local args=()
  for arg in "$@"; do
    case "$arg" in
      window=*:fm-*) window="window=isolated:w1:p-$id"; args+=("$window") ;;
      endpoint_task_id=*) binding=1; args+=("$arg") ;;
      spawn_gen=*) generation=1; args+=("$arg") ;;
      *) args+=("$arg") ;;
    esac
  done
  [ "$binding" = 1 ] || args+=("endpoint_task_id=$id")
  [ "$generation" = 1 ] || args+=("spawn_gen=s-$id")
  fm_write_meta "$file" "backend=herdr" "herdr_session=isolated" \
    "herdr_workspace_id=w1" "herdr_tab_id=w1:t-$id" "herdr_pane_id=w1:p-$id" "${args[@]}"
}

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
case "$1 ${2:-}" in
  'session list') if [ -f "${FM_RUNTIME_LOG}.sessions" ]; then cat "${FM_RUNTIME_LOG}.sessions"; exit; fi; jq -n --arg socket "${FM_RUNTIME_LOG}.sock" '{sessions:[{name:"isolated",running:true,socket_path:$socket}]}' ;;
  'status --json') if [ -f "${FM_RUNTIME_LOG}.status" ]; then cat "${FM_RUNTIME_LOG}.status"; exit; fi; jq -n --arg socket "${FM_RUNTIME_LOG}.sock" '{client:{version:"0.7.1",protocol:14},server:{running:true,session:"isolated",socket:$socket,version:"0.7.1",protocol:14}}' ;;
  'pane get')
    if [ -e "${FM_RUNTIME_LOG}.$3.closed" ]; then
      echo '{"error":{"code":"pane_not_found"}}'
    else
      jq -n --arg p "$3" --arg cwd "${FM_FAKE_PANE_PATH:-/changed-directory}" \
        '{result:{pane:{pane_id:$p,workspace_id:"w1",tab_id:"w1:t1",foreground_cwd:$cwd}}}'
    fi ;;
  'pane close') touch "${FM_RUNTIME_LOG}.$3.closed" ;;
  'workspace list') echo '{"result":{"workspaces":[]}}' ;;
  *) echo '{}' ;;
esac
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/herdr" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

create_fixture_socket() { # <socket>
  python3 - "$1" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()
PY
}

stage_absent_bound_endpoint() {  # <case> <id>
  local dir=$1 id=$2 socket instance journal label
  socket="$dir/runtime.log.sock"
  [ -S "$socket" ] || create_fixture_socket "$socket" || fail 'cannot create fixture socket'
  instance=$(python3 - "$socket" <<'PY'
import hashlib,os,sys
st=os.lstat(sys.argv[1])
print(hashlib.sha256(repr((st.st_dev,st.st_ino,st.st_mtime_ns,st.st_ctime_ns)).encode()).hexdigest())
PY
  ) || fail 'cannot read fixture socket identity'
  label=$(bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label "$2" abcdefghijklmnopqrstuv' _ "$ROOT" "$id")
  journal="$dir/home/state/$id.herdr-presentation"
  cat > "$journal" <<EOF
version=3
task_id=$id
projection_id=abcdefghijklmnopqrstuv
home=$(cd "$dir/home" && pwd -P)
session=isolated
workspace_id=w1
tab_id=w1:t-$id
pane_id=w1:p-$id
parent_workspace_id=anchor
parent_label=anchor
workspace_label=$label
task_label=fm-$id
spawn_gen=s-$id
terminal_id=t-$id
session_instance=$instance
shell_pid=$$
shell_start=synthetic-shell
EOF
  chmod 600 "$journal"
  : > "$dir/runtime.log.w1:p-$id.closed"
}

stage_archived_action() {  # <case> <id> <kind> <phase>
  local dir=$1 id=$2 kind=$3 phase=$4 candidate receipt_sha action_id
  action_id="$id.g1.a1"
  mkdir -p "$dir/home/data/$id"
  printf 'Deliver the complete requested result\n' > "$dir/home/data/$id/brief.md"
  FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" init "$id" >/dev/null
  candidate="$dir/$id-action.json"
  FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" lifecycle "$id" | jq --arg id "$action_id" --arg kind "$kind" \
    '.next_action={id:$id,kind:$kind,phase:"prepared",expected_execution_generation:.execution_generation,payload_ref:.assessment.evidence[0].ref,payload_sha256:.assessment.evidence[0].sha256,receipt_ref:null,attempts:0,attempt_limit:1,recheck_at:"2000-01-01T00:00:00Z",deadline:"2099-01-01T00:00:00Z"} | .next_action_seq=2' > "$candidate"
  chmod 600 "$candidate"
  FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" reconcile "$id" --expected-revision 1 --record "$candidate" >/dev/null
  FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" action "$id" --action-id "$action_id" --phase attempted >/dev/null \
    || fail 'fixture action attempt failed'
  if [ "$phase" = uncertain ]; then
    receipt_sha=$(shasum -a 256 "$dir/home/data/$id/brief.md" | awk '{print $1}')
    FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" action "$id" --action-id "$action_id" --phase uncertain \
      --receipt-ref "data/$id/brief.md" --receipt-sha256 "$receipt_sha" >/dev/null \
      || fail 'fixture uncertain action receipt failed'
  fi
  fm_test_archive_goal "$dir/home" "$id"
}

mark_case_as_treehouse_pool() {  # <case>
  local dir=$1
  rm -rf "$dir/worktree"
  mkdir -p "$dir/pool/1"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s "pool/1/project" "$dir/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  : > "$dir/worktree/sentinel"
}

claim_pool_slot() {  # <case> <task-id> [home]
  local dir=$1 id=$2 home=${3:-$1/home}
  printf 'task=%s\nhome=%s\nspawn_gen=s-%s\n' "$id" "$home" "$id" > "$dir/pool/1/.fm-slot-owner"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_control_lock_contention_refuses_before_mutation() {
  local dir id=locked-task lock holder i=0 rc
  dir=$(make_case control-lock)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.control-$id.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held lifecycle lock"
  }
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown unexpectedly succeeded under lifecycle lock contention"
  assert_present "$dir/home/state/$id.meta" "contended teardown removed task metadata"
  assert_present "$dir/worktree/sentinel" "contended teardown changed the worktree"
  assert_present "$lock" "contended teardown removed another action's lock"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another lifecycle action is already running" \
    "contended teardown should serialize before reading mutable task metadata"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: a concurrent lifecycle action refuses before mutation"
}

test_non_pool_teardown_ignores_task_set_lock() {
  local dir id=non-pool-task lock ready holder i=0
  dir=$(make_case non-pool-task-set-lock)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/missing-worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.task-set.lock"
  ready="$dir/task-set-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage an in-progress task publication"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "non-pool teardown was blocked by an unrelated task publication: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "non-pool teardown left task metadata"
  assert_present "$lock" "non-pool teardown removed the publisher's lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: non-pool cleanup ignores unrelated task publication locks"
}

test_metadata_lock_serializes_destructive_cleanup() {
  local dir id=metadata-locked-task lock ready release holder teardown_pid i=0 rc
  dir=$(make_case metadata-lock)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.meta-$id.lock"
  ready="$dir/meta-lock-ready"
  release="$dir/meta-lock-release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do
      sleep 0.01
    done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held metadata lock"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" &
  teardown_pid=$!
  sleep 0.2
  if ! kill -0 "$teardown_pid" 2>/dev/null; then
    : > "$release"
    wait "$holder" 2>/dev/null || true
    wait "$teardown_pid" 2>/dev/null || true
    fail "teardown did not wait for the shared metadata writer lock"
  fi
  assert_present "$dir/home/state/$id.meta" "metadata-lock contention removed task metadata"
  assert_present "$dir/worktree/sentinel" "metadata-lock contention changed the worktree"
  [ ! -s "$dir/runtime.log" ] \
    || fail "metadata-lock contention reached the runtime: $(cat "$dir/runtime.log")"

  : > "$release"
  wait "$holder" || fail "metadata lock holder failed"
  wait "$teardown_pid"; rc=$?
  expect_code 0 "$rc" "teardown should complete after the metadata writer releases"
  assert_absent "$dir/home/state/$id.meta" \
    "serialized teardown left a task record that a completed writer could resurrect"
  pass "fm-teardown: destructive cleanup serializes with metadata writers"
}

test_supported_backend_endpoint_records_validate() {
  local dir id=herdr-task target
  dir=$(make_case valid-backends)
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "isolated:w1:p-$id" ] || fail 'endpoint identity changed'
  set +e
  fm_backend_kill herdr "" >/dev/null 2>&1
  target=$?
  set -e
  [ "$target" -ne 0 ] || fail 'generic kill accepted empty target'
  pass 'cleanup identity: valid Herdr record validates, empty target refuses'
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

test_exact_endpoint_cleanup_preserves_neighbor() {
  local dir id=target
  dir=$(make_case exact-endpoint)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  write_herdr_meta "$dir/home/state/target2.meta" \
    'window=isolated:fm-target2' "worktree=$dir/other" "project=$dir/project" 'kind=scout'
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" || fail "exact cleanup failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" 'target record survived valid cleanup'
  assert_present "$dir/home/state/target2.meta" 'neighbor record was removed'
  assert_present "$dir/runtime.log.w1:p-target.closed" 'exact endpoint was not closed'
  assert_absent "$dir/runtime.log.w1:p-target2.closed" 'prefix neighbor endpoint was closed'
  pass 'teardown closes exact recorded Herdr endpoint and preserves prefix neighbor'
}

test_bare_relative_origin_shares_project_lock_with_clone() {
  local dir second_project primary_lock clone_lock
  dir=$(make_case bare-relative-origin-lock)
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm lock-fixture
  mkdir -p "$dir/project/remotes"
  git clone -q --bare "$dir/project" "$dir/project/remotes/origin.git"
  git -C "$dir/project" remote add origin remotes/origin.git
  second_project="$dir/second-project"
  git clone -q "$dir/project/remotes/origin.git" "$second_project"

  primary_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/project") \
    || fail "could not resolve the primary project's bare-origin lock"
  clone_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$second_project") \
    || fail "could not resolve the clone project's absolute-origin lock"
  [ "$primary_lock" = "$clone_lock" ] \
    || fail "bare and absolute forms of the same local origin resolved different project locks"

  pass "Treehouse locking resolves a bare local origin against its source project, matching the provisioned clone"
}

test_reused_pool_slot_refuses_before_touching_the_other_task() {
  local dir id=stale-task other=live-task worker rc

  dir=$(make_case slot-reuse)
  mark_case_as_treehouse_pool "$dir"
  # The reuse collision: the pool slot recorded for a finished task has already
  # been handed to another task, whose worker is live in it right now.
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$id"
  write_herdr_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a second task record still holds"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reused pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a second task record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the live task's record"
  assert_present "$dir/home/state/$id.meta" "teardown removed the stale task's record before refusing"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a contested pool slot: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "refusal should name the other task holding the slot"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  pass "fm-teardown: a pool slot named by a second task record is never returned, killed, or reset"
}

test_sole_slot_record_still_tears_down() {
  local dir id=sole-task worker

  dir=$(make_case slot-sole)
  mark_case_as_treehouse_pool "$dir"
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$id"
  # A neighbouring task on its OWN slot must not look like a collision.
  mkdir -p "$dir/other-worktree"
  write_herdr_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/other-worktree" "project=$dir/project" "kind=scout"
  ( cd "$dir/other-worktree" && exec sleep 30 ) &
  worker=$!

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task that solely holds its slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "uncontested teardown left the task record"
  assert_present "$dir/home/state/neighbour.meta" "uncontested teardown removed the neighbour's record"
  kill -0 "$worker" 2>/dev/null || fail "uncontested teardown killed a worker in a different slot"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "uncontested teardown did not return its own pool slot: $(cat "$dir/runtime.log")"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  pass "fm-teardown: a task that solely holds its slot still returns it"
}

test_recorded_endpoint_that_changed_directory_still_tears_down() {
  local dir id=moved-task

  dir=$(make_case slot-endpoint-moved)
  mark_case_as_treehouse_pool "$dir"
  mkdir -p "$dir/other-directory"
  # The exact recorded worker may legitimately cd outside its worktree. Its
  # endpoint identity still owns the lifecycle; cwd alone must not brick it.
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$id"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown refused its recorded endpoint after it changed directory: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "moved-endpoint teardown left the task record"
  grep -Fq "herdr <pane> <close> <w1:p-$id>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not stop the exact recorded worker: $(cat "$dir/runtime.log")"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not return its uncontested pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: an exact recorded endpoint still tears down after changing cwd outside its worktree"
}

assert_reassigned_slot_left_alone() {  # <case> <id> <other> <description>
  local dir=$1 id=$2 other=$3 description=$4
  assert_absent "$dir/home/state/$id.meta" "$description: the stale task's own record was not removed"
  assert_present "$dir/pool/1/.fm-slot-owner" "$description: another task's slot claim was removed"
  assert_contains "$(cat "$dir/pool/1/.fm-slot-owner")" "task=$other" \
    "$description: another task's slot claim was rewritten"
  assert_present "$dir/pool/1/project/.git" "$description: the reassigned slot's checkout was removed"
  ! grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "$description: the reassigned slot was returned to the pool: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "$description: the warning should name the task the slot was reassigned to"
  assert_contains "$(cat "$dir/stderr")" "reassigned" \
    "$description: the warning should name the reassignment as the cause"
}

test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot() {
  local dir id=stale-task other=reassigned-task worker rc

  # Dirty slot, --force, and a live worker inside it: --force authorizes
  # discarding this task's unlanded work, which is already gone with the slot,
  # never the other task's live work.
  dir=$(make_case slot-reassigned)
  mark_case_as_treehouse_pool "$dir"
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "teardown of a task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reassigned pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot another task had claimed"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "dirty reassigned slot with --force"
  assert_contains "$(cat "$dir/stderr")" "$dir/other-home" \
    "the warning should name the claimant's home"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # The same reassignment on a CLEAN slot: a landed ship task torn down without
  # --force, which is the shape of the real incident. A clean, fully landed copy
  # passes every unlanded-work check, so only the ownership determination can
  # keep this slot out of the pool; a guard keyed off dirtiness would return it
  # and destroy the live task's copy.
  dir=$(make_case slot-reassigned-clean)
  mark_case_as_treehouse_pool "$dir"
  rm -f "$dir/worktree/sentinel"
  [ -z "$(git -C "$dir/worktree" status --porcelain)" ] \
    || fail "clean-slot fixture is not clean: $(git -C "$dir/worktree" status --porcelain)"
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=ship"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of a clean ship task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the clean reassigned pool slot"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "clean reassigned slot without --force"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # A claim that exists but cannot be read as a claim proves nothing either way,
  # so it refuses rather than guessing the slot is still this task's.
  dir=$(make_case slot-claim-unreadable)
  mark_case_as_treehouse_pool "$dir"
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  printf 'not-a-claim\n' > "$dir/pool/1/.fm-slot-owner"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot whose claim could not be read"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot whose claim could not be read"
  assert_present "$dir/pool/1/.fm-slot-owner" "teardown removed an unreadable slot claim"
  assert_present "$dir/home/state/$id.meta" "teardown removed the task record on an unreadable claim"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on an unreadable slot claim: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$dir/pool/1/.fm-slot-owner" \
    "unreadable-claim refusal should name the claim file to inspect"

  pass "fm-teardown: a pool slot claimed by another task is left alone while the task's own cleanup finishes"
}

# Only an exact task/generation claim authorizes slot return. Historical slots
# without a claim retain their directory and task record for reconciliation.
test_own_claim_tears_down_and_absent_claim_is_retained() {
  local dir id=owned-task

  dir=$(make_case slot-claim-own)
  mark_case_as_treehouse_pool "$dir"
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$id"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task holding its own slot claim failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "own-claim teardown left the task record"
  assert_absent "$dir/pool/1/.fm-slot-owner" "own-claim teardown left its spent slot claim behind"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "own-claim teardown did not return its own pool slot: $(cat "$dir/runtime.log")"

  dir=$(make_case slot-claim-absent)
  mark_case_as_treehouse_pool "$dir"
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown accepted an unclaimed pool slot without positive ownership"
  assert_present "$dir/home/state/$id.meta" "unclaimed-slot teardown removed the cleanup obligation"
  assert_present "$dir/worktree/sentinel" "unclaimed-slot teardown changed the recorded directory"
  [ ! -s "$dir/runtime.log" ] \
    || fail "unclaimed-slot teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "has no slot-owner claim" \
    "unclaimed-slot refusal should name the missing positive identity"

  pass "fm-teardown: an exact claim returns its slot while an unclaimed slot retains its cleanup obligation"
}

test_historical_secondmate_record_refuses_without_mutation() {
  local dir id=retired-home rc
  dir=$(make_case historical-secondmate)
  write_herdr_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "home=$dir/retired-home" \
    "project=$dir/project" "kind=secondmate"
  mkdir -p "$dir/retired-home"
  printf 'preserve\n' > "$dir/retired-home/sentinel"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "historical secondmate teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "historical secondmate metadata was removed"
  assert_present "$dir/retired-home/sentinel" "historical secondmate home was modified"
  assert_present "$dir/worktree/sentinel" "historical secondmate worktree was modified"
  [ ! -s "$dir/runtime.log" ] \
    || fail "historical secondmate refusal reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "historical secondmate record" \
    "historical secondmate refusal should explain the unsupported record"
  pass "fm-teardown: historical secondmate records and homes are preserved by refusal"
}

test_open_goal_preserves_resources_before_cleanup() {
  local dir id=open-goal variant rc
  local -a args=()
  for variant in normal forced endpoint-only; do
    dir=$(make_case "open-goal-$variant")
    mark_case_as_treehouse_pool "$dir"
    write_herdr_meta "$dir/home/state/$id.meta" \
      "window=isolated:fm-$id" "worktree=$dir/worktree" \
      "project=$dir/project" "kind=scout"
    claim_pool_slot "$dir" "$id"
    mkdir -p "$dir/home/data/$id"
    printf 'Deliver the complete requested result\n' > "$dir/home/data/$id/brief.md"
    printf 'Only a partial milestone is complete\n' > "$dir/home/data/$id/report.md"
    # No user decision remains, but the requested result is still unfinished.
    FM_HOME="$dir/home" "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null
    FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" init "$id" >/dev/null
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    cp "$dir/home/data/$id/lifecycle.json" "$dir/goal-before"
    cp "$dir/pool/1/.fm-slot-owner" "$dir/claim-before"
    args=()
    case "$variant" in
      forced) args=(--force) ;;
      endpoint-only) args=(--endpoint-only --expect-spawn-gen "s-$id") ;;
    esac
    rc=0
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
      "$TEARDOWN" "$id" "${args[@]}" > "$dir/stdout" 2> "$dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "$variant teardown accepted an unfinished goal"
    assert_contains "$(cat "$dir/stderr")" 'task goal is still open' \
      "$variant teardown did not refuse for the unfinished goal"
    cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "$variant changed task metadata"
    cmp -s "$dir/goal-before" "$dir/home/data/$id/lifecycle.json" || fail "$variant changed the goal"
    cmp -s "$dir/claim-before" "$dir/pool/1/.fm-slot-owner" || fail "$variant changed the slot claim"
    assert_present "$dir/worktree/sentinel" "$variant removed unfinished work"
    assert_present "$dir/home/data/$id/report.md" "$variant removed the partial report"
    [ ! -s "$dir/runtime.log" ] || fail "$variant reached endpoint or slot cleanup for an open goal"
  done
  pass 'fm-teardown: open goals retain endpoint, slot, worktree and records even with a partial report or force'
}

test_completed_endpoint_ignores_historical_admission_gates() {
  local dir id variant rc
  for variant in uncertain missing-journal malformed-journal wrong-task wrong-generation shared-endpoint; do
    id="completed-$variant"
    dir=$(make_case "$id")
    write_herdr_meta "$dir/home/state/$id.meta" \
      "window=isolated:fm-$id" "worktree=$dir/worktree" "project=$dir/project" "kind=ship"
    stage_archived_action "$dir" "$id" cleanup uncertain
    mkdir -p "$dir/home/data/$id"
    printf 'Retained completed report\n' > "$dir/home/data/$id/report.md"
    case "$variant" in
      malformed-journal) printf 'unreadable historical journal\n' > "$dir/home/state/$id.herdr-presentation" ;;
      wrong-task) sed -i "s/^endpoint_task_id=$id$/endpoint_task_id=another-task/" "$dir/home/state/$id.meta" ;;
      shared-endpoint) cp "$dir/home/state/$id.meta" "$dir/home/state/another-task.meta" ;;
    esac
    rc=0
    local expected="s-$id"
    [ "$variant" != wrong-generation ] || expected=another-generation
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
      FM_SUPERVISION_ACTOR=short PATH="$dir/fakebin:$PATH" \
      "$TEARDOWN" "$id" --endpoint-only --expect-spawn-gen "$expected" \
      > "$dir/stdout" 2> "$dir/stderr" || rc=$?
    case "$variant" in
      wrong-task|wrong-generation|shared-endpoint)
        [ "$rc" -ne 0 ] || fail "$variant changed a different resolved target"
        ! grep -Fq 'pane <close>' "$dir/runtime.log" || fail "$variant closed an unrelated target"
        ;;
      *)
        [ "$rc" = 0 ] || fail "$variant historical evidence blocked completed window closure: $(cat "$dir/stderr")"
        assert_present "$dir/runtime.log.w1:p-$id.closed" 'exact completed pane was not closed'
        jq -e '.phases.pane_close.state=="confirmed"' "$dir/home/state/$id.cleanup.json" >/dev/null || fail 'endpoint absence was not recorded'
        FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" lifecycle "$id" | \
          jq -e '.disposition=="archived" and .next_action.phase=="uncertain"' >/dev/null || fail 'closure changed historical business evidence'
        ;;
    esac
    assert_present "$dir/home/state/$id.meta" 'endpoint-only cleanup erased the task record'
    assert_present "$dir/worktree/sentinel" 'endpoint-only cleanup touched the copy'
    assert_present "$dir/home/data/$id/report.md" 'endpoint-only cleanup removed the report'
  done
  pass 'completed exact windows close without short binding, journal or continuation admission; wrong task/generation and shared endpoints stay intact'
}

test_completed_copy_preservation_ignores_force() {
  local dir id variant
  for variant in dirty unlanded; do
    id="completed-force-$variant"
    dir=$(make_case "$id")
    write_herdr_meta "$dir/home/state/$id.meta" \
      "window=isolated:fm-$id" "worktree=$dir/worktree" "project=$dir/project" "kind=ship"
    git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm base
    rm -rf "$dir/worktree"
    git -C "$dir/project" worktree add -q -b "$id" "$dir/worktree"
    printf 'Preserve completed task content\n' > "$dir/worktree/sentinel"
    if [ "$variant" = unlanded ]; then
      git -C "$dir/worktree" add sentinel
      git -C "$dir/worktree" -c user.name=test -c user.email=test@example.invalid commit -qm unlanded
    fi
    stage_archived_action "$dir" "$id" cleanup uncertain
    run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" || fail "completed $variant window was blocked: $(cat "$dir/stderr")"
    assert_present "$dir/runtime.log.w1:p-$id.closed" 'completed pane was not closed'
    assert_present "$dir/worktree/sentinel" 'force bypassed completed-copy preservation'
    assert_absent "$dir/home/state/$id.meta" 'completed resource record was not archived'
  done
  pass 'completed dirty and unlanded copies remain even when the legacy force flag is supplied'
}

test_completed_pool_uncertain_ownership_retains_copy() {
  local dir id variant
  for variant in absent malformed stale-generation foreign-home; do
    id="completed-slot-$variant"
    dir=$(make_case "$id")
    mark_case_as_treehouse_pool "$dir"
    rm "$dir/worktree/sentinel"
    write_herdr_meta "$dir/home/state/$id.meta" \
      "window=isolated:fm-$id" "worktree=$dir/worktree" "project=$dir/project" "kind=ship"
    case "$variant" in
      malformed) printf 'task=\n' > "$dir/pool/1/.fm-slot-owner" ;;
      stale-generation) claim_pool_slot "$dir" "$id"; sed -i 's/^spawn_gen=.*/spawn_gen=another-generation/' "$dir/pool/1/.fm-slot-owner" ;;
      foreign-home) claim_pool_slot "$dir" "$id" "$dir/another-home" ;;
    esac
    stage_archived_action "$dir" "$id" steer uncertain
    run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" || fail "slot $variant blocked completed window closure: $(cat "$dir/stderr")"
    assert_present "$dir/runtime.log.w1:p-$id.closed" 'completed window was not actually closed'
    assert_present "$dir/pool/1/project/.git" 'unproved copy ownership allowed deletion'
    assert_absent "$dir/home/state/$id.meta" 'completed resource record was not archived'
    ! grep -Fq 'treehouse <return>' "$dir/runtime.log" || fail 'unproved pool ownership allowed return'
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
      "$TEARDOWN" "$id" --copy-only --expect-spawn-gen "s-$id" >/dev/null || fail 'retired pool copy observation failed'
    ! grep -Fq 'treehouse <return>' "$dir/runtime.log" || fail 'copy-only returned an unproved/foreign pool slot'
  done
  pass 'uncertain or foreign pool ownership retains the copy while completed windows and records retire'
}

test_retained_copy_only_followthrough() {
  local dir id variant before_runtime before_report rc copy_path
  for variant in dirty unlanded shared primary identity-changed disposal-interruption disposal-before-effect; do
    id="copy-followthrough-$variant"
    dir=$(make_case "$id")
    git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm base
    rm -rf "$dir/worktree"
    git -C "$dir/project" worktree add -q -b "$id" "$dir/worktree"
    printf 'Retained task content\n' > "$dir/worktree/sentinel"
    if [ "$variant" != dirty ] && [ "$variant" != disposal-interruption ] && [ "$variant" != disposal-before-effect ]; then
      git -C "$dir/worktree" add sentinel
      git -C "$dir/worktree" -c user.name=test -c user.email=test@example.invalid commit -qm content
    fi
    copy_path="$dir/worktree"
    if [ "$variant" = primary ]; then copy_path="$dir/project"; fi
    write_herdr_meta "$dir/home/state/$id.meta" \
      "window=isolated:fm-$id" "worktree=$copy_path" "project=$dir/project" "kind=ship"
    if [ "$variant" = shared ]; then
      write_herdr_meta "$dir/home/state/sibling.meta" \
        'window=isolated:fm-sibling' "worktree=$copy_path" "project=$dir/project" 'kind=ship'
    fi
    # Preserve an uncertain archived business effect separately from copy disposal.
    stage_archived_action "$dir" "$id" steer uncertain
    printf 'Preserved final report\n' > "$dir/home/data/$id/report.md"
    before_report=$(shasum "$dir/home/data/$id/report.md")
    run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" || fail "retained copy setup failed: $(cat "$dir/stderr")"
    assert_absent "$dir/home/state/$id.meta" 'retirement kept completed execution metadata active'
    before_runtime=$(cat "$dir/runtime.log")
    jq -e '.copy_binding.copy.inode>0 and .phases.directory_return.state=="retained"' \
      "$dir/home/state/$id.cleanup.json" >/dev/null || fail 'exact retained copy identity was not durable before metadata retirement'
    if [ "$variant" = identity-changed ]; then
      mv "$dir/worktree" "$dir/original-retained-copy"
      mkdir "$dir/worktree"
      printf 'Unrelated replacement content\n' > "$dir/worktree/replacement"
    fi
    rc=0
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
      "$TEARDOWN" "$id" --copy-only --expect-spawn-gen "s-$id" > "$dir/copy.out" 2> "$dir/copy.err" || rc=$?
    [ "$(cat "$dir/runtime.log")" = "$before_runtime" ] || fail 'copy-only repeated an endpoint operation'
    case "$variant" in
      identity-changed)
        [ "$rc" -ne 0 ] || fail 'replacement inode was admitted as the retired copy'
        assert_present "$dir/worktree/replacement" 'copy-only removed replacement content'
        ;;
      *)
        [ "$rc" = 0 ] || fail "copy-only readback failed: $(cat "$dir/copy.err")"
        assert_present "$copy_path/.git" 'copy-only removed protected copy'
        ;;
    esac
    [ "$(shasum "$dir/home/data/$id/report.md")" = "$before_report" ] || fail 'copy follow-through changed the report'
    FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" lifecycle "$id" | \
      jq -e '.disposition=="archived" and .next_action.phase=="uncertain"' >/dev/null || fail 'copy-only revived business or accepted its uncertain effect'
    if [ "$variant" = dirty ] || [ "$variant" = disposal-interruption ] || [ "$variant" = disposal-before-effect ]; then
      # One actual relevant release: commit and integrate the original copy.
      git -C "$dir/worktree" add sentinel
      git -C "$dir/worktree" -c user.name=test -c user.email=test@example.invalid commit -qm content
      git -C "$dir/project" merge --ff-only "$id" >/dev/null
      if [ "$variant" = disposal-interruption ] || [ "$variant" = disposal-before-effect ]; then
        local real_git
        real_git=$(command -v git)
        cat > "$dir/fakebin/git" <<SH
#!/bin/sh
if [ "\$3 \$4" = 'worktree remove' ]; then
  [ "$variant" = disposal-before-effect ] && exit 73
  "$real_git" "\$@" || exit \$?
  exit 73
fi
exec "$real_git" "\$@"
SH
        chmod +x "$dir/fakebin/git"
        rc=0
        FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
          "$TEARDOWN" "$id" --copy-only --expect-spawn-gen "s-$id" > "$dir/crash.out" 2> "$dir/crash.err" || rc=$?
        [ "$rc" -ne 0 ] || fail 'injected post-disposal response failure was hidden'
        if [ "$variant" = disposal-before-effect ]; then
          assert_present "$dir/worktree/sentinel" 'pre-effect failure removed the original copy'
          rc=0
          FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
            "$TEARDOWN" "$id" --copy-only --expect-spawn-gen "s-$id" > "$dir/pending.out" 2> "$dir/pending.err" || rc=$?
          [ "$rc" -ne 0 ] || fail 'pending existing copy disposal was blindly retried'
          assert_present "$dir/worktree/sentinel" 'uncertain existing copy was removed on retry'
          jq -e '.phases.directory_return.state=="pending"' "$dir/home/state/$id.cleanup.json" >/dev/null || fail 'pending copy obligation was lost'
          [ "$(cat "$dir/runtime.log")" = "$before_runtime" ] || fail 'pending copy replayed endpoint'
          continue
        fi
        assert_absent "$dir/worktree" 'fixture did not interrupt after the actual disposal effect'
        jq -e '.phases.directory_return.state=="pending"' "$dir/home/state/$id.cleanup.json" >/dev/null \
          || fail 'uncertain disposal lost its retained intent'
        rm "$dir/fakebin/git"
      fi
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
        "$TEARDOWN" "$id" --copy-only --expect-spawn-gen "s-$id" > "$dir/released.out" 2> "$dir/released.err" \
        || fail "eligible retained copy was not disposed: $(cat "$dir/released.err")"
      assert_absent "$dir/worktree" 'eligible retained copy remains after confirmed disposal'
      jq -e '.phases.directory_return.state=="confirmed"' "$dir/home/state/$id.cleanup.json" >/dev/null || fail 'copy disposal was not confirmed'
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
        "$TEARDOWN" "$id" --copy-only --expect-spawn-gen "s-$id" >/dev/null || fail 'copy-only confirmed retry did not converge'
      [ "$(cat "$dir/runtime.log")" = "$before_runtime" ] || fail 'later copy follow-through repeated endpoint effects'
      assert_absent "$dir/home/state/$id.meta" 'copy-only recreated business metadata'
    fi
  done
  pass 'retired copy-only follow-through disposes original content after integration; protected copies, replacement identity, reports and archived uncertain business effects stay intact without endpoint replay'
}

test_retained_copy_only_followthrough
test_completed_pool_uncertain_ownership_retains_copy
test_completed_copy_preservation_ignores_force
test_completed_endpoint_ignores_historical_admission_gates

test_open_goal_preserves_resources_before_cleanup
test_invalid_endpoint_records_refuse_before_mutation
test_control_lock_contention_refuses_before_mutation
test_non_pool_teardown_ignores_task_set_lock
test_metadata_lock_serializes_destructive_cleanup
test_supported_backend_endpoint_records_validate
test_recorded_process_identity_cleanup_is_exact
test_exact_endpoint_cleanup_preserves_neighbor
test_bare_relative_origin_shares_project_lock_with_clone
test_reused_pool_slot_refuses_before_touching_the_other_task
test_sole_slot_record_still_tears_down
test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot
test_own_claim_tears_down_and_absent_claim_is_retained
test_recorded_endpoint_that_changed_directory_still_tears_down
test_historical_secondmate_record_refuses_without_mutation
