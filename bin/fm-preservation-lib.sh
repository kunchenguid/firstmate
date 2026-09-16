#!/usr/bin/env bash
# Shared library for the AgentLab evidence-preservation gate
# (docs/evidence-preservation-lifecycle.md in yagakeerthikiran/agentlab-shared-memory
# is the canonical contract; this file is firstmate's mechanical enforcement of it).
#
# Owns the durable receipt log at state/<id>.preservation (append-only JSON
# Lines, one object per recorded checkpoint) and fm_preservation_verify, the
# single check every gate (fm-spawn.sh, fm-promote.sh, fm-teardown.sh) calls
# before it allows a lifecycle step to proceed. Never rewrite or truncate the
# receipt log: it is the audit trail a captain waiver and a later dispute both
# depend on.
#
# A receipt line carries: kind (initial|update|final|waiver), task, home,
# commit (the AgentLab commit the checkpoint file lives at), path (the
# checkpoint's path inside the AgentLab clone), branch (the AgentLab durable
# branch it must be reachable from, default "main"), app_branch, app_head (the
# task's application-repo branch head at checkpoint time, or "" when no
# worktree existed yet), timestamp (the checkpoint's own recorded time), and
# recorded_at (when this receipt was ingested into the log). A waiver line
# additionally carries captain_words.
#
# fm_preservation_verify re-reads the newest receipt of the requested kind and
# re-derives every fact from the AgentLab clone and (for a final check) the
# task's own worktree, rather than trusting the receipt's own claims: a stale,
# unpushed, unreachable, or validator-failing checkpoint is refused with an
# exact reason, and a missing clone, missing validator, or network failure is
# refused rather than silently skipped. There is no cache; every call re-fetches.
#
# AGENTLAB_ROOT resolves to $FM_HOME/projects/agentlab-shared-memory by
# default (the AGENTS.md project-clone layout), overridable with
# FM_PRESERVATION_AGENTLAB_ROOT for a task home whose clone lives elsewhere and
# for tests. FM_PRESERVATION_OFFLINE=1 passes --offline to the AgentLab
# validator (its own PR/commit-URL network checks only); it never skips the
# fetch or reachability check here, which is what proves "pushed and
# reachable" rather than merely "the receipt claims a commit".

_FM_PRESERVATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_PRESERVATION_LIB_DIR/fm-wake-lib.sh"

FM_PRESERVATION_VERIFY_ERROR=
FM_PRESERVATION_VERIFY_RECEIPT=

# fm_preservation_record_path <state_dir> <id>
fm_preservation_record_path() {
  printf '%s/%s.preservation\n' "$1" "$2"
}

# fm_preservation_agentlab_root <fm_home>
fm_preservation_agentlab_root() {
  printf '%s\n' "${FM_PRESERVATION_AGENTLAB_ROOT:-$1/projects/agentlab-shared-memory}"
}

# fm_preservation_append_line <state_dir> <id> <json_line>
# Appends one already-serialized compact JSON line under a lock shared with
# every other appender for this task, so two concurrent publishes never
# interleave partial lines. Never truncates or rewrites existing lines.
fm_preservation_append_line() {
  local state_dir=$1 id=$2 line=$3 path lock
  path=$(fm_preservation_record_path "$state_dir" "$id")
  lock="$state_dir/.$id.preservation.lock"
  mkdir -p "$state_dir" || return 1
  fm_lock_acquire_wait "$lock"
  printf '%s\n' "$line" >> "$path"
  local rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# _fm_preservation_node_latest <path> <kind> <id>
# Prints the newest line whose .kind and .task match, or nothing. Malformed
# lines are skipped rather than aborting the read (an append-only log may carry
# a torn line from a killed writer; that line is simply not a valid receipt).
_fm_preservation_node_latest() {
  local path=$1 kind=$2 id=$3
  [ -f "$path" ] || return 0
  node -e '
    const fs = require("node:fs");
    const [path, kind, id] = process.argv.slice(1);
    const lines = fs.readFileSync(path, "utf8").split("\n");
    let latest = null;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let obj;
      try { obj = JSON.parse(trimmed); } catch { continue; }
      if (obj && obj.kind === kind && (!id || obj.task === id)) latest = obj;
    }
    if (latest) process.stdout.write(JSON.stringify(latest));
  ' "$path" "$kind" "$id"
}

