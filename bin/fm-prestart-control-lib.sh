#!/usr/bin/env bash
# Narrow non-agent recovery for fm-control.sh cancel-prestart.
# This never adopts an endpoint or creates task metadata.
# A label is only a contradiction check, never an endpoint selector.
# The operator must identify the particular failed start from its original
# evidence and compare the fresh snapshot before supplying --if-match.
# The fingerprint is a freshness condition, not permission or ownership.
# Ordinary agent controls retain their existing metadata requirement.
#
# Caller owns the task lease, control lock, and this library's project lock.
# Only an ordinary primary clone under the current home's projects directory,
# a held queued task, the actual local coordinator, and a plain Treehouse/Git
# fetch job in its own single-pane tab can qualify. Unknown states refuse.

fm_prestart_roots_valid() {
  local config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  PRESTART_HOME=$(cd "$FM_HOME" && pwd -P) || return 1
  [ "$(cd "$STATE" && pwd -P)" = "$PRESTART_HOME/state" ] &&
    [ "$(cd "$DATA" && pwd -P)" = "$PRESTART_HOME/data" ] &&
    [ "$(cd "$config" && pwd -P)" = "$PRESTART_HOME/config" ]
}

fm_prestart_prepare() {  # Called in the parent shell, not a substitution.
  local row row_id repo kind state held actor cwd info shell cursor parent n common
  [ ! -e "$META" ] && [ ! -L "$META" ] || return 1
  [ "$(fm_backend_name)" = herdr ] || return 1
  fm_backend_source herdr || return 1
  [ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_PANE_ID:-}" ] || return 1
  PRESTART_SESSION=$(fm_backend_herdr_session) || return 1
  fm_backend_herdr_target_observable "$PRESTART_SESSION:$PRESTART_PANE" || return 1
  fm_backend_herdr_launcher_identity "$PRESTART_SESSION" || return 1
  PRESTART_WORKSPACE=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID
  PRESTART_ACTOR_TAB=$FM_BACKEND_HERDR_LAUNCHER_TAB_ID
  [ "$PRESTART_PANE" != "$HERDR_PANE_ID" ] || return 1
  actor=$(fm_backend_herdr_cli "$PRESTART_SESSION" pane get "$HERDR_PANE_ID") || return 1
  cwd=$(printf '%s' "$actor" | jq -er '.result.pane.foreground_cwd | select(type == "string" and length > 0)') || return 1
  [ "$(cd "$cwd" && pwd -P)" = "$PRESTART_HOME" ] || return 1
  info=$(fm_backend_herdr_cli "$PRESTART_SESSION" pane process-info --pane "$HERDR_PANE_ID") || return 1
  shell=$(printf '%s' "$info" | jq -er --arg pane "$HERDR_PANE_ID" '
    .result.process_info | select(.pane_id == $pane)
    | .shell_pid | select(type == "number" and . > 1 and floor == .)') || return 1
  # The injected pane must be this process's real ancestor, not a borrowed id.
  cursor=$$
  n=0
  while [ "$cursor" != "$shell" ] && [ "$cursor" -gt 1 ] && [ "$n" -lt 64 ]; do
    parent=$(ps -p "$cursor" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
    case "$parent" in ''|*[!0-9]*) return 1 ;; esac
    [ "$parent" != "$cursor" ] || return 1
    cursor=$parent
    n=$((n + 1))
  done
  [ "$cursor" = "$shell" ] || return 1
  PRESTART_ACTOR_SHELL=$shell

  row=$(fm_backlog_row_show "$DATA" "$ID") || return 1
  row_id=$(printf '%s\n' "$row" | sed -n 's/^  id: //p')
  [ "$row_id" = "$ID" ] || return 1
  repo=$(printf '%s\n' "$row" | sed -n 's/^  repo: //p')
  kind=$(printf '%s\n' "$row" | sed -n 's/^  kind: //p')
  state=$(printf '%s\n' "$row" | sed -n 's/^  state: //p')
  held=$(printf '%s\n' "$row" | sed -n 's/^  held: //p')
  [ "$state" = queued ] && [ "$held" = yes ] || return 1
  case "$kind" in ship|scout) ;; *) return 1 ;; esac
  case "$repo" in ''|*[!a-zA-Z0-9._-]*|.*) return 1 ;; esac
  PRESTART_PROJECT=$(cd "$PRESTART_HOME/projects/$repo" && pwd -P) || return 1
  [ "$PRESTART_PROJECT" = "$PRESTART_HOME/projects/$repo" ] &&
    [ -d "$PRESTART_PROJECT/.git" ] && [ ! -L "$PRESTART_PROJECT/.git" ] || return 1
  [ "$(git -C "$PRESTART_PROJECT" rev-parse --show-toplevel)" = "$PRESTART_PROJECT" ] || return 1
  common=$(git -C "$PRESTART_PROJECT" rev-parse --git-common-dir) || return 1
  common=$(cd "$PRESTART_PROJECT" && cd "$common" && pwd -P) || return 1
  [ "$common" = "$PRESTART_PROJECT/.git" ] || return 1
  PRESTART_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PRESTART_PROJECT") || return 1
  # A still-running native producer holds this same mutex. Do not race it or
  # cancel a start that is still being supervised by fm-spawn.
  fm_lock_try_acquire "$PRESTART_PROJECT_LOCK" || return 1
  PRESTART_PROJECT_LOCK_HELD=1
  PRESTART_HEAD=$(git -C "$PRESTART_PROJECT" rev-parse HEAD) || return 1
}

