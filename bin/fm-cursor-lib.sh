#!/usr/bin/env bash
# Shared owner of Firstmate's Cursor user-level turn-end fallback hook contract.
#
# ONE owner for the global-hook lifecycle that fm-spawn.sh (install) and
# fm-teardown.sh (per-task removal plus last-task cleanup) both rely on:
#   - ~/.cursor/hooks/fm-turn-end.sh          the shared fallback hook script
#   - ~/.cursor/hooks/fm-turn-end.d/fm.*      per-task token registry files
#   - ~/.cursor/hooks.json                    one additive Firstmate stop entry
#
# Why a lock: concurrent cursor spawns rewrite the same shared hook script and
# merge the same hooks.json, and a concurrent teardown may decide "no tokens
# remain" and remove both. fm_cursor_hooks_lock serializes
#   spawn:    [create token -> install hook script -> merge hooks.json]
#   teardown: [remove token -> if registry empty, remove script + entry]
# so cleanup can never observe an empty registry between a spawn's token
# creation and its hook install. The lock is a mkdir lockdir with bounded
# retries and mtime-based stale takeover.
#
# Failure posture:
#   - install: the hook script write is atomic (mktemp+chmod+mv in the same
#     directory), so a concurrently stopping Cursor session can never read a
#     truncated hook. A malformed pre-existing hooks.json is never overwritten;
#     install fails loudly instead.
#   - cleanup: every uncertain path (lock timeout, malformed hooks.json,
#     unreadable registry) SKIPS cleanup and leaves the fallback installed.
#     The installed hook is a strict no-op without a registered token, so a
#     skipped cleanup is safe and the next last-task teardown retries it.
#
# The hook itself stays fail-open for Cursor: it validates the workspace token
# pointer against the private registry and exits 0 with an empty hook response
# in every case. Cursor Agent 2026.07.16-899851b does not execute user hooks at
# all for accounts without the server-side hooks rollout (docs/turnend-guard.md),
# so this fallback is forward-compatible signal plumbing, not a load-bearing
# guarantee; the watcher's staleness path owns the degradation.

# Portable mtime in epoch seconds; kept local so this leaf lib stays standalone.
fm_cursor_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_cursor_shell_quote() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# fm_cursor_hooks_lock <hooks_dir>: acquire the serialization lock for the
# shared hook artifacts under <hooks_dir>. Bounded wait (FM_CURSOR_HOOK_LOCK_TRIES
# x 0.1s, default ~5s); a lockdir older than FM_CURSOR_HOOK_LOCK_STALE_SECS
# (default 120) is taken over as abandoned. Returns 1 on timeout.
fm_cursor_hooks_lock() {
  local hooks_dir=$1 lockdir tries=${FM_CURSOR_HOOK_LOCK_TRIES:-50} i=0 age now mtime
  lockdir="$hooks_dir/.fm-turn-end.lock"
  mkdir -p "$hooks_dir" 2>/dev/null || return 1
  while :; do
    if mkdir "$lockdir" 2>/dev/null; then
      return 0
    fi
    mtime=$(fm_cursor_path_mtime "$lockdir")
    now=$(date +%s)
    if [ -n "$mtime" ] && [ -n "$now" ]; then
      age=$((now - mtime))
      if [ "$age" -gt "${FM_CURSOR_HOOK_LOCK_STALE_SECS:-120}" ]; then
        rmdir "$lockdir" 2>/dev/null || true
        continue
      fi
    fi
    i=$((i + 1))
    [ "$i" -lt "$tries" ] || return 1
    sleep 0.1
  done
}

fm_cursor_hooks_unlock() {
  rmdir "$1/.fm-turn-end.lock" 2>/dev/null || true
}

