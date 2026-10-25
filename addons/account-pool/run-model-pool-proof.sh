#!/usr/bin/env bash
# Sealed done-done proof for fm-model-pool (screen: none). Forced-limit fixture journey only.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
export TMPDIR=${TMPDIR:-/var/tmp}
bash "$repo/account-pool/tests/model-pool.test.sh" | tee "$evidence/result.log"
cat >"$evidence/steps.json" <<'JSON'
{"target":{"version":"account-pool fm-model-pool JSON helper"},"start":"fixture Umer A/B pool readings and recording stand-in pool command; no login copy, no network, no real model CLI","steps":["pick A at 70% over B at 40% above the 15% eligibility floor","typed quota next on A yields B without repeating A","all Claude under floor falls over Sol then Goat then Cursor auto","credits-enabled registry account refused and logged","past overall deadline refuses","omitted pool_config uses FM_HOME default","explicit pool_config wins over default","omitted pool_config with no default file refuses"],"result":"helper rotates accounts and fallovers under one deadline; never usage credits; usable as lfm account_picker without pool_config"}
JSON
printf 'PASS: fm-model-pool forced-limit proof\n'
