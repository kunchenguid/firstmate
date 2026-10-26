#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE tmux source for delivery-busy detection, composer capture primitives,
# and verified submit.
# Both the away-mode daemon and bin/fm-send.sh reach these primitives through
# backend dispatch, while bin/fm-composer-lib.sh owns the shared verdict.
#
# Composer shapes and verdicts are owned by bin/fm-composer-lib.sh.
# This file owns only tmux's styled capture, cursor and Pi identity primitives,
# delivery busy read, and submit conversions that consume the shared verdict.
# Styled captures remain internal; fm-peek and every human-facing capture stay
# plain.
#
# OpenCode's busy-queued Enter conversion accepts only structurally proven
# pending text after retries, while the separate turn-started conversion accepts
# an unknown post-Enter composer only after this submit observed an idle baseline
# become busy.
# The queued-Enter policy itself lives in fm_composer_queued_enter_verdict
# (bin/fm-composer-lib.sh); this file supplies tmux's pane-busy primitive.
#
# FM_COMPOSER_IDLE_RE is interpreted by the shared classifier with its structural
# and styling safety gates.
# FM_BUSY_REGEX overrides the rendered delivery-busy matching used here.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.sh's
# semantic contract. The matching below serves only delivery guards: the submit
# acknowledgement and the away-mode supervisor-pane busy guard. Both ask about
# the pane receiving input, not the state of a recorded worker task. Matching
# stays harness-scoped so one harness's output cannot make another read busy.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer classification is NOT owned here: every shape, glyph, border
# family, geometry rule, and verdict decision lives in the shared
# bin/fm-composer-lib.sh (fm_composer_classify_screen), sourced below and
# reused by every backend adapter so the decision cannot drift. This file
# keeps only tmux's genuine capture-side primitives - the styled pane
# capture, the #{cursor_y} cursor read, the pi foreground-process identity
# probe, and the capability descriptor - plus the busy detection and submit
# cores that consume the shared verdict.

# The sibling directory is derived without forking dirname, because a backend
# probe can re-source this adapter inside a subshell on every watcher cycle.
_FM_TMUX_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_TMUX_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_TMUX_LIB_DIR=.
# shellcheck source=bin/fm-composer-lib.sh
. "${_FM_TMUX_LIB_DIR:-/}/fm-composer-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_TMUX_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_TMUX_LIB_DIR

# --- socket addressing owner -------------------------------------------------
#
# fm_tmux is the ONE owner of every tmux invocation firstmate makes. Every
# call site in bin/ goes through it, in one of two addressing modes:
#
#   Fleet     - FM_TMUX_SOCKET=<name> set in the caller's dynamic scope (the
#               bash `VAR=value fn args` prefix reaches every nested function,
#               so one prefix covers a whole dispatch tree). The command runs
#               against the named dedicated socket (`tmux -L <name>`), where
#               every newly spawned worker endpoint lives, physically isolated
#               from the captain's interactive tmux server (the 2026-10-16
#               jetsam incident: three tmux server deaths each took one
#               worker; the idle dedicated server dying no longer touches the
#               interactive one, and its death is provable - see
#               fm_control_endpoint_absence_verdict). Task-recorded endpoints
#               read their scope from the record's socket= field; a record
#               without socket= is a LEGACY record on the ambient server and
#               must stay unscoped.
#   Ambient   - no FM_TMUX_SOCKET: the bare command addresses whatever server
#               the process's own TMUX/TMUX_TMPDIR resolves - the captain's
#               interactive server. Reserved for endpoints that are BY DESIGN
#               the operator's own: the away-daemon terminal (bin/
#               fm-afk-launch.sh), the supervisor pane (bin/
#               fm-supervise-daemon.sh), and Orca's launch-env snapshot of the
#               operator's tmux session (bin/backends/orca.sh). These never
#               name worker endpoints, so a worker window can never be
#               addressed ambiently once spawned fleet-side.
#
# Socket identity and its death proof: fm-spawn.sh writes socket=<name> into
# every new tmux task record. fm_tmux_socket_path, fm_tmux_server_evidence,
# and fm_tmux_worktree_live_pids own the primitives the control plane's
# reclaim proof composes (bin/fm-control-lib.sh).

