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

overlay_root=$(fm_test_tmproot fm-check-lib-overlay)
overlay_state="$overlay_root/state"
overlay_fake="$overlay_root/fakebin"
mkdir -p "$overlay_state" "$overlay_fake"
printf '#!/usr/bin/env bash\nprintf "custom check\\n"\n' > "$overlay_state/$ID.check.sh"
chmod 0700 "$overlay_state/$ID.check.sh"
overlay_hash=$(fm_custom_check_sha256 "$overlay_state/$ID.check.sh") \
  || fail "could not hash overlay fixture check"
printf 'fm-custom-check-v1\n%s\n' "$overlay_hash" > "$overlay_state/$ID.check-trust"
chmod 0600 "$overlay_state/$ID.check-trust"
real_stat=$(command -v stat)
cat > "$overlay_fake/stat" <<SH
#!/usr/bin/env bash
path=\${!#}
case " \$* " in
  *" %d "*)
    if [ -d "\$path" ]; then
      printf '39\\n'
      exit 0
    fi
    if [ -f "\$path" ]; then
      printf '40\\n'
      exit 0
    fi
    ;;
esac
exec "$real_stat" "\$@"
SH
chmod +x "$overlay_fake/stat"
PATH="$overlay_fake:$PATH" fm_custom_check_snapshot_prepare "$overlay_state" "$ID" \
  || fail "overlay custom-check snapshot was not prepared"
[ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] || fail "overlay snapshot path was not created"
fm_custom_check_snapshot_cleanup
pass "custom check snapshot accepts overlay file-layer devices"
