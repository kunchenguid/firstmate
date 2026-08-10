#!/usr/bin/env bash
# tests/fm-attribution-sweep.test.sh - contract test for the model-write
# attribution sweep.
#
# The sweep's whole value is that an omitted attribution token becomes visible
# after the fact, so the cases that matter are the ones where a wrong answer
# would be indistinguishable from a right one:
#
#   1. A write WITHOUT the token is reported as a candidate (the red case).
#   2. A write WITH the token is counted as declared and is NOT reported, so the
#      sweep is a detector rather than a machine that flags everything.
#   3. A clean run, a run that could not look, and a run that found something are
#      three distinguishable outcomes with three distinct exit statuses. An API
#      error, a truncated response, and an exhausted request budget must never
#      read as clean.
#   4. Every GitHub call is a GET. The sweep never mutates what it reports on.
#
# A fake gh-axi first on PATH stands in for GitHub. It answers with the same
# AXI envelope the real client emits, and records every invocation so the
# read-only contract is asserted against actual argv rather than assumed. The
# token match itself lives inside the jq expression the real client evaluates
# and is verified against live GitHub, not here.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$ROOT/bin/fm-attribution-sweep.sh"

WORK=
FAILED=0

fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }
trap cleanup EXIT

command -v base64 >/dev/null 2>&1 || { echo "skip: base64 not found"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-attr-sweep.XXXXXX") || { echo "skip: mktemp failed"; exit 0; }
BIN="$WORK/bin"
mkdir -p "$BIN"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# One comment record as the sweep's transport encodes it:
# id | issue-number | created-at | token-present | author-association | app-slug
comment_record() {
  printf '%s|%s|%s|%s|%s|%s' \
    "$(b64 "$1")" "$(b64 "$2")" "$(b64 "$3")" "$(b64 "$4")" "$(b64 "$5")" "$(b64 "$6")"
}

cat >"$BIN/gh-axi" <<'FAKE'
#!/usr/bin/env bash
# Fake gh-axi. Records argv, then answers from the scenario in the environment.
# The jq program legitimately spans lines, so newlines are folded away to keep
# exactly one log record per invocation; a multi-line argument would otherwise
# read back as extra calls. The logging runs in a subshell because its shift
# would otherwise consume this script's own arguments.
verb=${1:-}
path=${2:-}
(
  printf '%s\t%s\t' "${1:-}" "${2:-}"
  if [ "$#" -gt 2 ]; then
    shift 2
    for arg in "$@"; do printf '%s ' "$arg" | tr '\n' ' '; done
  fi
  printf '\n'
) >>"$FM_FAKE_LOG"

: "$verb"

emit_envelope() {
  printf 'api_response:\n'
  printf '  body: "%s"\n' "$1"
  printf '  truncated: %s\n' "${2:-false}"
}

case $path in
  /user)
    printf 'api_response:\n  body: testcaptain\n  truncated: false\n'
    exit 0
    ;;
  /user/repos*)
    # Exactly what GitHub returns for a token whose scopes exclude the account's
    # repositories: HTTP 200 with an empty array. Identical bytes to an account
    # that owns nothing.
    printf 'api_response:\n  body: "%s"\n  truncated: false\n' "${FM_FAKE_REPOS:-0}"
    exit 0
    ;;
esac

# The commits scope walks branches, then pull request heads. Each listing gets
# its own canned answer so the test can prove a commit is found through the pull
# request even when no branch carries it.
if [ "${FM_FAKE_SCENARIO:-}" = "commits" ]; then
  case $path in
    */branches*)
      printf 'api_response:\n  body: "%s"\n  truncated: false\n' "$FM_FAKE_BRANCHES"
      exit 0
      ;;
    */pulls\?*)
      printf 'api_response:\n  body: "%s"\n  truncated: false\n' "$FM_FAKE_PULLS"
      exit 0
      ;;
    */pulls/*/commits*)
      printf 'api_response:\n  body: "%s"\n  truncated: false\n' "$FM_FAKE_PR_COMMITS"
      exit 0
      ;;
    */commits\?*)
      printf 'api_response:\n  body: "%s"\n  truncated: false\n' "$FM_FAKE_BRANCH_COMMITS"
      exit 0
      ;;
  esac
fi

case $FM_FAKE_SCENARIO in
  apierror)
    printf 'error: "gh: Bad credentials (HTTP 401)"\ncode: UNAUTHORIZED\n' >&2
    exit 1
    ;;
  truncated)
    emit_envelope "$FM_FAKE_BODY" true
    printf '  original_length: 99999\n'
    exit 0
    ;;
  *)
    emit_envelope "$FM_FAKE_BODY" false
    exit 0
    ;;