# _fm_preservation_field <json> <field>
_fm_preservation_field() {
  local json=$1 field=$2
  node -e '
    const obj = JSON.parse(process.argv[1] || "{}");
    const v = obj[process.argv[2]];
    process.stdout.write(v === undefined || v === null ? "" : String(v));
  ' "$json" "$field"
}

# fm_preservation_record_waiver <state_dir> <id> <captain_words>
# Records a captain waiver as its own auditable receipt-log line AND as a
# status-file line, so waiving preservation is always a visible captain act,
# never a silent flag. Never itself authorizes anything; callers still decide
# what a waiver permits.
fm_preservation_record_waiver() {
  local state_dir=$1 id=$2 words=$3 ts json status
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  json=$(node -e '
    process.stdout.write(JSON.stringify({
      kind: "waiver",
      task: process.argv[1],
      captain_words: process.argv[2],
      recorded_at: process.argv[3],
    }));
  ' "$id" "$words" "$ts")
  fm_preservation_append_line "$state_dir" "$id" "$json" || return 1
  status="$state_dir/$id.status"
  printf 'note: preservation gate waived by captain: %s\n' "$words" >> "$status" 2>/dev/null || true
}

# _fm_preservation_epoch <timestamp>: prints a receipt timestamp (ISO 8601,
# optional sub-second precision) as epoch seconds, or returns 1 if unparseable.
_fm_preservation_epoch() {
  local ts=$1
  ts=$(printf '%s' "$ts" | sed -E 's/\.[0-9]+Z$/Z/')
  date -u -d "$ts" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || return 1
}

# _fm_preservation_mtime <path>: prints a file's mtime as epoch seconds, or
# returns 1 if the file cannot be stat'd.
_fm_preservation_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# _fm_preservation_not_stale_against <id> <receipt_epoch> <file>...
# Refuses (sets FM_PRESERVATION_VERIFY_ERROR, returns 1) if any given file
# exists and was modified after the receipt's own recorded timestamp.
_fm_preservation_not_stale_against() {
  local id=$1 receipt_epoch=$2; shift 2
  local f mt
  for f in "$@"; do
    [ -e "$f" ] || continue
    mt=$(_fm_preservation_mtime "$f") || continue
    if [ "$mt" -gt "$receipt_epoch" ]; then
      # shellcheck disable=SC2034 # Output global consumed by sourcing callers.
      FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation final checkpoint for task $id is stale: $f was modified after the checkpoint's own recorded timestamp; publish an updated final checkpoint before teardown"
      return 1
    fi
  done
  return 0
}

# _fm_preservation_default_branch_head <dir>: prints the commit at <dir>'s
# default branch tip (origin/HEAD's branch, else a local main, else master),
# or returns 1 if none can be resolved.
_fm_preservation_default_branch_head() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ] && git -C "$dir" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null; then
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" \
      && git -C "$dir" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# fm_preservation_verify <state_dir> <id> <kind> [<worktree>] [<task_kind>]
