#!/usr/bin/env bash
# fm-remote-ssh.sh - the single owner of remote-run shell mechanics for
# phase-4 SSH-pane tasks: host-registry resolution, safe SSH quoting, a
# bounded remote preflight, and git-worktree create/inspect/remove primitives
# against a registered remote host's project checkout.
#
# Run with --help for the command reference, the config/remote-hosts registry
# schema, the wire protocol, and the exit codes; that output is the exact
# contract and is not restated elsewhere.
#
# Safety rules (fixed, not configurable):
#   - Structured arguments only. Every caller-supplied value is validated
#     against a strict allowlist charset BEFORE any ssh process is spawned,
#     and is embedded into the remote script exclusively via printf %q, so no
#     free text ever becomes a shell fragment.
#   - Remote task paths are never accepted from the caller. Each primitive
#     recomputes the one permitted worktree path from the registered task
#     root, the remote project's basename, and the validated task id.
#   - Never `rm -rf`. A task path is only ever removed through
#     `git worktree remove` WITHOUT --force, after re-proving that the path
#     is the exact registered worktree, physically below the registered task
#     root, distinct from the project checkout, and clean.
#   - The remote branch fm/<task-id> is deliberately NOT deleted here:
#     branch deletion requires the handoff-reachability proof owned by the
#     later remote-aware teardown path.
#   - Unknown remote responses are refusals. Anything that is not exactly one
#     well-formed fm-remote-v1 protocol line with the expected verb and an
#     allowlisted field set refuses; absence of evidence never passes.
#   - Remote stdout is read through a fixed byte bound; an over-long response
#     is truncated and therefore refused as unparseable.
#
# No fm-spawn/fm-watch/fm-teardown path routes here yet; this is the
# foundations layer of the phase-4 remote-run series
# (data/phase4-sshpane-design-s1/report.md, PR 1).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REGISTRY="$CONFIG/remote-hosts"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

MAX_REMOTE_OUTPUT=65536

usage() {
  cat <<'EOF'
Usage: fm-remote-ssh.sh <command> [args]

Commands (structured arguments only; free-form values are refused):
  resolve <host-id>
      Validate the whole registry and print the host's entry as key=value
      lines: host=, alias=, class=, login_shell=, task_root=, handoff=.
  preflight <host-id> <remote-project>
      Bounded remote preflight. Verifies the remote user is non-root, git is
      installed, <remote-project> is the top level of a git repository, and
      the registered task root is a directory or absent. Prints host=,
      class=, uid=, project= (remote-resolved physical path), taskroot=.
  worktree-create <host-id> <remote-project> <task-id> <base-ref>
      Create the task worktree <task-root>/worktrees/<basename-of-project>/
      <task-id> on branch fm/<task-id> at <base-ref>, then re-read and verify
      registration, top level, containment, branch, and head before
      reporting. Prints path=, branch=, head=, base_oid=.
  worktree-inspect <host-id> <remote-project> <task-id>
      Report structural facts about the task worktree. Prints state=absent,
      or state=worktree with path=, branch=, head=, clean= (a boolean only,
      never filenames). A path that exists but is not the exact registered,
      contained task worktree on branch fm/<task-id> is a refusal.
  worktree-remove <host-id> <remote-project> <task-id>
      Remove the task worktree via `git worktree remove` (never --force,
      never rm -rf) after re-proving registration, containment, branch
      identity, and cleanliness. Refuses dirty, unregistered, out-of-root,
      or absent paths. The fm/<task-id> branch is left in place. Prints
      path=, branch=.
  --help
      Print this reference.

Registry (config/remote-hosts; local, gitignored; this block is the schema):
  One host per non-empty, non-comment line, whitespace-separated:
    <host-id> alias=<ssh-alias> class=<client|non-client> \
      login-shell=<yes|no> task-root=<absolute-path> \
      handoff=<git-remote>[,<git-remote>...]
  host-id      [a-z0-9-], no leading dash, max 64 chars, unique per file.
  alias        the ssh_config alias to connect through; [A-Za-z0-9._-], no
               leading dash. Connection settings (keys, host names, ports)
               belong in ssh_config, never here.
  class        client or non-client; recorded and reported so callers can
               gate policy, never interpreted by this helper.
  login-shell  yes runs remote commands via `bash -lc`, no via `bash -c`.
  task-root    the ONLY remote directory tree task worktrees may live under;
               absolute, [A-Za-z0-9._/-], no dot components, no trailing or
               doubled slash.
  handoff      comma-separated git remote names approved for handoff pushes;
               schema-only in this PR, consumed by later delivery wiring.
  All five fields are required exactly once; unknown keys, duplicates, and
  malformed lines anywhere in the file refuse the whole registry.

Wire protocol (remote -> local): every remote script emits exactly one line
  fm-remote-v1 <verb> <key>=<value>...     on success, or
  fm-remote-v1 refuse reason=<code>        on a remote-side refusal.
Values are limited to [A-Za-z0-9._/-]; anything else, a missing line, a
duplicate line, an unexpected verb, or an unknown field is a local refusal.

Environment:
  FM_REMOTE_SSH_CONNECT_TIMEOUT  ssh ConnectTimeout seconds (default 10).
  FM_REMOTE_SSH_DEADLINE         overall wall-clock deadline in seconds for
                                 each remote call (default 120); a remote
                                 command still running at the deadline is
                                 killed and the call refuses.
  FM_CONFIG_OVERRIDE             alternate config directory (testing).

Exit codes: 0 success; 1 registry, transport, protocol, or remote refusal;
2 usage or invalid argument.
EOF
}

