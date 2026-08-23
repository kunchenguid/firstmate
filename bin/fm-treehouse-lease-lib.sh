#!/usr/bin/env bash
# Treehouse durable worktree guards shared by spawn and bootstrap.
#
# A live task's state/<id>.meta worktree= record is the authority for its
# checkout. Treehouse's normal owner reservation is process-bound, so a reboot
# can leave that checkout looking available before the task record is retired.
# These helpers locate its pool state file, lock it with Treehouse's own flock
# boundary, and register a pid-less durable lease. Bootstrap repairs all
# recorded worktrees after a reboot; fresh spawns also reject a path recorded by
# another task as a final collision guard.

fm_treehouse_real_path_or_raw() {  # <path>
  local path=$1
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
  else
    printf '%s\n' "$path"
  fi
}

fm_treehouse_state_file_for_worktree() {  # <worktree> -> treehouse-state.json, if an ancestor owns it
  local dir
  dir=$(fm_treehouse_real_path_or_raw "$1") || return 1
  while [ "$dir" != / ]; do
    if [ -f "$dir/treehouse-state.json" ] && [ ! -L "$dir/treehouse-state.json" ]; then
      printf '%s\n' "$dir/treehouse-state.json"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

fm_treehouse_meta_worktree() {  # <meta>
  local meta=$1 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
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
  local state_file=$1 worktree=$2 holder=$3 lock_file
  command -v flock >/dev/null 2>&1 || {
    echo "treehouse durable guard requires flock" >&2
    return 1
  }
  command -v node >/dev/null 2>&1 || {
    echo "treehouse durable guard requires node" >&2
    return 1
  }
  lock_file="$(dirname "$state_file")/treehouse-state.lock"
  (
    flock -x 9 || exit 1
    node - "$state_file" "$worktree" "$holder" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const [stateFile, requestedPath, holder] = process.argv.slice(2);
const requested = fs.realpathSync(requestedPath);
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
if (!Array.isArray(state.worktrees)) throw new Error('treehouse state has no worktrees array');
const matches = state.worktrees.filter((entry) => {
  try { return fs.realpathSync(entry.path) === requested; } catch { return false; }
});
if (matches.length !== 1) throw new Error(`treehouse state has ${matches.length} entries for ${requested}`);
const entry = matches[0];
entry.leased = true;
entry.lease_id ||= crypto.randomBytes(16).toString('hex');
entry.lease_holder ||= holder;
entry.leased_at ||= new Date().toISOString();
delete entry.owner_pid;
delete entry.owner_started_at;
const mode = fs.statSync(stateFile).mode;
const temp = `${stateFile}.fm-guard-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
let fd;
try {
  fd = fs.openSync(temp, 'wx', mode);
  fs.writeFileSync(fd, `${JSON.stringify(state, null, 2)}\n`);
  fs.fsyncSync(fd);
  fs.closeSync(fd);
  fd = undefined;
  fs.renameSync(temp, stateFile);
  const dirfd = fs.openSync(path.dirname(stateFile), 'r');
  try { fs.fsyncSync(dirfd); } finally { fs.closeSync(dirfd); }
} finally {
  if (fd !== undefined) fs.closeSync(fd);
  try { fs.unlinkSync(temp); } catch (error) { if (error.code !== 'ENOENT') throw error; }
}
NODE
  ) 9>"$lock_file"
}

fm_treehouse_guard_recorded_worktrees() {  # <state-dir>
  local state=$1 meta id worktree state_file
  [ -d "$state" ] || return 0
  while IFS= read -r -d '' meta; do
    id=$(basename "$meta" .meta)
    worktree=$(fm_treehouse_meta_worktree "$meta" 2>/dev/null || true)
    [ -n "$worktree" ] || continue
    state_file=$(fm_treehouse_state_file_for_worktree "$worktree" 2>/dev/null || true)
    [ -n "$state_file" ] || continue
    fm_treehouse_register_durable_lease "$state_file" "$worktree" "firstmate:$id" || return 1
  done < <(find "$state" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
}
