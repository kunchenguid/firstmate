#!/usr/bin/env bash
# Shared, read-only record comparison for the two existing re-anchor surfaces:
# bin/fm-session-start.sh and bin/fm-sessionstart-nudge.sh post-compact.
#
# This is an internal renderer, not a third reader or command. It writes no
# state and prints no heading, healthy row, or confirmation when records agree.
# The caller gets one bounded contradiction section or empty stdout.

fm_record_contradiction_positive_int() {  # <value> <fallback>
  case "$1" in
    ''|*[!0-9]*|0) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_record_contradiction_file_mtime() {  # <path>
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

fm_record_contradiction_backlog_rows() {  # <backlog>
  local backlog=$1
  [ -f "$backlog" ] || return 0
  LC_ALL=C awk '
    function section_state(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = section_state($0)
      next
    }
    state != "" && $0 ~ /^[-*][[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]+/ {
      row = $0
      sub(/^[-*][[:space:]]+\[/, "", row)
      checked = substr(row, 1, 1)
      sub(/^[ xX]\][[:space:]]+/, "", row)
      id = row
      sub(/[[:space:]].*$/, "", id)
      complete = (state == "done" || checked ~ /[xX]/) ? "complete" : "active"
      hold_kind = ""
      if ($0 ~ /\(hold-kind:[[:space:]]*[^)]*\)/) {
        hold_kind = $0
        sub(/^.*\(hold-kind:[[:space:]]*/, "", hold_kind)
        sub(/\).*$/, "", hold_kind)
        sub(/^[[:space:]]+/, "", hold_kind)
        sub(/[[:space:]]+$/, "", hold_kind)
      }
      printf "%s\t%s\t%s\t%s\n", id, state, complete, hold_kind
    }
  ' "$backlog"
}

fm_record_contradiction_backlog_state() {  # <rows> <id>
  local rows=$1 id=$2 row_id row_state completion _ complete_found=0
  while IFS=$'\t' read -r row_id row_state completion _; do
    [ "$row_id" = "$id" ] || continue
    if [ "$completion" = active ]; then
      printf 'active'
      return 0
    fi
    complete_found=1
  done <<EOF
$rows
EOF
  if [ "$complete_found" -eq 1 ]; then
    printf 'complete'
    return 0
  fi
  return 1
}

fm_record_contradiction_last_status_verb() {  # <status>
  local line
  line=$(LC_ALL=C awk 'NF { line=$0 } END { print line }' "$1" 2>/dev/null)
  case "$line" in
    *:*) printf '%s' "${line%%:*}" ;;
  esac
}

fm_record_contradiction_default_branch() {  # <worktree>
  local worktree=$1 ref branch
  ref=$(git -C "$worktree" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$worktree" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_record_contradiction_worktree_risk() {  # <worktree>
  local worktree=$1 default dirty_files dirty unlanded
  [ -d "$worktree" ] || { printf 'tracked-dirty=unknown,unlanded=unknown'; return 0; }
  git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'tracked-dirty=unknown,unlanded=unknown'; return 0; }
  dirty_files=$(git -C "$worktree" diff --name-only HEAD 2>/dev/null) \
    || { printf 'tracked-dirty=unknown,unlanded=unknown'; return 0; }
  dirty=$(printf '%s\n' "$dirty_files" | awk 'NF { count++ } END { print count + 0 }')
  default=$(fm_record_contradiction_default_branch "$worktree") \
    || { printf 'tracked-dirty=%s,unlanded=unknown' "$dirty"; return 0; }
  unlanded=$(git -C "$worktree" rev-list --count "$default..HEAD" 2>/dev/null) \
    || { printf 'tracked-dirty=%s,unlanded=unknown' "$dirty"; return 0; }
  printf 'tracked-dirty=%s,unlanded=%s' "$dirty" "$unlanded"
}

fm_record_contradiction_gh_bounded() {  # <seconds> <gh-axi args...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    LC_ALL=C LANG=C GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 timeout "$seconds" gh-axi "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    LC_ALL=C LANG=C GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gtimeout "$seconds" gh-axi "$@"
  elif command -v perl >/dev/null 2>&1; then
    LC_ALL=C LANG=C GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" gh-axi "$@"
  else
    return 124
  fi
}

