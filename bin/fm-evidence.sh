#!/usr/bin/env bash
# fm-evidence.sh - custodian write-through for expensive-to-reproduce task
# evidence.
#
# A task's surviving artifact directory, data/<task-id>/, already outlives
# cleanup on this machine. That is custody against a crash, not against a lost
# machine or a lost handoff: loose output a successor does not remember
# producing carries no provenance. This script copies that directory into a
# separate evidence repository, where real git history supplies the provenance
# and a real remote supplies off-machine durability.
#
# OPT-IN AND LOCAL. The destination is named only by the gitignored
# config/evidence-repo file in the effective firstmate home. With that file
# absent, every verb here is a silent no-op and teardown behaves exactly as it
# does today, so nothing about a repository is ever written into shared tracked
# material or into a generated brief.
#
# FIRSTMATE IS THE CUSTODIAN. Firstmate runs this at teardown. A crewmate never
# does, and no scout path ever pushes to any remote.
#
# THE LOCAL COMMIT IS THE CUSTODY GUARANTEE; THE PUSH IS BEST-EFFORT. `preserve`
# fails only when the commit fails, so its caller gates cleanup on committed
# evidence and never on a reachable network. An unreachable remote leaves the
# evidence committed locally and still reports success. Do not "tidy" that
# asymmetry into a single success path: gating cleanup on the push would make
# preserving evidence and reclaiming a worktree block each other, which is the
# deadlock this split exists to prevent.
#
# NO REDACTION, WHILE THE DESTINATION IS PRIVATE. Artifacts are copied verbatim.
# That is safe only because the destination repository is private, so the push
# verifies visibility first and REFUSES to publish into a repository that is not
# private. If visibility cannot be determined at all - offline, no gh-axi, an
# unrecognized remote - the push is skipped rather than risked, and the evidence
# stays committed locally. The day that repository stops being private, pushes
# stop and say why.
#
# LAYOUT: <evidence-repo>/<home-tag>/<task-id>/. The home tag identifies the
# firstmate home, so concurrent tasks in different homes - two secondmates, or
# two homes that both use the task id "fix-auth" - never collide. The path is
# derivable from the task alone; `path` prints it, and there is deliberately no
# registry to consult.
#
# SIZE POLICY: an artifact at or below FM_EVIDENCE_MAX_DIRECT_BYTES is committed
# whole. Anything larger is recorded in the manifest by size and SHA-256 only,
# never by content, so a corpus that reaches tens of GB is described rather than
# committed. Every artifact is listed in the manifest either way.
#
# Usage:
#   fm-evidence.sh preserve <task-id>   copy, commit, then best-effort push
#   fm-evidence.sh path <task-id>       print the destination path and exit
#
# Exit codes: 0 custody achieved, nothing to preserve, or disabled; 1 usage or
# configuration error; 2 the copy or commit failed, so custody was NOT achieved
# and the caller must not destroy the source.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_EVIDENCE_SECONDMATE_MARKER=".fm-secondmate-home"

# The home segment of the layout. This deliberately keys on FM_HOME rather than
# reusing fm-backend-hometag-lib.sh, which hashes FM_ROOT: that library
# discriminates INSTALLATIONS sharing one backend namespace, but FM_HOME exists
# precisely so several homes can share one tracked code root, and those homes
# must not write into each other's evidence path. The readable prefix follows
# the same convention so a path is recognizable on sight.
evidence_home_tag() {
  local marker="$FM_HOME/$FM_EVIDENCE_SECONDMATE_MARKER" id prefix home hash
  prefix=firstmate
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    [ -n "$id" ] && prefix="2ndmate-$id"
  fi
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || home=$FM_HOME
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$home" | shasum -a 256 | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$home" | sha256sum | awk '{print substr($1,1,8)}')
  fi
  printf '%s-%s\n' "$prefix" "$hash"
}

# The size boundary between a committed artifact and a manifest-only record, as
# a named constant rather than a judgement made at each call site. 64 MiB keeps
# the 776 KB measurement results this exists for well inside direct commit while
# keeping a corpus out of git history. config/evidence-max-direct-bytes
# overrides it for a home with different material.
FM_EVIDENCE_MAX_DIRECT_BYTES_DEFAULT=67108864

FM_EVIDENCE_MANIFEST="EVIDENCE-MANIFEST.txt"

CUSTODY_FAILED=2
# Reserved internal return meaning "this home has not opted in", kept distinct
# from every real failure so the two can never be confused.
NOT_CONFIGURED=3

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {  # <exit-code> <message>
  local code=$1
  shift
  printf 'fm-evidence: %s\n' "$*" >&2
  exit "$code"
}

note() {
  printf 'fm-evidence: %s\n' "$*"
}

