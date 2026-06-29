#!/usr/bin/env bash
# fm-cs-pool.sh - acquire / release / recreate codespaces for crewmate tasks.
#
# This is the lease lifecycle surface that fm-spawn (acquire) and fm-teardown
# (release) call, plus the captain-facing pool maintenance commands. The gh-backed
# primitives all live in fm-cs-lib.sh and route through _cs_gh, so this file holds
# only orchestration + lease-registry transitions - which the offline test
# (test/cs-pool-test.sh) verifies by stubbing those primitives.
#
# Commands:
#   fm-cs-pool.sh list                       # pool codespaces + state
#   fm-cs-pool.sh acquire <repo> <task> [branch]   # -> prints codespace name
#   fm-cs-pool.sh release <codespace>        # stop pooled / delete created, free lease
#   fm-cs-pool.sh recreate-free [repo]       # rebuild FREE pool machines with current setup
#
# acquire: reuse a FREE pooled codespace for <repo> if one exists (relabel BUSY,
# re-verify the non-atomic label), else cold-create one; then run fm-cs-setup.sh
# in it. The lease registry records source=pool|created so release knows whether
# to stop-and-free (pooled, reusable) or delete (created, ephemeral).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-cs-lib.sh
. "$SCRIPT_DIR/fm-cs-lib.sh"

CS_SETUP="${FM_CS_SETUP_CMD:-$SCRIPT_DIR/fm-cs-setup.sh}"
CS_MACHINE="${FM_CS_MACHINE:-xLargePremiumLinux}"

# cs_setup_run <cs> <harness> - run the cold-setup script inside the codespace
# over SSH, piping the script in. Overridable in tests via FM_CS_SETUP_RUN.
cs_setup_run() {
  local cs=$1 harness=$2
  if [ -n "${FM_CS_SETUP_RUN:-}" ]; then
    eval "$FM_CS_SETUP_RUN"
    return
  fi
  cs_ssh "$cs" -- "bash -s -- '$harness'" < "$CS_SETUP"
}

# cs_pool_acquire <repo> <task> [branch] - print the acquired codespace name.
cs_pool_acquire() {
  local repo=$1 task=$2 branch=${3:-} harness cs source slot label entry free_name free_display
  harness=$(cs_harness)
  entry=$(cs_pool_free_entry "$repo" || true)
  if [ -n "$entry" ]; then
    free_name=$(printf '%s' "$entry" | cut -f1)
    free_display=$(printf '%s' "$entry" | cut -f2)
    slot=$(cs_pool_slot_from_display "$free_display")
    [ -n "$slot" ] || slot="pool"
    label=$(cs_label "$slot" BUSY "$task")
    cs_set_label "$free_name" "$label" || { echo "error: could not label FREE codespace $free_name" >&2; return 1; }
    # Non-atomic label: re-read and confirm our BUSY label still owns the slot.
    local now_display
    now_display=$(cs_display_of "$free_name" || true)
    if [ "$now_display" != "$label" ]; then
      echo "error: lease race on $free_name (label is '$now_display', expected '$label')" >&2
      return 1
    fi
    cs=$free_name
    source=pool
    cs_lease_record "$cs" "$repo" "$task" pool "$branch" "$label"
  else
    [ -n "$branch" ] || branch=$(cs_default_branch "$repo") || { echo "error: cannot resolve default branch for $repo" >&2; return 1; }
    slot="task-$task"
    label=$(cs_label "$slot" BUSY "$task")
    cs=$(cs_create "$repo" "$branch" "$label" "$CS_MACHINE") || { echo "error: cs_create failed for $repo" >&2; return 1; }
    cs=$(printf '%s' "$cs" | tr -d '[:space:]')
    [ -n "$cs" ] || { echo "error: cs_create returned no name" >&2; return 1; }
    source=created
    cs_lease_record "$cs" "$repo" "$task" created "$branch" "$label"
  fi

  if ! cs_setup_run "$cs" "$harness" >&2; then
    echo "error: cold setup failed in $cs; lease kept for inspection" >&2
    return 1
  fi
  printf '%s\n' "$cs"
}

# cs_display_of <cs> - current display name of a codespace (empty if gone).
cs_display_of() {
  cs_list_json | jq -r --arg n "$1" '.[] | select(.name==$n) | .displayName' | head -1
}

# cs_pool_release <cs> - return a codespace per its lease source, free the lease.
cs_pool_release() {
  local cs=$1 source slot display
  source=$(cs_lease_get "$cs" source)
  if [ "$source" = created ]; then
    cs_delete "$cs" || { echo "error: delete failed for created codespace $cs; lease kept" >&2; return 1; }
  else
    # pooled (or unknown-but-pool-shaped): stop and relabel FREE for reuse.
    cs_stop "$cs" || echo "warning: stop failed for $cs; relabeling FREE anyway" >&2
    display=$(cs_lease_get "$cs" displayName)
    slot=$(cs_pool_slot_from_display "$display")
    if [ -n "$slot" ]; then
      cs_set_label "$cs" "$(cs_label "$slot" FREE)" || echo "warning: could not relabel $cs FREE" >&2
    fi
  fi
  cs_lease_release "$cs"
}

# cs_pool_recreate_free [repo] - delete each FREE pool codespace and recreate it
# from the same slot/branch, so a newly added tool in fm-cs-setup is baked in.
# Captain-driven maintenance, not part of the per-task path.
cs_pool_recreate_free() {
  local repo_filter=${1:-} harness
  harness=$(cs_harness)
  cs_list_json | jq -r '.[] | select(.displayName | test("(^| )pool-[a-z0-9-]+ FREE($| )")) | [.name,.displayName,.repository] | @tsv' \
  | while IFS=$'\t' read -r name display repo; do
      [ -z "$repo_filter" ] || [ "$repo_filter" = "$repo" ] || continue
      local slot branch
      slot=$(cs_pool_slot_from_display "$display")
      branch=$(cs_default_branch "$repo")
      echo "recreating $slot ($name) on $repo@$branch"
      cs_delete "$name" || { echo "  delete failed; skipping" >&2; continue; }
      local newcs
      newcs=$(cs_create "$repo" "$branch" "$(cs_label "$slot" FREE)" "$CS_MACHINE") || { echo "  create failed" >&2; continue; }
      newcs=$(printf '%s' "$newcs" | tr -d '[:space:]')
      cs_setup_run "$newcs" "$harness" >&2 || echo "  setup INCOMPLETE on $newcs (left FREE; inspect)" >&2
      cs_stop "$newcs" || true
    done
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    list)
      cs_list_json | jq -r '.[] | [.displayName, .state, .repository, .name] | @tsv' \
        | sort | column -t -s $'\t' 2>/dev/null || cs_list_json
      ;;
    acquire)
      shift; [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: fm-cs-pool.sh acquire <repo> <task> [branch]" >&2; exit 2; }
      cs_pool_acquire "$1" "$2" "${3:-}"
      ;;
    release)
      shift; [ -n "${1:-}" ] || { echo "usage: fm-cs-pool.sh release <codespace>" >&2; exit 2; }
      cs_pool_release "$1"
      ;;
    recreate-free)
      shift; cs_pool_recreate_free "${1:-}"
      ;;
    ""|-h|--help)
      sed -n '2,30p' "$0"
      ;;
    *)
      echo "unknown command: $cmd" >&2; exit 2 ;;
  esac
}
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
