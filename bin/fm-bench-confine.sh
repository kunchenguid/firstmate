#!/usr/bin/env bash
# fm-bench-confine.sh - run one command inside a benchmark entrant's enforced
# confinement, so the entrant reaches its own private clone, object store,
# temp, home, and session space and nothing else.
#
# This is the isolation CONTROL. bin/fm-bench-gate.py never trusts it: the gate
# runs bin/fm-bench-probe.sh through this wrapper and refuses to clear the
# benchmark unless every sibling-access probe is positively denied. A mechanism
# that this host cannot enforce therefore surfaces as a refused launch naming
# the concrete unmet requirement, never as a silent downgrade.
#
# Usage:
#   fm-bench-confine.sh --allow <dir> [--allow <dir>]... [--mechanism <name>]
#                       [--image <ref>] -- <command> [args...]
#   fm-bench-confine.sh --list-mechanisms
#   fm-bench-confine.sh --help
#
# Mechanisms (--mechanism, default auto):
#   auto          first available of container, bwrap, sandbox-exec
#   container     docker or podman with only --allow paths mounted and its own
#                 PID namespace; the only mechanism that confines storage,
#                 filesystem, AND processes on every supported host
#   bwrap         bubblewrap with --unshare-pid and per-path binds (Linux)
#   sandbox-exec  macOS seatbelt profile; confines storage and filesystem only,
#                 so the gate's process-inspection probe stays unproven and the
#                 launch stays refused until a container is available
#   none          no confinement; provided so the gate's own regression can
#                 prove the probe set detects a real leak
#
# The environment is always scrubbed to an explicit allowlist (PATH, HOME, TMPDIR,
# LANG, TERM), which is what denies the environment-leakage probe.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MECHANISM=auto
IMAGE=${FM_BENCH_CONFINE_IMAGE:-debian:stable-slim}
ALLOW=()
CMD=()

usage() { sed -n '2,/^set -u$/p' "$SELF_DIR/fm-bench-confine.sh" | sed 's/^# \{0,1\}//;$d'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow) [ "$#" -gt 1 ] || { echo "error: --allow requires a directory" >&2; exit 2; }
      ALLOW+=("$2"); shift 2 ;;
    --mechanism) [ "$#" -gt 1 ] || { echo "error: --mechanism requires a name" >&2; exit 2; }
      MECHANISM=$2; shift 2 ;;
    --image) [ "$#" -gt 1 ] || { echo "error: --image requires a reference" >&2; exit 2; }
      IMAGE=$2; shift 2 ;;
    --list-mechanisms) printf '%s\n' container bwrap sandbox-exec none; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; CMD=("$@"); break ;;
    *) echo "error: unexpected argument $1" >&2; exit 2 ;;
  esac
done

[ "${#CMD[@]}" -gt 0 ] || { echo "error: no command after --" >&2; exit 2; }
[ "${#ALLOW[@]}" -gt 0 ] || { echo "error: at least one --allow directory is required" >&2; exit 2; }

for dir in "${ALLOW[@]}"; do
  [ -d "$dir" ] || { echo "error: --allow path is not a directory: $dir" >&2; exit 2; }
done

resolve_container_runtime() {
  local runtime
  for runtime in docker podman; do
    if command -v "$runtime" >/dev/null 2>&1 && "$runtime" info >/dev/null 2>&1; then
      printf '%s\n' "$runtime"
      return 0
    fi
  done
  return 1
}

if [ "$MECHANISM" = auto ]; then
  if resolve_container_runtime >/dev/null 2>&1; then
    MECHANISM=container
  elif command -v bwrap >/dev/null 2>&1; then
    MECHANISM=bwrap
  elif command -v sandbox-exec >/dev/null 2>&1; then
    MECHANISM=sandbox-exec
  else
    echo "error: no confinement mechanism is available on this host" >&2
    exit 2
  fi
fi

# The confined command always runs under a scrubbed environment. Everything the
# entrant may see is named here; nothing else crosses the boundary.
scrubbed_env() {
  printf '%s\n' "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "HOME=${FM_BENCH_PRIVATE_HOME:-${ALLOW[0]}}" \
    "TMPDIR=${FM_BENCH_PRIVATE_TMP:-${ALLOW[0]}}" \
    "LANG=${LANG:-C.UTF-8}" \
    "TERM=dumb"
}

case "$MECHANISM" in
  container)
    runtime=$(resolve_container_runtime) || { echo "error: no usable container runtime" >&2; exit 2; }
    # A container gets its own PID namespace by default, which is what denies
    # the process-inspection probe.
    args=(run --rm --network none)
    # Run as the invoking user so an entrant's own writes stay owned by the
    # operator instead of arriving root-owned in the entrant's private clone.
    args+=(--user "$(id -u):$(id -g)")
    for dir in "${ALLOW[@]}"; do
      args+=(--volume "$dir:$dir")
    done
    args+=(--volume "$SELF_DIR:$SELF_DIR:ro")
    while IFS= read -r pair; do
      args+=(--env "$pair")
    done < <(scrubbed_env)
    args+=(--workdir "${ALLOW[0]}" "$IMAGE")
    exec "$runtime" "${args[@]}" "${CMD[@]}"
    ;;
  bwrap)
    command -v bwrap >/dev/null 2>&1 || { echo "error: bwrap is not installed" >&2; exit 2; }
    args=(--unshare-pid --unshare-net --die-with-parent --proc /proc --dev /dev)
    for dir in /usr /bin /sbin /lib /lib64 /etc; do
      [ -e "$dir" ] && args+=(--ro-bind "$dir" "$dir")
    done
    args+=(--ro-bind "$SELF_DIR" "$SELF_DIR")
    for dir in "${ALLOW[@]}"; do
      args+=(--bind "$dir" "$dir")
    done
    args+=(--chdir "${ALLOW[0]}" --clearenv)
    while IFS= read -r pair; do
      args+=(--setenv "${pair%%=*}" "${pair#*=}")
    done < <(scrubbed_env)
    exec bwrap "${args[@]}" -- "${CMD[@]}"
    ;;
  sandbox-exec)
    command -v sandbox-exec >/dev/null 2>&1 || { echo "error: sandbox-exec is not available" >&2; exit 2; }
    profile=$(mktemp) || exit 2
    trap 'rm -f -- "$profile"' EXIT HUP INT TERM
    env_args=()
    while IFS= read -r pair; do
      env_args+=("$pair")
    done < <(scrubbed_env)
    {
      printf '(version 1)\n(deny default)\n(allow process*)\n(allow sysctl-read)\n'
      printf '(allow mach*)\n(allow signal)\n(allow file-read-metadata)\n'
      printf '(allow file-read* (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/System") (subpath "/Library") (subpath "/opt") (subpath "/private/etc") (subpath "/private/var/db/dyld") (subpath "/dev")'
      printf ' (subpath "%s")' "$SELF_DIR"
      for dir in "${ALLOW[@]}"; do printf ' (subpath "%s")' "$dir"; done
      printf ')\n(allow file-write* (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr")'
      for dir in "${ALLOW[@]}"; do printf ' (subpath "%s")' "$dir"; done
      printf ')\n'
    } > "$profile"
    env -i "${env_args[@]}" sandbox-exec -f "$profile" "${CMD[@]}"
    exit $?
    ;;
  none)
    exec "${CMD[@]}"
    ;;
  *)
    echo "error: unknown mechanism $MECHANISM" >&2
    exit 2
    ;;
esac
