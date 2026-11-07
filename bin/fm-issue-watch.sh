#!/usr/bin/env bash
# fm-issue-watch.sh - recurring GitHub issue poll as a standing watcher check.
#
# Usage:
#   fm-issue-watch.sh check
#   fm-issue-watch.sh arm   <repo> <issue-number> <worker-target>
#   fm-issue-watch.sh disarm
#   fm-issue-watch.sh status
#   fm-issue-watch.sh --help
#
# A per-node watch on ONE GitHub issue: the swarm-runbook pattern where each
# fleet node works an assigned issue and must react to new activity on it.
# The watch itself is dumb and zero-token: it polls the issue's comments and
# state, and only when something substantively changed does it print one or
# more lines, which the watcher turns into `check:` wakes for firstmate to
# decide on (steer the assigned worker with bin/fm-send.sh, file a defect,
# hold, or note it). The watch never steers, posts, or mutates anything.
#
# `arm <repo> <issue-number> <worker-target>` writes state/issue-watch.check.sh
# (a byte-static identity shim for this script's `check` mode), binds its
# bytes with fm-check-register.sh, and records the assignment in
# state/issue-watch.conf. `worker-target` is the exact task id or label the
# assigned worker is reachable at (fm-send.sh resolves it; the watch only
# stores it for firstmate's wake-time use, it never sends anything).
#
# Assignment ownership: each node has its own FM_HOME, so
# state/issue-watch.conf is inherently per-node. The swarm-runbook charter's
# node matrix names the owning node per issue; arming an issue whose matrix
# row names another node is a runbook violation, not something this script
# can police.
#
# `check` (run by the watcher on the FM_CHECK_INTERVAL cadence):
# - Reads state/issue-watch.conf. Missing or malformed config prints one
#   line and stays a wake until fixed (misconfiguration is news, not
#   silence).
# - Fetches the issue and its comments via `gh api` newer than the cursor
#   (the created_at timestamp of the newest already-seen comment).
# - News = new comments (excluding the local gh login and any logins in
#   ISSUE_WATCH_IGNORE_LOGINS), a changed issue body, or a state change
#   (open/closed). Label churn is not news.
# - Prints one line per news item, capped at ISSUE_WATCH_MAX_LINES (default
#   3, valid 1..10); overflow is summarized in one extra line. Firstmate
#   reads the issue itself on wake; the line only has to earn the wake.
# - Advances the cursor after every successful poll, news or not:
#   durability is the watcher wake queue's job (a printed line is queued
#   until firstmate drains it), so the cursor only has to bound what the
#   NEXT poll reports. On any failure (gh error, timeout) prints one line
#   and leaves the cursor untouched: fail-closed. Silence is only a proven
#   no-op.
# - Must finish inside the watcher's per-check bound (FM_CHECK_TIMEOUT,
#   default 30); a poll that cannot finish prints its timeout line rather
#   than staying silent.
#
# Debounce economics: each handled wake is an LLM turn, so news is
# comment/state/body changes only - label churn, the watched node's own
# comments, and already-cursored comments never wake anyone.
#
# `disarm` removes the shim, the trust binding, the assignment record, and
# the cursor. `status` prints the current assignment and cursor.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONF="$STATE/issue-watch.conf"
CURSOR="$STATE/.issue-watch"
SHIM="$STATE/issue-watch.check.sh"
MAX_LINES_DEFAULT=3

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

require_state() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
}

require_gh() { command -v gh >/dev/null 2>&1 || die "gh is not on PATH"; }

fm_issue_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else return 1; fi
}

# --- check mode ------------------------------------------------------------

