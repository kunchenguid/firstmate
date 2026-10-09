#!/usr/bin/env bash
# Evaluate deterministic stuck-board signals for this home's ship and scout tasks.
# Usage: fm-stuck-board.sh scan
#   Prints one `stuck: <task-id> <rule>` line per newly breached rule episode.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

fail() { printf 'stuck-board-error: %s\n' "$*"; printf 'fm-stuck-board: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; }

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then usage; exit 0; fi
[ "${1:-}" = scan ] && [ "$#" -eq 1 ] || fail 'usage: fm-stuck-board.sh scan'
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0

HEARTBEAT_SECS=${FM_STUCK_HEARTBEAT_SECS:-900}
PROGRESS_SECS=${FM_STUCK_PROGRESS_SECS:-3600}
COMMAND_SECS=${FM_STUCK_COMMAND_SECS:-2700}
DRAFT_PR_SECS=${FM_STUCK_DRAFT_PR_SECS:-14400}
REVIEW_SECS=${FM_STUCK_REVIEW_SECS:-7200}
FAILURE_REPEATS=${FM_STUCK_FAILURE_REPEATS:-2}
READY_PR_SECS=${FM_STUCK_READY_PR_SECS:-86400}

config_read() {
  local key value line
  if [ ! -e "$CONFIG/stuck-board" ] && [ ! -L "$CONFIG/stuck-board" ]; then return 0; fi
  [ -f "$CONFIG/stuck-board" ] && [ ! -L "$CONFIG/stuck-board" ] \
    && [ -r "$CONFIG/stuck-board" ] || fail 'config/stuck-board must be a readable regular file'
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; *=*) key=${line%%=*}; value=${line#*=} ;; *) fail "invalid config/stuck-board line" ;; esac
    case "$key" in
      heartbeat_seconds) HEARTBEAT_SECS=$value ;;
      progress_seconds) PROGRESS_SECS=$value ;;
      command_seconds) COMMAND_SECS=$value ;;
      draft_pr_seconds) DRAFT_PR_SECS=$value ;;
      review_seconds) REVIEW_SECS=$value ;;
      failure_repeats) FAILURE_REPEATS=$value ;;
      ready_pr_seconds) READY_PR_SECS=$value ;;
      *) fail "unknown config/stuck-board key: $key" ;;
    esac
  done < "$CONFIG/stuck-board"
}

config_read
for value in "$HEARTBEAT_SECS" "$PROGRESS_SECS" "$COMMAND_SECS" "$DRAFT_PR_SECS" \
  "$REVIEW_SECS" "$FAILURE_REPEATS" "$READY_PR_SECS"; do
  case "$value" in ''|*[!0-9]*|0) fail 'stuck-board thresholds must be positive whole numbers' ;; esac
done

now=$(date +%s)
stat_mtime() {
  if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1" 2>/dev/null
  else stat -c %Y "$1" 2>/dev/null
  fi
}
task_start() {
  local id=$1 meta=$2 file value
  file="$STATE/$id.started"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    IFS= read -r value < "$file" || value=
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s' "$value"; return ;; esac
  fi
  stat_mtime "$meta"
}
breach() {
  local id=$1 rule=$2 marker="$STATE/.stuck-$1-$2"
  [ -e "$marker" ] && return 0
  (umask 077; set -C; printf '%s\n' "$now" > "$marker") 2>/dev/null || return 0
  printf 'stuck: %s %s\n' "$id" "$rule"
}
clear_rule() { rm -f -- "$STATE/.stuck-$1-$2"; }
elapsed() { [ "$now" -ge "$1" ] && printf '%s' "$((now - $1))" || printf '0'; }

last_status_progress() {
  local file=$1 stamp
  [ -f "$file" ] || { printf '0'; return; }
  stamp=$(stat_mtime "$file") || stamp=0
  printf '%s' "${stamp:-0}"
}

