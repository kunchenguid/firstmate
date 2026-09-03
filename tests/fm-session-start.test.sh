#!/usr/bin/env bash
# tests/fm-session-start.test.sh - behavior tests for bin/fm-session-start.sh,
# the single command that collapses AGENTS.md sections 3 (bootstrap) and 5
# (recovery) into one ordered digest.
#
# Coverage:
#   - absent-file markers vs empty-but-present files in the context digest
#   - the lock-refusal read-only path: banner leads, every mutating step is
#     skipped (including bootstrap's seven mutating sweeps, verified by their
#     ABSENCE), the digest still completes
#   - output section ordering: the safety preamble leads unchanged, live fleet
#     state precedes the curated memory a truncated tail may take, and the
#     read-once contract precedes both
#   - context-aware next-step guidance for read-only, AFK, X mode, and normal
#     watcher ownership
#   - status-tail bounding, default and FM_SESSION_START_STATUS_TAIL override
#   - the per-line status-tail cap and its truncation marker
#   - startup backlog composition: done rows dropped, every in-flight/held/
#     blocked row kept whole, the dispatchable queued listing bounded with an
#     exact disclosed remainder
#   - orphan status logs whose task meta has already disappeared
#   - per-task endpoint-liveness lines for a live and a dead recorded target,
#     tmux and herdr both
#   - composition: the script invokes the real fm-lock.sh/fm-bootstrap.sh/
#     fm-wake-drain.sh (their real, distinctive output appears verbatim), it
#     does not reimplement their logic
#   - the deferred startup stage: slow network and inactive current-state reads
#     do not delay the digest, the work still runs and lands durable findings, a
#     network result surfaces exactly once (inline or as a wake, never both), a
#     read-only session declares the checks it skipped, and the tasks-axi
#     compatibility verdict is paid for once per session start
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-start-tests)
SESSION_START_TEST_HARNESS_PID=$$
SESSION_START_SECOND_MATE_ID="fmtest-sm-${TMP_ROOT##*.}"
SESSION_START_SECOND_MATE_TMP="/tmp/fm-$SESSION_START_SECOND_MATE_ID"
SESSION_START_HERDR_SECOND_MATE_ID="fmtest-herdr-${TMP_ROOT##*.}"
SESSION_START_HERDR_SECOND_MATE_TMP="/tmp/fm-$SESSION_START_HERDR_SECOND_MATE_ID"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT" "$SESSION_START_SECOND_MATE_TMP" "$SESSION_START_HERDR_SECOND_MATE_TMP")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

# --- world builders ----------------------------------------------------------

# new_world <name>: a real, throwaway git repo on `main` (so the worktree-tangle
# and default-branch checks behave exactly as they do against the real
# firstmate repo) to use as FM_ROOT_OVERRIDE, plus an empty FM_HOME with
# state/, data/, config/, and a fakebin. Echoes "<root-dir>|<home-dir>|<fakebin>".
new_world() {
  local name=$1 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

# make_fake_toolchain <fakebin>: every tool fm-bootstrap.sh detects, present
# and compatible, so its own detect-only section stays quiet except where a
# test deliberately breaks one. Mirrors fm-bootstrap.test.sh's fixture.
make_fake_toolchain() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' manual > "${fakebin%/*}/home-placeholder" 2>/dev/null || true
}

# make_fake_tasks_axi_compact <fakebin>: a tasks-axi boundary that answers the
# four group filters the startup listing composes (in-flight, held, blocked
# queued, and the dispatchable ready set) and REFUSES anything the recovery
# listing must never ask for: a body field, an unfiltered whole-backlog listing,
# or done rows. FM_FAKE_TASKS_AXI_READY sizes the ready set so the queued bound
# can be driven past its limit.
make_fake_tasks_axi_compact() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TASKS_AXI_LOG:-}
[ -n "$log" ] && printf '%s\n' "$*" >> "$log"
ready_count=${FM_FAKE_TASKS_AXI_READY:-2}
require_file() {
  case "$*" in *'--file '*) return 0 ;; esac
  printf '%s\n' 'missing explicit backlog file' >&2
  exit 9
}
task_header() {
  printf 'count: %s\n' "$1"
  printf 'tasks[%s]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\n' "$1"
}
list_help() {
  printf 'help[1]:\n'
  printf '%s\n' '  - Run `tasks-axi show <id> --full` for full notes on a task'
}
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' '0.2.4'
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'
      exit 0
    fi
    ;;
  ready)
    require_file "$@"
    printf 'count: %s\n' "$ready_count"
    printf 'ready[%s]{id,state,kind,repo,title}:\n' "$ready_count"
    i=1
    while [ "$i" -le "$ready_count" ]; do
      printf '  ready-%s,queued,ship,firstmate,Ready item %s\n' "$i" "$i"
      i=$((i + 1))
    done
    printf 'ready_public_followups: 0 delivery-ready obligations\n'
    printf 'help[1]:\n'
    printf '%s\n' '  - Run `tasks-axi start <id>` to dispatch one of these'
    exit 0
    ;;
  list)
    case "$*" in
      *'--fields '*'body'*|*'--fields='*'body'*)
        printf '%s\n' 'unexpected body field requested' >&2
        exit 9
        ;;
    esac
    require_file "$@"
    case "$*" in
      *'--state done'*)
        printf '%s\n' 'startup recovery must never list done rows' >&2
        exit 9
        ;;
      *'--state in_flight'*)
        task_header 1
        printf '%s\n' '  compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending'
        ;;
      *'--state held'*)
        task_header 1
        printf '%s\n' '  held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending'
        ;;
      *'--state queued'*'--blocked'*)
        task_header 1
        printf '%s\n' '  blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"'
        ;;
      *)
        printf '%s\n' 'startup recovery must not request an unfiltered whole-backlog listing' >&2
        exit 9
        ;;
    esac
    list_help
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
}

# make_fake_ps_claude <fakebin>: harness_pid()/holder_alive() (fm-lock.sh) walk
# `ps` output looking for a harness command name; this fake reports EVERY
# queried pid as a live `claude` harness unless a stable harness pid is set.
make_fake_ps_claude() {
  local fakebin=$1
  make_fake_ps_harness "$fakebin" claude
}

make_fake_ps_harness() {
  local fakebin=$1 harness=$2
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
harness=${FM_FAKE_HARNESS:-claude}
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ] \
      || [ "$pid" = "${FM_FAKE_LIVE_HOLDER_PID:-}" ]; then
      printf '/usr/local/bin/%s\n' "$harness"
    else
      printf '/bin/bash\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ] \
      || [ "$pid" = "${FM_FAKE_LIVE_HOLDER_PID:-}" ]; then
      printf '%s\n' "$harness"
    else
      printf 'bash\n'
    fi
    exit 0
    ;;
  *"ppid="*)
    [ -n "${FM_FAKE_HARNESS_PID:-}" ] || exit 1
    /bin/ps -o ppid= -p "$pid"
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$harness" > "$fakebin/.harness-name"
}

make_fake_ps_pi_holder() {
  local fakebin=$1 holder_pid=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"comm="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf '/usr/local/bin/pi\n'
    else
      printf '/bin/zsh\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf 'pi\n'
    else
      printf 'zsh\n'
    fi
    exit 0
    ;;
  *"ppid="*) printf '%s\n' "$holder_pid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_tmux <fakebin> <live-target>: display-message succeeds only for
# the given "session:window" target - the exact primitive
# fm_backend_target_exists uses for a tmux endpoint liveness read.
make_fake_tmux() {
  local fakebin=$1 live=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    target=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "-t" ] && target="\$a"
      prev="\$a"
    done
    [ "\$target" = "$live" ] && { printf '%%1\n'; exit 0; }
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# make_fake_tmux_secondmate_recovery <fakebin>: a stateful tmux boundary
# fixture for the real session-start -> bootstrap -> spawn path.
# FM_FAKE_TMUX_MODE selects missing, ambiguous, unreadable, or shell; missing
# reproduces real tmux's active-window fallback while inventory omits the mate.
make_fake_tmux_secondmate_recovery() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_FAKE_TMUX_MODE:?}
log=${FM_FAKE_TMUX_LOG:?}
spawned=${FM_FAKE_TMUX_SPAWNED:?}
killed=${spawned}.killed
mate_home=${FM_FAKE_SECOND_MATE_HOME:?}
mate_id=${FM_FAKE_SECOND_MATE_ID:?}
mate_window="fm-$mate_id"
case "${1:-}" in
  display-message)
    target=
    format=
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && target=$arg
      prev=$arg
      case "$arg" in '#{'*) format=$arg ;; esac
    done
    if [ "${target#%}" != "$target" ]; then
      case "$format" in
        *pane_current_path*) printf '%s\n' "$mate_home" ;;
        *pane_current_command*) printf '%s\n' node ;;
        *) printf '%s\n' "$target" ;;
      esac
      exit 0
    fi
    if [ -e "$spawned" ]; then
      case "$format" in
        *pane_current_command*) printf '%s\n' node ;;
        *) printf '%%1\n' ;;
      esac
      exit 0
    fi
    case "$mode" in
      ambiguous)
        case "$format" in *pane_current_command*) printf '%s\n' node ;; *) printf '%%1\n' ;; esac
        exit 0
        ;;
      shell)
        case "$format" in *pane_current_command*) printf '%s\n' zsh ;; *) printf '%%1\n' ;; esac
        exit 0
        ;;
      missing)
        case "$format" in *pane_current_command*) printf '%s\n' node ;; *) printf '%%fallback\n' ;; esac
        exit 0
        ;;
      unreadable) exit 1 ;;
    esac
    ;;
  list-windows)
    if [ "$mode" = unreadable ] && [ ! -e "$spawned" ] && [ ! -e "$killed" ]; then
      exit 1
    fi
    if [ -e "$spawned" ]; then
      printf '%s\n' "$mate_window"
    elif [ ! -e "$killed" ] && { [ "$mode" = ambiguous ] || [ "$mode" = shell ]; }; then
      printf '%s\n' "$mate_window"
    else
      printf '%s\n' main
    fi
    exit 0
    ;;
  has-session) exit 0 ;;
  kill-window)
    printf '%s\n' "$*" >> "$log"
    : > "$killed"
    exit 0
    ;;
  new-window)
    printf '%s\n' "$*" >> "$log"
    : > "$spawned"
    printf '%%1\n'
    exit 0
    ;;
  set-window-option|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

make_fake_herdr_secondmate_recovery() {
  local fakebin=$1
  # The recovery kill now requires the shared named-session lock and an exact
  # focus snapshot. Keep a focused sibling tab so this test's husk close is
  # provably non-workspace-emptying and never needs to signal a fake shell pid.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_HERDR_LOG:?}
state=${FM_FAKE_HERDR_STATE:?}
mate_id=${FM_FAKE_SECOND_MATE_ID:?}
killed="${state}.killed"
spawned="${state}.spawned"
printf '%s\n' "$*" >> "$log"
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"protocol":14,"version":"test"},"server":{"running":true}}'
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s.sock"}]}\n' "$state"
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"ws1","label":"2ndmate-%s","focused":true,"active_tab_id":"t-focus"}]}}\n' "$mate_id"
    ;;
  "tab list")
    if [ -e "$spawned" ]; then
      printf '{"result":{"tabs":[{"tab_id":"t-focus","workspace_id":"ws1","label":"captain","focused":true},{"tab_id":"t-new","workspace_id":"ws1","label":"fm-%s","focused":false}]}}\n' "$mate_id"
    elif [ -e "$killed" ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"t-focus","workspace_id":"ws1","label":"captain","focused":true}]}}'
    else
      printf '{"result":{"tabs":[{"tab_id":"t-focus","workspace_id":"ws1","label":"captain","focused":true},{"tab_id":"t-old","workspace_id":"ws1","label":"fm-%s","focused":false}]}}\n' "$mate_id"
    fi
    ;;
  "tab create")
    : > "$spawned"
    printf '%s\n' '{"result":{"tab":{"tab_id":"t-new"},"root_pane":{"pane_id":"p-new"}}}'
    ;;
  "pane list")
    if [ -e "$spawned" ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"p-new","tab_id":"t-new"}]}}'
    elif [ ! -e "$killed" ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"p-old","tab_id":"t-old"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[]}}'
    fi
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" = p-new ] && [ -e "$spawned" ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"p-new","tab_id":"t-new","workspace_id":"ws1"}}}'
    elif [ "$pane" = p-old ] && [ ! -e "$killed" ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"p-old","tab_id":"t-old","workspace_id":"ws1"}}}'
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    ;;
  "agent get")
    if [ "${3:-}" = p-new ] && [ -e "$spawned" ]; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    ;;
  "pane close")
    [ "${3:-}" = p-old ] && : > "$killed"
    ;;
  "pane run"|"pane send-text"|"pane send-keys"|"tab close")
    ;;
  *)
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

