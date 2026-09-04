#!/usr/bin/env bash
# Behavior test for the watcher's shadow-only wait-event writer.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-premise-shadow)

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

test_shadow_writer_rejects_symlink
