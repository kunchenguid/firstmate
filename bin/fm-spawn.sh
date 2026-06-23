#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse worktree, or a secondmate in
# its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [harness|launch-command] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [harness|launch-command] --secondmate
#   With no harness arg, the harness comes from fm-harness.sh crew (config/crew-harness,
#   falling back to firstmate's own harness). A bare adapter name (claude|codex|
#   opencode|pi|cursor) overrides it for this spawn. A non-flag string containing whitespace
#   is treated as a RAW launch command - the escape hatch for verifying new adapters.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md section 7); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; a shared --scout applies to every pair. The loop lives here, in bash,
#   so callers never hand-write a multi-task shell loop (the tool shell is zsh, which does
#   not word-split unquoted $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<session:window> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-codespace-lib.sh
. "$SCRIPT_DIR/fm-codespace-lib.sh"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    *) POS+=("$a") ;;
  esac
done

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  rc=0
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|cursor)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in AGENTS.md section 4.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see AGENTS.md section 4). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode --prompt "$(cat __BRIEF__)"' ;;
    cursor)
      # cursor-agent has no turn-end hook mechanism (no notify flag, no extension
      # loader): turn-end is surfaced by the busy-signature + pane-staleness +
      # status writes, so the launch carries no __TURNEND__/__PIEXT__ wiring.
      printf '%s' 'cursor-agent --force "$(cat __BRIEF__)"'
      ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi -e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    *) return 1 ;;
  esac
}

# Build the remote launch command for a codespace crewmate. Unlike launch_template
# (which assumes the binary is on PATH under a fixed name), this resolves the real
# installed command in the codespace at launch time. $1 is the harness, $2 is the
# ALREADY shell-quoted remote brief path. Only cursor needs special handling: its
# CLI is installed as 'cursor-agent' on personal images but as plain 'agent'
# ($HOME/.local/bin/agent) in company-managed Codespaces, so launch whichever
# exists. All other harnesses reuse launch_template verbatim.
codespace_launch_command() {
  local harness=$1 brief_q=$2 tmpl
  case "$harness" in
    cursor)
      # shellcheck disable=SC2016  # $_fmcur expands in the remote shell, not here.
      printf '%s' '_fmcur=cursor-agent; command -v cursor-agent >/dev/null 2>&1 || _fmcur=agent; "$_fmcur" --force "$(cat '"$brief_q"')"'
      ;;
    *)
      tmpl=$(launch_template "$harness" secondmate) || return 1
      printf '%s' "${tmpl//__BRIEF__/$brief_q}"
      ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from config/crew-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS=""
  WT=""
  BRIEF="$DATA/$ID/brief.md"
  PROJ_NAME=$(basename "$PROJ")
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md sections 6-7).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode. Mode is resolved BEFORE the local clone is
# required, because codespace mode has no local clone at all.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
  if [ "$MODE" != codespace ]; then
    PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
    PROJ_NAME=$(basename "$PROJ_ABS")
  fi
fi

