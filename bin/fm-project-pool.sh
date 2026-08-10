#!/usr/bin/env bash
# fm-project-pool.sh - give each firstmate home its own treehouse worktree pool.
#
# THE BUG THIS CLOSES
# treehouse keys its pool by ($HOME, origin remote URL): the pool for a repo
# lives at $HOME/.treehouse/<clone-basename>-<sha256(origin-url)[:6]>. That key
# has no home dimension. The primary home and every secondmate home keep their
# OWN clone of the same repo, all those clones share one origin URL, so on one
# machine they all resolve to ONE pool.
#
# Each pool slot is a `git worktree add` from whichever clone happened to be the
# cwd when that slot was first created, and it stays bound to that clone for the
# rest of its life. So a home that asks for a worktree can be handed a slot that
# is a linked worktree of ANOTHER home's clone. Verified in a scratch pool on
# treehouse v2.1.0 (2026-08-11, Linux): home B ran `treehouse get` from its own
# clone and received /…/proj-dbc838/1/proj whose .git read
# "gitdir: <home A's clone>/.git/worktrees/proj".
#
# bin/fm-spawn.sh's spawn_worktree_isolated compares physical git common dirs and
# refuses to launch on such a worktree, which is what caught this - without the
# refusal that home's crewmate would have created branches and commits inside
# another home's clone. That refusal is the correct last line of defence, but it
# can only reject: the work stays undispatchable. This script removes the shared
# resource instead, the same shape as the per-home tmux session name.
#
# THE LEVER
# A `treehouse.toml` at a repo root supports `root = "<absolute path>"`, and
# treehouse then places its pool at {root}/.treehouse/ instead of $HOME.
# Measured on v2.1.0, all three facts, because two nearby levers do NOT work:
#   - TREEHOUSE_DIR in the environment does not relocate the pool.
#   - The config is NOT discovered by walking up parent directories; it must sit
#     at the clone root itself.
#   - `treehouse get` has no flag that selects a pool or a source repo.
# So writing this one file into each clone is the only available lever.
#
# WHY THIS IS A SANCTIONED WRITE UNDER projects/
# AGENTS.md section 1 forbids firstmate writing under projects/. This script is
# a narrow, named exception in that list: it writes exactly one file,
# <clone>/treehouse.toml, plus one line in <clone>/.git/info/exclude, and nothing
# else. It refuses rather than clobbers when a project owns a treehouse.toml of
# its own, and it never touches tracked content, never commits, and never runs a
# treehouse pool operation (no get, no return, no prune, no destroy).
#
# WHY .git/info/exclude
# treehouse.toml is untracked inside the clone, so a crewmate running `git add -A`
# could commit firstmate's private pool layout into the project. info/exclude is
# a local, uncommitted ignore file that lives in the git COMMON dir, so the one
# entry covers the clone and every linked worktree cut from it.
#
# WHY FM_HOME IS THE DISCRIMINATOR
# The tag comes from bin/fm-backend-hometag-lib.sh, the same derivation the tmux
# and cmux/zellij adapters use, so the fleet has one home-naming scheme rather
# than two. The discriminating path here is FM_HOME, not FM_ROOT: what must not
# collide is one home's SET OF PROJECT CLONES, and those live at
# <FM_HOME>/projects/. That is the tmux adapter's form, not the zellij/cmux one.
#
# WHAT THIS DOES NOT COVER
# Secondmate HOMES are themselves leased pool worktrees, acquired by
# bin/fm-home-seed.sh with `treehouse get --lease` run from $FM_ROOT. This script
# is not applied to $FM_ROOT, so home leasing keeps using the default $HOME pool
# and every live lease keeps working untouched. The residual is that two
# independent PRIMARY installations on one machine would still lease homes from
# one pool; that is a different resource with live leases riding on it, and
# moving it is deliberately not bundled into this change.
#
# Usage:
#   fm-project-pool.sh apply <project-clone> [--home <home>]
#       Write/refresh the home-scoped pool config for ONE project clone. The
#       owning home defaults to <project-clone>/../.. . Idempotent. This is the
#       chokepoint: every path that creates a project clone calls it.
#   fm-project-pool.sh root [--home <home>]
#       Print the pool root a home uses. Diagnostics and tests.
#   fm-project-pool.sh check [--home <home>] [--all]
#       Detect only. Print one "PROJECT_POOL: <detail>" line per clone that still
#       shares a pool, or has a config firstmate must not touch. Silent = all
#       good. Always exits 0; it changes nothing.
#   fm-project-pool.sh backfill [--home <home>] [--all] [--dry-run]
#       Apply to every project clone of the home. --all extends to every
#       secondmate home registered on THIS machine in data/secondmates.md.
#       It never prunes, destroys, or returns a worktree, and it reports the
#       worktrees left behind in the old shared pool instead of moving them.
#
# --home defaults to $FM_HOME. --all reads <home>/data/secondmates.md and skips
# entries carrying "machine: <host>", which name a home on another machine.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$SCRIPT_DIR/fm-backend-hometag-lib.sh"

