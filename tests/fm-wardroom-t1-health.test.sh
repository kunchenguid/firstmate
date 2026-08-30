#!/usr/bin/env bash
# T1 (health): the regression the repo lacked. A gate that can never pass is
# indistinguishable from a broken gate, and nothing noticed for 96 intake
# verdicts - 0 proceeds, 59 revises, 37 escalates - that the council had no
# reachable exit. This gate pins the detector: over a meaningful sample, a
# proceed rate of exactly zero is a FAULT the council reports on itself.
#
# Below the sample floor, zero proceeds means nothing and must stay quiet -
# a detector that cried wolf on the first three decisions would be muted.
# The judgement is a ROLLING WINDOW over the most recent decisions, not the
# all-time corpus: nothing prunes state/*.intake, so a cumulative count would be
# disarmed forever by the first proceed and could catch this regression once.
# Mutation (LEDGER_MUTATE=1): seed one proceed into the zero-proceed corpus -
# a correct detector then stays silent, failing the "must flag" assertions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

TMP=$(fm_test_tmproot fm-wd-t1h)
mkdir -p "$TMP/zero" "$TMP/healthy" "$TMP/small"

# A structurally-zero corpus: 12 decisions, not one proceed. This is the shape
# the real state/ was in when the council was found unable to say proceed.
seed_zero() {  # <state-dir>
  local i
  for i in 1 2 3 4 5 6; do
    fm_intake_append "$1" "task$i" panel "lens fugu some evidence"
    fm_intake_append "$1" "task$i" revise "(revise 1 of 2) the DoD is not machine-provable"
    fm_intake_append "$1" "task$i" escalate "revise cap reached (2 revises); captain decision required"
  done
}
seed_zero "$TMP/zero"
[ "${LEDGER_MUTATE:-}" = 1 ] && fm_intake_append "$TMP/zero" task1 proceed "mutation: a proceed exists"

seed_zero "$TMP/healthy"
fm_intake_append "$TMP/healthy" taskok proceed "panel proceed (lens=fugu)"

# Below the floor: three decisions, no proceed. Not enough sample to mean anything.
fm_intake_append "$TMP/small" tiny revise "(revise 1 of 2) x"
fm_intake_append "$TMP/small" tiny revise "(revise 2 of 2) x"
fm_intake_append "$TMP/small" tiny escalate "revise cap reached"

# --- 1. a structurally-zero corpus is FLAGGED --------------------------------
if line=$(fm_intake_health "$TMP/zero"); then
  fail "a corpus of 12 decisions with zero proceeds must be flagged (got: $line)"
fi
assert_contains "$line" "proceed=0" "the summary reports the proceed count"
assert_contains "$line" "proceed-rate=0%" "the summary reports the rate that is the fault"
assert_contains "$line" "decisions=12" "the summary reports the sample it judged"

# --- 2. one proceed is enough to clear it ------------------------------------
if ! line=$(fm_intake_health "$TMP/healthy"); then
  fail "a corpus with at least one proceed must not be flagged (got: $line)"
fi
assert_contains "$line" "proceed=1" "the healthy summary counts the proceed"

# --- 3. below the sample floor, stay quiet -----------------------------------
if ! line=$(fm_intake_health "$TMP/small"); then
  fail "3 decisions with no proceed is not evidence of a structural fault (got: $line)"
fi
# ...but it is once the floor is lowered to that sample.
if fm_intake_health "$TMP/small" 3 >/dev/null; then
  fail "with the floor at 3, the same corpus must be flagged"
fi

# --- 4. an empty corpus is not a fault ---------------------------------------
mkdir -p "$TMP/empty"
if ! line=$(fm_intake_health "$TMP/empty"); then
  fail "a council that has made no decisions at all is not broken (got: $line)"
fi
assert_contains "$line" "decisions=0" "an empty corpus reports zero decisions"

# --- 5. the window ROLLS, so the detector can never disarm itself ------------
# Read cumulatively this would be a one-shot: nothing prunes state/*.intake, so
# the first proceed ever recorded would silence the detector for the life of the
# corpus, and the prompt regression it exists to catch could only ever be caught
# once. Judged over the most recent decisions it stays live forever.
mkdir -p "$TMP/rolling"
fm_intake_append "$TMP/rolling" ancient proceed "the one proceed the council ever made"
i=1
while [ "$i" -le 21 ]; do
  fm_intake_append "$TMP/rolling" "later$i" revise "(revise 1 of 2) the bar drifted back to zero"
  i=$(( i + 1 ))
done
# Pin the ancient decision as genuinely oldest, so the ordering under test is
# recency and not whatever tie-break a coarse-mtime filesystem would apply.
touch -t 202601010000 "$(fm_intake_file "$TMP/rolling" ancient)"

if line=$(fm_intake_health "$TMP/rolling"); then
  fail "a proceed older than the window must not disarm the detector (got: $line)"
fi
assert_contains "$line" "proceed=0" "the window judges recent decisions, not the all-time corpus"
assert_contains "$line" "decisions=20" "the window is bounded at FM_INTAKE_HEALTH_WINDOW decisions"

# The same corpus is healthy again once the window is wide enough to hold the proceed.
if ! fm_intake_health "$TMP/rolling" 10 100 >/dev/null; then
  fail "with a window wide enough to include the proceed, the corpus is healthy"
fi
# ...and the window is a seam, not a constant.
if ! FM_INTAKE_HEALTH_WINDOW=100 fm_intake_health "$TMP/rolling" >/dev/null; then
  fail "FM_INTAKE_HEALTH_WINDOW must select the window"
fi

# Both seams are BOUNDS, not trust: a garbage value falls back to the default
# rather than erroring the comparison out into a silent pass. A watchdog that a
# stray environment variable can switch off is the exact failure this detector
# was built to catch, one level down.
for bad in '' abc 0 -1; do
  if FM_INTAKE_HEALTH_MIN="$bad" fm_intake_health "$TMP/zero" >/dev/null 2>&1; then
    fail "FM_INTAKE_HEALTH_MIN='$bad' must not disable the detector"
  fi
  if FM_INTAKE_HEALTH_WINDOW="$bad" fm_intake_health "$TMP/zero" >/dev/null 2>&1; then
    fail "FM_INTAKE_HEALTH_WINDOW='$bad' must not disable the detector"
  fi
done

# --- 6. fm-intake itself reports the fault when it decides -------------------
# The detector is worthless if nothing calls it, so intake carries it: every
# decision it records is followed by an honest read of the council's own record.
S="$TMP/live-state"; D="$TMP/live-data"; PROJ="$TMP/proj"
mkdir -p "$S" "$D/t1hlive" "$PROJ"
seed_zero "$S"
[ "${LEDGER_MUTATE:-}" = 1 ] && fm_intake_append "$S" task1 proceed "mutation: a proceed exists"
printf '# Task\nBuild it.\n' > "$D/t1hlive/brief.md"
cat > "$TMP/think-revise.sh" <<'SH'
#!/usr/bin/env bash
echo "PANEL: revise - the definition of done is not machine-provable"
SH
chmod +x "$TMP/think-revise.sh"
out=$(FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D" FM_LENS_CMD="echo stub" \
  FM_INTAKE_CMD="$TMP/think-revise.sh" "$ROOT/bin/fm-intake.sh" t1hlive "$PROJ" 2>&1) || true
assert_contains "$out" "proceed-rate=0%" "intake reports the council's own proceed rate when it is structurally zero"
assert_contains "$out" "never once proceeded" "the warning says plainly what is wrong"

pass "T1 proceed-rate detector: a council not proceeding reports itself, over a rolling window with a sample floor"
