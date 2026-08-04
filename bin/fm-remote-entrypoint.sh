#!/usr/bin/env bash
# Fixed remote entrypoint for bin/fm-on.sh.
#
# Install this tracked file as `fm-remote-entrypoint.sh` on the remote account's
# non-interactive SSH PATH. It accepts only protocol metadata and encoded argv
# from fm-on.sh, validates the configured code root and FM_HOME on this host,
# resolves one genuine non-symlink executable under <root>/bin/fm-*.sh, then
# executes it directly. It never accepts a shell command string.
#
# Protocol v1 argv is a base64-encoded NUL-delimited stream. stdin is not used
# for protocol framing, so it remains byte-for-byte available to the command.
# The child receives an empty environment plus fixed PATH, HOME, FM_HOME, and
# FM_ROOT_OVERRIDE. stdout, stderr, and exit status pass through unchanged.
#
# This file is the single owner of the child PATH. compose_operator_path builds
# its operator portion from the account's ~/.local/bin, the common
# package-manager directories that exist on this host, and the always-present
# system tail. The tracked-command check resolves git from that portion before
# <root>/bin is prepended for the child. No login or interactive shell is ever
# started, so a tool that
# lives outside those directories - anything installed by nvm, asdf, or mise -
# needs a wrapper in ~/.local/bin. bin/fm-remote-doctor.sh reports this exact
# PATH by inheriting it rather than recomposing it, so the two cannot drift.
set -eu

PROTOCOL=1
OPERATOR_PATH=

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-64}"; }

path_append() { # <directory>
  case ":$OPERATOR_PATH:" in *":$1:"*) return 0 ;; esac
  OPERATOR_PATH="${OPERATOR_PATH:+$OPERATOR_PATH:}$1"
}

path_append_if_dir() { # <directory>
  [ -d "$1" ] || return 0
  path_append "$1"
}

build_child_path() { # <remote-root-bin>
  local root_bin=$1 directory old_ifs
  CHILD_PATH=$root_bin
  old_ifs=$IFS
  IFS=:
  for directory in $OPERATOR_PATH; do
    case ":$CHILD_PATH:" in *":$directory:"*) continue ;; esac
    CHILD_PATH="$CHILD_PATH:$directory"
  done
  IFS=$old_ifs
}

compose_operator_path() { # <account-home>
  local account_home=$1 account_user
  OPERATOR_PATH=
  path_append "$account_home/.local/bin"
  path_append_if_dir "$account_home/.nix-profile/bin"
  # env -i clears USER, so ask the password database rather than the environment.
  account_user=$(id -un 2>/dev/null) || account_user=
  if [ -n "$account_user" ]; then
    path_append_if_dir "/etc/profiles/per-user/$account_user/bin"
  fi
  path_append_if_dir /run/current-system/sw/bin
  path_append_if_dir /opt/homebrew/bin
  path_append_if_dir /usr/local/bin
  path_append /usr/bin
  path_append /bin
  path_append /usr/sbin
  path_append /sbin
}

base64_decode_to() { # <encoded> <destination>
  local encoded=$1 destination=$2
  if printf '%s' "$encoded" | base64 --decode > "$destination" 2>/dev/null; then
    return 0
  fi
  if printf '%s' "$encoded" | base64 -D > "$destination" 2>/dev/null; then
    return 0
  fi
  return 1
}

decode_text() { # <label> <encoded> <destination>
  local label=$1 encoded=$2 destination=$3 bytes lines
  base64_decode_to "$encoded" "$destination" || die "invalid base64 for $label"
  bytes=$(LC_ALL=C wc -c < "$destination" | tr -d ' ')
  [ "$bytes" -gt 0 ] || die "$label is empty"
  lines=$(LC_ALL=C tr -cd '\000\012\015' < "$destination" | LC_ALL=C wc -c | tr -d ' ')
  [ "$lines" -eq 0 ] || die "$label contains forbidden control bytes"
}

normalize_lexical_path() { # <absolute-path>
  local path=$1 part old_ifs out=/
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *'//'*) return 1 ;; esac
  old_ifs=$IFS
  IFS=/
  for part in $path; do
    case "$part" in
      '') ;;
      .|..) IFS=$old_ifs; return 1 ;;
      *)
        case "$part" in *$'\n'*|*$'\r'*|*$'\t'*) IFS=$old_ifs; return 1 ;; esac
        if [ "$out" = / ]; then out="/$part"; else out="$out/$part"; fi
        ;;
    esac
  done
  IFS=$old_ifs
  printf '%s\n' "$out"
}