read_config() {  # <name>
  local file="$CONFIG/$1" value
  [ -f "$file" ] || return 1
  value=$(tr -d '\r' < "$file" | sed -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -1)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# The configured destination.
#
# Callers read this through a command substitution, which runs it in a subshell,
# so it must REPORT rather than exit: an `exit` here would only leave the
# subshell and the caller would read the failure as "not configured". That
# distinction is the whole safety property - a configured-but-unusable
# destination has to be a loud error, never a silent fallback to disabled, which
# would discard evidence exactly when the operator believed it was being kept.
# Hence two separate non-zero returns, and diagnostics on stderr.
resolve_evidence_repo() {
  local configured resolved
  configured=$(read_config evidence-repo) || return "$NOT_CONFIGURED"
  case "$configured" in
    /*) : ;;
    *) printf 'fm-evidence: config/evidence-repo must be an absolute path, got: %s\n' "$configured" >&2
       return 1 ;;
  esac
  if [ ! -d "$configured" ]; then
    printf 'fm-evidence: config/evidence-repo names no directory: %s\n' "$configured" >&2
    return 1
  fi
  if ! resolved=$(cd "$configured" && pwd -P); then
    printf 'fm-evidence: cannot resolve config/evidence-repo: %s\n' "$configured" >&2
    return 1
  fi
  if ! git -C "$resolved" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'fm-evidence: config/evidence-repo is not a git repository: %s\n' "$resolved" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

max_direct_bytes() {
  local configured
  if configured=$(read_config evidence-max-direct-bytes); then
    case "$configured" in
      ''|*[!0-9]*) fail 1 "config/evidence-max-direct-bytes must be a whole number of bytes, got: $configured" ;;
      *) printf '%s\n' "$configured"; return 0 ;;
    esac
  fi
  printf '%s\n' "$FM_EVIDENCE_MAX_DIRECT_BYTES_DEFAULT"
}

file_size() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %z "$1"
  else
    stat -c %s "$1"
  fi
}

file_sha256() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'unavailable\n'
  fi
}

# owner/name from the destination clone's remote, for the visibility check.
# Handles the ssh://, scp-like, and https:// forms, including the host alias
# form (github.com-personal) that a multi-account setup requires and that must
# survive verbatim, since rewriting it to a plain host breaks the identity the
# clone authenticates with.
# The last two path segments are the owner and name. A host path that is deeper
# than that (a nested group on another forge) simply yields a slug the GitHub
# lookup will not resolve, which skips the push rather than guessing.
# The remote this destination publishes to: origin when present, otherwise the
# only one configured. Whatever URL it carries is used verbatim, never rewritten.
evidence_remote() {  # <repo>
  local repo=$1 remote
  remote=$(git -C "$repo" remote 2>/dev/null | grep -Fx origin || git -C "$repo" remote 2>/dev/null | head -1)
  [ -n "$remote" ] || return 1
  printf '%s\n' "$remote"
}

remote_owner_name() {  # <repo>
  local repo=$1 remote url path owner name
  remote=$(evidence_remote "$repo") || return 1
  url=$(git -C "$repo" remote get-url "$remote" 2>/dev/null) || return 1
  case "$url" in
    *://*) path=${url#*://}; path=${path#*@}; path=${path#*/} ;;
    *:*) path=${url#*:} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  path=${path%/}
  case "$path" in
    */*) : ;;
    *) return 1 ;;
  esac
  name=${path##*/}
  owner=${path%/*}
  owner=${owner##*/}
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  printf '%s/%s\n' "$owner" "$name"
}

# Prints "private", "public", or returns non-zero when visibility cannot be
# established. Only a confirmed "private" authorizes a push.
remote_visibility() {  # <repo>
  local repo=$1 slug view
  command -v gh-axi >/dev/null 2>&1 || return 1
  slug=$(remote_owner_name "$repo") || return 1
  view=$(gh-axi repo view --repo "$slug" 2>/dev/null) || return 1
  printf '%s\n' "$view" \
    | awk -F: '/^[[:space:]]*visibility:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' \
    | grep -q . || return 1
  printf '%s\n' "$view" \
    | awk -F: '/^[[:space:]]*visibility:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}'
}

destination_path() {  # <repo> <task-id>
  printf '%s/%s/%s\n' "$1" "$(evidence_home_tag)" "$2"
}

