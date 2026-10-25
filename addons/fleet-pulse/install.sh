#!/usr/bin/env bash
# Install chat-tsv.py into <home>/bin and, when state/fleet-pulse.check.sh still
# globs only main-home fm-retro-*/report.md, point its retro wake at
# bin/fleet-retro-due.sh (newest report.md across known homes).
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] || { echo 'usage: install.sh [--dry-run] <home>' >&2; exit 2; }
home=$(cd "$1" && pwd -P)
addon=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
src=$addon/bin/chat-tsv.py
dest=$home/bin/chat-tsv.py
check=$home/state/fleet-pulse.check.sh
due=$addon/bin/fleet-retro-due.sh

if [ "$DRY" -eq 1 ]; then
  echo "would install $src -> $dest"
  if [ -f "$check" ] && grep -q 'fm-retro-\*/report\.md' "$check"; then
    echo "would retarget retro wake in $check -> $due"
  fi
  exit 0
fi

mkdir -p "$home/bin"
install -m 755 "$src" "$dest"
echo "installed: $dest (schedule it periodically with FM_HOME=$home)"

if [ -f "$check" ] && grep -q 'fm-retro-\*/report\.md' "$check"; then
  python3 - "$check" "$due" "$home" <<'PY'
import pathlib, re, sys
path, due, home = map(pathlib.Path, sys.argv[1:4])
text = path.read_text()
block = (
    "# Fleet retro every 2-3 days (captain 5 Oct): wake Main once 60 h after the last retro report.\n"
    f"if msg=$({due.as_posix()!r} {home.as_posix()!r}); then\n"
    '  echo "$msg"; exit 0\n'
    "fi\n"
)
pat = re.compile(
    r"# Fleet retro every 2-3 days.*?\n"
    r"last=\$\(ls -t .*?fm-retro-\*/report\.md.*?\n"
    r"RM=.*\n"
    r"if \[ -n \"\$last\" \].*?\n"
    r"  touch \"\$RM\"; echo \"fleet-retro due:.*?\n"
    r"fi\n",
    re.S,
)
new, n = pat.subn(block, text, count=1)
if n != 1:
    sys.stderr.write(f"install: could not retarget retro wake in {path}\n")
    sys.exit(1)
path.write_text(new)
print(f"retargeted retro wake: {path} -> {due}")
PY
fi
