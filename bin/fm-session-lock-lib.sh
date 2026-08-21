#!/usr/bin/env bash
# Shared per-home session-lock identity.
#
# ONE owner of the state/.lock record and the decision whether the current
# verified-harness session owns it.
# A current record keeps its numeric pid on line one for compatible readers,
# then carries `harness=<name>` and, when the harness exposes one to both hooks
# and ordinary commands, `session=<identity>`.
# A legacy record containing only one numeric pid remains valid and uses the
# unchanged ancestry-membership decision.
#
# bin/fm-lock.sh owns acquisition and uses the helpers here to inspect, publish,
# and refresh the record.
# bin/fm-claude-stop-autoarm.sh uses the same predicate before arming or
# rewaking.
# Callers that can reach an identity-matched reparenting case must source
# fm-wake-lib.sh first so the PID refresh can share fm-lock.sh's acquisition
# lock and cannot overwrite a concurrent owner.
# This file has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
FM_HARNESS_MATCH_NAME=
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_MATCH_NAME=
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in
      *claude*) name=claude ;;
      *codex*) name=codex ;;
      *opencode*) name=opencode ;;
      *grok*) name=grok ;;
      *kimi*) name=kimi ;;
      pi-signed) name=pi-signed ;;
      pi) name=pi ;;
      *) return 1 ;;
    esac
    FM_HARNESS_MATCH_NAME=$name
    [ "$name" != claude ] || FM_HARNESS_IS_CLAUDE=1
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    FM_HARNESS_MATCH_NAME=$name
    [ "$name" != claude ] || FM_HARNESS_IS_CLAUDE=1
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        for name in "${FM_HARNESS_NAMES[@]}"; do
          case "$args" in
            *"$name"*)
              FM_HARNESS_MATCH_NAME=$name
              [ "$name" != claude ] || FM_HARNESS_IS_CLAUDE=1
              return 0
              ;;
          esac
        done
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  if fm_cursor_process_matches "$comm" "$args" "$argv0"; then
    FM_HARNESS_MATCH_NAME=cursor
    return 0
  fi
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# Print the canonical verified-harness name for pid $1, or return 1.
fm_harness_pid_name() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  [ -n "$FM_HARNESS_MATCH_NAME" ] || return 1
  printf '%s\n' "$FM_HARNESS_MATCH_NAME"
}

fm_session_harness_valid() {
  case "$1" in
    claude|codex|opencode|grok|kimi|pi|pi-signed|cursor) return 0 ;;
    *) return 1 ;;
  esac
}

fm_session_identity_valid() {
  local identity=$1
  [ -n "$identity" ] && [ "${#identity}" -le 160 ] || return 1
  case "$identity" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "$identity" != unknown ]
}

# Parse state/.lock into FM_SESSION_LOCK_PID, FM_SESSION_LOCK_HARNESS, and
# FM_SESSION_LOCK_IDENTITY.
# A single numeric line is the legacy format.
# Current records retain that numeric first line and accept only the two named
# metadata fields, each at most once.
FM_SESSION_LOCK_PID=
FM_SESSION_LOCK_HARNESS=
FM_SESSION_LOCK_IDENTITY=
fm_session_lock_read() {  # <state-dir>
  local state=$1 lock line line_no=0 seen_harness=0 seen_session=0
  FM_SESSION_LOCK_PID=
  FM_SESSION_LOCK_HARNESS=
  FM_SESSION_LOCK_IDENTITY=
  lock="$state/.lock"
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      case "$line" in ''|*[!0-9]*|1) return 1 ;; esac
      FM_SESSION_LOCK_PID=$line
      continue
    fi
    case "$line" in
      harness=*)
        [ "$seen_harness" -eq 0 ] || return 1
        FM_SESSION_LOCK_HARNESS=${line#harness=}
        fm_session_harness_valid "$FM_SESSION_LOCK_HARNESS" || return 1
        seen_harness=1
        ;;
      session=*)
        [ "$seen_session" -eq 0 ] || return 1
        FM_SESSION_LOCK_IDENTITY=${line#session=}
        fm_session_identity_valid "$FM_SESSION_LOCK_IDENTITY" || return 1
        seen_session=1
        ;;
      *) return 1 ;;
    esac
  done < "$lock"
  [ "$line_no" -gt 0 ] || return 1
  if [ "$line_no" -eq 1 ]; then
    return 0
  fi
  [ "$seen_harness" -eq 1 ] || return 1
  [ "$seen_session" -eq 0 ] || [ "$seen_harness" -eq 1 ]
}

