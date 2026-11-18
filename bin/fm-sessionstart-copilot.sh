#!/usr/bin/env bash
# GitHub Copilot CLI session-open adapter: the RUN tier transport for Copilot.
#
# Registered in tracked .github/hooks/firstmate-primary.json for Copilot's
# `sessionStart` hook. It is a thin transport around bin/fm-sessionstart-run.sh,
# which remains the single owner of source routing, eligibility, and the digest
# itself.
#
# Copilot puts a sessionStart hook's `{"additionalContext":"..."}` stdout in
# front of the model before its first reply (docs/verification/copilot.md). The
# hook fires at the first prompt, not at launch, and its payload carries the
# `source` (`new`, `resume`) that the run wrapper routes, so this adapter reads
# it from stdin; `--source` overrides it for a registration that knows better.
#
# A `resume` (`copilot --resume <id>` or `--continue`) is a new process that
# restored an old conversation, so the lock is not ours and no wake process runs.
# The run wrapper's nudge for `resume` is only an instruction, which a resumed
# model followed past in favor of the restored conversation (docs/verification/
# copilot.md "Resume"), so this adapter takes the helm with the full digest, as
# Cursor does for a resumed session. A repeat is redundant and idempotent.
#
# Copilot's `view` refuses the ~50 KB AGENTS.md in one call, and a model that
# re-reads it after a self-update tends to stop at the first range, so this
# adapter alone appends a chunked-read line to the digest it forwards; every
# other harness's digest is untouched (harness-adapters copilot reference).
#
# In a linked crewmate worktree or a foreign checkout fm-sessionstart-run.sh
# stands down silently and this adapter prints nothing.
#
# Every path exits 0 and prints either nothing or one JSON object, so a failed
# session start reaches the agent as digest text and never blocks the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SOURCE" ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  SOURCE=$(cat 2>/dev/null | jq -r '(.source // empty) | strings' 2>/dev/null || true)
fi

[ "$SOURCE" != resume ] || SOURCE=startup
DIGEST=$(FM_COPILOT_HARNESS=copilot "$SCRIPT_DIR/fm-sessionstart-run.sh" --source "${SOURCE:-startup}" </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
DIGEST="$DIGEST
Copilot note: if you re-read AGENTS.md (for example after a self-update), its \`view\` refuses the whole file; read it in successive view_range calls until the last line (\`wc -l\` gives the length) and do not stop after the first range."
# Only fm-spawn checked the Copilot version, so a hand-opened primary that
# auto-updated outside the verified range got no warning (same bound as there).
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
if COPILOT_BIN=$(command -v copilot 2>/dev/null); then
  copilot_version=$(fm_run_timed 5 "$COPILOT_BIN" --version 2>/dev/null </dev/null | head -n 1 || true)
  fm_copilot_version_verified "$copilot_version" \
    || DIGEST="$DIGEST
$(fm_copilot_version_warning "$copilot_version")"
fi
jq -cn --arg c "$DIGEST" '{additionalContext:$c}' 2>/dev/null || true
exit 0