err() { printf 'fm-remote-ssh.sh: error: %s\n' "$1" >&2; }
refuse() { err "$1"; exit 1; }
usage_error() { err "$1"; echo "run: fm-remote-ssh.sh --help" >&2; exit 2; }

# --- local argument validation (all fail closed, LC_ALL=C charsets) ---------

valid_host_id() {
  local id=${1-}
  local LC_ALL=C
  [ "${#id}" -le 64 ] || return 1
  case "$id" in ''|-*|*[!a-z0-9-]*) return 1 ;; esac
}

valid_alias() {
  local a=${1-}
  local LC_ALL=C
  [ "${#a}" -le 128 ] || return 1
  case "$a" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

valid_remote_name() {
  local r=${1-}
  local LC_ALL=C
  [ "${#r}" -le 128 ] || return 1
  case "$r" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

valid_abs_path() {
  local p=${1-}
  local LC_ALL=C
  [ "${#p}" -le 512 ] || return 1
  case "$p" in ''|[!/]*|*//*|*/) return 1 ;; esac
  case "$p" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$p" in */..|*/../*|*/.|*/./*) return 1 ;; esac
}

valid_base_ref() {
  local r=${1-}
  local LC_ALL=C
  [ "${#r}" -le 256 ] || return 1
  case "$r" in ''|-*|/*|*[!A-Za-z0-9./_-]*) return 1 ;; esac
  case "$r" in *..*|*//*|*/|*.lock) return 1 ;; esac
}

valid_oid() {
  local o=${1-}
  local LC_ALL=C
  case "$o" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#o}" -eq 40 ] || [ "${#o}" -eq 64 ]
}

# --- registry --------------------------------------------------------------

HOST_ID=
HOST_ALIAS=
HOST_CLASS=
HOST_LOGIN_SHELL=
HOST_TASK_ROOT=
HOST_HANDOFF=

# parse_registry <host-id>: validate the ENTIRE registry file (any malformed
# line anywhere refuses, so a typo in a security field can never be silently
# skipped), then load the requested host into HOST_*.
parse_registry() {
  local want=$1 line lineno=0 seen=' ' found=no
  local id halias hclass hlogin hroot hhandoff tok key val r i
  local -a toks remotes
  [ -e "$REGISTRY" ] || refuse "no remote host registry (config/remote-hosts)"
  { [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; } \
    || refuse "remote host registry is not a regular file"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    toks=()
    read -r -a toks <<<"$line" || true
    [ "${#toks[@]}" -gt 0 ] || continue
    case "${toks[0]}" in '#'*) continue ;; esac
    id=${toks[0]}
    valid_host_id "$id" \
      || refuse "config/remote-hosts line $lineno: invalid host id"
    case "$seen" in
      *" $id "*) refuse "config/remote-hosts line $lineno: duplicate host id '$id'" ;;
    esac
    seen="$seen$id "
    halias=''
    hclass=''
    hlogin=''
    hroot=''
    hhandoff=''
    for ((i = 1; i < ${#toks[@]}; i++)); do
      tok=${toks[$i]}
      key=${tok%%=*}
      val=${tok#*=}
      [ "$key" != "$tok" ] && [ -n "$key" ] \
        || refuse "config/remote-hosts line $lineno: not a key=value field: '$tok'"
      case "$key" in
        alias)
          [ -z "$halias" ] || refuse "config/remote-hosts line $lineno: duplicate alias="
          valid_alias "$val" || refuse "config/remote-hosts line $lineno: invalid alias value"
          halias=$val ;;
        class)
          [ -z "$hclass" ] || refuse "config/remote-hosts line $lineno: duplicate class="
          case "$val" in client|non-client) : ;; *)
            refuse "config/remote-hosts line $lineno: class must be client or non-client" ;;
          esac
          hclass=$val ;;
        login-shell)
          [ -z "$hlogin" ] || refuse "config/remote-hosts line $lineno: duplicate login-shell="
          case "$val" in yes|no) : ;; *)
            refuse "config/remote-hosts line $lineno: login-shell must be yes or no" ;;
          esac
          hlogin=$val ;;
        task-root)
          [ -z "$hroot" ] || refuse "config/remote-hosts line $lineno: duplicate task-root="
          valid_abs_path "$val" \
            || refuse "config/remote-hosts line $lineno: task-root must be a clean absolute path"
          hroot=$val ;;
        handoff)
          [ -z "$hhandoff" ] || refuse "config/remote-hosts line $lineno: duplicate handoff="
          case "$val" in ''|,*|*,|*,,*)
            refuse "config/remote-hosts line $lineno: invalid handoff list" ;;
          esac
          remotes=()
          IFS=, read -r -a remotes <<<"$val" || true
          [ "${#remotes[@]}" -ge 1 ] \
            || refuse "config/remote-hosts line $lineno: invalid handoff list"
          for r in "${remotes[@]}"; do
            valid_remote_name "$r" \
              || refuse "config/remote-hosts line $lineno: invalid handoff remote name"
          done
          hhandoff=$val ;;
        *)
          refuse "config/remote-hosts line $lineno: unknown key '$key'" ;;
      esac
    done
    { [ -n "$halias" ] && [ -n "$hclass" ] && [ -n "$hlogin" ] \
      && [ -n "$hroot" ] && [ -n "$hhandoff" ]; } \
      || refuse "config/remote-hosts line $lineno: missing required field (need alias, class, login-shell, task-root, handoff)"
    if [ "$id" = "$want" ]; then
      HOST_ID=$id
      HOST_ALIAS=$halias
      HOST_CLASS=$hclass
      HOST_LOGIN_SHELL=$hlogin
      HOST_TASK_ROOT=$hroot
      HOST_HANDOFF=$hhandoff
      found=yes
    fi
  done <"$REGISTRY"
  [ "$found" = yes ] || refuse "unknown remote host: '$want' (not in config/remote-hosts)"
}

