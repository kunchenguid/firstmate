#!/usr/bin/env bash
set -u

pid=${1:-}
token=${2:-}
case "$pid" in ''|*[!0-9]*|0|1) exit 2 ;; esac
case "$token" in ''|*[!0-9a-f]*) exit 2 ;; esac

proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
tree_matches() {
  [ -r "$proc_root/$pid/environ" ] \
    && tr '\0' '\n' < "$proc_root/$pid/environ" 2>/dev/null \
      | grep -F -x -- "FM_PI_ARM_TREE_TOKEN=$token" >/dev/null 2>&1
}

tree_matches || exit 3
MSYS2_ARG_CONV_EXCL='*' taskkill.exe /PID "$pid" /T /F >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 20 ]; do
  tree_matches || exit 0
  sleep 0.05
  i=$((i + 1))
done
exit 1
