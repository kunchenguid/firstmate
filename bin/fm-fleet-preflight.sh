#!/usr/bin/env bash
# fm-fleet-preflight.sh — report which fleet tier this home is ready for, and what
# each unmet tier would still need. READ-ONLY: it never installs, creates, or
# changes anything, so it is safe to run before deciding whether you want the
# capability at all.
#
# The tiers are independent and additive (docs/fleet-quickstart.md):
#   A  token visibility + model->surface picker     no root, no shared dir
#   B  several accounts for one person              no root, no shared dir
#   C  several operators on one host (Admiral)      root once per host, opt-in
#
# Tier C is deliberately OPT-IN. A home without the gitignored config/admiral flag
# behaves exactly as a single-operator home always has, and this report says so
# rather than treating the default as a deficiency.
#
# Usage:
#   fm-fleet-preflight.sh            (human report)
#   fm-fleet-preflight.sh --quiet    (exit status only)
#
# Exit: 0 when at least Tier A is ready; 1 when a Tier A prerequisite is missing.
set -euo pipefail

# Portable file mode: BSD stat (macOS) has no -c. macOS is a declared supported
# platform (README badge), and the repo already branches this way in
# bin/backends/herdr.sh.
fm_portable_mode() { # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
QUIET=0
[ "${1:-}" != --quiet ] || QUIET=1

# The caller supplies the format string, which is the point: every report line keeps
# its own column widths at the call site instead of being assembled here.
# shellcheck disable=SC2059  # format is the caller's first argument, by design
say() { [ "$QUIET" = 1 ] || printf "$@"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Group membership as the KERNEL sees it for this process, not as /etc/group claims.
# A long-lived tmux/screen server and the systemd --user manager both keep the group
# set they started with, so `id` can report a group the running process does not
# actually carry - the single most confusing fleet failure there is.
in_group_now() { # <group>
  # Membership as this PROCESS carries it, not as /etc/group claims: a long-lived
  # tmux server or the systemd --user manager keeps the group set it started with.
  # /proc is the precise source but is Linux-only, so fall back to id(1) elsewhere.
  local gid
  gid=$(portable_gid "$1") || return 1
  if [ -r "/proc/$$/status" ]; then
    grep -qE "^Groups:.*(^| )${gid}( |$)" "/proc/$$/status" 2>/dev/null
  else
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$1"
  fi
}

# Group lookup without getent, which does not exist on macOS.
portable_gid() { # <group>
  local line
  line=$(getent group "$1" 2>/dev/null) || line=$(grep -E "^$1:" /etc/group 2>/dev/null | head -1)
  [ -n "$line" ] || return 1
  printf '%s' "$line" | cut -d: -f3
}

group_exists() { portable_gid "$1" >/dev/null 2>&1; }

FLEET_GROUP=${FM_FLEET_GROUP:-agents}
FLEET_DIR=${FM_FLEET_DIR:-}
if [ -z "$FLEET_DIR" ] && [ -f "$FM_HOME/config/fleet-dir" ]; then
  FLEET_DIR=$(head -1 "$FM_HOME/config/fleet-dir")
fi
FLEET_DIR=${FLEET_DIR:-/opt/agents/fleet}

# --- Tier A ------------------------------------------------------------------
a_missing=()
for t in bash git awk jq curl python3 flock realpath; do
  have "$t" || a_missing+=("$t")
done
quota_note="ready"
have quota-axi || quota_note="degraded (no quota-axi: queue/claim/route work, no quota-aware routing)"
a_state=ready
[ "${#a_missing[@]}" -eq 0 ] || a_state=BLOCKED

# --- Tier B ------------------------------------------------------------------
b_state=ready
if [ -f "$FM_HOME/config/accounts.json" ]; then
  b_note="config/accounts.json present"
else
  b_note="not configured (optional; cp docs/examples/accounts.json config/accounts.json)"
fi

# --- Tier C ------------------------------------------------------------------
admiral=absent
[ ! -f "$FM_HOME/config/admiral" ] || admiral=present
if [ "$admiral" = present ]; then
  c_state="opt-in"
  c_note="config/admiral present"
else
  c_state="opt-out"
  c_note="config/admiral absent - this is the default"
fi

say '%-5s %-32s %-9s %s\n' TIER CAPABILITY STATUS NOTE
say '%-5s %-32s %-9s %s\n' A "token visibility + failover" "$a_state" "$quota_note"
say '%-5s %-32s %-9s %s\n' B "several accounts, one person" "$b_state" "$b_note"
say '%-5s %-32s %-9s %s\n' C "several operators (Admiral)" "$c_state" "$c_note"

if [ "${#a_missing[@]}" -gt 0 ]; then
  say '\nTier A is blocked. Install: %s\n' "${a_missing[*]}"
fi

# One label column for every prerequisite line, so the report reads as a checklist
# rather than as ragged prose.
row() { say '  %-30s %s\n' "$1" "$2"; }
ROOT_FIX='ABSENT   -> sudo bash scripts/fleet-root-prereq.sh'

say '\nTier C would additionally need:\n'
if group_exists "$FLEET_GROUP"; then
  row "group '$FLEET_GROUP'" 'present'
else
  row "group '$FLEET_GROUP'" "$ROOT_FIX"
fi
if in_group_now "$FLEET_GROUP"; then
  row 'your membership' 'active in this process'
elif group_exists "$FLEET_GROUP" && id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$FLEET_GROUP"; then
  row 'your membership' 'GRANTED BUT NOT ACTIVE - this process predates it.'
  row '' "Re-login, or wrap commands in: sg $FLEET_GROUP -c \"...\""
else
  row 'your membership' "$ROOT_FIX"
fi
if [ -d "$FLEET_DIR" ]; then
  row "$FLEET_DIR" "present  mode $(fm_portable_mode "$FLEET_DIR" 2>/dev/null || printf '?')"
else
  row "$FLEET_DIR" "$ROOT_FIX"
fi
if [ "$admiral" = present ]; then
  row 'config/admiral' 'present'
else
  row 'config/admiral' 'ABSENT   -> bin/fm-fleet.sh admiral enable'
fi

say '\nNothing was changed. Tiers A and B need no root and no shared directory.\n'
say 'Run the privileged step only if you actually want Tier C:\n'
say '  sudo bash scripts/fleet-root-prereq.sh --check    # see exactly what it would do\n'

[ "${#a_missing[@]}" -eq 0 ]
