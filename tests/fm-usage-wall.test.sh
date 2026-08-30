#!/usr/bin/env bash
# tests/fm-usage-wall.test.sh - behavior tests for bin/fm-usage-wall.sh, the
# provider-usage-wall surface.
#
# The defect this command exists to prevent is a usage limit being read as a
# crash, so the cases below are weighted toward the ways that misreading
# happens rather than toward the happy path:
#
#   headroom
#     (a) a measurable provider reports its percent, bounding window, reset and
#         runway
#     (b) tight by percent, tight by runway, and exhausted are distinguishable
#         from ok
#     (c) EVERY unmeasurable path - quota-axi absent, erroring, hanging,
#         printing no effective block, or reporting auth_required - reports
#         `unknown` and is never reported as healthy
#     (d) the auth_required line names the one-time operator command
#     (e) the reading survives upstream reordering or adding fields, because it
#         is resolved by field name out of the block's own header
#     (f) a below-floor quota-axi still yields a reading, labelled as such
#     (g) credentials are never prompted for: --allow-keychain-prompt is never
#         passed
#     (h) one reading costs one --version and one shared budget across both
#         calls, so a slow gauge cannot exhaust the caller's bound and read as
#         unmeasurable when it was readable
#     (i) a build that could not be READ reads `build=unknown`, never
#         `below-floor`, and the displayed version is the tool's own even when
#         the banner carries a runtime's
#     (j) a mixed reading summarizes as `partial` and still carries the
#         next-step pointer
#     (k) one declared JSON schema id ships exactly one object shape
#
#   diagnose
#     (l) a vendor limit line in the endpoint output is a `wall`
#     (m) a vendor limit line in a failed step's log is a `wall`, which is where
#         the 2026-08-23 evidence actually was
#     (n) transient transport wording (HTTP 429, "rate limited") is NOT a wall
#     (n2) this repository's OWN tracked documentation of this detector - the
#         recovery skill and the verification record, which quote the vendor
#         phrasings verbatim - never reads as a wall, while a genuine limit line
#         beside the harness's own exit still does
#     (o) a clean read is `no-signature`, an unreadable one is `unknown`, and a
#         cheap endpoint-only scan that finds nothing is `unknown` rather than a
#         clean bill of health
#     (p) a step the scan budget never reached is disclosed as `unscanned=`,
#         separately from a log that failed to read (`unread=`)
#     (q) a run reachable only through the `runs` table is attributed, and
#         another branch's run never is
#
#   resume
#     (r) a record is generated from live durable state and is readable back
#         from a separate process after the generating one exits
#     (s) it carries merge posture, branch, head and pipeline custody
#     (t) two tasks sharing one local copy are named on both rows
#     (u) a failed generation leaves the previous record intact
#     (v) a successful publish is a same-directory rename, so it does not depend
#         on TMPDIR and leaves no staging file behind
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WALL="$ROOT/bin/fm-usage-wall.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-wall)
fm_git_identity

# --- fixtures ---------------------------------------------------------------

# quota_toon <mode>: a quota-axi default-TOON report. The `effective[7]{...}`
# header deliberately reproduces the vendor's own quirk of declaring a count
# that does not match its field list, so the parser is pinned against the real
# shape rather than a tidied one.
quota_toon() {  # <healthy|tight-pct|tight-runway|exhausted|auth|no-quota|reordered|divergent|singular-only>
  # The FLOOR-COMPLIANT layout, as quota-axi 0.1.29 and newer emit it and as
  # verified live against 0.1.34 on this host: quota[], exhaustion[] and
  # attention[]. The pre-floor effective[]/providers[]/windows[] shape is not
  # generated here, because a build emitting it is refused before parsing.
  case "$1" in
    no-quota)
      # Neither table present: nothing to read, so nothing may be claimed.
      cat <<'EOF'
bin: /fake/quota-axi
EOF
      return 0
      ;;
    reordered)
      # Same facts, different field order, plus an unknown extra field.
      cat <<'EOF'
bin: /fake/quota-axi
quota[1]{someNewField,scope,provider,limitedBy,effectivePercentRemaining,runway,confidence,resetsAt}:
  ignored,all_models,claude,five_hour,84,projected_exhaustion,early,"2026-08-27T02:19:59Z"
exhaustion[1]{scope,provider,limitingWindowId,usableRunwaySeconds}:
  all_models,claude,five_hour,14400
EOF
      return 0
      ;;
    singular-only)
      # No limitedBy at all: one window bounds both answers, and the percentage
      # must still carry it rather than printing an absent-field marker.
      cat <<'EOF'
bin: /fake/quota-axi
quota[1]{provider,scope,effectivePercentRemaining,runway,confidence,resetsAt}:
  claude,all_models,84,projected_exhaustion,early,"2026-08-27T02:19:59Z"
exhaustion[1]{provider,scope,usableRunwaySeconds,limitingWindowId}:
  claude,all_models,14400,five_hour
EOF
      return 0
      ;;
    model-scoped-only)
      # A quota table that parses but yields no account-level row: a reading
      # nobody got, and both emitters must say so identically.
      cat <<'EOF'
bin: /fake/quota-axi
quota[1]{provider,scope,effectivePercentRemaining,runway,confidence,limitedBy,resetsAt}:
  claude,"model:fable",84,projected_exhaustion,early,five_hour,"2026-08-27T02:19:59Z"
EOF
      return 0
      ;;
    divergent)
      # The two windows answer different questions and disagree loudly: the
      # percentage is held down by the seven-day window while the runway is
      # bounded by the five-hour one. Mislabelling either is unmistakable here,
      # which is the point - a fixture where they agree cannot catch it.
      cat <<'EOF'
bin: /fake/quota-axi
quota[1]{provider,scope,effectivePercentRemaining,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,35,projected_exhaustion,early,seven_day,"2026-09-02T07:59:59Z"
exhaustion[1]{provider,scope,usableRunwaySeconds,limitingWindowId}:
  claude,all_models,2400,five_hour
EOF
      return 0
      ;;
  esac
  local pct=84 runway=14400
  case "$1" in
    tight-pct) pct=12 ;;
    tight-runway) pct=90; runway=600 ;;
    exhausted) pct=0 ;;
  esac
  printf 'bin: /fake/quota-axi\n'
  printf 'quota[1]{provider,scope,effectivePercentRemaining,runway,confidence,limitedBy,resetsAt}:\n'
  printf '  claude,all_models,%s,projected_exhaustion,early,five_hour,"2026-08-27T02:19:59Z"\n' "$pct"
  printf 'exhaustion[1]{provider,scope,usableRunwaySeconds,limitingWindowId}:\n'
  printf '  claude,all_models,%s,five_hour\n' "$runway"
  # attention[] is sparse and carries the reason a provider has no quota row.
  if [ "$1" = auth ]; then
    printf 'attention[1]{provider,scope,kind,detail,remedy}:\n'
    printf '  cursor,all,auth_required,Cursor sign-in required,none\n'
  else
    printf 'quota[1]{provider,scope,effectivePercentRemaining,runway,confidence,limitedBy,resetsAt}:\n'
    printf '  cursor,all_models,77,projected_exhaustion,early,seven_day,"2026-09-02T07:59:59Z"\n'
  fi
}

# fake_quota <fakebin> <mode> [version] [argv-log]
fake_quota() {
  local fb=$1 mode=$2 version=${3:-0.1.40} argv=${4:-}
  mkdir -p "$fb"
  quota_toon "$mode" > "$fb/.quota-report"
  cat > "$fb/quota-axi" <<SH
#!/usr/bin/env bash
[ -n "$argv" ] && printf 'headroom-probe %s\n' "\$*" >> "$argv"
if [ "\${1:-}" = --version ]; then printf '%s\n' "$version"; exit 0; fi
cat "$fb/.quota-report"
SH
  chmod +x "$fb/quota-axi"
}

fake_quota_failing() {  # <fakebin> <exit-code>
  local fb=$1 code=$2
  mkdir -p "$fb"
  cat > "$fb/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '0.1.40\n'; exit 0; fi
printf 'quota-axi: no provider could be read\n' >&2
exit $code
SH
  chmod +x "$fb/quota-axi"
}

fake_quota_hanging() {  # <fakebin>
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '0.1.40\n'; exit 0; fi
sleep 30
SH
  chmod +x "$fb/quota-axi"
}

run_headroom() {  # <fakebin> [args...]
  local fb=$1
  shift
  ( PATH="$fb:$PATH" "$WALL" headroom "$@" 2>&1 )
}

# --- headroom: a measurable provider ---------------------------------------

CASE="$TMP_ROOT/hr-healthy"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" healthy
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude ok pct=84' 'a measurable provider reports ok with its percent'
# Anchored on the whole sequence on purpose: a bare `bound=five_hour` is a
# SUBSTRING of `runway_bound=five_hour`, so the loose form passed while the
# percentage carried no window at all.
assert_contains "$OUT" 'pct=84 bound=five_hour resets=2026-08-27T02:19:59Z' \
  'the percentage names its bounding window and that window reset, not the runway label'
assert_contains "$OUT" 'runway=4h0m' 'the reading converts usable runway to whole units'
assert_contains "$OUT" 'confidence=early' 'the reading carries the projection confidence'
assert_contains "$OUT" 'verdict=ok measured=2 tight=0 wall=0 unknown=0' 'all-measured all-ok summarizes as ok'
assert_not_contains "$OUT" 'HEADROOM_NOTE' 'a fully measured healthy fleet needs no unmeasured warning'
pass 'headroom reports a measurable provider with window, reset and runway'

