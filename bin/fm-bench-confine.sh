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
#                       [--purpose replay|entrant] [--image <ref>]
#                       [--provider-network <per-entrant-name> --provider-proxy <url>]
#                       [--provider-proxy-container <name>]
#                       -- <command> [args...]
#   fm-bench-confine.sh --list-mechanisms
#   fm-bench-confine.sh --help
#
# Mechanisms (--mechanism, default auto):
#   auto          first available of container, bwrap
#   container     docker or podman with only --allow paths mounted and its own
#                 PID namespace; the only mechanism that confines storage,
#                 filesystem, AND processes on every supported host
#   bwrap         bubblewrap with --unshare-pid and per-path binds (Linux)
#   none          no confinement; provided so the gate's own regression can
#                 prove the probe set detects a real leak
#
# The environment is always scrubbed to an explicit allowlist (PATH, HOME, TMPDIR,
# LANG, TERM), which is what denies the environment-leakage probe.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MECHANISM=auto
PURPOSE=replay
IMAGE=${FM_BENCH_CONFINE_IMAGE:-debian:stable-slim}
PROVIDER_NETWORK=
PROVIDER_PROXY=
PROVIDER_PROXY_CONTAINER=
ALLOW=()
CMD=()
EXPOSE_SELF_DIR=0

usage() { sed -n '2,/^set -u$/p' "$SELF_DIR/fm-bench-confine.sh" | sed 's/^# \{0,1\}//;$d'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow) [ "$#" -gt 1 ] || { echo "error: --allow requires a directory" >&2; exit 2; }
      ALLOW+=("$2"); shift 2 ;;
    --mechanism) [ "$#" -gt 1 ] || { echo "error: --mechanism requires a name" >&2; exit 2; }
      MECHANISM=$2; shift 2 ;;
    --image) [ "$#" -gt 1 ] || { echo "error: --image requires a reference" >&2; exit 2; }
      IMAGE=$2; shift 2 ;;
    --purpose) [ "$#" -gt 1 ] || { echo "error: --purpose requires replay or entrant" >&2; exit 2; }
      PURPOSE=$2; shift 2 ;;
    --provider-network) [ "$#" -gt 1 ] || { echo "error: --provider-network requires a name" >&2; exit 2; }
      PROVIDER_NETWORK=$2; shift 2 ;;
    --provider-proxy) [ "$#" -gt 1 ] || { echo "error: --provider-proxy requires a URL" >&2; exit 2; }
      PROVIDER_PROXY=$2; shift 2 ;;
    --provider-proxy-container) [ "$#" -gt 1 ] || { echo "error: --provider-proxy-container requires a name" >&2; exit 2; }
      PROVIDER_PROXY_CONTAINER=$2; shift 2 ;;
    --list-mechanisms) printf '%s\n' container bwrap none; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; CMD=("$@"); break ;;
    *) echo "error: unexpected argument $1" >&2; exit 2 ;;
  esac
done

[ "${#CMD[@]}" -gt 0 ] || { echo "error: no command after --" >&2; exit 2; }
[ "${#ALLOW[@]}" -gt 0 ] || { echo "error: at least one --allow directory is required" >&2; exit 2; }
case "$PURPOSE" in
  replay) [ -z "$PROVIDER_NETWORK$PROVIDER_PROXY" ] || { echo "error: replay confinement cannot enable provider egress" >&2; exit 2; } ;;
  entrant) [ -n "$PROVIDER_NETWORK" ] && [ -n "$PROVIDER_PROXY" ] && [ -n "$PROVIDER_PROXY_CONTAINER" ] || { echo "error: entrant confinement requires provider network and credential-free proxy container" >&2; exit 2; } ;;
  *) echo "error: unknown purpose $PURPOSE" >&2; exit 2 ;;
esac

