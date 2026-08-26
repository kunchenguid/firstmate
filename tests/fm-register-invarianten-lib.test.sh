#!/usr/bin/env bash
# tests/fm-register-invarianten-lib.test.sh - the three register invariants
# owned by bin/fm-register-invarianten-lib.sh must be true of the RECORDS, not
# of the rendered view:
#
#   1. ziel: a missing "(ziel: <repo>/<anker>)" is a WARN line in the
#      transition, and turns ROT only when the arming flag exists AND the post
#      was touched after it (since date after the flag date). A post that
#      predates the arming stays WARN; a prose citation of the field inside an
#      entry body never satisfies it; a post that carries the field is silent.
#   2. eigner: the owner is read from the carriers the format has TODAY -
#      (wer: ...) when present, otherwise (repo: ...) resolved through
#      data/secondmates.md, config/register-bereiche, or the Betrieb marker.
#      A post with no repo field, or a repo no home and no area claims, is
#      reported.
#   3. planlos: an active post without a plan approval record older than the
#      threshold is reminded WITH the three valid answers verbatim; a held
#      post is exempt (parking is a full answer); a record in a secondmate
#      home counts; a young post is silent.
#
# Plus: Done never counts, the Tor-Log carries exactly one summary line per
# sweep with the right verdict, and the exit code separates clean from
# findings from error.
#
# Isolation: throwaway home, no tasks-axi needed - the canonical file is read.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/fm-register-invarianten-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"
mkdir -p "$H/data" "$H/config" "$H/state" "$H/sm1/state"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

# shellcheck source=bin/fm-register-invarianten-lib.sh
# shellcheck disable=SC1091
. "$LIB"

TODAY=2026-08-26
TAGE=7
inv() { # -> findings on stdout, exit code of the library
  FM_HOME=$H
  FM_CONFIG_OVERRIDE=$H/config
  FM_REGISTER_INVARIANTEN_TODAY=$TODAY
  FM_REGISTER_PLANLOS_TAGE=$TAGE
  fm_register_invarianten "$H/data/backlog.md" "$H"
}

has() { printf '%s\n' "$1" | grep -Fxq "$2"; }
hasnt() { ! printf '%s\n' "$1" | grep -Fq "$2"; }

# --- fixture ----------------------------------------------------------------
# One secondmate home so a repo resolves to an sm-*, and so a plan approval
# record written into the OFFICER home is found from the primary backlog.
printf -- '- sm-lensclash - Zweiter Offizier fuer LensClash (home: %s/sm1; scope: App; projects: lensclash, katalogweg; added 2026-08-16)\n' \
  "$H" > "$H/data/secondmates.md"
# testlab has an area but no secondmate; lensclash has a secondmate but no area.
printf 'Kartenwerk\ttestlab\n' > "$H/config/register-bereiche"
: > "$H/sm1/state/geplant-alt.plan-approval"

{
  printf '## In flight\n'
  printf -- '- [ ] lauf-alt - Laufender Posten ohne Ziel (repo: lensclash) (since 2026-08-10)\n'
  printf '## Queued\n'
  printf -- '- [ ] ziel-da - Posten mit Ziel (ziel: lensclash/VISION.md#erfolgsmasse) (repo: lensclash) (since 2026-08-10)\n'
  printf -- '- [ ] neu-nach-scharf - Nach dem Scharfschalten angelegt (repo: lensclash) (since 2026-08-22)\n'
  printf -- '- [ ] alt-vor-scharf - Vor dem Scharfschalten angelegt (repo: lensclash) (since 2026-08-18)\n'
  printf -- '- [ ] ohne-repo - Posten ganz ohne Traeger (since 2026-08-10)\n'
  printf -- '- [ ] fremd-repo - Posten mit unbekanntem Repo (repo: niemandsland) (since 2026-08-10)\n'
  printf -- '- [ ] betrieb-posten - Betriebsposten (repo: -) (since 2026-08-10)\n'
  printf -- '- [ ] bereich-posten - Posten ueber den Bereich (repo: testlab) (since 2026-08-10)\n'
  printf -- '- [ ] wer-posten - Posten mit ausdruecklichem Eigner (wer: sm-lensclash) (since 2026-08-10)\n'
  printf -- '- [ ] geparkt-alt - Alter Posten mit Grund geparkt (repo: lensclash) (since 2026-08-01) (hold: Captain 01.08.: erst nach Go-Live) (hold-kind: captain)\n'
  printf -- '- [ ] geplant-alt - Alter Posten mit Plan-Freigabe (repo: lensclash) (since 2026-08-01)\n'
  printf -- '- [ ] jung-1 - Junger Posten (repo: lensclash) (since 2026-08-24)\n'
  printf '  Prosa-Zitat aus einem anderen Eintrag: (ziel: lensclash/VISION.md#nix) - ein Zitat, kein Feld.\n'
  printf '## Done\n'
  printf -- '- [x] fertig-1 - Erledigtes ohne Ziel und ohne alles (done 2026-08-16)\n'
} > "$H/data/backlog.md"