# --- transport -------------------------------------------------------------

REMOTE_OUT=

# run_with_deadline <seconds> <command...>: enforce an overall wall-clock
# bound on one remote call, via timeout/gtimeout when available and a perl
# alarm watchdog otherwise; every path exits 124 when the deadline expires,
# matching timeout(1).
run_with_deadline() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 } my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$secs" "$@"
  fi
}

# remote_run <script>: run <script> on HOST_ALIAS through bash -lc/-c per
# HOST_LOGIN_SHELL, with BatchMode (never an interactive prompt), a bounded
# connect timeout, keepalive bounds, an overall wall-clock deadline, and a
# fixed stdout byte cap. The script text is embedded via printf %q so it
# crosses ssh as one argument.
remote_run() {
  local script=$1 flags rc deadline
  deadline=${FM_REMOTE_SSH_DEADLINE:-120}
  case "$deadline" in ''|0*|*[!0-9]*)
    refuse "FM_REMOTE_SSH_DEADLINE must be a positive integer (seconds)" ;;
  esac
  if [ "$HOST_LOGIN_SHELL" = yes ]; then flags='-lc'; else flags='-c'; fi
  REMOTE_OUT=$(
    run_with_deadline "$deadline" ssh -o BatchMode=yes \
      -o ConnectTimeout="${FM_REMOTE_SSH_CONNECT_TIMEOUT:-10}" \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
      -- "$HOST_ALIAS" "bash $flags $(printf '%q' "$script")" \
      | head -c "$MAX_REMOTE_OUTPUT"
    exit "${PIPESTATUS[0]}"
  )
  rc=$?
  [ "$rc" -ne 124 ] \
    || refuse "remote host '$HOST_ID' hit the ${deadline}s wall-clock deadline (FM_REMOTE_SSH_DEADLINE)"
  [ "$rc" -eq 0 ] \
    || refuse "remote host '$HOST_ID' unreachable or remote command failed (ssh exit $rc)"
}

