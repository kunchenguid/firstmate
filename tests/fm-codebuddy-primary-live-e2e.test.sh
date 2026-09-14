#!/usr/bin/env bash
# Live end-to-end guard for the CodeBuddy Code primary hook contract.
#
# Everything else about the codebuddy primary is pinned offline (see
# tests/fm-codebuddy-harness.test.sh). What only a real `codebuddy` process can
# prove is the platform contract this adapter's whole primary wiring rests on:
#   - a `SessionStart` command hook declared in a settings file actually runs;
#   - the hook process receives `CLAUDE_PROJECT_DIR` pointing at the session's
#     working directory, which is why the tracked .codebuddy/settings.json can
#     address this home without a codebuddy-specific variable; and
#   - the hook's stdout reaches model context, which is what makes the shared
#     bin/fm-sessionstart-run.sh digest transport work here.
# The probe passes an explicit --settings file AND pins --setting-sources user, so
# it exercises the hook engine without loading this repo's tracked
# .codebuddy/settings.json: that would run the real session-start digest against
# the live home, which is far too invasive for a test.
#
# Deliberately NOT covered here and recorded instead in
# docs/verification/codebuddy-primary.md: project-scope `.codebuddy/settings.json`
# discovery, the Stop `asyncRewake` auto-arm, and the turn-end guard rewrite, all
# of which need an attended interactive session.
#
# Opt-in because the probe submits a model prompt and spends tokens:
#   FM_CODEBUDDY_PRIMARY_LIVE=1 bash tests/fm-codebuddy-primary-live-e2e.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEBUDDY_PRIMARY_LIVE codebuddy

TMP_ROOT=$(fm_test_tmproot fm-codebuddy-primary-live)
MARKER="$TMP_ROOT/sessionstart-ran"
PROBE="$TMP_ROOT/probe-settings.json"

cat > "$PROBE" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "printf '%s' \"\$CLAUDE_PROJECT_DIR\" > '$MARKER'; printf 'FM-CODEBUDDY-SESSIONSTART-PROBE'",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
JSON

out=$(cd "$ROOT" && codebuddy --print --setting-sources user --settings "$PROBE" \
  'Reply with exactly the single line of text the session-start hook printed to you, verbatim, and nothing else.' 2>&1) \
  || fail "codebuddy --print failed: $out"

[ -f "$MARKER" ] || fail "the SessionStart hook never ran under a real codebuddy session"
[ "$(cat "$MARKER")" = "$ROOT" ] \
  || fail "the hook did not receive CLAUDE_PROJECT_DIR pointing at the session cwd (got '$(cat "$MARKER")')"
assert_contains "$out" "FM-CODEBUDDY-SESSIONSTART-PROBE" \
  "the SessionStart hook's stdout did not reach model context"

pass "codebuddy: a SessionStart hook runs, sees CLAUDE_PROJECT_DIR, and its stdout reaches model context"
