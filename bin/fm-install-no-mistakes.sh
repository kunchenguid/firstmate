#!/usr/bin/env bash
# Pinned, checksum-verified installer for the no-mistakes engine.
#
# This replaces the former bootstrap install path
#   curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
# which was a supply-chain + integrity risk: it fetched an installer from a third
# party's MAIN branch (unversioned, so it silently drifted) and that installer
# then downloaded an UNSIGNED, UN-CHECKSUMMED release tarball. Here we instead
# download a PINNED release asset from the tagged GitHub release and VERIFY its
# SHA256 against a checksum pinned in this script before installing. There is no
# trust-on-first-use and no fallback to the old curl|sh: a checksum mismatch or a
# missing asset FAILS CLOSED (nothing is installed).
#
# FUTURE WORK (tracked, deliberately NOT done here): a later step will
#   (a) MIRROR the artifact to our own storage so bootstrap no longer depends on
#       the third party's GitHub staying up (availability-independence; the
#       FM_NO_MISTAKES_BASE_URL override below is the seam for that), and
#   (b) ultimately REPLACE this third-party engine with our own from-scratch
#       `squared-away` engine.
# This task removes only the unversioned/unverified INTEGRITY risk. The
# AVAILABILITY dependency on upstream GitHub remains until step (a).
#
# Install layout mirrors the upstream installer it replaces, so re-installing
# over an existing setup is seamless:
#   binary  -> $NO_MISTAKES_INSTALL_DIR (default $HOME/.no-mistakes/bin)/no-mistakes
#   symlink -> $NO_MISTAKES_LINK_DIR (default $HOME/.local/bin when on PATH, else
#              /usr/local/bin)/no-mistakes
#
# Usage: fm-install-no-mistakes.sh
#   Env overrides:
#     NO_MISTAKES_INSTALL_DIR, NO_MISTAKES_LINK_DIR - install/symlink locations
#       (same names the upstream installer honored).
#     FM_NO_MISTAKES_BASE_URL - override the release-download base URL. Defaults
#       to GitHub release assets; the seam for future artifact mirroring and for
#       hermetic tests.
#     FM_NO_MISTAKES_SKIP_DAEMON=1 - skip the post-install `daemon restart`.

REPO="kunchenguid/no-mistakes"

# Pinned release. Do NOT drop this below fm-bootstrap.sh's no_mistakes_compatible()
# minimum (NO_MISTAKES_MIN_* = 1.31.2). v1.31.2 is the current minimum gate and a
# proper (non-prerelease) release with downloadable assets. When bumping, refresh
# EVERY checksum in pinned_sha256() from the tagged release's own checksums.txt /
# the release-asset `digest` field, never a placeholder.
NO_MISTAKES_PINNED_VERSION="v1.31.2"

# SHA256 of each pinned release asset, keyed "<os>-<arch>". Verified 2026-07-05,
# read-only, three ways that all agreed: the release's own checksums.txt asset,
# the GitHub API release-asset `digest` field, and a locally recomputed sha256 of
# the downloaded linux-amd64 asset. The upstream installer supports linux/darwin
# on amd64/arm64, so those four are covered here.
pinned_sha256() {
  case "$1" in
    linux-amd64)  echo "e3009fe9986c51ca59ddb0152e127bb245858efe03dc84842138c0f192ff7f8b" ;;
    linux-arm64)  echo "b73d01abeb48dd11cbacecdeeccc92120aa241e7acc48e55b3e3f3331d1b011a" ;;
    darwin-amd64) echo "9e18e38fbc4f989d2dc2e3d4d3dafb8e1ffd7691dc351273668439d4c7bfb9eb" ;;
    darwin-arm64) echo "beefec1cf6a0280fba5e4bb795c49c655dbb1cb7f1960949f2434d02f7245fff" ;;
    *) return 1 ;;
  esac
}

nm_fail() { echo "no-mistakes install: $*" >&2; exit 1; }

# Echo the normalized "<os>-<arch>" platform, or fail on an unsupported one.
nm_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in
    darwin|linux) ;;
    *) nm_fail "unsupported OS: $os (pinned installer supports linux and darwin)" ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) nm_fail "unsupported architecture: $arch (pinned installer supports amd64 and arm64)" ;;
  esac
  echo "$os-$arch"
}