# --- headroom: each number carries the window that actually bounds IT --------
#
# Two windows answer two different questions. `limitingWindowIds` bounds the
# PERCENTAGE; `limitingWindowId` bounds the RUNWAY. Labelling the percentage
# with the runway's window read as "the five-hour window is at 35%" while that
# window was at 85%, and - the half that actually bites - paired the seven-day
# percentage with the five-hour RESET, which sends an operator off to wait out a
# window that is not the one holding them up. This fixture makes both windows
# disagree loudly, because one where they agree cannot catch either mistake.
CASE="$TMP_ROOT/hr-divergent"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" divergent
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'pct=35 bound=seven_day' \
  'the percentage is labelled with the window that bounds the percentage'
assert_contains "$OUT" 'resets=2026-09-02T07:59:59Z' \
  "the reset shown beside the percentage is that window's own reset"
assert_contains "$OUT" 'runway_bound=five_hour' \
  'the runway names its own limiting window when it differs'
# This layout publishes a reset only for the percentage's own window, so the
# runway's is reported as unknown rather than borrowed from the other window or
# quietly dropped. A borrowed clock is the failure this pair of fields exists to
# prevent: it sends a reader to wait out a window that was never the constraint.
assert_contains "$OUT" 'runway_resets=unknown' \
  "an unpublished reset is named as unknown, never borrowed from the other window"
assert_not_contains "$OUT" 'pct=35 bound=five_hour' \
  'the percentage must never be attributed to a window sitting at 85 percent'
pass 'headroom labels the percentage and the runway with their own windows and resets'

# --- headroom: a gauge that emits only the singular limiting window -----------
#
# `toon_block` yields "-" for a field absent from the block header, never an
# empty string, so a guard written as `[ -n "$win" ]` is always true and the
# fallback below it is dead code. The percentage then printed with NO window and
# NO reset at all - worse than the mislabel this pair of fixes started from. The
# assertion is anchored on the whole sequence because the loose form is a
# substring of the runway label and passed straight through the defect.
CASE="$TMP_ROOT/hr-singular-only"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" singular-only
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'pct=84 bound=five_hour resets=2026-08-27T02:19:59Z' \
  'a singular-only gauge still binds the percentage to that window and its reset'
assert_not_contains "$OUT" 'bound=-' 'the percentage must never print an absent-field marker as its window'
assert_not_contains "$OUT" 'resets=-' 'nor an absent-field marker as its reset'
assert_not_contains "$OUT" 'runway_bound=' \
  'with one window in play there is no second window to name'
pass 'headroom binds the percentage when the gauge emits only the singular window'

# --- headroom: tight and exhausted are distinguishable ----------------------

CASE="$TMP_ROOT/hr-tight-pct"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" tight-pct
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude tight pct=12' 'a low percent reads tight'
assert_contains "$OUT" 'verdict=tight' 'a tight provider makes the summary tight'
assert_contains "$OUT" 'HEADROOM_NEXT' 'a tight reading names the resume record as the next step'
pass 'headroom labels a low percent tight'

CASE="$TMP_ROOT/hr-tight-runway"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" tight-runway
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude tight pct=90' 'a short runway reads tight even at a high percent'
assert_contains "$OUT" 'runway=10m' 'the short runway itself is shown'
pass 'headroom labels a short runway tight independently of percent'

