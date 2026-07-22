#!/usr/bin/env bash
# Authoritative primary/support ship-lane lease management.
# Usage:
#   fm-lane-reserve.sh acquire primary <task-id>
#   fm-lane-reserve.sh acquire support <task-id> --supports <primary-task-id>
#   fm-lane-reserve.sh release <task-id>
#   fm-lane-reserve.sh renew <task-id>
#   fm-lane-reserve.sh status
#
# The authoritative lease store lives in the primary Firstmate home's
# state/.delivery-leases/ directory. Secondmate work may hold a local cache,
# but this store is the sole authority. All writes are atomic and identity-bound
# (owner PID plus start identity).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
LEASE_DIR="$FM_HOME/state/.delivery-leases"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
CMD=$1
shift

if [ "$CMD" = status ] || [ "$CMD" = reconcile ]; then
  :
else
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
fi

mkdir -p "$LEASE_DIR"
chmod 700 "$LEASE_DIR"

fm_lane_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fm_lane_pid() { printf '%s' "${FM_LANE_OWNER:-$$}"; }
fm_lane_start_identity() { printf '%s_%s' "$(fm_lane_pid)" "$(fm_lane_now)"; }

lease_path() { printf '%s/%s.json\n' "$LEASE_DIR" "$1"; }

atomic_write_lease() {
  local id=$1 content=$2
  local tmp path
  path=$(lease_path "$id")
  tmp=$(mktemp "$path.tmp.XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$path"
}

read_lease() {
  local path=$1
  [ -f "$path" ] || { printf '{}\n'; return 0; }
  cat "$path"
}

# Validate that a task id is safe for the lease filename.
valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

do_acquire() {
  local lane=$1 id=$2 supports=${3:-}
  valid_id "$id" || { echo "error: invalid task id: $id" >&2; exit 2; }
  [ "$lane" = primary ] || [ "$lane" = support ] || { echo "error: lane must be primary or support" >&2; exit 2; }
  if [ "$lane" = support ] && [ -z "$supports" ]; then
    echo "error: support lease requires --supports <primary-task-id>" >&2
    exit 2
  fi

  local path now owner identity content
  path=$(lease_path "$id")
  now=$(fm_lane_now)
  identity=$(fm_lane_start_identity)
  owner=$(fm_lane_pid)

  # Refuse a second primary if one already exists.
  if [ "$lane" = primary ]; then
    for existing in "$LEASE_DIR"/*.json; do
      [ -e "$existing" ] || continue
      local elane
      elane=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('lane',''))" < "$existing")
      if [ "$elane" = primary ]; then
        local existing_id
        existing_id=$(basename "$existing" .json)
        [ "$existing_id" = "$id" ] && continue
        echo "error: primary lane already held by $existing_id" >&2
        exit 1
      fi
    done
  fi

  # Refuse a support that does not name an existing primary, unless this is the
  # cutover's Dotfiles support and the primary is explicitly named.
  if [ "$lane" = support ] && [ -n "$supports" ]; then
    local primary_path
    primary_path=$(lease_path "$supports")
    if [ ! -f "$primary_path" ]; then
      echo "error: support lease references non-existent primary $supports" >&2
      exit 1
    fi
  fi

  if [ -f "$path" ]; then
    # Idempotent re-acquire only when owner identity matches exactly.
    local old_owner old_identity
    old_owner=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('owner',''))" < "$path")
    old_identity=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('identity',''))" < "$path")
    if [ "$old_owner" != "$owner" ] || [ "$old_identity" != "$identity" ]; then
      echo "error: lease $id already held by $old_owner" >&2
      exit 1
    fi
  fi

  content=$(python3 - "$lane" "$id" "$supports" "$owner" "$identity" "$now" <<'PYEOF'
import json, sys
lane, id, supports, owner, identity, now = sys.argv[1:7]
doc = {
    "schemaVersion": "firstmate.lane-lease.v1",
    "lane": lane,
    "id": id,
    "supports": supports or None,
    "owner": owner,
    "identity": identity,
    "acquiredAt": now,
    "renewedAt": now
}
print(json.dumps(doc))
PYEOF
)
  atomic_write_lease "$id" "$content"
  echo "acquired $lane lease for $id"
}

do_release() {
  local id=$1
  valid_id "$id" || { echo "error: invalid task id: $id" >&2; exit 2; }
  local path
  path=$(lease_path "$id")
  if [ ! -f "$path" ]; then
    echo "no lease for $id"
    return 0
  fi
  rm -f "$path"
  echo "released lease for $id"
}

do_renew() {
  local id=$1 path now owner old_owner content
  valid_id "$id" || { echo "error: invalid task id: $id" >&2; exit 2; }
  path=$(lease_path "$id")
  [ -f "$path" ] || { echo "error: no lease to renew for $id" >&2; exit 1; }
  owner=$(fm_lane_pid)
  old_owner=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('owner',''))" < "$path")
  if [ "$old_owner" != "$owner" ]; then
    echo "error: lease $id owned by $old_owner, cannot renew" >&2
    exit 1
  fi
  now=$(fm_lane_now)
  content=$(python3 - "$path" "$now" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
doc["renewedAt"] = sys.argv[2]
print(json.dumps(doc))
PYEOF
)
  atomic_write_lease "$id" "$content"
  echo "renewed lease for $id"
}

do_status() {
  local found=0
  for path in "$LEASE_DIR"/*.json; do
    [ -e "$path" ] || continue
    found=1
    python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d.get('lane','?')} {d.get('id','?')} supports={d.get('supports')} owner={d.get('owner')}\")" < "$path"
  done
  if [ "$found" -eq 0 ]; then
    echo "no active leases"
  fi
}

do_reconcile() {
  # Remove leases whose owner PID no longer exists (stale-owner reconciliation).
  local path owner
  for path in "$LEASE_DIR"/*.json; do
    [ -e "$path" ] || continue
    owner=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('owner',''))" < "$path")
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      local id
      id=$(basename "$path" .json)
      echo "reconciled stale lease for $id (owner $owner gone)"
      rm -f "$path"
    fi
  done
}

# Argument parsing -----------------------------------------------------------
case "$CMD" in
  acquire)
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    LANE=$1; ID=$2; shift 2
    SUPPORTS=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --supports) SUPPORTS=$2; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
      esac
    done
    do_acquire "$LANE" "$ID" "$SUPPORTS"
    ;;
  release)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    do_release "$1"
    ;;
  renew)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    do_renew "$1"
    ;;
  status)
    do_status
    ;;
  reconcile)
    do_reconcile
    ;;
  *)
    echo "error: unknown command $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
