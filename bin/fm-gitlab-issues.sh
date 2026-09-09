#!/usr/bin/env bash
# fm-gitlab-issues.sh - notice GitLab issues a human has handed to firstmate by
# label, and wake firstmate once per new (issue, label) pair.
#
# Usage:
#   fm-gitlab-issues.sh [check]
#   fm-gitlab-issues.sh arm
#   fm-gitlab-issues.sh disarm
#   fm-gitlab-issues.sh pending
#   fm-gitlab-issues.sh handled <path_with_namespace>#<iid>
#   fm-gitlab-issues.sh --help
#
# `check` prints exactly one line when firstmate should wake and nothing at all
# otherwise, so it composes with the watcher's existing state-check contract
# (bin/fm-watch.sh sweeps state/*.check.sh every FM_CHECK_INTERVAL and turns one
# printed line into a `check:` wake). `arm` writes state/gitlab-issues.check.sh
# and binds its bytes with fm-check-register.sh; `disarm` retires the shim and its
# trust binding through fm-check-unregister.sh and removes the private records
# below. No conversational turn ever runs the poll itself: the watcher does.
#
# Configuration is config/gitlab-issues.json, local and gitignored, home-local,
# and never inherited into a secondmate home. docs/configuration.md "GitLab issue
# intake" owns the schema; this header owns the mechanics. `arm` refuses when the
# config is absent or malformed, `check` with no config prints nothing and exits
# 0, and `check` with a malformed config reports the offending field through the
# poll-error line below so a broken config wakes firstmate instead of going quiet.
#
# One sweep queries the configured group once per intake label:
#
#   glab api --hostname <host> --method GET --paginate --output ndjson \
#     "groups/<url-encoded group>/issues?state=opened&scope=all&labels=<url-encoded label>&per_page=100"
#
# The host comes from the config, never from the current directory's git remote,
# because the watcher runs this check from its own working directory. The group
# endpoint already covers every project in the group and its subgroups, so the
# optional `projects` list only narrows the result, matched on each issue's
# project path taken from the API's canonical references.full (falling back to
# its web_url, which reads a relative URL root as part of the path).
#
# Private records, all under state/ and all removed by `disarm`:
#
#   .gitlab-issues-seen     one line per reported pair: <path>#<iid>\t<label>\t<epoch>.
#                           A pair is news when it is not in this record. A pair
#                           is dropped the moment the issue stops carrying that
#                           label (or is closed), so a label removed and later put
#                           back is reported again. The record is rewritten only
#                           after a sweep that reached GitLab for every label, so a
#                           failed poll never drops pairs and re-reports them later.
#   .gitlab-issues-pending  JSON lines, one per reported pair, appended by `check`
#                           and holding the issue details firstmate reads instead
#                           of calling GitLab in a conversational turn:
#                           {"issue","project","iid","label","title","state",
#                            "web_url","labels","author","created_at","updated_at",
#                            "description","seen_epoch"}. `pending` prints the
#                           file; `handled <path>#<iid>` removes every entry for
#                           that issue and refuses when there is none.
#   .gitlab-issues-error    the last poll-error line and when it was printed.
#
# Every writer of the pending record runs under state/.gitlab-issues.lock, the
# repo's portable lock from fm-wake-lib.sh (a dead holder is reclaimed, a live one
# is waited for): `check` appends the pending lines and then writes the seen
# record while holding it, and `handled` re-reads the pending record under it
# before rewriting, so an append can never be lost to a concurrent rewrite. A
# `check` that cannot take the lock before its sweep deadline reports that as a
# poll error and leaves the seen record alone, so the new pairs are reported by
# the next poll instead of being marked seen without their details. `handled`
# waits at most one FM_CHECK_TIMEOUT for the lock, longer than any sweep holds it.
# `disarm` removes the lock and its owner directory too, because a holder killed
# mid-sweep leaves both behind and a retired check has nothing left to reclaim
# them.
#
# The report line is `gitlab-issue <n> new: <path>#<iid>(<label>) ...`, listing
# the first MAX_LISTED pairs and counting the rest, capped to MAX_LINE characters.
# A glab or jq failure, a malformed config, or a sweep that ran out of time prints
# `gitlab-issue poll error: <reason>` at most once per FM_GITLAB_ISSUES_ERROR_SECS
# (default 3600) for the same reason; a different reason is news and is printed
# immediately. That is what keeps a broken token to one wake instead of one per
# sweep. A sweep that fails leaves the seen record untouched.
#
# Every network call is bounded. FM_GITLAB_ISSUES_CALL_SECS (default 10, valid
# 1..30) bounds one glab call, and the whole sweep must end inside the watcher's
# FM_CHECK_TIMEOUT (default 30, read from this check's own environment because the
# watcher runs it as a direct child): each call is also cut to the time left
# before that deadline, and a sweep that cannot fit another call reports that as
# a poll error rather than being killed silently by the watcher.
# FM_GITLAB_ISSUES_NOW overrides the epoch written to the records so a test can
# drive the error cadence; the sweep deadline always uses real time.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/gitlab-issues.json"
CHECK_ID=gitlab-issues
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
SEEN="$STATE/.gitlab-issues-seen"
PENDING="$STATE/.gitlab-issues-pending"
ERROR_MARK="$STATE/.gitlab-issues-error"
PENDING_LOCK="$STATE/.gitlab-issues.lock"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
DEFAULT_LABELS='["fm::todo","fm::human-replied"]'
MAX_LISTED=5
MAX_LINE=400

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-gitlab-issues.sh [check]              report new intake-labelled issues (silent when nothing is new)
  fm-gitlab-issues.sh arm                  write and register state/gitlab-issues.check.sh
  fm-gitlab-issues.sh disarm               retire the check shim, its trust binding, and the private records
  fm-gitlab-issues.sh pending              print the pending issue details as JSON lines
  fm-gitlab-issues.sh handled <path>#<iid>  remove that issue's pending entries
  fm-gitlab-issues.sh --help               print this help

