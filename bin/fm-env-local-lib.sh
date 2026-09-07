# shellcheck shell=bash
# fm-env-local-lib.sh - the single owner of a task worktree's .env.local lifecycle.
#
# Usage: . bin/fm-env-local-lib.sh
#
# fm_env_local_apply is the whole contract: bin/fm-spawn.sh calls it around the
# pooled-base refresh to retire an unignored leftover and then seed the current
# copy, and bin/fm-teardown.sh calls its retire phase before the uncommitted-work
# check so firstmate's own artifact never strands the slot it was seeded into.
# Both callers reach the same decisions from this one place; a second copy of a
# credential copy-or-delete decision is how a guard added to one caller silently
# leaves the other making the old decision.
#
# fm_env_local_apply's seed phase needs fm_inherit_file_device from
# bin/fm-config-inherit-lib.sh; the retire phase needs nothing beyond git, so a
# caller that only retires need not source that library.
# Seed the one checkout-local credential file from the captain's primary checkout
# into every worktree spawn acquires. No worktree provider seeds git-ignored files:
# treehouse creates and reissues a pooled slot without one, and orca creates its
# worktree with --setup skip. Firstmate therefore owns this seeding outright rather
# than inheriting it, so the acquisition call sits on the common acquisition gate
# and covers a newly created slot, a reused slot, and every backend alike.
# Refreshing on each acquisition also keeps a slot from serving a stale credential
# copy left behind by an earlier task, including when the captain revoked that
# credential by deleting the file outright rather than by rewriting it.
#
# Seeding applies while, and only while, the project git-ignores .env.local: a copy
# the project does not ignore is untracked work, and every step that inspects the
# working tree refuses it. Because a task can drop that ignore rule mid-flight, an
# artifact this seeding authored can become the reason a slot never returns to the
# pool, so the acquisition and teardown both retire such a copy - each only after
# the check that protects unlanded work has already passed on it.
#
# Authorship is proved by a record, never by content. When the seed phase publishes
# a copy it records that copy's digest in the worktree's own git directory, and a
# retire happens only when that record exists and the file still matches it. Bytes
# alone prove nothing: a task can legitimately author a .env.local whose content
# equals the project checkout's, and deleting that without the captain's explicit
# discard authority would tear down unlanded work. No record, or a file that no
# longer matches one, means the file is the task's and is left for the caller's own
# uncommitted-work check to refuse.

# Firstmate authors a file inside a worktree it does not own, so every edge of that
# ownership is settled deliberately here rather than falling out of branch order.
# The whole contract, in one place:
#
#   source absent + target absent      no-op
#   project tracks .env.local          no-op, warns (version-controlled content is
#                                      neither seeded over nor retired)
#   tracked question unresolvable      treated as tracked: no-op, warns
#   ignore check unresolvable          refuse (cannot establish, never assume benign)
#   not ignored + target absent        warn, skip
#   not ignored + target present       retire only if the seed record proves this
#                                      library wrote that exact file and nothing
#                                      changed it since, else refuse with the
#                                      manual cleanup
#   target is a directory              refuse
#   source absent + clone searchable   retire (a revoked credential must not persist)
#   source absent + clone unsearchable refuse (deletion not positively established)
#   source a broken symlink            never retires; warns, and names a stale target
#   source a symlink to a regular file seeds the dereferenced content
#   target a symlink                   publish replaces the link, retire removes it
#   git dir unresolvable/unwritable    refuse
#   filesystem identity unreadable     refuse
#   genuine cross-device               degrade to a loud skip, naming a stale target
#   staging scratch                    swept at entry, on every path
#
# Retiring never degrades: it needs no staging, and it is the half that carries the
# real risk. Seeding is a convenience and may degrade. Contents are never printed.

