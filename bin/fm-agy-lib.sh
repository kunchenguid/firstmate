#!/usr/bin/env bash
# fm-agy-lib.sh - the ONE executable owner of Antigravity CLI per-task wiring.
#
# agy discovers lifecycle hooks from the workspace customization root only:
# `.agents/hooks.json` at the project root (verified, agy 1.1.28: PreInvocation,
# PostInvocation, and Stop handlers placed there fired for a real turn). That
# path may be the PROJECT's own committed file, so install never blindly
# overwrites it: a missing file is created and retired by removal, while an
# existing file is byte-backed-up and merged on our own named key only, then
# restored byte-exact at teardown. `exclude_path` in bin/fm-spawn.sh keeps the
# created file out of git's view; a merged-into tracked file is restored before
# teardown's dirty check, so it never blocks a return or leaks into a commit.
#
# Sourcing: set -u safe; no side effects on source.
FM_AGY_HOOKS_KEY=fm-busy-state

fm_agy_shquote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

fm_agy_hooks_path() {  # <worktree>
  printf '%s/.agents/hooks.json' "$1"
}

fm_agy_hooks_mode_path() {  # <state-dir> <id>
  printf '%s/%s.agy-hooks-mode' "$1" "$2"
}

fm_agy_hooks_backup_path() {  # <state-dir> <id>
  printf '%s/%s.agy-hooks-backup' "$1" "$2"
}

# fm_agy_hooks_install <worktree> <state-dir> <id> <gen> <turnend> <fm-root>
# Writes the firstmate-owned busy-state hook under our named key and records
# how, so remove can retire exactly what install did. Refuses loudly when the
# existing file is not JSON this can merge into.
fm_agy_hooks_install() {
  local wt=$1 state=$2 id=$3 gen=$4 turnend=$5 fm_root=$6
  local hooks mode_path writer pre post stop payload tmp
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] && [ -n "$gen" ] \
    && [ -n "$turnend" ] && [ -n "$fm_root" ] || return 1
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to install Antigravity hooks and was not found on PATH" >&2
    return 1
  }
  hooks=$(fm_agy_hooks_path "$wt")
  mode_path=$(fm_agy_hooks_mode_path "$state" "$id")
  mkdir -p "$(dirname "$hooks")" "$state" 2>/dev/null || return 1
  writer="$(fm_agy_shquote "$fm_root/bin/fm-busy-event.sh") apply $(fm_agy_shquote "$state") $(fm_agy_shquote "$id")"
  suffix="--gen $(fm_agy_shquote "$gen") --source agy-hook"
  pre="$writer busy $suffix --event pre-invocation >/dev/null 2>&1 || true; printf '{}'"
  post="$writer idle $suffix --event post-invocation >/dev/null 2>&1 || true; printf '{}'"
  stop="touch $(fm_agy_shquote "$turnend"); $writer idle $suffix --event stop >/dev/null 2>&1 || true; printf '{}'"
  payload=$(jq -n --arg pre "$pre" --arg post "$post" --arg stop "$stop" \
    '{"fm-busy-state": {"PreInvocation": [{"type": "command", "command": $pre}], "PostInvocation": [{"type": "command", "command": $post}], "Stop": [{"type": "command", "command": $stop}]}}') || return 1
  if [ ! -e "$hooks" ]; then
    tmp="$hooks.tmp.$$"
    printf '%s\n' "$payload" > "$tmp" || return 1
    mv -f "$tmp" "$hooks" || { rm -f "$tmp"; return 1; }
    printf 'created\n' > "$mode_path" || return 1
    return 0
  fi
  [ -f "$hooks" ] || {
    echo "error: $hooks exists and is not a regular file; refusing to merge Antigravity hooks" >&2
    return 1
  }
  jq -e . "$hooks" >/dev/null 2>&1 || {
    echo "error: $hooks is not valid JSON; refusing to merge Antigravity hooks" >&2
    return 1
  }
  cp -p "$hooks" "$(fm_agy_hooks_backup_path "$state" "$id")" || return 1
  tmp="$hooks.tmp.$$"
  # Object `+` replaces only our named key wholesale and preserves every
  # other key untouched; it never deep-merges arrays the way `*` would.
  if ! jq --argjson ours "$payload" '. + $ours' "$hooks" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: could not merge Antigravity hooks into $hooks" >&2
    return 1
  fi
  mv -f "$tmp" "$hooks" || { rm -f "$tmp"; return 1; }
  printf 'merged\n' > "$mode_path" || return 1
  return 0
}

# fm_agy_drop_key: remove only our named key from <hooks> via jq. Best-effort
# fallback when the install record or backup is missing; 0 on success.
fm_agy_drop_key() {  # <hooks>
  local hooks=$1 tmp
  [ -f "$hooks" ] || return 0
  jq -e . "$hooks" >/dev/null 2>&1 || return 1
  tmp="$hooks.tmp.$$"
  jq 'del(.["fm-busy-state"])' "$hooks" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$hooks" || { rm -f "$tmp"; return 1; }
  return 0
}

# fm_agy_hooks_remove <worktree> <state-dir> <id>
# Retires exactly what install did: a created file is removed (or reduced to
# our-key removal when the worker grew other keys), a merged file is restored
# byte-exact from backup. Missing records degrade to our-key removal, never to
# deleting a file this did not create.
fm_agy_hooks_remove() {
  local wt=$1 state=$2 id=$3
  local hooks mode_path backup mode
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  hooks=$(fm_agy_hooks_path "$wt")
  mode_path=$(fm_agy_hooks_mode_path "$state" "$id")
  backup=$(fm_agy_hooks_backup_path "$state" "$id")
  mode=
  [ -f "$mode_path" ] && mode=$(cat "$mode_path" 2>/dev/null || true)
  case "$mode" in
    merged)
      if [ -f "$backup" ]; then
        cat "$backup" > "$hooks" || return 1
      else
        fm_agy_drop_key "$hooks" || return 1
      fi
      ;;
    created)
      if [ -f "$hooks" ] && command -v jq >/dev/null 2>&1 \
        && jq -e 'keys | length == 1 and .[0] == "fm-busy-state"' "$hooks" >/dev/null 2>&1; then
        rm -f "$hooks" || return 1
        rmdir "$(dirname "$hooks")" 2>/dev/null || true
      else
        fm_agy_drop_key "$hooks" || return 1
      fi
      ;;
    *)
      fm_agy_drop_key "$hooks" || return 1
      ;;
  esac
  rm -f "$mode_path" "$backup"
  return 0
}
