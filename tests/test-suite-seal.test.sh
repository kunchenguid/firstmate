#!/usr/bin/env bash
# Regression coverage for every behavior-suite admission door.
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-suite-seal)
FIXTURE_ONE=
FIXTURE_TWO=

cleanup() {
  [ -z "$FIXTURE_ONE" ] || kill "$FIXTURE_ONE" 2>/dev/null || true
  [ -z "$FIXTURE_TWO" ] || kill "$FIXTURE_TWO" 2>/dev/null || true
  [ -z "$FIXTURE_ONE" ] || wait "$FIXTURE_ONE" 2>/dev/null || true
  [ -z "$FIXTURE_TWO" ] || wait "$FIXTURE_TWO" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

sleep 60 &
FIXTURE_ONE=$!
sleep 60 &
FIXTURE_TWO=$!

rogue=$TMP_ROOT/rogue.test.sh
printf '%s\n' '#!/usr/bin/env bash' "kill $FIXTURE_ONE $FIXTURE_TWO" > "$rogue"
chmod +x "$rogue"
status=0
"$ROOT/tests/run.sh" "$rogue" >"$TMP_ROOT/rogue.out" 2>"$TMP_ROOT/rogue.err" || status=$?
expect_code 97 "$status" "unregistered lifecycle test admission"
kill -0 "$FIXTURE_ONE" 2>/dev/null || fail "admission refusal touched the first live fixture"
kill -0 "$FIXTURE_TWO" 2>/dev/null || fail "admission refusal touched the second live fixture"
assert_contains "$(cat "$TMP_ROOT/rogue.err")" "outside the registered suite" \
  "unregistered test refusal did not name the closed route"
pass "unregistered test admission refuses before touching live process fixtures"

raw=$TMP_ROOT/raw-lifecycle.sh
printf '%s\n' '#!/usr/bin/env bash' 'herdr server stop' > "$raw"
status=0
python3 "$ROOT/tests/test-seal.py" scan-file "$raw" >"$TMP_ROOT/raw.out" 2>"$TMP_ROOT/raw.err" || status=$?
expect_code 97 "$status" "raw lifecycle static admission"
assert_contains "$(cat "$TMP_ROOT/raw.err")" "raw Herdr server/session lifecycle" \
  "static refusal did not identify raw Herdr lifecycle"
kill -0 "$FIXTURE_ONE" 2>/dev/null || fail "static refusal touched the first live fixture"
kill -0 "$FIXTURE_TWO" 2>/dev/null || fail "static refusal touched the second live fixture"
pass "static admission refuses raw Herdr lifecycle before live fixtures can be touched"

probe_token=$FM_TEST_SUITE_ROOT/runtime-probe.json
probe_test=$ROOT/tests/fm-backend-herdr-smoke.test.sh
python3 - "$probe_token" "$FM_TEST_RUNNER_PID" "$probe_test" <<'PY'
import json
from pathlib import Path
import sys

path, runner_pid, test = sys.argv[1:]
Path(path).write_text(json.dumps({
    "runner_pid": int(runner_pid),
    "test": test,
    "capability": "herdr-lab",
}) + "\n", encoding="utf-8")
PY
chmod 600 "$probe_token"
status=0
lifecycle_server=server
lifecycle_stop=stop
FM_TEST_RUNNER_TOKEN="$probe_token" \
FM_TEST_CURRENT_TEST="$probe_test" \
FM_TEST_HERDR_CAPABILITY=herdr-lab \
FM_TEST_HERDR_LAB_SESSION=fm-lab-runtime-refusal \
HERDR_SESSION=fm-lab-runtime-refusal \
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh" \
FM_TEST_REAL_HERDR=/usr/bin/true \
FM_TEST_ORIGINAL_PATH=/usr/bin:/bin \
  "$ROOT/tests/herdr-guard-bin/herdr" "$lifecycle_server" "$lifecycle_stop" \
    >"$TMP_ROOT/runtime.out" 2>"$TMP_ROOT/runtime.err" || status=$?
expect_code 97 "$status" "raw lifecycle runtime admission"
assert_contains "$(cat "$TMP_ROOT/runtime.err")" "raw Herdr server/session lifecycle" \
  "runtime refusal did not identify raw Herdr lifecycle"
kill -0 "$FIXTURE_ONE" 2>/dev/null || fail "runtime refusal touched the first live fixture"
kill -0 "$FIXTURE_TWO" 2>/dev/null || fail "runtime refusal touched the second live fixture"
pass "runtime Herdr proxy refuses raw lifecycle before live fixtures can be touched"

hermetic_test=$ROOT/tests/runner-entry-probe.test.sh
python3 - "$probe_token" "$FM_TEST_RUNNER_PID" "$hermetic_test" <<'PY'
import json
from pathlib import Path
import sys

path, runner_pid, test = sys.argv[1:]
Path(path).write_text(json.dumps({
    "runner_pid": int(runner_pid),
    "test": test,
    "capability": "hermetic",
}) + "\n", encoding="utf-8")
PY
status=0
FM_TEST_RUNNER_TOKEN="$probe_token" \
FM_TEST_CURRENT_TEST="$hermetic_test" \
FM_TEST_HERDR_CAPABILITY=hermetic \
  "$ROOT/tests/herdr-guard-bin/herdr" status --json \
    >"$TMP_ROOT/hermetic-herdr.out" 2>"$TMP_ROOT/hermetic-herdr.err" || status=$?
expect_code 97 "$status" "hermetic real-Herdr negative control"
assert_contains "$(cat "$TMP_ROOT/hermetic-herdr.err")" "hermetic test attempted real Herdr" \
  "hermetic runtime refusal did not identify the capability violation"
pass "hermetic admission cannot execute any real Herdr command"

no_herdr_bin=$TMP_ROOT/no-herdr-bin
mkdir -p "$no_herdr_bin"
for command_name in basename chmod dirname find grep mkdir mktemp python3 rm; do
  ln -s "$(command -v "$command_name")" "$no_herdr_bin/$command_name"
done
status=0
FM_TEST_SKIP_HERDR=0 PATH="$no_herdr_bin" "$ROOT/tests/run.sh" "$probe_test" \
  >"$TMP_ROOT/missing-herdr.out" 2>"$TMP_ROOT/missing-herdr.err" || status=$?
expect_code 1 "$status" "undeclared non-Herdr fallback"
assert_contains "$(cat "$TMP_ROOT/missing-herdr.err")" "use --skip-herdr explicitly" \
  "missing Herdr silently skipped a lifecycle-capable test"
kill -0 "$FIXTURE_ONE" 2>/dev/null || fail "missing-tool refusal touched the first live fixture"
kill -0 "$FIXTURE_TWO" 2>/dev/null || fail "missing-tool refusal touched the second live fixture"
pass "real-Herdr admission fails closed unless the non-Herdr skip is explicit"

direct_out=$(env -u FM_TEST_RUNNER_ACTIVE -u FM_TEST_RUNNER_PID \
  -u FM_TEST_RUNNER_TOKEN -u FM_TEST_SUITE_ROOT -u FM_TEST_REPO_ROOT \
  -u FM_TEST_CURRENT_TEST -u FM_TEST_HERDR_CAPABILITY \
  FM_TEST_ENTRY_SOURCED=firstmate-test-entry-v1 \
  bash "$ROOT/tests/runner-entry-probe.test.sh") \
  || fail "direct hermetic invocation did not cross the runner"
assert_contains "$direct_out" "direct hermetic execution crossed the authoritative runner" \
  "direct hermetic invocation did not execute after admission"
pass "direct hermetic invocation reaches the runner and executes normally"

direct_out=$(FM_TEST_SKIP_HERDR=1 env -u FM_TEST_RUNNER_ACTIVE -u FM_TEST_RUNNER_PID \
  -u FM_TEST_RUNNER_TOKEN -u FM_TEST_SUITE_ROOT -u FM_TEST_REPO_ROOT \
  -u FM_TEST_CURRENT_TEST -u FM_TEST_HERDR_CAPABILITY \
  bash "$ROOT/tests/fm-backend-herdr-smoke.test.sh") \
  || fail "direct lifecycle-capable invocation did not cross the runner's skip gate"
assert_contains "$direct_out" "declares real Herdr lifecycle; --skip-herdr selected" \
  "direct lifecycle-capable invocation did not hit the same admission control"
pass "direct lifecycle-capable invocation reaches the same preflight and explicit skip path"

mixed_out=$(FM_TEST_SKIP_HERDR=1 FM_TEST_FOCUSED=afk-lock-aba \
  env -u FM_TEST_RUNNER_ACTIVE -u FM_TEST_RUNNER_PID \
  -u FM_TEST_RUNNER_TOKEN -u FM_TEST_SUITE_ROOT -u FM_TEST_REPO_ROOT \
  -u FM_TEST_CURRENT_TEST -u FM_TEST_HERDR_CAPABILITY \
  bash "$ROOT/tests/fm-afk-launch.test.sh") \
  || fail "mixed lifecycle invocation did not execute its hermetic portion"
assert_contains "$mixed_out" "launcher lock serializes concurrent stale-lock reclamation" \
  "mixed lifecycle invocation skipped its hermetic assertions"
pass "explicit non-Herdr mode executes mixed entrypoint hermetic assertions"

shard_fixture=$TMP_ROOT/shard-route
shard_admissions=$TMP_ROOT/shard-admissions.log
mkdir -p "$shard_fixture/bin" "$shard_fixture/tests"
cp "$ROOT/bin/fm-behavior-shards.sh" "$shard_fixture/bin/fm-behavior-shards.sh"
chmod +x "$shard_fixture/bin/fm-behavior-shards.sh"
cat > "$shard_fixture/tests/one.test.sh" <<'SH'
#!/usr/bin/env bash
printf 'ok - shard fixture\n'
SH
chmod +x "$shard_fixture/tests/one.test.sh"
printf '1\ttests/one.test.sh\n' > "$shard_fixture/tests/behavior-test-durations.tsv"
cat > "$shard_fixture/tests/run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_SHARD_ADMISSION_LOG:?}"
exec bash "$@"
SH
chmod +x "$shard_fixture/tests/run.sh"
: > "$shard_admissions"
FM_SHARD_ADMISSION_LOG="$shard_admissions" \
  "$shard_fixture/bin/fm-behavior-shards.sh" --run 1 1 "$TMP_ROOT/shard-manifest.tsv" \
    > "$TMP_ROOT/shard-run.out" \
  || fail "shard execution route did not cross its runner fixture"
FM_SHARD_ADMISSION_LOG="$shard_admissions" \
  "$shard_fixture/bin/fm-behavior-shards.sh" --record "$TMP_ROOT/shard-recorded.tsv" \
    > "$TMP_ROOT/shard-record.out" \
  || fail "timing refresh route did not cross its runner fixture"
[ "$(grep -Fxc "$shard_fixture/tests/one.test.sh" "$shard_admissions")" -eq 2 ] \
  || fail "shard execution and timing refresh did not each cross tests/run.sh"
pass "shard execution and timing refresh routes cross the authoritative runner"

grep -F 'tests/run.sh' "$ROOT/CONTRIBUTING.md" >/dev/null \
  || fail "CONTRIBUTING.md does not route behavior tests through tests/run.sh"
grep -F 'bin/fm-behavior-shards.sh --run' "$ROOT/.github/workflows/ci.yml" >/dev/null \
  || fail "CI does not route behavior tests through the sealed shard runner"
grep -F 'FM_TEST_SKIP_HERDR=1' "$ROOT/.github/workflows/ci.yml" >/dev/null \
  || fail "CI does not select the explicit non-Herdr path"
# shellcheck disable=SC2016  # The runner variables are a literal shell source needle.
grep -F '"$ROOT/tests/run.sh" "$ROOT/$path"' "$ROOT/bin/fm-behavior-shards.sh" >/dev/null \
  || fail "the shard runner bypasses tests/run.sh"
pass "sharded CI and documented local execution cross the authoritative runner"
