#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's assigned dev-port pair wiring
# (bin/fm-worktree-runtime-lib.sh).
#
# Contract under test:
#   - a project carrying its own code/web/.ports.main must not launch with
#     neither --backend-port nor --frontend-port and no --no-ports: that left a
#     live worktree occupying a dev port pair with no line in the global port
#     ledger. Checked purely on the contract FILE's presence, never on project
#     name or path shape, so a real tree with no .ports.main stays a silent
#     no-op.
#   - the pair arrives as firstmate's explicit input at intake: parsed,
#     validated (both together, positive integers), recorded in
#     state/<id>.meta, then validated again against .ports.main and live binds
#     by the library after the worktree settles. Malformed or one-sided values
#     refuse loudly and fail the spawn.
#   - --secondmate homes are never project checkouts and refuse the pair;
#     --relaunch adopts the already-provisioned worktree and refuses all three
#     port flags; batch dispatch forwards the shared decision to every pair.
#
# The refusals fire at argument-validation time or right after the project
# path resolves, always before any worktree move, backend window/session, or
# task metadata write, so these assertions stop at "exit code, stderr, no meta,
# nothing sent to the backend".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-ports-guard)

make_ports_guard_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SENDLOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_SENDLOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_ports_guard_case <name> <id> [--with-contract]: a home plus a real
# project/worktree pair. --with-contract seeds the project's own
# code/web/.ports.main so the project counts as port-contract-carrying.
make_ports_guard_case() {
  local name=$1 id=$2 with_contract=${3:-} case_dir home proj wt fakebin sendlog initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sendlog="$case_dir/send.log"
  fakebin=$(make_ports_guard_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  : > "$sendlog"

  git init --quiet -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  # A port-contract project keeps its per-worktree pair file gitignored, which
  # is exactly why a recycled pooled worktree can carry one across occupants.
  printf 'code/web/.ports.worktree\n' > "$proj/.gitignore"
  git -C "$proj" add README.md .gitignore
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$proj" "$proj.origin.git"
  git -C "$proj" remote add origin "file://$proj.origin.git"
  initial=$(git -C "$proj" rev-parse HEAD)
  git -C "$proj" worktree add --quiet --detach "$wt" "$initial"

  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  if [ "$with_contract" = --with-contract ]; then
    mkdir -p "$proj/code/web"
    {
      printf 'BACKEND_PORT=8802\n'
      printf 'FRONTEND_PORT=5302\n'
    } > "$proj/code/web/.ports.main"
  fi
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

read_ports_guard_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SEND_LOG <<EOF
$1
EOF
}

run_ports_guard_spawn() {
  local id=$1
  shift
  : > "$SEND_LOG"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_SENDLOG="$SEND_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

# --- 1. contract present + neither port flag given -> refused ----------------

test_contract_present_no_ports_is_refused() {
  local rec id out status
  id=ports-guard-refuse-z1
  rec=$(make_ports_guard_case ports-guard-refuse "$id" --with-contract)
  read_ports_guard_record "$rec"

  out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a port-contract project with neither port flag must be refused"
  assert_contains "$out" "has a port contract" "refusal did not name the port contract"
  assert_contains "$out" "code/web/.ports.main" "refusal did not name the contract file"
  assert_contains "$out" "--no-ports" "refusal did not name the explicit escape hatch"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not write task metadata"
  [ ! -s "$SEND_LOG" ] || fail "a refused spawn must never send anything to the backend (got: $(cat "$SEND_LOG"))"
  pass "a port-contract project refuses to launch with neither --backend-port nor --frontend-port"
}

# --- 2. contract ABSENT + neither port flag given -> silent pass (the vast
# majority of projects, firstmate's own worktrees included) ------------------

test_no_contract_no_ports_still_passes_silently() {
  local rec id out status
  id=ports-guard-nocontract-z2
  rec=$(make_ports_guard_case ports-guard-nocontract "$id")
  read_ports_guard_record "$rec"
  [ ! -e "$PROJ_DIR/code/web/.ports.main" ] || fail "test setup leaked a contract file for the no-contract case"

  out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a project with no port contract and no port flags must still launch"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_absent "$WT_DIR/code/web/.ports.worktree" "no ports.worktree should exist without a contract or pair"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "a successful spawn must record task metadata"
  assert_no_grep 'backend_port=' "$HOME_DIR/state/$id.meta" \
    "meta must record no port pair when firstmate passed none"
  pass "a project with no port contract file launches with neither port flag exactly as before"
}

# --- 3. contract present + both ports given -> passes, pair written and recorded

test_contract_present_both_ports_given_passes() {
  local rec id out status
  id=ports-guard-both-z3
  rec=$(make_ports_guard_case ports-guard-both "$id" --with-contract)
  read_ports_guard_record "$rec"

  out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off --backend-port 8902 --frontend-port 5402)
  status=$?
  expect_code 0 "$status" "a port-contract project with both ports given must launch"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "BACKEND_PORT=8902" "$WT_DIR/code/web/.ports.worktree" \
    "the given backend port was not written to .ports.worktree"
  assert_grep "FRONTEND_PORT=5402" "$WT_DIR/code/web/.ports.worktree" \
    "the given frontend port was not written to .ports.worktree"
  assert_grep "backend_port=8902" "$HOME_DIR/state/$id.meta" \
    "the decided backend port was not recorded in task metadata"
  assert_grep "frontend_port=5402" "$HOME_DIR/state/$id.meta" \
    "the decided frontend port was not recorded in task metadata"
  pass "a port-contract project launches normally when both --backend-port and --frontend-port are given"
}

# --- 3b. an already-bound pair is refused before anything is created ---------

# The refusal must fire while no window exists and nothing has been sent to the
# backend: a port grabbed between intake and spawn otherwise leaves an orphaned
# pane and a half-made wrangler-state copy behind before the library's own
# validate-and-write refuses.
test_already_bound_pair_refused_before_anything_is_created() {
  local rec id out status listen_port nc_pid
  id=ports-guard-bound-z9
  rec=$(make_ports_guard_case ports-guard-bound "$id" --with-contract)
  read_ports_guard_record "$rec"

  listen_port=41881
  nc -l "$listen_port" >/dev/null 2>&1 &
  nc_pid=$!
  sleep 0.3
  if ! lsof -nP -iTCP:"$listen_port" -sTCP:LISTEN >/dev/null 2>&1; then
    kill "$nc_pid" 2>/dev/null
    wait "$nc_pid" 2>/dev/null
    echo "note: could not confirm the test listener bound $listen_port via lsof; skipping the pre-flight refusal assertion" >&2
    return 0
  fi

  out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off \
    --backend-port "$listen_port" --frontend-port 5404)
  status=$?
  kill "$nc_pid" 2>/dev/null
  wait "$nc_pid" 2>/dev/null

  expect_code 1 "$status" "an already-bound backend-port must be refused"
  assert_contains "$out" "not confirmed free" "refusal did not name the failed liveness check"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused already-bound pair must not write task metadata"
  [ ! -s "$SEND_LOG" ] || fail "an already-bound pair must be refused before anything is sent to the backend (got: $(cat "$SEND_LOG"))"
  pass "an already-bound port pair is refused before any window or copy exists"
}

