#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-quota.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-quota.XXXXXX")
FAKEBIN="$LAB/fakebin"
COUNT="$LAB/count"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'quota-axi 0.1.29\n'
  exit 0
fi
if [ -n "${QUOTA_AXI_ARGV_LOG:-}" ]; then
  printf 'CODEX_HOME=%s\n' "${CODEX_HOME-<unset>}" >> "$QUOTA_AXI_ARGV_LOG"
  printf 'argv=%s\n' "$*" >> "$QUOTA_AXI_ARGV_LOG"
fi
if [ "${QUOTA_AXI_PER_HOME:-0}" = 1 ]; then
  # The ambient account (no CODEX_HOME) is exhausted; the selected account
  # starts healthy and drops below 10% on its second read.
  if [ -z "${CODEX_HOME:-}" ]; then
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n'
    exit 0
  fi
  count=0
  [ ! -f "$QUOTA_AXI_COUNT" ] || read -r count < "$QUOTA_AXI_COUNT"
  count=$((count + 1))
  printf '%s\n' "$count" > "$QUOTA_AXI_COUNT"
  if [ "$count" -eq 1 ]; then remaining=90; else remaining=5; fi
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"through_reset"}}]}}]}\n' "$remaining"
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
  semantics-mismatch)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  identity)
    printf '{"schemaVersion":5,"providers":[{"provider":" codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n'
    exit 0
    ;;
esac
if [ "${QUOTA_AXI_EXHAUSTED_DETAIL:-0}" = 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"exhausted_now"}},{"scope":"model:foo","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_UNKNOWN_EXHAUSTED:-0}" = 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]}}]}\n'
  exit 0
fi
count=0
[ ! -f "$QUOTA_AXI_COUNT" ] || read -r count < "$QUOTA_AXI_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$QUOTA_AXI_COUNT"
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

