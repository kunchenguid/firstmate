#!/usr/bin/env bash
# The shared secondmate charter contract: the parent-channel paths a charter
# names, the publish-time rendering of a durable charter for one destination,
# and the extraction of the registry summary and scope from it.
# Source only. FM_SECONDMATE_CHARTER and FM_SECONDMATE_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}

# The parent-channel surfaces a secondmate charter names, by route, and the
# single definition of their shape. A local route reads steers from, and
# answers on, the parent home's own state paths. A remote route's surfaces are
# host-local: its steering inbox is the parent-route inbox that home's control
# plane writes (bin/fm-remote-secondmate-control.sh), and its replies go
# through the append-only relay log the parent's reply adapter mirrors
# (bin/fm-parent-channel-lib.sh), so a parent-home absolute path names nothing
# on that host. An empty <remote-home> selects the local route.
SECONDMATE_REMOTE_STATUS_SUFFIX='/state/parent-replies.status'
SECONDMATE_REMOTE_INBOX_DIR='/state/parent-route'

secondmate_channel_status_path() {
  local id=$1 parent_state=$2 remote_home=$3
  if [ -n "$remote_home" ]; then
    printf '%s%s\n' "$remote_home" "$SECONDMATE_REMOTE_STATUS_SUFFIX"
  else
    printf '%s/%s.status\n' "$parent_state" "$id"
  fi
}

secondmate_channel_inbox_path() {
  local id=$1 parent_state=$2 remote_home=$3
  if [ -n "$remote_home" ]; then
    printf '%s%s/%s.inbox\n' "$remote_home" "$SECONDMATE_REMOTE_INBOX_DIR" "$id"
  else
    printf '%s/%s.inbox\n' "$parent_state" "$id"
  fi
}

# The remote home a durable charter already names, or nonzero when it names
# none. bin/fm-brief.sh renders every path shell-quoted and refuses a remote
# home that would need quote escaping, so that home is the absolute prefix of
# the quoted parent-channel token.
secondmate_charter_remote_home() {
  local line prefix
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *"'"*"$SECONDMATE_REMOTE_STATUS_SUFFIX'"*) ;; *) continue ;; esac
    prefix=${line%%"$SECONDMATE_REMOTE_STATUS_SUFFIX'"*}
    prefix=${prefix##*"'"}
    case "$prefix" in /*) printf '%s\n' "$prefix"; return 0 ;; esac
  done < "$1"
  return 1
}

# Publishing is the only owner of the published charter's correctness, for
# every destination: the mate must read steers and answer where its own route
# really is. Teardown retires a route without removing data/<id>/brief.md, so
# the durable charter a seed publishes from can name this parent home or any
# home an earlier seed published to, in either direction; both spellings
# converge on this destination here. Every parent differs from the others by
# suffix, so no rewrite can consume another's text and every mention - bare
# path, /*.msg listing, and handled/ acknowledgement - lands on the
# destination. Each rewrite stays its own plain assignment: on stock macOS bash
# a quoted substitution nested inside a double-quoted argument leaks literal
# quotes into the replacement text.
secondmate_charter_publish() {
  local brief=$1 id=$2 parent_state=$3 remote_home=$4
  local dest_status dest_inbox parent_status parent_inbox
  local prior_home prior_status='' prior_inbox='' line
  dest_status=$(secondmate_channel_status_path "$id" "$parent_state" "$remote_home")
  dest_inbox=$(secondmate_channel_inbox_path "$id" "$parent_state" "$remote_home")
  parent_status=$(secondmate_channel_status_path "$id" "$parent_state" '')
  parent_inbox=$(secondmate_channel_inbox_path "$id" "$parent_state" '')
  if prior_home=$(secondmate_charter_remote_home "$brief") \
    && [ "$prior_home" != "$remote_home" ]; then
    prior_status=$(secondmate_channel_status_path "$id" "$parent_state" "$prior_home")
    prior_inbox=$(secondmate_channel_inbox_path "$id" "$parent_state" "$prior_home")
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//"$parent_status"/"$dest_status"}
    line=${line//"$parent_inbox"/"$dest_inbox"}
    if [ -n "$prior_status" ]; then
      line=${line//"$prior_status"/"$dest_status"}
      line=${line//"$prior_inbox"/"$dest_inbox"}
    fi
    printf '%s\n' "$line"
  done < "$brief"
}
