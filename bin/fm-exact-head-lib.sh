#!/usr/bin/env bash
# Shared exact-head worktree byte, mode, index, ignored-file, and submodule
# inspection. fm-spawn uses this before launch staging, while the pane-side
# launch guard uses the same implementation at the actual worker boundary.

expected_head_raw_tree_status() { # <worktree>
  local worktree=$1 record metadata mode type object path actual complete=0 producer_status=1
  local link_bytes link_size sub_super sub_head nested
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
          if [ "$sub_head" != "$object" ]; then
            printf 'raw tree mismatch: %s\n' "$path"
          else
            nested=$(expected_head_raw_tree_status "$worktree/$path") || return 1
            [ -z "$nested" ] || printf '%s\n' "$nested"
          fi
        fi
        ;;
      *) return 1 ;;
    esac
  done < <({ git -C "$worktree" ls-tree -r -z --full-tree HEAD; printf '\0%s\0' "$?"; })
  [ "$complete" -eq 1 ] && [ "$producer_status" -eq 0 ]
}

expected_head_worktree_status() { # <worktree>
  local status index raw
  status=$(git -C "$1" -c core.quotePath=false -c core.fileMode=true status --porcelain \
    --untracked-files=all --ignored=matching --ignore-submodules=none) || return 1
  [ -z "$status" ] || printf '%s\n' "$status"
  index=$(git -C "$1" -c core.quotePath=true ls-files -v) || return 1
  index=$(printf '%s\n' "$index" | LC_ALL=C grep -E '^[a-zS] ' || true)
  [ -z "$index" ] || printf '%s\n' "$index"
  # shellcheck disable=SC2016 # The submodule foreach shell expands these variables.
  git -C "$1" submodule foreach --quiet --recursive '
    status=$(git -c core.quotePath=false -c core.fileMode=true status --porcelain --untracked-files=all --ignored=matching --ignore-submodules=none) || exit 1
    [ -z "$status" ] || printf "%s\n%s\n" "$displaypath" "$status"
    index=$(git -c core.quotePath=true ls-files -v) || exit 1
    index=$(printf "%s\n" "$index" | LC_ALL=C grep -E "^[a-zS] " || true)
    [ -z "$index" ] || printf "%s\n%s\n" "$displaypath" "$index"
  ' || return 1
  raw=$(expected_head_raw_tree_status "$1") || return 1
  [ -z "$raw" ] || printf '%s\n' "$raw"
}
