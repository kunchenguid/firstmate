# shellcheck shell=bash disable=SC2034
# Durable secondmate reread-nudge marker helpers. Source only.
#
# Both local tracked-file convergence and remote inherited-material transfer
# publish the same bounded record before delivery. A failed send leaves the
# record for the locked bootstrap retry; a successful send removes it.

FM_SECOND_MATE_NUDGE_MESSAGE='firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE='Firstmate instructions or inherited config changed on this host. Re-read AGENTS.md and the inherited config files before further work.'

fm_secondmate_nudge_marker_path() { # <state-dir> <id>
  local state=$1 id=$2
  case "$id" in *[!/A-Za-z0-9._-]*|''|*/*) return 1 ;; esac
  printf '%s/.secondmate-nudge-pending/%s.pending\n' "$state" "$id"
}

fm_remote_inherit_transaction_lock_path() { # <state-dir> <id>
  local state=$1 id=$2
  case "$id" in *[!/A-Za-z0-9._-]*|''|*/*) return 1 ;; esac
  printf '%s/.remote-inherit-%s.lock\n' "$state" "$id"
}

fm_remote_inherit_generation_next() { # <state-dir> <id>
  local state=$1 id=$2 path current next tmp
  case "$id" in *[!/A-Za-z0-9._-]*|''|*/*) return 1 ;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  path="$state/.remote-inherit-$id.generation"
  current=0
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    IFS= read -r current < "$path" || return 1
    case "$current" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#current}" -le 17 ] || return 1
  fi
  next=$((current + 1))
  tmp=$(umask 077; mktemp "$state/.remote-inherit-generation.XXXXXX") || return 1
  printf '%s\n' "$next" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$next"
}

fm_secondmate_nudge_value() {
  local marker=$1 key=$2
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  awk -v key="$key" '
    index($0, key "=") == 1 {
      count += 1
      value = substr($0, length(key) + 2)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$marker"
}

fm_secondmate_remote_nudge_matches() {
  local marker=$1 id=$2 home=$3 remote_host=$4 remote_root=$5 owner=${6:-} value
  value=$(fm_secondmate_nudge_value "$marker" id 2>/dev/null) || return 1
  [ "$value" = "$id" ] || return 1
  value=$(fm_secondmate_nudge_value "$marker" selector 2>/dev/null) || return 1
  [ "$value" = "fm-$id" ] || return 1
  value=$(fm_secondmate_nudge_value "$marker" home 2>/dev/null) || return 1
  [ "$value" = "$home" ] || return 1
  value=$(fm_secondmate_nudge_value "$marker" commit 2>/dev/null) || return 1
  [ -z "$value" ] || return 1
  value=$(fm_secondmate_nudge_value "$marker" instructions 2>/dev/null) || return 1
  [ "$value" = remote ] || return 1
  value=$(fm_secondmate_nudge_value "$marker" message 2>/dev/null) || return 1
  [ "$value" = "$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" ] || return 1
  value=$(fm_secondmate_nudge_value "$marker" remote 2>/dev/null) || return 1
  [ "$value" = 1 ] || return 1
  if [ -n "$owner" ]; then
    value=$(fm_secondmate_nudge_value "$marker" owner 2>/dev/null) || return 1
    [ "$value" = "$owner" ] || return 1
  elif grep -q '^owner=' "$marker" 2>/dev/null; then
    return 1
  fi
  value=$(fm_secondmate_nudge_value "$marker" remote_host 2>/dev/null) || return 1
  [ "$value" = "$remote_host" ] || return 1
  value=$(fm_secondmate_nudge_value "$marker" remote_root 2>/dev/null) || return 1
  [ "$value" = "$remote_root" ]
}

fm_secondmate_nudge_write() { # <state> <id> <home> <commit> <instructions> <message> <remote:0|1> [owner] [remote-host] [remote-root] [replace|create]
  local state=$1 id=$2 home=$3 commit=$4 instructions=$5 message=$6 remote=$7
  local owner=${8:-} remote_host=${9:-} remote_root=${10:-} mode=${11:-replace}
  local marker parent tmp
  case "$remote" in
    0) [ -z "$remote_host" ] && [ -z "$remote_root" ] || return 1 ;;
    1) [ -n "$remote_host" ] && [ -n "$remote_root" ] || return 1 ;;
    *) return 1 ;;
  esac
  case "$mode" in replace|create) ;; *) return 1 ;; esac
  case "$home$commit$instructions$message$owner$remote_host$remote_root" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  marker=$(fm_secondmate_nudge_marker_path "$state" "$id") || return 1
  parent=${marker%/*}
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  else
    mkdir -p "$parent" || return 1
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$mode" != create ] || return 2
  fi
  tmp=$(umask 077; mktemp "$parent/.nudge.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'id=%s\n' "$id"
    printf 'selector=fm-%s\n' "$id"
    printf 'home=%s\n' "$home"
    printf 'commit=%s\n' "$commit"
    printf 'instructions=%s\n' "$instructions"
    printf 'message=%s\n' "$message"
    printf 'remote=%s\n' "$remote"
    [ -z "$owner" ] || printf 'owner=%s\n' "$owner"
    [ -z "$remote_host" ] || printf 'remote_host=%s\n' "$remote_host"
    [ -z "$remote_root" ] || printf 'remote_root=%s\n' "$remote_root"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ "$mode" = create ]; then
    if ln -- "$tmp" "$marker" 2>/dev/null; then
      rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
      return 2
    fi
  else
    mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
  fi
}
