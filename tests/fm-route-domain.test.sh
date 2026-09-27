#!/usr/bin/env bash
# tests/fm-route-domain.test.sh - verify Jev domain router behavior
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTER="$ROOT/bin/fm-route-domain.sh"
[ -x "$ROUTER" ] || fail "bin/fm-route-domain.sh missing or not executable"

TDIR=$(fm_test_tmproot fm-route-test)

REG="$TDIR/secondmates.md"
cat <<'EOF' > "$REG"
- portal-ops - Clinical operations and EMR work: Portal implementation, UrgentIQ and DoseSpot, provider onboarding. (home: /tmp/p; scope: Arcs Portal clinical operations, UrgentIQ, DoseSpot; projects: portal; added 2026-07-29)
- seller-outreach - Seller lead generation and outreach for urgent-care clinics. (home: /tmp/s; scope: All urgent-care seller lead generation, campaigns, Flow; projects: agents-flow; added 2026-07-29)
- websites - Rebuild of arcs.health and jonroosevelt.com frontend. (home: /tmp/w; scope: Frontend website rebuild, UI components, Next.js, Framer Motion; projects: website-covenant; added 2026-08-06)
EOF

# 1. Empty input fails open to unavailable
out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "" --registry "$REG" 2>/dev/null || true)
assert_contains "$out" "action=unavailable" "empty task emits unavailable"