# fm_cursor_write_turnend_hook <hooks_dir> <auth_dir>: atomically write the
# shared fallback hook script. The script no-ops unless a workspace root
# carries a .fm-cursor-turnend pointer naming a live token in <auth_dir>.
fm_cursor_write_turnend_hook() {
  local hooks_dir=$1 auth_dir=$2 sq_auth_dir tmp
  sq_auth_dir=$(fm_cursor_shell_quote "$auth_dir")
  tmp=$(mktemp "$hooks_dir/fm-turn-end.sh.tmp.XXXXXXXXXXXX") || return 1
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_auth_dir
payload=\$(cat 2>/dev/null || true)
if [ -n "\$payload" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "\$payload" | jq -r '.workspace_roots[]? | select(type == "string")' 2>/dev/null |
  while IFS= read -r workspace; do
    p="\$workspace/.fm-cursor-turnend"
    [ -f "\$p" ] && [ ! -L "\$p" ] || continue
    first=
    IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || continue
    case "\$first" in token=*) token=\${first#token=} ;; *) continue ;; esac
    case "\$token" in fm.????????????) : ;; *) continue ;; esac
    case "\$token" in *[!A-Za-z0-9._-]*) continue ;; esac
    t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || continue
    case "\$t" in /*.turn-ended) : ;; *) continue ;; esac
    touch "\$t" 2>/dev/null || true
  done
fi
printf '%s\n' '{}'
exit 0
EOF
  chmod +x "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$hooks_dir/fm-turn-end.sh" || { rm -f "$tmp"; return 1; }
}

# fm_cursor_hooks_json_mergeable <hooks_file>: the existing file (when present)
# must be an object whose .hooks is an object and whose .hooks.stop is an array.
fm_cursor_hooks_json_mergeable() {
  jq -e 'type == "object" and ((.hooks? // {}) | type == "object") and ((.hooks?.stop? // []) | type == "array")' "$1" >/dev/null 2>&1
}

# fm_cursor_merge_stop_entry <cursor_home> <hook_command>: additively register
# the fallback stop hook in <cursor_home>/hooks.json (idempotent, atomic write).
# Refuses a malformed existing file instead of overwriting it.
fm_cursor_merge_stop_entry() {
  local cursor_home=$1 hook_command=$2 hooks_file tmp source
  hooks_file="$cursor_home/hooks.json"
  if [ -L "$hooks_file" ]; then
    echo "error: refusing to rewrite symlinked Cursor hooks file: $hooks_file" >&2
    return 1
  fi
  tmp=$(mktemp "$cursor_home/hooks.json.tmp.XXXXXXXXXXXX") || return 1
  if [ -f "$hooks_file" ]; then
    if ! fm_cursor_hooks_json_mergeable "$hooks_file"; then
      rm -f "$tmp"
      echo "error: existing Cursor hooks file is not mergeable: $hooks_file" >&2
      return 1
    fi
    source="$hooks_file"
  else
    printf '%s\n' '{}' > "$tmp.source"
    source="$tmp.source"
  fi
  if ! jq --arg command "$hook_command" '
    .version = (.version // 1)
    | .hooks = (.hooks // {})
    | .hooks.stop = ((.hooks.stop // []) as $hooks
        | if any($hooks[]?; .command? == $command) then $hooks
          else $hooks + [{"command": $command, "timeout": 5, "failClosed": false}]
          end)
  ' "$source" > "$tmp"; then
    rm -f "$tmp" "$tmp.source"
    echo "error: failed to merge Firstmate's Cursor stop hook into $hooks_file" >&2
    return 1
  fi
  mv -f "$tmp" "$hooks_file" || { rm -f "$tmp" "$tmp.source"; return 1; }
  rm -f "$tmp.source"
}

# fm_cursor_registry_empty <auth_dir>: true when no fm.* token files remain.
fm_cursor_registry_empty() {
  local auth_dir=$1 f
  [ -d "$auth_dir" ] || return 0
  for f in "$auth_dir"/fm.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    return 1
  done
  return 0
}

# fm_cursor_remove_stop_entry <cursor_home> <hook_command>: remove only
# Firstmate's own stop entry from hooks.json, preserving every other entry and
# leaving a malformed or missing file untouched (atomic write).
fm_cursor_remove_stop_entry() {
  local cursor_home=$1 hook_command=$2 hooks_file tmp
  hooks_file="$cursor_home/hooks.json"
  [ ! -L "$hooks_file" ] || return 1
  [ -f "$hooks_file" ] || return 0
  fm_cursor_hooks_json_mergeable "$hooks_file" || return 0
  tmp=$(mktemp "$cursor_home/hooks.json.tmp.XXXXXXXXXXXX") || return 1
  if ! jq --arg command "$hook_command" '
    if (.hooks?.stop? // null) == null then .
    else
      .hooks.stop = [.hooks.stop[] | select(.command? != $command)]
      | if .hooks.stop == [] then .hooks |= del(.stop) else . end
    end
  ' "$hooks_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$hooks_file" || { rm -f "$tmp"; return 1; }
}

# fm_cursor_remove_turnend_auth <state_dir> <id>: teardown entry point. Removes
# the task's token from the registry, then - when that was the last token -
# deterministically removes the shared hook script, Firstmate's hooks.json stop
# entry, and the empty registry directory. Uncertainty always skips cleanup.
fm_cursor_remove_turnend_auth() {
  local state_dir=$1 id=$2 token cursor_home hooks_dir auth_dir hook_command
  token=$(cat "$state_dir/$id.cursor-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  cursor_home="$HOME/.cursor"
  hooks_dir="$cursor_home/hooks"
  auth_dir="$hooks_dir/fm-turn-end.d"
  if ! fm_cursor_hooks_lock "$hooks_dir"; then
    # Another spawn or teardown owns the artifacts right now; remove only our
    # token and leave the shared hook installed (a strict no-op without tokens).
    rm -f "$auth_dir/$token"
    return 0
  fi
  rm -f "$auth_dir/$token"
  if fm_cursor_registry_empty "$auth_dir"; then
    # The registered hooks.json command is the shell-quoted script path
    # (exactly what fm-spawn merged), so match that same form here.
    hook_command=$(fm_cursor_shell_quote "$hooks_dir/fm-turn-end.sh")
    if fm_cursor_remove_stop_entry "$cursor_home" "$hook_command"; then
      rm -f "$hooks_dir/fm-turn-end.sh"
      rmdir "$auth_dir" 2>/dev/null || true
    fi
  fi
  fm_cursor_hooks_unlock "$hooks_dir"
}