case "${CMD[0]}" in
  "$SELF_DIR"|"$SELF_DIR"/*) EXPOSE_SELF_DIR=1 ;;
esac

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
  else
    echo "error: no confinement mechanism is available on this host" >&2
    exit 2
  fi
fi

# The confined command always runs under a scrubbed environment. Everything the
# entrant may see is named here; nothing else crosses the boundary.
scrubbed_env() {
  printf '%s\n' "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "HOME=${BENCH_PRIVATE_HOME:-${ALLOW[0]}}" \
    "TMPDIR=${BENCH_PRIVATE_TMP:-${ALLOW[0]}}" \
    "BENCH_PRIVATE_ROOT=${BENCH_PRIVATE_ROOT:-${ALLOW[0]}}" \
    "BENCH_PRIVATE_OBJECT_STORE=${BENCH_PRIVATE_OBJECT_STORE:-${ALLOW[0]}}" \
    "BENCH_PRIVATE_TMP=${BENCH_PRIVATE_TMP:-${ALLOW[0]}}" \
    "BENCH_PRIVATE_HOME=${BENCH_PRIVATE_HOME:-${ALLOW[0]}}" \
    "BENCH_PRIVATE_SESSION=${BENCH_PRIVATE_SESSION:-${ALLOW[0]}}" \
    "PROCESS_INSPECTION_MARKER_FILE=${PROCESS_INSPECTION_MARKER_FILE:-}" \
    "LANG=${LANG:-C.UTF-8}" \
    "TERM=dumb"
}

case "$MECHANISM" in
  container)
    runtime=$(resolve_container_runtime) || { echo "error: no usable container runtime" >&2; exit 2; }
    # A container gets its own PID namespace by default, which is what denies
    # the process-inspection probe.
    if [ "$PURPOSE" = entrant ]; then
      [ "$runtime" = docker ] || { echo "error: provider-only entrant egress requires Docker network inspection" >&2; exit 2; }
      topology=$(docker network inspect "$PROVIDER_NETWORK" --format '{{.Internal}} {{range .Containers}}{{.Name}} {{end}}' 2>/dev/null) \
        || { echo "error: provider-only network is unavailable" >&2; exit 2; }
      [ "$topology" = "true $PROVIDER_PROXY_CONTAINER " ] \
        || { echo "error: provider-only network must be internal and contain only $PROVIDER_PROXY_CONTAINER" >&2; exit 2; }
      args=(run --rm --network "$PROVIDER_NETWORK")
    else
      args=(run --rm --network none)
    fi
    # Run as the invoking user so an entrant's own writes stay owned by the
    # operator instead of arriving root-owned in the entrant's private clone.
    args+=(--user "$(id -u):$(id -g)")
    for dir in "${ALLOW[@]}"; do
      args+=(--volume "$dir:$dir")
    done
    [ "$EXPOSE_SELF_DIR" -eq 0 ] || args+=(--volume "$SELF_DIR:$SELF_DIR:ro")
    while IFS= read -r pair; do
      args+=(--env "$pair")
    done < <(scrubbed_env)
    if [ "$PURPOSE" = entrant ]; then
      args+=(--env "HTTP_PROXY=$PROVIDER_PROXY" --env "HTTPS_PROXY=$PROVIDER_PROXY" --env "ALL_PROXY=$PROVIDER_PROXY")
    fi
    args+=(--workdir "${ALLOW[0]}" "$IMAGE")
    exec "$runtime" "${args[@]}" "${CMD[@]}"
    ;;
  bwrap)
    [ "$PURPOSE" = replay ] || { echo "error: bwrap cannot enforce provider-only entrant egress" >&2; exit 2; }
    command -v bwrap >/dev/null 2>&1 || { echo "error: bwrap is not installed" >&2; exit 2; }
    args=(--unshare-pid --unshare-net --die-with-parent --proc /proc --dev /dev)
    for dir in /usr /bin /sbin /lib /lib64 /etc; do
      [ -e "$dir" ] && args+=(--ro-bind "$dir" "$dir")
    done
    [ "$EXPOSE_SELF_DIR" -eq 0 ] || args+=(--ro-bind "$SELF_DIR" "$SELF_DIR")
    for dir in "${ALLOW[@]}"; do
      args+=(--bind "$dir" "$dir")
    done
    args+=(--chdir "${ALLOW[0]}" --clearenv)
    while IFS= read -r pair; do
      args+=(--setenv "${pair%%=*}" "${pair#*=}")
    done < <(scrubbed_env)
    exec bwrap "${args[@]}" -- "${CMD[@]}"
    ;;
  none)
    exec "${CMD[@]}"
    ;;
  *)
    echo "error: unknown mechanism $MECHANISM" >&2
    exit 2
    ;;
esac