CASE="$TMP_ROOT/hr-exhausted"; mkdir -p "$CASE"
OUT=$(fake_quota "$CASE/fakebin" exhausted; run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude wall pct=0' 'an exhausted window reads as a wall'
# The aggregate must carry `wall`, not `tight`. These are different states, not
# degrees of one, and the whole command exists to keep "getting low" separable
# from "you have stopped"; an exhausted provider summarized as merely tight is a
# false reading of the one condition the surface was built to announce.
assert_contains "$OUT" 'verdict=wall' 'an exhausted provider makes the SUMMARY verdict wall, not tight'
assert_not_contains "$OUT" 'verdict=tight' 'an exhausted provider is never summarized as merely tight'
assert_contains "$OUT" 'AT the wall, not merely low' 'the wall summary says plainly that work has already stopped'
assert_contains "$OUT" 'HEADROOM_NEXT' 'a wall reading names the resume record as the next step'
pass 'headroom distinguishes an exhausted window from a merely tight one'

# A programmatic reader branches on `.verdict`, so the JSON must carry the same
# state the prose does.
OUT=$(fake_quota "$CASE/fakebin" exhausted; run_headroom "$CASE/fakebin" --json)
command -v jq >/dev/null 2>&1 && {
  printf '%s' "$OUT" | jq -e '.verdict == "wall" and .wall == 1 and .tight == 0' >/dev/null \
    || fail "--json .verdict must read wall for an exhausted provider: $OUT"
  pass 'headroom --json reports an exhausted provider as verdict=wall for a programmatic reader'
}

# A tight-but-not-exhausted provider must still summarize as tight, so the two
# states stay separable in both directions.
CASE="$TMP_ROOT/hr-tight-json"; mkdir -p "$CASE"
OUT=$(fake_quota "$CASE/fakebin" tight-pct; run_headroom "$CASE/fakebin" --json)
command -v jq >/dev/null 2>&1 && {
  printf '%s' "$OUT" | jq -e '.verdict == "tight" and .wall == 0 and .tight == 1' >/dev/null \
    || fail "--json .verdict must stay tight for a low-but-live provider: $OUT"
  pass 'headroom --json keeps a low-but-live provider separable from an exhausted one'
}

# --- headroom: every unmeasurable path reads unknown ------------------------

CASE="$TMP_ROOT/hr-absent"; mkdir -p "$CASE/fakebin"
OUT=$( PATH="$CASE/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "$WALL" headroom 2>&1 )
assert_contains "$OUT" 'unknown reason=quota-axi is not installed' 'an absent gauge reports why it is unmeasurable'
assert_contains "$OUT" 'verdict=unknown' 'an absent gauge summarizes as unknown'
assert_contains "$OUT" 'UNMEASURED, not healthy' 'an absent gauge is explicitly not healthy'
assert_not_contains "$OUT" ' ok ' 'an absent gauge never reports ok'
pass 'headroom reports an absent quota-axi as unknown, never as healthy'

CASE="$TMP_ROOT/hr-error"; mkdir -p "$CASE"
fake_quota_failing "$CASE/fakebin" 3
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'unknown reason=quota-axi exited 3' 'a failing gauge names its exit status'
assert_contains "$OUT" 'verdict=unknown' 'a failing gauge summarizes as unknown'
pass 'headroom reports a failing quota-axi as unknown'

CASE="$TMP_ROOT/hr-hang"; mkdir -p "$CASE"
fake_quota_hanging "$CASE/fakebin"
OUT=$( PATH="$CASE/fakebin:$PATH" FM_USAGE_WALL_QUOTA_TIMEOUT=1 "$WALL" headroom 2>&1 )
assert_contains "$OUT" 'did not answer within 1s' 'a hanging gauge is bounded and named'
assert_contains "$OUT" 'verdict=unknown' 'a hanging gauge summarizes as unknown'
pass 'headroom bounds a hanging quota-axi and reports unknown'

CASE="$TMP_ROOT/hr-noeff"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" no-quota
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'unknown reason=quota-axi printed no quota or attention block' \
  'a report with neither table is unmeasurable, not inferred from anything else'
assert_not_contains "$OUT" 'pct=84' 'a raw window percent is never presented as effective headroom'
pass 'headroom refuses to infer headroom from raw windows alone'

# An effective block that parses but yields no account-level row is a reading
# nobody got, and the two emitters must say so identically. The text form used
# to name `no-effective-rows` while --json returned an empty reason and
# unknown=0, so a programmatic reader branching on .verdict got an unknown it
# could not explain from a schema id that promises a reason on every path.
CASE="$TMP_ROOT/hr-modelscoped"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" model-scoped-only
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'unknown reason=no-effective-rows'   'a report with only model-scoped rows names why no account-level gauge was read'
assert_contains "$OUT" 'verdict=unknown' 'a report with no account-level row summarizes as unknown'
assert_not_contains "$OUT" 'pct=84' 'a model-scoped row is never presented as the dispatch gauge'
if command -v jq >/dev/null 2>&1; then
  OUT=$(run_headroom "$CASE/fakebin" --json)
  printf '%s' "$OUT" | jq -e '.verdict == "unknown" and .measured == 0 and .unknown == 1 and .reason == "no-effective-rows"' >/dev/null \
    || fail "--json must carry the same reason as the text form for a row-less read: $OUT"
fi
pass 'headroom reports a row-less effective block as unknown with the same reason on both emitters'

# --- headroom: auth_required is unknown, with the one-time command ----------

CASE="$TMP_ROOT/hr-auth"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" auth
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: cursor unknown reason=auth-required' 'a provider needing auth reads unknown'
assert_contains "$OUT" 'quota-axi --allow-keychain-prompt' 'the unknown line names the one-time operator command'
assert_contains "$OUT" 'HEADROOM: claude ok' 'one unmeasurable provider does not blank a measurable one'
assert_contains "$OUT" 'verdict=partial measured=1 tight=0 wall=0 unknown=1' \
  'a mixed fleet summarizes as partial, distinguishable from both ok and unknown'
assert_contains "$OUT" 'UNMEASURED, not healthy' 'a partial fleet still warns that unknown is not healthy'
# `partial` is the NORMAL reading on a host with one measurable provider and
# several unmeasurable ones, so it is the mixed verdict a reader hits most. It
# must carry the same next-step pointer every other actionable verdict does,
# rather than being the one common reading with no route out of it.
assert_contains "$OUT" 'HEADROOM_NEXT' 'a partial reading names the resume record as the next step'
pass 'headroom reports auth_required as unknown, names the fix, and routes a partial reading'

# --- headroom: never prompts for credentials --------------------------------

CASE="$TMP_ROOT/hr-noprompt"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" auth 0.1.40 "$CASE/argv.log"
run_headroom "$CASE/fakebin" >/dev/null
assert_present "$CASE/argv.log" 'the gauge was invoked'
assert_grep 'headroom-probe' "$CASE/argv.log" 'the recorded argv is the real invocation, not an empty file'
assert_no_grep '--allow-keychain-prompt' "$CASE/argv.log" \
  'headroom must never trigger the blocking credential prompt itself'
pass 'headroom never passes --allow-keychain-prompt'

# --- headroom: one reading costs one --version ------------------------------
#
# The floor check used to re-invoke quota-axi, so a single reading spent three
# bounded calls against ONE outer bound. A slow but working gauge then blew that
# bound and printed `unknown` for a gauge that could have been read - a false
# unmeasurable in the one surface built to prevent them.
CASE="$TMP_ROOT/hr-onever"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" healthy 0.1.40 "$CASE/argv.log"
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude ok' 'the reading still succeeds'
VERSION_CALLS=$(grep -c -- '--version' "$CASE/argv.log" || true)
[ "$VERSION_CALLS" = 1 ] \
  || fail "one reading must cost exactly one quota-axi --version, got $VERSION_CALLS: $(cat "$CASE/argv.log")"
TOTAL_CALLS=$(grep -c 'headroom-probe' "$CASE/argv.log" || true)
[ "$TOTAL_CALLS" = 2 ] \
  || fail "one reading must cost exactly two quota-axi invocations, got $TOTAL_CALLS: $(cat "$CASE/argv.log")"
pass 'one headroom reading costs one --version and one report call, not three'

# The floor verdict must not change now that it is compared from the captured
# string rather than a second invocation.
CASE="$TMP_ROOT/hr-onever-floor"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" healthy 0.1.1 "$CASE/argv.log"
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'build=below-floor' 'a below-floor build is still labelled from the single captured version'
VERSION_CALLS=$(grep -c -- '--version' "$CASE/argv.log" || true)
[ "$VERSION_CALLS" = 1 ] || fail "the below-floor path must not re-invoke --version, got $VERSION_CALLS"
pass 'the below-floor label is decided from the one captured version string'

# --- headroom: resolved by field name, not column position ------------------

CASE="$TMP_ROOT/hr-reordered"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" reordered
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude ok pct=84' 'a reordered report still yields the same percent'
assert_contains "$OUT" 'pct=84 bound=five_hour' \
  'a reordered report still binds the percentage to its own window, not to the runway label'
assert_contains "$OUT" 'runway=4h0m' 'a reordered report still yields the same runway'
pass 'headroom survives upstream field reordering and additions'

# --- headroom: a below-floor build is refused, loudly -----------------------
#
# This command reads the table layout a floor-compliant build emits. Builds
# below the floor emit a different one entirely, so parsing them would mean
# declaring a build unsupported and then reading it anyway - and a reading that
# looks fine from a build we reject is the exact failure this surface exists to
# prevent. The refusal must therefore be louder than an ordinary unknown and
# must name both versions, so an operator can act on it rather than wonder why
# every provider went quiet.
#
# This case is covered by a stub rather than a live old build, because no
# below-floor build remains reachable on this host; the floor path above is
# verified live against a real 0.1.34.
CASE="$TMP_ROOT/hr-floor"; mkdir -p "$CASE"
fake_quota "$CASE/fakebin" healthy 0.0.1
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'below the supported floor' 'a below-floor build is refused rather than parsed'
assert_contains "$OUT" '0.0.1' 'the refusal names the installed version'
assert_contains "$OUT" 'build=below-floor' 'and still carries the build label'
assert_not_contains "$OUT" 'pct=84' 'a build we refuse to run must never yield a percentage'
assert_contains "$OUT" 'UNMEASURED, not healthy' 'the refusal keeps the unmeasured note'
pass 'headroom refuses a below-floor build and says so in terms an operator can act on'

# --- headroom: an UNREAD build is not an OLD build ---------------------------
#
# The floor comparator answers "incompatible" for an empty string, so labelling
# straight off it printed `build=below-floor` whenever `--version` merely failed
# - a definite claim about a version nobody measured, beside a perfectly healthy
# reading, in the surface whose whole rule is that an unmeasured read is unknown.
CASE="$TMP_ROOT/hr-version-unread"; mkdir -p "$CASE/fakebin"
cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then exit 7; fi
cat "$CASE/report"
SH
chmod +x "$CASE/fakebin/quota-axi"
quota_toon healthy > "$CASE/report"
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'HEADROOM: claude ok pct=84' 'an unreadable version does not blank a readable reading'
assert_contains "$OUT" 'build=unknown' 'a version that could not be read is labelled unknown'
assert_not_contains "$OUT" 'build=below-floor' \
  'a version that was never read must never be reported as one read and found old'
pass 'headroom distinguishes an unread build from a below-floor build'

if command -v jq >/dev/null 2>&1; then
  OUT=$(run_headroom "$CASE/fakebin" --json)
  printf '%s' "$OUT" | jq -e '.build == "unknown" and .below_floor == false' >/dev/null \
    || fail "--json must not claim below_floor for a version it never read: $OUT"
  pass 'headroom --json keeps an unread build out of the below-floor claim'
fi

# --- headroom: the displayed version is the tool's own, not the last token ---
#
# The greedy form of this extraction returns the LAST version-like token, so a
# banner that ever grows a runtime suffix would both display and floor-check the
# runtime's version. bin/fm-quota-axi-lib.sh owns the parse for both uses.
CASE="$TMP_ROOT/hr-version-banner"; mkdir -p "$CASE/fakebin"
cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf 'quota-axi 0.1.40 (node 22.14.0)\n'; exit 0; fi
cat "$CASE/report"
SH
chmod +x "$CASE/fakebin/quota-axi"
quota_toon healthy > "$CASE/report"
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'source=quota-axi/0.1.40' \
  'a banner carrying a runtime version still displays the tool version'
assert_not_contains "$OUT" '22.14.0' 'the runtime version is never displayed as the build'
assert_not_contains "$OUT" 'build=below-floor' 'the floor is compared against the tool version'
pass 'headroom reads the tool version out of a banner carrying more than one'

# A banner whose FIRST version is below the floor must still read below-floor,
# so the anchoring did not just move the wrong answer somewhere else.
CASE="$TMP_ROOT/hr-version-banner-old"; mkdir -p "$CASE/fakebin"
cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf 'quota-axi 0.1.1 (node 22.14.0)\n'; exit 0; fi
cat "$CASE/report"
SH
chmod +x "$CASE/fakebin/quota-axi"
quota_toon healthy > "$CASE/report"
OUT=$(run_headroom "$CASE/fakebin")
assert_contains "$OUT" 'source=quota-axi/0.1.1' 'the first version token is the tool version'
assert_contains "$OUT" 'build=below-floor' 'an old tool version is still caught behind a runtime suffix'
pass 'headroom floor-checks the tool version, not whatever version came last'

# A DIGIT RUN BEFORE the version is the shape that broke this: with no real
# anchor the leftmost match starts mid-string and the unmatched prefix survives
# the substitution, so `node v22 quota-axi 0.1.40` displayed `node v220.1.40` and
# then failed the integer comparison, labelling a CURRENT build below-floor. Each
# banner below carries the same current version and must read identically.
for VERSION_BANNER in 'node v22 quota-axi 0.1.40' 'quota-axi2 0.1.40' '0.1.40'; do
  CASE="$TMP_ROOT/hr-version-prefix-$(printf '%s' "$VERSION_BANNER" | tr -c 'a-zA-Z0-9' '-')"
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' "$VERSION_BANNER"; exit 0; fi
cat "$CASE/report"
SH
  chmod +x "$CASE/fakebin/quota-axi"
  quota_toon healthy > "$CASE/report"
  OUT=$(run_headroom "$CASE/fakebin")
  assert_contains "$OUT" 'source=quota-axi/0.1.40' \
    "the banner '$VERSION_BANNER' must display the tool version and nothing else"
  assert_not_contains "$OUT" 'build=below-floor' \
    "the banner '$VERSION_BANNER' is a current build and must never be labelled below-floor"
  assert_not_contains "$OUT" 'build=unknown' \
    "the banner '$VERSION_BANNER' carries a readable version"
done
pass 'headroom extracts the first full dotted version token and nothing else'

# `unavailable` is the fourth build state the header declares, and the text
# summary carries it too rather than leaving it visible only in the JSON.
CASE="$TMP_ROOT/hr-build-unavailable"; mkdir -p "$CASE/empty"
OUT=$( PATH="$CASE/empty:/usr/bin:/bin:/usr/sbin:/sbin" "$WALL" headroom 2>&1 )
assert_contains "$OUT" 'build=unavailable' \
  'no gauge at all is labelled as such in the text summary, not only in the JSON'
assert_contains "$OUT" 'reason=quota-axi is not installed' 'the unmeasurable reason is still named'
pass 'headroom labels an absent gauge build=unavailable in the summary line'

# --- headroom: the reading budget is shared, not per call -------------------
#
# The two quota-axi calls used to get a full bound EACH, so one reading's worst
# case was twice the documented bound while both callers bound the whole command
# at or below it. A gauge answering each call inside its own bound then blew the
# caller's and was reported unmeasurable when it was readable.
CASE="$TMP_ROOT/hr-shared-budget"; mkdir -p "$CASE/fakebin"
cat > "$CASE/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
chmod +x "$CASE/fakebin/quota-axi"
STARTED=$(date +%s)
OUT=$( PATH="$CASE/fakebin:$PATH" FM_USAGE_WALL_QUOTA_TIMEOUT=4 "$WALL" headroom 2>&1 )
ELAPSED=$(( $(date +%s) - STARTED ))
[ "$ELAPSED" -le 6 ] \
  || fail "one reading must cost at most its own budget, not one per call (took ${ELAPSED}s of a 4s budget)"
assert_contains "$OUT" 'verdict=unknown' 'a wholly unreadable gauge is still unknown'
pass 'one headroom reading costs one shared budget across both quota-axi calls'

# The version call must not be able to starve the reading: it is labelling, the
# report is the answer, so a slow version still leaves the report readable.
CASE="$TMP_ROOT/hr-slow-version"; mkdir -p "$CASE/fakebin"
quota_toon healthy > "$CASE/report"
cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then sleep 60; fi
cat "$CASE/report"
SH
chmod +x "$CASE/fakebin/quota-axi"
OUT=$( PATH="$CASE/fakebin:$PATH" FM_USAGE_WALL_QUOTA_TIMEOUT=8 "$WALL" headroom 2>&1 )
assert_contains "$OUT" 'HEADROOM: claude ok pct=84' \
  'a hanging version call must not cost the reading itself'
assert_contains "$OUT" 'build=unknown' 'the version that could not be read is labelled unknown'
pass 'a slow version call cannot starve the headroom reading'

# --- headroom --json --------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  CASE="$TMP_ROOT/hr-json"; mkdir -p "$CASE"
  fake_quota "$CASE/fakebin" auth
  OUT=$(run_headroom "$CASE/fakebin" --json)
  printf '%s' "$OUT" | jq -e '.verdict == "partial"' >/dev/null \
    || fail "headroom --json must carry the same verdict as the text form: $OUT"
  printf '%s' "$OUT" | jq -e '[.providers[] | select(.provider == "cursor" and .verdict == "unknown")] | length == 1' >/dev/null \
    || fail "headroom --json must mark an unmeasurable provider unknown: $OUT"
  CASE="$TMP_ROOT/hr-json-absent"; mkdir -p "$CASE/fakebin"
  OUT=$( PATH="$CASE/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "$WALL" headroom --json 2>&1 )
  printf '%s' "$OUT" | jq -e '.verdict == "unknown" and .measured == 0' >/dev/null \
    || fail "headroom --json must report an absent gauge as unknown: $OUT"
  pass 'headroom --json carries the same verdicts as the text form'

  # One declared schema id must mean ONE object shape. When the measurable and
  # unmeasurable paths ship different key sets, a consumer branching on the id
  # gets null for whichever key its path happened to omit.
  CASE="$TMP_ROOT/hr-json-shape"; mkdir -p "$CASE"
  fake_quota "$CASE/fakebin" healthy
  MEASURED_JSON=$(run_headroom "$CASE/fakebin" --json)
  mkdir -p "$CASE/empty"
  ABSENT_JSON=$( PATH="$CASE/empty:/usr/bin:/bin:/usr/sbin:/sbin" "$WALL" headroom --json 2>&1 )
  MEASURED_KEYS=$(printf '%s' "$MEASURED_JSON" | jq -S -r 'keys | join(",")')
  ABSENT_KEYS=$(printf '%s' "$ABSENT_JSON" | jq -S -r 'keys | join(",")')
  [ "$MEASURED_KEYS" = "$ABSENT_KEYS" ] \
    || fail "one schema id must mean one shape: measured=[$MEASURED_KEYS] unmeasurable=[$ABSENT_KEYS]"
  printf '%s' "$MEASURED_JSON" | jq -e '.schema == "fm-usage-wall-headroom.v1" and .reason == "" and .build == "ok"' >/dev/null \
    || fail "a successful reading must carry an empty reason and a build state: $MEASURED_JSON"
  printf '%s' "$ABSENT_JSON" | jq -e '.schema == "fm-usage-wall-headroom.v1" and (.reason | length) > 0 and .below_floor == false' >/dev/null \
    || fail "an unmeasurable reading must carry a reason and the same below_floor key: $ABSENT_JSON"
  pass 'headroom --json ships one object shape for one schema id'
else
  pass 'headroom --json case skipped (jq unavailable)'
fi

# --- diagnose fixtures ------------------------------------------------------

WEEKLY_LIMIT_LINE="You've hit your weekly limit - resets Aug 26 at 10am (Europe/Rome)"
# Observed verbatim on 2026-08-27 in this repo's own pipeline log, on the run
# that stranded the very task adding this surface. The separator is the vendor's
# U+00B7, and the window is the SESSION one rather than the weekly one - a
# wording the first signature table missed, so a real wall read as no-signature.
SESSION_LIMIT_LINE="You've hit your session limit "$'\u00b7'" resets 1:40am (America/Los_Angeles)"

# make_task <case-dir> <task-id> -> exports CASE_HOME, CASE_WT, CASE_FB
make_task() {  # <case-dir> <task-id>
  local dir=$1 id=$2
  CASE_HOME="$dir/home"
  CASE_WT="$dir/wt"
  CASE_FB="$dir/fakebin"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/data" "$CASE_HOME/config" "$CASE_FB"
  printf 'manual\n' > "$CASE_HOME/config/backlog-backend"
  fm_git_worktree "$dir/repo" "$CASE_WT" "fm/$id"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=fmtest:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$dir/repo" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=tmux" \
    "model=claude-opus-5" \
    "effort=high"
}

# fake_tmux <fakebin> <window> <capture-file|->
fake_tmux() {
  local fb=$1 window=$2 capture=$3
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf '%s\n' "$window"; exit 0 ;;
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane)
    if [ "$capture" = - ]; then exit 1; fi
    cat "$capture"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

# fake_nm <fakebin> <branch> <run-id> <run-status> <steps-blob> <log-file|->
# Serves the two surfaces fm-usage-wall reads: the bare `axi` overview (which is
# scoped to the invoking worktree's own run) and `axi logs`.
fake_nm() {
  local fb=$1 branch=$2 run=$3 status=$4 steps=$5 log=$6
  cat > "$fb/nm-overview" <<SH
repo: /fake/repo
current_branch: $branch
daemon: running
active_run:
  id: "$run"
  branch: $branch
  status: $status
  head: deadbeef
  steps[9]{step,status,findings,duration_ms}:
$steps
branch_sync:
  state: pipeline_owned
  next_action:
    code: recover_custody
SH
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = logs ]; then
  if [ "$log" = - ]; then exit 1; fi
  cat "$log"
  exit 0
fi
if [ "\${1:-}" = axi ]; then cat "$fb/nm-overview"; exit 0; fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
}

# fake_nm_perstep <fakebin> <branch> <run-id> <run-status> <steps-blob>
# Same two surfaces as fake_nm, but `axi logs --step X` serves $fb/log-X and
# EXITS NON-ZERO when that file is absent. That distinction is the whole point:
# an unreadable log and a log read cleanly with no match are different facts,
# and the command must not collapse them.
fake_nm_perstep() {
  local fb=$1 branch=$2 run=$3 status=$4 steps=$5
  cat > "$fb/nm-overview" <<SH
repo: /fake/repo
current_branch: $branch
daemon: running
active_run:
  id: "$run"
  branch: $branch
  status: $status
  head: deadbeef
  steps[9]{step,status,findings,duration_ms}:
$steps
SH
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = logs ]; then
  step=
  prev=
  for a in "\$@"; do
    if [ "\$prev" = --step ]; then step=\$a; fi
    prev=\$a
  done
  [ -f "$fb/log-\$step" ] || exit 1
  cat "$fb/log-\$step"
  exit 0
fi
if [ "\${1:-}" = axi ]; then cat "$fb/nm-overview"; exit 0; fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
}

# fake_nm_perstep_slow <fakebin> <branch> <run-id> <run-status> <steps-blob> <delay>
# Same as fake_nm_perstep, but every `axi logs` read costs <delay> seconds. That
# is what makes the scan budget observable through the interface: the steps a
# budget could not reach are a different fact from the steps whose logs resisted
# a read, and the verdict has to keep them apart.
fake_nm_perstep_slow() {
  local fb=$1 branch=$2 run=$3 status=$4 steps=$5 delay=$6
  fake_nm_perstep "$fb" "$branch" "$run" "$status" "$steps"
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = logs ]; then
  step=
  prev=
  for a in "\$@"; do
    if [ "\$prev" = --step ]; then step=\$a; fi
    prev=\$a
  done
  sleep $delay
  [ -f "$fb/log-\$step" ] || exit 1
  cat "$fb/log-\$step"
  exit 0
fi
if [ "\${1:-}" = axi ]; then cat "$fb/nm-overview"; exit 0; fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
}

