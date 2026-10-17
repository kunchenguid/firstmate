#!/usr/bin/env bash
# Behavior tests for the bin/fm-flow.sh shim: it execs the
# firstmate-addons fleet-flow reader with FM_BIN pointing at this
# fork's bin/, and fails clearly when the add-ons checkout is absent.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/fm-flow.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-shim)

# A fake add-on checkout records the args it received and the FM_BIN it saw.
make_fake_addons() {  # <name>; prints the fake FM_ADDONS_DIR
  local dir="$TMP_ROOT/$1" target="$TMP_ROOT/$1/fleet-flow/bin/fm-flow.sh"
  mkdir -p "$TMP_ROOT/$1/fleet-flow/bin"
  cat > "$target" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_BIN" > "$FAKE_OUT/fmbin"
printf '%s\n' "$@" > "$FAKE_OUT/args"
SH
  chmod +x "$target"
  printf '%s\n' "$dir"
}

# The fake add-on receives the shim's args and FM_BIN naming this fork's bin/.
addons=$(make_fake_addons present)
mkdir -p "$TMP_ROOT/out-present"
FAKE_OUT="$TMP_ROOT/out-present" FM_ADDONS_DIR="$addons" "$SHIM" --json --now 100 --capacity >"$TMP_ROOT/out-present/stdout" 2>"$TMP_ROOT/out-present/stderr"
[ -f "$TMP_ROOT/out-present/args" ] || fail "fake add-on never ran"
[ "$(cat "$TMP_ROOT/out-present/args")" = "--json
--now
100
--capacity" ] || fail "fake add-on got wrong args: $(cat "$TMP_ROOT/out-present/args")"
[ "$(cat "$TMP_ROOT/out-present/fmbin")" = "$ROOT/bin" ] || fail "FM_BIN was '$(cat "$TMP_ROOT/out-present/fmbin")', want '$ROOT/bin'"

# A missing add-ons checkout exits 1 and names FM_ADDONS_DIR on stderr.
mkdir -p "$TMP_ROOT/out-missing"
status=0
FM_ADDONS_DIR="$TMP_ROOT/nowhere" "$SHIM" --json >"$TMP_ROOT/out-missing/stdout" 2>"$TMP_ROOT/out-missing/stderr" || status=$?
[ "$status" -eq 0 ] && fail "shim succeeded with no add-ons checkout"
[ "$status" -eq 1 ] || fail "shim exit was $status, want 1"
grep -q "FM_ADDONS_DIR" "$TMP_ROOT/out-missing/stderr" || fail "missing-checkout stderr never names FM_ADDONS_DIR: $(cat "$TMP_ROOT/out-missing/stderr")"

# With FM_ADDONS_DIR unset, the shim defaults to $FM_HOME/projects/firstmate-addons.
mkdir -p "$TMP_ROOT/fakehome/projects/firstmate-addons/fleet-flow/bin"
cp "$addons/fleet-flow/bin/fm-flow.sh" "$TMP_ROOT/fakehome/projects/firstmate-addons/fleet-flow/bin/fm-flow.sh"
mkdir -p "$TMP_ROOT/out-default"
env -u FM_ADDONS_DIR FAKE_OUT="$TMP_ROOT/out-default" FM_HOME="$TMP_ROOT/fakehome" "$SHIM" --json >"$TMP_ROOT/out-default/stdout" 2>"$TMP_ROOT/out-default/stderr"
[ "$(cat "$TMP_ROOT/out-default/args")" = "--json" ] || fail "default-dir add-on got wrong args: $(cat "$TMP_ROOT/out-default/args")"
[ "$(cat "$TMP_ROOT/out-default/fmbin")" = "$ROOT/bin" ] || fail "default-dir FM_BIN was '$(cat "$TMP_ROOT/out-default/fmbin")', want '$ROOT/bin'"

pass "fm-flow shim delegates with FM_BIN and fails clearly without add-ons"
