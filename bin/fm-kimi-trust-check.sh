#!/usr/bin/env bash
# Validate one Kimi workspace-trust record against its canonical worktree root.
# Sole owner of the trust predicate; callers must not restate it.
# Exit 0 when the record is a valid trust grant for <root>, exit 1 for every
# rejection (missing, symlinked, unreadable, malformed, non-object, wrong root,
# or a non-positive/non-numeric trustedAt), exit 2 when the predicate cannot be
# evaluated at all (bad usage, or jq unavailable) so an environment fault is
# never reported as a rejection.
set -u
[ "$#" -eq 2 ] || { echo "usage: $0 <root> <trust-file>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: $0 requires jq" >&2; exit 2; }
root=$(cd "$1" 2>/dev/null && pwd -P) || exit 1
trust_file=$2
[ -f "$trust_file" ] && [ ! -L "$trust_file" ] || exit 1
jq -er --arg root "$root" \
  'select((type == "object") and .root == $root and (.trustedAt | type) == "number" and .trustedAt > 0) | .root' \
  "$trust_file" >/dev/null 2>&1 || exit 1