# fake_nm_runstable <fakebin> <branch> <run-id> <steps-blob> <log-file>
# An overview whose own `active_run` belongs to ANOTHER branch, plus a `runs`
# table carrying this branch's run - the shape attributed_run's fallback exists
# for. No observation of either installed build has shown `axi` printing such a
# table, so this fixture is what keeps that tolerance from rotting into a
# fallback nobody knows still works: with it, the fallback is exercised; the
# happy path fixtures above never enter it.
fake_nm_runstable() {
  local fb=$1 branch=$2 run=$3 steps=$4 log=$5
  cat > "$fb/nm-overview" <<SH
repo: /fake/repo
current_branch: $branch
daemon: running
active_run:
  id: "RUNOTHER"
  branch: fm/some-other-task
  status: running
  head: cafebabe
runs[2]{id,branch,status,head}:
  RUNOTHER,fm/some-other-task,running,cafebabe
  $run,$branch,failed,deadbeef
SH
  cat > "$fb/nm-run-detail" <<SH
repo: /fake/repo
active_run:
  id: "$run"
  branch: $branch
  status: failed
  head: deadbeef
  steps[9]{step,status,findings,duration_ms}:
$steps
SH
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = logs ]; then cat "$log"; exit 0; fi
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ]; then cat "$fb/nm-run-detail"; exit 0; fi
if [ "\${1:-}" = axi ]; then cat "$fb/nm-overview"; exit 0; fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
}