# A .env.local the project commits is the repository's own version-controlled
# content: this seeding never writes over it and never deletes it. Seeding over it
# would put the captain's real credentials in a file the project commits, and
# deleting it makes `git status` report a deletion, which the base refresh refuses
# as uncommitted work and teardown then refuses to return - a wedge on every slot.
#
# git check-ignore does NOT answer the tracked question. It consults the index, so
# a tracked path whose .gitignore rule matches still reports exit 1, not-ignored,
# and the unignored branches below would then take repository content for this
# seeding's own artifact. `git ls-files --error-unmatch` answers it directly, in the
# same 0-or-1 shape the ignore check uses: 0 (tracked), 1 (not in the index), and
# anything else is git failing to answer at all. That last case is treated as
# tracked, because a state that cannot be positively established is never the
# permissive one, exactly as the ignore, deletion and cross-device checks already
# are. Git's own message is carried into the warning, since an operator reading a
# bare exit code cannot tell an unreadable index from a missing repository.
fm_env_local_is_tracked() {  # <worktree> <announce-warnings:0|1>
  local worktree=$1 announce=$2 tracked=0 track_err
  track_err=$(git -C "$worktree" ls-files --error-unmatch -- .env.local 2>&1 >/dev/null) || tracked=$?
  # Announced once per acquisition. Both phases ask, and repeating the line for a
  # project that simply commits the file would read as two separate problems.
  if [ "$tracked" -gt 1 ]; then
    if [ "$announce" = 1 ]; then
      echo "warning: could not determine whether '$worktree' tracks .env.local; git ls-files exited $tracked${track_err:+: $track_err}" >&2
      echo "warning: .env.local is treated as tracked there and left untouched while that check is unresolved" >&2
    fi
    return 0
  fi
  [ "$tracked" -eq 0 ] || return 1
  if [ "$announce" = 1 ]; then
    echo "warning: not seeding or retiring .env.local in '$worktree' because the project tracks that file; it is version-controlled content this seeding never touches" >&2
  fi
  return 0
}

# The one owner of the ignore verdict, which gates the delete decision below. Both
# phases ask git the identical question and differ only in the action their refusal
# names, so how an unresolvable answer is classified is spelled out once: a second
# copy is how one phase ends up refusing the slot before the base refresh while the
# other still refuses after it.
#
# check-ignore answers 0 (ignored) or 1 (not ignored); anything else is git failing
# to answer at all, reported here as 2. Reporting that as a missing ignore rule
# would send an operator to edit a .gitignore that already carries the rule while
# the task runs without credentials, which is the exact false blocker this seeding
# exists to remove. A state that cannot be established is never the benign one.
fm_env_local_ignored_verdict() {  # <worktree> <target> <refused-action>
  local worktree=$1 target=$2 refused=$3 ignored=0 check_err
  check_err=$(git -C "$worktree" check-ignore -q .env.local 2>&1) || ignored=$?
  if [ "$ignored" -gt 1 ]; then
    echo "error: could not determine whether '$worktree' ignores .env.local; git check-ignore exited $ignored${check_err:+: $check_err}" >&2
    echo "error: refusing to $refused '$target' while that check is unresolved" >&2
    return 2
  fi
  return "$ignored"
}

# Where the seed record lives, and what it holds. The worktree's own git directory
# is git's private storage for that worktree: git never reports it as working-tree
# content, it travels with a pooled slot across a return and a reissue, and it is
# already where this library stages its copy. The record holds a digest and never
# the seeded bytes, so it cannot outlive a revoked credential the way a kept copy
# would. The name deliberately sits outside the fm-env-local.* scratch glob the
# seed phase sweeps, because that sweep must not destroy the evidence teardown
# needs.
fm_env_local_seed_record_path() {  # <worktree>
  local gitdir
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$gitdir" ] || return 1
  printf '%s\n' "$gitdir/fm-env-local-seed-record"
}

fm_env_local_digest() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_env_local_file_identity() {  # <file>
  # Include ctime so an in-place rewrite is not mistaken for the untouched
  # seeded file merely because it preserved the inode and bytes.
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i:%c' "$1" 2>/dev/null
  else
    stat -c '%d:%i:%Z' "$1" 2>/dev/null
  fi
}

# The single authorship question, asked read-only: is the worktree's .env.local
# exactly the file this library seeded into that worktree, untouched since? Every
# unresolvable answer is a no, because the permissive answer here would delete a
# task's own unlanded work.
fm_env_local_seeded_copy_intact() {  # <worktree>
  local worktree=$1 record recorded identity current current_identity target="$1/.env.local"
  record=$(fm_env_local_seed_record_path "$worktree") || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  recorded=$(sed -n 's/^sha256=//p' "$record" 2>/dev/null | head -1)
  [ -n "$recorded" ] || return 1
  identity=$(sed -n 's/^identity=//p' "$record" 2>/dev/null | head -1)
  [ -n "$identity" ] || return 1
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  current_identity=$(fm_env_local_file_identity "$target") || return 1
  [ "$current_identity" = "$identity" ] || return 1
  current=$(fm_env_local_digest "$target") || return 1
  [ -n "$current" ] && [ "$current" = "$recorded" ]
}

