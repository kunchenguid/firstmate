#!/usr/bin/env bash
# Per-task pre-push guard. Two record kinds share one pre-push wrapper:
#   - forge=external: the review tool uploads its own snapshot, so a worker
#     never needs to push a branch (docs/external-review-forge.md owns that design);
#   - gate policy: pushes go to a stamped no-mistakes gate, or come
#     from that gate when it publishes its run (the gate rule below).
# bin/fm-spawn.sh owns policy selection; bin/fm-promote.sh owns installation
# for an existing scout promoted to a ship.
#
# Usage:
#   fm-git-push-guard.sh <guard-file> <remote-name> <remote-url>
#       Pre-push mode. Git's pre-push arguments follow the guard file, and git's
#       "<local-ref> <local-oid> <remote-ref> <remote-oid>" lines arrive on
#       stdin. Exits 0 to let the push proceed, nonzero with a refusal naming
#       the rule and the safe alternative otherwise. The record's header picks
#       the rule set.
#   fm-git-push-guard.sh write <guard-file> <repo> <task-branch> <task-prefix> [<backup-remote> <backup-prefix>]
#       Write a forge=external <guard-file> read-only for a launch: every
#       normalized fetch and push URL of <repo>'s origin as a shared URL, the
#       task branch, the task prefix, and the optional backup remote, its URLs,
#       and its prefix.
#   fm-git-push-guard.sh write-gate <guard-file>
#       Write a mode=no-mistakes <guard-file> read-only for a launch.
#
# GATE RULE (fm-git-push-guard-gate-v1). A push is allowed only when:
#   (g1) its resolved destination is a local directory carrying no-mistakes'
#        `no-mistakes-gate-config` stamp, by remote name, path, or file:// URL;
#   (g2) the pushing repository's common git directory carries that stamp,
#        allowing a gate daemon that inherited a pane's environment to publish.
# Every other destination is refused, including origin, a fork, and network
# URLs. Git supplies the resolved URL to pre-push regardless of command syntax
# or the repository used in the pane. No command-line parsing is involved.
# `no-mistakes axi run` skips client hooks for its push to the gate by design.
#
# bin/fm-spawn.sh writes the guard file and passes it to
# `bin/fm-git-strip-ai-trailers.sh install --push-guard`, whose pre-push wrapper
# runs this guard before chaining to the repository's own pre-push hook.
#
# The forge=external rule refuses:
#   (a) any push whose remote name is `origin`, or whose name or URL is one of
#       the shared URLs, which also covers `git push <url>` and a second remote
#       aliasing origin's URL with or without a trailing `.git`;
#   (b) any destination ref equal to refs/heads/<task-branch>, or under
#       refs/heads/<task-prefix> when that prefix is non-empty, on any remote;
#   (c) on the backup remote, any destination outside refs/heads/<backup-prefix>.
# An unreadable or malformed guard file refuses every push.
#
# ACCEPTED RESIDUAL. `git push --no-verify` skips every hook, a tool that
# writes refs without running git never reaches one, and an alias URL spelled
# differently from origin (an ssh form against an https form of the same
# server) does not compare equal. Each bypasses this layer; the brief's first
# rule still forbids all three, and no gate or cleanup step requires a push on
# this forge, which removes the pressure that would make a worker try one.
# The gate rule shares the first two residuals, plus overriding core.hooksPath,
# unsetting GIT_CONFIG_COUNT, and pushing from inside a stamped gate repository
# (g2). This protects ordinary pushes, not deliberate hook or stamp tampering.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-external-review-lib.sh
. "$SCRIPT_DIR/fm-external-review-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-git-push-guard.sh <guard-file> <remote-name> <remote-url>
  fm-git-push-guard.sh write <guard-file> <repo> <task-branch> <task-prefix> [<backup-remote> <backup-prefix>]
  fm-git-push-guard.sh write-gate <guard-file>
EOF
  exit 2
}

refuse() {  # <message>
  printf 'fm-git-push-guard: refused: %s\n' "$1" >&2
  exit 1
}

GATE_STAMP=no-mistakes-gate-config

write_gate_guard() {  # <guard-file>
  local out=$1 tmp
  [ -n "$out" ] || usage
  tmp=$(mktemp "$out.XXXXXX") || return 1
  printf 'fm-git-push-guard-gate-v1\n' >"$tmp" || { rm -f "$tmp"; return 1; }
  if ! chmod 400 "$tmp" || ! mv -f "$tmp" "$out"; then
    rm -f "$tmp"
    return 1
  fi
}

is_gate_dir() {  # <path>
  [ -n "$1" ] && [ -d "$1" ] && [ -f "$1/$GATE_STAMP" ]
}

guard_gate_push() {  # <remote-url>
  local url=$1 common dest resolved
  # A gate may publish from its bare repository or a linked worktree.
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
  if is_gate_dir "$common"; then
    cat >/dev/null
    return 0
  fi
  # Git passes the resolved destination, not just a configured remote name.
  dest=$url
  case "$dest" in
    file://*) dest=${dest#file://} ;;
    *:*) dest= ;;
  esac
  if [ -n "$dest" ]; then
    resolved=$(git rev-parse --resolve-git-dir "$dest" 2>/dev/null) \
      || resolved=
    if is_gate_dir "$resolved"; then
      cat >/dev/null
      return 0
    fi
  fi
  refuse "$url is not a no-mistakes gate; a mode=no-mistakes task publishes only through its gate. Use 'git push no-mistakes <branch>' or 'no-mistakes axi run'. A direct push leaves the pull request head without a matching pipeline attestation. If the gate is blocked, report the block"
}

