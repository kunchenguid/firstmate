#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home" "$T/fm/config"; export HOME=$T/home XDG_DATA_HOME=$T/data GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/global.gitconfig
printf 'original hook\n' > "$T/fm/config/launch-env-hook"; printf keep > "$T/fm/config/unrelated"
"$A/install.sh" --email a@example.test --name Tester "$T/fm" >/dev/null
"$A/uninstall.sh" --dry-run "$T/fm" > "$T/dry"; grep -q 'dry run: nothing written' "$T/dry"; grep -q 'exec .*env-file' "$T/fm/config/launch-env-hook"
out=$("$A/uninstall.sh" "$T/fm"); grep -q 'prior git identity values are not known' <<< "$out"
[ "$(cat "$T/fm/config/launch-env-hook")" = 'original hook' ] && [ "$(cat "$T/fm/config/unrelated")" = keep ] && [ ! -e "$T/data/fm-git-identity/git-identity" ] && [ ! -e "$T/data/fm-git-identity/identity.gitconfig" ]
"$A/uninstall.sh" "$T/fm" >/dev/null; echo 'PASS git-identity uninstall'
