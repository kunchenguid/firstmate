#!/usr/bin/env bash
# fm-cs-lib.sh - Codespace backend helpers for firstmate crewmates.
#
# Firstmate runs every project crewmate inside a leased GitHub Codespace instead
# of a local treehouse worktree (AGENTS.md task lifecycle). This library owns the
# lease/pool/SSH primitives shared by fm-spawn, fm-teardown, fm-review-diff,
# fm-pr-check, and the per-task status relay. It is sourced, never executed.
#
# Two halves:
#   1. PURE-LOCAL helpers (lease registry, repo resolution, label/parse logic) -
#      jq/git only, no network, fully unit-testable offline (test/cs-lib-test.sh).
#   2. gh-BACKED helpers (acquire/start/ssh/stop/create/delete) - thin wrappers
#      over the documented `gh codespace` CLI. These need a user token carrying
#      the `codespace` scope; the default GITHUB_TOKEN integration token can only
#      LIST codespaces and 403s on every management op.
#
# Lease registry: $STATE/leases.json, a JSON object keyed by codespace name:
#   { "<cs-name>": { "codespace","repository","task","displayName",
#                    "source":"pool|created","branch","leasedAt" } }
# Display-name labels ("<slot> BUSY <task>") are lightweight, NON-atomic status
# hints on the codespace itself; the registry is firstmate's authoritative record.

# Resolve operational dirs the same way every fm-* script does, so this lib works
# whether sourced from the primary home or a secondmate home.
_fm_cs_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }
FM_CS_ROOT="${FM_ROOT_OVERRIDE:-$(_fm_cs_root)}"
FM_CS_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_CS_ROOT}}"
FM_CS_STATE="${FM_STATE_OVERRIDE:-$FM_CS_HOME/state}"
FM_CS_LEASES="${FM_CS_LEASES_OVERRIDE:-$FM_CS_STATE/leases.json}"

# Pool slot label prefix per repo family, and the BUSY/FREE/DIRTY/BAD vocabulary
# from the codespace-pool-lease skill. Display names are capped at 48 chars.
FM_CS_LABEL_MAX=48

FM_CS_TOKEN_FILE="${FM_CS_TOKEN_FILE_OVERRIDE:-${FM_CS_CONFIG_OVERRIDE:-$FM_CS_HOME/config}/codespace-token.env}"
FM_CS_HARNESS_FILE="${FM_CS_HARNESS_FILE_OVERRIDE:-${FM_CS_CONFIG_OVERRIDE:-$FM_CS_HOME/config}/cs-harness}"

# Codespace management needs a token carrying the `codespace` scope. The runtime
# usually exports an integration GITHUB_TOKEN that can only LIST codespaces, so we
# load a captain-provided PAT from a gitignored file into GH_TOKEN (which gh
# prefers over GITHUB_TOKEN). Only the GH_TOKEN= line is honored - the file is
# never eval'd. A GH_TOKEN already in the environment wins and is left untouched.
_cs_load_token() {
  [ -n "${GH_TOKEN:-}" ] && return 0
  [ -f "$FM_CS_TOKEN_FILE" ] || return 0
  local line val
  line=$(grep -E '^[[:space:]]*GH_TOKEN[[:space:]]*=' "$FM_CS_TOKEN_FILE" | tail -1 || true)
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val%\"}; val=${val#\"}; val=${val%\'}; val=${val#\'}
  val=$(printf '%s' "$val" | tr -d '[:space:]')
  [ -n "$val" ] || return 0
  export GH_TOKEN="$val"
}
_cs_load_token

# cs_harness - the harness crewmates run INSIDE the codespace (config/cs-harness,
# default copilot). Copilot authenticates through the codespace's native
# credentials, so it needs no secret propagation.
cs_harness() {
  local h
  if [ -f "$FM_CS_HARNESS_FILE" ]; then
    h=$(tr -d '[:space:]' < "$FM_CS_HARNESS_FILE")
  fi
  printf '%s\n' "${h:-copilot}"
}