RETIRE_HOME="$LAB/retire-home"
RETIRE_STATE="$LAB/retire-state"
(umask 077; mkdir -p "$RETIRE_HOME" "$RETIRE_STATE")
out=$(FM_HOME="$RETIRE_HOME" FM_STATE_OVERRIDE="$RETIRE_STATE" \
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

for malformed in schema duplicate types range runway availability known-empty semantics-mismatch identity; do
  out=$(QUOTA_AXI_MALFORMED="$malformed" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
  printf '%s\n' "$out" | grep -qx 'status: error' || fail "$malformed snapshot did not report an error"
  printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "$malformed snapshot did not stop immediately"
done
ok "poll rejects malformed schema-five snapshots"

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

# --- Codex account axis (--codex-home) ---------------------------------------
# A Codex account is a directory holding that account's auth.json. Fixtures use
# placeholder files only; no real credential is ever read or copied.
make_codex_account() {  # <dir>
  mkdir -p "$1"
  printf '%s\n' '{"placeholder":"fixture"}' > "$1/auth.json"
}
ARGV_LOG="$LAB/quota-axi.argv"
ACCT="$LAB/accounts/.codex-1"
make_codex_account "$ACCT"

rm -f "$COUNT" "$ARGV_LOG"
out=$(QUOTA_AXI_PER_HOME=1 QUOTA_AXI_ARGV_LOG="$ARGV_LOG" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --codex-home "$ACCT" --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: low' || fail "codex-home watch did not report the selected account as low: $out"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "codex-home watch fired on the exhausted ambient account instead of its own: $out"
printf '%s\n' "$out" | grep -qx "codex_home: $ACCT" || fail "codex-home watch did not record the account it tracked: $out"
grep -qx "CODEX_HOME=$ACCT" "$ARGV_LOG" || fail "quota-axi was not read under the selected account's CODEX_HOME: $(cat "$ARGV_LOG")"
if grep -qx 'CODEX_HOME=<unset>' "$ARGV_LOG"; then
  fail "codex-home watch read the ambient account: $(cat "$ARGV_LOG")"
fi
grep -qx 'argv=--provider codex --json' "$ARGV_LOG" || fail "codex-home read did not name the codex provider: $(cat "$ARGV_LOG")"
source_id=$(printf '%s\n' "$out" | sed -n 's/^quota: //p')
case "$source_id" in
  quota-codex-codex-1-????????) ;;
  *) fail "codex-home watch did not derive a per-account source id: $source_id" ;;
esac
[ "$("$BIN/fm-procevent-quota.sh" source-id --provider codex --codex-home "$ACCT")" = "$source_id" ] \
  || fail "source-id did not resolve the same per-account id the poll reported"
ok "codex-home watch polls the selected account under its own CODEX_HOME and source id"

acct_alias="$LAB/accounts/codex-account-alias"
ln -s "$ACCT" "$acct_alias"
alias_source_id=$("$BIN/fm-procevent-quota.sh" source-id --provider codex --codex-home "$acct_alias")
[ "$alias_source_id" = "$source_id" ] \
  || fail "a symlink alias for one account produced a duplicate source id: $alias_source_id"
ok "codex-home watch canonicalizes aliases to one account identity"

rm -f "$COUNT" "$ARGV_LOG"
out=$(QUOTA_AXI_PER_HOME=1 QUOTA_AXI_ARGV_LOG="$ARGV_LOG" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "provider watch without --codex-home did not track the ambient account: $out"
printf '%s\n' "$out" | grep -qx 'quota: quota-codex' || fail "provider watch without --codex-home changed its source id: $out"
if printf '%s\n' "$out" | grep -q '^codex_home: '; then
  fail "provider watch without --codex-home reported an account: $out"
fi
grep -qx 'CODEX_HOME=<unset>' "$ARGV_LOG" || fail "provider watch without --codex-home exported a CODEX_HOME: $(cat "$ARGV_LOG")"
grep -qx 'argv=--json' "$ARGV_LOG" || fail "provider watch without --codex-home changed its quota-axi argv: $(cat "$ARGV_LOG")"
ok "provider watch without --codex-home still reads the ambient account exactly as before"

rm -f "$COUNT" "$ARGV_LOG"
user_home="$LAB/user-home"
make_codex_account "$user_home/.codex-2"
# shellcheck disable=SC2088  # the literal ~/ spelling is the input under test
out=$(HOME="$user_home" QUOTA_AXI_PER_HOME=1 QUOTA_AXI_ARGV_LOG="$ARGV_LOG" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --codex-home '~/.codex-2' --timeout 1)
printf '%s\n' "$out" | grep -qx "codex_home: $user_home/.codex-2" || fail "a ~/ codex home was not expanded against HOME: $out"
grep -qx "CODEX_HOME=$user_home/.codex-2" "$ARGV_LOG" || fail "quota-axi did not receive the expanded ~/ home: $(cat "$ARGV_LOG")"
ok "codex-home watch expands ~/ against the polling user's HOME"

ARM_HOME="$LAB/arm-home"
mkdir -p "$ARM_HOME" && mkdir -m 700 "$ARM_HOME/state"
out=$(FM_HOME="$ARM_HOME" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" arm --interval 30 --threshold 15 --provider codex --codex-home "$ACCT") \
  || fail "arm with a valid --codex-home refused: $out"
printf '%s\n' "$out" | grep -qx "armed: $source_id" || fail "arm did not register the per-account source id: $out"
printf '%s\n' "$out" | grep -qx "codex_home: $ACCT" || fail "arm did not report the tracked account: $out"
reg="$ARM_HOME/state/procevent/$source_id.source"
[ -f "$reg" ] || fail "arm did not publish the per-account registration at $reg"
grep -qx -- '--codex-home' "$reg" || fail "registered poll argv carries no --codex-home: $(cat "$reg")"
grep -qx -- "$ACCT" "$reg" || fail "registered poll argv does not name the expanded account: $(cat "$reg")"
out=$(FM_HOME="$ARM_HOME" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" arm --interval 30 --threshold 15 --provider codex) \
  || fail "arm without --codex-home refused: $out"
reg="$ARM_HOME/state/procevent/quota-codex.source"
[ -f "$reg" ] || fail "arm without --codex-home did not publish the provider registration"
if grep -q -- 'codex-home' "$reg"; then
  fail "arm without --codex-home registered an account axis: $(cat "$reg")"
fi
ok "arm registers the account axis only when --codex-home is given"

out=$(FM_HOME="$ARM_HOME" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" FM_STATE_OVERRIDE="$ARM_HOME/state" \
  "$BIN/fm-procevent-quota.sh" retire --provider codex --codex-home "$ACCT")
[ "$out" = "retired: $source_id" ] || fail "per-account retire targeted the wrong source: $out"
ok "per-account retire resolves the armed source id"

noauth="$LAB/accounts/.codex-3"
mkdir -p "$noauth"
if err=$(FM_HOME="$ARM_HOME" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" arm --provider codex --codex-home "$noauth" 2>&1); then
  fail "arm unexpectedly armed a watch on an account with no auth.json"
fi
printf '%s\n' "$err" | grep -q "codex home '$noauth' has no non-empty auth.json" \
  || fail "signed-out account refusal did not name the missing sign-in: $err"
[ -z "$(find "$ARM_HOME/state/procevent" -name 'quota-codex-codex-3-*' 2>/dev/null)" ] \
  || fail "a refused arm published a registration"
ok "arm refuses an account with no auth.json before registering anything"

if err=$(PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --provider claude --codex-home "$ACCT" 2>&1); then
  fail "arm unexpectedly accepted --codex-home for provider claude"
fi
printf '%s\n' "$err" | grep -q -- '--codex-home applies only to --provider codex' \
  || fail "non-codex --codex-home refusal returned: $err"
if err=$(PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --codex-home "$ACCT" 2>&1); then
  fail "arm unexpectedly accepted --codex-home for the aggregate watch"
fi
printf '%s\n' "$err" | grep -q -- '--codex-home applies only to --provider codex' \
  || fail "aggregate --codex-home refusal returned: $err"
ok "arm refuses --codex-home on a non-codex or aggregate watch"

rm -f "$COUNT" "$ARGV_LOG"
signed_out="$LAB/accounts/.codex-4"
make_codex_account "$signed_out"
: > "$signed_out/auth.json"
out=$(QUOTA_AXI_PER_HOME=1 QUOTA_AXI_ARGV_LOG="$ARGV_LOG" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --codex-home "$signed_out" --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "a signed-out account did not end the watch with an error: $out"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "a signed-out account kept polling: $out"
printf '%s\n' "$out" | grep -q 'has no non-empty auth.json' || fail "signed-out error did not name the missing sign-in: $out"
[ ! -e "$ARGV_LOG" ] || fail "a signed-out account still reached quota-axi (would have reported the ambient account): $(cat "$ARGV_LOG")"
ok "poll on a signed-out account wakes with an error instead of reading the ambient account"

printf '# all fm-procevent-quota tests passed\n'
