#!/usr/bin/env bash
# Behavior tests for bin/fm-wartebedingungen.sh - the waiting-condition guard.
#
# The two cases that motivated the guard are reproduced first and by name,
# because a regression there is the whole failure it exists to prevent: an entry
# whose condition the outside world satisfied long ago being presented as still
# open. Every probe here answers from a stub on PATH, so the suite needs no
# network, no forge account, and no real repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WARTE="$ROOT/bin/fm-wartebedingungen.sh"

TMP_ROOT=$(fm_test_tmproot fm-wartebedingungen) || fail "could not create temp root"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PATH="$FAKEBIN:$PATH"
export PATH

# --- fixture home -----------------------------------------------------------

# new_home <name>: a fresh operational home with an empty backlog, echoed as its
# path. Each case gets its own so a no-nag record never leaks between them.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  : > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# entry <home> <id> <header-extra> [body-line...]
entry() {
  local home=$1 id=$2 extra=$3 line
  shift 3
  printf -- '- [ ] %s - %s%s\n' "$id" "Fixture entry" "${extra:+ $extra}" >> "$home/data/backlog.md"
  for line in "$@"; do
    printf '  %s\n' "$line" >> "$home/data/backlog.md"
  done
}

# run_check <home> [env=value...]: one sweep with the cadence gate open, so a
# case never depends on wall-clock timing between its own runs.
run_check() {
  local home=$1
  shift
  env FM_HOME="$home" FM_WARTE_INTERVAL=0 FM_WARTE_TODAY=2026-08-22 "$@" \
    "$WARTE" check 2>&1
}

# --- probe stubs ------------------------------------------------------------

# stub_gh_pr_state <STATE>: what `gh pr view` reports, which is what
# bin/fm-pr-poll.sh reads for a GitHub pull request.
stub_gh_pr_state() {
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = pr ] && [ "\${2:-}" = view ]; then
  printf '%s\n' '$1'
  exit 0
fi
exit 1
SH
  chmod +x "$FAKEBIN/gh"
}

# stub_gh_newest_run <id> <status> <conclusion> <created_at>
stub_gh_newest_run() {
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ]; then
  printf '%s %s %s %s\n' '$1' '$2' '$3' '$4'
  exit 0
fi
exit 1
SH
  chmod +x "$FAKEBIN/gh"
}

# stub_gh_api_fails: the forge cannot be read at all.
stub_gh_api_fails() {
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$FAKEBIN/gh"
}

# stub_curl_status <code>
stub_curl_status() {
  cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s' '$1'
exit 0
SH
  chmod +x "$FAKEBIN/curl"
}

# ---------------------------------------------------------------------------
# Belegfall 1: the stopped account. Runs were not failing, they were not being
# created; once billing was restored a run started again and went green, and the
# entry stayed quoted as open for another day.
# ---------------------------------------------------------------------------

home=$(new_home zahlung-behoben)
entry "$home" github-zahlung-ci-stopp \
  '(hold: wartet auf Zahlungsfreigabe) (hold-kind: external)' \
  'wartet-auf: gh-runs-green example/hplan 2026-08-21'

stub_gh_newest_run 9911 completed success 2026-08-22T06:10:00Z
out=$(run_check "$home")
assert_contains "$out" 'Bedingung laengst erfuellt: github-zahlung-ci-stopp' \
  'a run that started after the outage and went green ends the wait'
assert_contains "$out" '9911' 'the finding carries the run it read as evidence'
pass 'payment case: a started, green run within one sweep ends the wait'

# The same entry, one sweep earlier: the newest green run predates the outage.
# Reporting that as resolved is the exact false positive a "newest run is green"
# check would produce.
home=$(new_home zahlung-noch-offen)
entry "$home" github-zahlung-ci-stopp \
  '(hold: wartet auf Zahlungsfreigabe) (hold-kind: external)' \
  'wartet-auf: gh-runs-green example/hplan 2026-08-21'
