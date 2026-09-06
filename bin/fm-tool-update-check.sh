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
# Published versions are read from the public npm registry or GitHub latest
# release API with curl and jq. No vendor CLI update command is invoked.
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
# FM_TOOL_UPDATE_BUDGET_SECS (default 20, valid 1..120).
#
# The sweep has to finish inside the watcher's own per check bound, because a run
# the watcher kills prints nothing and writes no record, so it would repeat that
# silence on every poll. That coupling is enforced rather than assumed: a budget
# larger than FM_CHECK_TIMEOUT (default 30, read from this check's own
# environment because the watcher runs it as a direct child) allows is cut down
# to what fits, and the cut is reported in the report line so the operator sees
# it. A budget that cannot be read as a whole number from 1 to 120 is still
# refused outright.
#
# The report record state/.tool-updates is written only when a sweep runs to its
# end, and it carries the whole finding set the last report was made from,
# uncut, so the same pending update is reported once rather than on every poll
# while a new finding that lands past the one-line cut is still news. A sweep
# killed part way through leaves no record and is retried, instead of
# suppressing its finding.
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
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

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

# The smallest bound a probe can be given, because fm_run_timed treats a
# non-positive bound as no bound.
PROBE_MIN_SECS=1
# Both clocks here count whole seconds, so a probe can start when the arithmetic
# says a second is left while almost none of it really is, and it still gets a
# full bound.
CLOCK_ROUNDING_SECS=1
# fm_run_timed asks its runner for -k 1, so a probe that does not stop on TERM is
# only killed a second after its bound.
KILL_GRACE_SECS=1

# The watcher's per check bound, read from this check's own environment. The
# watcher runs the check as a direct child, so an operator who raised it is seen
# here too, and when it is unset both sides resolve the same default.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
# The last probe of a sweep can end this far past the deadline, so that is what
# the budget has to leave the watcher's own bound.
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
# Cut rather than refuse. A refusal is reported once and then suppressed by the
# no-nag gate, which leaves the detector dead and quiet, and a check that goes
# silent is worse than a check that reports something awkward.
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
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
INCOMPLETE_REPORTED=0

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

# True while the sweep budget still has room for another probe. When it does not,
# it records once which tool the sweep did not finish, so a sweep that cannot
# finish says so rather than being killed by the watcher with nothing printed.
budget_allows() {
  local name=$1
  budget_exhausted || return 0
  if [ "$INCOMPLETE_REPORTED" -eq 0 ]; then
    INCOMPLETE_REPORTED=1
    emit "check incomplete: the time budget ran out before $name"
  fi
  return 1
}

