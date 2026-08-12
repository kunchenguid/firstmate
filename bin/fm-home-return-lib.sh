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
# name the secondmate the caller expects, or nothing is touched. What counts as
# a safe home layout is not redefined here - it is
# validate_firstmate_operational_dirs_for_removal below, the one validator both
# the pooled and the non-pooled retirement paths use, including its supported
# shape of an operational directory symlinked to a target inside the home. Such
# a link is staged together with the target it owns, so the returned checkout
# carries neither.
#
# Callers keep their own route and lifecycle bookkeeping: retirement keeps its
# registry and teardown records, seed rollback keeps its own restore-and-report
# behavior. This owns only the cleanup transaction around the return itself.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
SUB_HOME_PARENT_MARKER="${SUB_HOME_PARENT_MARKER:-.fm-secondmate-parent}"

# Refused before the return; nothing on disk changed.
FM_HOME_RETURN_REFUSED=1
# The return itself failed; the home was put back exactly as it was.
FM_HOME_RETURN_FAILED=2
# The return failed AND the staged identity could not be put back.
FM_HOME_RETURN_RESTORE_FAILED=3

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

# Every path inside <home> this retirement owns, one home-relative path per line,
# in the order they must be staged. A supported operational symlink contributes
# both the link and the target it owns, because clearing only the link would
# leave that target on the returned checkout. Nothing outside the home is ever
# listed, and two owned paths may never overlap: an alias that resolves onto
# another owned path is ambiguous about what clearing it would remove, so it is
# refused rather than guessed at.
fm_home_identity_inventory() {  # <abs-home> <label>
  local home=$1 label=$2 name path target rel seen entry
  seen=
  for name in $(fm_home_identity_artifacts); do
    path="$home/$name"
    { [ -e "$path" ] || [ -L "$path" ]; } || continue
    if [ -L "$path" ]; then
      case "$name" in
        "$SUB_HOME_MARKER"|"$SUB_HOME_PARENT_MARKER")
          echo "REFUSED: $label identity file $path is a symlink; retirement cannot prove whose identity it names" >&2
          return 1
          ;;
      esac
      target=$(cd "$path" 2>/dev/null && pwd -P) || {
        echo "REFUSED: $label operational path $path could not be resolved" >&2
        return 1
      }
      if ! path_is_ancestor_of "$home" "$target"; then
        echo "REFUSED: $label operational path $path resolves outside the secondmate home to $target" >&2
        return 1
      fi
      rel=${target#"$home"/}
    else
      rel=$name
    fi
    for entry in $seen; do
      if [ "$entry" = "$rel" ] || [ "$entry" = "$name" ] \
        || path_is_ancestor_of "$entry" "$rel" || path_is_ancestor_of "$rel" "$entry"; then
        echo "REFUSED: $label owns overlapping cleanup targets $entry and $rel; retirement cannot tell them apart" >&2
        return 1
      fi
    done
    seen="$seen $name"
    printf '%s\n' "$name"
    if [ "$rel" != "$name" ]; then
      seen="$seen $rel"
      printf '%s\n' "$rel"
    fi
  done
}

# Move the owned paths aside into a private staging directory, echoing that
# directory (empty when the home owns nothing). Staging is a move, not a copy, so
# what goes back to the pool is a checkout. A move that fails mid-way puts back
# what it already took, so a refusal never leaves a partially cleared home.
fm_home_identity_stage() {  # <abs-home> <label>
  local home=$1 label=$2 staging rel inventory
  inventory=$(fm_home_identity_inventory "$home" "$label") || return 1
  if [ -z "$inventory" ]; then
    printf '\n'
    return 0
  fi
  staging=$(umask 077; mktemp -d "${home%/*}/.fm-home-identity.XXXXXX") || {
    echo "REFUSED: cannot stage the retiring identity of $label $home" >&2
    return 1
  }
  : > "$staging/manifest"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! mkdir -p "$staging/tree/$(dirname "$rel")" \
      || ! mv -f -- "$home/$rel" "$staging/tree/$rel"; then
      echo "REFUSED: cannot stage $home/$rel for $label; recovering from $staging" >&2
      fm_home_identity_restore "$home" "$label" "$staging" || return 1
      return 1
    fi
    printf '%s\n' "$rel" >> "$staging/manifest"
  done <<EOF
$inventory
EOF
  printf '%s\n' "$staging"
}

# Put a staged identity back exactly as it was, link and target and all, so a
# home whose return failed keeps both its identity and its route. Reruns
# converge: an entry already back in place is skipped rather than fought over.
fm_home_identity_restore() {  # <abs-home> <label> <staging>
  local home=$1 label=$2 staging=$3 rel src dst reversed=""
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
  rm -rf -- "$staging"
}

# Return <home> to the pool with its identity cleared, or leave it exactly as it
# was. <return_fn> is called with the resolved home and the label and must
# perform the pool return; each lifecycle keeps its own return mechanics that way
# (teardown its lock-retry return, seed rollback its plain one).
fm_home_return_with_clean_identity() {  # <home> <label> <expected-id> <return_fn>
  local home=$1 label=$2 expected_id=${3:-} return_fn=$4
  local abs_home marker marker_id staging
  abs_home=$(removal_target_abs_path "$home") || {
    echo "REFUSED: $label $home could not be resolved for retirement" >&2
    return "$FM_HOME_RETURN_REFUSED"
  }
  marker="$abs_home/$SUB_HOME_MARKER"
  if [ -L "$marker" ]; then
    echo "REFUSED: $label $abs_home has a symlinked identity marker $marker; retirement cannot prove whose identity it names" >&2
    return "$FM_HOME_RETURN_REFUSED"
  fi
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
      return "$FM_HOME_RETURN_REFUSED"
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home" "$label" || return "$FM_HOME_RETURN_REFUSED"
  staging=$(fm_home_identity_stage "$abs_home" "$label") || return "$FM_HOME_RETURN_REFUSED"
  if "$return_fn" "$abs_home" "$label"; then
    [ -z "$staging" ] || rm -rf -- "$staging"
    return 0
  fi
  fm_home_identity_restore "$abs_home" "$label" "$staging" || return "$FM_HOME_RETURN_RESTORE_FAILED"
  return "$FM_HOME_RETURN_FAILED"
}
