#!/usr/bin/env bash
# Check the Linux AI-workspace toolchain for stable upgrades and, in an
# interactive terminal, offer each safe upgrade separately.
#
# This command is advisory unless the operator answers yes to an individual
# prompt. It never upgrades in a non-interactive shell, never batches consent,
# and never edits GitHub Actions: checkout major-version drift is reported as
# repository PR work. Lifecycle-sensitive runtimes are deferred while their
# processes/sessions are active. Firstmate updates use fm-update.sh's guarded,
# fast-forward-only path and run last so this script cannot change underneath
# the remaining checks.
#
# Linux package policy:
#   - Debian/Ubuntu packages are compared with the locally cached APT candidate
#     and upgraded with apt-get. This script does not refresh package indexes.
#   - NVM-managed Node stays on its installed major line; patch/minor upgrades
#     reinstall that version's global packages and update the default alias.
#   - Self-updating CLIs keep their upstream guarded update commands.
#   - macOS-only cmux and moshi-hook checks are intentionally absent.
#
# Usage: fm-deps.sh [--check]
#   --check  Check and report only; do not prompt.
#
# Test seams:
#   FM_DEPS_INTERACTIVE=1|0 overrides terminal detection.
#   FM_ROOT_OVERRIDE points at an isolated Firstmate fixture.
#   FM_DEPS_HERDR_MANIFEST_URL and FM_DEPS_NODE_INDEX_URL override release data.
#   FM_DEPS_NVM_DIR points at an isolated NVM fixture.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
CHECK_ONLY=0
FAILURES=0
UPDATES=0
DEFERRED=0
AVAILABLE=0
HERDR_MANIFEST_URL=${FM_DEPS_HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}
NODE_INDEX_URL=${FM_DEPS_NODE_INDEX_URL:-https://nodejs.org/dist/index.json}

usage() {
  echo "usage: fm-deps.sh [--check]" >&2
}

case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

is_interactive() {
  case "${FM_DEPS_INTERACTIVE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -t 0 ] && [ -t 1 ]
}

first_version() {
  sed -nE 's/^[^0-9]*[vV]?([0-9]+([.][0-9A-Za-z]+)+).*/\1/p' | head -n 1
}

normalize_version() {
  sed -E 's/^[^0-9]*//; s/[^0-9A-Za-z.+:~-].*$//'
}

version_is_older() {
  local installed latest
  installed=$(printf '%s\n' "$1" | normalize_version)
  latest=$(printf '%s\n' "$2" | normalize_version)
  command -v dpkg >/dev/null 2>&1 || return 1
  dpkg --compare-versions "$installed" lt "$latest"
}

command_version() {
  local command_name=$1 out
  command -v "$command_name" >/dev/null 2>&1 || return 1
  out=$("$command_name" --version 2>&1) || return 1
  printf '%s\n' "$out" | first_version
}

apt_package_versions() {
  local package=$1 installed candidate
  command -v dpkg-query >/dev/null 2>&1 || return 1
  command -v apt-cache >/dev/null 2>&1 || return 1
  installed=$(dpkg-query -W -f='${Status}\t${Version}\n' "$package" 2>/dev/null \
    | awk -F '\t' '$1 == "install ok installed" {print $2; exit}')
  candidate=$(apt-cache policy "$package" 2>/dev/null \
    | sed -nE 's/^[[:space:]]*Candidate:[[:space:]]*([^[:space:]]+).*/\1/p' \
    | head -n 1)
  [ "$candidate" != '(none)' ] || candidate=""
  printf '%s\t%s\n' "$installed" "$candidate"
}

npm_latest() {
  command -v npm >/dev/null 2>&1 || return 1
  npm view "$1" version 2>/dev/null | head -n 1
}

release_latest() {
  local repo=$1 out
  command -v gh-axi >/dev/null 2>&1 || return 1
  out=$(gh-axi release list --repo "$repo" --exclude-drafts --exclude-pre-releases --limit 1 2>/dev/null) || return 1
  printf '%s\n' "$out" \
    | sed -nE 's/^[[:space:]]+([^,[:space:]]+),.*/\1/p' \
    | head -n 1 \
    | normalize_version
}

json_url() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL --connect-timeout 10 --max-time 30 "$1"
}

herdr_latest() {
  command -v jq >/dev/null 2>&1 || return 1
  json_url "$HERDR_MANIFEST_URL" | jq -er '.version | select(type == "string" and length > 0)' 2>/dev/null
}

