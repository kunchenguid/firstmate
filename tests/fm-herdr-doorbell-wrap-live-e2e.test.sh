#!/usr/bin/env bash
# Live Herdr wrapped-doorbell guard (live-harness-optin family).
#
# A named Claude Code session draws its title into the composer's top rule, so
# the composer read depends on the bare-rule sandwich. The steering doorbell
# is longer than a lead-sized composer is wide, so it wraps onto a second row,
# and the payload proof used to refuse it on every ring (lower-unmatched-rule,
# then post-content-extraction) while the reason was discarded. This guard
# launches real `claude --name` in an isolated Herdr lab behind an owned
# 120-column viewer, rings a record through the real fm_task_inbox_ring, and
# requires the doorbell to wrap, the ring to report it rang, and the line to
# leave the composer.
#
# Claude runs under a throwaway HOME with a fixture API key aimed at a closed
# local port, so the guard spends no model tokens and never reads or writes
# the operator's Claude configuration or credentials.
# Every Herdr call is routed through bin/fm-herdr-lab.sh; HERDR_LAB_HELPER and
# HERDR_LAB_SESSION select the helper and an already-named lab session.
# FM_DOORBELL_WRAP_CODE_ROOT sources the libraries from another tree (for
# example a pre-fix export) as a negative control.
#
# Run explicitly with FM_HERDR_DOORBELL_WRAP_LIVE=1.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CODE_ROOT=${FM_DOORBELL_WRAP_CODE_ROOT:-$ROOT}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_DOORBELL_WRAP_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=${HERDR_LAB_SESSION:-$("$LAB_HELPER" name doorbell-wrap)}
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-doorbell-wrap.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer stop "$SESSION" >/dev/null 2>&1 || true
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# The backend reaches Herdr through bare `herdr ... --session <s>`; this
# wrapper refuses any other session and routes the call through the helper.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
"$LAB_HELPER" viewer start "$SESSION" || fail "could not attach the owned 120-column lab viewer"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$CODE_ROOT/bin/backends/herdr.sh"
# shellcheck source=/dev/null
. "$CODE_ROOT/bin/fm-task-inbox-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

# Throwaway Claude home: onboarding done, the work directory trusted, and the
# fixture key pre-approved, so the composer is the first thing it renders.
CLAUDE_HOME="$TMP_ROOT/home"
WORK="$TMP_ROOT/work"
mkdir -p "$CLAUDE_HOME" "$WORK"
WORK=$(cd "$WORK" && pwd -P)
API_KEY="sk-ant-api03-fm-doorbell-wrap-lab-fixture-0000000000000000"
jq -n --arg work "$WORK" --arg key "${API_KEY: -20}" '{
  hasCompletedOnboarding: true,
  theme: "dark",
  customApiKeyResponses: { approved: [$key], rejected: [] },
  projects: { ($work): { hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true } }
}' > "$CLAUDE_HOME/.claude.json"

WS_JSON=$(lab workspace create --cwd "$WORK" --label fm-doorbellwrap --no-focus) \
  || fail "could not create the isolated doorbell workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "env HOME='$CLAUDE_HOME' XDG_CONFIG_HOME='$CLAUDE_HOME/.config' ANTHROPIC_API_KEY='$API_KEY' ANTHROPIC_BASE_URL=http://127.0.0.1:9 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false DISABLE_AUTOUPDATER=1 claude --name fm-doorbell-lab --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the lab pane"

ready=0
for ((i = 0; i < 60; i++)); do
  if [ "$(fm_backend_herdr_composer_state "$TARGET" 2>/dev/null)" = empty ]; then ready=1; break; fi
  sleep 1
done
screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
[ "$ready" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER: the titled composer never read empty; viewport:"$'\n'"$screen"
printf '%s\n' "$screen" | grep -q 'fm-doorbell-lab' \
  || fail "Claude Code ($VERSION): the composer top rule does not carry the session title; viewport:"$'\n'"$screen"

INBOX="$TMP_ROOT/state/fm-retro-doorbell-wrap.inbox"
mkdir -p "$INBOX/handled"
REC="$INBOX/001.msg"
printf 'lab instruction\n' > "$REC"
line=$(fm_task_inbox_doorbell_line "$REC") || fail "could not render the doorbell line"
width=$(printf '%s\n' "$screen" | awk '{ if (length($0) > w) w = length($0) } END { print w }')
[ "${#line}" -gt "$width" ] || fail "the ${#line}-character doorbell fits the ${width}-column viewport, so it cannot prove a wrap"

FM_TASK_INBOX_RING_REASON=
rc=0
fm_task_inbox_ring herdr "$TARGET" "$REC" || rc=$?
screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
[ "$rc" -eq 0 ] || fail "Claude Code ($VERSION) on $HERDR_VER: the wrapped doorbell ring returned $rc (reason: ${FM_TASK_INBOX_RING_REASON:-none reported}); viewport:"$'\n'"$screen"
printf '%s\n' "$screen" | grep -q 'Firstmate instruction waiting' \
  || fail "the rang doorbell is not on screen; viewport:"$'\n'"$screen"
left=unknown
for ((i = 0; i < 20; i++)); do
  left=$(fm_backend_herdr_composer_state "$TARGET" 2>/dev/null)
  [ "$left" = empty ] && break
  sleep 0.5
done
[ "$left" = empty ] || fail "the doorbell did not leave the composer (state $left); viewport:"$'\n'"$screen"
pass "Claude Code ($VERSION) on $HERDR_VER: a ${#line}-character doorbell wrapped in a ${width}-column titled composer, rang, and was submitted"