# Codespace spawn path: no local clone. owner/repo comes from the registry line;
# discover the project's single Available codespace, ensure prerequisites (treehouse
# + remote state dir), lease a worktree inside it (non-interactive, capturing its
# path for teardown safety), copy the brief in, and launch the configured harness
# over SSH in a tmux window. The harness defaults to claude and is taken from the
# registry bracket ([codespace owner/repo <harness>]); it must already be installed
# in the codespace. Status is polled via a generated check.sh.
if [ "$MODE" = codespace ] && [ "$KIND" != secondmate ]; then
  CODESPACE_REMOTE_STATE="${FM_CODESPACE_REMOTE_STATE:-~/firstmate-state}"

  # Reusable remote env prefix, prepended to EVERY non-interactive SSH command we
  # run in the codespace (bootstrap, lease, launch). Defined once in
  # bin/fm-codespace-lib.sh so fm-teardown.sh's lease-release uses the identical
  # string; see that file for the full rationale (login-profile sourcing, PATH
  # force-add, guarded token injection).
  _CS_ENV_PREFIX="$FM_CS_ENV_PREFIX"

  # Codespace crewmate harness comes from the project's registry bracket
  # ([codespace owner/repo <harness>]); defaults to claude. The named agent must
  # already be installed in the codespace; firstmate only launches it over SSH.
  CS_HARNESS=$("$FM_ROOT/bin/fm-project-mode.sh" --codespace-harness "$PROJ_NAME" 2>/dev/null || echo claude)
  [ -n "$CS_HARNESS" ] || CS_HARNESS=claude
  # Validate the harness is supported (and surface a clear error if not). The actual
  # remote launch string is built by codespace_launch_command below, which resolves
  # the real installed binary at launch time (cursor in particular).
  launch_template "$CS_HARNESS" secondmate >/dev/null || {
    echo "error: no launch template for codespace harness '$CS_HARNESS' (from $PROJ_NAME's registry line); supported: claude, codex, opencode, pi, cursor" >&2
    exit 1
  }

  # owner/repo comes from the registry ([codespace owner/repo]); no clone required.
  _CS_SLUG=$("$FM_ROOT/bin/fm-project-mode.sh" --slug "$PROJ_NAME" 2>/dev/null || true)
  if [ -z "$_CS_SLUG" ]; then
    echo "error: codespace project $PROJ_NAME has no owner/repo in its registry line; expected '- $PROJ_NAME [codespace owner/repo] - ...'" >&2
    exit 1
  fi

  # Discover Available codespaces for this repo (exactly one required).
  _CS_LINES=$(gh codespace list --repo "$_CS_SLUG" --json name,state \
    --jq '.[] | select(.state == "Available") | .name' 2>/dev/null || true)
  if [ -z "$_CS_LINES" ]; then
    echo "error: no Available codespace found for $_CS_SLUG (run: gh codespace list --repo $_CS_SLUG)" >&2
    exit 1
  fi
  _CS_NAME=$(printf '%s\n' "$_CS_LINES" | head -1)
  _cs_count=$(printf '%s\n' "$_CS_LINES" | wc -l | tr -d '[:space:]')
  if [ "$_cs_count" -gt 1 ]; then
    echo "error: $_cs_count Available codespaces found for $_CS_SLUG; expected exactly one (run: gh codespace list --repo $_CS_SLUG)" >&2
    exit 1
  fi

  # Poll for shell-ready: a freshly Available codespace can still refuse SSH briefly.
  _cs_ready=
  for _ in $(seq 1 "${FM_CODESPACE_SSH_RETRIES:-30}"); do
    if gh codespace ssh -c "$_CS_NAME" -- true >/dev/null 2>&1; then _cs_ready=1; break; fi
    sleep 2
  done
  if [ -z "$_cs_ready" ]; then
    echo "error: codespace $_CS_NAME did not accept SSH within the retry window" >&2
    exit 1
  fi

  # Ensure codespace prerequisites BEFORE leasing a worktree. Company-managed
  # codespaces run an older base image and cannot run personal dotfiles (org
  # policy), so do not assume setup ran there: idempotently mkdir the remote state
  # dir and make treehouse runnable. The harness (cursor-agent/agent etc.) is
  # assumed already installed.
  #
  # The gate verifies treehouse actually EXECUTES (`treehouse --version` exits 0),
  # not merely that a binary is on PATH. The prebuilt binary can install yet crash
  # at runtime - on Debian 11 (glibc 2.31) the prebuilt v1.8.0 fails with
  # "GLIBC_2.34 not found" - a false green that `command -v` would pass and that
  # then breaks at the lease step. When the prebuilt binary does not run, fall back
  # to building from source with `go install`, which links against the codespace's
  # own glibc and includes --lease (Go is present at /usr/local/go/bin; the env
  # prefix puts it on PATH). The env prefix is re-sourced after each install so a
  # freshly-installed treehouse (in ~/.local/bin) is visible to the same gate,
  # matching what the later 'treehouse get' SSH session will see. The final
  # `treehouse --version` is the gate: if it fails, treehouse could not be made
  # runnable by either route and spawn aborts with the one-time manual command.
  _CS_TH_INSTALL='curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh'
  # shellcheck disable=SC2016  # $HOME expands in the remote shell, not here.
  _CS_TH_SRC='GOBIN="$HOME/.local/bin" go install github.com/kunchenguid/treehouse@latest'
  _CS_TH_RUNS='treehouse --version >/dev/null 2>&1'
  _CS_BOOTSTRAP="${_CS_ENV_PREFIX} mkdir -p $CODESPACE_REMOTE_STATE; "
  _CS_BOOTSTRAP="${_CS_BOOTSTRAP}if ! ${_CS_TH_RUNS}; then ${_CS_TH_INSTALL} || true; ${_CS_ENV_PREFIX} fi; "
  _CS_BOOTSTRAP="${_CS_BOOTSTRAP}if ! ${_CS_TH_RUNS}; then mkdir -p \"\$HOME/.local/bin\"; ${_CS_TH_SRC} || true; ${_CS_ENV_PREFIX} fi; "
  _CS_BOOTSTRAP="${_CS_BOOTSTRAP}${_CS_TH_RUNS}"
  if ! gh codespace ssh -c "$_CS_NAME" -- "$_CS_BOOTSTRAP" >/dev/null 2>&1; then
    echo "error: treehouse is not available (and could not be built from source) in codespace $_CS_NAME." >&2
    echo "       Run this once in the codespace, then retry: $_CS_TH_INSTALL" >&2
    echo "       (or build from source with /usr/local/go/bin on PATH: $_CS_TH_SRC)" >&2
    exit 1
  fi

  # 'treehouse get' operates on the current git repo (it runs 'git rev-parse
  # --show-toplevel' against cwd), so the lease MUST run from inside the codespace's
  # repo checkout. A 'gh codespace ssh -- <cmd>' shell starts in the session's HOME,
  # not the checkout, so an uncd'd lease fails with "not in a git repository". The
  # codespace checks the repo out at /workspaces/<repo-name> (basename of the
  # owner/repo slug); if that is not a git repo (a non-standard checkout dir), fall
  # back to the single git checkout under /workspaces/*, and if none is found fail
  # cleanly here rather than letting treehouse emit its cryptic error. The escaped
  # $VARs below expand in the remote shell, not locally. This snippet is prepended to
  # every lease attempt (after the env prefix, before treehouse).
  _CS_REPO_BASENAME=$(basename "$_CS_SLUG")
  _CS_CD_REPO="_fmdir=$(shell_quote "/workspaces/$_CS_REPO_BASENAME"); \
if ! git -C \"\$_fmdir\" rev-parse --show-toplevel >/dev/null 2>&1; then \
_fmdir=; for _c in /workspaces/*/; do \
if git -C \"\$_c\" rev-parse --show-toplevel >/dev/null 2>&1; then _fmdir=\${_c%/}; break; fi; \
done; fi; \
if [ -z \"\$_fmdir\" ]; then echo 'fm-spawn: no git checkout found under /workspaces in this codespace' >&2; exit 3; fi; \
cd \"\$_fmdir\" || exit 3;"

  # Poll for worktree-ready: lease a worktree (non-interactive; prints only its path,
  # banners to stderr). The lease is durable, so the slot survives until teardown
  # releases it with 'treehouse return', and its path is recorded for teardown safety.
  # Retry relies on 'treehouse get --lease' being idempotent per --lease-holder (the
  # same holder fm-$ID is returned the same worktree on repeat), so a parse miss on a
  # banner-only line re-acquires the same lease rather than leaking a fresh one.
  _CS_WT=
  for _ in $(seq 1 "${FM_CODESPACE_WT_RETRIES:-10}"); do
    _CS_WT=$(gh codespace ssh -c "$_CS_NAME" -- "${_CS_ENV_PREFIX} ${_CS_CD_REPO} treehouse get --lease --lease-holder fm-$ID" 2>/dev/null | tail -1 | tr -d '\r')
    [ -n "$_CS_WT" ] && break
    sleep 2
  done
  if [ -z "$_CS_WT" ]; then
    echo "error: could not lease a treehouse worktree in codespace $_CS_NAME" >&2
    echo "       (the repo must be checked out under /workspaces; expected /workspaces/$_CS_REPO_BASENAME)" >&2
    exit 1
  fi

  # Record the lease-release-critical fields the instant the lease exists, BEFORE
  # the unguarded brief copy / window creation / send-keys below. Under set -eu a
  # failure in any of those would otherwise abort with the durable lease held and
  # no meta for teardown to find and release. The complete meta (with window=)
  # overwrites this once the window exists.
  mkdir -p "$STATE"
  {
    echo "window="
    echo "worktree="
    echo "project="
    echo "harness=$CS_HARNESS"
    echo "kind=$KIND"
    echo "mode=codespace"
    echo "yolo=$YOLO"
    echo "codespace=$_CS_NAME"
    echo "remote_worktree=$_CS_WT"
    echo "remote_state=$CODESPACE_REMOTE_STATE"
  } > "$STATE/$ID.meta"

  # Copy brief into the codespace before opening the window.
  gh codespace cp "$BRIEF" "remote:/tmp/$ID-brief.md" -c "$_CS_NAME"

  if [ -n "${TMUX:-}" ]; then
    SES=$(tmux display-message -p '#S')
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    SES=firstmate
  fi
  W="fm-$ID"
  T="$SES:$W"
  if tmux list-windows -t "$SES" -F '#{window_name}' | grep -qx "$W"; then
    echo "error: window $T already exists" >&2
    exit 1
  fi
  tmux new-window -d -t "$SES" -n "$W" -c "$FM_HOME"

  # One self-contained line: SSH with a forced PTY (-t), source the env prefix
  # (login profiles + PATH + git credentials, so the harness binary resolves and a
  # ship task can commit/push), cd into the leased worktree, launch the configured
  # harness. A single command avoids inter-step timing; the $(cat ...) in the launch
  # command expands on the remote. The launch command comes from
  # codespace_launch_command (the turn-end-free variant, since codespace status is
  # mirrored via check.sh, not a local turn-end hook) and resolves the real harness
  # binary in the codespace - notably cursor, installed as 'cursor-agent' or plain
  # 'agent'. No 'exec' prefix: some templates carry a leading VAR=val env assignment
  # (opencode), which 'exec' would treat as the program name. The remote paths are
  # quoted for the remote shell, then the whole remote command is quoted again for
  # the local pane shell.
  _CS_LAUNCH=$(codespace_launch_command "$CS_HARNESS" "$(shell_quote "/tmp/$ID-brief.md")") || {
    echo "error: no launch command for codespace harness '$CS_HARNESS'" >&2
    exit 1
  }
  _CS_REMOTE_CMD="${_CS_ENV_PREFIX} cd $(shell_quote "$_CS_WT") && $_CS_LAUNCH"
  _CS_PANE_LINE="gh codespace ssh -c $(shell_quote "$_CS_NAME") -- -t $(shell_quote "$_CS_REMOTE_CMD")"
  tmux send-keys -t "$T" -l "$_CS_PANE_LINE"
  sleep 0.3
  tmux send-keys -t "$T" Enter

  mkdir -p "$STATE"
  {
    echo "window=$T"
    echo "worktree="
    echo "project="
    echo "harness=$CS_HARNESS"
    echo "kind=$KIND"
    echo "mode=codespace"
    echo "yolo=$YOLO"
    echo "codespace=$_CS_NAME"
    echo "remote_worktree=$_CS_WT"
    echo "remote_state=$CODESPACE_REMOTE_STATE"
  } > "$STATE/$ID.meta"

  # Poll script: pull the last status line from the remote state file and MIRROR a
  # new line into the local state/<id>.status. The perch dashboard reads the last
  # line of {FM_HOME}/state/<id>.status, so mirroring is what makes a codespace
  # task's status badge live instead of blank/stale. It also unifies codespace
  # status with local crewmates: the watcher's signal scan hashes state/*.status,
  # so the mirror's append is what wakes firstmate, the same path a local crewmate
  # uses.
  #
  # Watcher interaction (deliberate): we append ONLY when the remote line differs
  # from the last one we mirrored (recorded in the sibling check.last), so the
  # locally-hashed status file changes exactly once per distinct line - bounding
  # wakes and preventing a wake loop (the local append never touches the remote
  # file, so it cannot re-trigger this poll). We print NOTHING to stdout: the
  # signal wake from the status append is the single wake; emitting the line too
  # would add a redundant 'check:' wake for the same status (a spurious double-wake).
  _CS_NAME_Q=$(shell_quote "$_CS_NAME")
  cat > "$STATE/$ID.check.sh" <<CHECKEOF
