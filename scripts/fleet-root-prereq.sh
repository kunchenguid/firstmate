#!/usr/bin/env bash
# ONE-TIME root prerequisite for FirstMate federation (the ONLY privileged step).
# Creates the shared group + group-writable KB dir that operators coordinate through.
# Idempotent and additive — safe to re-run. Review it, then run as root:
#
#     sudo bash scripts/fleet-root-prereq.sh
#
# It changes nothing outside: (1) the `agents` group, (2) group membership for the
# listed operators, (3) /opt/agents/fleet (mode 2775 setgid). Reverse steps at the end.
#
# Required modes, exactly: every directory under the fleet dir is root:agents
# 2775 (setgid so created files inherit the group; group-writable; world-readable)
# and every file in it is 0664. Those modes are safe ONLY because the dir is
# data: nothing on any operator's PATH lives here, nothing here is executed or
# sourced, and the dir must never hold a git repository the fleet runs git
# against, because git executes hooks, fsmonitor, and filter commands from
# repo-local config, which here would be another operator's code. This script
# refuses a dir containing .git for that reason, and bin/fm-fleet-lib.sh never
# runs git in the KB.
#
# Pass --check to see exactly what it WOULD change and nothing else. --check needs
# no root and never mutates, so an operator can inspect the delta before deciding
# whether they want this tier at all.
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
fm_portable_group() { # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then stat -f '%Sg' "$1" 2>/dev/null
  else stat -c '%G' "$1" 2>/dev/null; fi
}
CHECK=0
[ "${1:-}" != --check ] || { CHECK=1; shift; }
GROUP=${FM_FLEET_GROUP:-agents}
DIR=${FM_FLEET_ROOT_DIR:-/opt/agents/fleet}
# Operators default to whoever invoked sudo — NEVER a baked-in list, or running this
# on someone else's host would try to enrol names that mean nothing there. Add the
# rest of your team explicitly:
#   sudo FM_FLEET_OPERATORS="alice bob carol" bash scripts/fleet-root-prereq.sh
OPERATORS=${FM_FLEET_OPERATORS:-${SUDO_USER:-}}

# Read-only delta report. Deliberately usable WITHOUT root: an operator deciding
# whether they want this tier should not have to escalate merely to look. Exits
# non-zero only when action is genuinely required, so it composes in scripts.
if [ "$CHECK" = 1 ]; then
  needed=0
  echo "fleet-root-prereq: CHECK ONLY - nothing will be changed."
  echo
  if getent group "$GROUP" >/dev/null 2>&1 || grep -qE "^$GROUP:" /etc/group 2>/dev/null; then
    printf '  %-32s present\n' "group '$GROUP'"
  else
    printf '  %-32s ABSENT   would run: groupadd -f %s\n' "group '$GROUP'" "$GROUP"; needed=1
  fi
  for u in $OPERATORS; do
    if ! id -u "$u" >/dev/null 2>&1; then
      printf '  %-32s no such OS user - would be skipped\n' "member $u"
    elif id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP"; then
      printf '  %-32s present\n' "member $u"
    else
      printf '  %-32s ABSENT   would run: usermod -aG %s %s\n' "member $u" "$GROUP" "$u"; needed=1
    fi
  done
  if [ -d "$DIR" ]; then
    printf '  %-32s present  mode %s  group %s\n' "$DIR" \
      "$(fm_portable_mode "$DIR" 2>/dev/null || echo '?')" \
      "$(fm_portable_group "$DIR" 2>/dev/null || echo '?')"
    [ "$(fm_portable_mode "$DIR" 2>/dev/null)" = 2775 ] || { printf '  %-32s would re-apply mode 2775 (setgid)\n' ""; needed=1; }
  else
    printf '  %-32s ABSENT   would create mode 2775, group %s\n' "$DIR" "$GROUP"; needed=1
  fi
  if [ -e "$DIR/.git" ]; then
    printf '  %-32s PRESENT  must be removed: the shared KB never holds a git repo\n' "$DIR/.git"; needed=1
  fi
  echo
  if [ "$needed" = 0 ]; then
    echo "Result: no action required. Nothing to install."
  else
    echo "Result: action required. Review the steps above, then approve by running:"
    echo "    sudo FM_FLEET_OPERATORS=\"$OPERATORS\" bash $0"
  fi
  exit "$needed"
fi

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0" >&2; exit 1; }

if [ -z "${OPERATORS// /}" ]; then
  cat >&2 <<EOF
$0: no operators to enrol.

Could not infer one (SUDO_USER is unset — you are probably in a root shell rather
than using sudo). Name them explicitly:

    sudo FM_FLEET_OPERATORS="alice bob" bash $0

Every operator must already be an OS user on this host.
EOF
  exit 1
fi

groupadd -f "$GROUP"
for u in $OPERATORS; do
  if id -u "$u" >/dev/null 2>&1; then
    usermod -aG "$GROUP" "$u"; echo "added $u to $GROUP"
  else
    echo "skip: OS user '$u' does not exist"
  fi
done

if [ -e "$DIR/.git" ]; then
  cat >&2 <<EOF
$0: refusing: $DIR/.git exists.

The shared fleet dir is group-writable, and running git in a group-writable
repo executes another operator's code (hooks, fsmonitor, and filter drivers
come from repo-local config). Move any history elsewhere, remove $DIR/.git,
and re-run.
EOF
  exit 1
fi

mkdir -p "$DIR/locks"
chgrp -R "$GROUP" "$DIR"
find "$DIR" -type d -exec chmod 2775 {} +   # setgid dirs: files created here inherit the group
find "$DIR" -type f -exec chmod g+rw {} +

echo "--- verify ---"
ls -ld "$DIR"
echo "expect: drwxrwsr-x root:$GROUP $DIR"
echo
echo "NEXT (per operator, NO root needed):"
echo "  • group membership takes effect on your NEXT login (re-login or 'newgrp $GROUP')"
echo "  • echo 'umask 002' >> ~/.bashrc   # keep shared files group-writable"
echo "  • cd <your firstmate home> && FM_FLEET_DIR=$DIR bin/fm-fleet.sh init   # once, first operator only"
echo "  • FM_FLEET_DIR=$DIR bin/fm-fleet-join.sh <you> <scopes-csv> [accounts-csv]"
echo
echo "# Reverse (only if you ever want to undo):"
echo "#   for u in $OPERATORS; do gpasswd -d \$u $GROUP 2>/dev/null; done; groupdel $GROUP; rm -rf $DIR"
