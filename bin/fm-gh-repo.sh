#!/usr/bin/env bash
# Name a project clone's GitHub repository from the clone's own remotes.
# Prints exactly one line, <owner>/<repo>, and exits 0 when the repository is
# unambiguous; prints nothing and exits 1 when it is not; exits 2 with an error
# on stderr for a missing clone or a directory that is not a git work tree.
#
# bin/fm-spawn.sh exports the result as GH_REPO into every ship and scout
# launch. gh and gh-axi infer the repository of an issue, PR, or comment command
# from the git remote of the shell's current directory, so a worker whose shell
# sits inside the firstmate home would otherwise address the firstmate repo
# itself. GH_REPO pins those commands to the task's project from any directory,
# and an explicit --repo still overrides it.
#
# The result is the repository gh itself would pick inside the clone, read from
# the clone's own git config and never from the network. Only remotes on
# github.com (including www. and ssh.github.com, case-insensitively) count:
#   1. a remote chosen with `gh repo set-default` (remote.<name>.gh-resolved,
#      recorded as `base`, or by older gh as the chosen owner/repo) names it;
#   2. otherwise the first GitHub remote in gh's non-interactive order does:
#      upstream, then github, then origin, then the rest in git's order.
# A clone with no GitHub remote, or a GH_HOST naming another host (where gh
# would read an unqualified owner/repo against that host), resolves to nothing.
# gh-axi's `stack` commands refuse while GH_REPO is set, because they act on
# the current directory's repository; `env -u GH_REPO gh-axi stack ...` runs
# them.
# Usage: fm-gh-repo.sh <clone-dir>
set -eu

DIR=${1:?usage: fm-gh-repo.sh <clone-dir>}
if [ ! -d "$DIR" ] || ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $DIR is not a git work tree" >&2
  exit 2
fi

# Print owner/repo for a github.com remote URL; fail for anything else.
github_slug() {  # <url>
  local url=$1 host path owner repo
  case "$url" in
    *://*)
      url=${url#*://}
      host=${url%%/*}
      path=${url#*/}
      [ "$path" != "$url" ] || return 1
      ;;
    *:*)
      host=${url%%:*}
      path=${url#*:}
      ;;
    *) return 1 ;;
  esac
  host=${host##*@}
  host=$(printf '%s' "${host%%:*}" | tr '[:upper:]' '[:lower:]')
  case "$host" in
    github.com|www.github.com|ssh.github.com) ;;
    *) return 1 ;;
  esac
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  case "$owner/$repo" in
    */*/* | *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  case "$owner" in ''|.|..) return 1 ;; esac
  case "$repo" in ''|.|..) return 1 ;; esac
  [ "$repo" != "$path" ] || return 1
  printf '%s/%s\n' "$owner" "$repo"
}

# gh's ranking of remote names when no set-default choice exists.
remote_rank() {  # <remote-name>
  case "$1" in
    upstream) printf 3 ;;
    github) printf 2 ;;
    origin) printf 1 ;;
    *) printf 0 ;;
  esac
}

case "${GH_HOST:-github.com}" in
  github.com) ;;
  *) exit 1 ;;
esac

REMOTES=$(git -C "$DIR" remote 2>/dev/null || true)
best=
best_rank=-1
while IFS= read -r remote; do
  [ -n "$remote" ] || continue
  url=$(git -C "$DIR" remote get-url "$remote" 2>/dev/null) || continue
  remote_slug=$(github_slug "$url") || continue
  resolved=$(git -C "$DIR" config --get "remote.$remote.gh-resolved" 2>/dev/null || true)
  case "$resolved" in
    '') ;;
    base) printf '%s\n' "$remote_slug"; exit 0 ;;
    *)
      if chosen=$(github_slug "https://github.com/$resolved"); then
        printf '%s\n' "$chosen"
        exit 0
      fi
      ;;
  esac
  rank=$(remote_rank "$remote")
  if [ "$rank" -gt "$best_rank" ]; then
    best=$remote_slug
    best_rank=$rank
  fi
done <<EOF
$REMOTES
EOF
[ -n "$best" ] || exit 1
printf '%s\n' "$best"
