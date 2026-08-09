#!/usr/bin/env bash
# One centralized live disposition reader and fresh per-effect authority
# resolver. Receipts are bound effect evidence, never live truth.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# shellcheck disable=SC2034
FM_DISPOSITION_LIB_SOURCED=1

fm_authority_for() {  # <transition> <task_key> [attempt_id] [generation]
  local transition=$1 key=$2 attempt=${3:-} generation=${4:-} file
  if [ "$transition" = close ] && [ -n "${FM_CLOSE_AUTHORITY:-}" ]; then
    printf '%s\n' "$FM_CLOSE_AUTHORITY"
    return 0
  fi
  file="${FM_AUTHORITY_FILE:-${FM_STATE_OVERRIDE:-$FM_HOME/state}/authority-current.json}"
  [ -f "$file" ] || { echo "missing current-session authority for $transition on $key" >&2; return 1; }
  jq -e --arg t "$transition" --arg key "$key" --arg attempt "$attempt" --arg generation "$generation" '
    .transition == $t
    and .task_key == $key
    and ($attempt != "" and .attempt_id == $attempt)
    and ($generation != "" and (.generation | tostring) == $generation)
    and (.authority | type == "string" and length > 0)
  ' "$file" >/dev/null 2>&1 || {
    echo "missing or mismatched fresh $transition authority for $key" >&2
    return 1
  }
  jq -r '.authority' "$file"
}

fm_disposition_result() {  # <disposition> <reason> <attempt> <generation> [evidence-json]
  local disposition=$1 reason=$2 attempt=$3 generation=$4 evidence=${5:-null}
  jq -nc --arg disposition "$disposition" --arg reason "$reason" \
    --arg attempt_id "$attempt" --argjson generation "$generation" --argjson evidence "$evidence" \
    '{disposition:$disposition,reason:$reason,attempt_id:$attempt_id,generation:$generation,evidence:$evidence}'
}