stub_gh_newest_run 4711 completed success 2026-08-19T10:00:00Z
out=$(run_check "$home")
assert_not_contains "$out" 'laengst erfuellt' \
  'a green run from before the outage must not end the wait'
pass 'payment case: a pre-outage green run is not reported as resolved'

# Nothing has run at all - the stopped-account shape itself.
home=$(new_home zahlung-kein-lauf)
entry "$home" github-zahlung-ci-stopp \
  '(hold: wartet auf Zahlungsfreigabe) (hold-kind: external)' \
  'wartet-auf: gh-runs-green example/hplan'
stub_gh_newest_run null null null null
out=$(run_check "$home")
assert_not_contains "$out" 'laengst erfuellt' \
  'an account with no run created must not be reported as green'
pass 'payment case: no run created at all is still waiting, not green'

# A forge that cannot be read is a failed probe, never a quiet "not yet".
home=$(new_home zahlung-unlesbar)
entry "$home" github-zahlung-ci-stopp \
  '(hold: wartet auf Zahlungsfreigabe) (hold-kind: external)' \
  'wartet-auf: gh-runs-green example/hplan'
stub_gh_api_fails
out=$(run_check "$home")
assert_contains "$out" 'Wartebedingung nicht pruefbar: github-zahlung-ci-stopp' \
  'an unreadable forge is reported as a failed probe'
assert_not_contains "$out" 'laengst erfuellt' 'a failed probe never reports a resolution'
pass 'a probe that cannot answer is reported, not silently treated as still waiting'

# ---------------------------------------------------------------------------
# Belegfall 2: the pull request merged at 06:53 and reported as outstanding at
# 09:40. The entry was in flight, not held, so the guard has to watch a
# condition wherever it is deposited rather than only under a hold.
# ---------------------------------------------------------------------------

home=$(new_home pr-gemergt)
entry "$home" hplan-runde-1 '(repo: hplan) (kind: ship)' \
  'wartet-auf: pr-merged https://github.com/example/hplan/pull/1'
stub_gh_pr_state MERGED
out=$(run_check "$home")
assert_contains "$out" 'Bedingung laengst erfuellt: hplan-runde-1' \
  'a merged pull request ends the wait on an in-flight entry'
assert_contains "$out" 'https://github.com/example/hplan/pull/1' \
  'the finding names the request it read'
pass 'PR case: a merged request on an in-flight entry is reported within one sweep'

home=$(new_home pr-offen)
entry "$home" hplan-runde-1 '(repo: hplan) (kind: ship)' \
  'wartet-auf: pr-merged https://github.com/example/hplan/pull/1'
stub_gh_pr_state OPEN
out=$(run_check "$home")
assert_not_contains "$out" 'laengst erfuellt' 'an open request keeps the entry waiting'
pass 'PR case: an open request stays silent'

# ---------------------------------------------------------------------------
# The risk marker, and what deliberately does not trigger it.
# ---------------------------------------------------------------------------

home=$(new_home risikomarker)
entry "$home" azure-founders-hub-antrag \
  '(hold: wartet auf Microsoft-Annahme) (hold-kind: external)' \
  'Kein Probenweg hinterlegt.'
entry "$home" mpc-api-antwort-abwarten \
  '(hold: wartet auf MPC-Antwort) (hold-kind: external)' \
  'wartet-auf: unpruefbar Antwort per E-Mail; keine lesende Probe'
entry "$home" foerderung-entscheid \
  '(hold: Captain entscheidet im Dezember) (hold-kind: captain)'
# An untyped hold that says in so many words that it is waiting for something.
entry "$home" ragdigital-belegung \
  '(hold: HPlan ist noch nicht ausgerollt - wartet auf einen erreichbaren HPlan-Dienst)'