#!/usr/bin/env bash
last_file='$STATE/$ID.check.last'
status_file='$STATE/$ID.status'
out=\$(gh codespace ssh -c ${_CS_NAME_Q} -- "cat ${CODESPACE_REMOTE_STATE}/${ID}.status 2>/dev/null | tail -1" 2>/dev/null)
[ -n "\$out" ] || exit 0
[ "\$out" = "\$(cat "\$last_file" 2>/dev/null)" ] && exit 0
printf '%s\n' "\$out" > "\$last_file"
printf '%s\n' "\$out" >> "\$status_file"
CHECKEOF
  chmod +x "$STATE/$ID.check.sh"

  echo "spawned $ID harness=$CS_HARNESS kind=$KIND mode=codespace yolo=$YOLO window=$T worktree=$_CS_WT codespace=$_CS_NAME"
  exit 0
fi

# Same session when firstmate already runs inside tmux; dedicated session otherwise.
if [ -n "${TMUX:-}" ]; then
  SES=$(tmux display-message -p '#S')
else
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
  SES=firstmate
fi

W="fm-$ID"
T="$SES:$W"
if tmux list-windows -t "$SES" -F '#{window_name}' | grep -qx "$W"; then
  echo "error: window $T already exists" >&2
  exit 1
fi

tmux new-window -d -t "$SES" -n "$W" -c "$PROJ_ABS"
if [ "$KIND" != secondmate ]; then
  tmux send-keys -t "$T" 'treehouse get' Enter

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  for _ in $(seq 1 60); do
    p=$(tmux display-message -p -t "$T" '#{pane_current_path}' 2>/dev/null || true)
    if [ -n "$p" ] && [ "$p" != "$PROJ_ABS" ]; then
      WT="$p"
      break
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
    exit 1
  fi
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$STATE/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    cursor*)
      # cursor-agent: no turn-end hook (no notify flag, no extension loader).
      # Supervision falls back to busy-signature + pane staleness + status writes.
      ;;
  esac
fi

mkdir -p "$STATE"
{
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
tmux send-keys -t "$T" -l "$LAUNCH"
sleep 0.3
tmux send-keys -t "$T" Enter

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT"
