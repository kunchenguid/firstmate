#!/usr/bin/env bash
# Behavioral regressions for bin/fm-e2e-stack.sh - the durable record and
# guarded removal of a task's local end-to-end test infrastructure.
#
# Every case drives the real script through a fake `docker` whose whole world is
# one TSV inventory file, so the ownership gates and the residue verification
# are exercised for real without a docker daemon.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

E2E="$ROOT/bin/fm-e2e-stack.sh"
TMP_ROOT=$(fm_test_tmproot fm-e2e-stack)

# make_case <name> -> echoes the case dir. Builds an isolated home plus a fake
# docker whose inventory starts empty.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/docker" "$fakebin"
  : > "$case_dir/docker/inv"
  # Fake docker. Inventory rows are "kind<TAB>name<TAB>project<TAB>task".
  # It answers only the reads and writes this script actually performs.
  cat > "$fakebin/docker" <<'SH'
#!/usr/bin/env bash
set -u
S=${FAKE_DOCKER_DIR:?}
INV=$S/inv
[ -f "$INV" ] || : > "$INV"

# Value of --filter label=<key>=<value>, if present.
filter_value() {
  local k=$1 a; shift
  for a in "$@"; do
    case $a in "label=$k="*) printf '%s' "${a#label="$k"=}"; return 0 ;; esac
  done
  return 1
}

# First positional after the subcommand, skipping docker's `--` end-of-options.
target() {
  local a
  for a in "$@"; do
    case $a in --) continue ;; -*) continue ;; *) printf '%s' "$a"; return 0 ;; esac
  done
  return 1
}

case "${1-}" in
  info) exit "${FAKE_DOCKER_INFO_RC:-0}" ;;
  ps)
    if v=$(filter_value com.docker.compose.project "$@"); then
      awk -F'\t' -v p="$v" '$1=="container" && $3==p {print $2}' "$INV"
    elif v=$(filter_value ai.revolab.fm.task "$@"); then
      awk -F'\t' -v t="$v" '$1=="container" && $4==t {print $2}' "$INV"
    else
      awk -F'\t' '$1=="container" {print $2}' "$INV"
    fi ;;
  inspect)
    c=$2; shift 2; fmt=""
    for a in "$@"; do case $a in --format) : ;; *) fmt=$a ;; esac; done
    case $fmt in
      *.Name*) printf '/%s\n' "$c" ;;
      *com.docker.compose.project.working_dir*) printf '%s\n' "${FAKE_DOCKER_WORKDIR:-}" ;;
      *com.docker.compose.project*) awk -F'\t' -v c="$c" '$2==c {print $3}' "$INV" ;;
      *ai.revolab.fm.task*) awk -F'\t' -v c="$c" '$2==c {print $4}' "$INV" ;;
      *) : ;;
    esac ;;
  volume)
    case ${2-} in
      ls) if v=$(filter_value com.docker.compose.project "$@"); then
            awk -F'\t' -v p="$v" '$1=="volume" && $3==p {print $2}' "$INV"
          else awk -F'\t' '$1=="volume" {print $2}' "$INV"; fi ;;
      rm) shift 2; n=$(target "$@") || exit 1
          # Refuse BEFORE mutating, so a simulated failure really leaves it.
          [ "${FAKE_VOLUME_RM_RC:-0}" = 0 ] || exit "${FAKE_VOLUME_RM_RC}"
          awk -F'\t' -v n="$n" '!($1=="volume" && $2==n)' "$INV" > "$INV.new" \
            && mv "$INV.new" "$INV" ;;
      inspect) shift 2; n=$(target "$@") || exit 1
          awk -F'\t' -v n="$n" '$1=="volume" && $2==n {f=1} END {exit !f}' "$INV"
          exit $? ;;
    esac ;;
  network)
    case ${2-} in
      ls) if v=$(filter_value com.docker.compose.project "$@"); then
            awk -F'\t' -v p="$v" '$1=="network" && $3==p {print $2}' "$INV"
          else awk -F'\t' '$1=="network" {print $2}' "$INV"; fi ;;
      rm) shift 2; n=$(target "$@") || exit 1
          awk -F'\t' -v n="$n" '!($1=="network" && $2==n)' "$INV" > "$INV.new" \
            && mv "$INV.new" "$INV" ;;
    esac ;;
  compose)
    printf '%s\n' "$*" >> "$S/compose.log"
    p=""; prev=""
    for a in "$@"; do [ "$prev" = "-p" ] && p=$a; prev=$a; done
    [ "${FAKE_COMPOSE_RC:-0}" = 0 ] && [ -n "$p" ] \
      && { awk -F'\t' -v p="$p" '$3 != p' "$INV" > "$INV.new" && mv "$INV.new" "$INV"; }
    exit "${FAKE_COMPOSE_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/docker"
  printf '%s\n' "$case_dir"
}