run_wall() {  # <home> <fakebin> <args...>
  local home=$1 fb=$2
  shift 2
  ( PATH="$fb:$PATH" FM_HOME="$home" "$WALL" "$@" 2>&1 )
}

# --- diagnose: the limit line in the endpoint output ------------------------

CASE="$TMP_ROOT/dx-endpoint"; mkdir -p "$CASE"
make_task "$CASE" wallcrew
printf 'building the fix\n%s\nclaude exited: exit status 1\n' "$WEEKLY_LIMIT_LINE" > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-wallcrew "$CASE/capture.txt"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose wallcrew)
assert_contains "$OUT" 'USAGE_WALL: wallcrew wall source=endpoint' 'a limit line in the endpoint output is a wall'
assert_contains "$OUT" "$WEEKLY_LIMIT_LINE" 'the verdict quotes the line it matched'
assert_contains "$OUT" 'not a crash' 'the wall verdict says plainly that this is not a crash'
assert_contains "$OUT" 'usage-limit-recovery' 'the wall verdict routes to the recovery procedure'
pass 'diagnose reads a usage wall out of the endpoint output'

# --- diagnose: the limit line in a failed step log --------------------------

CASE="$TMP_ROOT/dx-steplog"; mkdir -p "$CASE"
make_task "$CASE" logcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-logcrew "$CASE/capture.txt"
printf 'reviewing the diff\n%s\nclaude exited: exit status 1\n' "$WEEKLY_LIMIT_LINE" > "$CASE/review.log"
fake_nm "$CASE_FB" "fm/logcrew" RUN123 failed \
  '    intent,completed,0,0
    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose logcrew)
assert_contains "$OUT" 'USAGE_WALL: logcrew wall source=step-log:review' \
  'a limit line in the failed step log is a wall, which is where the evidence actually lives'
assert_contains "$OUT" "$WEEKLY_LIMIT_LINE" 'the step-log verdict quotes the line it matched'
pass 'diagnose reads a usage wall out of a failed pipeline step log'

# --- diagnose: the session-window phrasing is a wall too --------------------
#
# The table is only ever as complete as the phrasings actually observed, which
# is why a miss reads as `no-signature` and never as "it crashed". This one was
# found by diagnosing a real stranded run rather than a fixture.
CASE="$TMP_ROOT/dx-session"; mkdir -p "$CASE"
make_task "$CASE" sessioncrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-sessioncrew "$CASE/capture.txt"
printf 'I will start by examining the current state.%s\nclaude exited pid=91188 error=claude exited: exit status 1: \n' \
  "$SESSION_LIMIT_LINE" > "$CASE/review.log"
fake_nm "$CASE_FB" "fm/sessioncrew" RUNSESS failed '    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose sessioncrew)
assert_contains "$OUT" 'USAGE_WALL: sessioncrew wall source=step-log:review' \
  'the session-window limit phrasing is a usage wall, not an unrecognised failure'
assert_contains "$OUT" 'session limit' 'the verdict quotes the line it matched'
pass 'diagnose recognises the session-window limit phrasing'

# --- diagnose: transient transport wording is not a wall --------------------

CASE="$TMP_ROOT/dx-429"; mkdir -p "$CASE"
make_task "$CASE" ratecrew
printf 'HTTP 429 Too Many Requests\nrate limited, retrying in 5s\nretrying\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-ratecrew "$CASE/capture.txt"
printf 'HTTP 429 Too Many Requests\nrate limited, backing off\ntests failed: 3 assertions\n' > "$CASE/review.log"
fake_nm "$CASE_FB" "fm/ratecrew" RUN429 failed '    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose ratecrew)
assert_contains "$OUT" 'USAGE_WALL: ratecrew no-signature' \
  'transient transport throttling is not a usage wall'
assert_not_contains "$OUT" 'wall source=' 'a retryable 429 must never be reported as a wall'
assert_contains "$OUT" 'not proof the work crashed' 'a clean read still refuses to claim a crash'
pass 'diagnose does not mistake transient throttling for a usage wall'

# --- diagnose: this repository's own documentation is not a wall ------------
#
# The evidence sources here are a pane capture and a step log, and BOTH can carry
# this repository's own tracked documentation OF this detector, because the
# recovery skill and the verification record quote the vendor phrasings verbatim.
# The digest runs `diagnose --endpoint-only` for every endpoint it cannot read as
# alive, so a crewmate reading this surface when their endpoint dies is the
# concrete path. The fixture is built from the tracked files themselves, so the
# regression is pinned against the real text rather than a paraphrase of it.
CASE="$TMP_ROOT/dx-own-docs"; mkdir -p "$CASE"
make_task "$CASE" docscrew
grep -h -i -E "hit your (weekly|session) limit" \
  "$ROOT/.agents/skills/usage-limit-recovery/SKILL.md" \
  "$ROOT/docs/verification/usage-limits.md" > "$CASE/capture.txt"
[ -s "$CASE/capture.txt" ] \
  || fail 'the fixture must be built from this repository real tracked phrasings'
fake_tmux "$CASE_FB" fm-docscrew "$CASE/capture.txt"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose docscrew --endpoint-only)
assert_not_contains "$OUT" 'wall source=' \
  'this repository own documentation of the detector must never read as a wall'
assert_not_contains "$OUT" 'the work is intact' \
  'a false wall is the one direction that stops the reading, so it must not be claimed here'
pass 'diagnose does not read this repository own tracked phrasings as a wall'

# The same text on the step-log path, where the negative is `no-signature`
# rather than the endpoint-only `unknown`. The negative must stay `no-signature`:
# corroboration tightens the POSITIVE only, and a miss is still not proof of a
# crash.
CASE="$TMP_ROOT/dx-own-docs-log"; mkdir -p "$CASE"
make_task "$CASE" docslogcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-docslogcrew "$CASE/capture.txt"
grep -h -i -E "hit your (weekly|session) limit" \
  "$ROOT/.agents/skills/usage-limit-recovery/SKILL.md" \
  "$ROOT/docs/verification/usage-limits.md" > "$CASE/review.log"
fake_nm "$CASE_FB" "fm/docslogcrew" RUNDOCS failed '    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose docslogcrew)
assert_contains "$OUT" 'USAGE_WALL: docslogcrew no-signature' \
  'the negative on this repository own text is no-signature, never a claim of a crash'
assert_not_contains "$OUT" 'wall source=' \
  'a step log quoting this repository own documentation must not read as a wall'
assert_contains "$OUT" 'not proof the work crashed' \
  'the negative still refuses to assert that the work crashed'
pass 'diagnose reports this repository own text as no-signature, not as a wall'

# One sentence narrating BOTH facts at once is what a document does and what a
# harness does not: the harness prints the limit and then dies, on two lines. So
# the corroborating exit must be a line that does not itself carry a limit
# phrasing.
CASE="$TMP_ROOT/dx-narrated"; mkdir -p "$CASE"
make_task "$CASE" narratedcrew
grep -h -i -E "hit your (weekly|session) limit" \
  "$ROOT/.agents/skills/usage-limit-recovery/SKILL.md" |
  grep -i -E "exit status [1-9]" > "$CASE/capture.txt"
[ -s "$CASE/capture.txt" ] \
  || fail 'the recovery skill must still narrate the limit line and the harness exit in one sentence'
fake_tmux "$CASE_FB" fm-narratedcrew "$CASE/capture.txt"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose narratedcrew --endpoint-only)
assert_not_contains "$OUT" 'wall source=' \
  'a sentence narrating the limit and the exit together is prose, not evidence of a wall'
pass 'diagnose requires the harness exit on a line of its own, not narrated'

# The whole recovery skill on screen is the realistic shape of that hazard: a
# crewmate reading the procedure when their own endpoint dies. The digest scans
# that pane automatically, so the whole tracked file is fed in verbatim.
CASE="$TMP_ROOT/dx-whole-skill"; mkdir -p "$CASE"
make_task "$CASE" skillcrew
cp "$ROOT/.agents/skills/usage-limit-recovery/SKILL.md" "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-skillcrew "$CASE/capture.txt"
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_CAPTURE_LINES=2000 \
  "$WALL" diagnose skillcrew --endpoint-only 2>&1 )
assert_not_contains "$OUT" 'wall source=' \
  'a pane showing the whole recovery skill must not be read as a usage wall'
pass 'diagnose does not read the recovery skill on screen as a wall'

# Corroboration must cost no true positive: BOTH observed vendor phrasings, each
# followed by the harness exit as the harness actually emits it, still read as a
# wall.
for LIMIT_CASE in weekly session; do
  case "$LIMIT_CASE" in
    weekly) LIMIT_TEXT=$WEEKLY_LIMIT_LINE ;;
    *) LIMIT_TEXT=$SESSION_LIMIT_LINE ;;
  esac
  CASE="$TMP_ROOT/dx-corrob-$LIMIT_CASE"; mkdir -p "$CASE"
  make_task "$CASE" "corrob$LIMIT_CASE"
  printf 'building the fix\n%s\nclaude exited: exit status 1\n' "$LIMIT_TEXT" > "$CASE/capture.txt"
  fake_tmux "$CASE_FB" "fm-corrob$LIMIT_CASE" "$CASE/capture.txt"
  OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose "corrob$LIMIT_CASE")
  assert_contains "$OUT" "USAGE_WALL: corrob$LIMIT_CASE wall source=endpoint" \
    "the $LIMIT_CASE-window phrasing beside the harness exit is still a wall"
done
pass 'diagnose still reports a corroborated wall for both observed phrasings'

