#!/usr/bin/env bash
# fm-test-linux.sh - opt-in: run the shell tests changed on this branch inside a
# Linux container with GNU userland.
#
# macOS ships BSD stat, date, sed and friends, so a fixture that passes locally
# can fail on Linux CI (for example `stat -f ... || stat -c ...`, where GNU
# `stat -f` prints filesystem output before failing). Run this before
# publishing a branch whose tests touch stat, date, or process behavior.
#
# Usage:
#   fm-test-linux.sh [--base <git-ref>] [--list] [tests/<name>.test.sh ...]
#   fm-test-linux.sh -h|--help
#
# With no test paths, the tests are the tests/*.test.sh files that differ from
# the merge base with --base (default: origin/main, else main), including
# uncommitted and untracked ones. A local clone of the repo, overlaid with the
# working tree files, is mounted read-write from a scratch directory, so tests
# see git history and the checkout is never modified. Tests run as the host
# user, not root, to match CI file-mode behavior.
# --list prints the selected tests and exits without a container runtime.
#
# Runtime: FM_CONTAINER_RUNTIME, else docker, else podman. With none installed
# the script stops with exit 2. The image is built from tests/linux/Dockerfile
# (Debian bookworm, GNU coreutils) and tagged fm-test-linux:bookworm.
#
# Exit status: 0 all selected tests passed (or none changed), 1 a test failed,
# 2 usage error or no container runtime.
set -eu

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-test-linux: %s\n' "$1" >&2
  exit 2
}

base=""
list_only=0
tests=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ $# -ge 2 ] || die "--base needs a ref"; base=$2; shift 2 ;;
    --list) list_only=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) tests+=("$1"); shift ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "run inside a git checkout"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dockerfile_dir="$script_dir/../tests/linux"

if [ ${#tests[@]} -eq 0 ]; then
  if [ -z "$base" ]; then
    for ref in origin/main main; do
      if git -C "$root" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then base=$ref; break; fi
    done
  fi
  [ -n "$base" ] || die "no origin/main or main to compare against; pass --base <git-ref>"
  merge_base=$(git -C "$root" merge-base HEAD "$base") || die "no merge base with $base"
  while IFS= read -r path; do
    [ -f "$root/$path" ] && tests+=("$path")
  done < <({
    git -C "$root" diff --name-only --diff-filter=ACMR "$merge_base" --
    git -C "$root" ls-files --others --exclude-standard
  } | sort -u | grep -E '^tests/[^/]+\.test\.sh$' || true)
fi

if [ ${#tests[@]} -eq 0 ]; then
  echo "fm-test-linux: no changed shell tests"
  exit 0
fi

if [ "$list_only" = 1 ]; then
  printf '%s\n' "${tests[@]}"
  exit 0
fi

runtime=${FM_CONTAINER_RUNTIME:-}
if [ -z "$runtime" ]; then
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then runtime=$candidate; break; fi
  done
fi
{ [ -n "$runtime" ] && command -v "$runtime" >/dev/null 2>&1; } ||
  die "no container runtime found; install docker or podman, or set FM_CONTAINER_RUNTIME"

image=fm-test-linux:bookworm
"$runtime" build -q -t "$image" "$dockerfile_dir" >/dev/null ||
  die "$runtime could not build $image; is the container engine running?"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-linux.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
git clone -q --local "$root" "$scratch" || die "could not clone $root into the scratch directory"
files=()
while IFS= read -r -d '' path; do
  [ -e "$root/$path" ] && files+=("$path")
done < <(git -C "$root" ls-files -z --cached --others --exclude-standard)
(cd "$root" && printf '%s\0' "${files[@]}" | tar --null -T - -cf -) | tar -C "$scratch" -xf -
while IFS= read -r -d '' path; do
  [ -e "$root/$path" ] || rm -f "$scratch/$path"
done < <(git -C "$scratch" ls-files -z)

printf 'fm-test-linux: %s on %s\n' "${#tests[@]}" "$("$runtime" run --rm "$image" sh -c 'uname -sr')"
failed=()
for t in "${tests[@]}"; do
  if "$runtime" run --rm --user "$(id -u):$(id -g)" -v "$scratch:/work" -w /work -e HOME=/tmp -e TMPDIR=/tmp "$image" bash "$t"; then
    printf 'PASS %s\n' "$t"
  else
    printf 'FAIL %s\n' "$t"
    failed+=("$t")
  fi
done
[ ${#failed[@]} -eq 0 ] || { printf 'fm-test-linux: %s failed\n' "${#failed[@]}" >&2; exit 1; }