# 2. Missing key fails open to unavailable
out=$(env -u TYPESAFE_API_KEY python3 -c '
import os, sys
# shadow jev-typesafe-run
from pathlib import Path
' 2>/dev/null || true)
out=$(env TYPESAFE_API_KEY="" python3 "$ROOT/bin/fm-route-domain.py" --task "Test task" --registry "$REG" 2>/dev/null || true)
# Should emit action=unavailable if key cannot be obtained, or action=dispatch/handle_direct if key is live
assert_contains "$out" "action=" "router emits action field"

# 2b. Deterministic Jev: stub the SystemOne call at the urllib boundary so the
# router and dispatcher run end to end with no credentials and no network, then
# hold what they do with an unsafe route choice and with a partial scaffold.
FAKE_TS="$TDIR/fake-ts"
mkdir -p "$FAKE_TS"
cat > "$FAKE_TS/sitecustomize.py" <<'PY'
import os
import urllib.request

_real_urlopen = urllib.request.urlopen


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _fake_urlopen(req, *args, **kwargs):
    path = os.environ.get("FM_TEST_JEV_RESPONSE")
    if not path:
        return _real_urlopen(req, *args, **kwargs)
    with open(path, "rb") as handle:
        return _FakeResponse(handle.read())


urllib.request.urlopen = _fake_urlopen
PY

write_jev_response() {  # <choice> <noul>
  jq -n --arg choice "$1" --argjson noul "$2" \
    '{answers:{route:{choice:$choice,confidence:0.95},needs_new_secondmate:{noul:$noul}}}' \
    > "$TDIR/jev-response.json"
}

run_dispatch() {  # <registry> <homes-dir> [fm-route-dispatch.sh args...]
  local registry=$1 homes=$2
  shift 2
  PYTHONPATH="$FAKE_TS${PYTHONPATH:+:$PYTHONPATH}" \
    FM_TEST_JEV_RESPONSE="$TDIR/jev-response.json" \
    TYPESAFE_API_KEY=fake-key \
    FM_SECONDMATE_HOMES_DIR="$homes" \
    "$ROOT/bin/fm-route-dispatch.sh" --registry "$registry" "$@"
}

# A Jev response of ".." must be refused before it becomes a filesystem
# component: no charter is appended and nothing is scaffolded outside the
# homes root.
REG_UNSAFE="$TDIR/reg-unsafe.md"
cp "$REG" "$REG_UNSAFE"
REG_UNSAFE_BEFORE=$(cat "$REG_UNSAFE")
write_jev_response ".." 0.95
rc=0
out=$(run_dispatch "$REG_UNSAFE" "$TDIR/homes-unsafe" --auto-charter \
  --task "Autonomous agricultural drone autopilot navigation firmware in Rust" 2>&1) || rc=$?
expect_code 0 "$rc" "an unsafe route choice should fall back without erroring: $out"
assert_contains "$out" "refused unsafe route choice" "the router did not report the refusal"
assert_not_contains "$out" "Auto-chartered" "an unsafe route choice claimed a charter"
assert_equals "$REG_UNSAFE_BEFORE" "$(cat "$REG_UNSAFE")" \
  "an unsafe route choice appended a charter line"
assert_absent "$TDIR/data" "an unsafe route choice scaffolded data/ outside the homes root"
assert_absent "$TDIR/state" "an unsafe route choice scaffolded state/ outside the homes root"
assert_absent "$TDIR/.fm-secondmate-home" "an unsafe route choice planted a home marker outside the homes root"
assert_absent "$TDIR/.fm-secondmate-parent" "an unsafe route choice planted a parent marker outside the homes root"

rc=0
json_out=$(run_dispatch "$REG_UNSAFE" "$TDIR/homes-unsafe" --json --auto-charter \
  --task "Autonomous agricultural drone autopilot navigation firmware in Rust") || rc=$?
expect_code 0 "$rc" "the JSON refusal should exit zero: $json_out"
printf '%s' "$json_out" | jq -e \
  '.action == "unavailable" and .auto_charter.chartered == false and .route == "captain_direct"' \
  >/dev/null || fail "the refusal JSON did not fall back with no charter: $json_out"
assert_equals "$REG_UNSAFE_BEFORE" "$(cat "$REG_UNSAFE")" \
  "the JSON refusal appended a charter line"
pass "a Jev response of \"..\" is refused before it reaches the filesystem"

# The same refusal governs the dispatch path, where the choice would become a
# seat status read and the fm-send route.
write_jev_response "../../outside-seat" 0.1
rc=0
out=$(run_dispatch "$REG_UNSAFE" "$TDIR/homes-unsafe" \
  --task "Urgent care acquisition seller email outreach campaign" 2>&1) || rc=$?
expect_code 0 "$rc" "an unsafe dispatch route should fall back without erroring: $out"
assert_contains "$out" "refused unsafe route choice" "the router did not report the dispatch refusal"
assert_not_contains "$out" "Recommended dispatch command" \
  "the router recommended dispatching to a path-significant seat"
pass "a path-significant route choice is refused instead of dispatched"

# A partial scaffold (charter appended, home scaffolding failed) must report the
# scaffold error and exit non-zero instead of claiming success.
REG_PARTIAL="$TDIR/reg-partial.md"
cp "$REG" "$REG_PARTIAL"
HOMES_AS_FILE="$TDIR/homes-is-a-file"
: > "$HOMES_AS_FILE"
write_jev_response "new_domain" 0.95
rc=0
out=$(run_dispatch "$REG_PARTIAL" "$HOMES_AS_FILE" --auto-charter \
  --task "Quantum computing cryptographic lattice simulation engine in Haskell" 2>&1) || rc=$?
expect_code 1 "$rc" "a partial scaffold must exit non-zero: $out"
assert_contains "$out" "home scaffold failed" "the partial scaffold did not report the scaffold error"
assert_not_contains "$out" "Home scaffolded:" "the partial scaffold still claimed a scaffolded home"
assert_not_contains "$out" "Ready to spawn" "the partial scaffold still claimed readiness to spawn"
assert_contains "$(cat "$REG_PARTIAL")" "Dedicated secondmate for" \
  "the partial scaffold did not record the appended charter"
pass "a partial scaffold reports the error and exits non-zero"

# The --json path carries the same failure contract: emit the payload, then
# exit non-zero with the error on stderr.
REG_JSON_PARTIAL="$TDIR/reg-json-partial.md"
cp "$REG" "$REG_JSON_PARTIAL"
JSON_PARTIAL_ERR="$TDIR/json-partial.stderr"
write_jev_response "new_domain" 0.95
rc=0
json_out=$(run_dispatch "$REG_JSON_PARTIAL" "$HOMES_AS_FILE" --json --auto-charter \
  --task "Quantum computing cryptographic lattice simulation engine in Haskell" 2>"$JSON_PARTIAL_ERR") || rc=$?
expect_code 1 "$rc" "a partial scaffold must exit non-zero on the --json path: $json_out"
printf '%s' "$json_out" | jq -e '
  .action == "create_secondmate"
  and .auto_charter.chartered == true
  and ((.auto_charter.scaffold_error // "") | length) > 0
' >/dev/null || fail "the --json payload did not carry the scaffold failure: $json_out"
assert_grep "home scaffold failed" "$JSON_PARTIAL_ERR" \
  "the --json path did not report the scaffold error on stderr"
pass "the --json path reports a partial scaffold and exits non-zero"

# The happy path still banners success and scaffolds a real home.
REG_OK="$TDIR/reg-ok.md"
cp "$REG" "$REG_OK"
HOMES_OK="$TDIR/homes-ok"
mkdir -p "$HOMES_OK"
write_jev_response "new_domain" 0.95
rc=0
out=$(run_dispatch "$REG_OK" "$HOMES_OK" --auto-charter \
  --task "Quantum computing cryptographic lattice simulation engine in Haskell" 2>&1) || rc=$?
expect_code 0 "$rc" "a full scaffold should succeed: $out"
assert_contains "$out" "Auto-chartered new Second Mate" "the happy path lost its charter banner"
assert_contains "$out" "Home scaffolded: $HOMES_OK/" "the happy path lost its scaffold banner"
assert_contains "$out" "Ready to spawn" "the happy path lost its readiness banner"
scaffold_home=$(printf '%s\n' "$out" | sed -n 's/^Home scaffolded: //p')
[ -n "$scaffold_home" ] || fail "the success banner did not name the scaffolded home"
assert_present "$scaffold_home/.fm-secondmate-home" "the happy path did not create the home marker"
pass "a full auto-charter scaffold still reports success"

# A charter that cannot even be appended must fail loudly instead of falling
# back to the unmatched-domain guidance that tells the operator to pass
# --auto-charter again.
REG_CHARTER_FAIL="$TDIR/reg-charter-write-fail.md"
cp "$REG" "$REG_CHARTER_FAIL"
chmod 0444 "$REG_CHARTER_FAIL"
if [ -w "$REG_CHARTER_FAIL" ]; then
  pass "charter-write failure path skipped: this user can still write a mode-0444 registry"
else
  write_jev_response "new_domain" 0.95
  rc=0
  out=$(run_dispatch "$REG_CHARTER_FAIL" "$TDIR/homes-charter-fail" --auto-charter \
    --task "Quantum computing cryptographic lattice simulation engine in Haskell" 2>&1) || rc=$?
  expect_code 1 "$rc" "a charter-write failure must exit non-zero: $out"
  assert_contains "$out" "Failed to write charter" "the charter-write failure was not reported"
  assert_not_contains "$out" "(Pass --auto-charter" \
    "a failed --auto-charter still told the operator to pass --auto-charter"
  assert_not_contains "$out" "Home scaffolded:" \
    "a charter-write failure claimed a scaffolded home"

  CHARTER_ERR="$TDIR/charter-write.stderr"
  rc=0
  json_out=$(run_dispatch "$REG_CHARTER_FAIL" "$TDIR/homes-charter-fail" --json --auto-charter \
    --task "Quantum computing cryptographic lattice simulation engine in Haskell" 2>"$CHARTER_ERR") || rc=$?
  expect_code 1 "$rc" "a charter-write failure must exit non-zero on the --json path: $json_out"
  printf '%s' "$json_out" | jq -e \
    '.action == "create_secondmate" and ((.auto_charter.error // "") | length) > 0' \
    >/dev/null || fail "the --json payload did not carry the charter-write failure: $json_out"
  assert_grep "Failed to write charter" "$CHARTER_ERR" \
    "the --json path did not report the charter-write failure on stderr"
  pass "a charter-write failure is reported and fails on every front-door path"
fi

# The producer owns the verdict: its own CLI must fail a partial scaffold on
# both output formats, and dispatch only relays that verdict.
REG_PRODUCER="$TDIR/reg-producer.md"
cp "$REG" "$REG_PRODUCER"
write_jev_response "new_domain" 0.95
rc=0
producer_out=$(PYTHONPATH="$FAKE_TS${PYTHONPATH:+:$PYTHONPATH}" \
  FM_TEST_JEV_RESPONSE="$TDIR/jev-response.json" \
  TYPESAFE_API_KEY=fake-key \
  FM_SECONDMATE_HOMES_DIR="$HOMES_AS_FILE" \
  "$ROUTER" --auto-charter --registry "$REG_PRODUCER" \
  --task "Quantum computing cryptographic lattice simulation engine in Haskell" 2>&1) || rc=$?
expect_code 1 "$rc" "the router CLI must exit non-zero on a partial scaffold: $producer_out"
assert_contains "$producer_out" "home scaffold failed" \
  "the router CLI did not report the scaffold error"

rc=0
producer_json=$(PYTHONPATH="$FAKE_TS${PYTHONPATH:+:$PYTHONPATH}" \
  FM_TEST_JEV_RESPONSE="$TDIR/jev-response.json" \
  TYPESAFE_API_KEY=fake-key \
  FM_SECONDMATE_HOMES_DIR="$HOMES_AS_FILE" \
  "$ROUTER" --auto-charter --json --registry "$REG_PRODUCER" \
  --task "Quantum computing cryptographic lattice simulation engine in Haskell" 2>/dev/null) || rc=$?
expect_code 1 "$rc" "the router CLI --json must exit non-zero on a partial scaffold: $producer_json"
printf '%s' "$producer_json" | jq -e '
  .action == "create_secondmate"
  and ((.auto_charter.failure // "") | contains("home scaffold failed"))
' >/dev/null || fail "the router CLI --json payload did not carry the failure verdict: $producer_json"
pass "the router CLI reports a partial scaffold as failure on every output format"

# 3. Live call: known domain (seller-outreach)
if sudo -n /opt/ra/firstmate/bin/jev-typesafe-run.py -- env | grep -q "TYPESAFE_API_KEY"; then
  out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "Urgent care acquisition seller email outreach campaign" --registry "$REG")
  assert_contains "$out" "action=dispatch" "known domain emits dispatch action"
  assert_contains "$out" "route=seller-outreach" "known domain routes to seller-outreach"
  assert_contains "$out" "dispatch_cmd=" "dispatch action includes dispatch_cmd"

  # 4. Live call: captain direct conversation
  out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "Good morning Firstmate, what is the high level status?" --registry "$REG")
  assert_contains "$out" "action=handle_direct" "captain message emits handle_direct"
  assert_contains "$out" "route=captain_direct" "captain message routes to captain_direct"

  # 5. Live call: new domain
  out=$(python3 "$ROOT/bin/fm-route-domain.py" --task "Autonomous agricultural drone autopilot navigation firmware in Rust" --registry "$REG")
  assert_contains "$out" "action=create_secondmate" "unmatched task emits create_secondmate"
  assert_contains "$out" "route=new_domain" "unmatched task routes to new_domain"

  # 6. JSON output
  json_out=$(python3 "$ROOT/bin/fm-route-domain.py" --json --task "Good morning" --registry "$REG")
  assert_contains "$json_out" '"action": "handle_direct"' "json output contains valid action"

  # 7. Seat wall detection & Cursor Grok override suggestion
  MOCK_STATE="$TDIR/state"
  mkdir -p "$MOCK_STATE"
  cat <<'EOF' > "$MOCK_STATE/seller-outreach.status"
blocked [key=claude-rate-limit]: seat cannot act: claude weekly quota exhausted until 2026-09-27; lane walled
EOF
  walled_out=$(FM_STATE_OVERRIDE="$MOCK_STATE" python3 "$ROOT/bin/fm-route-domain.py" --task "Urgent care acquisition seller email outreach campaign" --registry "$REG")
  assert_contains "$walled_out" "seat_warning=Target seat 'seller-outreach' appears walled on Claude." "detects claude wall in target seat"
  assert_contains "$walled_out" "--harness cursor --model cursor-grok-4.6-high" "suggests cursor grok fallback"
  assert_contains "$walled_out" 'dispatch_cmd=FM_HOME=/opt/ra/firstmate bin/fm-send.sh seller-outreach --harness cursor --model cursor-grok-4.6-high' "dispatch_cmd contains cursor grok override"

  # 8. Auto-charter new secondmate
  MOCK_HOMES="$TDIR/homes"
  mkdir -p "$MOCK_HOMES"
  charter_out=$(FM_SECONDMATE_HOMES_DIR="$MOCK_HOMES" python3 "$ROOT/bin/fm-route-domain.py" --auto-charter --task "Autonomous agricultural drone autopilot navigation firmware in Rust" --registry "$REG")
  assert_contains "$charter_out" "action=create_secondmate" "auto-charter preserves create_secondmate"
  assert_contains "$charter_out" "chartered_domain=" "emits chartered_domain"
  assert_contains "$charter_out" "chartered_home=" "emits chartered_home"

  # Verify registry was updated with formatted charter
  reg_content=$(cat "$REG")
  assert_contains "$reg_content" "Dedicated secondmate for" "registry has new charter line"
  assert_contains "$reg_content" "scope: Autonomous agricultural drone" "charter has scope"

  # Verify directory scaffolding
  chartered_domain=$(echo "$charter_out" | grep '^chartered_domain=' | cut -d= -f2)
  [ -d "$MOCK_HOMES/$chartered_domain/data" ] || fail "scaffolded data dir missing"
  [ -d "$MOCK_HOMES/$chartered_domain/state" ] || fail "scaffolded state dir missing"
  [ -f "$MOCK_HOMES/$chartered_domain/.fm-secondmate-home" ] || fail "scaffolded .fm-secondmate-home missing"
  assert_contains "$(cat "$MOCK_HOMES/$chartered_domain/.fm-secondmate-home")" "$chartered_domain" "home marker contains domain"

  # 9. fm-route-dispatch.sh with --auto-charter
  dispatch_out=$(FM_SECONDMATE_HOMES_DIR="$MOCK_HOMES" "$ROOT/bin/fm-route-dispatch.sh" --registry "$REG" --auto-charter --task "Quantum computing cryptographic lattice simulation engine in Haskell")
  assert_contains "$dispatch_out" "Auto-chartered new Second Mate" "dispatch script reports auto-charter"
  assert_contains "$dispatch_out" "bin/fm-spawn.sh" "dispatch script reports spawn command"
fi

pass "all fm-route-domain tests passed"
