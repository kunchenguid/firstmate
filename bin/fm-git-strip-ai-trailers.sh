#!/usr/bin/env bash
# Strip AI co-author trailers from a commit message, and
# install that strip as a per-task git commit-msg hook for a fleet launch.
#
# Usage:
#   fm-git-strip-ai-trailers.sh <msgfile>
#       Commit-msg hook mode. Git passes the proposed message file as $1.
#       Rewrites that file in place, then exits 0 so the commit proceeds.
#   fm-git-strip-ai-trailers.sh install <hooks-dir> <worktree>
#       Recreate <hooks-dir> as a core.hooksPath for this launch: a commit-msg
#       hook that runs this strip, plus one wrapper per client-side hook name
#       git documents except reference-transaction and post-index-change,
#       which are deliberately excluded (see FM_GIT_CLIENT_HOOKS below).
#       Each wrapper unsets GIT_CONFIG_* and then resolves
#       core.hooksPath (or $GIT_DIR/hooks) in the repository git is actually
#       running in, so a husky directory that only appears after npm install
#       still runs, and git -C some-other-repo does not inherit the task
#       worktree's hooks. That lookup also ignores GIT_CONFIG_PARAMETERS,
#       because git -c core.hooksPath=<this dir> (or a child process that
#       inherits it) carries the override there, and a lookup that honored it
#       would find this directory again and never run the repository's own
#       hook - a skipped pre-push guard. An empty core.hooksPath means no
#       repository hook, as in plain git; any other failed lookup exits
#       nonzero rather than skipping the repository's hook.
#       Install also binds that hooksPath to <worktree> alone: it writes
#       extensions.worktreeConfig true and a worktree-scoped core.hooksPath,
#       so a commit written by a process that never inherited the pane
#       environment still runs the strip; the caller additionally prefixes the
#       pane with GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0.
#   fm-git-strip-ai-trailers.sh unbind <worktree> <hooks-dir>
#       Release the worktree-scoped binding only when it names <hooks-dir> -
#       the directory this caller is about to delete - so a reused pool
#       worktree never keeps pointing core.hooksPath at a deleted directory and
#       silently lose the project's own hooks, while a binding naming any
#       other directory (a successor's) is left exactly as it is. A worktree
#       that is gone, unreadable, no longer a repository, or already unbound
#       is a silent no-op, never a failure.
#   fm-git-strip-ai-trailers.sh release <worktree> <hooks-dir>
#       The one implementation of that rule for a caller that deletes a hooks
#       directory: release the binding that names <hooks-dir> (unbind above),
#       then delete the directory. Main teardown, child teardown, spawn abort
#       and home removal all go through this, so a binding and the directory
#       it names cannot diverge, whatever their slot-ownership flags say. The
#       release is silent and non-fatal: a worktree that cannot be unbound, or
#       a directory that cannot be deleted, never fails the caller's cleanup -
#       the binding is released first, so even a failed removal leaves no
#       worktree pointing at a directory the next spawn will recreate anyway.
#   fm-git-strip-ai-trailers.sh install-mirror <hooks-dir>
#       Deliver the strip's commit-msg to a no-mistakes mirror hooks
#       directory, the one every run worktree's worktree-scoped core.hooksPath
#       resolves, which is the boundary every pipeline commit passes. Only
#       <hooks-dir>/commit-msg is ever written: the directory is never
#       recreated or chmod'ed, because the live pre-receive and post-receive
#       push-authorization hooks beside it (and anything else a tool drops
#       there) must stay byte-identical, which is why install's rm -rf is
#       forbidden on this path. A real commit-msg already in that directory is
#       chained - kept as commit-msg.fm-prev and exec'd after the strip - so it
#       still runs; one that cannot be chained safely is left in place and the
#       install refuses rather than overwriting it. Installing twice writes
#       nothing, and an install whose hook still points at this copy of the
#       script rewrites itself in place, keeping its chain. The hook written
#       here fails open on every path, unlike this script's own commit-msg
#       file mode and the task-worktree install - see the hook's own comment.
#
# WHY THIS EXISTS. Claude launches already carry attribution-off in their
# per-launch --settings JSON. Cursor and other non-Claude runtimes inject a
# Co-Authored-By trailer at the tooling layer AFTER the worker types a clean
# message, so the typed message is not the commit object.
# A prior per-machine ~/.cursor/cli-config.json attribution-off is not durable:
# it does not travel with Firstmate, it defaults back to on when unset, and it
# only feeds the CLI's request to the server - the trailer text is emitted by
# the model, so the setting suppresses rather than prevents it. Verified live
# on cursor-agent 2026.09.15 with attribution on: the trailer is already in
# .git/COMMIT_EDITMSG when the commit-msg hook runs, so the spawn-owned hook is
# the layer that sees the assembled message before the commit object is written.
# Human Co-Authored-By trailers are left untouched. Author identity is not
# rewritten.
#
# WHAT COVERS WHICH COMMIT. Three layers, three scopes, none a superset of the
# others:
#   - the pane's GIT_CONFIG_* reaches only processes descended from the
#     launch, so it covers only commits made inside that pane;
#   - the worktree-scoped core.hooksPath binding covers any process committing
#     in the task copy, whatever started it, and only there - it is
#     worktree-scoped, so the primary checkout and sibling worktrees keep
#     resolving their own hooks. It does NOT cover the no-mistakes pipeline:
#     the pipeline never commits in the task copy;
#   - the no-mistakes daemon is long-lived, started outside any pane, and
#     carries no GIT_CONFIG_* at all. It writes its
#     `no-mistakes(review|document|ci):` fix rounds in its own run worktrees
#     (~/.no-mistakes/worktrees/<repo-id>/<run-id>), whose worktree-scoped
#     core.hooksPath already points at the mirror hooks directory
#     (~/.no-mistakes/repos/<repo-id>.git/hooks). install-mirror puts this
#     strip's commit-msg there, which is what covers a pipeline commit made in
#     a no-mistakes run worktree; bin/fm-nm-run-lib.sh delivers it.
# Verified live 2026-09-26: the running daemon's environment carries no
# GIT_CONFIG_*; pushed Portal branches kept
# `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; and every NM run
# worktree resolves core.hooksPath to its mirror's hooks directory, which held
# no commit-msg.
#
# ACCEPTED RESIDUAL, ruled 2026-09-17. git commit --no-verify skips every hook,
# so a worker that passes it still lands the trailer, as would a runtime that
# writes the commit object without running git. Both incidents that motivated
# this strip came through an ordinary hook-running commit, so the ruling is to
# accept that gap rather than add a push-side rewrite or a push-side check. A
# trailer found on a fleet commit therefore points at one of those two paths,
# not at an unnoticed hole in the matcher.
#
# ACCEPTED RESIDUAL, ruled 2026-09-17. Inside a fleet pane git reports this
# directory as the repository's hooks directory, so a hook manager run there
# (lefthook's npm postinstall, pre-commit install) targets it and would
# displace the strip. install leaves the directory and every hook in it
# read-only, so such a manager fails loudly instead of silently winning. Hook
# managers therefore cannot install from inside fleet panes until a registered
# project genuinely needs it. Whoever removes the directory restores the owner
# write bit first.
set -u
unset CDPATH GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-git-strip-ai-trailers.sh <msgfile>
  fm-git-strip-ai-trailers.sh install <hooks-dir> <worktree>
  fm-git-strip-ai-trailers.sh unbind <worktree> <hooks-dir>
  fm-git-strip-ai-trailers.sh release <worktree> <hooks-dir>
  fm-git-strip-ai-trailers.sh install-mirror <hooks-dir>
