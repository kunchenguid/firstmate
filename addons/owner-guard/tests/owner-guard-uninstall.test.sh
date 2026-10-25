#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'chmod -R u+w -- "$T"; rm -rf -- "$T"' EXIT
mkdir -p "$T/home" "$T/fm/config" "$T/previous-hooks"; export HOME=$T/home XDG_DATA_HOME=$T/data GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/global.gitconfig
: > "$GIT_CONFIG_GLOBAL"; git config --global core.hooksPath "$T/previous-hooks"; printf '#!/bin/sh\necho prior\n' > "$T/fm/config/merge-gate"; chmod +x "$T/fm/config/merge-gate"; printf 'fake-pattern\n' > "$T/fm/config/owner-details-patterns"
"$A/install.sh" "$T/fm" >/dev/null; "$A/uninstall.sh" --dry-run "$T/fm" > "$T/dry"; grep -q 'dry run: nothing written' "$T/dry"; grep -q 'fm-owner-guard' "$T/fm/config/merge-gate"
"$A/uninstall.sh" "$T/fm" >/dev/null
[ "$(cat "$T/fm/config/merge-gate")" = "$(printf '#!/bin/sh\necho prior\n')" ] && [ "$(git config --global core.hooksPath)" = "$T/previous-hooks" ] && [ ! -e "$T/data/fm-owner-guard/owner-guard" ] && [ ! -e "$T/data/fm-git-identity/hooks.d/pre-commit/owner-guard" ]
"$A/uninstall.sh" "$T/fm" >/dev/null; echo 'PASS owner-guard uninstall'