# ---------------------------------------------------------------------------
# Pure-local: lease registry
# ---------------------------------------------------------------------------

_cs_leases_init() {
  mkdir -p "$(dirname "$FM_CS_LEASES")"
  [ -f "$FM_CS_LEASES" ] || printf '{}\n' > "$FM_CS_LEASES"
}

# cs_lease_record <cs> <repo> <task> <source> <branch> [display]
# Upsert a lease entry. leasedAt is set on first record and preserved on update.
cs_lease_record() {
  local cs=$1 repo=$2 task=$3 source=$4 branch=$5 display=${6:-}
  [ -n "$cs" ] || { echo "cs_lease_record: empty codespace" >&2; return 2; }
  _cs_leases_init
  local now tmp
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp)
  jq --arg cs "$cs" --arg repo "$repo" --arg task "$task" \
     --arg source "$source" --arg branch "$branch" --arg display "$display" \
     --arg now "$now" '
     .[$cs] = ((.[$cs] // {}) + {
       codespace: $cs, repository: $repo, task: $task,
       source: $source, branch: $branch, displayName: $display,
       leasedAt: ((.[$cs].leasedAt) // $now)
     })' "$FM_CS_LEASES" > "$tmp" && mv "$tmp" "$FM_CS_LEASES"
}

# cs_lease_release <cs> - drop a lease entry (idempotent).
cs_lease_release() {
  local cs=$1
  [ -n "$cs" ] || return 2
  [ -f "$FM_CS_LEASES" ] || return 0
  local tmp; tmp=$(mktemp)
  jq --arg cs "$cs" 'del(.[$cs])' "$FM_CS_LEASES" > "$tmp" && mv "$tmp" "$FM_CS_LEASES"
}

# cs_lease_get <cs> <field> - print one field of a lease, empty if absent.
cs_lease_get() {
  local cs=$1 field=$2
  [ -f "$FM_CS_LEASES" ] || return 0
  jq -r --arg cs "$cs" --arg f "$field" '.[$cs][$f] // empty' "$FM_CS_LEASES"
}

# cs_lease_for_task <task> - print the codespace name leased to a task, if any.
cs_lease_for_task() {
  local task=$1
  [ -f "$FM_CS_LEASES" ] || return 0
  jq -r --arg t "$task" 'to_entries[] | select(.value.task == $t) | .key' "$FM_CS_LEASES" | head -1
}

# cs_lease_list - print "codespace<TAB>task<TAB>source<TAB>repository" per lease.
cs_lease_list() {
  [ -f "$FM_CS_LEASES" ] || return 0
  jq -r 'to_entries[] | [.key, .value.task, .value.source, .value.repository] | @tsv' "$FM_CS_LEASES"
}

# ---------------------------------------------------------------------------
# Pure-local: repo resolution + label/parse logic
# ---------------------------------------------------------------------------

# cs_repo_for_project <project-dir> - resolve the GitHub owner/repo a project's
# origin points at, normalized from either https or ssh remotes. Empty + nonzero
# when there is no usable github origin (e.g. a local-only project).
cs_repo_for_project() {
  local dir=$1 url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  cs_repo_from_url "$url"
}

