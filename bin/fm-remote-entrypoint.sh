#!/usr/bin/env bash
# Fixed remote entrypoint for bin/fm-on.sh.
#
# Install this tracked file as fm-remote-entrypoint.sh on the remote account's
# non-interactive SSH PATH. It accepts protocol metadata plus a base64-encoded
# NUL argv stream, validates one genuine tracked executable in <root>/bin/fm-*.sh,
# then stages it for the Firstmate-owned remote job worker. It never accepts a
# shell command string.
#
# The readiness-owning fm-remote-doctor.sh runs in this plain SSH bootstrap so
# check mode can inspect worker gaps without changing them and --fix can repair
# them. Every other command is staged after the worker is ready. On Darwin, a
# missing Aqua session fails before staging with the doctor-actionable
# console-login diagnostic. Linux uses the same queue and worker shape without
# an Aqua requirement.
#
# stdin is captured as bounded job input. The completed worker result is relayed
# with stdout and stderr kept separate and its exit status preserved. An SSH
# disconnect remains unknown completion to fm-on.sh, which preserves OpenSSH's
# exit 255 behavior. The shared library header owns job fields, bounds, PATH,
# LaunchAgent contract, and worker environment.
#
# A staged job whose caller goes away is cancelled rather than abandoned: any
# exit after staging and before the published result marks the job cancelled
# (signal traps cover a delivered HUP/TERM/PIPE/INT, and the exit trap covers a
# failed bounded wait), and while waiting this process probes its parent about
# once per second, so an ssh channel that dies without delivering any signal -
# sshd exiting and reparenting this process - also cancels the job. The worker
# then skips or stops the cancelled job instead of running it to completion for
# nobody.
set -eu

PROTOCOL=1
DOCTOR_SHA256=7bb13d9fad8455978bf109d4681a3aa3cb170565c8a74be4ec7b520427db14c2
REAL_SOURCE=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}" 2>/dev/null) ||
  REAL_SOURCE=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) ||
  REAL_SOURCE=${BASH_SOURCE[0]}
SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$REAL_SOURCE")" && pwd -P)

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-64}"; }

base64_decode_to() { # <encoded> <destination>
  local encoded=$1 destination=$2
  if printf '%s' "$encoded" | base64 --decode > "$destination" 2>/dev/null; then return 0; fi
  if printf '%s' "$encoded" | base64 -D > "$destination" 2>/dev/null; then return 0; fi
  return 1
}

decode_text() { # <label> <encoded> <destination>
  local label=$1 encoded=$2 destination=$3 bytes controls
  base64_decode_to "$encoded" "$destination" || die "invalid base64 for $label"
  bytes=$(LC_ALL=C wc -c < "$destination" | tr -d ' ')
  [ "$bytes" -gt 0 ] || die "$label is empty"
  controls=$(fm_remote_job_has_forbidden_text_bytes "$destination")
  [ "$controls" -eq 0 ] || die "$label contains forbidden control bytes"
}

path_is_ancestor() { # <ancestor> <path>
  [ "$1" != "$2" ] || return 1
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}

sha256_file() { # <path>
  local path=$1 digest extra
  if [ -x /usr/bin/shasum ]; then
    read -r digest extra < <(/usr/bin/shasum -a 256 "$path") || return 1
  elif [ -x /usr/bin/sha256sum ]; then
    read -r digest extra < <(/usr/bin/sha256sum "$path") || return 1
  elif [ -x /bin/sha256sum ]; then
    read -r digest extra < <(/bin/sha256sum "$path") || return 1
  else
    return 1
  fi
  case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$digest"
}

[ "$#" -eq 4 ] || die "remote entrypoint expects protocol, root, home, and argv"
[ "$1" = "$PROTOCOL" ] || die "incompatible remote protocol: local=$1 remote=$PROTOCOL"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-entrypoint.XXXXXX") || die "cannot create protocol staging directory" 70

JOB_ID=
JOB_COMPLETED=0
ACCOUNT_HOME=
ENTRYPOINT_PPID=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || true)

# The recorded parent is the ssh session process; when it disappears this
# process is reparented and the caller is provably gone. An unreadable probe
# never cancels: only an observed parent change does.
# shellcheck disable=SC2329 # Invoked by fm_remote_job_wait through FM_REMOTE_JOB_DISCONNECT_PROBE.
entrypoint_caller_connected() {
  local current
  case "$ENTRYPOINT_PPID" in ''|*[!0-9]*) return 0 ;; esac
  current=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || true)
  case "$current" in ''|*[!0-9]*) return 0 ;; esac
  [ "$current" = "$ENTRYPOINT_PPID" ]
}

# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
entrypoint_cleanup() {
  rm -rf -- "$TMP"
  if [ -n "$JOB_ID" ] && [ "$JOB_COMPLETED" -eq 0 ] && [ -n "$ACCOUNT_HOME" ]; then
    fm_remote_job_cancel "$ACCOUNT_HOME" "$JOB_ID" 2>/dev/null || true
  fi
}
trap entrypoint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 141' PIPE
trap 'exit 143' TERM