# The ownership marker. Its presence in a treehouse.toml is what makes a rewrite
# safe; its absence means the file belongs to somebody else and is not ours to
# touch.
POOL_CONFIG_NAME="treehouse.toml"
POOL_CONFIG_MARKER="# Managed by firstmate: bin/fm-project-pool.sh"
# Anchored, so it ignores only the repo-root file firstmate writes and never a
# same-named file somewhere deeper in the project.
POOL_EXCLUDE_LINE="/$POOL_CONFIG_NAME"
POOL_HOMES_DIRNAME=".treehouse-homes"

usage() {
  echo "usage: fm-project-pool.sh apply <project-clone> [--home <home>]" >&2
  echo "       fm-project-pool.sh root [--home <home>]" >&2
  echo "       fm-project-pool.sh check [--home <home>] [--all]" >&2
  echo "       fm-project-pool.sh backfill [--home <home>] [--all] [--dry-run]" >&2
}

abs_dir() {  # <path> -> physical path, or non-zero when it is not a directory
  ( cd "$1" 2>/dev/null && pwd -P )
}

# pool_root_for_home <home>: the directory treehouse must use as its `root` for
# every project clone this home owns. Physical, so the paths treehouse records
# are already in the canonical form firstmate stores everywhere else and
# bin/fm-treehouse-lib.sh's spelling translation has nothing left to translate.
pool_root_for_home() {  # <home>
  local home=$1 home_real base tag
  home_real=$(abs_dir "$home") || {
    echo "error: home $home is not a directory" >&2
    return 1
  }
  [ -n "${HOME:-}" ] || { echo "error: HOME is unset; cannot place a pool root" >&2; return 1; }
  base=$(abs_dir "$HOME") || {
    echo "error: HOME $HOME is not a directory" >&2
    return 1
  }
  tag=$(fm_backend_hometag_for "$home_real" "$home_real")
  printf '%s/%s/%s\n' "$base" "$POOL_HOMES_DIRNAME" "$tag"
}

# home_of_clone <clone>: the firstmate home that owns a clone, which is
# structurally <clone>/../.. because project clones live at <home>/projects/<name>.
# Deriving it beats trusting a caller-supplied value: the config must match the
# home whose projects/ directory actually contains this clone, and a caller that
# passes the wrong home writes a config that silently re-shares the pool.
home_of_clone() {  # <clone>
  local clone=$1 home
  home=$(abs_dir "$clone/../..") || return 1
  printf '%s\n' "$home"
}