The GitLab host, group, projects, and intake labels are read from
config/gitlab-issues.json (local, gitignored, not inherited).
See docs/configuration.md "GitLab issue intake" for the schema.
EOF
}

die_usage() {
  printf 'fm-gitlab-issues: %s\n' "$1" >&2
  usage >&2
  exit 2
}

CALL_SECS=${FM_GITLAB_ISSUES_CALL_SECS:-10}
case "$CALL_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-gitlab-issues: FM_GITLAB_ISSUES_CALL_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$CALL_SECS" -gt 30 ]; then
  printf 'fm-gitlab-issues: FM_GITLAB_ISSUES_CALL_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

ERROR_SECS=${FM_GITLAB_ISSUES_ERROR_SECS:-3600}
case "$ERROR_SECS" in
  ''|*[!0-9]*)
    printf 'fm-gitlab-issues: FM_GITLAB_ISSUES_ERROR_SECS must be a whole number of seconds\n' >&2
    exit 2
    ;;
esac

# The watcher's per check bound, read from this check's own environment. The last
# call may end a second past its own bound and its kill grace, so the sweep
# deadline sits that far inside the watcher's.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
DEADLINE_MARGIN_SECS=3
SWEEP_SECS=$((CHECK_TIMEOUT - DEADLINE_MARGIN_SECS))
[ "$SWEEP_SECS" -ge 1 ] || SWEEP_SECS=1

# --- small helpers ----------------------------------------------------------

record_epoch_now() {
  case "${FM_GITLAB_ISSUES_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_GITLAB_ISSUES_NOW" ;;
  esac
}

real_epoch() { date +%s; }

uri_encode() {
  jq -rn --arg s "$1" '$s | @uri'
}

