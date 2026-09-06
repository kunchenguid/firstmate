#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's docker-compose-stack cleanup (Fix 4 in that
# script's header).
#
# Before this fix, a task's worktree could leave a docker compose stack
# running forever after teardown, because nothing ever brought it down.
#
# Covers:
#   - the core fix: a task's own Docker Compose containers and networks are
#     removed by its teardown (test_docker_stack_is_stopped_on_teardown, which
#     FAILS against the pre-fix script).
#   - isolation, the most important property: tearing down one task's stack
#     never touches a second task's unrelated stack, even though both are
#     live at the same time (test_docker_stack_isolation_leaves_other_task_untouched).
#   - a Compose project spanning another worktree is refused as a unit before
#     any of its containers or networks are removed.
#   - an absent docker binary, an unreachable daemon, and a task that never
#     started a stack are all ordinary, silent no-ops.
#   - a container-enumeration failure (daemon reachable, query itself fails)
#     is reported visibly and never blocks teardown.
#   - the identity guard: a "worktree=" meta field corrupted to point at the
#     firstmate home/repo itself, or at a real but unregistered directory,
#     never lets docker cleanup reach a container labeled with that path
#     (test_docker_stack_never_touches_firstmate_root,
#     test_docker_stack_never_touches_firstmate_home,
#     test_docker_stack_never_touches_unregistered_directory).
#
# The ordinary-case tests run with docker mocks everywhere. The core,
# isolation, and identity-guard cases additionally use real containers when a
# reachable daemon is available.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REAL_DOCKER_AVAILABLE=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  REAL_DOCKER_AVAILABLE=1
fi

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-docker-stack)

DOCKER_CLEANUP_CONTAINER_IDS=()
DOCKER_CLEANUP_NETWORKS=()

# tests/lib.sh already owns an EXIT trap for TMP_ROOT; a file with extra
# teardown defines its own trap and calls fm_test_cleanup from inside it (see
# that file's "self-cleaning temp root" section) so both run.
docker_test_cleanup() {
  local id net
  if [ "$REAL_DOCKER_AVAILABLE" = 1 ]; then
    for id in "${DOCKER_CLEANUP_CONTAINER_IDS[@]:-}"; do
      [ -n "$id" ] && docker rm -f "$id" >/dev/null 2>&1 || true
    done
    for net in "${DOCKER_CLEANUP_NETWORKS[@]:-}"; do
      [ -n "$net" ] && docker network rm "$net" >/dev/null 2>&1 || true
    done
  fi
  fm_test_cleanup || true
}
trap docker_test_cleanup EXIT
trap 'docker_test_cleanup; exit 130' INT
trap 'docker_test_cleanup; exit 143' TERM

canon() {  # <dir>
  ( cd "$1" && pwd -P )
}

# Build a fresh sandbox for one task: a bare origin, a project clone, and a
# worktree on its own branch, plus fakebin mocks so teardown never reaches a
# real treehouse/tmux/gh/no-mistakes. Every case uses --force (landed-work
# safety is covered by tests/fm-teardown.test.sh, not this file), so the
# gh/no-mistakes mocks only need to be safe no-ops. Args: <task-id>
make_case() {
  local id=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$id"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/home" \
    "$case_dir/firstmate-root" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
wt=${3:-}
printf '%s\n' "$wt" >> "${FM_DOCKER_TREEHOUSE_LOG:?}"
[ -z "$wt" ] || git worktree remove --force "$wt" >/dev/null 2>&1 || true
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" \
    "$fakebin/no-mistakes" "$fakebin/lsof"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed"
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$id" "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"

  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"

  printf '%s\n' "$case_dir"
}