# --- diagnose: unreadable and cheap-scan negatives are unknown --------------

CASE="$TMP_ROOT/dx-unreadable"; mkdir -p "$CASE"
make_task "$CASE" darkcrew
fake_tmux "$CASE_FB" fm-darkcrew -
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose darkcrew --endpoint-only)
assert_contains "$OUT" 'USAGE_WALL: darkcrew unknown' 'an unreadable endpoint is unknown'
assert_contains "$OUT" 'checked=none' 'an unreadable endpoint is not counted as checked'
pass 'diagnose reports an unreadable endpoint as unknown'

# fake_tmux_wedged <fakebin> <window>: the endpoint answers liveness instantly
# but its capture never returns. That is the shape of a tmux server whose socket
# still exists while the server itself is wedged - the state a diagnose run is
# most likely to meet, because it is run by hand right after a provider wall has
# stranded the worker.
fake_tmux_wedged() {  # <fakebin> <window>
  local fb=$1 window=$2
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf '%s\n' "$window"; exit 0 ;;
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane) sleep 60; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

# The endpoint capture is bounded like every other read here. Unbounded, a
# wedged tmux server makes `diagnose` hang forever with no verdict at all - on
# the one path an agent runs by hand once a wall has stranded a worker. The
# bound must produce an unknown that names the timeout as the timeout, never a
# clean negative and never silence.
CASE="$TMP_ROOT/dx-wedged"; mkdir -p "$CASE"
make_task "$CASE" wedgedcrew
fake_tmux_wedged "$CASE_FB" fm-wedgedcrew
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_CAPTURE_TIMEOUT=1 \
  "$WALL" diagnose wedgedcrew --endpoint-only 2>&1 )
assert_contains "$OUT" 'USAGE_WALL: wedgedcrew unknown' 'a wedged endpoint capture must still produce a verdict'
assert_contains "$OUT" 'endpoint capture did not complete within 1s' \
  'a bounded capture that timed out names the timeout as the reason'
assert_contains "$OUT" 'checked=none' 'a capture that never returned is not counted as checked'
assert_not_contains "$OUT" 'no-signature' 'a capture that never returned must never read as a clean scan'
pass 'diagnose bounds a wedged endpoint capture and reports why it is unknown'

CASE="$TMP_ROOT/dx-cheap"; mkdir -p "$CASE"
make_task "$CASE" cheapcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-cheapcrew "$CASE/capture.txt"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose cheapcrew --endpoint-only)
assert_contains "$OUT" 'unknown reason=endpoint-only-scan-inconclusive' \
  'a cheap scan that finds nothing is inconclusive, not a clean bill of health'
assert_not_contains "$OUT" 'no-signature' 'the cheap scan must never claim the evidence was fully read'
pass 'diagnose downgrades an endpoint-only negative to unknown'

# An UNREADABLE step log must not be reported as read-and-clean. `no-signature`
# is defined as "evidence was read and nothing matched", so emitting it after a
# read that never produced anything is a false claim - and the `checked=` list
# would even name a step nothing had looked at. This is the shape a large log
# that does not stream out within the bound produces, which is exactly the
# post-wall state.
CASE="$TMP_ROOT/dx-log-unreadable"; mkdir -p "$CASE"
make_task "$CASE" darklogcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-darklogcrew "$CASE/capture.txt"
fake_nm_perstep "$CASE_FB" "fm/darklogcrew" RUNDARK failed \
  '    review,failed,0,120
    test,failed,0,120'
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose darklogcrew)
assert_contains "$OUT" 'unknown reason=step-log-unreadable' \
  'a step log that could not be read at all is unknown, never no-signature'
assert_not_contains "$OUT" 'no-signature' \
  'an unreadable log must never be reported as read-and-nothing-matched'
assert_not_contains "$OUT" 'step-log:review' \
  'a step that was never readable must not be listed as checked'
assert_contains "$OUT" 'unread=review,test' 'the verdict names the logs it could not read'
pass 'diagnose reports an unreadable step log as unknown rather than a clean read'

# `unread=` must name EVERYTHING that was attempted and yielded nothing, on the
# one verdict that means nothing was read at all. The endpoint and the step logs
# are the same fact, so a reader who learned from the recovery skill to trust
# the token and re-read what it names must not be handed the terminal alone
# while the step logs sit in prose beside it - the token would underreport
# exactly where the scan read least, and the agent would stop after re-reading
# the one source it was told about.
CASE="$TMP_ROOT/dx-log-unreadable-wedged"; mkdir -p "$CASE"
make_task "$CASE" darkwedgedcrew
fake_tmux_wedged "$CASE_FB" fm-darkwedgedcrew
fake_nm_perstep "$CASE_FB" "fm/darkwedgedcrew" RUNDARKW failed \
  '    review,failed,0,120
    test,failed,0,120'
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_CAPTURE_TIMEOUT=1 \
  "$WALL" diagnose darkwedgedcrew 2>&1 )
assert_contains "$OUT" 'unknown reason=step-log-unreadable' \
  'nothing readable anywhere is still unknown, never no-signature'
assert_contains "$OUT" 'unread=endpoint,review,test' \
  'one unread= list names every source that was attempted and yielded nothing'
assert_contains "$OUT" 'endpoint capture did not complete within 1s' \
  'the verdict still names why the endpoint yielded nothing'
assert_not_contains "$OUT" 'unread: ' \
  'the same fact must not be stated twice in two vocabularies on one line'
pass 'diagnose names the endpoint and the step logs in one unread= list'

# A PARTIAL read is disclosed rather than folded into a clean result: one log
# read cleanly does not license silence about the one that could not be read.
CASE="$TMP_ROOT/dx-log-partial"; mkdir -p "$CASE"
make_task "$CASE" partcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-partcrew "$CASE/capture.txt"
fake_nm_perstep "$CASE_FB" "fm/partcrew" RUNPART failed \
  '    review,failed,0,120
    test,failed,0,120'
printf 'tests failed: 3 assertions\n' > "$CASE_FB/log-review"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose partcrew)
assert_contains "$OUT" 'no-signature' 'a readable clean log still yields no-signature'
assert_contains "$OUT" 'step-log:review' 'the log that was read is named as checked'
assert_contains "$OUT" 'unread=test' 'the log that was NOT read is disclosed on the same line'
pass 'diagnose discloses a partially read scan instead of reporting it clean'

# The ENDPOINT is disclosed on the same terms as a step log. A wedged terminal
# costs the whole capture bound and then contributes no evidence, so a verdict
# that named only the step logs it did read would look cleaner than the evidence
# behind it - the unmeasured-presented-as-measured failure this command exists
# to refuse. The full path used to compute the capture's reason and discard it.
CASE="$TMP_ROOT/dx-endpoint-unread"; mkdir -p "$CASE"
make_task "$CASE" wedgedfullcrew
fake_tmux_wedged "$CASE_FB" fm-wedgedfullcrew
fake_nm_perstep "$CASE_FB" "fm/wedgedfullcrew" RUNWEDGE failed \
  '    review,failed,0,120'
printf 'tests failed: 3 assertions\n' > "$CASE_FB/log-review"
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_CAPTURE_TIMEOUT=1 \
  "$WALL" diagnose wedgedfullcrew 2>&1 )
assert_contains "$OUT" 'no-signature' 'a readable clean step log still yields no-signature'
assert_contains "$OUT" 'checked=step-log:review' 'the step log that was read is named as checked'
assert_not_contains "$OUT" 'checked=endpoint' 'a capture that never returned must not be named as checked'
assert_contains "$OUT" 'unread=endpoint' \
  'the endpoint that yielded no evidence is disclosed beside the logs'
assert_contains "$OUT" 'endpoint capture did not complete within 1s' \
  'the verdict names why the endpoint yielded nothing, not merely that it did'
pass 'diagnose discloses an unread endpoint on the full path, with its reason'

# The same disclosure reaches the inconclusive verdicts, which is where a reader
# lands when the pipeline evidence is unavailable too: without it, a task whose
# terminal is wedged AND whose run is unattributable reports only the second.
CASE="$TMP_ROOT/dx-endpoint-unread-inconclusive"; mkdir -p "$CASE"
make_task "$CASE" wedgedlonecrew
fake_tmux_wedged "$CASE_FB" fm-wedgedlonecrew
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_CAPTURE_TIMEOUT=1 \
  "$WALL" diagnose wedgedlonecrew 2>&1 )
assert_contains "$OUT" 'USAGE_WALL: wedgedlonecrew unknown' 'an unattributable run is still unknown'
assert_contains "$OUT" 'unread=endpoint' \
  'an inconclusive verdict carries the same unread= token the skill teaches a reader to look for'
assert_contains "$OUT" 'endpoint capture did not complete within 1s' \
  'an inconclusive verdict names the endpoint evidence it never read either'
pass 'diagnose carries the unread endpoint onto an inconclusive verdict too'

# The endpoint-only path uses that one shape too. It is the path the digest runs
# for every endpoint it cannot read as alive, so it is where a reader meets the
# disclosure most often, and it used to append the reason with no token at all.
CASE="$TMP_ROOT/dx-endpoint-unread-cheap"; mkdir -p "$CASE"
make_task "$CASE" wedgedcheapcrew
fake_tmux_wedged "$CASE_FB" fm-wedgedcheapcrew
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_CAPTURE_TIMEOUT=1 \
  "$WALL" diagnose wedgedcheapcrew --endpoint-only 2>&1 )
assert_contains "$OUT" 'unread=endpoint' \
  'the endpoint-only verdict carries the same unread= token as every other path'
assert_contains "$OUT" 'endpoint capture did not complete within 1s' \
  'the endpoint-only verdict still names why the capture yielded nothing'