decode_text "remote root" "$2" "$TMP/root"
decode_text "remote home" "$3" "$TMP/home"
base64_decode_to "$4" "$TMP/argv" || die "invalid base64 for argv"
ROOT=$(<"$TMP/root")
HOME_PATH=$(<"$TMP/home")
ROOT=$(fm_remote_job_canonical_existing_dir "$ROOT") || die "remote root is not a safe existing directory"
HOME_PATH=$(fm_remote_job_canonical_home "$HOME_PATH") || die "remote home is not a safe directory"
[ -f "$ROOT/AGENTS.md" ] && [ ! -L "$ROOT/AGENTS.md" ] || die "remote root is not a Firstmate checkout"
[ -d "$ROOT/bin" ] && [ ! -L "$ROOT/bin" ] || die "remote root has no safe bin directory"
if path_is_ancestor "$ROOT" "$HOME_PATH" || path_is_ancestor "$HOME_PATH" "$ROOT" || [ "$ROOT" = "$HOME_PATH" ]; then
  die "remote root and home must be separate, non-overlapping directories"
fi

ARGV=()
while IFS= read -r -d '' arg; do ARGV+=("$arg"); done < "$TMP/argv"
[ "${#ARGV[@]}" -ge 1 ] || die "argv contains no command"
COMMAND=${ARGV[0]}
case "$COMMAND" in fm-*.sh) ;; *) die "command is outside the fm-*.sh namespace: $COMMAND" ;; esac
case "$COMMAND" in */*|*..*) die "command contains a path or traversal: $COMMAND" ;; esac
COMMAND_PATH="$ROOT/bin/$COMMAND"
[ -f "$COMMAND_PATH" ] && [ ! -L "$COMMAND_PATH" ] && [ -x "$COMMAND_PATH" ] \
  || die "command is not a genuine executable in the configured remote root: $COMMAND"
unset HOME
ACCOUNT_HOME=$(CDPATH='' cd ~ 2>/dev/null && pwd -P) || die "cannot resolve the remote account home"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
GIT_BIN=$(fm_remote_job_operator_tool git 2>/dev/null || true)
if [ -n "$GIT_BIN" ]; then
  "$GIT_BIN" -C "$ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
    || die "command is not tracked by the configured remote root: $COMMAND"
elif [ "$COMMAND" = fm-remote-doctor.sh ]; then
  ACTUAL_DOCTOR_SHA256=$(sha256_file "$COMMAND_PATH") \
    || die "required tool git is unavailable and the doctor bootstrap identity cannot be verified"
  [ "$ACTUAL_DOCTOR_SHA256" = "$DOCTOR_SHA256" ] \
    || die "required tool git is unavailable and the doctor does not match the trusted bootstrap identity"
else
  die "required tool git does not resolve on the remote operator PATH; install git there or put a wrapper for it in ~/.local/bin using the recipe in docs/remote-secondmates.md"
fi
if [ "$COMMAND" = fm-remote-doctor.sh ]; then
  fm_remote_job_build_child_path "$ROOT" >/dev/null
  DOCTOR_ENV=(
    /usr/bin/env -i
    "PATH=$FM_REMOTE_JOB_CHILD_PATH"
    "HOME=$ACCOUNT_HOME"
    "FM_HOME=$HOME_PATH"
    "FM_ROOT_OVERRIDE=$ROOT"
    FM_REMOTE_DOCTOR_BOOTSTRAP=1
  )
  if [ -n "${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-}" ]; then
    DOCTOR_ENV+=("FM_REMOTE_JOB_PLATFORM_OVERRIDE=$FM_REMOTE_JOB_PLATFORM_OVERRIDE")
  fi
  if [ -n "${FM_REMOTE_JOB_STATE_ROOT:-}" ]; then
    DOCTOR_ENV+=("FM_REMOTE_JOB_STATE_ROOT=$FM_REMOTE_JOB_STATE_ROOT")
  fi
  trap - EXIT
  rm -rf -- "$TMP"
  exec "${DOCTOR_ENV[@]}" "$COMMAND_PATH" "${ARGV[@]:1}"
fi

if ! fm_remote_job_ensure_worker "$ROOT" "$ACCOUNT_HOME"; then
  die "${FM_REMOTE_JOB_ERROR:-remote job worker is unavailable; run fm-on.sh <route> fm-remote-doctor.sh --fix}"
fi
if ! JOB_ID=$(fm_remote_job_stage "$ACCOUNT_HOME" "$ROOT" "$HOME_PATH" "$COMMAND" "${ARGV[@]:1}"); then
  JOB_ID=
  die "${FM_REMOTE_JOB_ERROR:-cannot stage remote job}" 70
fi
FM_REMOTE_JOB_DISCONNECT_PROBE=entrypoint_caller_connected
if ! fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID"; then
  die "${FM_REMOTE_JOB_ERROR:-remote job did not complete}" 70
fi
JOB_COMPLETED=1
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR" >&2
RESULT=$FM_REMOTE_JOB_EXIT
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || true
trap - EXIT
rm -rf -- "$TMP"
exit "$RESULT"
