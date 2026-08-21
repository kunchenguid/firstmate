#!/usr/bin/env bash
# Run exactly one ephemeral GitHub Actions runner container, then exit.
# systemd restarts this unit, which registers a fresh runner with a fresh
# workspace. Installed on gex44 as /opt/gh-runner/supervise.sh.
#
# Usage: supervise.sh <repo>-<slot>        (systemd instance name)
#        supervise.sh <repo> <slot>
#
# The registration token is NOT minted here: gex holds no durable GitHub
# credential. A relay on the captain's laptop mints a short-lived token and
# drops it into /etc/gh-runner/token-<repo>. See docs/gex-ci-laeufer.md.
set -euo pipefail

CONF_DIR=${GH_RUNNER_CONF_DIR:-/etc/gh-runner}
IMAGE=${GH_RUNNER_IMAGE:-localhost/gh-runner:base}
CPUS=${GH_RUNNER_CPUS:-8}
MEMORY=${GH_RUNNER_MEMORY:-16g}
LABELS=${GH_RUNNER_LABELS:-gex}
SLICE=${GH_RUNNER_SLICE:-gh-runner.slice}

# The instance name arrives as one token because systemd would expand a
# ${...} written in ExecStart as one of its own variables before any shell
# sees it. Splitting here keeps the unit free of shell quoting entirely.
# Repo names may contain dashes, so the split takes the LAST one.
case "$#" in
  1) repo=${1%-*}; slot=${1##*-} ;;
  2) repo=$1; slot=$2 ;;
  *)
    printf 'supervise.sh: usage: supervise.sh <repo>-<slot> | <repo> <slot>\n' >&2
    exit 2
    ;;
esac

case "$slot" in
  *[!0-9]*|'')
    printf 'supervise.sh: slot must be numeric, got: %s\n' "$slot" >&2
    exit 2
    ;;
esac

case "$repo" in
  *[!A-Za-z0-9._-]*|'')
    printf 'supervise.sh: refusing implausible repo name: %s\n' "$repo" >&2
    exit 2
    ;;
esac

# The allowlist is the single owner of which repos may get a runner. It is
# maintained by hand and holds private repos only; a self-hosted runner on a
# public repo would execute pull-request code from strangers.
allowlist="$CONF_DIR/repos"
if [ ! -r "$allowlist" ]; then
  printf 'supervise.sh: allowlist %s is not readable.\n' "$allowlist" >&2
  exit 78
fi
if ! grep -qx -- "$repo" "$allowlist"; then
  printf 'supervise.sh: %s is not in %s; refusing to register.\n' "$repo" "$allowlist" >&2
  exit 78
fi

token_file="$CONF_DIR/token-$repo"
if [ ! -r "$token_file" ]; then
  printf 'supervise.sh: no registration token at %s; waiting for the relay.\n' "$token_file" >&2
  sleep 60
  exit 75
fi

token=$(sed -n '1p' "$token_file")
expires=$(sed -n '2p' "$token_file")
if [ -z "$token" ] || [ -z "$expires" ]; then
  printf 'supervise.sh: %s is malformed; waiting for the relay.\n' "$token_file" >&2
  sleep 60
  exit 75
fi

expires_epoch=$(date -d "$expires" +%s 2>/dev/null || echo 0)
now_epoch=$(date +%s)
# 120s of slack: config.sh must finish before the token dies.
if [ "$expires_epoch" -le $((now_epoch + 120)) ]; then
  printf 'supervise.sh: token for %s expired at %s; waiting for the relay.\n' "$repo" "$expires" >&2
  sleep 60
  exit 75
fi

name="gex-$repo-$slot"

# Hardening, in order:
#   --cap-drop=ALL / no-new-privileges : CI needs no capabilities
#   --cgroup-parent                    : land in the aggregate-capped slice
#   --cpus/--memory/--pids-limit       : per-container ceiling
#   allow_host_loopback=false          : CI cannot reach services on gex's loopback
#   no --gpus, no device passthrough   : /dev/nvidia* stays invisible
#   no socket mount                    : the host's docker is unreachable
exec podman run \
  --rm \
  --replace \
  --name "$name" \
  --cgroup-manager=systemd \
  --cgroup-parent="$SLICE" \
  --cpus="$CPUS" \
  --memory="$MEMORY" \
  --memory-swap="$MEMORY" \
  --pids-limit=4096 \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --network "slirp4netns:allow_host_loopback=false" \
  --env REPO_URL="https://github.com/swippipp/$repo" \
  --env RUNNER_TOKEN="$token" \
  --env RUNNER_NAME="$name" \
  --env RUNNER_LABELS="$LABELS" \
  "$IMAGE"
