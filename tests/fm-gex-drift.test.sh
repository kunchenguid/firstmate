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
#   6. A missing inventory is loudly unpruefbar (never an all-clear), on
#      report AND check, on EVERY poll; owe refuses loudly there.
#   7. An inventory without active service lines is treated the same; arm
#      refuses empty inventories and malformed lines at write time; restoring
#      a valid line returns the guard to normal service.
#   8. The per-service path filter: a docs/frontend-only window between the
#      deployed commit and the repo tip stays in sync, a service-relevant
#      change drifts, lines WITHOUT the filter keep the every-commit meaning,
#      and the `relevant` subcommand classifies one window directly.
#   9. Freshness: the probe fetches before comparing, so a remote ahead of a
#      stale local checkout measures against the FETCHED tip (never the
#      backwards "runs X, repo is at Y" alarm); a failing fetch is a FAILED
#      verdict, never in sync.
#  10. Owed-rollout ledger entries written by an older version survive the
#      upgrade untouched: report shows them, clear drops them.
#
# Isolation: throwaway FM_HOMEs, real throwaway git repos (including a bare
# origin) as the service repos, cmd probes steered by a verdict file, and the
# documented FM_GEX_DRIFT_TEST_IMAGE hook instead of ssh/docker. No ssh, no
# network.
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

# --- helpers for the fixture-based cases ------------------------------------
# mk_commit <dir> <file> <content> <msg>: commit one file, print the short sha.
mk_commit() {
  local dir=$1 file=$2 content=$3 msg=$4
  mkdir -p "$dir/$(dirname "$file")"
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@invalid commit -q -m "$msg"
  git -C "$dir" rev-parse --short=7 HEAD
}

fresh_home() { # <name>: a throwaway FM_HOME under $TMP
  local h="$TMP/$1"
  mkdir -p "$h/state" "$h/config"
  printf '%s' "$h"
}

run_in() { # <home> <args...>
  local h=$1
  shift
  FM_HOME="$h" "$DRIFT" "$@"
}

run_img() { # <home> <image-string> <args...>: image-tag probes read the given string
  local h=$1 img=$2
  shift 2
  FM_HOME="$h" FM_GEX_DRIFT_TEST_IMAGE="$img" "$DRIFT" "$@"
}

# --- 6. a missing inventory is loudly unpruefbar, never an all-clear --------
HOME_B="$(fresh_home home-b)"
out=$(run_in "$HOME_B" report)
printf '%s' "$out" | grep -q 'kein Inventar' \
  && ok "report says unpruefbar without an inventory" \
  || fail "a missing inventory must be reported loudly (got: $out)"
printf '%s' "$out" | grep -q 'all services in sync' \
  && fail "a missing inventory must never yield the all-clear line" \
  || ok "no false all-clear without an inventory"
out1=$(run_in "$HOME_B" check)
out2=$(run_in "$HOME_B" check)
printf '%s\n%s' "$out1" "$out2" | grep -qc 'kein Inventar' \
  && [ "$(printf '%s\n%s' "$out1" "$out2" | grep -c 'kein Inventar')" -ge 2 ] \
  && ok "check reports unpruefbar on EVERY poll" \
  || fail "the unpruefbar line must not be deduped away (got: $out1 | $out2)"
if run_in "$HOME_B" owe swippipp/DienstA t-x https://example.invalid/pr/x >/dev/null 2>"$TMP/owe-err"; then
  fail "owe against a missing inventory must fail, not stay silent"
else
  grep -q 'kein Inventar' "$TMP/owe-err" \
    && ok "owe refuses loudly without an inventory" \
    || fail "owe's refusal must name the missing inventory (got: $(cat "$TMP/owe-err"))"
fi
[ ! -f "$HOME_B/state/.rollout-owed" ] \
  && ok "owe deposits nothing when the inventory is gone" \
  || fail "a refused owe must not write the ledger"

# --- 7. empty inventories and write-time validation --------------------------
HOME_C="$(fresh_home home-c)"
printf '# nur kommentare\n\n' > "$HOME_C/config/gex-drift.services"
out=$(run_in "$HOME_C" report)
printf '%s' "$out" | grep -q 'kein Inventar' \
  && ok "a comments-only inventory is unpruefbar too" \
  || fail "an empty-of-lines inventory must be unpruefbar (got: $out)"