# An untyped hold on an event of firstmate's own, not on the world.
entry "$home" post-launch-paket '(hold: nach Go-Live)'
printf -- '- [x] alt-erledigt - schon fertig (hold-kind: external)\n' >> "$home/data/backlog.md"

out=$(run_check "$home")
assert_contains "$out" 'Bedingung unpruefbar hinterlegt: azure-founders-hub-antrag' \
  'an external wait with no condition is marked as a risk'
assert_not_contains "$out" 'mpc-api-antwort-abwarten' \
  'a wait recorded as not machine-checkable is accepted, not nagged about'
assert_not_contains "$out" 'foerderung-entscheid' \
  "a captain's own hold is not an external wait"
assert_not_contains "$out" 'alt-erledigt' 'a finished entry waits on nothing'
assert_contains "$out" 'Bedingung unpruefbar hinterlegt: ragdigital-belegung' \
  'a hold that says it is waiting for something is an external wait, typed or not'
assert_not_contains "$out" 'post-launch-paket' \
  "a hold on firstmate's own upcoming event is not a wait on the world"
pass 'risk marker fires only for an undeclared external wait'

# ---------------------------------------------------------------------------
# No nagging, but no silence either.
# ---------------------------------------------------------------------------

home=$(new_home kein-genoergel)
entry "$home" hplan-runde-1 '(repo: hplan)' \
  'wartet-auf: pr-merged https://github.com/example/hplan/pull/1'
stub_gh_pr_state MERGED
first=$(run_check "$home")
assert_contains "$first" 'laengst erfuellt' 'the first sweep reports the finding'
second=$(run_check "$home")
[ -z "$second" ] || fail "an unchanged finding was reported twice: $second"
pass 'an unhandled finding is reported once, not on every poll'

entry "$home" zweiter-eintrag '(hold: wartet auf etwas) (hold-kind: external)'
third=$(run_check "$home")
assert_contains "$third" 'Bedingung unpruefbar hinterlegt: zweiter-eintrag' \
  'a new finding is news again even while an older one is still open'
assert_contains "$third" 'hplan-runde-1' \
  'the standing finding is repeated alongside the new one, not dropped'
pass 'a changed finding set is reported again'

# The cadence gate keeps the sweep off most watcher cycles, and a frozen clock
# must not be able to disable the sweep budget along with it.
home=$(new_home kadenz)
entry "$home" hplan-runde-1 '(repo: hplan)' \
  'wartet-auf: pr-merged https://github.com/example/hplan/pull/1'
stub_gh_pr_state MERGED
out=$(env FM_HOME="$home" FM_WARTE_NOW=1000000 "$WARTE" check 2>&1)
assert_contains "$out" 'laengst erfuellt' 'the first sweep runs'
out=$(env FM_HOME="$home" FM_WARTE_NOW=1000060 "$WARTE" check 2>&1)
[ -z "$out" ] || fail "the check swept again inside its cadence: $out"
pass 'the sweep runs on its own cadence rather than on every watcher cycle'

# ---------------------------------------------------------------------------
# The cmd probe and the trust binding it runs under.
# ---------------------------------------------------------------------------

home=$(new_home cmd-ungebunden)
sentinel="$home/cmd-ran"
entry "$home" externes-kommando '(hold: wartet auf etwas) (hold-kind: external)' \
  "wartet-auf: cmd touch $sentinel"
out=$(run_check "$home")
assert_contains "$out" 'Wartebedingung nicht pruefbar: externes-kommando' \
  'an unbound cmd probe is refused out loud'
assert_contains "$out" 'gebundenem Check' 'the refusal names the binding it needs'
assert_absent "$sentinel" 'an unbound cmd probe must not run the command'
pass 'a cmd condition is refused, and reported as refused, while the check is unbound'