esac
FAKE
chmod +x "$BIN/gh-axi"

FM_FAKE_LOG="$WORK/calls.log"
export FM_FAKE_LOG

# Runs the sweep with the fake client in front. Body and scenario come from the
# caller; stdout, stderr, and the exit status land in the work dir.
run_sweep() {
  local scenario=$1 body=$2
  shift 2
  : >"$FM_FAKE_LOG"
  FM_FAKE_SCENARIO=$scenario FM_FAKE_BODY=$body PATH="$BIN:$PATH" \
    "$SWEEP" --account testcaptain --since 2026-01-01T00:00:00Z "$@" \
    >"$WORK/out" 2>"$WORK/err"
  printf '%s' $? >"$WORK/rc"
}

rc() { cat "$WORK/rc"; }
out() { cat "$WORK/out"; }

# --- 1. a write without the token is reported ------------------------------
run_sweep candidate "1\n$(comment_record 900001 42 2026-02-02T10:00:00Z false OWNER none)" \
  --repo acme/widgets --kind comments
if out | grep -q 'FM_SWEEP_CANDIDATE .*kind=comment ref=900001 '; then
  pass "an unprefixed comment is reported as a candidate"
else
  fail "an unprefixed comment was not reported; got: $(out | tr '\n' '~')"
fi
if out | grep -q 'FM_SWEEP_SCOPE .*kind=comments outcome=observed examined=1 declared=0 candidates=1'; then
  pass "the candidate scope tallies one examined and one candidate"
else
  fail "candidate scope tally wrong: $(out | grep FM_SWEEP_SCOPE || true)"
fi
if out | grep -q 'FM_SWEEP_SUMMARY .*candidates=1 .*outcome=candidates'; then
  pass "the summary reports the candidates outcome"
else
  fail "candidate summary wrong: $(out | grep FM_SWEEP_SUMMARY || true)"
fi
[ "$(rc)" = "10" ] || fail "expected exit 10 for candidates, got $(rc)"
[ "$(rc)" = "10" ] && pass "candidates exit with 10"

# The permalink is rebuilt rather than transported, so it has to be right.
if out | grep -q 'url=https://github.com/acme/widgets/issues/42#issuecomment-900001'; then
  pass "the candidate carries a usable permalink"
else
  fail "permalink wrong: $(out | grep FM_SWEEP_CANDIDATE || true)"
fi

# The app that performed the write is evidence, not a reason to skip it: the
# measured browser session writes through a GitHub App while still recording the
# comment under the account owner's own login.
run_sweep candidate "1\n$(comment_record 900002 7 2026-02-02T10:00:00Z false OWNER chatgpt-codex-connector)" \
  --repo acme/widgets --kind comments
if out | grep -q 'FM_SWEEP_CANDIDATE .*ref=900002 .*via_app=chatgpt-codex-connector'; then
  pass "an app-performed write is reported with the app named as evidence"
else
  fail "app-performed write not reported with its app: $(out | grep FM_SWEEP_CANDIDATE || true)"
fi

# --- 2. a write with the token is not reported -----------------------------
run_sweep declared "1\n$(comment_record 900003 42 2026-02-02T10:00:00Z true OWNER none)" \
  --repo acme/widgets --kind comments
if out | grep -q 'FM_SWEEP_CANDIDATE'; then
  fail "a token-carrying comment was reported as a candidate"
else
  pass "a token-carrying comment is not reported"
fi
if out | grep -q 'FM_SWEEP_SCOPE .*kind=comments outcome=observed examined=1 declared=1 candidates=0'; then
  pass "a token-carrying comment is counted as declared"
else
  fail "declared tally wrong: $(out | grep FM_SWEEP_SCOPE || true)"
fi
if out | grep -q 'FM_SWEEP_SUMMARY .*outcome=clean'; then
  pass "an all-declared run reports the clean outcome"
else
  fail "declared summary wrong: $(out | grep FM_SWEEP_SUMMARY || true)"
fi
[ "$(rc)" = "0" ] || fail "expected exit 0 for an all-declared run, got $(rc)"
[ "$(rc)" = "0" ] && pass "an all-declared run exits 0"

# --- 3. clean, could-not-observe, and candidates stay distinguishable ------
run_sweep clean "0" --repo acme/widgets --kind comments
CLEAN_OUT=$(out)
CLEAN_RC=$(rc)
if printf '%s' "$CLEAN_OUT" | grep -q 'FM_SWEEP_SCOPE .*outcome=observed examined=0 declared=0 candidates=0'; then
  pass "an empty result set is reported as observed and empty"
