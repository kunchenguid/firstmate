#!/usr/bin/env bash
# Opt-in live guard for the claude trust-decline discriminator
# (bin/fm-claude-trust.sh) and the refused-spawn handoff (bin/fm-spawn.sh).
# Proves, against the real installed Claude Code on the real tmux and
# treehouse backends: a scout spawn succeeds on a project carrying the
# vendor default (hasClaudeMdExternalIncludesApproved===false with the
# warning never shown), the worker reaches its brief with no trust dialog,
# teardown returns the lease, and a second spawn against a genuine decline
# (warning shown, approval refused) still refuses and leaves no window,
# no task record, and no leased slot behind.
# The project entries live in the operator's real store, because an isolated
# store carries no Claude authentication and the worker would meet a login
# wall instead of the dialog under test; every entry this writes is removed
# again by the EXIT trap and verified absent. No live fleet home, worktree,
# or session is touched: the FM_HOME, project, and task ids are lab-private.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude tmux git treehouse node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_VERSION=$(claude --version 2>/dev/null || printf 'unknown')

fail() {
  printf 'not ok - claude (%s): %s\n' "$CLAUDE_VERSION" "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-trust-live-e2e.$$"
PROJECT="$LAB/claudetrustlive"
DECLINE_PROJECT="$LAB/claudetrustdecline"
HOME_DIR="$LAB/fmhome"
STORE="$HOME/.claude.json"
ID="claudetrustlive$$"
DECLINE_ID="claudetrustdecline$$"
MARKER="LIVE-GUARD-OK"
TRUST_DIALOG="Is this a project you created or one you trust"

# seed_store_entry <project> <approved-json> <warning-json>: set the two
# external-imports flags on one project entry, preserving everything else.
seed_store_entry() {
  # shellcheck disable=SC2016 # ${...} are JavaScript template literals, not shell.
  node -e '
    const fs = require("node:fs");
    const [store, key, approved, warning] = process.argv.slice(1);
    const root = JSON.parse(fs.readFileSync(store, "utf8"));
    root.projects = root.projects || {};
    root.projects[key] = root.projects[key] || {};
    root.projects[key].hasClaudeMdExternalIncludesApproved = JSON.parse(approved);
    root.projects[key].hasClaudeMdExternalIncludesWarningShown = JSON.parse(warning);
    fs.writeFileSync(store, `${JSON.stringify(root, null, 2)}\n`);
  ' "$STORE" "$1" "$2" "$3"
}

# drop_store_entries <project...>: remove whole project entries again.
drop_store_entries() {
  # shellcheck disable=SC2016 # ${...} are JavaScript template literals, not shell.
  node -e '
    const fs = require("node:fs");
    const [store, ...keys] = process.argv.slice(1);
    const root = JSON.parse(fs.readFileSync(store, "utf8"));
    if (root.projects) for (const key of keys) delete root.projects[key];
    fs.writeFileSync(store, `${JSON.stringify(root, null, 2)}\n`);
  ' "$STORE" "$@"
}

# store_has_trust <project>: exit 0 only when the entry carries trust.
store_has_trust() {
  node -e '
    const root = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    process.exit((root.projects || {})[process.argv[2]]?.hasTrustDialogAccepted === true ? 0 : 1);
  ' "$STORE" "$1"
}

# store_has_entry <project>: exit 0 while any entry remains for the project.
store_has_entry() {
  node -e '
    const root = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    process.exit((root.projects || {})[process.argv[2]] === undefined ? 1 : 0);
  ' "$STORE" "$1"
}

# leased_slot_for <repo-basename>: exit 0 while treehouse reports a leased
# slot whose path contains the lab repo name.
leased_slot_for() {
  treehouse status 2>/dev/null | grep -F "$1" | grep -Fq leased
}

cleanup() {
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-control.sh" "$ID" exit >/dev/null 2>&1 || true
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teardown.sh" "$ID" >/dev/null 2>&1 || true
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-control.sh" "$DECLINE_ID" exit >/dev/null 2>&1 || true
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teardown.sh" "$DECLINE_ID" >/dev/null 2>&1 || true
  # Backstop for a teardown that refused: the lab window names carry this
  # process id, so closing them here can hit nothing but this test's own
  # leftovers.
  tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null \
    | grep -F -e ":fm-$ID" -e ":fm-$DECLINE_ID" \
    | while IFS= read -r target; do
      tmux kill-window -t "$target" >/dev/null 2>&1 || true
    done
  # After the first live run this lab's FM_HOME and an empty
  # CLAUDE_CONFIG_DIR were found in the tmux server's global environment,
  # where an empty CLAUDE_CONFIG_DIR would wedge every later claude launch
  # on that server. The promoting mechanism is unproven, so this scrubs back
  # exactly this lab's values and nothing else.
  if [ "$(tmux show-environment -g FM_HOME 2>/dev/null || true)" = "FM_HOME=$HOME_DIR" ]; then
    tmux set-environment -g -u FM_HOME >/dev/null 2>&1 || true
  fi
  if [ "$(tmux show-environment -g CLAUDE_CONFIG_DIR 2>/dev/null || true)" = "CLAUDE_CONFIG_DIR=" ]; then
    tmux set-environment -g -u CLAUDE_CONFIG_DIR >/dev/null 2>&1 || true
  fi
  if [ -f "$STORE" ]; then
    # Backstop for entries the verified removal below did not reach: match
    # the lab directory marker (project paths) and the lab repo basenames
    # (treehouse pool paths, which never contain the lab directory).
    # shellcheck disable=SC2016 # ${...} are JavaScript template literals, not shell.
    node -e '
      const fs = require("node:fs");
      const store = process.argv[1];
      const root = JSON.parse(fs.readFileSync(store, "utf8"));
      if (root.projects) for (const key of Object.keys(root.projects)) {
        if (key.indexOf("claude-trust-live-e2e") !== -1
          || key.indexOf("claudetrustlive") !== -1
          || key.indexOf("claudetrustdecline") !== -1) delete root.projects[key];
      }
      fs.writeFileSync(store, `${JSON.stringify(root, null, 2)}\n`);
    ' "$STORE" >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB"
}
WT1=""
WT2=""
trap cleanup EXIT

mkdir -p "$LAB" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
[ -f "$STORE" ] || fail "no Claude store at $STORE, so neither direction can be proven"
fm_git_init_commit "$PROJECT"
fm_git_add_origin "$PROJECT" "$PROJECT.origin.git"
fm_git_init_commit "$DECLINE_PROJECT"
fm_git_add_origin "$DECLINE_PROJECT" "$DECLINE_PROJECT.origin.git"

# The vendor default this regression is about: disapproved, warning never
# shown. This is the input that fails against the pre-discriminator guard.
seed_store_entry "$PROJECT" false false \
  || fail "could not seed the default-flag entry"

mkdir -p "$HOME_DIR/data/$ID"
cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live-guard probe: reply with exactly $MARKER, write exactly $MARKER on its own line to $HOME_DIR/data/$ID/report.md, and then idle. Do not use any other tools. Do not write any other files.

## Firstmate spec
Exercise the spawn behavior under test.
EOF

# The worker must inherit its environment the way a production spawn leaves
# it: CLAUDE_CONFIG_DIR unset. A set-but-empty value is NOT the same -
# fm-claude-trust.sh reads it with a `:-` fallback to HOME, but Claude Code
# itself treats the empty value as a real (bogus) config dir and parks the
# worker on the machine-scoped Bypass Permissions consent screen instead of
# its brief. So the variable is removed rather than emptied here.
SPAWN_OUT=$(FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 env -u CLAUDE_CONFIG_DIR \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --harness claude --backend tmux 2>&1) \
  || fail "scout spawn on the default-flag project failed: $SPAWN_OUT"
WINDOW=$(printf '%s\n' "$SPAWN_OUT" | sed -n 's/.*window=\([^ ]*\).*/\1/p' | head -n 1)
WT1=$(printf '%s\n' "$SPAWN_OUT" | sed -n 's/.*worktree=\([^ ]*\).*/\1/p' | head -n 1)
[ -n "$WINDOW" ] || fail "spawn reported no window: $SPAWN_OUT"
[ -n "$WT1" ] || fail "spawn reported no worktree: $SPAWN_OUT"
store_has_trust "$WT1" || fail "spawn succeeded but the worktree entry carries no trust"
store_has_trust "$PROJECT" || fail "spawn succeeded but the project entry carries no trust"

i=0
while [ "$i" -lt 300 ]; do
  PANE=$(tmux capture-pane -p -t "$WINDOW" 2>/dev/null || true)
  case "$PANE" in
    *"$TRUST_DIALOG"*)
      fail "worker met the workspace trust dialog instead of its brief"
      ;;
    *"$MARKER"*)
      break
      ;;
  esac
  sleep 1
  i=$((i + 1))
