#!/usr/bin/env bash
# tests/fm-gex-drift.test.sh - the drift guard must ask the target, report each
# finding once, treat failed probes as unknown (never in sync), refuse an
# edited inventory, and track owed rollouts to a confirmed deploy:
#
#   1. An in-sync service is silent; a drifted one is one finding, reported
#      once; flipping back to sync clears it; drifting AGAIN is news again.
#   2. A failed probe (rc>1) is a FAILED finding and never counts as in sync
#      (an owed rollout survives it).
#   3. owe: no-op for an unlisted repo; deposits and warns for a listed one;
#      the check reminds while owed; an in-sync probe CONFIRMS and clears it.
#   4. arm hash-binds the inventory: after an edit the check refuses and runs
#      no probe (asserted via a probe marker); re-arm probes again.
#   5. clear drops the owed entries by hand.
#
# Isolation: throwaway FM_HOME, a real throwaway git repo as the service repo,
# cmd probes steered by a verdict file. No ssh, no network.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIFT="$REPO/bin/fm-gex-drift.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state" "$HOME_A/config" "$TMP/svc-repo"
git -C "$TMP/svc-repo" init -q -b main
git -C "$TMP/svc-repo" -c user.name=t -c user.email=t@invalid commit -q --allow-empty -m x

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }
run() { FM_HOME="$HOME_A" "$DRIFT" "$@"; }

VERDICT="$TMP/verdict"
MARKER="$TMP/probe-ran"
printf '0' > "$VERDICT"
PROBE="touch $MARKER; exit \$(cat $VERDICT)"
printf 'dienst-a\tswippipp/DienstA\t%s\tcmd %s\n' "$TMP/svc-repo" "$PROBE" > "$HOME_A/config/gex-drift.services"

# --- 1. in sync silent; drift once; returning drift is news again ----------
out=$(run check)
[ -z "$out" ] && ok "an in-sync service is silent" || fail "in sync must be silent (got: $out)"
printf '1' > "$VERDICT"
out=$(run check)
printf '%s' "$out" | grep -q 'GEX_DRIFT: dienst-a' && ok "drift is reported" || fail "drift must be reported"
out=$(run check)
[ -z "$out" ] && ok "the same drift is reported once, not every poll" || fail "dedupe must silence a known drift"
printf '0' > "$VERDICT"
out=$(run check)
[ -z "$out" ] && ok "returning to sync is silent" || fail "sync restoration must be silent (got: $out)"
printf '1' > "$VERDICT"
out=$(run check)
printf '%s' "$out" | grep -q 'GEX_DRIFT: dienst-a' && ok "a RETURNING drift is news again" \
  || fail "a returning drift must be reported again"
printf '0' > "$VERDICT"
run check >/dev/null

# --- 2. a failed probe is unknown, never in sync ----------------------------
printf '3' > "$VERDICT"
out=$(run check)
printf '%s' "$out" | grep -q 'probe FAILED' && ok "a failed probe is a FAILED finding" \
  || fail "a failed probe must be reported as failed"
printf '0' > "$VERDICT"
run check >/dev/null

# --- 3. owed rollouts: deposit, remind, confirm-and-clear -------------------
run owe swippipp/Unbekannt t-1 https://example.invalid/pr/1 >/dev/null \
  && [ ! -f "$HOME_A/state/.rollout-owed" ] \
  && ok "owe is a silent no-op for an unlisted repo" \
  || fail "owe must not deposit for an unlisted repo"
printf '1' > "$VERDICT"
run check >/dev/null   # take the drift finding out of the news window
out=$(run owe swippipp/DienstA t-42 https://example.invalid/pr/7)
printf '%s' "$out" | grep -q 'ROLLOUT OWED' && ok "owe warns and deposits for a service repo" \
  || fail "owe must warn for a service repo"
out=$(run check)
printf '%s' "$out" | grep -q 'rollout owed for swippipp/DienstA' && ok "the check reminds while owed" \
  || fail "an owed rollout must be reminded (got: $out)"
printf '3' > "$VERDICT"
run check >/dev/null
grep -q 'DienstA' "$HOME_A/state/.rollout-owed" && ok "a FAILED probe never clears an owed rollout" \
  || fail "a failed probe must not clear the owed rollout"
printf '0' > "$VERDICT"
out=$(run check)
printf '%s' "$out" | grep -q 'rollout CONFIRMED for swippipp/DienstA' \
  && ok "an in-sync probe confirms the rollout with evidence" \
  || fail "the confirming probe must report the cleared rollout (got: $out)"
[ ! -s "$HOME_A/state/.rollout-owed" ] && ok "the confirmed rollout leaves the owed record" \
  || fail "confirmation must clear the owed record"

# --- 4. arm hash-binds the inventory ---------------------------------------
if run arm >/dev/null 2>&1; then
  [ -f "$HOME_A/state/gex-drift.check.sh" ] && ok "arm writes the poll shim" || fail "arm must write the shim"
  [ -f "$HOME_A/state/.gex-drift-armed" ] || fail "arm must record the inventory sha"
else
  fail "arm must succeed with an inventory present"
fi
printf '# kommentar\n' >> "$HOME_A/config/gex-drift.services"
rm -f "$MARKER"
out=$(run check)
printf '%s' "$out" | grep -q 'edited since arm' && ok "an edited inventory is refused loudly" \
  || fail "an edited inventory must refuse probes"
[ ! -f "$MARKER" ] && ok "the refused check ran no probe" || fail "a refused check must not execute probes"
run arm >/dev/null 2>&1 || fail "re-arm must succeed"
run check >/dev/null
[ -f "$MARKER" ] && ok "re-arming lets probes run again" || fail "re-arm must re-enable probes"

# --- 5. manual clear --------------------------------------------------------
run owe swippipp/DienstA t-9 https://example.invalid/pr/9 >/dev/null
run clear swippipp/DienstA >/dev/null
[ ! -s "$HOME_A/state/.rollout-owed" ] && ok "clear drops the owed entries" || fail "clear must drop owed entries"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-gex-drift.test.sh: all checks passed"
  exit 0
fi
echo "fm-gex-drift.test.sh: $FAILS check(s) FAILED"
exit 1
