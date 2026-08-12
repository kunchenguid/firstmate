#!/usr/bin/env bash
# Resolve a deterministic model route for a Firstmate task.
#
# This command is intentionally read-only. It classifies task text and prints a
# small key=value route record for later spawn/meta integration.
#
# Usage:
#   fm-route.sh <task-id> <project-or-path> [--kind ship|scout|secondmate]
#     [--task-file <path>] [--profile cheap|standard|deep|critical]
#     [--harness claude|codex|opencode|pi|grok] [--model <model>]
#     [--effort <effort>] [--captain-downgrade-ok] [--explain]
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: fm-route.sh <task-id> <project-or-path> [--kind ship|scout|secondmate] [--task-file <path>] [--profile <profile>] [--harness <adapter>] [--model <model>] [--effort <effort>] [--captain-downgrade-ok] [--explain]
USAGE
}

die() {
  printf 'fm-route: %s\n' "$1" >&2
  exit 1
}

is_profile() {
  case "$1" in cheap|standard|deep|critical) return 0 ;; *) return 1 ;; esac
}

is_harness() {
  case "$1" in claude|codex|opencode|pi|grok) return 0 ;; *) return 1 ;; esac
}

rank_profile() {
  case "$1" in
    cheap) echo 1 ;;
    standard) echo 2 ;;
    deep) echo 3 ;;
    critical) echo 4 ;;
    *) echo 0 ;;
  esac
}

append_unique() {
  local item=$1
  if [ -z "$2" ]; then
    printf '%s\n' "$item"
    return
  fi
  local existing=",$2,"
  case "$existing" in
    *",$item,"*) printf '%s\n' "$2" ;;
    *) printf '%s,%s\n' "$2" "$item" ;;
  esac
}

contains_any() {
  local haystack=$1
  shift
  local needle
  for needle in "$@"; do
    case "$haystack" in
      *"$needle"*) return 0 ;;
    esac
  done
  return 1
}

contains_git_danger() {
  local haystack=$1
  local normalized
  normalized=$(printf '%s' "$haystack" | tr -c '[:alnum:]' ' ')
  normalized=" $normalized "
  case "$normalized" in
    *" merge "*|*" rebase "*|*" reset "*|*" clean "*|*" force "*|*" history rewrite "*) return 0 ;;
  esac
  return 1
}

join_reasons() {
  local result="" part
  for part in "$@"; do
    [ -n "$part" ] || continue
    if [ -z "$result" ]; then
      result=$part
    else
      result="$result and $part"
    fi
  done
  printf '%s\n' "$result"
}

if [ "$#" -lt 2 ]; then
  usage
  exit 2
fi

task_id=$1
project=$2
shift 2

kind=ship
task_file=
manual_profile=
harness=codex
manual_harness=0
manual_model=
manual_effort=
captain_downgrade_ok=0
explain=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      [ "$#" -ge 2 ] || die "--kind needs a value"
      kind=$2
      case "$kind" in ship|scout|secondmate) ;; *) die "unknown kind: $kind" ;; esac
      shift 2
      ;;
    --task-file)
      [ "$#" -ge 2 ] || die "--task-file needs a path"
      task_file=$2
      shift 2
      ;;
    --profile)
      [ "$#" -ge 2 ] || die "--profile needs a value"
      manual_profile=$2
      is_profile "$manual_profile" || die "unknown profile: $manual_profile"
      shift 2
      ;;
    --harness)
      [ "$#" -ge 2 ] || die "--harness needs a value"
      harness=$2
      is_harness "$harness" || die "unknown harness: $harness"
      manual_harness=1
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || die "--model needs a value"
      manual_model=$2
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || die "--effort needs a value"
      manual_effort=$2
      shift 2
      ;;
    --captain-downgrade-ok)
      captain_downgrade_ok=1
      shift
      ;;
    --explain)
      explain=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

task_text=
if [ -n "$task_file" ]; then
  [ -f "$task_file" ] || die "task file not found: $task_file"
  task_text=$(cat "$task_file")
fi

raw_text="$task_id $project $kind $task_text"
text=$(printf '%s' "$raw_text" | tr '[:upper:]' '[:lower:]')

risk_flags=
production_reason=
money_reason=
credentials_reason=
external_reason=
security_reason=
git_reason=
firstmate_reason=