validate_task_id() {  # <task-id>
  case "$1" in
    ''|*/*|.|..|-*) fail 1 "invalid task id: ${1:-<empty>}" ;;
  esac
}

# Copy every artifact under <source> into <dest>, splitting on the size
# boundary, and write the manifest that describes all of them. Echoes the
# number of artifacts recorded.
copy_artifacts() {  # <source> <dest> <task-id> <limit>
  local source=$1 dest=$2 id=$3 limit=$4
  local rel size hash mode count=0 manifest="$dest/$FM_EVIDENCE_MANIFEST"

  {
    printf '# firstmate evidence manifest\n'
    printf '# task: %s\n' "$id"
    printf '# home: %s\n' "$(evidence_home_tag)"
    printf '# direct-commit limit: %s bytes\n' "$limit"
    printf '# columns: disposition sha256 bytes path\n'
  } > "$manifest"

  while IFS= read -r file; do
    rel=${file#"$source"/}
    [ "$rel" = "$FM_EVIDENCE_MANIFEST" ] && continue
    size=$(file_size "$file")
    hash=$(file_sha256 "$file")
    if [ "$size" -le "$limit" ]; then
      mode=committed
      mkdir -p "$dest/$(dirname "$rel")"
      cp -p "$file" "$dest/$rel"
    else
      # Corpus scale: described by size and hash, never carried as content.
      mode='manifest-only'
    fi
    printf '%s %s %s %s\n' "$mode" "$hash" "$size" "$rel" >> "$manifest"
    count=$((count + 1))
  done <<EOF
$(find "$source" -type f | LC_ALL=C sort)
EOF

  printf '%s\n' "$count"
}

cmd_path() {  # <task-id>
  local id=$1 repo rc=0
  validate_task_id "$id"
  repo=$(resolve_evidence_repo) || rc=$?
  case "$rc" in
    0) : ;;
    "$NOT_CONFIGURED") fail 1 "no config/evidence-repo in $CONFIG; this home has not opted in" ;;
    *) exit 1 ;;
  esac
  destination_path "$repo" "$id"
}

cmd_preserve() {  # <task-id>
  local id=$1 repo source dest limit count visibility rc=0

  validate_task_id "$id"

  repo=$(resolve_evidence_repo) || rc=$?
  case "$rc" in
    0) : ;;
    # Not opted in. Silence is the contract: teardown must behave exactly as it
    # does in a home that has never heard of this feature.
    "$NOT_CONFIGURED") return 0 ;;
    # Configured but unusable, already explained on stderr. This must stay a
    # failure so teardown refuses rather than destroying the source.
    *) exit 1 ;;
  esac

  source="$DATA/$id"
  if [ ! -d "$source" ] || [ -z "$(find "$source" -type f 2>/dev/null | head -1)" ]; then
    note "task $id has no artifacts to preserve"
    return 0
  fi

  limit=$(max_direct_bytes)
  dest=$(destination_path "$repo" "$id")

  mkdir -p "$dest" || fail "$CUSTODY_FAILED" "cannot create $dest"
  count=$(copy_artifacts "$source" "$dest" "$id" "$limit") \
    || fail "$CUSTODY_FAILED" "copying evidence for $id into $dest failed"

  git -C "$repo" add -- "$dest" >/dev/null 2>&1 \
    || fail "$CUSTODY_FAILED" "cannot stage evidence for $id in $repo"

  if git -C "$repo" diff --cached --quiet -- "$dest"; then
    note "evidence for $id already current in $repo"
  elif git -C "$repo" commit -q -m "evidence($(evidence_home_tag)/$id): preserve $count artifact(s)" -- "$dest"; then
    note "committed $count artifact(s) for $id in $repo"
  else
    fail "$CUSTODY_FAILED" "cannot commit evidence for $id in $repo"
  fi

  # Custody is achieved from here on. Everything below is best-effort and never
  # changes the exit code.
  if ! visibility=$(remote_visibility "$repo"); then
    note "evidence for $id is committed locally; skipped the push because the destination's visibility could not be verified"
    return 0
  fi
  if [ "$visibility" != private ]; then
    note "REFUSED to push evidence for $id: $repo is $visibility, and unredacted evidence may only be published to a private repository"
    return 0
  fi
  # Named remote and explicit ref, so this does not depend on the clone having
  # an upstream configured for its current branch.
  if git -C "$repo" push --quiet "$(evidence_remote "$repo")" HEAD 2>/dev/null; then
    note "pushed evidence for $id"
  else
    note "evidence for $id is committed locally; the push did not succeed and will be carried by the next preserve"
  fi
  return 0
}

[ $# -ge 1 ] || { usage >&2; exit 1; }

case "$1" in
  -h|--help|help) usage; exit 0 ;;
  preserve)
    [ $# -eq 2 ] || fail 1 "usage: fm-evidence.sh preserve <task-id>"
    cmd_preserve "$2"
    ;;
  path)
    [ $# -eq 2 ] || fail 1 "usage: fm-evidence.sh path <task-id>"
    cmd_path "$2"
    ;;
  *) fail 1 "unknown verb: $1" ;;
esac
