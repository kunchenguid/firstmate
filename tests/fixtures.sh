#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, tmux, ssh, and spawn-world helpers. Wake-queue mocks
# stay in wake-helpers.sh; secondmate-lifecycle mocks stay in
# secondmate-helpers.sh.
#
# FM_TEST_NO_MISTAKES_VERSION is the single default version for the shared fake
# no-mistakes banner. Override a single case with FM_FAKE_NO_MISTAKES_VERSION
# rather than editing a stub body.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${FM_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FIXTURES_SOURCED=1

# Production floor lives in bin/fm-bootstrap.sh (NO_MISTAKES_MIN). Keep this
# equal to that floor so a bump is one constant here plus that production pin.
export FM_TEST_NO_MISTAKES_VERSION=1.46.0
export FM_TEST_NO_MISTAKES_FAKE_VERSION="no-mistakes version v${FM_TEST_NO_MISTAKES_VERSION} (fake)"
export FM_TEST_NO_MISTAKES_FAKE_VERSION_TS="${FM_TEST_NO_MISTAKES_FAKE_VERSION} 2026-06-27T00:02:18Z"
export FM_TEST_GH_AXI_VERSION=0.1.29

# --- fake no-mistakes -------------------------------------------------------

# fm_test_fake_no_mistakes <fakebin>
# Drops a no-mistakes stub that answers --version with
# FM_TEST_NO_MISTAKES_FAKE_VERSION (or FM_FAKE_NO_MISTAKES_VERSION when set)
# and exits 0 for every other invocation.
fm_test_fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_NO_MISTAKES_VERSION:-$FM_TEST_NO_MISTAKES_FAKE_VERSION}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fm_test_fake_no_mistakes_init_doctor <fakebin>
# Secondmate-lifecycle stub: init/doctor touch marker files; other verbs exit 2.
# Does not answer --version (those suites never probe the floor).
fm_test_fake_no_mistakes_init_doctor() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
}

# --- fake gh / gh-axi -------------------------------------------------------

# fm_test_fake_gh <fakebin>
# Authenticates (`gh auth status` exits 0) and otherwise exits 0.
fm_test_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# fm_test_fake_gh_axi <fakebin>
# Answers --version with FM_FAKE_GH_AXI_VERSION or FM_TEST_GH_AXI_VERSION.
fm_test_fake_gh_axi() {
  local fakebin=$1
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION "$FM_TEST_GH_AXI_VERSION"
}

# --- fake tmux / ssh / sleep ------------------------------------------------

# fm_test_fake_tmux_spawn <fakebin>
# Spawn-world tmux: pane_current_path from FM_FAKE_PANE_PATH, session named
# firstmate, window ops succeed, send-keys succeed. When FM_FAKE_LAUNCH_LOG is
# set, each send-keys -l payload is appended one per line. When FM_FAKE_PANE_LOG
# is set, each send-keys TEXT-LINE payload (the pre-launch pane exports, which
# carry no -l) is appended there instead, one per line in send order. Optional
# FM_FAKE_DUPLICATE_WINDOW is printed from list-windows.
#
# The pane path defaults to empty when FM_FAKE_PANE_PATH is unset. Window
# cleanup and option operations are no-ops. Launch logging is env-gated, so
# suites that do not set FM_FAKE_LAUNCH_LOG keep a silent send-keys.
fm_test_fake_tmux_spawn() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_DUPLICATE_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_DUPLICATE_WINDOW"
    fi
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          # A spawn types a short line sourcing its staged launch file; log
          # the staged command itself so suites assert what the pane runs.
          # Direct literals past the terminal line buffer are truncated, so a
          # long launch only survives when it arrived through that short source.
          case "$a" in
            ". '"*"'")
              staged=${a#". '"}
              staged=${staged%"'"}
              if [ -f "$staged" ]; then
                a=$(cat "$staged")
              elif [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
            *)
              if [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
          esac
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    # The pre-launch pane exports ride the text-line form
    # (`send-keys -t <target> <text> Enter`), which carries no -l flag, so a
    # suite that asserts on what the pane shell received opts in with its own
    # log. Skip the flags, the target, and the trailing key so only the payload
    # is recorded, one per line, in send order.
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      shift
      skip_next=
      literal=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) literal=1; continue ;;
          Enter|C-m) continue ;;
          *) [ -n "$literal" ] || printf '%s\n' "$a" >> "$FM_FAKE_PANE_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_tmux_send <fakebin>
