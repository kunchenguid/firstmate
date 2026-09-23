#!/usr/bin/env bash
# fm-gh-read.sh - build, plan, verify, and attended installation for the
# Cursor worker GitHub read helper.
#
# The helper is the native executable compiled from bin/native/fm-gh-read.c.
# It accepts only closed read-only repo, pr, issue, run, and workflow shapes,
# rejects everything else before starting anything, and runs the absolute
# /usr/local/bin/gh with a constructed minimal environment. Enrolled as an
# Automic Vault Launcher Bundle with its own Read Only gh Gate row, it lets a
# Cursor worker read GitHub without per-command approval while every write
# stays on the existing attended paths. It is a caller-independent read
# appliance; it does not prove that Cursor was the caller.
# docs/gh-read-helper.md is the operator guide; this header owns the
# commands.
#
# Usage:
#   fm-gh-read.sh build --out <path> [--fake-target <absolute-path>]
#   fm-gh-read.sh build-router --out <path> [--helper-target <absolute-path>]
#                              [--generic-target <absolute-path>]
#   fm-gh-read.sh plan [--command <path>]
#   fm-gh-read.sh verify --payload <path> [--command <path>]
#                        [--signed-sha256 <hex>]
#   fm-gh-read.sh install-path --command <path>
#   fm-gh-read.sh --help
#
# build compiles the tracked source with `cc` into <path> and prints
# `sha256=<hex>` and `path=<path>`. The payload is compiled under the fixed
# basename fm-gh-read in a private directory, so the same source and
# toolchain reproduce the same bytes. --fake-target replaces the compiled
# /usr/local/bin/gh target for deterministic tests only; such a build can
# never pass verify.
#
# plan changes nothing. It prints the ordered attended steps and the current
# state of the Cursor PATH directory and the enrolled command.
#
# verify changes nothing and never contacts Automic Vault or GitHub. Each
# check prints `ok`, `FAIL`, or `unverified`; the exit status is 0 only when
# every check is `ok`:
#   payload        a fresh product build of the tracked source has the same
#                  sha256 as --payload, which proves the compiled policy and
#                  the exact /usr/local/bin/gh target. Compare the printed
#                  digest with the App's selected-source hash.
#   command        --command (default /usr/local/bin/fm-gh-read, the link
#                  the Launcher Bundle installs) resolves through root-owned,
#                  non-writable hops to an executable; with --signed-sha256
#                  that executable must also match the App's signed-payload
#                  hash for the enrolled generation.
#   signature      codesign --verify --strict passes, the signature carries
#                  Hardened Runtime, and it grants no entitlements.
#   target         /usr/local/bin/gh is a root-owned entry that resolves to
#                  an executable validly signed with Hardened Runtime by the
#                  Automic Vault gh Isotope's Team ID.
#   cursor-path    the protected Cursor PATH directory holds exactly the
#                  native `gh` router built for --command and generic gh.
#   gate           remains unverified because Authorization History has no
#                  published machine-readable schema. The operator confirms
#                  launcher identity and Read Only authorization in the App.
#
# install-path is the only mutating command. It creates the protected Cursor
# PATH directory and its native `gh` router through sudo, and only after
# the operator types `install` at an interactive terminal. It refuses a
# non-interactive run, a command that is not already a protected executable,
# and a directory that already holds anything else. Launcher Bundle
# enrollment and Gate rows are made only in the Automic Vault App.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-gh-read-lib.sh
. "$SCRIPT_DIR/fm-gh-read-lib.sh"

SOURCE="$SCRIPT_DIR/native/fm-gh-read.c"
PRODUCT_TARGET=/usr/local/bin/gh
DEFAULT_COMMAND=/usr/local/bin/fm-gh-read
# The Automic Vault gh Isotope's Developer ID Team ID, as installed on
# 2026-09-20 (gh 2.101.0-2).
TARGET_TEAM=ZU76A67LGU
CFLAGS=(-std=c11 -O2 -Wall -Wextra -Werror -pedantic)

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-gh-read.sh: %s\n' "$1" >&2
  exit "${2:-1}"
}