canonical_existing_dir() { # <label> <path>
  local label=$1 path=$2 normalized physical
  normalized=$(normalize_lexical_path "$path") || die "$label is not a safe absolute path: $path"
  [ "$normalized" != / ] || die "$label must not be the filesystem root"
  [ -d "$normalized" ] && [ ! -L "$normalized" ] || die "$label is not a non-symlink directory: $path"
  physical=$(CDPATH='' cd -- "$normalized" 2>/dev/null && pwd -P) || die "$label cannot be resolved: $path"
  [ "$physical" = "$normalized" ] || die "$label contains a symlink or noncanonical component: $path"
  printf '%s\n' "$physical"
}

canonical_home() { # <path>; an absent leaf is allowed for guarded provisioning
  local path=$1 normalized parent base parent_real
  normalized=$(normalize_lexical_path "$path") || die "remote home is not a safe absolute path: $path"
  [ "$normalized" != / ] || die "remote home must not be the filesystem root"
  if [ -e "$normalized" ] || [ -L "$normalized" ]; then
    canonical_existing_dir "remote home" "$normalized"
    return
  fi
  parent=$(dirname "$normalized")
  base=$(basename "$normalized")
  case "$base" in ''|.|..) die "remote home has an unsafe leaf: $path" ;; esac
  parent_real=$(canonical_existing_dir "remote home parent" "$parent")
  [ "$parent_real/$base" = "$normalized" ] || die "remote home has a noncanonical parent: $path"
  printf '%s\n' "$normalized"
}

path_is_ancestor() { # <ancestor> <path>
  [ "$1" != "$2" ] || return 1
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}

[ "$#" -eq 4 ] || die "remote entrypoint expects protocol, root, home, and argv"
[ "$1" = "$PROTOCOL" ] || die "incompatible remote protocol: local=$1 remote=$PROTOCOL"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-entrypoint.XXXXXX") || die "cannot create protocol staging directory" 70
trap 'rm -rf -- "$TMP"' EXIT

decode_text "remote root" "$2" "$TMP/root"
decode_text "remote home" "$3" "$TMP/home"
base64_decode_to "$4" "$TMP/argv" || die "invalid base64 for argv"
ROOT=$(cat "$TMP/root")
HOME_PATH=$(cat "$TMP/home")
ROOT=$(canonical_existing_dir "remote root" "$ROOT")
HOME_PATH=$(canonical_home "$HOME_PATH")
[ -f "$ROOT/AGENTS.md" ] && [ ! -L "$ROOT/AGENTS.md" ] || die "remote root is not a Firstmate checkout"
[ -d "$ROOT/bin" ] && [ ! -L "$ROOT/bin" ] || die "remote root has no safe bin directory"
if path_is_ancestor "$ROOT" "$HOME_PATH" || path_is_ancestor "$HOME_PATH" "$ROOT" || [ "$ROOT" = "$HOME_PATH" ]; then
  die "remote root and home must be separate, non-overlapping directories"
fi

ARGV=()
while IFS= read -r -d '' arg; do
  ARGV+=("$arg")
done < "$TMP/argv"
[ "${#ARGV[@]}" -ge 1 ] || die "argv contains no command"
COMMAND=${ARGV[0]}
case "$COMMAND" in fm-*.sh) ;; *) die "command is outside the fm-*.sh namespace: $COMMAND" ;; esac
case "$COMMAND" in */*|*..*) die "command contains a path or traversal: $COMMAND" ;; esac
COMMAND_PATH="$ROOT/bin/$COMMAND"
[ -f "$COMMAND_PATH" ] && [ ! -L "$COMMAND_PATH" ] && [ -x "$COMMAND_PATH" ] \
  || die "command is not a genuine executable in the configured remote root: $COMMAND"
unset HOME
ACCOUNT_HOME=$(CDPATH='' cd ~ 2>/dev/null && pwd -P) || die "cannot resolve the remote account home"
compose_operator_path "$ACCOUNT_HOME"
GIT_BIN=$(PATH="$OPERATOR_PATH" command -v git 2>/dev/null || true)
case "$GIT_BIN" in
  /*)
    [ -x "$GIT_BIN" ] || GIT_BIN=
    case ":$OPERATOR_PATH:" in *":${GIT_BIN%/*}:"*) ;; *) GIT_BIN= ;; esac
    ;;
  *) GIT_BIN= ;;
esac
[ -n "$GIT_BIN" ] || die "required tool git does not resolve on the remote operator PATH; install git there or put a wrapper for it in ~/.local/bin using the recipe in docs/remote-secondmates.md"
"$GIT_BIN" -C "$ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "command is not tracked by the configured remote root: $COMMAND"
build_child_path "$ROOT/bin"

trap - EXIT
rm -rf -- "$TMP"
exec /usr/bin/env -i \
  PATH="$CHILD_PATH" \
  HOME="$ACCOUNT_HOME" \
  FM_HOME="$HOME_PATH" \
  FM_ROOT_OVERRIDE="$ROOT" \
  "$COMMAND_PATH" "${ARGV[@]:1}"
