#!/usr/bin/env bash
# fm-treehouse-lib.sh - the single owner of pool-path spelling reconciliation
# between firstmate's recorded worktree paths and treehouse's managed inventory.
#
# Sourced, never executed.
#
# Why this exists: treehouse builds pool paths from its configured root exactly
# as that root is written, and the root defaults to `$HOME` used literally, so
# its inventory holds `/home/you/.treehouse/...`. Firstmate records the fully
# resolved physical path instead, because its liveness and worktree-isolation
# checks must prove one exact directory rather than compare strings that merely
# look equal. On a host whose home is a symlink the two records name a single
# directory yet differ as strings, and treehouse matches its inventory by
# string, so it refuses the physical spelling as "not managed by treehouse".
#
# Both records are right for their own purpose, so this library reconciles the
# spellings where they are used instead of making either side adopt the other's.
# That is the same shape bin/fm-teardown.sh's worktree_registered_for_project
# already uses for git's worktree list: resolve both sides, then compare.
#
# Safety invariant: a candidate spelling is offered only when it provably
# resolves to the same physical directory as the caller's own record, so
# reconciliation can never act on a worktree other than the recorded one.
#
# Not owned here: retry policy, deliberately. bin/fm-teardown.sh iterates the
# spellings itself because it interleaves its git index.lock patience window,
# while simpler callers use fm_treehouse_return_force below. The spelling
# knowledge lives here; each caller's own patience stays where it belongs.
#
# Usage:
#   . "$SCRIPT_DIR/fm-treehouse-lib.sh"
#
#   fm_treehouse_physical_dir <path>
#       Print the physical directory <path> names. Fails when <path> is empty or
#       is not an existing directory.
#
#   fm_treehouse_path_spellings <recorded-path>
#       Print each distinct spelling that provably names the same directory as
#       <recorded-path>, one per line, the recorded spelling first so a host
#       whose spellings already agree keeps exactly its previous single attempt.
#       Fails and prints nothing when <recorded-path> is not an existing
#       directory.
#
#   fm_treehouse_return_force <cd-dir> <recorded-path> [treehouse-bin]
#       Run `treehouse return --force` from <cd-dir> (empty means the current
#       directory), trying each spelling until one is accepted, and print the
#       accepted attempt's output. On total failure returns 1 and reports the
#       first attempt's output, the one describing the caller's own recorded
#       path; an intermediate spelling's refusal is dropped because it describes
#       a path the caller never recorded. [treehouse-bin] defaults to
#       `treehouse` and exists for a caller that must bypass a PATH wrapper,
#       such as a test with an instrumented fake.
set -u

fm_treehouse_physical_dir() { # <path>
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

fm_treehouse_path_spellings() { # <recorded-path>
  local recorded=$1 physical home_physical candidates candidate resolved seen
  [ -n "$recorded" ] || return 1
  physical=$(fm_treehouse_physical_dir "$recorded") || return 1

  # Candidate order is deliberate: the caller's own record first, then the
  # $HOME-rooted rewrite that treehouse's as-written default root produces on a
  # symlinked home, then the fully resolved spelling for a pool whose root is
  # configured physical while the record carries a symlinked prefix.
  candidates=$recorded
  if [ -n "${HOME:-}" ] && home_physical=$(fm_treehouse_physical_dir "$HOME") &&
    [ "$home_physical" != "$HOME" ]; then
    case "$physical" in
      "$home_physical") candidates="$candidates"$'\n'"$HOME" ;;
      "$home_physical"/*) candidates="$candidates"$'\n'"$HOME${physical#"$home_physical"}" ;;
    esac
  fi
  candidates="$candidates"$'\n'"$physical"

  # Newline-delimited rather than an array so a path containing spaces is safe
  # without depending on how a given bash treats an empty array under `set -u`.
  seen=$'\n'
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$seen" in *$'\n'"$candidate"$'\n'*) continue ;; esac
    resolved=$(fm_treehouse_physical_dir "$candidate") || continue
    [ "$resolved" = "$physical" ] || continue
    seen="$seen$candidate"$'\n'
    printf '%s\n' "$candidate"
  done <<EOF
$candidates
EOF
}

fm_treehouse_return_force() { # <cd-dir> <recorded-path> [treehouse-bin]
  local cd_dir=${1:-} recorded=${2:-} bin=${3:-treehouse}
  local spellings spelling out first_out='' first_seen=0

  [ -n "$recorded" ] || return 1
  [ -n "$cd_dir" ] || cd_dir=.
  # A record that does not resolve falls back to itself, so the caller sees
  # exactly the refusal it would have seen without any reconciliation.
  spellings=$(fm_treehouse_path_spellings "$recorded") || spellings=$recorded

  while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    if out=$( ( cd "$cd_dir" && "$bin" return --force "$spelling" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
    if [ "$first_seen" -eq 0 ]; then
      first_out=$out
      first_seen=1
    fi
  done <<EOF
$spellings
EOF

  [ -n "$first_out" ] && printf '%s\n' "$first_out" >&2
  return 1
}
