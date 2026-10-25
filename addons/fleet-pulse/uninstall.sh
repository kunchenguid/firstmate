#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: uninstall.sh <home>' >&2; exit 2; }
home=$(cd "$1" && pwd -P)
dest=$home/bin/chat-tsv.py
if [ -e "$dest" ]; then rm -- "$dest"; echo "removed: $dest"; else echo "not installed: $dest"; fi