env FM_HOME="$home" "$WARTE" arm >/dev/null || fail 'arming failed'
[ -x "$home/state/wartebedingungen.check.sh" ] || fail 'arming wrote no check'
[ -f "$home/state/wartebedingungen.check-trust" ] || fail 'arming wrote no trust binding'
out=$(run_check "$home")
assert_contains "$out" 'Bedingung laengst erfuellt: externes-kommando' \
  'a bound cmd probe that exits 0 ends the wait'
assert_present "$sentinel" 'a bound cmd probe actually runs the command'
pass 'a cmd condition runs once the check is bound to its bytes'

# Editing the check after binding breaks the binding, and the cmd probe has to
# notice: this is the mechanic that keeps backlog text from becoming a way to run
# something the watcher never authenticated.
home=$(new_home cmd-verbogen)
sentinel="$home/cmd-ran"
entry "$home" externes-kommando '(hold: wartet auf etwas) (hold-kind: external)' \
  "wartet-auf: cmd touch $sentinel"
env FM_HOME="$home" "$WARTE" arm >/dev/null || fail 'arming failed'
printf '# nachtraeglich veraendert\n' >> "$home/state/wartebedingungen.check.sh"
out=$(run_check "$home")
assert_contains "$out" 'Wartebedingung nicht pruefbar: externes-kommando' \
  'a mutated check no longer authorizes its cmd probes'
assert_absent "$sentinel" 'a mutated check must not run a cmd probe'
pass 'a check edited after binding stops authorizing cmd probes'

home=$(new_home cmd-abgeruestet)
entry "$home" externes-kommando '(hold: wartet auf etwas) (hold-kind: external)' \
  'wartet-auf: cmd true'
env FM_HOME="$home" "$WARTE" arm >/dev/null || fail 'arming failed'
env FM_HOME="$home" "$WARTE" disarm >/dev/null || fail 'disarming failed'
assert_absent "$home/state/wartebedingungen.check.sh" 'disarming left the check behind'
assert_absent "$home/state/wartebedingungen.check-trust" 'disarming left the binding behind'
out=$(run_check "$home")
assert_contains "$out" 'Wartebedingung nicht pruefbar: externes-kommando' \
  'a disarmed home refuses cmd probes again'
pass 'disarming removes the check, its binding, and its authority'

# ---------------------------------------------------------------------------
# The remaining built-in probe kinds, and an unusable deposit.
# ---------------------------------------------------------------------------

home=$(new_home datum)
entry "$home" trooper-delta-sicherung \
  '(hold: Zeitfenster ab 28.08.) (hold-kind: future) (hold-until: 2026-08-28)' \
  'wartet-auf: datum 2026-08-28'
out=$(run_check "$home")
assert_not_contains "$out" 'laengst erfuellt' 'a date gate before its date keeps waiting'
out=$(env FM_HOME="$home" FM_WARTE_INTERVAL=0 FM_WARTE_TODAY=2026-08-28 "$WARTE" check 2>&1)
assert_contains "$out" 'Bedingung laengst erfuellt: trooper-delta-sicherung' \
  'a date gate wakes on the day it opens'
pass 'a date window is reported when it opens instead of lapsing unnoticed'

home=$(new_home rollout)
entry "$home" ragdigital-belegung '(hold: wartet auf HPlan-Dienst) (hold-kind: external)' \
  'wartet-auf: url-status https://hplan.example/belegung 200'
stub_curl_status 503
out=$(run_check "$home")
assert_not_contains "$out" 'laengst erfuellt' 'a service still answering 503 keeps waiting'
stub_curl_status 200
out=$(env FM_HOME="$home" FM_WARTE_INTERVAL=0 "$WARTE" check 2>&1)
assert_contains "$out" 'Bedingung laengst erfuellt: ragdigital-belegung' \
  'a rolled-out service ends the wait'
pass 'a rollout is asked about rather than remembered'

home=$(new_home unbrauchbar)
entry "$home" kaputte-zeile '(hold: wartet auf etwas) (hold-kind: external)' \
  'wartet-auf: telepathie irgendwas'
