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

# cs_pool_free_entry_from_json <repo> < codespaces-json
# Like cs_pool_free_from_json but prints "name<TAB>displayName" for the first FREE
# pool codespace, so callers can recover the pool slot from the FREE label.
cs_pool_free_entry_from_json() {
  local repo=$1
  jq -r --arg repo "$repo" '
    [ .[]
      | select(.repository == $repo)
      | select(.displayName | test("(^| )pool-[a-z0-9-]+ FREE($| )"))
    ] | (.[0] // empty) | select(. != null) | [.name, .displayName] | @tsv'
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

# _cs_gh - run gh with whichever scoped credential is available. When GH_TOKEN is
# set (token-file path B, loaded above), gh already prefers it over GITHUB_TOKEN,
# so call gh directly. Otherwise (stored-login path A) the integration GITHUB_TOKEN
# would shadow the stored scoped cred, so strip it and let gh use ~/.config/gh.
_cs_gh() {
  if [ -n "${GH_TOKEN:-}" ]; then
    gh "$@"
  else
    env -u GITHUB_TOKEN gh "$@"
  fi
}

cs_have_scope() {
  # Cheap probe: list works on any token, but a management dry-run (ssh --config)
  # 403s on the integration token. We treat a successful `gh codespace list` plus
  # a non-403 ssh-config attempt as "scoped". Callers needing certainty should
  # just attempt the op and handle failure.
  _cs_gh codespace list --limit 1 >/dev/null 2>&1
}

cs_list_json() {
  _cs_gh codespace list --json name,displayName,repository,state,machineName,gitStatus "$@"
}

# cs_pool_free <repo> - name of a FREE pool codespace for repo, else empty.
cs_pool_free() {
  local repo=$1
  cs_list_json | cs_pool_free_from_json "$repo"
}

# cs_pool_free_entry <repo> - "name<TAB>displayName" of a FREE pool cs, else empty.
cs_pool_free_entry() {
  local repo=$1
  cs_list_json | cs_pool_free_entry_from_json "$repo"
}

# cs_default_branch <repo> - the repo's default branch name (for cold-create).
cs_default_branch() {
  _cs_gh repo view "$1" --json defaultBranchRef -q .defaultBranchRef.name
}

# cs_set_label <cs> <label> - set the display name (the lightweight lease hint).
cs_set_label() {
  _cs_gh codespace edit -c "$1" --display-name "$2"
}

# cs_ssh <cs> -- <cmd...> - run a command in the codespace over SSH.
cs_ssh() {
  local cs=$1; shift
  [ "${1:-}" = "--" ] && shift
  _cs_gh codespace ssh -c "$cs" -- "$@"
}

# cs_start <cs> - ensure the codespace is running (ssh implicitly starts it).
cs_start() {
  _cs_gh codespace ssh -c "$1" -- true
}

cs_stop()   { _cs_gh codespace stop -c "$1"; }
cs_delete() { _cs_gh codespace delete -c "$1" --force; }

# cs_create <repo> <branch> <display> [machine] - create a codespace, print name.
cs_create() {
  local repo=$1 branch=$2 display=$3 machine=${4:-xLargePremiumLinux}
  _cs_gh codespace create --repo "$repo" --branch "$branch" \
    --machine "$machine" --display-name "$display" \
    --idle-timeout 30m --retention-period 720h --default-permissions
}

# cs_repo_dir <cs> - print the workspace dir of the project inside the codespace
# (the single child of /workspaces). Needs a running codespace.
cs_repo_dir() {
  cs_ssh "$1" -- 'd=$(ls -d /workspaces/*/ 2>/dev/null | head -1); printf "%s" "${d%/}"'
}

# ---------------------------------------------------------------------------
# Spawn helpers: push the brief + a driver script into the codespace and build
# the local tmux pane command that runs the agent over SSH. The pane runs
# `gh codespace ssh` LOCALLY, so it must carry the same scoped credential as
# _cs_gh (strip the integration GITHUB_TOKEN; source a token file into GH_TOKEN
# if present) - without ever putting the token on the command line (it is
# sourced in the pane).
#
# Supervision model (copilot-in-codespace): the codespace-native `copilot`
# harness authenticates via env token (GH_TOKEN aliased to the codespace's own
# GITHUB_TOKEN) ONLY in headless `-p` mode; interactive `-i` ignores env tokens
# and demands a stored device-flow login. So the crewmate runs as a headless
# driver loop: an initial `copilot -p` on the brief (streamed to the pane, so
# peek works), then a loop that watches a remote inbox file for steers and
# resumes the same session (`--resume`, context preserved) for each one (so
# fm-send works). The driver appends TURN-ENDED to ~/.fm/<id>.events after every
# copilot turn; the relay mirrors that to wake the watcher. This keeps native
# codespace auth with no secret propagation.
# ---------------------------------------------------------------------------

# cs_push_brief <cs> <id> <local-brief> - copy the brief into the codespace and
# print its ABSOLUTE remote path (resolved remotely, so the launch command needs
# no $HOME/tilde expansion). The crewmate reads this file as its initial prompt.
cs_push_brief() {
  local cs=$1 id=$2 brief=$3
  [ -f "$brief" ] || { echo "cs_push_brief: no brief at $brief" >&2; return 1; }
  cs_ssh "$cs" -- "mkdir -p \$HOME/.fm && cat > \$HOME/.fm/$id.brief.md && printf '%s\\n' \$HOME/.fm/$id.brief.md" < "$brief"
}

# cs_session_id - print a fresh RFC-4122 UUID for a copilot session. copilot
# validates the --session-id format, so a real v4 UUID is required.
cs_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    python3 -c 'import uuid;print(uuid.uuid4())'
  fi
}

# cs_push_driver <cs> <id> <remote-dir> <session-id> [harness] - generate the
# headless driver loop, push it to ~/.fm/<id>.run.sh in the codespace, and print
# its absolute remote path. The driver (only `copilot` is supported):
#   - aliases GH_TOKEN to the codespace's native GITHUB_TOKEN (headless auth),
#   - runs the brief once with a fixed session id,
#   - then watches ~/.fm/<id>.inbox and resumes that session for each steer,
#   - appends TURN-ENDED to ~/.fm/<id>.events after every turn (relay wakes us).
# The script is generated LOCALLY with values interpolated and pushed over stdin,
# so the pane command needs no fragile remote quoting.
cs_push_driver() {
  local cs=$1 id=$2 rdir=$3 sid=$4 harness=${5:-$(cs_harness)}
  case "$harness" in
    copilot) ;;
    *) echo "cs_push_driver: unsupported codespace harness '$harness' (only copilot)" >&2; return 1 ;;
  esac
  local script
  script=$(cat <<EOF
#!/usr/bin/env bash
set -uo pipefail
export GH_TOKEN="\${GITHUB_TOKEN:-}"
EV="\$HOME/.fm/$id.events"
INBOX="\$HOME/.fm/$id.inbox"
BRIEF="\$HOME/.fm/$id.brief.md"
SID="$sid"
mkdir -p "\$HOME/.fm"
cd "$rdir" 2>/dev/null || { printf 'blocked: repo dir %s missing\\n' "$rdir" >> "\$EV"; exit 1; }
: > "\$INBOX"
run() { copilot --allow-all "\$@" 2>&1; printf 'TURN-ENDED\\n' >> "\$EV"; }
run --session-id "\$SID" -p "\$(cat "\$BRIEF")"
while true; do
  if [ -s "\$INBOX" ]; then
    steer="\$(cat "\$INBOX")"; : > "\$INBOX"
    run --resume="\$SID" -p "\$steer"
  fi
  sleep 4
done
EOF
)
  printf '%s\n' "$script" | cs_ssh "$cs" -- "mkdir -p \$HOME/.fm && cat > \$HOME/.fm/$id.run.sh && chmod +x \$HOME/.fm/$id.run.sh && printf '%s\\n' \$HOME/.fm/$id.run.sh"
}

