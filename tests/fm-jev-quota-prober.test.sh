#!/usr/bin/env bash
# tests/fm-jev-quota-prober.test.sh - Regression test suite for Pattern 9 Quota Prober.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBER="$FM_ROOT/bin/fm-jev-quota-prober.py"
unset FM_QUOTA_AXI_BIN
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-quota-prober.XXXXXX")
FAKEBIN="$LAB/fakebin"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN" "$LAB/home/state"
export FM_HOME="$LAB/home"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ -n "${QUOTA_JSON:-}" ]; then
  printf '%s\n' "$QUOTA_JSON"
  exit 0
fi
if [ "${QUOTA_EMPTY:-0}" = 1 ]; then
  printf '{}\n'
  exit 0
fi
cursor_remaining=50
cursor_runway=through_reset
cursor_stale=false
codex_remaining=50
codex_runway=through_reset
codex_model_remaining=50
codex_model_runway=through_reset
if [ "${CURSOR_EXHAUSTED:-0}" = 1 ]; then
  cursor_remaining=0
  cursor_runway=exhausted_now
fi
if [ "${CURSOR_STALE:-0}" = 1 ]; then
  cursor_stale=true
fi
if [ "${CURSOR_UNKNOWN_RUNWAY:-0}" = 1 ]; then
  cursor_runway=unknown
fi
if [ "${CODEX_EXHAUSTED:-0}" = 1 ]; then
  codex_remaining=0
  codex_runway=exhausted_now
fi
if [ "${CODEX_MODEL_EXHAUSTED:-0}" = 1 ]; then
  codex_model_remaining=0
  codex_model_runway=exhausted_now
fi
second_cursor=
if [ "${CODEX_WORK_ACCOUNT:-0}" = 1 ]; then
  second_cursor='{"provider":"codex","accountKey":"openai-codex-work","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":40,"runway":{"status":"through_reset"}}]}},'
fi
if [ "${CURSOR_SECOND_ACCOUNT_EXHAUSTED:-0}" = 1 ]; then
  second_cursor='{"provider":"cursor","accountKey":"work","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}},'
fi
if [ "${CODEX_DEFAULT_ACCOUNT:-0}" = 1 ]; then
  second_cursor='{"provider":"codex","accountKey":"default","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":40,"runway":{"status":"through_reset"}}]}},'
fi
printf '{"schemaVersion":6,"providers":[%s{"provider":"cursor","accountKey":"default","state":{"status":"fresh","stale":%s},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}},{"provider":"codex","accountKey":"codex-home","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}},{"scope":"model:gpt-5.6-luna","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}}]}\n' \
  "$second_cursor" "$cursor_stale" "$cursor_remaining" "$cursor_runway" "$codex_remaining" "$codex_runway" "$codex_model_remaining" "$codex_model_runway"
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

printf '1. Verify help flag...\n'
"$PROBER" --help >/dev/null 2>&1 || fail "prober --help failed"
ok "help flag works"

printf '2. Verify --check-all output...\n'
output=$("$PROBER" --check-all) || fail "check-all failed"
printf '%s\n' "$output" | grep -q "Fleet Pre-Flight Harness Runway" || fail "missing header in check-all"
printf '%s\n' "$output" | grep -q "cursor-grok-4.6-high.*forbidden" || fail "check-all did not reject Grok"
ok "check-all rejects forbidden Grok lane"

printf '3. Verify --json output format...\n'
json_out=$("$PROBER" --check-all --json) || fail "--check-all --json failed"
echo "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert isinstance(data, list)
assert len(data) >= 3
assert any(d["harness"] == "cursor" for d in data)
grok = next(d for d in data if "grok" in d["model"])
assert grok["healthy"] is False
assert grok["status"] == "forbidden"
assert all("grok" not in d["divert_model"] for d in data)
' || fail "malformed json output"
ok "json output format verified"