# clone_is_main_worktree <clone>: true only for the root of a repository's own
# main working tree. A linked worktree (a pool slot, a secondmate home) shares
# another directory's git common dir and must never be given a pool config: its
# pool is decided by the clone it was cut from.
clone_is_main_worktree() {  # <clone>
  local clone=$1 top common
  top=$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(abs_dir "$top")" = "$(abs_dir "$clone")" ] || return 1
  common=$(git -C "$clone" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$(abs_dir "$common")" = "$(abs_dir "$clone")/.git" ]
}

# config_state <clone> <want-root>: one word describing what apply would have to
# do, printed to stdout.
#   ok       - our config, already naming <want-root>
#   absent   - no treehouse.toml at all
#   stale    - our config, naming some other root
#   tracked  - the project commits its own treehouse.toml; firstmate must not touch it
#   foreign  - an untracked treehouse.toml that firstmate did not write
config_state() {  # <clone> <want-root>
  local clone=$1 want=$2 cfg="$1/$POOL_CONFIG_NAME" have
  if git -C "$clone" ls-files --error-unmatch "$POOL_CONFIG_NAME" >/dev/null 2>&1; then
    echo tracked
    return 0
  fi
  if [ ! -f "$cfg" ]; then
    echo absent
    return 0
  fi
  if ! grep -qxF "$POOL_CONFIG_MARKER" "$cfg" 2>/dev/null; then
    echo foreign
    return 0
  fi
  have=$(sed -n 's/^root[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$cfg" | head -1)
  if [ "$have" = "$want" ]; then
    echo ok
  else
    echo stale
  fi
}

write_pool_config() {  # <clone> <root>
  local clone=$1 root=$2 cfg="$1/$POOL_CONFIG_NAME" tmp
  tmp=$(mktemp "$clone/.fm-project-pool.XXXXXX") || return 1
  cat >"$tmp" <<EOF
$POOL_CONFIG_MARKER
# Home-scoped treehouse worktree pool for the firstmate home that owns this
# clone. Without it this clone shares one \$HOME-keyed pool with every other
# home holding the same repo, and a pool slot created by one home can be handed
# to another - a worktree of somebody else's clone. Not committed; regenerate
# with: bin/fm-project-pool.sh apply <this directory>
root = "$root"
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$cfg"
}

add_pool_exclude() {  # <clone>
  local clone=$1 excl
  excl=$(git -C "$clone" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null) || return 1
  [ -n "$excl" ] || return 1
  mkdir -p "$(dirname "$excl")"
  grep -qxF "$POOL_EXCLUDE_LINE" "$excl" 2>/dev/null || printf '%s\n' "$POOL_EXCLUDE_LINE" >>"$excl"
}

# apply_one <clone> [<home>]: the chokepoint. Every project-clone creation path
# calls exactly this. Idempotent, and loud rather than clever on anything it must
# not overwrite.
apply_one() {  # <clone> [<home>]
  local clone=$1 home=${2:-} clone_real root state
  clone_real=$(abs_dir "$clone") || {
    echo "error: project clone $clone is not a directory" >&2
    return 1
  }
  git -C "$clone_real" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "error: project clone $clone_real is not a git repository" >&2
    return 1
  }
  clone_is_main_worktree "$clone_real" || {
    echo "error: $clone_real is a linked worktree, not a project clone; its pool is decided by the clone it was cut from" >&2
    return 1
  }
  if [ -z "$home" ]; then
    home=$(home_of_clone "$clone_real") || {
      echo "error: cannot resolve the firstmate home that owns $clone_real" >&2
      return 1
    }
  fi
  root=$(pool_root_for_home "$home") || return 1
  state=$(config_state "$clone_real" "$root")
  case "$state" in
    ok)
      add_pool_exclude "$clone_real" || {
        echo "error: could not record $POOL_EXCLUDE_LINE in $clone_real's git exclude file" >&2
        return 1
      }
      return 0
      ;;
    tracked)
      echo "error: $clone_real commits its own $POOL_CONFIG_NAME; refusing to overwrite tracked project content. Give this project a pool root by hand, or exclude it from firstmate's pool isolation." >&2
      return 1
      ;;
    foreign)
      echo "error: $clone_real already has a $POOL_CONFIG_NAME that firstmate did not write; refusing to overwrite it. Inspect it, then remove or merge it before re-running." >&2
      return 1
      ;;
    absent|stale)
      write_pool_config "$clone_real" "$root" || {
        echo "error: could not write $clone_real/$POOL_CONFIG_NAME" >&2
        return 1
      }
      add_pool_exclude "$clone_real" || {
        echo "error: could not record $POOL_EXCLUDE_LINE in $clone_real's git exclude file" >&2
        return 1
      }
      return 0
      ;;
  esac
}

# clones_of_home <home>: every immediate child of <home>/projects that is the
# main working tree of a git repository. Anything else there is not a project
# clone and is left alone.
clones_of_home() {  # <home>
  local home=$1 dir
  [ -d "$home/projects" ] || return 0
  for dir in "$home"/projects/*; do
    [ -d "$dir" ] || continue
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    clone_is_main_worktree "$dir" || continue
    printf '%s\n' "$dir"
  done
}

# local_secondmate_homes <home>: absolute home paths from data/secondmates.md,
# excluding entries with a "machine:" field - those homes live on another fleet
# machine and are that machine's own firstmate's job.
local_secondmate_homes() {  # <home>
  local home=$1 reg="$1/data/secondmates.md" line path machine
  [ -f "$reg" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "- "*"(home: "*) ;;
      *) continue ;;
    esac
    machine=$(printf '%s\n' "$line" | sed -n 's/.*;[[:space:]]*machine:[[:space:]]*\([^;)]*\);.*/\1/p')
    [ -z "$machine" ] || continue
    path=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p')
    [ -n "$path" ] || continue
    printf '%s\n' "$path"
  done <"$reg"
}

# homes_to_sweep <home> <all>: the home itself, plus its locally registered
# secondmate homes when <all> is 1.
homes_to_sweep() {  # <home> <all>
  local home=$1 all=$2 sub sub_real
  printf '%s\n' "$home"
  [ "$all" = 1 ] || return 0
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    sub_real=$(abs_dir "$sub") || continue
    [ "$sub_real" != "$home" ] || continue
    printf '%s\n' "$sub_real"
  done <<EOF
$(local_secondmate_homes "$home")
EOF
}