# The bound for one probe: the probe bound, cut down to whatever the sweep
# budget has left, so no probe can run past the end of the sweep. Never below
# PROBE_MIN_SECS, because fm_run_timed treats a non-positive bound as no bound.
probe_bound() {
  local left
  left=$((DEADLINE - $(real_epoch)))
  if [ "$left" -lt "$PROBE_MIN_SECS" ]; then
    printf '%s\n' "$PROBE_MIN_SECS"
  elif [ "$left" -lt "$PROBE_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$PROBE_SECS"
  fi
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
    left=${ap[i]:-0}
    right=${bp[i]:-0}
    # Compare decimal strings so untrusted large components cannot overflow
    # shell arithmetic. Leading zeroes and omitted components are insignificant.
    while [ "${#left}" -gt 1 ] && [ "${left#0}" != "$left" ]; do left=${left#0}; done
    while [ "${#right}" -gt 1 ] && [ "${right#0}" != "$right" ]; do right=${right#0}; done
    if [ "${#left}" -gt "${#right}" ] || { [ "${#left}" -eq "${#right}" ] && [[ "$left" > "$right" ]]; }; then
      return 0
    elif [ "$left" != "$right" ]; then
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

# jq can check that an announce_pattern is a non-empty single-line string, but
# only grep can say whether it compiles as an extended regular expression. A
# pattern grep refuses would silently disable that tool's update source, which is
# the exact failure this script exists to prevent.
announce_pattern_usable() {
  local pattern=$1 status
  printf '%s' '' | grep -qE -- "$pattern" 2>/dev/null
  status=$?
  [ "$status" -le 1 ]
}

# Deliberately separate from config_validate, and asked only by arm. Arming is a
# deliberate operator action that should fail loudly, but a sweep must not treat
# one tool's unusable pattern as a reason to stop watching every other tool: that
# would let a one character typo turn the PATH skew detector off. So `check`
# reports this per tool instead, in command_findings.
config_announce_patterns_usable() {
  local name announce
  while IFS=$FIELD_SEP read -r name _ _ announce _; do
    [ -n "$announce" ] || continue
    if ! announce_pattern_usable "$announce"; then
      CONFIG_PROBLEM="tool $name announce_pattern is not a usable extended regular expression"
      return 1
    fi
  done < <(config_records)
  return 0
}

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
      elif ($t | has("published")) and (($t.published | type) != "object") then "tool \($t.name) published must be an object"
      elif ($t | has("published")) and (($t | has("command")) | not) then "tool \($t.name) published needs command to report the installed version"
      elif ($t | has("published")) and ($t.published.source != "npm" and $t.published.source != "github") then "tool \($t.name) published.source must be npm or github"
      elif ($t | has("published")) and $t.published.source == "npm" and
        (($t.published.package | type) != "string" or ($t.published.package | test("^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$") | not)) then "tool \($t.name) published.package must be an npm package name"
      elif ($t | has("published")) and $t.published.source == "github" and
        (($t.published.repo | type) != "string" or ($t.published.repo | test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$") | not)) then "tool \($t.name) published.repo must be a GitHub owner/repo"
      elif ($t | has("published")) and
        (($t.published | keys) - (if $t.published.source == "npm" then ["source", "package"] else ["source", "repo"] end) | length) > 0 then "tool \($t.name) published has unsupported fields"
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
      (.git.branch // ""),
      (.published.source // ""),
      (.published.package // .published.repo // "")
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
  fm_run_timed "$(probe_bound)" "$path" "$@" 2>&1
}

COMMAND_VERSION=

command_findings() {
  local name=$1 command_name=$2 args_joined=$3 announce=$4 announce_args=$5
  local hit out version matched announce_out status
  local resolved_path='' resolved_version='' resolved_out=''
  local best_path='' best_version='' unreadable='' hits=''
  COMMAND_VERSION=

  # This tool's announcement source is dead if its pattern cannot be used, which
  # is reported here, for this tool alone, so the rest of the sweep still runs.
  if [ -n "$announce" ] && ! announce_pattern_usable "$announce"; then
    emit "$name check failed: announce_pattern is not a usable extended regular expression"
    announce=
  fi

  hits=$(path_hits "$command_name")
  if [ -z "$hits" ]; then
    emit "$name check failed: $command_name is not on PATH"
    return 0
  fi

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if budget_exhausted; then
      INCOMPLETE_REPORTED=1
      emit "$name check failed: the time budget ran out before every copy answered"
      break
    fi
    # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
    out=$(probe_output "$hit" $args_joined)
    status=$?
    version=
    [ "$status" -ne 0 ] || version=$(parse_version "$out")
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
    if [ "$announce_args" != "$args_joined" ]; then
      if budget_exhausted; then
        # The version probe's output cannot carry the announcement, so searching
        # it would present a source that was never asked as a clean result.
        INCOMPLETE_REPORTED=1
        emit "$name check failed: the time budget ran out before the update announcement was checked"
        announce_out=
      else
        # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
        announce_out=$(probe_output "$resolved_path" $announce_args)
        status=$?
        if [ "$status" -eq 124 ]; then
          # A source that was asked and never answered is not a source that had
          # nothing to say. The one that answers with nothing stays silent below.
          emit "$name check failed: $resolved_path did not answer when asked for its update announcement"
          announce_out=
        fi
      fi
    fi
    if [ -n "$announce_out" ]; then
      # Not a pipeline, so grep's own status is still readable here: a pattern
      # grep cannot use is a check failure, never read as nothing to announce.
      matched=$(grep -oE -- "$announce" <<< "$announce_out" 2>/dev/null)
      status=$?
      if [ "$status" -gt 1 ]; then
        emit "$name check failed: announce_pattern is not a usable extended regular expression"
      elif [ -n "$matched" ]; then
        emit "$name update available: $(printf '%s\n' "$matched" | head -n 1)"
      fi
    fi
  fi

  if [ -z "$resolved_version" ]; then
    # No copy was probed at all when the path is empty, and the budget report
    # already covers that, so do not blame a copy that was never asked.
    [ -z "$resolved_path" ] || emit "$name check failed: $resolved_path did not report a version"
    return 0
  fi

  COMMAND_VERSION=$resolved_version

  if [ -n "$best_version" ] && [ "$best_path" != "$resolved_path" ] \
    && version_newer "$best_version" "$resolved_version"; then
    emit "$name update not in effect: PATH resolves $resolved_version at $resolved_path but $best_version is installed at $best_path"
  fi

  if [ -n "$unreadable" ]; then
    emit "$name check failed: $unreadable did not report a version"
  fi
  return 0
}

# --- published release probes -----------------------------------------------

published_findings() {
  local name=$1 source=$2 package=$3 installed=$4
  local url field version status bound
  # command_findings already reports a missing or unreadable resolved command.
  [ -n "$installed" ] || return 0
  budget_allows "$name published source" || return 0
  if ! command -v curl >/dev/null 2>&1; then
    emit "$name check failed: curl is required to read its published source"
    return 0
  fi
  case "$source" in
    npm)
      # Encode scoped package names as one URL path component.
      url="https://registry.npmjs.org/$(jq -rn --arg package "$package" '$package | @uri')/latest"
      field=version
      ;;
    github)
      url="https://api.github.com/repos/$package/releases/latest"
      field=tag_name
      ;;
  esac
  bound=$(probe_bound)
  # -q must be first: ignore curlrc (credentials, output files, or write methods).
  # No credentials, redirects, retries, or stdin; HTTP errors are failed probes.
  # Keep HTTP and JSON parsing in the same bound, including blocking DNS builds.
  # Only the documented version field counts, never dotted text in release notes
  # or errors. Exit 65 distinguishes an unsupported response from a failed read.
  # shellcheck disable=SC2016  # Expanded by the bounded child shell and jq.
  version=$(fm_run_timed "$bound" bash -c '
    body=$(curl -q --fail --silent --show-error \
      --proto "=https" --connect-timeout "$1" --max-time "$1" \
      --header "Accept: application/json" --url "$2") || exit "$?"
    version=$(printf "%s" "$body" | jq -ser --arg field "$3" "$4") || exit 65
    [ -n "$version" ] || exit 65
    printf "%s\n" "$version"
  ' published-probe "$bound" "$url" "$field" \
    'select(length == 1) | .[0][$field] | strings | select(test("^v?[0-9]+(\\.[0-9]+)+$"))' </dev/null 2>/dev/null)
  status=$?
  if [ "$status" -eq 65 ]; then
    emit "$name check failed: published source $url did not report a supported version"
    return 0
  elif [ "$status" -ne 0 ]; then
    emit "$name check failed: published source $url could not be reached or read (exit $status)"
    return 0
  fi
  version=${version#v}
  if version_newer "$version" "$installed"; then
    emit "$name update available: installed $installed, published $version at $url"
  fi
}

# --- git probes -------------------------------------------------------------

# A probe the sweep budget can no longer afford is never issued, and says so with
# a status of its own rather than a git status, so no caller can read it as an
# answer. Neither git nor the bounded runner uses this value.
GIT_PROBE_NOT_ISSUED=3

# One bounded read-only git probe. The budget check lives here rather than in the
# callers, so no probe can be issued past the sweep deadline whatever a caller
# does, and the budget only has to leave room for the one probe that was already
# running when the deadline passed.
git_probe() {
  local repo=$1
  shift
  budget_exhausted && return "$GIT_PROBE_NOT_ISSUED"
  fm_run_timed "$(probe_bound)" git -C "$repo" "$@"
}

# The single place that reads a probe status as no answer at all, so every probe
# reports an unanswered read the same way instead of taking it for the answer no.
git_probe_answered() {
  local status=$1 name=$2 subject=$3 question=$4
  case "$status" in
    "$GIT_PROBE_NOT_ISSUED")
      INCOMPLETE_REPORTED=1
      emit "$name check failed: the time budget ran out before $subject was asked $question"
      return 1
      ;;
    124)
      emit "$name check failed: $subject did not answer $question"
      return 1
      ;;
  esac
  return 0
}

# Read-only throughout: nothing here writes to the watched repository. This is the
# one tool kind that issues several probes in a row, two of them over the network,
# and each of them goes through git_probe, which owns both the bound and the
# budget check, so the sweep cannot outrun its deadline here.
git_findings() {
  local name=$1 repo=$2 remote=$3 branch=$4
  local status remote_sha local_sha local_label count short symref

  if ! command -v git >/dev/null 2>&1; then
    emit "$name check failed: git is not installed"
    return 0
  fi
  if [ ! -d "$repo" ]; then
    emit "$name check failed: $repo is not a directory"
    return 0
  fi
  budget_allows "$name" || return 0
  git_probe "$repo" rev-parse --git-dir >/dev/null 2>&1
  status=$?
  git_probe_answered "$status" "$name" "$repo" "whether it is a git repository" || return 0
  if [ "$status" -ne 0 ]; then
    emit "$name check failed: $repo is not a git repository"
    return 0
  fi

  if [ -z "$branch" ]; then
    branch=$(git_probe "$repo" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null)
    git_probe_answered "$?" "$name" "$repo" "which branch it records for $remote" || return 0
    branch=${branch#"$remote/"}
  fi
  if [ -z "$branch" ]; then
    # A clone made with --single-branch, or one that never ran remote set-head,
    # has no local record of the remote's default branch. Ask the remote itself
    # rather than reporting a check failure the operator cannot act on.
    symref=$(git_probe "$repo" ls-remote --symref "$remote" HEAD 2>/dev/null)
    git_probe_answered "$?" "$name" "$remote" "which branch it uses by default" || return 0
    branch=$(printf '%s\n' "$symref" \
      | awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  fi
  if [ -z "$branch" ]; then
    emit "$name check failed: cannot resolve the default branch of $remote in $repo"
    return 0
  fi

  remote_sha=$(git_probe "$repo" ls-remote "$remote" "refs/heads/$branch" 2>/dev/null)
  status=$?
  git_probe_answered "$status" "$name" "$remote" "where $branch points" || return 0
  if [ "$status" -ne 0 ]; then
    # The probe itself failed, so nothing at all is known about the branch. An
    # offline host and a deleted branch are different problems, and reporting a
    # missing branch here would name a cause that was never established.
    emit "$name check failed: $remote could not be reached or read from $repo"
    return 0
  fi
  remote_sha=$(printf '%s\n' "$remote_sha" | awk 'NR == 1 { print $1 }')
  if [ -z "$remote_sha" ]; then
    emit "$name check failed: $remote has no branch $branch"
    return 0
  fi

  # Each probe below is bounded, so a non-zero status means either the answer no
  # or no answer at all. They are kept apart: reading a bound that was hit as an
  # answer would report an update this check never established.
  local_sha=$(git_probe "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)
  git_probe_answered "$?" "$name" "$repo" "where $branch points" || return 0
  if [ -n "$local_sha" ]; then
    local_label="local $branch"
  else
    local_sha=$(git_probe "$repo" rev-parse --verify --quiet HEAD 2>/dev/null)
    git_probe_answered "$?" "$name" "$repo" "where HEAD points" || return 0
    if [ -z "$local_sha" ]; then
      emit "$name check failed: $repo has no commit to compare"
      return 0
    fi
    local_label='local HEAD'
  fi

  [ "$local_sha" != "$remote_sha" ] || return 0

  short=$(printf '%s' "$remote_sha" | cut -c1-12)

  git_probe "$repo" cat-file -e "$remote_sha^{commit}" 2>/dev/null
  status=$?
  git_probe_answered "$status" "$name" "$repo" "whether it already has $short" || return 0
  if [ "$status" -eq 0 ]; then
    # The local copy may be ahead of, or diverged from, the remote branch; only
    # commits it does not have yet are an available update.
    git_probe "$repo" merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null
    status=$?
    git_probe_answered "$status" "$name" "$repo" "how its history compares with $remote/$branch" || return 0
    [ "$status" -ne 0 ] || return 0
    count=$(git_probe "$repo" rev-list --count "$local_sha..$remote_sha" 2>/dev/null)
    git_probe_answered "$?" "$name" "$repo" "how many commits it is behind $remote/$branch" || return 0
    case "$count" in
      ''|*[!0-9]*|0) count= ;;
    esac
    if [ -n "$count" ]; then
      emit "$name update available: $local_label is $(commit_phrase "$count") behind $remote/$branch"
      return 0
    fi
  fi

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
  local line now source package

  [ -f "$CONFIG" ] || return 0

  record_read
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi

  DEADLINE=$(($(real_epoch) + BUDGET_SECS))

  if [ -n "$BUDGET_CUT_FROM" ]; then
    emit "sweep budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
  fi

  if ! config_validate; then
    emit "watched tool registry: $CONFIG_PROBLEM"
  else
    while IFS=$FIELD_SEP read -r name command_name args_joined announce announce_args repo remote branch source package; do
      [ -n "$name" ] || continue
      budget_allows "$name" || break
      COMMAND_VERSION=
      [ -z "$command_name" ] || command_findings "$name" "$command_name" "$args_joined" "$announce" "$announce_args"
      [ -z "$source" ] || published_findings "$name" "$source" "$package" "$COMMAND_VERSION"
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

  # The cut line is what gets printed, but the whole finding set is what decides
  # whether this is news, because a finding that lands past the cut leaves the
  # printed line unchanged and would otherwise be suppressed for good.
  #
  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  if [ -n "$line" ] && [ "$FINDINGS" != "$RECORD_REPORTED" ]; then
    printf '%s\n' "$line"
  fi
  # Only skipped work makes the sweep incomplete. The last issued probe can
  # finish after the deadline without leaving anything unchecked; keep that
  # complete result and cadence epoch so its finding is not reported again.
  if [ "$INCOMPLETE_REPORTED" -eq 0 ]; then
    record_write "$FINDINGS" || true
  fi
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-tool-update-check.sh - watched tool update poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-tool-update-check.sh") check"
}

# Write the shim the way this repo writes its other trusted check shim: the
# guards run before anything is written, so a symlink at the shim path is
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
  tmp=$(umask 077; mktemp "$STATE/.fm-tool-updates-check.XXXXXX" 2>/dev/null) || return 1
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
  tmp=$(umask 077; mktemp "$STATE/.fm-tool-updates-check.XXXXXX" 2>/dev/null) || return 1
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
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding. The shim a working home had is put back and kept only
# when it is still bound; otherwise the shim goes, so the home is plainly not
# armed and the failure is the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-tool-update-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -f "$CONFIG" ]; then
    printf 'fm-tool-update-check: no watched tool registry at %s\n' "$CONFIG" >&2
    return 1
  fi
  if ! config_validate || ! config_announce_patterns_usable; then
    printf 'fm-tool-update-check: %s (%s)\n' "$CONFIG_PROBLEM" "$CONFIG" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-tool-update-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-tool-update-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-tool-update-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-tool-update-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
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
