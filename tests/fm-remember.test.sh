#!/usr/bin/env bash
# tests/fm-remember.test.sh - guard behavior of bin/fm-remember.sh, the
# best-effort fleet-memory push its callers wire at firstmate's natural capture
# points (captain decisions, resolved worker decisions, scout findings, landed
# ship outcomes, /stow sweeps) (memval-04).
#
# fm-remember.sh is a side-effect that must NEVER block or fail its caller. Its
# write path is now `brain-axi remember`. The cases here drive the REAL script
# over a fake brain-axi and assert the load-bearing fail-open invariant in both
# directions:
#   - brain-axi absent (memory not wired for this home) -> no call, no output, exit 0;
#   - brain-axi present -> the decision text reaches the binary verbatim, with
#     mandatory provenance;
#   - a brain-axi that ERRORS (exit 1) is swallowed -> exit 0;
#   - a slow/hung brain-axi is bounded by FM_REMEMBER_TIMEOUT and still exits 0;
#   - empty text -> no call, exit 0.
# The write path itself (brain-axi) is brain-axi's own test surface and is not
# retested here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REMEMBER="$ROOT/bin/fm-remember.sh"
TMP_ROOT=$(fm_test_tmproot fm-remember-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Build a fakebin whose `brain-axi` records the remembered fact (one per line) to
# <dir>/recorded, so a test can assert what reached the binary. <mode> shapes the
# stub: "record" writes and exits 0; "fail" prints an error JSON and exits 1;
# "hang" never returns.
make_fake_brain() {  # <dir> <mode>
  local dir=$1 mode=$2 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  case "$mode" in
    record)
      cat > "$fakebin/brain-axi" <<SH
#!/usr/bin/env bash
# args: remember <fact> --provenance <p> --store <s> --by <b>
[ "\${1:-}" = remember ] || exit 0
printf '%s\n' "\${2:-}" >> "$dir/recorded"
printf '%s\n' "\$*" >> "$dir/recorded_args"
exit 0
SH
      ;;
    fail)
      cat > "$fakebin/brain-axi" <<'SH'
#!/usr/bin/env bash
echo '{"protocol_version":1,"error":"internal","message":"boom","suggestion":"x"}'
exit 1
SH
      ;;
    hang)
      cat > "$fakebin/brain-axi" <<'SH'
#!/usr/bin/env bash
sleep 3600
SH
      ;;
  esac
  chmod +x "$fakebin/brain-axi"
  printf '%s\n' "$fakebin"
}

test_absent_binary_does_nothing() {
  local out rc
  # A PATH with coreutils but NO brain-axi: the wrapper returns before it sources
  # anything, so it must be a pure exit-0 no-op.
  out=$(PATH="$BASE_PATH" BRAIN_STORE="$TMP_ROOT/store" "$REMEMBER" "chose X over Y because Z" 2>&1); rc=$?
  expect_code 0 "$rc" "absent brain-axi must exit 0"
  [ -z "$out" ] || fail "absent brain-axi must emit nothing, got: $out"
  pass "absent brain-axi: no call, no output, exit 0"
}

test_present_binary_receives_text() {
  local dir fakebin out rc
  dir="$TMP_ROOT/wired"; mkdir -p "$dir"
  fakebin=$(make_fake_brain "$dir" record)
  out=$(PATH="$fakebin:$BASE_PATH" BRAIN_STORE="$dir/store" "$REMEMBER" \
    "chose SQLite over Postgres for the seed" 2>&1); rc=$?
  expect_code 0 "$rc" "present brain-axi call must exit 0"
  [ -z "$out" ] || fail "present brain-axi must not print to the caller, got: $out"
  assert_present "$dir/recorded" "wired brain-axi should have recorded the decision"
  assert_grep "chose SQLite over Postgres for the seed" "$dir/recorded" \
    "the decision text must reach brain-axi verbatim"
  assert_grep "--by fm-remember" "$dir/recorded_args" \
    "the default --by fm-remember attribution must reach brain-axi"
  pass "wired brain-axi receives the decision text verbatim"
}

test_failing_binary_is_swallowed() {
  local dir fakebin out rc
  dir="$TMP_ROOT/failing"; mkdir -p "$dir"
  fakebin=$(make_fake_brain "$dir" fail)
  out=$(PATH="$fakebin:$BASE_PATH" BRAIN_STORE="$dir/store" "$REMEMBER" \
    "a decision brain-axi rejects" 2>&1); rc=$?
  expect_code 0 "$rc" "a brain-axi that exits 1 must still exit 0 (fail open)"
  [ -z "$out" ] || fail "a failing brain-axi must not leak output, got: $out"
  pass "failing brain-axi (exit 1) is swallowed and still exits 0"
}

