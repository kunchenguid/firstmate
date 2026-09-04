#!/usr/bin/env bash
# Behavior test for the watcher's shadow-only wait-event writer.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-premise-shadow)

# fm-pr-lib.sh owns the private state-file invariant (fm_pr_private_file_valid)
# and the device/link-count/mode readers the marker safety cases assert on.
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

set_mtime() {  # <epoch> <file>
  local epoch=$1 file=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$file"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$file"
  fi
}

test_shadow_writer_rejects_symlink() {
  local dir state fakebin statusf target
  dir=$(make_case shadow-writer-symlink); state="$dir/state"; fakebin="$dir/fakebin"
  statusf="$state/held.status"
  target="$dir/redirected.log"
  printf 'paused: waiting for the fork PR wait=pr:https://github.com/pedromuller-del/firstmate/pull/3541\n' \
    > "$statusf"
  printf '# must remain untouched\n' > "$target"
  ln -s "$target" "$state/wait-events.log"
  prime_status_seen "$state" "$statusf"
  printf '#!/usr/bin/env bash\nprintf "MERGED\\n"\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shadow_wait_premise held' _ "$WATCH" \
    || fail "shadow writer invocation failed"
  [ -L "$state/wait-events.log" ] || fail "shadow writer replaced the pre-planted symlink"
  [ "$(cat "$target")" = '# must remain untouched' ] || fail "shadow writer followed a pre-planted symlink"
  pass "shadow wait events reject a pre-planted symlink"
}

