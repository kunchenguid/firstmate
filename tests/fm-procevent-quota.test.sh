#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-quota.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-quota.XXXXXX")
FAKEBIN="$LAB/fakebin"
NO_QUOTA_BIN="$LAB/no-quota-bin"
COUNT="$LAB/count"
VERSION_COUNT="$LAB/version-count"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN" "$NO_QUOTA_BIN"
for command_name in dirname jq mkdir sleep; do
  ln -s "$(command -v "$command_name")" "$NO_QUOTA_BIN/$command_name"
done

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  vcount=0
  [ -z "${QUOTA_AXI_VERSION_COUNT:-}" ] || [ ! -f "$QUOTA_AXI_VERSION_COUNT" ] || read -r vcount < "$QUOTA_AXI_VERSION_COUNT"
  vcount=$((vcount + 1))
  [ -z "${QUOTA_AXI_VERSION_COUNT:-}" ] || printf '%s\n' "$vcount" > "$QUOTA_AXI_VERSION_COUNT"
  if [ -n "${QUOTA_AXI_VERSION_OK_COUNT:-}" ] && [ "$vcount" -gt "$QUOTA_AXI_VERSION_OK_COUNT" ]; then
    case "${QUOTA_AXI_VERSION_LATER:-fail}" in
      slow) sleep 10 ;;
      *) exit 42 ;;
    esac
  fi
  if [ "${QUOTA_AXI_SLOW_VERSION:-0}" = 1 ]; then
    sleep 10
  fi
  if [ "${QUOTA_AXI_VERSION_FAIL:-0}" = 1 ]; then
    exit 42
  fi
  printf 'quota-axi %s\n' "${QUOTA_AXI_VERSION:-0.1.51}"
  exit 0
fi
case "${QUOTA_AXI_MALFORMED:-}" in
  schema)
    printf '{"schemaVersion":4,"providers":[]}\n'
    exit 0
    ;;
  duplicate)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}},{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}\n'
    exit 0
    ;;
  types)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":"0","runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  range)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":150,"runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  runway)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"invalid"}}]}}]}\n'
    exit 0
    ;;
  availability)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"typo","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}},{"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  known-empty)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[]}}]}\n'
    exit 0
    ;;
  malformed-unknown-row)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[{"scope":"all_models","status":"known"}]}}]}\n'
    exit 0
    ;;
  auth-required-agy)
    printf '{"schemaVersion":5,"providers":[{"provider":"agy","state":{"status":"auth_required","error":"Antigravity sign-in required"},"quotaSemantics":{"status":"unknown","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n'
    exit 0
    ;;
  identity)
    printf '{"schemaVersion":5,"providers":[{"provider":" codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n'
    exit 0
    ;;
  schema6-keyless)
    printf '{"schemaVersion":6,"providers":[{"provider":"codex","accountKey":"openai-codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}},{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}\n'
    exit 0
    ;;
  schema6-duplicate)
    printf '{"schemaVersion":6,"providers":[{"provider":"codex","accountKey":"openai-codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}},{"provider":"codex","accountKey":"openai-codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}\n'
    exit 0
    ;;
esac
# Schema 6: an expanded provider (codex, two Pi lanes) puts one provider id on
# two rows keyed by accountKey; the schema 5 pair is the same state from an
# older quota-axi that only knows one codex account.
if [ "${QUOTA_AXI_SCHEMA6:-0}" = 1 ]; then
  printf '{"schemaVersion":6,"providers":[{"provider":"codex","accountKey":"openai-codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":3,"runway":{"status":"projected_exhaustion"}}]}},{"provider":"codex","accountKey":"openai-codex-work","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}},{"provider":"cursor","accountKey":"default","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_SCHEMA5_PAIR:-0}" = 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":3,"runway":{"status":"projected_exhaustion"}}]}},{"provider":"cursor","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_EXHAUSTED_DETAIL:-0}" = 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"exhausted_now"}},{"scope":"model:foo","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_UNKNOWN_EXHAUSTED:-0}" = 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_ALWAYS_SLOW:-0}" = 1 ] && [ "${1:-}" != "--version" ]; then
  sleep 10
fi
count=0
[ ! -f "$QUOTA_AXI_COUNT" ] || read -r count < "$QUOTA_AXI_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$QUOTA_AXI_COUNT"
if [ "${QUOTA_AXI_SLOW_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ] && [ "${1:-}" != "--version" ]; then
  sleep 10
fi
# Two immediate JSON failures, then one timeout: wording must not claim three slow reads.
if [ "${QUOTA_AXI_FAIL_THEN_SLOW:-0}" = 1 ] && [ "${1:-}" != "--version" ]; then
  if [ "$count" -le 2 ]; then
    exit 42
  fi
  sleep 10
fi
# Reset-streak sequence: timeouts on 1/2/4/5, healthy on 3, exhausted on 6+.
# Without consecutive_failures=0 after a good read, poll 4 would go terminal.
if [ "${QUOTA_AXI_RESET_STREAK:-0}" = 1 ]; then
  case "$count" in
    1|2|4|5)
      sleep 10
      ;;
    3)
      printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":20,"runway":{"status":"through_reset"}}]}}]}\n'
      exit 0
      ;;
    *)
      printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n'
      exit 0
      ;;
  esac