fm_record_contradiction_pr_state() {  # <url> <timeout-seconds>
  local url=$1 timeout_seconds=$2 owner repo number response body
  command -v gh-axi >/dev/null 2>&1 || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  owner=$FM_PR_OWNER
  repo=$FM_PR_REPO
  number=$FM_PR_NUMBER
  # gh-axi's view surface does not expose state+mergeability as selectable
  # fields. Its authenticated API surface applies the equivalent projection
  # server-side and returns a bounded TOON body that is validated below.
  response=$(fm_record_contradiction_gh_bounded "$timeout_seconds" \
    api "/repos/$owner/$repo/pulls/$number" --jq \
    '[if .merged_at != null then "MERGED" elif .state == "open" then "OPEN" elif .state == "closed" then "CLOSED" else "UNKNOWN" end, if .mergeable_state == "dirty" or .mergeable == false then "CONFLICTING" elif .mergeable == true then "MERGEABLE" else "UNKNOWN" end] | join(":")' \
    2>/dev/null) || return 1
  body=$(printf '%s\n' "$response" | sed -n 's/^  body: "\([A-Z][A-Z]*:[A-Z][A-Z]*\)"$/\1/p')
  case "$body" in
    OPEN:MERGEABLE|OPEN:CONFLICTING|OPEN:UNKNOWN|CLOSED:MERGEABLE|CLOSED:CONFLICTING|CLOSED:UNKNOWN|MERGED:MERGEABLE|MERGED:CONFLICTING|MERGED:UNKNOWN|UNKNOWN:MERGEABLE|UNKNOWN:CONFLICTING|UNKNOWN:UNKNOWN)
      printf '%s\t%s\n' "${body%%:*}" "${body#*:}"
      ;;
    *) return 1 ;;
  esac
}

fm_record_contradictions_init() {  # <data-dir>
  local data=$1 backlog
  FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE=$(fm_record_contradiction_positive_int \
    "${FM_RECORD_CONTRADICTION_LIMIT:-3}" 3)
  FM_RECORD_CONTRADICTION_ORPHAN_DAYS_EFFECTIVE=$(fm_record_contradiction_positive_int \
    "${FM_RECORD_CONTRADICTION_ORPHAN_DAYS:-3}" 3)
  FM_RECORD_CONTRADICTION_PR_LIMIT_EFFECTIVE=$(fm_record_contradiction_positive_int \
    "${FM_RECORD_CONTRADICTION_PR_LIMIT:-8}" 8)
  FM_RECORD_CONTRADICTION_PR_TIMEOUT_EFFECTIVE=$(fm_record_contradiction_positive_int \
    "${FM_RECORD_CONTRADICTION_PR_TIMEOUT:-5}" 5)
  FM_RECORD_CONTRADICTION_PR_BUDGET_EFFECTIVE=$(fm_record_contradiction_positive_int \
    "${FM_RECORD_CONTRADICTION_PR_BUDGET:-15}" 15)
  FM_RECORD_CONTRADICTION_PR_STARTED=$(date +%s)
  FM_RECORD_CONTRADICTION_PR_CHECKED=0
  FM_RECORD_CONTRADICTION_COUNT=0
  FM_RECORD_CONTRADICTION_META_COUNT=0
  FM_RECORD_CONTRADICTION_META_ENTRIES=
  FM_RECORD_CONTRADICTION_COMPLETE_COUNT=0
  FM_RECORD_CONTRADICTION_COMPLETE_ENTRIES=
  FM_RECORD_CONTRADICTION_BACKLOG_COUNT=0
  FM_RECORD_CONTRADICTION_BACKLOG_ENTRIES=
  FM_RECORD_CONTRADICTION_STATUS_COUNT=0
  FM_RECORD_CONTRADICTION_STATUS_ENTRIES=
  FM_RECORD_CONTRADICTION_PR_COUNT=0
  FM_RECORD_CONTRADICTION_PR_ENTRIES=
  FM_RECORD_CONTRADICTION_HOLD_COUNT=0
  FM_RECORD_CONTRADICTION_HOLD_ENTRIES=
  FM_RECORD_CONTRADICTION_ORPHAN_COUNT=0
  FM_RECORD_CONTRADICTION_ORPHAN_ENTRIES=
  backlog="$data/backlog.md"
  FM_RECORD_CONTRADICTION_ROWS=$(fm_record_contradiction_backlog_rows "$backlog")
}

