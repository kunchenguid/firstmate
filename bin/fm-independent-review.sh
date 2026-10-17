#!/usr/bin/env bash
# Dispatch and enforce one cold different-family review for a finished pull request.
#
# `ready` is the readiness boundary; no gate script calls it yet.
# It inspects the forge without writing to it, resolves the builder family from
# state/<id>.meta, starts a fresh reviewer when needed, and returns success only
# for a clear verdict bound to the pull request's exact current head.
# A moved head consumes the one permitted fix-review round.
# A second rejection, or another head after two rounds, opens the circuit and
# requires re-scoping rather than a third review.
#
# Reviewer candidates are verified fm-spawn adapters.
# The default candidate order is intentionally compared with the recorded
# builder family at runtime; it is not a standing vendor assignment.
# Model-routing adapters derive family from the recorded provider-qualified
# model, and an unknown provider is refused rather than guessed.
#
# The generated reviewer brief points only to an immutable copy of the original
# task criteria and the exact diff.
# It excludes builder reasoning, pipeline output, and previous verdicts.
# The reviewer is read-only against the forge and submits one bounded verdict
# through this script.
#
# Verdict provenance is firstmate's own orchestration channel, never a capability
# an agent can present.
# `submit` records the reviewer's bounded result as that reviewer's own scout
# deliverable and grants no authority by itself.
# `ready` promotes that result to the task verdict only when the reviewer
# firstmate spawned for the round also finished through the supervised scout
# completion path: the decision-hold completion attestation in its task metadata
# (written only by bin/fm-decision-hold.sh complete) and the prescribed done line
# in its status log, which names the verdict it submitted.
# No submit token exists, so no verdict can be obtained by reading another task's
# private files, and a result recorded by anyone else is promoted only if the
# reviewer independently attests to that same verdict.
#
# Every firstmate agent runs as the same user, so an agent that chose to write
# into another task's deliverable, metadata, and status log could still forge a
# verdict.
# That is an active mutation of supervised records rather than a passive read of
# a capability, and raising it to an OS boundary is out of scope here.
#
# Usage:
#   fm-independent-review.sh ready <task-id> <pr-url> [--head-file <path>]
#   fm-independent-review.sh retire-failed <task-id> <round>
#   fm-independent-review.sh submit <task-id> <review-task-id> <head> \
#     <clear|reject> <summary> [--block <category> <finding>]... \
#     [--follow-up <note>]...
#   fm-independent-review.sh add-finding <task-id> <category> <finding>
#   fm-independent-review.sh resolve-finding <task-id> <finding> [<reason>]
#
# add-finding and resolve-finding are supervisor/operator commands for firstmate
# or the captain, not for the builder or reviewer of the task.
# resolve-finding records the optional reason beside the resolved finding.
#
# Exit status for `ready`:
#   0  current head has a clear independent verdict
#   1  refusal, rejection, or circuit breaker
#   3  a review was started or is still pending
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$CODE_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$CODE_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

meta_value() {
  local file=$1 key=$2
  awk -v prefix="$key=" 'index($0, prefix) == 1 { value=substr($0, length(prefix) + 1) } END { print value }' "$file"
}

one_line() {
  local value=${1-} printable
  [ -n "$value" ] || return 1
  case "$value" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  printable=$(printf '%s' "$value" | LC_ALL=C tr -d '\000-\037\177')
  [ "$printable" = "$value" ]
}

