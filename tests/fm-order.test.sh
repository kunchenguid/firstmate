#!/usr/bin/env bash
# tests/fm-order.test.sh - the order book must actually carry captain words:
#
#   1. record refuses an empty wording and a promise without --due; nothing is
#      written on refusal.
#   2. record writes the documented file contract with the verbatim wording
#      (umlauts intact), and two records get distinct locked ids.
#   3. list shows active orders; pin emits the marked block with both ids.
#   4. recite passes on the exact active set and fails naming a missing id -
#      divergence asserted in both directions so the case cannot go vacuous.
#   5. close of a decision refuses without the captain's verbatim wording,
#      closes with it, and the order leaves list/pin/recite.
#   6. check-subject blocks a decided subject (exit 3), passes with --new-fact,
#      and passes an unknown subject.
#   7. an order whose expires date lies in the past stops binding: absent from
#      pin and recite, shown as expired in list --all.
#   8. record --task refuses before writing when tasks-axi is absent, and with
#      a tasks-axi shim it holds the task with the documented arguments.
#
# Isolation: throwaway FM_HOME; a tasks-axi shim logs its arguments. Nothing
# touches the live fleet.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORDER="$REPO/bin/fm-order.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/data" "$TMP/shims"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

run() { FM_HOME="$HOME_A" "$ORDER" "$@"; }

# --- 1. refusals write nothing -------------------------------------------
if run record --type decision --subject leer-test --quote "   " >/dev/null 2>&1; then
  fail "record must refuse an empty wording"
else
  ok "record refuses an empty wording"
fi
if run record --type promise --subject zusage-test --quote "Ich liefere." >/dev/null 2>&1; then
  fail "a promise without --due must be refused"
else
  ok "promise without --due is refused"
fi
if [ -d "$HOME_A/data/entscheide" ] && find "$HOME_A/data/entscheide" -name 'order-*.md' | grep -q .; then
  fail "refused records must not write files"
else
  ok "refusals write nothing"
fi

# --- 2. file contract and distinct ids -----------------------------------
out1="$(run record --type decision --subject sprache-regelwerk \
  --quote 'Vielleicht doch englisch? Inclusive meiner Zitate?' \
  --translation 'Maybe English after all? Including my quotes?')" || fail "first record must succeed"
out2="$(run record --type directive --subject register-messlauf \
  --quote 'Register am Ziel messen.' --due 2030-01-01)" || fail "second record must succeed"
id1="$(echo "$out1" | grep -o 'O-[0-9]*' | head -1)"
id2="$(echo "$out2" | grep -o 'O-[0-9]*' | head -1)"
[ -n "$id1" ] && [ -n "$id2" ] && [ "$id1" != "$id2" ] && ok "two records get distinct ids ($id1, $id2)" \
  || fail "records must print distinct order ids (got '$id1' / '$id2')"
f1="$(find "$HOME_A/data/entscheide" -name "order-$id1.md")"
[ -n "$f1" ] || fail "record must write the order file"
grep -q "^type: decision$" "$f1" || fail "order file must carry its type"
grep -q "^status: active$" "$f1" || fail "order file must start active"
grep -qF 'Vielleicht doch englisch? Inclusive meiner Zitate?' "$f1" \
  && ok "verbatim wording survives byte-exact" || fail "verbatim wording must survive"
grep -qF 'Maybe English after all?' "$f1" || fail "marked translation must be stored"

# --- 3. list and pin ------------------------------------------------------
list_out="$(run list)"
echo "$list_out" | grep -q "$id1" && echo "$list_out" | grep -q "$id2" \
  && ok "list shows both active orders" || fail "list must show both active orders"
pin_out="$(run pin)"
echo "$pin_out" | grep -q '=== ORDER PIN v1' || fail "pin must carry the begin marker"
echo "$pin_out" | grep -q 'END ORDER PIN' || fail "pin must carry the end marker"
echo "$pin_out" | grep -q "$id1" && echo "$pin_out" | grep -q "$id2" \
  && ok "pin lists both active orders" || fail "pin must list both active orders"

