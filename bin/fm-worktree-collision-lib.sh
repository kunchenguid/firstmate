# shellcheck shell=bash
# Worktree double-registration detection: two state/*.meta records claiming
# the same worktree= path. This header is the ONE owner of the check's
# contract; bin/fm-bootstrap.sh states only the emitted line format, and
# .agents/skills/bootstrap-diagnostics/SKILL.md only what to do about a line.
# Usage: . bin/fm-worktree-collision-lib.sh
#
# Requires bin/fm-backend.sh (fm_meta_get, fm_backend_of_meta,
# fm_backend_target_of_meta, fm_backend_agent_state) and bin/fm-tangle-lib.sh
# (fm_default_branch) sourced first by the caller. This file is sourced by
# scripts and has no side effects on source.
#
# A pooled worktree handed to two live task records is quiet and expensive: a
# commit can land on the wrong branch, or a teardown can return a copy another
# task still needs. This is detection only - it never repairs a collision,
# because an automatic fix here could discard unlanded work.
#
# Every emitted phrase is held to one rule: say exactly what the probe behind
# it proves, and no more. A backend that answered is never described as
# unreachable, and a path that could not be inspected is never described as
# empty.
#
# Two independent axes decide a collision, and each is owned by exactly one
# classifier below. PROCESS STATE (one verdict per record, from the backend)
# alone decides the kind: `live` means two or more claimants are still hazards,
# `stale` means at most one is. PATH STATE (one verdict per colliding path,
# from git) never changes the kind and never withholds a line; it only appends
# one caveat naming what is at risk at the shared path. The path fact belongs
# to the path, not to any one claimant, so it is never counted once per record.
#
# Nothing suppresses reporting. Every path claimed by more than one local
# record prints exactly one line, whatever either axis says, because absence of
# evidence is itself something the output must SAY rather than stay silent
# about.
#
# fm_worktree_collision_path_state classifies the shared worktree itself from
# cheap, entirely local git reads (no network). Exactly three verdicts are
# conclusions, and every probe that could not reach one shares a single
# fourth:
#   missing              - the path's absence was actually observed: nothing is
#                          there, and the nearest existing ancestor directory
#                          was searchable, so the absence is a fact rather than
#                          a stat that was refused. The only verdict that
#                          proves there is nothing left to lose there, and so
#                          the only one whose caveat carries no do-not-discard
#                          clause.
#   unlanded             - a probe answered, and its answer was that work is at
#                          risk: the worktree holds uncommitted changes that
#                          are the task's own (see fm_worktree_collision_task_dirty
#                          for who decides that), or the ancestry check ran and
#                          said HEAD is not reachable from the project's
#                          default branch.
#   landed               - the worktree is clean and its HEAD was checked and
#                          found reachable from the PUBLISHED default branch,
#                          origin/<default>. Nothing at the path is at risk.
#                          Ancestry from the LOCAL default branch alone never
#                          reaches this verdict: a branch merged into a local
#                          `main` that was pushed nowhere is exactly the copy
#                          bin/fm-teardown.sh's validate_worktree_teardown_safety
#                          refuses to discard ("work not on any remote and not
#                          landed"), so calling it landed - and printing the
#                          empty, safe-to-reclaim caveat - would be the
#                          falsely reassuring claim this file forbids.
#   unverifiable:<cause> - a probe could not answer at all, so the path is
#                          NEITHER landed nor unlanded, and the emitted caveat
#                          says so while naming <cause>. This is the one shared
#                          mechanism for every unanswerable probe; new causes
#                          are added to it rather than given a branch of their
#                          own. Current causes:
#                            not-a-worktree  - git resolved no work tree there
#                              (a dangling .git pointer, a bare repository, a
#                              plain file, a path inside a .git dir), the same
#                              --show-toplevel condition bin/fm-teardown.sh's
#                              own inspectable_git_worktree refuses on.
#                            worktree-state  - the working-tree probe itself
#                              failed (a truncated or unreadable .git/index).
#                              It printed no changes because it read none,
#                              which is not the same fact as a clean tree.
#                            default-branch  - the ancestry check could not be
#                              performed: no origin/HEAD and no local
#                              main/master to resolve a default branch, no ref
#                              for the resolved name, or a shallow or grafted
#                              history that made merge-base error out.
#                            unpublished-default - the ancestry check ran and
#                              the only ref that could answer it was the LOCAL
#                              default branch: HEAD is reachable from it, while
#                              origin/<default> either does not exist or could
#                              not answer. The commits are on no remote, so
#                              nothing here proves the copy is safe to reclaim.
#                            path-unreadable - the path could not be stat'ed
#                              because an ancestor directory is not searchable,
#                              so its absence was refused rather than observed.
#                            no-path         - no path was given at all. An
#                              argument this classifier cannot recognise is a
#                              non-answer, never an observed absence.
# The rule those verdicts encode, in both directions: a probe that could not
# run proves nothing, so it may never reach `landed` or `missing` (a falsely
# reassuring claim) and may never claim `unlanded` work it did not see (a
# falsely alarming one). Safety does not change either way - every verdict
# except `missing` carries the same do-not-discard clause.
fm_worktree_collision_path_state() {  # <worktree-path>
  local path=$1 default top status_out ref rc answered=0 local_only=0
  if [ -z "$path" ]; then
    printf 'unverifiable:no-path'
    return 0
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    if ! fm_worktree_collision_absence_observed "$path"; then
      printf 'unverifiable:path-unreadable'
      return 0
    fi
    printf 'missing'
    return 0
  fi
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null && printf X)
  top=${top%X}
  top=${top%$'\n'}
  if [ -z "$top" ] || [ ! -d "$top" ]; then
    printf 'unverifiable:not-a-worktree'
    return 0
  fi
  if ! status_out=$(git -C "$path" status --porcelain 2>/dev/null); then
    printf 'unverifiable:worktree-state'
    return 0
  fi
  if [ -n "$(fm_worktree_collision_task_dirty "$status_out")" ]; then
    printf 'unlanded'
    return 0
  fi
  default=$(fm_default_branch "$path" 2>/dev/null || true)
  if [ -n "$default" ]; then
    for ref in "origin/$default" "$default"; do
      git -C "$path" rev-parse --verify -q "$ref" >/dev/null 2>&1 || continue
      if git -C "$path" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
        case "$ref" in
          origin/*)
            printf 'landed'
            return 0
            ;;
          *) local_only=1 ;;
        esac
      else
        rc=$?
        if [ "$rc" = 1 ]; then
          answered=1
        fi
      fi
    done
  fi
  if [ "$answered" = 1 ]; then
    printf 'unlanded'
    return 0
  fi
  if [ "$local_only" = 1 ]; then
    printf 'unverifiable:unpublished-default'
    return 0
  fi
  printf 'unverifiable:default-branch'
}

# The grouping key for one recorded worktree= path: its physically resolved
# form when the path can be reached, and the recorded string itself otherwise.
# Two records can spell one pooled copy differently - bin/fm-spawn.sh's own
# worktree-vs-pane comparison documents backends that report a physically
# resolved cwd beside ones that report the shell's logical, symlink-preserving
# path - and grouping on the raw strings would never see those as one path.
# This applies the same cd-and-pwd-P-with-fallback rule bin/fm-spawn.sh's
# real_path_or_raw uses for exactly that question, with one added step: the
# resolved form is machine-generated and nothing bounds what `pwd -P` can
# contain, so a resolved path holding a newline is escaped rather than
# discarded (fm_worktree_collision_line_safe) before it becomes the key. Two
# different recorded spellings of the SAME newline-holding copy still resolve
# to the same physical path, so they must still produce the same key - falling
# back to each record's own (different) recorded string here would key them
# apart and let a real double registration on such a path go entirely
# unreported, exactly what grouping exists to prevent. Only a resolution that
# genuinely fails (cd or pwd -P itself does not succeed) falls back to the raw
# recorded string, because then there is no canonical form to escape. Either
# way the key stays newline-free, which is what the line-based transport in
# fm_worktree_collision_lines depends on.
# The rule itself lives in fm_worktree_collision_key_of_resolved, which takes a
# resolution that already happened, so the scan in fm_worktree_collision_lines
# - which needs the resolved path for the printed line anyway - derives the key
# from that one resolution instead of running a second identical `cd`+`pwd -P`.
# One resolution cannot disagree with itself if the filesystem changes mid-scan.
#
# fm_worktree_collision_resolve_path is the ONE place that resolution happens,
# and it answers through the caller's own fm_worktree_collision_real variable
# rather than stdout, because command substitution strips EVERY trailing
# newline while `pwd -P` adds one of its own: a copy at /pool/wt<LF> would come
# back as /pool/wt, a different path that normally does not exist at all, and
# the scan would then key on it, print it, and classify it - reaching the
# `missing` verdict, the one caveat with no do-not-discard clause, over a copy
# still holding the task's work. The X sentinel keeps every trailing newline
# the path itself has and drops only the one `pwd -P` appended. An empty answer
# means the resolution genuinely failed and there is no canonical form to use.
fm_worktree_collision_resolve_path() {  # <recorded-path> -> fm_worktree_collision_real
  fm_worktree_collision_real=$(cd "$1" 2>/dev/null && pwd -P && printf X) \
    || fm_worktree_collision_real=
  fm_worktree_collision_real=${fm_worktree_collision_real%X}
  fm_worktree_collision_real=${fm_worktree_collision_real%$'\n'}
}

fm_worktree_collision_key_of_resolved() {  # <recorded-path> <resolved-path-or-empty>
  if [ -n "$2" ]; then
    fm_worktree_collision_line_safe "$2"
  else
    printf '%s' "$1"
  fi
}

fm_worktree_collision_group_key() {  # <recorded-path>
  local path=$1 fm_worktree_collision_real
  fm_worktree_collision_resolve_path "$path"
  fm_worktree_collision_key_of_resolved "$path" "$fm_worktree_collision_real"
}

# Backslash-then-newline escaping so a machine-generated path that happens to
# hold a newline can still travel through a one-line transport or print on one
# line: every backslash is doubled first - always, whether or not the string
# holds a newline - so the newline escape it introduces can never be confused
# with one already present, then every newline becomes the two literal
# characters `\n`. The doubling is unconditional because this encoding is used
# as a GROUP KEY, and a rule applied only to newline-holding strings is not
# injective across strings: a path holding a real newline and a different path
# whose own name literally contains backslash-then-n would encode to one key,
# group two unrelated physical copies into one line, and name records that
# claim neither of the copies the other describes. The cost is that an ordinary
# path containing a backslash prints with that backslash doubled, which is an
# escaped rendering of a real path rather than a wrong one.
fm_worktree_collision_line_safe() {  # <string>
  local s=$1
  s=${s//\\/\\\\}
  printf '%s' "${s//$'\n'/\\n}"
}

# Which porcelain lines count as the TASK's work at a worktree is not this
# file's call: bin/fm-teardown.sh's validate_worktree_teardown_safety owns that
# definition, because it is the code that actually discards a copy, and it
# filters firstmate's own spawn-written scaffolding (bin/fm-spawn.sh writes
# .claude/settings.local.json into every claude task worktree) plus the harness
# turn-end markers out of the same probe. This applies that filter unchanged,
# so a shared copy holding only firstmate's own wiring is never reported as
# holding the task's work - the two readings of one probe cannot disagree.
fm_worktree_collision_task_dirty() {  # <porcelain-output>
  printf '%s\n' "$1" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' || true
}

# True only when a path's absence was OBSERVED rather than refused: walk up to
# the nearest ancestor that can be stat'ed and require it to be a searchable
# directory. A chmod-000 ancestor makes `[ ! -e ]` true for a worktree that is
# still there, holding work, so absence is a claim this has to earn.
fm_worktree_collision_absence_observed() {  # <path>
  local dir=$1
  while [ "$dir" != / ] && [ "$dir" != . ]; do
    dir=$(dirname "$dir")
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      { [ -d "$dir" ] && [ -x "$dir" ]; }
      return
    fi
  done
  [ -x "$dir" ]
}

# One caveat per path state, appended to the printed line whatever its kind -
# the risk at a shared path does not depend on how many processes are hazards.
# Every verdict that is not one of the three conclusions shares one sentence,
# built here once: the cause names which probe could not answer, and the same
# do-not-discard clause every non-landed verdict carries closes it. An
# unrecognised verdict takes that same branch with a generic cause, so a
# verdict added without a caveat can only ever read as unverified - never as
# the empty, safe-to-reclaim caveat `landed` earns.
fm_worktree_collision_path_caveat() {  # <path-state>
  local cause
  case "$1" in
    landed) ;;
    unlanded) printf ' - shared path still has unlanded work, do not discard' ;;
    missing) printf ' - shared worktree no longer exists at that path' ;;
    *)
      case "$1" in
        unverifiable:not-a-worktree) cause='is not an inspectable git worktree' ;;
        unverifiable:worktree-state) cause='is a git worktree whose working-tree state could not be read' ;;
        unverifiable:default-branch) cause="is a git worktree whose HEAD could not be checked against the project's default branch" ;;
        unverifiable:unpublished-default) cause='is a git worktree whose HEAD was found reachable only from a local default branch, because the published origin/<default> either does not exist or could not answer' ;;
        unverifiable:path-unreadable) cause='could not be examined because an ancestor directory is not searchable' ;;
        unverifiable:no-path) cause='was not provided, so no probe could look at anything' ;;
        *) cause='could not be examined' ;;
      esac
      printf ' - shared path %s, so whether work would be lost cannot be verified, do not discard' "$cause"
      ;;
  esac
}

# fm_worktree_collision_claimant_process reports ONE claimant's agent process
# from its own recorded backend endpoint alone - no git reads, so a claimant is
# never credited or blamed for the shared path's content. It passes through
# fm_backend_agent_state's own vocabulary verbatim (alive, dead, missing,
# ambiguous, unreadable, unverified - that function's header owns those
# meanings), because collapsing them here would throw away the distinction the
# printed line has to make between a backend that answered and one that could
# not. `no-endpoint` is this function's own addition, for a record carrying no
# usable target at all.
# Per that contract only `dead` and `missing` are confident finished verdicts,
# so every other value is a hazard for the kind.
fm_worktree_collision_claimant_process() {  # <meta-file>
  local meta=$1 target
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'no-endpoint'; return 0; }
  fm_backend_agent_state "$(fm_backend_of_meta "$meta")" "$target" 2>/dev/null \
    || printf 'unreadable'
}

# One human-readable fragment per claimant process state, used in the printed
# line. Each fragment describes only that claimant's own process - the shared
# path's state is reported once for the line, never here. An unverified verdict
# says the backend has no recovery classifier, an ambiguous or unreadable one
# quotes the verdict the backend actually returned, and a record with no
# endpoint blames no backend at all, so the reader is never sent to check a
# backend that answered correctly.
fm_worktree_collision_claimant_desc() {  # <claimant-process-state> [backend]
  local state=$1 backend=${2:-}
  case "$state" in
    alive) printf 'process alive' ;;
    dead|missing) printf 'process gone' ;;
    no-endpoint) printf 'process state unknown (record has no endpoint)' ;;
    *)
      if [ -z "$backend" ]; then
        printf 'process state unknown (%s)' "$state"
      elif [ "$state" = unverified ]; then
        printf 'process state unknown (backend=%s has no recovery classifier)' "$backend"
      else
        printf 'process state unknown (backend=%s reported %s)' "$backend" "$state"
      fi
      ;;
  esac
}

# fm_worktree_collision_lines: scan every state/*.meta under <state-dir> for
# worktree= paths claimed by more than one task record, and print one
# "WORKTREE_COLLISION: <kind> <path> claimed by <id> (<detail>), ...<caveat>"
# line per colliding path, in path order (the paths are sorted, so a stale
# collision can print before a live one). kind is `live` when two or more
# claimants are hazards on their own process state; otherwise `stale` - at most
# one hazardous claimant, so the collision is a finished task's leftover record
# rather than two tasks actually sharing a copy. The caveat is the path axis
# and rides either kind.
# Scope: LOCAL task records only. A record carrying remote_host= is skipped,
# because its worktree= is a path on another machine that is only unique when
# host-qualified (bin/fm-secondmate-registry-lib.sh keys those homes as
# ssh:<host>:<home>), and neither the local git probe nor the local backend
# probe can say anything true about it - so this check does NOT cover remote
# secondmates, whose dedicated homes are never pooled or recycled anyway.
# Prints nothing when no path is claimed twice. The scan is a snapshot, and
# this check holds no fleet lock, so a record torn down between the snapshot
# and its own process probe is dropped rather than reported as an unverifiable
# hazard: a path left with fewer than two surviving records is no longer a
# collision and prints nothing.
# Records are grouped by fm_worktree_collision_group_key, not by the recorded
# string, so two spellings of one pooled copy still collide. Because grouping
# proves only that the records point at one physical copy - not that they spell
# it alike - the line states both facts separately: the path after the kind is
# the shared physically resolved copy (re-derived from the first surviving
# claimant's own recorded spelling, then made line-safe for printing - never
# the group key itself, which may hold an escaped newline that is not a usable
# path), and every claimant's own segment names the worktree= that record
# actually contains. No single spelling is ever printed as though every
# claimant recorded it. A claimant whose record no longer keys to this group
# when it is read is dropped for the same reason a vanished record is: the
# line only ever names records that still claim the copy it describes.
# The internal id-to-key transport puts the id first and treats everything past
# the first tab as the key, so a tab anywhere cannot split a group. It is
# line-based, which holds because an id is a filename basename (no tab, no
# newline) and because fm_worktree_collision_group_key never returns a key
# containing a raw newline (fm_worktree_collision_line_safe escapes one before
# it can reach the key).
# Portable: no associative arrays, so this runs on bash 3.2 (macOS) too.
fm_worktree_collision_lines() {  # <state-dir>
  local state=$1 meta id path pairs dup_keys key ids_for_key recorded shown_path
  local fm_worktree_collision_real
  local proc_state desc claimant_line claimant_count live_count kind path_state caveat
  [ -d "$state" ] || return 0
  pairs=$(
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      path=$(fm_meta_get "$meta" worktree)
      [ -n "$path" ] || continue
      [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
      printf '%s\t%s\n' "$id" "$(fm_worktree_collision_group_key "$path")"
    done
  )
  [ -n "$pairs" ] || return 0
  dup_keys=$(printf '%s\n' "$pairs" | cut -f2- | sort | uniq -d)
  [ -n "$dup_keys" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ids_for_key=$(printf '%s\n' "$pairs" \
      | fm_collision_key="$key" awk 'substr($0, index($0, "\t") + 1) == ENVIRON["fm_collision_key"] { print substr($0, 1, index($0, "\t") - 1) }' \
      | sort)
    live_count=0
    claimant_count=0
    claimant_line=
    shown_path=
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ -f "$state/$id.meta" ] || continue
      recorded=$(fm_meta_get "$state/$id.meta" worktree)
      [ -n "$recorded" ] || continue
      fm_worktree_collision_resolve_path "$recorded"
      [ "$(fm_worktree_collision_key_of_resolved "$recorded" "$fm_worktree_collision_real")" = "$key" ] || continue
      [ -n "$shown_path" ] || shown_path=${fm_worktree_collision_real:-$recorded}
      claimant_count=$((claimant_count + 1))
      proc_state=$(fm_worktree_collision_claimant_process "$state/$id.meta")
      case "$proc_state" in
        dead|missing) ;;
        *) live_count=$((live_count + 1)) ;;
      esac
      desc=$(fm_worktree_collision_claimant_desc "$proc_state" "$(fm_backend_of_meta "$state/$id.meta")")
      claimant_line="${claimant_line:+$claimant_line, }$id ($desc, recorded $recorded)"
    done <<EOM
$ids_for_key
EOM
    [ "$claimant_count" -ge 2 ] || continue
    path_state=$(fm_worktree_collision_path_state "$shown_path")
    caveat=$(fm_worktree_collision_path_caveat "$path_state")
    if [ "$live_count" -ge 2 ]; then
      kind=live
    else
      kind=stale
    fi
    printf 'WORKTREE_COLLISION: %s %s claimed by %s%s\n' "$kind" "$(fm_worktree_collision_line_safe "$shown_path")" "$claimant_line" "$caveat"
  done <<EOM
$dup_keys
EOM
}
