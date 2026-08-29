# shellcheck shell=bash
# Shared owner of "hand a leased firstmate home back to the treehouse pool
# without leaving that home's identity on the slot".
# Usage: . bin/fm-home-return-lib.sh   (after FM_HOME and FM_ROOT are set)
#
# A pooled home keeps its directory across `treehouse return`, and every artifact
# that makes it a home rather than a checkout is gitignored, so the pool's own
# clean-and-reset leaves all of it in place (confirmed against treehouse v2.1.1;
# see docs/verification/runtime-backends.md) and the next task is handed a
# worktree still wearing a retired secondmate's identity, which the spawn-time
# isolation guard then refuses. Two lifecycle paths return a leased home:
# retirement (remove_firstmate_home in bin/fm-teardown.sh) and failed-seed
# rollback (seed_return_treehouse_home in bin/fm-home-seed.sh). Both call
# fm_home_return_with_clean_identity, so neither can hand a marked checkout back.
#
# The transaction is the same shape the process-event state beside it uses: the
# owned artifacts are staged aside, the checkout is returned, and the staging is
# deleted only once that return succeeded. A failed return puts everything back
# before the failure is reported, so a home is never left half cleared while its
# route is still registered. A restore that cannot complete says where the
# staging is, and a rerun converges on it rather than compounding.
#
# Ownership, never resemblance: the identity marker must be present and must
# name the secondmate the caller expects, or nothing is touched. Proven foreign
# ownership answers with an outcome of its own, FM_HOME_RETURN_NOT_OWNED, kept
# distinct from every other refusal because it is the only one that leaves none
# of the caller's own identity on the home, and so the only one on which a
# pooled lease may be handed back. What counts as a safe home layout is not
# redefined here - it is validate_firstmate_operational_dirs_for_removal below,
# the one validator both the pooled and the non-pooled retirement paths use,
# including its supported shape of an operational directory symlinked to a
# target inside the home. Such a link is staged together with the target it
# owns, so the returned checkout carries neither.
#
# Callers keep their own route and lifecycle bookkeeping: retirement keeps its
# registry and teardown records, seed rollback keeps its own restore-and-report
# behavior. This owns only the cleanup transaction around the return itself.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
SUB_HOME_PARENT_MARKER="${SUB_HOME_PARENT_MARKER:-.fm-secondmate-parent}"

# Refused before anything moved; nothing on disk changed. The home may still be
# wearing the identity THIS caller wrote, so a pooled lease must not be released
# on this outcome: handing that slot back marked is what the spawn-time isolation
# guard then refuses every task dispatched into it.
FM_HOME_RETURN_REFUSED=1
# The return itself failed; the home was put back exactly as it was.
FM_HOME_RETURN_FAILED=2
# The staged identity could not be put back; the staging directory named in the
# diagnostic holds it and the lease must not be released.
FM_HOME_RETURN_RESTORE_FAILED=3
# Staging could not finish, and what it had already moved was put back. The home
# is intact but its identity was never cleared, so the lease must not be
# released as though it had been.
FM_HOME_RETURN_STAGE_FAILED=4
# Proven foreign ownership, and only that: the identity marker is present and
# names a DIFFERENT secondmate, so nothing on this home was written by the caller
# and nothing was touched. This is the one outcome that carries no identity of
# the caller's own, and therefore the only refusal on which a pooled lease may be
# released - every other one leaves this run's marker on the slot.
FM_HOME_RETURN_NOT_OWNED=5
# Where fm_home_return_with_clean_identity staged this home's identity, so a
# caller reporting a failure can name it alongside its own staging.
# shellcheck disable=SC2034 # Output global read by sourcing callers (bin/fm-teardown.sh).
FM_HOME_RETURN_STAGING=""

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

# The canonical removable-home layout contract, and the only definition of it:
# data/, state/, config/ and projects/ may be plain directories or symlinks, and
# a symlink is supported exactly when its target resolves INSIDE the home. Both
# the pooled and the non-pooled retirement paths ask this one function, so they
# cannot disagree about which homes are retirable.
validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