# Publish the record for a copy just seeded, or drop it because this call leaves no
# copy of this library's own behind. A record that cannot be written is dropped
# rather than left stale: without it a later retire refuses, which is the safe
# direction, while a stale one would authorize deleting a file this library did not
# write.
fm_env_local_write_seed_record() {  # <worktree> <seeded-file>
  local record digest identity
  record=$(fm_env_local_seed_record_path "$1") || return 1
  digest=$(fm_env_local_digest "$2") || digest=""
  identity=$(fm_env_local_file_identity "$2") || identity=""
  if [ -z "$digest" ] || [ -z "$identity" ]; then
    rm -f "$record" 2>/dev/null || true
    return 1
  fi
  ( umask 077; printf 'sha256=%s\nidentity=%s\n' "$digest" "$identity" > "$record" ) 2>/dev/null \
    || { rm -f "$record" 2>/dev/null || true; return 1; }
}

fm_env_local_drop_seed_record() {  # <worktree>
  local record
  record=$(fm_env_local_seed_record_path "$1") || return 0
  rm -f "$record" 2>/dev/null || true
}

# The one owner of the decision to delete an unignored copy. Both phases reach the
# identical decision and differ only in which step would refuse the slot next, so
# the decision is spelled out once: a second copy of a credential deletion is how a
# guard added to one phase silently leaves the other making the old decision.
#
# Retire only what the seed record proves this library wrote and nothing changed
# since. Content is not evidence: a task can author a .env.local whose bytes equal
# the project checkout's, and deleting that would tear down unlanded work without
# the captain's explicit discard authority. Anything the record cannot account for
# is refused, and every refusal names the file and the cleanup that clears the slot.
# Digests are compared, never printed, and the file's own bytes are never read out.
fm_env_local_retire_unignored_copy() {  # <worktree> <target> <refusing-step>
  local worktree=$1 target=$2 refuser=$3
  if ! fm_env_local_seeded_copy_intact "$worktree"; then
    echo "error: '$target' is not ignored by the project and this seeding has no record of writing that exact file, so it is the task's own work and will not be removed" >&2
    echo "error: $refuser will refuse it as uncommitted work; save anything worth keeping out of '$target', then remove it by hand" >&2
    return 1
  fi
  if ! rm -f "$target"; then
    echo "error: could not retire this seeding's own unignored copy at '$target'; remove it by hand so $refuser does not refuse it as uncommitted work" >&2
    return 1
  fi
  fm_env_local_drop_seed_record "$worktree"
  echo "warning: removed this seeding's own copy at '$target' because the project no longer ignores .env.local; restore that ignore rule so crew worktrees can carry it again" >&2
}

# Remove the copy this library seeded after the caller's work-preservation checks
# have passed and its task processes have been reaped. It re-asks the authorship
# question rather than trusting the caller's earlier answer, so a file that changed
# in between is never deleted on a stale verdict.
fm_env_local_retire_seeded_copy() {  # <worktree>
  local worktree=$1
  fm_env_local_seeded_copy_intact "$worktree" || return 1
  rm -f "$worktree/.env.local" || return 1
  fm_env_local_drop_seed_record "$worktree"
}