sha256_of() {  # <file>
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 -- "$1") || return 1
  else
    out=$(sha256sum -- "$1") || return 1
  fi
  printf '%s\n' "${out%% *}"
}

# Compile the tracked source into <out>. The private build directory fixes
# the output basename, which the linker's ad-hoc signature records.
build_payload() {  # <out> [fake-target]
  local out=$1 fake=${2:-} work defines=() status
  command -v cc >/dev/null 2>&1 || die "no C compiler (cc) is available"
  if [ -n "$fake" ]; then
    case "$fake" in /*) ;; *) die "--fake-target must be an absolute path" ;; esac
    case "$fake" in *'"'* | *\\*) die "--fake-target may not contain quotes or backslashes" ;; esac
    defines=("-DFM_GH_READ_TARGET=\"$fake\"")
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-read-build.XXXXXX") || die "cannot create a build directory"
  (cd "$work" && cc "${CFLAGS[@]}" ${defines[@]+"${defines[@]}"} -o fm-gh-read "$SOURCE")
  status=$?
  if [ "$status" -eq 0 ]; then
    cp -f -- "$work/fm-gh-read" "$out" && chmod 0755 "$out"
    status=$?
  fi
  rm -rf -- "$work"
  return "$status"
}

valid_compiled_path() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *'"'* | *\\*) return 1 ;; esac
}

build_router() {  # <out> <helper-target> <generic-target>
  local out=$1 helper=$2 generic=$3 work status
  command -v cc >/dev/null 2>&1 || die "no C compiler (cc) is available"
  valid_compiled_path "$helper" || die "router helper target must be a safe absolute path"
  valid_compiled_path "$generic" || die "router generic target must be a safe absolute path"
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-read-router.XXXXXX") || die "cannot create a build directory"
  (cd "$work" && cc "${CFLAGS[@]}" -DFM_GH_READ_ROUTER \
    "-DFM_GH_READ_HELPER_TARGET=\"$helper\"" "-DFM_GH_READ_TARGET=\"$generic\"" \
    -o fm-gh-read-route "$SOURCE")
  status=$?
  if [ "$status" -eq 0 ]; then
    cp -f -- "$work/fm-gh-read-route" "$out" && chmod 0755 "$out"
    status=$?
  fi
  rm -rf -- "$work"
  return "$status"
}

cmd_build() {
  local out='' fake='' digest
  while [ $# -gt 0 ]; do
    case "$1" in
    --out) [ $# -ge 2 ] || die "--out needs a path" 2; out=$2; shift 2 ;;
    --fake-target) [ $# -ge 2 ] || die "--fake-target needs a path" 2; fake=$2; shift 2 ;;
    *) die "unknown build argument: $1" 2 ;;
    esac
  done
  [ -n "$out" ] || die "build needs --out <path>" 2
  build_payload "$out" "$fake" || die "build failed"
  digest=$(sha256_of "$out") || die "cannot hash $out"
  printf 'sha256=%s\npath=%s\n' "$digest" "$out"
  [ -z "$fake" ] || printf 'test-build: target=%s (never enroll this build)\n' "$fake"
}

cmd_build_router() {
  local out='' helper=$DEFAULT_COMMAND generic=$PRODUCT_TARGET digest
  while [ $# -gt 0 ]; do
    case "$1" in
    --out) [ $# -ge 2 ] || die "--out needs a path" 2; out=$2; shift 2 ;;
    --helper-target) [ $# -ge 2 ] || die "--helper-target needs a path" 2; helper=$2; shift 2 ;;
    --generic-target) [ $# -ge 2 ] || die "--generic-target needs a path" 2; generic=$2; shift 2 ;;
    *) die "unknown build-router argument: $1" 2 ;;
    esac
  done
  [ -n "$out" ] || die "build-router needs --out <path>" 2
  build_router "$out" "$helper" "$generic" || die "router build failed"
  digest=$(sha256_of "$out") || die "cannot hash $out"
  printf 'sha256=%s\npath=%s\n' "$digest" "$out"
}

# Follow every symlink hop of <path> and print the final executable file.
target_realpath() {  # <path>
  local path=$1 hops=0 target
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 16 ] || return 1
    target=$(readlink -- "$path") || return 1
    case "$target" in
    /*) path=$target ;;
    *) path="$(dirname -- "$path")/$target" ;;
    esac
  done
  [ -f "$path" ] && [ -x "$path" ] || return 1
  printf '%s\n' "$path"
}

report() {  # <check> <ok|FAIL|unverified> <detail>
  printf '%-12s %-10s %s\n' "$1" "$2" "$3"
  [ "$2" = ok ] || VERIFY_FAILED=1
}

cursor_path_state() {
  local dir status
  dir=$(fm_gh_read_cursor_path_dir 2>/dev/null)
  status=$?
  case "$status" in
  0) printf 'present and protected: %s\n' "$dir" ;;
  1) printf 'absent: %s (Cursor workers use the generic gh)\n' "${FM_GH_READ_CURSOR_DIR_OVERRIDE:-$FM_GH_READ_CURSOR_DIR_DEFAULT}" ;;
  *) printf 'UNSAFE: %s (Cursor ship and scout launches are refused)\n' "$(fm_gh_read_cursor_path_dir 2>&1 >/dev/null)" ;;
  esac
}

cmd_plan() {
  local command=$DEFAULT_COMMAND resolved
  while [ $# -gt 0 ]; do
    case "$1" in
    --command) [ $# -ge 2 ] || die "--command needs a path" 2; command=$2; shift 2 ;;
    *) die "unknown plan argument: $1" 2 ;;
    esac
  done
  printf 'Current state (read-only):\n'
  printf '  cursor-path: %s\n' "$(cursor_path_state)"
  if resolved=$(fm_gh_read_resolve_protected "$command" 0 2>/dev/null); then
    printf '  command:     %s -> %s\n' "$command" "$resolved"
  else
    printf '  command:     not installed or not protected: %s\n' "$command"
  fi
  cat <<EOF

Attended steps, in order (nothing below runs from this command):
  1. Build the payload: $0 build --out <payload>
     Record its sha256.
  2. In the Automic Vault App, create one Launcher Bundle from <payload>
     with command name fm-gh-read and no compatibility exceptions, approve
     the installation, and record the enrolled generation, the
     selected-source hash (it must equal the step 1 sha256), the
     signed-payload hash, and the installed command link.
  3. In the App, add one gh Gate row for exactly that Launcher Bundle at
     Read Only. Leave the All Other Verified Launchers default at Read Only
     and every existing write row unchanged.
  4. Create the Cursor PATH directory (sudo, interactive):
     $0 install-path --command <installed command link>
  5. Verify: $0 verify --payload <payload> --command <link>
       --signed-sha256 <signed-payload hash>
  6. From a real Cursor worker, run one harmless read per family and confirm
     in Authorization History that the helper is the launcher and the
     helper's Read Only row authorized it automatically.
EOF
}

cmd_verify() {
  local payload='' command=$DEFAULT_COMMAND signed='' work built_digest payload_digest
  local resolved='' sig ents bad actual dir router_digest expected_digest
  while [ $# -gt 0 ]; do
    case "$1" in
    --payload) [ $# -ge 2 ] || die "--payload needs a path" 2; payload=$2; shift 2 ;;
    --command) [ $# -ge 2 ] || die "--command needs a path" 2; command=$2; shift 2 ;;
    --signed-sha256) [ $# -ge 2 ] || die "--signed-sha256 needs a digest" 2; signed=$2; shift 2 ;;
    *) die "unknown verify argument: $1" 2 ;;
    esac
  done
  [ -n "$payload" ] || die "verify needs --payload <path>" 2
  VERIFY_FAILED=0

  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-read-verify.XXXXXX") || die "cannot create a scratch directory"
  if [ ! -f "$payload" ]; then
    report payload FAIL "no payload file: $payload"
  elif ! build_payload "$work/fm-gh-read" 2>/dev/null; then
    report payload FAIL "the tracked source did not build"
  else
    built_digest=$(sha256_of "$work/fm-gh-read")
    payload_digest=$(sha256_of "$payload")
    if [ "$built_digest" = "$payload_digest" ]; then
      report payload ok "sha256=$payload_digest matches a fresh build with target $PRODUCT_TARGET"
    else
      report payload FAIL "sha256=$payload_digest differs from a fresh product build ($built_digest)"
    fi
  fi
  rm -rf -- "$work"

  if resolved=$(fm_gh_read_resolve_protected "$command" 0 2>/dev/null); then
    actual=$(sha256_of "$resolved")
    if [ -z "$signed" ]; then
      report command unverified "$command -> $resolved sha256=$actual; pass --signed-sha256 from the App"
    elif [ "$actual" = "$signed" ]; then
      report command ok "$command -> $resolved matches the enrolled signed payload"
    else
      report command FAIL "$command -> $resolved sha256=$actual, App shows $signed"
    fi
  else
    report command FAIL "$command: $(fm_gh_read_resolve_protected "$command" 0 2>&1 >/dev/null)"
    resolved=''
  fi

  if [ -z "$resolved" ]; then
    report signature FAIL "no protected executable to inspect"
  elif ! command -v codesign >/dev/null 2>&1; then
    report signature FAIL "codesign is unavailable"
  elif ! codesign --verify --strict -- "$resolved" 2>/dev/null; then
    report signature FAIL "codesign --verify --strict failed for $resolved"
  else
    sig=$(codesign -d --verbose=2 -- "$resolved" 2>&1)
    ents=$(codesign -d --entitlements - -- "$resolved" 2>/dev/null)
    case "$sig" in
    *'flags='*'runtime'*)
      if printf '%s' "$ents" | grep -q '<key>'; then
        report signature FAIL "the signature grants entitlements"
      else
        report signature ok "valid, Hardened Runtime, no entitlements"
      fi
      ;;
    *) report signature FAIL "the signature lacks Hardened Runtime" ;;
    esac
  fi

  # The hardened gh lives in a user-writable Homebrew tree, so its protection
  # is its signature, which Automic Vault checks at the Gate, not its
  # ownership. The entry point the helper names must still be root-owned.
  if ! bad=$(fm_gh_read_protected_chain "$PRODUCT_TARGET" 0); then
    report target FAIL "$PRODUCT_TARGET is not a root-owned entry ($bad)"
  elif ! actual=$(target_realpath "$PRODUCT_TARGET"); then
    report target FAIL "$PRODUCT_TARGET does not resolve to an executable"
  elif ! command -v codesign >/dev/null 2>&1 || ! codesign --verify --strict -- "$actual" 2>/dev/null; then
    report target FAIL "$actual has no valid code signature"
  else
    sig=$(codesign -d --verbose=2 -- "$actual" 2>&1)
    # TeamIdentifier and flags= live on different codesign lines, so match
    # each line rather than one glob across newlines.
    if printf '%s\n' "$sig" | grep -q "TeamIdentifier=$TARGET_TEAM" &&
      printf '%s\n' "$sig" | grep -q 'flags=.*runtime'; then
      report target ok "$PRODUCT_TARGET -> $actual, Team ID $TARGET_TEAM, Hardened Runtime"
    else
      report target FAIL "$actual is not signed by Team ID $TARGET_TEAM with Hardened Runtime"
    fi
  fi

  if dir=$(fm_gh_read_cursor_path_dir 2>/dev/null); then
    work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-read-router-verify.XXXXXX") || die "cannot create a scratch directory"
    if build_router "$work/gh" "$command" "$PRODUCT_TARGET" 2>/dev/null; then
      router_digest=$(sha256_of "$dir/gh")
      expected_digest=$(sha256_of "$work/gh")
    else
      router_digest=''
      expected_digest='build-failed'
    fi
    rm -rf -- "$work"
    if [ "$router_digest" = "$expected_digest" ]; then
      report cursor-path ok "$dir/gh routes closed reads to $command"
    else
      report cursor-path FAIL "$dir/gh does not match a fresh router for $command"
    fi
  else
    report cursor-path FAIL "$(cursor_path_state)"
  fi

  report gate unverified "confirm helper launcher identity and Read Only authorization in the App"

  [ "$VERIFY_FAILED" -eq 0 ]
}

cmd_install_path() {
  local command='' dir=$FM_GH_READ_CURSOR_DIR_DEFAULT answer status work
  while [ $# -gt 0 ]; do
    case "$1" in
    --command) [ $# -ge 2 ] || die "--command needs a path" 2; command=$2; shift 2 ;;
    *) die "unknown install-path argument: $1" 2 ;;
    esac
  done
  [ -n "$command" ] || die "install-path needs --command <installed command link>" 2
  [ -z "${FM_GH_READ_CURSOR_DIR_OVERRIDE:-}" ] || die "install-path refuses FM_GH_READ_CURSOR_DIR_OVERRIDE"
  [ "$(uname)" = Darwin ] || die "install-path supports macOS only"
  [ -t 0 ] && [ -t 1 ] || die "install-path needs an attended interactive terminal"
  case "$command" in /*) ;; *) die "--command must be an absolute path" ;; esac
  fm_gh_read_resolve_protected "$command" 0 >/dev/null || die "$command is not a protected executable; enroll the Launcher Bundle first"
  fm_gh_read_cursor_path_dir >/dev/null 2>&1
  status=$?
  [ "$status" -eq 1 ] || die "$dir already exists; inspect it by hand before replacing anything"
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-read-install.XXXXXX") || die "cannot create a build directory"
  build_router "$work/gh" "$command" "$PRODUCT_TARGET" || {
    rm -rf -- "$work"
    die "router build failed"
  }
  printf 'This creates %s (root:wheel, 0755) with a native gh router.\n' "$dir"
  printf 'Accepted closed reads route to %s; every other form routes to %s.\n' "$command" "$PRODUCT_TARGET"
  printf 'Type install to continue: '
  IFS= read -r answer || answer=''
  [ "$answer" = install ] || {
    rm -rf -- "$work"
    die "not confirmed; nothing changed"
  }
  if ! { sudo /bin/mkdir -p -m 0755 "$dir" &&
    sudo /usr/sbin/chown root:wheel "$dir" "$(dirname -- "$dir")" &&
    sudo /bin/chmod 0755 "$dir" "$(dirname -- "$dir")" &&
    sudo /usr/bin/install -o root -g wheel -m 0755 "$work/gh" "$dir/gh"; }; then
    rm -rf -- "$work"
    die "installation failed; inspect $dir"
  fi
  rm -rf -- "$work"
  fm_gh_read_cursor_path_dir >/dev/null || die "the installed directory did not pass its own check; inspect $dir"
  printf 'installed: %s/gh\n' "$dir"
}

case "${1:-}" in
build) shift; cmd_build "$@" ;;
build-router) shift; cmd_build_router "$@" ;;
plan) shift; cmd_plan "$@" ;;
verify) shift; cmd_verify "$@" ;;
install-path) shift; cmd_install_path "$@" ;;
-h | --help) usage ;;
*) usage >&2; exit 2 ;;
esac
