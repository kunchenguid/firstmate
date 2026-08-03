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
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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
  target_sha=$(printf '%s' "$backend:$target" | shasum -a 256 | awk '{print $1}')
else
  identity_sha=$(printf '%s' "$root:$identity" | sha256sum | awk '{print $1}')
  target_sha=$(printf '%s' "$backend:$target" | sha256sum | awk '{print $1}')
fi

rows=$(LC_ALL=C ps -axo pid=,ppid=,lstart=,time= 2>/dev/null) || exit 1
current=$(printf '%s\n' "$rows" | awk -v root="$root" '
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
    parent[$1] = $2
    started[$1] = $3 " " $4 " " $5 " " $6 " " $7
    value[$1] = centis($8)
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
    for (p in member) print p "|" started[p] "\t" value[p]
  }
')
mkdir -p "$STATE"
ledger="$STATE/.process-progress-$target_sha"
prior=/dev/null
if [ -f "$ledger" ] && [ ! -L "$ledger" ] \
  && [ "$(awk -F '\t' '$1 == "root" { print $2; exit }' "$ledger" 2>/dev/null)" = "$identity_sha" ]; then
  prior=$ledger
fi
tmp=$(mktemp "$STATE/.process-progress.XXXXXX") || exit 1
total_file=$(mktemp "$STATE/.process-progress-total.XXXXXX") || { rm -f "$tmp"; exit 1; }
printf 'root\t%s\n' "$identity_sha" > "$tmp"
awk -F '\t' -v total_file="$total_file" '
  FILENAME == ARGV[1] {
    if ($1 == "retired") retired = $2 + 0
    else if ($1 == "proc") previous[$2] = $3 + 0
    next
  }
  {
    current[$1] = $2 + 0
  }
  END {
    for (key in previous) {
      if (!(key in current)) retired += previous[key]
    }
    total = retired
    print "retired\t" retired
    for (key in current) {
      value = current[key]
      if ((key in previous) && previous[key] > value) value = previous[key]
      print "proc\t" key "\t" value
      total += value
    }
    print total + 0 > total_file
  }
' "$prior" <(printf '%s\n' "$current") >> "$tmp" || { rm -f "$tmp" "$total_file"; exit 1; }
cpu=$(cat "$total_file")
rm -f "$total_file"
case "$cpu" in ''|*[!0-9]*) rm -f "$tmp"; exit 1 ;; esac
mv "$tmp" "$ledger" || { rm -f "$tmp"; exit 1; }
printf '%s\t%s\n' "$identity_sha" "$cpu"
