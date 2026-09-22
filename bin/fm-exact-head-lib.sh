#!/usr/bin/env bash
# Shared exact-head worktree byte, mode, index, ignored-file, and submodule
# inspection. fm-spawn uses this before launch staging, while the pane-side
# launch guard uses the same implementation at the actual worker boundary.

expected_head_raw_tree_status() { # <worktree> [<immutable-coordinate>]
  local worktree=$1 coordinate=${2:-HEAD}
  local record metadata mode type object path actual complete=0 producer_status=1
  local link_bytes link_size sub_super sub_head
  while IFS= read -r -d '' record; do
    if [ -z "$record" ]; then
      IFS= read -r -d '' producer_status || return 1
      complete=1
      break
    fi
    case "$record" in *$'\t'*) ;; *) return 1 ;; esac
    metadata=${record%%$'\t'*}
    path=${record#*$'\t'}
    read -r mode type object <<<"$metadata"
    case "$mode:$type" in
      100644:blob|100755:blob)
        if [ ! -f "$worktree/$path" ] || [ -L "$worktree/$path" ]; then
          printf 'raw tree mismatch: %s\n' "$path"
          continue
        fi
        actual=$(git -C "$worktree" hash-object --no-filters -- "$worktree/$path" 2>/dev/null) || return 1
        if [ "$actual" != "$object" ] ||
          { [ "$mode" = 100755 ] && [ ! -x "$worktree/$path" ]; } ||
          { [ "$mode" = 100644 ] && [ -x "$worktree/$path" ]; }; then
          printf 'raw tree mismatch: %s\n' "$path"
        fi
        ;;
      120000:blob)
        if [ ! -L "$worktree/$path" ]; then
          printf 'raw tree mismatch: %s\n' "$path"
          continue
        fi
        link_bytes=$(readlink "$worktree/$path" | wc -c | tr -d '[:space:]') || return 1
        case "$link_bytes" in ''|*[!0-9]*) return 1 ;; esac
        [ "$link_bytes" -gt 0 ] || return 1
        link_size=$((link_bytes - 1))
        actual=$(readlink "$worktree/$path" | dd bs=1 count="$link_size" 2>/dev/null | git -C "$worktree" hash-object --stdin) || return 1
        [ "$actual" = "$object" ] || printf 'raw tree mismatch: %s\n' "$path"
        ;;
      160000:commit)
        sub_super=$(git -C "$worktree/$path" rev-parse --show-superproject-working-tree 2>/dev/null || true)
        if [ -n "$sub_super" ]; then
          sub_head=$(git -C "$worktree/$path" rev-parse --verify --quiet HEAD 2>/dev/null || true)
          [ "$sub_head" = "$object" ] || printf 'raw tree mismatch: %s\n' "$path"
        fi
        ;;
      *) return 1 ;;
    esac
  done < <({ git -C "$worktree" ls-tree -r -z --full-tree "$coordinate"; printf '\0%s\0' "$?"; })
  [ "$complete" -eq 1 ] && [ "$producer_status" -eq 0 ]
}

expected_head_worktree_status() { # <worktree> [<immutable-coordinate>]
  local worktree=$1 coordinate=${2:-HEAD}
  local untracked ignored index raw diff_rc record metadata mode type object path sub_super nested
  local complete=0 producer_status=1
  untracked=$(git -C "$worktree" ls-files --others --exclude-standard) || return 1
  [ -z "$untracked" ] || printf 'untracked: %s\n' "$untracked"
  ignored=$(git -C "$worktree" ls-files --others --ignored --exclude-standard) || return 1
  [ -z "$ignored" ] || printf 'ignored: %s\n' "$ignored"
  index=$(git -C "$worktree" -c core.quotePath=true ls-files -v) || return 1
  index=$(printf '%s\n' "$index" | LC_ALL=C grep -E '^[a-zS] ' || true)
  [ -z "$index" ] || printf '%s\n' "$index"
  if git -C "$worktree" -c core.fileMode=true diff-index --cached --quiet "$coordinate" --; then
    diff_rc=0
  else
    diff_rc=$?
  fi
  case "$diff_rc" in
    0) ;;
    1) printf 'index tree mismatch\n' ;;
    *) return 1 ;;
  esac
  raw=$(expected_head_raw_tree_status "$worktree" "$coordinate") || return 1
  [ -z "$raw" ] || printf '%s\n' "$raw"
  while IFS= read -r -d '' record; do
    if [ -z "$record" ]; then
      IFS= read -r -d '' producer_status || return 1
      complete=1
      break
    fi
    case "$record" in *$'\t'*) ;; *) return 1 ;; esac
    metadata=${record%%$'\t'*}
    path=${record#*$'\t'}
    read -r mode type object <<<"$metadata"
    [ "$mode:$type" = 160000:commit ] || continue
    sub_super=$(git -C "$worktree/$path" rev-parse --show-superproject-working-tree 2>/dev/null || true)
    [ -n "$sub_super" ] || continue
    nested=$(expected_head_worktree_status "$worktree/$path" "$object") || return 1
    [ -z "$nested" ] || printf '%s\n%s\n' "$path" "$nested"
  done < <({ git -C "$worktree" ls-tree -z "$coordinate"; printf '\0%s\0' "$?"; })
  [ "$complete" -eq 1 ] && [ "$producer_status" -eq 0 ]
}
