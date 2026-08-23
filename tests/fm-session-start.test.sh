#!/usr/bin/env bash
# tests/fm-session-start.test.sh - behavior tests for bin/fm-session-start.sh,
# the single command that collapses AGENTS.md sections 3 (bootstrap) and 5
# (recovery) into one ordered digest.
#
# Coverage:
#   - absent-file markers vs empty-but-present files in the context digest
#   - the lock-refusal read-only path: banner leads, every mutating step is
#     skipped (including bootstrap's five mutating sweeps, verified by their
#     ABSENCE), the digest still completes
#   - output section ordering: diagnostics/banners lead, bulk file dumps follow
#   - context-aware next-step guidance for read-only, AFK, X mode, and normal
#     watcher ownership
#   - on-demand status pointer default, FM_SESSION_START_STATUS_TAIL tail
#     restore and bounding, and the switch-predicate oracle plus mutation kills
#   - orphan status logs whose task meta has already disappeared
#   - contradictions across backlog, metadata, status, endpoint, and PR reality
#   - the weekly quota-utilization block in the fleet digest
#   - per-task endpoint-liveness lines for a live and a dead recorded target,
#     tmux and herdr both
#   - composition: the script invokes the real fm-lock.sh/fm-bootstrap.sh/
#     fm-wake-drain.sh (their real, distinctive output appears verbatim), it
#     does not reimplement their logic
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/treehouse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/treehouse-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
# An operator's documented rollback export (FM_SESSION_START_STATUS_TAIL=5)
# would false-red every default-mode assertion below. Dropped here rather than
# with `env -u` in run_session_start, which would also strip the per-call
# FM_SESSION_START_STATUS_TAIL=<n> prefixes the tail cases depend on.
unset FM_SESSION_START_STATUS_TAIL
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
NODE_BIN=$(command -v node) || fail "test needs node"
JQ_BIN=$(command -v jq) || fail "test needs jq"
TMP_ROOT=$(fm_test_tmproot fm-session-start-tests)
fm_test_hide_host_commands "$TMP_ROOT" node tasks-axi
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
  fm_fake_exit0 "$fakebin" tmux chrome-devtools-axi
  # The secondmate recovery cases drive the real fm-spawn.sh, which builds and
  # validates its model-run telemetry intake with node and jq, so exit-0 stubs
  # are not enough. Wrappers, not symlinks: a later fm_fake_exit0 for the same
  # tool would write through a symlink into the real binary.
  printf '#!/usr/bin/env bash\nexec '"'"'%s'"'"' "$@"\n' "$NODE_BIN" > "$fakebin/node"
  printf '#!/usr/bin/env bash\nexec '"'"'%s'"'"' "$@"\n' "$JQ_BIN" > "$fakebin/jq"
  chmod +x "$fakebin/node" "$fakebin/jq"
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.45
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
  fm_test_write_active_treehouse_fake "$fakebin"
  fm_fake_quota_axi "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' manual > "${fakebin%/*}/home-placeholder" 2>/dev/null || true
}

make_fake_tasks_axi_compact() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TASKS_AXI_LOG:-}
[ -n "$log" ] && printf '%s\n' "$*" >> "$log"
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
  list)
    case "$*" in
      *'--fields '*'body'*|*'--fields='*'body'*)
        printf '%s\n' 'unexpected body field requested' >&2
        exit 9
        ;;
    esac
    case "$*" in *'--limit 80'*) : ;; *) printf '%s\n' 'missing compact limit' >&2; exit 9 ;; esac
    case "$*" in *'--file '*) : ;; *) printf '%s\n' 'missing explicit backlog file' >&2; exit 9 ;; esac
    cat <<'OUT'
count: 2
tasks[2]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:
  compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending
  blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"
help[2]:
  - Run `tasks-axi show <id> --full` for full notes on a task
  - Run `tasks-axi ready` to see unblocked queued work
OUT
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
}

# make_fake_ps_claude <fakebin>: harness_pid()/holder_alive() (fm-lock.sh) walk
# `ps` output looking for a harness command name; this fake reports EVERY
# queried pid as a live `claude` harness, so the very first ancestry check
# (this test process's own pid) matches and lock acquisition succeeds
# deterministically. Mirrors fm-grok-harness.test.sh's fake ps.
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
case "$*" in
  *"comm="*) printf '/usr/local/bin/%s\n' "$harness"; exit 0 ;;
  *"args="*) printf '%s\n' "$harness"; exit 0 ;;
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

make_fake_tmux_set() {
  local fakebin=$1 live_targets=$2
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    target=""
    prev=""
    for arg in "$@"; do
      [ "$prev" = -t ] && target=$arg
      prev=$arg
    done
    case ":${FM_FAKE_LIVE_TARGETS:-}:" in
      *":$target:"*) printf '%%1\n'; exit 0 ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$live_targets" > "$fakebin/.live-targets"
}

make_fake_contradiction_gh_axi() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.1.29'; exit 0 ;;
  api)
    case "${2:-}" in
      /repos/example/repo/pulls/7)
        printf '%s\n' 'api_response:' '  body: "OPEN:MERGEABLE"' '  truncated: false'
        ;;
      /repos/example/repo/pulls/8)
        printf '%s\n' 'api_response:' '  body: "OPEN:CONFLICTING"' '  truncated: false'
        ;;
      /repos/example/repo/pulls/9)
        printf '%s\n' 'api_response:' '  body: "MERGED:UNKNOWN"' '  truncated: false'
        ;;
      /repos/example/repo/pulls/10)
        printf '%s\n' 'api_response:' '  body: "OPEN:MERGEABLE"' '  truncated: false'
        ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
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
#
# Drop the ambient Herdr endpoint identity for the same reason: the fixtures
# record their own herdr_session/workspace/tab/pane, and every Herdr container
# operation falls back to ${HERDR_SESSION:-default}, so a suite launched from a
# real Herdr pane would assert against the launcher's session instead of the
# fixture's. HERDR_ENV stays inheritable because individual cases set it as a
# deliberate per-case input for runtime autodetection.
run_session_start() {
  local home=$1 root=$2 path=$3 pi_harness=${4:-}
  if [ -n "$pi_harness" ]; then
    env -u CLAUDECODE -u GROK_AGENT \
      -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
      PI_CODING_AGENT=true FM_PI_HARNESS="$pi_harness" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  else
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  fi
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
  make_fake_tmux_secondmate_recovery "$fakebin"
  : > "$log"
  printf '%s|%s|%s|%s|%s|%s\n' "$root" "$home" "$fakebin" "$mate" "$log" "$spawned"
}

run_session_start_secondmate() {
  local root=$1 home=$2 fakebin=$3 mate=$4 log=$5 spawned=$6 mode=$7
  TMUX='' FM_BACKEND=tmux FM_FAKE_TMUX_MODE="$mode" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_SPAWNED="$spawned" FM_FAKE_SECOND_MATE_HOME="$mate" \
    FM_FAKE_SECOND_MATE_ID="$SESSION_START_SECOND_MATE_ID" \
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
  make_fake_herdr_secondmate_recovery "$fakebin"
  : > "$log"
  printf '%s|%s|%s|%s|%s|%s\n' "$root" "$home" "$fakebin" "$mate" "$log" "$state"
}

run_session_start_herdr_secondmate() {
  local root=$1 home=$2 fakebin=$3 mate=$4 log=$5 state=$6
  FM_BACKEND=herdr FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_SECOND_MATE_ID="$SESSION_START_HERDR_SECOND_MATE_ID" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH"
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
  printf '#!/usr/bin/env bash\n# Unbound checks are not armed.\n' > "$home/state/unbound.check.sh"
  chmod 0700 "$home/state/unbound.check.sh"

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
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH" 2> "$home/session.err") || status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  expect_code 0 "$status" "fm-session-start.sh must exit 0 even on a lock refusal"
  assert_not_contains "$(cat "$home/session.err")" "command not found" \
    "standing-check validation loaded without its PR-validation dependency"
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
  assert_not_contains "$out" "Standing checks without task metadata:" \
    "read-only inventory included an unarmed check"
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

test_output_ordering_diagnostics_lead() {
  local rec root home fakebin out lock_line boot_line wake_line context_line fleet_line next_line
  rec=$(new_world ordering)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # Force a MISSING diagnostic line so the bootstrap section is non-trivial.
  rm -f "$fakebin/node"

  printf 'window=fm-sess:w1\nkind=ship\n' > "$home/state/task-a.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  lock_line=$(printf '%s\n' "$out" | grep -n '^LOCK$' | head -1 | cut -d: -f1)
  boot_line=$(printf '%s\n' "$out" | grep -n '^BOOTSTRAP$' | head -1 | cut -d: -f1)
  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  fleet_line=$(printf '%s\n' "$out" | grep -n '^FLEET STATE$' | head -1 | cut -d: -f1)
  next_line=$(printf '%s\n' "$out" | grep -n '^NEXT STEP$' | head -1 | cut -d: -f1)

  if [ -z "$lock_line" ] || [ -z "$boot_line" ] || [ -z "$wake_line" ] || [ -z "$context_line" ] || [ -z "$fleet_line" ] || [ -z "$next_line" ]; then
    fail "one or more section headers missing from digest: $out"
  fi

  [ "$lock_line" -lt "$boot_line" ] || fail "LOCK did not precede BOOTSTRAP"
  [ "$boot_line" -lt "$wake_line" ] || fail "BOOTSTRAP did not precede WAKE QUEUE"
  [ "$wake_line" -lt "$context_line" ] || fail "WAKE QUEUE did not precede CONTEXT"
  [ "$context_line" -lt "$fleet_line" ] || fail "CONTEXT did not precede FLEET STATE"
  [ "$fleet_line" -lt "$next_line" ] || fail "FLEET STATE did not precede NEXT STEP"

  missing_line=$(printf '%s\n' "$out" | grep -n 'MISSING: node' | head -1 | cut -d: -f1)
  [ -n "$missing_line" ] || fail "MISSING diagnostic did not appear at all"
  [ "$missing_line" -lt "$fleet_line" ] || fail "actionable MISSING diagnostic was buried after the bulk fleet-state digest"

  pass "digest sections are ordered diagnostics-first, bulk-context-last"
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
  printf 'kind=ship\n' > "$home/state/task-b.meta"
  printf 'working: step 1\nworking: step 2\nworking: step 3\nworking: step 4\nworking: step 5\nworking: step 6\nworking: step 7\n' \
    > "$home/state/task-a.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_not_contains "$out" "working: step 7" "default digest projected status log content into startup load"
  assert_not_contains "$out" "status tail (last" "default digest still rendered a status tail"
  assert_contains "$out" "status: wake-event log on demand (full log: $home/state/task-a.status); current state: bin/fm-crew-state.sh task-a" \
    "default digest missing the on-demand status pointer line"
  assert_contains "$out" "status: (no status file yet: $home/state/task-b.status); current state: bin/fm-crew-state.sh task-b" \
    "metadata-backed task without a status file is missing the current-state pointer"
  assert_contains "$out" "Do NOT bulk-read state/*.status now either: each task's status line above" \
    "closing reminder does not describe the on-demand status pointer"
  assert_not_contains "$out" "state/*.status now - they were just" "closing reminder still describes status logs as fully printed"

  out=$(FM_SESSION_START_STATUS_TAIL=5 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "FM_SESSION_START_STATUS_TAIL=5 tail missing the most recent line"
  assert_contains "$out" "working: step 3" "FM_SESSION_START_STATUS_TAIL=5 tail missing an expected recent line"
  assert_not_contains "$out" "working: step 1" "FM_SESSION_START_STATUS_TAIL=5 leaked an older line"
  assert_contains "$out" "$home/state/task-a.status" "tail rendering did not print the full status log path for a deeper read"
  assert_contains "$out" "Do NOT bulk-read state/*.status now either: their bounded tails were just" \
    "tail-mode closing reminder does not describe bounded status tails"

  out=$(FM_SESSION_START_STATUS_TAIL=2 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "FM_SESSION_START_STATUS_TAIL=2 tail missing the most recent line"
  assert_not_contains "$out" "working: step 5" "FM_SESSION_START_STATUS_TAIL=2 did not bound the tail to 2 lines"

  pass "status logs are on-demand pointers by default, with FM_SESSION_START_STATUS_TAIL restoring bounded tails"
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
  assert_contains "$out" "status: wake-event log on demand (full log: $home/state/task-orphan.status)" \
    "orphan status line did not name the full log path"
  assert_not_contains "$out" "bin/fm-crew-state.sh task-orphan" \
    "orphan status line pointed at fm-crew-state.sh, which reports unknown without task metadata"
  assert_not_contains "$out" "orphan: step 6" "default digest projected orphan status content"

  out=$(FM_SESSION_START_STATUS_TAIL=5 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "orphan: step 6" "orphan status tail missing the newest line"
  assert_not_contains "$out" "orphan: step 1" "orphan status tail was not bounded"
  assert_contains "$out" "$home/state/task-orphan.status" "orphan status tail did not print the full log path"

  matched_count=$(printf '%s\n' "$out" | grep -F -c 'matched: surfaced once')
  orphan_count=$(printf '%s\n' "$out" | grep -F -c 'orphan: step 6')
  [ "$matched_count" -eq 1 ] || fail "matched status log was printed $matched_count times: $out"
  [ "$orphan_count" -eq 1 ] || fail "orphan status log was printed $orphan_count times: $out"

  pass "orphan status logs surface as on-demand pointers by default and bounded tails on request"
}

# --- status-tail switch oracle and mutation kills -----------------------------
#
# The oracle runs one digest with the default on-demand pointer rendering and
# one with FM_SESSION_START_STATUS_TAIL=5 against the same fixture home, then
# asserts that the startup token estimate (ceil(bytes/3), the same estimator as
# bin/fm-startup-memory-budget.sh) drops by the measured status-tail fraction
# while the backlog, meta, endpoint-liveness, contradiction, and AFK sections
# stay byte-equivalent. The mutation harness re-runs that oracle against four
# mutants of the status_tail_projection_enabled predicate (delete, unreachable,
# weaken, constant-true) plus an unmutated control, expecting every mutant
# killed and the control green, with each recorded exit code printed.

status_tail_oracle_section() {  # <output> <start-line-regex> <end-line-regex>
  printf '%s\n' "$1" | awk -v s="$2" -v e="$3" '
    !found && $0 ~ s { found=1 }
    found && $0 ~ e { exit }
    found { print }
  '
}

status_tail_oracle_meta_blocks() {  # <output>: meta contents + endpoint lines only
  printf '%s\n' "$1" | awk '
    /^Work under way \(state\/\*\.meta\)$/ { insub=1; next }
    insub && /^Orphan status logs/ { exit }
    insub && /^--- / { inblock=1 }
    inblock && /^status/ { inblock=0; next }
    inblock { print }
  '
}

status_tail_oracle() {  # <session-start-bin> <home> <root> <path>
  local bin=$1 home=$2 root=$3 path=$4 off on file tail_bytes=0 chunk
  local bytes_off bytes_on est_off est_on tail_est drop allow=200 side a b
  # One discarded warm-up run absorbs first-run-only bootstrap output (sweep
  # markers, config materialization) so the two measured runs differ only in
  # the status rendering under test.
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u FM_SESSION_START_STATUS_TAIL \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" "$bin" >/dev/null 2>&1
  off=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u FM_SESSION_START_STATUS_TAIL \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" "$bin")
  on=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_SESSION_START_STATUS_TAIL=5 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" "$bin")

  case "$off" in
    *"status: wake-event log on demand (full log: $home/state/task-a.status); current state: bin/fm-crew-state.sh task-a"*) : ;;
    *) printf 'oracle: default run missing the task-a on-demand pointer line\n'; return 1 ;;
  esac
  case "$off" in
    *"status: wake-event log on demand (full log: $home/state/task-b.status); current state: bin/fm-crew-state.sh task-b"*) : ;;
    *) printf 'oracle: default run missing the task-b on-demand pointer line\n'; return 1 ;;
  esac
  case "$off" in
    *"status: wake-event log on demand (full log: $home/state/task-orphan.status)"*) : ;;
    *) printf 'oracle: default run missing the orphan on-demand pointer line\n'; return 1 ;;
  esac
  case "$off" in
    *'bin/fm-crew-state.sh task-orphan'*) printf 'oracle: default run pointed fm-crew-state.sh at a metadata-less orphan\n'; return 1 ;;
  esac
  case "$off" in
    *TAILMARK*) printf 'oracle: default run projected status log content\n'; return 1 ;;
  esac
  case "$off" in
    *'status tail (last'*) printf 'oracle: default run still rendered a status tail\n'; return 1 ;;
  esac
  case "$off" in
    *"each task's status line above"*) : ;;
    *) printf 'oracle: default run missing the on-demand closing reminder\n'; return 1 ;;
  esac

  case "$on" in
    *TAILMARK-a-8*) : ;;
    *) printf 'oracle: tail run missing the newest status line\n'; return 1 ;;
  esac
  case "$on" in
    *TAILMARK-a-4*) : ;;
    *) printf 'oracle: tail run missing an expected in-tail line\n'; return 1 ;;
  esac
  case "$on" in
    *TAILMARK-a-3*) printf 'oracle: tail run leaked a line older than the bound\n'; return 1 ;;
  esac
  case "$on" in
    *'status tail (last 5 line(s)'*) : ;;
    *) printf 'oracle: tail run missing the bounded tail header\n'; return 1 ;;
  esac
  case "$on" in
    *'their bounded tails were just'*) : ;;
    *) printf 'oracle: tail run missing the bounded-tail closing reminder\n'; return 1 ;;
  esac

  for side in backlog meta contradictions afk; do
    case "$side" in
      backlog)
        a=$(status_tail_oracle_section "$off" '^data/backlog.md$' '^Work under way')
        b=$(status_tail_oracle_section "$on" '^data/backlog.md$' '^Work under way')
        ;;
      meta)
        a=$(status_tail_oracle_meta_blocks "$off")
        b=$(status_tail_oracle_meta_blocks "$on")
        case "$a" in
          *'endpoint: alive'*) : ;;
          *) printf 'oracle: meta/liveness extraction lost the endpoint line (vacuous compare)\n'; return 1 ;;
        esac
        ;;
      contradictions)
        a=$(status_tail_oracle_section "$off" '^RECORD CONTRADICTIONS$' '^AFK$')
        b=$(status_tail_oracle_section "$on" '^RECORD CONTRADICTIONS$' '^AFK$')
        case "$a" in
          *'RECORD CONTRADICTIONS'*) : ;;
          *) printf 'oracle: contradiction extraction came back empty (vacuous compare)\n'; return 1 ;;
        esac
        ;;
      afk)
        a=$(status_tail_oracle_section "$off" '^AFK$' '^==========')
        b=$(status_tail_oracle_section "$on" '^AFK$' '^==========')
        ;;
    esac
    if [ "$a" != "$b" ]; then
      printf 'oracle: %s section is not byte-equivalent across the two runs\n--- default ---\n%s\n--- tail ---\n%s\n' "$side" "$a" "$b"
      return 1
    fi
  done

  for file in "$home/state/task-a.status" "$home/state/task-b.status" "$home/state/task-orphan.status"; do
    chunk=$(tail -n 5 "$file" | wc -c | tr -d '[:space:]')
    tail_bytes=$((tail_bytes + chunk))
  done
  bytes_off=$(printf '%s' "$off" | wc -c | tr -d '[:space:]')
  bytes_on=$(printf '%s' "$on" | wc -c | tr -d '[:space:]')
  est_off=$(((bytes_off + 2) / 3))
  est_on=$(((bytes_on + 2) / 3))
  tail_est=$(((tail_bytes + 2) / 3))
  drop=$((est_on - est_off))
  if [ "$drop" -lt $((tail_est - allow)) ]; then
    printf 'oracle: startup token estimate dropped by %s, below the status-tail fraction %s\n' "$drop" "$tail_est"
    return 1
  fi
  if [ "$drop" -gt $((tail_est + allow)) ]; then
    printf 'oracle: startup token estimate dropped by %s, more than the status-tail fraction %s - a non-tail section shrank\n' "$drop" "$tail_est"
    return 1
  fi
  return 0
}

test_status_tail_switch_oracle_and_mutations() {
  local rec root home fakebin w n body out rc
  local class mutant_body mbin killed codes
  rec=$(new_world status-tail-oracle)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  w=$(dirname "$root")
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live"
  # The mutant bin copies resolve docs/supervision-protocols from their own
  # parent directory (fm-supervision-instructions.sh REPO_ROOT), so mirror it.
  mkdir -p "$w/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$w/docs/"

  printf 'window=fm-sess:live\nkind=ship\n' > "$home/state/task-a.meta"
  printf 'kind=ship\n' > "$home/state/task-b.meta"
  body=$(printf 'x%.0s' $(seq 1 180))
  for id in a b orphan; do
    : > "$home/state/task-$id.status"
    for n in 1 2 3 4 5 6 7 8; do
      printf 'working: TAILMARK-%s-%s %s\n' "$id" "$n" "$body" >> "$home/state/task-$id.status"
    done
  done

  codes=''
  killed=0
  for class in control delete unreachable weaken constant-true; do
    case "$class" in
      control) mutant_body='' ;;
      delete) mutant_body=':' ;;
      unreachable) mutant_body='return 1' ;;
      weaken) mutant_body="[ \"\$STATUS_TAIL\" -ge 0 ]" ;;
      constant-true) mutant_body='true' ;;
    esac
    mbin="$w/mutant-bin-$class"
    rm -rf "$mbin"
    cp -R "$ROOT/bin" "$mbin"
    if [ -n "$mutant_body" ]; then
      awk -v body="$mutant_body" '
        /^status_tail_projection_enabled\(\)[[:space:]]*\{/ {
          print
          print "  " body
          replacing=1
          next
        }
        replacing && /^[[:space:]]*}/ { print; replacing=0; next }
        replacing { next }
        { print }
      ' "$ROOT/bin/fm-session-start.sh" > "$mbin/fm-session-start.sh" \
        || fail "mutation $class: predicate replacement failed"
      chmod +x "$mbin/fm-session-start.sh"
    fi
    rc=0
    out=$(status_tail_oracle "$mbin/fm-session-start.sh" "$home" "$root" "$fakebin:$BASE_PATH") || rc=$?
    codes="$codes $class=$rc"
    if [ "$class" = control ]; then
      [ "$rc" -eq 0 ] || fail "control (unmutated) oracle failed (exit $rc): $out"
    else
      if [ "$rc" -eq 0 ]; then
        fail "mutant $class survived the oracle (exit 0)"
      fi
      killed=$((killed + 1))
    fi
  done
  printf '# status-tail mutation exit codes:%s\n' "$codes"
  [ "$killed" -eq 4 ] || fail "expected 4 killed mutants, got $killed"

  pass "status-tail switch oracle holds token-drop and byte-equivalence, and kills all four predicate mutants"
}

contradiction_section() {
  awk '
    /^RECORD CONTRADICTIONS$/ { found=1 }
    found && /^AFK$/ { exit }
    found { print }
  '
}

test_record_contradictions_are_bounded_and_silent_when_consistent() {
  local rec root home fakebin out contradictions meta_line consistent_rec consistent_root consistent_home consistent_fakebin consistent_out
  rec=$(new_world record-contradictions)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux_set "$fakebin" "fm-sess:healthy:fm-sess:done"
  make_fake_contradiction_gh_axi "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] healthy-live - Healthy live task (repo: firstmate) (kind: ship)
- [ ] dead-working - Dead working task (repo: firstmate) (kind: ship)
- [ ] done-live - Done task with a live endpoint (repo: firstmate) (kind: ship)
- [ ] conflicted-pr - Conflicted pull request (repo: firstmate) (kind: ship)
- [ ] merged-pr - Merged pull request (repo: firstmate) (kind: ship)
- [ ] done-open-pr - Done task with an open pull request (repo: firstmate) (kind: ship)
- [ ] held-flight - Held task (repo: firstmate) (kind: ship) (hold: wait) (hold-kind: future)
- [ ] missing-meta - Missing runtime record (repo: firstmate) (kind: ship)
- [x] complete-flight-meta - Checked in-flight task with live metadata (repo: firstmate) (kind: ship)

## Queued
- [ ] queued-healthy - Queued work needs no runtime record (repo: firstmate) (kind: ship)

## Done
- [x] completed-healthy - Completed work needs no runtime record (repo: firstmate) (kind: ship)
- [x] complete-done-meta - Done task with live metadata (repo: firstmate) (kind: ship)
EOF
  printf 'window=fm-sess:healthy\nkind=ship\npr=https://github.com/example/repo/pull/7\n' > "$home/state/healthy-live.meta"
  printf 'working: current work\n' > "$home/state/healthy-live.status"
  printf 'window=fm-sess:dead\nkind=ship\n' > "$home/state/dead-working.meta"
  printf 'working: stale event\n' > "$home/state/dead-working.status"
  printf 'window=fm-sess:done\nkind=ship\n' > "$home/state/done-live.meta"
  printf 'done: stale completion\n' > "$home/state/done-live.status"
  printf 'window=fm-sess:conflict\nkind=ship\npr=https://github.com/example/repo/pull/8\n' > "$home/state/conflicted-pr.meta"
  printf 'window=fm-sess:merged\nkind=ship\npr=https://github.com/example/repo/pull/9\n' > "$home/state/merged-pr.meta"
  printf 'window=fm-sess:done-open\nkind=ship\npr=https://github.com/example/repo/pull/10\n' > "$home/state/done-open-pr.meta"
  printf 'done: falsely claimed landed\n' > "$home/state/done-open-pr.status"
  printf 'window=fm-sess:held\nkind=ship\n' > "$home/state/held-flight.meta"
  printf 'window=fm-sess:complete-done\nkind=ship\n' > "$home/state/complete-done-meta.meta"
  printf 'window=fm-sess:complete-flight\nkind=ship\n' > "$home/state/complete-flight-meta.meta"
  printf 'window=fm-sess:meta-only\nkind=ship\n' > "$home/state/meta-only.meta"
  printf 'clean\n' > "$root/tracked.txt"
  git -C "$root" add tracked.txt
  git -C "$root" commit -q -m fixture
  git clone -q "$root" "$home/meta-clean-wt"
  git clone -q "$root" "$home/meta-dirty-wt"
  git -C "$home/meta-dirty-wt" checkout -q -b orphan-feature
  printf 'unlanded\n' > "$home/meta-dirty-wt/unlanded.txt"
  git -C "$home/meta-dirty-wt" add unlanded.txt
  git -C "$home/meta-dirty-wt" commit -q -m unlanded-fixture
  printf 'dirty\n' > "$home/meta-dirty-wt/tracked.txt"
  git clone -q "$root" "$home/meta-untracked-wt"
  printf 'untracked\n' > "$home/meta-untracked-wt/untracked.txt"
  printf 'window=fm-sess:meta-clean\nkind=ship\nworktree=%s\n' "$home/meta-clean-wt" > "$home/state/meta-clean.meta"
  printf 'window=fm-sess:meta-dirty\nkind=ship\nworktree=%s\n' "$home/meta-dirty-wt" > "$home/state/meta-dirty.meta"
  printf 'window=fm-sess:meta-untracked\nkind=ship\nworktree=%s\n' "$home/meta-untracked-wt" > "$home/state/meta-untracked.meta"
  printf 'window=fm-sess:secondmate\nkind=secondmate\n' > "$home/state/fleet-mate.meta"
  printf 'resolved: archival candidate\n' > "$home/state/stale-orphan.status"
  touch -t 202608010000 "$home/state/stale-orphan.status"
  printf 'resolved: recent orphan\n' > "$home/state/recent-orphan.status"

  out=$(FM_FAKE_LIVE_TARGETS="fm-sess:healthy:fm-sess:done" \
    FM_RECORD_CONTRADICTION_LIMIT=20 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  contradictions=$(printf '%s\n' "$out" | contradiction_section)

  assert_contains "$contradictions" "RECORD CONTRADICTIONS" "startup digest omitted the contradiction section"
  assert_contains "$contradictions" "meta-without-backlog (4): meta-clean(dirty=0,unlanded=0), meta-dirty(dirty=1,unlanded=1), meta-only(dirty=unknown,unlanded=unknown), meta-untracked(dirty=1,unlanded=0)" \
    "startup digest missed metadata without a backlog row or its risk counts"
  assert_contains "$contradictions" "meta-untracked(dirty=1,unlanded=0)" \
    "startup digest treated untracked-only work as clean"
  assert_contains "$contradictions" "complete-but-live-meta (2): complete-done-meta, complete-flight-meta" \
    "startup digest did not distinguish checked backlog rows from absent backlog rows"
  meta_line=$(printf '%s\n' "$contradictions" | awk '/^- meta-without-backlog / { print }')
  assert_not_contains "$meta_line" "complete-done-meta" "a checked Done row was falsely labelled absent"
  assert_not_contains "$meta_line" "complete-flight-meta" "a checked In-flight row was falsely labelled absent"
  assert_contains "$contradictions" "backlog-without-meta (1): missing-meta(state=in_flight)" "startup digest missed an in-flight row without metadata"
  assert_contains "$contradictions" "dead-working(status=working,endpoint=dead)" "startup digest trusted working status on a dead endpoint"
  assert_contains "$contradictions" "done-live(status=done,endpoint=alive)" "startup digest trusted done status on a live endpoint"
  assert_contains "$contradictions" "conflicted-pr(mergeable=CONFLICTING)" "startup digest missed a conflicted recorded PR"
  assert_contains "$contradictions" "merged-pr(state=MERGED)" "startup digest missed a merged PR with live metadata"
  assert_contains "$contradictions" "done-open-pr(status=done,state=OPEN)" "startup digest trusted done status while its PR remained open"
  assert_contains "$contradictions" "held-in-flight (1): held-flight(hold-kind=future)" "startup digest missed a held in-flight row"
  assert_contains "$contradictions" "stale-orphan-status (1): stale-orphan(age=" "startup digest missed an old status log without metadata"
  assert_not_contains "$contradictions" "healthy-live" "startup contradiction section listed a consistent live task"
  assert_not_contains "$contradictions" "queued-healthy" "startup contradiction section treated queued work as live"
  assert_not_contains "$contradictions" "completed-healthy" "startup contradiction section treated completed work as live"
  assert_not_contains "$contradictions" "fleet-mate" "startup contradiction section required a secondmate backlog row"
  assert_not_contains "$contradictions" "recent-orphan" "startup contradiction section flagged a fresh orphan status"

  out=$(FM_FAKE_LIVE_TARGETS="fm-sess:healthy:fm-sess:done" \
    FM_RECORD_CONTRADICTION_LIMIT=2 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  contradictions=$(printf '%s\n' "$out" | contradiction_section)
  [ "$(printf '%s\n' "$contradictions" | awk '/^- / { count++ } END { print count + 0 }')" -le 7 ] \
    || fail "bounded contradiction section exceeded one line per contradiction class: $contradictions"
  assert_contains "$contradictions" "+1 more" "bounded contradiction section omitted its hidden-finding count"

  consistent_rec=$(new_world record-consistent)
  IFS='|' read -r consistent_root consistent_home consistent_fakebin <<EOF
$consistent_rec
EOF
  make_fake_toolchain "$consistent_fakebin"
  make_fake_ps_claude "$consistent_fakebin"
  make_fake_tmux "$consistent_fakebin" "fm-sess:healthy"
  printf '%s\n' manual > "$consistent_home/config/backlog-backend"
  cat > "$consistent_home/data/backlog.md" <<'EOF'
# Backlog
## In flight
- [ ] healthy-live - Healthy live task (repo: firstmate) (kind: ship)
## Queued
- [ ] queued-healthy - Queued work (repo: firstmate) (kind: ship)
## Done
EOF
  printf 'window=fm-sess:healthy\nkind=ship\n' > "$consistent_home/state/healthy-live.meta"
  printf 'working: current work\n' > "$consistent_home/state/healthy-live.status"
  consistent_out=$(run_session_start "$consistent_home" "$consistent_root" "$consistent_fakebin:$BASE_PATH")
  assert_not_contains "$consistent_out" "RECORD CONTRADICTIONS" "consistent startup records emitted a contradiction section"

  pass "session start prints only bounded contradictions and stays silent when records agree"
}

# --- session-start secondmate recovery boundary -----------------------------

test_session_start_relaunches_missing_pi_secondmate() {
  local rec root home fakebin mate log spawned out first_calls second_calls
  rec=$(prepare_session_start_secondmate secondmate-missing-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing)

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful missing-window recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "new-window" "session start did not relaunch the missing Pi secondmate"
  assert_not_contains "$(cat "$log")" "kill-window" "session start tried to kill an already-absent window"
  assert_contains "$out" "endpoint: alive (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later fleet read did not confirm the relaunched window"
  assert_grep 'harness=pi' "$home/state/$SESSION_START_SECOND_MATE_ID.meta" \
    "the real respawn path did not preserve the Pi harness: $(cat "$home/state/$SESSION_START_SECOND_MATE_ID.meta")"

  first_calls=$(grep -c 'new-window' "$log" || true)
  rm -f "$home/state/.lock"
  run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing >/dev/null
  second_calls=$(grep -c 'new-window' "$log" || true)
  [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ] \
    || fail "a second session-start pass duplicated the relaunched Pi secondmate: $(cat "$log")"
  pass "session start: an absent recorded tmux window relaunches its Pi secondmate exactly once"
}

test_session_start_preserves_ambiguous_pi_process() {
  local rec root home fakebin mate log spawned out
  rec=$(prepare_session_start_secondmate secondmate-ambiguous-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" ambiguous)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate $SESSION_START_SECOND_MATE_ID: skipped: existing endpoint has ambiguous agent process (backend=tmux)" \
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

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate $SESSION_START_SECOND_MATE_ID: skipped: endpoint probe unreadable (backend=tmux)" \
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

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" shell)

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful bare-shell recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-$SESSION_START_SECOND_MATE_ID" \
    "the proven bare-shell path did not remove its existing dead endpoint"
  assert_contains "$(cat "$log")" "new-window" "the proven bare-shell path did not relaunch"
  assert_contains "$out" "endpoint: alive (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later fleet read did not confirm the bare-shell relaunch"
  pass "session start: the proven bare-shell recovery path remains intact"
}

test_session_start_relaunches_herdr_husk_secondmate() {
  local rec root home fakebin mate log state out
  rec=$(prepare_session_start_herdr_secondmate secondmate-herdr-husk)
  IFS='|' read -r root home fakebin mate log state <<EOF
$rec
EOF

  out=$(run_session_start_herdr_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$state")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful Herdr husk recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "pane close p-old" "session start did not close the confirmed Herdr husk"
  assert_contains "$(cat "$log")" "tab create" "session start did not relaunch the Herdr secondmate"
  assert_contains "$out" "endpoint: alive (backend=herdr window=default:p-new)" \
    "the later fleet read did not confirm the relaunched Herdr endpoint"
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

# --- fleet-state digest: compact backlog rendering --------------------------

write_long_body_backlog() {
  local path=$1
  cat > "$path" <<'EOF'
# Backlog

## In flight
- [ ] compact-startup - Compact startup digest (repo: firstmate) (kind: ship) (since 2026-07-15) (hold: captain choice pending) (hold-kind: captain)
  OVERSIZED-BODY-LINE current startup leaks task note bodies into the session digest.
  Another long body line that should not be printed after the fix.

## Queued
- [ ] blocked-followup - Follow compact startup blocked-by: compact-startup - waits for implementation (repo: firstmate) (kind: scout) (since 2026-07-15)
  QUEUED-BODY-LINE this is another long multiline note.

## Done
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

  out=$(FM_FAKE_TASKS_AXI_LOG="$log" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi; max 80 item(s); task bodies omitted)" \
    "compatible tasks-axi backend did not render the compact backlog listing"
  assert_contains "$out" "tasks[2]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:" \
    "tasks-axi compact listing omitted the expected structured field header"
  assert_contains "$out" "compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending" \
    "tasks-axi compact listing omitted in-flight identity, state, or hold metadata"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "tasks-axi compact listing omitted blocked-by metadata"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "tasks-axi compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "tasks-axi compact digest leaked a queued task body"
  assert_contains "$out" "--- compact-startup ---" "in-flight meta identity disappeared from startup recovery digest"
  assert_contains "$out" "worktree=$home/projects/firstmate" "in-flight recovery worktree identity disappeared from startup digest"
  assert_contains "$out" "Full task bodies remain available on demand: tasks-axi show <id> --full" \
    "compact digest omitted the full-body lookup pointer"
  assert_grep "list --file $home/data/backlog.md --limit 80 --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the bounded compact field set"

  pass "compatible tasks-axi backlog rendering is compact, bounded, and preserves recovery metadata"
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

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (manual backend; max 80 item(s); indented task bodies omitted)" \
    "manual backend did not use compact title-line rendering"
  assert_contains "$out" "## In flight" "manual compact rendering omitted the in-flight section heading"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "manual compact rendering omitted the in-flight title line"
  assert_contains "$out" "(hold: captain choice pending) (hold-kind: captain)" \
    "manual compact rendering omitted hold metadata"
  assert_contains "$out" "blocked-by: compact-startup - waits for implementation" \
    "manual compact rendering omitted blocker metadata"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "manual compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "manual compact digest leaked a queued task body"
  assert_contains "$out" "(shown 2 of 2 backlog item title line(s))" \
    "manual compact rendering did not report its bound accounting"
  assert_contains "$out" "or data/backlog.md" "manual compact digest omitted the data/backlog.md full-body pointer"

  pass "manual backlog rendering prints only title lines with hold and blocker metadata"
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

  assert_contains "$out" "compact backlog listing (tasks-axi unavailable or incompatible; max 80 item(s); indented task bodies omitted)" \
    "unavailable tasks-axi did not fall back to compact title-line rendering"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "unavailable tasks-axi fallback omitted a backlog title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "unavailable tasks-axi fallback leaked an in-flight task body"

  pass "unavailable or incompatible tasks-axi falls back to compact manual backlog rendering"
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
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.28'
  exit 0
fi
printf '%s\n' '{"schemaVersion":3,"generatedAt":"2026-08-18T00:00:00Z","providers":[{"provider":"claude","label":"Claude","source":"oauth","state":{"status":"fresh","stale":false},"windows":[{"id":"seven_day","label":"week","kind":"weekly","percentUsed":42,"percentRemaining":58,"resetsAt":"2099-01-01T00:00:00Z","pace":{"status":"behind","reservePercentPoints":30}}],"quotaSemantics":{"status":"known","description":"","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":58,"boundedBy":["seven_day"],"limitingWindowIds":["seven_day"],"pace":{"status":"behind","worstReservePercentPoints":30,"worstReserveWindowId":"seven_day"},"runway":{"status":"through_reset","usableRunwaySeconds":604800,"limitingWindowId":"seven_day"}}]}}]}'
exit 0
SH
  chmod +x "$fakebin/quota-axi"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "(none)" "empty fleet did not report (none) for in-flight tasks"
  assert_contains "$out" "absent" "empty fleet's AFK section did not report absent"
  assert_contains "$out" "Quota utilization" "empty fleet omitted the weekly quota-utilization block"
  assert_contains "$out" "quota: claude default: 42% used (seven_day) resets in" \
    "the digest did not render the measured utilization line from the quota reader"
  assert_contains "$out" "SPEND reserve=30 hold=no" \
    "the digest did not carry the binding weekly reserve and no-hold contract"
  assert_not_contains "$out" "utilization reader failed" \
    "the quota reader failed instead of reporting the stubbed account"

  pass "an empty fleet reports (none) for in-flight tasks, an absent AFK flag, and the measured quota-utilization line"
}

test_fleet_digest_lists_bounded_standing_checks() {
  local rec root home fakebin out line count id
  rec=$(new_world standing-checks)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  id=1
  while [ "$id" -le 22 ]; do
    printf -v monitor 'standing-%02d' "$id"
    cat > "$home/state/$monitor.check.sh" <<'SH'
#!/usr/bin/env bash
# Watch a finite subject whose terminal state retires this monitor.
exit 0
SH
    chmod 0700 "$home/state/$monitor.check.sh"
    FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "$monitor" >/dev/null \
      || fail "could not register standing-check fixture $monitor"
    id=$((id + 1))
  done
  perl -e 'my $t = time() - 172800; utime $t, $t, @ARGV' "$home/state/standing-01.check.sh"

  cat > "$home/state/task-bound.check.sh" <<'SH'
#!/usr/bin/env bash
# A task-bound monitor must stay out of the standing inventory.
exit 0
SH
  chmod 0700 "$home/state/task-bound.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" task-bound >/dev/null \
    || fail "could not register task-bound fixture"
  printf 'kind=ship\n' > "$home/state/task-bound.meta"
  printf '#!/usr/bin/env bash\n# Relay-owned shim.\n' > "$home/state/x-watch.check.sh"
  chmod 0700 "$home/state/x-watch.check.sh"
  printf '#!/usr/bin/env bash\n# Unbound checks are not armed.\n' > "$home/state/unbound.check.sh"
  chmod 0700 "$home/state/unbound.check.sh"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  line=$(printf '%s\n' "$out" | sed -n '/^Standing checks without task metadata:/p')
  count=$(printf '%s\n' "$line" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || fail "standing-check inventory was not exactly one line: $out"
  assert_contains "$line" 'standing-01 [age=2d; comment=Watch a finite subject whose terminal state retires this monitor.]' \
    "standing-check inventory omitted id, age, or first comment"
  assert_contains "$line" 'standing-20 [' "standing-check inventory truncated before its declared bound"
  assert_contains "$line" '+2 more' "standing-check inventory did not report entries beyond its bound"
  assert_not_contains "$line" 'standing-21 [' "standing-check inventory exceeded its entry bound"
  assert_not_contains "$line" 'task-bound' "standing-check inventory included a task-backed check"
  assert_not_contains "$line" 'x-watch' "standing-check inventory included the relay-owned shim"
  assert_not_contains "$line" 'unbound' "standing-check inventory included an unarmed check"

  pass "fleet digest lists standing checks once with bounded id, age, and comment detail"
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
test_herdr_backend_diagnostics_follow_real_session_start
test_session_start_relaunches_missing_pi_secondmate
test_session_start_preserves_ambiguous_pi_process
test_session_start_preserves_transiently_unreadable_tmux
test_session_start_preserves_proven_bare_shell_recovery
test_session_start_relaunches_herdr_husk_secondmate
test_status_tail_bounding
test_orphan_status_logs_are_printed
test_status_tail_switch_oracle_and_mutations
test_record_contradictions_are_bounded_and_silent_when_consistent
test_endpoint_liveness_tmux
test_endpoint_liveness_herdr
test_composition_invokes_real_scripts
test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata
test_backlog_compact_manual_backend_skips_indented_bodies
test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback
test_fleet_digest_empty_fleet
test_fleet_digest_lists_bounded_standing_checks
test_next_step_sources_x_mode_cadence
test_next_step_afk_delegates_to_daemon
test_supervision_block_exactly_one_and_pi_diagnostic
test_pi_signed_primary_uses_pi_extensions_without_identity_normalization
test_pi_diagnostic_rejects_stale_loaded_marker
test_pi_diagnostic_accepts_prelock_loaded_marker
test_pi_diagnostic_rejects_missing_turnend_guard_marker
test_pi_diagnostic_rejects_previous_session_loaded_marker

echo "# fm-session-start.test.sh: all assertions passed"
