#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Provider credential expiry classification and the Azure Crosscheck reviewer
# preflight that must refuse before any compartment exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPIRY="$ROOT/bin/fm-credential-expiry.py"
ADAPTER="$ROOT/bin/fm-crosscheck-azure.py"
CORE="$ROOT/bin/fm-crosscheck.py"

# Every fixture credential carries this exact byte string in place of token
# material, so any output that leaks a token leaks this marker with it.
FIXTURE_TOKEN_MARKER=fmtestsecrettokenmarker

make_profiles() {
  # Build one fixture pool: <root>/<vendor>/<name>, each in a known state.
  python3 - "$1" "$FIXTURE_TOKEN_MARKER" <<'PY' || fail "credential fixture build failed"
import base64
import json
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
now = time.time()


def jwt(expiry):
    payload = base64.urlsafe_b64encode(
        json.dumps({"exp": int(expiry)}).encode("utf-8")
    ).decode("ascii").rstrip("=")
    return "h." + payload + "." + marker


def write(vendor, name, credential, value):
    directory = root / vendor / name
    directory.mkdir(parents=True)
    (directory / credential).write_text(
        json.dumps(value, indent=2) + "\n", encoding="utf-8"
    )


def codex(tokens):
    return {"OPENAI_API_KEY": None, "auth_mode": "chatgpt", "tokens": tokens}


write("codex", "live", "auth.json", codex({
    "access_token": jwt(now + 86400), "refresh_token": marker,
    "id_token": jwt(now + 86400), "account_id": "acct-live",
}))
write("codex", "stale", "auth.json", codex({
    "access_token": jwt(now - 3600), "refresh_token": marker,
    "id_token": jwt(now - 3600), "account_id": "acct-stale",
}))
write("codex", "expiring", "auth.json", codex({
    "access_token": jwt(now + 1200), "refresh_token": marker,
    "id_token": jwt(now + 1200), "account_id": "acct-expiring",
}))
# Outlives the review margin (1800) but not the provisioning that happens
# before the review starts, so only the allowance refuses it.
write("codex", "provisioning", "auth.json", codex({
    "access_token": jwt(now + 2100), "refresh_token": marker,
    "id_token": jwt(now + 2100), "account_id": "acct-provisioning",
}))
write("codex", "orphan", "auth.json", codex({
    "access_token": jwt(now - 3600), "refresh_token": "",
    "id_token": jwt(now - 3600), "account_id": "acct-orphan",
}))
write("codex", "apikey", "auth.json", {
    "OPENAI_API_KEY": marker, "auth_mode": "apikey", "tokens": None,
})
write("codex", "malformed", "auth.json", "not-an-object")

write("pi", "live", "auth.json", {"openai-codex": {
    "type": "oauth", "access": jwt(now + 86400), "refresh": marker,
    "accountId": "acct-pi-live", "expires": int((now + 86400) * 1000),
}})
write("pi", "stale", "auth.json", {"openai-codex": {
    "type": "oauth", "access": jwt(now - 3600), "refresh": marker,
    "accountId": "acct-pi-stale", "expires": int((now - 3600) * 1000),
}})

write("claude", "live", ".credentials.json", {"claudeAiOauth": {
    "accessToken": marker, "refreshToken": marker,
    "expiresAt": int((now + 43200) * 1000),
    "refreshTokenExpiresAt": int((now + 864000) * 1000),
}})
write("claude", "stale", ".credentials.json", {"claudeAiOauth": {
    "accessToken": marker, "refreshToken": marker,
    "expiresAt": int((now - 3600) * 1000),
    "refreshTokenExpiresAt": int((now + 864000) * 1000),
}})
write("claude", "dead", ".credentials.json", {"claudeAiOauth": {
    "accessToken": marker, "refreshToken": marker,
    "expiresAt": int((now - 864000) * 1000),
    "refreshTokenExpiresAt": int((now - 3600) * 1000),
}})
# A zeroed stamp is Claude's "no instant recorded", not an instant in 1970.
# Reading zero as a real timestamp would declare live refresh material dead.
write("claude", "zeroedrefresh", ".credentials.json", {"claudeAiOauth": {
    "accessToken": marker, "refreshToken": marker,
    "expiresAt": int((now - 3600) * 1000),
    "refreshTokenExpiresAt": 0,
}})
write("claude", "clearedaccess", ".credentials.json", {"claudeAiOauth": {
    "accessToken": marker, "refreshToken": marker,
    "expiresAt": 0,
    "refreshTokenExpiresAt": int((now + 864000) * 1000),
}})
write("claude", "blanked", ".credentials.json", {"claudeAiOauth": {
    "accessToken": "", "refreshToken": "",
    "expiresAt": 0,
    "refreshTokenExpiresAt": int((now + 864000) * 1000),
}})
(root / "claude" / "empty").mkdir(parents=True)
PY
}