write_guard() {  # <guard-file> <repo> <task-branch> <task-prefix> [<backup-remote> <backup-prefix>]
  local out=$1 repo=$2 branch=$3 prefix=$4 backup=${5:-} backup_prefix=${6:-} tmp url
  [ -n "$out" ] && [ -n "$repo" ] && [ -n "$branch" ] || usage
  if [ -n "$backup" ] && [ -z "$backup_prefix" ]; then
    usage
  fi
  tmp=$(mktemp "$out.XXXXXX") || return 1
  {
    printf 'fm-git-push-guard-v1\n'
    printf 'task_branch=%s\n' "$branch"
    printf 'task_prefix=%s\n' "$prefix"
    fm_external_review_remote_urls "$repo" origin | while IFS= read -r url; do
      printf 'shared_url=%s\n' "$url"
    done
    if [ -n "$backup" ]; then
      printf 'backup_remote=%s\n' "$backup"
      printf 'backup_prefix=%s\n' "$backup_prefix"
      fm_external_review_remote_urls "$repo" "$backup" | while IFS= read -r url; do
        printf 'backup_url=%s\n' "$url"
      done
    fi
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  if ! chmod 400 "$tmp" || ! mv -f "$tmp" "$out"; then
    rm -f "$tmp"
    return 1
  fi
}

guard_push() {  # <guard-file> <remote-name> <remote-url>
  local file=$1 name=$2 url=$3 line key value header
  local task_branch='' task_prefix='' backup='' backup_prefix='' has_branch=0
  local -a shared=() backup_urls=()
  [ -f "$file" ] && [ -r "$file" ] || refuse "the push guard file $file is unreadable, so no push can be checked"
  header=$(sed -n '1p' "$file")
  if [ "$header" = fm-git-push-guard-gate-v1 ]; then
    guard_gate_push "$url"
    return
  fi
  [ "$header" = fm-git-push-guard-v1 ] || refuse "the push guard file $file is not a guard record"
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      task_branch) task_branch=$value; has_branch=1 ;;
      task_prefix) task_prefix=$value ;;
      shared_url) shared+=("$value") ;;
      backup_remote) backup=$value ;;
      backup_prefix) backup_prefix=$value ;;
      backup_url) backup_urls+=("$value") ;;
    esac
  done < <(sed '1d' "$file")
  [ "$has_branch" = 1 ] && [ -n "$task_branch" ] || refuse "the push guard file $file names no task branch"
  if [ -n "$backup" ] && [ -z "$backup_prefix" ]; then
    refuse "the push guard file $file names a backup remote with no prefix"
  fi

  local norm_name norm_url s is_backup=0
  norm_name=$(fm_external_review_url_normalize "$name")
  norm_url=$(fm_external_review_url_normalize "$url")
  if [ "$name" = origin ]; then
    refuse "this project's review tool uploads its own snapshot, so nothing is ever pushed to origin; upload with the review tool your Definition of done names"
  fi
  for s in "${shared[@]+"${shared[@]}"}"; do
    if [ "$norm_url" = "$s" ] || [ "$norm_name" = "$s" ]; then
      refuse "$url is the project's shared origin, and nothing is ever pushed there on this project; upload with the review tool your Definition of done names"
    fi
  done
  if [ -n "$backup" ]; then
    [ "$name" != "$backup" ] || is_backup=1
    for s in "${backup_urls[@]+"${backup_urls[@]}"}"; do
      if [ "$norm_url" = "$s" ] || [ "$norm_name" = "$s" ]; then
        is_backup=1
      fi
    done
  fi

  local remote_ref
  while read -r _ _ remote_ref _; do
    [ -n "${remote_ref:-}" ] || continue
    if [ "$remote_ref" = "refs/heads/$task_branch" ]; then
      refuse "$remote_ref is your task branch, which is never pushed to any remote on this project${backup:+; push a durable copy to refs/heads/$backup_prefix<task-id> on $backup instead}"
    fi
    if [ -n "$task_prefix" ]; then
      case "$remote_ref" in
        "refs/heads/$task_prefix"*)
          refuse "$remote_ref is under the task branch prefix $task_prefix, which is never pushed to any remote on this project${backup:+; push a durable copy to refs/heads/$backup_prefix<task-id> on $backup instead}" ;;
      esac
    fi
    if [ "$is_backup" = 1 ]; then
      case "$remote_ref" in
        "refs/heads/$backup_prefix"*) ;;
        *) refuse "$remote_ref is outside refs/heads/$backup_prefix, the only namespace a durable copy may use on the backup remote $backup" ;;
      esac
    fi
  done
  return 0
}

case "${1:-}" in
  write)
    [ "$#" -eq 5 ] || [ "$#" -eq 7 ] || usage
    shift
    write_guard "$@"
    ;;
  write-gate)
    [ "$#" -eq 2 ] || usage
    shift
    write_gate_guard "$@"
    ;;
  ''|-h|--help)
    usage
    ;;
  *)
    [ "$#" -eq 3 ] || usage
    guard_push "$1" "$2" "$3"
    ;;
esac
