#!/usr/bin/env bash
# tests/treehouse-helpers.sh - Active writer-lease fixture for suites that drive
# the real spawn or teardown interfaces without testing Treehouse itself.

fm_test_write_active_treehouse_fake() {  # <fakebin> [default-worktree-path]
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u

case "${1:-} ${2:-}" in
  "get --help")
    printf '%s\n' 'Usage: treehouse get [--lease] [--json] [--lease-holder <id>]'
    exit 0
    ;;
  "return --help")
    printf '%s\n' 'Usage: treehouse return [--if-lease-id <id>] [--if-lease-holder <id>] <path>'
    exit 0
    ;;
esac

case "${1:-}" in
  get)
    shift
    holder=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    path=${FM_FAKE_TREEHOUSE_PATH:-${FM_FAKE_PANE_PATH:-}}
    if [ -z "$path" ] && [ -f "${0%/*}/.treehouse-path" ]; then
      IFS= read -r path < "${0%/*}/.treehouse-path"
    fi
    : "${path:?}"
    lease=${FM_FAKE_TREEHOUSE_LEASE:-lease-$holder}
    slot=${FM_FAKE_TREEHOUSE_SLOT:-slot-fixture}
    jq -cn --arg path "$path" --arg lease "$lease" --arg holder "$holder" \
      --arg slot "$slot" \
      '{name:$slot,path:$path,lease_id:$lease,lease_holder:$holder}'
    ;;
  status)
    state=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}
    separator=
    printf '['
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      path=$(sed -n 's/^worktree=//p' "$meta" | head -1)
      [ -n "$path" ] || continue
      holder=${meta##*/}
      holder=${holder%.meta}
      lease=$(sed -n 's/^treehouse_lease=//p' "$meta" | head -1)
      slot=$(sed -n 's/^treehouse_slot=//p' "$meta" | head -1)
      [ -n "$lease" ] || lease=lease-$holder
      [ -n "$slot" ] || slot=slot-fixture
      printf '%s' "$separator"
      jq -cn --arg path "$path" --arg lease "$lease" --arg holder "$holder" \
        --arg slot "$slot" \
        '{name:$slot,path:$path,status:"leased",lease_id:$lease,lease_holder:$holder}'
      separator=,
    done
    printf ']\n'
    ;;
  return) exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" > "$fakebin/.treehouse-path"
  fi
}
