#!/usr/bin/env bash
set -euo pipefail

check() {
  local expected=$1 verb=$2 text=$3 output rc=0
  output=$("$checker" "$verb" "$text" 2>&1) || rc=$?
  if [ "$rc" -ne "$expected" ]; then
    printf 'expected exit %s, got %s for %s: %s\n%s\n' "$expected" "$rc" "$verb" "$text" "$output" >&2
    exit 1
  fi
}
checker=$(cd "$(dirname "$0")/.." && pwd)/status-wait-check
for text in 'waiting on CI' 'waiting for a release' 'awaiting approval' 'CI pending' 'CI running' 'until 2026-10-21T12:00Z' 'until 12:00' 'release pending' 'timer has not fired'; do
  check 1 blocked "$text"
done
for text in 'failing CI' 'failed check, waiting on rerun' 'missing credential' 'error awaiting restart' 'needs a decision'; do
  check 0 blocked "$text"
done
check 1 'blocked:' 'waiting on CI'
check 0 'blocked:' 'real blocker'
check 0 'paused:' 'waiting on CI'
check 0 paused 'waiting on CI'
check 0 working 'waiting on CI'
printf 'status-wait-check: ok\n'