EOF
  exit 2
}

trim_space() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# True when this line is an AI Co-Authored-By trailer that must not reach a
# commit object. Matches known product names and exact observed bot addresses only; an
# address is added when a runtime is seen emitting it, never guessed from a
# vendor domain, so a human co-author who works at a vendor is kept. A human
# whose name or address merely contains a substring such as "ai" is kept.
fm_is_ai_attribution_line() {
  local raw=$1 lowered rest name email
  raw=${raw%$'\r'}
  raw=$(trim_space "$raw")
  [ -n "$raw" ] || return 1
  lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
  co-authored-by:*) ;;
  *) return 1 ;;
  esac
  rest=$(trim_space "${raw#*:}")
  name=$rest
  email=
  case "$rest" in
  *'<'*'>'*)
    email=$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')
    email=${email#*'<'}
    email=${email%%'>'*}
    name=$(trim_space "${rest%%'<'*}")
    ;;
  esac
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$email" in
  noreply@anthropic.com | cursoragent@* | noreply@openai.com | copilot@github.com | worker@firstmate.local)
    return 0
    ;;
  esac
  case "$name" in
  cursor | 'cursor agent' | claude | 'claude code' | 'github copilot' | copilot | codex | chatgpt | gemini | 'google gemini' | grok | openai | firstmate-worker)
    return 0
    ;;
  esac
  return 1
}