# cs_repo_from_url <url> - normalize a git remote URL to owner/repo. Pure string.
cs_repo_from_url() {
  local url=$1 path
  case "$url" in
    git@github.com:*)        path=${url#git@github.com:} ;;
    ssh://git@github.com/*)  path=${url#ssh://git@github.com/} ;;
    https://github.com/*)    path=${url#https://github.com/} ;;
    http://github.com/*)     path=${url#http://github.com/} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  case "$path" in
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

# cs_label <slot> <state> [note] - compose a <=48-char display-name label,
# truncating the note as needed. <state> is FREE|BUSY|DIRTY|BAD.
cs_label() {
  local slot=$1 state=$2 note=${3:-} base label
  base="$slot $state"
  if [ -n "$note" ]; then
    label="$base $note"
  else
    label="$base"
  fi
  if [ "${#label}" -gt "$FM_CS_LABEL_MAX" ]; then
    label=${label:0:$FM_CS_LABEL_MAX}
  fi
  printf '%s\n' "$label"
}

# cs_label_state <display-name> - extract the FREE|BUSY|DIRTY|BAD token from a
# pool display name ("pool-vscode-01 BUSY task"), empty if not a pool label.
cs_label_state() {
  local dn=$1
  printf '%s\n' "$dn" | awk '{for(i=1;i<=NF;i++) if($i=="FREE"||$i=="BUSY"||$i=="DIRTY"||$i=="BAD"){print $i; exit}}'
}

# cs_pool_free_from_json <repo> < codespaces-json
# Given `gh codespace list --json name,displayName,repository,state` output on
# stdin, print the name of the first FREE pool codespace for <repo>. Parsing is
# isolated here so it is unit-testable against canned JSON without auth.
cs_pool_free_from_json() {
  local repo=$1
  jq -r --arg repo "$repo" '
    [ .[]
      | select(.repository == $repo)
      | select(.displayName | test("(^| )pool-[a-z0-9-]+ FREE($| )"))
    ] | (.[0].name // empty)' 
}

# cs_pool_slot_from_display <display-name> - extract the "pool-xxx" slot token.
cs_pool_slot_from_display() {
  printf '%s\n' "$1" | grep -oE 'pool-[a-z0-9-]+' | head -1
}

# ---------------------------------------------------------------------------
# gh-backed: codespace management (needs `codespace` token scope)
# ---------------------------------------------------------------------------
# These are intentionally thin so the management surface stays auditable. Each
# returns the gh exit status. They are exercised live in test/cs-live-test.sh,
# which is skipped automatically when the token lacks codespace scope.

cs_have_scope() {
  # Cheap probe: list works on any token, but a management dry-run (ssh --config)
  # 403s on the integration token. We treat a successful `gh codespace list` plus
  # a non-403 ssh-config attempt as "scoped". Callers needing certainty should
  # just attempt the op and handle failure.
  gh codespace list --limit 1 >/dev/null 2>&1
}

cs_list_json() {
  gh codespace list --json name,displayName,repository,state,machineName,gitStatus "$@"
}

# cs_pool_free <repo> - name of a FREE pool codespace for repo, else empty.
cs_pool_free() {
  local repo=$1
  cs_list_json | cs_pool_free_from_json "$repo"
}

# cs_set_label <cs> <label> - set the display name (the lightweight lease hint).
cs_set_label() {
  gh codespace edit -c "$1" --display-name "$2"
}

# cs_ssh <cs> -- <cmd...> - run a command in the codespace over SSH.
cs_ssh() {
  local cs=$1; shift
  [ "${1:-}" = "--" ] && shift
  gh codespace ssh -c "$cs" -- "$@"
}

# cs_start <cs> - ensure the codespace is running (ssh implicitly starts it).
cs_start() {
  gh codespace ssh -c "$1" -- true
}

cs_stop()   { gh codespace stop -c "$1"; }
cs_delete() { gh codespace delete -c "$1" --force; }

# cs_create <repo> <branch> <display> [machine] - create a codespace, print name.
cs_create() {
  local repo=$1 branch=$2 display=$3 machine=${4:-xLargePremiumLinux}
  gh codespace create --repo "$repo" --branch "$branch" \
    --machine "$machine" --display-name "$display" \
    --idle-timeout 30m --retention-period 720h --default-permissions
}

# cs_repo_dir <cs> - print the workspace dir of the project inside the codespace
# (the single child of /workspaces). Needs a running codespace.
cs_repo_dir() {
  cs_ssh "$1" -- 'd=$(ls -d /workspaces/*/ 2>/dev/null | head -1); printf "%s" "${d%/}"'
}