fm_env_local_apply() {  # <worktree> <project> <retire|seed> <refusing-step>
  local worktree=$1 project=$2 phase=$3 refuser=$4
  local source target tmp ignored gitdir stage_device tree_device announce=0
  [ "$phase" != seed ] || announce=1
  source="$project/.env.local"
  target="$worktree/.env.local"
  # Clear the staging area on the way in, before any branch below can return. A
  # copy killed mid-flight leaves a scratch file holding the captain's credential
  # bytes, and a linked worktree's git directory is reachable from inside the
  # worktree, so a leftover would stay readable to every later task in this slot -
  # outliving even the revocation the retire branch below exists to enforce.
  # Sweeping at entry keeps that closed no matter which path this call takes, in
  # either phase, where a sweep further down would be skipped by every early
  # return. The scratch is invisible to git, so a leftover directory here is
  # harmless and must never become a refusal of its own.
  gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=""
  # Keep the seed record: only mktemp's six-character suffix names staging
  # scratch, while fm-env-local-seed-record is the retire phase's ownership
  # evidence and must survive until that phase has read it.
  [ -z "$gitdir" ] || rm -f "$gitdir"/fm-env-local.?????? 2>/dev/null || true
  # Every seed-phase path that returns below leaves no copy of this library's own
  # in the worktree except the one published at the very end, so the record is
  # dropped once here and written once there. That keeps it describing the current
  # acquisition and nothing older, without a removal on each of a dozen returns -
  # one of which would eventually be missed, and a stale record is precisely what
  # would authorize deleting a file this library did not write. The retire phase
  # must NOT drop it here: that phase exists to read this evidence.
  # Gates both halves of the contract, in both phases, from one place.
  if fm_env_local_is_tracked "$worktree" "$announce"; then
    return 0
  fi
  # The retire phase runs on its own, ahead of any step that inspects the working
  # tree for uncommitted work. An unignored copy IS untracked work, so the
  # acquisition's base refresh and teardown's uncommitted-work check both refuse
  # the slot before anything downstream runs - the same trap that made an earlier
  # scratch sweep unreachable. One owner still holds the whole lifecycle; it just
  # runs as an ordered phase each caller invokes before the step that would
  # otherwise refuse the very artifact this seeding authored.
  if [ "$phase" = retire ]; then
    { [ -e "$target" ] || [ -L "$target" ]; } || return 0
    ignored=0
    fm_env_local_ignored_verdict "$worktree" "$target" retire || ignored=$?
    [ "$ignored" -ne 2 ] || return 1
    [ "$ignored" -eq 1 ] || return 0
    fm_env_local_retire_unignored_copy "$worktree" "$target" "$refuser" || return 1
    return 0
  fi
  # Nothing to carry in, and no earlier task's copy left to retire.
  if [ ! -e "$source" ] && [ ! -L "$source" ] && [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  # Act only on what the project ignores: seeding applies while, and only while, the
  # project ignores .env.local. An unignored .env.local would land as untracked
  # work, and teardown's uncommitted-work refusal would then strand the worktree
  # forever. Say so once instead of wedging the task's cleanup later.
  ignored=0
  fm_env_local_ignored_verdict "$worktree" "$target" "seed or retire" || ignored=$?
  [ "$ignored" -ne 2 ] || return 1
  if [ "$ignored" -eq 1 ]; then
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      echo "warning: not seeding .env.local into '$worktree' because the project does not ignore it; add it to .gitignore so crew worktrees can carry it" >&2
      return 0
    fi
    # Reachable only when the ignore rule changed between the two phases. An
    # unignored copy already sitting here is untracked work, and teardown refuses
    # that before the next acquisition's clean check ever runs this seeding again,
    # so nothing automatic can free the slot afterwards. Firstmate authors this file
    # now, so retiring its own artifact here is the single chance to clear the wedge
    # unattended; whenever the rule disappears over a copy that cannot be proven to
    # be this seeding's own, the slot needs human attention, which is what every
    # refusal below asks for by name.
    fm_env_local_retire_unignored_copy "$worktree" "$target" "$refuser" || return 1
    return 0
  fi
  if [ -d "$target" ]; then
    echo "error: refusing to touch .env.local in '$worktree' because '$target' is a directory" >&2
    return 1
  fi
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    # The captain's copy is gone, so the slot's copy is a revoked credential the
    # next task must not inherit. Only a positively established deletion may remove
    # it: an unreadable source is not a deletion, so when the primary checkout
    # cannot even be searched, absence and failure are indistinguishable and the
    # copy stays put while the spawn stops.
    if [ ! -d "$project" ] || [ ! -x "$project" ]; then
      echo "error: cannot tell whether '$source' was deleted or is unreadable because '$project' is not a searchable directory; leaving '$target' in place" >&2
      return 1
    fi
    if ! fm_env_local_retire_seeded_copy "$worktree"; then
      echo "error: could not retire the stale .env.local in '$worktree' after it disappeared from '$project'" >&2
      return 1
    fi
    return 0
  fi
  if [ ! -f "$source" ]; then
    # Not a positively established deletion (a broken symlink lands here too), so
    # the copy below is never retired on this path. Say what the slot actually
    # holds: claiming it is empty while it still serves an earlier copy is how a
    # rotated-out credential passes for a current one.
    echo "warning: not seeding .env.local into '$worktree' because '$source' is not a regular file" >&2
    if [ -e "$target" ] || [ -L "$target" ]; then
      echo "warning: '$worktree' still holds an earlier .env.local that could not be refreshed, so it may be out of date; replace it from '$project' by hand before a task relies on it" >&2
    fi
    return 0
  fi
  # Stage the copy inside the worktree's own git directory, never in the working
  # tree. A scratch file in the tree is untracked work no .env.local rule covers,
  # so an interrupted copy would fail the next acquisition's clean check and block
  # teardown from returning the slot - the very wedge the ignore gate above exists
  # to prevent, and one no later sweep could undo, because the clean check runs
  # before this seeding does. A linked worktree's git directory resolves through
  # its .git file to the repository's worktrees/<name>, which is git's own storage
  # for that worktree: git never reports it as working-tree content, and it shares
  # the worktree's filesystem so the publish below stays an atomic rename.
  #
  # A target this seeding cannot resolve or write, and a filesystem question it
  # cannot answer at all, are states that stay refusals. A layout where the two
  # genuinely sit on different filesystems is not: seeding is a convenience, and
  # that layout spawned fine before firstmate owned it, so degrading to a loud skip
  # beats turning it into a spawn that cannot start. Retiring a revoked copy above
  # needs no staging and so never degrades with it.
  if [ -z "$gitdir" ] || [ ! -d "$gitdir" ] || [ ! -w "$gitdir" ]; then
    echo "error: could not resolve a writable git directory for '$worktree'; refusing to stage .env.local through the working tree where an interrupted copy would strand the worktree" >&2
    return 1
  fi
  stage_device=$(fm_inherit_file_device "$gitdir") || stage_device=""
  tree_device=$(fm_inherit_file_device "$worktree") || tree_device=""
  if [ -z "$stage_device" ] || [ -z "$tree_device" ]; then
    echo "error: could not read which filesystem '$gitdir' and '$worktree' are on, so .env.local cannot be published atomically; refusing rather than guessing" >&2
    return 1
  fi
  if [ "$stage_device" != "$tree_device" ]; then
    echo "warning: '$gitdir' and '$worktree' are on different filesystems, so .env.local cannot be published there by atomic rename and was not seeded" >&2
    if [ -e "$target" ] || [ -L "$target" ]; then
      echo "warning: '$worktree' still holds an earlier .env.local that could not be refreshed, so it may be out of date; copy '$source' over it by hand before a task relies on it" >&2
    else
      echo "warning: '$worktree' has no .env.local and any task running in it will find no credentials; copy '$source' into '$worktree' by hand before that task needs them" >&2
    fi
    return 0
  fi
  tmp=$(mktemp "$gitdir/fm-env-local.XXXXXX") || {
    echo "error: could not create a private temporary file while seeding .env.local for '$worktree'" >&2
    return 1
  }
  if ! cp -p "$source" "$tmp"; then
    rm -f "$tmp"
    echo "error: could not seed .env.local in '$worktree'" >&2
    return 1
  fi
  # Never let a reissue replace a file that may have been authored by the task.
  # Refreshing an existing copy is allowed only when the seed record still proves
  # that this library owns the untouched file.
  if [ -e "$target" ] || [ -L "$target" ]; then
    if ! fm_env_local_seeded_copy_intact "$worktree"; then
      rm -f "$tmp"
      echo "error: refusing to replace '$target' because this seeding cannot prove it owns the existing .env.local; preserve the task's file and remove it by hand before reissuing the worktree" >&2
      return 1
    fi
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    echo "error: could not publish the seeded .env.local in '$worktree'" >&2
    return 1
  fi
  if ! fm_env_local_write_seed_record "$worktree" "$target"; then
    rm -f "$target"
    echo "error: seeded .env.local in '$worktree' but could not record its ownership; removed the copy and refusing the acquisition" >&2
    return 1
  fi
}
