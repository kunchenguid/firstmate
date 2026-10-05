# shellcheck shell=bash
# Opt-in dispatch-resolve question/answer log.
# Usage: . bin/fm-dispatch-log-lib.sh
#
# This file is the single owner of where bin/fm-dispatch-resolve.sh may write
# the durable record of one Jev request and its answer, and of the two
# invariants that record holds: it can never carry the API key, and it can
# never land inside a repository.
#
# OFF BY DEFAULT AND INERT. Every helper here is a no-op for a caller that
# passes an empty setting, so an operator who never opts in gets no file, no
# directory, and no new failure mode. bin/fm-dispatch-resolve.sh already keeps
# its decisions and its stdout shape independent of this file: a refusal or a
# failed write costs the log only.
#
# UNDER THE HOME, NEVER IN A REPOSITORY. The setting names a directory; a
# relative value is anchored under $FM_HOME and an absolute value is taken as
# given. A resolved directory must sit under $FM_HOME/state or $FM_HOME/data,
# which are the home's two gitignored durable-state paths, and the deepest path
# that already exists is re-checked in its physical form. Two things are refused
# and nothing is created first: a target whose physical location escapes the
# home (a symlinked state path), and a target with a git work tree at or below
# it before the home is reached. The second guard exists because fm-hooks shipped
# the matching defect: a tool's own state resolved against process.cwd(), so a
# run inside a product repository wrote an untracked state directory into it and
# any consumer requiring a clean tree then refused to work there. A git
# directory below the home is a project clone, so refusing it keeps this record
# out of product diffs. The home's own checkout is never a destination either:
# $FM_HOME itself, and anything outside state/ or data/, is refused, which is
# what keeps a record from arriving as an untracked file in the home's diff.
# Because the directory is created only after every check has passed, a refused
# setting leaves no directory behind in a clone, a repository, or anywhere else,
# and a refusal costs the log only: the caller's decisions, output, and exit
# status are identical either way.
#
# NO KEY MATERIAL, BY CONSTRUCTION AND THEN BY ENFORCEMENT. A record is built
# from the request body, the response document, and the rendered output; the
# key lives in one caller shell variable that reaches no builder here. On top of
# that, fm_dispatch_log_write redacts every literal occurrence of the key from
# the bytes it is about to write, so the guarantee survives a future field that
# copies something it should not. Redaction is a literal substitution, not a
# pattern one, so a key containing glob characters is still matched exactly.
#
# CONCURRENT WRITERS. Each record lands by rename from a private mktemp file in
# the destination directory, so several overlapping intakes cannot interleave or
# clobber each other: the name is unique per run and a rename onto a fresh path
# is atomic. The mktemp file is owner-only, so a record is never briefly
# world-readable between creation and rename.
#
# fm-hooks INDEX LINE. fm-hooks records that a `fm-dispatch-resolve.sh` call
# happened but deliberately drops result payloads, so fm_dispatch_log_hooks_index
# appends ONE pointer line naming this record instead of widening that capture.
# It is best-effort by design: it writes only into a queue fm-hooks has already
# created, it never creates one, and any failure is discarded, because the index
# is a convenience over the record rather than a second copy of it. Queue
# resolution mirrors fm-hooks' own src/paths.js as the owner of that layout
# (FM_HOOK_QUEUE, then FM_HOOK_STATE_DIR/queue, then the home convention), and
# an FM_HOOK_QUEUE the operator has pointed elsewhere is honoured as given.
set -u

