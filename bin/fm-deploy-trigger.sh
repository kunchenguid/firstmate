#!/usr/bin/env bash
# Decide and perform the automatic deploy that follows a confirmed merge, and
# finish the one that was only ever early.
#
# Called by bin/fm-merge-outcome-lib.sh's fm_merge_outcome_report, the one owner
# of the confirmed-merge path, so a merge this home performed and a merge its
# poll noticed both reach the same decision without an agent remembering to make
# it.
#
# Usage:
#   fm-deploy-trigger.sh <home> <state> <task-id>
#   fm-deploy-trigger.sh <home> <state> --resume-pending
#
# Inert unless the task's project has a deploy policy at
# config/deploy-policy/<project>. A home with no policy for that project does
# nothing here and exits 0, so this changes nothing for every other project and
# every secondmate home.
#
# config/deploy-freeze/<project> pauses the automatic deploy without touching
# the policy. Pausing by moving the policy aside loses the reserved-surface
# list and the checkout, unit and bundle settings with it, so the way back on
# is a restore from memory; a freeze file is one file to create and one to
# delete. The freeze stops only what this script does on its own: a deploy the
# captain runs by hand still goes through, because the captain asking for it is
# the decision the freeze exists to reserve.
#
# It deploys ONLY when everything merged and not yet live is auto-deployable. A
# range that touches a captain-reserved surface is never deployed here under any
# circumstances; it is reported and left for the captain.
#
# Whatever happens, at most one captain-facing line is queued, and the exit
# status is always 0: a deploy that failed is a deploy problem, never a reason
# to report that the merge itself was not recorded.
#
# --- the deferred re-check --------------------------------------------------
#
# A merge that lands before its own commit's build finishes is the ordinary
# case, not an edge one: the merge poll notices the merge within seconds, and
# the build takes minutes. bin/fm-deploy.sh refuses that with exit 4 - the one
# refusal whose condition clears with nobody doing anything - and this script
# used to report it and forget it, so every such merge waited for a deploy by
# hand.
#
# So a refusal with exit 4, and only that refusal, writes one durable record at
# state/deploy-pending/<project> naming the commit it was refused for, the
# commit it would have come from, the authority it acted under, the reason, and
# when it was first seen. Nothing captain-facing is said: being a few minutes
# early is not news.
#
# bin/fm-watch.sh calls `--resume-pending` on its ordinary cycle cadence, which
# re-runs the whole decision above for each recorded project - policy, freeze,
# reserved surfaces and all - and lets it end the record itself. Success, a red
# build, an expired artifact, a freeze, a reserved surface, or nothing left to
# deploy all clear the record and report exactly as they would have on the
# merge; only exit 4 rewrites it and waits again. A newer merge simply rewrites
# the record with its own commit, so the newest pending commit supersedes the
# older one for that project rather than queueing behind it.
#
# A record that has waited longer than FM_DEPLOY_PENDING_MAX_SECS (default 3600,
# valid 300..86400) stops waiting: the captain is told the merge never built,
# and the record is removed. A value outside that range falls back to the
# default with a notice on stderr rather than refusing, because this horizon is
# a comfort bound on how long to keep trying - every safety boundary that
# decides WHETHER to deploy is checked afresh on each attempt and is untouched
# by it.
#
# The retry is deliberately the whole decision rather than a cheap "is the build
# done yet" probe: one owner, one set of refusals, and no second copy of the
# build-state question to drift from bin/fm-deploy.sh's. It costs a bounded
# attempt per recorded project per cycle, and a home has at most as many records
# as it has deploy policies.
#
# Every external call this script makes is individually bounded
# (FM_DEPLOY_SYNC_TIMEOUT, FM_DEPLOY_STATUS_TIMEOUT, FM_DEPLOY_TIMEOUT), so one
# wedged ssh or gh call cannot stall the watcher past those bounds; nothing here
# wraps a deploy in a timeout of its own, which could cut one off mid-swap.
#
# On the merge path this script prints nothing, exactly as before. On
# `--resume-pending` it prints the name of each project for which a
# captain-facing line was queued, and nothing otherwise, so the watcher rings
# only when there is something to read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOME_DIR=${1:-}
STATE_DIR=${2:-}
SUBJECT=${3:-}
[ -n "$HOME_DIR" ] && [ -n "$STATE_DIR" ] && [ -n "$SUBJECT" ] || exit 0

PENDING_DIR="$STATE_DIR/deploy-pending"
PENDING_SCHEMA=fm-deploy-pending-v1
PENDING_REASON_MAX=400

# Set by attempt() for the project it is deciding about.
PROJECT=''
TASK_ID=''
QUEUED=0

