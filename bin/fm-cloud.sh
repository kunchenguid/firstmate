#!/usr/bin/env bash
# fm-cloud.sh - the default command for Claude Code cloud runs: launch one from
# the command line, track it in a durable local record, poll its result branch,
# and retire the record.
#
# Usage:
#   fm-cloud.sh launch [--file <prompt-file>] [--environment <id>] [--repo <dir>]
#                      [--branch <name>] [--] [<prompt>...]
#   fm-cloud.sh status [<run-id>]
#   fm-cloud.sh list
#   fm-cloud.sh cleanup <run-id>
#   fm-cloud.sh doctor
#
# launch runs `claude --cloud <prompt>` from --repo (default: the current
# directory), passing --environment through when given, and records the run as
# state/cloud-runs/<run-id>.run (key=value lines, one record per run): the
# session id and url parsed from the CLI's output, the repo and its remote, the
# base branch, the expected result namespace (claude/*), the claude/* branch
# heads that already existed at launch, and the prompt's length and sha256.
# The prompt text itself is never stored or printed. --branch is recorded as the
# base branch and nothing else: this tool does not switch branches.
#
# status polls the recorded remote with `git ls-remote --heads` and prints each
# claude/* branch that is new or moved since launch; it reads only branch names
# and commit ids. list prints one line per recorded run without touching the
# network.
#
# cleanup retires a run record and PRINTS the web-only steps that remain; it
# performs none of them. The steps are owned by runbooks-e8k (the
# cloud-environment settings and the Tailscale key have no CLI).
#
# doctor reports whether the claude CLI is present and supports --cloud,
# --environment, and --teleport, and lists what still needs the web UI.
#
# Hard rules: this script never prints, logs, or stores an auth key, token, or
# environment value, never drives a browser, never touches Tailscale or
# claude.ai settings, and never creates a Codespace.
#
# Environment: FM_HOME and FM_STATE_OVERRIDE resolve the home like the other
# bin/ scripts. Exit: 0 ok, 1 operational failure, 2 usage error.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RUNS="$STATE/cloud-runs"

die() { printf 'fm-cloud: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'fm-cloud: %s\n' "$*" >&2; sed -n '5,10p' "${BASH_SOURCE[0]}" >&2; exit 2; }

valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac; }

rec_get() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

rec_path() {  # <run-id>
  valid_id "$1" || usage_die "invalid run id: $1"
  [ -f "$RUNS/$1.run" ] || die "no such run record: $1"
  printf '%s\n' "$RUNS/$1.run"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}

cmd_launch() {
  local file="" env_id="" repo="" branch="" prompt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) [ $# -ge 2 ] || usage_die "--file needs a value"; file=$2; shift 2 ;;
      --environment) [ $# -ge 2 ] || usage_die "--environment needs a value"; env_id=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || usage_die "--repo needs a value"; repo=$2; shift 2 ;;
      --branch) [ $# -ge 2 ] || usage_die "--branch needs a value"; branch=$2; shift 2 ;;
      --) shift; break ;;
      -*) usage_die "unknown launch option: $1" ;;
      *) break ;;
    esac
  done
  if [ -n "$file" ]; then
    [ $# -eq 0 ] || usage_die "give a prompt argument or --file, not both"
    [ -f "$file" ] || die "prompt file not found: $file"
    prompt=$(cat "$file")
  else
    prompt="$*"
  fi
  [ -n "$prompt" ] || usage_die "launch needs a prompt argument or --file"
  command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH (run: fm-cloud.sh doctor)"
  repo=${repo:-$PWD}
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git repository: $repo"
  repo=$(git -C "$repo" rev-parse --show-toplevel)
  local remote_name remote_url base before
  remote_name=$(git -C "$repo" remote | head -n 1)
  [ -n "$remote_name" ] || die "repository has no remote to poll for the result branch: $repo"
  remote_url=$(git -C "$repo" remote get-url "$remote_name")
  # A remote URL may embed credentials; keep only its host and path.
  remote_url=$(printf '%s' "$remote_url" | sed -E 's#^([a-z+]+://)[^@/]*@#\1#')
  base=${branch:-$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}
  before=$(git -C "$repo" ls-remote --heads "$remote_name" 'refs/heads/claude/*' 2>/dev/null \
    | awk '{print $1":"$2}' | paste -sd, - || true)

  local args=(--cloud "$prompt")
  [ -z "$env_id" ] || args+=(--environment "$env_id")
  local out rc=0
  out=$( (cd "$repo" && claude "${args[@]}") 2>&1 </dev/null) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" | tail -n 5 >&2; die "claude --cloud failed (exit $rc)"; }

  local url session
  url=$(printf '%s\n' "$out" | grep -Eo 'https://claude\.ai/code/[A-Za-z0-9_./-]+' | head -n 1 || true)
  session=$(printf '%s\n' "$url" | sed -n 's#.*/\(session_[A-Za-z0-9_]*\).*#\1#p' | head -n 1)
  [ -n "$session" ] || session=$(printf '%s\n' "$out" | grep -Eo 'session_[A-Za-z0-9]+' | head -n 1 || true)

  local id now
  now=$(date +%s)
  id="cloud-$now-$$"
  mkdir -p "$RUNS"
  {
    printf 'id=%s\n' "$id"
    printf 'launched_at=%s\n' "$now"
    printf 'session=%s\n' "$session"
    printf 'url=%s\n' "$url"
    printf 'environment=%s\n' "$env_id"
    printf 'repo=%s\n' "$repo"
    printf 'remote=%s\n' "$remote_name"
    printf 'remote_url=%s\n' "$remote_url"
    printf 'base_branch=%s\n' "$base"
    printf 'result_branch=claude/*\n'
    printf 'heads_before=%s\n' "$before"
    printf 'prompt_bytes=%s\n' "$(printf '%s' "$prompt" | wc -c | tr -d ' ')"
    printf 'prompt_sha256=%s\n' "$(printf '%s' "$prompt" | sha256_of)"
  } > "$RUNS/$id.run"
  printf 'run: %s\n' "$id"
  printf 'session: %s\n' "${session:-unknown}"
  printf 'url: %s\n' "${url:-unknown}"
  printf 'result: claude/* branch on %s (poll: fm-cloud.sh status %s)\n' "$remote_name" "$id"
  [ -n "$session" ] || printf 'note: no session id found in the claude output; the run is recorded without one\n'
  return 0
}

