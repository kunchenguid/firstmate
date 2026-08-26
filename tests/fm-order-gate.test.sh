#!/usr/bin/env bash
# tests/fm-order-gate.test.sh - a captain order must be ASKABLE by a tool, and
# the answer must carry his words. Covers bin/fm-order-gate-lib.sh:
#
#   1. RED without the gate condition / GREEN with it: a deny order blocks its
#      gate and prints "O-xxxx<TAB><wording>"; the same gate with an untouched
#      context passes. Both directions asserted so neither case can go vacuous.
#   2. An allow entry in the SAME order lifts its deny; a deny in ANOTHER order
#      still blocks (the strictest captain word stands).
#   3. A key the context does not mention never matches; path-prefix matches on
#      a leading substring; an entry without pairs shuts the whole gate.
#   4. Unknown gate, unknown key, and a non-key=value token abort loudly (exit 2),
#      and a hand-broken enforce line in an order file aborts loudly too.
#   5. A closed order and an expired order stop binding.
#   6. Every decision writes its Tor-Log line to state/tor-log/order-gate.jsonl -
#      rot with the blocking order id, gruen with "-".
#
# Isolation: hand-written fixture orders under a throwaway FM_HOME. Nothing
# touches the live order book, the live reservations, or the live tor-log.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/data/entscheide/2026-01-01"
LOG="$HOME_A/state/tor-log/order-gate.jsonl"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

export FM_HOME="$HOME_A"
# shellcheck source=bin/fm-order-gate-lib.sh
. "$REPO/bin/fm-order-gate-lib.sh"

order() { # order <id> <status> <expires> <wording> [enforce...]
  local id="$1" status="$2" expires="$3" wording="$4"
  shift 4
  local f="$HOME_A/data/entscheide/2026-01-01/order-$id.md"
  {
    printf 'id: %s\ntype: prohibition\nsubject: fixture-%s\nstatus: %s\n' "$id" "$id" "$status"
    printf 'scope: fixture\nsource: captain\nrecorded: 2026-01-01T00:00:00Z\n'
    printf 'due: -\nexpires: %s\ntask: -\n' "$expires"
    local e
    for e in "$@"; do printf 'enforce: %s\n' "$e"; done
    printf '\n## wording (verbatim, original language)\n%s\n' "$wording"
    printf '\n## translation (EN, marked)\n(none)\n'
  } > "$f"
}

check() { # check <gate> [k=v]... -> sets RC and OUT
  OUT="$(fm_order_gate_check "$@" 2>&1)"
  RC=$?
}

# --- 1. red without the condition, green with it ---------------------------
order O-0001 active - 'Konto 2 bleibt zu, bis ich es sage.' 'spawn account=konto-2'
check spawn account=konto-2
[ "$RC" -eq 1 ] && ok "a deny order blocks its gate (exit 1)" || fail "deny order must block (rc=$RC out=$OUT)"
printf '%s' "$OUT" | grep -q '^O-0001	Konto 2 bleibt zu, bis ich es sage\.$' \
  && ok "the refusal carries id and the captain's first wording line" \
  || fail "refusal must be 'O-0001<TAB><wording>' (got: $OUT)"
check spawn account=konto-1
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "an untouched context passes the same gate" \
  || fail "untouched context must pass (rc=$RC out=$OUT)"
check merge account=konto-2
[ "$RC" -eq 0 ] && ok "another gate is unaffected by the spawn order" \
  || fail "the deny must bind only its own gate (rc=$RC)"

# --- 2. allow lifts only its own order -------------------------------------
order O-0002 active - 'Notfaelle duerfen immer.' 'spawn account=konto-2' 'spawn allow klasse=notfall'
check spawn account=konto-2 klasse=notfall
[ "$RC" -eq 1 ] && ok "O-0001 still blocks what its own order never allowed" \
  || fail "a foreign allow must not lift another order's deny (rc=$RC)"
printf '%s' "$OUT" | grep -q 'O-0002' && fail "O-0002's own allow must lift O-0002's deny" \
  || ok "the allow lifts the deny of its own order"
rm -f "$HOME_A/data/entscheide/2026-01-01/order-O-0001.md"
check spawn account=konto-2 klasse=notfall
[ "$RC" -eq 0 ] && ok "with only the allowing order left, the gate is free" \
  || fail "allow must free the gate once no other order denies (rc=$RC out=$OUT)"
check spawn account=konto-2
[ "$RC" -eq 1 ] && ok "without the allow context the same order blocks again" \
  || fail "the deny must still bind without the allow context (rc=$RC)"
rm -f "$HOME_A/data/entscheide/2026-01-01/order-O-0002.md"

