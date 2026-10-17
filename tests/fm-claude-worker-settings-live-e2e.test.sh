#!/usr/bin/env bash
# Live guard for where a Claude worker's busy hooks live (live-harness-optin).
#
# bin/fm-spawn.sh passes them in Claude Code's per-session --settings file and
# writes nothing into the worker's tree. That those hooks load beside a
# project's own .claude/settings.local.json, and that Claude Code leaves that
# file alone, is vendor settings resolution, so a fake agent cannot prove it.
# For a project that commits the file and for one that ignores it, this guard
# runs the real fm-spawn against a fake pane, then one real Claude turn in the
# worker copy with the exact --settings value the launch carries. The turn
# runs in print mode, which loads the same settings layers without the
# interactive trust dialog a fresh lab folder would raise. Each project's own
# local file carries a hook of its own, which must fire beside firstmate's.
# It submits one short prompt per shape, so it is opt-in:
#   FM_CLAUDE_WORKER_SETTINGS_LIVE=1 tests/fm-claude-worker-settings-live-e2e.test.sh
# FM_CLAUDE_WORKER_SETTINGS_MODEL picks the model (default haiku).
# Refresh docs/verification/runtime-backends.md ("Claude worker settings
# placement") from this guard after a Claude Code upgrade.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_CLAUDE_WORKER_SETTINGS_LIVE claude jq

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

VERSION="claude $(claude --version 2>/dev/null | head -1)"
MODEL=${FM_CLAUDE_WORKER_SETTINGS_MODEL:-haiku}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-settings-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
CHECKED=0

cleanup() {
  # fm-spawn leaves each task's git hooks directory read-only.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2
  exit 1
}

check_shape() {  # <tracked|ignored>
  local shape=$1 case_dir home proj wt fakebin id local_file local_json project_hook settings state before after record gen
  case_dir="$LAB/$shape"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="claude-settings-$shape"
  project_hook="$case_dir/project-hook.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_init_commit "$proj"
  # The project's own local file: an allow-list plus a hook of its own.
  local_json=$(jq -n --arg cmd "echo project-hook >> '$project_hook'" \
    '{permissions: {allow: ["Bash(npm run test:*)"]}, hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}]}}')
  if [ "$shape" = tracked ]; then
    mkdir -p "$proj/.claude"
    printf '%s\n' "$local_json" > "$proj/.claude/settings.local.json"
    git -C "$proj" add -f .claude/settings.local.json
  else
    printf '%s\n' '.claude/settings.local.json' > "$proj/.gitignore"
    git -C "$proj" add .gitignore
  fi
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$shape claude settings"
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" worktree add --quiet -b "live-$shape" "$wt"
  local_file="$wt/.claude/settings.local.json"
  if [ "$shape" = ignored ]; then
    mkdir -p "$wt/.claude"
    printf '%s\n' "$local_json" > "$local_file"
  fi
  cp "$local_file" "$case_dir/local-settings.before"
  before=$(git -C "$wt" status --porcelain --ignored --untracked-files=all)
  fm_test_spawn_brief "$home" "$id"

  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --mode no-mistakes --yolo off > "$case_dir/spawn.log" 2>&1 \
    || fail "($shape) fm-spawn failed: $(cat "$case_dir/spawn.log")"
  settings=$(sed -n "s/.* --settings '\([^']*\)' .*/\1/p" "$case_dir/launch.log" | tail -1)
  state=$(cd "$home/state" && pwd -P)
  [ "$settings" = "$state/$id.claude-settings.json" ] \
    || fail "($shape) the launch does not pass this task's state settings file: '$settings'"
  gen=$(cat "$state/$id.busy-gen")

  # One real turn in the worker copy, with the launch's --settings value.
  (cd "$wt" && claude -p 'Reply with only the word OK.' --model "$MODEL" --settings "$settings") \
    > "$case_dir/claude.out" 2>&1 \
    || fail "($shape) the real claude turn failed: $(cat "$case_dir/claude.out")"

  # The spawn seeds seq=1 on this generation; the turn's UserPromptSubmit,
  # Stop, and SessionEnd each advance it, and a refused (stale or misrouted)
  # event cannot (bin/fm-busy-lib.sh owns the record format).
  record=$(cat "$state/$id.busy-state")
  case "$record" in
    "v1 gen=$gen seq=4 state=idle source=claude-hook event=session-end ts="*) ;;
    *) fail "($shape) prompt-submit, stop, and session-end did not all reach this task on gen $gen: $record" ;;
  esac
  [ "$(fm_busy_classify tmux fake:w claude "$id" "$state")" = "idle claude-hook" ] \
    || fail "($shape) the finished session does not classify idle claude-hook: $record"
  [ -f "$state/$id.turn-ended" ] || fail "($shape) Stop did not touch this task's turn-ended marker"
  [ -s "$project_hook" ] || fail "($shape) the project's own local hook did not fire beside firstmate's"
  cmp -s "$case_dir/local-settings.before" "$local_file" \
    || fail "($shape) .claude/settings.local.json changed: $(cat "$local_file")"
  after=$(git -C "$wt" status --porcelain --ignored --untracked-files=all)
  [ "$after" = "$before" ] || fail "($shape) the worker tree changed: before='$before' after='$after'"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "($shape) the worker tree is not clean: $(git -C "$wt" status --porcelain)"
  pass "$VERSION: ($shape .claude/settings.local.json) the --settings hooks reach this task beside the project's own, and the tree stays clean"
  CHECKED=$((CHECKED + 1))
}

check_shape tracked
check_shape ignored
[ "$CHECKED" -eq 2 ] || fail "checked $CHECKED of 2 project shapes"
printf '# claude worker settings live guard checked: tracked ignored\n'