fi
if [ "${QUOTA_AXI_UNKNOWN_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_KNOWN_UNKNOWN_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"unknown"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_EMPTY_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  printf '{"schemaVersion":5,"providers":[]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_AT_THRESHOLD:-0}" = 1 ]; then
  if [ "$count" -eq 1 ]; then
    remaining=10
  else
    remaining=9
  fi
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"through_reset"}}]}}]}\n' "$remaining"
  exit 0
fi
# After a first timed-out slow read (count already advanced), the next read is
# healthy and the one after that exhausts so the poll can prove it stayed live.
if [ "${QUOTA_AXI_SLOW_FIRST:-0}" = 1 ]; then
  if [ "$count" -eq 2 ]; then
    model_remaining=20
    runway=through_reset
  else
    model_remaining=0
    runway=exhausted_now
  fi
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":20,"runway":{"status":"through_reset"}},{"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}}]}\n' "$model_remaining" "$runway"
  exit 0
fi
if [ "$count" -eq 1 ]; then
  model_remaining=20
  runway=through_reset
else
  model_remaining=0
  runway=exhausted_now
fi
printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":20,"runway":{"status":"through_reset"}},{"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}},{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}\n' "$model_remaining" "$runway"
SH
chmod +x "$FAKEBIN/quota-axi"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