# Shared fixture for the wait-premise occurrence-marker safety cases: a real
# paused wait=pr: line, a fake gh that reports the PR still OPEN so the premise
# resolves to still-waiting and shadow_wait_premise writes the occurrence
# marker, and the status-seen marker primed so the watcher seam reaches the
# premise call. Echoes the case dir.
setup_marker_case() {  # <name>
  local dir state fakebin statusf
  dir=$(make_case "$1"); state="$dir/state"; fakebin="$dir/fakebin"
  statusf="$state/held.status"
  printf 'paused: waiting for the fork PR wait=pr:https://github.com/pedromuller-del/firstmate/pull/3541\n' \
    > "$statusf"
  prime_status_seen "$state" "$statusf"
  printf '#!/usr/bin/env bash\nprintf "OPEN\\n"\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

# The occurrence marker at state/.wait-premise-<task> must be a private file
# (regular, not a symlink, mode 0600, link count 1, on the state device) when
# the premise resolves, matching the invariant its sibling shadow logs already
# enforce through shadow_wait_log_append. Before the fix this fails red on
# mode 644 (umask 022): the plain `>` write never sets 0600.
test_wait_premise_marker_is_private_file() {
  local dir state device marker
  dir=$(setup_marker_case marker-private); state="$dir/state"
  marker="$state/.wait-premise-held"
  device=$(fm_pr_file_device "$state") || fail "cannot read state device"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shadow_wait_premise held' _ "$WATCH" \
    || fail "marker writer invocation failed"
  [ -f "$marker" ] && [ ! -L "$marker" ] || fail "occurrence marker is not a regular file"
  fm_pr_private_file_valid "$marker" 600 "$device" \
    || fail "occurrence marker must satisfy the private-file invariant (mode 0600, nlink 1, on device)"
  [ -s "$marker" ] || fail "occurrence marker was not written"
  pass "shadow wait-premise marker is a private 0600 file"
}

# A pre-planted symlink at state/.wait-premise-<task> must NOT be followed: the
# marker write refuses it and leaves the attacker-selected target untouched.
# Before the fix this fails red: the plain `>` follows the symlink and clobbers
# the victim.
test_wait_premise_marker_rejects_symlink() {
  local dir state device marker victim
  dir=$(setup_marker_case marker-symlink); state="$dir/state"
  marker="$state/.wait-premise-held"
  victim="$dir/victim.secret"
  printf 'SENSITIVE-VICTIM-CONTENT-DO-NOT-CLOBBER\n' > "$victim"
  chmod 600 "$victim"
  ln -s "$victim" "$marker"
  device=$(fm_pr_file_device "$state") || fail "cannot read state device"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shadow_wait_premise held' _ "$WATCH" \
    || fail "marker writer invocation failed"
  [ "$(cat "$victim")" = 'SENSITIVE-VICTIM-CONTENT-DO-NOT-CLOBBER' ] \
    || fail "marker write followed a pre-planted symlink and clobbered the target"
  [ -L "$marker" ] || fail "marker write replaced a pre-planted symlink instead of refusing it"
  pass "shadow wait-premise marker refuses a pre-planted symlink"
}

# A pre-planted hardlink at state/.wait-premise-<task> must NOT be written
# through: the marker write rejects the shared inode (link count 2) and leaves
# the attacker-selected target untouched. Before the fix this fails red: the
# plain `>` truncates and writes through the hardlink.
test_wait_premise_marker_rejects_hardlink() {
  local dir state device marker victim
  dir=$(setup_marker_case marker-hardlink); state="$dir/state"
  marker="$state/.wait-premise-held"
  victim="$dir/victim.secret"
  printf 'SENSITIVE-VICTIM-CONTENT-DO-NOT-CLOBBER\n' > "$victim"
  chmod 600 "$victim"
  ln "$victim" "$marker"
  device=$(fm_pr_file_device "$state") || fail "cannot read state device"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shadow_wait_premise held' _ "$WATCH" \
    || fail "marker writer invocation failed"
  [ "$(cat "$victim")" = 'SENSITIVE-VICTIM-CONTENT-DO-NOT-CLOBBER' ] \
    || fail "marker write followed a pre-planted hardlink and clobbered the target"
  [ "$(fm_pr_file_link_count "$marker")" = 2 ] \
    || fail "marker write truncated or replaced a pre-planted hardlink instead of refusing it"
  pass "shadow wait-premise marker refuses a pre-planted hardlink"
}

# Producer-to-consumer coverage: the publisher refuses a pre-planted hardlink
# (link count 2) and leaves it in place; the consumer must then apply the
# matching private/no-follow/identity validation and refuse to read or remove
# it, so the attacker's forged row never becomes a correction record. Before
# the fix this fails red: the consumer read the hardlink after only
# `[ -f ] && [ ! -L ]`, emitted the attacker's row into wait-corrections.log,
# and removed the marker.
test_wait_premise_consumer_rejects_hardlink() {
  local dir state device marker victim
  dir=$(setup_marker_case marker-consumer-hardlink); state="$dir/state"
  marker="$state/.wait-premise-held"
  victim="$dir/victim.secret"
  printf 'wait=pr:https://example.invalid/attacker/forged/pull/9\t777\n' > "$victim"
  chmod 600 "$victim"
  ln "$victim" "$marker"
  device=$(fm_pr_file_device "$state") || fail "cannot read state device"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shadow_wait_correction held' _ "$WATCH" \
    || fail "consumer invocation failed"
  [ ! -e "$state/wait-corrections.log" ] || [ ! -s "$state/wait-corrections.log" ] \
    || fail "consumer emitted a correction record from a refused hardlink marker"
  [ -e "$marker" ] || fail "consumer removed a refused hardlink marker instead of refusing it"
  [ "$(cat "$victim")" = 'wait=pr:https://example.invalid/attacker/forged/pull/9	777' ] \
    || fail "consumer altered the attacker's hardlink target"
  [ "$(fm_pr_file_link_count "$marker")" = 2 ] \
    || fail "consumer changed the refused hardlink's link count"
  pass "shadow wait-premise consumer refuses a hardlink marker"
}

# Producer-to-consumer coverage for a base-created mode-0644 legacy marker: the
# publisher refuses it (mode != 0600) and leaves it in place; the consumer must
# refuse it too, so the stale legacy row never becomes a correction record.
# Before the fix this fails red: the consumer read the legacy marker after only
# `[ -f ] && [ ! -L ]` and emitted its stale row into wait-corrections.log.
test_wait_premise_consumer_rejects_legacy_mode_0644() {
  local dir state device marker
  dir=$(setup_marker_case marker-consumer-legacy); state="$dir/state"
  marker="$state/.wait-premise-held"
  printf 'wait=pr:https://example.invalid/legacy/old/pull/8\t777\n' > "$marker"
  chmod 644 "$marker"
  device=$(fm_pr_file_device "$state") || fail "cannot read state device"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1"; shadow_wait_correction held' _ "$WATCH" \
    || fail "consumer invocation failed"
  [ ! -e "$state/wait-corrections.log" ] || [ ! -s "$state/wait-corrections.log" ] \
    || fail "consumer emitted a correction record from a legacy mode-0644 marker"
  [ -e "$marker" ] || fail "consumer removed a legacy mode-0644 marker instead of refusing it"
  [ "$(cat "$marker")" = 'wait=pr:https://example.invalid/legacy/old/pull/8	777' ] \
    || fail "consumer altered the legacy marker's content"
  pass "shadow wait-premise consumer refuses a legacy mode-0644 marker"
}

test_shadow_writer_rejects_symlink
test_wait_premise_marker_is_private_file
test_wait_premise_marker_rejects_symlink
test_wait_premise_marker_rejects_hardlink
test_wait_premise_consumer_rejects_hardlink
test_wait_premise_consumer_rejects_legacy_mode_0644