# One captain-facing line, through the queue this home already uses.
queue() {
  QUEUED=1
  (
    FM_HOME=$HOME_DIR
    FM_STATE_OVERRIDE=$STATE_DIR
    STATE=$STATE_DIR
    export FM_HOME FM_STATE_OVERRIDE
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    fm_wake_append check "deploy-$PROJECT-$TASK_ID" "check: $1"
  ) >/dev/null 2>&1 || true
}

pending_file() { printf '%s/%s\n' "$PENDING_DIR" "$1"; }

pending_clear() {  # <project>
  rm -f -- "$(pending_file "$1")" 2>/dev/null || true
}

pending_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# pending_write <project> <task-id> <sha> <from-sha> <reason>
# Rewritten in full on every refusal, so the record always names the commit the
# NEWEST attempt was refused for. first_seen survives only while the commit
# does: a new commit is new work and starts its own horizon.
pending_write() {
  local project=$1 task=$2 sha=$3 from=$4 reason=$5
  local file first_seen='' tmp
  file=$(pending_file "$project")
  reason=$(printf '%s' "$reason" | tr '\n\t' '  ' | cut -c "1-$PENDING_REASON_MAX")
  if [ -f "$file" ] && [ ! -L "$file" ] \
    && [ "$(pending_field "$file" sha)" = "$sha" ]; then
    first_seen=$(pending_field "$file" first_seen)
  fi
  case "$first_seen" in ''|*[!0-9]*) first_seen=$(date +%s) ;; esac
  mkdir -p "$PENDING_DIR" 2>/dev/null || return 0
  chmod 0700 "$PENDING_DIR" 2>/dev/null || true
  tmp=$(mktemp "$PENDING_DIR/.pending.XXXXXX" 2>/dev/null) || return 0
  {
    printf '%s\n' "$PENDING_SCHEMA"
    printf 'project=%s\n' "$project"
    printf 'task=%s\n' "$task"
    printf 'sha=%s\n' "$sha"
    printf 'from_sha=%s\n' "$from"
    # The standing deploy policy is the only authority this path ever acts
    # under; it never carries the captain's own words, which is why a reserved
    # surface is reported instead of deployed.
    printf 'authority=auto\n'
    printf 'first_seen=%s\n' "$first_seen"
    printf 'reason=%s\n' "$reason"
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp"
}

