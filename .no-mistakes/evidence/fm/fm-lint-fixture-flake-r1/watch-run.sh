#!/usr/bin/env bash
# Runs tests/fm-lint.test.sh while polling tests/ for untracked files every 20ms.
label=$1; log=$2
: > "$log.watch"
( while :; do git ls-files --others --exclude-standard tests/ >> "$log.watch"; sleep 0.02; done ) &
w=$!
rc=0; bash tests/fm-lint.test.sh > "$log" 2>&1 || rc=$?
kill $w; wait $w 2>/dev/null
echo "[$label] fm-lint.test.sh exit=$rc"
echo "[$label] changed-mode test line: $(grep -i 'changed mode excludes cross-file' "$log")"
echo "[$label] distinct untracked files seen in tests/ during run:"
sort -u "$log.watch" | sed 's/^/  /'; [ -s "$log.watch" ] || echo "  (none)"