# make_fake_herdr <fakebin> <live-pane>: `herdr pane get <pane>` succeeds only
# for the given pane id - the exact primitive fm_backend_target_exists uses
# for a herdr endpoint liveness read. No version/server-start calls: a
# liveness check must never auto-start a server (fm-backend.sh's contract).
make_fake_herdr() {
  local fakebin=$1 live=$2
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  [ "\${3:-}" = "$live" ] && exit 0
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/herdr"
}

# run_session_start <home> <root> <path>
# Drop every harness env marker from bin/fm-harness.sh detect_own so the
# surrounding interactive shell cannot leak past the suite's fake ps harness.
# Markers today: CLAUDECODE (claude), PI_CODING_AGENT plus FM_PI_HARNESS
# (Pi family), GROK_AGENT (grok).
# codex and opencode have no env markers (ancestry only). Without this, a local
# claude/pi/grok session fails cases that pin a different fake harness while CI
# (no ambient markers) still passes.
run_session_start() {
  local home=$1 root=$2 path=$3 pi_harness=${4:-}
  if [ -n "$pi_harness" ]; then
    env -u CLAUDECODE -u GROK_AGENT PI_CODING_AGENT=true FM_PI_HARNESS="$pi_harness" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  else
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  fi
}

run_pi_session_start() {  # <home> <root> <path> [fm-session-start args...]
  local home=$1 root=$2 path=$3
  shift 3
  env -u CLAUDECODE -u GROK_AGENT PI_CODING_AGENT=true FM_PI_HARNESS=pi \
    FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
    "$SESSION_START" "$@"
}

run_named_harness_session_start() {  # <harness> <home> <root> <path> [fm-session-start args...]
  local harness=$1 home=$2 root=$3 path=$4
  shift 4
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_FAKE_HARNESS="$harness" FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
    "$SESSION_START" "$@"
}

# prepare_session_start_secondmate <name>: a throwaway main home and Pi
# secondmate home wired to the real spawn implementation through the fixture
# root. Echoes root|home|fakebin|mate|log|spawned.
prepare_session_start_secondmate() {
  local name=$1 rec root home fakebin w mate log spawned id=$SESSION_START_SECOND_MATE_ID
  rec=$(new_world "$name")
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  w=${root%/root}
  mate="$w/secondmate-$id"
  log="$w/tmux.log"
  spawned="$w/tmux.spawned"
  mkdir -p "$mate/bin" "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'Second mate charter.\n' > "$mate/data/charter.md"
  printf '%s\n' pi > "$home/config/secondmate-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'harness=pi\n'
    printf 'home=%s\n' "$mate"
  } > "$home/state/$id.meta"
  ln -s "$ROOT/bin" "$root/bin"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_fake_exit0 "$fakebin" pi
  make_fake_tmux_secondmate_recovery "$fakebin"
  : > "$log"
  printf '%s|%s|%s|%s|%s|%s\n' "$root" "$home" "$fakebin" "$mate" "$log" "$spawned"
}

run_session_start_secondmate() {
  local root=$1 home=$2 fakebin=$3 mate=$4 log=$5 spawned=$6 mode=$7
  TMUX='' FM_BACKEND=tmux FM_FAKE_TMUX_MODE="$mode" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_SPAWNED="$spawned" FM_FAKE_SECOND_MATE_HOME="$mate" \
    FM_FAKE_SECOND_MATE_ID="$SESSION_START_SECOND_MATE_ID" \
    FM_FAKE_HARNESS_PID=$$ \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH"
}

prepare_session_start_herdr_secondmate() {
  local name=$1 rec root home fakebin w mate log state id=$SESSION_START_HERDR_SECOND_MATE_ID
  rec=$(new_world "$name")
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  w=${root%/root}
  mate="$w/secondmate-$id"
  log="$w/herdr.log"
  state="$w/herdr.state"
  mkdir -p "$mate/bin" "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'Second mate charter.\n' > "$mate/data/charter.md"
  printf '%s\n' herdr > "$home/config/backend"
  printf '%s\n' pi > "$home/config/secondmate-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  {
    printf 'window=default:p-old\n'
    printf 'kind=secondmate\n'
    printf 'harness=pi\n'
    printf 'home=%s\n' "$mate"
    printf 'backend=herdr\n'
    printf 'herdr_session=default\n'
    printf 'herdr_workspace_id=ws1\n'
    printf 'herdr_tab_id=t-old\n'
    printf 'herdr_pane_id=p-old\n'
  } > "$home/state/$id.meta"
  ln -s "$ROOT/bin" "$root/bin"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_fake_exit0 "$fakebin" pi
  make_fake_herdr_secondmate_recovery "$fakebin"
  : > "$log"
  printf '%s|%s|%s|%s|%s|%s\n' "$root" "$home" "$fakebin" "$mate" "$log" "$state"
}

run_session_start_herdr_secondmate() {
  local root=$1 home=$2 fakebin=$3 mate=$4 log=$5 state=$6
  FM_BACKEND=herdr FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_SECOND_MATE_ID="$SESSION_START_HERDR_SECOND_MATE_ID" \
    FM_FAKE_HARNESS_PID=$$ \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH"
}

# wait_for_network_stage <home> <root> [seconds]
# Block until the deferred network stage this home's session start launched has
# published. Only a TEST does this: the digest itself is required never to wait,
# which is exactly why the sweeps it used to run inline have to be re-asserted
# here instead of straight off the digest's own output.
wait_for_network_stage() {
  local home=$1 root=$2 limit=${3:-30}
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-startup-network.sh" wait "$limit"
}

wait_for_network_wake() {
  local home=$1 limit=${2:-30} waited=0
  while ! grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null
}

network_stage_report() {
  local home=$1 root=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-startup-network.sh" report
}

hash_file_for_test() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

install_pi_turnend_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$root/.pi/extensions/fm-primary-turnend-guard.ts"
}

install_pi_watch_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$root/.pi/extensions/fm-primary-pi-watch.ts"
}

write_pi_watch_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n%s\n' "$version" "$pid" > "$home/state/.pi-watch-extension-loaded"
}

write_pi_turnend_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-turnend-guard.ts")
  printf '%s\n%s\n' "$version" "$pid" > "$home/state/.pi-turnend-extension-loaded"
}

write_pi_loaded_markers() {
  local home=$1 root=$2 pid=$3
  write_pi_watch_loaded_marker "$home" "$root" "$pid"
  write_pi_turnend_loaded_marker "$home" "$root" "$pid"
}

# --- context digest: absent vs empty vs present -----------------------------

test_context_digest_absent_empty_present() {
  local rec root home fakebin out
  rec=$(new_world context-digest)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf '%s\n' '- demo [no-mistakes] - a demo project (added 2026-07-01)' > "$home/data/projects.md"
  : > "$home/data/captain.md"
  # secondmates.md, captain-shared.md, and learnings.md deliberately absent

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  jq -e --arg home "$home" '
    .schema == "fm-secondmate-home-summary.v1"
    and .home == $home
    and (.generated_epoch | type) == "number"
  ' "$home/state/home-summary.json" >/dev/null \
    || fail "a locked session start did not publish the home summary ledger"
  assert_contains "$out" "data/projects.md" "digest did not label the projects.md section"
  assert_contains "$out" "- demo [no-mistakes] - a demo project (added 2026-07-01)" "digest did not print projects.md content"

  assert_contains "$out" "data/captain.md" "digest did not label the captain.md section"
  assert_contains "$out" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)" \
    "digest did not label the shared captain section"

  assert_contains "$out" "data/secondmates.md" "digest did not label the secondmates.md section"
  assert_contains "$out" "data/learnings.md" "digest did not label the learnings.md section"

  # Exactly four context ABSENT markers (secondmates.md, captain-shared.md,
  # learnings.md; backlog.md is covered by its own test) - and the
  # present-but-empty captain.md must NOT print ABSENT.
  absent_count=$(printf '%s\n' "$out" | grep -c '^ABSENT$')
  [ "$absent_count" -eq 4 ] || fail "expected 4 ABSENT markers (secondmates.md, captain-shared.md, learnings.md, backlog.md), got $absent_count: $out"

  cap_section=$(printf '%s\n' "$out" | awk '/^data\/captain\.md$/{flag=1;next}/^data\//{flag=0}flag')
  assert_contains "$cap_section" "(present, empty)" "empty-but-present captain.md was not distinguished from ABSENT"

  pass "context digest distinguishes ABSENT, empty-but-present, and populated files"
}

# --- lock refusal: read-only path --------------------------------------------

test_lock_refusal_read_only_path() {
  local rec root home fakebin holder_pid out status
  rec=$(new_world lock-refusal)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  # A live secondmate meta with a window pointed at nothing real - if the
  # bootstrap sweep's secondmate_sync ran (a MUTATING step), it would try to
  # fast-forward this "home" and/or report a SECONDMATE_SYNC/NUDGE_SECONDMATES
  # line. Absence of any such line is this test's proof that
  # FM_BOOTSTRAP_DETECT_ONLY=1 actually suppressed the mutating sweep.
  mkdir -p "$home/other-secondmate/state"
  fm_write_secondmate_meta "$home/state/sm-x.meta" "$home/other-secondmate" "firstmate:fm-sm-x" alpha
  append_wake "$home/state" signal sm-x "done: surfaced before refusal" || fail "seed wake failed"
  git -C "$root" checkout -q -B fm/read-only-tangle

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"

  status=0
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  expect_code 0 "$status" "fm-session-start.sh must exit 0 even on a lock refusal"
  assert_contains "$out" "READ-ONLY SESSION" "read-only banner missing on lock refusal"
  assert_contains "$out" "another live firstmate session holds the lock" "read-only banner did not surface fm-lock.sh's own error text"
  assert_contains "$out" "Skipping every mutating step" "read-only banner did not explain what was skipped"
  assert_contains "$out" "skipped (read-only session)" "wake-queue section did not report itself skipped"
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "read-only guard did not surface watcher-liveness alarm"
  assert_contains "$out" "queued wakes pending - left untouched because this session lacks verified fleet-lock ownership" "read-only guard did not leave queued wakes untouched without verified lock ownership"
  assert_contains "$out" "TANGLE: primary checkout on feature branch 'fm/read-only-tangle'" "read-only bootstrap did not surface the tangle diagnostic"
  assert_contains "$out" "read-only session must leave restore work" "read-only tangle diagnostic did not explain restore ownership"
  assert_contains "$out" "Stay read-only: do not arm" "read-only next step did not block direct watcher repair"
  assert_not_contains "$out" "drain them with bin/fm-wake-drain.sh" "read-only guard printed a mutating drain instruction"
  assert_not_contains "$out" "After draining queued wakes" "read-only guard printed a drain-then-rearm instruction"
  assert_not_contains "$out" "run bin/fm-watch-arm.sh" "read-only guard printed a mutating watcher-arm instruction"
  assert_not_contains "$out" "git -C $root checkout main" "read-only bootstrap printed a state-changing checkout remediation"

  # Detect-only bootstrap diagnostics still ran (the fakebin's PATH excludes
  # tasks-axi, so bootstrap's own read-only tool-detection line fires
  # deterministically regardless of what is installed on the test host).
  assert_contains "$out" "MISSING: tasks-axi (install:" "detect-only bootstrap diagnostics did not run on the read-only path"

  # The mutating secondmate sweep must NOT have run: no SECONDMATE_SYNC/
  # NUDGE_SECONDMATES line, and the sowed secondmate meta's target dir is
  # untouched (fm-ff-lib would have tried to fast-forward it otherwise).
  assert_not_contains "$out" "SECONDMATE_SYNC" "mutating secondmate sweep ran during a lock refusal"
  assert_not_contains "$out" "NUDGE_SECONDMATES" "mutating secondmate sweep ran during a lock refusal"

  # The rest of the digest (read-only-safe) still completed.
  assert_contains "$out" "FLEET STATE" "fleet-state digest section missing on the read-only path"
  assert_contains "$out" "NEXT STEP" "closing reminder missing on the read-only path"

  pass "a lock refusal prints a loud read-only banner, skips every mutating step, and still completes the digest"
}

