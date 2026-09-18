#!/usr/bin/env bash
# tests/fm-executor-headless-flags-live-e2e.test.sh - default-on drift guard
# proving every INSTALLED headless executor adapter still advertises the flags
# bin/fm-spawn.sh's executor launch templates pass it (docs/verification/executor.md).
#
# Why this file exists: `claude -p`, `codex exec`, and `opencode run` are
# vendor-emitted surfaces. A release that renames or drops one of those flags
# would make every executor launch die at argument parsing, which the executor
# poll would then report as "no commits and no PR" - a launch-environment
# failure disguised as a failed attempt. What this guard pins is exactly that
# and nothing else: for each INSTALLED adapter, the flag tokens its headless
# launch template passes must still appear as whole tokens in that adapter's own
# --help. It never asserts the vendor's wording, never submits a prompt, and so
# consumes no model tokens. An absent adapter is reported explicitly, a pass
# that checked nothing is refused, and a failure names the harness and its
# version.
#
# The portable counterpart, tests/fm-spawn-executor.test.sh, pins the templates
# themselves against a fake pane; this guard pins the adapter's flag surface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_EXECUTOR_HEADLESS_FLAGS_LIVE

REQUESTED=0
case "${FM_EXECUTOR_HEADLESS_FLAGS_LIVE:-}${FM_LIVE:-}" in *1*) REQUESTED=1 ;; esac

checked=0
absent=

# require_flags <harness> <version> <help-text> <flag>...
# Every flag must appear as a whole token in the help text.
require_flags() {
  local harness=$1 version=$2 help=$3 flag
  shift 3
  for flag in "$@"; do
    printf '%s\n' "$help" | grep -Eq -- "(^|[[:space:],])${flag//\[/\\[}([[:space:]=,<]|$)" \
      || fail "$harness $version no longer advertises '$flag', which bin/fm-spawn.sh's executor template passes it"
  done
}

if command -v claude >/dev/null 2>&1; then
  version=$(claude --version 2>/dev/null | head -1 || true)
  help=$(claude --help 2>&1 || true)
  require_flags claude "$version" "$help" --print --output-format --dangerously-skip-permissions --permission-mode --model --effort --settings
  printf '%s\n' "$help" | grep -Eq -- '-p, --print' \
    || fail "claude $version no longer advertises -p as the short form of --print"
  pass "claude $version advertises every flag of the executor template (claude -p)"
  checked=$((checked + 1))
else
  absent="$absent claude"
fi

if command -v codex >/dev/null 2>&1; then
  version=$(codex --version 2>/dev/null | head -1 || true)
  help=$(codex exec --help 2>&1 || true)
  require_flags codex "$version" "$help" --model --config --disable --dangerously-bypass-approvals-and-sandbox
  pass "codex $version advertises every flag of the executor template (codex exec)"
  checked=$((checked + 1))
else
  absent="$absent codex"
fi

if command -v opencode >/dev/null 2>&1; then
  version=$(opencode --version 2>/dev/null | head -1 || true)
  help=$(opencode run --help 2>&1 || true)
  require_flags opencode "$version" "$help" --model
  pass "opencode $version advertises every flag of the executor template (opencode run)"
  checked=$((checked + 1))
else
  absent="$absent opencode"
fi

[ -z "$absent" ] || printf '# absent, not checked:%s\n' "$absent"
if [ "$checked" -eq 0 ]; then
  if [ "$REQUESTED" -eq 1 ]; then
    fail "the executor headless-flag guard was requested but no headless adapter is installed"
  fi
  printf 'skip: live: no headless executor adapter installed (claude, codex, opencode all absent)\n'
  exit 0
fi