# build_prelude <name> <value>...: emit one shell assignment per pair, with
# the value rendered by printf %q. This is the ONLY way caller data enters a
# remote script.
build_prelude() {
  while [ "$#" -ge 2 ]; do
    printf '%s=%q\n' "$1" "$2"
    shift 2
  done
}

# --- wire-protocol parsing (unknown responses are refusals) ----------------

RESP_TOKENS=()

# parse_response <expected-verb> "<allowed keys>": require exactly one
# well-formed fm-remote-v1 line in REMOTE_OUT, translate a remote refuse into
# a local refusal, and load validated key=value tokens into RESP_TOKENS.
parse_response() {
  local verb=$1 allowed=" $2 " line proto='' tok key val keys_seen=' ' i
  local -a toks
  while IFS= read -r line; do
    case "$line" in
      'fm-remote-v1 '*)
        [ -z "$proto" ] || refuse "unexpected remote response (multiple protocol lines)"
        proto=$line ;;
    esac
  done <<<"$REMOTE_OUT"
  [ -n "$proto" ] || refuse "unexpected remote response (no protocol line)"
  toks=()
  read -r -a toks <<<"$proto" || true
  [ "${#toks[@]}" -ge 2 ] || refuse "unexpected remote response"
  if [ "${toks[1]}" = refuse ]; then
    [ "${#toks[@]}" -eq 3 ] || refuse "unexpected remote response"
    case "${toks[2]}" in
      reason=*)
        val=${toks[2]#reason=}
        case "$val" in ''|*[!a-z0-9-]*) refuse "unexpected remote response" ;; esac
        refuse "remote refused: $val" ;;
      *) refuse "unexpected remote response" ;;
    esac
  fi
  [ "${toks[1]}" = "$verb" ] || refuse "unexpected remote response (verb mismatch)"
  RESP_TOKENS=()
  for ((i = 2; i < ${#toks[@]}; i++)); do
    tok=${toks[$i]}
    key=${tok%%=*}
    val=${tok#*=}
    [ "$key" != "$tok" ] && [ -n "$key" ] || refuse "unexpected remote response"
    case "$key" in *[!a-z_]*) refuse "unexpected remote response" ;; esac
    case "$allowed" in *" $key "*) : ;; *)
      refuse "unexpected remote response (unknown field '$key')" ;;
    esac
    case "$keys_seen" in *" $key "*)
      refuse "unexpected remote response (duplicate field '$key')" ;;
    esac
    keys_seen="$keys_seen$key "
    case "$val" in ''|*[!A-Za-z0-9._/-]*) refuse "unexpected remote response (bad value)" ;; esac
    [ "${#val}" -le 512 ] || refuse "unexpected remote response (bad value)"
    RESP_TOKENS+=("$tok")
  done
}

