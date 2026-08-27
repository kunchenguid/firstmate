#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pi_package=${FM_PI_PACKAGE_DIR:-}
tsc_bin=
selected_node_dir=

while IFS= read -r node_bin; do
  node_dir=$(dirname "$node_bin")
  [ -n "$selected_node_dir" ] || selected_node_dir=$node_dir
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

for candidate in \
  "$(command -v tsc 2>/dev/null || true)" \
  "$HOME"/.nvm/versions/node/*/lib/node_modules/typescript/bin/tsc \
  "$HOME"/.nvm/versions/node/*/lib/node_modules/*/node_modules/.bin/tsc \
  /opt/homebrew/lib/node_modules/typescript/bin/tsc \
  /opt/homebrew/lib/node_modules/*/node_modules/.bin/tsc \
  /usr/local/lib/node_modules/typescript/bin/tsc \
  /usr/local/lib/node_modules/*/node_modules/.bin/tsc; do
  [ -x "$candidate" ] || continue
  tsc_bin=$candidate
  break
done

[ -n "$pi_package" ] && [ -f "$pi_package/package.json" ] || { echo "not ok - installed Pi package not found" >&2; exit 1; }
[ -n "$tsc_bin" ] || { echo "not ok - installed TypeScript compiler not found" >&2; exit 1; }
[ -n "$selected_node_dir" ] || { echo "not ok - Node runtime not found" >&2; exit 1; }

out=$(env -u FM_TEST_RUNNER_ACTIVE PATH="$(dirname "$tsc_bin"):$selected_node_dir:$PATH" FM_PI_PACKAGE_DIR="$pi_package" "$ROOT/tests/fm-pi-primary-types.test.sh") || {
  printf '%s\n' "$out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -Eq '^ok - Pi primary extensions pass strict no-emit typecheck against Pi ' || {
  printf '%s\n' "$out" >&2
  echo "not ok - strict Pi consumer typecheck did not run" >&2
  exit 1
}
printf '%s\n' 'ok - exact Pi continuity consumer typecheck passed'
