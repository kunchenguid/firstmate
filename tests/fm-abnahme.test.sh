#!/usr/bin/env bash
# tests/fm-abnahme.test.sh - proves the acceptance TOR (bin/fm-abnahme.sh)
# actually gates, and gates on the right things:
#
#   0. Flag off: both subcommands exit 0 in total silence, whatever the
#      brief/report content, proving the transition rule (gate built, not live).
#   1. check-brief: rot without a wellformed A-point, rot on missing brief,
#      rot when Captain-Flaeche: ja lacks a klickbeleg point, gruen otherwise.
#   2. check-report: rot on a missing report, rot on a missing judgment line,
#      rot on prose instead of a verdict, rot on an unknown A-number, rot on
#      a duplicate judgment line.
#   3. Verdicts: 'unklar - <Grund>' and 'nicht-erfüllt - <Grund>' are gruen
#      with no evidence needed; 'erfüllt' needs an existing beleg file (rot
#      if missing).
#   4. Art-Prüfung: testlauf evidence without the 'gelaufen: ...' line is
#      gelb (exit 3), and beleg=sonstig on 'erfüllt' is always gelb.
#   5. --legacy: a brief without an Abnahme block prints the LEGACY line and
#      exits 3 (gelb), never green; once state/.abnahme-legacy-verfall names
#      a past UTC date, the same call turns rot.
#
# Isolation: everything runs against a throwaway FM_HOME (state/, data/);
# nothing touches the real fleet.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin/fm-abnahme.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state" "$HOME_A/data"
FLAG="$HOME_A/state/.tor-abnahme-scharf"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

fresh_task() { # fresh_task <task-id> -> wipes and recreates data/<task-id>
  rm -rf "${HOME_A:?}/data/${1:?}"
  mkdir -p "$HOME_A/data/$1/belege"
}

