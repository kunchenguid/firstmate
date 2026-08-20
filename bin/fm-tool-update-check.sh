#!/usr/bin/env bash
# fm-tool-update-check.sh - report watched tooling that has an update available,
# and tooling whose update is installed but not in effect.
#
# Usage:
#   fm-tool-update-check.sh [check]
#   fm-tool-update-check.sh arm
#   fm-tool-update-check.sh disarm
#   fm-tool-update-check.sh --help
#
# `check` prints one line when something needs attention and prints nothing at
# all otherwise, so it composes with the existing watcher state-check contract
# instead of needing a schedule of its own. `arm` writes
# state/tool-updates.check.sh and binds its bytes with fm-check-register.sh, so
# the watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns
# its one line into a `check:` wake. `disarm` removes the shim, its trust
# binding, and the report record.
#
# Two conditions are reported, and they are deliberately distinct:
#
#   "<tool> update available"      a newer version exists at the update source.
#   "<tool> update not in effect"  a newer copy is installed on this host, but
#                                  PATH still resolves an older one.
#
# The second condition is the reason this script exists. A tool that
# self-installs into ~/.local/bin while a version manager keeps its own older
# copy earlier on PATH looks fully up to date to anything that asks only "is a
# newer version published". So PATH skew is measured, never inferred: every
# executable copy on PATH is asked for its own version, and those answers are
# compared. A directory name is never read as a version, because a version
# manager's "latest" directory can hold an older build. A copy that will not
# report a version is reported as a check failure rather than assumed current.
#
# What this script never does: it reports, and it repairs nothing. It does not
# install, update, uninstall, reorder PATH, or touch any version manager's
# configuration, and it never fetches into a watched git repository. Every git
# probe is read-only (rev-parse, symbolic-ref, ls-remote, cat-file, merge-base,
# rev-list), so a watched project is never mutated.
#
# The watched tools live in config/watched-tools.json, which is local and
# gitignored, and is never propagated to another home. Adding a tool is a config
# edit, never a code change. docs/configuration.md owns that schema.
#
# Probing costs real time, so `check` runs its probes at most once per
# FM_TOOL_UPDATE_INTERVAL (default 900, 0 disables the gate, otherwise 60..86400)
# and stays silent in between. Each probe is bounded by
# FM_TOOL_UPDATE_PROBE_SECS (default 5, valid 1..30) and a whole sweep by
# FM_TOOL_UPDATE_BUDGET_SECS (default 20, valid 1..120) so the run finishes
# inside the watcher's FM_CHECK_TIMEOUT.
#
# The report record state/.tool-updates is written only after a complete sweep,
# and it carries the last reported line so the same pending update is reported
# once rather than on every poll. A sweep killed part way through therefore
# leaves no record and is retried, instead of silently suppressing its finding.
set -u
export LC_ALL=C
# A watched git remote must never stop to ask for credentials; an unauthenticated
# probe has to fail inside its bound instead of waiting for an answer.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/watched-tools.json"
RECORD="$STATE/.tool-updates"
CHECK_ID=tool-updates
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-tool-updates-v1
# Wider than the digest default because one finding names two absolute paths and
# their two versions, and several tools can report in the same sweep.
MAX_LINE=1000

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-tool-update-check.sh [check]   report watched tools needing attention (silent when current)
  fm-tool-update-check.sh arm       write and register state/tool-updates.check.sh
  fm-tool-update-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-tool-update-check.sh --help    print this help

Watched tools are read from config/watched-tools.json (local, gitignored).
See docs/configuration.md for the schema and docs/examples/watched-tools.json for a starting point.
EOF
}

die_usage() {
  printf 'fm-tool-update-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

INTERVAL=${FM_TOOL_UPDATE_INTERVAL:-900}
case "$INTERVAL" in
  ''|*[!0-9]*)
    printf 'fm-tool-update-check: FM_TOOL_UPDATE_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  printf 'fm-tool-update-check: FM_TOOL_UPDATE_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
  exit 2
fi

PROBE_SECS=${FM_TOOL_UPDATE_PROBE_SECS:-5}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-tool-update-check: FM_TOOL_UPDATE_PROBE_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$PROBE_SECS" -gt 30 ]; then
  printf 'fm-tool-update-check: FM_TOOL_UPDATE_PROBE_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

BUDGET_SECS=${FM_TOOL_UPDATE_BUDGET_SECS:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-tool-update-check: FM_TOOL_UPDATE_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -gt 120 ]; then
  printf 'fm-tool-update-check: FM_TOOL_UPDATE_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
  exit 2
fi

# --- small helpers ----------------------------------------------------------

# The record epoch is overridable so a test can drive the cadence gate; the
# sweep budget always uses real time so a frozen epoch cannot disable it.
record_epoch_now() {
  case "${FM_TOOL_UPDATE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_TOOL_UPDATE_NOW" ;;
  esac
}

