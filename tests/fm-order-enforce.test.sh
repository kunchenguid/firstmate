#!/usr/bin/env bash
# tests/fm-order-enforce.test.sh - the order book's enforce surface: recording
# the machine-readable half of a captain word, asking it from the command line,
# and never letting our reading pass for his words. Covers bin/fm-order.sh:
#
#   1. record --enforce is repeatable and lands verbatim in the order file's
#      header block; a malformed entry is refused BEFORE anything is written
#      (nothing recorded, no id burnt into the file tree).
#   2. gate-check is red for the enforced context and green without it - both
#      directions asserted - and prints the order id with the captain's wording
#      on the red path; an unknown gate exits 2.
#   3. show and pin print every enforce line verbatim AND a separately marked
#      "[interpretation]" line, so the captain's words and our reading are never
#      confusable (L46, L50).
#   4. An order without enforce lines keeps its old output exactly.
#
# Isolation: throwaway FM_HOME; nothing touches the live order book.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORDER="$REPO/bin/fm-order.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/data"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }
run() { FM_HOME="$HOME_A" "$ORDER" "$@"; }

# --- 1. recording the enforce lines ----------------------------------------
out1="$(run record --type prohibition --subject konto-zwei --scope 'spawn auf Konto 2' \
  --quote 'Konto 2 bleibt zu, bis ich es sage.' \
  --enforce 'spawn account=konto-2' --enforce 'spawn allow klasse=notfall')" \
  || fail "record with --enforce must succeed"
id1="$(printf '%s' "$out1" | grep -o 'O-[0-9]*' | head -1)"
f1="$(find "$HOME_A/data/entscheide" -name "order-$id1.md")"
[ -n "$f1" ] || fail "record must write the order file"
grep -qx 'enforce: spawn account=konto-2' "$f1" \
  && grep -qx 'enforce: spawn allow klasse=notfall' "$f1" \
  && ok "both enforce lines land verbatim in the header block" \
  || fail "the order file must carry each --enforce line verbatim"
awk '/^$/{exit} /^enforce: /{n++} END{exit !(n==2)}' "$f1" \
  && ok "the enforce lines sit inside the header block" || fail "enforce must stand before the first blank line"

before="$(find "$HOME_A/data/entscheide" -name 'order-*.md' | wc -l)"
if run record --type directive --subject kaputt-test --quote 'Egal.' --enforce 'spawn konto=2' >/dev/null 2>&1; then
  fail "record must refuse an unknown enforce key"
else
  ok "record refuses an unknown enforce key"
fi
if run record --type directive --subject kaputt-test --quote 'Egal.' --enforce 'quatsch account=konto-2' >/dev/null 2>&1; then
  fail "record must refuse an unknown enforce gate"
else
  ok "record refuses an unknown enforce gate"
fi
after="$(find "$HOME_A/data/entscheide" -name 'order-*.md' | wc -l)"
[ "$before" = "$after" ] && ok "a refused enforce writes no order file" || fail "refusal must write nothing"

# --- 2. gate-check, both directions ----------------------------------------
gc_out="$(run gate-check spawn --ctx account=konto-2 2>&1)"
gc_rc=$?
[ "$gc_rc" -eq 1 ] && ok "gate-check is red for the enforced context (exit 1)" \
  || fail "gate-check must exit 1 for the enforced context (rc=$gc_rc out=$gc_out)"
printf '%s' "$gc_out" | grep -q "$id1" && printf '%s' "$gc_out" | grep -qF 'Konto 2 bleibt zu, bis ich es sage.' \
  && ok "the red answer carries the order id and the captain's wording" \
  || fail "the red answer must name id and wording (got: $gc_out)"
if run gate-check spawn --ctx account=konto-1 >/dev/null 2>&1; then
  ok "gate-check is green for an untouched context"
else
  fail "gate-check must be green for an untouched context"
fi
if run gate-check spawn --ctx account=konto-2 --ctx klasse=notfall >/dev/null 2>&1; then
  ok "the order's own allow entry frees the gate"
else
  fail "an allow entry must free the gate"
fi
run gate-check quatsch --ctx account=konto-2 >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "an unknown gate exits 2 loudly" || fail "unknown gate must exit 2"
run gate-check >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "gate-check without a gate exits 2" || fail "gate-check without a gate must exit 2"

# --- 3. wording and interpretation stand apart ------------------------------
show_out="$(run show "$id1")"
printf '%s' "$show_out" | grep -qF 'Konto 2 bleibt zu, bis ich es sage.' || fail "show must keep printing the wording"
printf '%s' "$show_out" | grep -q 'INTERPRETATION, marked' \
  && ok "show marks the interpretation block as interpretation" || fail "show must mark the interpretation block"
printf '%s' "$show_out" | grep -q '\[interpretation\] spawn with account=konto-2 is blocked by this order' \
  && ok "show renders the deny entry as a marked reading" || fail "show must render the deny interpretation"
printf '%s' "$show_out" | grep -q '\[interpretation\] spawn with klasse=notfall is expressly allowed by this order' \
  && ok "show renders the allow entry as a marked reading" || fail "show must render the allow interpretation"

pin_out="$(run pin)"
printf '%s' "$pin_out" | grep -q '^  enforce: spawn account=konto-2$' \
  && ok "pin carries the enforce line verbatim" || fail "pin must carry the enforce line verbatim"
printf '%s' "$pin_out" | grep -q '\[interpretation\] spawn with account=konto-2 is blocked' \
  && ok "pin carries the marked interpretation next to the quote" || fail "pin must carry the marked interpretation"

# --- 4. an order without enforce keeps its old shape ------------------------
out2="$(run record --type directive --subject ohne-enforce --quote 'Nur Worte, keine Mechanik.')" \
  || fail "record without --enforce must still succeed"
id2="$(printf '%s' "$out2" | grep -o 'O-[0-9]*' | head -1)"
f2="$(find "$HOME_A/data/entscheide" -name "order-$id2.md")"
grep -q '^enforce: ' "$f2" && fail "an order without --enforce must carry no enforce line" \
  || ok "an order without --enforce carries none"
run show "$id2" | grep -q 'INTERPRETATION' && fail "show must stay unchanged without enforce lines" \
  || ok "show of an enforce-free order is unchanged"
run recite "$id1" "$id2" >/dev/null && ok "recite still tracks the active set" || fail "recite must still pass"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-order-enforce.test.sh: all checks passed"
  exit 0
fi
echo "fm-order-enforce.test.sh: $FAILS check(s) FAILED"
exit 1
