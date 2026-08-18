#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior: projecting one Pi profile into the single-profile account home its
# consumers actually read, without ever writing a token into the transcript.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-pi-account-home.py"
# A marker standing in for token material, so leakage is detectable by grep
# rather than by inspection.
MARKER=fmtestpitokenmarker

make_pool() {
  python3 - "$1" "$MARKER" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
marker = sys.argv[2]


def entry(account, expires=1893456000000, access=None, refresh=None, kind="oauth"):
    return {
        "type": kind,
        "access": marker + "-access" if access is None else access,
        "refresh": marker + "-refresh" if refresh is None else refresh,
        "expires": expires,
        "accountId": account,
    }


pool = {
    "openai-codex": entry("acct-one"),
    "openai-codex-2": entry("acct-two"),
    # The shape a de-authenticated profile leaves behind: the keys are all
    # present, and both token strings are empty.
    "openai-codex-3": entry("acct-three", access="", refresh=""),
    "openai-codex-4": entry("acct-four", kind="apikey"),
    "openai-codex-5": {"type": "oauth", "access": marker, "refresh": marker,
                       "accountId": "acct-five"},
    "openai-codex-6": entry("   "),
}
path.write_text(json.dumps(pool, indent=2) + "\n", encoding="utf-8")
PY
}

# `stat -f` is a BSD format string and a GNU filesystem-status flag, so a
# `stat -f ... || stat -c ...` pair silently reports the wrong thing on Linux
# rather than falling through. Python means one thing on both.
file_mode() {
  python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
}

