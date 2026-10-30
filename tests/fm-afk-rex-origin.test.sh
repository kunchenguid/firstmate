#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-afk-launch.sh
. "$ROOT/bin/fm-afk-launch.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-rex-origin)
FM_AFK_LAUNCH_STATE=$TMP_ROOT
FM_AFK_LAUNCH_RECORD="$TMP_ROOT/terminal"
fm_backend_source() { :; }
fm_backend_rex_server_endpoint() { printf '%s' "$CURRENT"; }
fm_backend_rex_block_presence() { printf missing; }
fm_backend_rex_target_ready() { return 0; }
fm_backend_rex_cli() { printf 'kill\n' >> "$TMP_ROOT/calls"; }
fm_afk_launch_log() { printf '%s\n' "$*" >&2; }
CURRENT=server-a
fm_afk_launch_record_write rex s:b session:s server-a || fail "record publication failed"
fm_afk_launch_record_read || fail "record could not be read"
CURRENT=server-b
fm_afk_launch_terminal_alive rex s:b && fail "foreign server proved liveness"
fm_afk_launch_close_recorded && fail "foreign server finalized the route"
assert_present "$FM_AFK_LAUNCH_RECORD" "server mismatch lost its route"
assert_absent "$TMP_ROOT/calls" "server mismatch killed a foreign session"
CURRENT=server-a
fm_afk_launch_close_recorded || fail "matching origin did not finalize an absent endpoint"
assert_absent "$FM_AFK_LAUNCH_RECORD" "confirmed absence retained the route"
printf 'rex\ts:b\tsession:s\n' > "$FM_AFK_LAUNCH_RECORD"
unset FM_AFK_LEGACY_REX_SERVER
fm_afk_launch_record_read
[ "$?" -eq 2 ] || fail "unverified legacy record was not refused"
[ "$(cat "$FM_AFK_LAUNCH_RECORD")" = $'rex\ts:b\tsession:s' ] || fail "refused legacy record was changed"
fm_afk_launch_close_recorded && fail "an unproven legacy origin finalized its route"
assert_present "$FM_AFK_LAUNCH_RECORD" "unproven origin lost its route"
pass "AFK Rex lifecycle requires the recorded creation server"
