#!/usr/bin/env bash
# Manage the explicit local stack replayed by bin/fm-update.sh.
#
# Usage:
#   fm-held-improvements.sh init <upstream-base>
#   fm-held-improvements.sh init <upstream-base> <order> <id> <title>
#   fm-held-improvements.sh add <order> <id> <base> <head> <title>
#   fm-held-improvements.sh retire <id> <reason>
#   fm-held-improvements.sh list
#
# init detaches the primary at its current clean HEAD and leaves the default
# branch free to track upstream. If HEAD differs from <upstream-base>, the
# four-argument form captures that complete diff as the first held entry. add
# records one whole improvement as a single binary patch from <base> to <head>;
# order is a three-digit replay position and id is a stable inspectable label.
# retire is the explicit conflict-resolution path and requires a reason. The
# updater also retires an entry automatically when upstream contains its patch
# id or already has its exact resulting content.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  local status=${1:-2}
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit "$status"
}

die() {
  printf 'error: fm-held-improvements: %s\n' "$*" >&2
  exit 1
}

validate_id() {
  case "$1" in
    ''|[._-]*|*[!a-z0-9._-]*)
      die "id must start with a lowercase letter or digit and use only lowercase letters, digits, dots, underscores, or dashes"
      ;;
    *) ;;
  esac
}

validate_order_id() {
  case "$1" in
    [0-9][0-9][0-9]) ;;
    *) die "order must be exactly three digits" ;;
  esac
  validate_id "$2"
}

validate_title() {
  [ -n "$1" ] || die "title must not be empty"
  case "$1" in
    *$'\n'*) die "title must be one line" ;;
  esac
}

cmd_init() {
  local base_ref=$1 order=${2:-} id=${3:-} title=${4:-} config default base head tmp stem
  config=$(held_config_root)
  [ ! -e "$config" ] || die "$config already exists"
  [ -z "$(dirty_status "$FM_ROOT" no)" ] || die "primary checkout must be clean"
  default=$(default_branch "$FM_ROOT") || die "cannot determine the upstream default branch"
  base=$(git -C "$FM_ROOT" rev-parse --verify "$base_ref^{commit}" 2>/dev/null) \
    || die "upstream base '$base_ref' is not a commit"
  [ "$base" = "$(git -C "$FM_ROOT" rev-parse "refs/heads/$default")" ] \
    || die "upstream base must resolve to the pristine local $default ref"
  head=$(git -C "$FM_ROOT" rev-parse HEAD)
  git -C "$FM_ROOT" merge-base --is-ancestor "$base" "$head" \
    || die "current HEAD does not descend from upstream base $base"
  if [ "$head" = "$base" ]; then
    [ -z "$order$id$title" ] || die "capture arguments apply only when HEAD differs from the upstream base"
  else
    [ -n "$order" ] && [ -n "$id" ] && [ -n "$title" ] \
      || die "HEAD differs from the upstream base; provide <order> <id> <title> to capture it"
    validate_order_id "$order" "$id"
    validate_title "$title"
  fi

  mkdir -p "$(dirname "$config")"
  tmp=$(mktemp -d "$(dirname "$config")/.held-improvements.XXXXXX") || exit 1
  mkdir -p "$tmp/active" "$tmp/retired"
  printf '%s\n' "$base" > "$tmp/last-base"
  if [ "$head" != "$base" ]; then
    stem="$order-$id"
    git -C "$FM_ROOT" diff --binary --full-index "$base" "$head" > "$tmp/active/$stem.patch"
    [ -s "$tmp/active/$stem.patch" ] || die "captured improvement has an empty patch"
    printf '%s\n' "$title" > "$tmp/active/$stem.title"
  fi
  # A stack directory without its live ref is a wedged state no command can
  # leave: fm-update.sh fails closed on it while init reports it already exists
  # and every other subcommand reports it uninitialized. So publish all of it or
  # none of it, and roll the directory back rather than merely documenting a way
  # out of the half state.
  mv "$tmp" "$config"
  if ! git -C "$FM_ROOT" update-ref "$HELD_LIVE_REF" "$head" \
    || ! held_register_effective "$FM_ROOT" "$base" \
    || ! held_register_effective "$FM_ROOT" "$head" \
    || ! git -C "$FM_ROOT" checkout --quiet --detach "$head"; then
    git -C "$FM_ROOT" update-ref -d "$HELD_LIVE_REF" >/dev/null 2>&1 || true
    git -C "$FM_ROOT" update-ref -d "$HELD_REF_ROOT/effective/$base" >/dev/null 2>&1 || true
    git -C "$FM_ROOT" update-ref -d "$HELD_REF_ROOT/effective/$head" >/dev/null 2>&1 || true
    rm -rf -- "$config"
    die "could not publish the held-improvement stack at $head; nothing was changed"
  fi
  printf 'initialized: upstream=%s live=%s active=%s\n' \
    "$(printf '%.12s' "$base")" "$(printf '%.12s' "$head")" "${id:-none}"
}