else
  fail "empty result not reported as observed: $CLEAN_OUT"
fi
[ "$CLEAN_RC" = "0" ] || fail "expected exit 0 for a clean run, got $CLEAN_RC"
[ "$CLEAN_RC" = "0" ] && pass "a clean run exits 0"

run_sweep apierror "" --repo acme/widgets --kind comments
ERR_OUT=$(out)
ERR_RC=$(rc)
if printf '%s' "$ERR_OUT" | grep -q 'FM_SWEEP_SCOPE .*outcome=could-not-observe reason=api-error'; then
  pass "an API failure is reported as could-not-observe"
else
  fail "API failure not reported as could-not-observe: $ERR_OUT"
fi
if printf '%s' "$ERR_OUT" | grep -q 'outcome=clean'; then
  fail "an API failure printed a clean outcome"
else
  pass "an API failure never prints a clean outcome"
fi
if printf '%s' "$ERR_OUT" | grep -q 'NOT a clean result'; then
  pass "an unobserved run says in words that it is not clean"
else
  fail "unobserved run lacks its plain-language warning: $ERR_OUT"
fi
[ "$ERR_RC" = "20" ] || fail "expected exit 20 for an unobservable run, got $ERR_RC"
[ "$ERR_RC" = "20" ] && pass "an unobservable run exits 20"

if [ "$CLEAN_OUT" = "$ERR_OUT" ]; then
  fail "a clean run and a run that could not look printed the same thing"
else
  pass "a clean run and a run that could not look are distinguishable"
fi

run_sweep truncated "1\n$(comment_record 900004 42 2026-02-02T10:00:00Z false OWNER none)" \
  --repo acme/widgets --kind comments
if out | grep -q 'FM_SWEEP_SCOPE .*outcome=could-not-observe reason=truncated'; then
  pass "a truncated response is could-not-observe, not a partial answer"
else
  fail "truncated response mishandled: $(out)"
fi
[ "$(rc)" = "20" ] || fail "expected exit 20 for a truncated response, got $(rc)"
[ "$(rc)" = "20" ] && pass "a truncated response exits 20"

# The dangerous budget case is running out PART WAY through a listing: the sweep
# then holds real findings but has not seen the whole window, and reporting that
# as a finished scope would be a partial answer wearing a complete one's clothes.
# A one-record page at --per-page 1 looks full, so a second page is due when the
# budget is already spent.
run_sweep candidate "1\n$(comment_record 900006 42 2026-02-02T10:00:00Z false OWNER none)" \
  --repo acme/widgets --kind comments --per-page 1 --budget 1
if out | grep -q 'FM_SWEEP_SCOPE .*outcome=could-not-observe reason=request-budget'; then
  pass "a budget spent mid-listing is could-not-observe"
else
  fail "mid-listing budget exhaustion mishandled: $(out)"
fi
if out | grep -q 'FM_SWEEP_CANDIDATE .*ref=900006'; then
  pass "findings already made are still listed when the scope goes unobserved"
else
  fail "a candidate found before the budget ran out was dropped: $(out)"
fi
if out | grep -q 'FM_SWEEP_SUMMARY .*candidates=1 .*outcome=could-not-observe'; then
  pass "could-not-observe outranks candidates in the summary while both are counted"
else
  fail "partial-scope summary wrong: $(out | grep FM_SWEEP_SUMMARY || true)"
fi
[ "$(rc)" = "20" ] || fail "expected exit 20 for an exhausted budget, got $(rc)"
[ "$(rc)" = "20" ] && pass "an exhausted budget exits 20"

# Zero means no request may be made, never "unlimited".
run_sweep clean "0" --repo acme/widgets --kind comments --budget 0
if out | grep -q 'outcome=could-not-observe reason=request-budget'; then
  pass "a zero budget permits no request and observes nothing"
else
  fail "a zero budget was treated as unlimited: $(out)"
fi