run_in "$HOME_C" arm >/dev/null 2>&1 \
  && fail "arm must refuse an inventory with no active lines" \
  || ok "arm refuses an empty inventory at write time"
run_in "$HOME_C" owe swippipp/DienstA t-y https://example.invalid/pr/y >/dev/null 2>&1 \
  && fail "owe must refuse against an empty inventory" \
  || ok "owe refuses loudly against an empty inventory"
printf 'dienst-c\tswippipp/DienstC\t%s\tcmd true\n' "$TMP/svc-repo" >> "$HOME_C/config/gex-drift.services"
out=$(run_in "$HOME_C" report 2>&1)
printf '%s' "$out" | grep -q 'dienst-c (' \
  && ! printf '%s' "$out" | grep -q 'kein Inventar' \
  && ok "restoring a valid line returns normal service" \
  || fail "a restored inventory must probe normally (got: $out)"
printf 'kaputt\n' > "$HOME_C/config/gex-drift.services.bad"
mv "$HOME_C/config/gex-drift.services" "$HOME_C/config/gex-drift.services.ok"
cp "$HOME_C/config/gex-drift.services.ok" "$HOME_C/config/gex-drift.services"
printf 'x\tswippipp/X\t/nonexistent-dir-xyz\tcmd true\n' >> "$HOME_C/config/gex-drift.services"
run_in "$HOME_C" arm >/dev/null 2>&1 \
  && fail "arm must reject a missing repo dir" \
  || ok "arm rejects a missing repo directory"
mv -f "$HOME_C/config/gex-drift.services.ok" "$HOME_C/config/gex-drift.services"
printf 'x\tswippipp/X\t%s\twarp true\n' "$TMP/svc-repo" >> "$HOME_C/config/gex-drift.services"
run_in "$HOME_C" arm >/dev/null 2>&1 \
  && fail "arm must reject an unknown art" \
  || ok "arm rejects an unknown probe art"
mv -f "$HOME_C/config/gex-drift.services.ok" "$HOME_C/config/gex-drift.services"

# --- 8. per-service path filter ----------------------------------------------
FILT="$TMP/filt-repo"
mkdir -p "$FILT"
git -C "$FILT" init -q -b main
git -C "$FILT" -c user.name=t -c user.email=t@invalid commit -q --allow-empty -m base
C1=$(mk_commit "$FILT" backend/api.txt v1 "backend change")
C2=$(mk_commit "$FILT" frontend/app.js ui "frontend change")
HOME_D="$(fresh_home home-d)"
{
  printf 'dienst-p\tswippipp/P\t%s\timage-tag host container\tbackend/* shared/* contracts/*\n' "$FILT"
  printf 'dienst-legacy\tswippipp/L\t%s\timage-tag host container\n' "$FILT"
} > "$HOME_D/config/gex-drift.services"
out=$(run_img "$HOME_D" "registry.example/lens:$C1" report 2>&1)
printf '%s' "$out" | grep -q 'dienst-p .*: insync' \
  && printf '%s' "$out" | grep -q 'only non-service paths changed' \
  && ok "a docs/frontend-only window stays in sync under the filter" \
  || fail "frontend-only drift window must be filtered green (got: $out)"
printf '%s' "$out" | grep 'dienst-legacy' | grep -q ': drift' \
  && ok "a line WITHOUT the filter keeps the every-commit meaning" \
  || fail "the legacy service line must still drift (got: $out)"
C3=$(mk_commit "$FILT" backend/rollout.sh x "synthetic backend delta")
out=$(run_img "$HOME_D" "registry.example/lens:$C1" report 2>&1)
printf '%s' "$out" | grep 'dienst-p' | grep -q ': drift' \
  && printf '%s' "$out" | grep -q 'service-relevant change: backend/rollout.sh' \
  && ok "a synthetic backend delta is DRIFT under the filter" \
  || fail "backend delta must be reported as drift (got: $out)"