projection_contract() {
  local work pool out code
  work=$(fm_test_tmproot fm-pi-account-home)
  pool=$work/auth.json
  make_pool "$pool"

  # A named profile lands under the fixed consumer key, not under its pool name.
  "$TOOL" project --source "$pool" --destination-root "$work/homes" \
    --profile openai-codex-2 >"$work/out.txt" 2>&1 \
    || fail "projecting a usable profile refused"
  assert_present "$work/homes/openai-codex-2/auth.json" "the projected account home has no credential"
  python3 - "$work/homes/openai-codex-2/auth.json" <<'PY' || fail "the projected credential is not consumer-shaped"
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert list(value) == ["openai-codex"], list(value)
assert value["openai-codex"]["accountId"] == "acct-two", value["openai-codex"]["accountId"]
PY

  # Exactly one credential reaches the home. Handing over the pool would carry
  # every signed-in account into a compartment that needs one.
  assert_no_grep "acct-one" "$work/homes/openai-codex-2/auth.json" \
    "a sibling profile's account rode along into the projected home"

  # The consumer reads this file directly; wrong modes expose a live token.
  expect_code 600 "$(file_mode "$work/homes/openai-codex-2/auth.json")" "the projected credential is not owner-only"
  expect_code 700 "$(file_mode "$work/homes/openai-codex-2")" "the projected account home is not owner-only"

  # Nothing the command prints may carry token material.
  assert_no_grep "$MARKER" "$work/out.txt" "the projection printed token material"
  "$TOOL" report --source "$pool" >"$work/report.txt" 2>&1 || fail "report refused a readable pool"
  assert_no_grep "$MARKER" "$work/report.txt" "the report printed token material"
  assert_grep "distinct-accounts" "$work/report.txt" "the report omitted its account summary"

  # Re-projecting is idempotent, so a refreshed pool can be re-run at any time.
  "$TOOL" project --source "$pool" --destination-root "$work/homes" \
    --profile openai-codex-2 >/dev/null 2>&1 || fail "re-projecting the same profile refused"

  # A blanked profile reads as present to anything checking only for the key.
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/blank" \
    --profile openai-codex-3 2>&1) || code=$?
  expect_code 1 "$code" "a blanked-token profile was projected"
  assert_contains "$out" "blank access" "the refusal did not name the blank token"
  assert_absent "$work/blank/openai-codex-3/auth.json" "a refused profile still wrote a credential"

  for bad in openai-codex-4 openai-codex-5 openai-codex-6; do
    code=0
    "$TOOL" project --source "$pool" --destination-root "$work/bad" --profile "$bad" >/dev/null 2>&1 || code=$?
    expect_code 1 "$code" "an unusable profile ($bad) was projected"
  done

  # --all refuses as a set rather than leaving a half-projected root behind.
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/every" --all 2>&1) || code=$?
  expect_code 1 "$code" "--all projected a pool containing unusable profiles"
  assert_contains "$out" "4 of 6" "the refusal did not report the full unusable set"
  assert_absent "$work/every/openai-codex/auth.json" "a refused --all run projected the usable profiles anyway"

  # A planted symlink at the credential path must not be followed into a write.
  mkdir -p "$work/planted/openai-codex-2" "$work/target"
  ln -s "$work/target/stolen.json" "$work/planted/openai-codex-2/auth.json"
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/planted" \
    --profile openai-codex-2 2>&1) || code=$?
  expect_code 1 "$code" "a symlinked credential path was followed into a write"
  assert_absent "$work/target/stolen.json" "the projection wrote through a planted symlink"

  code=0
  "$TOOL" project --source "$pool" --destination-root "$work/none" --profile absent >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a profile absent from the pool was projected"

  # A lone unknown name is refused by the empty-selection guard, which says
  # nothing about whether unknown names are noticed. Mix one in with a good one:
  # a typo that is silently dropped tells the operator the projection succeeded.
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/mixed" \
    --profile openai-codex-2 --profile openai-codex-77 2>&1) || code=$?
  expect_code 1 "$code" "an unknown profile mixed with a known one was silently dropped"
  assert_contains "$out" "openai-codex-77" "the refusal did not name the unknown profile"
  assert_absent "$work/mixed/openai-codex-2/auth.json" "a refused selection projected its known profiles anyway"

  # Every reason at once, not just the first: the blanked fixture has two.
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/faults" --profile openai-codex-3 2>&1) || code=$?
  expect_code 1 "$code" "a blanked profile was projected"
  assert_contains "$out" "blank access" "the refusal omitted the blank access token"
  assert_contains "$out" "blank refresh" "the refusal reported only the first fault"

  # The source guard must be reachable: resolving the path before reading it
  # strips the symlink and the guard can never fire.
  ln -s "$pool" "$work/linked-pool.json"
  code=0
  "$TOOL" report --source "$work/linked-pool.json" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a symlinked credential pool was read"

  # The reported instant and the distinct-account count are the values an
  # operator plans a rotation from; neither is proved by the header alone.
  "$TOOL" report --source "$pool" >"$work/report2.txt" 2>&1 || fail "report refused"
  assert_grep "2030-01-01T00:00:00Z" "$work/report2.txt" "the report did not render the expiry instant"
  assert_grep "profiles=6 distinct-accounts=5" "$work/report2.txt" "the report miscounted distinct accounts"

  # An intermediate symlink redirects the write as effectively as one at the
  # credential path, and mkdir(exist_ok) follows it because isdir does.
  mkdir -p "$work/traverse" "$work/elsewhere"
  ln -s "$work/elsewhere" "$work/traverse/openai-codex-2"
  code=0
  "$TOOL" project --source "$pool" --destination-root "$work/traverse" --profile openai-codex-2 >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a symlinked profile directory was followed into a write"
  assert_absent "$work/elsewhere/auth.json" "the projection wrote a credential outside its destination root"

  # A root anyone can write to is where a profile component gets replaced by a
  # link between the check and the write.
  mkdir -p "$work/openroot"; chmod 0777 "$work/openroot"
  code=0
  "$TOOL" project --source "$pool" --destination-root "$work/openroot" --profile openai-codex-2 >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a credential was written under a world-writable root"

  # Created ancestors are owner-only regardless of the caller's umask; a mode
  # that only holds under a strict umask is not an assurance.
  (umask 000; "$TOOL" project --source "$pool" --destination-root "$work/deep/nested/root" \
    --profile openai-codex-2 >/dev/null 2>&1) || fail "projecting into a new root refused"
  for created in "$work/deep" "$work/deep/nested" "$work/deep/nested/root"; do
    expect_code 700 "$(file_mode "$created")" \
      "a created ancestor was left readable to others under a permissive umask"
  done

  # An account is identified by digest, so the raw upstream id never appears.
  assert_no_grep "acct-two" "$work/report2.txt" "the report printed a raw account identifier"

  # The pool bound is a real refusal, not a comment.
  python3 -c 'import sys; open(sys.argv[1],"w").write("{\"openai-codex\":\"" + "x"*5000000 + "\"}")' "$work/huge.json"
  code=0
  "$TOOL" report --source "$work/huge.json" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "an oversized credential pool was read"

  # An ordinary OS error is still a refusal, not a traceback.
  mkdir -p "$work/readonly"; chmod 0500 "$work/readonly"
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/readonly/sub" --profile openai-codex-2 2>&1) || code=$?
  chmod 0700 "$work/readonly"
  expect_code 1 "$code" "an unwritable destination did not refuse cleanly"
  assert_contains "$out" "PI ACCOUNT HOME REFUSED" "an OS error escaped the refusal contract"

  code=0
  "$TOOL" report --source "$work/missing.json" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "an absent pool was reported as readable"

  printf 'not json\n' >"$work/malformed.json"
  code=0
  "$TOOL" report --source "$work/malformed.json" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a malformed pool was reported as readable"

  pass "one Pi profile projects into the single-profile account home its consumers read, and unusable or planted paths refuse"
}

