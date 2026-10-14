#!/usr/bin/env bash
# fm-pr-comment-poll.sh - standing watcher check that wakes firstmate when the
# captain comments on a task's Forgejo pull request, so feedback left on the PR
# reaches the owning crew as steer instructions.
#
# Usage:
#   fm-pr-comment-poll.sh check       scan every armed sidecar and wake on new captain comments
#   fm-pr-comment-poll.sh arm <id>    arm the comment poll for one task's recorded Forgejo PR
#   fm-pr-comment-poll.sh disarm <id> retire one task's comment poll
#   fm-pr-comment-poll.sh --help      print this help
#
# Mechanism: POLLING through the existing watcher check family, a sibling of
# bin/fm-pr-poll.sh's merge poll. A webhook was evaluated and rejected: it would
# need an inbound-reachable endpoint, a shared secret, and per-instance forge
# configuration, while the watcher already runs authenticated checks on a fixed
# FM_CHECK_INTERVAL cadence, and comment feedback does not need sub-minute
# latency. This check runs as one standing custom check, so the watcher's own
# FM_CHECK_TIMEOUT bound (default 30s) bounds every scan.
#
# `arm` records one per-task sidecar state/<id>.pr-comment-poll (identity
# lines, never shell source) from the task's own recorded pr= URL, refuses any
# URL that is not a Forgejo pull request, and resolves the tea login pinned to
# the URL's host exactly as bin/fm-pr-poll.sh does. Arming baselines the seen
# marker at the newest existing comment id, so history never wakes; a re-arm
# for the same PR keeps the recorded marker so no wake is lost, while arming a
# replacement PR re-baselines the marker, because one PR's comment ids say
# nothing about another's. arm
# also writes the one standing shim state/pr-comments.check.sh through the same
# embedded-home contract as fm-mail-check.sh and binds its bytes with
# bin/fm-check-register.sh. bin/fm-pr-check.sh arms this poll for every Forgejo
# PR it records; an arm failure there is a warning, never a refusal of the PR
# recording itself.
#
# `check` scans every sidecar and, per task, reads
# GET /repos/{owner}/{repo}/issues/<number>/comments
# through "tea api" on the host's one registered login, so the credential never
# leaves tea; the endpoint returns the issue's full comment list ascending by
# id. tea api exits 0 on an HTTP error with the error body as output, so only a
# payload that is an array of records carrying a numeric id, a string body,
# and a string user.login is classified. Comment bodies and authors are data:
# they are read only by jq, never interpolated into shell source, and
# only numeric comment ids and the canonical URL ever reach output. A comment
# wakes exactly one line when BOTH hold:
#   - its author login equals the repository owner, the configured captain
#     identity for this forge, and
#   - its body starts with the explicit command prefix "/fm" plus whitespace,
#     e.g. "/fm rework: use a config flag instead".
# Bare captain comments do NOT wake: the prefix is the documented way to say
# "crew, act on this", and without it ordinary review chatter directed at
# humans would spend a firstmate turn per comment. Ignored comments still
# advance the seen marker, so a comment that did not wake never wakes later.
# The marker state/<id>.pr-comment-seen holds the newest comment id observed on
# the last fully parsed read, and is written by rename only after that read
# parsed, so an error leaves it untouched and the missed window is re-read next
# cycle; the sidecar's identity is re-read before any wake or marker write, so
# a PR retargeted by a concurrent arm mid-read leaves both untouched. A sidecar
# whose state/<id>.meta is gone - the task was cleaned up - is retired silently
# with its marker. A printed line becomes one ordinary `check:` wake through
# the watcher's custom-check contract; firstmate steers the named task's
# worker, which reads the comments itself.
#
# `check` stays silent on every error, exactly like bin/fm-pr-poll.sh: a failed
# lookup must never be readable as either a wake or a clean no-wake.
#
# `disarm` removes one task's sidecar and marker, and retires the standing shim
# through bin/fm-check-unregister.sh once no sidecar remains. The standing shim
# deliberately outlives the last sidecar - automatic retirement of a cleaned-up
# task leaves it registered as one silent empty scan, ready for the next
# Forgejo PR - and only `disarm` retires it.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

CHECK_ID=pr-comments
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
SIDE_SUFFIX=.pr-comment-poll
SEEN_SUFFIX=.pr-comment-seen
SIDE_SCHEMA=fm-pr-comment-poll-v1
WAKE_IDS_MAX=5

usage() {
  cat <<'EOF'
Usage:
  fm-pr-comment-poll.sh check       scan every armed sidecar and wake on new captain comments
  fm-pr-comment-poll.sh arm <id>    arm the comment poll for one task's recorded Forgejo PR
  fm-pr-comment-poll.sh disarm <id> retire one task's comment poll
  fm-pr-comment-poll.sh --help      print this help

A comment wakes only when its author is the repository owner (the configured
captain identity) and its body starts with the "/fm " command prefix. See the
script header for the full contract.
EOF
}

