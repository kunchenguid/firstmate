#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Cost-shape tests for the checkout identity primitives in
# bin/fm-checkout-lock-lib.sh.
#
# These pin a COST invariant, not a behavior: proving one checkout's identity
# must cost a fixed number of helper processes, independent of how many
# worktrees the repository has registered.
#
# The regression this file exists for: fm_checkout_validate_git_metadata used
# to resolve every path `git worktree list` reported with its own helper
# process. One identity check therefore cost one process launch per registered
# worktree, and any caller that checked identity per worktree paid that product.
# A 61-worktree repository turned a spawn preflight into ~2,000 process
# launches and roughly 105 seconds of wall clock, on every single spawn, growing
# with the fleet rather than with the repository being spawned into.
#
# Counting processes rather than seconds keeps this deterministic: it is the
# actual cost driver, and it does not flake on a loaded machine. The counter
# wraps the library's own helper-process entry point from the TEST process, so
# no production code carries a hook for it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$ROOT/bin/fm-checkout-lock-lib.sh"

pass() {
  printf 'ok - %s\n' "$1"
}

fm_git_identity fmtest fmtest@example.invalid
fm_test_tmproot_into TMP_ROOT fm-checkout-identity-cost

HELPER_CALL_LOG="$TMP_ROOT/helper-calls"

# Wrap the library's helper-process launcher with a counter. The wrapper appends
# to a FILE rather than incrementing a variable because every caller invokes it
# inside a command substitution, and a subshell's variables do not survive.
eval "fm_checkout_system_perl_real() $(declare -f fm_checkout_system_perl | sed -n '2,$p')"
fm_checkout_system_perl() {
  printf 'x' >> "$HELPER_CALL_LOG"
  fm_checkout_system_perl_real "$@"
}

helper_calls_for() {
  local description=$1
  shift
  : > "$HELPER_CALL_LOG"
  "$@" > /dev/null 2>&1 || fail "$description unexpectedly failed"
  wc -c < "$HELPER_CALL_LOG" | tr -d ' '
}

# build_repo_with_worktrees <name> <count>: a repository carrying <count>
# additional registered worktrees, printed as its exact root.
build_repo_with_worktrees() {
  local name=$1 count=$2 repo index=1
  repo="$TMP_ROOT/$name"
  fm_git_init_commit "$repo" >/dev/null 2>&1 || fail "could not create fixture repository $name"
  while [ "$index" -le "$count" ]; do
    git -C "$repo" worktree add --quiet --detach "$TMP_ROOT/$name-wt-$index" >/dev/null 2>&1 \
      || fail "could not register worktree $index for $name"
    index=$((index + 1))
  done
  (cd "$repo" && pwd -P)
}

test_identity_cost_is_flat_in_registered_worktrees() {
  local small large small_calls large_calls small_registrations large_registrations
  small=$(build_repo_with_worktrees small 1)
  large=$(build_repo_with_worktrees large 24)
  small_registrations=$(git -C "$small" worktree list | wc -l | tr -d ' ')
  large_registrations=$(git -C "$large" worktree list | wc -l | tr -d ' ')
  [ "$large_registrations" -gt "$small_registrations" ] \
    || fail "the fixture did not actually add registrations"

  small_calls=$(helper_calls_for "identity validation of a $small_registrations-worktree repository" \
    fm_checkout_validate_git_metadata "$small")
  large_calls=$(helper_calls_for "identity validation of a $large_registrations-worktree repository" \
    fm_checkout_validate_git_metadata "$large")

  [ "$small_calls" = "$large_calls" ] || fail \
    "identity validation cost grows with registered worktrees: $small_registrations worktrees cost $small_calls helper processes, $large_registrations cost $large_calls. Resolve every registration in one batch instead of one process per registration."
  pass "checkout identity validation costs the same whatever the worktree count"
}

test_identity_cost_stays_small_in_absolute_terms() {
  local large large_calls limit=6
  large=$(build_repo_with_worktrees budget 24)
  large_calls=$(helper_calls_for "identity validation under a fixed process budget" \
    fm_checkout_validate_git_metadata "$large")
  [ "$large_calls" -le "$limit" ] || fail \
    "identity validation used $large_calls helper processes, above the $limit budget; a flat but large cost is still paid on every worktree of every sweep"
  pass "checkout identity validation stays within a small fixed process budget"
}