pass 'diagnose uses one disclosure shape on the endpoint-only path too'

# A task that never had a terminal is NOT an unread endpoint. Nothing was
# attempted, so there is no gap for a reader to close, and the skill sends
# anyone who sees `unread=` off to read evidence that does not exist. Reporting
# it is the same false precision as labelling a percentage with a window it did
# not come from - and it is a state the digest itself calls out separately.
CASE="$TMP_ROOT/dx-endpoint-unrecorded"; mkdir -p "$CASE"
make_task "$CASE" nowindowcrew
fm_write_meta "$CASE_HOME/state/nowindowcrew.meta" \
  "worktree=$CASE_WT" "project=$CASE/repo" "harness=claude" "kind=ship" \
  "mode=no-mistakes" "yolo=off" "backend=tmux"
fake_tmux "$CASE_FB" fm-nowindowcrew -
fake_nm_perstep "$CASE_FB" "fm/nowindowcrew" RUNNOWIN failed \
  '    review,failed,0,120'
printf 'tests failed: 3 assertions\n' > "$CASE_FB/log-review"
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" "$WALL" diagnose nowindowcrew 2>&1 )
assert_contains "$OUT" 'no-signature' 'a readable clean step log still yields no-signature'
assert_not_contains "$OUT" 'unread=endpoint' \
  'an endpoint that was never attempted must not be claimed as one that resisted a read'
assert_not_contains "$OUT" 'checked=endpoint' 'an absent endpoint is not checked either'
assert_contains "$OUT" 'no endpoint is recorded for this task' \
  'the absence is still stated, so the reader knows why no terminal evidence appears'
pass 'diagnose does not claim an unread endpoint for a task that never had one'

# --- diagnose: an EMPTY successful log read is not a read -------------------
#
# `axi logs` exits 0 and prints nothing for a step that never produced a log (a
# cancelled or skipped step). Branching on the exit status alone counted that as
# read: the step landed in `checked=` and the scan settled on `no-signature`,
# which this command defines as evidence that WAS read. Empty output is no
# evidence, so it belongs with the steps that yielded nothing.
CASE="$TMP_ROOT/dx-log-empty"; mkdir -p "$CASE"
make_task "$CASE" emptycrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-emptycrew "$CASE/capture.txt"
fake_nm_perstep "$CASE_FB" "fm/emptycrew" RUNEMPTY failed \
  '    review,cancelled,0,10
    test,failed,0,120'
: > "$CASE_FB/log-review"                      # exists, readable, EMPTY, exits 0
printf 'tests failed: 3 assertions\n' > "$CASE_FB/log-test"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose emptycrew)
assert_not_contains "$OUT" 'step-log:review' \
  'a step whose log had nothing in it must never be listed as checked'
assert_contains "$OUT" 'unread=review' \
  'the empty step is disclosed as having yielded no evidence'
assert_contains "$OUT" 'step-log:test' 'the step that did have content is still read'
pass 'diagnose does not count an empty successful log read as evidence read'

# Every step empty means nothing was read at all, so the verdict must be the
# honest `unknown`, not `no-signature` - the same boundary as a failed read.
CASE="$TMP_ROOT/dx-log-all-empty"; mkdir -p "$CASE"
make_task "$CASE" allemptycrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-allemptycrew "$CASE/capture.txt"
fake_nm_perstep "$CASE_FB" "fm/allemptycrew" RUNALLEMPTY failed \
  '    review,cancelled,0,10'
: > "$CASE_FB/log-review"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose allemptycrew)
assert_contains "$OUT" 'unknown' 'a scan that read nothing reports unknown'
assert_contains "$OUT" 'step-log-unreadable' 'and names the reason it could not read'
assert_not_contains "$OUT" 'no-signature' \
  'nothing matched is a claim about evidence that was actually read'
pass 'diagnose reports unknown when every step log yielded nothing'

# The scan used to stop after three failed steps, silently. A run whose FOURTH
# failed step carries the vendor limit line would then return `no-signature` -
# the exact false negative this command exists to prevent.
CASE="$TMP_ROOT/dx-log-fourth"; mkdir -p "$CASE"
make_task "$CASE" deepcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-deepcrew "$CASE/capture.txt"
fake_nm_perstep "$CASE_FB" "fm/deepcrew" RUNDEEP failed \
  '    intent,failed,0,10
    rebase,failed,0,10
    review,failed,0,10
    test,failed,0,120'
printf 'nothing here\n' > "$CASE_FB/log-intent"
printf 'nothing here\n' > "$CASE_FB/log-rebase"
printf 'nothing here\n' > "$CASE_FB/log-review"
printf 'running tests\n%s\nclaude exited: exit status 1\n' "$WEEKLY_LIMIT_LINE" > "$CASE_FB/log-test"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose deepcrew)
assert_contains "$OUT" 'USAGE_WALL: deepcrew wall source=step-log:test' \
  'the scan reaches the fourth failed step rather than silently stopping at three'
pass 'diagnose scans every failed step, so a late limit line is still found'

# A step the budget never reached is NOT a step whose log failed to read. Both
# used to land in one `unread=` list, so the verdict reported a read that never
# happened as one that resisted - and named `step-log-unreadable`, defined as a
# log that failed to read, for steps nothing had attempted.
CASE="$TMP_ROOT/dx-log-budget-mixed"; mkdir -p "$CASE"
make_task "$CASE" budgetcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-budgetcrew "$CASE/capture.txt"
fake_nm_perstep_slow "$CASE_FB" "fm/budgetcrew" RUNBUD failed \
  '    review,failed,0,120
    test,failed,0,120' 30
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_SCAN_BUDGET=1 \
  "$WALL" diagnose budgetcrew 2>&1 )
assert_contains "$OUT" 'unknown reason=step-log-unreadable' \
  'a log that resisted a read still reports step-log-unreadable'
assert_contains "$OUT" 'unread=review' 'the log that failed to read is named as unread'
assert_contains "$OUT" 'unscanned=test' 'the step the budget never reached is named as unscanned'
assert_not_contains "$OUT" 'unread=review,test' \
  'a step nothing attempted must not be reported as one whose log failed to read'
pass 'diagnose separates a step the budget never reached from a log that failed to read'

# The same split on a verdict that DID read something: a readable clean log is
# still `no-signature`, and the budget-truncated remainder is disclosed as
# unscanned rather than folded into the clean result.
CASE="$TMP_ROOT/dx-log-budget-clean"; mkdir -p "$CASE"
make_task "$CASE" budgetclean
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-budgetclean "$CASE/capture.txt"
fake_nm_perstep_slow "$CASE_FB" "fm/budgetclean" RUNBUDC failed \
  '    review,failed,0,10
    test,failed,0,10
    push,failed,0,10' 1.2
printf 'tests failed: 3 assertions\n' > "$CASE_FB/log-review"
printf 'tests failed: 3 assertions\n' > "$CASE_FB/log-test"
printf 'tests failed: 3 assertions\n' > "$CASE_FB/log-push"
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" FM_USAGE_WALL_SCAN_BUDGET=2 \
  FM_USAGE_WALL_NM_TIMEOUT=3 "$WALL" diagnose budgetclean 2>&1 )
assert_contains "$OUT" 'no-signature' 'a readable clean log still yields no-signature'
assert_contains "$OUT" 'unscanned=' 'the budget-truncated remainder is disclosed as unscanned'
assert_not_contains "$OUT" 'reason=step-log-unreadable' \
  'a scan that read a log cleanly is not reported as an unreadable one'
pass 'diagnose discloses a budget-truncated remainder as unscanned, not as unread'

# The `runs`-table fallback in attributed_run: no observed build prints such a
# table, so this is the fixture that keeps the tolerance honest rather than
# untested. The overview's own active_run belongs to another branch, and the run
# for THIS branch is reachable only through the table.
CASE="$TMP_ROOT/dx-runstable"; mkdir -p "$CASE"
make_task "$CASE" runscrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-runscrew "$CASE/capture.txt"
printf 'reviewing the diff\n%s\nclaude exited: exit status 1\n' "$WEEKLY_LIMIT_LINE" > "$CASE/review.log"
fake_nm_runstable "$CASE_FB" "fm/runscrew" RUNTBL \
  '    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose runscrew)
assert_contains "$OUT" 'USAGE_WALL: runscrew wall source=step-log:review' \
  'a run reachable only through the runs table is still attributed and read'
assert_contains "$OUT" "$WEEKLY_LIMIT_LINE" 'the fallback verdict quotes the line it matched'
pass 'diagnose attributes a run through the runs-table fallback when active_run is another branch'

# An overview whose active_run is another branch and which carries NO runs table
# must fail safe rather than borrowing that other run's evidence.
CASE="$TMP_ROOT/dx-otherbranch"; mkdir -p "$CASE"
make_task "$CASE" othercrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-othercrew "$CASE/capture.txt"
printf 'reviewing the diff\n%s\n' "$WEEKLY_LIMIT_LINE" > "$CASE/review.log"
fake_nm "$CASE_FB" "fm/some-other-task" RUNELSE failed '    review,failed,0,120' "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" diagnose othercrew)
assert_contains "$OUT" 'unknown reason=no-attributed-run' \
  'another branch run is never attributed to this task'
assert_not_contains "$OUT" 'wall source=' \
  'evidence from another task run must never become this task verdict'
pass 'diagnose refuses to attribute another branch run to this task'

CASE="$TMP_ROOT/dx-nometa"; mkdir -p "$CASE/home/state"
OUT=$( FM_HOME="$CASE/home" "$WALL" diagnose ghost 2>&1 )
assert_contains "$OUT" 'unknown reason=no-durable-record' 'a task with no local record is unknown'
pass 'diagnose reports an unrecorded task as unknown'