out=$(run_in "$HOME_D" relevant "$FILT" "$C1" "$C3" 'backend/*')
printf '%s' "$out" | grep -q "^relevant $C1..$C3:" \
  && printf '%s' "$out" | grep -q 'backend/rollout.sh' \
  && ok "relevant lists the matching path and exits 0" \
  || fail "relevant must list backend/rollout.sh (got: $out)"
run_in "$HOME_D" relevant "$FILT" "$C1" "$C2" 'backend/*' >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok "an irrelevant window answers irrelevant with rc 1" \
  || fail "irrelevant windows must exit 1 (got rc=$RC)"

# --- 9. freshness: fetch before compare, failed fetch stays failed ------------
ORIGIN="$TMP/origin.git"
SEED="$TMP/seed"
git init -q --bare -b main "$ORIGIN"
mkdir -p "$SEED"
git -C "$SEED" init -q -b main
S1=$(mk_commit "$SEED" backend/api.txt v1 "seed")
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q -u origin main
WC="$TMP/wc"
git clone -q "$ORIGIN" "$WC"
HOME_E="$(fresh_home home-e)"
printf 'dienst-f\tswippipp/F\t%s\timage-tag host container\n' "$WC" > "$HOME_E/config/gex-drift.services"
out=$(run_img "$HOME_E" "reg/f:$S1" report 2>&1)
printf '%s' "$out" | grep 'dienst-f' | grep -q ': insync' \
  && ok "a synced clone measures in sync" \
  || fail "baseline sync expected (got: $out)"
PUSHER="$TMP/pusher"
git clone -q "$ORIGIN" "$PUSHER"
S2=$(mk_commit "$PUSHER" frontend/ui.txt new "remote advance")
git -C "$PUSHER" push -q origin main
# WC has NOT fetched: its checkout stands at S1 while the remote tip is S2.
out=$(run_img "$HOME_E" "reg/f:$S2" report 2>&1)
printf '%s' "$out" | grep 'dienst-f' | grep -q ': insync' \
  && ! printf '%s' "$out" | grep -qE 'runs .*, repo is at' \
  && ok "the probe fetches first: remote-ahead is in sync, no backwards alarm" \
  || fail "stale-checkout basis must fetch before comparing (got: $out)"
[ "$(git -C "$WC" rev-parse --short=7 origin/main)" = "$S2" ] \
  && ok "the probe really fetched (origin/main advanced)" \
  || fail "the probe must have fetched the remote tip into the clone"
git -C "$WC" remote set-url origin "$TMP/gone.git"
out=$(run_img "$HOME_E" "reg/f:$S2" report 2>&1)
printf '%s' "$out" | grep -q 'probe FAILED' \
  && printf '%s' "$out" | grep -q 'fetch failed' \
  && ! printf '%s' "$out" | grep -q ': insync' \
  && ok "a failing fetch is a FAILED verdict, never in sync" \
  || fail "fetch failure must be loud and failed (got: $out)"

# --- 10. old owed-ledger entries survive untouched ----------------------------
HOME_F="$(fresh_home home-f)"
printf 'dienst-g\tswippipp/G\t%s\tcmd true\n' "$TMP/svc-repo" > "$HOME_F/config/gex-drift.services"
mkdir -p "$HOME_F/state"
printf '%s\t%s\t%s\t%s\n' "2026-08-24T22:10:00Z" "swippipp/OldRepo" "t-alt" "https://example.invalid/pr/alt" \
  > "$HOME_F/state/.rollout-owed"
out=$(run_in "$HOME_F" report)
printf '%s' "$out" | grep -q 'rollout owed for swippipp/OldRepo since 2026-08-24T22:10:00Z (task t-alt, https://example.invalid/pr/alt)' \
  && ok "pre-existing owed entries are shown unchanged" \
  || fail "old ledger entries must survive verbatim (got: $out)"
run_in "$HOME_F" clear swippipp/OldRepo >/dev/null
[ ! -s "$HOME_F/state/.rollout-owed" ] \
  && ok "clear still drops a pre-existing entry" \
  || fail "clear must work on pre-existing entries"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-gex-drift.test.sh: all checks passed"
  exit 0
fi
echo "fm-gex-drift.test.sh: $FAILS check(s) FAILED"
exit 1
