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

fm_secondmate_nudge_write() { # <state> <id> <home> <commit> <instructions> <message> <remote:0|1>
  local state=$1 id=$2 home=$3 commit=$4 instructions=$5 message=$6 remote=$7
  local marker parent tmp
  case "$remote" in 0|1) ;; *) return 1 ;; esac
  case "$home$commit$instructions$message" in *$'\n'*|*$'\r'*) return 1 ;; esac
  marker=$(fm_secondmate_nudge_marker_path "$state" "$id") || return 1
  parent=${marker%/*}
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  else
    mkdir -p "$parent" || return 1
  fi
  [ ! -L "$marker" ] || return 1
  tmp=$(umask 077; mktemp "$parent/.nudge.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'id=%s\n' "$id"
    printf 'selector=fm-%s\n' "$id"
    printf 'home=%s\n' "$home"
    printf 'commit=%s\n' "$commit"
    printf 'instructions=%s\n' "$instructions"
    printf 'message=%s\n' "$message"
    printf 'remote=%s\n' "$remote"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}