# --- 4. contract present + --no-ports -> passes, and a stale .ports.worktree
# from a recycled worktree is actively removed, not silently inherited -------

test_no_ports_escape_hatch_passes_and_clears_stale_file() {
  local rec id out status
  id=ports-guard-noflag-z4
  rec=$(make_ports_guard_case ports-guard-noflag "$id" --with-contract)
  read_ports_guard_record "$rec"

  # Simulate a recycled worktree still carrying a stale pair from a prior
  # occupant (gitignored, so a pooled reuse of the same physical directory
  # would otherwise leave it untouched).
  mkdir -p "$WT_DIR/code/web"
  {
    printf 'BACKEND_PORT=8907\n'
    printf 'FRONTEND_PORT=5408\n'
  } > "$WT_DIR/code/web/.ports.worktree"

  out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off --no-ports)
  status=$?
  expect_code 0 "$status" "--no-ports must let a port-contract project launch with neither port flag"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ ! -e "$WT_DIR/code/web/.ports.worktree" ] \
    || fail "--no-ports must actively remove a stale .ports.worktree left by a recycled worktree, not silently inherit it"
  assert_no_grep 'backend_port=' "$HOME_DIR/state/$id.meta" \
    "--no-ports must record no port pair in metadata"
  pass "--no-ports launches a port-contract project and clears a stale .ports.worktree from a recycled worktree"
}

# --- 5. a malformed or one-sided pair is refused at parse time ---------------

test_malformed_or_one_sided_pair_refused_at_parse() {
  local rec id out status
  id=ports-guard-malformed-z5
  rec=$(make_ports_guard_case ports-guard-malformed "$id")
  read_ports_guard_record "$rec"

  out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off --backend-port abc --frontend-port 5402)
  status=$?
  expect_code 1 "$status" "a non-integer backend-port must be refused"
  assert_contains "$out" "positive integer" "refusal did not name the positive-integer requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused malformed pair must not write task metadata"

  out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off --backend-port 8902)
  status=$?
  expect_code 1 "$status" "a one-sided pair must be refused"
  assert_contains "$out" "both be given together" "refusal did not name the both-together rule"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused one-sided pair must not write task metadata"
  pass "malformed and one-sided port pairs refuse the spawn before anything is created"
}

# --- 6. --secondmate refuses the pair ----------------------------------------

