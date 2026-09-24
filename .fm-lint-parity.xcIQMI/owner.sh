#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.xcIQMI/owner-dep.sh
. "/Users/marsjohn/.no-mistakes/worktrees/45849cd9dd00/01M30G5WGZN31Y0S7BBXB4Y1C2/.fm-lint-parity.xcIQMI/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
