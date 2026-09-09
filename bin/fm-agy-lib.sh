#!/usr/bin/env bash
# fm-agy-lib.sh - the ONE executable owner of Antigravity CLI per-task wiring.
#
# agy discovers lifecycle hooks from `.agents/hooks.json` at the workspace root.
# Tracked hooks are refused because Git excludes cannot protect tracked content.
# Existing untracked hooks are backed up and merged under the adapter-owned key.
# Removal restores that key while preserving changes to other project keys.
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
  local hooks mode_path writer pre post stop payload tmp suffix
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] && [ -n "$gen" ] \
    && [ -n "$turnend" ] && [ -n "$fm_root" ] || return 1
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to install Antigravity hooks and was not found on PATH" >&2
    return 1
  }
  hooks=$(fm_agy_hooks_path "$wt")
  mode_path=$(fm_agy_hooks_mode_path "$state" "$id")
  if git -C "$wt" ls-files --error-unmatch -- .agents/hooks.json >/dev/null 2>&1; then
    echo "error: tracked .agents/hooks.json cannot safely carry generated Antigravity hooks" >&2
    return 1
  fi
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
# cleanup for a created file that acquired project keys; 0 on success.
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
fm_agy_hooks_remove() {
  local wt=$1 state=$2 id=$3
  local hooks mode_path backup mode tmp
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  hooks=$(fm_agy_hooks_path "$wt")
  mode_path=$(fm_agy_hooks_mode_path "$state" "$id")
  backup=$(fm_agy_hooks_backup_path "$state" "$id")
  mode=
  [ -f "$mode_path" ] && mode=$(cat "$mode_path" 2>/dev/null || true)
  case "$mode" in
    merged)
      [ -f "$backup" ] || return 1
      if [ -f "$hooks" ]; then
        tmp="$hooks.tmp.$$"
        jq --slurpfile original "$backup" '
          del(.["fm-busy-state"]) +
          ($original[0] | with_entries(select(.key == "fm-busy-state")))
        ' "$hooks" > "$tmp" || { rm -f "$tmp"; return 1; }
        if [ "$(jq -S . "$tmp")" = "$(jq -S . "$backup")" ]; then
          cp -p "$backup" "$tmp" || { rm -f "$tmp"; return 1; }
        fi
        mv -f "$tmp" "$hooks" || { rm -f "$tmp"; return 1; }
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
      return 0
      ;;
  esac
  rm -f "$mode_path" "$backup"
  return 0
}