# Run teardown with PATH mocking. FM_TEARDOWN_GUARD_DONE=1 skips fm-guard.sh's
# unrelated worktree-tangle check, which otherwise inspects $ROOT itself (this
# repo) and is noisy whenever $ROOT happens to be on a non-default branch, as a
# task worktree normally is - not something this docker-focused suite tests.
# Args: <case_dir> <id> [extra args...]
run_teardown() {
  local case_dir=$1 id=$2; shift 2
  FM_HOME="$case_dir/home" \
  FM_ROOT_OVERRIDE="$case_dir/firstmate-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEARDOWN_GUARD_DONE=1 \
  FM_DOCKER_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  FM_FAKE_DOCKER_STATE="$case_dir/docker.state" \
  FM_FAKE_DOCKER_STOP_FAIL_ID="${FM_FAKE_DOCKER_STOP_FAIL_ID:-}" \
  FM_FAKE_DOCKER_RM_FAIL_ID="${FM_FAKE_DOCKER_RM_FAIL_ID:-}" \
  FM_FAKE_DOCKER_NETWORK_RM_FAIL_ID="${FM_FAKE_DOCKER_NETWORK_RM_FAIL_ID:-}" \
  FM_FAKE_DOCKER_HANG_COMMAND="${FM_FAKE_DOCKER_HANG_COMMAND:-}" \
  FM_FAKE_DOCKER_HANG_SECS="${FM_FAKE_DOCKER_HANG_SECS:-3}" \
  FM_TEARDOWN_DOCKER_TIMEOUT_SECS="${FM_TEARDOWN_DOCKER_TIMEOUT_SECS:-10}" \
  FM_TIMEOUT_MECHANISM_OVERRIDE="${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

install_stateful_docker() {
  local case_dir=$1
  : > "$case_dir/docker.state"
  cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_DOCKER_STATE:?}
command=${1:-}
if [ "$command" = network ]; then
  command="network-${2:-}"
fi
if [ "${FM_FAKE_DOCKER_HANG_COMMAND:-}" = "$command" ]; then
  sleep "${FM_FAKE_DOCKER_HANG_SECS:-3}"
  : > "${state}.${command}.completed"
  exit 1
fi
case "${1:-}" in
  info)
    exit 0
    ;;
  ps)
    working_filter=
    project_filter=
    formatted=0
    for arg in "$@"; do
      case "$arg" in
        label=com.docker.compose.project.working_dir=*)
          working_filter=${arg#label=com.docker.compose.project.working_dir=}
          ;;
        label=com.docker.compose.project=*)
          project_filter=${arg#label=com.docker.compose.project=}
          ;;
        --format)
          formatted=1
          ;;
      esac
    done
    [ -f "$state" ] || exit 0
    awk -F '\t' -v working="$working_filter" -v project="$project_filter" -v formatted="$formatted" '
      (working == "" || $2 == working) && (project == "" || $3 == project) {
        if (formatted == 1) print $1 "\t" $3 "\t" $2
        else print $1
      }
    ' "$state"
    ;;
  stop)
    id=${2:-}
    [ "${FM_FAKE_DOCKER_STOP_FAIL_ID:-}" != "$id" ] || exit 1
    tmp="${state}.tmp.$$"
    awk -F '\t' -v OFS='\t' -v id="$id" '$1 == id { $4 = "stopped" } { print }' "$state" > "$tmp" \
      && mv "$tmp" "$state"
    ;;
  rm)
    id=${3:-}
    [ "${FM_FAKE_DOCKER_RM_FAIL_ID:-}" != "$id" ] || exit 1
    tmp="${state}.tmp.$$"
    awk -F '\t' -v OFS='\t' -v id="$id" '$1 != id { print }' "$state" > "$tmp" \
      && mv "$tmp" "$state"
    ;;
  inspect)
    id=${!#}
    status=$(awk -F '\t' -v id="$id" '$1 == id { print $4; exit }' "$state")
    [ -n "$status" ] || exit 1
    if [ "$status" = running ]; then
      echo true
    else
      echo false
    fi
    ;;
  network)
    case "${2:-}" in
      ls)
        project_filter=
        for arg in "$@"; do
          case "$arg" in
            label=com.docker.compose.project=*)
              project_filter=${arg#label=com.docker.compose.project=}
              ;;
          esac
        done
        [ -f "${state}.networks" ] || exit 0
        awk -F '\t' -v project="$project_filter" '$2 == project { print $1 }' "${state}.networks"
        ;;
      rm)
        id=${3:-}
        [ "${FM_FAKE_DOCKER_NETWORK_RM_FAIL_ID:-}" != "$id" ] || exit 1
        tmp="${state}.networks.tmp.$$"
        awk -F '\t' -v id="$id" '$1 != id { print }' "${state}.networks" > "$tmp" \
          && mv "$tmp" "${state}.networks"
        ;;
      *) exit 2 ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/docker"
}

