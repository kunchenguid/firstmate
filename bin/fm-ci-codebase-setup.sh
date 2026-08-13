#!/usr/bin/env bash
# fm-ci-codebase-setup.sh - provision the Codebase CI image for a behavior lane.
#
# Only .codebase/pipelines/ci.yaml calls this. It exists because that pipeline
# now runs the suite as SEVERAL sharded jobs, and every one of them needs the
# identical toolchain repair below; a copy of it per job in the YAML would drift
# the moment one copy is edited.
#
# THE IMAGE: ci_nodejs_20 is Debian 10 (buster), whose apt packages are from
# 2018 and too old to trust:
#   - shellcheck 0.5.0 still emits SC1117 (removed upstream in 0.7) and flags
#     backticks inside single quotes, so it fails on code that is clean under
#     any current shellcheck. bin/fm-lint.sh refuses any version but its pin,
#     and several tests call it, so the pinned build has to be on PATH in the
#     behavior jobs too, not only in the lint job.
#   - jq 1.5 exits 0 from `jq -e` on empty input instead of 4. cmux.sh's
#     surface_exists is exactly that predicate, so an absent surface reads as
#     present and tests/fm-backend-cmux.test.sh fails.
#   - awk is mawk 1.3.3, which predates POSIX character classes, so the
#     [[:space:]] patterns in bin/fm-backlog-handoff.sh never match and its
#     malformed-continuation refusal silently passes. gawk takes over the
#     alternative; Ubuntu's mawk 1.3.4 and macOS awk both handle it.
#   - node is 20, but tests/fm-pi-watch-extension.test.sh imports the .ts
#     extension directly, which needs native type stripping (default-on from
#     22.18). Node 22 goes in its own prefix: unpacking over /usr/local would
#     replace the image's npm and its internal-registry config, which the
#     tasks-axi install needs.
#   - python3 is 3.7, so it has no tomllib. bin/fm-kimi-turnend-hook.sh needs
#     it to validate config.toml; nothing is installed for that here and
#     tests/fm-kimi-harness.test.sh gate-skips visibly instead.
#
# github.com is not reachable from the runner directly, so every pinned tool is
# fetched through the internal relay. Bump versions in the owning script (
# bin/fm-install-shellcheck.sh) or here, never in apt.
#
# Usage: fm-ci-codebase-setup.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY=${FM_CI_RELAY_PROXY:-http://sys-proxy-rd-relay.byted.org:8118}
JQ_VERSION=1.7.1
NODE_VERSION=22.22.1

case "${1:-}" in
  -h|--help)
    sed -n '2,36p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

echo "--- apt: tmux and gawk"
apt-get update
apt-get install -y --no-install-recommends tmux gawk
tmux -V
awk --version | head -1
# The POSIX class the backlog-handoff refusal depends on must actually work.
printf '\tx\n' | awk '/^[[:space:]]/ { found = 1 } END { exit found ? 0 : 1 }'

echo "--- jq $JQ_VERSION"
https_proxy=$RELAY http_proxy=$RELAY curl -sSfL --max-time 120 -o /tmp/jq \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64"
install -m 0755 /tmp/jq /usr/local/bin/jq
jq --version

echo "--- pinned ShellCheck"
https_proxy=$RELAY http_proxy=$RELAY "$SCRIPT_DIR/fm-install-shellcheck.sh" /usr/local/bin
shellcheck --version | awk '/^version:/ {print $2}'

echo "--- tasks-axi"
npm install -g tasks-axi
tasks-axi --version
# The floor the delegated backlog handoff needs is owned by
# bin/fm-tasks-axi-lib.sh; read it from there rather than repeating a number.
required=$(sed -n 's/^FM_TASKS_AXI_MIN=\([0-9][0-9.]*\).*/\1/p' "$SCRIPT_DIR/fm-tasks-axi-lib.sh" | head -1)
[ -n "$required" ] || { echo "could not read the tasks-axi floor from bin/fm-tasks-axi-lib.sh"; exit 1; }
have=$(tasks-axi --version | tr -d '[:space:]')
lowest=$(printf '%s\n%s\n' "$have" "$required" | sort -V | head -n1)
if [ "$lowest" != "$required" ]; then
  echo "tasks-axi ${have} is older than the required ${required}"
  exit 1
fi

echo "--- node $NODE_VERSION into /opt/node22"
https_proxy=$RELAY http_proxy=$RELAY curl -sSfL --max-time 180 -o /tmp/node.tar.xz \
  "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
mkdir -p /opt/node22
tar -xJf /tmp/node.tar.xz -C /opt/node22 --strip-components=1
/opt/node22/bin/node --version

echo "--- default-branch history"
# tests/fm-backend.test.sh resolves a merge-base against main and hard-fails
# without it; the MR checkout does not carry that ref.
if [ -f "$(git rev-parse --git-dir)/shallow" ]; then
  git fetch --unshallow origin || git fetch --depth=1000 origin
fi
git fetch origin "main:refs/remotes/origin/main"
git merge-base HEAD origin/main >/dev/null
