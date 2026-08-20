#!/usr/bin/env bash
# Characterization coverage for Claude account-profile validation primitives.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-claude-account-profile-lib.sh disable=SC1091
. "$ROOT/bin/fm-claude-account-profile-lib.sh"

for valid in primary a1 account-2; do
  fm_claude_account_profile_name_valid "$valid" \
    || fail "valid account-profile name was rejected: $valid"
done

for invalid in '' 1primary Primary 'primary_name' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
  if fm_claude_account_profile_name_valid "$invalid"; then
    fail "unsafe account-profile name was accepted: $invalid"
  fi
done

for private_mode in 700 1700 2700; do
  fm_claude_account_profile_mode_is_private "$private_mode" \
    || fail "private mode was rejected: $private_mode"
done

for public_mode in 701 740 755 770; do
  if fm_claude_account_profile_mode_is_private "$public_mode"; then
    fail "group/world-accessible mode was accepted: $public_mode"
  fi
done

pass "claude-account-profile-lib validates safe names and private directory modes"
echo '# fm-claude-account-profile-lib.test.sh: all assertions passed'
