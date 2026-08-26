#!/usr/bin/env bash
# tests/fm-brett-vollzug.test.sh - the Bemerkungstor's enforcement side must
# actually block, and only when scharfgeschaltet:
#
#   1. vollzugsfrei is rot (exit 1, prints the Bemerkung and a named Ausweg)
#      for a context whose task= matches an open marker's task: field.
#   2. `erledigt` retires the marker (delegating to
#      fm-brett-antworten.sh bemerkung-erledigt, which this fixture ships),
#      after which the same context is vollzugsfrei again.
#   3. An Altbestand marker (no task:/subject: fields) never blocks, but
#      does print a WARN line; overall still gruen (exit 0).
#   4. `anreichern` tags such a marker with task:/subject:, after which it DOES
#      block a matching context.
#   5. With the .tor-bemerkung-scharf flag absent, vollzugsfrei is always
#      gruen and silent, whatever markers exist.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-brett-vollzug.sh"
TMP_ROOT=$(fm_test_tmproot fm-brett-vollzug)

make_home() {  # <name> -> home path on stdout
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/brett-antworten" "$home/state/brett-bemerkungen" "$home/config"
  printf '%s\n' "$home"
}

write_marker() {  # <home> <id> <bemerkung> [task] [subject]
  local home=$1 id=$2 bem=$3 task=${4:-} subject=${5:-}
  {
    printf 'schema: fm-brett-bemerkung.v1\n'
    printf 'antwort-id: %s\n' "$id"
    printf 'entscheid: test-entscheid\n'
    printf 'verbleib: offen\n'
    printf 'angelegt: 2026-08-25T10:00:00+0000\n'
    printf 'bemerkung: %s\n' "$bem"
    [ -z "$task" ] || printf 'task: %s\n' "$task"
    [ -z "$subject" ] || printf 'subject: %s\n' "$subject"
  } > "$home/state/brett-bemerkungen/$id.md"
}

arm() {  # <home>
  : > "$1/state/.tor-bemerkung-scharf"
}

H=$(make_home h1)
arm "$H"

# --- 1. rot: task= matches an open marker's task: field ---------------------

write_marker "$H" ant-1 "Bitte unbedingt X beruecksichtigen." task-42
out=$(FM_HOME="$H" "$CHECK" vollzugsfrei task=task-42 2>&1)
rc=$?
[ "$rc" -eq 1 ] || fail "vollzugsfrei must refuse a matching task context (rc=$rc out=$out)"
case $out in
  *"Bitte unbedingt X beruecksichtigen."*) pass "ok - refusal quotes the Bemerkung text" ;;
  *) fail "refusal must quote the Bemerkung text, got: $out" ;;
esac
case $out in
  *"erledigt"*"--vermerk"*) pass "ok - refusal names an Ausweg" ;;
  *) fail "refusal must name an Ausweg (erledigt --vermerk), got: $out" ;;
esac

# --- 2. gruen after erledigt --------------------------------------------------

erledigt_out=$(FM_HOME="$H" "$CHECK" erledigt ant-1 --vermerk "an Testoffizier geroutet" 2>&1)
erledigt_rc=$?
[ "$erledigt_rc" -eq 0 ] || fail "erledigt must succeed: $erledigt_out"
[ -f "$H/state/brett-bemerkungen/ant-1.md" ] && fail "erledigt must remove the open marker"
[ -f "$H/state/brett-bemerkungen/erledigt/ant-1.md" ] || fail "erledigt must archive the marker to erledigt/"

out2=$(FM_HOME="$H" "$CHECK" vollzugsfrei task=task-42 2>&1)
rc2=$?
[ "$rc2" -eq 0 ] || fail "vollzugsfrei must be gruen once the matching marker is erledigt: $out2"
pass "ok - vollzugsfrei is gruen after erledigt retires the marker"

# --- 3. Altbestand marker: warn, but never blocks -----------------------------

write_marker "$H" ant-2 "Altes Format ohne Felder."
warn_out=$(FM_HOME="$H" "$CHECK" vollzugsfrei task=irgendwas 2>&1)
warn_rc=$?
[ "$warn_rc" -eq 0 ] || fail "an Altbestand marker must never block: $warn_out"
case $warn_out in
  *WARN*ant-2*) pass "ok - Altbestand marker prints a WARN line" ;;
  *) fail "expected a WARN line naming ant-2, got: $warn_out" ;;
esac

# --- 4. anreichern makes it matchable -----------------------------------------

anr_out=$(FM_HOME="$H" "$CHECK" anreichern ant-2 --task task-99 --subject "Ausrollplan Server" 2>&1)
anr_rc=$?
[ "$anr_rc" -eq 0 ] || fail "anreichern must succeed: $anr_out"
grep -q '^task: task-99$' "$H/state/brett-bemerkungen/ant-2.md" || fail "anreichern must write task: task-99"
grep -q '^subject: Ausrollplan Server$' "$H/state/brett-bemerkungen/ant-2.md" || fail "anreichern must write subject:"

blocked_out=$(FM_HOME="$H" "$CHECK" vollzugsfrei task=task-99 2>&1)
blocked_rc=$?
[ "$blocked_rc" -eq 1 ] || fail "the enriched marker must now block a matching task context: $blocked_out"
case $blocked_out in
  *"Altes Format ohne Felder."*) pass "ok - anreichern makes a formerly-Altbestand marker block" ;;
  *) fail "expected the enriched marker's Bemerkung quoted, got: $blocked_out" ;;
esac

sub_out=$(FM_HOME="$H" "$CHECK" vollzugsfrei subject="grosser Ausrollplan Server Q3" 2>&1)
sub_rc=$?
[ "$sub_rc" -eq 1 ] || fail "a substring subject match must also block: $sub_out"
pass "ok - subject substring match blocks too"

# --- 5. flag absent: always gruen, always silent ------------------------------

rm -f "$H/state/.tor-bemerkung-scharf"
off_out=$(FM_HOME="$H" "$CHECK" vollzugsfrei task=task-99 2>&1)
off_rc=$?
[ "$off_rc" -eq 0 ] || fail "with the flag absent vollzugsfrei must be gruen: $off_out"
[ -z "$off_out" ] || fail "with the flag absent vollzugsfrei must be silent, got: $off_out"
pass "ok - vollzugsfrei is silently gruen while the tor flag is absent"

# --- status prints option and Bemerkung side by side --------------------------

arm "$H"
cat > "$H/data/brett-antworten/ant-99.md" <<'EOF'
antwort-id: ant-99
entscheid: freigeben
art: wahl
gesendet: 2026-08-25T09:00:00+0000
schonfrist-bis: -
ersetzt: -

## Wort des Captains

Mach das so.

## Bemerkung

Wichtiger Hinweis fuer spaeter.
EOF
write_marker "$H" ant-99 "Wichtiger Hinweis fuer spaeter." task-1 "irgendein Betreff"
status_out=$(FM_HOME="$H" "$CHECK" status ant-99 2>&1)
status_rc=$?
[ "$status_rc" -eq 0 ] || fail "status must succeed for a known id: $status_out"
case $status_out in
  *"entscheid: freigeben"*) ;;
  *) fail "status must print the option's entscheid, got: $status_out" ;;
esac
case $status_out in
  *"bemerkung: Wichtiger Hinweis fuer spaeter."*) pass "ok - status prints option and Bemerkung together" ;;
  *) fail "status must print the marker's Bemerkung, got: $status_out" ;;
esac

echo "all ok"
