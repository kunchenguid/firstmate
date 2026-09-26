#!/usr/bin/env bash
# Behavioral checks for bin/fm-omp-calm-install.sh against a sandboxed HOME:
# the link lands in OMP's user plugin scope, re-running is idempotent, and a
# legacy project-local copy is retired without double-loading.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OMP_CALM_INSTALL_TEST omp
JQ_BIN=$(command -v jq) || fail "these tests assert omp registration with the real jq, which was not found"

TMP_ROOT=$(fm_test_tmproot fm-omp-calm-install)
trap 'fm_test_cleanup' EXIT

FAKE_HOME="$TMP_ROOT/home"
FAKE_FM_HOME="$TMP_ROOT/fm-home"
mkdir -p "$FAKE_HOME" "$FAKE_FM_HOME/.omp/extensions"

run_install() {
  HOME="$FAKE_HOME" FM_HOME="$FAKE_FM_HOME" "$ROOT/bin/fm-omp-calm-install.sh"
}

# Fresh install links the package into the sandboxed user plugin scope.
run_install >"$TMP_ROOT/install.out" 2>"$TMP_ROOT/install.err" \
  || fail "install failed: $(cat "$TMP_ROOT/install.err")"
LINK="$FAKE_HOME/.omp/plugins/node_modules/fm-calm-omp"
STANDALONE="$FAKE_HOME/.local/share/fm-calm-omp"
[ -L "$LINK" ] || fail "plugin link is not a symlink at $LINK"
assert_equals "$STANDALONE" "$(readlink "$LINK")" "link target"
[ -f "$STANDALONE/lib/fm-calm-working-ship.ts" ] || fail "standalone lib missing"
assert_absent "$STANDALONE/../../.pi" "standalone copy is not nested under firstmate .pi"
"$JQ_BIN" -e '.plugins["fm-calm-omp"] != null and .plugins["fm-calm-omp"].enabled == true' \
  "$FAKE_HOME/.omp/plugins/omp-plugins.lock.json" >/dev/null \
  || fail "lockfile did not register fm-calm-omp as an enabled plugin"
pass "install links package into user plugin scope"

# Re-running over an existing link is idempotent.
mkdir -p "$STANDALONE/unrelated"
printf 'preserve me\n' >"$STANDALONE/unrelated/data"
printf 'outdated\n' >"$STANDALONE/fm-calm-omp.ts"
run_install >"$TMP_ROOT/reinstall.out" 2>"$TMP_ROOT/reinstall.err" \
  || fail "reinstall failed: $(cat "$TMP_ROOT/reinstall.err")"
[ -L "$LINK" ] || fail "link missing after reinstall"
assert_equals "preserve me" "$(cat "$STANDALONE/unrelated/data")" "unrelated destination data preserved"
cmp -s "$ROOT/extensions/fm-calm-omp/fm-calm-omp.ts" "$STANDALONE/fm-calm-omp.ts" \
  || fail "plugin source was not refreshed"
pass "reinstall is idempotent"

# An identical legacy project-local copy is removed so it cannot double-load.
cp "$ROOT/extensions/fm-calm-omp/fm-calm-omp.ts" "$FAKE_FM_HOME/.omp/extensions/fm-calm-omp.ts"
run_install >"$TMP_ROOT/legacy.out" 2>"$TMP_ROOT/legacy.err" \
  || fail "install with legacy copy failed: $(cat "$TMP_ROOT/legacy.err")"
assert_absent "$FAKE_FM_HOME/.omp/extensions/fm-calm-omp.ts" "identical legacy copy removed"
assert_absent "$FAKE_FM_HOME/.omp/extensions/fm-calm-omp.ts.bak" "no backup for identical copy"
pass "identical legacy copy removed"

# A divergent legacy copy is preserved aside, never silently discarded.
printf '// divergent local edit\n' >"$FAKE_FM_HOME/.omp/extensions/fm-calm-omp.ts"
run_install >"$TMP_ROOT/divergent.out" 2>"$TMP_ROOT/divergent.err" \
  || fail "install with divergent copy failed: $(cat "$TMP_ROOT/divergent.err")"
assert_absent "$FAKE_FM_HOME/.omp/extensions/fm-calm-omp.ts" "divergent legacy copy moved"
assert_equals "// divergent local edit" "$(cat "$FAKE_FM_HOME/.omp/extensions/fm-calm-omp.ts.bak")" "divergent copy preserved"
pass "divergent legacy copy preserved as .bak"