fail() {
  printf 'fm-pr-comment-poll: %s\n' "$*" >&2
  exit 1
}

# Reads the sidecar's five identity lines and revalidates every component the
# way bin/fm-pr-poll.sh revalidates its own sidecar: the stored URL must be
# exactly reconstructible from the parsed components, so a doctored sidecar
# cannot point this poll at another host or project. Sets FM_CMP_* on success.
fm_pr_comment_sidecar_parse() {  # <file>
  local file=$1 schema provider url host path number _extra
  FM_CMP_URL=
  FM_CMP_HOST=
  FM_CMP_PATH=
  FM_CMP_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  { exec 8< "$file"; } 2>/dev/null || return 1
  IFS= read -r schema <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$schema" = "$SIDE_SCHEMA" ] || return 1
  [ "$provider" = forgejo ] || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = forgejo ] || return 1
  [ "$FM_PR_HOST" = "$host" ] || return 1
  [ "$FM_PR_PATH" = "$path" ] || return 1
  [ "$FM_PR_NUMBER" = "$number" ] || return 1
  [ "$url" = "https://$host/$path/pulls/$number" ] || return 1
  FM_CMP_URL=$url
  FM_CMP_HOST=$host
  FM_CMP_PATH=$path
  FM_CMP_NUMBER=$number
}

# The comments array for one pull request, or nothing on any failure. The pull
# request number is part of the validated identity, never of the shell source.
fm_pr_comment_fetch() {  # <login> <path> <number>
  tea api --login "$1" --repo "$2" \
    "/repos/{owner}/{repo}/issues/$3/comments" 2>/dev/null
}

# Classifies one fetched comments array. Prints "<max-id> <id[,id...]>" where
# the second field is empty when no new qualifying comment woke, and returns 1
# on any payload that is not an array of records carrying a numeric id, a
# string body and a string user.login - an unreadable comment must never
# advance the marker past itself.
fm_pr_comment_classify() {  # <owner> <seen> <json>
  printf '%s' "$3" | jq -r --arg owner "$1" --argjson seen "$2" '
    if type == "array"
       and all(.[]; (.id | type) == "number"
                  and (.body | type) == "string"
                  and (.user.login | type) == "string")
    then
      ([.[] | select(.user.login == $owner
                     and (.body | test("^/fm[[:space:]]"))) | .id]) as $wake
      | (([.[] | .id] | max) // 0) as $max
      | "\($max) \($wake | map(select(. > $seen)) | sort | join(","))"
    else
      error("invalid comments payload")
    end' 2>/dev/null
}

# The sidecar identity lines, written atomically for one task.
fm_pr_comment_sidecar_write() {  # <id> <url> <host> <path> <number>
  local id=$1 url=$2 host=$3 path=$4 number=$5 dest tmp device
  dest="$STATE/$id$SIDE_SUFFIX"
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-comment-side.XXXXXX") || return 1
  if ! printf '%s\n' "$SIDE_SCHEMA" forgejo "$url" "$host" "$path" "$number" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device" \
    || ! fm_pr_comment_sidecar_parse "$tmp" \
    || [ "$FM_CMP_URL" != "$url" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  fm_pr_private_file_valid "$dest" 600 "$device"
}

# The newest observed comment id, written by rename for one task. A poll's
# observation never lowers an existing marker, so a re-read of an older window
# cannot un-see a comment; the replace mode is the arm path's one re-baseline
# of a replacement PR, swapping the marker in a single rename.
fm_pr_comment_seen_store() {  # <id> <seen> [replace]
  local id=$1 seen=$2 replace=${3:-} dest tmp device
  dest="$STATE/$id$SEEN_SUFFIX"
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" || return 1
  if [ -z "$replace" ] && [ -f "$dest" ] && [ ! -L "$dest" ] \
    && fm_pr_comment_seen_read "$id" >/dev/null \
    && [ "$(fm_pr_comment_seen_read "$id")" -ge "$seen" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-comment-seen.XXXXXX") || return 1
  if ! printf '%s\n' "$seen" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  fm_pr_private_file_valid "$dest" 600 "$device"
}

fm_pr_comment_seen_read() {  # <id>
  local file="$STATE/$1$SEEN_SUFFIX" seen
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r seen < "$file" || return 1
  case "$seen" in
    ''|*[!0-9]*|0[0-9]*) return 1 ;;
  esac
  printf '%s\n' "$seen"
}

# The standing shim, through fm-mail-check.sh's embedded-home contract: the
# watcher runs the shim from its own working directory, so a relative spelling
# would send the check to a different home, or to none at all.
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-pr-comment-poll.sh - Forgejo PR comment poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pr-comment-poll.sh") check"
}