# Send-world tmux: logs send-keys -l payloads to FM_SEND_LOG, reports a numeric
# cursor_y, and renders an empty bordered composer so the submit path reads
# empty. Env knobs:
#   FM_FAKE_TMUX_SEND_FAIL=1  send-keys exits 1
#   FM_FAKE_TMUX_COMPOSER=pending  capture-pane shows leftover composer text
fm_test_fake_tmux_send() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_ssh <fakebin> [name]
# Records argv to FM_SSH_LOG, consumes stdin, exits FM_FAKE_SSH_RC (default 0).
# Default name is fake-ssh so tests can point FM_SSH_BIN at it without
# shadowing a real ssh on PATH.
fm_test_fake_ssh() {
  local fakebin=$1 name=${2:-fake-ssh}
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "${FM_SSH_LOG:-/dev/null}"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fakebin/$name"
}

# fm_test_fake_sleep_noop <fakebin>
fm_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# fm_test_fake_sleep_log <fakebin>
# Records each requested duration to FM_SLEEP_LOG instead of sleeping.
fm_test_fake_sleep_log() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# fm_test_spawn_home <home> [harness]
# Minimal firstmate home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
fm_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
}

# fm_test_spawn_brief <home> <id> [captain-intent]
fm_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

# fm_test_make_spawn_fakebin <dir> [extra-exit0-tool...]
# Creates <dir>/fakebin with the spawn tmux stub, a no-op treehouse, and any
# extra exit-0 tools. Echoes the fakebin path.
fm_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse "$@"
  printf '%s\n' "$fakebin"
}

# Drop-in name used by the spawn suites. Extra args are additional exit-0 tools
# (gh, gh-axi, pi, ...).
make_spawn_fakebin() {
  fm_test_make_spawn_fakebin "$@"
}

# fm_test_run_spawn <home> <pane-path> <fakebin> [fm-spawn args...]
# Common spawn env. Extra variables in the caller (GROK_HOME, FM_FAKE_LAUNCH_LOG,
# CLAUDE_CONFIG_DIR, ...) are inherited. Does not add --mode/--yolo; ship tests
# that need a delivery contract pass those flags themselves.
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so every spawn here runs against a throwaway
  # HOME; without it the suite would write the developer's real ~/.claude.json.
  # CLAUDE_CONFIG_DIR must be pinned too, and pinned EMPTY: the script resolves
  # the store as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so a value inherited from the
  # developer's shell would beat the throwaway HOME and the sandbox would not
  # hold, while an empty value falls through to it. Empty rather than a path
  # because bin/fm-spawn.sh prefixes the launch only when the value is non-empty,
  # so every launch-shape assertion in the suite keeps reading the same command.
  # A test that needs the set case opts in through FM_TEST_CLAUDE_CONFIG_DIR.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# make_seeded_secondmate_home <home> <id>
# The minimal marked home a --secondmate spawn launches into.
make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
}

# fm_test_capture_codex_launch <case-dir> [--secondmate[=<home>]] <extra fm-spawn args...>
# Capture the generated launch through the public spawn interface. The task is
# codex-live in <case-dir>/home; --secondmate launches it into a seeded
# <case-dir>/secondmate-home instead of a project worktree. --secondmate=<home>
# launches into that already-marked home instead, skipping the inheritance and
# fast-forward steps so the spawn writes nothing there beyond its state/ dir.
fm_test_capture_codex_launch() {
  local case_dir=$1 home proj wt fakebin launchlog target skip=0
  shift
  case "${1:-}" in
    --secondmate=*)
      target=${1#--secondmate=}
      shift
      set -- --secondmate "$@"
      skip=1
      ;;
  esac
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" codex-live
  fm_git_worktree "$proj" "$wt" codex-live
  if [ "$skip" -eq 0 ]; then
    target=$proj
    if [ "${1:-}" = --secondmate ]; then
      target="$case_dir/secondmate-home"
      make_seeded_secondmate_home "$target" codex-live
    fi
  fi
  : > "$launchlog"
  FM_SKIP_SECONDMATE_INHERIT=$skip FM_SKIP_SECONDMATE_SYNC=$skip FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" codex-live "$target" "$@" >/dev/null 2>&1 ||
    fail "fm-spawn could not build a codex launch"
  cat "$launchlog"
}