# inv <case-dir> <kind> <name> <project> <task>: append one inventory row.
inv() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$1/docker/inv"
}

# Count of live inventory rows. `grep -c` prints 0 AND exits 1 on no match, so
# an `|| printf 0` fallback would emit "0" twice.
inv_rows() {
  local n
  n=$(grep -c . "$1/docker/inv" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

# run_e2e <case-dir> <args...>
run_e2e() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DOCKER="$case_dir/fakebin/docker" \
  FAKE_DOCKER_DIR="$case_dir/docker" \
    "$E2E" "$@"
}

# record_stack <case-dir> <task> <project> [extra args...]
record_stack() {
  local case_dir=$1 task=$2 project=$3; shift 3
  run_e2e "$case_dir" record "$task" \
    --project "$project" --stack revcaf-db --repo Conversational-AI-Framework \
    --scenario org-scope-write-path --worktree "$case_dir/wt" \
    --compose-file "$case_dir/dc.yaml" "$@"
}

test_record_round_trips_and_replaces_a_reprovisioned_project() {
  local c out
  c=$(make_case record-round-trip)
  record_stack "$c" t1 fm-t1-revcaf --service db --port PORT_POSTGRES=15433 >/dev/null
  out=$(run_e2e "$c" read t1)
  assert_contains "$out" 'schema=fm-e2e-stack.v1' "record omits its schema marker"
  assert_contains "$out" 'project=fm-t1-revcaf' "record omits the project"
  assert_contains "$out" 'compose_file=' "record omits the compose file it must tear down with"
  assert_contains "$out" 'port=PORT_POSTGRES=15433' "record loses a port whose value itself contains '='"

  # Re-provisioning the same project must replace its block, not add a second.
  run_e2e "$c" record t1 --project fm-t1-revcaf --stack revcaf-full \
    --repo Conversational-AI-Framework --scenario org-scope-write-path \
    --worktree "$c/wt" --compose-file "$c/dc.yaml" --service db --service qdrant >/dev/null
  out=$(run_e2e "$c" read t1)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^project=fm-t1-revcaf$')" \
    "re-recording one project left two blocks for it"
  assert_contains "$out" 'stack=revcaf-full' "re-recording did not replace the stale block"
  assert_not_contains "$out" 'stack=revcaf-db' "re-recording kept the superseded block"

  # A second, different project coexists.
  record_stack "$c" t1 fm-t1-revocall >/dev/null
  out=$(run_e2e "$c" read t1)
  assert_equals 2 "$(printf '%s\n' "$out" | grep -c '^project=')" \
    "a task holding two stacks lost one of them"
  pass "record round-trips its fields, replaces a re-provisioned project, and keeps distinct ones"
}

test_record_refuses_a_project_cleanup_could_not_safely_own() {
  local c code
  c=$(make_case record-refusals)

  # No fm- prefix: this is what protects a hand-run or pipeline-owned stack,
  # whose project name is its own directory basename.
  code=0
  run_e2e "$c" record t1 --project backend --stack s --repo r --scenario s \
    --worktree "$c/wt" --compose-file "$c/dc.yaml" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "record accepted a project name outside the fm- namespace"
  assert_contains "$(run_e2e "$c" read t1)" ABSENT "a refused record was written anyway"

  # Not docker's own charset: keeps filter syntax out of `--filter label=...`.
  code=0
  run_e2e "$c" record t1 --project 'fm-t1 revcaf' --stack s --repo r --scenario s \
    --worktree "$c/wt" --compose-file "$c/dc.yaml" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "record accepted a project name outside docker's charset"

  # A missing required field must refuse rather than record an empty value.
  code=0
  run_e2e "$c" record t1 --project fm-t1-revcaf --stack s --repo r \
    --compose-file "$c/dc.yaml" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "record accepted a stack with no scenario or worktree"

  # No compose file means `down` would have nothing to tear down with.
  code=0
  run_e2e "$c" record t1 --project fm-t1-revcaf --stack s --repo r --scenario s \
    --worktree "$c/wt" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "record accepted a stack with no compose file"
  pass "record refuses every stack whose ownership cleanup could not later prove"
}

test_record_refuses_an_external_volume_that_is_shared_local_data() {
  local c code out
  c=$(make_case record-external-volume)

  # RevoCall's deploy stack pins six external volumes to fixed names; compose
  # removes an external volume on no code path, so cleanup removes them by
  # name. An unsuffixed name is the shared local development data.
  code=0
  run_e2e "$c" record t1 --project fm-t1-revocall --stack revocall-admin-db \
    --repo RevoCall --scenario admin-portal-login --worktree "$c/wt" \
    --compose-file "$c/dc.yaml" --external-volume revocall-infra_postgres-data >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "record accepted an external volume carrying no task id"

  run_e2e "$c" record t1 --project fm-t1-revocall --stack revocall-admin-db \
    --repo RevoCall --scenario admin-portal-login --worktree "$c/wt" \
    --compose-file "$c/dc.yaml" --external-volume revocall-infra_postgres-data-t1 >/dev/null
  out=$(run_e2e "$c" read t1)
  assert_contains "$out" 'external_volume=revocall-infra_postgres-data-t1' \
    "record rejected a task-suffixed external volume"
  pass "record admits only external volumes whose names carry the task id"
}

test_gate_refuses_a_project_another_task_record_claims() {
  local c out code
  c=$(make_case gate-collision)
  record_stack "$c" t1 fm-t1-revcaf >/dev/null
  # A second task record naming the same project is the collision itself,
  # whichever record is stale. Never resolved by guessing.
  cp "$c/state/t1.e2e-stack" "$c/state/t2.e2e-stack"

  code=0
  out=$(run_e2e "$c" gate t1 2>&1) || code=$?
  expect_code 1 "$code" "gate passed a project two task records claim"
  assert_contains "$out" 'gate3 REFUSED' "gate did not name the claim collision"
  assert_contains "$out" 't2 claims project fm-t1-revcaf' "gate did not name the other claimant"
  pass "gate refuses a project or worktree another task record also claims"
}

test_gate_refuses_when_labels_and_the_record_disagree() {
  local c out code
  c=$(make_case gate-divergence)
  record_stack "$c" t1 fm-t1-revcaf >/dev/null

  # A container inside a recorded project carrying someone else's task label.
  inv "$c" container fm-t1-revcaf-db fm-t1-revcaf other-task
  code=0
  out=$(run_e2e "$c" gate t1 2>&1) || code=$?
  expect_code 1 "$code" "gate passed a container labelled for another task"
  assert_contains "$out" 'carries task label other-task' "gate did not name the foreign label"
  assert_not_contains "$out" 'gate1 ok' "gate reported success beside its own refusal"

  # The other direction: a container labelled for this task in a project the
  # record does not name. Also a divergence, never a removal target.
  : > "$c/docker/inv"
  inv "$c" container stray-db someone-else t1
  code=0
  out=$(run_e2e "$c" gate t1 2>&1) || code=$?
  expect_code 1 "$code" "gate passed a labelled container in an unrecorded project"
  assert_contains "$out" 'is unrecorded' "gate did not name the unrecorded project"
  pass "gate refuses in both directions when container labels and the record disagree"
}

test_gate_cannot_pass_without_docker() {
  local c out code
  c=$(make_case gate-no-docker)
  record_stack "$c" t1 fm-t1-revcaf >/dev/null
  code=0
  out=$(FAKE_DOCKER_INFO_RC=1 run_e2e "$c" gate t1 2>&1) || code=$?
  expect_code 1 "$code" "gate passed while the container gates could not be proved"
  assert_contains "$out" 'docker unavailable' "gate did not say why it could not prove ownership"

  # An absent record is not an implicit pass either.
  code=0
  out=$(run_e2e "$c" gate no-such-task 2>&1) || code=$?
  expect_code 1 "$code" "gate passed with no record at all"
  pass "gate refuses rather than passing when it cannot prove ownership"
}

test_down_removes_only_what_the_record_names_then_clears_it() {
  local c out
  c=$(make_case down-success)
  run_e2e "$c" record t1 --project fm-t1-revocall --stack revocall-admin-db \
    --repo RevoCall --scenario admin-portal-login --worktree "$c/wt" \
    --compose-file "$c/dc.yaml" --external-volume revocall-infra_postgres-data-t1 \
    --network fm-t1-revocall --created-network >/dev/null
  inv "$c" container fm-t1-revocall-postgres fm-t1-revocall t1
  inv "$c" volume fm-t1-revocall_pgdata fm-t1-revocall t1
  inv "$c" network fm-t1-revocall_default fm-t1-revocall t1
  inv "$c" volume revocall-infra_postgres-data-t1 '' ''
  # A neighbour with no record at all must survive: an anonymous project can be
  # live work, such as a no-mistakes pipeline run under its own directory name.
  inv "$c" container backend-postgres-1 backend ''

  out=$(run_e2e "$c" down t1 2>&1) || fail "down refused a stack whose gates all pass"$'\n'"$out"
  assert_contains "$out" 'removed (containers, volumes, network)' "down did not report the removal"
  assert_grep 'down -v --remove-orphans' "$c/docker/compose.log" \
    "down did not remove volumes and orphans with the project's own compose files"
  assert_equals 1 "$(inv_rows "$c")" "down removed more or less than the record named"
  assert_grep 'backend-postgres-1' "$c/docker/inv" "down removed an unrecorded neighbour"
  assert_contains "$(run_e2e "$c" read t1)" ABSENT "a verified removal left its record behind"
  pass "down removes exactly the recorded stack, spares unrecorded neighbours, then clears the record"
}

test_down_refuses_and_removes_nothing_when_a_gate_fails() {
  local c out code before
  c=$(make_case down-refusal)
  record_stack "$c" t1 fm-t1-revcaf >/dev/null
  inv "$c" container fm-t1-revcaf-db fm-t1-revcaf other-task
  before=$(inv_rows "$c")

  code=0
  out=$(run_e2e "$c" down t1 2>&1) || code=$?
  expect_code 1 "$code" "down proceeded past a failed ownership gate"
  assert_contains "$out" 'nothing was removed' "down did not say it removed nothing"
  assert_equals "$before" "$(inv_rows "$c")" "a refused down still changed the inventory"
  assert_contains "$(run_e2e "$c" read t1)" 'project=fm-t1-revcaf' "a refused down cleared the record"
  assert_absent "$c/docker/compose.log" "a refused down still invoked compose"
  pass "down refuses on a failed gate, removes nothing, and preserves the record for retry"
}

test_down_dry_run_changes_nothing() {
  local c out
  c=$(make_case down-dry-run)
  record_stack "$c" t1 fm-t1-revcaf >/dev/null
  inv "$c" container fm-t1-revcaf-db fm-t1-revcaf t1
  out=$(run_e2e "$c" down t1 --dry-run 2>&1) || fail "dry run refused a passing stack"$'\n'"$out"
  assert_contains "$out" 'would run' "dry run did not print the removal plan"
  assert_equals 1 "$(inv_rows "$c")" "dry run changed the inventory"
  assert_absent "$c/docker/compose.log" "dry run invoked compose"
  assert_contains "$(run_e2e "$c" read t1)" 'project=fm-t1-revcaf' "dry run cleared the record"
  pass "down --dry-run prints the plan and changes nothing"
}

test_down_treats_surviving_residue_as_failure() {
  local c out code
  c=$(make_case down-residue)
  record_stack "$c" t1 fm-t1-revcaf >/dev/null
  inv "$c" container fm-t1-revcaf-db fm-t1-revcaf t1
  code=0
  out=$(FAKE_COMPOSE_RC=1 run_e2e "$c" down t1 2>&1) || code=$?
  expect_code 1 "$code" "down reported success while its containers survived"
  assert_contains "$out" 'RESIDUE remains' "down did not name the surviving residue"
  assert_contains "$(run_e2e "$c" read t1)" 'project=fm-t1-revcaf' \
    "down cleared the record of a stack it failed to remove"

  # An external volume that refuses removal is the same kind of failure, and
  # matters more: compose never removes those, so only this check catches it.
  c=$(make_case down-residue-external)
  run_e2e "$c" record t1 --project fm-t1-revocall --stack revocall-admin-db \
    --repo RevoCall --scenario s --worktree "$c/wt" --compose-file "$c/dc.yaml" \
    --external-volume revocall-infra_postgres-data-t1 >/dev/null
  inv "$c" volume revocall-infra_postgres-data-t1 '' ''
  code=0
  out=$(FAKE_VOLUME_RM_RC=1 run_e2e "$c" down t1 2>&1) || code=$?
  expect_code 1 "$code" "down reported success while an external volume survived"
  assert_contains "$out" 'RESIDUE external volume' "down did not name the surviving external volume"
  assert_contains "$(run_e2e "$c" read t1)" 'project=fm-t1-revocall' \
    "down cleared the record of an external volume it failed to remove"
  pass "down fails loudly and keeps its record when any resource survives removal"
}

test_strays_reports_and_never_removes() {
  local c out
  c=$(make_case strays)
  : > "$c/state/live-task.meta"
  inv "$c" container fm-gone-revcaf-db fm-gone-revcaf gone-task
  inv "$c" container fm-live-revcaf-db fm-live-revcaf live-task
  inv "$c" container backend-postgres-1 backend ''

  # A label is written by whoever started the container, so a value that is not
  # a usable task id must be reported as unreadable rather than probed as a path.
  inv "$c" container fm-evil-db fm-evil '../../etc/passwd'

  out=$(run_e2e "$c" strays 2>&1) || fail "strays failed"$'\n'"$out"
  assert_contains "$out" 'record=GONE' "strays did not flag a container whose task record is gone"
  assert_contains "$out" 'record=LIVE' "strays did not spare a container whose task is still live"
  assert_contains "$out" 'unlabelled' "strays did not report an unattributed container"
  assert_contains "$out" 'record=UNREADABLE' "strays treated an unusable task label as a task id"
  assert_equals 4 "$(inv_rows "$c")" "strays removed a container instead of reporting it"
  assert_absent "$c/docker/compose.log" "strays invoked compose"
  pass "strays reports ownership without removing anything, and never trusts a label as a path"
}

test_recorded_paths_survive_a_space() {
  local c out spaced
  c=$(make_case spaced-paths)
  spaced="$c/My Compose/dc.yaml"
  mkdir -p "$c/My Compose"
  : > "$spaced"
  run_e2e "$c" record t1 --project fm-t1-revcaf --stack revcaf-db \
    --repo Conversational-AI-Framework --scenario org-scope-write-path \
    --worktree "$c/wt" --compose-file "$spaced" --service db >/dev/null
  assert_contains "$(run_e2e "$c" read t1)" "compose_file=$spaced" \
    "a compose path containing a space did not round-trip"

  inv "$c" container fm-t1-revcaf-db fm-t1-revcaf t1
  out=$(run_e2e "$c" down t1 2>&1) || fail "down failed on a compose path with a space"$'\n'"$out"
  # One -f, with the whole path intact. Word-splitting the record would have
  # produced two bogus -f arguments and torn down nothing.
  assert_grep "-f $spaced " "$c/docker/compose.log" \
    "down split a spaced compose path into separate -f arguments"
  assert_equals 1 "$(grep -c -- ' -f ' "$c/docker/compose.log")" \
    "down passed more -f arguments than the record named"
  assert_equals 0 "$(inv_rows "$c")" "down left the stack in place"
  pass "a recorded compose path containing a space reaches compose as one argument"
}

test_clear_is_idempotent() {
  local c
  c=$(make_case clear)
  record_stack "$c" t1 fm-t1-revcaf >/dev/null
  run_e2e "$c" clear t1 >/dev/null
  assert_absent "$c/state/t1.e2e-stack" "clear left the record in place"
  run_e2e "$c" clear t1 >/dev/null || fail "clear failed on an already-cleared record"
  pass "clear removes the record and is a no-op on a second run"
}

test_record_round_trips_and_replaces_a_reprovisioned_project
test_record_refuses_a_project_cleanup_could_not_safely_own
test_record_refuses_an_external_volume_that_is_shared_local_data
test_gate_refuses_a_project_another_task_record_claims
test_gate_refuses_when_labels_and_the_record_disagree
test_gate_cannot_pass_without_docker
test_down_removes_only_what_the_record_names_then_clears_it
test_down_refuses_and_removes_nothing_when_a_gate_fails
test_down_dry_run_changes_nothing
test_down_treats_surviving_residue_as_failure
test_strays_reports_and_never_removes
test_clear_is_idempotent
test_recorded_paths_survive_a_space