# --- a commit whose branch is gone is still found through its pull request ---
# This is the normal end state for shipped work: the branch is deleted when the
# pull request closes, and branch enumeration alone then goes quiet on exactly
# the commits that landed. The branch listing here is deliberately empty.
commit_record() {
  printf '%s|%s|%s|%s|%s' \
    "$(b64 "$1")" "$(b64 "$2")" "$(b64 "$3")" "$(b64 "$4")" "$(b64 "$5")"
}
: >"$FM_FAKE_LOG"
FM_FAKE_SCENARIO=commits \
FM_FAKE_BODY='' \
FM_FAKE_BRANCHES="0" \
FM_FAKE_PULLS="1\n$(b64 24)|$(b64 2026-02-03T00:00:00Z)" \
FM_FAKE_PR_COMMITS="1\n$(commit_record c73f62d0 2026-02-02T15:28:55Z false false testcaptain)" \
FM_FAKE_BRANCH_COMMITS="0" \
PATH="$BIN:$PATH" \
  "$SWEEP" --account testcaptain --since 2026-01-01T00:00:00Z \
  --repo acme/widgets --kind commits >"$WORK/out" 2>"$WORK/err"
printf '%s' $? >"$WORK/rc"

if out | grep -q 'FM_SWEEP_CANDIDATE .*kind=commit ref=c73f62d0 .*pr=24'; then
  pass "a commit reachable only through its pull request is still found"
else
  fail "deleted-branch commit was missed: $(out)"
fi
if out | grep -q 'FM_SWEEP_SCOPE .*kind=commits outcome=observed examined=1'; then
  pass "the pull request pass counts toward the commits scope"
else
  fail "commits scope tally wrong: $(out | grep FM_SWEEP_SCOPE || true)"
fi
if grep -q '/repos/acme/widgets/pulls/24/commits' "$FM_FAKE_LOG"; then
  pass "the commits scope actually asks GitHub for the pull request's commits"
else
  fail "the pull request commit listing was never requested"
fi

# --- an empty repository set is could-not-observe, never a clean sweep -------
# A token whose scopes exclude the account's repositories gets HTTP 200 with an
# empty array - the same bytes as an account that genuinely owns none. Neither
# can be called clean, because a run that looked at nothing has found nothing.
# No --repo is passed here, so the sweep must resolve the set itself.
: >"$FM_FAKE_LOG"
FM_FAKE_SCENARIO=clean FM_FAKE_BODY='' FM_FAKE_REPOS="0" PATH="$BIN:$PATH" \
  "$SWEEP" --account testcaptain --since 2026-01-01T00:00:00Z \
  >"$WORK/out" 2>"$WORK/err"
printf '%s' $? >"$WORK/rc"

if out | grep -q 'outcome=could-not-observe reason=empty-repository-set'; then
  pass "an empty owner listing is reported as could-not-observe"
else
  fail "empty repository set was not could-not-observe: $(out)"
fi
if out | grep -q 'outcome=clean'; then
  fail "an empty repository set printed a clean outcome"
else
  pass "an empty repository set never prints a clean outcome"
fi
if [ "$(rc)" = "20" ]; then
  pass "an empty repository set exits 20"
else
  fail "expected exit 20 for an empty repository set, got $(rc)"
fi
# A resolvable repository set must still sweep normally, or the check above
# would pass simply by refusing every run.
: >"$FM_FAKE_LOG"
FM_FAKE_SCENARIO=candidate \
FM_FAKE_BODY="1\n$(comment_record 900007 42 2026-02-02T10:00:00Z false OWNER none)" \
FM_FAKE_REPOS="1\n$(b64 acme/widgets)" PATH="$BIN:$PATH" \
  "$SWEEP" --account testcaptain --since 2026-01-01T00:00:00Z --kind comments \
  >"$WORK/out" 2>"$WORK/err"
printf '%s' $? >"$WORK/rc"
if out | grep -q 'FM_SWEEP_CANDIDATE .*repo=acme/widgets .*ref=900007'; then
  pass "a resolved repository set is still swept normally"
else
  fail "self-resolved repository set was not swept: $(out)"
fi

# --- 4. the sweep is read-only ---------------------------------------------
run_sweep candidate "1\n$(comment_record 900005 42 2026-02-02T10:00:00Z false OWNER none)" \
  --repo acme/widgets --kind comments