node_latest_same_major() {
  local installed=$1 major
  command -v jq >/dev/null 2>&1 || return 1
  major=${installed#v}
  major=${major%%.*}
  json_url "$NODE_INDEX_URL" | jq -er --arg major "$major" '
    first(
      .[]
      | select(.lts != false)
      | .version | ltrimstr("v")
      | select(split(".")[0] == $major)
    )
  ' 2>/dev/null
}

prompt_yes() {
  local label=$1 reply
  [ "$CHECK_ONLY" -eq 0 ] && is_interactive || return 1
  printf 'Upgrade %s now? [y/N] ' "$label"
  IFS= read -r reply || reply=""
  case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

process_active() {
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -x "$1" >/dev/null 2>&1
}

quiet_window_blocker() {
  case "$1" in
    codex)
      process_active codex && { printf 'Codex process is active; close Codex and rerun'; return 0; }
      ;;
    herdr)
      if command -v herdr >/dev/null 2>&1 \
        && herdr session list --json 2>/dev/null | grep -Eq '"running"[[:space:]]*:[[:space:]]*true'; then
        printf 'Herdr session is running; finish/stop Herdr-backed work and rerun'
        return 0
      fi
      ;;
    opencode)
      process_active opencode && { printf 'OpenCode process is active; close it and rerun'; return 0; }
      ;;
    tmux)
      if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
        printf 'tmux session is running; finish tmux-backed work and rerun'
        return 0
      fi
      ;;
    node)
      process_active node && { printf 'Node process is active; stop shared Node workloads and rerun'; return 0; }
      ;;
  esac
  return 1
}

run_apt_upgrade() {
  local package=$1
  if [ "$(id -u)" -eq 0 ]; then
    apt-get install --only-upgrade "$package"
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get install --only-upgrade "$package"
  else
    printf 'sudo is required to upgrade APT package %s\n' "$package" >&2
    return 1
  fi
}

load_nvm() {
  local nvm_dir
  nvm_dir=${FM_DEPS_NVM_DIR:-${NVM_DIR:-$HOME/.nvm}}
  [ -s "$nvm_dir/nvm.sh" ] || return 1
  # shellcheck source=/dev/null
  . "$nvm_dir/nvm.sh"
  command -v nvm >/dev/null 2>&1
}

run_upgrade() {
  local id=$1 installed=${2:-} latest=${3:-} before after
  case "$id" in
    codex) codex update ;;
    github-cli) run_apt_upgrade gh ;;
    gh-axi) npm install -g gh-axi@latest && gh-axi setup hooks ;;
    chrome-devtools-axi) npm install -g chrome-devtools-axi@latest && chrome-devtools-axi setup hooks ;;
    lavish-axi) npm install -g lavish-axi@latest && lavish-axi setup hooks ;;
    quota-axi) npm install -g quota-axi@latest ;;
    tasks-axi) npm install -g tasks-axi@latest ;;
    treehouse) treehouse update ;;
    no-mistakes) no-mistakes update ;;
    herdr) herdr update ;;
    opencode) opencode upgrade --method curl ;;
    tmux) run_apt_upgrade tmux ;;
    node)
      load_nvm || { printf 'NVM is required to upgrade Node safely\n' >&2; return 1; }
      nvm install "$latest" --reinstall-packages-from="$installed" \
        && nvm alias default "$latest"
      ;;
    github-actions) return 1 ;;
    firstmate)
      before=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) || return 1
      "$FM_ROOT/bin/fm-update.sh" || return 1
      after=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) || return 1
      [ "$after" != "$before" ]
      ;;
    *) return 1 ;;
  esac
}