fm_tmux() {
  # No `command` prefix: tests and adapters may override tmux as a shell
  # FUNCTION (tests/fm-kimi-harness.test.sh's busy-signature seam does), and
  # that seam must keep working through this owner.
  if [ -n "${FM_TMUX_SOCKET:-}" ]; then
    tmux -L "$FM_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

# fm_tmux_home_fleet_socket: the DEFAULT fleet socket name for THIS home.
# Derived from the home identity (review M3): two homes (a primary and its
# local secondmates, or any two FM_HOMEs) must never share one fleet server
# by default - task ids are unique only within a home, so a shared default
# would let a stale or foreign meta with a colliding id read, steer, or kill
# another home's live window. The shared `firstmate` name stays available as
# an EXPLICIT, documented config/env choice.
fm_tmux_home_fleet_socket() {
  local home=${FM_HOME:-${HOME:-}}
  printf 'firstmate-%s\n' "$(printf '%s' "$home" | cksum | awk '{print substr($1,1,8)}')"
}

# fm_tmux_fleet_socket: print the socket name NEW worker endpoints spawn into:
# FM_FLEET_TMUX_SOCKET (tests, the real-socket smoke), else the FIRST LINE of
# config/fleet-tmux-socket under <config-dir> when a readable regular file
# exists there, else this home's derived default (fm_tmux_home_fleet_socket).
# `default` is refused (review M3): it names the operator's own tmux server
# and would silently defeat the entire isolation guarantee. A name must be a
# plain atom - it becomes a socket filename - so a malformed, unreadable, or
# non-regular config refuses loudly here instead of failing inside tmux.
fm_tmux_fleet_socket() {  # [config-dir]
  local name line dir=${1:-}
  name=${FM_FLEET_TMUX_SOCKET:-}
  if [ -z "$name" ] && [ -n "$dir" ] && [ -e "$dir/fleet-tmux-socket" ]; then
    [ -f "$dir/fleet-tmux-socket" ] && [ -r "$dir/fleet-tmux-socket" ] \
      || { echo "error: config/fleet-tmux-socket exists but is not a readable regular file; refusing to guess a fleet socket" >&2; return 1; }
    IFS= read -r line < "$dir/fleet-tmux-socket" || true
    name=$line
  fi
  [ -n "$name" ] || name=$(fm_tmux_home_fleet_socket)
  case "$name" in
    default)
      echo "error: 'default' names the operator's own tmux server and would defeat socket isolation; pick a dedicated fleet socket name" >&2
      return 1
      ;;
  esac
  case "$name" in
    [A-Za-z0-9_-])
      : ;;  # one character is valid ([A-Za-z0-9_-]{1,64})
    ?[A-Za-z0-9_-]*[A-Za-z0-9_-])
      [ "${#name}" -le 64 ] || { echo "error: tmux fleet socket name is ${#name} chars (max 64)" >&2; return 1; } ;;
    *) echo "error: malformed tmux fleet socket name '$name' (want [A-Za-z0-9_-]{1,64})" >&2; return 1 ;;
  esac
  printf '%s\n' "$name"
}

# fm_tmux_socket_path: the filesystem path of named socket <name>, derived
# with the same rule the spawning server used: tmux ALWAYS nests its sockets
# in a tmux-<uid> directory - ${TMUX_TMPDIR}/tmux-<uid>/<name> when
# TMUX_TMPDIR is set, /tmp/tmux-<uid>/<name> otherwise (verified 2026-10-17
# against a real server: TMUX_TMPDIR=<dir> puts the socket at
# <dir>/tmux-<uid>/<name>, not <dir>/<name>). Note macOS resolves /tmp (and
# TMPDIR-style paths) to a /private prefix: callers comparing lsof output
# must test both spellings (fm_tmux_server_evidence builds the /private
# candidate for ANY absolute path).
fm_tmux_socket_path() {  # <name>
  # ${var%/}: macOS TMPDIR carries a trailing slash, and real tmux normalizes
  # the doubled separator away when it creates the socket - the computed path
  # must match what lsof reports, slash for slash.
  local dir=${TMUX_TMPDIR%/}
  printf '%s/tmux-%s/%s\n' "${dir:-/tmp}" "$(id -u)" "$1"
}

# fm_tmux_bounded: run <cmd...> under a wait bound (FM_TMUX_PROOF_TIMEOUT,
# default 15s); the command's stdout is this function's stdout when it
# completes in bound, and the rc is the child's (0/child-status) or 2 on
# timeout. A proof primitive must never hang the control plane:
# - TIMEOUT teardown is two-level (review M-a): the probe, its direct
#   children, and one further generation are killed and reaped - a shim
#   script blocked in a child (e.g. a `sleep`) would otherwise leave an
#   orphan behind, and the orphan would ALSO hold the capture pipe open and
#   stall the caller. Reap latency is bounded by the configured timeout
#   (FM_TMUX_PROOF_TIMEOUT, default 15 s) plus loop granularity: with the
#   regression's 2 s bound the probe and its child are gone in ~2-3.5 s
#   end to end. The configured value is counted in real seconds (five
#   0.2 s ticks), so the default bound expires at ~15 s, not ~3 s.
# - The probe writes to a FILE, not the inherited pipe: a timed-out
#   grandchild then holds only that file (partial output is discarded), so
#   the caller's command substitution can return while the reaper finishes.
# The child's status rides a sentinel file because bash reaps fast
# background jobs before `wait $pid` can read them. rc 2 reads as
# `unproven` at every proof caller - a取证超时 is "no usable evidence",
# never "no evidence found".
fm_tmux_bounded() {
  local timeout=${FM_TMUX_PROOF_TIMEOUT:-15} rc pid rcfile outfile child ticks
  case "$timeout" in ''|*[!0-9]*) timeout=15 ;; esac
  rcfile=$(mktemp "${TMPDIR:-/tmp}/fm-tmux-bounded.XXXXXX") || return 2
  outfile=$rcfile.out
  (
    "$@" >"$outfile" 2>/dev/null
    printf '%s' "$?" > "$rcfile"
  ) &
  pid=$!
  rc=2
  ticks=$((timeout * 5))
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rc=$(cat "$rcfile" 2>/dev/null || printf 2)
      break
    fi
    if [ "$ticks" -le 0 ]; then
      # Two-level teardown: the probe's children first (while their parent
      # still exists to name them), then the probe, then reap.
      for child in $(pgrep -P "$pid" 2>/dev/null); do
        pkill -P "$child" 2>/dev/null || true
        kill "$child" 2>/dev/null || true
      done
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=2
      break
    fi
    sleep 0.2
    ticks=$((ticks - 1))
  done
  cat "$outfile" 2>/dev/null || true
  rm -f "$rcfile" "$outfile"
  case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  return "$rc"
}

