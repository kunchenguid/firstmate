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
  assert_grep '_job_slim_status_js' "$DRIVER" "driver omits slim waitSettled poll helper"
  assert_grep 'frameCount' "$DRIVER" "driver slim poll omits frameCount"
  assert_grep '_job_message_summaries_js' "$DRIVER" "driver omits slim snapshotMessages helper"
  assert_grep 'NEVER stringify frames' "$DRIVER" "driver lost slim-poll frames ban comment"
  assert_grep 'demo-session' "$SKILL" "skill should explicitly refuse demo-session"
  assert_grep 'Do **not** call agent-host' "$SKILL" "skill lost agent-host turn refusal"
  assert_grep 'never agent-host' "$DRIVER" "driver header lost agent-host refusal"
  assert_grep 'slim status object' "$SKILL" "skill omits slim waitSettled poll guidance"
  assert_grep 'Slim message summaries' "$SKILL" "skill omits slim snapshotMessages guidance"

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

test_slim_waitsettled_poll_shape() {
  # Slim poll JS must not stringify the page job wholesale (frames[]).
  local slim_js
  slim_js="$(
    DRIVER="$DRIVER" bash <<'EOS'
eval "$(sed -n '/^_job_slim_status_js()/,/^}/p' "$DRIVER")"
_job_slim_status_js "job_test"
EOS
  )"
  printf '%s\n' "$slim_js" | grep -q 'frameCount' || fail "slim poll JS missing frameCount"
  printf '%s\n' "$slim_js" | grep -q 'settledType' || fail "slim poll JS missing settledType"
  printf '%s\n' "$slim_js" | grep -q 'lastRunEventSeq' || fail "slim poll JS missing lastRunEventSeq"
  if printf '%s\n' "$slim_js" | grep -Eq 'frames[[:space:]]*:[[:space:]]*frames|frames[[:space:]]*:[[:space:]]*job\.frames'; then
    fail "slim poll JS still returns frames array through axi"
  fi
  pass "playstudio-agent-loop slim waitSettled poll shape is axi-safe"
}

test_skill_and_driver_surface
test_slim_waitsettled_poll_shape