test_batch_resolution_is_positional_and_mode_aware() {
  local real untrusted out line_count first second third
  real="$TMP_ROOT/batch-real"
  mkdir -p "$real/nested"
  real=$(cd "$real" && pwd -P)
  untrusted="$real-link"
  ln -s "$real" "$untrusted"

  fm_checkout_trusted_dirs strict "$real" "$untrusted" >/dev/null 2>&1 \
    && fail "strict batch resolution accepted a symlinked directory"

  out=$(fm_checkout_trusted_dirs lenient "$real" "$untrusted" "$real/nested") \
    || fail "lenient batch resolution failed on a recoverable input"
  line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$line_count" -eq 3 ] \
    || fail "lenient batch resolution returned $line_count lines for 3 inputs; positional alignment is what makes per-row decisions safe"
  first=$(printf '%s\n' "$out" | sed -n '1p')
  second=$(printf '%s\n' "$out" | sed -n '2p')
  third=$(printf '%s\n' "$out" | sed -n '3p')
  [ "$first" = "+$real" ] || fail "lenient batch resolution lost a trusted directory"
  [ "$second" = - ] || fail "lenient batch resolution trusted a symlinked directory"
  [ "$third" = "+$real/nested" ] \
    || fail "lenient batch resolution did not keep later rows aligned after an untrusted one"

  out=$(fm_checkout_trusted_dirs lenient "$real" "$real/nested" "$untrusted") \
    || fail "lenient batch resolution failed with a trailing untrusted input"
  line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$line_count" -eq 3 ] \
    || fail "lenient batch resolution dropped a trailing untrusted row"
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = "+$real" ] \
    || fail "trailing-untrusted resolution lost its first trusted row"
  [ "$(printf '%s\n' "$out" | sed -n '2p')" = "+$real/nested" ] \
    || fail "trailing-untrusted resolution lost its second trusted row"
  [ "$(printf '%s\n' "$out" | sed -n '3p')" = - ] \
    || fail "trailing-untrusted resolution lost its final rejection row"

  out=$(fm_checkout_trusted_dirs lenient "$untrusted" "$untrusted" "$untrusted") \
    || fail "lenient batch resolution failed when every input was untrusted"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 3 ] \
    || fail "all-untrusted batch resolution did not preserve every row"
  [ "$out" = $'-\n-\n-' ] \
    || fail "all-untrusted batch resolution returned an unexpected wire format"

  out=$(fm_checkout_trusted_dirs lenient "$untrusted") \
    || fail "lenient batch resolution failed for one untrusted input"
  [ "$out" = - ] \
    || fail "single-untrusted batch resolution did not preserve its rejection row"

  out=$(fm_checkout_trusted_dirs strict "$real" "$real/nested") \
    || fail "strict batch resolution rejected two trusted directories"
  line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$line_count" -eq 2 ] || fail "strict batch resolution returned $line_count lines for 2 inputs"
  pass "batch directory resolution keeps per-path trust decisions and row alignment"
}

test_batch_resolution_matches_single_path_resolution() {
  local candidate batch single
  for candidate in "$TMP_ROOT" "$TMP_ROOT/batch-real" "$TMP_ROOT/batch-real-link" \
    "$TMP_ROOT/missing-entirely" "$TMP_ROOT/batch-real/nested/.." /; do
    single=$(fm_checkout_trusted_dir "$candidate" 2>/dev/null) || single='<rejected>'
    batch=$(fm_checkout_trusted_dirs lenient "$candidate" 2>/dev/null) || batch='<rejected>'
    case "$batch" in
      +/*) batch=${batch#+} ;;
      -) batch='<rejected>' ;;
      *) batch='<invalid>' ;;
    esac
    [ "$single" = "$batch" ] || fail \
      "batch and single-path resolution disagree for $candidate: single=$single batch=$batch"
  done
  pass "batch resolution agrees with single-path resolution on every trust decision"
}

test_identity_cost_is_flat_in_registered_worktrees
test_identity_cost_stays_small_in_absolute_terms
test_batch_resolution_is_positional_and_mode_aware
test_batch_resolution_matches_single_path_resolution