# kind is initial|update|final. worktree, when given and kind=final, checks the
# receipt's app_head for staleness against it; task_kind (ship|scout|secondmate,
# default ship) selects which staleness rule applies:
#   ship (default): app_head is required and must equal worktree's current HEAD.
#   scout: app_head may be empty (a scout has no code-review head to record);
#     when given, it must equal worktree's current HEAD; the receipt's own
#     timestamp must additionally be no older than the newest data/<id>/*.md
#     report and the task's own status file.
#   secondmate: app_head is required and must equal worktree's (the secondmate
#     home's own checkout) current default-branch head; the receipt's own
#     timestamp must additionally be no older than that home's
#     data/backlog.md and data/captain.md.
# Sets FM_PRESERVATION_VERIFY_ERROR (a "REFUSED: preservation ..." line) and
# returns 1 on any failure; sets FM_PRESERVATION_VERIFY_RECEIPT (the matched
# receipt JSON) and returns 0 on success.
fm_preservation_verify() {
  local state_dir=$1 id=$2 kind=$3 worktree=${4:-} task_kind=${5:-ship}
  local fm_home=${FM_HOME:-$FM_ROOT}
  local record_path agentlab_root receipt commit path branch app_head validator
  local tmp_checkpoint rc offline_flag

  FM_PRESERVATION_VERIFY_ERROR=
  FM_PRESERVATION_VERIFY_RECEIPT=

  record_path=$(fm_preservation_record_path "$state_dir" "$id")
  receipt=$(_fm_preservation_node_latest "$record_path" "$kind" "$id")
  if [ -z "$receipt" ]; then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation $kind checkpoint absent for task $id (no receipt recorded in $record_path)"
    return 1
  fi

  commit=$(_fm_preservation_field "$receipt" commit)
  path=$(_fm_preservation_field "$receipt" path)
  branch=$(_fm_preservation_field "$receipt" branch)
  app_head=$(_fm_preservation_field "$receipt" app_head)
  [ -n "$branch" ] || branch=main
  if [ -z "$commit" ] || [ -z "$path" ]; then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation $kind checkpoint for task $id is missing required commit/path fields in its receipt"
    return 1
  fi

  agentlab_root=$(fm_preservation_agentlab_root "$fm_home")
  if [ ! -d "$agentlab_root/.git" ]; then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation verification requires the agentlab-shared-memory clone at $agentlab_root, which is absent; refusing rather than skipping verification"
    return 1
  fi

  validator="$agentlab_root/scripts/validate-checkpoint.mjs"
  if [ ! -f "$validator" ]; then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation validator missing at $validator; refusing rather than skipping verification"
    return 1
  fi

  local fetch_out
  if ! fetch_out=$(git -C "$agentlab_root" fetch origin --quiet 2>&1); then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation verification could not fetch origin for $agentlab_root: $(printf '%s' "$fetch_out" | tail -n 1)"
    return 1
  fi

  if ! git -C "$agentlab_root" cat-file -e "$commit^{commit}" 2>/dev/null; then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation $kind checkpoint commit $commit for task $id is not present in $agentlab_root (absent evidence)"
    return 1
  fi

  if ! git -C "$agentlab_root" merge-base --is-ancestor "$commit" "origin/$branch" 2>/dev/null; then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation $kind checkpoint commit $commit for task $id is not reachable from origin/$branch (committed locally but not pushed, or pushed to an undeclared branch)"
    return 1
  fi

  if ! git -C "$agentlab_root" cat-file -e "$commit:$path" 2>/dev/null; then
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation $kind checkpoint file $path for task $id is missing at commit $commit"
    return 1
  fi

  tmp_checkpoint=$(mktemp "${TMPDIR:-/tmp}/fm-preservation-checkpoint.XXXXXX") || {
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation verification could not create a temp file to run the validator"
    return 1
  }
  if ! git -C "$agentlab_root" show "$commit:$path" > "$tmp_checkpoint" 2>/dev/null; then
    rm -f -- "$tmp_checkpoint"
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation verification could not extract $path at commit $commit"
    return 1
  fi
  offline_flag=()
  [ "${FM_PRESERVATION_OFFLINE:-0}" != 1 ] || offline_flag=(--offline)
  local validator_out
  if ! validator_out=$(node "$validator" "$tmp_checkpoint" --repo-root "$agentlab_root" "${offline_flag[@]}" 2>&1); then
    rm -f -- "$tmp_checkpoint"
    FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation validator failures for $path@$commit: $(printf '%s' "$validator_out" | tr '\n' ';' )"
    return 1
  fi
  rm -f -- "$tmp_checkpoint"

  # A worktree that no longer exists or is not (or no longer) an inspectable
  # git checkout is not automatically stale: fm-teardown.sh itself tolerates a
  # gone worktree (teardown_owns_worktree && [ -d "$WT" ]), the common case for
  # already-landed work whose worktree was separately cleaned up, so this
  # check mirrors that same tolerance - it verifies freshness only when a head
  # can actually be read - rather than refusing on a path that is legitimately
  # gone or not a git checkout at all.
  if [ "$kind" = final ] && [ -n "$worktree" ]; then
    case "$task_kind" in
      scout)
        local current_head
        if current_head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null); then
          if [ -n "$app_head" ] && [ "$app_head" != "$current_head" ]; then
            FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation final checkpoint for task $id is stale: its recorded app head '$app_head' does not match the current branch head $current_head at $worktree; publish an updated final checkpoint before teardown"
            return 1
          fi
        fi
        local receipt_ts receipt_epoch
        receipt_ts=$(_fm_preservation_field "$receipt" timestamp)
        receipt_epoch=$(_fm_preservation_epoch "$receipt_ts") || {
          FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation final checkpoint for task $id has an unparseable timestamp '$receipt_ts'"
          return 1
        }
        _fm_preservation_not_stale_against "$id" "$receipt_epoch" \
          "$fm_home/data/$id"/*.md "$state_dir/$id.status" || return 1
        ;;
      secondmate)
        if [ -z "$app_head" ]; then
          FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation final checkpoint for task $id is missing app_head; a secondmate final checkpoint must record the secondmate home's current default-branch head"
          return 1
        fi
        local secondmate_head
        if secondmate_head=$(_fm_preservation_default_branch_head "$worktree"); then
          if [ "$app_head" != "$secondmate_head" ]; then
            FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation final checkpoint for task $id is stale: its recorded app head '$app_head' does not match the secondmate home's current default-branch head $secondmate_head at $worktree; publish an updated final checkpoint before teardown"
            return 1
          fi
        fi
        local receipt_ts receipt_epoch
        receipt_ts=$(_fm_preservation_field "$receipt" timestamp)
        receipt_epoch=$(_fm_preservation_epoch "$receipt_ts") || {
          FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation final checkpoint for task $id has an unparseable timestamp '$receipt_ts'"
          return 1
        }
        _fm_preservation_not_stale_against "$id" "$receipt_epoch" \
          "$worktree/data/backlog.md" "$worktree/data/captain.md" || return 1
        ;;
      *)
        local current_head
        if current_head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null); then
          if [ -z "$app_head" ] || [ "$app_head" != "$current_head" ]; then
            # shellcheck disable=SC2034 # Output global consumed by sourcing callers.
            FM_PRESERVATION_VERIFY_ERROR="REFUSED: preservation final checkpoint for task $id is stale: its recorded app head '${app_head:-<none>}' does not match the current branch head $current_head at $worktree; publish an updated final checkpoint before teardown"
            return 1
          fi
        fi
        ;;
    esac
  fi

  # shellcheck disable=SC2034 # Output global consumed by sourcing callers.
  FM_PRESERVATION_VERIFY_RECEIPT=$receipt
  return 0
}

# fm_preservation_digest_line <state_dir> <id> [<worktree>]
# One bounded, network-free line for bin/fm-session-start.sh's fleet-state
# digest: the newest receipt of any kind, its commit, and whether the
# worktree's current head has moved past it (a local git rev-parse only - no
# fetch, no validator - so the digest stays fast; fm_preservation_verify is the
# authoritative, network-checking gate a spawn/promote/teardown call actually
# enforces). Always prints exactly one line; never fails the digest.
fm_preservation_digest_line() {
  local state_dir=$1 id=$2 worktree=${3:-}
  local record_path receipt kind commit app_head short staleness current_head
  record_path=$(fm_preservation_record_path "$state_dir" "$id")
  receipt=$(node -e '
    const fs = require("node:fs");
    const path = process.argv[1];
    let lines;
    try { lines = fs.readFileSync(path, "utf8").split("\n"); } catch { process.exit(0); }
    let latest = null;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try { latest = JSON.parse(trimmed); } catch { continue; }
    }
    if (latest) process.stdout.write(JSON.stringify(latest));
  ' "$record_path" 2>/dev/null)
  if [ -z "$receipt" ]; then
    printf 'preservation: no checkpoint receipt recorded (%s)\n' "$record_path"
    return 0
  fi
  kind=$(_fm_preservation_field "$receipt" kind)
  commit=$(_fm_preservation_field "$receipt" commit)
  app_head=$(_fm_preservation_field "$receipt" app_head)
  short=${commit:0:12}
  staleness=unknown
  if [ "$kind" = final ] && [ -n "$worktree" ] && [ -n "$app_head" ]; then
    if current_head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null); then
      if [ "$app_head" = "$current_head" ]; then staleness=fresh; else staleness=stale; fi
    fi
  fi
  printf 'preservation: kind=%s commit=%s staleness=%s\n' "${kind:-unknown}" "${short:-none}" "$staleness"
}