# --- 1. transition: every missing ziel is a WARN, nothing is red ------------
out=$(inv); rc=$?
[ "$rc" = 1 ] && ok "findings exit 1" || fail "findings must exit 1 (rc=$rc)"
has "$out" 'ziel fehlt: lauf-alt' && ok "a missing ziel field warns in the transition" \
  || fail "the transition must warn about a missing ziel field"
has "$out" 'ziel fehlt: jung-1' \
  && ok "a prose citation of (ziel: ...) in the body does not satisfy the field" \
  || fail "prose must never satisfy the ziel field"
hasnt "$out" 'ziel fehlt: ziel-da' && ok "a post carrying the field is silent" \
  || fail "a post with (ziel: ...) must not be reported"
hasnt "$out" 'ziel fehlt: fertig-1' && ok "Done never counts" \
  || fail "a Done entry must never produce a finding"
hasnt "$out" 'ROT' && ok "unarmed, no ziel finding is red" \
  || fail "without the arming flag nothing may be red"
grep -q '"tor":"register-ziel"' "$H/state/tor-log/register-ziel.jsonl" \
  && grep -q '"verdikt":"warn"' "$H/state/tor-log/register-ziel.jsonl" \
  && ok "the sweep logs one warn line to the register-ziel gate" \
  || fail "the transition sweep must log a warn verdict"
[ "$(wc -l < "$H/state/tor-log/register-ziel.jsonl")" = 1 ] \
  && ok "exactly one Tor-Log line per sweep, not one per post" \
  || fail "the sweep must log once, not per post"

# --- 2. armed: only posts touched after the arming turn red -----------------
printf '2026-08-20\n' > "$H/state/.register-ziel-scharf"
out=$(inv); rc=$?
[ "$rc" = 1 ] || fail "an armed sweep with findings must exit 1 (rc=$rc)"
printf '%s\n' "$out" | grep -q '^ziel fehlt: neu-nach-scharf - ROT: Ziel-Tor scharf seit 2026-08-20, Posten seit 2026-08-22' \
  && ok "a post touched after the arming is ROT and names both dates" \
  || fail "a post dated after the flag date must be red"
has "$out" 'ziel fehlt: alt-vor-scharf' \
  && ok "a post predating the arming stays a plain warn (Nachzug bei Beruehrung)" \
  || fail "an untouched older post must not be dragged into the block"
grep -q '"verdikt":"rot"' "$H/state/tor-log/register-ziel.jsonl" \
  && ok "the armed sweep logs rot" || fail "a red finding must be logged as rot"

# An unreadable arming never turns anything red and never goes silent.
printf 'irgendwas\n' > "$H/state/.register-ziel-scharf"
touch -d 2026-08-20 "$H/state/.register-ziel-scharf" 2>/dev/null \
  && { out=$(inv 2>/dev/null)
       printf '%s\n' "$out" | grep -q 'ROT: Ziel-Tor scharf seit 2026-08-20' \
         && ok "a flag without a date line falls back to its mtime date" \
         || fail "the mtime fallback for the flag date is broken"; }
printf '2026-08-20\n' > "$H/state/.register-ziel-scharf"

# --- 3. eigner: the carriers the format has today ---------------------------
out=$(inv)
has "$out" 'eigner fehlt: ohne-repo - kein (repo:)- und kein (wer:)-Feld auf der Zeile' \
  && ok "a line with no carrier at all has no owner" \
  || fail "a post without (repo:) and (wer:) must be reported"
printf '%s\n' "$out" | grep -q '^eigner fehlt: fremd-repo - (repo: niemandsland) kennt weder' \
  && ok "a repo no home and no area claims has no owner" \
  || fail "an unknown repo must not pass as an owner"
