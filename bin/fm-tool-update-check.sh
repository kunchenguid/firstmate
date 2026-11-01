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
# A tool that announces its own update is only reported as "update available"
# when the version it announces is newer than the newest installed copy found;
# a version already installed is reported only as "update not in effect".
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
# For tools without CLI update announcements, see `version_url` in
# docs/configuration.md's "Watched tool updates" section.
#
# Probing costs real time, so `check` runs its probes at most once per
# FM_TOOL_UPDATE_INTERVAL (default 900, 0 disables the gate, otherwise 60..86400)
# and stays silent in between. Each probe is bounded by
# FM_TOOL_UPDATE_PROBE_SECS (default 5, valid 1..30) and a whole sweep by
# FM_TOOL_UPDATE_BUDGET_SECS (default 20, valid 1..120).
#
# Running out of either is never reported as a failed tool. A probe that overruns
# its own bound is reported as timed out. A probe whose bound the sweep budget
# had already cut, and a tool the sweep never reached, are reported as not
# checked, because that is the check's own scheduling and says nothing about the
# tool.
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
# end, and it carries the whole finding set that sweep found, one finding per
# line. Only findings missing from the recorded set are news and are reported, so
# the same pending update is reported once, a finding leaving the set announces
# nothing, and a finding that leaves and later returns is news again. A sweep
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
RECORD_SCHEMA=fm-tool-updates-v2
# The earlier record carried the whole finding set as one "; " joined line, and
# is still read so an upgrade does not announce every pending finding again.
RECORD_SCHEMA_V1=fm-tool-updates-v1
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

FINDINGS=()
DEADLINE=0

# Each finding is flattened to a single line here, because the whole report must
# stay one line for the wake record and the record holds one finding per line.
emit() {
  FINDINGS+=("$(printf '%s' "$1" | tr '\t\r\n' '   ')")
}

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
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

