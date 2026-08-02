#!/usr/bin/env bash
# Opt-in real visible browser smoke contract.
# This test intentionally skips until a verified real engine adapter exists.
# It must never launch a browser accidentally in CI or ordinary local runs.
set -u

if [ "${FM_BROWSER_REAL_SMOKE:-0}" != 1 ]; then
  echo "skip: set FM_BROWSER_REAL_SMOKE=1 only for the supervised public visible browser smoke"
  exit 0
fi

if [ "${FM_BROWSER_REAL_ENGINE_VERIFIED:-0}" != 1 ]; then
  echo "skip: real browser engine support is not verified in this disabled core"
  exit 0
fi

printf 'not ok - real smoke runner has no verified implementation yet\n' >&2
exit 1
