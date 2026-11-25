#!/usr/bin/env bash
# fm-launch-guard-lib.sh - ownership admission for fresh worker launches.
# Sourced by fm-spawn.sh with backend, wake and secondmate-registry libraries.
# A branch belongs to its project's origin (the shared project lock identity).
# Every full GitHub PR URL in a brief is conservatively treated as work on that
# PR, including PR start bindings; metadata pr= and launch_pr= also claim it.
# URLs are case-insensitive and trailing paths/query/fragment are ignored.
# Claims are compared across the root and all registered local descendant homes.
# Remote registry entries are outside this machine-local guard and are skipped.
# A matched record holds ownership unless backend recovery proves dead/missing;
# unknown liveness is not permission to start another worker. Terminal status or
# a ready PR does not release a still-live worker's ownership.
# Unavailable local homes fail closed. No SSH or remote endpoint access runs.
# --allow-duplicate <reason> on fm-spawn.sh explicitly bypasses this guard and
# records the reason in metadata; it never bypasses other launch gates.
# Relaunch replaces an existing owner without adding one and is exempt;
# its existing same-task endpoint safety remains owned by fm-spawn.sh.
# Free-text scope without a branch or full PR URL is not inferred or matched.
# The caller holds the root home's ownership lock through metadata publication,
# even on Orca, so concurrent local starts cannot both claim the same ownership.

fm_launch_pr_urls() {  # <readable-file>...
  LC_ALL=C grep -Eioh 'https://github\.com/[a-z0-9_.-]+/[a-z0-9_.-]+/pull/[1-9][0-9]*' "$@" |
    tr '[:upper:]' '[:lower:]' | sort -u
}

fm_launch_guard() {  # <project> <branch-or-empty> <brief> <state> <data> <id>
  local project=$1 branch=$2 brief=$3 first=$4 data=$5 self=$6
  local want prs state meta id other_project other_branch lock other_prs overlap
  local backend target alive home line claim_brief
  FM_LAUNCH_GUARD_ERROR=
  want=$(fm_treehouse_project_lock_path "$project") || {
    FM_LAUNCH_GUARD_ERROR="cannot resolve project identity for $project"
    return 1
  }
  if [ ! -f "$brief" ] || [ ! -r "$brief" ]; then
    FM_LAUNCH_GUARD_ERROR="cannot read launch brief $brief"
    return 1
  fi
  prs=$(fm_launch_pr_urls "$brief") || prs=
  fm_local_firstmate_state_dirs "$first" || {
    FM_LAUNCH_GUARD_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    home=$(dirname "$state")
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_LAUNCH_GUARD_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
        FM_LAUNCH_GUARD_ERROR="task record $meta cannot be read"
        return 1
      fi
      [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
      id=$(basename "$meta" .meta)
      other_project=$(fm_meta_get "$meta" project)
      other_branch=$(fm_meta_get "$meta" branch)
      overlap=
      if [ -n "$branch" ] && [ "$branch" = "$other_branch" ]; then
        lock=$(fm_treehouse_project_lock_path "$other_project" 2>/dev/null) || lock=
        if [ -z "$lock" ]; then
          FM_LAUNCH_GUARD_ERROR="cannot resolve project identity of branch $branch owned by $meta"
          return 1
        fi
        [ "$lock" != "$want" ] || overlap="branch $branch"
      fi
      if [ -n "$prs" ]; then
        claim_brief="$home/data/$id/brief.md"
        [ "$state" != "$first" ] || claim_brief="$data/$id/brief.md"
        other_prs=$(fm_launch_pr_urls "$meta") || other_prs=
        if [ -e "$claim_brief" ] || [ -L "$claim_brief" ]; then
          if [ ! -f "$claim_brief" ] || [ ! -r "$claim_brief" ] || [ -L "$claim_brief" ]; then
            FM_LAUNCH_GUARD_ERROR="cannot read worker PR claims in $claim_brief"
            return 1
          fi
          other_prs="$other_prs
$(fm_launch_pr_urls "$claim_brief" || true)"
        fi
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          if printf '%s\n' "$other_prs" | grep -Fqx -- "$line"; then
            overlap="PR $line"
            break
          fi
        done <<< "$prs"
      fi
      [ -n "$overlap" ] || continue
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      # Never repair/bind another home's endpoint during a read-only check.
      # Rex's server selector must come from that record, not this launcher.
      if [ "$backend" = rex ]; then
        alive=unknown
      else
        alive=$(fm_backend_agent_alive "$backend" "$target") || alive=unknown
      fi
      [ "$alive" != dead ] || continue
      FM_LAUNCH_GUARD_ERROR="$overlap is already owned by worker $id in $home (liveness=$alive)"
      return 1
    done
  done
  return 0
}
