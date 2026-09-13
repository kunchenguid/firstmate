#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.Y0C6mZ/owner-dep.sh
. "/Users/andreylitvinov/.no-mistakes/worktrees/8bd42adffd3c/01M2DJZRSXZZ8H44HVDQAZCJXJ/.fm-lint-parity.Y0C6mZ/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
