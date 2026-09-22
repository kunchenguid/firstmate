#!/usr/bin/env bash
# Live guard for the secondmate busy contract (live-harness-optin family).
#
# The active-turn gate reads a busy verdict from the parent home's semantic
# record and from the tmux pane. A fake pane can only confirm the command
# this tree already built. This guard runs bin/fm-spawn.sh --secondmate
# against a private tmux server.
#
# The pane command during spawn is a sleeper, so the launch brief is never
# delivered to a model and no key is sent. After the record exists, each
# installed harness that the spawn arms (claude, opencode, pi, omp) is
# started for real, with no prompt, long enough to prove that process stays
# up beside the wiring the spawn just wrote. Grok and codex are the
# disconfirming launches: they stay unarmed and gain no parent turn-end.
# An absent binary is reported and skipped. A run that checks nothing fails.
#
# Refresh docs/verification/runtime-backends.md ("Secondmate busy contract")
# from this guard after a harness upgrade.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_SECONDMATE_BUSY_LIVE tmux

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-sm-busy-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-busy-live.XXXXXX")
CHECKED=0
SKIPPED=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
  fm_test_cleanup
}
trap cleanup_all EXIT

note() { printf '# %s\n' "$1"; }

resolve_bin() {  # <name>
  local candidate
  candidate=$(command -v "$1" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

install_tmux_shim() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$dir/tmux"
}

install_sleeper() {  # <dir> <name> <real-bin>
  local dir=$1 name=$2 real=$3
  mkdir -p "$dir"
  cat > "$dir/$name" <<SH
#!/usr/bin/env bash
# Spawn probes the resolved executable with --help before it builds the
# launch. Those probes must reach the real binary. The pane command is the
# launch itself, which carries the brief, and that one must not.
case "\${1:-}" in
  --help|--version|-v|-V) exec $(printf '%q' "$real") "\$@" ;;
esac
printf 'working\n'
exec sleep 300
SH
  chmod +x "$dir/$name"
}

seed_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  if [ -d "$ROOT/.pi/extensions" ]; then
    mkdir -p "$home/.pi"
    cp -a "$ROOT/.pi/extensions" "$home/.pi/extensions"
  fi
  fm_git_init_commit "$home"
}

spawn_mate() {  # <case> <id> <harness> <sleeper-dir> <shim-dir>
  local case_dir=$1 id=$2 harness=$3 sleeper=$4 shim=$5
  local primary="$case_dir/primary" sm="$case_dir/sm" user_home="$case_dir/user-home"
  mkdir -p "$case_dir" "$user_home"
  fm_test_spawn_home "$primary" "$harness"
  seed_home "$sm" "$id"
  FM_BACKEND=tmux FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" \
    HOME="$user_home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_PROJECTS_OVERRIDE="$primary/projects" FM_CONFIG_OVERRIDE="$primary/config" \
    FM_SPAWN_NO_GUARD=1 \
    env -u TMUX -u TMUX_PANE \
    PATH="$sleeper:$shim:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$sm" "$harness" --secondmate
}