if contains_any "$text" production systemd timer cron service 4187 serve refresh follow-main deploy runtime; then
  risk_flags=$(append_unique production "$risk_flags")
  production_reason="production refresh/runtime"
fi

if contains_any "$text" ppc "amazon ads" sellersnap repricing campaign budget "purchase order" margin revenue; then
  risk_flags=$(append_unique money "$risk_flags")
  money_reason="money/business operations"
fi

if contains_any "$text" credential secret token auth gmail sp-api session mailbox; then
  risk_flags=$(append_unique credentials "$risk_flags")
  credentials_reason="credentials/auth"
fi

if contains_any "$text" send delivery email "live run" restart push merge delete archive prune "return worktree"; then
  risk_flags=$(append_unique external-side-effect "$risk_flags")
  external_reason="external side effects"
fi

if contains_any "$text" security vulnerability threat exploit pii "customer data" "customer-facing data"; then
  risk_flags=$(append_unique security "$risk_flags")
  security_reason="security/customer data"
fi

if contains_git_danger "$text"; then
  risk_flags=$(append_unique git-danger "$risk_flags")
  git_reason="git history/destructive operations"
fi

if contains_any "$text" fm-spawn fm-teardown fm-watch fm-guard fm-lock fm-route harness-adapters "state/meta" radar; then
  risk_flags=$(append_unique firstmate-core "$risk_flags")
  firstmate_reason="Firstmate core safety"
fi

deep_flags=
deep_reason=
if contains_any "$text" architecture migration strategy multi-step lfg " ce " "broad audit" "unclear audit"; then
  deep_flags=deep
  deep_reason="architecture/migration/deep planning"
elif contains_any "$text" audit && [ -z "$risk_flags" ]; then
  deep_flags=deep
  deep_reason="broad audit"
fi

safe_readonly=0
if [ "$kind" = scout ] && contains_any "$text" read-only readonly "read only" inventory docs documentation report-only summarize summary; then
  safe_readonly=1
fi

if [ -n "$risk_flags" ]; then
  auto_profile=critical
  reason="task touches $(join_reasons "$production_reason" "$money_reason" "$credentials_reason" "$external_reason" "$security_reason" "$git_reason" "$firstmate_reason")"
elif [ -n "$deep_flags" ]; then
  auto_profile=deep
  reason="task needs $deep_reason"
elif [ "$safe_readonly" = 1 ]; then
  auto_profile=cheap
  reason="task is read-only scout work with no high-risk signals"
else
  auto_profile=standard
  reason="task is routine or ambiguous without high-risk signals"
fi

profile=$auto_profile
override=none
if [ -n "$manual_profile" ]; then
  auto_rank=$(rank_profile "$auto_profile")
  manual_rank=$(rank_profile "$manual_profile")
  if [ "$manual_rank" -lt "$auto_rank" ] && [ "$captain_downgrade_ok" -ne 1 ]; then
    die "refusing risky downgrade from $auto_profile to $manual_profile without --captain-downgrade-ok"
  fi
  profile=$manual_profile
  if [ "$manual_rank" -lt "$auto_rank" ]; then
    override=captain-downgrade
    reason="captain explicitly allowed downgrade despite $auto_profile signals"
  else
    override=manual-profile
    reason="captain requested $manual_profile profile"
  fi
fi

if [ "$override" = none ] && { [ "$manual_harness" -eq 1 ] || [ -n "$manual_model" ] || [ -n "$manual_effort" ]; }; then
  override=manual
fi

case "$profile" in
  cheap)
    model=gpt-5.6-luna
    effort=low
    ;;
  standard)
    model=gpt-5.6-terra
    effort=medium
    ;;
  deep)
    model=gpt-5.6-sol
    effort=high
    ;;
  critical)
    model=gpt-5.6-sol
    effort=medium
    ;;
esac

[ -z "$manual_model" ] || model=$manual_model
[ -z "$manual_effort" ] || effort=$manual_effort

printf 'profile=%s\n' "$profile"
printf 'harness=%s\n' "$harness"
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
printf 'reason=%s\n' "$reason"
printf 'override=%s\n' "$override"
printf 'risk_flags=%s\n' "${risk_flags:-none}"
if [ "$explain" -eq 1 ]; then
  printf 'route: %s because %s\n' "$profile" "$reason"
fi