strip_msgfile() {
  local src=$1 tmp
  [ -f "$src" ] || {
    echo "error: commit message file not found: $src" >&2
    return 1
  }
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-git-strip-ai-trailers.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if fm_is_ai_attribution_line "$line"; then
      continue
    fi
    printf '%s\n' "$line"
  done <"$src" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$src"
}

quote_for_hook() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_executable() {
  local dest=$1
  cat >"$dest" || return 1
  chmod 500 "$dest"
}

# Shared body for every wrapper: after the pane-wide GIT_CONFIG override is
# cleared, resolve this repository's own hooks directory the way git does
# (core.hooksPath, else the common dir's hooks) and exec that name if it
# exists. The lookup runs without GIT_CONFIG_PARAMETERS as well, since git -c
# is the other environment channel that can carry this directory as
# core.hooksPath; only the repository's config files name its own hooks. An
# empty core.hooksPath means "no hooks" in plain git, so the wrapper runs none;
# any other lookup failure prints a diagnostic and exits nonzero rather than
# skipping the repository's own hook.
#
# install writes its binding in git's worktree scope, which outranks every
# other scope, so asking git for the effective core.hooksPath here would just
# return this launch's own directory and chaining would stop. The scopes below
# the binding are read instead - local, then global, then system, highest
# precedence first - and git's default common-dir hooks path is used when none
# of them sets one, which is what the repository would resolve had this launch
# never bound anything. A husky or lefthook directory that only appears after
# npm install lands in local scope, so it is still found. Skip when the
# resolved path still names this launch's own hooks dir, meaning those config
# files point here, so the wrapper cannot recurse into itself.
runtime_chain_body() {
  local ours=$1
  cat <<EOF
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
ours=$(quote_for_hook "$ours")
name=\${0##*/}
refuse() {
  echo "fm-git-strip-ai-trailers: cannot resolve this repository's hooks directory; refusing to skip its \$name hook" >&2
  exit 1
}
proj=
for scope in --local --global --system; do
  if proj=\$(unset GIT_CONFIG_PARAMETERS; git config "\$scope" --get --type=path core.hooksPath); then
    [ -n "\$proj" ] || exit 0
    break
  elif [ \$? -ne 1 ]; then
    refuse
  fi
  proj=
done
if [ -n "\$proj" ]; then
  orig=\$(unset GIT_CONFIG_PARAMETERS; git -c core.hooksPath="\$proj" rev-parse --path-format=absolute --git-path hooks) || refuse
else
  orig=\$(unset GIT_CONFIG_PARAMETERS; git rev-parse --path-format=absolute --git-common-dir) || refuse
  orig=\$orig/hooks
fi
if [ "\$orig" = "\$ours" ]; then
  exit 0
fi
if [ -x "\$orig/\$name" ]; then
  exec "\$orig/\$name" "\$@"
fi
EOF
}

# Client-side hook names git invokes by name from core.hooksPath, per
# githooks(5) in git 2.50. The receive-side names, the config-invoked
# fsmonitor-watchman, and the git-p4 names are left out because git never looks
# them up in a fleet worker's own worktree. commit-msg is written separately
# because it is the one that carries the strip.
#
# reference-transaction and post-index-change are deliberately excluded, ruled
# 2026-09-17. git invokes them twice per updated ref and on every index write,
# so a wrapper for either turns a stat git used to skip into hundreds of forks
# on one bulk command. Measured on git 2.50.1: a fetch of 300 new refs goes
# 0.23s -> 24.6s, and a no-op /bin/sh hook still costs 4.9s, so the price is
# git's invocation rather than the wrapper body. Neither name is one
# commit-message or lint tooling installs, which is what this chaining exists
# to preserve. A project that does install one loses chaining for it inside
# fleet panes only.
#
# The names kept are not free either, and that cost is accepted, ruled
# 2026-09-17. Every wrapper call forks bash plus one git rev-parse. A plain
# commit fires four wrappers, and git's sequencer fires prepare-commit-msg and
# post-commit once per replayed commit in rebase and cherry-pick, as git am does
# its applypatch hooks per patch. Measured on git 2.50.1 with no project hooks:
# one commit goes ~76ms -> ~276ms, and a 60-commit rebase 0.74s -> 3.7s. They
# stay because git-lfs installs post-commit, post-checkout, post-merge and
# pre-push, and a slower rebase inside a pane is the accepted price.
FM_GIT_CLIENT_HOOKS='applypatch-msg pre-applypatch post-applypatch pre-commit
pre-merge-commit prepare-commit-msg post-commit pre-rebase post-checkout
post-merge pre-push post-rewrite pre-auto-gc sendemail-validate'

install_hooks() {
  local hooks_dir=$1 wt=$2 name ext_err
  [ -n "$hooks_dir" ] && [ -n "$wt" ] || usage
  [ -d "$wt" ] || {
    echo "error: worktree is not a directory: $wt" >&2
    return 1
  }
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null || {
    echo "error: not a git worktree: $wt" >&2
    return 1
  }
  chmod u+w "$hooks_dir" 2>/dev/null
  rm -rf "$hooks_dir"
  mkdir -p "$hooks_dir" || return 1
  chmod 700 "$hooks_dir" 2>/dev/null || true
  hooks_dir=$(CDPATH='' cd -- "$hooks_dir" && pwd -P) || return 1

  # The worktree this directory binds, recorded inside the directory this
  # installer owns, so a wholesale home removal can release the binding by
  # name even for a leftover whose task record was never published.
  printf '%s\n' "$(CDPATH='' cd -- "$wt" && pwd -P)" >"$hooks_dir/.fm-worktree" || return 1

  write_executable "$hooks_dir/commit-msg" <<EOF
#!/usr/bin/env bash
set -u
$(quote_for_hook "$SELF") "\$1" || exit \$?
$(runtime_chain_body "$hooks_dir")
EOF

  for name in $FM_GIT_CLIENT_HOOKS; do
    write_executable "$hooks_dir/$name" <<EOF
#!/usr/bin/env bash
set -u
$(runtime_chain_body "$hooks_dir")
EOF
  done
  chmod 500 "$hooks_dir"

  # Bind the same path to this worktree so a commit written outside the pane
  # environment still strips. extensions.worktreeConfig is repository-wide but
  # inert on its own: it only tells git to read a config.worktree that no other
  # worktree has. The write is skipped when the value is already set, because
  # that file is shared by every worktree of the project, but a first wave of
  # concurrent spawns still reaches the write together and git's config lock
  # rejects the losers even though each of them writes the same constant. A
  # rejected write that leaves the extension true therefore stands: only one
  # that leaves it unset fails, because a launch that cannot strip is the leak
  # this exists to close.
  if [ "$(git -C "$wt" config --get extensions.worktreeConfig 2>/dev/null)" != true ]; then
    if ! ext_err=$(git -C "$wt" config extensions.worktreeConfig true 2>&1); then
      if [ "$(git -C "$wt" config --get extensions.worktreeConfig 2>/dev/null)" != true ]; then
        [ -z "$ext_err" ] || printf '%s\n' "$ext_err" >&2
        echo "error: could not enable worktree config in: $wt" >&2
        return 1
      fi
    fi
  fi
  git -C "$wt" config --worktree core.hooksPath "$hooks_dir" || {
    echo "error: could not bind the strip hooks to: $wt" >&2
    return 1
  }
}

# One rule for every caller that deletes a hooks directory: release only the
# binding that names that directory. The value match and the removal are one
# git transaction, so nothing that rebinds this worktree between an inspection
# and a mutation can be caught by it - a slot-ownership flag was read long ago,
# after the slot could already have been handed to a successor whose own
# binding must never be touched. Worktree gone, binding unreadable, value
# already gone, or a value naming some other directory: all silent no-ops,
# never a teardown failure.
unbind_hooks() {
  local wt=$1 hooks_dir=$2 want
  [ -n "$wt" ] && [ -n "$hooks_dir" ] || return 0
  want=$(CDPATH='' cd -- "$hooks_dir" 2>/dev/null && pwd -P) || want=$hooks_dir
  git -C "$wt" config --worktree --unset --fixed-value core.hooksPath "$want" 2>/dev/null || true
}

# One implementation of the header's rule for a caller that deletes a hooks
# directory: release the binding that names it, then delete it. The release is
# the identity-guarded unbind above, so a binding naming some other directory
# is never touched, and it happens before the removal, so a directory that
# cannot be deleted still leaves no worktree pointing at it. Callers do not
# gate their cleanup on this command's status.
release_hooks_dir() {
  local wt=$1 hooks_dir=$2
  [ -n "$hooks_dir" ] || return 0
  unbind_hooks "$wt" "$hooks_dir" || true
  chmod u+w "$hooks_dir" 2>/dev/null || true
  rm -rf "$hooks_dir"
}

# Identity of a mirror commit-msg this script wrote: the marker line every
# install-mirror hook carries. Used to tell ours from a real hook beside it.
MIRROR_MARKER='# fm-git-strip-ai-trailers mirror commit-msg'
MIRROR_PREV=commit-msg.fm-prev

mirror_commit_msg_is_ours() {  # <file>
  [ -f "$1" ] && [ ! -L "$1" ] && grep -q "^${MIRROR_MARKER}\$" "$1" 2>/dev/null
}

mirror_commit_msg_is_current() {  # <file>
  mirror_commit_msg_is_ours "$1" &&
    grep -qF "strip=$(quote_for_hook "$SELF")" "$1" 2>/dev/null
}

# install-mirror writes one file into a directory it does not own. The
# no-mistakes mirror hooks directory holds the live pre-receive and
# post-receive push-authorization hooks and whatever else a tool installed
# there, so nothing in it is ever recreated, removed, or chmod'ed except a
# commit-msg this function is about to replace - foreign, never silently: it is
# parked as commit-msg.fm-prev and exec'd after the strip so it still runs.
# What is installed here is per-repository, not per-task: it must outlive every
# task in that repository, which is why teardown's per-task unbind and spawn's
# abort cleanup must never grow a matching removal. Dropping this hook when a
# task ends would silently end trailer coverage for the next task in the same
# repository - the exact leak this exists to close.
MIRROR_INSTALL_LOCK=
install_mirror_hook() {
  local hooks_dir=$1 lock rc
  [ -n "$hooks_dir" ] || usage
  [ -d "$hooks_dir" ] || {
    echo "error: hooks directory is not a directory: $hooks_dir" >&2
    return 1
  }
  # One process per mirror across the whole check-park-install sequence, held
  # in a lock beside the directory so that nothing inside it is ever written
  # but commit-msg. Two deliveries that both saw a foreign commit-msg would
  # each park it and then park the other's hook over it, destroying the foreign
  # hook silently; the loser of the mkdir lock skips instead of waiting or
  # forcing, because the winner installs the identical hook, install is
  # idempotent, and this path must stay non-fatal for the status read it rides
  # on. The traps release the lock on EXIT, INT and TERM, so an ordinary signal
  # cannot strand it. SIGKILL runs no trap and can leave one behind; a
  # staleness policy that abandons an old lock is deliberately NOT implemented
  # here, because an age-based steal is not owner-checked and could rip the
  # lock off a live-but-stalled delivery, letting two check-park-install
  # sequences interleave and double-park the foreign commit-msg this lock
  # exists to protect. If a leftover lock is ever observed blocking a real
  # delivery, that comes back as its own decision with owner-checking designed
  # in - never as a side branch here. Any lock found already present means
  # skip and success, whatever its age, because install is idempotent.
  lock="${hooks_dir}.fm-install.lock"
  mkdir "$lock" 2>/dev/null || return 0
  MIRROR_INSTALL_LOCK=$lock
  trap 'rmdir "$MIRROR_INSTALL_LOCK" 2>/dev/null || true' EXIT
  trap 'rmdir "$MIRROR_INSTALL_LOCK" 2>/dev/null || true; exit 130' INT
  trap 'rmdir "$MIRROR_INSTALL_LOCK" 2>/dev/null || true; exit 143' TERM
  mirror_install_hook "$hooks_dir"
  rc=$?
  rmdir "$lock" 2>/dev/null || true
  MIRROR_INSTALL_LOCK=
  trap - EXIT INT TERM
  return "$rc"
}

# The check-park-install sequence itself, one process at a time under the lock
# above.
mirror_install_hook() {
  local hooks_dir=$1 existing prev tmp chain_prev parked=0
  existing="$hooks_dir/commit-msg"
  prev="$hooks_dir/$MIRROR_PREV"
  # Whether the hook written below must exec $prev at runtime: a real hook
  # about to be parked there, or a chained hook already sitting there. Decided
  # before the body is written, because the parking move happens after it.
  chain_prev=0
  if mirror_commit_msg_is_ours "$existing"; then
    mirror_commit_msg_is_current "$existing" && return 0
    [ -f "$prev" ] && chain_prev=1
  elif [ -e "$existing" ] || [ -L "$existing" ]; then
    if [ ! -f "$existing" ] || [ -L "$existing" ] || [ ! -r "$existing" ]; then
      echo "error: $existing cannot be read, so it cannot be chained safely; not installing" >&2
      return 1
    fi
    if [ -e "$prev" ] || [ -L "$prev" ]; then
      echo "error: $prev already holds a chained hook, so $existing cannot be chained safely; not installing" >&2
      return 1
    fi
    chain_prev=1
  elif [ -f "$prev" ]; then
    chain_prev=1
  fi
  tmp=$(mktemp "$hooks_dir/.commit-msg.fm.XXXXXXXX") || {
    echo "error: cannot write into hooks directory: $hooks_dir" >&2
    return 1
  }
  {
    cat <<EOF
#!/bin/sh
$MIRROR_MARKER
# Fail OPEN on every path: this hook runs for every no-mistakes pipeline
# commit in every lane and every home, so a hook that can block them all is
# far worse than a trailer the acceptance grep will catch. A missing strip
# script, a strip error, or an unreadable message file leaves the message
# unchanged and the commit succeeding. The task-worktree install is the
# deliberate opposite: it fails closed at spawn time.
strip=$(quote_for_hook "$SELF")
msg=\${1-}
if [ -n "\$msg" ] && [ -f "\$msg" ] && [ -x "\$strip" ]; then
  "\$strip" "\$msg" || :
fi
EOF
    if [ "$chain_prev" -eq 1 ]; then
      cat <<EOF
prev=$(quote_for_hook "$prev")
if [ -z "\${FM_GIT_STRIP_MIRROR_CHAIN:-}" ] && [ -f "\$prev" ] && [ -x "\$prev" ]; then
  FM_GIT_STRIP_MIRROR_CHAIN=1
  export FM_GIT_STRIP_MIRROR_CHAIN
  exec "\$prev" "\$@"
fi
EOF
    fi
    printf '%s\n' 'exit 0'
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 500 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if mirror_commit_msg_is_ours "$existing"; then
    :
  elif [ -e "$existing" ] || [ -L "$existing" ]; then
    mv -f "$existing" "$prev" || {
      rm -f "$tmp"
      return 1
    }
    parked=1
  fi
  if ! mv -f "$tmp" "$existing"; then
    rm -f "$tmp"
    if [ "$parked" -eq 1 ]; then
      mv -f "$prev" "$existing" 2>/dev/null || true
    fi
    return 1
  fi
  return 0
}

CMD=${1:-}
case "$CMD" in
install)
  [ "$#" -eq 3 ] || usage
  install_hooks "$2" "$3"
  ;;
unbind)
  [ "$#" -eq 3 ] || usage
  unbind_hooks "$2" "$3"
  ;;
release)
  [ "$#" -eq 3 ] || usage
  release_hooks_dir "$2" "$3"
  ;;
install-mirror)
  [ "$#" -eq 2 ] || usage
  install_mirror_hook "$2"
  ;;
-h | --help)
  usage
  ;;
'')
  usage
  ;;
*)
  if [ "$CMD" = "${CMD#-}" ] && [ "$#" -ge 1 ]; then
    strip_msgfile "$1"
  else
    usage
  fi
  ;;
esac