cmd_check() {  # <home> <all>
  local home=$1 all=$2 h clone root state
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    root=$(pool_root_for_home "$h") || continue
    while IFS= read -r clone; do
      [ -n "$clone" ] || continue
      state=$(config_state "$clone" "$root")
      case "$state" in
        ok) ;;
        absent)
          echo "PROJECT_POOL: $clone has no home-scoped worktree pool config, so it shares one worktree pool with every other home holding this repo and can be handed a worktree of another home's clone (repair: bin/fm-project-pool.sh apply $clone)"
          ;;
        stale)
          echo "PROJECT_POOL: $clone names a worktree pool root that is not this home's (repair: bin/fm-project-pool.sh apply $clone)"
          ;;
        tracked)
          echo "PROJECT_POOL: $clone commits its own $POOL_CONFIG_NAME, so firstmate will not manage its worktree pool; it still shares a pool with any other home holding this repo"
          ;;
        foreign)
          echo "PROJECT_POOL: $clone has a $POOL_CONFIG_NAME firstmate did not write; inspect it before running bin/fm-project-pool.sh apply $clone"
          ;;
      esac
    done <<EOF
$(clones_of_home "$h")
EOF
  done <<EOF
$(homes_to_sweep "$home" "$all")
EOF
}

# report_legacy_worktrees <clone> <root>: name the worktrees this clone still has
# outside its new pool root. They are the slots the old shared pool already
# created, they stay exactly where they are, and `treehouse return <path>`
# still releases them after the repoint (measured on v2.1.0: a lease taken from
# the shared pool was released cleanly, and --if-lease-holder still read that
# pool's own lease record, from a clone whose config pointed elsewhere). This
# only reports; deciding what to do with a live worktree is firstmate's call.
report_legacy_worktrees() {  # <clone> <root>
  local clone=$1 root=$2 line path n=0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path=${line#worktree } ;;
      *) continue ;;
    esac
    [ "$(abs_dir "$path" || echo "$path")" != "$(abs_dir "$clone")" ] || continue
    case "$path" in
      "$root"/*) continue ;;
    esac
    n=$((n + 1))
    echo "  legacy worktree still checked out from the old shared pool, left untouched: $path"
  done <<EOF
$(git -C "$clone" worktree list --porcelain 2>/dev/null)
EOF
  [ "$n" = 0 ] || echo "  ^ $n worktree(s) above stay where they are and stay returnable; nothing was pruned, destroyed, or returned."
}

cmd_backfill() {  # <home> <all> <dry-run>
  local home=$1 all=$2 dry=$3 h clone root state rc=0 changed=0 skipped=0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    root=$(pool_root_for_home "$h") || { rc=1; continue; }
    echo "home $h -> pool root $root"
    while IFS= read -r clone; do
      [ -n "$clone" ] || continue
      state=$(config_state "$clone" "$root")
      case "$state" in
        ok)
          echo "  ok       $clone"
          if [ "$dry" != 1 ]; then
            apply_one "$clone" "$h" || rc=1
          fi
          ;;
        absent|stale)
          if [ "$dry" = 1 ]; then
            echo "  would    $clone ($state)"
          elif apply_one "$clone" "$h"; then
            echo "  applied  $clone ($state)"
            changed=$((changed + 1))
            report_legacy_worktrees "$clone" "$root"
          else
            rc=1
          fi
          ;;
        tracked|foreign)
          echo "  SKIPPED  $clone ($state): firstmate will not overwrite this $POOL_CONFIG_NAME"
          skipped=$((skipped + 1))
          ;;
      esac
    done <<EOF
$(clones_of_home "$h")
EOF
  done <<EOF
$(homes_to_sweep "$home" "$all")
EOF
  echo "backfill: $changed clone(s) given a home-scoped pool, $skipped skipped"
  return "$rc"
}

CMD=${1:-}
[ -n "$CMD" ] || { usage; exit 2; }
shift || true

HOME_ARG=""
ALL=0
DRY=0
TARGET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) HOME_ARG=${2:?--home needs a path}; shift 2 ;;
    --all) ALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; usage; exit 2 ;;
    *)
      [ -z "$TARGET" ] || { echo "error: unexpected argument $1" >&2; usage; exit 2; }
      TARGET=$1; shift
      ;;
  esac
done

HOME_DIR=${HOME_ARG:-$FM_HOME}

case "$CMD" in
  apply)
    [ -n "$TARGET" ] || { usage; exit 2; }
    apply_one "$TARGET" "$HOME_ARG"
    ;;
  root)
    pool_root_for_home "$HOME_DIR"
    ;;
  check)
    cmd_check "$(abs_dir "$HOME_DIR")" "$ALL"
    ;;
  backfill)
    cmd_backfill "$(abs_dir "$HOME_DIR")" "$ALL" "$DRY"
    ;;
  *)
    usage
    exit 2
    ;;
esac