seed_fake_docker_container() {
  local case_dir=$1 id=$2 label=$3 project=${4:-project-$2}
  printf '%s\t%s\t%s\trunning\n' "$id" "$label" "$project" >> "$case_dir/docker.state"
}

seed_fake_docker_network() {
  local case_dir=$1 id=$2 project=$3
  printf '%s\t%s\n' "$id" "$project" >> "$case_dir/docker.state.networks"
}

fake_docker_container_ids() {
  local case_dir=$1 label=$2
  FM_FAKE_DOCKER_STATE="$case_dir/docker.state" \
    "$case_dir/fakebin/docker" ps -aq \
      --filter "label=com.docker.compose.project.working_dir=$label"
}

fake_docker_container_running() {
  local case_dir=$1 id=$2
  FM_FAKE_DOCKER_STATE="$case_dir/docker.state" \
    "$case_dir/fakebin/docker" inspect -f '{{.State.Running}}' "$id"
}

fake_docker_network_exists() {
  local case_dir=$1 id=$2
  awk -F '\t' -v id="$id" '$1 == id { found=1 } END { exit !found }' \
    "$case_dir/docker.state.networks" 2>/dev/null
}

# Build a PATH with every common tool except docker, so `command -v docker`
# genuinely fails - the "docker not installed" case. Mirrors
# tests/fm-teardown.test.sh's make_path_without_lsof for the same reason:
# there is no portable way to hide one binary from a live PATH other than
# building a curated one.
make_path_without_docker() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-docker" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
    lsof mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

# Start a one-container docker compose stack rooted exactly at <dir>, so its
# com.docker.compose.project.working_dir label equals <dir>. Registers the
# stack's default network for this file's own fallback cleanup. Args: <dir>
# <project>
start_docker_stack() {
  local dir=$1 project=$2 out
  cat > "$dir/docker-compose.yml" <<'YML'
services:
  sleeper:
    image: busybox
    command: sleep 3600
YML
  if ! out=$(docker compose -p "$project" -f "$dir/docker-compose.yml" --project-directory "$dir" up -d 2>&1); then
    fail "docker fixture: failed to start compose stack '$project' in $dir: $out"
  fi
  DOCKER_CLEANUP_NETWORKS+=("${project}_default")
}

docker_stack_container_ids() {  # <abs-dir>
  docker ps -aq --filter "label=com.docker.compose.project.working_dir=$1" 2>/dev/null
}

record_container_ids_for_cleanup() {  # <ids, one per line>
  local cid
  while IFS= read -r cid; do
    [ -n "$cid" ] && DOCKER_CLEANUP_CONTAINER_IDS+=("$cid")
  done <<EOF
$1
EOF
}

# Rewrite a case's meta with a different "worktree=" value, everything else
# unchanged from make_case. Used to simulate the exact metadata-corruption
# class the identity guard exists for: a "worktree=" field that does not
# actually point at this task's own registered worktree. Args: <case_dir>
# <id> <bad-worktree-path>
corrupt_meta_worktree() {
  local case_dir=$1 id=$2 bad=$3
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$bad" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
}

# Start a single container carrying exactly the compose working_dir label a
# real stack would have, without needing a real compose stack rooted there -
# so the identity-guard tests below can label a container with the firstmate
# repo's own path, or an unregistered directory's path, without actually
# running docker compose against either. Stores the container id in the named
# caller variable and registers it for cleanup in this shell.
# Args: <working-dir-label-value> <result-variable>
start_labeled_container() {
  local label_value=$1 result_var=$2 out id
  if ! out=$(docker run -d --label "com.docker.compose.project.working_dir=$label_value" busybox sleep 3600 2>&1); then
    fail "docker fixture: failed to start labeled container for $label_value: $out"
  fi
  id=$(printf '%s\n' "$out" | tail -1)
  DOCKER_CLEANUP_CONTAINER_IDS+=("$id")
  printf -v "$result_var" '%s' "$id"
}