check_one() {
  require_state
  require_gh
  [ -f "$CONF" ] || { printf 'issue-watch: no assignment (state/issue-watch.conf missing); arm or disarm the watch\n'; return 0; }
  local repo number worker
  repo=$(awk 'NR==1{print $1}' "$CONF")
  number=$(awk 'NR==1{print $2}' "$CONF")
  worker=$(awk 'NR==1{print $3}' "$CONF")
  [ -n "$repo" ] && [ -n "$number" ] || { printf 'issue-watch: malformed assignment (state/issue-watch.conf line 1 needs "<repo> <number> <worker-target>")\n'; return 0; }

  local max_lines=${ISSUE_WATCH_MAX_LINES:-$MAX_LINES_DEFAULT}
  case "$max_lines" in (*[!0-9]*|''|0) max_lines=$MAX_LINES_DEFAULT;; esac
  [ "$max_lines" -le 10 ] || max_lines=10

  local budget=${ISSUE_WATCH_BUDGET:-20}
  case "$budget" in (*[!0-9]*|''|0) budget=20;; esac

  local json
  json=$(timeout "$budget" gh api "repos/$repo/issues/$number" --jq . 2>/dev/null) || {
    printf 'issue-watch: poll failed (gh api repos/%s/issues/%s within %ss); cursor not advanced\n' "$repo" "$number" "$budget"
    return 0
  }

  local body state body_hash
  body=$(printf '%s' "$json" | jq -r '.body // ""')
  state=$(printf '%s' "$json" | jq -r '.state // ""')
  body_hash=$(printf '%s' "$body" | fm_issue_hash)

  local since max_id
  max_id=$(awk 'NR==1{print $1}' "$CURSOR" 2>/dev/null)
  case "$max_id" in (*[!0-9]*|'') max_id=0;; esac
  since=$(sed -n '2p' "$CURSOR" 2>/dev/null)
  [ -n "$since" ] || since=1970-01-01T00:00:00Z

  local me ignore
  me=$(timeout "$budget" gh api user --jq .login 2>/dev/null) || me=""
  ignore=",$me,"
  [ -n "${ISSUE_WATCH_IGNORE_LOGINS:-}" ] && ignore="$ignore$(printf '%s' "$ISSUE_WATCH_IGNORE_LOGINS" | tr -d ' '),"

  local comments lines=() out newest_id=$max_id newest_ts="$since" cid
  comments=$(timeout "$budget" gh api "repos/$repo/issues/$number/comments?since=$since&per_page=100" 2>/dev/null) || comments='[]'
  while IFS=$'\t' read -r cid created login cbody; do
    [ -n "$cid" ] || continue
    [ "$cid" -gt "$newest_id" ] && newest_id=$cid
    [ "$created" \> "$newest_ts" ] && newest_ts="$created"
    case ",$login," in (*"$ignore"*) ;; (*)
      out=$(printf '%s' "$cbody" | jq -r . 2>/dev/null | head -c 200 | tr '\n\t' '  ')
      lines+=("comment by $login: $out")
    ;; esac
  done < <(printf '%s' "$comments" | jq -r '.[] | [.id, .created_at, .user.login, (.body | @json)] | @tsv' 2>/dev/null)

  local prev_body prev_state
  prev_body=$(sed -n '3p' "$CURSOR" 2>/dev/null)
  prev_state=$(sed -n '4p' "$CURSOR" 2>/dev/null)
  [ -n "$prev_body" ] && [ "$body_hash" != "$prev_body" ] && lines+=("issue body changed")
  [ -n "$prev_state" ] && [ "$state" != "$prev_state" ] && lines+=("issue state -> $state")

  printf '%s\n%s\n%s\n%s\n' "$newest_id" "$newest_ts" "$body_hash" "$state" > "$CURSOR" 2>/dev/null \
    || printf 'issue-watch: could not advance cursor for %s#%s\n' "$repo" "$number"
  if [ "${#lines[@]}" -eq 0 ]; then
    return 0
  fi

  local n=${#lines[@]} i
  if [ "$n" -le "$max_lines" ]; then
    for i in "${lines[@]}"; do printf 'issue-watch %s#%s (worker %s): %s\n' "$repo" "$number" "$worker" "$i"; done
  else
    for ((i=0; i<max_lines; i++)); do printf 'issue-watch %s#%s (worker %s): %s\n' "$repo" "$number" "$worker" "${lines[$i]}"; done
    printf 'issue-watch %s#%s (worker %s): +%d more news items; read the issue\n' "$repo" "$number" "$worker" $((n - max_lines))
  fi
}

# --- arm / disarm / status -------------------------------------------------

arm() {
  require_state
  [ "$#" -eq 3 ] || die "usage: fm-issue-watch.sh arm <repo> <issue-number> <worker-target>"
  local repo=$1 number=$2 worker=$3
  case "$number" in (*[!0-9]*|'') die "issue number must be numeric";; esac
  printf '%s %s %s\n' "$repo" "$number" "$worker" > "$CONF" || die "cannot write $CONF"
  chmod 0600 "$CONF" 2>/dev/null
  cat > "$SHIM" <<EOF || { rm -f -- "$CONF"; die "cannot write $SHIM"; }
#!/usr/bin/env bash
# Byte-static identity shim for bin/fm-issue-watch.sh check (swarm issue watch).
exec "$FM_ROOT/bin/fm-issue-watch.sh" check
EOF
  chmod 700 "$SHIM"
  "$SCRIPT_DIR/fm-check-register.sh" issue-watch || { rm -f -- "$SHIM" "$CONF"; die "registration refused; shim and assignment removed"; }
  printf 'armed: %s#%s -> worker %s\n' "$repo" "$number" "$worker"
}

disarm() {
  require_state
  rm -f -- "$SHIM" "$CONF" "$CURSOR" "$STATE/issue-watch.check-trust"
  printf 'disarmed\n'
}

status() {
  if [ -f "$CONF" ]; then
    printf 'watching: %s\n' "$(cat "$CONF")"
  else
    printf 'not armed\n'
  fi
  if [ -f "$CURSOR" ]; then
    printf 'cursor: %s\n' "$(tr '\n' ' ' < "$CURSOR")"
  else
    printf 'cursor: none yet\n'
  fi
}

case "${1:-}" in
  check) shift; check_one "$@" ;;
  arm) shift; arm "$@" ;;
  disarm) shift; disarm "$@" ;;
  status) shift; status "$@" ;;
  --help|-h|'') usage ;;
  *) die "unknown mode: $1 (see --help)" ;;
esac