# Last dotted number in the text: an announcement phrase like "v1.46.0 ->
# v1.47.0" names the current version first and the announced version last.
parse_announced_version() {
  printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | tail -n 1
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
      elif ($t | has("version_url")) and (($t.version_url | type) != "string" or ($t.version_url | test("^https://[^[:space:][:cntrl:]]+$") | not)) then "tool \($t.name) version_url must be one https URL"
      elif ($t | has("version_url")) and (($t | has("command")) | not) then "tool \($t.name) version_url needs command"
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
      (.git.branch // ""),
      (.version_url // "")
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

# Ask one copy for its own version under the given bound. Combined output,
# because tools answer on either stream, and no-mistakes announces its update on
# stderr. The caller takes the bound from probe_bound, so it can still tell which
# of the two budgets a timeout used up.
probe_output() {
  local bound=$1 path=$2
  shift 2
  fm_run_timed "$bound" "$path" "$@" 2>&1
}

# Report a probe that ran out of time. A full probe bound is the tool's own time
# and is reported as timed out; a bound the sweep budget had cut is the sweep's
# own time, so the tool is reported as not checked rather than blamed.
emit_probe_timeout() {
  local name=$1 bound=$2 path=$3 question=$4
  if [ "$bound" -lt "$PROBE_SECS" ]; then
    emit "$name not checked: the sweep time budget ran out while $path was asked $question"
  else
    emit "$name timed out: $path did not answer within ${bound}s when asked $question"
  fi
}

command_findings() {
  local name=$1 command_name=$2 args_joined=$3 announce=$4 announce_args=$5 version_url=${6:-}
  local hit out version matched announce_out status matched_line announced_version published bound
  local resolved_path='' resolved_version='' resolved_out='' resolved_timed_out=''
  local best_path='' best_version='' unreadable='' hits=''

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
      emit "$name not checked: the sweep time budget ran out before every copy answered"
      break
    fi
    bound=$(probe_bound)
    # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
    out=$(probe_output "$bound" "$hit" $args_joined)
    status=$?
    version=$(parse_version "$out")
    if [ -z "$resolved_path" ]; then
      resolved_path=$hit
      resolved_version=$version
      resolved_out=$out
    fi
    if [ -z "$version" ]; then
      # A copy that ran out of time never had the chance to report a version.
      if fm_timed_out "$status"; then
        emit_probe_timeout "$name" "$bound" "$hit" "for its version"
        [ "$resolved_path" != "$hit" ] || resolved_timed_out=1
      else
        [ -n "$unreadable" ] || unreadable=$hit
      fi
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
        emit "$name not checked: the sweep time budget ran out before the update announcement was checked"
        announce_out=
      else
        bound=$(probe_bound)
        # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
        announce_out=$(probe_output "$bound" "$resolved_path" $announce_args)
        status=$?
        if fm_timed_out "$status"; then
          # A source that was asked and never answered is not a source that had
          # nothing to say. The one that answers with nothing stays silent below.
          emit_probe_timeout "$name" "$bound" "$resolved_path" "for its update announcement"
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
        matched_line=$(printf '%s\n' "$matched" | head -n 1)
        announced_version=$(parse_announced_version "$matched_line")
        # An announcement naming no readable version is reported as today; one
        # naming a version already installed is not an available update.
        if [ -z "$announced_version" ] || [ -z "$best_version" ] \
          || version_newer "$announced_version" "$best_version"; then
          emit "$name update available: $matched_line"
        fi
      fi
    fi
  fi

  if [ -z "$resolved_version" ]; then
    # No copy was probed at all when the path is empty, and the budget report
    # already covers that, so do not blame a copy that was never asked. A copy
    # that ran out of time was already reported as such.
    [ -z "$resolved_path" ] || [ -n "$resolved_timed_out" ] \
      || emit "$name check failed: $resolved_path did not report a version"
    return 0
  fi

  if [ -n "$version_url" ]; then
    # The published version is read from the document body, never from the URL,
    # and compared with the newest installed copy found: a newer install elsewhere
    # on PATH is the "not in effect" finding below, not an available update.
    if budget_exhausted; then
      emit "$name not checked: the sweep time budget ran out before $version_url was read"
    elif ! command -v curl >/dev/null 2>&1; then
      emit "$name check failed: curl is required to read $version_url"
    else
      bound=$(probe_bound)
      out=$(fm_run_timed "$bound" curl -fsS --max-time "$bound" -- "$version_url" 2>/dev/null)
      status=$?
      published=$(parse_version "$out")
      # curl reports its own --max-time with status 28.
      if fm_timed_out "$status" || [ "$status" -eq 28 ]; then
        emit_probe_timeout "$name" "$bound" "$version_url" "for its published version"
      elif [ "$status" -ne 0 ] || [ -z "$published" ]; then
        emit "$name check failed: $version_url did not report a version"
      elif version_newer "$published" "$best_version"; then
        emit "$name update available: $published published at $version_url, PATH resolves $resolved_version"
      fi
    fi
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

# A probe the sweep budget can no longer afford is never issued, and one whose
# bound the sweep budget had cut and that then ran out of time is the sweep's
# doing too. Both say so with a status of their own rather than a git status, so
# no caller can read it as an answer or blame the repository. Neither git nor the
# bounded runner uses this value.
GIT_PROBE_BUDGET_GONE=3

# One bounded read-only git probe. The budget check lives here rather than in the
# callers, so no probe can be issued past the sweep deadline whatever a caller
# does, and the budget only has to leave room for the one probe that was already
# running when the deadline passed.
git_probe() {
  local repo=$1 bound status
  shift
  budget_exhausted && return "$GIT_PROBE_BUDGET_GONE"
  bound=$(probe_bound)
  fm_run_timed "$bound" git -C "$repo" "$@"
  status=$?
  if fm_timed_out "$status" && [ "$bound" -lt "$PROBE_SECS" ]; then
    return "$GIT_PROBE_BUDGET_GONE"
  fi
  return "$status"
}

# The single place that reads a probe status as no answer at all, so every probe
# reports an unanswered read the same way instead of taking it for the answer no.
git_probe_answered() {
  local status=$1 name=$2 subject=$3 question=$4
  if [ "$status" = "$GIT_PROBE_BUDGET_GONE" ]; then
    emit "$name not checked: the sweep time budget ran out before $subject answered $question"
    return 1
  fi
  if fm_timed_out "$status"; then
    emit "$name timed out: $subject did not answer $question within ${PROBE_SECS}s"
    return 1
  fi
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
# The recorded finding set, one finding per line.
RECORD_FOUND=

record_read() {
  local line first=1 schema='' nl=$'\n'
  RECORD_EPOCH=0
  RECORD_FOUND=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      case "$line" in
        "$RECORD_SCHEMA"|"$RECORD_SCHEMA_V1") schema=$line ;;
        *) return 0 ;;
      esac
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
      found=*)
        [ "$schema" = "$RECORD_SCHEMA" ] || continue
        RECORD_FOUND="$RECORD_FOUND${line#found=}$nl"
        ;;
      reported=*)
        [ "$schema" = "$RECORD_SCHEMA_V1" ] || continue
        line=${line#reported=}
        [ -z "$line" ] || RECORD_FOUND="${line//; /$nl}$nl"
        ;;
    esac
  done < "$RECORD"
  return 0
}

# True when the finding is in the recorded set.
record_has() {
  case $'\n'"$RECORD_FOUND" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

record_write() {
  local tmp finding
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    for finding in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
      printf 'found=%s\n' "$finding"
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- actions ----------------------------------------------------------------

action_check() {
  local name command_name args_joined announce announce_args repo remote branch version_url
  local line now finding news=''

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
    while IFS=$FIELD_SEP read -r name command_name args_joined announce announce_args repo remote branch version_url; do
      [ -n "$name" ] || continue
      # A tool the sweep never reached was not asked anything, so it is named as
      # not checked rather than reported as failing or read as current.
      if budget_exhausted; then
        emit "$name not checked: the sweep time budget ran out before it was reached"
        continue
      fi
      [ -z "$command_name" ] || command_findings "$name" "$command_name" "$args_joined" "$announce" "$announce_args" "$version_url"
      [ -z "$repo" ] || git_findings "$name" "$repo" "$remote" "$branch"
    done < <(config_records)
  fi

  # Only a finding the recorded set does not hold is news. Comparing the sets
  # rather than the whole report keeps a finding that leaves the set from
  # announcing the ones that remain again.
  for finding in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
    record_has "$finding" && continue
    news="${news:+$news; }$finding"
  done

  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one. Capped through the shared cut so an over-long
  # report carries the same visible truncation marker the digests use, instead
  # of ending mid-finding as if that were all of it.
  if [ -n "$news" ]; then
    fm_cap_line_var "tool updates: $news" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
    printf '%s\n' "$line"
  fi
  record_write || true
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