fm_record_contradiction_append() {  # <kind> <entry>
  local kind=$1 entry=$2 separator
  FM_RECORD_CONTRADICTION_COUNT=$((FM_RECORD_CONTRADICTION_COUNT + 1))
  case "$kind" in
    meta)
      FM_RECORD_CONTRADICTION_META_COUNT=$((FM_RECORD_CONTRADICTION_META_COUNT + 1))
      [ "$FM_RECORD_CONTRADICTION_META_COUNT" -le "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ] || return 0
      [ -z "$FM_RECORD_CONTRADICTION_META_ENTRIES" ] && separator= || separator=', '
      FM_RECORD_CONTRADICTION_META_ENTRIES="$FM_RECORD_CONTRADICTION_META_ENTRIES$separator$entry"
      ;;
    complete)
      FM_RECORD_CONTRADICTION_COMPLETE_COUNT=$((FM_RECORD_CONTRADICTION_COMPLETE_COUNT + 1))
      [ "$FM_RECORD_CONTRADICTION_COMPLETE_COUNT" -le "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ] || return 0
      [ -z "$FM_RECORD_CONTRADICTION_COMPLETE_ENTRIES" ] && separator= || separator=', '
      FM_RECORD_CONTRADICTION_COMPLETE_ENTRIES="$FM_RECORD_CONTRADICTION_COMPLETE_ENTRIES$separator$entry"
      ;;
    backlog)
      FM_RECORD_CONTRADICTION_BACKLOG_COUNT=$((FM_RECORD_CONTRADICTION_BACKLOG_COUNT + 1))
      [ "$FM_RECORD_CONTRADICTION_BACKLOG_COUNT" -le "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ] || return 0
      [ -z "$FM_RECORD_CONTRADICTION_BACKLOG_ENTRIES" ] && separator= || separator=', '
      FM_RECORD_CONTRADICTION_BACKLOG_ENTRIES="$FM_RECORD_CONTRADICTION_BACKLOG_ENTRIES$separator$entry"
      ;;
    status)
      FM_RECORD_CONTRADICTION_STATUS_COUNT=$((FM_RECORD_CONTRADICTION_STATUS_COUNT + 1))
      [ "$FM_RECORD_CONTRADICTION_STATUS_COUNT" -le "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ] || return 0
      [ -z "$FM_RECORD_CONTRADICTION_STATUS_ENTRIES" ] && separator= || separator=', '
      FM_RECORD_CONTRADICTION_STATUS_ENTRIES="$FM_RECORD_CONTRADICTION_STATUS_ENTRIES$separator$entry"
      ;;
    pr)
      FM_RECORD_CONTRADICTION_PR_COUNT=$((FM_RECORD_CONTRADICTION_PR_COUNT + 1))
      [ "$FM_RECORD_CONTRADICTION_PR_COUNT" -le "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ] || return 0
      [ -z "$FM_RECORD_CONTRADICTION_PR_ENTRIES" ] && separator= || separator=', '
      FM_RECORD_CONTRADICTION_PR_ENTRIES="$FM_RECORD_CONTRADICTION_PR_ENTRIES$separator$entry"
      ;;
    hold)
      FM_RECORD_CONTRADICTION_HOLD_COUNT=$((FM_RECORD_CONTRADICTION_HOLD_COUNT + 1))
      [ "$FM_RECORD_CONTRADICTION_HOLD_COUNT" -le "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ] || return 0
      [ -z "$FM_RECORD_CONTRADICTION_HOLD_ENTRIES" ] && separator= || separator=', '
      FM_RECORD_CONTRADICTION_HOLD_ENTRIES="$FM_RECORD_CONTRADICTION_HOLD_ENTRIES$separator$entry"
      ;;
    orphan)
      FM_RECORD_CONTRADICTION_ORPHAN_COUNT=$((FM_RECORD_CONTRADICTION_ORPHAN_COUNT + 1))
      [ "$FM_RECORD_CONTRADICTION_ORPHAN_COUNT" -le "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ] || return 0
      [ -z "$FM_RECORD_CONTRADICTION_ORPHAN_ENTRIES" ] && separator= || separator=', '
      FM_RECORD_CONTRADICTION_ORPHAN_ENTRIES="$FM_RECORD_CONTRADICTION_ORPHAN_ENTRIES$separator$entry"
      ;;
  esac
}

