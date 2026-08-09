#!/usr/bin/env bash
# fm-verify-fork-landing.sh - the bound verifier for the fork-landing LoopSpec.
#
# WHAT IT DECIDES, and only this: for the contribution named by the event key,
# does a pull request exist on the fork, and have that pull request's own checks
# reached a resolved state? That is the whole question. It does not decide
# whether the contribution is good, whether it should merge, or whether anything
# should happen next.
#
# WHY IT IS A LEGITIMATE VERIFIER. A LoopSpec is only genuinely loopable when a
# named verifier can produce different evidence after an iteration because of the
# action that iteration took. That holds here: before the iteration opens the
# fork pull request this reports no pull request and fails; after it does, this
# reports the pull request and its checks. The evidence moves because the action
# moved it, which is exactly the property that distinguishes a loop from mere
# repetition.
#
# It is level l2: deterministic, but reading external evidence (the forge) rather
# than only the local tree. It needs no model, no judgment and no vendor
# diversity, which is why it is preferred while maker/checker vendor separation
# is degraded.
#
# THIS VERIFIER NEVER MERGES. It has no write path at all. The loop it serves
# terminates at ready-for-merge; landing stays a separate act under existing
# authority.
#
# Invocation contract, owned by bin/fm-loopspec.sh verify:
#   --spec <id> --spec-version <n> --event-key <k> --iteration <i>
# The event key is the fork branch name carrying the contribution.
#
# Exit status: 0 pass, 1 fail (ran and rejected), 2 unavailable (could not
# establish the evidence; fail-closed, and never a pass).
#
# Every fact it observes is printed on stdout as one evidence line, and those
# lines become the loop's recorded evidence.
set -u

REPO="${FM_FORK_REPO:-sbracewell64/firstmate}"
EVENT_KEY=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event-key) EVENT_KEY=${2:-}; shift 2 ;;
    --spec|--spec-version|--iteration) shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$EVENT_KEY" ]; then
  printf 'unavailable: no event key supplied, so there is no branch to verify\n'
  exit 2
fi

if ! command -v gh-axi >/dev/null 2>&1; then
  printf 'unavailable: gh-axi is not installed, so forge evidence cannot be read\n'
  exit 2
fi

# The forge is the authority on whether the pull request exists. An unreadable
# forge is unavailable, never "no pull request": absence of evidence must not be
# read as evidence of absence.
listing=$(gh-axi pr list --repo "$REPO" --state open --head "$EVENT_KEY" 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  printf 'unavailable: could not list pull requests on %s for head %s\n' "$REPO" "$EVENT_KEY"
  exit 2
fi

number=$(printf '%s\n' "$listing" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),".*/\1/p' | head -1)
if [ -z "$number" ]; then
  printf 'fail: no open pull request on %s with head %s\n' "$REPO" "$EVENT_KEY"
  printf 'evidence: the contribution has not been carried to the fork yet\n'
  exit 1
fi

printf 'evidence: fork pull request %s exists on %s for head %s\n' "$number" "$REPO" "$EVENT_KEY"

checks=$(gh-axi pr checks "$number" --repo "$REPO" 2>&1)
status=$?
# `pr checks` exits non-zero when checks are failing, which is a real verdict and
# not an inability to read one. Only an empty read is unavailable.
if [ -z "$checks" ]; then
  printf 'unavailable: could not read the checks for pull request %s\n' "$number"
  exit 2
fi

# Parse the authoritative summary line, never the prose. Counting matches of
# "fail" across the whole listing also matches the summary's own "0 failed" and
# every check whose NAME contains the word, which reaches a plausible verdict for
# entirely the wrong reason.
summary=$(printf '%s\n' "$checks" | sed -n 's/^summary:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' | head -1)
if [ -z "$summary" ]; then
  # A pull request whose checks have not been registered yet reports a different
  # shape entirely. It is unavailable, not resolved: treating "no checks
  # configured" as a resolved empty set would pass a pull request that nothing
  # has examined, which is the exact shape of a verifier that verifies nothing.
  if printf '%s\n' "$checks" | grep -q 'no CI checks configured'; then
    printf 'unavailable: pull request %s has no checks registered yet, so nothing has examined it\n' "$number"
  else
    printf 'unavailable: pull request %s returned no parsable check summary\n' "$number"
  fi
  exit 2
fi

# The summary omits any clause whose count is zero, so an absent clause means
# zero and only an absent TOTAL means the summary could not be read. Requiring
# every clause treated a fully resolved pull request as unreadable; defaulting
# every clause to zero would let a genuinely unreadable summary look resolved.
# The reconciliation below is what makes the difference safe: if the parts do not
# add up to the total, a clause was missed and this refuses rather than guessing.
read_count() {
  local n
  n=$(printf '%s\n' "$summary" | sed -n "s/.*[^0-9]\([0-9][0-9]*\) $1.*/\1/p" | head -1)
  [ -n "$n" ] || n=$(printf '%s\n' "$summary" | sed -n "s/^\([0-9][0-9]*\) $1.*/\1/p" | head -1)
  printf '%s\n' "${n:-0}"
}
passed=$(read_count passed)
failed=$(read_count failed)
pending=$(read_count pending)
total=$(printf '%s\n' "$summary" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) total.*/\1/p' | head -1)
case "${total:-}" in
  ''|*[!0-9]*)
    printf 'unavailable: could not read the total check count from the summary of pull request %s\n' "$number"
    exit 2 ;;
esac
if [ "$((passed + failed + pending))" -ne "$total" ]; then
  printf 'unavailable: check summary of pull request %s does not reconcile (%s passed + %s failed + %s pending != %s total)\n' \
    "$number" "$passed" "$failed" "$pending" "$total"
  exit 2
fi

printf 'evidence: check summary for pull request %s: passed=%s failed=%s pending=%s total=%s\n' \
  "$number" "$passed" "$failed" "$pending" "$total"

if [ "$total" -eq 0 ]; then
  printf 'unavailable: pull request %s reports no checks at all, so nothing was verified\n' "$number"
  exit 2
fi

if [ "$pending" -gt 0 ]; then
  printf 'fail: pull request %s still has %s check(s) in flight, so its state is not yet resolved\n' "$number" "$pending"
  exit 1
fi

# What this pass asserts, exactly: the contribution reached the fork and its
# checks finished. It does NOT assert that they are green, and the failed count
# above is part of the record precisely so this can never be read as a green
# light. Whether a red pull request may land is the merge decision, which this
# loop deliberately never makes.
if [ "$failed" -gt 0 ]; then
  printf 'evidence: NOT GREEN - %s check(s) failed; this pass asserts only that the contribution was carried and its checks resolved\n' "$failed"
fi
printf 'evidence: pull request %s has no checks in flight; the carry is verified and the merge decision has its inputs\n' "$number"
printf 'evidence: verifier made no write of any kind; landing remains a separate act under existing authority\n'
exit 0