hasnt "$out" 'eigner fehlt: lauf-alt' && ok "(repo: lensclash) resolves through data/secondmates.md" \
  || fail "a repo listed in a secondmate's projects must resolve"
hasnt "$out" 'eigner fehlt: bereich-posten' && ok "(repo: testlab) resolves through config/register-bereiche" \
  || fail "a repo with an area line must resolve"
hasnt "$out" 'eigner fehlt: betrieb-posten' && ok "(repo: -) is firstmate's own Betrieb" \
  || fail "the Betrieb marker must resolve"
hasnt "$out" 'eigner fehlt: wer-posten' && ok "an explicit (wer: sm-*) is honored without any repo" \
  || fail "the (wer: ...) carrier must be honored when a line grows one"

# --- 4. planlos: age, three answers, parking is a full answer ---------------
has "$out" 'planlos seit 16 Tagen: lauf-alt - planen | parken mit Grund | streichen vorschlagen' \
  && ok "the reminder carries the three valid answers verbatim" \
  || fail "the planlos line must name planen | parken mit Grund | streichen vorschlagen"
has "$out" 'planlos seit 8 Tagen: alt-vor-scharf - planen | parken mit Grund | streichen vorschlagen' \
  && ok "the age counts from the post's own since date" || fail "planlos age is miscounted"
hasnt "$out" 'planlos seit 25 Tagen: geparkt-alt' \
  && ok "a held post is exempt - parking is a full answer, not a lesser one" \
  || fail "a parked post must never be re-reminded"
hasnt "$out" 'planlos seit 25 Tagen: geplant-alt' \
  && ok "a plan approval record in the officer home counts as planned" \
  || fail "a plan-approval record in a secondmate home must be found"
hasnt "$out" 'planlos seit 2 Tagen: jung-1' && ok "a young post is silent" \
  || fail "a post under the threshold must not be reminded"

# The record in THIS home counts too, and removing it makes the post planlos
# again - so the silence above is the record's doing, not an accident.
rm -f "$H/sm1/state/geplant-alt.plan-approval"
out=$(inv)
has "$out" 'planlos seit 25 Tagen: geplant-alt - planen | parken mit Grund | streichen vorschlagen' \
  && ok "counter-probe: without the record the same post is planlos" \
  || fail "the plan-approval lookup must actually decide the planlos line"
: > "$H/state/geplant-alt.plan-approval"
out=$(inv)
hasnt "$out" 'planlos seit 25 Tagen: geplant-alt' \
  && ok "a record in the reading home itself counts as well" \
  || fail "the home's own state/<id>.plan-approval must count"

# --- 5. clean backlog, and loud errors --------------------------------------
{
  printf '## In flight\n'
  printf '## Queued\n'
  printf -- '- [ ] sauber-1 - Sauberer Posten (ziel: lensclash/VISION.md#ziel) (repo: lensclash) (since 2026-08-25)\n'
  printf '## Done\n'
} > "$H/data/backlog.md"
rm -f "$H/state/tor-log/register-ziel.jsonl"
out=$(inv); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a clean backlog is silent and exits 0" \
  || fail "a clean backlog must be silent (rc=$rc out=$out)"
grep -q '"verdikt":"gruen"' "$H/state/tor-log/register-ziel.jsonl" \
  && ok "a clean sweep still logs gruen - a silent gate and an unarmed one stay distinguishable" \
  || fail "the clean sweep must log a gruen line"

if out=$(fm_register_invarianten "$H/data/gibtsnicht.md" "$H" 2>&1); then
  fail "a missing backlog file must not pass silently"
else
  rc=$?
  [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'keine lesbare Backlog-Datei' \
    && ok "a missing backlog file is a loud error (exit 2)" \
    || fail "a missing backlog must exit 2 with a named reason (rc=$rc out=$out)"
fi

TODAY=nichtsdatum
if out=$(inv 2>&1); then
  fail "an unusable pinned clock must not pass silently"
else
  rc=$?
  [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'ist kein Datum' \
    && ok "an unusable FM_REGISTER_INVARIANTEN_TODAY is a loud error (exit 2)" \
    || fail "a bad pinned clock must exit 2 (rc=$rc out=$out)"
fi
TODAY=2026-08-26

echo
if [ "$FAILS" = 0 ]; then
  echo "fm-register-invarianten-lib.test.sh: all checks passed"
else
  echo "fm-register-invarianten-lib.test.sh: $FAILS check(s) FAILED"
  exit 1
fi