cmd_list() {
  local f any=0
  [ -d "$RUNS" ] || { printf 'no cloud runs recorded\n'; return 0; }
  for f in "$RUNS"/*.run; do
    [ -e "$f" ] || continue
    any=1
    printf '%s session=%s environment=%s base=%s url=%s\n' \
      "$(rec_get "$f" id)" "$(rec_get "$f" session)" "$(rec_get "$f" environment)" \
      "$(rec_get "$f" base_branch)" "$(rec_get "$f" url)"
  done
  [ "$any" -eq 1 ] || printf 'no cloud runs recorded\n'
}

status_one() {  # <record-file>
  local f=$1 repo remote before now sha ref found=0
  repo=$(rec_get "$f" repo); remote=$(rec_get "$f" remote); before=$(rec_get "$f" heads_before)
  printf 'run: %s\nsession: %s\nurl: %s\nresult: %s on %s\n' "$(rec_get "$f" id)" \
    "$(rec_get "$f" session)" "$(rec_get "$f" url)" "$(rec_get "$f" result_branch)" "$remote"
  if ! now=$(git -C "$repo" ls-remote --heads "$remote" 'refs/heads/claude/*' 2>/dev/null); then
    printf 'poll: failed (remote unreachable)\n'; return 0
  fi
  while read -r sha ref; do
    [ -n "$ref" ] || continue
    case ",$before," in *",$sha:$ref,"*) continue ;; esac
    found=1
    printf 'branch: %s %s\n' "${ref#refs/heads/}" "$sha"
  done <<< "$now"
  [ "$found" -eq 1 ] || printf 'branch: none yet\n'
  return 0
}

cmd_status() {
  local f any=0
  if [ $# -ge 1 ]; then
    status_one "$(rec_path "$1")"; return 0
  fi
  [ -d "$RUNS" ] || { printf 'no cloud runs recorded\n'; return 0; }
  for f in "$RUNS"/*.run; do
    [ -e "$f" ] || continue
    any=1; status_one "$f"; printf '\n'
  done
  [ "$any" -eq 1 ] || printf 'no cloud runs recorded\n'
}

cmd_cleanup() {
  [ $# -eq 1 ] || usage_die "cleanup needs exactly one run id"
  local f
  f=$(rec_path "$1")
  rm -f "$f"
  printf 'retired run record: %s\n' "$1"
  cat <<'WEB'
web-only steps (this tool performs none of them; runbook: runbooks-e8k):
  1. remove TS_AUTHKEY from the cloud environment
  2. revoke the Tailscale auth key
  3. restore the environment's network access to its normal setting
WEB
}

cmd_doctor() {
  local rc=0 help ver flag
  if ! command -v claude >/dev/null 2>&1; then
    printf 'claude: MISSING (install Claude Code, then rerun doctor)\n'; rc=1
  else
    ver=$(claude --version 2>/dev/null | head -n 1 || true)
    printf 'claude: %s\n' "${ver:-version unknown}"
    help=$(claude --help 2>&1 || true)
    for flag in --cloud --environment --teleport; do
      if printf '%s\n' "$help" | grep -q -- "$flag"; then
        printf 'flag %s: supported\n' "$flag"
      else
        printf 'flag %s: NOT FOUND in claude --help\n' "$flag"
        [ "$flag" != --cloud ] || rc=1
      fi
    done
  fi
  if command -v git >/dev/null 2>&1; then printf 'git: present\n'; else printf 'git: MISSING\n'; rc=1; fi
  if command -v gh-axi >/dev/null 2>&1; then printf 'gh-axi: present\n'; else printf 'gh-axi: not installed (optional; status uses git ls-remote)\n'; fi
  printf 'still needs the web UI (no CLI): cloud-environment network allowlist and environment variables, Tailscale key minting\n'
  printf 'runbook: runbooks-e8k\n'
  return "$rc"
}

[ $# -ge 1 ] || usage_die "missing subcommand"
sub=$1; shift
case "$sub" in
  launch) cmd_launch "$@" ;;
  status) cmd_status "$@" ;;
  list) cmd_list "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  doctor) cmd_doctor "$@" ;;
  -h|--help|help) sed -n '2,41p' "${BASH_SOURCE[0]}" ;;
  *) usage_die "unknown subcommand: $sub" ;;
esac
