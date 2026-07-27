#!/usr/bin/env bash
# fm-install-no-mistakes-omp.sh - reinstall the OMP-agent no-mistakes fork into GOBIN.
#
# Single owner of the guarded reinstall path for the captain's OMP-capable
# no-mistakes binary. Upstream releases and plain go-install / mise bumps
# silently overwrite GOBIN without the omp agent; this helper rebuilds from the
# local feat/omp-agent checkout and installs over the live GOBIN path (not the
# Makefile's default GOPATH/bin trap).
#
# Usage:
#   fm-install-no-mistakes-omp.sh
#   FM_NO_MISTAKES_OMP_SRC=~/Dev/no-mistakes fm-install-no-mistakes-omp.sh
#   INSTALL_BIN="$(go env GOBIN)/no-mistakes" fm-install-no-mistakes-omp.sh
#
# Does NOT run "no-mistakes update" (that fetches upstream).
# Does NOT restart the shared no-mistakes daemon (firstmate never restarts it
# from a crew; replace the on-disk binary only and report if a daemon is live).
set -eu

die() {
  printf 'fm-install-no-mistakes-omp.sh: %s\n' "$*" >&2
  exit 1
}

SRC=${FM_NO_MISTAKES_OMP_SRC:-${HOME:+$HOME/Dev/no-mistakes}}
SRC=${SRC:-}
[ -n "$SRC" ] || die "set FM_NO_MISTAKES_OMP_SRC to the omp-agent no-mistakes checkout"
[ -d "$SRC" ] || die "source checkout missing: $SRC"
[ -f "$SRC/internal/agent/omp.go" ] || die "source is not the omp-agent fork (missing internal/agent/omp.go): $SRC"
[ -f "$SRC/Makefile" ] || die "source checkout has no Makefile: $SRC"
command -v go >/dev/null 2>&1 || die "go is required to build no-mistakes"
command -v make >/dev/null 2>&1 || die "make is required to build no-mistakes"

# Resolve the live install path. Prefer an explicit override, then go env GOBIN
# (the path mise and this machine's PATH actually use), then the currently
# resolved no-mistakes binary when it is a real file (not a bare shim dir), and
# only then GOPATH/bin. Never silently default to GOPATH/bin when GOBIN is set.
resolve_install_bin() {
  local gobin gopath live real
  if [ -n "${INSTALL_BIN:-}" ]; then
    printf '%s\n' "$INSTALL_BIN"
    return 0
  fi
  if [ -n "${FM_NO_MISTAKES_INSTALL_BIN:-}" ]; then
    printf '%s\n' "$FM_NO_MISTAKES_INSTALL_BIN"
    return 0
  fi
  gobin=$(go env GOBIN 2>/dev/null || true)
  if [ -n "$gobin" ]; then
    printf '%s\n' "$gobin/no-mistakes"
    return 0
  fi
  live=$(command -v no-mistakes 2>/dev/null || true)
  if [ -n "$live" ] && [ -f "$live" ] && [ -x "$live" ]; then
    # Follow one symlink hop when present (mise shims). Avoid GNU-only readlink -f.
    if [ -L "$live" ]; then
      if command -v realpath >/dev/null 2>&1; then
        real=$(realpath "$live" 2>/dev/null || printf '%s\n' "$live")
      else
        real=$(readlink "$live" 2>/dev/null || printf '%s\n' "$live")
        case "$real" in
          /*) ;;
          *) real="$(cd "$(dirname "$live")" && pwd)/$real" ;;
        esac
      fi
      if [ -n "$real" ] && [ -f "$real" ] && [ -x "$real" ]; then
        printf '%s\n' "$real"
        return 0
      fi
    fi
    printf '%s\n' "$live"
    return 0
  fi
  gopath=$(go env GOPATH 2>/dev/null || true)
  gopath=${gopath%%:*}
  [ -n "$gopath" ] || die "cannot resolve install path: set INSTALL_BIN or go env GOBIN/GOPATH"
  printf '%s\n' "$gopath/bin/no-mistakes"
}

DEST=$(resolve_install_bin)
DEST_DIR=$(dirname "$DEST")
mkdir -p "$DEST_DIR"

printf 'fm-install-no-mistakes-omp.sh: building omp-agent no-mistakes from %s\n' "$SRC" >&2
# Build only. Deliberately avoid the Makefile install target so we never inherit
# its GOPATH/bin default or its daemon lifecycle side effects.
make -C "$SRC" build \
  || die "make build failed in $SRC"

[ -x "$SRC/bin/no-mistakes" ] || die "build did not produce $SRC/bin/no-mistakes"

# Fail closed if the built binary still lacks the omp agent implementation.
if ! grep -aFq 'omp start:' "$SRC/bin/no-mistakes" 2>/dev/null; then
  die "built binary lacks omp agent marker (omp start:); refusing to install"
fi

install -m 0755 "$SRC/bin/no-mistakes" "$DEST" \
  || die "install to $DEST failed"

if ! grep -aFq 'omp start:' "$DEST" 2>/dev/null; then
  die "installed binary at $DEST lacks omp agent marker after install"
fi

version=$("$DEST" --version 2>/dev/null | head -n 1 || true)
printf 'fm-install-no-mistakes-omp.sh: installed %s\n' "${version:-no-mistakes}" >&2
printf 'fm-install-no-mistakes-omp.sh: path %s\n' "$DEST" >&2

# Shared daemon keeps the previously loaded binary in memory. Report only; do
# not restart it from this helper (other lanes may hold active pipeline runs).
if command -v no-mistakes >/dev/null 2>&1; then
  if no-mistakes daemon status >/dev/null 2>&1; then
    printf 'fm-install-no-mistakes-omp.sh: note: shared daemon still running the previous binary; captain may restart it when no pipeline runs are active\n' >&2
  fi
fi

printf '%s\n' "$DEST"