classification_unit() {
  local work
  work=$(fm_test_tmproot fm-credential-expiry-classify)
  make_profiles "$work/pool"
  python3 - "$EXPIRY" "$work/pool" <<'PY' || fail "credential classification contract failed"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("expiry", sys.argv[1])
expiry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(expiry)
pool = pathlib.Path(sys.argv[2])

expected = {
    ("codex", "live"): "usable",
    ("codex", "stale"): "refreshable",
    # No refresh material: nothing can revive this one, so it is provably dead
    # rather than merely stale.
    ("codex", "orphan"): "expired",
    # An API key declares no expiry and must not be classified by a clock.
    ("codex", "apikey"): "usable",
    ("codex", "malformed"): "unusable",
    ("pi", "live"): "usable",
    ("pi", "stale"): "refreshable",
    ("claude", "live"): "usable",
    ("claude", "stale"): "refreshable",
    # The refresh token's own declared expiry has passed: provably dead.
    ("claude", "dead"): "expired",
    # A zeroed refresh stamp records no instant at all, so the refresh cannot
    # be proved dead and this is stale, not expired.
    ("claude", "zeroedrefresh"): "refreshable",
    # A cleared access stamp is not an expiry in 1970; the live refresh token
    # still makes this recoverable by an interactive login.
    ("claude", "clearedaccess"): "refreshable",
    # Blanked token strings carry no material to classify at all.
    ("claude", "blanked"): "unusable",
    ("claude", "empty"): "unusable",
}
for (vendor, name), state in expected.items():
    record = expiry.inspect_profile(pool / vendor / name)
    assert record["state"] == state, (vendor, name, record["state"], state)
    assert record["profile"] == str((pool / vendor / name).resolve())

# Harness detection reads the credential shape, not the directory name.
assert expiry.inspect_profile(pool / "pi" / "live")["harness"] == "pi"
assert expiry.inspect_profile(pool / "codex" / "live")["harness"] == "codex"
assert expiry.inspect_profile(pool / "claude" / "live")["harness"] == "claude"

# The margin is the caller's own deadline: a token that survives the preflight
# but not the run is exactly the failure this module exists to stop.
live = pool / "codex" / "live"
assert expiry.inspect_profile(live, margin_seconds=0)["state"] == "usable"
assert expiry.inspect_profile(live, margin_seconds=172800)["state"] == "refreshable"

# A symlinked credential is never followed.
linked = pool / "codex" / "linked"
linked.mkdir()
(linked / "auth.json").symlink_to(pool / "codex" / "live" / "auth.json")
assert expiry.inspect_profile(linked, harness="codex")["state"] == "unusable"

# require_state names the profile and the refusal without opening the file.
record = expiry.inspect_profile(pool / "codex" / "stale")
try:
    expiry.require_state(record, "usable", "unit")
except expiry.CredentialExpiryError as exc:
    assert str(pool / "codex" / "stale") in str(exc)
    assert "refreshable" in str(exc)
else:
    raise AssertionError("require_state admitted a refreshable profile as usable")
expiry.require_state(record, "refreshable", "unit")
PY
  pass "credential states classify usable, refreshable, expired, and unusable from the real provider shapes"
}

cli_unit() {
  local work out code
  work=$(fm_test_tmproot fm-credential-expiry-cli)
  make_profiles "$work/pool"

  out=$(python3 "$EXPIRY" report --pool-root "$work/pool" 2>&1)
  assert_contains "$out" "usable" "pool report omitted a usable profile"
  assert_contains "$out" "refreshable" "pool report omitted a refreshable profile"
  assert_contains "$out" "$work/pool/codex/live" "pool report omitted a scanned profile path"
  # The report is an operator artifact: it must never carry token material.
  assert_not_contains "$out" "$FIXTURE_TOKEN_MARKER" "pool report leaked token material"

  out=$(python3 "$EXPIRY" report --json --pool-root "$work/pool" 2>&1)
  assert_not_contains "$out" "$FIXTURE_TOKEN_MARKER" "JSON report leaked token material"
  assert_contains "$out" '"expires_at"' "JSON report omitted the expiry instant"

  code=0
  out=$(python3 "$EXPIRY" check "$work/pool/codex/live" 2>&1) || code=$?
  expect_code 0 "$code" "check refused a usable profile"
  code=0
  out=$(python3 "$EXPIRY" check "$work/pool/codex/stale" 2>&1) || code=$?
  expect_code 1 "$code" "check admitted a refreshable profile at the usable default"
  assert_contains "$out" "refreshable" "check refusal did not name the state"
  assert_not_contains "$out" "$FIXTURE_TOKEN_MARKER" "check refusal leaked token material"
  code=0
  out=$(python3 "$EXPIRY" check --min-state refreshable "$work/pool/codex/stale" 2>&1) || code=$?
  expect_code 0 "$code" "check refused a refreshable profile at the refreshable minimum"
  # `check` is a gate. A minimum state that nothing can fall below is a gate
  # that cannot refuse, which reads like one and is not.
  code=0
  "$ROOT/bin/fm-credential-expiry.py" check --min-state unusable "$work/pool/codex/live" >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "check accepted a minimum state it can never refuse"

  pass "the expiry CLI reports and gates profiles without ever emitting token material"
}