fm_prestart_snapshot() {
  local pane tab tabs info checked origin shell root fetch group pids pid row
  local parent pgid uid started dirty os='[]'
  [ ! -e "$META" ] && [ ! -L "$META" ] || return 1
  dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$PRESTART_PROJECT" -c core.fsmonitor=false status --porcelain=v1) || return 1
  [ -z "$dirty" ] && [ "$(git -C "$PRESTART_PROJECT" rev-parse HEAD)" = "$PRESTART_HEAD" ] || return 1
  pane=$(fm_backend_herdr_cli "$PRESTART_SESSION" pane get "$PRESTART_PANE") || return 1
  tab=$(printf '%s' "$pane" | jq -er --arg pane "$PRESTART_PANE" --arg ws "$PRESTART_WORKSPACE" --arg project "$PRESTART_PROJECT" '
    .result.pane | select(.pane_id == $pane and .workspace_id == $ws and .foreground_cwd == $project)
    | .tab_id | select(type == "string" and length > 0)') || return 1
  [ "$tab" != "$PRESTART_ACTOR_TAB" ] || return 1
  tabs=$(fm_backend_herdr_cli "$PRESTART_SESSION" tab list --workspace "$PRESTART_WORKSPACE") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" --arg ws "$PRESTART_WORKSPACE" --arg label "fm-$ID" '
    [.result.tabs[] | select(.label == $label)] as $matches
    | ($matches | length) == 1 and $matches[0].tab_id == $tab
    and $matches[0].workspace_id == $ws and $matches[0].pane_count == 1
  ' >/dev/null 2>&1 || return 1
  [ "$(fm_backend_herdr_pane_agent_state "$PRESTART_SESSION" "$PRESTART_PANE")" = no-agent ] || return 1
  info=$(fm_backend_herdr_cli "$PRESTART_SESSION" pane process-info --pane "$PRESTART_PANE") || return 1
  origin=$(git -C "$PRESTART_PROJECT" remote get-url origin) || return 1
  case "$origin" in https://*) ;; *) return 1 ;; esac
  case "${origin#*://}" in *@*|*\?*|*\#*|*[[:space:]]*) return 1 ;; esac
  # URL and process argv remain on stdin, never in another process's argv or
  # the returned snapshot. Only the exact known prefetch command shapes qualify.
  checked=$(printf '%s\n%s' "$origin" "$info" | jq -Rsec --arg pane "$PRESTART_PANE" --arg project "$PRESTART_PROJECT" '
    split("\n") as $lines | $lines[0] as $origin
    | ($lines[1:] | join("\n") | fromjson).result.process_info
    | def base: split("/") | last;
      def tree: .name == "treehouse" and (.argv | length) == 2 and (.argv[0] | base) == "treehouse" and .argv[1] == "get";
      def fetch: .name == "git" and (.argv | length) == 3 and (.argv[0] | base) == "git" and .argv[1:] == ["fetch", "origin"];
      def remote:
        (.name == "git" and (.argv | length) == 4 and (.argv[0] | base) == "git"
          and .argv[1] == "remote-https" and .argv[2:] == ["origin", $origin])
        or ((.name == "git-remote-http" or .name == "git-remote-https") and (.argv | length) == 3
          and ((.argv[0] | base) == "git-remote-http" or (.argv[0] | base) == "git-remote-https") and .argv[1:] == ["origin", $origin]);
      select(.pane_id == $pane and (.shell_pid | type) == "number" and .shell_pid > 1)
    | select((.foreground_processes | type) == "array" and (.foreground_processes | length) >= 2)
    | select(all(.foreground_processes[]; (.argv | type) == "array" and .cwd == $project
        and (.pid | type) == "number" and .pid > 1 and (.pid | floor) == .pid and (tree or fetch or remote)))
    | select(([.foreground_processes[] | select(tree)] | length) == 1 and ([.foreground_processes[] | select(fetch)] | length) == 1)
    | select(([.foreground_processes[].pid] | unique | length) == (.foreground_processes | length))
    | {shell: .shell_pid, group: .foreground_process_group_id,
       root: (.foreground_processes[] | select(tree) | .pid), fetch: (.foreground_processes[] | select(fetch) | .pid),
       processes: [.foreground_processes[] | {pid, name}] | sort_by(.pid)}
  ' 2>/dev/null) || return 1
  shell=$(printf '%s' "$checked" | jq -er .shell) || return 1
  root=$(printf '%s' "$checked" | jq -er .root) || return 1
  fetch=$(printf '%s' "$checked" | jq -er .fetch) || return 1
  group=$(printf '%s' "$checked" | jq -er .group) || return 1
  [ "$shell" != "$PRESTART_ACTOR_SHELL" ] && [ "$group" = "$root" ] || return 1
  pids=$(printf '%s' "$checked" | jq -r '.processes[].pid') || return 1
  while IFS= read -r pid; do
    row=$(LC_ALL=C ps -p "$pid" -o ppid=,pgid=,uid=,lstart= 2>/dev/null) || return 1
    IFS=$' \t' read -r parent pgid uid started <<< "$row"
    case "$parent:$pgid:$uid" in *[!0-9:]*) return 1 ;; esac
    [ -n "$started" ] && [ "$uid" = "$(id -u)" ] && [ "$pgid" = "$group" ] || return 1
    if [ "$pid" = "$root" ]; then
      [ "$parent" = "$shell" ] || return 1
    elif [ "$pid" = "$fetch" ]; then
      [ "$parent" = "$root" ] || return 1
    else
      case $'\n'"$pids"$'\n' in *$'\n'"$parent"$'\n'*) ;; *) return 1 ;; esac
    fi
    os=$(printf '%s' "$os" | jq -c --argjson pid "$pid" --argjson parent "$parent" --argjson group "$pgid" --arg started "$started" \
      '. + [{pid: $pid, parent: $parent, group: $group, started: $started}]') || return 1
  done <<< "$pids"
  jq -cnS --arg id "$ID" --arg home "$PRESTART_HOME" --arg project "$PRESTART_PROJECT" --arg head "$PRESTART_HEAD" \
    --arg session "$PRESTART_SESSION" --arg workspace "$PRESTART_WORKSPACE" --arg pane "$PRESTART_PANE" --arg tab "$tab" \
    --argjson actor_shell "$PRESTART_ACTOR_SHELL" --argjson shell "$shell" --argjson root "$root" --argjson processes "$os" \
    '{task: $id, home: $home, project: $project, head: $head, session: $session, workspace: $workspace,
      pane: $pane, tab: $tab, actor_shell: $actor_shell, shell: $shell, treehouse: $root, processes: $processes}'
}

