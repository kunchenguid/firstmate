#!/usr/bin/env bash
# Behavior test for the worktree-scoped rm -rf allow entry fm-spawn.sh writes
# into a claude crewmate's .claude/settings.local.json (task crew-rmrf-fix-q3).
#
# Regression coverage: routine worktree-scoped cleanup (deleting node_modules,
# .terraform, a scratch trace dir) must not park an unattended crewmate at an
# interactive rm -rf confirmation dialog it cannot answer itself - an incident
# that cost committed-but-not-yet-landed work when the parked worktree was
# later reclaimed. The real end-to-end verification that Claude Code actually
# honors this generated allow entry (and still prompts outside the worktree)
# lives in the harness-adapters skill's "Permission precedence" fact; this test
# only pins fm-spawn.sh's own generated-file contract, using a fake tmux and a
# real git worktree so it runs without a live interactive session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-rmrf-allow)
export FM_BACKEND=tmux

# Fake tmux that satisfies fm-spawn.sh's ship-crewmate window/worktree
# sequence: container_ensure ('#S'), the duplicate-check + new-window, the
# 'treehouse get' send, and the pane_current_path poll fm-spawn.sh uses to
# discover the worktree treehouse handed back - here, a REAL git worktree
# created ahead of time (fm_git_worktree), so validate_spawn_worktree's real
# git checks pass.
make_fake_tmux() {  # <dir> <worktree-path>
  local dir=$1 wt=$2 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_current_path*) printf '%s\n' "$wt"; exit 0 ;;
      esac
    done
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # fm-spawn.sh's ship path never invokes the treehouse binary directly (it
  # types "treehouse get" into the fake pane above), but stub it so any
  # incidental PATH lookup does not fail.
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

test_claude_ship_spawn_writes_worktree_scoped_rmrf_allow() {
  local home proj wt wt_real fakebin out settings allow_pattern
  home="$TMP_ROOT/home"
  proj="$TMP_ROOT/proj"
  wt="$TMP_ROOT/proj-wt"
  mkdir -p "$home/data" "$home/state"
  fm_git_worktree "$proj" "$wt" "fm/rmrf-allow-t1"
  wt_real=$(cd "$wt" && pwd -P)

  mkdir -p "$home/data/rmrf-allow-t1"
  printf 'test brief\n' > "$home/data/rmrf-allow-t1/brief.md"

  fakebin=$(make_fake_tmux "$TMP_ROOT/fake" "$wt")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" rmrf-allow-t1 "$proj" --harness claude 2>&1)
  expect_code 0 "$?" "fm-spawn.sh should exit 0 for a fake-backed ship spawn: $out"

  settings="$wt/.claude/settings.local.json"
  assert_present "$settings" "fm-spawn.sh did not write $settings"

  jq empty "$settings" 2>/dev/null || fail "$settings is not valid JSON"

  allow_pattern="Bash(rm -rf $wt_real/*)"
  assert_grep "$allow_pattern" "$settings" \
    "settings.local.json missing worktree-scoped rm -rf allow entry for $wt_real"

  assert_grep '"Stop"' "$settings" \
    "settings.local.json lost the pre-existing turn-end Stop hook"

  pass "fm-spawn.sh: claude ship spawn writes a worktree-scoped rm -rf allow entry alongside the turn-end hook"
}

test_claude_ship_spawn_writes_worktree_scoped_rmrf_allow