resp_get() {
  local t
  for t in ${RESP_TOKENS[@]+"${RESP_TOKENS[@]}"}; do
    case "$t" in "$1"=*)
      printf '%s\n' "${t#*=}"
      return 0 ;;
    esac
  done
  return 1
}

resp_require() {
  resp_get "$1" || refuse "unexpected remote response (missing field '$1')"
}

# --- remote script bodies (static single-quoted text, expanded remotely) ---

# The remote bodies below are deliberately single-quoted: their $vars expand
# on the REMOTE side, seeded only by build_prelude's printf-%q assignments.
# shellcheck disable=SC2016

# Shared: verify git exists and $proj is the physical top level of a repo.
REMOTE_COMMON='
LC_ALL=C
export LC_ALL
command -v git >/dev/null 2>&1 || { printf "fm-remote-v1 refuse reason=git-missing\n"; exit 0; }
[ -d "$proj" ] || { printf "fm-remote-v1 refuse reason=project-missing\n"; exit 0; }
proj_phys=$(cd "$proj" && pwd -P) || { printf "fm-remote-v1 refuse reason=project-unreadable\n"; exit 0; }
top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null) || { printf "fm-remote-v1 refuse reason=not-a-repo\n"; exit 0; }
top_phys=$(cd "$top" && pwd -P) || { printf "fm-remote-v1 refuse reason=not-a-repo\n"; exit 0; }
[ "$top_phys" = "$proj_phys" ] || { printf "fm-remote-v1 refuse reason=project-not-toplevel\n"; exit 0; }
'

# Shared: resolve $dest physically and prove containment strictly below
# $root plus that it is a worktree whose top level is $dest itself.
# shellcheck disable=SC2016
REMOTE_DEST_CHECK='
[ -d "$dest" ] || { printf "fm-remote-v1 refuse reason=path-not-dir\n"; exit 0; }
dest_phys=$(cd "$dest" && pwd -P) || { printf "fm-remote-v1 refuse reason=path-unreadable\n"; exit 0; }
root_phys=$(cd "$root" && pwd -P) || { printf "fm-remote-v1 refuse reason=task-root-unreadable\n"; exit 0; }
case "$dest_phys/" in "$root_phys"/?*) : ;; *) printf "fm-remote-v1 refuse reason=out-of-root\n"; exit 0 ;; esac
[ "$dest_phys" != "$proj_phys" ] || { printf "fm-remote-v1 refuse reason=path-is-project\n"; exit 0; }
wt_top=$(git -C "$dest" rev-parse --show-toplevel 2>/dev/null) || { printf "fm-remote-v1 refuse reason=not-a-worktree\n"; exit 0; }
wt_top_phys=$(cd "$wt_top" && pwd -P) || { printf "fm-remote-v1 refuse reason=not-a-worktree\n"; exit 0; }
[ "$wt_top_phys" = "$dest_phys" ] || { printf "fm-remote-v1 refuse reason=toplevel-mismatch\n"; exit 0; }
'

