#!/usr/bin/env bash
# tests/fm-regel-eval.test.sh - meta-golden tests for the rule gate.
#
# The gate's own promise is that it goes RED on the breaches it names. So each
# case builds a complete, green fixture rulebook under mktemp, breaks exactly
# one thing, and demands the matching FATAL. Green-without / red-with, in that
# order, for every rung the gate claims to hold:
#
#   0. the untouched fixture passes armed, and `run` runs its golden suite and
#      names the reason the retrieval suite is skipped
#   1. a synthetic 9th core rule breaks the VERFASSUNG cap  -> red
#   2. a v2 rule without an anchor                          -> red
#   3. an anchor with no lesson in the ledger               -> red
#   4. a newly added rule without the post-incident ladder  -> red
#   5. an AGENTS.md Reader: clause naming a dead file       -> red
#   6. an AGENTS.md line pointing at a skill                -> red
#   7. AGENTS.md over its own 60-line cap                   -> red
#   8. a hook reader not registered in .claude/settings.json-> red
#   9. a tor reader without a colocated test                -> red
#  10. an incident-born rule (leiter:) without verfall:     -> red
#  11. coverage debt growing past its ratchet stand         -> red
#  12. a dead "AGENTS.md section N" pointer in docs/        -> red
#  13. THE REAL repo passes the armed gate
#
# Everything resolves under FM_REGEL_EVAL_ROOT, so no case can touch the repo.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVAL="$REPO/bin/fm-regel-eval.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
T=$(printf '\t')

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

lauf() {
  local root="$1"; shift
  FM_REGEL_EVAL_ROOT="$root" FM_HOME="$root" bash "$EVAL" "$@" 2>&1
}

friere() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=tt -c user.email=t@t -c commit.gpgsign=false \
    commit -q -m fixture >/dev/null 2>&1
}

# rot <dir> <pattern> <label> - the gate must go red, and for the named reason.
rot() {
  local dir="$1" muster="$2" label="$3" out rc
  out=$(lauf "$dir" check --scharf); rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label: the gate stayed GREEN"
  elif printf '%s' "$out" | grep -qE "$muster"; then
    ok "$label"
  else
    fail "$label: red, but not for the named reason (wanted /$muster/), got:
$(printf '%s' "$out" | grep '^FATAL' | sed 's/^/    /')"
  fi
}

# --- the green fixture ------------------------------------------------------
kern_regel() {
  # kern_regel <id> <verbindlichkeit> <anker> <quelle> <leser> [extra-yaml-line]
  cat <<YAML
  - id: $1
    geltung: flotte
    verbindlichkeit: $2
    severity: 3
    anker: [$3]
    quelle: $4
    leser: $5
    verfall: null
${6:+    $6}
    trigger: >
      Something the fixture rule reacts to happens.
    statement: >
      The fixture rule states its duty in one sentence.
YAML
}

baue_fixture() {
  local d="$1"
  mkdir -p "$d/bin" "$d/tests" "$d/regeln" "$d/data/forensik-2026-08" "$d/.claude"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/fm-hook.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/fm-tor.sh"
  chmod +x "$d/bin/fm-hook.sh" "$d/bin/fm-tor.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/fm-hook.test.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/fm-tor.test.sh"

  cat > "$d/AGENTS.md" <<'MD'
# Fixture fleet order

> regel-eval: enforced - the gate reads this file.

## Hard rules - each line names its reader
1. **HR1 (untouchable): Nothing is written blind.**
   Reader: bin/fm-hook.sh refuses the write at the point of action.
2. **HR2 (rebuilt): Landing passes the acceptance gate.**
   Reader: bin/fm-tor.sh answers the brief's acceptance criteria.

## Maintaining this file
This file stays under 60 lines; a new line needs a reader, or it goes into regeln/.
MD

  cat > "$d/regeln/VERFASSUNG.yaml" <<'YAML'
kern_max: 8
kern_token_max: 1200
kontext_max_je_geltung: 12
kontext_max_gesamt: 40
topk: 3
brief_token_max: 600
YAML

  {
    echo 'rules:'
    kern_regel TEST-KERN-001 kern 'L01, HR1' grundsatz:1 hook:bin/fm-hook.sh
    kern_regel TEST-TOR-001 kontext 'L02, HR2' order:O-42 tor:bin/fm-tor.sh
  } > "$d/regeln/kern.yaml"

  cat > "$d/data/forensik-2026-08/lehren-ledger.md" <<'MD'
# Lessons ledger (fixture)

### L01 Blind writes
A write nobody read went into the wrong tree.

### L02 Landing without a gate
Work was reported done that was never measured at the target.
MD

  cat > "$d/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/fm-hook.sh" }
        ]
      }
    ]
  }
}
JSON

  {
    printf '# fixture manifest\n'
    printf 'hook-row%sL01%sblind writes are refused at the point of action%stest:tests/fm-hook.test.sh\n' "$T" "$T" "$T"
    printf 'tor-row%sL02%slanding passes the acceptance gate%stest:tests/fm-tor.test.sh\n' "$T" "$T" "$T"
  } > "$d/tests/regel-eval.manifest.tsv"

  git -C "$d" init -q -b main >/dev/null 2>&1
  friere "$d"
}