# fm_tmux_server_evidence: evidence about a tmux server for <name>.
# Three outcomes, because "no evidence found" and "no usable evidence
# source" are different facts and only the first is proof of absence:
#   rc 0 - POSITIVE evidence printed (one line per source): the server is
#          running. The pid-liveness/zombie and exact-match rules below
#          keep a stale or coincidental line from counting.
#   rc 1 - NO evidence, and at least one source completed a clean scan: the
#          server is provably without a live process (the caller still owes
#          the worktree check before `gone`).
#   rc 2 - every source was unusable (lsof missing/failed/timed out AND
#          pgrep missing/failed): the socket's liveness is UNPROVEN; callers
#          must refuse, never treat as dead.
# Sources, each independent because no single one is reliable everywhere:
#   lsof -U   a process holding the socket. The socket path is matched
#             EXACTLY (last whitespace field equal to either spelling -
#             substring matching would let `firstmate` match `firstmate2`).
#             Verified 2026-10-17: a plain `lsof <socket-path>` matches
#             NOTHING on macOS even for a live server - the -U table is the
#             only holder read; and it keeps listing a JUST-EXITED server's
#             binding for a second or two, so a holder line counts only
#             after a pid-liveness check (kill -0, zombies excluded).
#   pgrep     a `tmux -L <name>` argv boundary-matched (macOS keeps the
#             client's original argv for the server process) or a rewritten
#             `tmux: server (... <path-or-name>)` proctitle end-anchored
#             (Linux). The [r] bracket keeps the pattern from matching this
#             shell's own command line.
# The socket FILE's existence is deliberately NOT evidence either way:
# verified 2026-10-17 that a clean `kill-server` can leave the file behind,
# and jetsam leaves it forever.
fm_tmux_server_evidence() {  # <name>
  local name=$1 path private_path found=0 clean=0
  local holder_pid holder_stat out rc
  path=$(fm_tmux_socket_path "$name")
  case "$path" in
    /private/*) private_path=$path ;;
    /*) private_path=/private$path ;;
    *) private_path=$path ;;
  esac
  if command -v lsof >/dev/null 2>&1; then
    # macOS lsof exits 1 on a walk with any error even while printing
    # matches, so output-present is usable; only an EMPTY nonzero result
    # leaves this source unusable (a clean pgrep can still prove absence).
    rc=0
    out=$(fm_tmux_bounded env LC_ALL=C lsof -U 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ] || [ -n "$out" ]; then
      clean=1
      holder_pid=$(printf '%s\n' "$out" \
        | awk -v p="$path" -v pp="$private_path" '
            $NF == p || $NF == pp { print $2; exit }')
      case "$holder_pid" in
        ''|*[!0-9]*) : ;;
        *)
          if kill -0 "$holder_pid" 2>/dev/null; then
            holder_stat=$(ps -o stat= -p "$holder_pid" 2>/dev/null || true)
            case "$holder_stat" in
              Z*|'') : ;;
              *) printf 'lsof-pid:%s\n' "$holder_pid"; found=1 ;;
            esac
          fi
          ;;
      esac
    elif [ "$rc" -ne 2 ]; then
      # lsof ran and failed: this source is unusable, but a clean pgrep can
      # still prove absence on its own - the rc-2 (all sources unusable)
      # verdict is composed below.
      :
    fi
  fi
  if command -v pgrep >/dev/null 2>&1; then
    # pgrep's vocabulary differs from lsof's: rc 1 is the CLEAN "no
    # processes matched" answer (it is the empty-scan proof), rc 0 means a
    # match was found, and only other statuses are source failures.
    rc=0
    out=$(fm_tmux_bounded pgrep -fl "tmux -L ${name}([[:space:]]|$)" 2>/dev/null) || rc=$?
    case "$rc" in
      0) clean=1; printf 'pgrep:%s\n' "$(printf '%s' "$out" | head -1)"; found=1 ;;
      1) clean=1 ;;
    esac
    rc=0
    out=$(fm_tmux_bounded pgrep -fl "tmux: serve[r].*(${path}|${name})$" 2>/dev/null) || rc=$?
    case "$rc" in
      0) clean=1; printf 'pgrep:%s\n' "$(printf '%s' "$out" | head -1)"; found=1 ;;
      1) clean=1 ;;
    esac
  fi
  if [ "$found" -eq 1 ]; then
    return 0
  fi
  if [ "$clean" -eq 1 ]; then
    return 1
  fi
  return 2
}

# fm_tmux_worktree_live_pids: pids attributable to the checkout at <dir>,
# one pid per line, deduplicated. A process counts as live-in-the-worktree
# under THREE independent criteria (review M-b: cwd alone is too narrow -
# a reparented agent can keep running with its cwd here, but so can a build
# daemon that only holds an open file, or a wrapper whose argv names the
# checkout while its cwd lives elsewhere):
#   1. cwd is <dir> or a subdirectory (lsof -a -d cwd -F pn);
#   2. ANY open file under <dir>        (lsof +D <dir> - catches editors,
#      watchers, and log-holding daemons);
#   3. the command line names <dir>     (pgrep -f - catches wrappers and
#      runners whose cwd is elsewhere).
# TOOL CALIBRATION (round 4): a HEALTHY macOS `lsof +D` on a holderless
# directory exits 1 with no output - byte-for-byte identical to a disguised
# lsof that fakes the scan - so before ANY lsof result is believed, the
# tool is proven honest inside a PRIVATE LAB: a mktemp -d directory (0700,
# this process's own), holding OUR fd on a RANDOM-UNPREDICTABLE-NAME file
# the lab created, scanned by both lsof forms. If the lab scan does not
# report the canary path the tool did not walk the tree, and the check
# returns rc 2 UNPROVABLE. NOTHING is ever written into the project
# worktree: a fixed-name canary there could truncate a same-named project
# file or follow an attacker-planted symlink (both reproduced by review);
# a private lab with a random name closes the collision, symlink, and
# forgery attack surfaces by construction. The lab lives under a scratch
# base OUTSIDE the worktree: a caller TMPDIR inside <dir> falls back to
# /tmp, and no safe base means UNPROVABLE, so an adversarial TMPDIR cannot
# move proof scratch into the project. ABSENCE AUTHORITY stays with lsof
# alone and stays fail-closed: a TIMEOUT (rc 2) on either worktree scan,
# or any nonzero cwd-scan status, is unusable even when calibrated. A +D
# walk that prints the coverage target and exits 1 is ACCEPTED because
# macOS lsof reports that shape for a healthy walk (measured 2026-10-19);
# requiring 0 there would make every reclaim unproven. A partial +D tool
# that prints the coverage path and exits nonzero is therefore inside the
# declared trust boundary below - it is not distinguishable from the
# healthy shape without authenticating the tool. pgrep can only ADD pids
# here, never prove absence. Every caller must
# read rc 2 as `unproven`, never as `gone`. A <dir> that no longer exists
# cannot hold anything, so it returns 0 with no output. This is the
# reclaim proof's orphan guard: a tmux server death usually takes its pane
# processes with it, but a reparented survivor (launchd under jetsam) is
# exactly what relaunching a second agent would duplicate.
#
# TRUST MODEL (round 5 review; this is the declared boundary):
#   - We trust the local toolchain's lsof SEMANTICS. The proof requires:
#     (a) any timeout or suspicious result reads as UNPROVABLE (fail-closed),
#         never as absence; the cwd scan additionally requires rc 0, while
#         the +D scan accepts its measured healthy macOS rc-1-with-output
#         shape (see above), so a partial +D tool that exits nonzero after
#         printing the coverage path is inside this boundary;
#     (b) PER-WORKTREE COVERAGE PROOF: an fd we hold ourselves, opened
#         O_NOFOLLOW read-only on an EXISTING regular file inside the
#         worktree (the directory itself, opened as a directory handle, when
#         no regular file exists), must appear in the scan output - this
#         writes nothing into the project, never follows a symlink, and
#         proves the scan actually covered THIS worktree rather than merely
#         working elsewhere (the lab below);
#     (c) the trusted lsof is invoked by its resolved absolute path.
#   - The worktree path is matched in its given, /private, and physically
#     resolved spellings, so a checkout opened through a symlinked path
#     (/tmp on macOS, a linked project root) is not mistaken for uncovered.
#   - Further forgery built on top of those three requirements (for example
#     an lsof that honors this exact coverage protocol and then lies about
#     one path) is OUT OF SCOPE for this proof.
fm_tmux_worktree_live_pids() {  # <dir>
  local dir=$1 out rc pids='' lab canary escaped lsof_bin
  local holder='' coverage='' coverage_alt='' coverage_phys='' _i=0
  local dir_phys dir_alt base_phys scratch
  [ -d "$dir" ] || return 0
  lsof_bin=$(command -v lsof 2>/dev/null || true)
  [ -n "$lsof_bin" ] || return 2
  command -v perl >/dev/null 2>&1 || return 2
  # lsof reports the kernel's spelling: /tmp and logical /var paths appear
  # under /private on macOS, and a symlinked checkout appears at its target.
  # Match the given, /private, and physically resolved spellings so a valid
  # worktree is never mistaken for an uncovered one.
  dir_phys=$(cd "$dir" 2>/dev/null && pwd -P) || dir_phys=$dir
  dir_alt=$dir
  case "$dir" in
    /private/*) : ;;
    /*) dir_alt=/private$dir ;;
  esac
  # Proof scratch (the calibration lab and fm_tmux_bounded's tiny sentinel
  # files) must never land in the project. A TMPDIR that resolves to or
  # under the worktree falls back to /tmp; if no candidate is outside the
  # worktree, absence is unprovable rather than written into the project.
  scratch=${TMPDIR%/}
  [ -n "$scratch" ] || scratch=/tmp
  base_phys=$(cd "$scratch" 2>/dev/null && pwd -P) || base_phys=
  case "$base_phys" in
    ''|"$dir_phys"|"$dir_phys"/*)
      scratch=/tmp
      base_phys=$(cd /tmp 2>/dev/null && pwd -P) || base_phys=
      case "$base_phys" in
        ''|"$dir_phys"|"$dir_phys"/*) return 2 ;;
      esac
      ;;
  esac
  local TMPDIR="$scratch"
  if [ -n "$lsof_bin" ]; then
    # Private calibration lab: prove THIS lsof walks trees before any
    # worktree result is believed. Random dir + random file name, our own
    # fd, nothing project-visible. Build the lab on the safe scratch base
    # and use its physical spelling (macOS /tmp -> /private/tmp) so the
    # lsof-output greps match slash for slash.
    lab=$(mktemp -d "$scratch/fm-lsof-lab.XXXXXX" 2>/dev/null) || lab=
    if [ -n "$lab" ]; then
      lab=$(cd "$lab" 2>/dev/null && pwd -P) || lab=
    fi
    if [ -n "$lab" ]; then
      chmod 700 "$lab" 2>/dev/null || true
      canary="$lab/c.$$.$(date +%s).$RANDOM"
      : > "$canary" 2>/dev/null || true
      cal=0
      # Criterion-1 honesty: a cwd scan run INSIDE the lab must report the
      # lab path.
      out=$( ( cd "$lab" && fm_tmux_bounded env LC_ALL=C "$lsof_bin" -a -d cwd -F pn 2>/dev/null ) ) || true
      printf '%s\n' "$out" | grep -qF "$lab" || cal=1
      # Criterion-2 honesty: a +D walk of the lab must report the canary WE
      # hold open, whatever the rc. Group redirections keep a failed open or
      # close from silencing the rest of the shell's stderr.
      rc=0
      if ! { exec 9<"$canary"; } 2>/dev/null; then
        rm -rf "$lab" 2>/dev/null || true
        return 2
      fi
      out=$(fm_tmux_bounded env LC_ALL=C "$lsof_bin" +D "$lab" 2>/dev/null) || rc=$?
      { exec 9<&-; } 2>/dev/null || true
      if [ "$rc" -eq 2 ] || [ "$cal" -ne 0 ]; then
        cal=1
      elif printf '%s\n' "$out" | grep -qF "$canary"; then
        cal=0
      else
        cal=1
      fi
      rm -rf "$lab" 2>/dev/null || true
      [ "$cal" -eq 0 ] || return 2
    else
      return 2
    fi
    # PER-WORKTREE COVERAGE (trust model (b)): hold our own O_NOFOLLOW
    # read-only fd on an existing regular file inside the worktree (or the
    # directory itself) with cwd there, for the duration of both scans. The
    # scans must report it; a scan that works only in the lab and fails on
    # this worktree therefore reads unproven, never "no live processes".
    coverage=$(find "$dir" -mindepth 1 -maxdepth 2 -type f ! -type l 2>/dev/null | head -1)
    case "$coverage" in
      /private/*) coverage_alt=$coverage ;;
      /*) coverage_alt=/private$coverage ;;
      *) coverage_alt=$coverage ;;
    esac
    coverage_phys=$coverage
    case "$coverage" in
      "$dir"/*) coverage_phys="$dir_phys/${coverage#"$dir"/}" ;;
    esac
    if [ -n "$coverage" ]; then
      perl -e 'use Fcntl; chdir($ARGV[1]) or exit 9; sysopen(my $fh, $ARGV[0], O_RDONLY|O_NOFOLLOW) or exit 9; sleep 30' \
        "$coverage" "$dir" >/dev/null 2>&1 &
      holder=$!
    else
      perl -e 'chdir($ARGV[0]) or exit 9; opendir(my $dh, $ARGV[0]) or exit 9; sleep 30' \
        "$dir" >/dev/null 2>&1 &
      holder=$!
      coverage=$dir
      coverage_phys=$dir_phys
      case "$coverage" in
        /private/*) coverage_alt=$coverage ;;
        /*) coverage_alt=/private$coverage ;;
        *) coverage_alt=$coverage ;;
      esac
    fi
    # Give the holder a moment to take its fd/cwd (bounded).
    _i=0
    while [ "$_i" -lt 10 ] && ! kill -0 "$holder" 2>/dev/null; do
      _i=$((_i + 1))
      sleep 0.2
    done
    sleep 0.3
    rc=0
    out=$(fm_tmux_bounded env LC_ALL=C "$lsof_bin" -a -d cwd -F pn 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      kill "$holder" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      return 2
    fi
    # Coverage assertion 1: the cwd scan reports the holder's cwd (the
    # worktree). -F pn emits "p<pid>" then "n<cwd>".
    if ! printf '%s\n' "$out" | awk -v h="$holder" -v d="$dir" -v dalt="$dir_alt" -v dphys="$dir_phys" '
        /^p/ { pid = substr($0, 2); next }
        /^n/ { cwd = substr($0, 2); if (pid == h && (cwd == d || cwd == dalt || cwd == dphys)) { found = 1 } }
        END { exit !found }'; then
      kill "$holder" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      return 2
    fi
    pids=$pids$(printf '%s\n' "$out" | awk -v dir="$dir" -v dalt="$dir_alt" -v dphys="$dir_phys" -v h="$holder" '
      /^p/ { pid = substr($0, 2); next }
      /^n/ {
        cwd = substr($0, 2)
        if (cwd == dir || cwd == dalt || cwd == dphys ||
            (index(cwd, dir) == 1 && substr(cwd, length(dir) + 1, 1) == "/") ||
            (index(cwd, dphys) == 1 && substr(cwd, length(dphys) + 1, 1) == "/")) {
          if (pid != h) print pid
        }
      }
    ')
    rc=0
    out=$(fm_tmux_bounded env LC_ALL=C "$lsof_bin" +D "$dir" 2>/dev/null) || rc=$?
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    # rc 1 is the measured HEALTHY macOS shape: a +D walk prints every open
    # file and still exits 1 (verified 2026-10-19 on tmux 3.8 / macOS 25.6).
    # Requiring rc 0 here would make every reclaim unproven; rc 2 is a
    # timeout and stays unusable. The coverage assertion below is the
    # absence authority.
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    # Coverage assertion 2: the +D walk reports our coverage target.
    if ! printf '%s\n' "$out" | grep -qF -e "$coverage" -e "$coverage_phys" -e "$coverage_alt"; then
      return 2
    fi
    # Header line filtered; only numeric pid fields are attributions; the
    # coverage holder (our own probe) is excluded.
    pids=$pids$(printf '%s\n' "$out" | awk -v h="$holder" '$2 ~ /^[0-9]+$/ && $2 != h { print $2 }')
  fi
  if command -v pgrep >/dev/null 2>&1; then
    escaped=$(printf '%s' "$dir" | sed 's/[][(){}.^$*+?|]/\\&/g')
    rc=0
    out=$(fm_tmux_bounded pgrep -f "$escaped" 2>/dev/null) || rc=$?
    case "$rc" in
      0|1) pids=$pids$(printf '%s\n' "$out") ;;
    esac
  fi
  [ -n "$pids" ] || return 0
  printf '%s\n' "$pids" | awk 'NF > 0' | sort -n -u 2>/dev/null || printf '%s\n' "$pids"
}


# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's/cursor's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# --- tmux composer capture and capability primitives ------------------------
#
# These four functions are the ONLY tmux-specific composer knowledge left:
# how to capture a styled screen, how to read the cursor row, how to probe a
# live pi agent, and the static capability facts. Every shape, glyph, border
# family, and verdict decision lives in the shared owner
# (bin/fm-composer-lib.sh, fm_composer_classify_screen), so a new harness
# shape is taught there once and never here.

# fm_tmux_composer_capture: the visible pane WITH ANSI styling. The styled
# capture is consumed internally by the classifier and is NEVER surfaced
# (fm-peek and every human/LLM-facing path stay plain).
fm_tmux_composer_capture() {  # <target>
  fm_tmux capture-pane -e -p -t "$1" -S 0 -E - 2>/dev/null
}

# fm_tmux_composer_cursor_row: the pane's cursor row, zero-based, relative to
# the visible pane - tmux's genuine primitive that no other backend has.
fm_tmux_composer_cursor_row() {  # <target>
  fm_tmux display-message -p -t "$1" '#{cursor_y}' 2>/dev/null
}

# fm_tmux_composer_caps: the tmux capability descriptor - static data, not
# logic (see the capability model in bin/fm-composer-lib.sh).
fm_tmux_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n'
}

# fm_tmux_composer_identity: the tmux agent-identity probe backing the
# separated (pi) composer shape, tmux's analogue of herdr's native
# `agent get`. It answers only for the verified owners of that shape, from
# two live signals:
#   - identity: the pane tty's FOREGROUND process group (pgid = tpgid, the
#     same scoping as fm_backend_tmux_foreground_comms) contains a
#     shape-owner process (pi, pi-signed, pi-launcher - docs/verification/
#     runtime-backends.md "Agent liveness name sources"; polytoken, whose
#     TUI pane foreground is comm `polytoken`, verified live on 0.8.19),
#     falling back to tmux's own foreground-derived #{pane_current_command}.
#     A pane whose agent died to a shell has no shape-owner foreground
#     process and gets NO identity, which is exactly what keeps the strict
#     blank-row rule honest: a blank row between two stale rules stays
#     unknown.
#   - status: the shape owner's verified busy footer via fm_pane_is_busy,
#     mapped onto the idle/working vocabulary herdr's probe reports natively.
# It answers Command Code the same way, from its anchored `command-code`
# foreground process name and its own verified busy footer: its composer is a
# bare `❯` row between the same two rules, and its placeholder needs the
# identity-scoped ghost ceiling in bin/fm-composer-lib.sh.
# Prints "<owner><TAB>idle" or "<owner><TAB>working" for owner pi,
# polytoken, or commandcode; exits 1 when the pane is not a live shape owner.
fm_tmux_composer_identity() {  # <target>
  local target=$1 tty pgid tpgid comm owner='' status
  tty=$(fm_tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || tty=
  case "$tty" in
    /dev/*)
      while read -r _ pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        case "${comm##*/}" in
          pi|pi-signed|pi-launcher|Pi) owner=pi ;;
          polytoken) owner=polytoken ;;
          command-code) owner=commandcode ;;
        esac
        [ -n "$owner" ] && break
      done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
      ;;
  esac
  if [ -z "$owner" ]; then
    comm=$(fm_tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || comm=
    case "${comm##*/}" in
      pi|pi-signed|pi-launcher) owner=pi ;;
      polytoken) owner=polytoken ;;
    esac
  fi
  [ -n "$owner" ] || return 1
  # The busy footer read is scoped to the matched owner's own harness
  # signature (pi for the pi family, polytoken's `Running for` row, Command
  # Code's own footer) so one owner's ordinary output can never acknowledge
  # another's pane.
  status=$(fm_pane_busy_state "$target" "$owner")
  case "$status" in
    busy) printf '%s\tworking' "$owner" ;;
    idle) printf '%s\tidle' "$owner" ;;
    *) return 1 ;;
  esac
}