# attempt <project> <task-id>
# The whole decision, from the project's policy to the deploy itself. Every
# path through it either ends the project's pending record or rewrites it.
attempt() {
  PROJECT=$1
  TASK_ID=$2

  local policy freeze frozen=0 status_out auto pending captain_paths target from
  local deploy_out rc

  policy="$HOME_DIR/config/deploy-policy/$PROJECT"
  if [ ! -f "$policy" ] || [ -L "$policy" ]; then
    pending_clear "$PROJECT"
    return 0
  fi

  freeze="$HOME_DIR/config/deploy-freeze/$PROJECT"
  [ -f "$freeze" ] && [ ! -L "$freeze" ] && frozen=1

  # Refresh this home's copy through the one guarded path that may touch a
  # project clone, so the comparison is against what actually landed. A refresh
  # that cannot run is not fatal: the status read below simply reports against
  # the copy as it stands.
  FM_HOME="$HOME_DIR" timeout "${FM_DEPLOY_SYNC_TIMEOUT:-120}" \
    "$SCRIPT_DIR/fm-fleet-sync.sh" "$PROJECT" >/dev/null 2>&1 || true

  status_out=$(FM_HOME="$HOME_DIR" timeout "${FM_DEPLOY_STATUS_TIMEOUT:-120}" \
    "$SCRIPT_DIR/fm-deploy-status.sh" "$PROJECT" --porcelain 2>/dev/null) || {
    # A status read that failed is not evidence the deploy is merely early, so
    # it is reported once rather than retried into a repeated report.
    pending_clear "$PROJECT"
    queue "could not check whether $PROJECT's live site is up to date; it needs a look"
    return 0
  }

  field() { printf '%s\n' "$status_out" | sed -n "s/^$1=//p" | head -1; }

  if [ "$(field managed)" != yes ]; then
    pending_clear "$PROJECT"
    return 0
  fi
  auto=$(field auto_deployable)
  pending=$(field pending_total)
  captain_paths=$(field pending_captain_paths)
  target=$(field target_sha)
  from=$(field deployed_sha)

  if [ "${pending:-0}" = 0 ]; then
    pending_clear "$PROJECT"
    return 0
  fi

  if [ "$frozen" -eq 1 ]; then
    # Said once per merged change rather than kept quiet: a freeze that stops
    # reporting is a freeze everyone forgets is on.
    pending_clear "$PROJECT"
    queue "$PROJECT has $pending merged change(s) waiting to go live, and going live on its own is paused. Run /deploy to send them yourself, or lift the pause."
    return 0
  fi

  if [ "$auto" != yes ]; then
    pending_clear "$PROJECT"
    queue "$PROJECT has $pending merged change(s) waiting to go live, and $captain_paths of the files they touch are design surfaces you asked to approve first. Run /deploy to see them."
    return 0
  fi

  rc=0
  deploy_out=$(FM_HOME="$HOME_DIR" timeout "${FM_DEPLOY_TIMEOUT:-900}" \
    "$SCRIPT_DIR/fm-deploy.sh" "$PROJECT" "$target" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    pending_clear "$PROJECT"
    queue "$PROJECT's live site is now up to date with everything merged; nothing needed your permission."
    return 0
  fi
  if [ "$rc" -eq 4 ]; then
    # The one refusal that clears on its own. Nothing is said; the record is
    # what makes the deploy happen once the build lands.
    pending_write "$PROJECT" "$TASK_ID" "$target" "$from" \
      "$(printf '%s' "$deploy_out" | tail -1)"
    return 0
  fi
  pending_clear "$PROJECT"
  queue "$PROJECT's live site could not be updated automatically and needs a look: $(printf '%s' "$deploy_out" | tail -3 | tr '\n' ' ')"
}

# A record reads back only when this script wrote it whole: the schema line, a
# project matching its own file name, and a numeric first_seen.
pending_record_valid() {  # <file> <basename>
  local file=$1 base=$2 first_seen
  [ "$(head -1 "$file" 2>/dev/null)" = "$PENDING_SCHEMA" ] || return 1
  [ "$(pending_field "$file" project)" = "$base" ] || return 1
  first_seen=$(pending_field "$file" first_seen)
  case "$first_seen" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

pending_max_secs() {
  local secs=${FM_DEPLOY_PENDING_MAX_SECS:-3600}
  case "$secs" in
    ''|*[!0-9]*) secs='' ;;
  esac
  if [ -n "$secs" ] && { [ "$secs" -lt 300 ] || [ "$secs" -gt 86400 ]; }; then
    secs=''
  fi
  if [ -z "$secs" ]; then
    printf 'fm-deploy-trigger: FM_DEPLOY_PENDING_MAX_SECS must be a whole number from 300 to 86400; using 3600\n' >&2
    secs=3600
  fi
  printf '%s\n' "$secs"
}

# Re-run the decision for every project with a pending record, and print the
# name of each one that produced a captain-facing line.
resume_pending() {
  local file base project task sha first_seen now max age
  [ -d "$PENDING_DIR" ] && [ ! -L "$PENDING_DIR" ] || return 0
  max=$(pending_max_secs)
  now=$(date +%s)
  for file in "$PENDING_DIR"/*; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    base=$(basename "$file")
    case "$base" in .*) continue ;; esac
    # This script is the only writer, and it writes whole records atomically, so
    # a record that does not read back is corruption. It cannot name a project
    # to deploy, and keeping it would retry that same nothing every cycle, so it
    # is dropped loudly rather than trusted or looped on.
    if ! pending_record_valid "$file" "$base"; then
      printf 'fm-deploy-trigger: dropping an unreadable pending deploy record: %s\n' "$file" >&2
      rm -f -- "$file"
      continue
    fi
    project=$base
    task=$(pending_field "$file" task)
    sha=$(pending_field "$file" sha)
    first_seen=$(pending_field "$file" first_seen)
    age=$(( now - first_seen ))
    QUEUED=0
    if [ "$age" -ge "$max" ]; then
      PROJECT=$project
      TASK_ID=$task
      pending_clear "$project"
      queue "$project has merged work that still has not gone live: the build for $sha has not finished in $(( age / 60 )) minutes, so it needs a look."
    else
      attempt "$project" "$task"
    fi
    [ "$QUEUED" -eq 0 ] || printf '%s\n' "$project"
  done
}

if [ "$SUBJECT" = --resume-pending ]; then
  resume_pending
  exit 0
fi

META="$STATE_DIR/$SUBJECT.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
PROJECT_PATH=$(sed -n 's/^project=//p' "$META" | head -1)
[ -n "$PROJECT_PATH" ] || exit 0
project_name=$(basename "$PROJECT_PATH")
[ -n "$project_name" ] || exit 0

attempt "$project_name" "$SUBJECT" >/dev/null
exit 0
