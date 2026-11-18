#!/usr/bin/env bash
# tests/fm-context-ceiling-live.test.sh - live guard: the context ceiling a real
# spawn emits is honored by the real installed Claude Code.
#
# Token-free and default-on (fm_live_gate): Claude Code's `/context` command is
# answered locally in print mode and reports the session's window, which the
# autoCompactWindow setting replaces. The guard takes the --settings value from
# the launch a real bin/fm-spawn.sh emitted into a fake pane, for a worker and
# for a secondmate, runs the installed claude with exactly that value, and fails
# naming the Claude Code version when the reported window is not the ceiling.
# A control run without the value must report a different window, so a host
# whose own setting already equals the ceiling cannot pass vacuously.
#
# Codex's ceiling needs a real compaction and spends tokens, so it is the
# separate opt-in guard tests/fm-context-ceiling-codex-live.test.sh.
# Refresh the dated record in docs/verification/runtime-backends.md from both.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_LIVE_CONTEXT_CEILING claude jq

TMP_ROOT=$(fm_test_tmproot fm-context-ceiling-live)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)

# Spawn one worker or secondmate through the real spawn into a fake pane and
# print the --settings value the launched claude received.
emitted_settings() {  # <name> <kind> <ceiling-line>
  local name=$1 kind=$2 line=$3 dir home proj wt fakebin launchlog panelog id out sm
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  launchlog="$dir/launch.log"
  panelog="$dir/pane.log"
  id="live-$name-a1"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" claude
  printf '%s\n' "$line" >"$home/config/context-ceiling"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : >"$launchlog"
  : >"$panelog"
  if [ "$kind" = secondmate ]; then
    sm="$dir/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' >"$sm/AGENTS.md"
    printf '%s\n' "$id" >"$sm/.fm-secondmate-home"
    printf 'charter for %s\n' "$id" >"$sm/data/charter.md"
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' >"$sm/.gitignore"
    git -C "$sm" init -q -b main
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$sm" --secondmate 2>&1) || fail "secondmate spawn failed: $out"
  else
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode local-only --yolo off 2>&1) || fail "worker spawn failed: $out"
  fi
  cat >"$fakebin/claude" <<'SH'
#!/bin/sh
for a do printf '%s\n' "$a"; done
SH
  chmod +x "$fakebin/claude"
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(grep '^export ' "$panelog")
$(cat "$launchlog")" | awk 'prev == "--settings" { print; exit } { prev = $0 }'
}

# The window the installed claude reports for a session with <settings>, or
# its own default with no argument, from a scratch directory.
reported_window() {  # [settings]
  local scratch out
  scratch=$(mktemp -d "$TMP_ROOT/ctx.XXXXXX")
  if [ "$#" -gt 0 ]; then
    out=$(cd "$scratch" && claude -p /context --settings "$1" --output-format text 2>&1)
  else
    out=$(cd "$scratch" && claude -p /context --output-format text 2>&1)
  fi
  printf '%s\n' "$out" | sed -n 's/^\*\*Tokens:\*\* [^/]*\/ *\([0-9.]*[kKmM]*\).*/\1/p' | head -1
}

test_worker_window_is_the_ceiling() {
  local settings window control
  settings=$(emitted_settings worker ship 'worker=250000')
  assert_contains "$settings" '"autoCompactWindow":250000' "the spawn must emit the ceiling for the live run"
  window=$(reported_window "$settings")
  control=$(reported_window)
  [ -n "$window" ] || fail "claude $CLAUDE_VERSION: /context printed no window line; the live signal moved"
  assert_equals 250k "$window" "claude $CLAUDE_VERSION: a worker launched with the emitted settings must report a 250k window"
  [ "$control" != "$window" ] || fail "claude $CLAUDE_VERSION: the control run also reports $control, so this host cannot show the setting took effect; change the host's own autoCompactWindow and rerun"
  pass "claude $CLAUDE_VERSION: a worker launched with the spawn's settings reports the 250k ceiling (default here: $control)"
}

test_secondmate_window_is_the_ceiling() {
  local settings file window
  settings=$(emitted_settings secondmate secondmate 'secondmate=300000')
  file=$(eval "printf '%s' $settings")
  [ -f "$file" ] || fail "the secondmate launch must name its settings file, got: $settings"
  window=$(reported_window "$file")
  assert_equals 300k "$window" "claude $CLAUDE_VERSION: a secondmate launched with its settings file must report a 300k window"
  pass "claude $CLAUDE_VERSION: a secondmate launched with its settings file reports the 300k ceiling"
}

report_uncovered() {
  local tool
  for tool in pi pi-signed opencode gemini agy grok kimi cursor-agent omp; do
    command -v "$tool" >/dev/null 2>&1 || continue
    printf '# %s is installed and not covered: it has no verified per-launch ceiling (bin/fm-context-ceiling-lib.sh)\n' "$tool"
  done
}

test_worker_window_is_the_ceiling
test_secondmate_window_is_the_ceiling
report_uncovered
