#!/usr/bin/env bash
# Portable behavioral tests of native host request and app-server policy.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
node --test "$ROOT/tests/fixtures/native-owner/tool-gate.test.mjs" "$ROOT/tests/fixtures/native-owner/host-lifecycle.test.mjs" "$ROOT/tests/fixtures/native-owner/app-server-policy.test.mjs" "$ROOT/tests/fixtures/native-owner/host-evidence.test.mjs"