# Echo the sha256 of a file using whichever tool is available.
nm_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# nm_verify_sha256 <file> <expected>: succeed only when <file>'s sha256 equals
# <expected>. Returns non-zero on mismatch or when no sha256 tool is available -
# the caller MUST treat a non-zero return as "do not install".
nm_verify_sha256() {
  local file=$1 expected=$2 actual
  actual="$(nm_sha256_of "$file")" || return 2
  [ "$actual" = "$expected" ]
}

nm_install_main() {
  set -eu

  local platform version expected_sha filename base_url url
  local install_dir link_dir bin_path link_path work
  local real_install_dir real_link_dir

  command -v curl >/dev/null 2>&1 || nm_fail "curl is required"
  command -v tar >/dev/null 2>&1 || nm_fail "tar is required"

  platform="$(nm_platform)"
  version="$NO_MISTAKES_PINNED_VERSION"
  expected_sha="$(pinned_sha256 "$platform")" || nm_fail "no pinned checksum for $platform"

  filename="no-mistakes-${version}-${platform}.tar.gz"
  base_url="${FM_NO_MISTAKES_BASE_URL:-https://github.com/${REPO}/releases/download}"
  url="${base_url}/${version}/${filename}"

  install_dir="${NO_MISTAKES_INSTALL_DIR:-$HOME/.no-mistakes/bin}"
  link_dir="${NO_MISTAKES_LINK_DIR:-}"
  if [ -z "$link_dir" ]; then
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) link_dir="$HOME/.local/bin" ;;
      *) link_dir="/usr/local/bin" ;;
    esac
  fi
  bin_path="$install_dir/no-mistakes"
  link_path="$link_dir/no-mistakes"

  work="$(mktemp -d "${TMPDIR:-/tmp}/fm-no-mistakes-install.XXXXXX")" || nm_fail "cannot create temp dir"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT

  echo "Downloading no-mistakes ${version} for ${platform}..."
  curl -fsSL "$url" -o "$work/$filename" || nm_fail "download failed: $url"

  if ! nm_verify_sha256 "$work/$filename" "$expected_sha"; then
    nm_fail "checksum verification FAILED for $filename
  expected sha256 $expected_sha
  got      sha256 $(nm_sha256_of "$work/$filename" 2>/dev/null || echo '<no sha256 tool>')
Refusing to install an unverified binary. Either the pinned checksum is wrong,
the download was corrupted, or the artifact was tampered with. Nothing was
installed; the existing install (if any) is untouched."
  fi

  tar xzf "$work/$filename" -C "$work" || nm_fail "failed to extract $filename"
  [ -f "$work/no-mistakes" ] || nm_fail "archive did not contain a no-mistakes binary"

  mkdir -p "$install_dir" || nm_fail "cannot create install dir: $install_dir"
  mv "$work/no-mistakes" "$bin_path" || nm_fail "cannot install binary to $bin_path"
  chmod 755 "$bin_path" 2>/dev/null || true

  # Symlink, mirroring the upstream installer (skip when link and install dirs
  # resolve to the same path).
  real_install_dir="$( (cd "$install_dir" 2>/dev/null && pwd -P) || true)"
  real_link_dir="$( (cd "$link_dir" 2>/dev/null && pwd -P) || true)"
  if [ -n "$real_install_dir" ] && [ "$real_install_dir" = "$real_link_dir" ]; then
    echo "Install dir and link dir resolve to the same path; skipping symlink."
  elif [ -w "$link_dir" ] || (mkdir -p "$link_dir" 2>/dev/null && [ -w "$link_dir" ]); then
    rm -f "$link_path"
    ln -s "$bin_path" "$link_path"
  else
    echo "Linking ${link_path} to ${bin_path} (requires sudo)..."
    sudo mkdir -p "$link_dir"
    sudo rm -f "$link_path"
    sudo ln -s "$bin_path" "$link_path"
  fi

  echo "no-mistakes ${version} installed to ${bin_path}"
  echo "Command path: ${link_path} -> ${bin_path}"

  if [ "${FM_NO_MISTAKES_SKIP_DAEMON:-0}" != 1 ]; then
    "$bin_path" daemon restart >/dev/null 2>&1 || true
  fi

  case ":$PATH:" in
    *":$link_dir:"*) ;;
    *) echo "Add ${link_dir} to your PATH and restart your terminal." ;;
  esac
}

# Run only when executed directly, not when sourced (the colocated test sources
# this file to exercise nm_verify_sha256 and nm_install_main against a local,
# non-live artifact).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  nm_install_main "$@"
fi
