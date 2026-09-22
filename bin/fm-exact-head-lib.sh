#!/usr/bin/env bash
# Shared exact-head worktree byte, mode, index, ignored-file, and submodule
# inspection. fm-spawn uses this before launch staging, while the pane-side
# launch guard uses the same implementation at the actual worker boundary.

exact_head_git() {
  # Custody reads retain ordinary repository structure and index semantics, but
  # no config layer or inherited process variable may turn a read into code
  # execution. Git aliases cannot shadow the built-in subcommands used below;
  # command-scope overrides neutralize the local execution-capable settings
  # that still apply after global/system and command-env config are removed.
  local git_bin=${EXACT_HEAD_GIT_BIN:-}
  if [ -z "$git_bin" ]; then
    git_bin=$(command -v git 2>/dev/null) || return 1
  fi
  case "$git_bin" in /*) ;; *) return 1 ;; esac
  [ -x "$git_bin" ] || return 1
  /usr/bin/env \
    -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_SYSTEM -u GIT_EXTERNAL_DIFF -u GIT_DIFF_OPTS \
    -u GIT_PAGER -u GIT_EDITOR -u GIT_SEQUENCE_EDITOR \
    -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_SSH -u GIT_SSH_COMMAND \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    "$git_bin" --no-pager \
      -c core.fsmonitor=false \
      -c core.hooksPath=/dev/null \
      -c core.excludesFile=/dev/null \
      "$@"
}

expected_head_execution_config_status() { # <worktree>
  # Some local Git settings name arbitrary commands and cannot be wildcard-
  # disabled without changing how reviewed bytes materialize. Exact-head mode
  # refuses those settings before fetch/reset/submodule operations rather than
  # executing them. Settings safely neutralized by exact_head_git (fsmonitor,
  # hooks, external diff/pager, and global/system config) remain supported.
  local worktree=$1 record key value complete=0 producer_status=2
  while IFS= read -r -d '' record; do
    if [ -z "$record" ]; then
      IFS= read -r -d '' producer_status || return 1
      complete=1
      break
    fi
    case "$record" in *$'\n'*) ;; *) return 1 ;; esac
    key=${record%%$'\n'*}
    value=${record#*$'\n'}
    case "$key" in
      filter.*.clean | filter.*.smudge | filter.*.process | diff.*.command | merge.*.driver)
        printf '%s\n' "$key"
        ;;
      submodule.*.update)
        case "$value" in !*) printf '%s\n' "$key" ;; esac
        ;;
    esac
  done < <({
    exact_head_git -C "$worktree" config --local --null --get-regexp \
      '^(filter\..*\.(clean|smudge|process)|diff\..*\.command|merge\..*\.driver|submodule\..*\.update)$'
    printf '\0%s\0' "$?"
  })
  [ "$complete" -eq 1 ] || return 1
  case "$producer_status" in 0 | 1) return 0 ;; *) return 1 ;; esac
}

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
        actual=$(exact_head_git -C "$worktree" hash-object --no-filters -- "$worktree/$path" 2>/dev/null) || return 1
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
        actual=$(readlink "$worktree/$path" | dd bs=1 count="$link_size" 2>/dev/null | exact_head_git -C "$worktree" hash-object --stdin) || return 1
        [ "$actual" = "$object" ] || printf 'raw tree mismatch: %s\n' "$path"
        ;;
      160000:commit)
        sub_super=$(exact_head_git -C "$worktree/$path" rev-parse --show-superproject-working-tree 2>/dev/null || true)
        if [ -n "$sub_super" ]; then
          sub_head=$(exact_head_git -C "$worktree/$path" rev-parse --verify --quiet HEAD 2>/dev/null || true)
          [ "$sub_head" = "$object" ] || printf 'raw tree mismatch: %s\n' "$path"
        fi
        ;;
      *) return 1 ;;
    esac
  done < <({ exact_head_git -C "$worktree" ls-tree -r -z --full-tree "$coordinate"; printf '\0%s\0' "$?"; })
  [ "$complete" -eq 1 ] && [ "$producer_status" -eq 0 ]
}

expected_head_worktree_status() { # <worktree> [<immutable-coordinate>]
  local worktree=$1 coordinate=${2:-HEAD}
  local untracked ignored index raw diff_rc record metadata mode type object path sub_super nested
  local complete=0 producer_status=1
  untracked=$(exact_head_git -C "$worktree" ls-files --others --exclude-standard) || return 1
  [ -z "$untracked" ] || printf 'untracked: %s\n' "$untracked"
  ignored=$(exact_head_git -C "$worktree" ls-files --others --ignored --exclude-standard) || return 1
  [ -z "$ignored" ] || printf 'ignored: %s\n' "$ignored"
  index=$(exact_head_git -C "$worktree" -c core.quotePath=true ls-files -v) || return 1
  index=$(printf '%s\n' "$index" | LC_ALL=C grep -E '^[a-zS] ' || true)
  [ -z "$index" ] || printf '%s\n' "$index"
  if exact_head_git -C "$worktree" -c core.fileMode=true diff-index --no-ext-diff --cached --quiet "$coordinate" --; then
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
    sub_super=$(exact_head_git -C "$worktree/$path" rev-parse --show-superproject-working-tree 2>/dev/null || true)
    [ -n "$sub_super" ] || continue
    nested=$(expected_head_worktree_status "$worktree/$path" "$object") || return 1
    [ -z "$nested" ] || printf '%s\n%s\n' "$path" "$nested"
  done < <({ exact_head_git -C "$worktree" ls-tree -z "$coordinate"; printf '\0%s\0' "$?"; })
  [ "$complete" -eq 1 ] && [ "$producer_status" -eq 0 ]
}
