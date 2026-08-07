#!/usr/bin/env bash
# Install, remove, and verify the `gh` shim that routes pull-request mutations through
# fm-gh.sh. Nothing here runs automatically: installation changes how every process
# using the target PATH resolves gh, so it is always a deliberate, explicit act.
#
# Usage: fm-gh-shim-install.sh --check [--dir <d>] [--path <PATH>]
#        fm-gh-shim-install.sh --install --dir <d> [--path <PATH>]
#        fm-gh-shim-install.sh --uninstall --dir <d>
#
#   --dir <d>     directory the shim is installed into, as a symlink named `gh`.
#                 It must already exist and must precede the real gh on the PATH the
#                 intercepted process uses.
#   --path <PATH> PATH string to evaluate precedence against; defaults to this
#                 process's own PATH. The no-mistakes daemon resolves its environment
#                 from the LOGIN shell once at startup, so a check run from an
#                 unusual shell can report a precedence this daemon does not have.
#                 See docs/no-mistakes-pr-credential.md.
#   --check       report installed state, the real gh, and whether --dir wins.
#                 --check is the default when no mode flag is given.
#
# Exit status is 0 when the requested action succeeded, or when --check finds the shim
# installed and winning; --check exits 1 when the shim is absent or loses precedence,
# so it is usable as a gate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_SOURCE="$SCRIPT_DIR/fm-gh-shim.sh"

MODE=--check
DIR=
TARGET_PATH=$PATH

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check | --install | --uninstall)
      MODE=$1
      shift
      ;;
    --dir)
      [ "$#" -ge 2 ] || {
        echo "fm-gh-shim-install: --dir needs a value" >&2
        exit 2
      }
      DIR=$2
      shift 2
      ;;
    --path)
      [ "$#" -ge 2 ] || {
        echo "fm-gh-shim-install: --path needs a value" >&2
        exit 2
      }
      TARGET_PATH=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "fm-gh-shim-install: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[ -f "$SHIM_SOURCE" ] || {
  echo "fm-gh-shim-install: shim source missing: $SHIM_SOURCE" >&2
  exit 1
}

# first_gh_on_path <path> [skip_dir]: echo the first executable gh on <path>,
# optionally ignoring one directory.
first_gh_on_path() {
  local path_value=$1 skip=${2:-} entry resolved
  local IFS=:
  for entry in $path_value; do
    [ -n "$entry" ] || entry=.
    [ -f "$entry/gh" ] && [ -x "$entry/gh" ] || continue
    resolved=$(cd "$entry" 2> /dev/null && pwd) || continue
    if [ -n "$skip" ] && [ "$resolved" = "$skip" ]; then
      continue
    fi
    printf '%s\n' "$resolved/gh"
    return 0
  done
  return 1
}

resolve_dir() {
  cd "$1" 2> /dev/null && pwd
}

case "$MODE" in
  --install)
    [ -n "$DIR" ] || {
      echo "fm-gh-shim-install: --install needs --dir" >&2
      exit 2
    }
    dir_abs=$(resolve_dir "$DIR") || {
      echo "fm-gh-shim-install: --dir does not exist: $DIR" >&2
      exit 1
    }
    link="$dir_abs/gh"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "fm-gh-shim-install: refusing to replace a non-symlink at $link" >&2
      exit 1
    fi
    real_gh=$(first_gh_on_path "$TARGET_PATH" "$dir_abs") || {
      echo "fm-gh-shim-install: no real gh on PATH outside $dir_abs; refusing to install a shim that cannot delegate" >&2
      exit 1
    }
    ln -sf "$SHIM_SOURCE" "$link"
    printf 'installed: %s -> %s\n' "$link" "$SHIM_SOURCE"
    printf 'delegates to: %s\n' "$real_gh"
    winner=$(first_gh_on_path "$TARGET_PATH") || winner=
    if [ "$winner" != "$link" ]; then
      printf 'WARNING: %s does not win on the evaluated PATH (first gh is %s)\n' \
        "$link" "${winner:-none}" >&2
    fi
    ;;
  --uninstall)
    [ -n "$DIR" ] || {
      echo "fm-gh-shim-install: --uninstall needs --dir" >&2
      exit 2
    }
    dir_abs=$(resolve_dir "$DIR") || {
      echo "fm-gh-shim-install: --dir does not exist: $DIR" >&2
      exit 1
    }
    link="$dir_abs/gh"
    if [ ! -L "$link" ]; then
      printf 'not installed: %s\n' "$link"
      exit 0
    fi
    # Only remove a link this script owns, so an unrelated gh symlink survives.
    if [ "$(readlink "$link")" != "$SHIM_SOURCE" ]; then
      echo "fm-gh-shim-install: $link does not point at $SHIM_SOURCE; leaving it alone" >&2
      exit 1
    fi
    rm -f "$link"
    printf 'removed: %s\n' "$link"
    ;;
  --check)
    status=0
    if [ -n "$DIR" ]; then
      dir_abs=$(resolve_dir "$DIR") || {
        echo "fm-gh-shim-install: --dir does not exist: $DIR" >&2
        exit 1
      }
      link="$dir_abs/gh"
      if [ -L "$link" ] && [ "$(readlink "$link")" = "$SHIM_SOURCE" ]; then
        printf 'shim: installed at %s\n' "$link"
      else
        printf 'shim: not installed at %s\n' "$link"
        status=1
      fi
      real_gh=$(first_gh_on_path "$TARGET_PATH" "$dir_abs") || real_gh=
      printf 'real gh: %s\n' "${real_gh:-none found}"
    fi
    winner=$(first_gh_on_path "$TARGET_PATH") || winner=
    printf 'first gh on evaluated PATH: %s\n' "${winner:-none found}"
    if [ -n "$DIR" ]; then
      if [ "$winner" = "$dir_abs/gh" ]; then
        printf 'precedence: %s wins\n' "$dir_abs"
      else
        printf 'precedence: %s does NOT win\n' "$dir_abs"
        status=1
      fi
    fi
    exit "$status"
    ;;
esac