# --- resume -----------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  pass 'resume cases skipped (jq unavailable)'
else

CASE="$TMP_ROOT/rs-record"; mkdir -p "$CASE"
make_task "$CASE" recordcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-recordcrew "$CASE/capture.txt"
fake_nm "$CASE_FB" "fm/recordcrew" RUNREC failed \
  '    review,failed,0,120' "$CASE/review.log"
printf 'nothing to see\n' > "$CASE/review.log"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" resume)
RECORD="$CASE_HOME/state/resume-record.md"
assert_present "$RECORD" 'resume publishes a durable record'
assert_contains "$OUT" "$RECORD" 'resume prints the path of the record it published'

# Read it back from a separate process, which is the property that matters: the
# record has to outlive the session that generated it.
BACK=$( cat "$RECORD" )
assert_contains "$BACK" '## recordcrew' 'the record names the task'
assert_contains "$BACK" 'mode=no-mistakes yolo=off' 'the record carries the standing merge posture'
assert_contains "$BACK" 'the captain approves every merge' 'the record spells out what that posture means'
assert_contains "$BACK" 'branch: fm/recordcrew' 'the record carries the branch a recovery must return to'
assert_contains "$BACK" 'harness=claude model=claude-opus-5 effort=high' 'the record carries the runtime to relaunch on'
assert_contains "$BACK" 'GENERATED from live durable state' 'the record says it is generated, not hand-authored'
assert_contains "$BACK" 'usage-limit-recovery' 'the record points at the procedure instead of restating it'
assert_contains "$BACK" 'custody=pipeline_owned' 'the record carries pipeline branch custody'
assert_contains "$BACK" 'next-action=recover_custody' 'the record carries the custody action the pipeline asks for'
assert_contains "$BACK" 'commits this local copy does not have' \
  'the record warns when the pipeline holds commits the local copy lacks'
pass 'resume generates a durable record that survives the process that wrote it'

# The steering counts, through the layout's declared owner. The fixture asks
# bin/fm-task-inbox-lib.sh where the records go rather than spelling the paths
# out, so a layout change there moves both the writer and this reader together
# instead of leaving the record quietly reporting nothing delivered.
INBOX=$( . "$ROOT/bin/fm-task-inbox-lib.sh" >/dev/null 2>&1; fm_task_inbox_dir "$CASE_HOME/state" recordcrew )
HANDLED=$( . "$ROOT/bin/fm-task-inbox-lib.sh" >/dev/null 2>&1; fm_task_inbox_handled_dir "$CASE_HOME/state" recordcrew )
mkdir -p "$INBOX" "$HANDLED"
printf 'schema=fm-task-inbox.v1\n--\nstill unread\n' > "$INBOX/001.msg"
printf 'schema=fm-task-inbox.v1\n--\nalready handled\n' > "$HANDLED/002.msg"
printf 'bookkeeping\n' > "$INBOX/.ring-state"
run_wall "$CASE_HOME" "$CASE_FB" resume >/dev/null
assert_grep 'delivered instructions: 1 acknowledged, 1 still unread' "$RECORD" \
  'the record counts the steering the worker has and has not acknowledged'
pass 'resume counts steering records through the inbox layout owner'

# A regenerated record reflects state as it is now, not as it was.
git -C "$CASE_WT" checkout -q -b fm/recordcrew-moved
run_wall "$CASE_HOME" "$CASE_FB" resume >/dev/null
assert_grep 'branch: fm/recordcrew-moved' "$RECORD" 'regenerating the record picks up the new branch'
assert_no_grep 'branch: fm/recordcrew ' "$RECORD" 'the regenerated record does not keep the stale branch'
pass 'resume regenerates from current state rather than accumulating'

# --- resume: an empty home ---------------------------------------------------

CASE="$TMP_ROOT/rs-empty"; mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/home/config" "$CASE/fakebin"
printf 'manual\n' > "$CASE/home/config/backlog-backend"
run_wall "$CASE/home" "$CASE/fakebin" resume >/dev/null
assert_grep 'No task metadata is present' "$CASE/home/state/resume-record.md" \
  'an empty home produces a record that says so rather than an empty file'
pass 'resume records an empty home explicitly'

# --- resume: two tasks recording one local copy -----------------------------

CASE="$TMP_ROOT/rs-shared"; mkdir -p "$CASE"
make_task "$CASE" sharedone
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-sharedone "$CASE/capture.txt"
fm_write_meta "$CASE_HOME/state/sharedtwo.meta" \
  "window=fmtest:fm-sharedtwo" "endpoint_task_id=sharedtwo" "worktree=$CASE_WT" \
  "project=$CASE/repo" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=tmux"
run_wall "$CASE_HOME" "$CASE_FB" resume >/dev/null
SHARED_HITS=$(grep -c 'SHARED: another task in this home records the same local copy' "$CASE_HOME/state/resume-record.md")
[ "$SHARED_HITS" = 2 ] || fail "both tasks sharing one local copy must be flagged, got $SHARED_HITS"
pass 'resume names a local copy claimed by two tasks on both rows'

# --- resume: a failed generation keeps the previous record -------------------

CASE="$TMP_ROOT/rs-atomic"; mkdir -p "$CASE"
make_task "$CASE" atomiccrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-atomiccrew "$CASE/capture.txt"
run_wall "$CASE_HOME" "$CASE_FB" resume >/dev/null
printf 'PRIOR RECORD SENTINEL\n' > "$CASE_HOME/state/resume-record.md"
# Break the snapshot the record is composed from, mid-flight, and require that
# the previous complete record is still the one on disk afterwards.
cat > "$CASE_FB/jq" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$CASE_FB/jq"
OUT=$(run_wall "$CASE_HOME" "$CASE_FB" resume)
RC=$?
[ "$RC" -ne 0 ] || fail "resume must refuse when the fleet snapshot cannot be read: $OUT"
assert_contains "$OUT" 'fleet snapshot could not be read' 'the refusal names what it could not read'
assert_contains "$OUT" 'no record was written' 'the refusal says the previous record is still the one on disk'
assert_grep 'PRIOR RECORD SENTINEL' "$CASE_HOME/state/resume-record.md" \
  'a failed generation must leave the previous record readable'
pass 'resume refuses rather than replacing a good record with a broken one'

# The publish side of the same guarantee. The record used to be staged in TMPDIR,
# so on a home and a temporary directory that sit on different filesystems the
# final `mv` degraded to copy-then-unlink and a reader during regeneration could
# see a truncated record. Staging BESIDE the destination is what keeps the rename
# atomic, and pointing TMPDIR somewhere unusable is how that is observable: a
# publish that still succeeds cannot have staged there.
CASE="$TMP_ROOT/rs-publish"; mkdir -p "$CASE"
make_task "$CASE" publishcrew
printf 'idle shell\n' > "$CASE/capture.txt"
fake_tmux "$CASE_FB" fm-publishcrew "$CASE/capture.txt"
OUT=$( PATH="$CASE_FB:$PATH" FM_HOME="$CASE_HOME" TMPDIR="$CASE/no-such-tmpdir" \
  "$WALL" resume 2>&1 )
RC=$?
[ "$RC" -eq 0 ] || fail "resume must publish without depending on TMPDIR: $OUT"
RECORD="$CASE_HOME/state/resume-record.md"
assert_grep '## publishcrew' "$RECORD" 'the record published through an unusable TMPDIR is complete'
assert_grep 'GENERATED from live durable state' "$RECORD" 'the whole record is on disk, not a truncated prefix'
STRAY=$(find "$CASE_HOME/state" -maxdepth 1 -name '.fm-resume-record.*' | grep -c . || true)
[ "$STRAY" = 0 ] || fail "the staging file must not survive a successful publish, found $STRAY"
pass 'resume publishes the record with a same-directory rename'

fi

# --- usage errors -----------------------------------------------------------

"$WALL" >/dev/null 2>&1; expect_code 2 $? 'no command is a usage error'
"$WALL" nonsense >/dev/null 2>&1; expect_code 2 $? 'an unknown command is a usage error'
"$WALL" diagnose >/dev/null 2>&1; expect_code 2 $? 'diagnose without a task id is a usage error'
"$WALL" --help >/dev/null 2>&1; expect_code 0 $? '--help succeeds'
pass 'usage errors are refused with a usage exit status'

# Every bound this command hands to fm_run_timed must be refused when it is not
# a bound. bin/fm-timeout-lib.sh states the caller's obligation: `timeout 0` and
# the perl fallback's `alarm 0` both DISABLE the deadline, so a zero that slips
# through does not shorten a read, it restores an unbounded one - on the manual
# recovery path, which has no outer bound to save it. Asserted over the whole
# set rather than one knob at a time, because the defect this reproduces was a
# newly added bound being the only one left out of the validation block.
for KNOB in FM_USAGE_WALL_QUOTA_TIMEOUT FM_USAGE_WALL_NM_TIMEOUT \
  FM_USAGE_WALL_SCAN_BUDGET FM_USAGE_WALL_SNAPSHOT_TIMEOUT \
  FM_USAGE_WALL_CAPTURE_LINES FM_USAGE_WALL_CAPTURE_TIMEOUT; do
  OUT=$(env "$KNOB=0" "$WALL" --help 2>&1); RC=$?
  expect_code 2 "$RC" "$KNOB=0 must be refused, not accepted as a disabled bound"
  assert_contains "$OUT" "$KNOB must be a positive integer" \
    "$KNOB=0 must name the knob and its constraint"
  OUT=$(env "$KNOB=abc" "$WALL" --help 2>&1); RC=$?
  expect_code 2 "$RC" "$KNOB must refuse a non-numeric value rather than degrade"
done
pass 'every bound tunable is refused when it is not a bound'