# --- 0. Flag off: silent pass regardless of content -------------------------
rm -f "$FLAG"
fresh_task off1
out=$(FM_HOME="$HOME_A" "$BIN" check-brief off1 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "check-brief with the flag absent exits 0 in silence, even with no brief"
else
  fail "check-brief must exit 0 silently without the flag (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/off1/brief.md" <<'EOF'
## Abnahme (maschinenlesbar)
- [A1] Prosa ohne Regel :: beleg=diff
EOF
cat > "$HOME_A/data/off1/report.md" <<'EOF'
this is not a verdict line at all
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report off1 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "check-report with the flag absent exits 0 in silence, even on prose"
else
  fail "check-report must exit 0 silently without the flag (rc=$rc out=$out)"
fi

# Arm the gate for every remaining case.
touch "$FLAG"

# --- 1. check-brief ----------------------------------------------------------
fresh_task b1
out=$(FM_HOME="$HOME_A" "$BIN" check-brief b1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "kein Brief"; then
  ok "check-brief refuses rot when the brief file is missing, naming the path"
else
  fail "check-brief must refuse rot on a missing brief (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/b1/brief.md" <<'EOF'
# Auftrag ohne Abnahmeblock
Nur Prosa hier.
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-brief b1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Ausweg:"; then
  ok "check-brief refuses rot without a wellformed A-point, naming an Ausweg"
else
  fail "check-brief must refuse rot on zero A-points (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/b1/brief.md" <<'EOF'
Captain-Flaeche: ja

## Abnahme (maschinenlesbar)
- [A1] Diff ist minimal :: beleg=diff
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-brief b1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Captain-Flaeche" && printf '%s' "$out" | grep -q "klickbeleg"; then
  ok "Captain-Flaeche: ja without a klickbeleg point is refused rot, quoting the header"
else
  fail "check-brief must refuse rot on Captain-Flaeche without klickbeleg (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/b1/brief.md" <<'EOF'
Captain-Flaeche: ja

## Abnahme (maschinenlesbar)
- [A1] Diff ist minimal :: beleg=diff
- [A2] Klick sichtbar :: beleg=klickbeleg
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-brief b1 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "^GRUEN:"; then
  ok "check-brief is gruen with a klickbeleg point satisfying Captain-Flaeche"
else
  fail "check-brief must be gruen once klickbeleg is present (rc=$rc out=$out)"
fi

out=$(FM_HOME="$HOME_A" "$BIN" check-brief b1 --brief /does/not/exist 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "/does/not/exist"; then
  ok "check-brief --brief honors an explicit path and refuses rot when it is missing"
else
  fail "check-brief --brief must resolve an explicit path (rc=$rc out=$out)"
fi

# --- 2. check-report structural checks ---------------------------------------
fresh_task r1
cat > "$HOME_A/data/r1/brief.md" <<'EOF'
## Abnahme (maschinenlesbar)
- [A1] Login klappt :: beleg=klickbeleg
- [A2] Tests laufen :: beleg=testlauf
EOF

out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "kein Bericht"; then
  ok "check-report refuses rot when the report file is missing"
else
  fail "check-report must refuse rot on a missing report (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/r1/report.md" <<'EOF'
A1: unklar - noch offen
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "A2"; then
  ok "check-report refuses rot when a brief A-point has no judgment line"
else
  fail "check-report must refuse rot on a missing judgment line (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/r1/report.md" <<'EOF'
A1: unklar - noch offen
Wir denken A2 ist erledigt, sieht gut aus.
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Prosa"; then
  ok "check-report refuses rot on a prose line where a verdict belongs"
else
  fail "check-report must refuse rot on prose (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/r1/report.md" <<'EOF'
A1: unklar - noch offen
A2: unklar - noch offen
A9: erfüllt - nirgendwo.png
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "A9"; then
  ok "check-report refuses rot on a judgment line with no matching brief point"
else
  fail "check-report must refuse rot on an unknown A-number (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/r1/report.md" <<'EOF'
A1: unklar - noch offen
A1: nicht-erfüllt - doppelt
A2: unklar - noch offen
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "mehr als eine"; then
  ok "check-report refuses rot on a duplicate judgment line for one A-point"
else
  fail "check-report must refuse rot on a duplicate judgment line (rc=$rc out=$out)"
fi

# --- 3. unklar/nicht-erfüllt need no evidence; erfüllt needs an existing file
cat > "$HOME_A/data/r1/report.md" <<'EOF'
A1: unklar - noch nicht geprüft
A2: nicht-erfüllt - keine Zeit gehabt
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "^GRUEN:"; then
  ok "'unklar' and 'nicht-erfüllt' with a reason are gruen without any evidence file"
else
  fail "'unklar'/'nicht-erfüllt' must be gruen (rc=$rc out=$out)"
fi

cat > "$HOME_A/data/r1/report.md" <<'EOF'
A1: erfüllt - klick.png
A2: unklar - noch offen
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Beleg-Datei fehlt"; then
  ok "'erfüllt' with a non-existent beleg path is refused rot"
else
  fail "'erfüllt' must be refused rot without an existing beleg file (rc=$rc out=$out)"
fi

# --- 4. Art-Prüfung: mismatch and sonstig are gelb, not rot -----------------
echo "not the right shape" > "$HOME_A/data/r1/belege/lauf.txt"
touch "$HOME_A/data/r1/belege/klick.png"
cat > "$HOME_A/data/r1/report.md" <<'EOF'
A1: erfüllt - klick.png
A2: erfüllt - lauf.txt
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qi "gelaufen:"; then
  ok "testlauf evidence missing the 'gelaufen: ...' line is gelb (exit 3), naming the requirement"
else
  fail "testlauf Art-Mismatch must be gelb exit 3 (rc=$rc out=$out)"
fi

echo "gelaufen: 3 Tests, exit=0" > "$HOME_A/data/r1/belege/lauf.txt"
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "^GRUEN:"; then
  ok "testlauf evidence carrying the 'gelaufen: ...' line is gruen"
else
  fail "well-formed testlauf evidence must be gruen (rc=$rc out=$out)"
fi

touch "$HOME_A/data/r1/belege/irgendwas.bin"
cat > "$HOME_A/data/r1/report-sonstig.md" <<'EOF'
A1: erfüllt - irgendwas.bin
EOF
cat > "$HOME_A/data/r1/brief.md" <<'EOF'
## Abnahme (maschinenlesbar)
- [A1] Irgendwas :: beleg=sonstig
EOF
out=$(FM_HOME="$HOME_A" "$BIN" check-report r1 --report "$HOME_A/data/r1/report-sonstig.md" 2>&1)
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qi "sonstig"; then
  ok "beleg=sonstig on 'erfüllt' is always gelb (exit 3), even with an existing beleg file"
else
  fail "beleg=sonstig must always be gelb on 'erfüllt' (rc=$rc out=$out)"
fi

# --- 5. --legacy: gelb, never green; rot once the grace period has passed --
fresh_task leg1
cat > "$HOME_A/data/leg1/brief.md" <<'EOF'
# alter Auftrag ohne Abnahmeblock
Historisch gewachsen, kein Block hier.
EOF

out=$(FM_HOME="$HOME_A" "$BIN" check-report leg1 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then
  ok "check-report without --legacy refuses rot on a brief with no Abnahme block"
else
  fail "check-report must refuse rot without --legacy on a blockless brief (rc=$rc)"
fi

out=$(FM_HOME="$HOME_A" "$BIN" check-report leg1 --legacy 2>&1)
rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qF "LEGACY: Punkte vom Firstmate nachzutragen"; then
  ok "check-report --legacy prints the LEGACY line and exits 3 (gelb), never green"
else
  fail "check-report --legacy must print the LEGACY line and exit 3 (rc=$rc out=$out)"
fi

echo "2000-01-01" > "$HOME_A/state/.abnahme-legacy-verfall"
out=$(FM_HOME="$HOME_A" "$BIN" check-report leg1 --legacy 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Verfall\|verfall"; then
  ok "check-report --legacy turns rot once state/.abnahme-legacy-verfall names a past date"
else
  fail "check-report --legacy must turn rot past the legacy-verfall date (rc=$rc out=$out)"
fi

rm -f "$HOME_A/state/.abnahme-legacy-verfall"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all abnahme-tor checks passed"