# fm_dispatch_log_timestamp
# UTC RFC 3339 to the second; the one time format every record uses, so a log
# written across machines still sorts and still names its own moment.
fm_dispatch_log_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _fm_dispatch_log_normalize <absolute-path>
# Collapse ".", "..", and repeated separators textually, so a guard comparison
# cannot be walked around with "$FM_HOME/state/../../elsewhere". Purely
# lexical: symlinks are handled by the physical re-check in fm_dispatch_log_dir.
_fm_dispatch_log_normalize() {
  local path=$1 out='' part
  local -a parts=()
  IFS=/ read -r -a parts <<<"$path"
  for part in "${parts[@]}"; do
    case $part in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out=$out/$part ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# _fm_dispatch_log_absolute <path> <fallback-base>
# Make a path absolute using the base when it is not already, then normalize.
_fm_dispatch_log_absolute() {
  local path=$1 base=$2
  case $path in
    /*) ;;
    *) path=$base/$path ;;
  esac
  _fm_dispatch_log_normalize "$path"
}

# _fm_dispatch_log_under <path> <parent>
# True when path is parent itself or a descendant of it.
_fm_dispatch_log_under() {
  local path=$1 parent=$2
  [ "$path" = "$parent" ] && return 0
  case $path in
    "$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _fm_dispatch_log_repo_below <physical-dir> <physical-stop>
# True when a git work tree sits at or below physical-dir before physical-stop
# is reached. Stopping at the home is what distinguishes the home's own
# checkout, whose state and data paths are gitignored, from a project clone.
_fm_dispatch_log_repo_below() {
  local path=$1 stop=$2
  while [ -n "$path" ] && [ "$path" != "$stop" ] && [ "$path" != / ]; do
    [ -e "$path/.git" ] && return 0
    path=$(dirname -- "$path")
  done
  return 1
}

# fm_dispatch_log_abs <path> <fallback-base>
# Absolute, lexically normalized form of <path>, for a record that must stay
# readable after the directory it was written from is gone.
fm_dispatch_log_abs() {
  _fm_dispatch_log_absolute "$1" "$2"
}

# fm_dispatch_log_dir <fm-home> <setting>
# Print ONE line describing the outcome, because a caller's command substitution
# runs in a subshell and cannot carry a variable back out of it:
#   ok<TAB><physical-directory>   the setting was accepted; the directory exists
#   refused<TAB><reason>          the setting was rejected; nothing was created
# Exits 0 on the ok path and 1 on the refused path. The directory is created
# only on the ok path, after every check, so a refusal leaves no directory
# behind anywhere. An empty setting is the ordinary off path and is refused
# with that as its reason.
fm_dispatch_log_dir() {
  local home=$1 setting=$2 dir home_real probe probe_real dir_real
  [ -n "$setting" ] || {
    printf 'refused\t%s\n' 'FM_DISPATCH_RESOLVE_LOG is not set'
    return 1
  }
  home=$(_fm_dispatch_log_absolute "$home" "$PWD")
  dir=$(_fm_dispatch_log_absolute "$setting" "$home")
  case $dir in
    "$home"/state/*|"$home"/data/*) ;;
    *)
      printf 'refused\t%s\n' "$dir is not under $home/state or $home/data"
      return 1
      ;;
  esac
  home_real=$(cd -- "$home" 2>/dev/null && pwd -P) || home_real=$home
  # The deepest existing ancestor is the only place a clone root or a symlink
  # could be hiding: no component below it exists yet, so nothing is created
  # before the refusal and nothing new can appear between the check and the
  # mkdir that follows it.
  probe=$dir
  while [ -n "$probe" ] && [ "$probe" != / ] && [ ! -d "$probe" ]; do
    probe=$(dirname -- "$probe")
  done
  probe_real=$(cd -- "$probe" 2>/dev/null && pwd -P) || probe_real=$probe
  if ! _fm_dispatch_log_under "$probe_real" "$home_real"; then
    printf 'refused\t%s\n' "$dir resolves to $probe_real, outside $home_real"
    return 1
  fi
  if _fm_dispatch_log_repo_below "$probe_real" "$home_real"; then
    printf 'refused\t%s\n' "$dir is inside a git work tree below $home_real"
    return 1
  fi
  ( umask 077; mkdir -p -- "$dir" ) 2>/dev/null || {
    printf 'refused\t%s\n' "$dir could not be created"
    return 1
  }
  dir_real=$(cd -- "$dir" 2>/dev/null && pwd -P) || {
    printf 'refused\t%s\n' "$dir could not be resolved"
    return 1
  }
  if ! _fm_dispatch_log_under "$dir_real" "$home_real" || [ "$dir_real" = "$home_real" ]; then
    printf 'refused\t%s\n' "$dir resolves to $dir_real, outside $home_real"
    return 1
  fi
  printf 'ok\t%s\n' "$dir_real"
  return 0
}

# fm_dispatch_log_write <directory> <name> <secret>   (JSON body on stdin)
# Redact any literal occurrence of <secret>, write the body to a private
# temporary file beside its destination, and rename it into place as <name>.
# Print the written path, or print nothing and return 1. The caller owns the
# decision to log; a failure here is reported and otherwise ignored.
fm_dispatch_log_write() {
  local directory=$1 name=$2 secret=$3 body tmp target
  body=$(cat)
  if [ -n "$secret" ]; then
    body=${body//"$secret"/[redacted]}
  fi
  [ -d "$directory" ] || return 1
  tmp=$(mktemp "$directory/.dispatch-resolve.XXXXXX") || return 1
  if ! printf '%s\n' "$body" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 -- "$tmp" 2>/dev/null || true
  target=$directory/$name
  if ! mv -f -- "$tmp" "$target" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s' "$target"
  return 0
}

# fm_dispatch_log_hooks_queue <fm-home>
# Print the fm-hooks queue directory this home's observer would use, following
# fm-hooks' own precedence: FM_HOOK_QUEUE, then FM_HOOK_STATE_DIR/queue, then
# $FM_HOME/state/fm-hooks/queue. Callers must treat it as a hint and check that
# fm-hooks has actually created it.
fm_dispatch_log_hooks_queue() {
  local home=$1 base=${HOME:-}
  if [ -n "${FM_HOOK_QUEUE:-}" ]; then
    case $FM_HOOK_QUEUE in
      /*) printf '%s' "$FM_HOOK_QUEUE" ;;
      *) printf '%s/%s' "$base" "$FM_HOOK_QUEUE" ;;
    esac
    return 0
  fi
  if [ -n "${FM_HOOK_STATE_DIR:-}" ]; then
    case $FM_HOOK_STATE_DIR in
      /*) printf '%s/queue' "$FM_HOOK_STATE_DIR" ;;
      *) printf '%s/%s/queue' "$base" "$FM_HOOK_STATE_DIR" ;;
    esac
    return 0
  fi
  printf '%s/state/fm-hooks/queue' "$home"
}

# fm_dispatch_log_hooks_index <fm-home> <operation> <correlation-id> <record-path>
# Append ONE fm-hooks event naming the record, so a call fm-hooks already saw
# can be joined to what it asked and what came back. Never creates a queue,
# never writes into a git work tree, never fails the caller, and never carries
# more than the pointer: the record stays the single copy of the payload.
fm_dispatch_log_hooks_index() {
  local home=$1 operation=$2 correlation=$3 record=$4
  local queue home_real queue_real line
  queue=$(fm_dispatch_log_hooks_queue "$home") || return 0
  [ -n "$queue" ] && [ -d "$queue" ] && [ -f "$queue/events.jsonl" ] || return 0
  home_real=$(cd -- "$home" 2>/dev/null && pwd -P) || home_real=$home
  queue_real=$(cd -- "$queue" 2>/dev/null && pwd -P) || return 0
  if _fm_dispatch_log_under "$queue_real" "$home_real"; then
    _fm_dispatch_log_repo_below "$queue_real" "$home_real" && return 0
  else
    _fm_dispatch_log_repo_below "$queue_real" / && return 0
  fi
  command -v jq >/dev/null 2>&1 || return 0
  line=$(jq -cn --arg operation "$operation" --arg correlation "$correlation" \
    --arg record "$record" --arg at "$(fm_dispatch_log_timestamp)" \
    '{type: "artifact", operation: $operation, correlationId: $correlation,
      artifact: {kind: "dispatch-resolve-log", path: $record}, loggedAt: $at}' 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >>"$queue_real/events.jsonl" 2>/dev/null || return 0
  return 0
}