consumer_agreement_contract() {
  local work pool
  work=$(fm_test_tmproot fm-pi-account-home-consumer)
  pool=$work/auth.json
  make_pool "$pool"
  "$TOOL" project --source "$pool" --destination-root "$work/homes" \
    --profile openai-codex-2 >/dev/null 2>&1 || fail "projection refused"

  # The real consumer, not a restatement of it: fm-crosscheck.py's own reader
  # must accept the projected home and derive the expected identity from it.
  # Asserting the key name here instead would only prove this test agrees with
  # itself.
  python3 - "$ROOT/bin/fm-crosscheck.py" "$work/homes/openai-codex-2" <<'PY' \
    || fail "the real Pi credential reader rejected a projected account home"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("core", sys.argv[1])
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
home = pathlib.Path(sys.argv[2])
source, identifier = core.inspect_pi_credential(home)
assert source == "pi-openai-codex-oauth-file", source
assert identifier == str(home / "auth.json"), identifier
identity = core.account_identity("pi", home)
assert identity == "openai-codex:acct-two", identity
PY
  # The reader must also refuse the pooled file outright. Without that, the
  # hazard this tool exists to remove stays reachable for anyone who does not
  # run it: the pool passes every check, and the Azure archive stages all of it.
  python3 - "$ROOT/bin/fm-crosscheck.py" "$work" <<'PY' || fail "the Pi reader accepted a pooled account home"
import importlib.util
import json
import pathlib
import sys

spec = importlib.util.spec_from_file_location("core", sys.argv[1])
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
home = pathlib.Path(sys.argv[2]) / "pooled"
home.mkdir(parents=True, exist_ok=True)
entry = {"type": "oauth", "access": "a", "refresh": "r",
         "expires": 1893456000000, "accountId": "acct"}
(home / "auth.json").write_text(
    json.dumps({"openai-codex": entry, "openai-codex-2": entry}), encoding="utf-8"
)
try:
    core.inspect_pi_credential(home)
except core.CrosscheckToolError as exc:
    assert "provider slots" in str(exc), str(exc)
else:
    raise AssertionError("a pooled multi-slot account home was accepted")
PY

  pass "the real fm-crosscheck Pi reader accepts a projected home, derives its account, and refuses a pooled one"
}

projection_contract
consumer_agreement_contract