# Write stdin to <path> as a private 0600 file by rename, so a reader never sees
# a half-written record.
private_write() {
  local path=$1 tmp
  tmp=$(umask 077; mktemp "$path.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# --- configuration ----------------------------------------------------------

CONFIG_PROBLEM=
HOST=
GROUP=
LABELS=
PROJECTS_JSON='[]'

# The first problem found, as one sentence naming the field. Segment rules follow
# fm_pr_gitlab_path_valid; a group path may be a single segment, which is why the
# project-path validator there is not reused for it.
config_problem() {
  jq -r '
    def seg_ok:
      type == "string"
      and test("^[A-Za-z0-9._-]{1,255}$")
      and (startswith("-") | not)
      and . != "." and . != ".."
      and (endswith(".git") | not)
      and (endswith(".atom") | not);
    def path_ok: type == "string" and (split("/") | length >= 1 and length <= 20 and all(.[]; seg_ok));
    if type != "object" then "config must be a JSON object"
    elif (.host | type) != "string" or (.host | length) == 0 then "host must be a non-empty GitLab host name"
    elif (.group | type) != "string" or (.group | length) == 0 then "group must be a non-empty group path"
    elif (.group | path_ok | not) then "group \(.group | tojson) is not a GitLab namespace path"
    elif .projects != null and (.projects | type) != "array" then "projects must be an array of project paths"
    elif .projects != null and ([.projects[] | select(path_ok | not)] | length) > 0 then "projects entries must be project paths relative to the group or full path_with_namespace values"
    elif .intake_labels != null and ((.intake_labels | type) != "array" or (.intake_labels | length) == 0) then "intake_labels must be a non-empty array of label names"
    elif .intake_labels != null and ([.intake_labels[] | select(type != "string" or length == 0 or test("[,\t\n]"))] | length) > 0 then "intake_labels entries must be non-empty label names without commas, tabs, or newlines"
    elif .label_prefix != null and ((.label_prefix | type) != "string" or (.label_prefix | length) == 0) then "label_prefix must be a non-empty string"
    elif .max_in_flight != null and ((.max_in_flight | type) != "number" or .max_in_flight != (.max_in_flight | floor) or .max_in_flight < 1) then "max_in_flight must be a whole number of at least 1"
    else empty end
  ' "$CONFIG" 2>&1
}

config_validate() {
  local problem status
  CONFIG_PROBLEM=
  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_PROBLEM='jq is required to read config/gitlab-issues.json'
    return 1
  fi
  if ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    CONFIG_PROBLEM="config/gitlab-issues.json is not valid JSON"
    return 1
  fi
  problem=$(config_problem)
  status=$?
  if [ "$status" -ne 0 ]; then
    CONFIG_PROBLEM="config/gitlab-issues.json could not be read: $problem"
    return 1
  fi
  if [ -n "$problem" ]; then
    CONFIG_PROBLEM="config/gitlab-issues.json: $problem"
    return 1
  fi
  HOST=$(jq -r '.host' "$CONFIG")
  if ! fm_pr_gitlab_host_valid "$HOST"; then
    CONFIG_PROBLEM="config/gitlab-issues.json: host $HOST is not a lowercase GitLab host name"
    return 1
  fi
  GROUP=$(jq -r '.group' "$CONFIG")
  LABELS=$(jq -r --argjson d "$DEFAULT_LABELS" '(.intake_labels // $d)[]' "$CONFIG" | LC_ALL=C sort -u)
  # A relative entry is a path under the group; a full path_with_namespace is
  # recognised by its group prefix and kept as is.
  PROJECTS_JSON=$(jq -c --arg g "$GROUP" '
    [(.projects // [])[] | if startswith($g + "/") then . else $g + "/" + . end] | unique
  ' "$CONFIG")
  return 0
}

# --- poll error, once per reason per hour ----------------------------------

emit_error() {
  local reason=$1 msg now epoch prev
  fm_cap_line_var "gitlab-issue poll error: $reason" "$MAX_LINE"
  msg=$FM_LINE_CAP_LINE
  now=$(record_epoch_now)
  if [ -f "$ERROR_MARK" ] && [ ! -L "$ERROR_MARK" ]; then
    epoch=$(sed -n '1p' "$ERROR_MARK" 2>/dev/null)
    prev=$(sed -n '2p' "$ERROR_MARK" 2>/dev/null)
    case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
    if [ "$prev" = "$msg" ] && [ "$now" -ge "$epoch" ] && [ $((now - epoch)) -lt "$ERROR_SECS" ]; then
      return 0
    fi
  fi
  # Report before recording, so a marker that cannot be written costs a repeated
  # report rather than a lost one.
  printf '%s\n' "$msg"
  printf '%s\n%s\n' "$now" "$msg" | private_write "$ERROR_MARK" || true
}

# --- the sweep --------------------------------------------------------------

SWEEP_DIR=
DEADLINE=0
POLL_REASON=
LOCK_HELD=0

# pending_lock_take <seconds>: hold state/.gitlab-issues.lock, waiting at most
# that long for a live holder. FM_LOCK_HELD_PID names a holder that outlasted it.
pending_lock_take() {
  fm_lock_acquire_wait_bounded "$PENDING_LOCK" "$1" || return 1
  LOCK_HELD=1
}

pending_lock_release() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  LOCK_HELD=0
  fm_lock_release "$PENDING_LOCK"
}

sweep_cleanup() {
  pending_lock_release
  [ -z "$SWEEP_DIR" ] || rm -rf -- "$SWEEP_DIR"
  SWEEP_DIR=
}

# shellcheck disable=SC2329  # Registered by action_check's signal traps.
sweep_interrupted() {
  sweep_cleanup
  exit "$1"
}

# fetch_label <label> <out-file>: one bounded, paginated glab call. Sets
# POLL_REASON and returns 1 on any failure.
fetch_label() {
  local label=$1 out=$2 err="$2.err" endpoint remaining secs rc reason
  remaining=$((DEADLINE - $(real_epoch)))
  if [ "$remaining" -lt 1 ]; then
    POLL_REASON="ran out of time before querying label $label (watcher check timeout ${CHECK_TIMEOUT}s)"
    return 1
  fi
  secs=$CALL_SECS
  [ "$secs" -le "$remaining" ] || secs=$remaining
  endpoint="groups/$(uri_encode "$GROUP")/issues?state=opened&scope=all&labels=$(uri_encode "$label")&per_page=100"
  rc=0
  fm_run_timed "$secs" glab api --hostname "$HOST" --method GET --paginate --output ndjson "$endpoint" \
    >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 124 ]; then
    POLL_REASON="glab api for label $label timed out after ${secs}s"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    reason=$(grep -v '^[[:space:]]*$' "$err" 2>/dev/null | tail -1)
    POLL_REASON="glab api for label $label failed (exit $rc)${reason:+: $reason}"
    return 1
  fi
  # Every line must be an issue; an error body that slipped through with exit 0
  # is reported by its own message rather than read as no issues.
  if [ -s "$out" ] && ! jq -e -s 'all(.[]; type == "object" and (.iid | type) == "number")' "$out" >/dev/null 2>&1; then
    reason=$(jq -r -s 'map(select(type == "object" and has("message")) | .message | tostring) | first // "unexpected response shape"' "$out" 2>/dev/null)
    POLL_REASON="glab api for label $label returned ${reason:-unexpected response shape}"
    return 1
  fi
  return 0
}

# The project path is read once, here, and interpolated into both jq programs
# below: current_pairs decides which pairs are news and go into the seen record
# while pending_records decides which of them get a details line, so the two
# readings must not drift. references.full is the API's canonical
# <group>/<project>#<iid> and is right on every install shape; the web_url
# capture is the fallback, because a GitLab under a relative URL root
# ("https://host/gitlab/<group>/<project>/-/issues/<iid>") makes it read the URL
# root as part of the project path.
PROJECT_PATH_JQ='
    def project_path:
      ((((.references // {}).full // "") | split("#") | .[0]) | select(type == "string" and length > 0))
      // (((.web_url // "") | capture("^https?://[^/]+/(?<p>.+)/-/issues/[0-9]+/?$")? | .p) // null);
'

# current_pairs <label> <ndjson> : print "<path>#<iid>\t<label>" for each issue in
# the configured projects that carries the label.
current_pairs() {
  local label=$1 file=$2
  [ -s "$file" ] || return 0
  jq -r --arg want "$label" --argjson projects "$PROJECTS_JSON" "$PROJECT_PATH_JQ"'
    (project_path) as $p
    | select($p != null and $p != "")
    | select(($projects | length) == 0 or any($projects[]; . == $p))
    | select(any((.labels // [])[]; . == $want))
    | "\($p)#\(.iid)\t\($want)"
  ' "$file"
}

# pending_records <label> <ndjson> <new-pairs-json-object> <epoch>: one JSON line
# per new (issue, label) pair. A paginated answer can list the same issue on two
# pages when issues shift between page fetches, so the pairs are deduplicated the
# way the seen merge deduplicates them, and pending agrees with the report count.
pending_records() {
  local label=$1 file=$2 new=$3 epoch=$4
  [ -s "$file" ] || return 0
  jq -c -s --arg want "$label" --argjson new "$new" --argjson epoch "$epoch" "$PROJECT_PATH_JQ"'
    [ .[]
      | (project_path) as $p
      | select($p != null and $p != "")
      | "\($p)#\(.iid)" as $key
      | select($new | has($key + "\t" + $want))
      | {
          issue: $key, project: $p, iid: .iid, label: $want,
          title: .title, state: .state, web_url: .web_url, labels: (.labels // []),
          author: ((.author // {}).username // null),
          created_at: .created_at, updated_at: .updated_at,
          description: (.description // ""), seen_epoch: $epoch
        }
    ] | unique_by([.issue, .label]) | .[]
  ' "$file"
}

action_check() {
  local label i now current seen_old seen_new new_pairs new_json count line listed rest remaining
  local -a labels=()

  [ -f "$CONFIG" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || true

  if ! config_validate; then
    emit_error "$CONFIG_PROBLEM"
    return 0
  fi
  if ! command -v glab >/dev/null 2>&1; then
    emit_error "glab is not on PATH"
    return 0
  fi

  SWEEP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-gitlab-issues.XXXXXX") || {
    emit_error "could not create a temporary directory"
    return 0
  }
  trap sweep_cleanup EXIT
  trap 'sweep_interrupted 129' HUP
  trap 'sweep_interrupted 130' INT
  trap 'sweep_interrupted 143' TERM
  DEADLINE=$(($(real_epoch) + SWEEP_SECS))

  while IFS= read -r label; do
    [ -n "$label" ] || continue
    labels+=("$label")
  done <<< "$LABELS"

  i=0
  for label in "${labels[@]}"; do
    i=$((i + 1))
    if ! fetch_label "$label" "$SWEEP_DIR/$i.ndjson"; then
      emit_error "$POLL_REASON"
      return 0
    fi
  done

  current="$SWEEP_DIR/current"
  : > "$current"
  i=0
  for label in "${labels[@]}"; do
    i=$((i + 1))
    if ! current_pairs "$label" "$SWEEP_DIR/$i.ndjson" >> "$current"; then
      emit_error "jq could not read the issues returned for label $label"
      return 0
    fi
  done

  seen_old="$SWEEP_DIR/seen-old"
  if [ -f "$SEEN" ] && [ ! -L "$SEEN" ]; then
    cat "$SEEN" > "$seen_old" 2>/dev/null || : > "$seen_old"
  else
    : > "$seen_old"
  fi
  now=$(record_epoch_now)
  seen_new="$SWEEP_DIR/seen-new"
  new_pairs="$SWEEP_DIR/new"
  # The new record keeps every current pair, carrying the epoch it was first
  # reported at, and drops every pair no longer current. A current pair the old
  # record does not hold is news.
  # FILENAME rather than NR == FNR, because an empty seen record would otherwise
  # make every current pair read as already seen.
  awk -F '\t' -v now="$now" -v newfile="$new_pairs" -v seenfile="$seen_old" '
    FILENAME == seenfile { if (NF >= 3) seen[$1 "\t" $2] = $3; next }
    NF >= 2 {
      k = $1 "\t" $2
      if (k in done) next
      done[k] = 1
      if (k in seen) print $1 "\t" $2 "\t" seen[k]
      else { print $1 "\t" $2 "\t" now; print k > newfile }
    }
  ' "$seen_old" "$current" > "$seen_new"
  [ -f "$new_pairs" ] || : > "$new_pairs"

  count=$(wc -l < "$new_pairs" | tr -d '[:space:]')
  if [ "$count" -eq 0 ]; then
    private_write "$SEEN" < "$seen_new" || true
    return 0
  fi

  new_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | map({(.): true}) | add // {}' "$new_pairs")
  i=0
  : > "$SWEEP_DIR/pending"
  for label in "${labels[@]}"; do
    i=$((i + 1))
    if ! pending_records "$label" "$SWEEP_DIR/$i.ndjson" "$new_json" "$now" >> "$SWEEP_DIR/pending"; then
      emit_error "jq could not build the pending records for label $label"
      return 0
    fi
  done
  # The details land before the wake is printed, so firstmate finds them when it
  # reads `pending`; a seen record that cannot be written costs a repeated report.
  # Both land under the pending lock, and a lock that cannot be taken before the
  # sweep deadline leaves the seen record alone so the next poll reports the pairs.
  remaining=$((DEADLINE - $(real_epoch)))
  [ "$remaining" -ge 1 ] || remaining=1
  # The reason is what emit_error dedupes on, so it names the fixed sweep budget
  # rather than the seconds left this sweep; a wedged holder is one wake, not one
  # per poll.
  if ! pending_lock_take "$remaining"; then
    emit_error "could not lock $PENDING before the sweep deadline (watcher check timeout ${CHECK_TIMEOUT}s)"
    return 0
  fi
  # The append is the one write to the pending record that does not go through
  # private_write's rename, so it needs the guard the readers already apply: a
  # symlink here would send the issue details somewhere `pending` and `handled`
  # both refuse to read, and the seen record would still claim the pair reported.
  if [ -L "$PENDING" ] || { [ -e "$PENDING" ] && [ ! -f "$PENDING" ]; }; then
    pending_lock_release
    emit_error "$PENDING is not a regular file"
    return 0
  fi
  if ! ( umask 077; cat "$SWEEP_DIR/pending" >> "$PENDING" ); then
    pending_lock_release
    emit_error "could not write $PENDING"
    return 0
  fi
  private_write "$SEEN" < "$seen_new" || true
  pending_lock_release

  listed=$(awk -F '\t' -v max="$MAX_LISTED" 'NR <= max { printf "%s%s(%s)", (NR > 1 ? " " : ""), $1, $2 }' "$new_pairs")
  rest=$((count - MAX_LISTED))
  line="gitlab-issue $count new: $listed"
  [ "$rest" -le 0 ] || line="$line and $rest more"
  fm_cap_line_var "$line" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
  return 0
}

# --- pending records ----------------------------------------------------------

action_pending() {
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 0
  cat "$PENDING"
}

HANDLED_REMOVED=0

# handled_rewrite <key>: read the pending record and write it back without that
# issue's entries. Runs only while the pending lock is held, so the lines read
# are the lines replaced.
handled_rewrite() {
  local key=$1 kept
  HANDLED_REMOVED=0
  if [ ! -f "$PENDING" ] || [ -L "$PENDING" ]; then
    printf 'fm-gitlab-issues: no pending entry for %s\n' "$key" >&2
    return 1
  fi
  kept=$(jq -c --arg k "$key" 'select(.issue != $k)' "$PENDING" 2>/dev/null) || {
    printf 'fm-gitlab-issues: %s is not readable as JSON lines\n' "$PENDING" >&2
    return 1
  }
  HANDLED_REMOVED=$(jq -c --arg k "$key" 'select(.issue == $k)' "$PENDING" 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$HANDLED_REMOVED" -eq 0 ]; then
    printf 'fm-gitlab-issues: no pending entry for %s\n' "$key" >&2
    return 1
  fi
  if [ -z "$kept" ]; then
    rm -f -- "$PENDING" || return 1
  else
    printf '%s\n' "$kept" | private_write "$PENDING" || return 1
  fi
}

action_handled() {
  local key=${1-} path iid rc
  case "$key" in
    *#*) path=${key%#*}; iid=${key##*#} ;;
    *) die_usage "handled needs <path_with_namespace>#<iid>" ;;
  esac
  case "$iid" in ''|*[!0-9]*) die_usage "handled needs <path_with_namespace>#<iid>" ;; esac
  fm_pr_gitlab_path_valid "$path" || die_usage "handled needs <path_with_namespace>#<iid>"
  if [ ! -f "$PENDING" ] || [ -L "$PENDING" ]; then
    printf 'fm-gitlab-issues: no pending entry for %s\n' "$key" >&2
    return 1
  fi
  if ! pending_lock_take "$CHECK_TIMEOUT"; then
    printf 'fm-gitlab-issues: could not lock %s within %ss%s\n' "$PENDING" "$CHECK_TIMEOUT" "${FM_LOCK_HELD_PID:+ (held by pid $FM_LOCK_HELD_PID)}" >&2
    return 1
  fi
  rc=0
  handled_rewrite "$key" || rc=$?
  pending_lock_release
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'handled: %s (%s pending entr%s removed)\n' "$key" "$HANDLED_REMOVED" "$([ "$HANDLED_REMOVED" -eq 1 ] && printf y || printf ies)"
}

# --- arm and disarm -----------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-gitlab-issues.sh - GitLab issue intake poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-gitlab-issues.sh") check"
}

# The guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-gitlab-issues-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite. The trust binding is over the bytes, so a rewrite would satisfy it
# too, but a home that was armed stays armed with what it had.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-gitlab-issues-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So after a failed or
# interrupted arm the home never holds a shim without a matching trust binding.
# The shim a working home had is put back and kept only when it is still bound;
# otherwise the shim goes, so the home is plainly not armed and the failure is
# the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
  fi
  fm_custom_check_registered "$STATE" "$CHECK_ID" || rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-gitlab-issues: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -f "$CONFIG" ]; then
    printf 'fm-gitlab-issues: no GitLab issue intake config at %s\n' "$CONFIG" >&2
    return 1
  fi
  if ! config_validate; then
    printf 'fm-gitlab-issues: %s (%s)\n' "$CONFIG_PROBLEM" "$CONFIG" >&2
    return 1
  fi
  if ! command -v glab >/dev/null 2>&1; then
    printf 'fm-gitlab-issues: glab is not on PATH; install it before arming the issue poll\n' >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-gitlab-issues: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-gitlab-issues: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-gitlab-issues: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-gitlab-issues: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  local leftover
  if [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
    FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || {
      printf 'fm-gitlab-issues: could not retire %s\n' "$CHECK_SHIM" >&2
      return 1
    }
    rm -f -- "$SEEN" "$PENDING" "$ERROR_MARK" "$PENDING_LOCK"
    # A holder killed mid-sweep leaves the lock link and its owner directory
    # behind with nothing left to reclaim them once the check is retired.
    for leftover in "$PENDING_LOCK".owner.*; do
      [ -e "$leftover" ] || continue
      rm -rf -- "$leftover"
    done
  fi
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  pending) action_pending ;;
  handled) shift; [ "$#" -eq 1 ] || die_usage "handled needs exactly one <path_with_namespace>#<iid>"; action_handled "$1" ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
