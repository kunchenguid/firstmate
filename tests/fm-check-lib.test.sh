#!/usr/bin/env bash
# tests/fm-check-lib.test.sh - custom-check trust registration and snapshots.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-check-lib)
STATE="$TMP_ROOT/state"
ID=custom
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"

mkdir -p "$STATE"
printf '#!/usr/bin/env bash\nprintf "custom check\\n"\n' > "$CHECK"
chmod 0700 "$CHECK"
hash=$(fm_custom_check_sha256 "$CHECK") || fail "could not hash fixture check"
printf 'fm-custom-check-v1\n%s\n' "$hash" > "$TRUST"
chmod 0600 "$TRUST"

fm_custom_check_registered "$STATE" "$ID" \
  || fail "valid trust record was not accepted"
[ "$FM_CUSTOM_CHECK_HASH" = "$hash" ] \
  || fail "registered hash was not exported"

fm_custom_check_snapshot_prepare "$STATE" "$ID" \
  || fail "valid custom check snapshot was not prepared"
SNAPSHOT=$FM_CUSTOM_CHECK_SNAPSHOT
[ -f "$SNAPSHOT" ] || fail "snapshot path was not created"
[ "$(cat "$SNAPSHOT")" = "$(cat "$CHECK")" ] \
  || fail "snapshot contents differ from the registered check"
[ "$(fm_pr_file_mode "$SNAPSHOT")" = 600 ] \
  || fail "snapshot mode was not reduced to 0600"
fm_custom_check_snapshot_cleanup
[ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || fail "snapshot variable was not cleared"
[ ! -e "$SNAPSHOT" ] || fail "snapshot file was not removed"

printf 'unexpected\n' >> "$TRUST"
! fm_custom_check_registered "$STATE" "$ID" \
  || fail "trust record with trailing data was accepted"
pass "custom check trust validation and snapshot lifecycle are enforced"
