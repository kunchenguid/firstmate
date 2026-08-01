#!/usr/bin/env bash
# Dispatch and enforce one cold different-family review for a finished pull request.
#
# `ready` is the readiness boundary used by fm-pr-check.sh.
# It inspects the forge without writing to it, resolves the builder family from
# state/<id>.meta, starts a fresh reviewer when needed, and returns success only
# for a clear verdict bound to the pull request's exact current head.
# A moved head consumes the one permitted fix-review round.
# A second rejection, or another head after two rounds, opens the circuit and
# requires re-scoping rather than a third review.
#
# A round file is never rewritten or deleted here. A round whose reviewer failed
# to launch or died before submitting stays on disk and its refusal names the
# exact file, so stale rounds accumulate and are cleaned up separately rather
# than by this script.
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
# Verdict provenance is cooperative task identity: a submission is accepted only
# when it names a reviewer task bound to the round whose recorded metadata is a
# fresh scout in the resolved different family. That enforces provenance against
# mistakes and drift, not against a deliberately dishonest same-UID agent.
# Every firstmate agent runs as the same user, so a builder that chose to lie
# could still record its own clear verdict; that sits outside the accepted
# honest-but-fallible threat model and is not defended against here.
#
# Usage:
#   fm-independent-review.sh ready <task-id> <pr-url> [--head-file <path>]
#   fm-independent-review.sh submit <task-id> <review-task-id> <head> \
#     <clear|reject> <summary> [--block <category> <finding>]... \
#     [--follow-up <note>]...
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

private_file_write() {
  local destination=$1 source=$2 tmp device
  [ ! -L "$destination" ] || return 1
  if [ -e "$destination" ]; then
    [ -f "$destination" ] && [ "$(fm_pr_file_link_count "$destination")" = 1 ] || return 1
  fi
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(mktemp "$STATE/.fm-independent-review.XXXXXX") || return 1
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
    pi|pi-signed|opencode) ;;
    *) return 1 ;;
  esac
  [ -n "$normalized" ] && [ "$normalized" != default ] || return 1
  normalized=${normalized#openrouter/~}
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
  local builder_family=$1 candidates line harness model effort family
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

inspect_pr() {
  local url=$1 raw encoded
  fm_pr_url_parse "$url" || return 1
  case "$FM_PR_PROVIDER" in
    github)
      command -v gh >/dev/null 2>&1 || {
        fail 'could not establish pull request state and head because gh is unavailable'
        return 1
      }
      raw=$(gh pr view "$FM_PR_NUMBER" --repo "$FM_PR_PATH" \
        --json state,isDraft,headRefOid \
        -q '.state + "\t" + (.isDraft | tostring) + "\t" + .headRefOid' 2>/dev/null) || {
          fail 'could not establish pull request state and exact head from GitHub'
          return 1
        }
      IFS=$'\t' read -r PR_STATE PR_DRAFT PR_HEAD extra <<EOF
$raw
EOF
      [ -z "${extra:-}" ] || {
        fail 'could not establish pull request state and exact head from the GitHub response'
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
      ;;
  esac
  fm_pr_head_valid "$PR_HEAD" || {
    fail 'could not establish the pull request exact head commit from the forge response'
    return 1
  }
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
    MERGED)
      fail 'pull request is already merged; independent review never runs on merged work'
      ;;
    CLOSED)
      fail 'pull request is closed; independent review covers finished open pull requests only'
      ;;
    *)
      fail "could not establish that the pull request is finished and open (state=$PR_STATE)"
      ;;
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
  local id=$1 url=$2 status line
  status="$STATE/$id.status"
  [ -f "$status" ] && [ ! -L "$status" ] && [ "$(fm_pr_file_link_count "$status")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      done:\ *|done\ \[key=*\]:\ *)
        case "$line" in *"$url"*) return 0 ;; esac
        ;;
    esac
  done < "$status"
  return 1
}