test_docker_stack_is_stopped_on_teardown() {
  local id=docker-core case_dir abs_wt project ids rc
  case_dir=$(make_case "$id")
  abs_wt=$(canon "$case_dir/wt")
  project="fmtest-${id//[^a-z0-9]/}-$$"
  start_docker_stack "$abs_wt" "$project"

  ids=$(docker_stack_container_ids "$abs_wt")
  [ -n "$ids" ] || fail "docker-stack-core: fixture did not start any container under $abs_wt"
  record_container_ids_for_cleanup "$ids"

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-stack-core: teardown should succeed"

  ids=$(docker_stack_container_ids "$abs_wt")
  [ -z "$ids" ] || fail "docker-stack-core: container(s) for $abs_wt are still alive after teardown: $ids"
  if docker network inspect "${project}_default" >/dev/null 2>&1; then
    fail "docker-stack-core: Compose network ${project}_default remains after teardown"
  fi
  assert_absent "$case_dir/wt" \
    "docker-stack-core: treehouse did not return the worktree after docker cleanup"
  assert_grep "$case_dir/wt" "$case_dir/treehouse.log" \
    "docker-stack-core: teardown never reached treehouse return"
  pass "teardown stops and removes the docker container(s) started by its own worktree"
}

test_docker_stack_isolation_leaves_other_task_untouched() {
  local id_a=docker-iso-a id_b=docker-iso-b case_a case_b abs_a abs_b proj_a proj_b ids_a ids_b rc state

  case_a=$(make_case "$id_a")
  case_b=$(make_case "$id_b")
  abs_a=$(canon "$case_a/wt")
  abs_b=$(canon "$case_b/wt")
  proj_a="fmtest-${id_a//[^a-z0-9]/}-$$"
  proj_b="fmtest-${id_b//[^a-z0-9]/}-$$"
  start_docker_stack "$abs_a" "$proj_a"
  start_docker_stack "$abs_b" "$proj_b"

  ids_a=$(docker_stack_container_ids "$abs_a")
  ids_b=$(docker_stack_container_ids "$abs_b")
  [ -n "$ids_a" ] || fail "docker-stack-isolation: fixture did not start task A's container"
  [ -n "$ids_b" ] || fail "docker-stack-isolation: fixture did not start task B's container"
  record_container_ids_for_cleanup "$ids_a"
  record_container_ids_for_cleanup "$ids_b"

  set +e
  run_teardown "$case_a" "$id_a" --force > "$case_a/stdout" 2> "$case_a/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-stack-isolation: teardown of task A should succeed"

  ids_a=$(docker_stack_container_ids "$abs_a")
  [ -z "$ids_a" ] || fail "docker-stack-isolation: task A's own container(s) are still alive after its teardown"

  ids_b=$(docker_stack_container_ids "$abs_b")
  [ -n "$ids_b" ] || fail "docker-stack-isolation: tearing down task A also removed task B's container(s) - isolation failure"
  state=$(docker inspect -f '{{.State.Running}}' "$ids_b" 2>/dev/null | head -1)
  [ "$state" = "true" ] || fail "docker-stack-isolation: task B's container is no longer running after task A's teardown"

  pass "tearing down task A's docker stack leaves task B's unrelated, concurrently-live stack fully intact"
}

test_portable_docker_stack_is_stopped_on_teardown() {
  local id=docker-portable-core case_dir abs_wt ids rc compose_project=portable-core-project
  case_dir=$(make_case "$id")
  abs_wt=$(canon "$case_dir/wt")
  install_stateful_docker "$case_dir"
  seed_fake_docker_container "$case_dir" portable-core "$abs_wt" "$compose_project"
  seed_fake_docker_network "$case_dir" portable-core-network "$compose_project"

  ids=$(fake_docker_container_ids "$case_dir" "$abs_wt")
  [ "$ids" = portable-core ] || fail "docker-portable-core: fixture did not expose the task container"

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-portable-core: teardown should succeed"

  ids=$(fake_docker_container_ids "$case_dir" "$abs_wt")
  [ -z "$ids" ] || fail "docker-portable-core: task container remains after teardown"
  if fake_docker_network_exists "$case_dir" portable-core-network; then
    fail "docker-portable-core: task Compose network remains after teardown"
  fi
  assert_grep "removed Compose project $compose_project for task $id: 1 container(s), 1 network(s)" \
    "$case_dir/stderr" "docker-portable-core: successful cleanup was not reported exactly"
  assert_absent "$case_dir/wt" \
    "docker-portable-core: treehouse did not return the worktree after docker cleanup"
  pass "portable teardown removes its task's docker container before returning the worktree"
}

