#!/usr/bin/env bash
# Opt-in live guard for config/worker-launch-command (bin/fm-spawn.sh header,
# docs/configuration.md "Worker launch command"), in the live-harness-optin
# family. Whether a harness runs a command that opens its launch prompt, and
# still reads the brief that follows it, is vendor behavior a stub cannot
# prove, so this drives the REAL installed harness.
#
# For each of claude, codex, grok, pi, and pi-signed that is installed, the real
# bin/fm-spawn.sh renders a ship launch against a fake endpoint, with a
# model-invocation-disabled probe skill in the task worktree named by the home's
# config/worker-launch-command. The captured launch then runs, unchanged, in an
# isolated tmux server. The probe skill touches one marker; the brief touches a
# second marker only when the first already exists. Both markers prove the
# command ran first and the brief still followed it as its arguments.
#
# The lab home, project, and worktree are temporary. Each harness keeps its
# existing authentication and records trust for the one temporary worktree.
# A few low-effort turns are submitted per installed harness, so run it only
# with FM_WORKER_LAUNCH_COMMAND_LIVE=1. Refresh docs/verification/runtime-backends.md
# ("Worker launch command") from its output after any of these harnesses upgrade.
# shellcheck disable=SC2016 # the harness, not this test shell, reads $fmlc-probe
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_WORKER_LAUNCH_COMMAND_LIVE tmux

SOCKET="fm-launch-command-$$"
TMP_ROOT=$(fm_test_tmproot fm-worker-launch-command-live)
CHECKED=0

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

write_probe_skill() {  # <worktree>
  local dir
  for dir in .claude .agents .codex .grok .pi; do
    mkdir -p "$1/$dir/skills/fmlc-probe"
    cat > "$1/$dir/skills/fmlc-probe/SKILL.md" <<'MD'
---
name: fmlc-probe
description: Firstmate worker launch command probe. Only for explicit invocation.
disable-model-invocation: true
---

# fmlc-probe

Before doing anything else, run the shell command `touch fmlc-skill-ran` in the current directory.
Then continue with the text that followed the command, treating it as the request.
MD
  done
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$1" 2>/dev/null || true
}

# Each harness asks once whether to trust the fresh worktree. Claude opens with
# its cursor on "No, exit", so it moves to the trusting option before Enter.
answer_trust() {  # <harness> <session> <screen text>
  case "$1:$3" in
    claude:*'Yes, I trust this folder'*)
      if printf '%s\n' "$3" | grep -F '❯' | head -1 | grep -qF 'Yes, I trust this folder'; then
        tmux -L "$SOCKET" send-keys -t "$2" Enter
      else
        tmux -L "$SOCKET" send-keys -t "$2" Down
      fi
      ;;
    codex:*'Trust and continue'* | codex:*'trust the contents of this directory'* | \
      pi:*'Trust project folder'* | pi-signed:*'Trust project folder'*)
      tmux -L "$SOCKET" send-keys -t "$2" Enter
      ;;
    grok:*'Yes, proceed'*)
      tmux -L "$SOCKET" send-keys -t "$2" y
      ;;
  esac
}

check_harness() {  # <harness> <command>
  local harness=$1 command=$2 version id case_dir home proj wt fakebin launchlog out session shot i=0
  version=$("$harness" --version 2>/dev/null | head -1)
  [ -n "$version" ] || fail "$harness is installed but reports no version"
  id="fmlc-$harness"
  case_dir="$TMP_ROOT/$harness"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$harness"
  fm_test_spawn_brief "$home" "$id" \
    'Run exactly `test -e fmlc-skill-ran && touch fmlc-brief-ran` in the task worktree, then stop without doing anything else.'
  printf '%s %s\n' "$harness" "$command" > "$home/config/worker-launch-command"

  if ! out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --mode local-only --yolo off --effort low); then
    fail "$harness $version: fm-spawn refused the launch: $out"
  fi
  [ -s "$launchlog" ] || fail "$harness $version: fm-spawn typed no launch command"
  printf 'cd -- %q || exit 1\n%s\n' "$wt" "$(cat "$launchlog")" > "$case_dir/launch.sh"
  # The spawn resets the worktree to its base, so the probe arrives afterwards.
  write_probe_skill "$wt"

  session="fmlc-$harness"
  tmux -L "$SOCKET" new-session -d -s "$session" -x 180 -y 50 -c "$wt" \
    "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CONFIG_DIR bash '$case_dir/launch.sh'; printf '\nFMLC_EXIT=%s\n' \"\$?\"; sleep 60"
  while [ "$i" -lt 1200 ]; do
    [ -e "$wt/fmlc-brief-ran" ] && break
    shot=$(screen "$session")
    case "$shot" in
      *FMLC_EXIT=*)
        printf '%s\n' "$shot" >&2
        fail "$harness $version exited before running the launch command and brief"
        ;;
    esac
    answer_trust "$harness" "$session" "$shot"
    sleep 0.25
    i=$((i + 1))
  done
  tmux -L "$SOCKET" kill-session -t "$session" >/dev/null 2>&1 || true
  if [ ! -e "$wt/fmlc-skill-ran" ]; then
    printf '%s\n' "$shot" >&2
    fail "$harness $version never ran the leading $command"
  fi
  if [ ! -e "$wt/fmlc-brief-ran" ]; then
    printf '%s\n' "$shot" >&2
    fail "$harness $version ran $command but never followed the brief after it"
  fi
  CHECKED=$((CHECKED + 1))
  pass "$harness $version runs the leading $command and then follows the brief"
}

for entry in 'claude /fmlc-probe' 'codex $fmlc-probe' 'grok /fmlc-probe' 'pi /skill:fmlc-probe' 'pi-signed /skill:fmlc-probe'; do
  harness=${entry%% *}
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf '# %s is not installed; not checked\n' "$harness"
    continue
  fi
  check_harness "$harness" "${entry#* }"
done
[ "$CHECKED" -gt 0 ] || fail "no supported harness is installed, so nothing was checked"
