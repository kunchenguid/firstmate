#!/usr/bin/env bash
# Behavior tests for fm-spawn's pre-launch gate chain (bin/fm-spawn-gate-lib.sh).
#
# WHY these exist: every rollback of 24.-25.08. had the rule in place and no
# READER at the point of action. fm-spawn read only state/.fleet-stop, so a
# pinned captain order, a live reservation, an open captain remark, and a ship
# brief with no acceptance block all passed unseen. These tests pin the reader:
# each gate must actually STOP a spawn, name its source, and print the way out -
# and each must stay silent while its arming flag is absent, because "built but
# standing down" is a real, wanted state during the transition.
#
# The spawn never reaches a real harness: a fake tmux captures the launch command
# instead, so a green case proves the launch was constructed, not that an agent ran.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-konten-fixture-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-konten-fixture-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-order-gate)
export FM_BACKEND=tmux

make_gate_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          [ "$a" = "--" ] && continue
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# make_gate_case <name> <task-id> -> a fixture home with one spawnable ship task
# and NO gate armed. Each test arms exactly the one gate it is about, so a
# refusal can only have come from that gate.
make_gate_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_gate_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_konten_fixture "$home" "$case_dir/konten" "$proj" "$wt" "$home"
  touch "$home/state/.last-watcher-beat"
  # A ship brief with the delivery contract the spawn is launched with, and a
  # bold title, which is what the remark gate matches a subject against.
  {
    printf 'Delivery contract: mode=no-mistakes\n\n'
    printf '## Task\n**%s**\n\nDo the thing.\n' "gate probe $id"
  } > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_gate_case() {
  # shellcheck disable=SC2034 # CASE_DIR keeps this record the same shape as the
  # other spawn fixtures' one; no gate test happens to need it yet.
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# A refused spawn must stop BEFORE the launch is constructed; the fake tmux log
# staying empty is the only direct evidence of that.
assert_no_launch() {
  local logged
  logged=$(cat "$1")
  [ -z "$logged" ] || fail "a blocked spawn still built a launch command: $logged"
}

run_gate_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # FM_KONTEN_AKTE is pinned into the fixture so a fixture without a ledger can
  # never fall back to the checkout's real config/konten.tsv and read the
  # operator's actual accounts.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_KONTEN_AKTE="$home/config/konten.tsv" \
    CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

# write_order <home> <order-id> <wording> <enforce-tail>
write_order() {
  local home=$1 oid=$2 wording=$3 enforce=$4 dir
  dir="$home/data/entscheide/2026-08-25"
  mkdir -p "$dir"
  # The gate reads only order-O-*.md exactly two levels under data/entscheide,
  # takes the header block before the first blank line, and quotes the first
  # non-empty line under "## wording".
  {
    printf 'id: %s\n' "$oid"
    printf 'type: order\n'
    printf 'status: active\n'
    printf 'source: captain\n'
    printf 'expires: -\n'
    printf 'enforce: %s\n' "$enforce"
    printf '\n## wording (verbatim, original language)\n%s\n' "$wording"
  } > "$dir/order-$oid.md"
}

test_forbidding_order_stops_the_spawn() {
  local rec id out status
  id=gate-order-z1
  rec=$(make_gate_case gate-order "$id")
  read_gate_case "$rec"
  write_order "$HOME_DIR" O-0083 \
    'keine Spawns mehr in diesem Projekt bis zum Wiederanlauf' \
    "spawn project=$(basename "$PROJ_DIR")"
  touch "$HOME_DIR/state/.tor-order-scharf"

  out=$(run_gate_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a standing captain order must stop the spawn"
  assert_contains "$out" "O-0083" "refusal does not name the blocking order id"
  assert_contains "$out" "keine Spawns mehr in diesem Projekt" \
    "refusal does not quote the captain's own wording, only a paraphrase"
  assert_contains "$out" "close O-0083" "refusal does not state the way out"
  assert_no_launch "$LAUNCH_LOG"
  pass "a forbidding captain order stops the spawn, quoted with its id and its way out"
}

test_live_reservation_stops_the_spawn() {
  local rec id out status
  id=gate-reservierung-z2
  rec=$(make_gate_case gate-reservierung "$id")
  read_gate_case "$rec"
  mkdir -p "$HOME_DIR/state/reservierungen"
  {
    printf 'holder: sm-lensclash\n'
    printf 'purpose: Umbau der Flottenordnung, keine fremden Spawns\n'
    printf 'expiry: 2099-12-31\n'
    printf 'blocks: spawn project=%s\n' "$(basename "$PROJ_DIR")"
  } > "$HOME_DIR/state/reservierungen/umbau.md"
  touch "$HOME_DIR/state/.tor-reservierung-scharf"

  out=$(run_gate_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a live reservation must stop the spawn"
  assert_contains "$out" "SPAWN-TOR ROT (reservierung)" "refusal does not name the reservation gate"
  assert_contains "$out" "sm-lensclash" "refusal does not name who holds the ground"
  assert_contains "$out" "keine fremden Spawns" "refusal does not print the reservation's purpose"
  assert_no_launch "$LAUNCH_LOG"
  pass "a live reservation stops the spawn and names its holder and purpose"
}

test_open_remark_on_the_task_stops_the_spawn() {
  local rec id out status
  id=gate-bemerkung-z3
  rec=$(make_gate_case gate-bemerkung "$id")
  read_gate_case "$rec"
  mkdir -p "$HOME_DIR/state/brett-bemerkungen"
  {
    printf 'schema: fm-brett-bemerkung.v1\n'
    printf 'task: %s\n' "$id"
    printf 'subject: gate probe\n'
    printf 'bemerkung: erst die Abnahme klaeren, dann starten\n'
  } > "$HOME_DIR/state/brett-bemerkungen/A-0007.md"
  touch "$HOME_DIR/state/.tor-bemerkung-scharf"

  out=$(run_gate_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "an open captain remark on this task must stop the spawn"
  assert_contains "$out" "erst die Abnahme klaeren, dann starten" \
    "refusal does not print the remark text the captain actually wrote"
  assert_contains "$out" "A-0007" "refusal does not name the remark marker"
  assert_no_launch "$LAUNCH_LOG"
  pass "an open captain remark matching the task stops the spawn and prints its text"
}

test_ship_brief_without_acceptance_block_stops_the_spawn() {
  local rec id out status
  id=gate-abnahme-z4
  rec=$(make_gate_case gate-abnahme "$id")
  read_gate_case "$rec"
  # The brief make_gate_case wrote carries no "## Abnahme (maschinenlesbar)" block.
  touch "$HOME_DIR/state/.tor-abnahme-scharf"

  out=$(run_gate_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a ship brief with no acceptance block must stop the spawn"
  assert_contains "$out" "SPAWN-TOR ROT (abnahme)" "refusal does not name the acceptance gate"
  assert_contains "$out" "Abnahme" "refusal does not state which block the brief is missing"
  assert_no_launch "$LAUNCH_LOG"
  pass "a ship brief without a machine-readable acceptance block stops the spawn"
}

# The transition state, and the one that matters most day to day: the gates are
# BUILT but not armed, so they must let the spawn through in total silence.
test_unarmed_gates_let_the_spawn_through() {
  local rec id out status launch
  id=gate-frei-z5
  rec=$(make_gate_case gate-frei "$id")
  read_gate_case "$rec"
  # Every blocking condition of the tests above is present at once - only the
  # arming flags are absent. Nothing here may stop the spawn.
  write_order "$HOME_DIR" O-0083 'keine Spawns mehr' "spawn project=$(basename "$PROJ_DIR")"
  mkdir -p "$HOME_DIR/state/reservierungen"
  {
    printf 'holder: sm-lensclash\n'
    printf 'purpose: Umbau\n'
    printf 'expiry: 2099-12-31\n'
    printf 'blocks: spawn project=%s\n' "$(basename "$PROJ_DIR")"
  } > "$HOME_DIR/state/reservierungen/umbau.md"

  out=$(run_gate_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "with no gate armed the spawn must go through"
  assert_contains "$out" "spawned $id" "spawn did not report a launch"
  assert_not_contains "$out" "SPAWN-TOR ROT" "an unarmed gate still refused"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude" "no claude launch command was built"
  pass "unarmed gates stay silent and let the spawn through"
}

test_forbidding_order_stops_the_spawn
test_live_reservation_stops_the_spawn
test_open_remark_on_the_task_stops_the_spawn
test_ship_brief_without_acceptance_block_stops_the_spawn
test_unarmed_gates_let_the_spawn_through
echo "# all fm-spawn-order-gate tests passed"
