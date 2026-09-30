#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.SyRWKu/owner-dep.sh
. "/home/futanbear/.no-mistakes/worktrees/5047a2b66307/01M3SXCKVNCEPJ7958END05XJK/.fm-lint-parity.SyRWKu/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
