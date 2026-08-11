#!/usr/bin/env bash

fm_home_boundary_resolve() {  # <path>
  local p=$1 rp IFS=/ part out
  rp=$(realpath -m "$p" 2>/dev/null) || rp=
  if [ -z "$rp" ]; then
    case "$p" in /*) rp=$p ;; *) rp=$PWD/$p ;; esac
    out=
    for part in $rp; do
      case "$part" in
        ''|.) ;;
        ..) out=${out%/*} ;;
        *) out="$out/$part" ;;
      esac
    done
    rp=${out:-/}
  fi
  printf '%s\n' "$rp"
}

fm_home_boundary_private_owner() {  # <resolved-path>
  local rp=$1 owner
  case "$rp" in
    /home/*)
      owner=${rp#/home/}
      owner=${owner%%/*}
      [ -n "$owner" ] || return 1
      printf '%s\n' "$owner"
      ;;
    /Users/*)
      owner=${rp#/Users/}
      owner=${owner%%/*}
      case "$owner" in ''|Shared) return 1 ;; esac
      printf '%s\n' "$owner"
      ;;
    *)
      return 1
      ;;
  esac
}
