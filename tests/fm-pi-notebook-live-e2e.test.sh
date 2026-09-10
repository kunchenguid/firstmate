#!/usr/bin/env bash
# Token-free Pi + published Notebook module guard, on a private tmux socket.
# Supply an unpacked @howaboua/pi-codex-conversion with its runtime dependencies
# via FM_PI_NOTEBOOK_PACKAGE, and its pinned Deno binary via FM_NOTEBOOK_DENO.
# Nothing is installed or downloaded by this test. FM_PI_PACKAGE_DIR selects Pi;
# FM_NOTEBOOK_TEST_OUTPUT optionally retains evidence in a caller-owned directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_PI_NOTEBOOK_LIVE node tmux
if [ -z "${FM_PI_NOTEBOOK_PACKAGE:-}" ] || [ -z "${FM_NOTEBOOK_DENO:-}" ]; then
  if [ "${FM_PI_NOTEBOOK_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
    fail "Notebook guard requires FM_PI_NOTEBOOK_PACKAGE and FM_NOTEBOOK_DENO"
  fi
  echo 'skip: Notebook package/Deno fixture not supplied (FM_PI_NOTEBOOK_PACKAGE, FM_NOTEBOOK_DENO)'
  exit 0
fi
export FM_PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
export FM_NOTEBOOK_TEST_ROOT="$ROOT"
export FM_NOTEBOOK_TEST_OUTPUT=${FM_NOTEBOOK_TEST_OUTPUT:-"$(fm_test_tmproot fm-notebook-live)"}
mkdir -p "$FM_NOTEBOOK_TEST_OUTPUT"
# Each case owns a fresh Pi process, Deno kernel, home and tmux server; serial.
for order in first last; do
  for provider in azure-anthropic azure-openai-responses; do
    FM_NOTEBOOK_ORDER="$order" FM_NOTEBOOK_PROVIDER="$provider" \
      node "$ROOT/tests/fm-pi-notebook-live.mjs" || fail "Notebook guard: $order / $provider"
  done
done