# --- dedicated live secondmate fixture -------------------------------------
#
# The live doorbell guard's secondmate variant runs only in an operator-supplied
# standalone clone (FM_SEND_INBOX_LIVE_SECONDMATE_HOME). The guard never creates
# the consent sentinel and owns only the literal paths prepare writes.

# fm_live_sm_fixture_check <dir> <root>
# Echoes the canonical fixture; with no <dir>, prints the untested report and
# returns 2; otherwise prints the refusal reason and returns 1.
fm_live_sm_fixture_check() {
  local dir=$1 root=$2 abs tmp other sentinel p
  [ -n "$dir" ] || { printf 'untested: no dedicated fixture supplied\n'; return 2; }
  case "$dir" in
    /*) ;;
    *) printf 'not an absolute path: %s\n' "$dir"; return 1 ;;
  esac
  [ ! -L "$dir" ] || { printf 'is a symlink: %s\n' "$dir"; return 1; }
  [ -d "$dir" ] || { printf 'not an existing directory: %s\n' "$dir"; return 1; }
  abs=$(cd "$dir" && pwd -P)
  [ "$abs" = "$dir" ] || { printf 'not canonical (resolves to %s): %s\n' "$abs" "$dir"; return 1; }
  tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  case "$abs" in
    "$tmp"/*) ;;
    *) printf 'not under %s: %s\n' "$tmp" "$abs"; return 1 ;;
  esac
  if [ -L "$abs/.git" ] || [ ! -d "$abs/.git" ] ||
    [ "$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null)" != "$abs" ] ||
    [ "$(git -C "$abs" rev-parse --git-common-dir 2>/dev/null)" != .git ]; then
    printf 'not a standalone clone (linked worktree or not its own git top level): %s\n' "$abs"
    return 1
  fi
  sentinel=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$abs/.git/fm-live-secondmate-fixture" 2>/dev/null) || sentinel=''
  [ "$sentinel" = "$abs" ] || {
    printf 'no consent sentinel naming this fixture: %s/.git/fm-live-secondmate-fixture\n' "$abs"
    return 1
  }
  root=$(cd "$root" && pwd -P)
  for other in "${FM_HOME:-}" "$root" "${HOME:-}"; do
    [ -n "$other" ] && [ -d "$other" ] || continue
    other=$(cd "$other" && pwd -P)
    [ "$abs" = "$root" ] && [ "$other" = "$root" ] && continue
    case "$abs/" in
      "$other"/*) printf 'equal to or inside %s: %s\n' "$other" "$abs"; return 1 ;;
    esac
    case "$other/" in
      "$abs"/*) printf 'contains %s: %s\n' "$other" "$abs"; return 1 ;;
    esac
  done
  for p in .fm-secondmate-home .fm-secondmate-parent projects; do
    if [ -e "$abs/$p" ] || [ -L "$abs/$p" ]; then
      printf 'stale fixture state; remove manually: %s\n' "$abs/$p"
      return 1
    fi
  done
  for p in state data; do
    if [ -L "$abs/$p" ] || { [ -e "$abs/$p" ] && [ ! -d "$abs/$p" ]; } ||
      [ -n "$(ls -A "$abs/$p" 2>/dev/null)" ]; then
      printf 'stale fixture state; remove manually: %s\n' "$abs/$p"
      return 1
    fi
  done
  if ! p=$(git -C "$abs" status --porcelain 2>&1) || [ -n "$p" ]; then
    printf 'work tree is not clean: %s\n' "$abs"
    return 1
  fi
  [ "$(git -C "$abs" rev-parse HEAD 2>/dev/null)" = "$(git -C "$root" rev-parse HEAD 2>/dev/null)" ] ||
    { printf 'HEAD differs from %s: %s\n' "$root" "$abs"; return 1; }
  if [ ! -f "$abs/.codex/hooks.json" ] || ! cmp -s "$abs/.codex/hooks.json" "$root/.codex/hooks.json"; then
    printf '.codex/hooks.json is missing or differs from %s: %s\n' "$root" "$abs"
    return 1
  fi
  printf '%s\n' "$abs"
}

FM_LIVE_SM_FIXTURE=''
FM_LIVE_SM_MADE_DATA=0
FM_LIVE_SM_MADE_STATE=0
# What the secondmate's own startup and hooks were observed to leave in the
# fixture's state/ (plus an empty terminal-outcomes/). Cleanup removes only
# these literal names; anything else stops it.
FM_LIVE_SM_STATE_FILES='.inactive-outcome-reconcile .lock .session-start-agents-baseline .session-start-complete .startup-network.delivered .startup-network.report .startup-network.status .startup-network.timings .trace-context-effective .wake-queue home-summary.json'

# fm_live_sm_fixture_prepare <checked-fixture> <id>
# Marks the fixture as <id>'s secondmate home. The charter is only the input
# fm-spawn needs to build the launch; the replayed launch delivers no brief.
# Records which of data/ and state/ (the spawn creates state/) did not exist,
# so cleanup removes only those.
fm_live_sm_fixture_prepare() {
  local abs=$1 id=$2
  FM_LIVE_SM_FIXTURE=$abs
  [ -d "$abs/data" ] || FM_LIVE_SM_MADE_DATA=1
  [ -d "$abs/state" ] || FM_LIVE_SM_MADE_STATE=1
  mkdir -p "$abs/data" &&
    printf '%s\n' "$id" > "$abs/.fm-secondmate-home" &&
    printf 'charter for %s\n' "$id" > "$abs/data/charter.md"
}

# fm_live_sm_fixture_cleanup
# Call only once the fixture's Codex processes have exited. Removes exactly
# what prepare (and the spawn's state/ mkdir) created plus the documented
# FM_LIVE_SM_STATE_FILES. Any other state/ entry makes it remove nothing,
# print the unexpected paths, and return 1.
fm_live_sm_fixture_cleanup() {
  local abs=$FM_LIVE_SM_FIXTURE name extra='' known k
  [ -n "$abs" ] || return 0
  if [ -d "$abs/state" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      known=0
      for k in $FM_LIVE_SM_STATE_FILES; do
        [ "$name" != "$k" ] || [ -d "$abs/state/$name" ] || known=1
      done
      if [ "$name" = terminal-outcomes ] && [ -d "$abs/state/$name" ] && [ ! -L "$abs/state/$name" ] &&
        [ -z "$(ls -A "$abs/state/$name")" ]; then
        known=1
      fi
      [ "$known" -eq 1 ] || extra="$extra $abs/state/$name"
    done <<EOF
$(ls -A "$abs/state")
EOF
  fi
  if [ -n "$extra" ]; then
    printf 'unexpected fixture state, nothing removed; remove manually:%s\n' "$extra"
    return 1
  fi
  for name in $FM_LIVE_SM_STATE_FILES; do
    rm -f "$abs/state/$name"
  done
  [ ! -d "$abs/state/terminal-outcomes" ] || rmdir "$abs/state/terminal-outcomes"
  rm -f "$abs/.fm-secondmate-home" "$abs/data/charter.md"
  [ "$FM_LIVE_SM_MADE_DATA" -eq 0 ] || rmdir "$abs/data" 2>/dev/null || true
  [ "$FM_LIVE_SM_MADE_STATE" -eq 0 ] || rmdir "$abs/state" 2>/dev/null || true
  FM_LIVE_SM_FIXTURE=''
  FM_LIVE_SM_MADE_DATA=0
  FM_LIVE_SM_MADE_STATE=0
}

# fm_test_codex_turn_state <sessions-dir> <cwd> <since: UTC YYYY-MM-DDTHH:MM:SS>
# Codex's own rollout record is the turn evidence: each
# <sessions-dir>/YYYY/MM/DD/rollout-*.jsonl opens with a session_meta line
# (payload.cwd, payload.timestamp) and logs event_msg task_started and
# task_complete per turn. Over sessions at <cwd> started at or after <since>,
# prints active if any has a task_started without a later task_complete,
# completed if one finished a turn, none if no turn started (no such session,
# or none in it), and invalid if the evidence cannot be read or parsed.
fm_test_codex_turn_state() {
  local dir=$1 cwd=$2 since=$3 f last state=none
  [ -e "$dir" ] || { printf 'none\n'; return 0; }
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || { printf 'invalid\n'; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    head -1 "$f" 2>/dev/null | jq -e 'type == "object"' >/dev/null 2>&1 || { printf 'invalid\n'; return 0; }
    head -1 "$f" | jq -e --arg cwd "$cwd" --arg since "$since" \
      '.type == "session_meta" and .payload.cwd == $cwd and
       ((.payload.timestamp // .timestamp // "")[0:19] >= $since)' >/dev/null 2>&1 || continue
    last=$(jq -r 'select(.type == "event_msg" and
      (.payload.type == "task_started" or .payload.type == "task_complete")) | .payload.type' "$f" 2>/dev/null) ||
      { printf 'invalid\n'; return 0; }
    case "$(printf '%s\n' "$last" | tail -1)" in
      task_started) printf 'active\n'; return 0 ;;
      task_complete) state=completed ;;
    esac
  done <<EOF
$(find "$dir" -type f -name 'rollout-*.jsonl' -mtime -2 2>/dev/null)
EOF
  printf '%s\n' "$state"
}

# fm_test_wait_codex_idle <timeout-seconds> <quiet-polls> <probe> [args...]
# Read-only readiness: polls <probe>, which prints "<composer-state>
# <turn-state>", about once a second. Prints the verified state and returns 0
# once the composer reads empty and the turn none or completed for
# <quiet-polls> consecutive polls; otherwise prints the last inconclusive
# reason and returns 1 when <timeout-seconds> expires. It sends nothing.
fm_test_wait_codex_idle() {
  local budget=$1 quiet=$2 i=0 run=0 obs composer turn why
  shift 2
  while :; do
    obs=$("$@")
    composer=${obs%% *}
    turn=${obs#* }
    case "$composer:$turn" in
      empty:none|empty:completed)
        run=$((run + 1))
        why="inconclusive: not quiet for $quiet consecutive polls"
        ;;
      *)
        run=0
        case "$turn" in
          active) why='inconclusive: turn active' ;;
          none|completed) why="inconclusive: composer not readable or not empty (${composer:-unknown})" ;;
          *) why='inconclusive: turn evidence unreadable or invalid' ;;
        esac
        ;;
    esac
    if [ "$run" -ge "$quiet" ]; then
      if [ "$turn" = none ]; then
        printf 'verified idle: no turn started\n'
      else
        printf 'verified idle: initial turn completed\n'
      fi
      return 0
    fi
    [ "$i" -lt "$budget" ] || { printf '%s\n' "$why"; return 1; }
    sleep 1
    i=$((i + 1))
  done
}

# fm_test_codex_secondmate_cmd <launch command> [<daemon option + space>]
# What the live guard executes for a secondmate: the generated environment
# prefix (it points the hooks at the fixture home), codex, and the generated
# global flags, with no positional launch brief.
fm_test_codex_secondmate_cmd() {
  printf '%s' "unset CODEX_THREAD_ID; ${1%%codex *}codex ${2:-}$(fm_test_codex_global_flags "$1")"
}

# fm_test_codex_global_flags <launch command>
# The generated flags before the positional encoded brief.
fm_test_codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: send tmux + no-op sleep. Echoes the fakebin path.
# Suites that need recording sleep, herdr, or ssh add those on top of this
# fakebin (or replace sleep via fm_test_fake_sleep_log).
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_send "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}
