#!/usr/bin/env bash
# fm_branch_prefix_resolve: the one owner of config/branch-prefix resolution
# (docs/configuration.md "Branch prefix"). A generated ship brief's task
# branch, and every script that later has to find that same branch by name
# (bin/fm-merge-local.sh, bin/fm-review-diff.sh), must agree on the exact same
# prefix, so all three source this instead of hardcoding "fm/" or resolving
# the config file themselves.
#
# Usage: fm_branch_prefix_resolve <config-dir>
#   <config-dir>: the caller's already-resolved config directory (e.g.
#     "$FM_HOME/config", or an FM_CONFIG_OVERRIDE the caller resolved itself -
#     this function does no path resolution of its own, so a relative or
#     CDPATH-sensitive override must already be handled by the caller).
# Prints the prefix (e.g. "fm/" or "ryan-fm/") to stdout. Absent or
# whitespace-only config/branch-prefix resolves to the historical default
# "fm/". No side effects on source. set -u / set -e safe.
fm_branch_prefix_resolve() {  # <config-dir>
  local config=$1 prefix=fm/
  if [ -f "$config/branch-prefix" ]; then
    prefix=$(tr -d '[:space:]' < "$config/branch-prefix")
    [ -n "$prefix" ] || prefix=fm/
  fi
  printf '%s' "$prefix"
}
