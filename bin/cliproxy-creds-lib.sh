#!/usr/bin/env bash
# cliproxy-creds-lib.sh - one owner of the CLIProxyAPI credential filesystem
# contract shared by bin/cliproxy-relogin.sh and bin/cliproxy-retire-legacy.sh.
#
# Sourced, never run. It owns four things and nothing else:
#
#   where          cliproxy_auth_dir, cliproxy_archive_root, and
#                  cliproxy_login_registry resolve the three local locations from
#                  their environment overrides. The archive root is deliberately
#                  OUTSIDE the auth dir: a future CLIProxyAPI that learns to walk
#                  subdirectories must never load a retired credential.
#   writing        cliproxy_atomic_write puts a credential in place by rename, so
#                  the running proxy never reads a half-written file, and the
#                  destination is never a symlink and never widens beyond 0600.
#   retiring       cliproxy_archive_move moves a retired copy into
#                  <archive-root>/<date>/ and never deletes one, so a wrong
#                  retirement is always reversible.
#   the registry   cliproxy_registry_set records "<email>": "<login date>" in
#                  FM_CLIPROXY_LOGIN_REGISTRY, preserving every other key, so the
#                  login-age alarm in bin/fm-cliproxy-expiry-check.sh keeps
#                  measuring after a re-login.
#
# No function here ever prints secret material, and none of them reads a token.

# shellcheck disable=SC2034  # consumed by the sourcing scripts
CLIPROXY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cliproxy_repo_root() {
  printf '%s\n' "${FM_HOME:-$(cd "$CLIPROXY_LIB_DIR/.." && pwd)}"
}

cliproxy_auth_dir() {
  printf '%s\n' "${FM_CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}"
}

cliproxy_archive_root() {
  printf '%s\n' "${FM_CLIPROXY_ARCHIVE_ROOT:-$HOME/.cli-proxy-api-archive}"
}

cliproxy_login_registry() {
  if [ -n "${FM_CLIPROXY_LOGIN_REGISTRY:-}" ]; then
    printf '%s\n' "$FM_CLIPROXY_LOGIN_REGISTRY"
  else
    printf '%s\n' "$(cliproxy_repo_root)/config/cliproxy-login-registry.json"
  fi
}

# cliproxy_atomic_write <destination>: write stdin to <destination> by rename.
cliproxy_atomic_write() {
  local dest=$1 dir base tmp
  [ -n "$dest" ] || return 2
  dir=$(dirname -- "$dest")
  base=$(basename -- "$dest")
  [ -d "$dir" ] || return 1
  [ ! -L "$dest" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.$base.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# cliproxy_archive_move <file> [<label>]: move a retired copy into the dated
# archive and print where it went. Never overwrites and never deletes.
cliproxy_archive_move() {
  local src=$1 label=${2:-} root day base dest n=1
  [ -f "$src" ] || return 1
  root=$(cliproxy_archive_root)
  day=$(date -u +%Y-%m-%d)
  base=$(basename -- "$src")
  dest="$root/$day/$base"
  (umask 077; mkdir -p "$root/$day") || return 1
  while [ -e "$dest" ]; do
    dest="$root/$day/$base.$n"
    n=$((n + 1))
  done
  mv -- "$src" "$dest" || return 1
  [ -z "$label" ] || printf '%s -> %s\n' "$label" "$dest" >&2
  printf '%s\n' "$dest"
}

# cliproxy_registry_set <email> <ISO date> [<email> <ISO date> ...]: record each
# login date, preserving every other key in the registry. Prints nothing.
cliproxy_registry_set() {
  local registry
  [ "$#" -ge 2 ] || return 2
  registry=$(cliproxy_login_registry)
  (umask 077; mkdir -p "$(dirname -- "$registry")") || return 1
  CLIPROXY_REGISTRY_TARGET=$registry python3 - "$@" <<'PY' | cliproxy_atomic_write "$registry"
import json
import os
import sys

target = os.environ["CLIPROXY_REGISTRY_TARGET"]
pairs = sys.argv[1:]
data = {}
try:
    with open(target) as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict):
        data = loaded
except (OSError, ValueError):
    data = {"_note": "human login date per Claude account; written by bin/cliproxy-relogin.sh"}
if "_note" not in data:
    data["_note"] = "human login date per Claude account; written by bin/cliproxy-relogin.sh"
for index in range(0, len(pairs) - 1, 2):
    data[pairs[index]] = pairs[index + 1]
json.dump(data, sys.stdout, indent=1, sort_keys=True)
sys.stdout.write("\n")
PY
}

# cliproxy_json_setup_token <email> <expired-ISO>: emit a setup-token credential
# JSON for the token read from stdin, and fail when that token is empty. The
# token reaches neither stdout nor a log, and it is handed to the interpreter
# through a 0600 file rather than a command line or an inherited environment.
cliproxy_json_setup_token() {
  local email=$1 expired=$2 tmp rc
  [ -n "$email" ] && [ -n "$expired" ] || return 2
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/cliproxy-token.XXXXXX") || return 1
  cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
  CLIPROXY_EMAIL=$email CLIPROXY_EXPIRED=$expired CLIPROXY_TOKEN_FILE=$tmp python3 -c '
import json, os, sys
try:
    with open(os.environ["CLIPROXY_TOKEN_FILE"]) as handle:
        token = handle.read().strip()
except OSError as exc:
    sys.exit("cliproxy: cannot read the token: %s" % exc)
if not token:
    sys.exit("cliproxy: no token on stdin")
payload = {
    "type": "claude",
    "email": os.environ["CLIPROXY_EMAIL"],
    "access_token": token,
    "is_setup_token": True,
    "expired": os.environ["CLIPROXY_EXPIRED"],
}
json.dump(payload, sys.stdout, indent=1)
sys.stdout.write("\n")
'
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# cliproxy_email_slug <email>: a filename-safe form of an account address.
cliproxy_email_slug() {
  printf '%s\n' "${1//[^A-Za-z0-9.@_-]/-}"
}
