#!/usr/bin/env bash
# Git-native protection for persistent linked-worktree homes.
# The per-worktree administrative receipt binds schema, mate, canonical home,
# canonical parent and a unique lock reason. Neither a familiar reason alone
# nor a home marker authorizes unlocking. Clone homes need no Git worktree lock.
# Callers retain their registry, authority and removal guards; check is read-only,
# acquire converges, release keeps the receipt for failure restoration, and
# forget removes it only after successful return. Acquired reports attempt ownership.
# shellcheck disable=SC2034 # output globals consumed by sourcing callers

fm_home_worktree_lock_context() {
  local home=$1 parent=$2 common backlink top
  FM_HOME_LOCK_LINKED=0
  FM_HOME_LOCK_DIR=
  FM_HOME_LOCK_RECEIPT=
  FM_HOME_LOCK_REASON=
  FM_HOME_LOCK_HOME=$(cd "$home" && pwd -P) || return 1
  FM_HOME_LOCK_PARENT=$(cd "$parent" && pwd -P) || return 1
  [ ! -L "$home/.git" ] || {
    echo "REFUSED: symlinked Git metadata for durable home $home" >&2
    return 1
  }
  [ -f "$home/.git" ] || return 0
  FM_HOME_LOCK_DIR=$(git -C "$home" rev-parse --absolute-git-dir) || return 1
  common=$(cd "$home" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
  top=$(git -C "$home" rev-parse --show-toplevel) || return 1
  [ "$top" = "$FM_HOME_LOCK_HOME" ] || return 1
  case "$FM_HOME_LOCK_DIR" in
    "$common"/worktrees/*)
      backlink=${FM_HOME_LOCK_DIR#"$common"/worktrees/}
      case "$backlink" in ''|*/*) return 1 ;; esac
      ;;
    *) echo "REFUSED: unknown linked-worktree identity for durable home $home" >&2; return 1 ;;
  esac
  [ ! -L "$FM_HOME_LOCK_DIR" ] && [ ! -L "$FM_HOME_LOCK_DIR/gitdir" ] || return 1
  printf '%s\n' "$FM_HOME_LOCK_HOME/.git" | cmp -s - "$FM_HOME_LOCK_DIR/gitdir" || {
    echo "REFUSED: mismatched Git worktree backlink for durable home $home" >&2
    return 1
  }
  FM_HOME_LOCK_LINKED=1
  FM_HOME_LOCK_RECEIPT="$FM_HOME_LOCK_DIR/firstmate-home-lock"
}

fm_home_worktree_lock_receipt_text() {
  printf 'schema=fm-home-worktree-lock.v1\nid=%s\nhome=%s\nparent=%s\nreason=%s\n' \
    "$1" "$FM_HOME_LOCK_HOME" "$FM_HOME_LOCK_PARENT" "$FM_HOME_LOCK_REASON"
}

fm_home_worktree_lock_check() { # <home> <id> <parent>
  local home=$1 id=$2 parent=$3 reason_line
  fm_home_worktree_lock_context "$home" "$parent" || return 1
  [ "$FM_HOME_LOCK_LINKED" = 1 ] || return 0
  if [ -e "$FM_HOME_LOCK_RECEIPT" ] || [ -L "$FM_HOME_LOCK_RECEIPT" ]; then
    [ -f "$FM_HOME_LOCK_RECEIPT" ] && [ ! -L "$FM_HOME_LOCK_RECEIPT" ] || {
      echo "REFUSED: invalid durable-home lock receipt for $home" >&2; return 1
    }
    reason_line=$(sed -n '5p' "$FM_HOME_LOCK_RECEIPT") || return 1
    FM_HOME_LOCK_REASON=${reason_line#reason=}
    case "$FM_HOME_LOCK_REASON" in
      "Firstmate durable home $id ["*']') ;;
      *) echo "REFUSED: unknown durable-home lock ownership for $home" >&2; return 1 ;;
    esac
    fm_home_worktree_lock_receipt_text "$id" | cmp -s - "$FM_HOME_LOCK_RECEIPT" || {
      echo "REFUSED: mismatched durable-home lock ownership for $home" >&2; return 1
    }
  elif [ -e "$FM_HOME_LOCK_DIR/locked" ] || [ -L "$FM_HOME_LOCK_DIR/locked" ]; then
    echo "REFUSED: foreign Git worktree lock for durable home $home" >&2
    return 1
  fi
  if [ -e "$FM_HOME_LOCK_DIR/locked" ] || [ -L "$FM_HOME_LOCK_DIR/locked" ]; then
    if [ ! -f "$FM_HOME_LOCK_DIR/locked" ] || [ -L "$FM_HOME_LOCK_DIR/locked" ] \
      || ! printf '%s\n' "$FM_HOME_LOCK_REASON" | cmp -s - "$FM_HOME_LOCK_DIR/locked"; then
      echo "REFUSED: foreign Git worktree lock for durable home $home" >&2
      return 1
    fi
  fi
}

fm_home_worktree_lock_acquire() { # <home> <id> <parent>
  local home=$1 id=$2 parent=$3 tmp new_receipt=0
  FM_HOME_LOCK_ACQUIRED=0
  fm_home_worktree_lock_check "$home" "$id" "$parent" || return 1
  [ "$FM_HOME_LOCK_LINKED" = 1 ] || return 0
  [ ! -e "$FM_HOME_LOCK_DIR/locked" ] || return 0
  if [ ! -e "$FM_HOME_LOCK_RECEIPT" ]; then
    tmp=$(umask 077; mktemp "$FM_HOME_LOCK_DIR/fm-home-lock.XXXXXX") || return 1
    FM_HOME_LOCK_REASON="Firstmate durable home $id [${tmp##*/}]"
    if ! fm_home_worktree_lock_receipt_text "$id" > "$tmp" \
      || ! ln "$tmp" "$FM_HOME_LOCK_RECEIPT"; then
      rm -f -- "$tmp"
      echo "error: cannot publish durable-home lock ownership for $home" >&2
      return 1
    fi
    rm -f -- "$tmp"
    new_receipt=1
  fi
  if ! git -C "$home" worktree lock --reason "$FM_HOME_LOCK_REASON" "$home"; then
    [ "$new_receipt" = 0 ] || rm -f -- "$FM_HOME_LOCK_RECEIPT"
    echo "error: cannot lock durable home $home" >&2
    return 1
  fi
  FM_HOME_LOCK_ACQUIRED=1
}

fm_home_worktree_lock_release() { # <home> <id> <parent>
  fm_home_worktree_lock_check "$1" "$2" "$3" || return 1
  [ "$FM_HOME_LOCK_LINKED" = 1 ] || return 0
  [ -e "$FM_HOME_LOCK_DIR/locked" ] || return 0
  git -C "$1" worktree unlock "$1" || {
    echo "error: cannot unlock owned durable home $1" >&2
    return 1
  }
}

fm_home_worktree_lock_forget() { # <home> <id> <parent>
  [ -d "$1" ] || return 0
  fm_home_worktree_lock_check "$1" "$2" "$3" || return 1
  [ "$FM_HOME_LOCK_LINKED" = 1 ] || return 0
  [ ! -e "$FM_HOME_LOCK_DIR/locked" ] || {
    echo "REFUSED: durable home $1 remains locked after return" >&2; return 1
  }
  [ ! -e "$FM_HOME_LOCK_RECEIPT" ] || rm -- "$FM_HOME_LOCK_RECEIPT"
}