crosscheck_preflight_unit() {
  local work
  work=$(fm_test_tmproot fm-credential-expiry-crosscheck)
  make_profiles "$work/pool"
  mkdir -p "$work/home"
  # Enough Azure scope that a refused reviewer is refused by the preflight and
  # not by an absent environment: without it, runtime_config raises before a
  # lane is ever taken and the no-lane assertion below holds identically
  # whether the preflight exists or not.
  #
  # It is deliberately not a COMPLETE scope. verify_scope_and_foundation still
  # raises inside the lane before any `az` runs, so this unit cannot observe
  # Azure CLI calls at all and does not claim to; the lane is what it proves.
  FM_AZURE_TENANT_ID=11111111-1111-4111-8111-111111111111 \
  FM_AZURE_SUBSCRIPTION_ID=11111111-1111-4111-8111-111111111111 \
  FM_AZURE_NAMING_PREFIX=fmtest FM_AZURE_STORAGE_NAME=stfmtest \
  FM_AZURE_DEPLOYMENT_GENERATION=gen-1 FM_AZURE_OWNER_TAG=owner \
  FM_AZURE_RUNNER_OPERATOR_OBJECT_ID=11111111-1111-4111-8111-111111111111 \
  FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID="/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/i/versions/1.0.0" \
  python3 - "$ADAPTER" "$CORE" "$work" <<'PY' || fail "Azure Crosscheck reviewer preflight contract failed"
import fcntl
import importlib.util
import inspect
import pathlib
import subprocess
import sys


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load("adapter", sys.argv[1])
# The real core module supplies the real CrosscheckToolError, so the refusal
# is proved against the class the reviewer roster actually catches to rotate.
core = load("core", sys.argv[2])
work = pathlib.Path(sys.argv[3])
pool = work / "pool"
home = work / "home"

# The preflight runs before the FIFO lane wait, before runtime_config, and
# again once the lane is held because the lane wait can outlast the
# credential. A third check inside the held lane still precedes every remote
# staged object and reviewer-host use. The snapshot wrapper delegates these
# contracts to the two functions that own lane admission and paid compute.
lane_source = inspect.getsource(adapter._run_azure_review_after_snapshot)
entry_source = inspect.getsource(adapter.run_azure_review)
assert "_run_azure_review_after_snapshot" in entry_source
assert lane_source.index("preflight_reviewer_credential") < lane_source.index("acquire_review_lane")
assert lane_source.index("preflight_reviewer_credential") < lane_source.index("runtime_config")
assert lane_source.rindex("preflight_reviewer_credential") > lane_source.index("acquire_review_lane")
compute_source = inspect.getsource(adapter._run_azure_review_in_lane)
assert compute_source.index("preflight_reviewer_credential") < compute_source.index("upload_blob")
assert compute_source.index("preflight_reviewer_credential") < compute_source.index("ensure_model_host")


def review(profile, harness):
    return adapter._run_azure_review_after_snapshot(
        core=core, root=home, home=home, task_id="t", pr_url="https://example.invalid/pr/1",
        review_dir=home, proof_root=home, snapshot_value={}, ledger={},
        config={"harness": harness, "account_home": str(profile),
                "model": "m", "effort": "xhigh"},
        phase_timer=None, persist_result=None, repository_snapshot={}, guidance={},
    )


# An expired reviewer is refused as a tool failure, which is what makes the
# roster skip this account instead of ending the review.
try:
    review(pool / "codex" / "orphan", "codex")
except core.CrosscheckToolError as exc:
    message = str(exc)
    assert str(pool / "codex" / "orphan") in message, message
    assert "expired" in message, message
    assert "no model compartment" in message, message
else:
    raise AssertionError("an expired reviewer reached the Azure compartment path")

# The compartment's egress allowlist is Azure DNS plus one provider API host,
# so a CLI inside it can never reach an auth host: refreshable is not
# recoverable there and must be refused too.
try:
    review(pool / "claude" / "stale", "claude")
except core.CrosscheckToolError as exc:
    assert "refreshable" in str(exc), str(exc)
else:
    raise AssertionError("a refreshable reviewer reached the Azure compartment path")

# A credential alive right now but dead before the review deadline is refused
# too. This is the only fixture the review margin participates in: without it
# the margin could be zeroed and every assertion here would still pass.
try:
    review(pool / "codex" / "expiring", "codex")
except core.CrosscheckToolError as exc:
    # 1200s of life is more than the module default margin (900) and less than
    # the caller's review margin (1800), so only the caller's own margin
    # refuses it: dropping that argument makes this fixture pass.
    assert "acct" not in str(exc)
    assert "refreshable" in str(exc) or "expired" in str(exc), str(exc)
else:
    raise AssertionError("a reviewer that dies mid-review reached the Azure compartment path")

# A credential that outlives the review itself but not the VM create, boot, and
# bundle upload in front of it still cannot finish, so the margin covers that
# gap too. Without the allowance this profile is admitted and buys a VM.
try:
    review(pool / "codex" / "provisioning", "codex")
except core.CrosscheckToolError as exc:
    assert "refreshable" in str(exc) or "expired" in str(exc), str(exc)
else:
    raise AssertionError("a reviewer that dies during provisioning reached the Azure compartment path")

# Nothing above took a lane.
lanes = adapter.lane_root(home)
assert not lanes.exists() or not any(lanes.iterdir()), "a refused reviewer held a review lane"

# Positive control for that assertion: a usable credential must get PAST the
# preflight and reach the lane. Without this, the check above would be satisfied
# by a code path that never reaches a lane at all, and would stay green with the
# whole feature deleted.
try:
    review(pool / "codex" / "live", "codex")
except Exception:
    pass
assert lanes.exists() and any(lanes.iterdir()), (
    "a usable reviewer never reached a lane, so the refusal assertion proves nothing"
)

# The second preflight, the one that gates spend, is proved by expiring the
# credential during the lane wait: the pre-lane call saw a live token, so only
# a check behind the lane can refuse this.
expiring_home = pool / "codex" / "secondgate"
expiring_home.mkdir(parents=True)
live_body = (pool / "codex" / "live" / "auth.json").read_text(encoding="utf-8")
dead_body = (pool / "codex" / "stale" / "auth.json").read_text(encoding="utf-8")
(expiring_home / "auth.json").write_text(live_body, encoding="utf-8")

# Lane occupancy is an flock on a lock file that acquire_review_lane creates
# once and never unlinks, so a held lane and a released one produce identical
# directory listings. Probe the lock itself: a non-blocking flock from a
# separate process succeeds only if nothing still holds it.
def lanes_held():
    held = []
    if not lanes.exists():
        return held
    for lock in sorted(lanes.glob("lane-*.lock")):
        probe = subprocess.run(
            [sys.executable, "-c",
             "import fcntl,sys\n"
             "handle = open(sys.argv[1], 'a+')\n"
             "try:\n"
             "    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
             "except OSError:\n"
             "    raise SystemExit(3)\n"
             "raise SystemExit(0)\n",
             str(lock)],
            capture_output=True,
        )
        if probe.returncode == 3:
            held.append(lock.name)
    return held


# Self-check: the probe must actually observe a held lane, or every assertion
# built on it is vacuous.
_probe_lane = lanes / "lane-probe.lock"
lanes.mkdir(parents=True, exist_ok=True)
_probe_handle = open(_probe_lane, "a+")
fcntl.flock(_probe_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
assert "lane-probe.lock" in lanes_held(), "the lane occupancy probe cannot see a held lane"
_probe_handle.close()
assert "lane-probe.lock" not in lanes_held(), "the lane occupancy probe reports a released lane as held"
_probe_lane.unlink()

real_acquire = adapter.acquire_review_lane


def expire_during_wait(*args, **kwargs):
    # Stand in for a queue wait that outlasts the token.
    (expiring_home / "auth.json").write_text(dead_body, encoding="utf-8")
    return real_acquire(*args, **kwargs)


adapter.acquire_review_lane = expire_during_wait
try:
    try:
        review(expiring_home, "codex")
    except core.CrosscheckToolError as exc:
        assert "expired" in str(exc), str(exc)
    else:
        raise AssertionError(
            "a credential that died during the lane wait was never re-checked behind the lane"
        )
finally:
    adapter.acquire_review_lane = real_acquire

# That refusal released its lane rather than leaking it.
still_held = lanes_held()
assert not still_held, "the second preflight leaked its review lane: %r" % (still_held,)
PY
  pass "an expired, unrefreshable, or mid-review-expiring Azure reviewer is refused before any lane or compartment"
}

classification_unit
cli_unit
crosscheck_preflight_unit