# Shared: prove $dest_phys is registered in $proj's `git worktree list`.
# shellcheck disable=SC2016
REMOTE_REG_CHECK='
registered=no
while IFS= read -r wline; do
  case "$wline" in
    "worktree "*)
      wpath=${wline#worktree }
      if [ -d "$wpath" ]; then
        wphys=$(cd "$wpath" && pwd -P) || continue
        [ "$wphys" = "$dest_phys" ] && registered=yes
      fi
      ;;
  esac
done <<FM_WT_LIST
$(git -C "$proj" worktree list --porcelain)
FM_WT_LIST
[ "$registered" = yes ] || { printf "fm-remote-v1 refuse reason=unregistered\n"; exit 0; }
'

# Shared: read branch, head, and a clean/dirty BOOLEAN (never filenames).
# shellcheck disable=SC2016
REMOTE_STATE_READ='
cur_branch=$(git -C "$dest" rev-parse --abbrev-ref HEAD 2>/dev/null) || { printf "fm-remote-v1 refuse reason=head-unreadable\n"; exit 0; }
head_oid=$(git -C "$dest" rev-parse HEAD 2>/dev/null) || { printf "fm-remote-v1 refuse reason=head-unreadable\n"; exit 0; }
status_out=$(git -C "$dest" status --porcelain 2>/dev/null) || { printf "fm-remote-v1 refuse reason=status-unreadable\n"; exit 0; }
clean=yes
[ -z "$status_out" ] || clean=no
'

# shellcheck disable=SC2016
REMOTE_PREFLIGHT_BODY='
set -u
uid=$(id -u) || exit 9
'"$REMOTE_COMMON"'
if [ -e "$root" ] && [ ! -d "$root" ]; then printf "fm-remote-v1 refuse reason=task-root-not-dir\n"; exit 0; fi
rootstate=absent
[ -d "$root" ] && rootstate=dir
printf "fm-remote-v1 preflight uid=%s project=%s taskroot=%s\n" "$uid" "$proj_phys" "$rootstate"
'

# shellcheck disable=SC2016
REMOTE_CREATE_BODY='
set -u
'"$REMOTE_COMMON"'
[ ! -e "$dest" ] || { printf "fm-remote-v1 refuse reason=path-exists\n"; exit 0; }
if git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
  printf "fm-remote-v1 refuse reason=branch-exists\n"; exit 0
fi
base_oid=$(git -C "$proj" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null) || { printf "fm-remote-v1 refuse reason=base-ref-unknown\n"; exit 0; }
mkdir -p "$destdir" 2>/dev/null || { printf "fm-remote-v1 refuse reason=task-root-unwritable\n"; exit 0; }
git -C "$proj" worktree add -b "$branch" "$dest" "$base_oid" >/dev/null 2>&1 || { printf "fm-remote-v1 refuse reason=worktree-add-failed\n"; exit 0; }
'"$REMOTE_DEST_CHECK"'
'"$REMOTE_REG_CHECK"'
'"$REMOTE_STATE_READ"'
[ "$head_oid" = "$base_oid" ] || { printf "fm-remote-v1 refuse reason=head-mismatch\n"; exit 0; }
[ "$cur_branch" = "$branch" ] || { printf "fm-remote-v1 refuse reason=branch-mismatch\n"; exit 0; }
printf "fm-remote-v1 worktree-create path=%s branch=%s head=%s base_oid=%s\n" "$dest_phys" "$branch" "$head_oid" "$base_oid"
'

# shellcheck disable=SC2016
REMOTE_INSPECT_BODY='
set -u
'"$REMOTE_COMMON"'
if [ ! -e "$dest" ]; then printf "fm-remote-v1 worktree-inspect state=absent\n"; exit 0; fi
'"$REMOTE_DEST_CHECK"'
'"$REMOTE_REG_CHECK"'
'"$REMOTE_STATE_READ"'
printf "fm-remote-v1 worktree-inspect state=worktree path=%s branch=%s head=%s clean=%s\n" "$dest_phys" "$cur_branch" "$head_oid" "$clean"
'

# shellcheck disable=SC2016
REMOTE_REMOVE_BODY='
set -u
'"$REMOTE_COMMON"'
[ -e "$dest" ] || { printf "fm-remote-v1 refuse reason=path-not-dir\n"; exit 0; }
'"$REMOTE_DEST_CHECK"'
'"$REMOTE_REG_CHECK"'
'"$REMOTE_STATE_READ"'
[ "$cur_branch" = "$branch" ] || { printf "fm-remote-v1 refuse reason=branch-mismatch\n"; exit 0; }
[ "$clean" = yes ] || { printf "fm-remote-v1 refuse reason=dirty\n"; exit 0; }
git -C "$proj" worktree remove "$dest" >/dev/null 2>&1 || { printf "fm-remote-v1 refuse reason=remove-failed\n"; exit 0; }
[ ! -e "$dest" ] || { printf "fm-remote-v1 refuse reason=remove-incomplete\n"; exit 0; }
printf "fm-remote-v1 worktree-remove path=%s branch=%s\n" "$dest_phys" "$branch"
'

# --- shared command argument handling ---------------------------------------

TASK_PROJ=
TASK_DEST=
TASK_BRANCH=

# task_args <host-id> <remote-project> <task-id>: validate and derive the one
# permitted worktree path and branch for this task on this host.
task_args() {
  local host=$1 proj=$2 id=$3 slug
  valid_host_id "$host" || usage_error "invalid host id"
  parse_registry "$host"
  valid_abs_path "$proj" \
    || usage_error "remote project must be a clean absolute path"
  fm_task_id_creation_valid "$id" || usage_error "invalid task id"
  slug=$(basename "$proj")
  TASK_PROJ=$proj
  TASK_DEST="$HOST_TASK_ROOT/worktrees/$slug/$id"
  TASK_BRANCH="fm/$id"
}

# --- commands ---------------------------------------------------------------

cmd_resolve() {
  [ "$#" -eq 1 ] || usage_error "resolve takes exactly: <host-id>"
  valid_host_id "$1" || usage_error "invalid host id"
  parse_registry "$1"
  printf 'host=%s\n' "$HOST_ID"
  printf 'alias=%s\n' "$HOST_ALIAS"
  printf 'class=%s\n' "$HOST_CLASS"
  printf 'login_shell=%s\n' "$HOST_LOGIN_SHELL"
  printf 'task_root=%s\n' "$HOST_TASK_ROOT"
  printf 'handoff=%s\n' "$HOST_HANDOFF"
}

cmd_preflight() {
  [ "$#" -eq 2 ] || usage_error "preflight takes exactly: <host-id> <remote-project>"
  local host=$1 proj=$2 script uid project taskroot
  valid_host_id "$host" || usage_error "invalid host id"
  parse_registry "$host"
  valid_abs_path "$proj" \
    || usage_error "remote project must be a clean absolute path"
  script="$(build_prelude proj "$proj" root "$HOST_TASK_ROOT")
$REMOTE_PREFLIGHT_BODY"
  remote_run "$script"
  parse_response preflight "uid project taskroot"
  uid=$(resp_require uid)
  project=$(resp_require project)
  taskroot=$(resp_require taskroot)
  case "$uid" in *[!0-9]*) refuse "unexpected remote response (bad uid)" ;; esac
  [ "$uid" != 0 ] || refuse "remote user on host '$HOST_ID' is root; a non-root remote account is required"
  valid_abs_path "$project" || refuse "unexpected remote response (bad project path)"
  case "$taskroot" in dir|absent) : ;; *) refuse "unexpected remote response (bad taskroot)" ;; esac
  printf 'host=%s\n' "$HOST_ID"
  printf 'class=%s\n' "$HOST_CLASS"
  printf 'uid=%s\n' "$uid"
  printf 'project=%s\n' "$project"
  printf 'taskroot=%s\n' "$taskroot"
}