test_portable_shared_compose_project_is_refused() {
  local id=docker-portable-shared case_dir abs_wt other_wt rc state compose_project=portable-shared-project
  case_dir=$(make_case "$id")
  abs_wt=$(canon "$case_dir/wt")
  other_wt="$case_dir/other-wt"
  mkdir -p "$other_wt"
  other_wt=$(canon "$other_wt")
  install_stateful_docker "$case_dir"
  seed_fake_docker_container "$case_dir" shared-task "$abs_wt" "$compose_project"
  seed_fake_docker_container "$case_dir" shared-other "$other_wt" "$compose_project"
  seed_fake_docker_network "$case_dir" shared-network "$compose_project"

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-portable-shared: refusal should not block teardown"

  state=$(fake_docker_container_running "$case_dir" shared-task)
  [ "$state" = true ] || fail "docker-portable-shared: task container was removed from a cross-worktree project"
  state=$(fake_docker_container_running "$case_dir" shared-other)
  [ "$state" = true ] || fail "docker-portable-shared: other worktree container was removed"
  fake_docker_network_exists "$case_dir" shared-network \
    || fail "docker-portable-shared: shared project network was removed"
  assert_grep "has containers outside task $id's exact worktree" "$case_dir/stderr" \
    "docker-portable-shared: cross-worktree ownership refusal was not reported"
  pass "a Compose project spanning another worktree is refused intact and reported"
}

test_portable_docker_stack_isolation() {
  local id_a=docker-portable-iso-a id_b=docker-portable-iso-b case_a case_b abs_a abs_b ids_a ids_b rc state
  case_a=$(make_case "$id_a")
  case_b=$(make_case "$id_b")
  abs_a=$(canon "$case_a/wt")
  abs_b=$(canon "$case_b/wt")
  install_stateful_docker "$case_a"
  seed_fake_docker_container "$case_a" portable-a "$abs_a"
  seed_fake_docker_container "$case_a" portable-b "$abs_b"

  set +e
  run_teardown "$case_a" "$id_a" --force > "$case_a/stdout" 2> "$case_a/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-portable-isolation: teardown of task A should succeed"

  ids_a=$(fake_docker_container_ids "$case_a" "$abs_a")
  [ -z "$ids_a" ] || fail "docker-portable-isolation: task A's container remains after teardown"
  ids_b=$(fake_docker_container_ids "$case_a" "$abs_b")
  [ "$ids_b" = portable-b ] || fail "docker-portable-isolation: teardown of task A removed task B's container"
  state=$(fake_docker_container_running "$case_a" portable-b)
  [ "$state" = true ] || fail "docker-portable-isolation: task B's container is no longer running"
  pass "portable teardown leaves another task's docker stack intact"
}

test_docker_removal_failure_is_reported_and_non_blocking() {
  local id=docker-remove-fail case_dir abs_wt rc state
  case_dir=$(make_case "$id")
  abs_wt=$(canon "$case_dir/wt")
  install_stateful_docker "$case_dir"
  seed_fake_docker_container "$case_dir" sticky-container "$abs_wt"

  set +e
  FM_FAKE_DOCKER_STOP_FAIL_ID=sticky-container \
  FM_FAKE_DOCKER_RM_FAIL_ID=sticky-container \
    run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-remove-fail: removal failure should not block teardown"

  state=$(fake_docker_container_running "$case_dir" sticky-container)
  [ "$state" = true ] || fail "docker-remove-fail: fixture did not preserve the failed container"
  assert_grep "could not confirm removal" "$case_dir/stderr" \
    "docker-remove-fail: teardown did not report the failed removal"
  assert_grep "sticky-container" "$case_dir/stderr" \
    "docker-remove-fail: teardown did not identify the container requiring manual inspection"
  pass "a failed docker removal is visible and does not block teardown"
}

