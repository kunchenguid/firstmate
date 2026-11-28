#!/usr/bin/env bash
# fm-claude-account-quota.sh - measure each Claude account a home declares in
# config/claude-accounts, in isolation, and print each one's quota facts.
#
# Usage:
#   fm-claude-account-quota.sh [--model <model>]
#
# Each entry is read with CLAUDE_CONFIG_DIR=<root> quota-axi --provider claude
# --profile-only --json, `ordinary` meaning ~/.claude. Prints a
# `claude-account-quota:` block of facts and never picks an account.
# bin/fm-account-quota-lib.sh owns the read, the output rows, and the exit
# codes; bin/fm-codex-account-quota.sh is the Codex counterpart.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-account-quota-lib.sh
. "$SCRIPT_DIR/fm-account-quota-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

MODEL=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ -n "${2-}" ] || die "--model needs a value"
      MODEL=$2
      shift 2
      ;;
    --model=*)
      MODEL=${1#--model=}
      [ -n "$MODEL" ] || die "--model needs a value"
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[ "$MODEL" != default ] || MODEL=

fm_account_quota_report claude "$CONFIG" "$MODEL"
