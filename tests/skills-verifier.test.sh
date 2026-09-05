#!/usr/bin/env bash
# Behavioral regressions for the skills-verifier loop's deterministic guarantees.
#
# The loop this skill owns is orchestrated by independent pi agents, so a
# model's prose cannot be pinned by a test. What CAN be pinned is the rules the
# loop treats as code, because they decide which version wins, when negotiation
# must stop, and whether a judge can tell the versions apart. Those rules are
# declared in SKILL.md's contract (Phase 4's bump bullets and negotiation cap,
# Phase 5's labeling and stripping orders); this test DERIVES its inputs from
# that contract and executes gates keyed on the derived values, so the shipped
# skill and this suite cannot drift apart with the suite green.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_MD="$ROOT/.agents/skills/skills-verifier/SKILL.md"
assert_present "$SKILL_MD" "the shipped skill must exist for its contract to be tested"

# --- inputs derived from SKILL.md's contract --------------------------------

# bump_classes -> the version-bump classes Phase 4 declares, in contract order.
bump_classes() {
  sed -nE 's/^- \*\*(PATCH|MINOR|MAJOR)\*\* -.*/\1/p' "$SKILL_MD" | tr '[:upper:]' '[:lower:]'
}

# bump_rule_line <class> -> Phase 4's own description of that bump class.
bump_rule_line() {
  sed -nE "s/^- \*\*$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')\*\* - (.*)/\1/p" "$SKILL_MD"
}

# negotiation_cap -> the round cap Phase 4 declares ("capped at N suggestion
# rounds"), as a number. Fails loudly when the contract stops declaring one.
negotiation_cap() {
  local word
  word=$(sed -nE 's/.*capped at ([a-z]+) suggestion rounds.*/\1/p' "$SKILL_MD" | head -n 1)
  case "$word" in
    one) echo 1 ;;
    two) echo 2 ;;
    three) echo 3 ;;
    four) echo 4 ;;
    five) echo 5 ;;
    *) return 1 ;;
  esac
}

# blind_labels -> the two labels Phase 5 assigns, in contract order.
blind_labels() {
  sed -nE 's/^- Label the versions ([A-Z]) and ([A-Z]).*/\1 \2/p' "$SKILL_MD"
}

# strip_markers -> every metadata key Phase 5 orders stripped ("Strip all
# metadata ... including author, timestamp, ..."). Commas and "and" both
# separate markers; no token the contract sentence declares may be filtered
# out, so a reworded contract cannot grow a marker this suite stops testing.
strip_markers() {
  sed -nE 's/^- Strip all metadata.* including (.*)\..*/\1/p' "$SKILL_MD" |
    sed -E 's/[[:space:]]+and[[:space:]]+/,/g' |
    tr ',' '\n' |
    sed -E 's/^[[:space:]]+|[[:space:]]+$//g' |
    grep -v '^$'
}

# --- gates executed against the derived contract -----------------------------

# classify_bump <change-description> -> the bump class whose own Phase 4 rule
# line names the change; refuses change classes no declared rule covers.
classify_bump() {
  local class
  while IFS= read -r class; do
    case "$(bump_rule_line "$class")" in
      *"$1"*) printf '%s\n' "$class"; return 0 ;;
    esac
  done < <(bump_classes)
  return 1
}

# negotiation_open <round> -> whether the declared cap still admits this round.
negotiation_open() {
  local cap
  cap=$(negotiation_cap) || return 1
  [ "$1" -le "$cap" ]
}

# anonymize <body-a> <body-b> -> "<label>:<body>" lines using the derived
# labels, assigned at random, with every derived marker stripped from each body.
anonymize() {
  local la lb a b flip marker strip_re
  read -r la lb <<EOF
$(blind_labels)
EOF
  strip_re="^($(
    local first=1 marker
    while IFS= read -r marker; do
      [ "$first" = 1 ] || printf '|'
      printf '%s' "$marker"
      first=0
    done < <(strip_markers)
  )):"
  a=$(printf '%s' "$1" | sed -E "s/$strip_re.*/<redacted>/")
  b=$(printf '%s' "$2" | sed -E "s/$strip_re.*/<redacted>/")
  flip=$(( RANDOM % 2 ))
  if [ "$flip" = "0" ]; then
    printf '%s:%s\n%s:%s\n' "$la" "$a" "$lb" "$b"
  else
    printf '%s:%s\n%s:%s\n' "$la" "$b" "$lb" "$a"
  fi
}