test_docker_network_removal_failure_is_reported() {
  local id=docker-network-remove-fail case_dir abs_wt rc compose_project=network-remove-fail-project
  case_dir=$(make_case "$id")
  abs_wt=$(canon "$case_dir/wt")
  install_stateful_docker "$case_dir"
  seed_fake_docker_container "$case_dir" network-owner "$abs_wt" "$compose_project"
  seed_fake_docker_network "$case_dir" sticky-network "$compose_project"

  set +e
  FM_FAKE_DOCKER_NETWORK_RM_FAIL_ID=sticky-network \
    run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-network-remove-fail: network failure should not block teardown"

  [ -z "$(fake_docker_container_ids "$case_dir" "$abs_wt")" ] \
    || fail "docker-network-remove-fail: verified project container remains"
  fake_docker_network_exists "$case_dir" sticky-network \
    || fail "docker-network-remove-fail: fixture did not preserve the failed network"
  assert_grep "network cleanup failed for: sticky-network" "$case_dir/stderr" \
    "docker-network-remove-fail: failed network removal was not reported exactly"
  pass "a failed Compose network removal is visible and non-blocking"
}

test_docker_commands_are_bounded() {
  local command id case_dir abs_wt rc
  for command in info ps stop rm network-ls network-rm; do
    id="docker-timeout-$command"
    case_dir=$(make_case "$id")
    abs_wt=$(canon "$case_dir/wt")
    install_stateful_docker "$case_dir"
    seed_fake_docker_container "$case_dir" "timeout-$command" "$abs_wt"
    seed_fake_docker_network "$case_dir" "timeout-$command-network" "project-timeout-$command"

    set +e
    FM_FAKE_DOCKER_HANG_COMMAND="$command" \
    FM_FAKE_DOCKER_HANG_SECS=3 \
    FM_TEARDOWN_DOCKER_TIMEOUT_SECS=1 \
    FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
      run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" "docker-timeout-$command: a hung docker command should not block teardown"
    assert_absent "$case_dir/docker.state.$command.completed" \
      "docker-timeout-$command: docker command outlived its hard deadline"
    assert_present "$case_dir/treehouse.log" \
      "docker-timeout-$command: teardown did not continue to worktree return"
  done
  pass "hung docker commands are bounded and never block teardown"
}

test_docker_absent_does_not_break_teardown() {
  local id=docker-absent case_dir path_no_docker rc
  case_dir=$(make_case "$id")
  path_no_docker=$(make_path_without_docker "$case_dir")

  set +e
  FM_HOME="$case_dir/home" \
  FM_ROOT_OVERRIDE="$case_dir/firstmate-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEARDOWN_GUARD_DONE=1 \
  FM_DOCKER_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  PATH="$case_dir/fakebin:$path_no_docker" \
    "$TEARDOWN" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-absent: teardown should succeed when docker is not installed"
  assert_no_grep "cannot enumerate docker" "$case_dir/stderr" \
    "docker-absent: should not attempt to enumerate docker containers"
  assert_no_grep "stopping" "$case_dir/stderr" \
    "docker-absent: should never report stopping a container it could not have found"
  pass "an absent docker binary is a silent no-op and never breaks teardown"
}

test_docker_daemon_unreachable_does_not_break_teardown() {
  local id=docker-no-daemon case_dir rc
  case_dir=$(make_case "$id")
  cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/docker"

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-no-daemon: teardown should succeed when the daemon is unreachable"
  assert_no_grep "cannot enumerate docker" "$case_dir/stderr" \
    "docker-no-daemon: an unreachable daemon should be a silent normal case, not a reported warning"
  pass "an unreachable docker daemon is a silent no-op and never breaks teardown"
}

test_no_docker_stack_present_completes_silently() {
  local id=docker-no-stack case_dir rc
  case_dir=$(make_case "$id")
  cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  info|ps) exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/docker"

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "no-docker-stack: teardown should succeed when the task never started a docker stack"
  assert_no_grep "cannot enumerate docker" "$case_dir/stderr" \
    "no-docker-stack: should not report an enumeration failure when there is none"
  assert_no_grep "stopping" "$case_dir/stderr" \
    "no-docker-stack: should never report stopping a container when it never started one"
  pass "a task that never started a docker stack tears down silently"
}