offer_update() {
  local id=$1 label=$2 installed=$3 latest=$4 class=$5 blocker=""
  if ! version_is_older "$installed" "$latest"; then
    printf 'OK: %s %s\n' "$label" "$installed"
    return 0
  fi
  AVAILABLE=$((AVAILABLE + 1))
  printf 'UPDATE: %s %s -> %s' "$label" "$installed" "$latest"
  [ "$class" = quiet ] && printf ' [quiet window]'
  printf '\n'

  if [ "$class" = quiet ] && blocker=$(quiet_window_blocker "$id"); then
    printf 'DEFER: %s - %s\n' "$label" "$blocker"
    DEFERRED=$((DEFERRED + 1))
    return 0
  fi
  if prompt_yes "$label"; then
    if run_upgrade "$id" "$installed" "$latest"; then
      printf 'UPGRADED: %s\n' "$label"
      UPDATES=$((UPDATES + 1))
    else
      printf 'FAILED: %s upgrade command failed\n' "$label" >&2
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

check_npm_tool() {
  local id=$1 label=$2 command_name=$3 installed latest
  if ! installed=$(command_version "$command_name") || [ -z "$installed" ]; then
    printf 'MISSING: %s (%s)\n' "$label" "$command_name"
    return 0
  fi
  if ! latest=$(npm_latest "$id") || [ -z "$latest" ]; then
    printf 'UNKNOWN: %s %s; npm registry check failed\n' "$label" "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  offer_update "$id" "$label" "$installed" "$latest" normal
}

check_apt_package() {
  local id=$1 label=$2 package=$3 class=$4 versions installed latest
  if ! versions=$(apt_package_versions "$package") || [[ "$versions" != *$'\t'* ]]; then
    printf 'UNKNOWN: %s; APT metadata check failed\n' "$label"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  installed=${versions%%$'\t'*}
  latest=${versions#*$'\t'}
  if [ -z "$installed" ]; then
    printf 'MISSING: %s (sudo apt-get install %s)\n' "$label" "$package"
  elif [ -z "$latest" ]; then
    printf 'UNKNOWN: %s %s; APT candidate check failed\n' "$label" "$installed"
    FAILURES=$((FAILURES + 1))
  else
    offer_update "$id" "$label" "$installed" "$latest" "$class"
  fi
}

check_release_tool() {
  local id=$1 label=$2 command_name=$3 repo=$4 class=$5 installed latest
  if ! installed=$(command_version "$command_name") || [ -z "$installed" ]; then
    printf 'MISSING: %s (%s)\n' "$label" "$command_name"
    return 0
  fi
  if ! latest=$(release_latest "$repo") || [ -z "$latest" ]; then
    printf 'UNKNOWN: %s %s; stable release check failed\n' "$label" "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  offer_update "$id" "$label" "$installed" "$latest" "$class"
}

check_herdr() {
  local installed latest
  if ! installed=$(command_version herdr) || [ -z "$installed" ]; then
    printf 'MISSING: Herdr (instructions: https://herdr.dev)\n'
    return 0
  fi
  if ! latest=$(herdr_latest) || [ -z "$latest" ]; then
    printf 'UNKNOWN: Herdr %s; stable manifest check failed\n' "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  offer_update herdr Herdr "$installed" "$latest" quiet
}

check_node() {
  local installed latest nvm_dir
  if ! installed=$(command_version node) || [ -z "$installed" ]; then
    printf 'MISSING: Node (install with NVM)\n'
    return 0
  fi
  nvm_dir=${FM_DEPS_NVM_DIR:-${NVM_DIR:-$HOME/.nvm}}
  if [ ! -s "$nvm_dir/nvm.sh" ]; then
    printf 'MANUAL: Node %s is not NVM-managed; update it with its owning package manager\n' "$installed"
    return 0
  fi
  if ! latest=$(node_latest_same_major "$installed") || [ -z "$latest" ]; then
    printf 'UNKNOWN: Node %s; same-major LTS release check failed\n' "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  offer_update node "Node ${installed%%.*}" "$installed" "$latest" quiet
}

check_zellij() {
  local installed latest
  if ! installed=$(command_version zellij) || [ -z "$installed" ]; then
    printf 'MISSING: Zellij (optional; install from https://zellij.dev)\n'
    return 0
  fi
  if ! latest=$(release_latest zellij-org/zellij) || [ -z "$latest" ]; then
    printf 'UNKNOWN: Zellij %s; stable release check failed\n' "$installed"
    FAILURES=$((FAILURES + 1))
  elif version_is_older "$installed" "$latest"; then
    printf 'MANUAL: Zellij %s -> %s; update it with its owning package manager\n' "$installed" "$latest"
    AVAILABLE=$((AVAILABLE + 1))
  else
    printf 'OK: Zellij %s\n' "$installed"
  fi
}

check_shellcheck_pin() {
  local installed required
  required=$("$FM_ROOT/bin/fm-lint.sh" --required-version 2>/dev/null || printf '0.11.0')
  if ! installed=$(command_version shellcheck) || [ -z "$installed" ]; then
    printf 'MISSING: ShellCheck (repository requires %s)\n' "$required"
  elif [ "$installed" = "$required" ]; then
    printf 'OK: ShellCheck %s (repository pin)\n' "$installed"
  else
    printf 'PIN_MISMATCH: ShellCheck %s; repository requires %s (not auto-upgraded)\n' "$installed" "$required"
  fi
}

check_github_actions() {
  local latest major pins
  if ! latest=$(release_latest actions/checkout) || [ -z "$latest" ]; then
    printf 'UNKNOWN: actions/checkout; stable release check failed\n'
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  major=${latest%%.*}
  pins=$(grep -Rho 'actions/checkout@v[0-9][0-9]*' "$FM_ROOT/.github/workflows" 2>/dev/null \
    | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  if [ -z "$pins" ]; then
    printf 'OK: actions/checkout has no workflow call sites\n'
  elif printf '%s\n' "$pins" | grep -q "actions/checkout@v$major"; then
    printf 'OK: actions/checkout %s (latest stable %s)\n' "$pins" "$latest"
  else
    printf 'REPO_UPDATE: %s -> actions/checkout@v%s (latest %s); create a normal repository PR\n' "$pins" "$major" "$latest"
    AVAILABLE=$((AVAILABLE + 1))
  fi
}

check_firstmate() {
  local branch local_sha remote_sha
  branch=$(git -C "$FM_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -n "$branch" ] || branch=main
  if ! local_sha=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null); then
    printf 'UNKNOWN: Firstmate checkout is not a Git repository\n'
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  remote_sha=$(git -C "$FM_ROOT" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR == 1 {print $1}')
  if [ -z "$remote_sha" ]; then
    printf 'UNKNOWN: Firstmate %s; origin/%s check failed\n' "$(printf '%.12s' "$local_sha")" "$branch"
    FAILURES=$((FAILURES + 1))
  elif [ "$local_sha" = "$remote_sha" ]; then
    printf 'OK: Firstmate %s\n' "$(printf '%.12s' "$local_sha")"
  else
    printf 'UPDATE: Firstmate %s -> origin/%s %s [guarded fast-forward]\n' \
      "$(printf '%.12s' "$local_sha")" "$branch" "$(printf '%.12s' "$remote_sha")"
    AVAILABLE=$((AVAILABLE + 1))
    if [ -n "$(git -C "$FM_ROOT" status --porcelain 2>/dev/null)" ]; then
      printf 'DEFER: Firstmate - working tree is not clean; commit or remove local changes, then rerun\n'
      DEFERRED=$((DEFERRED + 1))
      return 0
    fi
    if [ "$(git -C "$FM_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)" != "$branch" ]; then
      printf 'DEFER: Firstmate - checkout is not on %s; switch back safely, then rerun\n' "$branch"
      DEFERRED=$((DEFERRED + 1))
      return 0
    fi
    if prompt_yes Firstmate; then
      if run_upgrade firstmate; then
        printf 'UPGRADED: Firstmate\n'
        UPDATES=$((UPDATES + 1))
      else
        printf 'FAILED: Firstmate guarded update failed or was skipped\n' >&2
        FAILURES=$((FAILURES + 1))
      fi
    fi
  fi
}

if [ "${FM_DEPS_SOURCE_ONLY:-0}" = 1 ]; then
  # shellcheck disable=SC2317 # exit is the direct-execution fallback; sourcing uses return.
  return 0 2>/dev/null || exit 0
fi

if [ "$(uname -s)" != Linux ]; then
  printf 'fm-deps.sh: this variant supports Linux only\n' >&2
  exit 1
fi
for required_command in dpkg dpkg-query apt-cache; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'fm-deps.sh: Debian/Ubuntu command %s is required\n' "$required_command" >&2
    exit 1
  fi
done

if [ "$CHECK_ONLY" -eq 0 ] && ! is_interactive; then
  printf 'INFO: non-interactive shell detected; running checks without upgrade prompts\n'
fi

printf 'AI workspace dependency check (Linux)\n'
printf '%s\n' '----------------------------------------'

check_release_tool codex Codex codex openai/codex quiet
check_apt_package github-cli 'GitHub CLI' gh normal
check_npm_tool gh-axi gh-axi gh-axi
check_npm_tool chrome-devtools-axi chrome-devtools-axi chrome-devtools-axi
check_npm_tool lavish-axi lavish-axi lavish-axi
check_npm_tool quota-axi quota-axi quota-axi
check_npm_tool tasks-axi tasks-axi tasks-axi
check_release_tool no-mistakes no-mistakes no-mistakes kunchenguid/no-mistakes normal
check_release_tool treehouse Treehouse treehouse kunchenguid/treehouse normal
check_herdr
check_release_tool opencode OpenCode opencode anomalyco/opencode quiet
check_apt_package tmux tmux tmux quiet
check_node
check_zellij
check_shellcheck_pin
check_github_actions

# Self-update last: a successful fast-forward may replace this script.
check_firstmate

printf '%s\n' '----------------------------------------'
printf 'SUMMARY: %s update(s) available; %s completed; %s deferred; %s check/upgrade failure(s)\n' \
  "$AVAILABLE" "$UPDATES" "$DEFERRED" "$FAILURES"
[ "$FAILURES" -eq 0 ]