test_secondmate_refuses_port_pair() {
  local rec id out status
  id=ports-guard-secondmate-z6
  rec=$(make_ports_guard_case ports-guard-secondmate "$id")
  read_ports_guard_record "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" sm-"$id" "$HOME_DIR" --secondmate --backend-port 8902 --frontend-port 5402 2>&1)
  status=$?
  expect_code 1 "$status" "--secondmate with a port pair must be refused"
  assert_contains "$out" "firstmate home" "refusal did not explain that a secondmate home holds no project ports"
  assert_absent "$HOME_DIR/state/sm-$id.meta" "a refused secondmate spawn must not write task metadata"
  pass "a --secondmate spawn refuses --backend-port/--frontend-port outright"
}

# --- 7. --relaunch refuses all three port flags -------------------------------

test_relaunch_refuses_port_flags() {
  local rec id out status
  id=ports-guard-relaunch-z7
  rec=$(make_ports_guard_case ports-guard-relaunch "$id" --with-contract)
  read_ports_guard_record "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch --backend-port 8902 --frontend-port 5402 2>&1)
  status=$?
  expect_code 1 "$status" "--relaunch with a port pair must be refused"
  assert_contains "$out" "already-provisioned worktree" "refusal did not explain that relaunch adopts the provisioned worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused relaunch must not write task metadata"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch --no-ports 2>&1)
  status=$?
  expect_code 1 "$status" "--relaunch --no-ports must be refused too"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused relaunch must not write task metadata"
  pass "--relaunch refuses --backend-port/--frontend-port/--no-ports instead of re-deciding the runtime"
}

# --- 7b. a flagless relaunch adopts the recorded pair instead of tripping the
# intake guard --------------------------------------------------------------

# Regression: the intake port-contract guard used to fire on --relaunch too,
# but relaunch refuses all three port flags, so a ship/scout task on a port-
# contract project could never be relaunched. A flagless relaunch must get past
# the guard (its runtime was decided at the original intake) and proceed to the
# endpoint checks; here it deterministically stops at the agent-free proof
# because the fake tmux reports the recorded endpoint as missing.
test_flagless_relaunch_adopts_recorded_pair() {
  local rec id first_out out status
  id=ports-guard-relaunch-ok-z10
  rec=$(make_ports_guard_case ports-guard-relaunch-ok "$id" --with-contract)
  read_ports_guard_record "$rec"

  first_out=$(run_ports_guard_spawn "$id" --mode no-mistakes --yolo off \
    --backend-port 8904 --frontend-port 5405)
  expect_code 0 "$?" "the initial spawn carrying the pair must launch"
  assert_contains "$first_out" "spawned $id" "initial spawn did not report success"
  assert_grep "backend_port=8904" "$HOME_DIR/state/$id.meta" \
    "the initial spawn did not record the decided pair in metadata"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  assert_not_contains "$out" "has a port contract" \
    "a flagless relaunch must adopt the task's recorded pair instead of tripping the intake port-contract guard"
  assert_contains "$out" "agent-free" \
    "a flagless relaunch should have proceeded past the port guard to the endpoint checks"
  assert_grep "backend_port=8904" "$HOME_DIR/state/$id.meta" \
    "a refused relaunch must preserve the recorded pair lines verbatim"
  pass "a flagless --relaunch reuses the recorded pair without re-deciding the runtime"
}

# --- 8. batch dispatch forwards the shared pair to each single-task exec -----

test_batch_forwards_shared_pair() {
  local rec id out status
  id=ports-guard-batchpair-z8
  rec=$(make_ports_guard_case ports-guard-batchpair "$id" --with-contract)
  read_ports_guard_record "$rec"
  local batch_id=batch-$id
  mkdir -p "$HOME_DIR/data/$batch_id"
  printf 'brief for %s\n' "$batch_id" > "$HOME_DIR/data/$batch_id/brief.md"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_SENDLOG="$SEND_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$batch_id=$PROJ_DIR" --mode no-mistakes --yolo off \
    --backend-port 8903 --frontend-port 5403 2>&1)
  status=$?
  expect_code 0 "$status" "a batch carrying the shared port pair must launch its contract project"
  assert_grep "BACKEND_PORT=8903" "$WT_DIR/code/web/.ports.worktree" \
    "the batch's shared backend port did not reach the spawned worktree"
  assert_grep "frontend_port=5403" "$HOME_DIR/state/$batch_id.meta" \
    "the batch's shared pair was not recorded in the spawned task's metadata"
  pass "batch dispatch forwards the shared --backend-port/--frontend-port decision to every pair"
}

test_contract_present_no_ports_is_refused
test_no_contract_no_ports_still_passes_silently
test_contract_present_both_ports_given_passes
test_no_ports_escape_hatch_passes_and_clears_stale_file
test_malformed_or_one_sided_pair_refused_at_parse
test_secondmate_refuses_port_pair
test_relaunch_refuses_port_flags
test_already_bound_pair_refused_before_anything_is_created
test_flagless_relaunch_adopts_recorded_pair
test_batch_forwards_shared_pair

echo "# all fm-spawn-ports-guard tests passed"