test_docker_enumeration_failure_is_reported_and_non_blocking() {
  local id=docker-enum-fail case_dir rc
  case_dir=$(make_case "$id")
  cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  ps) echo "docker: simulated enumeration failure" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/docker"

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-enum-fail: a container-enumeration failure should never block teardown"
  assert_grep "cannot enumerate docker containers" "$case_dir/stderr" \
    "docker-enum-fail: teardown should visibly report that it could not identify the docker stack"
  pass "a docker enumeration failure is reported visibly and never blocks teardown"
}

# The most consequential guard in this feature: a corrupted or wrong
# "worktree=" meta field must never let docker cleanup reach the captain's own
# firstmate home/repo, even though every other check in this file already
# passes (docker present, daemon reachable, real container to find).
test_docker_stack_never_touches_firstmate_root() {
  local id=docker-guard-root case_dir canon_root cid rc
  case_dir=$(make_case "$id")
  canon_root=$(canon "$case_dir/firstmate-root")
  corrupt_meta_worktree "$case_dir" "$id" "$canon_root"
  start_labeled_container "$canon_root" cid

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-guard-root: teardown should still succeed"

  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ] \
    || fail "docker-guard-root: CRITICAL - a container labeled with the firstmate repo's own path was removed via a corrupted worktree field"
  assert_grep "firstmate repo itself" "$case_dir/stderr" \
    "docker-guard-root: teardown should visibly report refusing to treat the firstmate repo/home as a task worktree"
  pass "a worktree field corrupted to point at the firstmate repo itself never reaches its docker containers"
}

test_docker_stack_never_touches_firstmate_home() {
  local id=docker-guard-home case_dir canon_home cid rc
  case_dir=$(make_case "$id")
  canon_home=$(canon "$case_dir/home")
  corrupt_meta_worktree "$case_dir" "$id" "$canon_home"
  start_labeled_container "$canon_home" cid

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-guard-home: teardown should still succeed"

  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ] \
    || fail "docker-guard-home: CRITICAL - a container labeled with the active firstmate home's path was removed via a corrupted worktree field"
  assert_grep "active firstmate home itself" "$case_dir/stderr" \
    "docker-guard-home: teardown should visibly report refusing to treat the active firstmate home as a task worktree"
  pass "a worktree field corrupted to point at the active firstmate home never reaches its docker containers"
}

# A worktree field pointing at a real, existing directory that simply is not
# a registered git worktree of the recorded project - not the captain's home,
# just untrusted - must be treated with the same "cannot verify" caution.
test_docker_stack_never_touches_unregistered_directory() {
  local id=docker-guard-unregistered case_dir bogus_dir canon_bogus cid rc
  case_dir=$(make_case "$id")
  bogus_dir="$TMP_ROOT/$id-bogus"
  mkdir -p "$bogus_dir"
  canon_bogus=$(canon "$bogus_dir")
  corrupt_meta_worktree "$case_dir" "$id" "$bogus_dir"
  start_labeled_container "$canon_bogus" cid

  set +e
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "docker-guard-unregistered: teardown should still succeed"

  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ] \
    || fail "docker-guard-unregistered: a container labeled with an unregistered directory was removed"
  assert_grep "cannot verify" "$case_dir/stderr" \
    "docker-guard-unregistered: teardown should visibly report it cannot verify this is the task's own registered worktree"
  pass "a worktree field pointing at a real but unregistered directory never reaches its docker containers"
}

test_portable_docker_stack_is_stopped_on_teardown
test_portable_docker_stack_isolation
test_portable_shared_compose_project_is_refused
test_docker_removal_failure_is_reported_and_non_blocking
test_docker_network_removal_failure_is_reported
test_docker_commands_are_bounded
test_docker_absent_does_not_break_teardown
test_docker_daemon_unreachable_does_not_break_teardown
test_no_docker_stack_present_completes_silently
test_docker_enumeration_failure_is_reported_and_non_blocking

if [ "$REAL_DOCKER_AVAILABLE" = 1 ]; then
  test_docker_stack_is_stopped_on_teardown
  test_docker_stack_isolation_leaves_other_task_untouched
  test_docker_stack_never_touches_firstmate_root
  test_docker_stack_never_touches_firstmate_home
  test_docker_stack_never_touches_unregistered_directory
else
  echo "skip: real docker unavailable; portable docker teardown cases passed"
fi