# label_of <label> -> the body line out of an anonymize() pair.
label_of() { grep "^$1:" | sed "s/^$1://"; }

# --- tests -------------------------------------------------------------------

test_bump_contract_declares_exactly_three_classes() {
  local classes
  classes=$(bump_classes | tr '\n' ' ' | sed 's/ $//')
  expect_code "patch minor major" "$classes" "Phase 4 declares exactly PATCH, MINOR, MAJOR in order"
  pass "the version-bump contract declares exactly three ordered classes"
}

test_version_bump_is_truthful_and_total() {
  local got
  got=$(classify_bump "wording") || fail "wording must classify"
  expect_code patch "$got" "wording/clarity bumps PATCH"
  got=$(classify_bump "bounded capability") || fail "a bounded capability must classify"
  expect_code minor "$got" "a new bounded capability bumps MINOR"
  got=$(classify_bump "a behavior change") || fail "a behavior change must classify"
  expect_code major "$got" "a behavior change bumps MAJOR"
  if classify_bump "completely different" >/dev/null 2>&1; then
    fail "an unsupported change class must be refused, not guessed"
  fi
  pass "version bump classification follows the contract and does not guess"
}

test_negotiation_cap_holds() {
  local cap round
  cap=$(negotiation_cap) || fail "the contract must declare a suggestion-round cap"
  [ "$cap" -ge 1 ] || fail "the negotiation cap must admit at least one round"
  round=1
  while [ "$round" -le "$cap" ]; do
    negotiation_open "$round" || fail "round $round must be admitted under a cap of $cap"
    round=$((round + 1))
  done
  if negotiation_open "$round"; then
    fail "round $round exceeds the declared cap of $cap and must be refused"
  fi
  pass "the negotiation admits exactly the declared rounds and refuses the next"
}

test_blind_label_randomizes_per_round() {
  local la lb out_a seen_ab=0 seen_ba=0
  read -r la lb <<EOF
$(blind_labels)
EOF
  [ -n "$la" ] && [ -n "$lb" ] || fail "Phase 5 must declare two blind labels"
  for _ in $(seq 1 30); do
    out_a=$(anonymize "body-alpha" "body-beta" | label_of "$la")
    case "$out_a" in
      "body-alpha") seen_ab=$(( seen_ab + 1 )) ;;
      "body-beta") seen_ba=$(( seen_ba + 1 )) ;;
    esac
  done
  [ "$seen_ab" -gt 0 ] && [ "$seen_ba" -gt 0 ] || fail "the blind labels did not randomize across rounds"
  pass "blind-judging labels randomize so the newer version is not inferable from labeling"
}

test_blind_label_strips_every_declared_marker() {
  local draft labeled marker
  [ -n "$(strip_markers)" ] || fail "SKILL.md no longer declares any strip markers, so the stripping contract cannot be tested"
  draft="author: ver-agent
timestamp: 2026-08-30T23:25:00Z
body-only-content"
  labeled=$(anonymize "$draft" "$draft")
  while IFS= read -r marker; do
    assert_not_contains "$labeled" "$marker: " "the blind label leaks a declared $marker marker"
  done < <(strip_markers)
  assert_contains "$labeled" "body-only-content" "the blind label kept the real body content"
  pass "blind judging strips every metadata marker the contract declares"
}

test_bump_contract_declares_exactly_three_classes
test_version_bump_is_truthful_and_total
test_negotiation_cap_holds
test_blind_label_randomizes_per_round
test_blind_label_strips_every_declared_marker
