#!/usr/bin/env bash
# Opt-in live guard for the agy (Antigravity CLI) surface contracts the adapter
# is built on. Every check below reads something the VENDOR emits, so a stub
# could only confirm the assumption already written into the stub; each one is
# therefore run against the installed binary and reported with its exact
# version.
#
# What this guard protects, and why each item is load-bearing:
#   - agy rejects a positional prompt. bin/fm-spawn.sh's launch template passes
#     the brief through -i because of this. If a release ever accepted a
#     positional prompt the template would still work, but if -i were withdrawn
#     every agy spawn would fail at launch.
#   - --effort advertises only low|medium|high. bin/fm-spawn.sh omits xhigh and
#     max rather than passing a value agy refuses. agy validates that value
#     inside its TUI rather than at flag-parse time, so the advertised
#     vocabulary is what this guard reads.
#   - `agy models` answers without opening a session, which is what makes model
#     discovery usable at dispatch time.
#   - the customization root still resolves the way the Stop-hook installer
#     assumes.
#
# Set FM_AGY_TURNEND_LIVE_E2E=1 as well to check the SHAPE of a Stop payload the
# operator captured from a real agy turn and handed over in
# FM_AGY_TURNEND_PAYLOAD. It spends no turn of its own and it does not re-prove
# the fullyIdle rule: that a true value ends a turn and a false or absent one
# does not is owned by tests/fm-agy-harness.test.sh, which drives the installed
# hook against the captured payloads. This check answers only whether the vendor
# still emits the two keys that gate reads.
# docs/verification/agy.md records the dated result of both.
set -u

if [ "${FM_AGY_SURFACE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AGY_SURFACE_LIVE_E2E=1 to run the agy surface guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGY_BIN=${FM_AGY_BIN:-$(command -v agy || true)}
# An absent harness is reported, never silently passed over.
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "agy is not installed; this guard must not report a pass that checked nothing (set FM_AGY_BIN to an exact path)"

AGY_VERSION=$("$AGY_BIN" --version 2>&1 | head -1)
[ -n "$AGY_VERSION" ] || fail "agy at $AGY_BIN did not report a version"
echo "# agy $AGY_VERSION ($AGY_BIN)"

CHECKS_RUN=0

# agy must keep refusing a positional prompt AND keep offering -i, because
# bin/fm-spawn.sh's launch template depends on both halves.
# The probe runs from a disposable empty directory, never from the suite's own
# working copy. The very contract it guards is that agy REFUSES this command,
# so the case it exists to catch is the one where agy accepts it and starts an
# autonomous, permission-skipping session in whatever directory it was given.
test_positional_prompt_is_rejected() {
  local out probe_dir
  probe_dir=$(fm_test_tmproot fm-agy-positional) \
    || fail "no scratch directory could be created to run the positional-prompt probe outside the repository"
  out=$(cd "$probe_dir" && "$AGY_BIN" --dangerously-skip-permissions "a positional prompt" 2>&1 </dev/null || true)
  case "$out" in
    *"unexpected argument"*) : ;;
    *) fail "agy $AGY_VERSION no longer rejects a positional prompt, so the launch template's premise changed: $out" ;;
  esac
  out=$("$AGY_BIN" --help 2>&1 || true)
  case "$out" in
    *" -i,"*|*" -i "*) : ;;
    *) fail "agy $AGY_VERSION no longer advertises the short -i, which is the exact spelling every agy spawn passes the brief through: $out" ;;
  esac
  CHECKS_RUN=$((CHECKS_RUN + 1))
  pass "agy $AGY_VERSION rejects a positional prompt and still offers -i"
}

# The effort clamp in bin/fm-spawn.sh omits xhigh and max because agy accepts
# only low|medium|high. agy validates that value INSIDE its TUI rather than at
# flag-parse time - passing xhigh gets all the way to terminal setup - so the
# vocabulary is read from the flag description agy itself prints, which is the
# same string the vendor would have to change to change the contract.
test_effort_vocabulary() {
  local out line
  out=$("$AGY_BIN" --help 2>&1 || true)
  line=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*--effort' | head -1)
  [ -n "$line" ] || fail "agy $AGY_VERSION no longer advertises --effort, which bin/fm-spawn.sh passes for a non-default effort"
  case "$line" in
    *"low|medium|high"*) : ;;
    *) fail "agy $AGY_VERSION changed its advertised effort vocabulary; re-check the clamp in bin/fm-spawn.sh: $line" ;;
  esac
  # The clamp is only correct while these stay OUTSIDE the vocabulary. If agy
  # ever admitted them, firstmate would be silently downgrading a captain's
  # explicit choice rather than omitting an unsupported one.
  case "$line" in
    *xhigh*|*max*) fail "agy $AGY_VERSION now advertises an effort level the clamp drops: $line" ;;
  esac
  # --model has no vocabulary to pin, but the flag itself must still exist.
  printf '%s\n' "$out" | grep -qE '^[[:space:]]*--model' \
    || fail "agy $AGY_VERSION no longer advertises --model, which bin/fm-spawn.sh passes for a non-default model"
  CHECKS_RUN=$((CHECKS_RUN + 1))
  pass "agy $AGY_VERSION still advertises effort low|medium|high and a model flag"
}