fm_session_lock_pid() {  # <state-dir>
  fm_session_lock_read "$1" || return 1
  printf '%s\n' "$FM_SESSION_LOCK_PID"
}

# Print the pid a record names when that pid is a live harness process outside
# this session's own harness ancestry, EVEN IF the rest of the record does not
# parse.
# A first line that still names a usable pid names a candidate owner, so a
# reclaim decision can never treat such a record as ownerless; only a record that
# names no live foreign harness is genuinely unowned.
fm_session_lock_foreign_live_pid() {  # <state-dir>
  local state=$1 lock line='' pid pids ancestor
  lock="$state/.lock"
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  IFS= read -r line < "$lock" || true
  case "$line" in ''|*[!0-9]*|1) return 1 ;; esac
  pid=$line
  fm_harness_pid_alive "$pid" || return 1
  pids=$(fm_harness_ancestry_pids 2>/dev/null || true)
  while IFS= read -r ancestor; do
    [ "$ancestor" = "$pid" ] && return 1
  done <<EOF
$pids
EOF
  printf '%s\n' "$pid"
}

# True when <publisher-pid> - the harness process that published the ambient
# session identity - HOSTS this process from outside its own contiguous harness
# run.
#
# The bridged identity is exported into the publishing session's ordinary command
# environment, so every process it launches inherits it, including a nested
# session of the same harness whose own SessionStart bridge never ran. Such a
# session presents its host's identity AND its host's publisher pid, and that pid
# is reachable only by leaving this process's own contiguous run - which is
# exactly what this walk detects. A nested session that DID run its own bridge
# publishes its own session pid, finds it inside its own run, and keeps full
# identity ownership.
# The walk never stops at an unrelated harness in between: only the recorded
# publisher pid decides, so an intervening process of another harness cannot hide
# a same-harness host.
fm_session_identity_publisher_is_foreign_host() {  # <publisher-pid>
  local publisher=$1 pid=$$ comm args in_run=0 run_done=0
  case "$publisher" in ''|*[!0-9]*) return 1 ;; esac
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
    if [ "$pid" = "$publisher" ]; then
      [ "$run_done" -eq 1 ] || return 1
      return 0
    fi
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      in_run=1
      # Only Claude reports a multi-level contiguous run; every other harness
      # ends its own run at the first match, exactly as the ancestry walk does.
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || run_done=1
    elif [ "$in_run" -eq 1 ]; then
      run_done=1
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  return 1
}

# Print the stable identity an adapter has explicitly bridged to ordinary
# commands.
# Claude's SessionStart adapter persists the hook payload's session_id into the
# vendor-owned CLAUDE_ENV_FILE before fm-lock.sh runs, together with the pid of
# the harness process that published it.
# Other vendor session variables are deliberately not inferred here: an
# identifier that changes across an in-process reset would turn one owner into a
# false competitor.
# Provenance is REQUIRED, not advisory: an identity with no publisher pid, or one
# whose publisher hosts this process from outside its own harness run, is an
# inherited value rather than this session's own, so it is refused and the caller
# falls back to the ancestry decision, which can never reach across that gap.
fm_current_session_identity() {  # <actual-harness>
  local actual=$1 configured_harness=${FM_SESSION_HARNESS:-} identity=${FM_SESSION_ID:-}
  local publisher=${FM_SESSION_PUBLISHER_PID:-}
  [ -n "$configured_harness" ] || [ -n "$identity" ] || return 1
  [ "$configured_harness" = "$actual" ] || return 1
  fm_session_identity_valid "$identity" || return 1
  case "$publisher" in ''|*[!0-9]*|1) return 1 ;; esac
  fm_session_identity_publisher_is_foreign_host "$publisher" && return 1
  printf '%s\n' "$identity"
}

