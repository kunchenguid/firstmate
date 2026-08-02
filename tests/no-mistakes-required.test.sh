#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
CONTRIBUTING="$ROOT/CONTRIBUTING.md"

assert_marker_assignment_once() {
  local file=$1
  local count

  count=$(grep -Fc -- "marker='$MARKER'" "$file" || true)
  if [[ $count -ne 1 ]]; then
    printf 'expected exactly one no-mistakes marker assignment in %s, found %s\n' \
      "$file" "$count" >&2
    return 1
  fi
}

# The workflow and contributor instructions are both inputs to the external
# publisher. Keep their machine-verifiable signature synchronized so a PR body
# cannot claim successful publication while omitting the gate marker.
assert_marker_assignment_once "$WORKFLOW"

if ! grep -Fq -- "\`$MARKER\` exactly" "$CONTRIBUTING"; then
  printf 'CONTRIBUTING.md does not document the workflow marker exactly\n' >&2
  exit 1
fi

printf 'no-mistakes PR signature contract is synchronized\n'
