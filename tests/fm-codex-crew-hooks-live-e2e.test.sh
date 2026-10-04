#!/usr/bin/env bash
# Live guard for the config/codex-crew-hooks opt-in (live-harness-optin family).
#
# The portable half (tests/fm-spawn-dispatch-profile.test.sh) pins that the
# opt-in drops `--disable hooks` from a crewmate or scout launch. Whether a
# trusted project hook then actually RUNS is a vendor-owned surface a stub can
# only assume, so this guard asks the installed codex: it captures the REAL
# launch command fm-spawn builds for a crewmate and for a scout, runs it under
# a real PTY in an isolated tmux server, in a linked worktree of a test checkout
# whose .codex/hooks.json registers one SessionStart hook that writes a sentinel
# file, and requires
#   - with config/codex-crew-hooks=on, the sentinel to appear, and
#   - with the file absent, the turn to end with no sentinel.
#
# Trust: codex persists hook trust keyed by the repository checkout's
# hooks.json path and the hook's content hash, and only an operator can grant
# it. This guard never writes codex's trust store and never passes
# --dangerously-bypass-hook-trust. The checkout therefore lives at one stable
# per-user path with fixed hooks content and is left in place between runs, so
# the operator can trust it once interactively.
#
# Ownership: that stable path is a dedicated directory the guard creates
# together with a marker file. The guard deletes nothing there, and a directory
# that already exists without the marker, or a marked one whose checkout is not
# the repository the guard made, fails the run by name instead of being touched.
# Deleting the whole directory by hand is always safe; the next run rebuilds it.
#
# Each launch submits a real prompt, so the gate is opt-in (fm_live_gate): the
# guard only ever runs forced on by FM_CODEX_CREW_HOOKS_LIVE=1 or FM_LIVE=1, and
# a forced run that cannot prove its claim fails. An absent tool fails, and so
# does codex parking the opted-in launch on its folder-trust or "Hooks need
# review" modal. The marker records the last run in which the hook ran trusted,
# so that failure says whether the checkout was never trusted or trust that
# once held has regressed. Refresh docs/verification/runtime-backends.md
# ("Codex hook trust") from this guard's output after any codex upgrade.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_CODEX_CREW_HOOKS_LIVE codex tmux git

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-crew-hooks-live)
GUARD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/codex-crew-hooks-live"
MARKER="$GUARD_DIR/.fm-codex-crew-hooks-live-guard"
MARKER_OWNER='owner: tests/fm-codex-crew-hooks-live-e2e.test.sh'
CHECKOUT="$GUARD_DIR/project"
OWNED=0
SENTINEL=.fm-codex-crew-hook-fired
SOCKET="fm-codex-crew-hooks-$$"
POLLS=${FM_CODEX_CREW_HOOKS_LIVE_POLLS:-180}
CHECKED=0

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
  [ "$OWNED" -eq 0 ] || git -C "$CHECKOUT" worktree prune 2>/dev/null || true
}
trap cleanup EXIT

# prepare_checkout: prove the guard directory is this guard's own, creating it
# with its marker and test checkout when the path is free, then commit the hooks
# file so every linked worktree carries the identical content trust is keyed by.
prepare_checkout() {
  if [ -e "$GUARD_DIR" ] || [ -L "$GUARD_DIR" ]; then
    if [ -L "$GUARD_DIR" ] || [ ! -f "$MARKER" ] || [ "$(sed -n 1p "$MARKER")" != "$MARKER_OWNER" ]; then
      fail "codex $CODEX_VERSION: $GUARD_DIR exists but was not created by this guard (no ownership marker); left untouched - move it away or remove it yourself and rerun"
    fi
    [ "$(git -C "$CHECKOUT" rev-parse --absolute-git-dir 2>/dev/null)" = "$(cd -P -- "$CHECKOUT" 2>/dev/null && pwd -P)/.git" ] ||
      fail "codex $CODEX_VERSION: $CHECKOUT is not the repository this guard created; left untouched - remove $GUARD_DIR yourself and rerun"
  else
    mkdir -p "$(dirname "$GUARD_DIR")"
    if ! mkdir "$GUARD_DIR" || ! printf '%s\n' "$MARKER_OWNER" > "$MARKER"; then
      fail "codex $CODEX_VERSION: could not create the guard directory $GUARD_DIR"
    fi
    fm_git_init_commit "$CHECKOUT"
    fm_git_add_origin "$CHECKOUT" "$CHECKOUT.origin.git"
  fi
  OWNED=1
  git -C "$CHECKOUT" worktree prune
  mkdir -p "$CHECKOUT/.codex"
  cat > "$CHECKOUT/.codex/hooks.json" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "touch $SENTINEL",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
JSON
  git -C "$CHECKOUT" add .codex/hooks.json
  git -C "$CHECKOUT" diff --cached --quiet ||
    git -C "$CHECKOUT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -qm 'sentinel hook'
}