done
[ "$i" -lt 300 ] || fail "worker never replied $MARKER within 300s; pane tail: $(tmux capture-pane -p -t "$WINDOW" 2>/dev/null | tail -n 20)"

# The scout contract: the report is the work product, and teardown refuses
# without it. Wait for the worker to deliver, so the teardown below proves a
# complete scout lifecycle rather than a forced one.
i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HOME_DIR/data/$ID/report.md" ] && break
  sleep 1
  i=$((i + 1))
done
[ -f "$HOME_DIR/data/$ID/report.md" ] \
  || fail "worker replied but never delivered its report within 120s"
grep -Fq "$MARKER" "$HOME_DIR/data/$ID/report.md" \
  || fail "the delivered report does not carry $MARKER"
# The scout completion gate: the report carries no captain call, so complete
# the origin's inventory as explicitly none before teardown.
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none >/dev/null 2>&1 \
  || fail "could not complete the scout's captain-call inventory"

# The worker reached its brief, so stop it, then clear the runtime dirs Claude
# Code itself drops into the worktree (caches, sessions, local settings):
# they are lab junk by construction - the brief forbade writing files - and
# teardown must see the clean tree it protects rather than be forced around
# it. No --force anywhere: a genuinely dirty tree must still refuse below.
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-control.sh" "$ID" exit >/dev/null 2>&1 || true
sleep 5
rm -rf "$WT1/.claude" "$WT1/cache" "$WT1/sessions" "$WT1/backups" "$WT1/.claude.json" 2>/dev/null || true
WT_STATUS=$(git -C "$WT1" status --short 2>&1) || fail "live worktree unreadable before teardown: $WT_STATUS"
[ -z "$WT_STATUS" ] || fail "live worktree is dirty before teardown: $WT_STATUS"
TEARDOWN_OUT=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teardown.sh" "$ID" 2>&1) \
  || fail "teardown of the live scout failed: $TEARDOWN_OUT"