# kopie <name> - a fresh copy of the green fixture, git history included.
kopie() {
  local d="$TMP/$1"
  cp -a "$TMP/gruen" "$d"
  printf '%s\n' "$d"
}

baue_fixture "$TMP/gruen"

# --- 0. the untouched fixture is green --------------------------------------
out=$(lauf "$TMP/gruen" check --scharf); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'gate passed'; then
  ok "the untouched fixture rulebook passes the armed gate"
else
  fail "the green fixture must pass armed, got:
$(printf '%s' "$out" | sed 's/^/    /')"
fi

out=$(lauf "$TMP/gruen" run --scharf); rc=$?
if [ "$rc" -ne 0 ]; then
  fail "run must be green on the green fixture, got:
$(printf '%s' "$out" | sed 's/^/    /')"
elif ! printf '%s' "$out" | grep -q 'golden suite: 2 test file(s), 0 failed'; then
  fail "run must execute both mapped tests, got: $(printf '%s' "$out" | tail -n 3)"
elif ! printf '%s' "$out" | grep -q 'golden retrieval: skipped'; then
  fail "a missing retrieval suite must be skipped with a named reason"
else
  ok "run executes the golden suite and names why retrieval is skipped"
fi

# --- 1. the synthetic 9th core rule breaks the cap --------------------------
d=$(kopie deckel)
{
  echo 'rules:'
  for n in 1 2 3 4 5 6 7 8 9; do
    kern_regel "TEST-KERN-00$n" kern 'L01, HR1' grundsatz:1 hook:bin/fm-hook.sh
  done
  kern_regel TEST-TOR-001 kontext 'L02, HR2' order:O-42 tor:bin/fm-tor.sh
} > "$d/regeln/kern.yaml"
friere "$d"
rot "$d" 'core set holds 9 rules, cap kern_max is 8' \
  "a 9th core rule hits the VERFASSUNG cap"

# --- 2. a rule without an anchor --------------------------------------------
d=$(kopie ankerlos)
{
  echo 'rules:'
  kern_regel TEST-KERN-001 kern 'L01, HR1' grundsatz:1 hook:bin/fm-hook.sh
  printf '  - id: TEST-ANKERLOS-001\n    geltung: flotte\n    verbindlichkeit: kontext\n    quelle: order:O-42\n    leser: tor:bin/fm-tor.sh\n    verfall: null\n    trigger: >\n      Anything.\n    statement: >\n      A duty with no documented failure behind it.\n'
} > "$d/regeln/kern.yaml"
friere "$d"
rot "$d" 'TEST-ANKERLOS-001.*missing v2 field\(s\): anker' \
  "a v2 rule without an anchor is refused"

# --- 3. an anchor with no lesson in the ledger ------------------------------
d=$(kopie totanker)
sed -i 's/\[L02, HR2\]/[L77, HR2]/' "$d/regeln/kern.yaml"
printf 'debt-row%sL77%suncovered%sprose:not yet mechanized\n' "$T" "$T" "$T" \
  >> "$d/tests/regel-eval.manifest.tsv"
friere "$d"
rot "$d" 'cites anchor L77, which has no .### L77 . entry' \
  "an anchor with no ledger lesson is refused"

# --- 4. a new rule without the post-incident ladder -------------------------
d=$(kopie neuaufnahme)
kern_regel TEST-NEU-001 kontext 'L02, HR2' grundsatz:1 tor:bin/fm-tor.sh \
  >> "$d/regeln/kern.yaml"
# deliberately NOT frozen: the diff against HEAD is what the gate reads
rot "$d" 'new rule TEST-NEU-001 .* is adopted without:.*post-incident ladder' \
  "a newly added rule without leiter/verfall/quelle:order is refused"

d=$(kopie neuaufnahme-vollstaendig)
kern_regel TEST-NEU-002 kontext 'L02, HR2' order:O-43 tor:bin/fm-tor.sh \
  'leiter: "gate sharpened first, this rule is the last rung"' > "$TMP/neu.yaml"