if help=$("$BIN/fm-procevent-quota.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-quota.sh retire [--provider <provider>]' \
  || fail "help omitted the retire usage"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders only the complete header"

out=$(QUOTA_AXI_EXHAUSTED_DETAIL=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll)
printf '%s\n' "$out" | grep -qx 'status: exhausted' \
  || fail "default aggregate poll did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'quota: quota' \
  || fail "default aggregate poll did not use the aggregate source"
ok "poll accepts its documented defaults"

out=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "provider watch did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "provider watch did not wait through the healthy poll"
ok "provider watch blocks until a model scope is exhausted"

out=$(QUOTA_AXI_EXHAUSTED_DETAIL=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '
  .best.scope == "all_models" and
  .best.runway.status == "exhausted_now"
' >/dev/null || fail "exhausted poll recorded non-triggering detail: $detail"
ok "exhausted poll records the triggering scope"

out=$(QUOTA_AXI_UNKNOWN_EXHAUSTED=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' \
  || fail "unknown headroom with exhausted runway did not wake as exhausted"
ok "poll detects exhausted runway under unknown headroom"

rm -f "$COUNT"
out=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider '' --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "aggregate watch did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "aggregate watch did not evaluate all providers"
ok "aggregate watch blocks until any scope is exhausted"

rm -f "$COUNT"
out=$(QUOTA_AXI_EMPTY_FIRST=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider '' --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "empty aggregate quota did not continue polling"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "empty aggregate quota stopped early"
ok "aggregate watch preserves empty quota uncertainty"

if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --provider 2>&1); then
  fail "missing provider value unexpectedly armed a watch"
fi
[ "$err" = "error: --provider needs a value" ] || fail "missing provider value returned: $err"
ok "arm rejects a missing provider value"

for provider in -- codex-; do
  if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --provider "$provider" 2>&1); then
    fail "noncanonical provider unexpectedly armed a watch: $provider"
  fi
  [ "$err" = "error: invalid provider: $provider" ] || fail "noncanonical provider returned: $err"
done
ok "arm rejects noncanonical provider identities"

out=$(FM_HOME="$LAB/retire-home" FM_STATE_OVERRIDE="$LAB/retire-state" \
  "$BIN/fm-procevent-quota.sh" retire --provider codex)
[ "$out" = "retired: quota-codex" ] || fail "provider retire targeted the wrong source: $out"
ok "provider retire resolves the armed source id"

if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 100.5 --provider codex --timeout 1 2>&1); then
  fail "threshold above 100 unexpectedly started polling"
fi
[ "$err" = "error: --threshold needs a percent 0-100" ] || fail "invalid threshold returned: $err"
ok "poll rejects a decimal threshold above 100"

rm -f "$COUNT"
out=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 010 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "leading-zero threshold did not evaluate quota"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "leading-zero threshold stopped before exhaustion"
ok "poll accepts a leading-zero threshold"

rm -f "$COUNT"
out=$(QUOTA_AXI_AT_THRESHOLD=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: low' || fail "quota below the threshold did not report low"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "quota at the threshold fired before dropping below it"
ok "poll fires only after quota drops below the threshold"

if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --provider 2>&1); then
  fail "missing poll provider value unexpectedly succeeded"
fi
[ "$err" = "error: --provider needs a value" ] || fail "missing poll provider returned: $err"
ok "poll rejects a missing option value"

rm -f "$COUNT"
out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "bash timeout fallback did not poll quota"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "bash timeout fallback stopped before exhaustion"
ok "quota polling uses the shared bash timeout fallback"

for malformed in schema duplicate types range runway availability known-empty malformed-unknown-row identity; do
  out=$(QUOTA_AXI_MALFORMED="$malformed" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
  printf '%s\n' "$out" | grep -qx 'status: error' || fail "$malformed snapshot did not report an error"
  printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "$malformed snapshot did not stop immediately"
done
ok "poll rejects malformed schema-five snapshots"

for malformed in schema6-keyless schema6-duplicate; do
  out=$(QUOTA_AXI_MALFORMED="$malformed" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
  printf '%s\n' "$out" | grep -qx 'status: error' || fail "$malformed snapshot did not report an error"
  printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "$malformed snapshot did not stop immediately"
done
ok "poll rejects schema-six snapshots missing or repeating an account key"

out=$(QUOTA_AXI_SCHEMA6=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider '' --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "schema 6 aggregate watch did not report the exhausted account"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "schema 6 aggregate watch did not fire on the first poll"
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '
  [.summary[] | select(.provider == "codex") | .accountKey] == ["openai-codex", "openai-codex-work"] and
  ([.summary[] | select(.accountKey == "openai-codex-work") | .best.runway.status] == ["exhausted_now"]) and
  ([.summary[] | select(.accountKey == "openai-codex") | .best.effectivePercentRemaining] == [3])
' >/dev/null || fail "schema 6 aggregate detail did not keep each account separate: $detail"
ok "aggregate watch reads every schema 6 account row without combining them"

out=$(QUOTA_AXI_SCHEMA6=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider cursor --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: low' || fail "schema 6 provider watch included another provider's exhausted account"
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '.provider == "cursor" and .accountKey == "default" and .best.effectivePercentRemaining == 5' >/dev/null \
  || fail "schema 6 provider detail did not name the default account: $detail"
out=$(QUOTA_AXI_SCHEMA6=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "expanded provider watch did not report the exhausted account"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "expanded provider watch did not stop immediately"
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '
  .provider == "codex" and
  (.summary | length) == 2 and
  all(.summary[]; .provider == "codex") and
  ([.summary[] | select(.accountKey == "openai-codex") | .best.effectivePercentRemaining] == [3]) and
  ([.summary[] | select(.accountKey == "openai-codex-work") | .best.runway.status] == ["exhausted_now"])
' >/dev/null || fail "provider watch did not preserve independent account evidence: $detail"
ok "provider watch classifies every matching account and preserves accountKey in details"

out=$(QUOTA_AXI_SCHEMA5_PAIR=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: low' || fail "schema 5 provider watch did not bind the keyless codex row"
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '.provider == "codex" and (has("accountKey") | not) and .best.effectivePercentRemaining == 3' >/dev/null \
  || fail "schema 5 provider detail changed shape: $detail"
ok "the same path still binds a schema 5 row by provider alone"

rm -f "$COUNT"
out=$(QUOTA_AXI_UNKNOWN_FIRST=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "unknown quota did not continue to exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "unknown quota stopped polling"
ok "poll preserves provider-level unknown quota"

rm -f "$COUNT"
out=$(QUOTA_AXI_KNOWN_UNKNOWN_FIRST=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "known semantics with unknown headroom did not continue polling"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "known semantics with unknown headroom stopped early"
ok "poll preserves unknown headroom under known semantics"

out=$(QUOTA_AXI_MALFORMED=auth-required-agy QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider agy --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "auth-required AGY quota unexpectedly triggered a wake"
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '.best == null and .error == "Antigravity sign-in required"' >/dev/null || fail "auth-required AGY detail hid the authentication cause: $detail"
out=$(QUOTA_AXI_MALFORMED=auth-required-agy QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "aggregate auth-required AGY quota did not surface an error"
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '.summary[0].best == null and .summary[0].error == "Antigravity sign-in required"' >/dev/null || fail "aggregate auth-required AGY detail hid the authentication cause: $detail"
ok "auth-required AGY stays out of wake classification and surfaces its cause"

printf '# all fm-procevent-quota tests passed\n'
