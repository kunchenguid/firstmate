#!/usr/bin/env bash
# tests/fm-submit-latency-live-e2e.test.sh - the live submit-acceptance-latency
# guard (live-harness-optin family).
#
# The submit confirmation window (bin/fm-composer-lib.sh: "Submit confirmation
# window") is sized from how long a real harness takes to ACCEPT a submitted
# line, which is a vendor timing fact: per
# .agents/skills/firstmate-coding-guidelines a stub can only confirm the
# assumption already written into the stub. This guard drives the REAL herdr
# submit core against every INSTALLED verified harness with a realistic
# firstmate steer - a few hundred characters, the length that exposed the bug
# on agy, where a short one never did - into a worker that is MID-TURN, the
# condition firstmate actually steers under, and requires a confirmed submit,
# failing loudly with the harness name and version.
#
# It also reports the elapsed confirmation time per harness, which is what
# docs/verification/runtime-backends.md ("Submit acceptance latency") records;
# refresh that table from this guard's output after a harness upgrade.
#
# This guard DOES submit one prompt per harness and therefore spends model
# tokens, which is why it is opt-in and separate from the token-free
# composer-matrix guard. Run explicitly with FM_SUBMIT_LATENCY_LIVE=1.
#
# Isolation: every Herdr call goes through bin/fm-herdr-lab.sh's named
# non-default lab session, which records the live default session before
# provisioning and requires an identical fleet state after teardown. An absent
# harness is reported explicitly and skipped; a run that verified nothing fails
# rather than passing vacuously.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_SUBMIT_LATENCY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_SUBMIT_LATENCY_LIVE=1 to run the live submit-acceptance-latency guard (spends model tokens)"
  exit 0
fi

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

command -v herdr >/dev/null 2>&1 || { echo "not ok - FM_SUBMIT_LATENCY_LIVE=1 but herdr is not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "not ok - FM_SUBMIT_LATENCY_LIVE=1 but jq is not installed" >&2; exit 1; }

LAB=$(fm_herdr_lab_name submit-latency) || exit 1
CHECKED=0
FAILED=0
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-slat-live.XXXXXX")

cleanup() {
  fm_herdr_lab_teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_herdr_lab_provision "$LAB" >/dev/null || fail "could not provision the isolated Herdr lab session"

export FM_BACKEND=herdr
export HERDR_SESSION="$LAB"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

# A realistic firstmate steer. Its LENGTH is the whole point of this guard: the
# shipped bug never fired on a short one.
STEER='Decision on the open question you raised: go with option B, the isolated worktree approach, and keep the existing guard exactly as it is - do not widen the check under any circumstances, because a check that passes when it cannot confirm is worse than one that cries wolf. Add a regression test that pins the new behaviour in both directions, refresh the verification record with the measured numbers, then push the branch and open the pull request against the fork rather than origin. Reply with only the word ACK and nothing else, and do not summarise this instruction back to me.'
# The steer must go into a worker that is MID-TURN, which is when firstmate
# actually steers and the only condition under which the constant window
# expired: an idle harness accepts fast enough to hide the defect.
BUSY_PROMPT='Without using any tools and without stopping, write a long detailed essay of at least 2000 words about the history of maritime navigation. Keep writing continuously and do not stop early.'

harness_version() { "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'; }

make_pane() {  # <label> -> pane id
  local label=$1 out ws
  out=$(fm_herdr_lab_cli "$LAB" workspace create --cwd "$WORKDIR" --label "$label" --no-focus) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  [ -n "$ws" ] || return 1
  out=$(fm_herdr_lab_cli "$LAB" tab create --workspace "$ws" --cwd "$WORKDIR" --label "$label" --no-focus) || return 1
  printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty'
}

check_harness_submit() {  # <name> <launch-command-line>
  local name=$1 launch=$2 pane target version i=0 trusted=0 verdict started elapsed
  version=$(harness_version "$name")
  pane=$(make_pane "sl-$name") || { FAILED=1; printf 'not ok - %s (%s): could not create an isolated lab pane\n' "$name" "$version" >&2; return; }
  target="$LAB:$pane"
  fm_herdr_lab_cli "$LAB" pane send-text "$pane" "$launch" >/dev/null || true
  sleep 0.5
  fm_herdr_lab_cli "$LAB" pane send-keys "$pane" enter >/dev/null || true
  # A first launch in this guard's own fresh temp directory parks on the
  # vendor folder-trust prompt, whose default option is already "yes" in every
  # harness that shows one. Answer it once, and only when the pane actually
  # shows that prompt, rather than launching in the repo where a submitted
  # turn could touch tracked files.
  while [ "$i" -lt 90 ]; do
    [ "$(fm_backend_herdr_composer_state "$target")" = empty ] && break
    if [ "$trusted" -eq 0 ] \
      && fm_backend_herdr_capture "$target" 25 2>/dev/null | grep -qi 'trust'; then
      fm_herdr_lab_cli "$LAB" pane send-keys "$pane" enter >/dev/null || true
      trusted=1
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$(fm_backend_herdr_composer_state "$target")" != empty ]; then
    FAILED=1
    printf 'not ok - %s (%s): never reached an idle empty composer, so its submit could not be measured\n' "$name" "$version" >&2
    printf '# %s pane tail:\n' "$name" >&2
    fm_backend_herdr_capture "$target" 12 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    return
  fi
  fm_backend_herdr_send_text_submit "$target" "$BUSY_PROMPT" 3 0.4 0.4 >/dev/null
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(fm_backend_herdr_agent_status_raw "$LAB" "$pane")" = working ] && break
    i=$((i + 1))
    sleep 1
  done
  if [ "$(fm_backend_herdr_agent_status_raw "$LAB" "$pane")" != working ]; then
    FAILED=1
    printf 'not ok - %s (%s): never entered a turn, so a mid-turn steer could not be measured\n' "$name" "$version" >&2
    return
  fi
  sleep 5
  started=$SECONDS
  verdict=$(fm_backend_herdr_send_text_submit "$target" "$STEER" 3 0.4 0.4)
  elapsed=$((SECONDS - started))
  if [ "$verdict" = empty ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): a ${#STEER}-character mid-turn steer confirmed submitted in ${elapsed}s"
  else
    FAILED=1
    printf 'not ok - %s (%s): a %s-character mid-turn steer returned %s instead of a confirmed submit\n' \
      "$name" "$version" "${#STEER}" "$verdict" >&2
    printf '# %s pane tail at failure:\n' "$name" >&2
    fm_backend_herdr_capture "$target" 14 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
}

for h in agy claude codex opencode pi grok kimi muse; do
  if command -v "$h" >/dev/null 2>&1; then
    case "$h" in
      agy|claude) check_harness_submit "$h" "$h --dangerously-skip-permissions" ;;
      *) check_harness_submit "$h" "$h" ;;
    esac
  else
    note "harness absent, not verified here: $h"
  fi
done

[ "$CHECKED" -gt 0 ] || fail "the live submit-acceptance-latency guard verified no harness at all; it must never pass vacuously"
[ "$FAILED" -eq 0 ] || fail "one or more installed harnesses failed the live submit-acceptance-latency guard"
pass "live submit-acceptance-latency guard: $CHECKED installed harness(es) confirmed a realistic-length steer"
