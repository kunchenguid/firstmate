#!/usr/bin/env bash
# Sealed done-done proof for quota-axi-pool (screen: none).
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
export TMPDIR=${TMPDIR:-/var/tmp}
bash "$repo/quota-axi-pool/tests/quota-axi-pool.test.sh" | tee "$evidence/result.log"
cat >"$evidence/steps.json" <<'JSON'
{"target":{"version":"quota-axi-pool"},"start":"fixture Umer A/B, stub upstream ambient 11%; temp-HOME install over foreign symlink; no login/network/model CLI","steps":["Claude row A=70 matching fm-model-pool","after A attempted Claude row B=40","no pool ambient 11","under floor Claude unknown","--version passthrough","refuse install with no upstream","install records resolved upstream and original link target","reinstall keeps recorded upstream","uninstall restores original link"],"result":"dispatch Claude row follows fm-model-pool; install preserves foreign quota-axi symlink"}
JSON
printf 'PASS: quota-axi-pool forced-limit proof\n'
