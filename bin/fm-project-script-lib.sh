#!/usr/bin/env bash
# bin/fm-project-script-lib.sh - ONE owner for the "a project opts in by
# publishing a script" contract.
#
# Some guarantees only the project can answer: whether a pooled working copy
# still has an owner (`check:worktree-custody`, bin/fm-teardown.sh), or which
# delivered copies it is safe to release back to the pool
# (`pool:release-delivered`, bin/fm-spawn.sh). Firstmate never implements those
# verdicts; it asks the project, and only when the project published one.
#
# The contract, stated once:
#   - Opt-in is presence of that exact key in the project's package.json
#     "scripts". No package.json, or no such key, means the project published
#     nothing and firstmate must behave exactly as it did before.
#   - The manifest, not a grep, is authoritative. A project that looks like it
#     published one but cannot be read is reported as UNCONFIRMED, and each
#     caller applies its own policy - a safety gate refuses, housekeeping warns.
#   - The runner is whichever package manager the project's own lockfile
#     selects, and extra arguments reach the script the way that manager passes
#     them (pnpm directly, npm and yarn behind `--`).
#
# Callers source this file; it defines functions only.

FM_PROJECT_SCRIPT_DECLARED=0
FM_PROJECT_SCRIPT_ABSENT=1
FM_PROJECT_SCRIPT_UNCONFIRMED=2

# Does <dir> publish <script>? Prints nothing.
#   0 declared, 1 absent, 2 published-but-unconfirmable (no node to read it).
fm_project_script_declared() {  # <dir> <script>
  local dir=$1 script=$2
  [ -f "$dir/package.json" ] || return "$FM_PROJECT_SCRIPT_ABSENT"
  # Cheap presence signal first, so a project with no such script never pays
  # for a node process.
  grep -Fq "\"$script\"" "$dir/package.json" 2>/dev/null \
    || return "$FM_PROJECT_SCRIPT_ABSENT"
  command -v node >/dev/null 2>&1 || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  node -e 'const p=require(process.argv[1]);process.exit(p.scripts&&p.scripts[process.argv[2]]?0:1)' \
    "$dir/package.json" "$script" 2>/dev/null \
    || return "$FM_PROJECT_SCRIPT_ABSENT"
  return "$FM_PROJECT_SCRIPT_DECLARED"
}

fm_project_script_manager() {  # <dir>
  local dir=$1
  if [ -f "$dir/pnpm-lock.yaml" ]; then printf 'pnpm\n'
  elif [ -f "$dir/yarn.lock" ]; then printf 'yarn\n'
  else printf 'npm\n'
  fi
}

# Run <dir>'s <script> with <timeout> seconds and any extra arguments,
# preserving its stdout, stderr, and exit status. Exit 127 means the selected
# package manager is not installed, which no caller may read as a verdict.
fm_project_script_run() {  # <dir> <script> <timeout> [args...]
  local dir=$1 script=$2 timeout_secs=$3 manager bound
  shift 3
  manager=$(fm_project_script_manager "$dir")
  command -v "$manager" >/dev/null 2>&1 || return 127
  bound=
  if command -v timeout >/dev/null 2>&1; then bound=timeout
  elif command -v gtimeout >/dev/null 2>&1; then bound=gtimeout
  fi
  local -a argv
  argv=("$manager" run "$script")
  if [ "$#" -gt 0 ]; then
    # pnpm forwards trailing arguments to the script; npm and yarn need `--`.
    [ "$manager" = pnpm ] || argv+=(--)
    argv+=("$@")
  fi
  if [ -n "$bound" ]; then
    ( cd "$dir" && "$bound" "$timeout_secs" "${argv[@]}" )
  else
    ( cd "$dir" && "${argv[@]}" )
  fi
}