cmd_worktree_create() {
  [ "$#" -eq 4 ] || usage_error "worktree-create takes exactly: <host-id> <remote-project> <task-id> <base-ref>"
  local base=$4 script path branch head base_oid
  task_args "$1" "$2" "$3"
  valid_base_ref "$base" || usage_error "invalid base ref"
  script="$(build_prelude proj "$TASK_PROJ" root "$HOST_TASK_ROOT" \
    destdir "$(dirname "$TASK_DEST")" dest "$TASK_DEST" \
    branch "$TASK_BRANCH" base "$base")
$REMOTE_CREATE_BODY"
  remote_run "$script"
  parse_response worktree-create "path branch head base_oid"
  path=$(resp_require path)
  branch=$(resp_require branch)
  head=$(resp_require head)
  base_oid=$(resp_require base_oid)
  valid_abs_path "$path" || refuse "unexpected remote response (bad path)"
  [ "$branch" = "$TASK_BRANCH" ] || refuse "unexpected remote response (branch mismatch)"
  valid_oid "$head" || refuse "unexpected remote response (bad head oid)"
  valid_oid "$base_oid" || refuse "unexpected remote response (bad base oid)"
  printf 'path=%s\n' "$path"
  printf 'branch=%s\n' "$branch"
  printf 'head=%s\n' "$head"
  printf 'base_oid=%s\n' "$base_oid"
}