# cs_pane_launch_cmd <cs> <remote-run-path> [harness] - print the exact local
# command line for `tmux send-keys -l` that launches the crewmate driver inside
# the codespace over one SSH connection. <remote-run-path> is the ABSOLUTE path
# printed by cs_push_driver (no $HOME/tilde, so nothing needs shell expansion or
# escaping). The driver streams to the pane (peekable) and watches the inbox for
# steers (send-able). Only the codespace-native `copilot` harness is supported.
cs_pane_launch_cmd() {
  local cs=$1 rrun=$2 harness=${3:-$(cs_harness)}
  case "$harness" in
    copilot) ;;
    *)
      echo "cs_pane_launch_cmd: unsupported codespace harness '$harness' (only copilot)" >&2
      return 1
      ;;
  esac
  printf '%s' "[ -f '$FM_CS_TOKEN_FILE' ] && . '$FM_CS_TOKEN_FILE'; exec env -u GITHUB_TOKEN gh codespace ssh -c '$cs' -- \"bash -lc 'bash $rrun'\""
}

# cs_send_steer <cs> <id> <text> - append a one-line steer to the crewmate's
# remote inbox; the driver loop picks it up and resumes the copilot session.
# This is the codespace equivalent of `tmux send-keys` for a local crewmate.
cs_send_steer() {
  local cs=$1 id=$2 text=$3
  printf '%s\n' "$text" | cs_ssh "$cs" -- "mkdir -p \$HOME/.fm && cat >> \$HOME/.fm/$id.inbox"
}

# cs_pull_report <cs> <id> <local-dest> - copy a scout crewmate's report from the
# codespace (~/.fm/<id>.report.md) to a local path, creating the parent dir. The
# crewmate writes its report inside the codespace; firstmate needs it locally to
# relay findings and to satisfy teardown's scout-report gate. Best-effort: prints
# the dest and returns 0 on success, returns 1 (quietly) when the remote report
# is absent so callers can decide how to handle a missing report.
cs_pull_report() {
  local cs=$1 id=$2 dest=$3 content
  content=$(cs_ssh "$cs" -- "cat \$HOME/.fm/$id.report.md 2>/dev/null" 2>/dev/null || true)
  [ -n "$content" ] || return 1
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
  printf '%s\n' "$dest"
}