fm_disposition_canonical_dir() {
  [ -n "$1" ] && git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

fm_disposition_target_branch() {
  local target=$1
  target=${target#refs/remotes/}
  target=${target#refs/heads/}
  target=${target#origin/}
  printf '%s' "$target"
}

fm_disposition_repo_identity() {
  case "$1" in
    git@github.com:*) printf '%s\n' "${1#git@github.com:}" | sed 's/\.git$//' ;;
    ssh://git@github.com/*) printf '%s\n' "${1#ssh://git@github.com/}" | sed 's/\.git$//' ;;
    https://github.com/*) printf '%s\n' "${1#https://github.com/}" | sed 's/\.git$//' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fm_disposition_evidence_live() {  # <attempt_id> -> deterministic evidence JSON
  local attempt=$1 record gen key copy mode base target repo_identity observation provider source repo pr
  local copy_head target_branch live state live_head live_base url_repo project_head before after
  local target_head
  record=$(fm_attempt_load "$attempt") || {
    fm_disposition_result unknown attempt-missing "$attempt" 0
    return 0
  }
  gen=$(printf '%s' "$record" | jq -r '.envelope.generation')
  key=$(printf '%s' "$record" | jq -r '.envelope.task_key')
  copy=$(printf '%s' "$record" | jq -r '.provider.copy // ""')
  mode=$(printf '%s' "$record" | jq -r '.delivery.mode // ""')
  base=$(printf '%s' "$record" | jq -r '.delivery.base // ""')
  target=$(printf '%s' "$record" | jq -r '.delivery.target // ""')
  repo_identity=$(printf '%s' "$record" | jq -r '.delivery.repo_identity // ""')
  observation=$(printf '%s' "$record" | jq -c --arg key "$key" --argjson gen "$gen" \
    '[.observations[]? | select(.name == "forge" and .generation == $gen and .evidence.source == $key)][-1].evidence // null')
  [ "$observation" != null ] || {
    fm_disposition_result unknown no-attributed-forge-observation "$attempt" "$gen"
    return 0
  }
  provider=$(printf '%s' "$observation" | jq -r '.provider // ""')
  source=$(printf '%s' "$observation" | jq -r '.source // ""')
  repo=$(printf '%s' "$observation" | jq -r '.repo // ""')
  pr=$(printf '%s' "$observation" | jq -r '.pr // ""')
  [ "$source" = "$key" ] || {
    fm_disposition_result unknown observation-task-mismatch "$attempt" "$gen" "$observation"
    return 0
  }
  copy_head=$(git -C "$copy" rev-parse HEAD 2>/dev/null || true)
  [ -n "$copy_head" ] || {
    fm_disposition_result unknown copy-head-unavailable "$attempt" "$gen" "$observation"
    return 0
  }

  if [ "$provider" = local ]; then
    [ "$mode" = local-only ] || {
      fm_disposition_result unknown local-mode-mismatch "$attempt" "$gen" "$observation"
      return 0
    }
    [ "$(printf '%s' "$observation" | jq -r '.state // ""')" = merged ] || {
      fm_disposition_result unknown local-merge-unconfirmed "$attempt" "$gen" "$observation"
      return 0
    }
    [ "$(printf '%s' "$observation" | jq -r '.target // ""')" = "$base" ] || {
      fm_disposition_result unknown local-target-mismatch "$attempt" "$gen" "$observation"
      return 0
    }
    before=$(printf '%s' "$observation" | jq -r '.before_sha // ""')
    after=$(printf '%s' "$observation" | jq -r '.after_sha // ""')
    if [ -z "$before" ] || [ -z "$after" ] \
      || [ "$(printf '%s' "$observation" | jq -r '.head // ""')" != "$after" ] \
      || [ "$copy_head" != "$after" ]; then
      fm_disposition_result unknown local-content-mismatch "$attempt" "$gen" "$observation"
      return 0
    fi
    [ -n "$repo_identity" ] \
      && [ "$(fm_disposition_canonical_dir "$repo" || true)" = "$(fm_disposition_canonical_dir "$repo_identity" || true)" ] || {
      fm_disposition_result unknown local-repo-mismatch "$attempt" "$gen" "$observation"
      return 0
    }
    project_head=$(git -C "$repo" rev-parse "$base" 2>/dev/null || true)
    if [ "$project_head" != "$after" ] \
      || ! git -C "$repo" merge-base --is-ancestor "$before" "$after" 2>/dev/null; then
      fm_disposition_result unknown local-target-content-mismatch "$attempt" "$gen" "$observation"
      return 0
    fi
    fm_disposition_result landed authorized-local-merge "$attempt" "$gen" \
      "$(jq -nc --argjson observation "$observation" --arg copy_head "$copy_head" --arg target_head "$project_head" \
        '{kind:"local-only-ff",observation:$observation,copy_head:$copy_head,target_head:$target_head}')"
    return 0
  fi

  [ "$provider" = github ] && [ -n "$pr" ] || {
    fm_disposition_result unknown unsupported-forge-evidence "$attempt" "$gen" "$observation"
    return 0
  }
  case "$mode" in direct-PR|no-mistakes) ;; *)
    fm_disposition_result unknown pr-delivery-mode-mismatch "$attempt" "$gen" "$observation"
    return 0
    ;;
  esac
  case "$pr" in
    https://github.com/*/*/pull/[0-9]*)
      url_repo=${pr#https://github.com/}
      url_repo=${url_repo%/pull/*}
      ;;
    *)
      fm_disposition_result unknown invalid-pr-identity "$attempt" "$gen" "$observation"
      return 0
      ;;
  esac
  [ -n "$repo_identity" ] && [ "$(fm_disposition_repo_identity "$repo_identity")" = "$url_repo" ] || {
    fm_disposition_result unknown frozen-repo-mismatch "$attempt" "$gen" "$observation"
    return 0
  }
  [ "$repo" = "$url_repo" ] || {
    fm_disposition_result unknown pr-repo-mismatch "$attempt" "$gen" "$observation"
    return 0
  }
  live=$(gh pr view "$pr" --json state,headRefOid,baseRefName 2>/dev/null) || live=
  printf '%s' "$live" | jq -e '
    (.state | type == "string") and (.headRefOid | type == "string" and length > 0)
    and (.baseRefName | type == "string" and length > 0)
  ' >/dev/null 2>&1 || {
    fm_disposition_result unknown forge-read-unavailable "$attempt" "$gen" "$observation"
    return 0
  }
  state=$(printf '%s' "$live" | jq -r '.state | ascii_upcase')
  live_head=$(printf '%s' "$live" | jq -r '.headRefOid')
  live_base=$(printf '%s' "$live" | jq -r '.baseRefName')
  target_branch=$(fm_disposition_target_branch "$target")
  [ "$live_base" = "$target_branch" ] || {
    fm_disposition_result unknown pr-target-mismatch "$attempt" "$gen" \
      "$(jq -nc --argjson observation "$observation" --argjson forge "$live" '{observation:$observation,forge:$forge}')"
    return 0
  }
  [ "$live_head" = "$copy_head" ] || {
    fm_disposition_result unknown pr-content-mismatch "$attempt" "$gen" \
      "$(jq -nc --argjson observation "$observation" --argjson forge "$live" --arg copy_head "$copy_head" \
        '{observation:$observation,forge:$forge,copy_head:$copy_head}')"
    return 0
  }
  case "$state" in
    MERGED)
      target_branch=$(fm_disposition_target_branch "$target")
      git -C "$copy" fetch --quiet origin "$target_branch" 2>/dev/null || {
        fm_disposition_result unknown target-git-fetch-failed "$attempt" "$gen" "$observation"
        return 0
      }
      target_head=$(git -C "$copy" rev-parse "$target" 2>/dev/null || true)
      [ -n "$target_head" ] || {
        fm_disposition_result unknown target-git-evidence-unavailable "$attempt" "$gen" \
          "$(jq -nc --argjson observation "$observation" --argjson forge "$live" '{observation:$observation,forge:$forge}')"
        return 0
      }
      if ! git -C "$copy" merge-base --is-ancestor "$copy_head" "$target_head" 2>/dev/null; then
        fm_pr_content_in_ref "$copy" "$target_head" "$copy_head" || {
          fm_disposition_result unknown target-content-not-equivalent "$attempt" "$gen" \
            "$(jq -nc --argjson observation "$observation" --argjson forge "$live" \
              --arg copy_head "$copy_head" --arg target_head "$target_head" \
              '{observation:$observation,forge:$forge,copy_head:$copy_head,target_head:$target_head}')"
          return 0
        }
      fi
      fm_disposition_result landed merged-exact-pr-head "$attempt" "$gen" \
        "$(jq -nc --argjson observation "$observation" --argjson forge "$live" --arg copy_head "$copy_head" \
          --arg target_head "$target_head" \
          '{kind:"github-pr",observation:$observation,forge:$forge,copy_head:$copy_head,target_head:$target_head}')"
      ;;
    CLOSED)
      fm_disposition_result preserved_unlanded closed-pr-exact-recovery "$attempt" "$gen" \
        "$(jq -nc --argjson observation "$observation" --argjson forge "$live" --arg copy_head "$copy_head" \
          '{kind:"closed-pr-head",observation:$observation,forge:$forge,copy_head:$copy_head,recovery:{provider:"github",durable:true}}')"
      ;;
    *) fm_disposition_result unknown active-or-unsupported-pr-state "$attempt" "$gen" \
      "$(jq -nc --argjson observation "$observation" --argjson forge "$live" '{observation:$observation,forge:$forge}')" ;;
  esac
}

fm_disposition_live() {  # <attempt_id> -> landed | preserved_unlanded | unknown
  fm_disposition_evidence_live "$1" | jq -r '.disposition // "unknown"'
}