cmd_worktree_inspect() {
  [ "$#" -eq 3 ] || usage_error "worktree-inspect takes exactly: <host-id> <remote-project> <task-id>"
  local script state path branch head clean
  task_args "$1" "$2" "$3"
  script="$(build_prelude proj "$TASK_PROJ" root "$HOST_TASK_ROOT" dest "$TASK_DEST")
$REMOTE_INSPECT_BODY"
  remote_run "$script"
  parse_response worktree-inspect "state path branch head clean"
  state=$(resp_require state)
  if [ "$state" = absent ]; then
    printf 'state=absent\n'
    return 0
  fi
  [ "$state" = worktree ] || refuse "unexpected remote response (bad state)"
  path=$(resp_require path)
  branch=$(resp_require branch)
  head=$(resp_require head)
  clean=$(resp_require clean)
  valid_abs_path "$path" || refuse "unexpected remote response (bad path)"
  [ "$branch" = "$TASK_BRANCH" ] \
    || refuse "remote worktree is on branch '$branch', not the task branch '$TASK_BRANCH'"
  valid_oid "$head" || refuse "unexpected remote response (bad head oid)"
  case "$clean" in yes|no) : ;; *) refuse "unexpected remote response (bad clean flag)" ;; esac
  printf 'state=worktree\n'
  printf 'path=%s\n' "$path"
  printf 'branch=%s\n' "$branch"
  printf 'head=%s\n' "$head"
  printf 'clean=%s\n' "$clean"
}

cmd_worktree_remove() {
  [ "$#" -eq 3 ] || usage_error "worktree-remove takes exactly: <host-id> <remote-project> <task-id>"
  local script path branch
  task_args "$1" "$2" "$3"
  script="$(build_prelude proj "$TASK_PROJ" root "$HOST_TASK_ROOT" \
    dest "$TASK_DEST" branch "$TASK_BRANCH")
$REMOTE_REMOVE_BODY"
  remote_run "$script"
  parse_response worktree-remove "path branch"
  path=$(resp_require path)
  branch=$(resp_require branch)
  valid_abs_path "$path" || refuse "unexpected remote response (bad path)"
  [ "$branch" = "$TASK_BRANCH" ] || refuse "unexpected remote response (branch mismatch)"
  printf 'path=%s\n' "$path"
  printf 'branch=%s\n' "$branch"
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -ge 1 ] || usage_error "missing command"
COMMAND=$1
shift
case "$COMMAND" in
  --help|-h|help) usage ;;
  resolve) cmd_resolve "$@" ;;
  preflight) cmd_preflight "$@" ;;
  worktree-create) cmd_worktree_create "$@" ;;
  worktree-inspect) cmd_worktree_inspect "$@" ;;
  worktree-remove) cmd_worktree_remove "$@" ;;
  *) usage_error "unknown command: $COMMAND" ;;
esac
