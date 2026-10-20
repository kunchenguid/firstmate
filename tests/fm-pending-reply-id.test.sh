#!/usr/bin/env bash
# Correlation creation must work without the optional OpenSSL executable.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pending-reply-id)
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT

(
  # Hide only OpenSSL discovery; all fallback tools remain real executables.
  # shellcheck disable=SC2329 # Shadowed builtin, called indirectly by the pending-reply helper.
  command() {
    if [ "$#" -eq 2 ] && [ "$1" = -v ] && [ "$2" = openssl ]; then
      return 1
    fi
    builtin command "$@"
  }
  home="$TMP_ROOT/parent"
  state="$home/state"
  mkdir -p "$state"
  corr=$(fm_pending_reply_create "$home" "$state" ios 'report the result')
  [[ "$corr" =~ ^[0-9a-f]{16}$ ]] || fail "fallback did not create a correlation id"
  assert_grep 'task_id=ios' "$state/pending-replies/$corr" \
    "fallback did not persist the pending-reply expectation"
) || fail "pending-reply creation without OpenSSL failed"

pass "pending-reply creation works without OpenSSL under nounset"