real_epoch() { date +%s; }

FINDINGS=
DEADLINE=0

# Each finding is flattened to a single line here, because the whole report must
# stay one line for the wake record.
emit() {
  local text
  text=$(printf '%s' "$1" | tr '\t\r\n' '   ')
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$text
  else
    FINDINGS="$FINDINGS; $text"
  fi
}

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

# First dotted number in the text, so "herdr 0.8.2" and "v1.46.0" both work.
parse_version() {
  printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

# version_newer <a> <b>: true when version a is numerically newer than b.
version_newer() {
  local a=$1 b=$2 i left right
  local -a ap bp
  IFS=. read -r -a ap <<< "$a"
  IFS=. read -r -a bp <<< "$b"
  i=0
  while [ "$i" -lt "${#ap[@]}" ] || [ "$i" -lt "${#bp[@]}" ]; do
    left=$((10#${ap[i]:-0}))
    right=$((10#${bp[i]:-0}))
    if [ "$left" -gt "$right" ]; then
      return 0
    elif [ "$left" -lt "$right" ]; then
      return 1
    fi
    i=$((i + 1))
  done
  return 1
}

commit_phrase() {
  if [ "$1" = 1 ]; then
    printf '1 commit\n'
  else
    printf '%s commits\n' "$1"
  fi
}

# --- watched tool registry --------------------------------------------------

CONFIG_PROBLEM=

config_validate() {
  local problem status
  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_PROBLEM='jq is required to read the watched tool registry'
    return 1
  fi
  problem=$(jq -r '
    def tool_problem($t):
      if ($t | type) != "object" then "every entry in tools must be an object"
      elif ($t.name | type) != "string" or ($t.name | length) == 0 then "every tool needs a non-empty name"
      elif ($t.name | test("^[A-Za-z0-9._+-]+$") | not) then "tool name \($t.name) may use only letters, digits, dot, underscore, plus, and dash"
      elif ($t | has("command") | not) and ($t | has("git") | not) then "tool \($t.name) needs command, git, or both"
      elif ($t | has("command")) and (($t.command | type) != "string" or ($t.command | test("^[A-Za-z0-9._+-]+$") | not)) then "tool \($t.name) command must be a bare executable name"
      elif ($t | has("version_args")) and (($t.version_args | type) != "array" or ($t.version_args | length) == 0) then "tool \($t.name) version_args must be a non-empty array"
      elif ($t | has("version_args")) and ([$t.version_args[] | select((type != "string") or (test("^[A-Za-z0-9._=+/:-]+$") | not))] | length) > 0 then "tool \($t.name) version_args must be simple flag strings without spaces"
      elif ($t | has("announce_pattern")) and (($t.announce_pattern | type) != "string" or ($t.announce_pattern | length) == 0 or ($t.announce_pattern | test("[[:cntrl:]]"))) then "tool \($t.name) announce_pattern must be a non-empty single-line string"
      elif ($t | has("announce_pattern")) and (($t | has("command")) | not) then "tool \($t.name) announce_pattern needs command"
      elif ($t | has("announce_args")) and (($t.announce_args | type) != "array" or ($t.announce_args | length) == 0) then "tool \($t.name) announce_args must be a non-empty array"
      elif ($t | has("announce_args")) and ([$t.announce_args[] | select((type != "string") or (test("^[A-Za-z0-9._=+/:-]+$") | not))] | length) > 0 then "tool \($t.name) announce_args must be simple flag strings without spaces"
      elif ($t | has("announce_args")) and (($t | has("announce_pattern")) | not) then "tool \($t.name) announce_args needs announce_pattern"
      elif ($t | has("git")) and (($t.git | type) != "object") then "tool \($t.name) git must be an object"
      elif ($t | has("git")) and (($t.git.repo | type) != "string" or ($t.git.repo | startswith("/") | not) or ($t.git.repo | test("[[:cntrl:]]"))) then "tool \($t.name) git.repo must be an absolute path on one line"
      elif ($t | has("git")) and ($t.git | has("remote")) and (($t.git.remote | type) != "string" or ($t.git.remote | test("^[A-Za-z0-9._-]+$") | not)) then "tool \($t.name) git.remote must be a simple remote name"
      elif ($t | has("git")) and ($t.git | has("branch")) and (($t.git.branch | type) != "string" or ($t.git.branch | test("^[A-Za-z0-9._/-]+$") | not)) then "tool \($t.name) git.branch must be a simple branch name"
      else empty
      end;
    def problems:
      if type != "object" then ["the top level must be an object"]
      elif (.tools | type) != "array" then ["tools must be an array"]
      elif (.tools | length) == 0 then ["tools must list at least one tool"]
      else
        [.tools[] | tool_problem(.)]
        + (if ([.tools[].name] | unique | length) != (.tools | length) then ["tool names must be unique"] else [] end)
      end;
    problems | .[0] // "ok"
  ' "$CONFIG" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ] || [ -z "$problem" ]; then
    CONFIG_PROBLEM='the watched tool registry is not valid JSON'
    return 1
  fi
  if [ "$problem" != ok ]; then
    CONFIG_PROBLEM=$problem
    return 1
  fi
  CONFIG_PROBLEM=
  return 0
}

# One record per tool, in config order. Fields are joined with the unit
# separator rather than a tab, because tab is IFS whitespace and `read` would
# collapse the empty fields that an optional key leaves behind.
FIELD_SEP=$(printf '\037')

config_records() {
  jq -r '
    .tools[] | [
      .name,
      (.command // ""),
      ((.version_args // ["--version"]) | join(" ")),
      (.announce_pattern // ""),
      ((.announce_args // .version_args // ["--version"]) | join(" ")),
      (.git.repo // ""),
      (.git.remote // "origin"),
      (.git.branch // "")
    ] | join("\u001f")
  ' "$CONFIG" 2>/dev/null
}

# --- PATH probes ------------------------------------------------------------

# Every executable copy of <command> on PATH, in PATH order, deduplicated by
# device and inode so one copy reached through two PATH entries is not read as
# two installs.
path_hits() {
  local command_name=$1 dir candidate identity seen=''
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    candidate="$dir/$command_name"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    identity=$(fm_pr_file_identity "$candidate" 2>/dev/null) || identity=
    [ -n "$identity" ] || identity=$candidate
    case " $seen " in
      *" $identity "*) continue ;;
    esac
    seen="$seen $identity"
    printf '%s\n' "$candidate"
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
}

# Ask one copy for its own version. Combined output, because tools answer on
# either stream, and no-mistakes announces its update on stderr.
probe_output() {
  local path=$1
  shift
  fm_run_timed "$PROBE_SECS" "$path" "$@" 2>&1
}

command_findings() {
  local name=$1 command_name=$2 args_joined=$3 announce=$4 announce_args=$5
  local hit out version matched announce_out
  local resolved_path='' resolved_version='' resolved_out=''
  local best_path='' best_version='' unreadable='' hits=''

  hits=$(path_hits "$command_name")
  if [ -z "$hits" ]; then
    emit "$name check failed: $command_name is not on PATH"
    return 0
  fi

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if budget_exhausted; then
      emit "$name check failed: the time budget ran out before every copy answered"
      break
    fi
    # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
    out=$(probe_output "$hit" $args_joined)
    version=$(parse_version "$out")
    if [ -z "$resolved_path" ]; then
      resolved_path=$hit
      resolved_version=$version
      resolved_out=$out
    fi
    if [ -z "$version" ]; then
      [ -n "$unreadable" ] || unreadable=$hit
      continue
    fi
    if [ -z "$best_version" ] || version_newer "$version" "$best_version"; then
      best_version=$version
      best_path=$hit
    fi
  done <<EOF
$hits
EOF

  if [ -n "$announce" ] && [ -n "$resolved_path" ]; then
    # A tool does not have to announce its update on the command that reports its
    # version: no-mistakes prints its version for --version but announces a new
    # release on its other commands. So announce_args may name a second command,
    # and it is asked of the copy PATH actually resolves.
    announce_out=$resolved_out
    if [ "$announce_args" != "$args_joined" ] && ! budget_exhausted; then
      # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
      announce_out=$(probe_output "$resolved_path" $announce_args)
    fi
    if [ -n "$announce_out" ]; then
      matched=$(printf '%s' "$announce_out" | grep -oE -- "$announce" 2>/dev/null | head -n 1)
      [ -z "$matched" ] || emit "$name update available: $matched"
    fi
  fi

  if [ -z "$resolved_version" ]; then
    emit "$name check failed: $resolved_path did not report a version"
    return 0
  fi

  if [ -n "$best_version" ] && [ "$best_path" != "$resolved_path" ] \
    && version_newer "$best_version" "$resolved_version"; then
    emit "$name update not in effect: PATH resolves $resolved_version at $resolved_path but $best_version is installed at $best_path"
  fi

  if [ -n "$unreadable" ]; then
    emit "$name check failed: $unreadable did not report a version"
  fi
  return 0
}

# --- git probes -------------------------------------------------------------

# Read-only throughout: nothing here writes to the watched repository.
git_findings() {
  local name=$1 repo=$2 remote=$3 branch=$4
  local status remote_sha local_sha local_label count short

  if ! command -v git >/dev/null 2>&1; then
    emit "$name check failed: git is not installed"
    return 0
  fi
  if [ ! -d "$repo" ]; then
    emit "$name check failed: $repo is not a directory"
    return 0
  fi
  if ! fm_run_timed "$PROBE_SECS" git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    emit "$name check failed: $repo is not a git repository"
    return 0
  fi

  if [ -z "$branch" ]; then
    branch=$(fm_run_timed "$PROBE_SECS" git -C "$repo" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null)
    branch=${branch#"$remote/"}
  fi
  if [ -z "$branch" ]; then
    # A clone made with --single-branch, or one that never ran remote set-head,
    # has no local record of the remote's default branch. Ask the remote itself
    # rather than reporting a check failure the operator cannot act on.
    branch=$(fm_run_timed "$PROBE_SECS" git -C "$repo" ls-remote --symref "$remote" HEAD 2>/dev/null \
      | awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  fi
  if [ -z "$branch" ]; then
    emit "$name check failed: cannot resolve the default branch of $remote in $repo"
    return 0
  fi

  remote_sha=$(fm_run_timed "$PROBE_SECS" git -C "$repo" ls-remote "$remote" "refs/heads/$branch" 2>/dev/null)
  status=$?
  if [ "$status" -eq 124 ]; then
    emit "$name check failed: $remote did not answer within ${PROBE_SECS}s"
    return 0
  fi
  remote_sha=$(printf '%s\n' "$remote_sha" | awk 'NR == 1 { print $1 }')
  if [ -z "$remote_sha" ]; then
    emit "$name check failed: $remote has no branch $branch"
    return 0
  fi

  if local_sha=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null) && [ -n "$local_sha" ]; then
    local_label="local $branch"
  elif local_sha=$(git -C "$repo" rev-parse --verify --quiet HEAD 2>/dev/null) && [ -n "$local_sha" ]; then
    local_label='local HEAD'
  else
    emit "$name check failed: $repo has no commit to compare"
    return 0
  fi

  [ "$local_sha" != "$remote_sha" ] || return 0

  if git -C "$repo" cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    # The local copy may be ahead of, or diverged from, the remote branch; only
    # commits it does not have yet are an available update.
    if git -C "$repo" merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
      return 0
    fi
    count=$(git -C "$repo" rev-list --count "$local_sha..$remote_sha" 2>/dev/null)
    case "$count" in
      ''|*[!0-9]*|0) count= ;;
    esac
    if [ -n "$count" ]; then
      emit "$name update available: $local_label is $(commit_phrase "$count") behind $remote/$branch"
      return 0
    fi
  fi

  short=$(printf '%s' "$remote_sha" | cut -c1-12)
  emit "$name update available: $remote/$branch is at $short which this copy does not have"
  return 0
}

# --- report record ----------------------------------------------------------

RECORD_EPOCH=0
RECORD_REPORTED=

record_read() {
  local line first=1
  RECORD_EPOCH=0
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- actions ----------------------------------------------------------------

action_check() {
  local name command_name args_joined announce announce_args repo remote branch
  local line now

  [ -f "$CONFIG" ] || return 0

  record_read
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi

  DEADLINE=$(($(real_epoch) + BUDGET_SECS))

  if ! config_validate; then
    emit "watched tool registry: $CONFIG_PROBLEM"
  else
    while IFS=$FIELD_SEP read -r name command_name args_joined announce announce_args repo remote branch; do
      [ -n "$name" ] || continue
      if budget_exhausted; then
        emit "check incomplete: the time budget ran out before $name"
        break
      fi
      [ -z "$command_name" ] || command_findings "$name" "$command_name" "$args_joined" "$announce" "$announce_args"
      [ -z "$repo" ] || git_findings "$name" "$repo" "$remote" "$branch"
    done < <(config_records)
  fi

  line=
  if [ -n "$FINDINGS" ]; then
    # Capped through the shared cut so an over-long report carries the same
    # visible truncation marker the digests use, instead of ending mid-finding
    # as if that were all of it.
    fm_cap_line_var "tool updates: $FINDINGS" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  if [ -n "$line" ] && [ "$line" != "$RECORD_REPORTED" ]; then
    printf '%s\n' "$line"
  fi
  record_write "$line" || true
  return 0
}

shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-tool-update-check.sh - watched tool update poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-tool-update-check.sh") check"
}

action_arm() {
  local want
  if [ ! -f "$CONFIG" ]; then
    printf 'fm-tool-update-check: no watched tool registry at %s\n' "$CONFIG" >&2
    return 1
  fi
  if ! config_validate; then
    printf 'fm-tool-update-check: %s (%s)\n' "$CONFIG_PROBLEM" "$CONFIG" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  want=$(shim_content)
  if [ ! -f "$CHECK_SHIM" ] || [ "$(cat "$CHECK_SHIM" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" > "$CHECK_SHIM" || return 1
  fi
  chmod 0700 "$CHECK_SHIM" || return 1
  FM_HOME="$FM_HOME" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || {
    printf 'fm-tool-update-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