# Model discovery must stay answerable without opening a session, or dispatch
# cannot enumerate models without spending a turn.
test_model_discovery_needs_no_session() {
  local out
  out=$("$AGY_BIN" models 2>&1 </dev/null || true)
  [ -n "$out" ] || fail "agy $AGY_VERSION 'models' returned nothing"
  case "$out" in
    *gemini*|*claude*|*gpt*) : ;;
    *) fail "agy $AGY_VERSION 'models' did not list any recognizable model id: $out" ;;
  esac
  CHECKS_RUN=$((CHECKS_RUN + 1))
  pass "agy $AGY_VERSION lists models without opening a session"
}

# The Stop-hook installer writes a plugin under this FIXED root - there is no
# environment override, so spawn and teardown resolve it identically. If agy
# relocated its global customization root the installer would write somewhere
# agy no longer reads, and every turn-end signal would silently stop arriving.
test_customization_root_is_where_the_installer_writes() {
  local root
  root="$HOME/.gemini/config"
  [ -d "$root" ] \
    || fail "agy $AGY_VERSION global customization root '$root' is absent; bin/fm-spawn.sh installs its turn-end plugin there"
  CHECKS_RUN=$((CHECKS_RUN + 1))
  pass "agy $AGY_VERSION's global customization root is where the turn-end installer writes"
}

# The SHAPE of a Stop payload the operator captured from a real agy turn: the
# keys fullyIdle and workspacePaths must both still be PRESENT, because those
# are what the installed hook parses. What the hook tolerates is a different
# question from what this guard demands: the hook treats an absent fullyIdle as
# not a turn end, while a vendor that stops emitting the key at all is exactly
# the drift that would silently end every turn-end signal, so presence is the
# assertion. Every Stop measured in the lab carried it explicitly, including the
# interrupted turn. It asserts nothing about what those values MEAN - the
# fullyIdle rule is owned by the portable regression - and it spends no turn, so
# the operator supplies the capture.
test_turn_end_payload_contract() {
  local lab payload
  if [ "${FM_AGY_TURNEND_LIVE_E2E:-0}" != 1 ]; then
    echo "# skip: set FM_AGY_TURNEND_LIVE_E2E=1 with FM_AGY_TURNEND_PAYLOAD to check a captured Stop payload's shape"
    return 0
  fi
  lab=${FM_AGY_TURNEND_PAYLOAD:-}
  [ -n "$lab" ] && [ -f "$lab" ] \
    || fail "FM_AGY_TURNEND_LIVE_E2E=1 requires FM_AGY_TURNEND_PAYLOAD to name a captured Stop payload file from a real agy turn"
  payload=$(cat "$lab")
  command -v jq >/dev/null 2>&1 || fail "jq is required to check the agy Stop payload contract"
  printf '%s' "$payload" | jq -e 'has("fullyIdle")' >/dev/null 2>&1 \
    || fail "agy $AGY_VERSION Stop payload no longer carries fullyIdle; the turn-end gate has no signal to read"
  printf '%s' "$payload" | jq -e 'has("workspacePaths")' >/dev/null 2>&1 \
    || fail "agy $AGY_VERSION Stop payload no longer carries workspacePaths; the hook cannot resolve its task worktree"
  CHECKS_RUN=$((CHECKS_RUN + 1))
  pass "agy $AGY_VERSION's Stop payload still carries fullyIdle and workspacePaths"
}

test_positional_prompt_is_rejected
test_effort_vocabulary
test_model_discovery_needs_no_session
test_customization_root_is_where_the_installer_writes
test_turn_end_payload_contract

[ "$CHECKS_RUN" -ge 4 ] \
  || fail "the agy surface guard ran only $CHECKS_RUN checks; refusing to report a pass that checked nothing"

echo "all fm-agy-surface-live-e2e checks passed against agy $AGY_VERSION"