test_lock_write_failure_read_only_path() {
  local rec root home fakebin out status
  rec=$(new_world lock-write-failure)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  append_wake "$home/state" signal task-a "done: must remain queued" || fail "seed wake failed"
  chmod 0500 "$home/state"

  status=0
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?
  chmod 0700 "$home/state"

  expect_code 0 "$status" "fm-session-start.sh must exit 0 when lock publication fails"
  assert_contains "$out" "cannot write session lock" "lock publication failure was not surfaced"
  assert_contains "$out" "READ-ONLY SESSION" "lock publication failure did not force a read-only session"
  assert_contains "$out" "FLEET LOCK OWNERSHIP WAS NOT VERIFIED" "lock publication failure was misreported as a live holder"
  assert_contains "$out" "lacks verified fleet-lock ownership" "lock publication failure did not explain why queued wakes remain untouched"
  assert_not_contains "$out" "ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK" "lock publication failure falsely claimed a live lock holder"
  [ -s "$home/state/.wake-queue" ] || fail "lock publication failure allowed the wake queue to mutate"

  pass "session start stays read-only when lock ownership cannot be published"
}

test_trace_context_effective_state_is_frozen_after_lock() {
  local rec root home fakebin out frozen
  rec=$(new_world trace-context-session-state)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  : > "$home/config/trace-context"

  FM_TRACE_CONTEXT=off run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  [ "$(awk '{print $2}' "$home/state/.trace-context-effective")" = off ] \
    || fail "session start must freeze an env-off override over a present config flag"

  rm "$home/config/trace-context"
  FM_TRACE_CONTEXT=on run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  [ "$(awk '{print $2}' "$home/state/.trace-context-effective")" = on ] \
    || fail "a new session start must freeze an env-on override over an absent config flag"
  frozen=$(cat "$home/state/.trace-context-effective")

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  out=$(FM_TRACE_CONTEXT=off run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  assert_contains "$out" "READ-ONLY SESSION" "trace-context refusal fixture did not enter read-only mode"
  [ "$(cat "$home/state/.trace-context-effective")" = "$frozen" ] \
    || fail "a lock-refused session must not mutate the frozen trace-context state"

  pass "locked session start freezes trace context and lock refusal leaves it unchanged"
}

test_session_lock_concurrent_single_winner() {
  local rec root home fakebin ready completed winners pids i pid count
  rec=$(new_world lock-concurrency)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  ready="$home/ready"
  completed="$home/done"
  winners="$home/winners"
  mkdir -p "$ready" "$completed"
  : > "$winners"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ -f "$FM_FAKE_LOCK_STATE/harness-$pid" ]; then
      printf '%s\n' /usr/local/bin/claude
    else
      printf '%s\n' /bin/bash
    fi
    ;;
  *"args="*)
    if [ -f "$FM_FAKE_LOCK_STATE/harness-$pid" ]; then
      printf '%s\n' claude
    else
      printf '%s\n' bash
    fi
    ;;
  *"ppid="*) printf '%s\n' "$FM_FAKE_HARNESS_PID" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  pids=
  i=1
  while [ "$i" -le 40 ]; do
    (
      harness_pid=$(sh -c 'printf "%s\n" "$PPID"')
      : > "$home/state/harness-$harness_pid"
      : > "$ready/$i"
      while [ "$(find "$ready" -type f | wc -l | tr -d ' ')" -lt 40 ]; do
        sleep 0.01
      done
      if FM_HOME="$home" FM_FAKE_LOCK_STATE="$home/state" \
        FM_FAKE_HARNESS_PID="$harness_pid" PATH="$fakebin:$BASE_PATH" \
        "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1; then
        printf '%s\n' "$harness_pid" >> "$winners"
      fi
      : > "$completed/$i"
      while [ "$(find "$completed" -type f | wc -l | tr -d ' ')" -lt 40 ]; do
        sleep 0.01
      done
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  count=$(awk 'NF { count++ } END { print count + 0 }' "$winners")
  [ "$count" -eq 1 ] || fail "concurrent session-lock acquisition produced $count winners"

  pass "concurrent session-lock acquisition admits exactly one live harness"
}

# --- output ordering ----------------------------------------------------------

