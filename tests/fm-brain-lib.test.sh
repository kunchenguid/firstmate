#!/usr/bin/env bash
# tests/fm-brain-lib.test.sh - guard bin/fm-brain-lib.sh, the single owner of the
# home's brain-axi store path and of the availability gate every caller uses.
#
# brain-axi is an OPTIONAL, one-directional dependency: firstmate -> the binary.
# The lib exists so every caller fails open the same way. These cases assert:
#   - fm_brain_store honors $BRAIN_STORE and falls back to ~/.brain;
#   - fm_brain_available succeeds ONLY when the binary is on PATH AND the store
#     directory already exists (it must never materialize a store as a side
#     effect of a read path).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-brain-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-brain-lib-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Run one sourced-lib expression under a controlled PATH/env and print its
# stdout; returns the expression's exit status.
run_lib() {  # <path> <expr...>
  local path=$1; shift
  PATH="$path" bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}

fake_brain_on() {  # <dir> -> prints a PATH with brain-axi first
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/brain-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/brain-axi"
  printf '%s\n' "$fakebin:$BASE_PATH"
}

test_store_honors_override() {
  local out
  out=$(BRAIN_STORE="/tmp/custom-brain" run_lib "$BASE_PATH" fm_brain_store)
  [ "$out" = "/tmp/custom-brain" ] || fail "fm_brain_store must honor \$BRAIN_STORE, got: $out"
  pass "fm_brain_store honors \$BRAIN_STORE"
}

test_store_defaults_to_home() {
  local out
  out=$(HOME="/home/skipper" BRAIN_STORE="" run_lib "$BASE_PATH" fm_brain_store)
  [ "$out" = "/home/skipper/.brain" ] || fail "fm_brain_store must default to ~/.brain, got: $out"
  pass "fm_brain_store defaults to \$HOME/.brain"
}

test_available_false_when_binary_absent() {
  local store="$TMP_ROOT/present-store"; mkdir -p "$store"
  # store dir EXISTS, but PATH has no brain-axi -> unavailable.
  if BRAIN_STORE="$store" run_lib "$BASE_PATH" fm_brain_available; then
    fail "fm_brain_available must fail when brain-axi is not on PATH"
  fi
  pass "fm_brain_available is false when the binary is absent"
}

test_available_false_when_store_missing() {
  local dir="$TMP_ROOT/nostore" path
  path=$(fake_brain_on "$dir")
  # binary present, but the store dir does NOT exist -> unavailable (never create).
  if BRAIN_STORE="$dir/does-not-exist" run_lib "$path" fm_brain_available; then
    fail "fm_brain_available must fail when the store directory is missing"
  fi
  assert_absent "$dir/does-not-exist" "fm_brain_available must not create the store"
  pass "fm_brain_available is false (and creates nothing) when the store is missing"
}

test_available_true_when_binary_and_store_present() {
  local dir="$TMP_ROOT/ready" store path
  store="$dir/store"; mkdir -p "$store"
  path=$(fake_brain_on "$dir")
  if ! BRAIN_STORE="$store" run_lib "$path" fm_brain_available; then
    fail "fm_brain_available must succeed with binary on PATH and store present"
  fi
  pass "fm_brain_available is true when both the binary and the store are present"
}

test_store_honors_override
test_store_defaults_to_home
test_available_false_when_binary_absent
test_available_false_when_store_missing
test_available_true_when_binary_and_store_present