# fm_tmux_composer_state: the tmux composer verdict - a thin adapter over the
# shared screen classifier. The verdict contract (empty | pending |
# pending-unproven | unknown, positive proof required for empty, unrecognized
# future verdicts failing safe) is owned by bin/fm-composer-lib.sh. Identity
# is fetched lazily, only when the classifier reports the verdict depends on
# it (a pi separator pair under the cursor) or the cursor-anchored read is
# `unknown` (the Command Code check below), so an `unknown` read pays one
# process probe and a definite read never does.
fm_tmux_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local target=$1 cy pane verdict identity
  cy=$(fm_tmux_composer_cursor_row "$target") || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_tmux_composer_capture "$target") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_tmux_composer_identity "$target") || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy" "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  # Cursor Agent CLI parks its terminal cursor OUTSIDE its composer, below the
  # footer, with #{cursor_flag} 0 - so on a Cursor pane tmux's cursor row is not
  # a composer locator and the cursor-anchored read can only ever answer
  # `unknown`. Reclassify that pane the way every cursorless backend already
  # classifies it, letting the bottom-most shape win, which is the same rule
  # herdr, zellij, cmux, orca, and tern use for every harness including this one.
  # Gated on Cursor's own structural process identity, never on the verdict
  # alone, so the strict blank-row posture that owns `unknown` for every other
  # harness is untouched.
  if [ "$verdict" = unknown ] && fm_tmux_pane_is_cursor "$target"; then
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" '')
  fi
  # Cortex Code parks its terminal cursor in the first column of the blank row
  # under its footer, before and after typing (verified cortex 1.1.104 in
  # tmux), so the cursor row names no composer and the same cursorless read
  # applies, gated on its anchored foreground process name rather than on the
  # verdict alone. That proven identity is also what lets the classifier
  # accept Cortex's titled top rule (the cortex=1 capability).
  if [ "$verdict" = unknown ] && fm_tmux_pane_is_cortex "$target"; then
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)"$'\ncortex=1' "$pane" '')
  fi
  # Command Code parks its terminal cursor below its footer too, drawing its
  # own reverse-video cursor cell in the composer (verified live, Command Code
  # 1.74.1), so it takes the same cursorless reclassification, gated on its own
  # process identity and read with that identity.
  if [ "$verdict" = unknown ] && identity=$(fm_tmux_composer_identity "$target") \
     && [ "${identity%%$'\t'*}" = commandcode ]; then
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_tmux_pane_is_cortex: true when the pane's FOREGROUND process group contains
# a process named exactly `cortex` (Cortex Code is a compiled single binary, so
# its comm is that anchored word). The foreground scoping (pgid = tpgid)
# matches fm_tmux_pane_is_cursor, so a pane whose agent exited to a shell gets
# no reclassification.
fm_tmux_pane_is_cortex() {  # <target>
  local target=$1 tty pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 1
  case "$tty" in /dev/*) ;; *) return 1 ;; esac
  while read -r _ pgid tpgid comm; do
    [ -n "$comm" ] || continue
    [ "$pgid" = "$tpgid" ] || continue
    [ "${comm##*/}" = cortex ] && return 0
  done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
  return 1
}