fm_prestart_stopped() {  # <snapshot>
  local snapshot=$1 pid started now info expected_shell dirty pane tab
  [ ! -e "$META" ] && [ ! -L "$META" ] || return 1
  [ "$(fm_backend_herdr_pane_process_state "$PRESTART_SESSION" "$PRESTART_PANE")" = shell ] || return 1
  expected_shell=$(printf '%s' "$snapshot" | jq -er .shell) || return 1
  info=$(fm_backend_herdr_cli "$PRESTART_SESSION" pane process-info --pane "$PRESTART_PANE") || return 1
  [ "$(printf '%s' "$info" | jq -er .result.process_info.shell_pid)" = "$expected_shell" ] || return 1
  pane=$(fm_backend_herdr_cli "$PRESTART_SESSION" pane get "$PRESTART_PANE") || return 1
  tab=$(printf '%s' "$snapshot" | jq -er .tab) || return 1
  printf '%s' "$pane" | jq -e --arg pane "$PRESTART_PANE" --arg tab "$tab" --arg ws "$PRESTART_WORKSPACE" --arg project "$PRESTART_PROJECT" '
    .result.pane | .pane_id == $pane and .tab_id == $tab and .workspace_id == $ws and .foreground_cwd == $project
  ' >/dev/null 2>&1 || return 1
  [ "$(git -C "$PRESTART_PROJECT" rev-parse HEAD)" = "$PRESTART_HEAD" ] || return 1
  dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$PRESTART_PROJECT" -c core.fsmonitor=false status --porcelain=v1) || return 1
  [ -z "$dirty" ] || return 1
  while IFS=$'\t' read -r pid started; do
    now=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//') || true
    [ "$now" != "$started" ] || return 1
  done < <(printf '%s' "$snapshot" | jq -r '.processes[] | [.pid, .started] | @tsv')
}

fm_prestart_control() {  # <expected-fingerprint-or-empty>
  local expected=$1 snapshot fingerprint elapsed=0
  snapshot=$(fm_prestart_snapshot) || return 1
  fingerprint=$(printf '%s' "$snapshot" | git hash-object --stdin) || return 1
  if [ -z "$expected" ]; then
    printf '%s' "$snapshot" | jq --arg proof "$fingerprint" '. + {proof: $proof, input_sent: false}'
    return 0
  fi
  [ "$expected" = "$fingerprint" ] || {
    echo 'error: prestart identity changed; no input sent' >&2
    return 1
  }
  fm_backend_herdr_send_key_observable "$PRESTART_SESSION:$PRESTART_PANE" C-c || return 1
  while :; do
    if fm_prestart_stopped "$snapshot"; then
      printf 'prestart stopped: %s; endpoint preserved; project unchanged\n' "$ID"
      return 0
    fi
    awk -v e="$elapsed" -v t="$EXIT_WAIT" 'BEGIN {exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN {printf "%.3f", e + p}')
  done
  echo 'error: prestart cancellation was delivered but the stop could not be verified; no further input sent' >&2
  return 1
}