sed -i 's/^    verfall: null$/    verfall: 2099-01-01/' "$TMP/neu.yaml"
cat "$TMP/neu.yaml" >> "$d/regeln/kern.yaml"
out=$(lauf "$d" check --scharf); rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a new rule WITH leiter, verfall and quelle:order passes the diff gate"
else
  fail "the complete new rule must pass, got:
$(printf '%s' "$out" | grep '^FATAL' | sed 's/^/    /')"
fi

# --- 5. an AGENTS.md Reader: clause naming a dead file ----------------------
d=$(kopie toter-reader)
sed -i 's|Reader: bin/fm-tor.sh|Reader: bin/fm-gibt-es-nicht.sh|' "$d/AGENTS.md"
friere "$d"
rot "$d" 'names a reader that does not exist: bin/fm-gibt-es-nicht.sh' \
  "an AGENTS.md Reader: clause naming a dead file is refused"

# --- 6. AGENTS.md pointing at a skill ---------------------------------------
d=$(kopie skillzeiger)
printf 'See .claude/skills/firstmate-coding-guidelines for the rest.\n' >> "$d/AGENTS.md"
friere "$d"
rot "$d" 'AGENTS.md points at a skill' \
  "AGENTS.md may not point at a skill name"

# --- 7. AGENTS.md over its own 60-line cap ----------------------------------
d=$(kopie deckel60)
for _ in $(seq 1 60); do echo 'Filler line without a reader.' >> "$d/AGENTS.md"; done
friere "$d"
rot "$d" 'AGENTS.md has [0-9]+ lines \(limit 60' \
  "AGENTS.md over 60 lines is refused"

# --- 8. a hook reader that is not registered --------------------------------
d=$(kopie hook-unregistriert)
printf '{ "hooks": {} }\n' > "$d/.claude/settings.json"
friere "$d"
rot "$d" 'names hook reader bin/fm-hook.sh, which is NOT registered' \
  "an unregistered hook reader is refused"

# --- 9. a tor reader without a colocated test -------------------------------
d=$(kopie tor-ohne-test)
rm -f "$d/tests/fm-tor.test.sh"
sed -i '/tor-row/d' "$d/tests/regel-eval.manifest.tsv"
printf 'tor-row%sL02%slanding passes the acceptance gate%sprose:not yet mechanized\n' \
  "$T" "$T" "$T" >> "$d/tests/regel-eval.manifest.tsv"
friere "$d"
rot "$d" 'names reader bin/fm-tor.sh without a colocated test' \
  "a tor reader without a colocated test is refused"

# --- 10. an incident-born rule without an expiry ----------------------------
d=$(kopie leiter-ohne-verfall)
{
  echo 'rules:'
  kern_regel TEST-KERN-001 kern 'L01, HR1' grundsatz:1 hook:bin/fm-hook.sh
  kern_regel TEST-TOR-001 kontext 'L02, HR2' order:O-42 tor:bin/fm-tor.sh \
    'leiter: "born from the incident of 2026-08-25"'
} > "$d/regeln/kern.yaml"
sed -i '/TEST-TOR-001/,$ s/^    verfall: null$//' "$d/regeln/kern.yaml"
friere "$d"
rot "$d" 'TEST-TOR-001 .* is incident-born .* but has no verfall' \
  "an incident-born rule without verfall: is refused"

# --- 11. coverage debt growing past its ratchet stand -----------------------
d=$(kopie schuld-waechst)
echo 0 > "$d/tests/regel-eval.schuld-stand"
sed -i 's/\[L02, HR2\]/[L02, L03, HR2]/' "$d/regeln/kern.yaml"
printf '\n### L03 A third lesson\nIt happened.\n' >> "$d/data/forensik-2026-08/lehren-ledger.md"
friere "$d"
rot "$d" 'coverage debt GREW: 1 \(ratchet stand 0' \
  "coverage debt growing past its ratchet stand is refused"

# --- 12. a dead AGENTS.md section pointer in docs/ --------------------------
d=$(kopie deadref)
mkdir -p "$d/docs"
printf 'The contract lives in AGENTS.md section 3.\n' > "$d/docs/irgendwas.md"
friere "$d"
rot "$d" 'dead references GREW: 1|dead references: 1 open item' \
  "a dead 'AGENTS.md section N' pointer in docs/ is refused"

# --- 13. the real repo passes its own armed gate ----------------------------
out=$("$EVAL" check --scharf 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  ok "the real repo passes the armed gate"
else
  fail "the real rulebook must pass its own gate, got:
$(printf '%s' "$out" | grep '^FATAL' | sed 's/^/    /')"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-regel-eval.test.sh: all checks passed"
  exit 0
fi
echo "fm-regel-eval.test.sh: $FAILS check(s) FAILED"
exit 1
