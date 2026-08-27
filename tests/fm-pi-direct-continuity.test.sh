#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selected_node=
pi_package=${FM_PI_PACKAGE_DIR:-}

while IFS= read -r node_bin; do
  [ -n "$node_bin" ] || continue
  node_dir=$(dirname "$node_bin")
  if [ -z "$selected_node" ] && [ "$("$node_bin" -p 'process.features?.typescript ? "yes" : "no"' 2>/dev/null)" = yes ]; then
    selected_node=$node_dir
  fi
  if [ -z "$pi_package" ] && [ -x "$node_dir/npm" ]; then
    candidate=$(PATH="$node_dir:$PATH" "$node_dir/npm" root -g 2>/dev/null)/@earendil-works/pi-coding-agent
    if [ -f "$candidate/package.json" ]; then
      pi_package=$candidate
    fi
  fi
done < <(
  {
    type -a -p node 2>/dev/null
    for candidate_node in /opt/homebrew/opt/node/bin/node /usr/local/opt/node/bin/node; do
      [ -x "$candidate_node" ] && printf '%s\n' "$candidate_node"
    done
  } | awk '!seen[$0]++'
)

[ -n "$selected_node" ] || { echo "not ok - no available Node runtime supports TypeScript import" >&2; exit 1; }
[ -n "$pi_package" ] && [ -f "$pi_package/package.json" ] || { echo "not ok - installed Pi package not found" >&2; exit 1; }

out=$(env -u FM_TEST_RUNNER_ACTIVE PATH="$selected_node:$PATH" FM_PI_PACKAGE_DIR="$pi_package" FM_PI_EXACT_DELIVERY_PROOF=1 "$ROOT/tests/fm-pi-watch-extension.test.sh") || {
  printf '%s\n' "$out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -Fqx 'PI_EXACT_DELIVERY_ASSOCIATION_PROOF_OK' || {
  printf '%s\n' "$out" >&2
  echo "not ok - exact Pi delivery association proof token missing" >&2
  exit 1
}
printf '%s\n' 'PI_EXACT_DELIVERY_ASSOCIATION_PROOF_OK'
