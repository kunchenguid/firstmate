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
#       worktree's hooks. Does not touch the project's git config; the caller
#       prefixes the pane with GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 /
#       GIT_CONFIG_VALUE_0.
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
  noreply@anthropic.com | cursoragent@* | noreply@openai.com | copilot@github.com)
    return 0
    ;;
  esac
  case "$name" in
  cursor | 'cursor agent' | claude | 'claude code' | 'github copilot' | copilot | codex | chatgpt | gemini | 'google gemini' | grok | openai)
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
  mv "$tmp" "$src"
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
# exists. Skip when that path is this launch's own hooks dir so the wrapper
# cannot recurse into itself.
runtime_chain_body() {
  local ours=$1
  cat <<EOF
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
ours=$(quote_for_hook "$ours")
name=\${0##*/}
orig=\$(git rev-parse --path-format=absolute --git-path hooks) || exit 0
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
  local hooks_dir=$1 wt=$2 name
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
}

CMD=${1:-}
case "$CMD" in
install)
  [ "$#" -eq 3 ] || usage
  install_hooks "$2" "$3"
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