# Replace a private record in one step, refusing a symlink or a hardlinked
# destination so no other name observes or survives the write.
private_file_write() {
  local destination=$1 source=$2 tmp device dir
  [ ! -L "$destination" ] || return 1
  if [ -e "$destination" ]; then
    [ -f "$destination" ] && [ "$(fm_pr_file_link_count "$destination")" = 1 ] || return 1
  fi
  dir=$(dirname -- "$destination")
  device=$(fm_pr_file_device "$dir") || return 1
  tmp=$(mktemp "$dir/.fm-independent-review.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' RETURN
  cp "$source" "$tmp" || return 1
  chmod 0600 "$tmp" || return 1
  fm_pr_private_file_valid "$tmp" 600 "$device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$destination" "$device" || return 1
  mv -f -- "$tmp" "$destination" || return 1
  trap - RETURN
}

write_lines_file() {
  local destination=$1
  shift
  local tmp
  tmp=$(mktemp "$STATE/.fm-independent-review-lines.XXXXXX") || return 1
  printf '%s\n' "$@" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  private_file_write "$destination" "$tmp" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
}

model_family() {
  local harness=$1 model=${2:-default} normalized
  normalized=$model
  case "$harness" in
    claude) printf '%s\n' anthropic; return 0 ;;
    codex) printf '%s\n' openai; return 0 ;;
    grok) printf '%s\n' xai; return 0 ;;
    kimi) printf '%s\n' moonshot; return 0 ;;
    muse) printf '%s\n' meta; return 0 ;;
    cursor|pi|pi-signed|opencode) ;;
    *) return 1 ;;
  esac
  [ -n "$normalized" ] && [ "$normalized" != default ] || return 1
  normalized=${normalized#openrouter/~}
  if [ "$harness" = cursor ]; then
    case "$normalized" in
      cursor-grok-*) printf '%s\n' xai ;;
      *) return 1 ;;
    esac
    return 0
  fi
  case "$normalized" in
    anthropic/*|openrouter/anthropic/*) printf '%s\n' anthropic ;;
    openai/*|openai-codex/*|openrouter/openai/*) printf '%s\n' openai ;;
    xai/*|x-ai/*|openrouter/xai/*|openrouter/x-ai/*) printf '%s\n' xai ;;
    google/*|openrouter/google/*) printf '%s\n' google ;;
    kimi-code/*|moonshotai/*|openrouter/kimi-code/*|openrouter/moonshotai/*) printf '%s\n' moonshot ;;
    *) return 1 ;;
  esac
}

adapter_available() {
  local harness=$1
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok)
      command -v "$harness" >/dev/null 2>&1
      ;;
    kimi)
      command -v kimi >/dev/null 2>&1 || [ -x "${HOME:-}/.kimi-code/bin/kimi" ]
      ;;
    *) return 1 ;;
  esac
}

SELECTED_HARNESS=
SELECTED_MODEL=
SELECTED_EFFORT=
SELECTED_FAMILY=

select_reviewer() {
  local builder_family=$1 candidates line harness model effort extra family
  candidates=${FM_INDEPENDENT_REVIEW_CANDIDATES:-$'claude|default|high\ncodex|default|high\ngrok|default|high\nkimi|default|high'}
  SELECTED_HARNESS=
  SELECTED_MODEL=
  SELECTED_EFFORT=
  SELECTED_FAMILY=
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    IFS='|' read -r harness model effort extra <<EOF
$line
EOF
    [ -n "$harness" ] && [ -n "$model" ] && [ -n "$effort" ] && [ -z "${extra:-}" ] || continue
    case "$effort" in low|medium|high|xhigh|max) ;; *) continue ;; esac
    family=$(model_family "$harness" "$model" 2>/dev/null) || continue
    [ "$family" != "$builder_family" ] || continue
    adapter_available "$harness" || continue
    SELECTED_HARNESS=$harness
    SELECTED_MODEL=$model
    SELECTED_EFFORT=$effort
    SELECTED_FAMILY=$family
    return 0
  done <<EOF
$candidates
EOF
  return 1
}

PR_STATE=
PR_DRAFT=
PR_HEAD=
PR_BASE=

inspect_pr() {
  local url=$1 raw encoded extra
  fm_pr_url_parse "$url" || return 1
  case "$FM_PR_PROVIDER" in
    github)
      command -v gh-axi >/dev/null 2>&1 || {
        fail 'could not establish pull request state and head because gh-axi is unavailable'
        return 1
      }
      raw=$(gh-axi pr view "$FM_PR_NUMBER" --repo "$FM_PR_PATH" \
        --json state,isDraft,headRefOid,baseRefName \
        --template '{{.state}}{{"\t"}}{{.isDraft}}{{"\t"}}{{.headRefOid}}{{"\t"}}{{.baseRefName}}{{"\n"}}' 2>/dev/null) || {
          fail 'could not establish pull request state, exact head, and target base from GitHub'
          return 1
        }
      IFS=$'\t' read -r PR_STATE PR_DRAFT PR_HEAD PR_BASE extra <<EOF
$raw
EOF
      [ -z "${extra:-}" ] || {
        fail 'could not establish pull request state, exact head, and target base from the GitHub response'
        return 1
      }
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 || {
        fail 'could not establish merge request state and head because glab is unavailable'
        return 1
      }
      command -v jq >/dev/null 2>&1 || {
        fail 'could not establish merge request state and head because jq is unavailable'
        return 1
      }
      encoded=${FM_PR_PATH//\//%2F}
      raw=$(glab api --hostname "$FM_PR_HOST" "projects/$encoded/merge_requests/$FM_PR_NUMBER" 2>/dev/null) || {
        fail 'could not establish merge request state and exact head from GitLab'
        return 1
      }
      PR_STATE=$(printf '%s' "$raw" | jq -er '.state | strings') || return 1
      PR_DRAFT=$(printf '%s' "$raw" | jq -er '(.draft // false) | tostring') || return 1
      PR_HEAD=$(printf '%s' "$raw" | jq -er '.sha | strings') || return 1
      PR_BASE=$(printf '%s' "$raw" | jq -r '(.target_branch // "") | strings' 2>/dev/null || true)
      ;;
  esac
  fm_pr_head_valid "$PR_HEAD" || {
    fail 'could not establish the pull request exact head commit from the forge response'
    return 1
  }
  if ! { one_line "$PR_BASE" && git check-ref-format "refs/heads/$PR_BASE" >/dev/null 2>&1; }; then
    fail 'could not establish the pull request target base branch from the forge response'
    return 1
  fi
}

scope_allows_review() {
  local state draft
  state=$(printf '%s' "$PR_STATE" | tr '[:lower:]' '[:upper:]')
  draft=$(printf '%s' "$PR_DRAFT" | tr '[:upper:]' '[:lower:]')
  if [ "$draft" = true ]; then
    fail 'pull request is still a draft; independent review covers finished pull requests only'
    return 1
  fi
  case "$state" in
    OPEN|OPENED) return 0 ;;
    MERGED) fail 'pull request is already merged; independent review never runs on merged work' ;;
    CLOSED) fail 'pull request is closed; independent review covers finished open pull requests only' ;;
    *) fail "could not establish that the pull request is finished and open (state=$PR_STATE)" ;;
  esac
  return 1
}

task_meta_validate() {
  local id=$1 meta=$2 kind
  fm_pr_task_id_valid "$id" || { fail 'invalid independent review task id'; return 1; }
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ "$(fm_pr_file_link_count "$meta")" = 1 ] || {
    fail "could not establish builder metadata for task $id"
    return 1
  }
  kind=$(meta_value "$meta" kind)
  [ "$kind" = ship ] || {
    fail "independent review applies only to finished ship pull requests (kind=${kind:-missing})"
    return 1
  }
}

finished_pr_recorded() {
  local id=$1 url=$2 meta mode current status line payload
  meta="$STATE/$id.meta"
  mode=$(meta_value "$meta" mode)
  case "$mode" in
    no-mistakes|direct-PR) ;;
    *)
      fail "could not establish a supported delivery mode for task $id (mode=${mode:-missing})"
      return 1
      ;;
  esac
  current=$("$FM_ROOT/bin/fm-crew-state.sh" "$id" 2>/dev/null) || current=
  case "$current" in
    state:\ done\ ·\ source:\ *) ;;
    *)
      fail "task $id has not recorded a finished pull request for $url in its current state (${current:-unavailable}); independent review never runs on work in progress"
      return 1
      ;;
  esac
  status="$STATE/$id.status"
  [ -f "$status" ] && [ ! -L "$status" ] && [ "$(fm_pr_file_link_count "$status")" = 1 ] || {
    fail "task $id has not recorded a finished pull request for $url in its current status"
    return 1
  }
  line=$(awk 'NF { value=$0 } END { print value }' "$status")
  case "$line" in
    done:\ *) payload=${line#done: } ;;
    done\ \[key=*\]:\ *) payload=${line#*: } ;;
    *)
      fail "task $id has not recorded a finished pull request for $url in its current status"
      return 1
      ;;
  esac
  case "$mode:$payload" in
    "no-mistakes:PR $url checks green"|"direct-PR:PR $url") return 0 ;;
    *)
      fail "task $id has not recorded a finished pull request for $url in the required mode=$mode form"
      return 1
      ;;
  esac
}

# The reviewer exists to check the original acceptance criteria, so a silently
# truncated extraction is worse than a refusal. The task section ends only at a
# known generated brief heading with its matching scaffold signature; an
# authored heading that collides with a scaffold heading name is retained as
# criteria rather than truncating the extraction. Any other top-level heading
# refuses and names the line, because treating it as criteria would instead
# feed the reviewer builder-side reasoning. Fenced blocks are tracked so a
# heading quoted inside a code fence is criteria rather than a terminator.
extract_task_criteria() {
  local source=$1 destination=$2 reject status
  reject=$(mktemp "$STATE/.fm-independent-review-heading.XXXXXX") || return 1
  set +e
  # bin/fm-brief.sh owns this list of generated Task terminators and signatures.
  awk -v reject="$reject" '
    function is_scaffold_heading(h, next_nb) {
      if (h ~ /^# Herdr isolation - HARD SAFETY CONTRACT[[:space:]]*$/ ||
          h ~ /^# Herdr lifecycle declaration - NOT ENABLED[[:space:]]*$/) {
        return 1
      }
      if (h ~ /^# Setup[[:space:]]*$/) {
        if (next_nb ~ /^You are in a disposable git worktree of/ ||
            next_nb ~ /^\*\*Verify isolation before anything else\.\*\*/) {
          return 1
        }
      }
      if (h ~ /^# Rules[[:space:]]*$/) {
        if (next_nb ~ /^1\. (Never push|First action|Keep changes)/ ||
            next_nb ~ /^RULE 1\./) {
          return 1
        }
      }
      if (h ~ /^# Project memory[[:space:]]*$/) {
        if (next_nb ~ /^A project'\''s `(AGENTS\.md|CLAUDE\.md)` is loaded/ ||
            next_nb ~ /^If `(AGENTS\.md|CLAUDE\.md)` already exists/) {
          return 1
        }
      }
      if (h ~ /^# Definition of done[[:space:]]*$/) {
        if (next_nb ~ /^(Delivery contract:|Write your findings to|Open a pull request\.|BUILDER_REASONING_SENTINEL:|The task is complete only when|You are persistent by default)/) {
          return 1
        }
      }
      return 0
    }

    function is_collision_candidate(h) {
      if (h ~ /^# Herdr isolation - HARD SAFETY CONTRACT[[:space:]]*$/ ||
          h ~ /^# Herdr lifecycle declaration - NOT ENABLED[[:space:]]*$/ ||
          h ~ /^# Setup[[:space:]]*$/ ||
          h ~ /^# Rules[[:space:]]*$/ ||
          h ~ /^# Project memory[[:space:]]*$/ ||
          h ~ /^# Definition of done[[:space:]]*$/) {
        return 1
      }
      return 0
    }

    { lines[NR] = $0 }

    END {
      total = NR
      for (i = 1; i <= total; i++) {
        line = lines[i]
        if (!in_task) {
          if (line ~ /^# Task[[:space:]]*$/) in_task = 1
          continue
        }
        if (line ~ /^```/ || line ~ /^~~~/) {
          fence = !fence
          print line
          continue
        }
        if (fence) {
          print line
          continue
        }
        if (line ~ /^<!--[[:space:]]*fm:task:end[[:space:]]*-->/) {
          terminated = 1
          exit 0
        }
        if (line ~ /^#[[:space:]]+/) {
          next_nb = ""
          for (j = i + 1; j <= total; j++) {
            if (lines[j] ~ /[^[:space:]]/) {
              next_nb = lines[j]
              break
            }
          }
          if (is_scaffold_heading(line, next_nb)) {
            terminated = 1
            exit 0
          }
          if (is_collision_candidate(line)) {
            print line
            continue
          }
          print line > reject
          rejected = 1
          exit 1
        }
        print line
      }
      if (!terminated && !rejected) exit 2
    }
  ' "$source" > "$destination"
  status=$?
  set -e
  case "$status" in
    0) ;;
    1) fail "original task criteria contain an unrecognized top-level heading: $(cat "$reject")" ;;
    *) fail 'original task criteria reach EOF without a recognized generated terminator' ;;
  esac
  rm -f -- "$reject"
  [ "$status" -eq 0 ] || return 1
  [ -s "$destination" ]
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

sha256_digest_valid() {
  [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]
}

validated_sha256() {
  local digest
  digest=$(fm_pr_sha256 "$1") || return 1
  sha256_digest_valid "$digest" || return 1
  printf '%s\n' "$digest"
}

make_review_id() {
  local id=$1 round=$2 head=$3 digest
  digest=$(validated_sha256 <(printf '%s\037%s\037%s' "$id" "$round" "$head")) || return 1
  printf 'ir-%s\n' "${digest:0:61}"
}

authoritative_diff_digest() {
  local worktree=$1 base=$2 head=$3 tmp digest
  git -C "$worktree" fetch --quiet origin \
    "+refs/heads/$base:refs/remotes/origin/$base" || return 1
  tmp=$(mktemp "$STATE/.fm-independent-review-current-diff.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' RETURN
  git -C "$worktree" diff "origin/$base...$head" -- > "$tmp" || return 1
  digest=$(validated_sha256 "$tmp") || return 1
  rm -f -- "$tmp" || return 1
  trap - RETURN
  printf '%s\n' "$digest"
}

round_artifact_owner_path() {
  printf '%s/.firstmate-independent-review-owner\n' "$1"
}

write_round_artifact_owner() {
  local dir=$1 id=$2 round=$3 head=$4 reviewer=$5
  write_lines_file "$(round_artifact_owner_path "$dir")" \
    'format=firstmate-independent-review-owner-v1' \
    "task=$id" \
    "round=$round" \
    "head=$head" \
    "reviewer_task=$reviewer"
}

round_artifact_owned() {
  local dir=$1 id=$2 round=$3 head=$4 reviewer=$5 owner device
  owner=$(round_artifact_owner_path "$dir")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  device=$(fm_pr_file_device "$dir") || return 1
  fm_pr_private_file_valid "$owner" 600 "$device" || return 1
  [ "$(meta_value "$owner" format)" = firstmate-independent-review-owner-v1 ] \
    && [ "$(meta_value "$owner" task)" = "$id" ] \
    && [ "$(meta_value "$owner" round)" = "$round" ] \
    && [ "$(meta_value "$owner" head)" = "$head" ] \
    && [ "$(meta_value "$owner" reviewer_task)" = "$reviewer" ]
}

remove_owned_round_artifacts() {
  local id=$1 round=$2 head=$3 reviewer=$4 artifact
  shift 4
  for artifact in "$@"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    round_artifact_owned "$artifact" "$id" "$round" "$head" "$reviewer" || return 1
  done
  for artifact in "$@"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    rm -rf -- "$artifact" || return 1
  done
}

abort_owned_round() {
  local id=$1 round=$2 head=$3 reviewer=$4 message=$5
  shift 5
  remove_owned_round_artifacts "$id" "$round" "$head" "$reviewer" "$@" \
    || printf 'error: refused to clean up independent review round %s without its ownership binding\n' "$round" >&2
  printf 'error: %s\n' "$message" >&2
  return 1
}

authorized_findings_file() {
  printf '%s/%s.independent-review.authorized-findings\n' "$STATE" "$1"
}

authorized_findings_file_valid() {
  local id=$1 file
  file=$(authorized_findings_file "$id")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  [ "$(meta_value "$file" format)" = firstmate-independent-review-authorized-findings-v1 ] || return 1
  [ "$(meta_value "$file" task)" = "$id" ] || return 1
}

copy_authorized_finding() {
  local file=$1 idx=$2 resolution
  printf 'finding_%s_category=%s\n' "$idx" "$(meta_value "$file" "finding_${idx}_category")"
  printf 'finding_%s=%s\n' "$idx" "$(meta_value "$file" "finding_${idx}")"
  printf 'finding_%s_status=%s\n' "$idx" "$(meta_value "$file" "finding_${idx}_status")"
  resolution=$(meta_value "$file" "finding_${idx}_resolution")
  [ -z "$resolution" ] || printf 'finding_%s_resolution=%s\n' "$idx" "$resolution"
}

record_authorized_finding() {
  local id=$1 category=$2 finding=$3 file tmp count idx existing_fnd found=0
  file=$(authorized_findings_file "$id")
  tmp=$(mktemp "$STATE/.fm-independent-review-findings.XXXXXX") || return 1
  if [ -f "$file" ]; then
    authorized_findings_file_valid "$id" || { rm -f -- "$tmp"; fail "could not validate authorized findings file for $id"; return 1; }
    count=$(meta_value "$file" finding_count)
    idx=1
    while [ "$idx" -le "${count:-0}" ]; do
      existing_fnd=$(meta_value "$file" "finding_${idx}")
      if [ "$existing_fnd" = "$finding" ]; then
        found=1
        break
      fi
      idx=$((idx + 1))
    done
    if [ "$found" -eq 1 ]; then
      idx=1
      {
        printf '%s\n' 'format=firstmate-independent-review-authorized-findings-v1'
        printf 'task=%s\n' "$id"
        printf 'finding_count=%s\n' "$count"
        while [ "$idx" -le "${count:-0}" ]; do
          if [ "$(meta_value "$file" "finding_${idx}")" = "$finding" ]; then
            printf 'finding_%s_category=%s\n' "$idx" "$category"
            printf 'finding_%s=%s\n' "$idx" "$finding"
            printf 'finding_%s_status=pending\n' "$idx"
          else
            copy_authorized_finding "$file" "$idx"
          fi
          idx=$((idx + 1))
        done
      } > "$tmp"
      private_file_write "$file" "$tmp" || { rm -f -- "$tmp"; return 1; }
      rm -f -- "$tmp"
      return 0
    fi
  else
    count=0
  fi

  count=$((count + 1))
  {
    printf '%s\n' 'format=firstmate-independent-review-authorized-findings-v1'
    printf 'task=%s\n' "$id"
    printf 'finding_count=%s\n' "$count"
    idx=1
    while [ "$idx" -lt "$count" ]; do
      copy_authorized_finding "$file" "$idx"
      idx=$((idx + 1))
    done
    printf 'finding_%s_category=%s\n' "$count" "$category"
    printf 'finding_%s=%s\n' "$count" "$finding"
    printf 'finding_%s_status=pending\n' "$count"
  } > "$tmp"
  private_file_write "$file" "$tmp" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
}

resolve_authorized_finding() {
  local id=$1 finding=$2 reason=$3 file tmp count idx existing_fnd found=0
  file=$(authorized_findings_file "$id")
  [ -f "$file" ] || { fail "no authorized findings recorded for task $id"; return 1; }
  authorized_findings_file_valid "$id" || { fail "could not validate authorized findings file for $id"; return 1; }
  count=$(meta_value "$file" finding_count)
  idx=1
  while [ "$idx" -le "${count:-0}" ]; do
    existing_fnd=$(meta_value "$file" "finding_${idx}")
    if [ "$existing_fnd" = "$finding" ]; then
      found=1
      break
    fi
    idx=$((idx + 1))
  done
  [ "$found" -eq 1 ] || { fail "authorized finding not found for task $id: $finding"; return 1; }

  tmp=$(mktemp "$STATE/.fm-independent-review-findings.XXXXXX") || return 1
  {
    printf '%s\n' 'format=firstmate-independent-review-authorized-findings-v1'
    printf 'task=%s\n' "$id"
    printf 'finding_count=%s\n' "$count"
    idx=1
    while [ "$idx" -le "${count:-0}" ]; do
      if [ "$(meta_value "$file" "finding_${idx}")" = "$finding" ]; then
        printf 'finding_%s_category=%s\n' "$idx" "$(meta_value "$file" "finding_${idx}_category")"
        printf 'finding_%s=%s\n' "$idx" "$finding"
        printf 'finding_%s_status=resolved\n' "$idx"
        [ -z "$reason" ] || printf 'finding_%s_resolution=%s\n' "$idx" "$reason"
      else
        copy_authorized_finding "$file" "$idx"
      fi
      idx=$((idx + 1))
    done
  } > "$tmp"
  private_file_write "$file" "$tmp" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
}

has_unresolved_authorized_findings() {
  local id=$1 file count idx status
  file=$(authorized_findings_file "$id")
  [ -f "$file" ] || return 1
  count=$(meta_value "$file" finding_count)
  idx=1
  while [ "$idx" -le "${count:-0}" ]; do
    status=$(meta_value "$file" "finding_${idx}_status")
    if [ "$status" = pending ]; then
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

print_unresolved_authorized_findings() {
  local id=$1 file count idx category finding status
  file=$(authorized_findings_file "$id")
  [ -f "$file" ] || return 0
  count=$(meta_value "$file" finding_count)
  idx=1
  while [ "$idx" -le "${count:-0}" ]; do
    status=$(meta_value "$file" "finding_${idx}_status")
    if [ "$status" = pending ]; then
      category=$(meta_value "$file" "finding_${idx}_category")
      finding=$(meta_value "$file" "finding_${idx}")
      printf 'blocker: %s: %s\n' "$category" "$finding" >&2
    fi
    idx=$((idx + 1))
  done
}

add_finding_command() {
  local id=${1:-} category=${2:-} finding=${3:-}
  [ "$#" -eq 3 ] || { usage >&2; return 2; }
  fm_pr_task_id_valid "$id" || { fail 'invalid independent review task id'; return 1; }
  case "$category" in correctness|security|privacy|data-loss|acceptance) ;; *) fail "invalid blocking category: $category"; return 1 ;; esac
  one_line "$finding" && [ "${#finding}" -le 1000 ] || { fail 'finding must be one line and at most 1000 characters'; return 1; }
  record_authorized_finding "$id" "$category" "$finding" || return 1
  printf 'recorded authorized finding for %s: %s: %s\n' "$id" "$category" "$finding"
}

resolve_finding_command() {
  local id=${1:-} finding=${2:-} reason=${3:-}
  [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || { usage >&2; return 2; }
  fm_pr_task_id_valid "$id" || { fail 'invalid independent review task id'; return 1; }
  one_line "$finding" && [ "${#finding}" -le 1000 ] || { fail 'finding must be one line and at most 1000 characters'; return 1; }
  [ -z "$reason" ] || { one_line "$reason" && [ "${#reason}" -le 1000 ]; } || { fail 'resolution reason must be one line and at most 1000 characters'; return 1; }
  resolve_authorized_finding "$id" "$finding" "$reason" || return 1
  printf 'resolved authorized finding for %s: %s\n' "$id" "$finding"
}

retire_failed_hint() {
  printf '%s retire-failed %s %s\n' "$SCRIPT_DIR/fm-independent-review.sh" "$1" "$2"
}

retire_failed_command() {
  local id=${1:-} round=${2:-} round_file bundle reviewer head review_dir brief criteria diff
  local verdict verdict_round last_status stage expected_reviewer
  [ "$#" -eq 2 ] || { usage >&2; return 2; }
  fm_pr_task_id_valid "$id" || { fail 'invalid independent review task id'; return 1; }
  case "$round" in 1|2) ;; *) fail 'independent review round must be 1 or 2'; return 1 ;; esac

  round_file="$STATE/$id.independent-review.round-$round"
  bundle="$STATE/$id.independent-review.bundle-$round"
  [ -f "$round_file" ] && [ ! -L "$round_file" ] \
    && [ "$(fm_pr_file_link_count "$round_file")" = 1 ] || {
      fail "could not validate independent review round $round state"
      return 1
    }
  [ "$(meta_value "$round_file" format)" = firstmate-independent-review-round-v1 ] \
    && [ "$(meta_value "$round_file" task)" = "$id" ] \
    && [ "$(meta_value "$round_file" round)" = "$round" ] || {
      fail "could not validate independent review round $round state"
      return 1
  }
  head=$(meta_value "$round_file" head)
  reviewer=$(meta_value "$round_file" reviewer_task)
  expected_reviewer=$(make_review_id "$id" "$round" "$head") || {
    fail "could not validate independent review round $round ownership"
    return 1
  }
  fm_pr_head_valid "$head" \
    && [ "$reviewer" = "$expected_reviewer" ] || {
      fail "could not validate independent review round $round ownership"
      return 1
    }
  review_dir="$DATA/$reviewer"
  brief="$review_dir/brief.md"
  criteria="$bundle/criteria.md"
  diff="$bundle/diff.patch"
  [ "$(meta_value "$round_file" brief)" = "$brief" ] \
    && [ "$(meta_value "$round_file" criteria)" = "$criteria" ] \
    && [ "$(meta_value "$round_file" diff)" = "$diff" ] || {
      fail "could not validate independent review round $round artifact ownership"
      return 1
    }
  last_status=$(meta_value "$round_file" status)
  case "$last_status" in
    launch-failed|launching|pending) ;;
    *) fail "independent review round $round is not failed or abandoned"; return 1 ;;
  esac

  verdict="$STATE/$id.independent-review.verdict"
  if [ -e "$verdict" ] || [ -L "$verdict" ]; then
    [ -f "$verdict" ] && [ ! -L "$verdict" ] \
      && [ "$(fm_pr_file_link_count "$verdict")" = 1 ] \
      && [ "$(meta_value "$verdict" format)" = firstmate-independent-review-verdict-v1 ] \
      && [ "$(meta_value "$verdict" task)" = "$id" ] || {
        fail 'could not validate the promoted independent review verdict'
        return 1
      }
    verdict_round=$(meta_value "$verdict" round)
    case "$verdict_round" in 1|2) ;; *) fail 'could not validate the promoted independent review verdict'; return 1 ;; esac
    if [ "$verdict_round" -ge "$round" ]; then
      fail "independent review round $round has a promoted verdict and cannot be retired"
      return 1
    fi
  fi
  if [ "$round" = 1 ] && { [ -e "$STATE/$id.independent-review.round-2" ] \
    || [ -L "$STATE/$id.independent-review.round-2" ]; }; then
    fail 'independent review round 1 cannot be retired after round 2 exists'
    return 1
  fi
  [ -d "$bundle" ] && [ ! -L "$bundle" ] \
    && [ -f "$criteria" ] && [ ! -L "$criteria" ] \
    && [ -f "$diff" ] && [ ! -L "$diff" ] || {
      fail "could not validate independent review bundle $round"
      return 1
    }
  [ -d "$review_dir" ] && [ ! -L "$review_dir" ] \
    && [ -f "$brief" ] && [ ! -L "$brief" ] || {
      fail "could not validate reviewer data for independent review round $round"
      return 1
    }
  if ! { round_artifact_owned "$bundle" "$id" "$round" "$head" "$reviewer" \
    && round_artifact_owned "$review_dir" "$id" "$round" "$head" "$reviewer"; }; then
    fail "could not validate independent review round $round artifact ownership binding"
    return 1
  fi

  stage=$(mktemp -d "$STATE/.fm-independent-review-retire.XXXXXX") || return 1
  if ! mv -- "$bundle" "$stage/bundle"; then
    rmdir -- "$stage" 2>/dev/null || true
    fail "could not retire independent review bundle $round"
    return 1
  fi
  if ! mv -- "$review_dir" "$stage/reviewer-data"; then
    mv -- "$stage/bundle" "$bundle" 2>/dev/null \
      || printf 'error: could not restore independent review bundle %s after failed retirement\n' "$round" >&2
    rmdir -- "$stage" 2>/dev/null || true
    fail "could not retire reviewer data for independent review round $round"
    return 1
  fi
  if ! mv -- "$round_file" "$stage/round"; then
    mv -- "$stage/reviewer-data" "$review_dir" 2>/dev/null \
      || printf 'error: could not restore reviewer data for independent review round %s\n' "$round" >&2
    mv -- "$stage/bundle" "$bundle" 2>/dev/null \
      || printf 'error: could not restore independent review bundle %s\n' "$round" >&2
    rmdir -- "$stage" 2>/dev/null || true
    fail "could not retire independent review round $round state"
    return 1
  fi
  rm -rf -- "$stage" \
    || printf 'warning: retired independent review round %s but could not remove its staged artifacts\n' "$round" >&2
  printf 'retired failed independent review round: task=%s round=%s reviewer=%s\n' \
    "$id" "$round" "$reviewer"
}

reviewer_verdict_path() {
  printf '%s\n' "$DATA/$1/independent-review-verdict"
}

# The reviewer's prescribed completion line names the verdict it submitted, so a
# result seeded by anyone else is promoted only if the reviewer independently
# attests to that same verdict.
reviewer_done_line() {
  printf 'done: independent review %s for %s at %s\n' "$1" "$2" "$3"
}

write_reviewer_brief() {
  local brief=$1 parent=$2 reviewer=$3 head=$4 criteria=$5 diff=$6 report=$7 status=$8
  local submit_command decision_command q_fm_home q_state q_data q_submit_script q_decision_script
  printf -v q_fm_home '%q' "$FM_HOME"
  printf -v q_state '%q' "$STATE"
  printf -v q_data '%q' "$DATA"
  printf -v q_submit_script '%q' "$SCRIPT_DIR/fm-independent-review.sh"
  printf -v q_decision_script '%q' "$CODE_ROOT/bin/fm-decision-hold.sh"
  submit_command="FM_HOME=$q_fm_home FM_STATE_OVERRIDE=$q_state FM_DATA_OVERRIDE=$q_data $q_submit_script submit '$parent' '$reviewer' '$head'"
  decision_command="FM_HOME=$q_fm_home FM_STATE_OVERRIDE=$q_state FM_DATA_OVERRIDE=$q_data $q_decision_script complete '$reviewer' --none"
  cat > "$brief" <<EOF
You are an independent cold reviewer managed by firstmate.
Work autonomously and do not wait for a human.

# Review boundary

Read only these two immutable artifacts:

- Original task acceptance criteria: $criteria
- Exact pull request diff for head $head: $diff

Do not inspect the repository, builder messages, status history, pipeline output, summaries, or any previous review.
Your job is to try to refute the change rather than approve it.
Keep the review short and bounded to the supplied criteria and diff.

Block only on confirmed correctness, security, privacy, data loss, or unmet acceptance criteria.
Record every other concern as a non-blocking follow-up.
Uncertainty is not a confirmed blocker: state the missing evidence as a follow-up unless the supplied diff itself proves an in-scope failure.

# Verdict

Submit exactly one verdict against head $head.
For a clear result, run:

  $submit_command clear '<one-line summary>' [--follow-up '<one-line note>']

For a rejection, run:

  $submit_command reject '<one-line summary>' --block <correctness|security|privacy|data-loss|acceptance> '<one-line finding>' [additional --block or --follow-up arguments]

That command records your result as this review's own deliverable and settles nothing by itself.
Firstmate ignores it until you finish the two completion steps below, so run all three yourself, in order, and never let another agent submit for you.

Never edit, comment on, approve, merge, close, or re-run anything on the pull request.
Never fix the finding yourself.
Write the same bounded result to $report, then run:

  $decision_command

Then append to $status exactly the one line below that names the verdict you submitted:

  $(reviewer_done_line clear "$parent" "$head")
  $(reviewer_done_line reject "$parent" "$head")

Firstmate promotes your result only when that line names the same verdict you submitted, so never append the other one.

Stop after that line.
EOF
}

# A round that never reached its recorded state must leave nothing behind, or
# the next readiness call would resume a round with no reviewer.
abort_unrecorded_round() {
  local round=$1 message=$2
  shift 2
  rm -rf -- "$@" \
    || printf 'error: could not clean up incomplete independent review round %s\n' "$round" >&2
  printf 'error: %s\n' "$message" >&2
  return 1
}

start_review() {
  local id=$1 url=$2 round=$3 meta=$4 builder_harness=$5 builder_model=$6 builder_family=$7
  local worktree project task_brief review_id review_dir review_tmp bundle_tmp bundle criteria diff
  local brief report status base ref fetched max_diff max_criteria diff_digest round_file spawn_status
  local -a spawn_args
  worktree=$(meta_value "$meta" worktree)
  project=$(meta_value "$meta" project)
  [ -d "$worktree" ] || { fail "could not establish builder worktree for task $id"; return 1; }
  [ -d "$project" ] || { fail "could not establish builder project for task $id"; return 1; }
  task_brief="$DATA/$id/brief.md"
  [ -f "$task_brief" ] && [ ! -L "$task_brief" ] || {
    fail "could not establish original acceptance criteria at $task_brief"
    return 1
  }
  select_reviewer "$builder_family" || {
    fail "could not establish an available verified different-family reviewer for builder family '$builder_family'"
    return 1
  }

  review_id=$(make_review_id "$id" "$round" "$PR_HEAD") || {
    fail 'could not derive a safe reviewer task id'
    return 1
  }
  fm_task_id_creation_valid "$review_id" || { fail 'could not derive a safe reviewer task id'; return 1; }
  round_file="$STATE/$id.independent-review.round-$round"
  bundle="$STATE/$id.independent-review.bundle-$round"
  review_dir="$DATA/$review_id"
  if [ ! -e "$round_file" ] && [ ! -L "$round_file" ] \
    && { [ -e "$bundle" ] || [ -L "$bundle" ] || [ -e "$review_dir" ] || [ -L "$review_dir" ]; }; then
    if [ -L "$bundle" ] || { [ -e "$bundle" ] && [ ! -d "$bundle" ]; } \
      || [ -L "$review_dir" ] || { [ -e "$review_dir" ] && [ ! -d "$review_dir" ]; }; then
      fail "could not recover incomplete independent review round $round artifacts"
      return 1
    fi
    remove_owned_round_artifacts "$id" "$round" "$PR_HEAD" "$review_id" "$bundle" "$review_dir" || {
      fail "could not recover incomplete independent review round $round artifacts without their ownership binding"
      return 1
    }
  fi
  [ ! -e "$round_file" ] && [ ! -L "$round_file" ] || {
    fail "independent review round $round already exists and cannot be replaced"
    return 1
  }
  [ ! -e "$bundle" ] && [ ! -L "$bundle" ] || {
    fail "independent review bundle $round already exists and cannot be replaced"
    return 1
  }

  bundle_tmp=$(mktemp -d "$STATE/.fm-independent-review-bundle.XXXXXX") || return 1
  criteria="$bundle_tmp/criteria.md"
  diff="$bundle_tmp/diff.patch"
  extract_task_criteria "$task_brief" "$criteria" || {
    abort_unrecorded_round "$round" "could not establish original task criteria from $task_brief" "$bundle_tmp"
    return 1
  }
  max_criteria=${FM_INDEPENDENT_REVIEW_MAX_CRITERIA_BYTES:-131072}
  [ "$(file_size "$criteria")" -le "$max_criteria" ] || {
    abort_unrecorded_round "$round" "original task criteria exceed the bounded review limit of $max_criteria bytes" "$bundle_tmp"
    return 1
  }

  case "$FM_PR_PROVIDER" in
    github) ref="refs/pull/$FM_PR_NUMBER/head" ;;
    gitlab) ref="refs/merge-requests/$FM_PR_NUMBER/head" ;;
  esac
  git -C "$worktree" fetch --quiet origin "+$ref:refs/fm-independent-review/head" || {
    abort_unrecorded_round "$round" "could not fetch the exact pull request head $ref for bounded review" "$bundle_tmp"
    return 1
  }
  fetched=$(git -C "$worktree" rev-parse --verify 'refs/fm-independent-review/head^{commit}' 2>/dev/null) || {
    abort_unrecorded_round "$round" 'could not resolve the fetched pull request head commit' "$bundle_tmp"
    return 1
  }
  [ "$fetched" = "$PR_HEAD" ] || {
    abort_unrecorded_round "$round" "pull request head changed while the review bundle was prepared (forge=$PR_HEAD fetched=$fetched); retry" "$bundle_tmp"
    return 1
  }
  git -C "$worktree" fetch --quiet origin "+refs/heads/$PR_BASE:refs/remotes/origin/$PR_BASE" || {
    abort_unrecorded_round "$round" "could not fetch the pull request target base branch origin/$PR_BASE" "$bundle_tmp"
    return 1
  }
  base="origin/$PR_BASE"
  git -C "$worktree" diff "$base...$PR_HEAD" -- > "$diff" || {
    abort_unrecorded_round "$round" 'could not produce the exact pull request diff for independent review' "$bundle_tmp"
    return 1
  }
  [ -s "$diff" ] || {
    abort_unrecorded_round "$round" 'pull request has no diff against its authoritative base' "$bundle_tmp"
    return 1
  }
  max_diff=${FM_INDEPENDENT_REVIEW_MAX_DIFF_BYTES:-524288}
  [ "$(file_size "$diff")" -le "$max_diff" ] || {
    abort_unrecorded_round "$round" "pull request diff exceeds the bounded review limit of $max_diff bytes" "$bundle_tmp"
    return 1
  }
  diff_digest=$(validated_sha256 "$diff") || {
    abort_unrecorded_round "$round" 'could not bind the independent review bundle to its exact diff' "$bundle_tmp"
    return 1
  }
  write_round_artifact_owner "$bundle_tmp" "$id" "$round" "$PR_HEAD" "$review_id" || {
    abort_unrecorded_round "$round" "could not record independent review bundle $round ownership" "$bundle_tmp"
    return 1
  }
  chmod 0600 "$criteria" "$diff"
  mv -- "$bundle_tmp" "$bundle"
  criteria="$bundle/criteria.md"
  diff="$bundle/diff.patch"

  if [ -e "$review_dir" ] || [ -L "$review_dir" ]; then
    abort_owned_round "$id" "$round" "$PR_HEAD" "$review_id" \
      "reviewer data path is unavailable: $review_dir" "$bundle" "$review_dir"
    return 1
  fi
  review_tmp=$(mktemp -d "$DATA/.fm-independent-review-reviewer.XXXXXX") || {
    abort_owned_round "$id" "$round" "$PR_HEAD" "$review_id" \
      "could not create reviewer data path: $review_dir" "$bundle"
    return 1
  }
  if ! write_round_artifact_owner "$review_tmp" "$id" "$round" "$PR_HEAD" "$review_id"; then
    rm -rf -- "$review_tmp"
    abort_owned_round "$id" "$round" "$PR_HEAD" "$review_id" \
      "could not record reviewer data ownership: $review_dir" "$bundle"
    return 1
  fi
  if ! mv -- "$review_tmp" "$review_dir"; then
    abort_owned_round "$id" "$round" "$PR_HEAD" "$review_id" \
      "could not publish reviewer data path: $review_dir" "$bundle" "$review_tmp"
    return 1
  fi
  brief="$review_dir/brief.md"
  report="$review_dir/report.md"
  status="$STATE/$review_id.status"
  [ ! -e "$brief" ] && [ ! -L "$brief" ] || {
    abort_owned_round "$id" "$round" "$PR_HEAD" "$review_id" \
      "reviewer brief already exists and cannot be replaced: $brief" "$bundle" "$review_dir"
    return 1
  }
  if ! { write_reviewer_brief "$brief" "$id" "$review_id" "$PR_HEAD" "$criteria" "$diff" "$report" "$status" \
    && chmod 0600 "$brief"; }; then
    abort_owned_round "$id" "$round" "$PR_HEAD" "$review_id" \
      "could not write reviewer brief: $brief" "$bundle" "$review_dir"
    return 1
  fi

  write_lines_file "$round_file" \
    'format=firstmate-independent-review-round-v1' \
    "task=$id" \
    "pr=$url" \
    "round=$round" \
    "head=$PR_HEAD" \
    "base=$PR_BASE" \
    "diff_digest=$diff_digest" \
    "builder_harness=$builder_harness" \
    "builder_model=$builder_model" \
    "builder_family=$builder_family" \
    "reviewer_task=$review_id" \
    "reviewer_harness=$SELECTED_HARNESS" \
    "reviewer_model=$SELECTED_MODEL" \
    "reviewer_family=$SELECTED_FAMILY" \
    "criteria=$criteria" \
    "diff=$diff" \
    "brief=$brief" \
    'status=launching' || {
      abort_owned_round "$id" "$round" "$PR_HEAD" "$review_id" \
        "could not record independent review round $round" "$bundle" "$review_dir"
      return 1
    }

  spawn_args=("$review_id" "$project" --harness "$SELECTED_HARNESS")
  [ "$SELECTED_MODEL" = default ] || spawn_args+=(--model "$SELECTED_MODEL")
  spawn_args+=(--effort "$SELECTED_EFFORT" --scout)
  set +e
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$FM_ROOT/bin/fm-spawn.sh" "${spawn_args[@]}"
  spawn_status=$?
  set -e
  if [ "$spawn_status" -ne 0 ]; then
    printf '%s\n' 'status=launch-failed' >> "$round_file"
    fail "different-family reviewer launch failed for round $round; run $(retire_failed_hint "$id" "$round") to allow a fresh reviewer"
    return 1
  fi
  printf '%s\n' 'status=pending' >> "$round_file"
  printf 'independent review started: round %s reviewer=%s family=%s head=%s\n' \
    "$round" "$review_id" "$SELECTED_FAMILY" "$PR_HEAD"
  return 3
}

verdict_matches_round() {
  local verdict=$1 round_file=$2 key
  [ -f "$verdict" ] && [ ! -L "$verdict" ] || return 1
  [ "$(meta_value "$verdict" format)" = firstmate-independent-review-verdict-v1 ] || return 1
  for key in task pr round head builder_family reviewer_family reviewer_task; do
    [ "$(meta_value "$verdict" "$key")" = "$(meta_value "$round_file" "$key")" ] || return 1
  done
}

# Firstmate's own supervision evidence that the reviewer it spawned finished the
# round: the decision-hold completion attestation written into the reviewer's
# task metadata by bin/fm-decision-hold.sh complete, and the exact done line the
# generated brief prescribes. Neither is a capability an agent can be handed.
reviewer_completed_round() {
  local reviewer=$1 parent=$2 head=$3 result=$4 meta status expected line
  meta="$STATE/$reviewer.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(meta_value "$meta" decisions_reviewed)" = 1 ] || return 1
  status="$STATE/$reviewer.status"
  [ -f "$status" ] && [ ! -L "$status" ] || return 1
  expected=$(reviewer_done_line "$result" "$parent" "$head")
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "$expected" ] || return 0
  done < "$status"
  return 1
}

# Promote this round's reviewer deliverable to the task verdict, or leave the
# round pending. A deliverable that exists without its supervised completion is
# not a verdict, so nothing an agent writes alone can clear a head.
promote_round_verdict() {
  local id=$1 round_file=$2 verdict=$3 reviewer proposal blocker_count idx cat fnd
  reviewer=$(meta_value "$round_file" reviewer_task)
  fm_pr_task_id_valid "$reviewer" || return 1
  proposal=$(reviewer_verdict_path "$reviewer")
  [ -f "$proposal" ] && [ ! -L "$proposal" ] || return 1
  verdict_matches_round "$proposal" "$round_file" || return 1
  reviewer_completed_round "$reviewer" "$id" "$(meta_value "$round_file" head)" \
    "$(meta_value "$proposal" verdict)" || return 1
  private_file_write "$verdict" "$proposal" || return 2
  if [ "$(meta_value "$verdict" verdict)" = reject ]; then
    blocker_count=$(meta_value "$verdict" blocker_count)
    idx=1
    while [ "$idx" -le "${blocker_count:-0}" ]; do
      cat=$(meta_value "$verdict" "blocker_${idx}_category")
      fnd=$(meta_value "$verdict" "blocker_${idx}")
      record_authorized_finding "$id" "$cat" "$fnd" || return 2
      idx=$((idx + 1))
    done
  fi
}

print_rejection() {
  local verdict=$1 round=$2 count idx category finding
  count=$(meta_value "$verdict" blocker_count)
  printf 'error: independent review by %s rejected head %s: %s\n' \
    "$(meta_value "$verdict" reviewer_task)" "$(meta_value "$verdict" head)" \
    "$(meta_value "$verdict" summary)" >&2
  idx=1
  while [ "$idx" -le "${count:-0}" ]; do
    category=$(meta_value "$verdict" "blocker_${idx}_category")
    finding=$(meta_value "$verdict" "blocker_${idx}")
    printf 'blocker: %s: %s\n' "$category" "$finding" >&2
    idx=$((idx + 1))
  done
  if [ "$round" -ge 2 ]; then
    printf 'error: second rejection opened the circuit; stop and re-scope the design instead of producing a third fix round\n' >&2
  fi
}

write_head_file() {
  local destination=$1 head=$2
  [ -n "$destination" ] || return 0
  [ ! -L "$destination" ] || return 1
  if [ -e "$destination" ]; then
    [ -f "$destination" ] && [ "$(fm_pr_file_link_count "$destination")" = 1 ] || return 1
  fi
  printf '%s\n' "$head" > "$destination" || return 1
  chmod 0600 "$destination" || return 1
}

print_clear_verdict() {
  local verdict=$1 reviewer_id
  reviewer_id=$(meta_value "$verdict" reviewer_harness)
  [ "$(meta_value "$verdict" reviewer_model)" = default ] \
    || reviewer_id="$reviewer_id/$(meta_value "$verdict" reviewer_model)"
  printf 'Independent review: %s via %s (%s family) - %s\n' \
    "$(meta_value "$verdict" reviewer_task)" "$reviewer_id" \
    "$(meta_value "$verdict" reviewer_family)" "$(meta_value "$verdict" summary)"
}

resolve_builder_family() {
  local harness=$1 model=$2
  if model_family "$harness" "$model"; then
    return 0
  fi
  case "$harness" in
    cursor|pi|pi-signed|opencode)
      if [ "$model" = default ]; then
        fail "could not establish builder model family: harness=$harness requires a recorded model with a verified provider family"
      else
        fail "could not establish builder model family: harness=$harness model=$model has no verified provider-family mapping"
      fi
      ;;
    *) fail "could not establish builder model family from harness=$harness model=$model" ;;
  esac
  return 1
}

ready_command() {
  local id=${1:-} url=${2:-} head_file='' meta builder_harness builder_model builder_family
  local round=0 round_file='' verdict verdict_round verdict_value last_status reviewer_id promotion_status
  local worktree round_diff_digest current_diff_digest diff_matches=1
  [ -n "$id" ] && [ -n "$url" ] || { usage >&2; return 2; }
  shift 2
  if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --head-file ] || { usage >&2; return 2; }
    head_file=$2
  fi
  meta="$STATE/$id.meta"
  task_meta_validate "$id" "$meta" || return 1
  fm_pr_url_parse "$url" || { fail 'invalid pull request URL for independent review'; return 1; }
  finished_pr_recorded "$id" "$url" || return 1
  inspect_pr "$url" || return 1
  scope_allows_review || return 1

  builder_harness=$(meta_value "$meta" harness)
  builder_model=$(meta_value "$meta" model)
  [ -n "$builder_harness" ] || {
    fail "could not establish builder harness from state/$id.meta"
    return 1
  }
  [ -n "$builder_model" ] || builder_model=default
  builder_family=$(resolve_builder_family "$builder_harness" "$builder_model") || return 1

  if [ -f "$STATE/$id.independent-review.round-2" ]; then
    round=2
  elif [ -f "$STATE/$id.independent-review.round-1" ]; then
    round=1
  fi
  verdict="$STATE/$id.independent-review.verdict"
  verdict_round=0
  verdict_value=
  if [ -f "$verdict" ]; then
    verdict_round=$(meta_value "$verdict" round)
    verdict_value=$(meta_value "$verdict" verdict)
  fi

  if [ "$round" -gt 0 ]; then
    round_file="$STATE/$id.independent-review.round-$round"
    [ "$(meta_value "$round_file" format)" = firstmate-independent-review-round-v1 ] || {
      fail "could not validate independent review round $round state"
      return 1
    }
    [ "$(meta_value "$round_file" task)" = "$id" ] \
      && [ "$(meta_value "$round_file" pr)" = "$url" ] || {
        fail "independent review round $round is bound to another task or pull request"
        return 1
      }
    if ! { one_line "$(meta_value "$round_file" base)" \
      && git check-ref-format "refs/heads/$(meta_value "$round_file" base)" >/dev/null 2>&1; }; then
      fail "could not validate independent review round $round target base"
      return 1
    fi
    round_diff_digest=$(meta_value "$round_file" diff_digest)
    sha256_digest_valid "$round_diff_digest" || {
      fail "could not validate independent review round $round diff binding"
      return 1
    }
    reviewer_id=$(meta_value "$round_file" reviewer_task)
    if [ "$verdict_round" != "$round" ]; then
      if promote_round_verdict "$id" "$round_file" "$verdict"; then
        verdict_round=$(meta_value "$verdict" round)
        verdict_value=$(meta_value "$verdict" verdict)
      else
        promotion_status=$?
        if [ "$promotion_status" -eq 2 ]; then
          fail "could not store promoted independent review verdict for round $round"
          return 1
        fi
      fi
    fi

    if [ "$(meta_value "$round_file" head)" = "$PR_HEAD" ] \
      && [ "$(meta_value "$round_file" base)" = "$PR_BASE" ] \
      && [ "$verdict_round" = "$round" ]; then
      worktree=$(meta_value "$meta" worktree)
      current_diff_digest=$(authoritative_diff_digest "$worktree" "$PR_BASE" "$PR_HEAD") || {
        fail 'could not recompute the current pull request diff for independent review'
        return 1
      }
      [ "$current_diff_digest" = "$round_diff_digest" ] || diff_matches=0
    fi

    if [ "$(meta_value "$round_file" head)" = "$PR_HEAD" ] \
      && [ "$(meta_value "$round_file" base)" = "$PR_BASE" ] \
      && [ "$diff_matches" = 1 ]; then
      if [ "$verdict_round" = "$round" ]; then
        verdict_matches_round "$verdict" "$round_file" || {
          fail "could not validate independent review verdict for round $round"
          return 1
        }
        case "$verdict_value" in
          clear)
            [ "$(meta_value "$verdict" builder_family)" != "$(meta_value "$verdict" reviewer_family)" ] || {
              fail 'independent review verdict used the builder model family'
              return 1
            }
            if [ -e "$(authorized_findings_file "$id")" ] || [ -L "$(authorized_findings_file "$id")" ]; then
              authorized_findings_file_valid "$id" || {
                fail "could not validate authorized findings file for $id"
                return 1
              }
            fi
            if has_unresolved_authorized_findings "$id"; then
              printf 'error: independent review cannot clear: authorized finding was dropped without resolution\n' >&2
              print_unresolved_authorized_findings "$id"
              return 1
            fi
            write_head_file "$head_file" "$PR_HEAD" || {
              fail 'could not publish the reviewed head binding for the readiness caller'
              return 1
            }
            print_clear_verdict "$verdict"
            return 0
            ;;
          reject)
            print_rejection "$verdict" "$round"
            return 1
            ;;
          *) fail "independent review verdict has an unknown result: $verdict_value"; return 1 ;;
        esac
      fi
      last_status=$(meta_value "$round_file" status)
      if [ "$last_status" = launch-failed ]; then
        fail "different-family reviewer launch failed for round $round; run $(retire_failed_hint "$id" "$round") to allow a fresh reviewer"
        return 1
      fi
      if [ -f "$(reviewer_verdict_path "$reviewer_id")" ]; then
        printf 'independent review pending: round %s head=%s reviewer=%s recorded a result but has not completed its supervised review; its decision completion and done line are still missing\n' \
          "$round" "$PR_HEAD" "$reviewer_id" >&2
      else
        printf 'independent review pending: round %s head=%s reviewer=%s; if that reviewer is gone, run %s and retry\n' \
          "$round" "$PR_HEAD" "$reviewer_id" "$(retire_failed_hint "$id" "$round")" >&2
      fi
      return 3
    fi

    if [ "$verdict_round" != "$round" ]; then
      printf 'independent review pending for prior head %s base=%s; current head %s base=%s remains not ready; if reviewer %s is gone, run %s and retry\n' \
        "$(meta_value "$round_file" head)" "$(meta_value "$round_file" base)" \
        "$PR_HEAD" "$PR_BASE" "$reviewer_id" \
        "$(retire_failed_hint "$id" "$round")" >&2
      return 3
    fi
    verdict_matches_round "$verdict" "$round_file" || {
      fail "could not validate completed independent review round $round"
      return 1
    }
    if [ "$round" -ge 2 ]; then
      fail 'pull request head, target base, or reviewed diff changed after two review rounds; the circuit is open and the work must be re-scoped'
      return 1
    fi
  fi

  start_review "$id" "$url" "$((round + 1))" "$meta" \
    "$builder_harness" "$builder_model" "$builder_family"
}

submit_command() {
  local id=${1:-} reviewer=${2:-} head=${3:-} verdict_value=${4:-} summary=${5:-}
  local round round_file parent_meta reviewer_meta builder_harness builder_model builder_family
  local reviewer_harness reviewer_model reviewer_family proposal result_file arg category finding idx
  local blocker_count=0 follow_count=0
  local -a blocker_categories=() blockers=() followups=()
  if [ -z "$id" ] || [ -z "$reviewer" ] || [ -z "$head" ] || [ -z "$verdict_value" ] \
    || ! one_line "$summary"; then
    usage >&2
    return 2
  fi
  if ! fm_pr_task_id_valid "$id" || ! fm_pr_task_id_valid "$reviewer" \
    || ! fm_pr_head_valid "$head"; then
    fail 'invalid independent review submission identity'
    return 1
  fi
  case "$verdict_value" in clear|reject) ;; *) fail 'review verdict must be clear or reject'; return 1 ;; esac
  [ "${#summary}" -le 500 ] || { fail 'review summary must be 500 characters or fewer'; return 1; }
  shift 5
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --block)
        [ "$#" -ge 3 ] || { usage >&2; return 2; }
        category=$2
        finding=$3
        case "$category" in correctness|security|privacy|data-loss|acceptance) ;; *) fail "invalid blocking category: $category"; return 1 ;; esac
        one_line "$finding" && [ "${#finding}" -le 1000 ] || { fail 'blocking finding must be one line and at most 1000 characters'; return 1; }
        blocker_categories+=("$category")
        blockers+=("$finding")
        blocker_count=$((blocker_count + 1))
        shift 3
        ;;
      --follow-up)
        [ "$#" -ge 2 ] || { usage >&2; return 2; }
        one_line "$2" && [ "${#2}" -le 1000 ] || { fail 'follow-up must be one line and at most 1000 characters'; return 1; }
        followups+=("$2")
        follow_count=$((follow_count + 1))
        shift 2
        ;;
      *) usage >&2; return 2 ;;
    esac
  done
  if [ "$verdict_value" = clear ] && [ "$blocker_count" -ne 0 ]; then
    fail 'a clear verdict cannot carry blocking findings'
    return 1
  fi
  if [ "$verdict_value" = reject ] && [ "$blocker_count" -eq 0 ]; then
    fail 'a rejection requires at least one in-scope blocking finding'
    return 1
  fi

  round=0
  if [ -f "$STATE/$id.independent-review.round-2" ] \
    && [ "$(meta_value "$STATE/$id.independent-review.round-2" reviewer_task)" = "$reviewer" ]; then
    round=2
  elif [ -f "$STATE/$id.independent-review.round-1" ] \
    && [ "$(meta_value "$STATE/$id.independent-review.round-1" reviewer_task)" = "$reviewer" ]; then
    round=1
  fi
  [ "$round" -gt 0 ] || { fail "reviewer task $reviewer is not bound to task $id"; return 1; }
  round_file="$STATE/$id.independent-review.round-$round"
  [ "$(meta_value "$round_file" head)" = "$head" ] || { fail 'review submission head does not match its cold-review bundle'; return 1; }
  parent_meta="$STATE/$id.meta"
  reviewer_meta="$STATE/$reviewer.meta"
  task_meta_validate "$id" "$parent_meta" || return 1
  [ -f "$reviewer_meta" ] && [ ! -L "$reviewer_meta" ] || { fail 'reviewer task metadata is unavailable'; return 1; }
  [ "$(meta_value "$reviewer_meta" kind)" = scout ] || { fail 'independent reviewer is not a fresh scout task'; return 1; }

  builder_harness=$(meta_value "$parent_meta" harness)
  builder_model=$(meta_value "$parent_meta" model)
  [ -n "$builder_model" ] || builder_model=default
  builder_family=$(model_family "$builder_harness" "$builder_model") || { fail 'builder family is no longer resolvable'; return 1; }
  reviewer_harness=$(meta_value "$reviewer_meta" harness)
  reviewer_model=$(meta_value "$reviewer_meta" model)
  [ -n "$reviewer_model" ] || reviewer_model=default
  reviewer_family=$(model_family "$reviewer_harness" "$reviewer_model") || { fail 'reviewer family is not resolvable from recorded task metadata'; return 1; }
  [ "$builder_family" != "$reviewer_family" ] || { fail 'reviewer uses the builder model family'; return 1; }
  [ "$builder_family" = "$(meta_value "$round_file" builder_family)" ] \
    && [ "$reviewer_family" = "$(meta_value "$round_file" reviewer_family)" ] \
    && [ "$reviewer_harness" = "$(meta_value "$round_file" reviewer_harness)" ] \
    && [ "$reviewer_model" = "$(meta_value "$round_file" reviewer_model)" ] || {
      fail 'reviewer identity no longer matches the selected cold-review round'
      return 1
    }

  proposal=$(reviewer_verdict_path "$reviewer")
  [ ! -e "$proposal" ] || { fail "independent review round $round already recorded this reviewer's result"; return 1; }
  result_file=$(mktemp "$STATE/.fm-independent-review-result.XXXXXX") || return 1
  {
    printf '%s\n' \
      'format=firstmate-independent-review-verdict-v1' \
      "task=$id" \
      "pr=$(meta_value "$round_file" pr)" \
      "round=$round" \
      "head=$head" \
      "builder_harness=$builder_harness" \
      "builder_model=$builder_model" \
      "builder_family=$builder_family" \
      "reviewer_task=$reviewer" \
      "reviewer_harness=$reviewer_harness" \
      "reviewer_model=$reviewer_model" \
      "reviewer_family=$reviewer_family" \
      "verdict=$verdict_value" \
      "summary=$summary" \
      "blocker_count=$blocker_count"
    idx=0
    while [ "$idx" -lt "$blocker_count" ]; do
      printf 'blocker_%s_category=%s\n' "$((idx + 1))" "${blocker_categories[$idx]}"
      printf 'blocker_%s=%s\n' "$((idx + 1))" "${blockers[$idx]}"
      idx=$((idx + 1))
    done
    printf 'follow_up_count=%s\n' "$follow_count"
    idx=0
    while [ "$idx" -lt "$follow_count" ]; do
      printf 'follow_up_%s=%s\n' "$((idx + 1))" "${followups[$idx]}"
      idx=$((idx + 1))
    done
  } > "$result_file"
  private_file_write "$proposal" "$result_file" || { rm -f -- "$result_file"; return 1; }
  rm -f -- "$result_file"
  printf 'recorded independent review result: task=%s round=%s verdict=%s head=%s\n' \
    "$id" "$round" "$verdict_value" "$head"
}

REVIEW_LOCK=
REVIEW_LOCK_HELD=0

review_lock_cleanup() {
  if [ "$REVIEW_LOCK_HELD" = 1 ]; then
    fm_lock_release "$REVIEW_LOCK" || true
    REVIEW_LOCK_HELD=0
  fi
}

run_with_review_lock() {
  local command=$1 id=${2:-}
  shift
  if ! fm_pr_task_id_valid "$id"; then
    "$command" "$@"
    return
  fi
  REVIEW_LOCK="$STATE/.independent-review-$id.lock"
  REVIEW_LOCK_HELD=1
  fm_lock_acquire_wait "$REVIEW_LOCK"
  "$command" "$@"
  review_lock_cleanup
}

trap review_lock_cleanup EXIT
trap 'exit 1' HUP INT TERM

case "${1:-}" in
  ready)
    shift
    run_with_review_lock ready_command "$@"
    ;;
  retire-failed)
    shift
    run_with_review_lock retire_failed_command "$@"
    ;;
  submit)
    shift
    run_with_review_lock submit_command "$@"
    ;;
  add-finding)
    shift
    run_with_review_lock add_finding_command "$@"
    ;;
  resolve-finding)
    shift
    run_with_review_lock resolve_finding_command "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
