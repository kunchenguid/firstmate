#!/usr/bin/env bash
# run-proof-pick.sh: the chooser proof for done-done. Uses the real pool pick fm-spawn calls
# (fm_account_pool_select from this repo's account-pool add-on; FM_BIN names a Firstmate checkout's bin/
# for fm-timeout-lib.sh) with a throwaway
# config/account-pool pointing at the chooser and the real accounts, then starts one tiny throwaway
# Haiku task on the picked profile folder with the launch prefix the pool builds, and reads quota again.
# Captures keep ids, names and percentages only: no folder path, no credential value.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
FM_BIN=${FM_BIN:?set FM_BIN to a Firstmate checkout bin/}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/config" "$work/home/state" "$work/cwd"
export FM_HOME=$work/home SCRIPT_DIR=$FM_BIN
bash "$repo/claude-accounts/install.sh" "$FM_HOME" >/dev/null
summary() { # label: both accounts' windows from the file the reader wrote
  jq -r --arg l "$1" '.accounts[] | "\($l) \(.id) (\(.name)): 5h left \(.five_hour.left // "?")% window-started \(.five_hour.resets_at != null), 7d left \(.seven_day.left // "?")%"' "$FM_HOME/state/claude-accounts.json"
}
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
{ summary before; } >"$evidence/pick.txt"

# shellcheck source=/dev/null
. "$repo/account-pool/bin/fm-account-pool-lib.sh"
tuple=$(fm_account_pool_select claude "$FM_HOME/config")
id=$(cut -f1 <<<"$tuple"); folder=$(cut -f3 <<<"$tuple"); shed=$(cut -f4 <<<"$tuple")
echo "pool pick for a new Claude worker: $id" >>"$evidence/pick.txt"
prefix='env'
for n in $shed; do prefix="$prefix -u $n"; done
# Signed in on the picked folder, asked the way the pin check asks (exit status only, nothing printed).
if env -i HOME="$HOME" PATH="$PATH" CLAUDE_CONFIG_DIR="$folder" claude auth status >/dev/null 2>&1; then echo "claude auth status on the picked profile: signed in" >>"$evidence/pick.txt"; fi
reply=$(cd "$work/cwd" && $prefix CLAUDE_CONFIG_DIR="$folder" claude -p --model claude-haiku-5-5 "Reply with the single word ok." </dev/null 2>&1 | head -c 200)
echo "throwaway worker (claude-haiku-5-5) on $id answered: $reply" >>"$evidence/pick.txt"
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
summary after >>"$evidence/pick.txt"
cat "$evidence/pick.txt"