# --- 4. recite: green on exact set, red naming the gap --------------------
if run recite "$id1" "$id2" >/dev/null; then
  ok "recite passes on the exact active set"
else
  fail "recite must pass on the exact active set"
fi
if recite_err="$(run recite "$id2" 2>&1)"; then
  fail "recite must fail on an incomplete set"
elif echo "$recite_err" | grep -q "$id1"; then
  ok "recite fails naming the missing id"
else
  fail "recite failure must name the missing id"
fi

# --- 5. closing a decision needs the captain's words ----------------------
if run close "$id1" --reason "superseded" >/dev/null 2>&1; then
  fail "closing a decision without --captain-wording must refuse"
else
  ok "closing a decision without the captain's wording refuses"
fi
run close "$id1" --reason "revised by E1" --captain-wording "Vielleicht doch englisch?" >/dev/null \
  && ok "decision closes with the captain's wording" || fail "close with wording must succeed"
grep -q "^status: closed$" "$f1" || fail "closed order must carry status closed"
run list | grep -q "$id1" && fail "closed order must leave the active list" || ok "closed order leaves the active list"
run recite "$id2" >/dev/null && ok "recite tracks the shrunken active set" \
  || fail "recite must accept the remaining active set"

# --- 6. resubmission filter ----------------------------------------------
run check-subject sprache-regelwerk >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] && ok "decided subject blocks resubmission (exit 3)" \
  || fail "decided subject must block with exit 3 (got $rc)"
run check-subject sprache-regelwerk --new-fact "captain revised the decision" >/dev/null \
  && ok "named new fact unblocks resubmission" || fail "--new-fact must unblock"
run check-subject voellig-neu >/dev/null \
  && ok "unknown subject is free" || fail "unknown subject must be free"

# --- 7. expiry ends the binding ------------------------------------------
out3="$(run record --type directive --subject abgelaufen-test --quote 'Kurzlebige Order.' --expires 2020-01-01)"
id3="$(echo "$out3" | grep -o 'O-[0-9]*' | head -1)"
run pin | grep -q "$id3" && fail "expired order must leave pin" || ok "expired order leaves pin"
run recite "$id2" >/dev/null && ok "expired order leaves the recite set" \
  || fail "recite must not demand an expired order"
run list --all | grep "$id3" | grep -q expired && ok "list --all marks it expired" \
  || fail "list --all must mark the expired order"

# --- 8. task hold: fail-closed without tasks-axi, exact args with it ------
before="$(find "$HOME_A/data/entscheide" -name 'order-*.md' | wc -l)"
if PATH="/usr/bin:/bin" FM_HOME="$HOME_A" "$ORDER" record --type directive --subject halte-test \
     --quote 'Mit Posten.' --task t-42 >/dev/null 2>&1; then
  fail "record --task without tasks-axi must refuse"
else
  ok "record --task refuses without tasks-axi"
fi
after="$(find "$HOME_A/data/entscheide" -name 'order-*.md' | wc -l)"
[ "$before" = "$after" ] && ok "the refusal wrote nothing" || fail "refusal must not write an order file"
cat > "$TMP/shims/tasks-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/shims/tasks-axi.log"
exit 0
EOF
chmod +x "$TMP/shims/tasks-axi"
PATH="$TMP/shims:$PATH" FM_HOME="$HOME_A" "$ORDER" record --type promise --subject trooper-sicherung \
  --quote 'Sicherung bis Freitag.' --due 2030-08-28 --task t-77 >/dev/null \
  || fail "record --task with tasks-axi must succeed"
grep -q 'hold t-77 --reason order O-.*: trooper-sicherung --kind captain --until 2030-08-28' \
  "$TMP/shims/tasks-axi.log" && ok "task hold carries the documented arguments" \
  || fail "task hold must carry id, subject, kind captain, and --until"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-order.test.sh: all checks passed"
  exit 0
fi
echo "fm-order.test.sh: $FAILS check(s) FAILED"
exit 1