fm_record_contradictions_observe_meta() {  # <meta> <id> <endpoint> <state-dir>
  local meta=$1 id=$2 endpoint=$3 state_dir=$4 kind backlog_state status verb pr pr_remaining query_timeout result pr_state mergeable worktree risk
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" != secondmate ]; then
    backlog_state=$(fm_record_contradiction_backlog_state "$FM_RECORD_CONTRADICTION_ROWS" "$id") || backlog_state=absent
    case "$backlog_state" in
      complete) fm_record_contradiction_append complete "$id" ;;
      absent)
        worktree=$(fm_meta_get "$meta" worktree)
        risk=$(fm_record_contradiction_worktree_risk "$worktree")
        fm_record_contradiction_append meta "$id($risk)"
        ;;
    esac
  fi

  status="$state_dir/$id.status"
  verb=
  if [ -f "$status" ]; then
    verb=$(fm_record_contradiction_last_status_verb "$status")
    if { [ "$verb" = working ] && [ "$endpoint" = dead ]; } \
      || { [ "$verb" = 'done' ] && [ "$endpoint" = alive ]; }; then
      fm_record_contradiction_append status "$id(status=$verb,endpoint=$endpoint)"
    fi
  fi

  pr=$(fm_meta_get "$meta" pr)
  [ -n "$pr" ] || return 0
  [ "$FM_RECORD_CONTRADICTION_PR_CHECKED" -lt "$FM_RECORD_CONTRADICTION_PR_LIMIT_EFFECTIVE" ] || return 0
  pr_remaining=$((FM_RECORD_CONTRADICTION_PR_BUDGET_EFFECTIVE - ($(date +%s) - FM_RECORD_CONTRADICTION_PR_STARTED)))
  [ "$pr_remaining" -gt 0 ] || return 0
  query_timeout=$FM_RECORD_CONTRADICTION_PR_TIMEOUT_EFFECTIVE
  [ "$query_timeout" -le "$pr_remaining" ] || query_timeout=$pr_remaining
  FM_RECORD_CONTRADICTION_PR_CHECKED=$((FM_RECORD_CONTRADICTION_PR_CHECKED + 1))
  result=$(fm_record_contradiction_pr_state "$pr" "$query_timeout") || return 0
  IFS=$'\t' read -r pr_state mergeable <<EOF
$result
EOF
  if [ "$pr_state" != OPEN ]; then
    fm_record_contradiction_append pr "$id(state=$pr_state)"
  elif [ "$verb" = 'done' ]; then
    fm_record_contradiction_append pr "$id(status=done,state=OPEN)"
  fi
  if [ "$mergeable" = CONFLICTING ]; then
    fm_record_contradiction_append pr "$id(mergeable=CONFLICTING)"
  fi
}

fm_record_contradictions_observe_backlog() {  # <state-dir>
  local state_dir=$1 row_id row_state completion hold_kind
  while IFS=$'\t' read -r row_id row_state completion hold_kind; do
    [ -n "$row_id" ] || continue
    [ "$completion" = active ] || continue
    if [ "$row_state" = in_flight ] && [ ! -f "$state_dir/$row_id.meta" ]; then
      fm_record_contradiction_append backlog "$row_id(state=in_flight)"
    fi
    if [ "$row_state" = in_flight ] && [ -n "$hold_kind" ]; then
      fm_record_contradiction_append hold "$row_id(hold-kind=$hold_kind)"
    fi
  done <<EOF
$FM_RECORD_CONTRADICTION_ROWS
EOF
}