printf '4. Verify zai bundle is not dry without evidence...\n'
zai_out=$("$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert) || fail "zai probe without dry evidence failed"
echo "$zai_out" | grep -q "harness=pi model=zai-general/glm-5.3-flash healthy=1" || fail "zai bundle reported dry without marker or outcome evidence"
printf '{"branch":"x","note":"zai-general insufficient balance"}\n' > "$FM_HOME/state/branch-outcomes.jsonl"
"$PROBER" --harness pi --model zai-general/glm-5.3-flash --json >/dev/null || fail "free-form outcome history marked the zai bundle dry"
rm "$FM_HOME/state/branch-outcomes.jsonl"
ok "zai dryness comes only from the explicit marker"

touch "$FM_HOME/state/.zai-bundle-dry"
divert_out=$("$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert) || fail "auto-divert failed"
echo "$divert_out" | grep -q "harness=cursor model=composer-2.5" || fail "failed to divert dry zai bundle"
ok "auto-divert safely redirects to cursor Composer"

printf '5. Verify auto-divert never targets Grok...\n'
if printf '%s\n' "$divert_out" | grep -qi "grok"; then
  fail "auto-divert target must never contain grok"
fi
ok "auto-divert target excludes Grok"

printf '6. Verify exhausted diversion destination is refused...\n'
if divert_out=$(CURSOR_EXHAUSTED=1 "$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert); then
  fail "auto-divert accepted an exhausted destination"
fi
[ -z "$divert_out" ] || fail "exhausted destination emitted a launch profile"
ok "auto-divert refuses exhausted destination"

printf '7. Verify Codex quota semantics drive exhaustion...\n'
if codex_out=$(CODEX_MODEL_EXHAUSTED=1 "$PROBER" --harness codex --model gpt-5.6-luna --json); then
  fail "Codex semantic exhaustion reported healthy"
fi
printf '%s\n' "$codex_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["healthy"] is False
assert data["status"] == "exhausted"
' || fail "Codex semantic exhaustion result was malformed"
ok "Codex quota semantics detect exhaustion"

printf '8. Verify direct Grok launch is forbidden...\n'
if grok_out=$("$PROBER" --harness cursor --model cursor-grok-4.6-high --json); then
  fail "direct Grok launch reported healthy"
fi
printf '%s\n' "$grok_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["healthy"] is False
assert data["status"] == "forbidden"
' || fail "Grok prohibition result was malformed"
ok "direct Grok launch is forbidden"

printf '9. Verify stale destination evidence is refused...\n'
if divert_out=$(CURSOR_STALE=1 "$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert); then
  fail "auto-divert accepted stale destination evidence"
fi
[ -z "$divert_out" ] || fail "stale destination emitted a launch profile"
ok "auto-divert refuses stale destination evidence"

printf '10. Verify unknown destination runway is refused...\n'
if divert_out=$(CURSOR_UNKNOWN_RUNWAY=1 "$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert); then
  fail "auto-divert accepted unknown destination runway"
fi
[ -z "$divert_out" ] || fail "unknown destination runway emitted a launch profile"
ok "auto-divert refuses unknown destination runway"

printf '11. Verify absent quota evidence is unknown, never healthy...\n'
for target in "codex gpt-5.6-luna" "cursor composer-2.5" "pi openai/gpt-5.5"; do
  read -r harness model <<<"$target"
  set -- "$harness" "$model"
  if unknown_out=$(QUOTA_EMPTY=1 "$PROBER" --harness "$1" --model "$2" --json); then
    fail "$1 without quota evidence reported healthy"
  fi
  printf '%s\n' "$unknown_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["healthy"] is False
assert data["status"] == "unknown"
assert data["divert_harness"] == ""
' || fail "$1 unknown-evidence result was malformed"
done
ok "absent quota evidence reports unknown and permits no launch"

printf '12. Verify direct probes require confirmed runway...\n'
"$PROBER" --harness cursor --model composer-2.5 --json >/dev/null || fail "fresh confirmed cursor runway reported unhealthy"
for env in CURSOR_UNKNOWN_RUNWAY CURSOR_STALE; do
  if env "$env=1" "$PROBER" --harness cursor --model composer-2.5 --json >/dev/null; then
    fail "cursor probe with $env reported healthy"
  fi
done
CURSOR_SECOND_ACCOUNT_EXHAUSTED=1 "$PROBER" --harness cursor --model composer-2.5 --json >/dev/null ||
  fail "an exhausted sibling account blocked the healthy default cursor lane"
divert_out=$(CURSOR_SECOND_ACCOUNT_EXHAUSTED=1 "$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert) ||
  fail "an exhausted sibling account withheld the Composer diversion"
echo "$divert_out" | grep -q "harness=cursor model=composer-2.5" || fail "sibling account changed the diversion"
ok "direct probes refuse unconfirmed runway and judge only their own account"

printf '13. Verify Pi models need their own provider evidence...\n'
if pi_out=$("$PROBER" --harness pi --model openai/gpt-5.5 --json); then
  fail "Pi openai model reported healthy from unrelated provider evidence"
fi
printf '%s\n' "$pi_out" | python3 -c '
import json, sys
assert json.load(sys.stdin)["status"] == "unknown"
' || fail "Pi unrelated-evidence result was malformed"
if pi_out=$("$PROBER" --harness pi --model codex/gpt-5.6-luna --json); then
  fail "Pi provider lane bound to an unrelated codex account by row order"
fi
printf '%s\n' "$pi_out" | python3 -c '
import json, sys
assert json.load(sys.stdin)["status"] == "unknown"
' || fail "Pi unbound-account result was malformed"
CODEX_EXHAUSTED=1 CODEX_DEFAULT_ACCOUNT=1 "$PROBER" --harness pi --model codex/gpt-5.6-luna --json >/dev/null ||
  fail "Pi provider lane did not bind to its provider's default account"
if CODEX_EXHAUSTED=1 "$PROBER" --harness pi --model openai-codex-work/gpt-5.6-terra --json >/dev/null; then
  fail "Pi account lane without its own row reported healthy"
fi
CODEX_EXHAUSTED=1 CODEX_WORK_ACCOUNT=1 "$PROBER" --harness pi --model openai-codex-work/gpt-5.6-terra --json >/dev/null ||
  fail "Pi account lane did not bind to its own codex account row"
ok "Pi models are judged by their own provider or account evidence"

printf '12. Verify null credits yield a structured result, not a traceback...\n'
for credits in 'null' '{"remaining":null}'; do
  row='{"provider":"codex","credits":'"$credits"',"state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}'
  null_out=$(QUOTA_JSON='{"schemaVersion":5,"providers":['"$row"']}' "$PROBER" --harness codex --model gpt-5.6-luna --json 2>&1) \
    || fail "codex with credits $credits did not report healthy: $null_out"
  printf '%s\n' "$null_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["healthy"] is True
assert data["status"] == "healthy"
' || fail "codex with credits $credits returned a malformed result: $null_out"
done
ok "null credits are treated as missing evidence"

printf '13. Verify auto-divert reports the lane status...\n'
status_out=$(CODEX_EXHAUSTED=1 "$PROBER" --harness codex --model gpt-5.6-luna --auto-divert) || fail "exhausted codex did not divert"
[ "$status_out" = "harness=cursor model=composer-2.5 healthy=0 status=exhausted" ] || fail "unexpected auto-divert line: $status_out"
unknown_rc=0
QUOTA_EMPTY=1 "$PROBER" --harness codex --model gpt-5.6-luna --auto-divert >/dev/null 2>&1 || unknown_rc=$?
[ "$unknown_rc" = 3 ] || fail "unknown lane without diversion should exit 3, got $unknown_rc"
ok "auto-divert reports status and distinguishes unknown from doomed"

printf '14. Verify a quota measurement error is unknown and never diverts...\n'
error_json='{"schemaVersion":5,"providers":[{"provider":"codex","state":{"status":"fresh","stale":false,"error":"fetch timed out"},"quotaSemantics":{"status":"known","effectiveAvailability":[]}},{"provider":"cursor","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}'
error_out=$(QUOTA_JSON="$error_json" "$PROBER" --harness codex --model gpt-5.6-luna --json) && fail "codex quota error reported healthy"
printf '%s\n' "$error_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["status"] == "unknown", data
assert data["divert_harness"] == "", data
' || fail "codex quota error result was not unknown without diversion: $error_out"
error_rc=0
QUOTA_JSON="$error_json" "$PROBER" --harness codex --model gpt-5.6-luna --auto-divert >/dev/null 2>&1 || error_rc=$?
[ "$error_rc" = 3 ] || fail "codex quota error with --auto-divert should exit 3, got $error_rc"
ok "quota measurement errors are unknown and never divert"

printf '15. Verify a credit-exhausted safe lane is never offered as a diversion...\n'
credits_json='{"schemaVersion":5,"providers":[{"provider":"codex","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}},{"provider":"cursor","credits":{"remaining":0},"state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}'
for target in "cursor composer-2.5" "codex gpt-5.6-luna"; do
  read -r h m <<<"$target"
  credit_rc=0
  QUOTA_JSON="$credits_json" "$PROBER" --harness "$h" --model "$m" --auto-divert >/dev/null 2>&1 || credit_rc=$?
  [ "$credit_rc" = 1 ] || fail "$h with a credit-exhausted cursor lane should refuse (exit 1), got $credit_rc"
done
same_rc=0
CURSOR_EXHAUSTED=1 "$PROBER" --harness cursor --model cursor/composer-2.5 --auto-divert >/dev/null 2>&1 || same_rc=$?
[ "$same_rc" = 1 ] || fail "an exhausted safe lane diverted to itself (exit $same_rc)"
ok "no diversion into a credit-exhausted or the requested lane"

printf '16. Verify raw launch words never pollute model scoping...\n'
scan_out=$(CODEX_MODEL_EXHAUSTED=1 "$PROBER" --harness codex --model gpt-5.6-luna --scan "codex brief.md" --auto-divert) || fail "model-scoped exhaustion with scan words did not divert"
[ "$scan_out" = "harness=cursor model=composer-2.5 healthy=0 status=exhausted" ] || fail "scan words hid model-scoped exhaustion: $scan_out"
scan_json=$("$PROBER" --harness codex --model gpt-5.6-luna --scan "grok --model grok-4" --json) && fail "Grok raw launch words were not refused"
printf '%s\n' "$scan_json" | grep -q '"status": "forbidden"' || fail "Grok raw launch words not forbidden: $scan_json"
ok "scan words only feed the Grok check"

printf 'ok - all fm-jev-quota-prober tests passed\n'