# launch_and_watch <name> <on|absent> <fm-spawn args...>: captures the launch
# fm-spawn builds under that hook posture, runs it for real in a fresh linked
# worktree, and echoes the first thing that happened: fired (the hook wrote its
# sentinel), untrusted (codex's folder-trust or hook-trust modal), turn-ended,
# exited, or timeout.
launch_and_watch() {
  local name=$1 posture=$2
  shift 2
  local case_dir home wt fakebin launchlog id i screen
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-crew-hooks-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id" \
    'This is a launch check. Reply with the single word ACK and stop. Run no commands and change no files.'
  [ "$posture" != on ] || printf 'on\n' > "$home/config/codex-crew-hooks"
  git -C "$CHECKOUT" worktree add --quiet --detach "$wt" ||
    fail "codex $CODEX_VERSION: could not add a linked worktree of $CHECKOUT"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$CHECKOUT" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build the $name launch"

  tmux -L "$SOCKET" new-session -d -s "$name" -x 160 -y 45 -c "$wt" bash "$launchlog" ||
    fail "codex $CODEX_VERSION: could not run the $name launch in the isolated tmux server"
  i=0
  while [ "$i" -lt "$POLLS" ]; do
    if [ -e "$wt/$SENTINEL" ]; then
      printf 'fired'
      return 0
    fi
    if [ -e "$home/state/$id.turn-ended" ]; then
      printf 'turn-ended'
      return 0
    fi
    screen=$(tmux -L "$SOCKET" capture-pane -p -t "$name" 2>/dev/null) || {
      printf 'exited'
      return 0
    }
    case "$screen" in
      *'Hooks need review'* | *'Trust this folder?'*)
        printf 'untrusted'
        return 0
        ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  printf '# codex %s launch pane at timeout:\n' "$name" >&2
  printf '%s\n' "$screen" | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  printf 'timeout'
}

# check_kind <crewmate|scout> <fm-spawn args...>
check_kind() {
  local kind=$1 outcome trusted_run
  shift

  outcome=$(launch_and_watch "$kind-on" on "$@") || exit 1
  case "$outcome" in
    fired) ;;
    untrusted)
      trusted_run=$(sed -n 's/^trusted-run: //p' "$MARKER")
      [ -z "$trusted_run" ] ||
        fail "codex $CODEX_VERSION: trust regressed - the $kind launch parked on a trust dialog for $CHECKOUT, whose hook last ran trusted on $trusted_run"
      fail "codex $CODEX_VERSION: the $kind launch parked on a trust dialog because $CHECKOUT and its hook were never trusted; run codex once in that directory, trust the folder and its hook, and rerun"
      ;;
    *)
      fail "codex $CODEX_VERSION: a $kind launch under config/codex-crew-hooks=on never ran the trusted project hook ($outcome)"
      ;;
  esac

  outcome=$(launch_and_watch "$kind-absent" absent "$@") || exit 1
  [ "$outcome" = turn-ended ] ||
    fail "codex $CODEX_VERSION: a default $kind launch did not finish its turn hook-free ($outcome)"
  [ ! -e "$TMP_ROOT/$kind-absent/wt/$SENTINEL" ] ||
    fail "codex $CODEX_VERSION: a default $kind launch ran the project hook after its turn ended"

  CHECKED=$((CHECKED + 1))
  pass "codex $CODEX_VERSION: a $kind launch runs the trusted project hook under config/codex-crew-hooks=on and no hook without it"
}

prepare_checkout
check_kind crewmate --mode no-mistakes --yolo off
check_kind scout --scout --harness codex

[ "$CHECKED" -gt 0 ] || fail "live codex crew-hooks guard verified nothing; refusing a vacuous pass"
printf '%s\ntrusted-run: %s with %s\n' "$MARKER_OWNER" "$(date -u +%Y-%m-%d)" "$CODEX_VERSION" > "$MARKER"
echo "# all fm-codex-crew-hooks-live-e2e tests passed"