# Write the shim the way this repo writes its other trusted check shim: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
shim_write() {  # <content>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-comment-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f "$tmp" "$CHECK_SHIM"; then
    rm -f "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

action_arm() {  # <task-id>
  local id=$1 meta url login owner line max pr_url pr_host pr_path pr_number
  fm_pr_task_id_valid "$id" || fail "invalid task id: $id"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "task metadata is unavailable for $id"
  url=$(grep '^pr=' "$meta" | tail -1 | cut -d= -f2- || true)
  fm_pr_url_parse "$url" || fail "no valid recorded PR URL for $id"
  [ "$FM_PR_PROVIDER" = forgejo ] \
    || fail "the recorded PR for $id is not a Forgejo pull request"
  login=$(fm_pr_forgejo_login "$FM_PR_HOST") \
    || fail "watching Forgejo PR comments at $FM_PR_HOST requires exactly one 'tea login' registered for that host (see 'tea login list')"
  pr_url=$FM_PR_URL
  pr_host=$FM_PR_HOST
  pr_path=$FM_PR_PATH
  pr_number=$FM_PR_NUMBER
  if [ ! -f "$STATE/$id$SIDE_SUFFIX" ] \
    || ! fm_pr_comment_sidecar_parse "$STATE/$id$SIDE_SUFFIX" \
    || [ "$FM_CMP_URL" != "$pr_url" ]; then
    owner=${pr_path%%/*}
    line=$(fm_pr_comment_classify "$owner" 0 \
      "$(fm_pr_comment_fetch "$login" "$pr_path" "$pr_number")") \
      || fail "could not read the comments of $pr_url to baseline the seen marker"
    max=${line%% *}
    case "$max" in
      ''|*[!0-9]*|0[0-9]*) fail "could not read the comments of $pr_url to baseline the seen marker" ;;
    esac
    fm_pr_comment_seen_store "$id" "$max" replace \
      || fail "could not write the seen marker for $id"
  fi
  fm_pr_comment_sidecar_write "$id" "$pr_url" "$pr_host" "$pr_path" "$pr_number" \
    || fail "could not write the comment-poll sidecar for $id"
  shim_write "$(shim_content)" \
    || fail "could not write the standing check shim"
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null \
    || fail "could not bind the standing check shim to its bytes"
  printf 'armed: state/%s%s\n' "$id" "$SIDE_SUFFIX"
}

action_disarm() {  # <task-id>
  local id=$1 side
  fm_pr_task_id_valid "$id" || fail "invalid task id: $id"
  side="$STATE/$id$SIDE_SUFFIX"
  [ -f "$side" ] && [ ! -L "$side" ] \
    || fail "no comment poll is armed for $id"
  rm -f -- "$side" "$STATE/$id$SEEN_SUFFIX" \
    || fail "could not remove the comment poll of $id"
  for side in "$STATE"/*"$SIDE_SUFFIX"; do
    [ -e "$side" ] || continue
    return 0
  done
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null \
    || fail "could not retire the standing comment check"
  printf 'disarmed: state/%s%s\n' "$id" "$SIDE_SUFFIX"
}

action_check() {
  local side id url host path owner login seen line max wake n shown rest
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
  for side in "$STATE"/*"$SIDE_SUFFIX"; do
    [ -e "$side" ] || continue
    case "$(basename "$side")" in
      *"$SIDE_SUFFIX") ;;
      *) continue ;;
    esac
    id=$(basename "$side" "$SIDE_SUFFIX")
    # A task whose metadata record is gone has been cleaned up: retire its
    # comment poll with it, silently, exactly like the merge poll's retirement.
    if [ ! -f "$STATE/$id.meta" ]; then
      rm -f -- "$side" "$STATE/$id$SEEN_SUFFIX"
      continue
    fi
    fm_pr_comment_sidecar_parse "$side" || continue
    url=$FM_CMP_URL
    host=$FM_CMP_HOST
    path=$FM_CMP_PATH
    owner=${path%%/*}
    seen=$(fm_pr_comment_seen_read "$id") || seen=0
    login=$(fm_pr_forgejo_login "$host") || continue
    line=$(fm_pr_comment_classify "$owner" "$seen" \
      "$(fm_pr_comment_fetch "$login" "$path" "$FM_CMP_NUMBER")") \
      || continue
    max=${line%% *}
    case "$max" in
      ''|*[!0-9]*|0[0-9]*) continue ;;
    esac
    fm_pr_comment_sidecar_parse "$side" || continue
    [ "$FM_CMP_URL" = "$url" ] || continue
    wake=${line#* }
    if [ -n "$wake" ]; then
      n=$(awk -F, '{print NF}' <<EOF
$wake
EOF
)
      shown=$(cut -d, -f1-"$WAKE_IDS_MAX" <<EOF
$wake
EOF
)
      rest=$((n - WAKE_IDS_MAX))
      if [ "$rest" -gt 0 ]; then
        shown="$shown and $rest more"
      fi
      printf 'pr-comment: task %s has new captain comment id(s) %s on %s\n' "$id" "$shown" "$url"
    fi
    fm_pr_comment_seen_store "$id" "$max" || continue
  done
  exit 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  check) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; action_check ;;
  arm|disarm)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    "action_$1" "$2"
    ;;
  *) usage >&2; exit 2 ;;
esac
