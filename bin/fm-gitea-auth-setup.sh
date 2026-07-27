#!/usr/bin/env bash
# Wire HTTPS Gitea auth through config/gitea-token + a git credential helper,
# and strip any embedded userinfo credentials from project remote URLs.
#
# Usage:
#   fm-gitea-auth-setup.sh
#     Configure the helper for the Gitea host (global git config, host-scoped),
#     ensure config/gitea-username exists when discoverable, and sanitize every
#     clone under this home's projects/.
#   fm-gitea-auth-setup.sh --repo <path>
#     Same helper install, sanitize only <path>.
#   fm-gitea-auth-setup.sh --print-helper
#     Print the credential.helper value that would be installed and exit.
#   fm-gitea-auth-setup.sh --dry-run
#     Report planned changes without writing git config or rewriting remotes.
#
# Requires config/gitea-token (mode 600) under the effective home. Username from
# FM_GITEA_USERNAME, config/gitea-username, or default apinant when the token
# file is present (override with config/gitea-username). Host from FM_GITEA_HOST,
# config/gitea-host, or private-git.ocin.cloud.
#
# Does NOT rotate the token. Token creation on this Gitea requires a password
# session; print the captain-facing rotate steps when --check-rotate is passed
# and the current token cannot mint a replacement.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-git-remote-sanitize-lib.sh
. "$SCRIPT_DIR/fm-git-remote-sanitize-lib.sh"

DRY_RUN=0
PRINT_HELPER=0
CHECK_ROTATE=0
REPO=

usage() {
  cat <<'EOF' >&2
usage: fm-gitea-auth-setup.sh [--dry-run] [--repo <path>] [--print-helper] [--check-rotate]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --print-helper) PRINT_HELPER=1; shift ;;
    --check-rotate) CHECK_ROTATE=1; shift ;;
    --repo)
      [ $# -ge 2 ] || { usage; exit 1; }
      REPO=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

HOST=${FM_GITEA_HOST:-}
if [ -z "$HOST" ] && [ -f "$CONFIG/gitea-host" ]; then
  HOST=$(sed -n '1s/[[:space:]]*$//p' "$CONFIG/gitea-host" 2>/dev/null || true)
fi
[ -n "$HOST" ] || HOST=private-git.ocin.cloud

HELPER_PATH=$SCRIPT_DIR/fm-gitea-credential.sh
STABLE_HELPER=$CONFIG/fm-gitea-credential.sh
# Prefer the stable home copy when present so --print-helper matches install.
if [ -f "$STABLE_HELPER" ]; then
  HELPER_VALUE="!${STABLE_HELPER}"
else
  HELPER_VALUE="!${HELPER_PATH}"
fi

if [ "$PRINT_HELPER" -eq 1 ]; then
  printf '%s\n' "$HELPER_VALUE"
  exit 0
fi

TOKEN_FILE=${FM_GITEA_TOKEN_FILE:-$CONFIG/gitea-token}
if [ ! -f "$TOKEN_FILE" ]; then
  echo "gitea-auth-setup: missing token file $TOKEN_FILE" >&2
  echo "gitea-auth-setup: create it (mode 600, single line token) then re-run" >&2
  exit 1
fi

USERNAME=${FM_GITEA_USERNAME:-}
if [ -z "$USERNAME" ] && [ -f "$CONFIG/gitea-username" ]; then
  USERNAME=$(sed -n '1s/[[:space:]]*$//p' "$CONFIG/gitea-username" 2>/dev/null || true)
fi
if [ -z "$USERNAME" ]; then
  USERNAME=apinant
fi

# Install a stable copy of the credential helper under the home's config/ so the
# global git config does not point at a disposable crew worktree path that
# vanishes on teardown. Re-copied on every setup so it tracks the tracked bin/.
STABLE_HELPER=$CONFIG/fm-gitea-credential.sh
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$CONFIG"
  if [ ! -f "$CONFIG/gitea-username" ]; then
    printf '%s\n' "$USERNAME" > "$CONFIG/gitea-username"
    chmod 600 "$CONFIG/gitea-username"
    echo "gitea-auth-setup: wrote config/gitea-username"
  fi
  if [ ! -f "$CONFIG/gitea-host" ]; then
    printf '%s\n' "$HOST" > "$CONFIG/gitea-host"
    chmod 644 "$CONFIG/gitea-host"
    echo "gitea-auth-setup: wrote config/gitea-host"
  fi
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  cp "$HELPER_PATH" "$STABLE_HELPER"
  chmod 700 "$STABLE_HELPER"
  echo "gitea-auth-setup: installed stable helper at config/fm-gitea-credential.sh"
else
  echo "gitea-auth-setup: dry-run would ensure config/gitea-username=$USERNAME host=$HOST"
  echo "gitea-auth-setup: dry-run would copy helper to $STABLE_HELPER"
fi

HELPER_VALUE="!${STABLE_HELPER}"

# Host-scoped helper so only this Gitea host uses the token file.
# Use --global so every project/worktree inherits it; local repo config is not
# required and would be lost when a worktree is discarded.
# An empty helper entry clears inherited helpers (e.g. osxkeychain) for this
# host so config/gitea-token is authoritative rather than a stale keychain user.
if [ "$DRY_RUN" -eq 0 ]; then
  git config --global --unset-all "credential.https://${HOST}.helper" 2>/dev/null || true
  git config --global --add "credential.https://${HOST}.helper" ''
  git config --global --add "credential.https://${HOST}.helper" "$HELPER_VALUE"
  git config --global --unset-all "credential.https://${HOST}.useHttpPath" 2>/dev/null || true
  echo "gitea-auth-setup: installed credential helper for https://${HOST}"
else
  echo "gitea-auth-setup: dry-run would set credential.https://${HOST}.helper=$HELPER_VALUE"
fi

sanitize_one() {
  local path=$1 line
  if [ "$DRY_RUN" -eq 1 ]; then
    local name url
    git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      url=$(git -C "$path" remote get-url "$name" 2>/dev/null || true)
      if fm_git_remote_has_userinfo "$url"; then
        echo "gitea-auth-setup: dry-run would sanitize $(basename "$path") remote $name"
      fi
    done < <(git -C "$path" remote 2>/dev/null || true)
    return 0
  fi
  while IFS= read -r line || [ -n "${line:-}" ]; do
    [ -n "${line:-}" ] || continue
    echo "gitea-auth-setup: $(basename "$path"): $line"
  done < <(fm_git_remote_sanitize_repo "$path")
}

if [ -n "$REPO" ]; then
  sanitize_one "$REPO"
elif [ -d "$PROJECTS" ]; then
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    sanitize_one "$proj"
  done
fi

if [ "$CHECK_ROTATE" -eq 1 ]; then
  cat <<EOF
gitea-auth-setup: rotate steps (current token treated compromised-at-rest):
  1. Open https://${HOST}/user/settings/applications as ${USERNAME}
  2. Generate a new token with repo read/write scope; copy it once
  3. printf '%s\\n' '<new-token>' > ${TOKEN_FILE} && chmod 600 ${TOKEN_FILE}
  4. Delete the old token in the same Applications page
  5. Re-run: FM_HOME=${FM_HOME} ${SCRIPT_DIR}/fm-gitea-auth-setup.sh
  6. Prove: git -C <project> ls-remote https://${HOST}/OpenCloud/core.git HEAD
Note: this Gitea rejects token-list/create with a bearer token alone (HTTP 401);
password/session login is required for mint+revoke. No automatic rotate from here.
EOF
fi

echo "gitea-auth-setup: done"
