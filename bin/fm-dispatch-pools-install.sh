#!/usr/bin/env bash
# Owned write path for a home's config/dispatch-pools.json. This script's
# header owns the install contract; docs/configuration.md routes operators
# here and names the primary home authoritative for ranks.
#
# Usage: fm-dispatch-pools-install.sh <home-config> <replacement-file> [--no-probe]
#
# Probing is the default: every pool must keep at least one viable
# candidate or the install refuses. Pass --no-probe only when offline;
# a --no-probe install still runs the admission gate but cannot see
# validate-clean outages (stale carriers, missing wrapper binaries).
#
# Contract, in order:
#  1. The replacement must be a regular file, never a symlink.
#  2. It must pass the pool's own admission gate
#     (fm-dispatch-pool.sh validate): bad identity, bad weights, duplicate
#     candidates and unknown fields refuse here, before anything is installed.
#  3. Every pool must keep at least one viable candidate. A pool with
#     zero viable candidates is a total dispatch outage (for example
#     stale-only carriers that validate clean but always reject), so the
#     install refuses instead of landing the outage. --no-probe skips
#     this step; see the usage note above.
#  4. Install is atomic (temp file plus rename) at mode 0600. An existing
#     symlink target is never followed: a symlink at the destination refuses.
#  5. Install while the fleet is idle. In-flight pooled tasks pin their
#     route receipt to the config digest, so changing ranks underneath them
#     breaks their later verify step with route_config_changed, and removing
#     or renaming a candidate breaks their relaunch with
#     pinned_candidate_not_viable. This script does not check the fleet;
#     the operator confirms idleness before running it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,24s/^# \{0,1\}//p' "$0"; exit 2; }
[ "${1:-}" = -h ] || [ "${1:-}" = --help ] && usage
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
dest=$1 src=$2 skip=${3:-}
[ "$skip" = --no-probe ] || [ -z "$skip" ] || usage
[ -f "$src" ] && [ ! -L "$src" ] || { echo 'error: replacement must be a regular file' >&2; exit 1; }
[ -n "$dest" ] && [ ! -L "$dest" ] || { echo 'error: destination must not be a symlink' >&2; exit 1; }
dest_dir=$(dirname "$dest")
[ -d "$dest_dir" ] && [ ! -L "$dest_dir" ] || { echo 'error: destination directory missing' >&2; exit 1; }
validation=$("$SCRIPT_DIR/fm-dispatch-pool.sh" validate "$src" "$dest_dir" 2>&1) || {
  printf 'error: refusing install: %s\n' "$validation" >&2; exit 1;
}
if [ -z "$skip" ]; then
  pools=$(node -e 'console.log(Object.keys(require(process.argv[1]).pools).join("\n"))' "$src")
  state_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-pool-probe.XXXXXX")
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    out=$("$SCRIPT_DIR/fm-dispatch-pool.sh" probe "$src" "$state_dir" inspection "$pool" 2>&1) || {
      printf 'error: refusing install: probe failed for pool %s: %s\n' "$pool" "$out" >&2
      rm -f "$state_dir"/dispatch-pools.json; rmdir "$state_dir"; exit 1;
    }
    viable=$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).candidates.filter(c=>c.viable).length))')
    if [ "$viable" = 0 ]; then
      printf 'error: refusing install: pool %s has zero viable candidates: %s\n' "$pool" "$out" >&2
      rm -f "$state_dir"/dispatch-pools.json; rmdir "$state_dir"; exit 1;
    fi
  done <<EOF
$pools
EOF
  rm -f "$state_dir"/dispatch-pools.json; rmdir "$state_dir"
fi
tmp="$dest_dir/.dispatch-pools.json.$$.tmp"
rm -f "$tmp"
cp -p "$src" "$tmp"
chmod 0600 "$tmp"
mv "$tmp" "$dest"
printf 'installed %s\n' "$dest"