fm_record_contradictions_observe_orphan() {  # <status> <id>
  local status_file=$1 id=$2 now mtime age_days
  now=$(date +%s)
  mtime=$(fm_record_contradiction_file_mtime "$status_file") || return 0
  [ "$now" -ge "$mtime" ] || return 0
  age_days=$(((now - mtime) / 86400))
  [ "$age_days" -ge "$FM_RECORD_CONTRADICTION_ORPHAN_DAYS_EFFECTIVE" ] || return 0
  fm_record_contradiction_append orphan \
    "$id(age=${age_days}d,threshold=${FM_RECORD_CONTRADICTION_ORPHAN_DAYS_EFFECTIVE}d)"
}

fm_record_contradiction_print_kind() {  # <label> <count> <entries>
  local label=$1 count=$2 entries=$3 omitted
  [ "$count" -gt 0 ] || return 0
  printf -- '- %s (%s): %s' "$label" "$count" "$entries"
  if [ "$count" -gt "$FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE" ]; then
    omitted=$((count - FM_RECORD_CONTRADICTION_LIMIT_EFFECTIVE))
    printf '; +%s more' "$omitted"
  fi
  printf '\n'
}

fm_record_contradictions_format() {
  [ "$FM_RECORD_CONTRADICTION_COUNT" -gt 0 ] || return 0
  printf 'RECORD CONTRADICTIONS\n%s\n' '--------------------------------------------------------------------------------'
  fm_record_contradiction_print_kind meta-without-backlog \
    "$FM_RECORD_CONTRADICTION_META_COUNT" "$FM_RECORD_CONTRADICTION_META_ENTRIES"
  fm_record_contradiction_print_kind complete-but-live-meta \
    "$FM_RECORD_CONTRADICTION_COMPLETE_COUNT" "$FM_RECORD_CONTRADICTION_COMPLETE_ENTRIES"
  fm_record_contradiction_print_kind backlog-without-meta \
    "$FM_RECORD_CONTRADICTION_BACKLOG_COUNT" "$FM_RECORD_CONTRADICTION_BACKLOG_ENTRIES"
  fm_record_contradiction_print_kind status-endpoint \
    "$FM_RECORD_CONTRADICTION_STATUS_COUNT" "$FM_RECORD_CONTRADICTION_STATUS_ENTRIES"
  fm_record_contradiction_print_kind pr-state \
    "$FM_RECORD_CONTRADICTION_PR_COUNT" "$FM_RECORD_CONTRADICTION_PR_ENTRIES"
  fm_record_contradiction_print_kind held-in-flight \
    "$FM_RECORD_CONTRADICTION_HOLD_COUNT" "$FM_RECORD_CONTRADICTION_HOLD_ENTRIES"
  fm_record_contradiction_print_kind stale-orphan-status \
    "$FM_RECORD_CONTRADICTION_ORPHAN_COUNT" "$FM_RECORD_CONTRADICTION_ORPHAN_ENTRIES"
}

fm_record_contradictions_render() {  # <data-dir> <state-dir>
  local data=$1 state_dir=$2 meta id target backend endpoint status_file
  fm_record_contradictions_init "$data"

  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    target=$(fm_backend_target_of_meta "$meta")
    endpoint=unknown
    if [ -n "$target" ]; then
      backend=$(fm_backend_of_meta "$meta")
      if fm_backend_target_exists "$backend" "$target" "fm-$id"; then
        endpoint=alive
      else
        endpoint=dead
      fi
    fi
    fm_record_contradictions_observe_meta "$meta" "$id" "$endpoint" "$state_dir"
  done

  fm_record_contradictions_observe_backlog "$state_dir"
  for status_file in "$state_dir"/*.status; do
    [ -f "$status_file" ] || continue
    id=$(basename "$status_file" .status)
    [ ! -f "$state_dir/$id.meta" ] || continue
    fm_record_contradictions_observe_orphan "$status_file" "$id"
  done
  fm_record_contradictions_format
}