# --- 3. match semantics -----------------------------------------------------
order O-0003 active - 'Nicht am Zahlungspfad ohne mich.' 'merge path-prefix=projects/hplan/pay'
check merge path-prefix=projects/hplan/pay/checkout.ts
[ "$RC" -eq 1 ] && ok "path-prefix matches a leading substring" || fail "path-prefix must match by prefix (rc=$RC)"
check merge path-prefix=projects/hplan/ui/button.ts
[ "$RC" -eq 0 ] && ok "a path outside the prefix passes" || fail "a foreign path must pass (rc=$RC out=$OUT)"
check merge account=konto-1
[ "$RC" -eq 0 ] && ok "a context that never mentions the key cannot match" \
  || fail "an unmentioned key must not block (rc=$RC out=$OUT)"
rm -f "$HOME_A/data/entscheide/2026-01-01/order-O-0003.md"
order O-0004 active - 'Es wird gar nichts gemerged.' 'merge'
check merge
[ "$RC" -eq 1 ] && ok "an entry without pairs shuts the whole gate" || fail "a bare gate entry must shut it (rc=$RC)"
check rollout
[ "$RC" -eq 0 ] && ok "the bare entry still binds only its own gate" || fail "bare entry must not leak to other gates (rc=$RC)"
rm -f "$HOME_A/data/entscheide/2026-01-01/order-O-0004.md"

# --- 4. loud on unknown values ---------------------------------------------
check quatsch account=konto-2
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "unknown gate" \
  && ok "an unknown gate aborts loudly (exit 2)" || fail "unknown gate must exit 2 loudly (rc=$RC out=$OUT)"
check spawn konto=2
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "unknown context key" \
  && ok "an unknown context key aborts loudly (exit 2)" || fail "unknown key must exit 2 (rc=$RC out=$OUT)"
check spawn konto-2
[ "$RC" -eq 2 ] && ok "a context token that is not key=value aborts loudly" \
  || fail "a bare context token must exit 2 (rc=$RC out=$OUT)"
order O-0005 active - 'Handverbogen.' 'spawn kontoo=konto-2'
check spawn account=konto-2
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "unreadable enforce entry" \
  && ok "a hand-broken enforce line in an order aborts loudly" \
  || fail "a broken enforce entry must exit 2 naming the file (rc=$RC out=$OUT)"
rm -f "$HOME_A/data/entscheide/2026-01-01/order-O-0005.md"
if fm_order_gate_validate_entry 'spawn account=konto-2' >/dev/null 2>&1; then
  ok "validate accepts a well-formed entry"
else
  fail "validate must accept a well-formed entry"
fi
fm_order_gate_validate_entry 'spawn account=' >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "validate refuses an empty value" || fail "validate must refuse an empty value"

# --- 5. closed and expired orders stop binding ------------------------------
order O-0006 closed - 'Damals galt das.' 'spawn account=konto-2'
check spawn account=konto-2
[ "$RC" -eq 0 ] && ok "a closed order no longer enforces" || fail "closed order must not block (rc=$RC out=$OUT)"
order O-0007 active 2020-01-01 'Nur fuer diesen Tag.' 'spawn account=konto-2'
check spawn account=konto-2
[ "$RC" -eq 0 ] && ok "an expired order no longer enforces" || fail "expired order must not block (rc=$RC out=$OUT)"
order O-0008 active 2099-01-01 'Gilt noch lange.' 'spawn account=konto-2'
check spawn account=konto-2
[ "$RC" -eq 1 ] && ok "an unexpired dated order still enforces" || fail "unexpired order must block (rc=$RC)"

# --- 6. the Tor-Log carries every decision ---------------------------------
[ -f "$LOG" ] || fail "the gate must write state/tor-log/order-gate.jsonl"
grep -q '"regel":"O-0008","verdikt":"rot"' "$LOG" \
  && ok "a refusal is logged with the deciding order id" || fail "rot line must name the order id"
grep -q '"regel":"-","verdikt":"gruen"' "$LOG" \
  && ok "a green passage is logged too (a silent gate is indistinguishable from a broken one)" \
  || fail "gruen lines must be logged"
grep -q '"kontext":"gate=spawn account=konto-2"' "$LOG" || fail "the log must carry the judged context"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$LOG" >/dev/null 2>&1 && ok "every log line is valid JSON" || fail "the tor-log must be valid JSONL"
fi
lines_before="$(wc -l < "$LOG")"
check spawn account=konto-2
lines_after="$(wc -l < "$LOG")"
[ "$lines_after" -eq $((lines_before + 1)) ] && ok "one decision appends exactly one line" \
  || fail "each decision must append exactly one line ($lines_before -> $lines_after)"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-order-gate.test.sh: all checks passed"
  exit 0
fi
echo "fm-order-gate.test.sh: $FAILS check(s) FAILED"
exit 1