cmd_add() {
  local order=$1 id=$2 base_ref=$3 head_ref=$4 title=$5 config base head stem tmp_patch tmp_title existing
  validate_order_id "$order" "$id"
  validate_title "$title"
  held_stack_active || die "held-improvement stack is not initialized"
  config=$(held_config_root)
  stem="$order-$id"
  [ ! -e "$config/active/$stem.patch" ] && [ ! -e "$config/retired/$stem.patch" ] \
    || die "entry $stem already exists"
  for existing in "$config"/active/"$order"-*.patch "$config"/retired/"$order"-*.patch; do
    [ ! -e "$existing" ] || die "order $order is already in use"
  done
  for existing in "$config"/active/[0-9][0-9][0-9]-"$id".patch \
    "$config"/retired/[0-9][0-9][0-9]-"$id".patch; do
    [ ! -e "$existing" ] || die "id $id is already in use"
  done
  base=$(git -C "$FM_ROOT" rev-parse --verify "$base_ref^{commit}" 2>/dev/null) \
    || die "base '$base_ref' is not a commit"
  head=$(git -C "$FM_ROOT" rev-parse --verify "$head_ref^{commit}" 2>/dev/null) \
    || die "head '$head_ref' is not a commit"
  [ "$base" != "$head" ] || die "base and head are identical"
  git -C "$FM_ROOT" merge-base --is-ancestor "$base" "$head" \
    || die "head does not descend from base"
  tmp_patch=$(mktemp "$config/.add-patch.XXXXXX") || exit 1
  tmp_title=$(mktemp "$config/.add-title.XXXXXX") || exit 1
  git -C "$FM_ROOT" diff --binary --full-index "$base" "$head" > "$tmp_patch"
  [ -s "$tmp_patch" ] || die "improvement patch is empty"
  printf '%s\n' "$title" > "$tmp_title"
  mv "$tmp_patch" "$config/active/$stem.patch"
  mv "$tmp_title" "$config/active/$stem.title"
  printf 'added: %s %s\n' "$id" "$title"
}

cmd_retire() {
  local id=$1 reason=$2 config patch found= stem matches=0
  validate_title "$reason"
  validate_id "$id"
  held_stack_active || die "held-improvement stack is not initialized"
  config=$(held_config_root)
  # Anchored on the three-digit order prefix so an id that is a dash-suffix of
  # another entry's id cannot select it. The conflict-recovery path must retire
  # the entry the operator named and no other.
  for patch in "$config"/active/[0-9][0-9][0-9]-"$id".patch; do
    [ -f "$patch" ] || continue
    found=$patch
    matches=$((matches + 1))
  done
  [ "$matches" -eq 1 ] || die "active id '$id' matched $matches entries"
  patch=$found
  stem=$(basename "$patch" .patch)
  mv "$patch" "$config/retired/$stem.patch"
  mv "$config/active/$stem.title" "$config/retired/$stem.title"
  held_write_file "$config/retired/$stem.reason" "$reason"
  printf 'retired: %s %s\n' "$id" "$reason"
}

list_dir() {
  local state=$1 dir=$2 patch stem order id title
  for patch in "$dir"/*.patch; do
    [ -f "$patch" ] || continue
    stem=$(basename "$patch" .patch)
    order=${stem%%-*}
    id=${stem#*-}
    title=$(held_entry_title "$patch" 2>/dev/null || printf '<missing title>\n')
    printf '%s %s %s %s\n' "$state" "$order" "$id" "$title"
  done
}

cmd_list() {
  local config
  held_stack_active || die "held-improvement stack is not initialized"
  config=$(held_config_root)
  list_dir active "$config/active"
  list_dir retired "$config/retired"
}

case "${1:-}" in
  init)
    shift
    case "$#" in 1|4) cmd_init "$@" ;; *) usage ;; esac
    ;;
  add) shift; [ "$#" -eq 5 ] || usage; cmd_add "$@" ;;
  retire) shift; [ "$#" -eq 2 ] || usage; cmd_retire "$@" ;;
  list) shift; [ "$#" -eq 0 ] || usage; cmd_list ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