BAD_CALL=
while IFS=$'\t' read -r verb path rest; do
  [ -n "$verb" ] || continue
  if [ "$verb" != "api" ]; then
    BAD_CALL="non-api subcommand: $verb"
    break
  fi
  case $path in
    /*) ;;
    *) BAD_CALL="second argument is not a path: $path"; break ;;
  esac
  case " $rest " in
    *" --field "*|*" -X "*|*" --method "*|*" POST "*|*" PATCH "*|*" PUT "*|*" DELETE "*)
      BAD_CALL="mutating argument in: $rest"
      break
      ;;
  esac
done <"$FM_FAKE_LOG"
if [ -n "$BAD_CALL" ]; then
  fail "the sweep made a call that is not a plain GET ($BAD_CALL)"
else
  pass "every GitHub call is a plain GET"
fi
if [ -s "$FM_FAKE_LOG" ]; then
  pass "the read-only assertion ran against recorded calls"
else
  fail "no GitHub calls were recorded, so the read-only assertion checked nothing"
fi

# --- the permanent known-positives are labelled where a triager stands ------
# The probe artifacts are reported by every run whose window covers them, and an
# unlabelled permanent known-positive gets investigated as a real finding every
# time. The pointer therefore has to be in the output someone is holding, not
# only in a document they would have to know to open.
run_sweep candidate "1\n$(comment_record 900008 42 2026-02-02T10:00:00Z false OWNER none)" \
  --repo acme/widgets --kind comments
if out | grep -q 'docs/model-write-attribution.md'; then
  pass "the summary points a triager at the retained-probe table"
else
  fail "no pointer to the probe table in the summary: $(out)"
fi
if out | grep -q '2026-08-02'; then
  pass "the summary names the date whose candidates are known permanent ones"
else
  fail "the summary does not name the probe date: $(out)"
fi

# --- the convention is reachable from the tool itself ----------------------
TOKEN=$(PATH="$BIN:$PATH" "$SWEEP" --token)
if [ "$TOKEN" = "SOL-AI:" ]; then
  pass "the token is exactly SOL-AI:"
else
  fail "unexpected token: $TOKEN"
fi
if PATH="$BIN:$PATH" "$SWEEP" --convention | grep -qF "$TOKEN"; then
  pass "the pasteable preamble carries the same token the sweep looks for"
else
  fail "the preamble and the detector disagree about the token"
fi

# A usage error is its own status, never confused with a finding or a failure.
usage_rc=0
PATH="$BIN:$PATH" "$SWEEP" --kind bogus >/dev/null 2>&1 || usage_rc=$?
if [ "$usage_rc" = "64" ]; then
  pass "an unknown kind exits 64"
else
  fail "expected exit 64 for an unknown kind, got $usage_rc"
fi

# The worst window bug is the one that still exits 0. Every window filter is a
# string comparison against GitHub's timestamps, so a plausible-looking "30d"
# would sort below every record, examine nothing, and print a clean sweep. It has
# to be refused before it is ever compared against anything.
#
# The impossible dates below are the same bug from the other side: they match the
# shape a timestamp has, so a shape-only check would admit them, and they then
# sort ABOVE every real timestamp and drop every record just as silently.
for bad_since in 30d 2026-01-01 "2026-01-01 00:00:00" 2026-01-01T00:00:00+05:00 \
  2026-13-01T00:00:00Z 2026-00-01T00:00:00Z 2026-01-32T00:00:00Z 2026-01-00T00:00:00Z \
  2026-01-01T24:00:00Z 2026-01-01T00:00:69Z; do
  since_rc=0
  : >"$FM_FAKE_LOG"
  FM_FAKE_SCENARIO=clean FM_FAKE_BODY=0 PATH="$BIN:$PATH" \
    "$SWEEP" --account testcaptain --since "$bad_since" --repo acme/widgets \
    >/dev/null 2>&1 || since_rc=$?
  if [ "$since_rc" != "64" ]; then
    fail "expected exit 64 for --since '$bad_since', got $since_rc"
  elif [ -s "$FM_FAKE_LOG" ]; then
    fail "--since '$bad_since' reached GitHub before it was refused"
  else
    pass "--since '$bad_since' is refused with exit 64 before any request"
  fi
done

# A refusal that refuses everything would pass the loop above while making the
# tool useless, so the edges of every accepted component are swept for real. The
# leap second is one GitHub can print, and midnight and year end are the values a
# hand-typed window most often carries.
for good_since in 2026-01-01T00:00:00Z 2026-12-31T23:59:60Z 2026-08-09T09:08:07Z; do
  good_rc=0
  : >"$FM_FAKE_LOG"
  FM_FAKE_SCENARIO=clean FM_FAKE_BODY=0 PATH="$BIN:$PATH" \
    "$SWEEP" --account testcaptain --since "$good_since" --repo acme/widgets \
    --kind comments >/dev/null 2>&1 || good_rc=$?
  if [ "$good_rc" = "0" ] && [ -s "$FM_FAKE_LOG" ]; then
    pass "--since '$good_since' is accepted and actually sweeps"
  else
    fail "a real timestamp was refused: --since '$good_since' exited $good_rc"
  fi
done

exit "$FAILED"