# Parse one JSON string field from a Claude-shaped hook payload without making
# session startup depend on jq.
# Hook payload identifiers are UUID-shaped ASCII in current Claude, and the
# validator below rejects escapes or arbitrary JSON text before use.
fm_session_identity_from_hook_payload() {  # <payload>
  local payload=$1 identity
  identity=$(printf '%s' "$payload" | awk '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == "session_id" { seen = 1 }
  ')
  fm_session_identity_valid "$identity" || return 1
  printf '%s\n' "$identity"
}

# Atomically publish a current record.
# The numeric first line is intentionally retained for readers outside this
# library that only need the owner pid.
fm_session_lock_write() {  # <state-dir> <pid> <harness> [<identity>]
  local state=$1 pid=$2 harness=$3 identity=${4:-} lock tmp
  case "$pid" in ''|*[!0-9]*|1) return 1 ;; esac
  fm_session_harness_valid "$harness" || return 1
  [ -z "$identity" ] || fm_session_identity_valid "$identity" || return 1
  lock="$state/.lock"
  tmp=$(mktemp "$state/.lock-write.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf '%s\n' "$pid"
    printf 'harness=%s\n' "$harness"
    [ -z "$identity" ] || printf 'session=%s\n' "$identity"
  } > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$lock" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Refresh a matching structured record while sharing fm-lock.sh's acquisition
# lock.
# The record is re-read after the claim, so a concurrent takeover can never be
# overwritten by an identity match observed before that takeover.
fm_session_lock_refresh_pid() {  # <state> <expected-pid> <harness> <identity> <new-pid>
  local state=$1 expected_pid=$2 harness=$3 identity=$4 new_pid=$5 claim acquired=0 held_pid
  command -v fm_lock_try_acquire >/dev/null 2>&1 || return 1
  claim="$state/.lock.acquire"
  held_pid=$(cat "$claim/pid" 2>/dev/null || true)
  if [ "$held_pid" != "${BASHPID:-$$}" ]; then
    fm_lock_try_acquire "$claim" || return 1
    acquired=1
  fi
  if ! fm_session_lock_read "$state" \
    || [ "$FM_SESSION_LOCK_PID" != "$expected_pid" ] \
    || [ "$FM_SESSION_LOCK_HARNESS" != "$harness" ] \
    || [ "$FM_SESSION_LOCK_IDENTITY" != "$identity" ] \
    || ! fm_session_lock_write "$state" "$new_pid" "$harness" "$identity"; then
    [ "$acquired" -eq 0 ] || fm_lock_release "$claim"
    return 1
  fi
  [ "$acquired" -eq 0 ] || fm_lock_release "$claim"
  return 0
}

# True when the current verified-harness session owns state dir $1.
#
# Current records use stable identity first:
#   - matching harness and session identity owns the lock regardless of ancestry;
#   - a matching identity with a changed live pid is a reparented session, so the
#     pid is refreshed under the acquisition lock before success.
# Every other case, including differing identities, then falls back to the legacy
# ancestry-membership decision byte-for-byte: the recorded pid must appear in the
# current contiguous harness ancestry. That fallback is what keeps an in-process
# re-identification - Claude routes /clear and /compact through their own
# SessionStart, which re-publishes a session_id that is not proven stable across
# the reset - from turning the one live owner into its own competitor, while a
# genuinely competing live session is still refused because its pid is not in
# this ancestry.
# That fallback is READ-ONLY here. Run membership is a weaker proof than an
# identity match, so it never rewrites the record: republishing a re-identified
# owner belongs to the single acquisition owner, bin/fm-lock.sh, under the
# acquisition lock and after its own authoritative ownership confirmation.
# A dead recorded pid is never identity-refreshed and remains the existing stale
# owner recovery case handled by fm-lock.sh.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid lock_harness lock_identity pids pid current_pid='' current_harness current_identity='' recorded_harness
  fm_session_lock_read "$state" || return 1
  lock_pid=$FM_SESSION_LOCK_PID
  lock_harness=$FM_SESSION_LOCK_HARNESS
  lock_identity=$FM_SESSION_LOCK_IDENTITY
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && current_pid=$pid
  done <<EOF
$pids
EOF
  [ -n "$current_pid" ] || return 1
  current_harness=$(fm_harness_pid_name "$current_pid") || return 1
  current_identity=$(fm_current_session_identity "$current_harness" 2>/dev/null || true)

  if [ -n "$lock_identity" ] && [ -n "$current_identity" ] \
    && [ "$lock_harness" = "$current_harness" ] && [ "$lock_identity" = "$current_identity" ]; then
    # Identity cannot revive a dead record; stale-owner recovery keeps its
    # existing single acquisition owner in fm-lock.sh.
    if fm_harness_pid_alive "$lock_pid" \
      && recorded_harness=$(fm_harness_pid_name "$lock_pid") \
      && [ "$recorded_harness" = "$lock_harness" ]; then
      if [ "$lock_pid" = "$current_pid" ] \
        || fm_session_lock_refresh_pid "$state" "$lock_pid" "$lock_harness" "$lock_identity" "$current_pid"; then
        return 0
      fi
    fi
  fi

  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
