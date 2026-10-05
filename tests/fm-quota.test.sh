#!/usr/bin/env bash
# Behavioral coverage for Codex native quota and TraeX model load reads.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-quota.mjs"
TMP_ROOT=$(fm_test_tmproot fm-quota)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

write_codex() {
  cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
set -eu
while IFS= read -r line; do
  printf '%s\n' "$line" >> "${FM_QUOTA_CODEX_CALLS:?}"
  id=$(printf '%s\n' "$line" | jq -r '.id // empty')
  case "$id" in
    fm-quota-initialize)
      printf '%s\n' '{"id":"fm-quota-initialize","result":{"userAgent":"fixture"}}'
      ;;
    fm-quota-read)
      printf '%s\n' '{"id":"fm-quota-read","result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":1767225600},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"42"}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"pro","primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":1767225600},"secondary":null}},"rateLimitResetCredits":{"availableCount":2}}}'
      ;;
  esac
done
SH
  chmod +x "$FAKEBIN/codex"
}

write_traex() {
  cat > "$FAKEBIN/traex" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = models ] && [ "${2:-}" = --json ] || exit 2
printf '%s\n' '[{"name":"GPT-Loaded","config_name":"gpt-loaded","backend_model":"gpt-loaded__dev","provider":"trae","_meta":{"trae":{"load":{"percent":170}}}},{"name":"No-Load","config_name":"no-load","backend_model":"no-load__dev","provider":"trae","_meta":{"trae":{}}}]'
SH
  chmod +x "$FAKEBIN/traex"
}

write_codex
write_traex
CALLS="$TMP_ROOT/codex.calls"
: > "$CALLS"

json=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_CODEX_CALLS="$CALLS" "$TOOL" --json)
[ "$(printf '%s\n' "$json" | jq -r '.schema')" = fm-quota-v1 ] || fail "structured output omitted its schema"
[ "$(printf '%s\n' "$json" | jq -r '.status')" = partial ] || fail "missing TraeX load did not make the combined result partial"
[ "$(printf '%s\n' "$json" | jq -r '.providers.codex.rate_limits[0].primary.used_percent')" = 17 ] || fail "Codex used percent was not retained"
[ "$(printf '%s\n' "$json" | jq -r '.providers.codex.rate_limits[0].primary.resets_at')" = 2026-01-01T00:00:00.000Z ] || fail "Codex reset instant was not retained canonically"
[ "$(printf '%s\n' "$json" | jq -r '.providers.traex.models[0].load_percent')" = 170 ] || fail "TraeX load above 100 was clamped or lost"
[ "$(printf '%s\n' "$json" | jq -r '.providers.traex.models[1].load_percent')" = null ] || fail "missing TraeX load was fabricated"
[ "$(printf '%s\n' "$json" | jq -r '.providers.traex.models[1].load_available')" = false ] || fail "missing TraeX load was not distinguished"
assert_contains "$(cat "$CALLS")" '"method":"initialize"' "Codex initialize was not sent"
assert_contains "$(cat "$CALLS")" '"method":"initialized"' "Codex initialized notification was not sent"
assert_contains "$(cat "$CALLS")" '"method":"account/rateLimits/read"' "Codex rate-limit read was not sent"
assert_not_contains "$(cat "$CALLS")" 'thread/' "quota read started a Codex thread"
pass "structured output preserves native quota, canonical resets, high load, and missing load"

: > "$CALLS"
human=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_CODEX_CALLS="$CALLS" "$TOOL" --provider codex)
assert_contains "$human" "resets 2026-01-01 08:00:00 UTC+8" "human reset display was not UTC+8"
assert_contains "$human" "17% used" "human Codex quota was not rendered"
pass "human output displays Codex reset time in UTC+8"

: > "$CALLS"
selected=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_CODEX_CALLS="$CALLS" "$TOOL" --json --provider traex --model gpt-loaded)
[ "$(printf '%s\n' "$selected" | jq -r '.providers.traex.models | length')" = 1 ] || fail "TraeX model selection returned extra models"
[ "$(printf '%s\n' "$selected" | jq -r '.providers.traex.models[0].name')" = GPT-Loaded ] || fail "config-name selection changed model identity"
[ "$(printf '%s\n' "$selected" | jq -r '.providers.traex.models[0].load_percent')" = 170 ] || fail "selected model lost its load"
[ ! -s "$CALLS" ] || fail "TraeX-only selection invoked Codex"
pass "provider and model selection query only the requested native surface"

missing=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_CODEX_CALLS="$CALLS" "$TOOL" --provider traex --model No-Load)
assert_contains "$missing" "No-Load: unavailable" "missing model load was displayed as a number"
pass "human output reports missing load as unavailable"

cat > "$FAKEBIN/traex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'provider unavailable' >&2
exit 42
SH
chmod +x "$FAKEBIN/traex"
: > "$CALLS"
set +e
PATH="$FAKEBIN:$PATH" FM_QUOTA_CODEX_CALLS="$CALLS" "$TOOL" --json > "$TMP_ROOT/partial.json"
partial_rc=$?
set -e
[ "$partial_rc" -eq 1 ] || fail "provider failure did not produce exit 1"
[ "$(jq -r '.status' "$TMP_ROOT/partial.json")" = partial ] || fail "one-provider failure was not reported as partial"
[ "$(jq -r '.providers.codex.status' "$TMP_ROOT/partial.json")" = ok ] || fail "successful Codex result was lost beside TraeX failure"
[ "$(jq -r '.providers.traex.status' "$TMP_ROOT/partial.json")" = unavailable ] || fail "failed TraeX provider was reported as successful"
[ "$(jq -r '.providers.traex.models // "absent"' "$TMP_ROOT/partial.json")" = absent ] || fail "failed TraeX provider exposed stale model data"
pass "provider failure returns partial live evidence without stale success"

cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$$" > "${FM_QUOTA_HANG_PID:?}"
IFS= read -r _
while :; do sleep 1; done
SH
chmod +x "$FAKEBIN/codex"
set +e
PATH="$FAKEBIN:$PATH" FM_QUOTA_TIMEOUT_MS=150 FM_QUOTA_HANG_PID="$TMP_ROOT/hang.pid" \
  "$TOOL" --json --provider codex > "$TMP_ROOT/timeout.json"
timeout_rc=$?
set -e
[ "$timeout_rc" -eq 1 ] || fail "timed-out Codex child did not produce exit 1"
[ "$(jq -r '.providers.codex.status' "$TMP_ROOT/timeout.json")" = unavailable ] || fail "timed-out Codex child was reported as successful"
hang_pid=$(cat "$TMP_ROOT/hang.pid")
tries=0
while kill -0 "$hang_pid" 2>/dev/null && [ "$tries" -lt 20 ]; do
  sleep 0.05
  tries=$((tries + 1))
done
if kill -0 "$hang_pid" 2>/dev/null; then
  kill -KILL "$hang_pid" 2>/dev/null || true
  fail "timed-out Codex child remained alive"
fi
pass "timed-out provider child is reaped without touching another process"
