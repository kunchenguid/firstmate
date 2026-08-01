#!/usr/bin/env bash
# Sample cumulative CPU for the descendant closure of one recorded backend pane.
# This is progress evidence, not a current-state oracle: callers compare two
# samples with the same root-process identity and use only a positive delta.
#
# Usage: fm-process-progress.sh <backend> <target>
# Output: <root-identity-sha256><TAB><cumulative-centiseconds>
#
# Verified root PID bindings currently exist for tmux and herdr. zellij, Orca,
# and cmux return nonzero rather than guessing. FM_PROCESS_PROGRESS_ROOT_PID is
# a test seam for a pre-bound root.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

[ "$#" -eq 2 ] || { printf 'usage: fm-process-progress.sh <backend> <target>\n' >&2; exit 2; }
backend=$1
target=$2
root=${FM_PROCESS_PROGRESS_ROOT_PID:-}
[ -n "$root" ] || root=$(fm_backend_process_root_pid "$backend" "$target")
case "$root" in ''|*[!0-9]*) exit 1 ;; esac

identity=$(LC_ALL=C ps -p "$root" -o lstart= -o command= 2>/dev/null) || exit 1
[ -n "$identity" ] || exit 1
if command -v shasum >/dev/null 2>&1; then
  identity_sha=$(printf '%s' "$root:$identity" | shasum -a 256 | awk '{print $1}')
else
  identity_sha=$(printf '%s' "$root:$identity" | sha256sum | awk '{print $1}')
fi

rows=$(LC_ALL=C ps -axo pid=,ppid=,time=,command= 2>/dev/null) || exit 1
cpu=$(printf '%s\n' "$rows" | awk -v root="$root" '
  function centis(raw, d, rest, n, a, h, m, s) {
    d = 0
    rest = raw
    if (index(rest, "-") > 0) {
      split(rest, dayparts, "-")
      d = dayparts[1] + 0
      rest = dayparts[2]
    }
    n = split(rest, a, ":")
    h = 0; m = 0; s = 0
    if (n == 3) { h = a[1] + 0; m = a[2] + 0; s = a[3] + 0 }
    else if (n == 2) { m = a[1] + 0; s = a[2] + 0 }
    else { s = a[1] + 0 }
    return int((((d * 24 + h) * 60 + m) * 60 + s) * 100 + 0.5)
  }
  {
    pid[NR] = $1
    parent[$1] = $2
    value[$1] = centis($3)
    seen[$1] = 1
  }
  END {
    member[root] = 1
    changed = 1
    while (changed) {
      changed = 0
      for (p in seen) {
        if (!member[p] && member[parent[p]]) {
          member[p] = 1
          changed = 1
        }
      }
    }
    total = 0
    for (p in member) total += value[p]
    print total + 0
  }
')
case "$cpu" in ''|*[!0-9]*) exit 1 ;; esac
printf '%s\t%s\n' "$identity_sha" "$cpu"
