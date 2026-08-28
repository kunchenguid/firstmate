#!/usr/bin/env bash
# Treehouse durable worktree guards shared by spawn and bootstrap.
#
# A live task's state/<id>.meta worktree= record is the authority for its
# checkout. Treehouse's normal owner reservation is process-bound, so a reboot
# can leave that checkout looking available before the task record is retired.
# These helpers locate its pool-owned state file, take Treehouse's advisory-lock
# boundary, and register a pid-less durable lease. Bootstrap repairs local
# recorded Treehouse worktrees after a reboot when their owning pool can be
# identified; remote records belong to another filesystem namespace and are
# ignored. Fresh spawns also reject a local path recorded by another task as a
# final collision guard.

FM_TREEHOUSE_LEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_treehouse_real_path_or_raw() {  # <path>
  local path=$1
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
  else
    printf '%s\n' "$path"
  fi
}

fm_treehouse_state_file_for_worktree() {  # <worktree> -> treehouse-state.json, if an ancestor owns it
  local target dir candidate
  target=$(fm_treehouse_real_path_or_raw "$1") || return 1
  dir=$(dirname "$target")
  while [ "$dir" != / ]; do
    candidate="$dir/treehouse-state.json"
    if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
      if node - "$candidate" "$target" >/dev/null 2>&1 <<'NODE'
const fs = require('fs');

const [stateFile, requestedPath] = process.argv.slice(2);
const requested = fs.realpathSync(requestedPath);
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
if (!Array.isArray(state.worktrees)) process.exit(1);
const matches = state.worktrees.filter((entry) => {
  if (!entry || typeof entry.path !== 'string') return false;
  try { return fs.realpathSync(entry.path) === requested; } catch { return false; }
});
if (matches.length !== 1) process.exit(1);
NODE
      then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

fm_treehouse_meta_worktree() {  # <meta>
  local meta=$1 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  grep -q '^remote_host=.' "$meta" 2>/dev/null && return 1
  count=$(grep -c '^worktree=' "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n 's/^worktree=//p' "$meta"
}

fm_treehouse_recorded_worktree_owner() {  # <state-dir> <excluding-task-id> <worktree> -> task id
  local state=$1 excluded_id=$2 worktree=$3 meta id recorded target
  [ -d "$state" ] || return 1
  target=$(fm_treehouse_real_path_or_raw "$worktree") || return 1
  while IFS= read -r -d '' meta; do
    id=$(basename "$meta" .meta)
    [ "$id" = "$excluded_id" ] && continue
    recorded=$(fm_treehouse_meta_worktree "$meta" 2>/dev/null || true)
    [ -n "$recorded" ] || continue
    [ "$(fm_treehouse_real_path_or_raw "$recorded")" = "$target" ] || continue
    printf '%s\n' "$id"
    return 0
  done < <(find "$state" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
  return 1
}

fm_treehouse_register_durable_lease() {  # <treehouse-state.json> <worktree> <holder>
  local state_file=$1 worktree=$2 holder=$3 lock_file register_script
  command -v node >/dev/null 2>&1 || {
    echo "treehouse durable guard requires node" >&2
    return 1
  }
  lock_file="$(dirname "$state_file")/treehouse-state.lock"
  register_script="$FM_TREEHOUSE_LEASE_LIB_DIR/fm-treehouse-register-lease.mjs"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9 || exit 1
      node "$register_script" "$state_file" "$worktree" "$holder"
    ) 9>"$lock_file"
    return
  fi
  command -v perl >/dev/null 2>&1 || {
    echo "treehouse durable guard requires flock or perl" >&2
    return 1
  }
  perl -MFcntl=:DEFAULT,:flock -e '
    my $lock_path = shift @ARGV;
    sysopen(my $lock, $lock_path, O_RDWR | O_CREAT, 0644) or die "open $lock_path: $!\n";
    flock($lock, LOCK_EX) or die "lock $lock_path: $!\n";
    my $status = system @ARGV;
    exit 127 if $status == -1;
    exit 128 + ($status & 127) if $status & 127;
    exit $status >> 8;
  ' "$lock_file" node "$register_script" "$state_file" "$worktree" "$holder"
}

fm_treehouse_guard_recorded_worktrees() {  # <state-dir>
  local state=$1 meta id worktree state_file
  [ -d "$state" ] || return 0
  command -v node >/dev/null 2>&1 || {
    echo "treehouse durable guard requires node" >&2
    return 1
  }
  while IFS= read -r -d '' meta; do
    id=$(basename "$meta" .meta)
    worktree=$(fm_treehouse_meta_worktree "$meta" 2>/dev/null || true)
    [ -n "$worktree" ] || continue
    state_file=$(fm_treehouse_state_file_for_worktree "$worktree" 2>/dev/null || true)
    [ -n "$state_file" ] || continue
    fm_treehouse_register_durable_lease "$state_file" "$worktree" "firstmate:$id" || return 1
  done < <(find "$state" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
}
