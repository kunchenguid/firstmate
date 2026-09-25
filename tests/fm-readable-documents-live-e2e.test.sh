#!/usr/bin/env bash
# Credentialed behavior regression for the readable-documents body-only rubric.
#
# This drives Pi's public skill-loading interface with one positive and one
# negative document body. The verdict must come from the loaded skill rather
# than a source-text or snapshot assertion.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_READABLE_DOCUMENTS_LIVE_E2E pi

command -v pi >/dev/null 2>&1 || fail "pi not found"

out=$(
  cd "$ROOT" &&
    pi --print --approve --no-session --no-context-files --no-extensions \
      --no-skills --skill .agents/skills/readable-documents --tools read \
      --model openai-codex/gpt-5.6-sol --thinking low \
      'Apply the loaded readable-documents skill to the two bodies below. Return exactly four lines and no other text:
POSITIVE=PASS
NEGATIVE=FAIL
NEGATIVE_GAP=NO_CAUSE_OR_TRANSITION
EVIDENCE=AUTHOR_CHECK_ONLY

Positive body:
Today, retry R17 can be accepted by two workers because both check availability before either records ownership. We will make one compare-and-swap lease the acceptance boundary. Worker A records generation 4 and proceeds; worker B sees generation 4 and declines. Routing and response formats remain unchanged. A later section defines lease fields, stale-owner recovery, and an executable duplicate-acceptance test.

Negative body:
Conclusion: add RequestRouter, LeaseRow, and retry_generation. Sections below list every interface, state, error, and test. The glossary defines each term.'
) || fail "Pi readable-documents run failed: $out"

expected=$(cat <<'EOF'
POSITIVE=PASS
NEGATIVE=FAIL
NEGATIVE_GAP=NO_CAUSE_OR_TRANSITION
EVIDENCE=AUTHOR_CHECK_ONLY
EOF
)

[ "$out" = "$expected" ] \
  || fail "Pi did not apply the body-only rubric as required: $out"

pass "readable-documents accepts a causal through-line, rejects an inventory-only body, and labels self-check evidence"
