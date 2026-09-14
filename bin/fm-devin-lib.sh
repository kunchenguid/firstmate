#!/usr/bin/env bash
# Devin crewmate/scout launch mechanics, verified on Devin 3000.10.21 and
# Herdr 0.9.0. No primary/secondmate or non-Herdr launch is verified.
# fm_devin_preflight validates the executable, permission mode, auth and model
# before endpoint allocation. fm_devin_start types a direct pane launch with a
# file-backed initial prompt, then verifies Herdr's native pane identity.
# Native agent start has an intermittent name-binding race; it is not used.
# --permission-mode defaults to dangerous for unattended workers; auto,
# accept-edits and smart are explicit opt-ins that can require human approval.
# Effort is selected by a catalog model id, never a guessed effort flag.
# Workspace trust is skipped per launch because each worker has a fresh path;
# neither the user's config nor their trust store is edited.

fm_devin_resolve_binary() {
  local binary dir
  binary=$(command -v devin 2>/dev/null || true)
  [ -n "$binary" ] || binary="${HOME:-}/.local/bin/devin"
  [ -x "$binary" ] && [ -f "$binary" ] || {
    echo "error: devin executable not found on PATH or at ~/.local/bin/devin" >&2
    return 1
  }
  dir=$(cd "$(dirname "$binary")" && pwd -P) || return 1
  # Preserve the stable launcher symlink rather than pinning a release target.
  printf '%s/%s\n' "$dir" "$(basename "$binary")"
}

fm_devin_permission_valid() {
  case "$1" in auto|accept-edits|smart|dangerous) return 0 ;; esac
  return 1
}

fm_devin_preflight() { # <binary> <model> <permission-mode>
  local binary=$1 model=$2 mode=$3 help catalog flag
  fm_devin_permission_valid "$mode" || {
    echo "error: Devin --permission-mode must be auto, accept-edits, smart, or dangerous" >&2
    return 1
  }
  help=$("$binary" --help 2>&1) || return 1
  for flag in --prompt-file --respect-workspace-trust --permission-mode --model; do
    if ! printf '%s\n' "$help" | grep -Fq -- "$flag"; then
      echo "error: Devin launch capability $flag is missing; re-verify the installed version" >&2
      return 1
    fi
  done
  if ! "$binary" auth status >/dev/null 2>&1; then
    echo "error: Devin authentication is unavailable; run devin auth status and resolve login before spawning" >&2
    return 1
  fi
  [ -n "$model" ] && [ "$model" != default ] || return 0
  catalog=$("$binary" models list --format json) || {
    echo "error: Devin model catalog unavailable; refusing an unverified model" >&2
    return 1
  }
  if ! printf '%s' "$catalog" | jq -e --arg model "$model" '
    [.families[] | .family_uid, .slug, .aliases[]?, .variants[].model_uid]
    | index($model) != null
  ' >/dev/null 2>&1; then
    echo "error: Devin model is not available in devin models list --format json: $model" >&2
    return 1
  fi
}

fm_devin_shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

fm_devin_start() { # <target> <binary> <prompt-file> <model> <permission-mode>
  local target=$1 binary=$2 brief=$3 model=$4 mode=$5 session pane out arg attempt
  local launch='env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS'
  local args=("$binary" --respect-workspace-trust false --permission-mode "$mode" --prompt-file "$brief")
  fm_devin_permission_valid "$mode" || return 1
  fm_backend_herdr_parse_target "$target" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  [ -n "$model" ] && [ "$model" != default ] && args+=(--model "$model")
  # Devin retains PI_CODING_AGENT from its parent. Clear foreign markers in
  # the agent's environment without modifying the pane shell or global config.
  for arg in "${args[@]}"; do launch+=" $(fm_devin_shell_quote "$arg")"; done
  fm_backend_herdr_send_literal "$target" "$launch" || return 1
  sleep 0.3
  fm_backend_herdr_send_key "$target" Enter || return 1
  # Query the exact pane, never a named-agent alias. Direct launches do not
  # publish interactive_ready (that field belongs to native agent start).
  # This proves identity only; processing requires the execution receipt.
  for ((attempt=0; attempt<60; attempt++)); do
    out=$(fm_backend_herdr_cli "$session" agent get "$pane" 2>/dev/null) || out=
    if printf '%s' "$out" | jq -e --arg pane "$pane" '
      .result.agent | .agent == "devin" and .pane_id == $pane
    ' >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "error: Devin pane identity is unconfirmed; inspect the recorded pane before any retry" >&2
  return 1
}