failure_repeats() {
  local file=$1 count
  [ -f "$file" ] || return 1
  count=$(awk -v threshold="$FAILURE_REPEATS" '
    { latest = $0 }
    /^failed:/ {
      failures[$0]++
    }
    END {
      if (latest ~ /^failed:/ && failures[latest] >= threshold) print 1
      else print 0
    }
  ' "$file") || return 1
  [ "$count" -eq 1 ]
}

since_for_head() {  # <task-id> <rule> <head-oid>
  local id=$1 rule=$2 head=$3 marker="$STATE/.stuck-$1-$2-since" old_head old_ts tmp
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    IFS=$'\t' read -r old_head old_ts < "$marker" || old_head=
    if [ "$old_head" = "$head" ]; then
      case "$old_ts" in ''|*[!0-9]*) ;; *) printf '%s' "$old_ts"; return 0 ;; esac
    fi
  fi
  umask 077
  tmp=$(mktemp "$STATE/.$1.$2-since.XXXXXX") || return 1
  if printf '%s\t%s\n' "$head" "$now" > "$tmp" && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$marker"; then :; else rm -f -- "$tmp"; return 1; fi
  printf '%s' "$now"
}

command_age() {
  local meta=$1 backend target pid table found
  backend=$(fm_backend_of_meta "$meta")
  [ "$backend" = tmux ] || return 1
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  table=$(ps -axo pid=,ppid=,etime=,comm= 2>/dev/null) || return 1
  found=$(printf '%s\n' "$table" | awk -v root="$pid" '
    NF >= 4 { parent[$1] = $2; elapsed[$1] = $3; command[$1] = $4 }
    END {
      for (process in parent) {
        if (process == root || command[process] ~ /(claude|codex)$/) continue
        current = parent[process]
        depth = 0
        while (current != root && current > 1 && current in parent && depth < 32) {
          current = parent[current]
          depth++
        }
        if (current != root) continue
        value = elapsed[process]
        days = 0
        if (value ~ /-/) { split(value, dayparts, "-"); days = dayparts[1] + 0; value = dayparts[2] }
        parts = split(value, clock, ":")
        if (parts == 2) seconds = clock[1] * 60 + clock[2]
        else if (parts == 3) seconds = clock[1] * 3600 + clock[2] * 60 + clock[3]
        else continue
        seconds += days * 86400
        if (seconds > max) max = seconds
      }
      print max + 0
    }
  ') || return 1
  [ "$found" -gt 0 ] || return 1
  printf '%s' "$found"
}

pr_snapshot() {
  local url=$1 result
  result=$(gh pr view "$url" --json state,isDraft,reviewDecision,mergeStateStatus,headRefOid 2>/dev/null) || return 1
  printf '%s' "$result"
}

discover_pr() {  # <worktree>
  local worktree=$1 branch remote repo url
  command -v gh >/dev/null 2>&1 || return 1
  branch=$(git -C "$worktree" branch --show-current 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  remote=$(git -C "$worktree" remote get-url origin 2>/dev/null) || return 1
  case "$remote" in
    git@github.com:*) repo=${remote#git@github.com:} ;;
    ssh://git@github.com/*) repo=${remote#ssh://git@github.com/} ;;
    https://github.com/*) repo=${remote#https://github.com/} ;;
    *) return 1 ;;
  esac
  repo=${repo%.git}
  case "$repo" in */*) ;; *) return 1 ;; esac
  url=$(gh pr list --repo "$repo" --head "$branch" --state open --json url --jq '.[0].url // empty' 2>/dev/null) || return 1
  [ -n "$url" ] && printf '%s' "$url"
}

scan_task() {
  local id=$1 meta=$2 kind start hb hb_ts status_ts commit_ts progress_ts age pr url pr_json pr_state pr_draft pr_decision merge_state pr_head head_ts review_since ready_since branch pushed_head pushed_ts cmd_age worktree
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in ship|scout) ;; *) return 0 ;; esac
  start=$(task_start "$id" "$meta") || start=$now

  hb="$STATE/$id.heartbeat"
  hb_ts=0
  if [ -f "$hb" ] && [ ! -L "$hb" ]; then
    IFS=$'\t' read -r hb_ts _ < "$hb" || hb_ts=0
    case "$hb_ts" in ''|*[!0-9]*) hb_ts=0 ;; esac
  fi
  if [ "$hb_ts" -eq 0 ]; then hb_ts=$start; fi
  age=$(elapsed "$hb_ts")
  if [ "$age" -gt "$HEARTBEAT_SECS" ]; then breach "$id" heartbeat; else clear_rule "$id" heartbeat; fi

  status_ts=$(last_status_progress "$STATE/$id.status")
  commit_ts=0
  worktree=$(fm_meta_get "$meta" worktree)
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    commit_ts=$(git -C "$worktree" log -1 --format=%ct 2>/dev/null || echo 0)
    branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)
    if [ -n "$branch" ]; then
      pushed_head=$(git -C "$worktree" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR == 1 {print $1}')
      case "$pushed_head" in
        *[!0-9a-f]*|'') ;;
      *) pushed_ts=$(since_for_head "$id" push "$pushed_head" || echo 0); [ "$pushed_ts" -le "$commit_ts" ] || commit_ts=$pushed_ts ;;
      esac
    fi
  fi
  progress_ts=$status_ts
  [ "$commit_ts" -le "$progress_ts" ] || progress_ts=$commit_ts
  url=$(fm_meta_get "$meta" pr)
  if [ -z "$url" ] && [ -n "$worktree" ] && [ -d "$worktree" ]; then
    url=$(discover_pr "$worktree" || true)
  fi
  pr_json=
  if [ -n "$url" ]; then pr_json=$(pr_snapshot "$url" || true); fi
  pr_state=$(printf '%s' "$pr_json" | jq -r '.state // empty' 2>/dev/null || true)
  pr_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // empty' 2>/dev/null || true)
  pr_decision=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // empty' 2>/dev/null || true)
  merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // empty' 2>/dev/null || true)
  pr_head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null || true)
  if [ -n "$pr_head" ]; then
    head_ts=$(since_for_head "$id" progress "$pr_head" || echo 0)
    [ "$head_ts" -le "$progress_ts" ] || progress_ts=$head_ts
  fi
  [ "$progress_ts" -gt 0 ] || progress_ts=$start
  age=$(elapsed "$progress_ts")
  if [ "$age" -gt "$PROGRESS_SECS" ]; then breach "$id" no-progress; else clear_rule "$id" no-progress; fi

  cmd_age=$(command_age "$meta" 2>/dev/null || echo 0)
  if [ "$cmd_age" -gt "$COMMAND_SECS" ]; then breach "$id" long-command; else clear_rule "$id" long-command; fi

  if [ "$kind" = ship ]; then
    if { [ -z "$url" ] || { [ -n "$pr_json" ] && [ "$pr_state" != OPEN ]; }; } \
      && [ "$(elapsed "$start")" -gt "$DRAFT_PR_SECS" ]; then
      breach "$id" missing-draft-pr
    else
      clear_rule "$id" missing-draft-pr
    fi
  else
    clear_rule "$id" missing-draft-pr
  fi

  if [ -n "$url" ] && [ -z "$pr_json" ]; then
    : # A failed forge read cannot close a previously observed review episode.
  elif [ "$pr_state" = OPEN ] && [ "$pr_draft" = false ]; then
    if [ "$pr_decision" = REVIEW_REQUIRED ]; then
      review_since=$(since_for_head "$id" review "$pr_head")
      if [ "$(elapsed "$review_since")" -gt "$REVIEW_SECS" ]; then
        breach "$id" review-wait
      else
        clear_rule "$id" review-wait
      fi
    else
      clear_rule "$id" review-wait
      rm -f -- "$STATE/.stuck-$id-review-since"
    fi
    if [ "$merge_state" = CLEAN ] && [ "$pr_decision" = APPROVED ]; then
      ready_since=$(since_for_head "$id" ready "$pr_head")
      if [ "$(elapsed "$ready_since")" -gt "$READY_PR_SECS" ]; then
        breach "$id" ready-pr-wait
      else
        clear_rule "$id" ready-pr-wait
      fi
    else
      clear_rule "$id" ready-pr-wait
      rm -f -- "$STATE/.stuck-$id-ready-since"
    fi
  else
    clear_rule "$id" review-wait
    clear_rule "$id" ready-pr-wait
    rm -f -- "$STATE/.stuck-$id-review-since" "$STATE/.stuck-$id-ready-since"
  fi

  if failure_repeats "$STATE/$id.status"; then breach "$id" repeated-failure; else clear_rule "$id" repeated-failure; fi
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  fm_task_id_creation_valid "$id" || continue
  scan_task "$id" "$meta"
done