test_slow_binary_is_bounded() {
  local dir fakebin rc start end elapsed
  dir="$TMP_ROOT/slow"; mkdir -p "$dir"
  fakebin=$(make_fake_brain "$dir" hang)
  start=$(date +%s)
  PATH="$fakebin:$BASE_PATH" BRAIN_STORE="$dir/store" FM_REMEMBER_TIMEOUT=1 \
    "$REMEMBER" "a decision the store cannot ack" >/dev/null 2>&1
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$rc" "a hung brain-axi must still exit 0 (fail open)"
  [ "$elapsed" -lt 8 ] \
    || fail "a hung brain-axi must be bounded by the timeout, took ${elapsed}s"
  pass "slow/hung brain-axi is bounded and still exits 0"
}

test_empty_text_is_a_noop() {
  local dir fakebin out rc
  dir="$TMP_ROOT/empty"; mkdir -p "$dir"
  fakebin=$(make_fake_brain "$dir" record)
  out=$(PATH="$fakebin:$BASE_PATH" BRAIN_STORE="$dir/store" "$REMEMBER" "" 2>&1); rc=$?
  expect_code 0 "$rc" "empty text must exit 0"
  [ -z "$out" ] || fail "empty text must emit nothing, got: $out"
  assert_absent "$dir/recorded" "empty text must not invoke brain-axi"
  pass "empty decision text: no call, exit 0"
}

# Regression for the leak this suite once caused: a remember whose caller did NOT
# pin its own $BRAIN_STORE must land in the harness sandbox (lib.sh default),
# never $HOME/.brain - the captain-private real fleet store (memval-04). HOME is
# redirected so a leak would be an observable, harmless fixture write here rather
# than a silent append to the real store.
test_unpinned_store_never_hits_home() {
  local dir fakebin fakehome rc
  dir="$TMP_ROOT/unpinned"; mkdir -p "$dir"
  fakehome="$dir/home"; mkdir -p "$fakehome/.brain"
  # A brain-axi that honors --store and appends the fact to <store>/facts.md, so
  # we can see exactly which store the wrapper resolved.
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/brain-axi" <<'SH'
#!/usr/bin/env bash
store=
while [ $# -gt 0 ]; do
  case "$1" in --store) store=$2; shift 2 ;; *) shift ;; esac
done
[ -n "$store" ] || exit 0
mkdir -p "$store"
printf 'fact\n' >> "$store/facts.md"
exit 0
SH
  chmod +x "$fakebin/brain-axi"
  # BRAIN_STORE is intentionally NOT set: the lib.sh sandbox default must govern.
  HOME="$fakehome" PATH="$fakebin:$BASE_PATH" "$REMEMBER" "an unpinned decision"; rc=$?
  expect_code 0 "$rc" "unpinned remember must still exit 0"
  assert_absent "$fakehome/.brain/facts.md" \
    "an unpinned remember must never write \$HOME/.brain (the real fleet store)"
  [ -n "${BRAIN_STORE:-}" ] || fail "lib.sh must export a sandbox \$BRAIN_STORE for tests"
  assert_present "$BRAIN_STORE/facts.md" \
    "the unpinned remember must land in the harness sandbox store"
  pass "unpinned remember lands in the sandbox, never \$HOME/.brain"
}

test_present_binary_honors_brain_by() {
  local dir fakebin out rc
  dir="$TMP_ROOT/wired-by"; mkdir -p "$dir"
  fakebin=$(make_fake_brain "$dir" record)
  out=$(BRAIN_BY="task-456" PATH="$fakebin:$BASE_PATH" BRAIN_STORE="$dir/store" "$REMEMBER" \
    "decision with custom attribution" 2>&1); rc=$?
  expect_code 0 "$rc" "present brain-axi call must exit 0"
  assert_grep "--by task-456" "$dir/recorded_args" \
    "an explicit \$BRAIN_BY must reach brain-axi via --by"
  pass "wired brain-axi honors \$BRAIN_BY attribution"
}

test_absent_binary_does_nothing
test_present_binary_receives_text
test_failing_binary_is_swallowed
test_slow_binary_is_bounded
test_empty_text_is_a_noop
test_unpinned_store_never_hits_home
test_present_binary_honors_brain_by
