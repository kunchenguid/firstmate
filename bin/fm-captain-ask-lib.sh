#!/usr/bin/env bash
# Shared fork guard for captain asks; callers supply tasks_axi, SCRIPT_DIR, and fail.
captain_ask_row() {  # <id>; sets CAPTAIN_ASK_SHOW to the row's show output when it is a [captain-ask] item
  local title
  CAPTAIN_ASK_SHOW=''
  [ -n "$1" ] || return 0
  CAPTAIN_ASK_SHOW=$(tasks_axi show "$1" --full 2>/dev/null) \
    || fail "cannot read $1 to check whether it is a [captain-ask] item; it stays in the backlog until the read succeeds"
  title=$(printf '%s\n' "$CAPTAIN_ASK_SHOW" | sed -n 's/^  title: //p' | head -1)
  case "$title" in
    '') fail "cannot read the title of $1 to check whether it is a [captain-ask] item; it stays in the backlog" ;;
    *'[captain-ask]'*) ;;
    *) CAPTAIN_ASK_SHOW='' ;;
  esac
}

guard_captain_ask() {  # <id>
  local pr
  captain_ask_row "$1"
  [ -n "$CAPTAIN_ASK_SHOW" ] || return 0
  "$SCRIPT_DIR/fm-captain-hold.sh" answered "$1" && return 0
  for pr in $(printf '%s\n' "$CAPTAIN_ASK_SHOW" | sed -n 's/^  links: //p' | grep -o 'pr:[^" ,]*' | sed 's/^pr://'); do
    [ "$(gh pr view "$pr" --json state -q .state 2>/dev/null)" = MERGED ] && return 0
  done
  fail "$1 is a [captain-ask] item with no recorded captain answer (bin/fm-captain-hold.sh answer) and no merged PR (tasks-axi update --pr); it cannot leave the backlog"
}

# A raw hold would revive an old answer's record; the sanctioned hold starts a new hold set.
guard_captain_ask_hold() {  # <id>
  captain_ask_row "$1"
  [ -z "$CAPTAIN_ASK_SHOW" ] || fail "$1 is a [captain-ask] item; hold it with bin/fm-captain-hold.sh hold so the new hold is recorded"
}

captain_ask_done_keep() {  # <root>
  local toml value
  for toml in "$1/.tasks.toml" "${HOME:-}/.tasks-axi/config.toml"; do
    value=$(LC_ALL=C awk '{ l = $0; sub(/#.*/, "", l); gsub(/^[ \t\r]+|[ \t\r]+$/, "", l) } l ~ /^\[.*\]$/ { s = substr(l, 2, length(l) - 2); gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); md = (s == "markdown") } md && l ~ /^done_keep[ \t]*=/ { v = l; sub(/^done_keep[ \t]*=[ \t]*/, "", v); k = v } END { print k }' "$toml" 2>/dev/null)
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$value"; return 0 ;; esac
  done
  printf '%s\n' 10
}

# Inspects only the rows tasks-axi archives: those past keep; a call target not yet in <state> pushes one row further.
guard_captain_ask_archive() {  # <state> <keep-or-empty> <call-target-or-empty>
  local listing ids id count backlog root backend keep ahead=0 skip
  backlog=$(fm_backlog_data_absolute "$DATA") || fail "cannot resolve backlog data before pruning"
  root=$(fm_backlog_root "$backlog") || fail "$FM_BACKLOG_TRANSITION_ERROR"
  backend=$(fm_tasks_axi_backend "$root") || fail "cannot read backlog backend before pruning"
  [ "$backend" = markdown ] || return 0
  listing=$(tasks_axi list --state "$1") || fail "cannot read $1 tasks before pruning"
  count=$(printf '%s\n' "$listing" | sed -n 's/^count: //p')
  ids=$(printf '%s\n' "$listing" | sed -nE 's/^  ([A-Za-z0-9._-]+),.*/\1/p')
  [ "$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')" = "$count" ] \
    || fail "cannot read every $1 task before pruning"
  if [ -n "$3" ] && ! printf '%s\n' "$ids" | grep -qxF -- "$3"; then ahead=1; fi
  keep=${2:-$(captain_ask_done_keep "$root")}
  skip=$(( keep - ahead ))
  [ "$skip" -ge 0 ] || skip=0
  for id in $(printf '%s\n' "$ids" | tail -n +"$(( skip + 1 ))"); do guard_captain_ask "$id"; done
}
