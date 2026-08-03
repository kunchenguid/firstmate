# shellcheck shell=bash
# Shared held-improvement stack mechanics for fm-update.sh and local
# secondmate convergence.
#
# The gitignored config/held-improvements/active directory is the explicit,
# ordered stack. Each <order>-<id>.patch has a sibling .title file. The default
# branch remains a pristine upstream ref; refs/firstmate/held/live points at the
# detached effective revision built from that base plus the active patches.
# refs/firstmate/held/effective/<sha> records the recent known-good effective
# commits so a clean detached linked secondmate can safely move between replayed
# histories without treating the rewrite as unlanded work. That set is bounded,
# because an unpruned ref pins its commit and tree forever.

HELD_REF_ROOT=refs/firstmate/held
HELD_LIVE_REF=$HELD_REF_ROOT/live

held_config_root() {
  local home base parent name
  home=${FM_HOME:-${FM_ROOT:-}}
  [ -n "${FM_CONFIG_OVERRIDE:-$home}" ] || return 1
  base=${FM_CONFIG_OVERRIDE:-$home/config}
  case "$base" in
    /*) ;;
    *)
      if [ -d "$base" ]; then
        base=$(cd "$base" && pwd -P) || return 1
      else
        parent=$(dirname "$base")
        name=$(basename "$base")
        parent=$(cd "$parent" && pwd -P) || return 1
        base="$parent/$name"
      fi
      ;;
  esac
  printf '%s/held-improvements\n' "$base"
}

held_stack_present() {
  [ -d "$(held_config_root)" ]
}

held_stack_active() {
  local root=${1:-${FM_ROOT:-}} config
  [ -n "$root" ] || return 1
  config=$(held_config_root) || return 1
  [ -f "$config/last-base" ] || return 1
  [ -d "$config/active" ] || return 1
  git -C "$root" show-ref --verify --quiet "$HELD_LIVE_REF"
}

held_live_commit() {
  local root=${1:-$FM_ROOT}
  held_stack_active "$root" || return 1
  git -C "$root" rev-parse --verify --quiet "$HELD_LIVE_REF^{commit}" 2>/dev/null
}

# Each known-effective ref pins its commit and whole tree against gc, and every
# successful update registers two, so the set is capped at the most recent
# HELD_EFFECTIVE_RETAIN registrations. That window only has to be deep enough
# for a linked secondmate that missed a few updates to still recognise its own
# commit as known-effective, not to be a permanent archive. The registration
# order lives in a log beside the stack because ref names carry no order and
# replayed candidates are committed with synthetic dates.
HELD_EFFECTIVE_RETAIN=${HELD_EFFECTIVE_RETAIN:-20}

held_register_effective() {
  local root=$1 commit=$2 config log tmp
  git -C "$root" update-ref "$HELD_REF_ROOT/effective/$commit" "$commit" || return 1
  config=$(held_config_root 2>/dev/null) || return 0
  [ -d "$config" ] || return 0
  log="$config/effective-log"
  tmp="$log.tmp"
  {
    if [ -f "$log" ]; then
      grep -v -x -F -e "$commit" "$log" || true
    fi
    printf '%s\n' "$commit"
  } > "$tmp" || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$log" || { rm -f "$tmp"; return 0; }
  held_prune_effective "$root" "$log"
}

held_prune_effective() {
  local root=$1 log=$2 total drop stale tmp
  total=$(wc -l < "$log" | tr -d ' ')
  [ "$total" -gt "$HELD_EFFECTIVE_RETAIN" ] || return 0
  drop=$((total - HELD_EFFECTIVE_RETAIN))
  while IFS= read -r stale; do
    [ -n "$stale" ] || continue
    git -C "$root" update-ref -d "$HELD_REF_ROOT/effective/$stale" >/dev/null 2>&1 || true
  done < <(head -n "$drop" "$log")
  tmp="$log.tmp"
  tail -n "$HELD_EFFECTIVE_RETAIN" "$log" > "$tmp" || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$log" || rm -f "$tmp"
}

held_commit_is_known_effective() {
  local root=$1 commit=$2
  git -C "$root" show-ref --verify --quiet "$HELD_REF_ROOT/effective/$commit"
}

held_target_is_live() {
  local root=$1 commit=$2 live
  live=$(held_live_commit "$root" 2>/dev/null || true)
  [ -n "$live" ] && [ "$commit" = "$live" ]
}

held_branch_checkout_path() {
  local root=$1 branch=$2
  git -C "$root" worktree list --porcelain | awk -v wanted="refs/heads/$branch" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " wanted { print path; exit }
  '
}

held_write_file() {
  local target=$1 content=$2 dir tmp
  dir=$(dirname "$target")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.held-write.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$target"
}

held_attention() {
  local message=$1 alarm
  alarm="${STATE:-$FM_HOME/state}/.nightly-update-needs-attention"
  if ! held_write_file "$alarm" "$message"; then
    printf 'error: held-improvement update could not write attention alarm %s\n' "$alarm" >&2
  fi
  printf 'error: %s\n' "$message" >&2
}

held_clear_attention() {
  rm -f "${STATE:-$FM_HOME/state}/.nightly-update-needs-attention"
}

held_entry_title() {
  local patch=$1 title_file title line_count
  title_file=${patch%.patch}.title
  [ -f "$title_file" ] || return 1
  line_count=$(wc -l < "$title_file" | tr -d ' ')
  [ "$line_count" -eq 1 ] || return 1
  title=$(sed -n '1p' "$title_file")
  [ -n "$title" ] || return 1
  printf '%s\n' "$title"
}

held_entry_id() {
  local patch=$1 stem
  stem=$(basename "$patch" .patch)
  printf '%s\n' "${stem#*-}"
}

held_entry_order() {
  local patch=$1 stem
  stem=$(basename "$patch" .patch)
  printf '%s\n' "${stem%%-*}"
}

held_patch_id() {
  local patch=$1
  git patch-id --verbatim < "$patch" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

held_upstream_contains_patch_id() {
  local root=$1 patch=$2 old_base=$3 new_base=$4 wanted commit actual
  wanted=$(held_patch_id "$patch")
  [ -n "$wanted" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    actual=$(git -C "$root" show --no-ext-diff --pretty=format: --binary "$commit" \
      | git patch-id --verbatim 2>/dev/null | awk 'NR == 1 { print $1 }')
    [ -n "$actual" ] && [ "$actual" = "$wanted" ] && return 0
  done < <(git -C "$root" rev-list --reverse "$old_base..$new_base")
  return 1
}

held_patch_paths() {
  local patch=$1
  git apply --numstat "$patch" 2>/dev/null | cut -f3-
}

held_conflicting_upstream_changes() {
  local root=$1 old_base=$2 new_base=$3 paths_file=$4 path commit seen="" nl=$'\n'
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r commit; do
      [ -n "$commit" ] || continue
      case "$nl$seen$nl" in
        *"$nl$commit$nl"*) continue ;;
      esac
      seen="$seen${seen:+$nl}$commit"
      printf '%s\n' "$commit"
    done < <(git -C "$root" log --reverse --format='%H %s' "$old_base..$new_base" -- "$path")
  done < "$paths_file"
}

HELD_TMP=
HELD_CANDIDATE_WORKTREE=

held_candidate_cleanup() {
  if [ -n "$HELD_CANDIDATE_WORKTREE" ] && [ -d "$HELD_CANDIDATE_WORKTREE" ]; then
    git -C "$FM_ROOT" worktree remove --force "$HELD_CANDIDATE_WORKTREE" >/dev/null 2>&1 || true
  fi
  if [ -n "$HELD_TMP" ] && [ -d "$HELD_TMP" ]; then
    rm -rf -- "$HELD_TMP"
  fi
  HELD_TMP=
  HELD_CANDIDATE_WORKTREE=
}

HELD_REAPPLIED=
HELD_RETIRED=

held_update_primary() {
  local root=$1 config default old_base local_base new_base old_live current_head dirty
  local branch_holder patch id order title apply_out candidate instr before after stamp paths upstream_changes message
  config=$(held_config_root)
  HELD_REAPPLIED=
  HELD_RETIRED=
  FF_STATUS=skipped
  FF_INSTR=

  if ! held_stack_active; then
    held_attention "held-improvement configuration is incomplete under $config; the live revision was not changed"
    return 1
  fi
  default=$(default_branch "$root") || {
    held_attention "held-improvement update cannot determine the upstream default branch; the live revision was not changed"
    return 1
  }
  old_base=$(sed -n '1p' "$config/last-base")
  old_live=$(held_live_commit "$root") || {
    held_attention "held-improvement live ref is unreadable; the live revision was not changed"
    return 1
  }
  current_head=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
  if [ "$current_head" != "$old_live" ]; then
    held_attention "held-improvement live checkout is at ${current_head:-unknown}, expected $old_live; the live revision was not changed"
    return 1
  fi
  if git -C "$root" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    held_attention "held-improvement live checkout must be detached at $old_live; the live revision was not changed"
    return 1
  fi
  dirty=$(dirty_status "$root" no)
  if [ -n "$dirty" ]; then
    held_attention "held-improvement live checkout is dirty; the live revision was not changed"
    return 1
  fi
  if ! git -C "$root" merge-base --is-ancestor "$old_base" "$old_live" 2>/dev/null; then
    held_attention "held-improvement live revision $old_live is not based on recorded upstream $old_base; the live revision was not changed"
    return 1
  fi
  if ! fetch_once "$root"; then
    held_attention "held-improvement update could not fetch origin; the live revision was not changed"
    return 1
  fi
  new_base=$(git -C "$root" rev-parse "origin/$default" 2>/dev/null || true)
  local_base=$(git -C "$root" rev-parse "refs/heads/$default" 2>/dev/null || true)
  if [ -z "$new_base" ] || [ -z "$local_base" ]; then
    held_attention "held-improvement update cannot resolve refs/heads/$default and origin/$default; the live revision was not changed"
    return 1
  fi
  if ! git -C "$root" merge-base --is-ancestor "$old_base" "$new_base" 2>/dev/null; then
    held_attention "upstream $default no longer descends from recorded base $old_base; the live revision was not changed"
    return 1
  fi
  if ! git -C "$root" merge-base --is-ancestor "$local_base" "$new_base" 2>/dev/null; then
    held_attention "local $default has diverged from origin/$default; the live revision was not changed"
    return 1
  fi
  branch_holder=$(held_branch_checkout_path "$root" "$default")
  if [ -n "$branch_holder" ]; then
    held_attention "pristine $default is checked out by worktree $branch_holder; the pristine ref was not changed and the live revision was not changed"
    return 1
  fi
  if ! git -C "$root" update-ref "refs/heads/$default" "$new_base" "$local_base"; then
    held_attention "pristine $default could not fast-forward to origin/$default; the live revision was not changed"
    return 1
  fi

  HELD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-held-update.XXXXXX") || return 1
  HELD_CANDIDATE_WORKTREE="$HELD_TMP/worktree"
  trap 'held_candidate_cleanup' EXIT
  trap 'held_candidate_cleanup; exit 129' HUP
  trap 'held_candidate_cleanup; exit 130' INT
  trap 'held_candidate_cleanup; exit 143' TERM
  if ! git -C "$root" worktree add --quiet --detach "$HELD_CANDIDATE_WORKTREE" "$new_base"; then
    held_attention "held-improvement candidate worktree could not be created; the live revision was not changed"
    held_candidate_cleanup
    trap - EXIT HUP INT TERM
    return 1
  fi
  : > "$HELD_TMP/retired"

  for patch in "$config"/active/*.patch; do
    [ -f "$patch" ] || continue
    id=$(held_entry_id "$patch")
    order=$(held_entry_order "$patch")
    title=$(held_entry_title "$patch" 2>/dev/null || true)
    if [ -z "$title" ]; then
      held_attention "held improvement $id has no readable title; the live revision was not changed"
      held_candidate_cleanup
      trap - EXIT HUP INT TERM
      return 1
    fi

    if held_upstream_contains_patch_id "$root" "$patch" "$old_base" "$new_base" \
      || git -C "$HELD_CANDIDATE_WORKTREE" apply --reverse --check "$patch" >/dev/null 2>&1; then
      printf '%s\n' "$(basename "$patch" .patch)" >> "$HELD_TMP/retired"
      HELD_RETIRED="$HELD_RETIRED${HELD_RETIRED:+,}$id"
      continue
    fi

    if ! apply_out=$(git -C "$HELD_CANDIDATE_WORKTREE" apply --index --3way "$patch" 2>&1); then
      git -C "$HELD_CANDIDATE_WORKTREE" diff --name-only --diff-filter=U > "$HELD_TMP/conflict-paths"
      if [ ! -s "$HELD_TMP/conflict-paths" ]; then
        held_patch_paths "$patch" > "$HELD_TMP/conflict-paths"
      fi
      upstream_changes=$(held_conflicting_upstream_changes \
        "$root" "$old_base" "$new_base" "$HELD_TMP/conflict-paths")
      [ -n "$upstream_changes" ] || upstream_changes="${new_base:0:12} current upstream $default"
      paths=$(paste -sd, "$HELD_TMP/conflict-paths")
      message="held improvement $id ($title) collided with upstream change(s): $upstream_changes; paths: ${paths:-unknown}; live revision remains $old_live"
      held_attention "$message"
      [ -z "$apply_out" ] || printf '%s\n' "$apply_out" >&2
      held_candidate_cleanup
      trap - EXIT HUP INT TERM
      return 1
    fi

    stamp=$((946684800 + 10#$order))
    if ! GIT_AUTHOR_NAME='Firstmate Held Improvements' \
      GIT_AUTHOR_EMAIL='firstmate-held@example.invalid' \
      GIT_COMMITTER_NAME='Firstmate Held Improvements' \
      GIT_COMMITTER_EMAIL='firstmate-held@example.invalid' \
      GIT_AUTHOR_DATE="@$stamp +0000" GIT_COMMITTER_DATE="@$stamp +0000" \
      git -C "$HELD_CANDIDATE_WORKTREE" commit --quiet --no-gpg-sign \
        -m "held($id): $title"; then
      held_attention "held improvement $id applied but its candidate commit failed; the live revision was not changed"
      held_candidate_cleanup
      trap - EXIT HUP INT TERM
      return 1
    fi
    HELD_REAPPLIED="$HELD_REAPPLIED${HELD_REAPPLIED:+,}$id"
  done

  candidate=$(git -C "$HELD_CANDIDATE_WORKTREE" rev-parse HEAD)
  instr=$(changed_instr "$root" "$candidate")
  before=$(git -C "$root" rev-parse --short HEAD)
  held_register_effective "$root" "$new_base"
  held_register_effective "$root" "$candidate"
  if ! git -C "$root" checkout --quiet --detach "$candidate"; then
    held_attention "held-improvement candidate $candidate was built but the live checkout could not switch; live revision remains $old_live"
    held_candidate_cleanup
    trap - EXIT HUP INT TERM
    return 1
  fi
  if ! git -C "$root" update-ref "$HELD_LIVE_REF" "$candidate" "$old_live"; then
    git -C "$root" checkout --quiet --detach "$old_live" || true
    held_attention "held-improvement live ref could not publish candidate $candidate; live revision remains $old_live"
    held_candidate_cleanup
    trap - EXIT HUP INT TERM
    return 1
  fi
  if ! held_write_file "$config/last-base" "$new_base"; then
    git -C "$root" update-ref "$HELD_LIVE_REF" "$old_live" "$candidate" || true
    git -C "$root" checkout --quiet --detach "$old_live" || true
    held_attention "held-improvement candidate $candidate was built but its upstream-base record could not publish; live revision remains $old_live"
    held_candidate_cleanup
    trap - EXIT HUP INT TERM
    return 1
  fi

  while IFS= read -r stem; do
    [ -n "$stem" ] || continue
    if ! mv "$config/active/$stem.patch" "$config/retired/$stem.patch" \
      || ! mv "$config/active/$stem.title" "$config/retired/$stem.title" \
      || ! held_write_file "$config/retired/$stem.reason" \
        "upstream content equivalent detected at $new_base"; then
      held_attention "held improvement $stem reached the effective revision but its retirement record could not publish; inspect $config before the next update"
      held_candidate_cleanup
      trap - EXIT HUP INT TERM
      return 1
    fi
  done < "$HELD_TMP/retired"

  after=$(git -C "$root" rev-parse --short HEAD)
  # shellcheck disable=SC2034 # Output global consumed by the sourcing updater.
  FF_INSTR=$instr
  if [ "$old_live" = "$candidate" ]; then
    # shellcheck disable=SC2034 # Output global consumed by the sourcing updater.
    FF_STATUS=current
    echo "firstmate: already current (held improvements active)"
  else
    # shellcheck disable=SC2034 # Output global consumed by the sourcing updater.
    FF_STATUS=updated
    echo "firstmate: updated $before..$after (upstream $default $(printf '%.7s' "$old_base")..$(printf '%.7s' "$new_base"); reapplied: ${HELD_REAPPLIED:-none}; retired: ${HELD_RETIRED:-none})"
  fi
  held_candidate_cleanup
  trap - EXIT HUP INT TERM
  return 0
}