# An earlier preserved copy is never overwritten by a later divergent one: the
# install aborts before linking and leaves both files for a human to resolve.
BAK_HOME="$TMP_ROOT/bak-home"
BAK_FM_HOME="$TMP_ROOT/bak-fm-home"
mkdir -p "$BAK_HOME" "$BAK_FM_HOME/.omp/extensions"
printf '// earlier divergent edit\n' >"$BAK_FM_HOME/.omp/extensions/fm-calm-omp.ts.bak"
printf '// later divergent edit\n' >"$BAK_FM_HOME/.omp/extensions/fm-calm-omp.ts"
HOME="$BAK_HOME" FM_HOME="$BAK_FM_HOME" \
  "$ROOT/bin/fm-omp-calm-install.sh" >"$TMP_ROOT/bak.out" 2>"$TMP_ROOT/bak.err" \
  && fail "install succeeded despite an existing .bak"
assert_equals "// earlier divergent edit" \
  "$(cat "$BAK_FM_HOME/.omp/extensions/fm-calm-omp.ts.bak")" "existing .bak preserved"
assert_present "$BAK_FM_HOME/.omp/extensions/fm-calm-omp.ts" \
  "later divergent copy left in place beside the .bak"
assert_grep ".bak already exists" "$TMP_ROOT/bak.err" "existing .bak reported"
assert_absent "$BAK_HOME/.omp/plugins/node_modules/fm-calm-omp" \
  "no link while an existing .bak blocks legacy retirement"
pass "an existing .bak is never overwritten"

# A retirement step that cannot complete aborts the install before linking,
# instead of reporting success and leaving the legacy copy to double-load with
# the linked package in home sessions.
RETIRE_HOME="$TMP_ROOT/retire-home"
RETIRE_FM_HOME="$TMP_ROOT/retire-fm-home"
mkdir -p "$RETIRE_HOME" "$RETIRE_FM_HOME/.omp/extensions"
printf '// divergent local edit\n' >"$RETIRE_FM_HOME/.omp/extensions/fm-calm-omp.ts"
chmod 555 "$RETIRE_FM_HOME/.omp/extensions"
HOME="$RETIRE_HOME" FM_HOME="$RETIRE_FM_HOME" \
  "$ROOT/bin/fm-omp-calm-install.sh" >"$TMP_ROOT/retire.out" 2>"$TMP_ROOT/retire.err" \
  && fail "install succeeded despite failed legacy retirement"
assert_present "$RETIRE_FM_HOME/.omp/extensions/fm-calm-omp.ts" "legacy copy left in place by failed move"
assert_grep "error: failed to move" "$TMP_ROOT/retire.err" "retirement failure reported"
assert_absent "$RETIRE_HOME/.omp/plugins/node_modules/fm-calm-omp" "no link after failed retirement"
chmod 755 "$RETIRE_FM_HOME/.omp/extensions"
pass "failed legacy retirement aborts before linking"

# Same abort for the identical-copy removal branch.
cp "$ROOT/extensions/fm-calm-omp/fm-calm-omp.ts" "$RETIRE_FM_HOME/.omp/extensions/fm-calm-omp.ts"
chmod 555 "$RETIRE_FM_HOME/.omp/extensions"
HOME="$RETIRE_HOME" FM_HOME="$RETIRE_FM_HOME" \
  "$ROOT/bin/fm-omp-calm-install.sh" >"$TMP_ROOT/rm-fail.out" 2>"$TMP_ROOT/rm-fail.err" \
  && fail "install succeeded despite failed legacy removal"
assert_present "$RETIRE_FM_HOME/.omp/extensions/fm-calm-omp.ts" "identical legacy copy left by failed removal"
assert_grep "error: failed to remove" "$TMP_ROOT/rm-fail.err" "removal failure reported"
assert_absent "$RETIRE_HOME/.omp/plugins/node_modules/fm-calm-omp" "no link after failed removal"
chmod 755 "$RETIRE_FM_HOME/.omp/extensions"
pass "failed legacy removal aborts before linking"

# omp's own discovery reads the linked package: the registered plugin is the
# one every omp session loads, enabled, with the tracked extension entry.
DISCOVERED=$(HOME="$FAKE_HOME" omp plugin list --json) \
  || fail "omp plugin list failed after install"
ENTRY=$(printf '%s' "$DISCOVERED" | "$JQ_BIN" -c '.npm[]? | select(.name == "fm-calm-omp")')
[ -n "$ENTRY" ] || fail "omp did not discover the linked fm-calm-omp plugin"
printf '%s' "$ENTRY" | "$JQ_BIN" -e \
  '.enabled == true and (.manifest.extensions == ["./fm-calm-omp.ts"])' >/dev/null \
  || fail "discovered plugin is not enabled with the tracked extension entry: $ENTRY"
assert_equals "$LINK" "$(printf '%s' "$ENTRY" | "$JQ_BIN" -r '.path')" "discovered plugin path"
assert_present "$(printf '%s' "$ENTRY" | "$JQ_BIN" -r '.path')/fm-calm-omp.ts" \
  "declared extension entry resolves"
pass "omp discovers the linked package with the tracked extension entry"
