#!/usr/bin/env bash
# Behavioral smoke for playstudio-agent-loop driver help and refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$ROOT/.agents/skills/playstudio-agent-loop/ps-agent-loop.sh"
SKILL="$ROOT/.agents/skills/playstudio-agent-loop/SKILL.md"

test_skill_and_driver_surface() {
  assert_present "$SKILL" "playstudio-agent-loop skill is missing"
  assert_present "$DRIVER" "playstudio-agent-loop driver is missing"
  assert_grep 'ensureSession' "$SKILL" "skill omits ensureSession"
  assert_grep 'waitSettled' "$SKILL" "skill omits waitSettled"
  assert_grep 'fixture-blackjack' "$SKILL" "skill omits blackjack fixture"
  assert_grep 'Continue with Microsoft Entra' "$SKILL" "skill omits Entra self-click guidance"
  assert_grep 'MFA/passkey' "$SKILL" "skill omits MFA-only block guidance"
  assert_grep 'review.mp4' "$SKILL" "skill omits review.mp4 artifact path"
  assert_grep '--review-dir' "$DRIVER" "driver omits --review-dir for waitSettled"
  assert_grep '_stitch_review_mp4' "$DRIVER" "driver omits ffmpeg stitch helper"
  assert_grep 'PS_DAYTONA_PRUNE_STARTED' "$SKILL" "skill omits Daytona prune flag"
  assert_grep 'started_mem' "$SKILL" "skill omits Daytona started_mem gate"
  assert_grep '_daytona_capacity_gate' "$DRIVER" "driver omits Daytona capacity gate"
  assert_grep 'strict=False' "$DRIVER" "driver omits tolerant JSON loads"
  assert_grep 'demo-session' "$SKILL" "skill should explicitly refuse demo-session"
  assert_grep 'Do **not** call agent-host' "$SKILL" "skill lost agent-host turn refusal"
  assert_grep 'never agent-host' "$DRIVER" "driver header lost agent-host refusal"

  local help
  help="$("$DRIVER" --help 2>&1)" || fail "driver --help failed"
  printf '%s\n' "$help" | grep -q 'ensureSession' || fail "driver help omits ensureSession"
  printf '%s\n' "$help" | grep -q 'fixture-blackjack' || fail "driver help omits fixture-blackjack"
  printf '%s\n' "$help" | grep -q 'demo-session' || fail "driver help should mention demo-session refusal"

  if "$DRIVER" unknown-verb >/dev/null 2>&1; then
    fail "driver accepted an unknown verb"
  fi
  pass "playstudio-agent-loop skill and driver expose the expected mate surface"
}

test_skill_and_driver_surface