# Everything a seeded secondmate home owns that makes it a home rather than a
# reusable checkout: the identity markers bin/fm-home-seed.sh writes and the
# operational directories it creates.
fm_home_identity_artifacts() {
  printf '%s\n' "$SUB_HOME_MARKER" "$SUB_HOME_PARENT_MARKER" data state config projects
}

# The physically resolved target of a symlink, following its chain without
# guessing: a directory target resolves through `cd -P`, a file target through
# its own parent directory, and a chain that will not terminate within a bounded
# number of hops is an ambiguous resolution reported as failure rather than
# followed further.
fm_home_resolved_link_target() {  # <link-path>
  local path=$1 hops=0 link dir
  while [ -L "$path" ]; do
    hops=$(( hops + 1 ))
    [ "$hops" -le 32 ] || return 1
    link=$(readlink "$path") || return 1
    case "$link" in
      /*) path=$link ;;
      *) path="$(dirname "$path")/$link" ;;
    esac
  done
  if [ -d "$path" ]; then
    ( cd "$path" 2>/dev/null && pwd -P ) || return 1
    return 0
  fi
  [ -e "$path" ] || return 1
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# Every path inside <home> this retirement owns, one home-relative path per line,
# which is the format fm_home_identity_stage and fm_home_identity_restore consume.
# The rule is exactly what removing the home directory outright would have taken,
# so a pooled home and a standalone one answer the same question the same way: a
# link entry itself always counts, and a resolved target counts too whenever it
# lives inside the home, since removing the home would have taken that target
# with it. That holds for an identity file's target as much as an operational
# directory's; a target outside the home is never followed, which is also what
# removing the home would have done to it.
# A symlinked operational directory is therefore staged THROUGH its resolved
# target rather than refused, which is the layout
# validate_firstmate_operational_dirs_for_removal already approves. Such a target
# that escapes the home, dangles, resolves nowhere, or is the home itself is
# refused by that same validator before this runs, and refused again here because
# an unresolvable target cannot be staged. Targets that nest inside another owned
# path are folded into it rather than staged twice, so an internal layout is
# never rejected merely for being spelled as a link.
fm_home_identity_inventory() {  # <abs-home> <label>
  local home=$1 label=$2 name path target rel owned="" printed="" entry keep identity
  local nl='
'
  printed="$nl"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path="$home/$name"
    { [ -e "$path" ] || [ -L "$path" ]; } || continue
    owned="$owned$name$nl"
    [ -L "$path" ] || continue
    identity=0
    case "$name" in
      "$SUB_HOME_MARKER"|"$SUB_HOME_PARENT_MARKER") identity=1 ;;
    esac
    if ! target=$(fm_home_resolved_link_target "$path"); then
      [ "$identity" -eq 0 ] || continue
      echo "REFUSED: $label operational path $path could not be resolved, so retirement cannot tell what clearing it would remove" >&2
      return 1
    fi
    if [ "$target" = "$home" ] || ! path_is_ancestor_of "$home" "$target"; then
      [ "$identity" -eq 0 ] || continue
      echo "REFUSED: $label operational path $path resolves to $target, which is not inside the secondmate home" >&2
      return 1
    fi
    owned="$owned${target#"$home"/}$nl"
  done <<EOF
$(fm_home_identity_artifacts)
EOF
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    keep=1
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      [ "$entry" != "$rel" ] || continue
      if path_is_ancestor_of "$entry" "$rel"; then
        keep=0
        break
      fi
    done <<EOF
$owned
EOF
    [ "$keep" -eq 1 ] || continue
    case "$printed" in
      *"$nl$rel$nl"*) continue ;;
    esac
    printed="$printed$rel$nl"
    printf '%s\n' "$rel"
  done <<EOF
$owned
EOF
}

# Move the owned paths aside into a private staging directory, echoing that
# directory (empty when the home owns nothing). Staging is a move, not a copy, so
# what goes back to the pool is a checkout.
# Returns FM_HOME_RETURN_REFUSED only while nothing has moved. Once a move has
# happened the answer is never "nothing changed": a failure mid-inventory puts
# back what it already took and reports FM_HOME_RETURN_STAGE_FAILED, or
# FM_HOME_RETURN_RESTORE_FAILED when that recovery itself could not finish, and
# both name the staging directory and the artifact that stopped it.
# Each path is written to the manifest BEFORE it moves, and a manifest write that
# fails stops the staging then and there, so the manifest can name a path that
# never moved but can never miss one that did. Restore tolerates the first and
# would silently lose the second.
fm_home_identity_stage() {  # <abs-home> <label>
  local home=$1 label=$2 staging rel inventory moved=0
  inventory=$(fm_home_identity_inventory "$home" "$label") || return "$FM_HOME_RETURN_REFUSED"
  if [ -z "$inventory" ]; then
    printf '\n'
    return 0
  fi
  staging=$(umask 077; mktemp -d "${home%/*}/.fm-home-identity.XXXXXX") || {
    echo "REFUSED: cannot stage the retiring identity of $label $home" >&2
    return "$FM_HOME_RETURN_REFUSED"
  }
  if ! : > "$staging/manifest"; then
    echo "REFUSED: cannot record what retiring $label $home would stage into $staging; nothing was moved" >&2
    rm -rf -- "$staging"
    return "$FM_HOME_RETURN_REFUSED"
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! printf '%s\n' "$rel" >> "$staging/manifest"; then
      if [ "$moved" -eq 0 ]; then
        echo "REFUSED: cannot record $home/$rel in $staging/manifest for $label; nothing was moved" >&2
        rm -rf -- "$staging"
        return "$FM_HOME_RETURN_REFUSED"
      fi
      echo "error: cannot record $home/$rel in $staging/manifest for $label after already moving $moved of its owned paths aside; recovering them from $staging" >&2
      fm_home_identity_restore "$home" "$label" "$staging" || return "$FM_HOME_RETURN_RESTORE_FAILED"
      return "$FM_HOME_RETURN_STAGE_FAILED"
    fi
    if ! mkdir -p "$staging/tree/$(dirname "$rel")" \
      || ! mv -f -- "$home/$rel" "$staging/tree/$rel"; then
      if [ "$moved" -eq 0 ]; then
        echo "REFUSED: cannot stage $home/$rel for $label; nothing was moved and $staging is empty" >&2
        rm -rf -- "$staging"
        return "$FM_HOME_RETURN_REFUSED"
      fi
      echo "error: cannot stage $home/$rel for $label after already moving $moved of its owned paths aside; recovering them from $staging" >&2
      fm_home_identity_restore "$home" "$label" "$staging" || return "$FM_HOME_RETURN_RESTORE_FAILED"
      return "$FM_HOME_RETURN_STAGE_FAILED"
    fi
    moved=$(( moved + 1 ))
  done <<EOF
$inventory
EOF
  printf '%s\n' "$staging"
}

# Staged content the manifest cannot account for, one staging-relative path per
# line. Everything the manifest names has already been moved back by the time
# this runs, so what remains is either a directory the staging created to hold a
# nested entry or content nobody recorded, and only the second kind is reported.
fm_home_identity_unaccounted_staging() {  # <staging>
  local staging=$1 found rel entry accounted
  [ -d "$staging/tree" ] || return 0
  while IFS= read -r found; do
    rel=${found#./}
    [ -n "$rel" ] && [ "$rel" != "." ] || continue
    accounted=0
    if [ -d "$staging/tree/$rel" ] && [ ! -L "$staging/tree/$rel" ] && [ -f "$staging/manifest" ]; then
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if path_is_ancestor_of "$rel" "$entry"; then
          accounted=1
          break
        fi
      done < "$staging/manifest"
    fi
    [ "$accounted" -eq 0 ] || continue
    printf '%s\n' "$rel"
  done <<EOF
$(cd "$staging/tree" 2>/dev/null && find . -mindepth 1)
EOF
}

# Put a staged identity back exactly as it was, link and target and all, so a
# home whose return failed keeps both its identity and its route. Rerunning this
# over the same staging converges: an entry already back in place is skipped
# rather than fought over.
# The manifest is never the sole authority on what the staging holds. Once every
# entry it names is back, the staging tree is reconciled against it, and content
# nobody recorded means the staging is KEPT and the failure reported: deleting it
# would destroy the only copy of something this transaction moved.
fm_home_identity_restore() {  # <abs-home> <label> <staging>
  local home=$1 label=$2 staging=$3 rel src dst reversed="" unaccounted
  [ -n "$staging" ] || return 0
  [ -d "$staging" ] && [ ! -L "$staging" ] || {
    echo "error: identity restoration failed for $label $home; recovery staging is unavailable at $staging" >&2
    return 1
  }
  # Staging order nests outer paths before inner ones, so restore unwinds it.
  if [ -f "$staging/manifest" ]; then
    reversed=$(awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' "$staging/manifest")
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    src="$staging/tree/$rel"
    dst="$home/$rel"
    { [ -e "$src" ] || [ -L "$src" ]; } || continue
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      echo "error: identity restoration failed for $label $home; $dst reappeared during retirement, recover it from $staging" >&2
      return 1
    fi
    if ! mkdir -p "$(dirname "$dst")" || ! mv -f -- "$src" "$dst"; then
      echo "error: identity restoration failed for $label $home; recover its identity from $staging" >&2
      return 1
    fi
  done <<EOF
$reversed
EOF
  unaccounted=$(fm_home_identity_unaccounted_staging "$staging")
  if [ -n "$unaccounted" ]; then
    echo "error: identity restoration for $label $home put back everything its manifest names, but $staging/tree still holds content that manifest does not account for: $(printf '%s' "$unaccounted" | tr '\n' ' '); the staging is kept, and that content has to be placed by hand before the home is whole" >&2
    return 1
  fi
  rm -rf -- "$staging"
}

# Return <home> to the pool with its identity cleared, or leave it exactly as it
# was. <return_fn> is called with the resolved home and the label and must
# perform the pool return; each lifecycle keeps its own return mechanics that way
# (teardown its lock-retry return, seed rollback its plain one).
# shellcheck disable=SC2034 # FM_HOME_RETURN_STAGING is an output global read by sourcing callers (bin/fm-teardown.sh).
fm_home_return_with_clean_identity() {  # <home> <label> <expected-id> <return_fn>
  local home=$1 label=$2 expected_id=${3:-} return_fn=$4
  local abs_home marker marker_id staging
  FM_HOME_RETURN_STAGING=""
  abs_home=$(removal_target_abs_path "$home") || {
    echo "REFUSED: $label $home could not be resolved for retirement" >&2
    return "$FM_HOME_RETURN_REFUSED"
  }
  marker="$abs_home/$SUB_HOME_MARKER"
  # Read exactly as the standalone removal gate reads it: `-f` follows a link to
  # a regular file, so a home is seeded here whenever it is seeded there.
  if [ ! -f "$marker" ]; then
    # Not a seeded home, so this fleet owns nothing on it to clear. Resemblance
    # is not ownership: the checkout goes back untouched.
    "$return_fn" "$abs_home" "$label" || return "$FM_HOME_RETURN_FAILED"
    return 0
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$marker" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: $label $abs_home is marked for secondmate ${marker_id:-unknown}, expected $expected_id; its identity is not this retirement's to clear" >&2
      return "$FM_HOME_RETURN_NOT_OWNED"
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home" "$label" || return "$FM_HOME_RETURN_REFUSED"
  staging=$(fm_home_identity_stage "$abs_home" "$label") || return $?
  FM_HOME_RETURN_STAGING="$staging"
  if "$return_fn" "$abs_home" "$label"; then
    [ -z "$staging" ] || rm -rf -- "$staging"
    return 0
  fi
  fm_home_identity_restore "$abs_home" "$label" "$staging" || return "$FM_HOME_RETURN_RESTORE_FAILED"
  return "$FM_HOME_RETURN_FAILED"
}