# A returned slot stays on disk as an available pool slot; leaked means still
# leased. The checkout path persisting is treehouse's normal pool management,
# not a leak, so the assertion below reads the lease state, not the directory.
if leased_slot_for claudetrustlive; then
  fail "teardown left a leased slot behind for the live project"
fi

# The genuine decline: warning shown, approval refused. This must refuse
# exactly as before, and the refusal must hand back its endpoint and slot.
seed_store_entry "$DECLINE_PROJECT" false true \
  || fail "could not seed the genuine-decline entry"
mkdir -p "$HOME_DIR/data/$DECLINE_ID"
cat > "$HOME_DIR/data/$DECLINE_ID/brief.md" <<EOF
# Task
## Captain's intent
Live-guard probe: this spawn must never launch.

## Firstmate spec
Exercise the spawn behavior under test.
EOF

if DECLINE_OUT=$(FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 env -u CLAUDE_CONFIG_DIR \
  "$ROOT/bin/fm-spawn.sh" "$DECLINE_ID" "$DECLINE_PROJECT" --scout --harness claude --backend tmux 2>&1); then
  fail "scout spawn on the genuine decline succeeded, spending a refused consent: $DECLINE_OUT"
fi
case "$DECLINE_OUT" in
  *"declined external CLAUDE.md imports"*) ;;
  *) fail "the refusal did not name the declined-consent reason: $DECLINE_OUT" ;;
esac
[ ! -e "$HOME_DIR/state/$DECLINE_ID.meta" ] && [ ! -L "$HOME_DIR/state/$DECLINE_ID.meta" ] \
  || fail "the refused spawn published a task record no worker backs"
if tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -Fqx "fm-$DECLINE_ID"; then
  fail "the refused spawn left its endpoint window behind"
fi
if leased_slot_for claudetrustdecline; then
  fail "the refused spawn left a leased slot behind for the decline project"
fi

drop_store_entries "$PROJECT" "$DECLINE_PROJECT" "$WT1" "$WT2" \
  || fail "could not remove the lab entries from the store"
for key in "$PROJECT" "$DECLINE_PROJECT" "$WT1"; do
  if store_has_entry "$key"; then
    fail "lab entry for $key survived cleanup in $STORE"
  fi
done

printf 'ok - claude (%s): default-flag scout spawns end to end, genuine decline still refuses with no window, record, slot, or store entry left\n' "$CLAUDE_VERSION"
