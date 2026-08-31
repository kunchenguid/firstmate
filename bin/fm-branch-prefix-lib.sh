#!/usr/bin/env bash
# fm-branch-prefix-lib.sh - single owner of the home-local task-branch prefix.
#
# Crewmate task branches are named <prefix>/<task-id>, and the default prefix
# is "fm". An optional local, gitignored config/branch-prefix selects a
# different prefix for one home (docs/configuration.md owns the surface).
# Every consumer - the brief scaffold (bin/fm-brief.sh), the Definition-of-done
# block (bin/fm-dod-lib.sh, also rendered by bin/fm-promote.sh), local-only
# landing (bin/fm-merge-local.sh), branch review (bin/fm-review-diff.sh), and
# the bearings PR enrichment (bin/fm-bearings-snapshot.sh) - resolves the
# prefix through this library so a brief and the helpers that land or review
# its branch cannot disagree about the branch name.
#
# An absent file is the unconfigured default. A present file must be a regular
# non-symlink file holding one line of letters, digits, and dashes with no
# slash (a single trailing newline is tolerated); any other shape is a
# configuration error that fails loudly rather than silently falling back,
# because a brief naming one branch while the landing helper resolves another
# is worse than a stopped helper.
#
# Usage: . bin/fm-branch-prefix-lib.sh
# No side effects on source. set -u / set -e safe.

FM_BRANCH_PREFIX_DEFAULT="fm"
FM_BRANCH_PREFIX_FILE="branch-prefix"
FM_BRANCH_PREFIX_ERROR=""

# fm_branch_prefix_fail <message>
# Records and prints the reason a prefix could not be resolved.
# Does not itself return a status; the resolver returns 1 after calling this.
fm_branch_prefix_fail() {  # <message>
  FM_BRANCH_PREFIX_ERROR=$1
  echo "error: $1" >&2
}

# fm_branch_prefix_resolve <config-dir>
# Prints the effective task-branch prefix (no trailing slash) on stdout and
# returns 0: the default when config/branch-prefix is absent, or the validated
# value otherwise. Any invalid shape prints the reason to stderr, records it in
# FM_BRANCH_PREFIX_ERROR, and returns 1; callers must refuse rather than fall
# back.
fm_branch_prefix_resolve() {  # <config-dir>
  local config_dir=$1 path value
  FM_BRANCH_PREFIX_ERROR=""
  path="$config_dir/$FM_BRANCH_PREFIX_FILE"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '%s\n' "$FM_BRANCH_PREFIX_DEFAULT"
    return 0
  fi
  if [ -L "$path" ]; then
    fm_branch_prefix_fail "$path is a symlink; it must be a regular one-line file"
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_branch_prefix_fail "$path is not a regular file"
    return 1
  fi
  # Read the whole file (newline-terminated or not) and strip one trailing
  # newline so both "ardy" and "ardy\n" are accepted; anything else - extra
  # lines, whitespace, a slash - is rejected by the charset check below.
  value=""
  IFS= read -r -d '' value < "$path" || true
  value=${value%$'\n'}
  if [ -z "$value" ]; then
    fm_branch_prefix_fail "$path is empty; expected one line holding the prefix, e.g. 'ardy'"
    return 1
  fi
  case "$value" in
    *[!A-Za-z0-9-]*)
      fm_branch_prefix_fail "$path must hold one line of letters, digits, and dashes with no slash (got '$value')"
      return 1
      ;;
  esac
  printf '%s\n' "$value"
  return 0
}
