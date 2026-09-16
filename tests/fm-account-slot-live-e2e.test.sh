#!/usr/bin/env bash
# Opt-in, prompt-free live verification for two Claude and two Codex profiles.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_ACCOUNT_SLOT_LIVE_E2E quota-axi jq

real_quota=$(command -v quota-axi) || fail "quota-axi is unavailable"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$ROOT/bin/fm-quota-axi-lib.sh"
fm_quota_axi_probe_capability || fail "$FM_QUOTA_AXI_CAPABILITY_ERROR"

REGISTRY="${FM_HOME:-$ROOT}/config/account-slots.json"
[ -f "$REGISTRY" ] || fail "FM_ACCOUNT_SLOT_LIVE_E2E requires a provisioned config/account-slots.json"

slots=$(jq -r '
  [.slots | to_entries[] | select(.value.harness == "claude") | .key][0:2] +
  [.slots | to_entries[] | select(.value.harness == "codex") | .key][0:2] | .[]
' "$REGISTRY") || fail "account slot registry could not be read"
assert_equals 4 "$(printf '%s\n' "$slots" | grep -c . | tr -d ' ')" "live check requires two Claude and two Codex slots"
slot_args=()
while IFS= read -r slot; do
  [ -n "$slot" ] || continue
  slot_args+=("$slot")
done <<< "$slots"

identity_counts=$(jq -r '
  [
    ([.slots[] | select(.harness == "claude") | .expectedAccountId] | unique | length),
    ([.slots[] | select(.harness == "codex") | .expectedAccountId] | unique | length)
  ] | @tsv
' "$REGISTRY") || fail "configured expected identities could not be compared"
assert_equals $'2\t2' "$identity_counts" "each provider's two slots must name distinct expected identities"

lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-account-slot-live.XXXXXX") || fail "temporary live-check directory could not be created"
trap 'rm -rf "$lab"' EXIT
mkdir -p "$lab/bin"
calls="$lab/calls"
: > "$calls"
cat > "$lab/bin/quota-axi" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --no-credential-refresh '*)
    provider=unknown
    prior=
    for arg in "$@"; do
      if [ "$prior" = --provider ]; then provider=$arg; break; fi
      prior=$arg
    done
    printf '%s\n' "$provider" >> "${FM_ACCOUNT_SLOT_LIVE_CALLS:?}"
    ;;
esac
exec "${FM_ACCOUNT_SLOT_REAL_QUOTA:?}" "$@"
SH
chmod +x "$lab/bin/quota-axi"

output="$lab/sanitized.json"
if ! fm_run_timed 120 env PATH="$lab/bin:$PATH" FM_ACCOUNT_SLOT_REAL_QUOTA="$real_quota" \
    FM_ACCOUNT_SLOT_LIVE_CALLS="$calls" FM_HOME="${FM_HOME:-$ROOT}" \
    "$ROOT/bin/fm-account-slot.sh" probe-all "${slot_args[@]}" > "$output"; then
  fail "four-profile account-slot probe failed"
fi

assert_equals 4 "$(wc -l < "$calls" | tr -d ' ')" "live check did not invoke exactly four single-provider quota probes"
assert_equals 2 "$(grep -c '^claude$' "$calls" | tr -d ' ')" "live check did not invoke two Claude slot probes"
assert_equals 2 "$(grep -c '^codex$' "$calls" | tr -d ' ')" "live check did not invoke two Codex slot probes"

jq -e '.slots | length == 4 and all(.[]; .providers | length == 1) and all(.[]; .providers[0].state.status == "fresh" and .providers[0].state.stale == false)' \
  "$output" >/dev/null || fail "sanitized live evidence did not contain four fresh provider rows"
jq -e 'any(.. | objects; has("account") or has("attempts") or has("source") or has("storePath"))' "$output" >/dev/null 2>&1 \
  && fail "sanitized live output contains private account or provenance fields"

jq -r '.slots[] | [.accountSlot,.providers[0].provider,(.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining // "unknown"),(.providers[0].quotaSemantics.effectiveAvailability[0].runway.status // "unknown"),"pass"] | @tsv' "$output"
printf 'ok - four account slots returned fresh isolated quota evidence\n'