entry "$home" kaputte-url '(repo: hplan)' \
  'wartet-auf: pr-merged nicht-mal-eine-url'
out=$(run_check "$home")
assert_contains "$out" 'Wartebedingung nicht pruefbar: kaputte-zeile' \
  'an unknown probe kind is reported rather than ignored'
assert_contains "$out" 'Wartebedingung nicht pruefbar: kaputte-url' \
  'an unusable URL is reported rather than ignored'
pass 'a deposit the guard cannot use is reported, never quietly skipped'

# ---------------------------------------------------------------------------
# Bounds: the sweep has to end well inside the watcher's own per-check timeout,
# because a check the watcher kills prints nothing and would repeat that silence.
# ---------------------------------------------------------------------------

home=$(new_home zeitrahmen)
entry "$home" haengende-probe '(hold: wartet auf etwas) (hold-kind: external)' \
  'wartet-auf: cmd sleep 120'
entry "$home" zweite-probe '(hold: wartet auf etwas) (hold-kind: external)' \
  'wartet-auf: cmd sleep 120'
env FM_HOME="$home" "$WARTE" arm >/dev/null || fail 'arming failed'
started=$(date +%s)
out=$(env FM_HOME="$home" FM_WARTE_INTERVAL=0 FM_WARTE_BUDGET_SECS=3 FM_WARTE_PROBE_SECS=2 \
  "$WARTE" check 2>&1)
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 20 ] || fail "the sweep ran $elapsed seconds despite a 3 second budget"
assert_contains "$out" 'Wartebedingung nicht pruefbar' 'a probe killed by its bound is reported'
pass 'a hanging condition cannot run the sweep past its budget'

home=$(new_home budgetschnitt)
entry "$home" irgendetwas '(hold: wartet auf etwas) (hold-kind: external)'
out=$(env FM_HOME="$home" FM_WARTE_INTERVAL=0 FM_WARTE_BUDGET_SECS=120 FM_CHECK_TIMEOUT=10 \
  "$WARTE" check 2>&1)
assert_contains "$out" 'Zeitbudget' 'a budget wider than the watcher timeout is cut, and says so'
pass 'the sweep budget is cut to the watcher timeout instead of being refused'

# ---------------------------------------------------------------------------
# A missing backlog is a finding, not silence.
# ---------------------------------------------------------------------------

home=$(new_home ohne-backlog)
rm -f "$home/data/backlog.md"
out=$(run_check "$home")
assert_contains "$out" 'Wartebedingungen nicht pruefbar' 'a missing backlog is reported'
if env FM_HOME="$home" "$WARTE" arm >/dev/null 2>&1; then
  fail 'arming succeeded without a backlog to guard'
fi
assert_absent "$home/state/wartebedingungen.check.sh" \
  'a refused arm must leave no unregistered check behind'
pass 'a home with no backlog reports that, and cannot be armed'

# ---------------------------------------------------------------------------
# The report is the retrofit worklist: it names every scanned entry, whether or
# not it has a condition, so the gap is read off the machine rather than memory.
# ---------------------------------------------------------------------------

home=$(new_home bericht)
entry "$home" mit-bedingung '(hold: wartet auf etwas) (hold-kind: external)' \
  'wartet-auf: datum 2026-12-01'
entry "$home" ohne-bedingung '(hold: wartet auf Antwort) (hold-kind: external)'
out=$(env FM_HOME="$home" FM_WARTE_TODAY=2026-08-22 "$WARTE" report 2>&1)
assert_contains "$out" 'mit-bedingung: datum 2026-12-01' 'the report shows a deposited condition'
assert_contains "$out" 'ohne-bedingung: keine wartet-auf-Zeile' \
  'the report names an entry that still needs a condition'
assert_contains "$out" 'NICHT gebunden' 'the report says whether cmd probes are authorized'
pass 'the report lists every watched entry and what it still lacks'