# The digest is delivered through a harness that truncates from the TAIL, so
# section order decides what a truncated startup loses. The safety preamble
# still leads, live fleet identity now outranks curated memory, and the
# read-once contract arrives before the payload it governs.
test_output_ordering_diagnostics_lead() {
  local rec root home fakebin out lock_line boot_line wake_line read_once_line
  local context_line fleet_line next_line inventory_line missing_line
  rec=$(new_world ordering)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # Force a MISSING diagnostic line so the bootstrap section is non-trivial.
  rm -f "$fakebin/node"

  printf 'window=fm-sess:w1\nkind=ship\n' > "$home/state/task-a.meta"
  printf 'Captain memory that may be truncated away safely.\n' > "$home/data/captain.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  lock_line=$(printf '%s\n' "$out" | grep -n '^LOCK$' | head -1 | cut -d: -f1)
  boot_line=$(printf '%s\n' "$out" | grep -n '^BOOTSTRAP$' | head -1 | cut -d: -f1)
  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  read_once_line=$(printf '%s\n' "$out" | grep -n '^READ-ONCE CONTRACT$' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  fleet_line=$(printf '%s\n' "$out" | grep -n '^FLEET STATE$' | head -1 | cut -d: -f1)
  next_line=$(printf '%s\n' "$out" | grep -n '^NEXT STEP$' | head -1 | cut -d: -f1)
  inventory_line=$(printf '%s\n' "$out" | grep -n '^--- task-a ---$' | head -1 | cut -d: -f1)

  if [ -z "$lock_line" ] || [ -z "$boot_line" ] || [ -z "$wake_line" ] \
    || [ -z "$read_once_line" ] || [ -z "$context_line" ] || [ -z "$fleet_line" ] \
    || [ -z "$next_line" ] || [ -z "$inventory_line" ]; then
    fail "one or more section headers missing from digest: $out"
  fi

  # The safety preamble's order is unchanged: mutation authority, then
  # diagnostics, then this turn's work queue, before anything bulky is read.
  [ "$lock_line" -lt "$boot_line" ] || fail "LOCK did not precede BOOTSTRAP"
  [ "$boot_line" -lt "$wake_line" ] || fail "BOOTSTRAP did not precede WAKE QUEUE"
  [ "$wake_line" -lt "$read_once_line" ] || fail "WAKE QUEUE did not precede the read-once contract"

  [ "$read_once_line" -lt "$fleet_line" ] || fail "the read-once contract did not precede FLEET STATE"
  [ "$fleet_line" -lt "$context_line" ] || fail "FLEET STATE did not precede CONTEXT"
  [ "$context_line" -lt "$next_line" ] || fail "CONTEXT did not precede NEXT STEP"

  # The live-task inventory - the record recovery actually depends on - must sit
  # ahead of the curated memory a truncated tail is allowed to take.
  [ "$inventory_line" -lt "$context_line" ] \
    || fail "the live-task inventory was buried behind the curated memory files"
  assert_contains "$out" "Captain memory that may be truncated away safely." \
    "the ordering fixture did not actually print a memory file"

  missing_line=$(printf '%s\n' "$out" | grep -n 'MISSING: node' | head -1 | cut -d: -f1)
  [ -n "$missing_line" ] || fail "MISSING diagnostic did not appear at all"
  [ "$missing_line" -lt "$fleet_line" ] || fail "actionable MISSING diagnostic was buried after the bulk fleet-state digest"

  pass "digest sections are ordered safety-preamble first, live fleet state before curated memory"
}

# The contract has to survive tail truncation and stay honest once it precedes
# the sections it governs, so it carries the truncated-stage escape itself.
test_read_once_contract_is_stated_once_before_its_subject() {
  local rec root home fakebin out contract_count
  rec=$(new_world read-once)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "Do NOT re-read any of them after reading this digest" \
    "the read-once contract lost its core instruction"
  assert_contains "$out" "STARTUP TRUNCATED banner named the stage that would have printed it" \
    "the read-once contract does not void itself for a stage that never ran"
  assert_contains "$out" "The READ-ONCE CONTRACT" \
    "the closing reminder does not point back at the contract"

  contract_count=$(printf '%s\n' "$out" | grep -c 'Do NOT re-read any of them')
  [ "$contract_count" -eq 1 ] \
    || fail "the read-once contract is stated $contract_count times instead of once: $out"

  pass "the read-once contract is stated once, ahead of the sources it governs"
}

test_herdr_backend_diagnostics_follow_real_session_start() {
  local mode rec root home fakebin mask out
  for mode in configured autodetected; do
    rec=$(new_world "herdr-$mode")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    rm -f "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" herdr jq
    printf '%s\n' manual > "$home/config/backlog-backend"
    mask="$home/mask-tmux.bash"
    cat > "$mask" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = tmux ]; then
    return 1
  fi
  builtin command "$@"
}
SH
    if [ "$mode" = configured ]; then
      printf '%s\n' herdr > "$home/config/backend"
      out=$(TMUX='' HERDR_ENV='' BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_not_contains "$out" "NOTICE: auto-detected herdr runtime" \
        "an explicit Herdr home should not be reported as auto-detected"
    else
      out=$(TMUX='' HERDR_ENV=1 BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_contains "$out" "NOTICE: auto-detected herdr runtime (HERDR_ENV=1)" \
        "session start did not preserve the Herdr runtime auto-detection fallback"
    fi
    assert_contains "$out" "SESSION START - $home" "the real session-start path did not run in the throwaway home"
    assert_not_contains "$out" "MISSING: tmux" "Herdr session start falsely required masked tmux"
    assert_not_contains "$out" "MISSING: herdr" "Herdr session start missed its available session CLI"
    assert_not_contains "$out" "MISSING: jq" "Herdr session start missed its available JSON dependency"
    assert_not_contains "$out" "MISSING: treehouse" "Herdr session start missed its available worktree provider"
  done
  pass "session start: configured and auto-detected Herdr homes never require tmux"
}

# --- status tail bounding -----------------------------------------------------

test_status_tail_bounding() {
  local rec root home fakebin out
  rec=$(new_world status-tail)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live"

  printf 'window=fm-sess:live\nkind=ship\n' > "$home/state/task-a.meta"
  printf 'working: step 1\nworking: step 2\nworking: step 3\nworking: step 4\nworking: step 5\nworking: step 6\nworking: step 7\n' \
    > "$home/state/task-a.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "default status tail missing the most recent line"
  assert_contains "$out" "working: step 3" "default status tail (5 lines) missing an expected recent line"
  assert_not_contains "$out" "working: step 1" "default status tail (5 lines) leaked an older line"
  assert_contains "$out" "$home/state/task-a.status" "digest did not print the full status log path for a deeper read"
  assert_contains "$out" "a bounded tail of every state/*.status" "read-once contract does not distinguish bounded status tails"

  out=$(FM_SESSION_START_STATUS_TAIL=2 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "FM_SESSION_START_STATUS_TAIL=2 tail missing the most recent line"
  assert_not_contains "$out" "working: step 5" "FM_SESSION_START_STATUS_TAIL=2 did not bound the tail to 2 lines"

  pass "status tail is bounded to the configured line count, with the full log path always printed"
}

# A crewmate writes its own status lines, so nothing upstream bounds their
# length: an observed one ran 865 characters. The tail is a wake-EVENT view
# whose full log path is printed beside it, so a long line is cut, marked, and
# left recoverable rather than allowed to scale the digest with fleet load.
test_status_tail_line_cap() {
  local rec root home fakebin out lede longest capped tail_section
  rec=$(new_world status-line-cap)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live"

  lede='needs-decision: [key=cap] pick the rendering strategy'
  printf 'window=fm-sess:live\nkind=ship\n' > "$home/state/task-cap.meta"
  {
    printf '%s' "$lede"
    awk 'BEGIN { while (i++ < 400) printf " padding" }'
    printf '\n'
    printf 'working: short line kept whole\n'
  } > "$home/state/task-cap.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "$lede" "the cap discarded the lede that carries the state word and decision key"
  assert_contains "$out" " [truncated]" "an over-long status line was not marked as truncated"
  assert_contains "$out" "working: short line kept whole" "the cap mangled a status line already under it"
  assert_contains "$out" "each capped at 220 characters" "the status tail header does not disclose its per-line cap"
  assert_contains "$out" "$home/state/task-cap.status" "a capped tail dropped the full log path that recovers the rest"

  # Nothing the tail emits may exceed the cap, and the padded line really was
  # long enough to exercise it.
  tail_section=$(printf '%s\n' "$out" | awk '/^status tail \(/ { flag = 1; next } flag && /^$/ { flag = 0 } flag')
  longest=$(printf '%s\n' "$tail_section" | awk '{ if (length($0) > max) max = length($0) } END { print max + 0 }')
  [ "$longest" -le 220 ] || fail "a status tail line ran $longest characters past the 220-character cap"
  capped=$(printf '%s\n' "$tail_section" | grep -c ' \[truncated\]$')
  [ "$capped" -eq 1 ] || fail "expected exactly one truncated tail line, got $capped: $tail_section"

  pass "status tail lines are capped with a truncation marker while the full log stays reachable"
}

test_orphan_status_logs_are_printed() {
  local rec root home fakebin out matched_count orphan_count
  rec=$(new_world orphan-status)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf 'kind=ship\n' > "$home/state/task-a.meta"
  printf 'matched: surfaced once\n' > "$home/state/task-a.status"
  printf 'orphan: step 1\norphan: step 2\norphan: step 3\norphan: step 4\norphan: step 5\norphan: step 6\n' \
    > "$home/state/task-orphan.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "Orphan status logs (state/*.status without matching .meta)" "digest did not label orphan status logs"
  assert_contains "$out" "--- task-orphan ---" "digest did not print the orphan status id"
  assert_contains "$out" "orphan: step 6" "orphan status tail missing the newest line"
  assert_not_contains "$out" "orphan: step 1" "orphan status tail was not bounded"
  assert_contains "$out" "$home/state/task-orphan.status" "orphan status tail did not print the full log path"

  matched_count=$(printf '%s\n' "$out" | grep -F -c 'matched: surfaced once')
  orphan_count=$(printf '%s\n' "$out" | grep -F -c 'orphan: step 6')
  [ "$matched_count" -eq 1 ] || fail "matched status log was printed $matched_count times: $out"
  [ "$orphan_count" -eq 1 ] || fail "orphan status log was printed $orphan_count times: $out"

  pass "orphan status logs are printed once with bounded tails"
}

# --- session-start secondmate recovery boundary -----------------------------

test_session_start_relaunches_missing_pi_secondmate() {
  local rec root home fakebin mate log spawned out first_calls second_calls
  rec=$(prepare_session_start_secondmate secondmate-missing-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing)

  # The relaunch now runs off the blocking path, so the digest's own liveness
  # read may legitimately still show the pre-relaunch endpoint. What must NOT
  # happen is silence: the section names the relaunch as either done or not yet
  # confirmed.
  assert_contains "$out" "NETWORK CHECKS" "the digest lost its deferred network-check section"
  assert_contains "$out" "dead-secondmate relaunch" \
    "the digest never accounted for the dead-secondmate relaunch"

  wait_for_network_stage "$home" "$root" \
    || fail "the deferred network stage never published: $(network_stage_report "$home" "$root")"

  assert_not_contains "$(network_stage_report "$home" "$root")" "SECONDMATE_LIVENESS:" \
    "successful missing-window recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "new-window" "the deferred stage did not relaunch the missing Pi secondmate"
  assert_not_contains "$(cat "$log")" "kill-window" "the deferred stage tried to kill an already-absent window"
  assert_grep 'harness=pi' "$home/state/$SESSION_START_SECOND_MATE_ID.meta" \
    "the real respawn path did not preserve the Pi harness: $(cat "$home/state/$SESSION_START_SECOND_MATE_ID.meta")"

  first_calls=$(grep -c 'new-window' "$log" || true)
  rm -f "$home/state/.lock"
  run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing >/dev/null
  wait_for_network_stage "$home" "$root" \
    || fail "the second pass's deferred network stage never published"
  second_calls=$(grep -c 'new-window' "$log" || true)
  [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ] \
    || fail "a second session-start pass duplicated the relaunched Pi secondmate: $(cat "$log")"
  pass "session start: an absent recorded tmux window relaunches its Pi secondmate exactly once, off the blocking path"
}

# The relaunch is the sharpest deferral: it mutates the very endpoint record the
# digest printed moments earlier. Silence would leave that stale record looking
# authoritative, so the deferred pass reports it whether or not verbose facts are
# on, and the report says the digest's records are now behind.
test_deferred_relaunch_is_always_reported() {
  local rec root home fakebin mate log spawned report
  rec=$(prepare_session_start_secondmate secondmate-relaunch-reported)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing >/dev/null
  wait_for_network_stage "$home" "$root" || fail "the deferred network stage never published"

  report=$(network_stage_report "$home" "$root")
  assert_contains "$report" "secondmate $SESSION_START_SECOND_MATE_ID relaunched" \
    "a relaunch performed after the digest was composed went unreported"
  assert_contains "$report" "re-read any record" \
    "the report did not tell the reader the digest's records are now behind"
  pass "session start: a deferred relaunch is always reported, so the digest's stale endpoint record cannot stand"
}

test_session_start_preserves_ambiguous_pi_process() {
  local rec root home fakebin mate log spawned out
  rec=$(prepare_session_start_secondmate secondmate-ambiguous-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" ambiguous)
  wait_for_network_stage "$home" "$root" || fail "the deferred network stage never published"

  assert_contains "$(network_stage_report "$home" "$root")" \
    "SECONDMATE_LIVENESS: secondmate $SESSION_START_SECOND_MATE_ID: skipped: existing endpoint has ambiguous agent process (backend=tmux)" \
    "session start did not distinguish an existing Pi-shaped process from a missing window"
  [ ! -s "$log" ] || fail "session start touched an ambiguous existing Pi process: $(cat "$log")"
  assert_contains "$out" "endpoint: alive (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later fleet read should still see the ambiguous endpoint"
  pass "session start: an existing ambiguous Pi process prevents duplicate recovery"
}

test_session_start_preserves_transiently_unreadable_tmux() {
  local rec root home fakebin mate log spawned out
  rec=$(prepare_session_start_secondmate secondmate-unreadable-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" unreadable)
  wait_for_network_stage "$home" "$root" || fail "the deferred network stage never published"

  assert_contains "$(network_stage_report "$home" "$root")" \
    "SECONDMATE_LIVENESS: secondmate $SESSION_START_SECOND_MATE_ID: skipped: endpoint probe unreadable (backend=tmux)" \
    "session start did not distinguish transient unreadability from absence"
  [ ! -s "$log" ] || fail "session start touched a transiently unreadable target: $(cat "$log")"
  assert_contains "$out" "endpoint: dead (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later cheap presence read should preserve the visible offline symptom"
  pass "session start: transient tmux unreadability never licenses a relaunch"
}

test_session_start_preserves_proven_bare_shell_recovery() {
  local rec root home fakebin mate log spawned out
  rec=$(prepare_session_start_secondmate secondmate-bare-shell)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" shell >/dev/null
  wait_for_network_stage "$home" "$root" || fail "the deferred network stage never published"

  out=$(network_stage_report "$home" "$root")
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful bare-shell recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-$SESSION_START_SECOND_MATE_ID" \
    "the proven bare-shell path did not remove its existing dead endpoint"
  assert_contains "$(cat "$log")" "new-window" "the proven bare-shell path did not relaunch"
  pass "session start: the proven bare-shell recovery path remains intact"
}

test_session_start_relaunches_herdr_husk_secondmate() {
  local rec root home fakebin mate log state out
  rec=$(prepare_session_start_herdr_secondmate secondmate-herdr-husk)
  IFS='|' read -r root home fakebin mate log state <<EOF
$rec
EOF

  run_session_start_herdr_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$state" >/dev/null
  wait_for_network_stage "$home" "$root" || fail "the deferred network stage never published"

  out=$(network_stage_report "$home" "$root")
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful Herdr husk recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "pane close p-old" "session start did not close the confirmed Herdr husk"
  assert_contains "$(cat "$log")" "tab create" "session start did not relaunch the Herdr secondmate"
  assert_grep 'herdr_pane_id=p-new' "$home/state/$SESSION_START_HERDR_SECOND_MATE_ID.meta" \
    "the real respawn path did not record the replacement Herdr pane"
  pass "session start: a confirmed Herdr husk is closed and relaunched"
}

# --- endpoint liveness: tmux and herdr, live and dead ------------------------

test_endpoint_liveness_tmux() {
  local rec root home fakebin out
  rec=$(new_world liveness-tmux)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live-window"

  printf 'window=fm-sess:live-window\nkind=ship\n' > "$home/state/task-live.meta"
  printf 'window=fm-sess:dead-window\nkind=ship\n' > "$home/state/task-dead.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "endpoint: alive (backend=tmux window=fm-sess:live-window)" "live tmux endpoint not reported alive"
  assert_contains "$out" "endpoint: dead (backend=tmux window=fm-sess:dead-window)" "dead tmux endpoint not reported dead"

  pass "tmux endpoint liveness is reported per task: alive for a live window, dead for a gone one"
}

test_endpoint_liveness_herdr() {
  local rec root home fakebin out
  rec=$(new_world liveness-herdr)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr "$fakebin" "p-live"

  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-live.meta"
  printf 'window=sess:p-dead\nkind=ship\nbackend=herdr\n' > "$home/state/task-dead.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "endpoint: alive (backend=herdr window=sess:p-live)" "live herdr endpoint not reported alive"
  assert_contains "$out" "endpoint: dead (backend=herdr window=sess:p-dead)" "dead herdr endpoint not reported dead"

  pass "herdr endpoint liveness is reported per task: alive for a live pane, dead for a gone one"
}

# --- composition: real scripts run, not reimplemented ------------------------

test_composition_invokes_real_scripts() {
  local rec root home fakebin out
  rec=$(new_world composition)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  rm -f "$fakebin/node"

  printf 'needs-decision: pick a library\n' > "$home/state/task-z.status"
  append_wake "$home/state" signal task-z.status "needs-decision: pick a library"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # fm-lock.sh's own exact success text.
  assert_contains "$out" "lock acquired: harness pid" "fm-lock.sh's real output did not appear (composition, not reimplementation)"
  # fm-bootstrap.sh's own exact MISSING-tool line format.
  assert_contains "$out" "MISSING: node (install:" "fm-bootstrap.sh's real detect line did not appear verbatim"
  # fm-wake-drain.sh's real drained record (raw tab-separated queue line).
  assert_contains "$out" "$(printf 'signal\ttask-z.status\tneeds-decision: pick a library')" "fm-wake-drain.sh's real drained record did not appear"
  assert_contains "$out" "wake annotation: latest wake-EVENT observed at drain, not current state: task-z.status: needs-decision: pick a library" "fm-session-start.sh did not preserve the drain's separate annotation line"

  pass "fm-session-start.sh composes the real fm-lock.sh, fm-bootstrap.sh, and fm-wake-drain.sh output verbatim"
}

test_branch_outcome_replay_respects_captain_barrier_and_lease_sweep() {
  local rec root home fakebin out
  rec=$(new_world branch-recovery)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi

  # A crash window the locked start must preserve: the supervision branch
  # stored a leading routine row and a captain row that never reached Pi, plus one lease whose
  # supervising process died and one still held by a live process.
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-a --verdict routine --summary 'worker recovered automatically' >/dev/null \
    || fail "could not seed the unread routine branch outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-b --verdict captain --summary 'PR https://example.com/pr/b checks green' >/dev/null \
    || fail "could not seed the unread branch outcome"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-live --actor branch \
    || fail "could not seed the live lease"

  out=$(run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):" \
    "locked start did not replay the leading routine branch outcome"
  assert_contains "$out" "worker recovered automatically" "replayed routine outcome lost its content"
  assert_not_contains "$out" "https://example.com/pr/b" "locked start crossed the captain delivery barrier"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" \
    "https://example.com/pr/b" "locked start marked the unrendered captain outcome read"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1 ] || fail "locked start advanced past the captain row"
  [ ! -e "$home/state/.lease-task-dead" ] || fail "locked start left a provably dead lease in place"
  [ -e "$home/state/.lease-task-live" ] || fail "locked start swept a live lease"

  # Routine replay is one-shot, while the captain row remains held for Pi's
  # sequence-keyed visible-entry reconciliation.
  out=$(run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  case "$out" in
    *"BRANCH OUTCOMES"*) fail "second start re-presented already-replayed branch outcomes" ;;
  esac
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" \
    "https://example.com/pr/b" "second start consumed the captain row without a Pi entry"
  pass "locked Pi session start replays leading routine outcomes, preserves the captain barrier, and sweeps only dead leases"
}

test_non_pi_session_start_leaves_branch_state_untouched() {
  local rec root home fakebin out
  rec=$(new_world non-pi-branch-recovery)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-b --verdict captain --summary 'unread Pi branch outcome' >/dev/null \
    || fail "could not seed the non-Pi unread branch outcome"
  rm -f "$home/state/.branch-outcomes-cursor"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  case "$out" in
    *"BRANCH OUTCOMES"*|*"unread Pi branch outcome"*) fail "non-Pi session replayed Pi branch outcomes" ;;
  esac
  [ -e "$home/state/.lease-task-dead" ] || fail "non-Pi session swept a Pi branch lease"
  [ ! -e "$home/state/.branch-outcomes-cursor" ] || fail "non-Pi session marked a Pi branch outcome read"
  pass "non-Pi session start neither sweeps nor replays Pi branch state"
}

# --- deferred network stage -------------------------------------------------

# install_slow_gh <fakebin> <seconds>: one external-network call the digest used
# to make directly. Making it pathologically slow is how a test stands in for an
# unreachable host without touching one: if any part of the blocking path still
# waits on the network, the digest cannot finish before this does.
install_slow_gh() {
  local fakebin=$1 seconds=$2 finished_marker=${3:-}
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ]; then
  sleep $seconds
  [ -z '$finished_marker' ] || : > '$finished_marker'
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# The locked startup scan may need the same expensive current-state read that a
# busy validation makes slow. It belongs to the detached startup worker, so the
# digest must finish while that read is still outstanding; the answer then has to
# create the ordinary durable inactive-outcome wake rather than disappear
# off-path. The slow read is held open by this case rather than by a fixed sleep,
# so "the digest did not wait for it" is decided by what had happened when the
# digest returned and not by how fast the host was.
test_inactive_reconcile_never_blocks_the_digest() {
  local rec root home fakebin world worktree crew_state calls out waited=0
  local release_gate read_finished
  rec=$(new_world inactive-reconcile-deferred)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  world=${root%/root}
  worktree="$world/child-worktree"
  crew_state="$world/slow-crew-state.sh"
  calls="$world/no-mistakes-state.calls"
  ln -s "$ROOT/bin" "$root/bin"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_git_init_commit "$worktree"

  release_gate="$world/slow-state-read.release"
  read_finished="$world/slow-state-read.finished"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
if [ "${1:-} ${2:-}" = 'axi status' ]; then
  if [ "${FM_BOOTSTRAP_NETWORK:-}" = only ]; then
    printf '%s\n' 'deferred' >> "${FM_FAKE_NM_CALLS:?}"
  else
    printf '%s\n' 'blocking' >> "${FM_FAKE_NM_CALLS:?}"
  fi
  # Stay outstanding until the case releases this read. A caller that waits for
  # it therefore waits indefinitely rather than for a fixed interval a loaded
  # host could out-run. The tick bound only stops a broken case hanging forever.
  ticks=0
  while [ ! -e "${FM_FAKE_NM_RELEASE:?}" ] && [ "$ticks" -lt 300 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  : > "${FM_FAKE_NM_READ_FINISHED:?}"
  printf '%s\n' 'slow validation state answered'
fi
exit 0
SH
  cat > "$crew_state" <<'SH'
#!/usr/bin/env bash
set -u
no-mistakes axi status >/dev/null
printf '%s\n' 'state: done · source: run-step · passed'
SH
  chmod +x "$fakebin/no-mistakes" "$crew_state"

  fm_write_meta "$home/state/slow-child.meta" \
    'window=firstmate:fm-slow-child' "worktree=$worktree" 'project=firstmate' \
    'harness=pi' 'kind=scout' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=slow-child.1'
  printf '%s\n' 'working: validating' > "$home/state/slow-child.status"
  : > "$home/state/slow-child.turn-ended"
  touch -t 202001010000 "$home/state/slow-child.meta" \
    "$home/state/slow-child.status" "$home/state/slow-child.turn-ended"

  out=$(FM_BACKEND=tmux FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    FM_FAKE_NM_CALLS="$calls" FM_FAKE_NM_RELEASE="$release_gate" \
    FM_FAKE_NM_READ_FINISHED="$read_finished" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_INACTIVE_CREW_STATE_BIN="$crew_state" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "SESSION START" "the digest did not complete"
  assert_absent "$read_finished" \
    "the digest waited for inactive reconciliation's still-unreleased state read"
  [ "$(grep -c '^blocking$' "$calls" 2>/dev/null || true)" -eq 0 ] \
    || fail "the digest called the slow state reader on its blocking path"
  : > "$release_gate"

  while ! grep -Fq $'\tcheck\tinactive-outcome:' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt 150 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'check	inactive-outcome:' "$home/state/.wake-queue" \
    "the deferred scan's terminal finding never reached the durable wake queue (calls=$(cat "$calls" 2>/dev/null), report=$(network_stage_report "$home" "$root" 2>/dev/null), queue=$(cat "$home/state/.wake-queue" 2>/dev/null))"
  [ "$(grep -c '^deferred$' "$calls" 2>/dev/null || true)" -eq 1 ] \
    || fail "the deferred scan did not make exactly one slow state read"
  pass "session start: inactive reconciliation runs after the digest and retains its durable wake"
}

# The headline guarantee: an unreachable host delays a reported CHECK, never the
# startup. The fake host hangs for 12s; the digest must be done long before that,
# must say so rather than implying the checks passed, and the sweeps must still
# run and land afterwards.
test_unreachable_network_never_blocks_the_digest() {
  local rec root home fakebin mate log spawned network_finished out started elapsed
  rec=$(prepare_session_start_secondmate secondmate-slow-network)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF
  network_finished="${root%/root}/network-finished"
  install_slow_gh "$fakebin" 12 "$network_finished"

  started=$(date +%s)
  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing)
  elapsed=$(( $(date +%s) - started ))

  [ ! -e "$network_finished" ] \
    || fail "the digest waited for the 12s unreachable-host probe instead of returning from local state (${elapsed}s)"
  assert_contains "$out" "SESSION START" "the digest did not complete"
  assert_contains "$out" "IN PROGRESS - the deferred network checks have not finished yet." \
    "the digest did not disclose that its network checks were still running"
  assert_contains "$out" "NOT yet confirmed: GitHub authentication, dead-secondmate relaunch" \
    "the digest did not name the checks it has not confirmed"
  assert_not_contains "$out" "NEEDS_GH_AUTH" \
    "the digest reported a GitHub-auth verdict it could not yet have"

  # ... and the work itself still happens, off the blocking path.
  wait_for_network_stage "$home" "$root" 60 \
    || fail "the deferred stage never finished: $(network_stage_report "$home" "$root")"
  assert_contains "$(network_stage_report "$home" "$root")" "NEEDS_GH_AUTH" \
    "the deferred stage lost the GitHub-auth verdict it was deferring"
  assert_contains "$(cat "$log")" "new-window" \
    "the deferred stage lost the dead-secondmate relaunch"
  pass "session start: an unreachable host delays a reported check, not the digest"
}

# A result the digest could not print must still reach the agent by itself. The
# opposite half of the handshake - a printed result never ALSO queuing a wake -
# is asserted deterministically in tests/fm-startup-network.test.sh, where the
# claim can be set up directly instead of raced against digest composition.
test_deferred_result_reaches_the_agent_when_the_digest_cannot_print_it() {
  local rec root home fakebin mate log spawned queue
  rec=$(prepare_session_start_secondmate secondmate-wake-once)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF
  install_slow_gh "$fakebin" 8
  queue="$home/state/.wake-queue"

  run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing >/dev/null
  wait_for_network_stage "$home" "$root" 60 || fail "the deferred stage never finished"
  wait_for_network_wake "$home" 60 || fail "the deferred stage never settled wake delivery"
  assert_grep 'check	startup-network' "$queue" \
    "a result the digest could not print never reached the agent: $(cat "$queue" 2>/dev/null)"
  pass "session start: a deferred result the digest outran still reaches the agent as a wake"
}

# A read-only session has no lock, so it neither owns the mutating sweeps nor has
# any action a GitHub-auth verdict would gate. It must say that plainly instead of
# quietly dropping the checks.
test_read_only_session_declares_skipped_network_checks() {
  local rec root home fakebin out
  rec=$(new_world network-read-only)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"-p 999999"*) printf 'claude\n'; exit 0 ;;
  *"comm="*|*"args="*) printf 'bash\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "READ-ONLY SESSION" "the read-only fixture did not actually refuse the lock"
  assert_contains "$out" "skipped (read-only session) - GitHub authentication" \
    "a read-only session did not declare its skipped network checks"
  assert_absent "$home/state/.startup-network.status" \
    "a read-only session started the deferred stage it has no authority for"
  pass "session start: a read-only session declares its skipped network checks rather than dropping them"
}

# The compatibility verdict costs three tasks-axi subprocesses and one session
# start needs it twice. The digest must pay for it once.
test_tasks_axi_compatibility_is_probed_once() {
  local rec root home fakebin log probes
  rec=$(new_world tasks-axi-once)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  log="$home/tasks-axi.log"
  printf '# Backlog\n\n## In flight\n\n## Queued\n' > "$home/data/backlog.md"

  FM_FAKE_TASKS_AXI_LOG="$log" run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null

  probes=$(grep -c -- '--version' "$log" || true)
  [ "$probes" -eq 1 ] \
    || fail "tasks-axi was version-probed $probes times in one session start: $(cat "$log")"
  probes=$(grep -c -- 'update --help' "$log" || true)
  [ "$probes" -eq 1 ] \
    || fail "tasks-axi update --help ran $probes times in one session start: $(cat "$log")"
  assert_grep 'ready --file' "$log" "the backlog listing never ran, so the verdict was not actually reused"
  pass "session start: the tasks-axi compatibility verdict is computed once and reused"
}

# --- fleet-state digest: compact backlog rendering --------------------------

# A backlog whose Done section, held row, blocked row, and plain queued rows can
# each be told apart in the rendered digest. DONE-ROW-LINE and the *-BODY-LINE
# markers exist so a leak is unmistakable.
write_long_body_backlog() {
  local path=$1 i=1
  cat > "$path" <<'EOF'
# Backlog

## In flight
- [ ] compact-startup - Compact startup digest (repo: firstmate) (kind: ship) (since 2026-07-15) (hold: captain choice pending) (hold-kind: captain)
  OVERSIZED-BODY-LINE current startup leaks task note bodies into the session digest.
  Another long body line that should not be printed after the fix.

## Queued
- [ ] blocked-followup - Follow compact startup blocked-by: compact-startup - waits for implementation (repo: firstmate) (kind: scout) (since 2026-07-15)
  QUEUED-BODY-LINE this is another long multiline note.
- [ ] held-queued - Held queued work (repo: firstmate) (kind: ship) (hold: captain choice pending) (hold-kind: captain)
EOF
  while [ "$i" -le 25 ]; do
    printf -- '- [ ] plain-%s - Plain queued item %s (repo: firstmate) (kind: ship)\n' "$i" "$i" >> "$path"
    i=$((i + 1))
  done
  cat >> "$path" <<'EOF'

## Done
- [x] landed-earlier - DONE-ROW-LINE already landed and torn down (repo: firstmate) (kind: ship)
EOF
}

test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata() {
  local rec root home fakebin out log
  rec=$(new_world backlog-compact-tasks-axi)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  mkdir -p "$home/projects/firstmate"
  printf 'window=fm-sess:compact\nworktree=%s\nproject=firstmate\nkind=ship\n' "$home/projects/firstmate" \
    > "$home/state/compact-startup.meta"
  log="$home/tasks-axi.log"

  out=$(FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TASKS_AXI_READY=3 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown in full; ready queued bounded to 20; task bodies omitted)" \
    "compatible tasks-axi backend did not render the compact backlog listing"
  assert_contains "$out" "tasks[1]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:" \
    "tasks-axi compact listing omitted the expected structured field header"
  assert_contains "$out" "compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending" \
    "tasks-axi compact listing omitted in-flight identity, state, or hold metadata"
  assert_contains "$out" "held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending" \
    "tasks-axi compact listing omitted a held row or its hold metadata"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "tasks-axi compact listing omitted blocked-by metadata"
  assert_contains "$out" "ready-3,queued,ship,firstmate,Ready item 3" \
    "tasks-axi compact listing omitted a dispatchable queued row inside the bound"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "tasks-axi compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "tasks-axi compact digest leaked a queued task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "tasks-axi compact digest listed a done row at startup"
  assert_contains "$out" "--- compact-startup ---" "in-flight meta identity disappeared from startup recovery digest"
  assert_contains "$out" "worktree=$home/projects/firstmate" "in-flight recovery worktree identity disappeared from startup digest"
  assert_contains "$out" "Full task bodies remain available on demand: tasks-axi show <id> --full" \
    "compact digest omitted the full-body lookup pointer"
  assert_contains "$out" "ready_public_followups: 0 delivery-ready obligations" \
    "the composed listing dropped a real signal from the dispatchable set"
  # One section pointer, not one repeated help block per composed group.
  assert_not_contains "$out" "help[1]:" \
    "the composed listing repeated tasks-axi's per-group help block"

  # The fake refuses a body field, an unfiltered listing, and a done listing, so
  # a clean render already proves those were never asked for; pin the group
  # filters the listing is built from.
  assert_grep "--state in_flight --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the in-flight group"
  assert_grep "--state held --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the held group"
  assert_grep "--state queued --blocked --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the blocked queued group"
  assert_grep "ready --file $home/data/backlog.md" "$log" \
    "session start did not ask tasks-axi for the dispatchable queued set"

  pass "compatible tasks-axi backlog rendering drops done rows and keeps every in-flight, held, and blocked row"
}

# The bound may only ever cut the dispatchable-now listing, and whatever it cuts
# must be disclosed with an exact count and the command that shows the rest.
test_backlog_queued_bound_discloses_its_remainder() {
  local rec root home fakebin out
  rec=$(new_world backlog-queued-bound)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(FM_FAKE_TASKS_AXI_READY=7 FM_SESSION_START_QUEUED_LIMIT=3 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "ready-3,queued,ship,firstmate,Ready item 3" \
    "the queued bound dropped a row inside its own limit"
  assert_not_contains "$out" "ready-4,queued" "the queued bound did not actually bound the ready listing"
  assert_contains "$out" "(shown 3 of 7 ready queued item(s))" \
    "the bounded queued listing did not report what it showed"
  assert_contains "$out" "(4 more queued - tasks-axi ready --file $home/data/backlog.md)" \
    "the bounded queued listing did not disclose an exact remainder and how to see it"

  # The bound is for dispatchable work only: held and blocked rows stay whole.
  assert_contains "$out" "held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending" \
    "the queued bound swallowed a held row"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "the queued bound swallowed a blocked row"
  assert_contains "$out" "compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending" \
    "the queued bound swallowed an in-flight row"

  pass "the startup backlog bound cuts only dispatchable queued rows and discloses the remainder exactly"
}

test_backlog_compact_manual_backend_skips_indented_bodies() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-manual)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(FM_SESSION_START_QUEUED_LIMIT=4 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (manual backend; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to 4; indented task bodies omitted)" \
    "manual backend did not use compact title-line rendering"
  assert_contains "$out" "## In flight" "manual compact rendering omitted the in-flight section heading"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "manual compact rendering omitted the in-flight title line"
  assert_contains "$out" "(hold: captain choice pending) (hold-kind: captain)" \
    "manual compact rendering omitted hold metadata"
  assert_contains "$out" "blocked-by: compact-startup - waits for implementation" \
    "manual compact rendering omitted blocker metadata"
  assert_contains "$out" "- [ ] held-queued - Held queued work" \
    "manual compact rendering dropped a held queued title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "manual compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "manual compact digest leaked a queued task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "manual compact digest listed a done row at startup"
  assert_not_contains "$out" "## Done" "manual compact digest printed the done heading it never fills"
  assert_contains "$out" "- [ ] plain-4 - Plain queued item 4" \
    "manual compact rendering dropped a queued title line inside its bound"
  assert_not_contains "$out" "- [ ] plain-5 - Plain queued item 5" \
    "manual compact rendering did not bound its plain queued listing"
  assert_contains "$out" "(shown 1 in-flight, 2 held or blocked queued, 4 of 25 other queued title line(s); 1 done row(s) omitted)" \
    "manual compact rendering did not report its bound accounting"
  assert_contains "$out" "(21 more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)" \
    "manual compact rendering did not disclose an exact queued remainder"
  assert_contains "$out" "or data/backlog.md" "manual compact digest omitted the data/backlog.md full-body pointer"

  pass "manual backlog rendering drops done rows, keeps every held or blocked title line, and bounds the rest"
}

test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-unavailable)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi unavailable or incompatible; done rows omitted;" \
    "unavailable tasks-axi did not fall back to compact title-line rendering"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "unavailable tasks-axi fallback omitted a backlog title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "unavailable tasks-axi fallback leaked an in-flight task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "unavailable tasks-axi fallback listed a done row at startup"

  pass "unavailable or incompatible tasks-axi falls back to compact manual backlog rendering"
}

# --- runtime bound -----------------------------------------------------------
#
# The digest runs on a session-open hook that blocks session initialization, so
# it must have a guaranteed upper bound. These cases drive REAL processes that
# really hang, and assert the outcome the hook depends on: whatever the digest
# already emitted survives, the agent is told exactly what it never saw, and
# the command still exits 0 so the session can open.

# make_hanging_tool <fakebin> <name>: a real, unkillable-by-timeout-alone
# subprocess of the digest. `git` is the honest choice - the bootstrap stage
# shells out to it - and it also proves the bound reaches a GRANDCHILD, because
# bootstrap runs it inside its own command substitution.
make_hanging_tool() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
trap '' TERM
sleep 600
SH
  chmod +x "$fakebin/$name"
}

make_term_escalating_timeout() {
  local fakebin=$1
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env perl
use strict;
use warnings;
(shift @ARGV) eq '-k' or exit 64;
my $kill_after = shift @ARGV;
my $seconds = shift @ARGV;
my $pid = fork;
defined $pid or die "fork failed";
if (!$pid) {
  setpgrp(0, 0);
  exec @ARGV;
}
local $SIG{ALRM} = sub {
  kill 'TERM', -$pid;
  select undef, undef, undef, $kill_after;
  kill 'KILL', -$pid;
  waitpid $pid, 0;
  exit 137;
};
alarm $seconds;
waitpid $pid, 0;
alarm 0;
exit($? >> 8);
SH
  chmod +x "$fakebin/timeout"
}

test_runtime_bound_truncates_loudly_and_exits_zero() {
  local rec root home fakebin out status=0 stray mechanism
  rec=$(new_world runtime-bound)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_hanging_tool "$fakebin" git

  mechanism=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash bash -c '. "$1"; fm_timeout_mechanism' \
    _ "$ROOT/bin/fm-timeout-lib.sh")
  [ "$mechanism" = bash ] || fail "the forced pure-Bash timeout fixture selected '$mechanism'"

  out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_SESSION_START_TIMEOUT=3 FM_STARTUP_NETWORK_TIMEOUT=2 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?

  expect_code 0 "$status" "a truncated session start must still exit 0 so the session can open"
  assert_contains "$out" "SESSION START - $home" "the truncated digest lost the output it had already produced"
  assert_contains "$out" "LOCK" "the truncated digest lost a stage that had completed"
  assert_contains "$out" "STARTUP TRUNCATED - SESSION START HIT ITS" "a truncated session start did not say so"
  assert_contains "$out" "RUNTIME BOUND" "the truncation banner did not name the bound it hit"
  assert_contains "$out" 'stopped during the "bootstrap" stage' "the truncation banner did not name the incomplete stage"
  assert_contains "$out" "RECONCILE these stages" "the truncation banner did not tell the agent what to reconcile"
  assert_contains "$out" "wake-queue supervision-instructions read-once fleet-state network-checks context next-step" \
    "the truncation banner did not list every stage that never ran"
  assert_not_contains "$out" "NEXT STEP" "a truncated digest claimed to have reached its closing reminder"
  assert_absent "$home/state/.session-start-complete" \
    "a truncated startup recorded itself as complete"

  # The bound must reach the whole process group: a hung grandchild that
  # outlives the digest would keep holding whatever the digest was waiting on.
  # There are now TWO bounds, deliberately independent - the digest's, and the
  # deferred network stage's own - because a truncated digest must not kill work
  # it was never waiting for. So the guarantee asserted here is the one that
  # actually matters: once BOTH deadlines have passed, nothing hung is left.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STARTUP_NETWORK_TIMEOUT=2 \
    "$ROOT/bin/fm-startup-network.sh" wait 30 >/dev/null || true
  sleep 1
  stray=$(pgrep -f "$fakebin/git" 2>/dev/null | wc -l | tr -d ' ')
  [ "$stray" -eq 0 ] || fail "the runtime bound left $stray hung subprocess(es) behind"

  status=0
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash bash -c \
    '. "$1"; fm_run_timed 2 bash -c "exit 137"' _ "$ROOT/bin/fm-timeout-lib.sh" || status=$?
  expect_code 137 "$status" "pure-Bash natural command exit 137"

  pass "the pure-Bash watchdog bounds session start, kills its hung grandchild, and emits the truncation contract"
}

test_portable_timeout_escalates_term_resistant_process() {
  local fakebin="$TMP_ROOT/portable-kill-after" driver status=0
  mkdir -p "$fakebin"
  make_term_escalating_timeout "$fakebin"
  driver="$TMP_ROOT/portable-kill-after-driver.sh"
  cat > "$driver" <<'SH'
#!/usr/bin/env bash
. "$1"
shift
fm_run_timed 1 "$@"
SH
  chmod +x "$driver"

  perl -e '
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV }
    local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid $pid, 0; exit 99 };
    alarm 5;
    waitpid $pid, 0;
    exit($? >> 8);
  ' env PATH="$fakebin:$BASE_PATH" "$driver" "$ROOT/bin/fm-timeout-lib.sh" \
    perl -e '$SIG{TERM} = "IGNORE"; sleep 600' || status=$?

  expect_code 124 "$status" "portable timeout TERM-resistant escalation"
  status=0
  env PATH="$fakebin:$BASE_PATH" "$driver" "$ROOT/bin/fm-timeout-lib.sh" \
    bash -c 'exit 137' || status=$?
  expect_code 137 "$status" "natural command exit 137"
  pass "the portable timeout path force-kills a command that ignores TERM"
}

test_runtime_bound_leaves_a_healthy_digest_untouched() {
  local rec root home fakebin out
  rec=$(new_world runtime-bound-healthy)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # The banner line itself, not the phrase: the read-once contract names the
  # banner as the condition that voids it, and that mention is not a banner.
  assert_not_contains "$out" "STARTUP TRUNCATED - SESSION START HIT ITS" \
    "a digest that finished in time reported itself truncated"
  assert_contains "$out" "NEXT STEP" "a digest that finished in time lost its closing reminder"
  assert_absent "${TMPDIR:-/tmp}/fm-session-start-stage" "the stage breadcrumb leaked a fixed-name file"

  pass "a session start inside its budget prints no truncation banner"
}

test_runtime_bound_leaves_harness_ancestry_headroom() {
  local rec root home fakebin nest out
  rec=$(new_world runtime-bound-ancestry)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  # Only ONE pid in the whole tree is the harness, and it sits at the very top.
  # fm-session-lock-lib.sh walks a BOUNDED sixteen parents to find it, and the
  # runtime bound spends some of that budget on its own wrapper processes, so
  # this pins that the budget still reaches a realistically deep session.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then printf '%s\n' /usr/local/bin/claude
    else printf '%s\n' /bin/bash; fi
    ;;
  *"args="*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then printf '%s\n' claude
    else printf '%s\n' bash; fi
    ;;
  *"ppid="*) /bin/ps -o ppid= -p "$pid" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Each level forks rather than execs, so the counter really is process depth.
  nest="$home/nest.sh"
  cat > "$nest" <<'SH'
#!/usr/bin/env bash
set -u
levels=$1
shift
if [ "$levels" -gt 0 ]; then
  bash "$0" $((levels - 1)) "$@"
  exit $?
fi
exec "$@"
SH
  chmod +x "$nest"

  # shellcheck disable=SC2016 # $$ must expand in the launched shell, not here.
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    bash -c 'export FM_FAKE_HARNESS_PID=$$; exec "$1" 8 "$2"' _ "$nest" "$SESSION_START")

  assert_contains "$out" "lock acquired: harness pid" \
    "the runtime bound's wrapper processes pushed the harness out of the bounded ancestry walk"
  assert_not_contains "$out" "READ-ONLY SESSION" \
    "a session start eight shells below its harness was wrongly refused the lock"

  pass "the runtime bound leaves enough ancestry headroom for a deeply nested session to take the lock"
}

# --- context re-emit (--reemit) ----------------------------------------------

test_reemit_skips_startup_sweeps_but_keeps_the_wake_drain() {
  local rec root home fakebin network_report reemit sequence generation
  rec=$(new_world reemit)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  mkdir -p "$home/other-secondmate/state"
  fm_write_secondmate_meta "$home/state/sm-r.meta" "$home/other-secondmate" "firstmate:fm-sm-r" alpha
  append_wake "$home/state" signal task-r "done: queued after startup" || fail "seed wake failed"

  # A full startup reconciles the secondmate sweep and reports it.
  FM_FAKE_HARNESS_PID=$$ run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  wait_for_network_stage "$home" "$root" \
    || fail "the full startup fixture's deferred network stage never published"
  network_report=$(network_stage_report "$home" "$root")
  assert_contains "$network_report" "SECONDMATE_LIVENESS" \
    "the full startup fixture did not exercise a mutating sweep"

  append_wake "$home/state" signal task-r "done: queued after the re-emit too" || fail "seed second wake failed"
  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)

  assert_contains "$reemit" "SESSION START (CONTEXT RE-EMIT) - $home" "--reemit did not label itself"
  assert_not_contains "$reemit" "SECONDMATE_LIVENESS" "--reemit repeated a mutating sweep startup already ran"
  assert_contains "$reemit" "done: queued after the re-emit too" "--reemit did not drain the wake queue"
  [ -s "$home/state/.wake-queue" ] || fail "--reemit removed the wake before its handling acknowledgement"
  sequence=$(printf '%s\n' "$reemit" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' | tail -1)
  generation=$(printf '%s\n' "$reemit" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "--reemit omitted the generation-bound wake acknowledgement"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation" || fail "--reemit wake acknowledgement failed"
  [ ! -s "$home/state/.wake-queue" ] || fail "--reemit acknowledgement left queued wakes behind"
  assert_contains "$reemit" "CONTEXT" "--reemit dropped the context digest"
  assert_contains "$reemit" "FLEET STATE" "--reemit dropped the fleet-state digest"
  assert_contains "$reemit" "NEXT STEP" "--reemit dropped the closing reminder"

  pass "--reemit reprints the digest without repeating startup's mutating sweeps and still drains queued wakes"
}

test_agents_baseline_stays_at_true_start_and_reemits_on_every_drifted_pi_compact() {
  local rec root home fakebin startup compact_equal compact_first compact_second clear_out resume_out reset_out baseline baseline_after expected_hash refresh_line bootstrap_line
  rec=$(new_world agents-refresh)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi
  cat > "$root/AGENTS.md" <<'EOF'
FIRSTMATE_TEST_INSTRUCTION=original
Keep this original instruction.
EOF

  startup=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup)
  assert_contains "$startup" "SESSION START - $home" "true startup did not run the full digest"
  assert_present "$home/state/.session-start-agents-baseline" "true startup did not record an AGENTS baseline"
  baseline=$(cat "$home/state/.session-start-agents-baseline")
  expected_hash=$(hash_file_for_test "$root/AGENTS.md")
  [ "$(printf '%s\n' "$baseline" | sed -n '2p')" = "$expected_hash" ] \
    || fail "true startup baseline did not record the original AGENTS hash: $baseline"

  compact_equal=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_not_contains "$compact_equal" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "an unchanged AGENTS file was unnecessarily re-emitted"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a no-drift compact rewrote the true-start baseline"

  cat > "$root/AGENTS.md" <<'EOF'
FIRSTMATE_TEST_INSTRUCTION=updated
The complete updated instruction must survive every stale rebuild.
EOF
  resume_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source resume)
  assert_not_contains "$resume_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "a context-preserving continuation emitted a replacement contract"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a context-preserving continuation rebased the true-start baseline"

  compact_first=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_first" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "a drifted Pi compact did not emit the replacement instructions"
  assert_contains "$compact_first" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a drifted Pi compact did not emit the complete current AGENTS content"
  refresh_line=$(printf '%s\n' "$compact_first" | grep -n '^CURRENT AGENTS.md - INSTRUCTION REFRESH$' | head -1 | cut -d: -f1)
  bootstrap_line=$(printf '%s\n' "$compact_first" | grep -n '^BOOTSTRAP$' | head -1 | cut -d: -f1)
  [ -n "$refresh_line" ] && [ -n "$bootstrap_line" ] && [ "$refresh_line" -lt "$bootstrap_line" ] \
    || fail "replacement instructions were not emitted before the bulky digest"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a drifted compact rebased the original-session baseline"

  compact_second=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_second" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a second drifted compact suppressed the required replacement instructions"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a repeated compact rebased the original-session baseline"

  clear_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source clear)
  assert_not_contains "$clear_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "a Pi clear, which creates a fresh runtime, unnecessarily emitted a replacement contract"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a clear rebuild rebased the original-session baseline"

  reset_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source reset)
  assert_not_contains "$reset_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "an unrecognized reset source emitted a replacement contract"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "reset rebased the original-session baseline"

  rm -f "$home/state/.session-start-agents-baseline"
  compact_first=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_first" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a missing baseline did not trigger first-post-fix replacement instructions"
  assert_absent "$home/state/.session-start-agents-baseline" \
    "a rebuild fabricated a baseline instead of preserving true-start-only ownership"

  printf 'wrong-session\n%s\n' "$(hash_file_for_test "$root/AGENTS.md")" > "$home/state/.session-start-agents-baseline"
  compact_first=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_first" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a wrong-session baseline did not trigger replacement instructions"
  baseline_after=$(cat "$home/state/.session-start-agents-baseline")
  [ "$baseline_after" = "wrong-session
$(hash_file_for_test "$root/AGENTS.md")" ] \
    || fail "a wrong-session baseline was rewritten during a rebuild"

  pass "true-start AGENTS baselines stay immutable while every drifted Pi compact re-emits the current contract"
}

test_read_only_pi_compact_refreshes_against_its_own_session_identity() {
  local rec root home fakebin holder_pid out baseline_before completion_before
  rec=$(new_world agents-refresh-read-only)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi
  printf '%s\n' 'READ_ONLY_AGENTS=current' > "$root/AGENTS.md"
  FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup >/dev/null

  sleep 300 &
  holder_pid=$!
  printf '%s\n%s\n' "$holder_pid" "$(hash_file_for_test "$root/AGENTS.md")" \
    > "$home/state/.session-start-agents-baseline"
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  baseline_before=$(cat "$home/state/.session-start-agents-baseline")
  completion_before=$(cat "$home/state/.session-start-complete")

  out=$(FM_FAKE_HARNESS=pi FM_FAKE_LIVE_HOLDER_PID="$holder_pid" \
    run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "READ-ONLY SESSION" "competing live lock owner did not force read-only mode"
  assert_contains "$out" "READ_ONLY_AGENTS=current" \
    "read-only compact trusted another session's equal baseline"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline_before" ] \
    || fail "read-only compact mutated the competing session's baseline"
  [ "$(cat "$home/state/.session-start-complete")" = "$completion_before" ] \
    || fail "read-only compact mutated startup completion state"

  pass "read-only Pi compact refreshes against the rebuilding session identity without mutation"
}

test_codex_unreachable_reset_sources_do_not_claim_instruction_refresh() {
  local rec root home fakebin startup baseline clear_out compact_out
  rec=$(new_world codex-instruction-refresh)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" codex
  printf '%s\n' 'CODEX_TEST_INSTRUCTION=original' > "$root/AGENTS.md"

  startup=$(run_named_harness_session_start codex "$home" "$root" "$fakebin:$BASE_PATH" --source startup)
  assert_contains "$startup" "primary harness: codex" "codex fixture did not select the codex run tier"
  baseline=$(cat "$home/state/.session-start-agents-baseline")
  printf '%s\n' 'CODEX_TEST_INSTRUCTION=updated' > "$root/AGENTS.md"

  clear_out=$(run_named_harness_session_start codex "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source clear)
  compact_out=$(run_named_harness_session_start codex "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_not_contains "$clear_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "Codex clear claimed an instruction-refresh channel unavailable to the tracked transport"
  assert_not_contains "$compact_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "Codex compact claimed an instruction-refresh channel unavailable to the tracked transport"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "an unsupported Codex rebuild rewrote the true-start baseline"

  pass "Codex reset sources do not claim an unavailable instruction-refresh channel"
}

test_agents_baseline_requires_sha256_and_successful_completion() {
  local rec root home fakebin compact_out
  rec=$(new_world agents-baseline-failures)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi
  printf '%s\n' 'AGENTS_SHA_TEST=original' > "$root/AGENTS.md"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/shasum"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/sha256sum"
  chmod +x "$fakebin/shasum" "$fakebin/sha256sum"

  FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup >/dev/null
  assert_absent "$home/state/.session-start-agents-baseline" \
    "startup recorded a non-SHA-256 instruction baseline when both SHA-256 tools failed"
  printf '%s\n' 'AGENTS_SHA_TEST=updated' > "$root/AGENTS.md"
  compact_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_out" "AGENTS_SHA_TEST=updated" \
    "a missing SHA-256 baseline did not conservatively refresh a supported rebuild"

  rm -f "$fakebin/shasum" "$fakebin/sha256sum" "$home/state/.session-start-complete"
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
case "\${*: -1}" in
  "$home/state/.session-start-complete") exit 1 ;;
esac
exec /bin/mv "\$@"
SH
  chmod +x "$fakebin/mv"
  FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup >/dev/null
  assert_absent "$home/state/.session-start-complete" \
    "startup published completion despite the atomic completion write failure"
  assert_absent "$home/state/.session-start-agents-baseline" \
    "startup recorded an instruction baseline after completion publication failed"

  pass "instruction baselines require SHA-256 and successful startup completion"
}

test_reemit_keeps_repair_ownership_with_the_lock_holder() {
  local rec root home fakebin reemit readonly_out holder_pid
  rec=$(new_world reemit-tangle)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  git -C "$root" checkout -q -B fm/reemit-tangle

  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)

  # A re-emit skips the sweeps because it ALREADY ran them, not because it lacks
  # the lock, so it must still own repair rather than deferring to a lock holder.
  assert_contains "$reemit" "restore the primary with: git -C $root checkout main" \
    "--reemit disowned a repair it is entitled to perform"
  assert_not_contains "$reemit" "must leave restore work to the session holding the fleet lock" \
    "--reemit misreported itself as an unlocked read-only session"

  rm -f "$home/state/.lock"
  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  readonly_out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$readonly_out" "READ-ONLY SESSION" \
    "--reemit assumed lock ownership instead of re-verifying it"
  assert_contains "$readonly_out" "must leave restore work to the session holding the fleet lock" \
    "a lock-refused --reemit still claimed repair ownership"

  pass "--reemit re-verifies lock ownership and keeps repair ownership with whoever holds it"
}

# --- fleet-state digest: no in-flight tasks ----------------------------------

test_fleet_digest_empty_fleet() {
  local rec root home fakebin out
  rec=$(new_world empty-fleet)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "(none)" "empty fleet did not report (none) for in-flight tasks"
  assert_contains "$out" "absent" "empty fleet's AFK section did not report absent"

  pass "an empty fleet reports (none) for in-flight tasks and an absent AFK flag"
}

test_next_step_sources_x_mode_cadence() {
  local rec root home fakebin out
  rec=$(new_world next-step-x)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_fake_exit0 "$fakebin" curl jq
  printf 'FMX_PAIRING_TOKEN=tok-next-step\n' > "$home/.env"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "FMX: X mode on" "bootstrap did not activate X mode"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude" "supervision block missing"
  assert_contains "$out" "- X mode: active" "supervision block did not mention X cadence"
  assert_contains "$out" "Follow the supervision operating instructions block above" "next step did not point back to the emitted supervision block"

  pass "session start emits X-mode cadence guidance in the harness supervision block"
}

test_next_step_afk_delegates_to_daemon() {
  local rec root home fakebin out
  rec=$(new_world next-step-afk)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  : > "$home/state/.afk"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "away-mode supervision is active" "AFK digest did not report away mode"
  assert_contains "$out" "Away mode is active" "next step did not switch to AFK guidance"
  assert_contains "$out" "daemon owns the watcher" "next step did not delegate watcher ownership to the daemon"
  assert_contains "$out" "- Away mode: active" "supervision block did not include active AFK state"
  assert_not_contains "$out" "  bin/fm-watch-arm.sh" "AFK next step still told the agent to arm the watcher directly"

  pass "next step delegates watcher ownership to the AFK daemon"
}

test_supervision_block_exactly_one_and_pi_diagnostic() {
  local rec root home fakebin out block_count wake_line sup_line context_line
  rec=$(new_world pi-supervision-block)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  block_count=$(printf '%s\n' "$out" | grep -c '^SUPERVISION OPERATING INSTRUCTIONS - primary harness:')
  [ "$block_count" -eq 1 ] || fail "expected exactly one supervision block, got $block_count"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi" "pi supervision block missing"
  assert_contains "$out" "Mode: Pi extension background wake." "pi snippet missing from session start"
  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi extension load diagnostic missing"
  assert_contains "$out" "restart plain pi so $root/.pi/extensions/fm-primary-turnend-guard.ts and $root/.pi/extensions/fm-primary-pi-watch.ts auto-load" "pi extension load diagnostic omits the turn-end guard extension"

  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  sup_line=$(printf '%s\n' "$out" | grep -n '^SUPERVISION OPERATING INSTRUCTIONS' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  [ "$wake_line" -lt "$sup_line" ] || fail "supervision block did not follow wake queue"
  [ "$sup_line" -lt "$context_line" ] || fail "supervision block did not precede context"

  pass "session start emits exactly one detected harness block and reports Pi extension load state"
}

test_pi_signed_primary_uses_pi_extensions_without_identity_normalization() {
  local rec root home fakebin out
  rec=$(new_world pi-signed-supervision-block)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi-signed

  out=$(FM_FAKE_HARNESS=pi-signed run_session_start "$home" "$root" "$fakebin:$BASE_PATH" pi-signed)

  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi-signed" \
    "session start normalized a pi-signed primary to pi"
  assert_contains "$out" "Mode: Pi extension background wake." \
    "pi-signed primary did not reuse Pi's supervision protocol"
  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" \
    "pi-signed primary skipped Pi extension validation"
  assert_contains "$out" "restart pi-signed so $root/.pi/extensions/fm-primary-turnend-guard.ts and $root/.pi/extensions/fm-primary-pi-watch.ts auto-load" \
    "pi-signed extension diagnostic did not preserve the executable identity"

  pass "session start preserves pi-signed primary identity while applying Pi extension guarantees"
}

test_pi_diagnostic_rejects_stale_loaded_marker() {
  local rec root home fakebin out marker holder_pid
  rec=$(new_world pi-stale-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  printf 'stale-extension-version\n%s\n' "$holder_pid" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"
  touch -t 203001010000 "$marker" 2>/dev/null || touch "$marker"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a stale loaded marker"

  pass "session start rejects stale Pi loaded markers"
}

test_pi_diagnostic_accepts_prelock_loaded_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-prelock-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_loaded_markers "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_not_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic rejected a current pre-lock loaded marker"

  pass "session start accepts current Pi markers written before lock acquisition"
}

test_pi_diagnostic_rejects_missing_turnend_guard_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-missing-turnend-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_watch_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a session without the turn-end guard extension"

  pass "session start rejects Pi sessions missing the turn-end guard marker"
}

test_pi_diagnostic_rejects_previous_session_loaded_marker() {
  local rec root home fakebin out marker version holder_pid
  rec=$(new_world pi-previous-session-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n999999\n' "$version" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a marker from a previous Pi process"

  pass "session start rejects Pi loaded markers from previous sessions"
}

test_context_digest_absent_empty_present
test_lock_refusal_read_only_path
test_lock_write_failure_read_only_path
test_trace_context_effective_state_is_frozen_after_lock
test_session_lock_concurrent_single_winner
test_output_ordering_diagnostics_lead
test_read_once_contract_is_stated_once_before_its_subject
test_herdr_backend_diagnostics_follow_real_session_start
test_session_start_relaunches_missing_pi_secondmate
test_deferred_relaunch_is_always_reported
test_inactive_reconcile_never_blocks_the_digest
test_unreachable_network_never_blocks_the_digest
test_deferred_result_reaches_the_agent_when_the_digest_cannot_print_it
test_read_only_session_declares_skipped_network_checks
test_tasks_axi_compatibility_is_probed_once
test_session_start_preserves_ambiguous_pi_process
test_session_start_preserves_transiently_unreadable_tmux
test_session_start_preserves_proven_bare_shell_recovery
test_session_start_relaunches_herdr_husk_secondmate
test_status_tail_bounding
test_status_tail_line_cap
test_orphan_status_logs_are_printed
test_endpoint_liveness_tmux
test_endpoint_liveness_herdr
test_composition_invokes_real_scripts
test_branch_outcome_replay_respects_captain_barrier_and_lease_sweep
test_non_pi_session_start_leaves_branch_state_untouched
test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata
test_backlog_queued_bound_discloses_its_remainder
test_backlog_compact_manual_backend_skips_indented_bodies
test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback
test_fleet_digest_empty_fleet
test_next_step_sources_x_mode_cadence
test_next_step_afk_delegates_to_daemon
test_supervision_block_exactly_one_and_pi_diagnostic
test_pi_signed_primary_uses_pi_extensions_without_identity_normalization
test_pi_diagnostic_rejects_stale_loaded_marker
test_pi_diagnostic_accepts_prelock_loaded_marker
test_pi_diagnostic_rejects_missing_turnend_guard_marker
test_pi_diagnostic_rejects_previous_session_loaded_marker
test_runtime_bound_truncates_loudly_and_exits_zero
test_portable_timeout_escalates_term_resistant_process
test_runtime_bound_leaves_a_healthy_digest_untouched
test_runtime_bound_leaves_harness_ancestry_headroom
test_reemit_skips_startup_sweeps_but_keeps_the_wake_drain
test_agents_baseline_stays_at_true_start_and_reemits_on_every_drifted_pi_compact
test_read_only_pi_compact_refreshes_against_its_own_session_identity
test_codex_unreachable_reset_sources_do_not_claim_instruction_refresh
test_agents_baseline_requires_sha256_and_successful_completion
test_reemit_keeps_repair_ownership_with_the_lock_holder

echo "# fm-session-start.test.sh: all assertions passed"