# fm_tmux_pane_is_cursor: true when the pane's FOREGROUND process group contains
# a genuine Cursor Agent CLI process. Cursor runs as a bundled node script, so
# tmux's own #{pane_current_command} reports a bare `node`; identity therefore
# comes from Cursor's name or install tree in the command path or argv[0], whose
# single owner is bin/fm-cursor-lib.sh. The foreground scoping (pgid = tpgid)
# matches fm_tmux_composer_identity, so a pane whose agent exited to a shell has
# no Cursor foreground process and gets no reclassification.
fm_tmux_pane_is_cursor() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(fm_tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 1
  case "$tty" in /dev/*) ;; *) return 1 ;; esac
  while read -r pid pgid tpgid comm; do
    [ -n "$comm" ] || continue
    [ "$pgid" = "$tpgid" ] || continue
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    fm_cursor_process_matches "$comm" '' "$argv0" && return 0
  done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
  return 1
}

# fm_pane_input_pending: 0 when the composer is not proven empty, so pending
# text, ambiguous structure, unreadable state, and future verdicts all defer.
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" != empty ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_busy_state() {  # <target> [harness] -> busy|idle|unknown
  local win=$1 harness=${2:-} tail40 visible
  tail40=$(fm_tmux capture-pane -p -t "$win" -S -40 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || { printf 'unknown'; return 0; }
  if printf '%s' "$visible" | fm_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

fm_pane_is_busy() {  # <target> [harness]
  [ "$(fm_pane_busy_state "$1" "${2:-}")" = busy ]
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final proof-carrying verdict on stdout so callers can require
# exact `empty` before treating submission as confirmed.
# Busy-queued Enter (opencode 1.18.4): the harness accepts Enter while mid-turn
# and queues it for after the current turn, but keeps the typed text visible in
# the composer. Once the Enter-retry budget is spent and a structurally proven
# composer still reads "pending", the submit core falls back to
# `fm_pane_is_busy`: a busy pane means the Enter was accepted and queued (report
# `empty` so the caller does not re-send), while an idle pane keeps `pending` as
# a genuine swallow. Pending-unproven receives the same Enter retry budget but
# never reaches this exception.
# Turn-started confirmation (the strict blank-row posture's counterpart): a
# harness whose mid-turn screen the classifier cannot positively identify (pi
# replaces its separated composer while working) reads `unknown` right after a
# successful submit. When and only when the pane was IDLE before the text was
# typed, an idle-to-busy transition across our Enter is proof the harness
# accepted the submission - the same semantic signal herdr's native
# agent-state confirmation uses, read from the pane's verified busy footer.
# The busy read is polled across the remaining retry budget because the turn
# takes a beat to render. Without the baseline (a direct
# fm_tmux_submit_enter_core caller, or a pane already busy before typing) an
# `unknown` verdict is preserved untouched: busy conversion without the
# transition evidence could mark an undelivered message delivered.
# [busy-harness] scopes every busy read to one harness signature; the submit
# core passes polytoken for a pane whose composer identity is polytoken (its
# `Running for` row is outside the harness-less union) and nothing otherwise.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep> [baseline-idle] [busy-harness]
  local target=$1 retries=$2 sleep_s=$3 baseline_idle=${4:-} busy_harness=${5:-} i=0 j state busy_state
  while :; do
    fm_tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    # The first Enter can open a picker. A later Enter would confirm it.
    if fm_composer_blocking_dialog_noted >/dev/null; then
      printf 'unknown'
      return 0
    fi
    case "$state" in
      pending|pending-unproven) ;;
      unknown)
        if [ "$baseline_idle" = 1 ]; then
          j=0
          while [ "$j" -lt "$retries" ]; do
            if fm_pane_is_busy "$target" "$busy_harness"; then
              printf 'empty'
              return 0
            fi
            j=$((j + 1))
            [ "$j" -ge "$retries" ] || sleep "$sleep_s"
          done
        fi
        printf 'unknown'
        return 0
        ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  if [ "$state" != pending ]; then
    printf '%s' "$state"
    return 0
  fi
  # Retries exhausted, composer still shows proven pending.
  # Busy conversion is owned by fm_composer_queued_enter_verdict.
  busy_state=idle
  fm_pane_is_busy "$target" "$busy_harness" && busy_state=busy
  fm_composer_queued_enter_verdict "$state" "$busy_state"
}

# fm_tmux_submit_busy_harness: the busy-footer harness for a submit on
# <target> - polytoken when the pane's composer identity is polytoken, empty
# (the harness-less union) for every other pane.
fm_tmux_submit_busy_harness() {  # <target>
  local identity
  identity=$(fm_tmux_composer_identity "$1") || return 0
  [ "${identity%%$'\t'*}" != polytoken ] || printf 'polytoken'
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 baseline_idle='' baseline_state err busy_harness
  # The turn-started baseline must predate our own typing: a pane already
  # busy before the text lands can turn "busy" for reasons unrelated to our
  # Enter, so only a clean idle-to-busy transition may confirm a submit.
  busy_harness=$(fm_tmux_submit_busy_harness "$target")
  baseline_state=$(fm_pane_busy_state "$target" "$busy_harness")
  [ "$baseline_state" = idle ] && baseline_idle=1
  # A failed literal send replays tmux's stderr (for example "command too
  # long") so the caller can log why nothing was typed.
  if ! err=$(fm_tmux send-keys -t "$target" -l "$text" 2>&1 >/dev/null); then
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    printf 'send-failed'
    return 0
  fi
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$baseline_idle" "$busy_harness"
}