# ---------------------------------------------------------------------------
# A deposited condition is data, not shell source. Its fields must reach the
# probe as the characters that were written, whatever the working directory the
# watcher happens to run the check from contains.
# ---------------------------------------------------------------------------

home=$(new_home keine-expansion)
entry "$home" muster-eintrag '(hold: wartet auf etwas) (hold-kind: external)' \
  'wartet-auf: url-status * 200'
# A directory whose contents a pattern field would visibly expand into.
mkdir -p "$home/cwd"
: > "$home/cwd/beispieldatei"
out=$(cd "$home/cwd" && run_check "$home")
assert_contains "$out" 'url-status verlangt eine https-URL: *' \
  'a pattern field reaches the probe as the character that was written'
assert_not_contains "$out" 'beispieldatei' \
  'a pattern field must not be expanded against the working directory'
pass 'a pattern in a condition is never expanded against the working directory'

# The cmd remainder is handed over verbatim rather than re-split and re-joined,
# because collapsing its spacing would change the command that runs.
home=$(new_home cmd-woertlich)
printf 'zwei  leerzeichen\n' > "$home/muster.txt"
entry "$home" woertliches-kommando '(hold: wartet auf etwas) (hold-kind: external)' \
  "wartet-auf: cmd grep -q 'zwei  leerzeichen' $home/muster.txt"
env FM_HOME="$home" "$WARTE" arm >/dev/null || fail 'arming failed'
out=$(run_check "$home")
assert_contains "$out" 'Bedingung laengst erfuellt: woertliches-kommando' \
  'the cmd remainder keeps the spacing it was written with'
pass 'a cmd condition reaches the shell exactly as it was deposited'

# ---------------------------------------------------------------------------
# The watcher's own dispatch path: it validates the armed check against its trust
# binding, copies it to a private snapshot, and runs that copy with `bash`. The
# guard has to produce its finding through exactly that path, not just when
# invoked directly, or arming it would achieve nothing.
# ---------------------------------------------------------------------------

home=$(new_home waechter-weg)
entry "$home" hplan-runde-1 '(repo: hplan)' \
  'wartet-auf: pr-merged https://github.com/example/hplan/pull/1'
stub_gh_pr_state MERGED
env FM_HOME="$home" "$WARTE" arm >/dev/null || fail 'arming failed'

out=$(FM_HOME="$home" FM_WARTE_INTERVAL=0 bash -c '
  . "$1/bin/fm-pr-lib.sh"
  . "$1/bin/fm-check-lib.sh"
  fm_custom_check_snapshot_prepare "$2/state" wartebedingungen || { echo "SNAPSHOT-REFUSED"; exit 0; }
  bash "$FM_CUSTOM_CHECK_SNAPSHOT"
  fm_custom_check_snapshot_cleanup
' _ "$ROOT" "$home" 2>&1)
assert_contains "$out" 'Bedingung laengst erfuellt: hplan-runde-1' \
  'the armed check produces its finding through the watcher dispatch path'
pass 'the watcher can validate, snapshot, and run the armed check'

# The same path with a broken binding: the watcher would reject the check
# outright, which is the state a home must never be left in silently.
printf '# nachtraeglich veraendert\n' >> "$home/state/wartebedingungen.check.sh"
out=$(bash -c '
  . "$1/bin/fm-pr-lib.sh"
  . "$1/bin/fm-check-lib.sh"
  fm_custom_check_snapshot_prepare "$2/state" wartebedingungen && { echo "SNAPSHOT-ACCEPTED"; exit 0; }
  echo "SNAPSHOT-REFUSED"
' _ "$ROOT" "$home" 2>&1)
assert_contains "$out" 'SNAPSHOT-REFUSED' \
  'a check edited after binding is refused by the same validation the watcher uses'
pass 'an edited check is refused before it can run'

printf 'ok - fm-wartebedingungen\n'
