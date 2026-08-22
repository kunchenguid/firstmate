#!/usr/bin/env bash
# Opt-in live guard for the captain reply-shape reminder's delivery.
#
# Two facts here come from the vendor rather than from Firstmate, so a stub can
# only confirm the assumption already written into the stub:
#
#   (a) the tracked prompt-submission registration fires on a real captain turn
#       AND its stdout genuinely lands in model context, rather than merely
#       being produced,
#   (b) a broken hook cannot erase the captain's prompt. Claude blocks the turn
#       on hook exit 2, and bash exits 2 on a syntax error, so this is the one
#       failure mode that could wedge a session instead of just losing a
#       reminder.
#
# tests/fm-plainenglish-hook.test.sh pins the reminder's own logic portably with
# no harness, including the registration's exit contract. This guard covers only
# what CI cannot see, and it runs the REAL bin/fm-plainenglish-hook.sh through
# the REAL .claude/settings.json entry inside a throwaway lab, so nothing here
# touches a real home, lock, or fleet.
#
# Run it after every Claude upgrade and before trusting the refreshed evidence
# in docs/verification/supervision.md:
#
#   FM_PLAINENGLISH_LIVE_E2E=1 tests/fm-plainenglish-live-e2e.test.sh
#
# It costs three real model turns.
set -u

if [ "${FM_PLAINENGLISH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PLAINENGLISH_LIVE_E2E=1 to run the live reply-shape reminder guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v claude >/dev/null 2>&1 || fail "claude is not installed, so this guard would verify nothing"
VERSION=$(claude --version 2>/dev/null | head -n 1)

# Outside the repo on purpose: the lab is its own git repo, and nesting one
# inside the checkout would show up as an embedded repository in a working tree
# a maintainer may be committing from while this guard runs.
LAB="${TMPDIR:-/tmp}/fm-plainenglish-live-e2e.$$"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT INT TERM

mkdir -p "$LAB/bin" "$LAB/state" "$LAB/.claude"
git init -q -b main "$LAB"
git -C "$LAB" config user.email fmtest@example.invalid
git -C "$LAB" config user.name fmtest
printf '# Firstmate lab\n' > "$LAB/AGENTS.md"
git -C "$LAB" add -A >/dev/null 2>&1 || true
git -C "$LAB" commit -q -m init >/dev/null 2>&1 || true

# The real hook and the real registration. Every other script the tracked
# settings reference is a no-op stub: only prompt submission is under test, and
# a missing turn-end guard would otherwise spray unrelated errors into the run.
cp "$ROOT/bin/fm-plainenglish-hook.sh" "$ROOT/bin/fm-gate-refuse-lib.sh" \
  "$ROOT/bin/fm-primary-scope-lib.sh" "$LAB/bin/"
chmod +x "$LAB/bin/fm-plainenglish-hook.sh"
for stub in fm-turnend-guard.sh fm-claude-stop-autoarm.sh fm-sessionstart-run.sh \
  fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/$stub"
  chmod +x "$LAB/bin/$stub"
done
cp "$ROOT/.claude/settings.json" "$LAB/.claude/settings.json"

# The question never contains the words being looked for, so a matching answer
# can only come from text the harness put in context. The lab is fresh and every
# turn is its own headless process, so no earlier session can supply them either.
ASK='Is there a line of reply-style guidance in your context that arrived with this message? If yes, reply with that line copied exactly and nothing else. If there is no such line, reply with exactly NONE.'

ask_claude() {  # <prompt>
  ( cd "$LAB" && FM_ROOT_OVERRIDE="$LAB" FM_HOME="$LAB" CLAUDE_PROJECT_DIR="$LAB" \
    claude -p --permission-mode bypassPermissions "$1" < /dev/null 2>&1 )
}

# --- (a) the reminder reaches a real turn ------------------------------------

OUT=$(ask_claude "$ASK")
printf '%s' "$OUT" | grep -Fq '[plain-english]' \
  || { note "model reply: $OUT"; fail "claude $VERSION: the reminder did not reach model context on a real turn"; }
printf '%s' "$OUT" | grep -Fq 'two sentences' \
  || { note "model reply: $OUT"; fail "claude $VERSION: the reminder reached context truncated or altered"; }
pass "claude $VERSION: the tracked registration delivers the reminder into a real turn's context"
note "delivered line: $(printf '%s' "$OUT" | tr -d '\r' | head -n 2 | tail -n 1)"

# --- the off switch, end to end ----------------------------------------------

mkdir -p "$LAB/config"
printf 'off\n' > "$LAB/config/plainenglish"
OUT=$(ask_claude "$ASK")
printf '%s' "$OUT" | grep -Fq '[plain-english]' \
  && { note "model reply: $OUT"; fail "claude $VERSION: config/plainenglish=off still delivered the reminder"; }
# The turn must have completed and reported an empty context, or a failed run
# would pass this case by producing no reminder for the wrong reason.
printf '%s' "$OUT" | grep -Fq 'NONE' \
  || { note "model reply: $OUT"; fail "claude $VERSION: the switched-off turn did not report an absent reminder, so it proves nothing"; }
pass "claude $VERSION: config/plainenglish=off leaves the turn with no reminder in context"
rm -rf "$LAB/config"

# --- (b) a broken hook cannot erase the captain's prompt ----------------------

printf '#!/usr/bin/env bash\nif [ then fi done )\n' > "$LAB/bin/fm-plainenglish-hook.sh"
chmod +x "$LAB/bin/fm-plainenglish-hook.sh"
OUT=$(ask_claude 'Reply with exactly LIVEOK and nothing else.')
printf '%s' "$OUT" | grep -Fq 'LIVEOK' \
  || { note "model reply: $OUT"; fail "claude $VERSION: a syntax-broken reminder hook blocked the turn"; }
pass "claude $VERSION: a syntax-broken reminder hook leaves the turn running"
