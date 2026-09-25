#!/usr/bin/env bash
# fm-branch-name-lib.sh - the single owner of a ship branch's name, derived from
# its task id.
#
# Usage:
#   # shellcheck source=bin/fm-branch-name-lib.sh
#   . "$SCRIPT_DIR/fm-branch-name-lib.sh"
#   branch=$(fm_ship_branch_name "$BRANCH_PREFIX" "$ID" "$CONFIG")
#
# The branch name is "<prefix><task id>", unchanged by default.
# When the home's config directory (third argument) holds the presence flag
# `ship-branch-ticket-case`, a Jira-style ticket token embedded anywhere in the
# task id is canonicalized to its uppercase KEY-NNN form, so the same ticket is
# spelled one way no matter how the id was authored (ve1262, ve-1262, VE-1262,
# visto-pipelines-ve1262-...).
# That canonical spelling is what lets no-mistakes' `commit.fix_message` and
# `pr.title_format` `{{.Branch}}` placeholders carry a stable `[VE-XXXX]`
# ticket, which a branch-pattern match against a lowercased id cannot do.
#
# A ticket-shaped token is 2-4 ASCII letters, an optional dash, then 3-6 digits,
# bounded by a non-alphanumeric character or a string edge. The letter-count and
# digit-count floors keep ordinary slug fragments (v121, mysql2, php8, api) from
# being rewritten as if they were tickets.
#
# The function never fails. Without the flag, or for an id with no ticket-shaped
# token, the id is returned unchanged, and only the first matching token is
# normalized.

fm_ship_branch_name() {
  local prefix=$1 id=$2 config=${3-}
  local whole replacement
  if [ -n "$config" ] && [ -e "$config/ship-branch-ticket-case" ] &&
    [[ $id =~ (^|[^[:alnum:]])([[:alpha:]]{2,4})-?([0-9]{3,6})([^[:alnum:]]|$) ]]; then
    whole=${BASH_REMATCH[0]}
    replacement="${BASH_REMATCH[1]}${BASH_REMATCH[2]^^}-${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
    printf '%s%s\n' "$prefix" "${id/"$whole"/"$replacement"}"
  else
    printf '%s%s\n' "$prefix" "$id"
  fi
}