# Start the real binary with no positional brief and no keystrokes.
# Returns 0 when the pane is still alive after the wait.
real_harness_stays_up() {  # <harness> <version> <case> <id> <bin>
  local harness=$1 version=$2 case_dir=$3 id=$4 bin=$5
  local sm="$case_dir/sm" state="$case_dir/primary/state" target="firstmate:live-$harness"
  local pane_dead="" i=0 tail
  case "$harness" in
    pi|pi-signed)
      "$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "live-$harness" -c "$sm" -- \
        "$bin" \
        -e "$sm/.pi/extensions/fm-primary-turnend-guard.ts" \
        -e "$sm/.pi/extensions/fm-primary-pi-watch.ts" \
        -e "$state/$id.pi-ext.ts" \
        || fail "$harness $version: could not start the real binary"
      ;;
    omp)
      "$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "live-$harness" -c "$sm" -- \
        env -u CLAUDECODE -u PI_CODING_AGENT FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 \
        "$bin" --auto-approve --cwd "$sm" -e "$state/$id.omp-ext.ts" \
        || fail "$harness $version: could not start the real binary"
      ;;
    opencode)
      "$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "live-$harness" -c "$sm" -- \
        env OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' "$bin" \
        || fail "$harness $version: could not start the real binary"
      ;;
    claude)
      "$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "live-$harness" -c "$sm" -- \
        "$bin" \
        || fail "$harness $version: could not start the real binary"
      ;;
    *)
      fail "$harness: no token-free real launch is defined"
      ;;
  esac
  while [ "$i" -lt 40 ]; do
    pane_dead=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_dead}' 2>/dev/null || true)
    [ "$pane_dead" = 0 ] && break
    sleep 0.5
    i=$((i + 1))
  done
  # A process that exits in the first seconds must not pass on the race
  # between new-window and the crash.
  sleep 3
  pane_dead=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_dead}' 2>/dev/null || true)
  tail=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S -40 2>/dev/null || true)
  [ "$pane_dead" = 0 ] || fail "$harness $version: real process exited before the wiring could be observed: ${tail:-<empty pane>}"
  [ ! -e "$state/$id.turn-ended" ] || fail "$harness $version: the real process touched the parent's turn-ended marker"
  note "$harness $version: real process stayed up; pane tail classify=$(fm_busy_classify tmux "$target" "$harness" "$id" "$state" "$tail")"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
}

check_harness() {  # <harness>
  local harness=$1 bin version id case_dir state out armed=0
  if ! bin=$(resolve_bin "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its secondmate busy contract is unverified here"
    return 0
  fi
  version=$("$bin" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version=unknown
  id="sm-$harness"
  case_dir="$LAB/$harness"
  install_sleeper "$case_dir/sleeper" "$harness" "$bin"
  install_tmux_shim "$case_dir/shim"
  out=$(spawn_mate "$case_dir" "$id" "$harness" "$case_dir/sleeper" "$case_dir/shim" 2>&1) \
    || fail "$harness $version: secondmate spawn failed: $out"
  state="$case_dir/primary/state"
  case "$harness" in
    claude|opencode|pi|pi-signed|omp) armed=1 ;;
  esac
  if [ "$armed" -eq 1 ]; then
    [ -f "$state/$id.busy-state" ] || fail "$harness $version: real tmux secondmate spawn did not arm the busy contract"
    out=$(fm_busy_classify tmux "firstmate:fm-$id" "$harness" "$id" "$state" 'working on the charter')
    [ "$out" = "busy fm-spawn" ] || fail "$harness $version: a mid-turn tail classified '$out', not busy fm-spawn"
    [ ! -e "$state/$id.turn-ended" ] || fail "$harness $version: spawn touched the parent's turn-ended marker"
    real_harness_stays_up "$harness" "$version" "$case_dir" "$id" "$bin"
    pass "$harness $version: a tmux secondmate spawn arms a busy verdict the active-turn gate can see"
  else
    [ ! -e "$state/$id.busy-gen" ] || fail "$harness $version: an unarmed secondmate spawn wrote a busy generation"
    [ ! -e "$state/$id.turn-ended" ] || fail "$harness $version: an unarmed secondmate spawn touched the parent's turn-ended marker"
    [ ! -e "$state/$id.grok-turnend-token" ] || fail "$harness $version: spawn installed a parent grok turn-end token"
    pass "$harness $version: secondmate spawn stays unarmed and does not emit a parent turn-end"
  fi
  CHECKED=$((CHECKED + 1))
}

for harness in claude opencode pi pi-signed omp grok codex; do
  check_harness "$harness"
done

[ "$CHECKED" -gt 0 ] || fail "secondmate busy contract live guard checked nothing (skipped:${SKIPPED:- none})"
note "checked $CHECKED harness(es); absent:${SKIPPED:- none}"
pass "secondmate busy contract live guard checked every installed harness"
