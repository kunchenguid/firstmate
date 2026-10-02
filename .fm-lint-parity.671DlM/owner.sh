#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.671DlM/owner-dep.sh
. "/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M3Z3KYXNCBEJ3335425CCTCB/.fm-lint-parity.671DlM/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
