#!/usr/bin/env bash
# Run a local Git worktree's verification command on the configured SSH host.
# Usage: bin/fm-remote-verify.sh [--env NAME=VALUE]... <worktree> <command> [argument ...]
# The command is passed as an argv vector, not evaluated as shell text.
# --env sets one variable for the remote command; repeat it for more.
# The script installs nothing: put any dependency install in the command itself.
# config/remote-verify contains exactly one user@host SSH destination.
# Every remote step is a script read from stdin by `bash -s`, so the remote
# login shell never parses arguments; the remote host needs bash, Git, and rsync.
# Git history is bundled locally into a disposable remote test repository.
# Committed files, including committed .env files, are sent as repository content;
# ignored files and untracked files with secret-like names are not.
# The untracked filter matches file names only, so ignore any other secret file.
# Remote Git is limited to verification and throwaway test fixtures: no GitHub
# clones, worker copies, source commits, pushes, credentials, remotes, or hooks.
set -euo pipefail

usage() { printf 'usage: %s [--env NAME=VALUE]... <worktree> <command> [argument ...]\n' "$0" >&2; exit 64; }
env_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      [ "$#" -ge 2 ] || usage
      [[ "$2" =~ ^[A-Za-z_][A-Za-z_0-9]*= ]] || { printf 'error: --env needs NAME=VALUE: %s\n' "$2" >&2; exit 64; }
      env_args+=("$2")
      shift 2
      ;;
    --) shift; break;;
    -*) usage;;
    *) break;;
  esac
done
[ "$#" -ge 2 ] || usage
worktree=$1
shift
[ -d "$worktree" ] || { printf 'error: worktree is not a directory: %s\n' "$worktree" >&2; exit 64; }
worktree=$(cd "$worktree" && pwd -P)
[ "$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)" = "$worktree" ] || {
  printf 'error: path must be a Git worktree root: %s\n' "$worktree" >&2
  exit 64
}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
config_dir=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$repo_root}/config}
config=$config_dir/remote-verify
[ -f "$config" ] || { printf 'error: remote verify is not configured; put user@host in %s\n' "$config" >&2; exit 78; }
destination=$(cat "$config")
[[ "$destination" =~ ^[a-zA-Z_][a-zA-Z_0-9-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
  printf 'error: %s must contain one user@host SSH destination\n' "$config" >&2
  exit 78
}
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
# Run a bash script from stdin on the host; arguments are quoted for bash, not the login shell.
remote_bash() {
  local args=''
  [ "$#" -eq 0 ] || printf -v args ' %q' "$@"
  { printf 'set --%s\n' "$args"; cat; } | ssh "${ssh_opts[@]}" "$destination" 'bash -s'
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}
# shellcheck disable=SC2016
remote_home=$(remote_bash <<<'printf %s "$HOME"') || {
  printf 'error: remote verify host %s is unreachable; run locally if needed\n' "$destination" >&2
  exit 69
}
[[ "$remote_home" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { printf 'error: unsafe remote home path\n' >&2; exit 69; }
task_hash=$(printf %s "$worktree" | sha256 | cut -c1-16)
remote_task=$remote_home/.cache/firstmate/verify/$task_hash
# shellcheck disable=SC2016
remote_work=$(remote_bash "$remote_task" <<<'mkdir -p "$1" && mktemp -d "$1/work.XXXXXXXX"') || {
  printf 'error: cannot create remote verify directory on %s\n' "$destination" >&2
  exit 69
}
[[ "$remote_work" =~ ^$remote_task/work\.[a-zA-Z0-9]+$ ]] || {
  printf 'error: unexpected remote verify directory from %s\n' "$destination" >&2
  exit 69
}
cleanup() {
  # shellcheck disable=SC2016
  remote_bash "$remote_work" <<<'chmod -R u+w "$1/.git" 2>/dev/null || true; rm -rf "$1" "$1.template"; rm -f "$1.bundle"' >/dev/null 2>&1 || true
  rm -f "$file_list" "$bundle_file"
}
file_list=$(mktemp)
bundle_file=$(mktemp)
trap cleanup EXIT

# Committed files are repository content already shared through the project
# remote, so the tree and history are sent as committed, including .env files.
# Untracked files are sent only when not ignored and not named like a secret;
# ignored files, including local .env files and keys, never leave this machine.
is_secret_path() {
  case "$1" in
    .env.example|*/.env.example|.env.sample|*/.env.sample|.env.template|*/.env.template) return 1;;
    .env|.env.*|*/.env|*/.env.*|.npmrc|*/.npmrc|.pypirc|*/.pypirc|.netrc|*/.netrc|\
    .ssh/*|*/.ssh/*|.aws/*|*/.aws/*|.gnupg/*|*/.gnupg/*|\
    *.pem|*.key|*.p12|*.pfx|credentials.json|*/credentials.json|secrets.json|*/secrets.json|\
    id_rsa*|*/id_rsa*|id_ed25519*|*/id_ed25519*) return 0;;
  esac
  return 1
}
# Untracked dependency and build output stays local; tracked files are always sent.
is_output_path() {
  case "/$1/" in
    */node_modules/*|*/dist/*|*/build/*|*/coverage/*|*/.next/*|*/.turbo/*|*/.cache/*) return 0;;
  esac
  return 1
}
{
  git -C "$worktree" ls-files --cached -z
  git -C "$worktree" ls-files --others --exclude-standard -z | while IFS= read -r -d '' path; do
    is_secret_path "$path" || is_output_path "$path" || printf '%s\0' "$path"
  done
} | while IFS= read -r -d '' path; do
  if [ -e "$worktree/$path" ] || [ -L "$worktree/$path" ]; then
    printf '%s\0' "$path"
  fi
done > "$file_list"
source_head=$(git -C "$worktree" rev-parse HEAD)
git -C "$worktree" bundle create "$bundle_file" HEAD
rsync -a --from0 --files-from="$file_list" --exclude=.git -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' "$worktree/" "$destination:$remote_work/"
rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' "$bundle_file" "$destination:$remote_work.bundle"

remote_bash "$remote_work" "$source_head" "${#env_args[@]}" ${env_args[@]+"${env_args[@]}"} "$@" <<'REMOTE'
set -euo pipefail
work=$1
source_head=$2
env_count=$3
shift 3
env_vars=("${@:1:$env_count}")
shift "$env_count"
trap 'chmod -R u+w "$work/.git" 2>/dev/null || true; rm -rf "$work"' EXIT
cd "$work"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=0
mkdir "$work.template"
git init -q --template="$work.template"
rmdir "$work.template"
git bundle unbundle "$work.bundle" >/dev/null
git update-ref refs/heads/verify "$source_head"
git symbolic-ref HEAD refs/heads/verify
git read-tree HEAD
rm "$work.bundle"
chmod -R a-w .git
export GIT_OPTIONAL_LOCKS=0
export PATH="$HOME/.local/bin:$PATH"
for assignment in ${env_vars[@]+"${env_vars[@]}"}; do export "${assignment?}"; done
# The command must not read the rest of this script from stdin.
"$@" </dev/null
REMOTE