default_branch() {
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$project" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

extract_task_criteria() {
  local source=$1 destination=$2
  awk '
    !in_task { if ($0 ~ /^# Task[[:space:]]*$/) in_task = 1; next }
    /^[[:space:]]*(```|~~~)/ { fence = 1 - fence; print; next }
    !fence && /^# / { done = 1; exit }
    { print }
    END { if (!done && fence) exit 3 }
  ' "$source" > "$destination" || return 1
  [ -s "$destination" ]
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

make_review_id() {
  local id=$1 round=$2 head=$3 prefix
  prefix=${id:0:32}
  printf 'ir-%s-r%s-%s\n' "$prefix" "$round" "${head:0:12}"
}

write_reviewer_brief() {
  local brief=$1 parent=$2 reviewer=$3 head=$4 criteria=$5 diff=$6 report=$7 status=$8
  local submit_command decision_command
  submit_command="FM_HOME='$FM_HOME' FM_STATE_OVERRIDE='$STATE' FM_DATA_OVERRIDE='$DATA' '$SCRIPT_DIR/fm-independent-review.sh' submit '$parent' '$reviewer' '$head'"
  decision_command="FM_HOME='$FM_HOME' FM_STATE_OVERRIDE='$STATE' FM_DATA_OVERRIDE='$DATA' '$CODE_ROOT/bin/fm-decision-hold.sh' complete '$reviewer' --none"
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

Never edit, comment on, approve, merge, close, or re-run anything on the pull request.
Never fix the finding yourself.
Write the same bounded result to $report, run:

  $decision_command

Then append one line to $status:

  done: independent review submitted for $parent at $head

Stop after that line.
EOF
}

start_review() {
  local id=$1 url=$2 round=$3 meta=$4 builder_harness=$5 builder_model=$6 builder_family=$7
  local worktree project task_brief review_id review_dir bundle_tmp bundle criteria diff brief report status
  local default base ref fetched max_diff max_criteria round_file spawn_status
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

  review_id=$(make_review_id "$id" "$round" "$PR_HEAD")
  fm_task_id_creation_valid "$review_id" || { fail 'could not derive a safe reviewer task id'; return 1; }
  round_file="$STATE/$id.independent-review.round-$round"
  [ ! -e "$round_file" ] && [ ! -L "$round_file" ] || {
    fail "independent review round $round already exists and cannot be replaced"
    return 1
  }
  bundle="$STATE/$id.independent-review.bundle-$round"
  [ ! -e "$bundle" ] && [ ! -L "$bundle" ] || {
    fail "independent review bundle $round already exists and cannot be replaced"
    return 1
  }

  bundle_tmp=$(mktemp -d "$STATE/.fm-independent-review-bundle.XXXXXX") || return 1
  criteria="$bundle_tmp/criteria.md"
  diff="$bundle_tmp/diff.patch"
  if ! extract_task_criteria "$task_brief" "$criteria"; then
    rm -rf -- "$bundle_tmp"
    fail "could not establish original task criteria from $task_brief"
    return 1
  fi
  max_criteria=${FM_INDEPENDENT_REVIEW_MAX_CRITERIA_BYTES:-131072}
  if [ "$(file_size "$criteria")" -gt "$max_criteria" ]; then
    rm -rf -- "$bundle_tmp"
    fail "original task criteria exceed the bounded review limit of $max_criteria bytes"
    return 1
  fi

  default=$(default_branch "$project") || {
    rm -rf -- "$bundle_tmp"
    fail "could not establish the default branch for $project"
    return 1
  }
  ref="refs/fm-independent-review/$id/round-$round"
  case "$FM_PR_PROVIDER" in
    github) fetched="refs/pull/$FM_PR_NUMBER/head" ;;
    gitlab) fetched="refs/merge-requests/$FM_PR_NUMBER/head" ;;
  esac
  git -C "$worktree" fetch --quiet origin "+$fetched:$ref" || {
    rm -rf -- "$bundle_tmp"
    fail "could not fetch the exact pull request head $fetched for bounded review"
    return 1
  }
  fetched=$(git -C "$worktree" rev-parse --verify "$ref^{commit}" 2>/dev/null) || {
    rm -rf -- "$bundle_tmp"
    fail 'could not resolve the fetched pull request head commit'
    return 1
  }
  [ "$fetched" = "$PR_HEAD" ] || {
    rm -rf -- "$bundle_tmp"
    fail "pull request head changed while the review bundle was prepared (forge=$PR_HEAD fetched=$fetched); retry"
    return 1
  }
  git -C "$worktree" fetch --quiet origin "+refs/heads/$default:refs/remotes/origin/$default" || {
    rm -rf -- "$bundle_tmp"
    fail "could not fetch the authoritative base branch origin/$default"
    return 1
  }
  base="origin/$default"
  git -C "$worktree" diff "$base...$PR_HEAD" -- > "$diff" || {
    rm -rf -- "$bundle_tmp"
    fail 'could not produce the exact pull request diff for independent review'
    return 1
  }
  [ -s "$diff" ] || {
    rm -rf -- "$bundle_tmp"
    fail 'pull request has no diff against its authoritative base'
    return 1
  }
  max_diff=${FM_INDEPENDENT_REVIEW_MAX_DIFF_BYTES:-524288}
  if [ "$(file_size "$diff")" -gt "$max_diff" ]; then
    rm -rf -- "$bundle_tmp"
    fail "pull request diff exceeds the bounded review limit of $max_diff bytes"
    return 1
  fi
  chmod 0600 "$criteria" "$diff"
  mv -- "$bundle_tmp" "$bundle"
  criteria="$bundle/criteria.md"
  diff="$bundle/diff.patch"

  review_dir="$DATA/$review_id"
  if [ -L "$review_dir" ] || { [ -e "$review_dir" ] && [ ! -d "$review_dir" ]; }; then
    fail "reviewer data path is unavailable: $review_dir"
    return 1
  fi
  mkdir -p "$review_dir"
  brief="$review_dir/brief.md"
  report="$review_dir/report.md"
  status="$STATE/$review_id.status"
  [ ! -e "$brief" ] && [ ! -L "$brief" ] || {
    fail "reviewer brief already exists and cannot be replaced: $brief"
    return 1
  }
  write_reviewer_brief "$brief" "$id" "$review_id" "$PR_HEAD" "$criteria" "$diff" "$report" "$status"
  chmod 0600 "$brief"

  write_lines_file "$round_file" \
    'format=firstmate-independent-review-round-v1' \
    "task=$id" \
    "pr=$url" \
    "round=$round" \
    "head=$PR_HEAD" \
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
    'status=launching' || return 1

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
    fail "different-family reviewer launch failed for round $round; retire $round_file before retrying"
    return 1
  fi
  printf '%s\n' 'status=pending' >> "$round_file"
  printf 'independent review started: round %s reviewer=%s family=%s head=%s\n' \
    "$round" "$review_id" "$SELECTED_FAMILY" "$PR_HEAD"
  return 3
}

verdict_matches_round() {
  local verdict=$1 round_file=$2
  [ -f "$verdict" ] && [ ! -L "$verdict" ] || return 1
  [ "$(meta_value "$verdict" format)" = firstmate-independent-review-verdict-v1 ] || return 1
  [ "$(meta_value "$verdict" task)" = "$(meta_value "$round_file" task)" ] || return 1
  [ "$(meta_value "$verdict" pr)" = "$(meta_value "$round_file" pr)" ] || return 1
  [ "$(meta_value "$verdict" round)" = "$(meta_value "$round_file" round)" ] || return 1
  [ "$(meta_value "$verdict" head)" = "$(meta_value "$round_file" head)" ] || return 1
  [ "$(meta_value "$verdict" builder_family)" = "$(meta_value "$round_file" builder_family)" ] || return 1
  [ "$(meta_value "$verdict" reviewer_family)" = "$(meta_value "$round_file" reviewer_family)" ] || return 1
  [ "$(meta_value "$verdict" reviewer_task)" = "$(meta_value "$round_file" reviewer_task)" ] || return 1
}

print_rejection() {
  local verdict=$1 round=$2 count idx category finding
  count=$(meta_value "$verdict" blocker_count)
  printf 'error: independent review rejected head %s: %s\n' \
    "$(meta_value "$verdict" head)" "$(meta_value "$verdict" summary)" >&2
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
  printf '%s\n' "$head" > "$destination"
  chmod 0600 "$destination"
}

ready_command() {
  local id=${1:-} url=${2:-} head_file='' meta builder_harness builder_model builder_family
  local round=0 round_file='' verdict verdict_round verdict_value last_status
  local reviewer_id reviewer_model
  [ -n "$id" ] && [ -n "$url" ] || { usage >&2; return 2; }
  shift 2
  if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --head-file ] || { usage >&2; return 2; }
    head_file=$2
  fi
  meta="$STATE/$id.meta"
  task_meta_validate "$id" "$meta" || return 1
  fm_pr_url_parse "$url" || { fail 'invalid pull request URL for independent review'; return 1; }
  finished_pr_recorded "$id" "$url" || {
    fail "task $id has not recorded a finished pull request for $url; independent review never runs on work in progress"
    return 1
  }
  inspect_pr "$url" || return 1
  scope_allows_review || return 1

  builder_harness=$(meta_value "$meta" harness)
  builder_model=$(meta_value "$meta" model)
  [ -n "$builder_harness" ] || {
    fail "could not establish builder harness from state/$id.meta"
    return 1
  }
  [ -n "$builder_model" ] || builder_model=default
  if ! builder_family=$(model_family "$builder_harness" "$builder_model"); then
    case "$builder_harness" in
      pi|pi-signed|opencode)
        if [ "$builder_model" = default ]; then
          fail "could not establish builder model family: harness=$builder_harness requires a recorded model with a verified provider family"
        else
          fail "could not establish builder model family: harness=$builder_harness model=$builder_model has no verified provider-family mapping"
        fi
        ;;
      *) fail "could not establish builder model family from harness=$builder_harness model=$builder_model" ;;
    esac
    return 1
  fi

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
    if [ "$(meta_value "$round_file" head)" = "$PR_HEAD" ]; then
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
            write_head_file "$head_file" "$PR_HEAD" || {
              fail 'could not publish the reviewed head binding for the readiness caller'
              return 1
            }
            reviewer_id=$(meta_value "$verdict" reviewer_harness)
            reviewer_model=$(meta_value "$verdict" reviewer_model)
            [ "$reviewer_model" = default ] || reviewer_id="$reviewer_id/$reviewer_model"
            printf 'Independent review: %s via %s (%s family) - %s\n' \
              "$(meta_value "$verdict" reviewer_task)" \
              "$reviewer_id" \
              "$(meta_value "$verdict" reviewer_family)" \
              "$(meta_value "$verdict" summary)"
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
        fail "different-family reviewer launch failed for round $round; retire $round_file to allow a fresh reviewer"
        return 1
      fi
      printf 'independent review pending: round %s head=%s reviewer=%s; if that reviewer is gone, retire %s and retry\n' \
        "$round" "$PR_HEAD" "$(meta_value "$round_file" reviewer_task)" "$round_file" >&2
      return 3
    fi

    if [ "$verdict_round" != "$round" ]; then
      printf 'independent review pending for prior head %s; current head %s remains not ready; if reviewer %s is gone, retire %s and retry\n' \
        "$(meta_value "$round_file" head)" "$PR_HEAD" \
        "$(meta_value "$round_file" reviewer_task)" "$round_file" >&2
      return 3
    fi
    verdict_matches_round "$verdict" "$round_file" || {
      fail "could not validate completed independent review round $round"
      return 1
    }
    if [ "$round" -ge 2 ]; then
      fail 'pull request head changed after two review rounds; the circuit is open and the work must be re-scoped'
      return 1
    fi
  fi

  start_review "$id" "$url" "$((round + 1))" "$meta" \
    "$builder_harness" "$builder_model" "$builder_family"
}

submit_command() {
  local id=${1:-} reviewer=${2:-} head=${3:-} verdict_value=${4:-} summary=${5:-}
  local round round_file parent_meta reviewer_meta builder_harness builder_model builder_family
  local reviewer_harness reviewer_model reviewer_family existing existing_round
  local blocker_count=0 follow_count=0 arg category finding tmp result_file idx
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

  existing="$STATE/$id.independent-review.verdict"
  if [ -f "$existing" ]; then
    existing_round=$(meta_value "$existing" round)
    if [ "$existing_round" -ge "$round" ]; then
      fail "independent review round $round already has a recorded verdict"
      return 1
    fi
  fi
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
  private_file_write "$existing" "$result_file" || { rm -f -- "$result_file"; return 1; }
  rm -f -- "$result_file"
  printf 'recorded independent review: task=%s round=%s verdict=%s head=%s\n' \
    "$id" "$round" "$verdict_value" "$head"
}

case "${1:-}" in
  ready)
    shift
    ready_command "$@"
    ;;
  submit)
    shift
    submit_command "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
