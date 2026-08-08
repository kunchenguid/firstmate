#!/usr/bin/env bash
# fm-provision-lib.sh - provision a task worktree's project dependencies.
#
# Sourced by bin/fm-spawn.sh. A git worktree carries only tracked files, so the
# gitignored machinery a project needs to RUN its own checks - a Python virtual
# environment, an installed node_modules - never arrives with it. Treehouse
# v2.0.0 exposes no setup hook, so a freshly leased worktree has the source and
# none of the tooling. A lane in that state cannot run the project's tests,
# formatters, or browser checks, so it ships on another agent's evidence or on
# none. This library closes that gap between worktree verification and endpoint
# launch.
#
# CONTRACT (exactly two non-success outcomes, one decision point each)
#   A CAPABILITY GAP is work this provisioner was never able to do here. It
#   WARNS, is RECORDED in the provisioning summary, and LAUNCHES the lane
#   unprovisioned for that component. Refusing a gap would be strictly worse
#   than the behavior this library replaced, which launched every lane
#   unprovisioned; it would also brick the spawn on projects this feature
#   exists to serve. The gaps are: more provisionable components than the
#   FM_PROVISION_MAX_COMPONENTS budget allows, a component whose directory lies
#   deeper below the worktree root than FM_PROVISION_SCAN_DEPTH, a Python
#   component declaring a pyproject.toml but neither a uv.lock nor a
#   requirements.txt, a recognized-but-unsupported
#   package manager (yarn, bun), a JS component whose package manager is neither
#   named by package.json's packageManager field nor implied by a single
#   lockfile, a declared Node major that cannot be found under the standard
#   version-manager directories, components declaring conflicting Node majors,
#   a node that does not run, a missing installer (uv, npm, pnpm), a
#   pinned-Node toolchain directory that cannot be established under the
#   provisioning cache, a pip declaration reaching more requirements files than
#   this library traverses, a dependency scan that outlives its own bound, and a
#   host missing a tool provisioning itself needs
#   (python3, or any bounded-execution mechanism). Every gap is named on stderr,
#   in the provisioning log, in the summary the caller records as task metadata,
#   and - the only one of the four the LANE itself can read - in
#   .fm-provisioning.md at the root of the worktree, git-excluded before it is
#   written and removed before every lease decides anything, so a pool slot
#   never carries one task's report into the next. What was NOT provisioned is
#   as loud as what was, on a surface the crewmate reaches without knowing the
#   firstmate home layout.
#   A FAILURE is an attempt that was made and did not complete. It REFUSES the
#   spawn and names both the cause and the opt-out, because a lane launched on
#   a half-built environment is worse than no lane. The failures are: a tunable
#   that is not a positive integer, a worktree path that is not a directory, a
#   dependency scan that cannot traverse it, a UV_PROJECT_ENVIRONMENT that would
#   put an environment where the probe cannot see it, a component that declares
#   no ignored install directory to protect, an install directory the project
#   does not already ignore (provisioning refuses rather than hiding it: the only
#   exclusion git would honour for a linked worktree lives in the MAIN clone, and
#   installing into a path git can see strands the pool lease when the abort path
#   cannot prove the worktree returnable), declared manifests that cannot be
#   resolved for a component, an
#   install that fails, exceeds its bound, or is killed by a signal, an install
#   that leaves no working interpreter, a readiness probe that fails after
#   installing, an environment signature that is empty or unprovable, a declared
#   manifest that exists but yields no digest, and a
#   cache directory, log, record, or previous lease's report that cannot be
#   written or removed.
#   fm_provision_gap and fm_provision_fail are those two decision points, and
#   every non-success outcome goes through exactly one of them, so a capability
#   limit added later cannot become a spawn refusal by accident.
#   A NOTE is neither, and is the one thing a SUCCESSFUL component can also
#   carry: something the installer's own consistency check reported about an
#   environment that installed and runs. `uv pip check` verifies that installed
#   metadata is mutually consistent, which is not the same thing as usable - a
#   project using uv's [tool.uv] override-dependencies or constraint-dependencies
#   installs a version some package's own metadata calls incompatible ON PURPOSE
#   - so it is announced, recorded beside the component's state, and carried into
#   the lane's report, while the component still counts as provisioned. The
#   proofs of usability stay failures: the interpreter must exist, be executable,
#   run, and report the runtime recorded for it. There are two note tokens and
#   they are not interchangeable: inconsistent-dependency-metadata is a verdict
#   the check produced, and unverified-dependency-metadata means the check could
#   not be run at all, which is never reported as though it had found something.
#   A worktree that declares no recognized dependency manifest is a clean
#   no-op, and so is a traversal that succeeds and finds nothing.
#   fm-spawn.sh's --no-provision flag and the home-local
#   config/worktree-provision file are the opt-out; the caller owns reading
#   them.
#
# DETECTION is per-project and declaration-driven. Nothing here knows the name
# of any project, and no interpreter or runtime version is hardcoded: uv reads
# the project's own .python-version / requires-python, and a Node pin is read
# from the project's .nvmrc or package.json engines.node. A stack this library
# does not recognize provisions nothing.
#
# SUPPORTED ECOSYSTEMS (one component per directory per language)
#   uv      uv.lock            -> uv sync --frozen
#   pip     requirements.txt   -> uv venv --clear .venv + uv pip install -r ...
#   npm     package-lock.json  -> npm ci
#   pnpm    pnpm-lock.yaml     -> pnpm install --frozen-lockfile
# Python always goes through uv, never pip/venv directly (AGENTS.md toolchain
# convention). A directory whose pyproject.toml declares a project - a [project],
# [build-system], or [tool.poetry] table - with neither of those
# two Python manifests is a capability gap: choosing an installer for a lockless
# project is a design decision this library has not made, and provisioning
# something it cannot install from a committed declaration would be a guess. It
# is still ENUMERATED and reported, because the lane silently lacking an
# environment it needs to validate is the failure this library exists to
# prevent. A pyproject.toml carrying only tool configuration - [tool.ruff],
# [tool.black], [tool.pytest.ini_options] - declares nothing to provision and is
# a clean no-op, because a false line on the lane's report costs more than it
# buys on the one surface built for signal.
# The JS package manager is read from what the project DECLARES -
# package.json's corepack `packageManager` field - and only falls back to the
# lockfile when the project declares nothing; lockfile-filename precedence is
# convention, not evidence, and a directory carrying two committed lockfiles
# would otherwise be resolved by this library's opinion rather than by what the
# project actually installs with. yarn and bun, and a JS component whose
# manager cannot be determined, are capability gaps: they are left
# unprovisioned and reported, never installed with a guessed installer.
#
# CACHING. Every component carries a fingerprint over its own manifests - the
# installer's configuration files (.npmrc, uv.toml) among them, because they
# decide what the installer actually produces without any lockfile changing -
# plus the resolved installer and runtime identity. A cache hit needs BOTH a
# matching fingerprint AND a live readiness probe of the installed environment,
# because a pool slot's ignored directories survive leases but a previous agent
# may have deleted or broken them - directory existence alone is not readiness
# (data/v3-env-repair-e3/report.md, 2026-08-05). Records live in firstmate's
# state dir, never in the worktree, so provisioning cannot dirty a checkout that
# teardown and the freshness proof both require to be clean.
#
# BOUNDS. Every install and probe runs through fm_provision_run_bounded, which
# follows the established timeout/gtimeout/perl-alarm pattern (this machine has
# neither timeout nor gtimeout). With no bounding mechanism available nothing is
# run at all - the whole worktree is a capability gap - rather than risking an
# unbounded install wedging a spawn.
#
# Tunables (seconds unless noted). Each is validated as a positive integer
# before anything is scanned or run, and the defaults are unset-only, so an
# explicitly empty or zero override refuses rather than silently becoming the
# default and removing the bound it was meant to set.
#   FM_PROVISION_SCAN_DEPTH=4        how deep below the worktree root a manifest
#                                    is still classified and installed; the
#                                    traversal goes exactly one level further,
#                                    so the first component past the bound is
#                                    reported as a capability gap rather than
#                                    dropped in silence, and anything past THAT
#                                    is not enumerated at all
#   FM_PROVISION_MAX_COMPONENTS=8    provision at most this many components,
#                                    the ones the task's brief names first;
#                                    the rest are reported as a capability gap
#   FM_PROVISION_INSTALL_TIMEOUT=600 per-component install bound
#   FM_PROVISION_PROBE_TIMEOUT=60    per-readiness-probe bound

FM_PROVISION_SCAN_DEPTH=${FM_PROVISION_SCAN_DEPTH-4}
FM_PROVISION_MAX_COMPONENTS=${FM_PROVISION_MAX_COMPONENTS-8}
FM_PROVISION_INSTALL_TIMEOUT=${FM_PROVISION_INSTALL_TIMEOUT-600}
FM_PROVISION_PROBE_TIMEOUT=${FM_PROVISION_PROBE_TIMEOUT-60}

# Bumped whenever a recorded field's meaning changes; a record from another
# schema is treated as a miss rather than misread.
FM_PROVISION_CACHE_SCHEMA=4

# Outputs of fm_provision_worktree, read by the sourcing caller (fm-spawn.sh),
# so shellcheck cannot see their consumers from this file alone.
# shellcheck disable=SC2034
FM_PROVISION_SUMMARY=
# shellcheck disable=SC2034
FM_PROVISION_PATH_PREFIX=

# --- primitives -------------------------------------------------------------

# Where a component lives. Every component is named by a path RELATIVE to the
# worktree, and the worktree root itself is named "."; one helper owns that
# convention so a new call site cannot get the special case wrong.
fm_provision_component_dir() {  # <worktree> <relative-dir>
  local wt=$1 rel=$2
  if [ "$rel" = . ]; then
    printf '%s' "$wt"
  else
    printf '%s/%s' "$wt" "$rel"
  fi
}

fm_provision_sha256() {  # reads stdin, prints the hex digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  fi
}

# Which bounding mechanism this host has. The probe resolves into
# FM_PROVISION_BOUND_KIND in the caller's own shell and callers read that
# variable, so the resolution really is paid once per run - a resolver called
# through a command substitution would assign in a subshell and be re-probed by
# every caller after it. "none" provisions nothing, because nothing can be run
# under a bound this host does not have.
FM_PROVISION_BOUND_KIND=
fm_provision_resolve_bound_kind() {
  [ -z "$FM_PROVISION_BOUND_KIND" ] || return 0
  if command -v timeout >/dev/null 2>&1; then FM_PROVISION_BOUND_KIND=timeout
  elif command -v gtimeout >/dev/null 2>&1; then FM_PROVISION_BOUND_KIND=gtimeout
  elif command -v perl >/dev/null 2>&1; then FM_PROVISION_BOUND_KIND=perl
  else FM_PROVISION_BOUND_KIND=none
  fi
}

# Run a command with cwd and a hard wall-clock bound, preserving its exit code.
# Exit 124 means the bound expired; exit 125 means this host cannot bound at all;
# exit 126 means the child's status could not be determined; exit 127 means the
# command could not be executed. A signal-terminated child is reported as
# 128 + signal, so an installer the OOM killer reaps can never be mistaken for a
# successful install. The perl child exits explicitly when exec fails rather than
# falling through into the parent's tail, so a missing command can never be
# reported as a success that produced no output.
fm_provision_run_bounded() {  # <seconds> <cwd> <cmd> [args...]
  local secs=$1 cwd=$2
  shift 2
  fm_provision_resolve_bound_kind
  case "$FM_PROVISION_BOUND_KIND" in
    timeout)  ( cd "$cwd" && timeout "$secs" "$@" ) ;;
    gtimeout) ( cd "$cwd" && gtimeout "$secs" "$@" ) ;;
    perl)     ( cd "$cwd" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; my $reaped = waitpid $pid, 0; my $status = $?; exit 126 if $reaped != $pid; exit(($status & 127) ? 128 + ($status & 127) : $status >> 8)' "$secs" "$@" ) ;;
    *)        return 125 ;;
  esac
}

# Same bound, with all output appended to the provisioning log.
fm_provision_run_logged() {  # <seconds> <cwd> <log> <cmd> [args...]
  local secs=$1 cwd=$2 log=$3 rc=0
  shift 3
  printf '\n$ (cd %s) %s\n' "$cwd" "$*" >> "$log"
  fm_provision_run_bounded "$secs" "$cwd" "$@" >> "$log" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >> "$log"
  return "$rc"
}

# First line of a tool's own version output; empty when the tool is absent.
fm_provision_tool_version() {  # <tool> [args...]
  local tool=$1 out=
  shift
  command -v "$tool" >/dev/null 2>&1 || return 1
  out=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$PWD" "$tool" "$@" 2>/dev/null | head -1) || return 1
  printf '%s' "$out"
}

# --- home configuration -----------------------------------------------------

# Resolve the home's provisioning posture from config/worktree-provision.
# Absent or "on" enables it; "off" disables it. Anything else is a refusal,
# because a typo must not silently disable the gate this exists to hold.
fm_provision_mode() {  # <config-dir>
  local config_dir=${1:-} file value
  file="$config_dir/worktree-provision"
  [ -n "$config_dir" ] && [ -e "$file" ] || { printf 'on'; return 0; }
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'invalid'
    return 1
  fi
  value=$(tr -d '[:space:]' < "$file")
  case "$value" in
    ''|on) printf 'on' ;;
    off) printf 'off' ;;
    *) printf 'invalid'; return 1 ;;
  esac
}

# --- detection --------------------------------------------------------------

# Exact element membership, never a pattern match over a joined list: a value
# that contains another as a token would otherwise compare equal and silently
# drop a real entry.
fm_provision_list_has() {  # <needle> [element...]
  local needle=$1 item
  shift
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# The JS package manager a directory DECLARES, through package.json's corepack
# `packageManager` field. This is evidence; a lockfile's filename is only
# convention. Empty when the project declares nothing, which is also what a
# host without python3 and a host with no bounding mechanism see - both
# provision nothing anyway, and the parse goes through fm_provision_run_bounded
# like every other one so the second of those decisions is reached before this
# reads a project-controlled file at all.
fm_provision_declared_js_manager() {  # <component-dir>
  local dir=$1 raw=''
  [ -f "$dir/package.json" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  raw=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
    python3 - "$dir/package.json" 2>/dev/null <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], "rb") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
declared = data.get("packageManager")
if not isinstance(declared, str):
    sys.exit(0)
name = declared.strip().split("@", 1)[0].strip().lower()
if re.fullmatch(r"[a-z][a-z0-9-]*", name):
    sys.stdout.write(name)
PY
  ) || raw=
  printf '%s' "$raw"
}

# The component directories a worktree declares, deduplicated and
# deterministically ordered, as "<scope> <relative-dir>" lines - "component" for
# a directory within FM_PROVISION_SCAN_DEPTH and "below-depth" for one past it,
# relative to the worktree ("." for its root). Only `find` runs here. Deciding
# WHICH ecosystem a directory carries reads the project's own package.json
# through python3, so that step is separate: the caller has to be able to decide
# this host can bound nothing - and therefore provisions nothing at all - before
# any such read is reached.
#
# The traversal descends exactly ONE level past FM_PROVISION_SCAN_DEPTH. The
# bound is real - this is a leased pool slot whose gitignored directories
# survive leases, so traversal cost is driven by whatever the last lane left
# behind, not by the repository - but a bound that stops exactly at the limit
# makes the first component past it invisible to every surface this library
# reports on: the summary, the log, the metadata, and the lane's own report
# would each name only the shallower components and read as complete. Going one
# level further costs nothing and turns that silent drop into a named gap, which
# is what a monorepo carrying platform/services/billing/api/requirements.txt
# needs from its crewmate's report. A manifest more than one level past the
# bound is genuinely not enumerated; FM_PROVISION_SCAN_DEPTH is the knob for it.
# The find itself runs under the same bound as every other traversal here, so a
# pathological or leftover-heavy tree cannot wedge a spawn - except on a host
# with no bounding mechanism at all, which provisions nothing anyway and where
# running it plainly is what still lets the lane's report name what it is not
# getting.
# Returns 0 on success, 1 when the traversal itself failed (a refusal), and 2
# when it could not finish within its bound (a whole-worktree capability gap).
# None of those is the same thing as a traversal that succeeded and found
# nothing.
fm_provision_scan() {  # <worktree>
  local wt=$1 file dir rel depth separators found manifest_output rc=0
  local -a manifests=() dirs=() shallow=() deep=()
  local -a find_args=(
    "$wt" -maxdepth "$((FM_PROVISION_SCAN_DEPTH + 1))"
    '(' -name .git -o -name node_modules -o -name .venv -o -name venv
        -o -name .tox -o -name .nox -o -name .mypy_cache -o -name __pycache__
        -o -name .pytest_cache -o -name site-packages -o -name vendor
        -o -name target -o -name dist -o -name build -o -name .next
        -o -name .turbo -o -name .gradle -o -name Pods -o -name coverage
        -o -name .treehouse ')' -prune -o
    -type f '(' -name uv.lock -o -name requirements.txt -o -name pyproject.toml
                -o -name package-lock.json -o -name pnpm-lock.yaml
                -o -name yarn.lock -o -name bun.lockb -o -name bun.lock ')'
    -print
  )
  fm_provision_resolve_bound_kind
  if [ "$FM_PROVISION_BOUND_KIND" = none ]; then
    manifest_output=$(find "${find_args[@]}") || return 1
  else
    manifest_output=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$wt" \
      find "${find_args[@]}") || rc=$?
    case "$rc" in
      0) ;;
      124) return 2 ;;
      *) return 1 ;;
    esac
  fi
  manifest_output=$(printf '%s\n' "$manifest_output" | LC_ALL=C sort) || return 1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    manifests+=("$file")
  done <<< "$manifest_output"
  [ "${#manifests[@]}" -gt 0 ] || return 0

  for file in "${manifests[@]}"; do
    dir=$(dirname "$file")
    rel=${dir#"$wt"}
    rel=${rel#/}
    [ -n "$rel" ] || rel=.
    # Exact element comparison, never a pattern match over a joined list: a
    # directory whose name contains another as a token would otherwise dedup
    # away a real component and leave it silently unprovisioned.
    found=0
    if [ "${#dirs[@]}" -gt 0 ] && fm_provision_list_has "$rel" "${dirs[@]}"; then
      found=1
    fi
    [ "$found" = 0 ] || continue
    dirs+=("$rel")
    # The manifest's own depth, counted the way `find -maxdepth` counts it: a
    # manifest directly in the worktree root is depth 1.
    if [ "$rel" = . ]; then
      depth=1
    else
      separators=${rel//[!\/]}
      depth=$(( ${#separators} + 2 ))
    fi
    if [ "$depth" -le "$FM_PROVISION_SCAN_DEPTH" ]; then
      shallow+=("$rel")
    else
      deep+=("$rel")
    fi
  done
  [ "${#shallow[@]}" -eq 0 ] || printf 'component %s\n' "${shallow[@]}"
  [ "${#deep[@]}" -eq 0 ] || printf 'below-depth %s\n' "${deep[@]}"
}

# Emit "<ecosystem> <relative-dir>" per detected component, deterministically
# ordered. A directory can yield at most one Python and one JS component. Three
# pseudo-ecosystems name a component this library will not install but must
# still report: "js" is a JS component whose package manager could not be
# determined, "python" is a directory whose pyproject.toml declares a project
# while carrying neither a uv.lock nor a requirements.txt, and "unscanned" is a
# directory past FM_PROVISION_SCAN_DEPTH. The caller records each as a
# capability gap rather than guessing an installer the project does not use.
# The scan lines can be passed in by a caller that already scanned -
# fm_provision_worktree does, so its host-prerequisite decision lands before
# anything here reads a project-controlled file - and are scanned for otherwise.
# Returns non-zero when the traversal itself failed, which is a refusal and not
# the same thing as a traversal that succeeded and found nothing.
fm_provision_detect() {  # <worktree> [<scan-line>...]
  local wt=$1 dir rel scope line entry member workspace_info scanned declared declared_rc=0
  shift
  local -a lines=() js_managers=() candidates=() covered=()
  if [ "$#" -gt 0 ]; then
    lines=("$@")
  else
    scanned=$(fm_provision_scan "$wt") || return $?
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      lines+=("$line")
    done <<< "$scanned"
  fi
  [ "${#lines[@]}" -gt 0 ] || return 0

  # A uv workspace member declares a pyproject.toml and no lock of its own, and
  # is nonetheless installed by its root's `uv sync --all-packages`. Reporting
  # every member as an unprovisioned Python component would bury the real gaps
  # this enumeration exists to surface, so the workspace's own membership - the
  # same resolution that decides --all-packages - is what excuses them. Resolved
  # only when some directory actually looks lockless, so an ordinary worktree
  # pays nothing for it.
  for line in "${lines[@]}"; do
    [ "${line%% *}" = component ] || continue
    rel=${line#* }
    dir=$(fm_provision_component_dir "$wt" "$rel")
    if [ ! -f "$dir/uv.lock" ] && [ ! -f "$dir/requirements.txt" ]; then
      declared_rc=0
      fm_provision_python_project_declared "$dir" || declared_rc=$?
      [ "$declared_rc" -eq 1 ] || candidates+=("$rel")
    fi
  done
  if [ "${#candidates[@]}" -gt 0 ]; then
    for line in "${lines[@]}"; do
      [ "${line%% *}" = component ] || continue
      rel=${line#* }
      dir=$(fm_provision_component_dir "$wt" "$rel")
      [ -f "$dir/uv.lock" ] || continue
      workspace_info=$(fm_provision_uv_workspace_info "$dir") || continue
      while IFS= read -r entry; do
        case "$entry" in */pyproject.toml) ;; *) continue ;; esac
        member=${entry%/pyproject.toml}
        [ -n "$member" ] || continue
        if [ "$rel" = . ]; then
          covered+=("$member")
        else
          covered+=("$rel/$member")
        fi
      done <<< "$workspace_info"
    done
  fi

  for line in "${lines[@]}"; do
    scope=${line%% *}
    rel=${line#* }
    if [ "$scope" != component ]; then
      printf 'unscanned %s\n' "$rel"
      continue
    fi
    dir=$(fm_provision_component_dir "$wt" "$rel")
    # Python: uv-managed project wins over a bare requirements install, and a
    # project declaring neither is named rather than passed over in silence.
    if [ -f "$dir/uv.lock" ]; then
      printf '%s %s\n' uv "$rel"
    elif [ -f "$dir/requirements.txt" ]; then
      printf '%s %s\n' pip "$rel"
    else
      declared_rc=0
      fm_provision_python_project_declared "$dir" || declared_rc=$?
      if [ "$declared_rc" -ne 1 ] \
        && ! { [ "${#covered[@]}" -gt 0 ] && fm_provision_list_has "$rel" "${covered[@]}"; }; then
        printf 'python %s\n' "$rel"
      fi
    fi
    # JS: what the project DECLARES decides the package manager, and a lockfile
    # is only the fallback when it declares nothing. A directory carrying more
    # than one lockfile while declaring nothing is undecidable, and a declared
    # manager whose lockfile is absent is a contradiction; both emit "js" so the
    # caller leaves that component unprovisioned instead of running an installer
    # the project never validated against.
    js_managers=()
    [ ! -f "$dir/pnpm-lock.yaml" ] || js_managers+=(pnpm)
    [ ! -f "$dir/yarn.lock" ] || js_managers+=(yarn)
    if [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
      js_managers+=(bun)
    fi
    [ ! -f "$dir/package-lock.json" ] || js_managers+=(npm)
    if [ "${#js_managers[@]}" -gt 0 ]; then
      declared=$(fm_provision_declared_js_manager "$dir")
      if [ -n "$declared" ]; then
        if fm_provision_list_has "$declared" "${js_managers[@]}"; then
          printf '%s %s\n' "$declared" "$rel"
        else
          printf 'js %s\n' "$rel"
        fi
      elif [ "${#js_managers[@]}" -eq 1 ]; then
        printf '%s %s\n' "${js_managers[0]}" "$rel"
      else
        printf 'js %s\n' "$rel"
      fi
    fi
  done
}

# Whether a directory's pyproject.toml declares a PROJECT rather than only tool
# configuration. A pyproject.toml carrying nothing but [tool.ruff], [tool.black],
# or [tool.pytest.ini_options] declares no dependencies and no package, so there
# is nothing there to provision and naming it as a gap would put a false line on
# the one surface this feature built for signal - and trip the "left N of M
# components UNPROVISIONED" warning on a worktree that is in fact complete.
# Returns 0 when a packaging or dependency table is declared, 1 when the file is
# tool configuration only, and 2 when it exists but could not be read, which is
# reported rather than passed over: a file this cannot read is not a file it can
# call empty.
fm_provision_python_project_declared() {  # <component-dir>
  local file=$1/pyproject.toml rc=0
  [ -f "$file" ] || return 1
  # Bounded like every other read of a project-controlled file in this library: a
  # pathological pyproject.toml must not be able to hold a spawn open. The
  # reserved bound codes fall through to 2 below, which is reported rather than
  # treated as "declares nothing".
  fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$1" \
    env LC_ALL=C grep -qE '^[[:space:]]*\[[[:space:]]*(project|build-system|tool\.poetry)[].]' \
    "$file" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) return 2 ;;
  esac
}

fm_provision_uv_workspace_info() {  # <component-dir>
  local dir=$1
  [ -f "$dir/pyproject.toml" ] || return 0
  fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
    python3 - "$dir" <<'PY'
import ast
import os
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
lines = (root / "pyproject.toml").read_text(encoding="utf-8").splitlines()
start = next((index for index, line in enumerate(lines) if re.fullmatch(r"\s*\[tool\.uv\.workspace\]\s*(?:#.*)?", line)), None)
if start is None:
    raise SystemExit(0)
print("workspace")

def without_comment(line):
    quote = None
    escaped = False
    out = []
    for char in line:
        if escaped:
            out.append(char)
            escaped = False
            continue
        if quote == '"' and char == "\\":
            out.append(char)
            escaped = True
            continue
        if char in ("'", '"'):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
            out.append(char)
            continue
        if char == "#" and quote is None:
            break
        out.append(char)
    return "".join(out)

def bracket_depth(value):
    quote = None
    escaped = False
    depth = 0
    for char in value:
        if escaped:
            escaped = False
            continue
        if quote == '"' and char == "\\":
            escaped = True
            continue
        if char in ("'", '"'):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
            continue
        if quote is None:
            depth += (char == "[") - (char == "]")
    return depth

values = {}
index = start + 1
while index < len(lines):
    line = without_comment(lines[index]).strip()
    if line.startswith("["):
        break
    match = re.match(r"^(members|exclude)\s*=\s*(.*)$", line)
    if not match:
        index += 1
        continue
    key, value = match.groups()
    if key in values:
        raise SystemExit(1)
    while bracket_depth(value) > 0:
        index += 1
        if index >= len(lines):
            raise SystemExit(1)
        value += "\n" + without_comment(lines[index])
    try:
        parsed = ast.literal_eval(value)
    except (SyntaxError, ValueError):
        raise SystemExit(1)
    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        raise SystemExit(1)
    values[key] = parsed
    index += 1

members = values.get("members", [])
excludes = values.get("exclude", [])

def matches(patterns):
    found = set()
    for pattern in patterns:
        if os.path.isabs(pattern):
            raise SystemExit(1)
        for candidate in root.glob(pattern):
            resolved = candidate.resolve()
            try:
                resolved.relative_to(root)
            except ValueError:
                raise SystemExit(1)
            if resolved.is_dir():
                found.add(resolved)
    return found

member_dirs = matches(members) - matches(excludes)
paths = []
for member in member_dirs:
    manifest = member / "pyproject.toml"
    if not manifest.is_file():
        continue
    paths.append(manifest.relative_to(root).as_posix())
    python_version = member / ".python-version"
    if python_version.is_file():
        paths.append(python_version.relative_to(root).as_posix())
for path in sorted(paths):
    print(path)
PY
}

# One parser for the real requirements.txt grammar, shared by the fingerprint's
# file list and the readiness check so the two can never disagree about what a
# component declares. It accepts what pip accepts: -r/-c includes, -e editable
# installs, --index-url and its siblings, standalone --hash lines, VCS, URL and
# local-path requirements, extras, environment markers, inline comments, and
# line continuations.
#   files - print every requirements file reached, relative to the component
#   ready - verify every requirement whose package identity is determinable
# A local editable requirement - `-e .`, which is about as common as a
# requirements.txt gets - is verified from the artifacts the installer ITSELF
# wrote: the PEP 610 direct_url.json beside a dist-info, and the .pth an editable
# install drops into site-packages. Without that it would be permanently
# unverifiable, and a component carrying one line of it would pay a full
# `uv venv --clear` plus reinstall on every single lease forever.
# Exit 0 succeeded. In `ready`, 1 means a declared package is not installed and
# 2 means the declaration could not be determined; a line whose package identity
# cannot be established cheaply yields 2, which the caller treats as a cache MISS
# - never a hit, and never an error that would make the miss permanent and
# silent. In `files`, 1 means an include could not be read (an attempt that
# failed) and 2 means the include graph exceeded MAX_FILES (a capability limit);
# both withhold the file list, because fingerprinting a traversed prefix would be
# a false cache hit the moment an untraversed include changes.
fm_provision_pip_parse() {  # <files|ready> <component-dir> <venv> [requirements-file...]
  local dir=$2
  fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
    python3 - "$@" <<'PY'
import json
import os
import pathlib
import re
import sys
from urllib.parse import unquote, urlparse

mode = sys.argv[1]
root = pathlib.Path(sys.argv[2]).resolve()
venv = pathlib.Path(sys.argv[3])
roots = [pathlib.Path(path) for path in sys.argv[4:]]

MAX_FILES = 64
INCLUDE = ("-r", "--requirement", "-c", "--constraint")
EDITABLE = ("-e", "--editable")
REMOTE = ("git+", "hg+", "svn+", "bzr+", "file:", "http:", "https:")
URLISH = ("git+", "hg+", "svn+", "bzr+", "./", "../", "/", "~/", "file:", "http:", "https:")
ARCHIVE = (".whl", ".zip", ".tar.gz", ".tar.bz2", ".tar.xz")
SPECIFIER = re.compile(r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^]]*\])?\s*(?P<rest>.*)$")

visited = []
seen = set()
declared = set()
editables = set()
unreadable = False
unverifiable = False
truncated = False


def strip_comment(line):
    index = 0
    while True:
        index = line.find("#", index)
        if index < 0:
            return line
        if index == 0 or line[index - 1] in " \t":
            return line[:index]
        index += 1


def logical_lines(text):
    buffer = ""
    for raw in text.splitlines():
        line = strip_comment(raw)
        if line.rstrip().endswith("\\"):
            buffer += line.rstrip()[:-1]
            continue
        buffer += line
        yield buffer
        buffer = ""
    if buffer:
        yield buffer


def visit(path):
    global unreadable, unverifiable, truncated
    try:
        resolved = path.resolve()
        text = resolved.read_text(encoding="utf-8", errors="strict")
    except (OSError, ValueError, UnicodeDecodeError):
        unreadable = True
        return
    if resolved in seen:
        return
    if len(seen) >= MAX_FILES:
        truncated = True
        return
    seen.add(resolved)
    visited.append(resolved)
    for line in logical_lines(text):
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        token = parts[0]
        rest = parts[1] if len(parts) > 1 else ""
        base = token.split("=", 1)[0]
        if base in INCLUDE:
            target = token.split("=", 1)[1] if "=" in token else rest.strip()
            if not target:
                unreadable = True
                continue
            visit(resolved.parent / target)
            continue
        if base in EDITABLE:
            target = token.split("=", 1)[1] if "=" in token else rest.strip()
            target = target.split(";", 1)[0].strip()
            if target.endswith("]") and "[" in target:
                target = target[: target.rindex("[")].strip()
            lowered = target.lower()
            if not target or "://" in lowered or lowered.startswith(REMOTE):
                # A VCS or URL editable names no local tree to look for, so its
                # identity stays undeterminable and the caller says so.
                unverifiable = True
                continue
            # Relative to the component root, which is the directory the install
            # itself ran in.
            editables.add(os.path.realpath(os.path.join(str(root), os.path.expanduser(target))))
            continue
        if token.startswith("-"):
            continue
        requirement = line.split(";", 1)[0].strip()
        lowered = requirement.lower()
        if (
            not requirement
            or requirement in (".", "..")
            or "://" in lowered
            or lowered.startswith(URLISH)
            or lowered.endswith(ARCHIVE)
        ):
            unverifiable = True
            continue
        match = SPECIFIER.match(requirement)
        tail = match.group("rest").strip() if match else "?"
        if not match or (tail and tail[0] not in "=<>!~@"):
            unverifiable = True
            continue
        declared.add(match.group("name"))


for path in roots:
    visit(path)

if mode == "files":
    # Either way the declared set is unknown, so the caller must not fingerprint
    # the partial one it can see - a fingerprint over the traversed prefix is a
    # FALSE CACHE HIT the moment an untraversed include changes. An include that
    # cannot be read is an attempt that failed; a graph past MAX_FILES is a
    # capability limit, and the two exit distinctly so the caller can refuse the
    # first and leave the component unprovisioned for the second.
    if unreadable:
        raise SystemExit(1)
    if truncated:
        raise SystemExit(2)
    for path in visited:
        print(os.path.relpath(path, root))
    raise SystemExit(0)

site_dirs = [path for path in venv.glob("lib*/python*/site-packages") if path.is_dir()]
if not site_dirs:
    raise SystemExit(1)


def installed_editable_paths():
    """Every local tree site-packages says an editable install points at.

    Read from what the installer wrote and nothing else: PEP 610's
    direct_url.json beside a dist-info, and the .pth an editable install leaves
    behind (PEP 660's __editable__*.pth names the package's source directory,
    which can sit under the project root rather than at it).
    """
    found = set()
    for site_dir in site_dirs:
        for dist in site_dir.glob("*.dist-info"):
            try:
                data = json.loads((dist / "direct_url.json").read_text(encoding="utf-8"))
            except (OSError, ValueError, UnicodeDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            info = data.get("dir_info")
            url = data.get("url")
            if not isinstance(info, dict) or not info.get("editable") or not isinstance(url, str):
                continue
            parsed = urlparse(url)
            if parsed.scheme != "file" or not parsed.path:
                continue
            found.add(os.path.realpath(unquote(parsed.path)))
        for pth in site_dir.glob("*.pth"):
            try:
                text = pth.read_text(encoding="utf-8", errors="strict")
            except (OSError, ValueError, UnicodeDecodeError):
                continue
            for entry in text.splitlines():
                entry = entry.strip()
                if not entry or entry.startswith("#") or entry.startswith(("import ", "import\t")):
                    continue
                if os.path.isabs(entry) and os.path.isdir(entry):
                    found.add(os.path.realpath(entry))
    return found


if editables:
    installed = installed_editable_paths()
    for target in sorted(editables):
        prefix = target + os.sep
        if not any(path == target or path.startswith(prefix) for path in installed):
            # The tree is declared editable but nothing in site-packages points
            # at it. Whether the install never happened or this installer leaves
            # no artifact naming it, the honest answer is that it could not be
            # verified - which is a miss that explains itself, never a hit.
            unverifiable = True
            break
for name in sorted(declared):
    normalized = re.sub(r"[-_.]+", "_", name).lower()
    found = any(
        (candidate / "METADATA").is_file()
        for site_dir in site_dirs
        for candidate in site_dir.glob("%s-*.dist-info" % normalized)
    )
    if not found:
        raise SystemExit(1)
raise SystemExit(2 if (unreadable or unverifiable or truncated) else 0)
PY
}

# The requirements files a pip component reaches through -r/-c includes. A
# component whose real declaration lives in an included file must be
# fingerprinted on what it actually installs; without this, editing that
# include would be a false cache HIT.
fm_provision_pip_included_files() {  # <component-dir>
  local dir=$1 name
  local -a requirements=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    requirements+=("$dir/$name")
  done < <(fm_provision_pip_requirements "$dir")
  [ "${#requirements[@]}" -gt 0 ] || return 0
  fm_provision_pip_parse files "$dir" "$dir/.venv" "${requirements[@]}" 2>/dev/null
}

# The files whose content defines a component's fingerprint. Only files that
# exist are listed, so an added or removed optional manifest is itself a change.
# The installer's own configuration is part of that declaration: .npmrc decides
# the registry npm and pnpm install from, what they omit, and pnpm's
# node-linker, and uv.toml carries uv configuration that pyproject.toml does
# not. A component whose config changed with no lockfile change installs a
# different tree, so leaving them out would make the next lease a confidently
# wrong cache HIT against a tree built under superseded configuration.
# Returns 1 when the declaration could not be read at all and 2 when it is
# larger than this library will traverse, so the caller can refuse the first and
# leave the component unprovisioned for the second.
fm_provision_manifests() {  # <worktree> <ecosystem> <relative-dir>
  local wt=$1 eco=$2 rel=$3 dir name workspace_info included rc=0
  dir=$(fm_provision_component_dir "$wt" "$rel")
  local -a names=()
  case "$eco" in
    uv) names=(uv.lock uv.toml pyproject.toml .python-version) ;;
    pip)
      names=(requirements.txt requirements-dev.txt requirements-test.txt
             requirements_dev.txt requirements_test.txt
             constraints.txt uv.toml pyproject.toml .python-version)
      ;;
    npm) names=(package-lock.json package.json .npmrc .nvmrc) ;;
    pnpm) names=(pnpm-lock.yaml package.json pnpm-workspace.yaml .npmrc .nvmrc) ;;
    *) return 0 ;;
  esac
  for name in "${names[@]}"; do
    [ -f "$dir/$name" ] || continue
    printf '%s\n' "$name"
  done
  if [ "$eco" = uv ]; then
    workspace_info=$(fm_provision_uv_workspace_info "$dir") || return 1
    while IFS= read -r name; do
      [ -n "$name" ] && [ "$name" != workspace ] || continue
      printf '%s\n' "$name"
    done <<< "$workspace_info"
  fi
  if [ "$eco" = pip ]; then
    included=$(fm_provision_pip_included_files "$dir") || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if fm_provision_list_has "$name" "${names[@]}"; then
        continue
      fi
      printf '%s\n' "$name"
    done <<< "$included"
  fi
}

# The requirements files a pip component installs: requirements.txt plus the
# conventional dev/test companions. Deliberately not a requirements*.txt glob,
# which would sweep in mutually exclusive variants.
fm_provision_pip_requirements() {  # <component-dir>
  local dir=$1 name
  for name in requirements.txt requirements-dev.txt requirements-test.txt \
    requirements_dev.txt requirements_test.txt; do
    [ -f "$dir/$name" ] || continue
    printf '%s\n' "$name"
  done
}

# --- node runtime resolution ------------------------------------------------

# The Node major version a component pins, or empty when it declares none.
# .nvmrc is an exact pin by definition. engines.node is accepted only in
# unambiguous single-major forms; a real range ('>=18 <21', '18 || 20') leaves
# the runtime unpinned rather than guessing which end the project meant.
fm_provision_declared_node_major() {  # <component-dir>
  local dir=$1 raw='' major=''
  if [ -f "$dir/.nvmrc" ]; then
    raw=$(tr -d '[:space:]' < "$dir/.nvmrc")
  elif [ -f "$dir/package.json" ]; then
    raw=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
      python3 - "$dir/package.json" 2>/dev/null <<'PY'
import json, sys
try:
    with open(sys.argv[1], "rb") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
engines = data.get("engines")
if isinstance(engines, dict):
    node = engines.get("node")
    if isinstance(node, str):
        sys.stdout.write(node.strip())
PY
    ) || raw=
  fi
  [ -n "$raw" ] || return 0
  case "$raw" in
    *' '*|*'||'*|*'>'*|*'<'*|*'-'*) return 0 ;;
  esac
  raw=${raw#v}
  raw=${raw#^}
  raw=${raw#\~}
  raw=${raw#=}
  major=${raw%%.*}
  case "$major" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$major"
}

# Highest installed Node whose major matches, searched through the standard
# version-manager layouts only (env-var driven, no captain-specific path).
# Prints the bin directory; empty when nothing matches.
fm_provision_find_node_bin() {  # <major>
  local major=$1 candidate best=
  local -a roots=()
  roots+=("${NVM_DIR:-$HOME/.nvm}/versions/node")
  roots+=("${FNM_DIR:-$HOME/.local/share/fnm}/node-versions")
  roots+=("${VOLTA_HOME:-$HOME/.volta}/tools/image/node")
  roots+=("$HOME/.asdf/installs/nodejs")
  local root name
  local -a found=()
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    for candidate in "$root"/*; do
      [ -d "$candidate" ] || continue
      name=$(basename "$candidate")
      name=${name#v}
      case "$name" in "$major"|"$major".*) ;; *) continue ;; esac
      if [ -x "$candidate/bin/node" ]; then
        found+=("$name $candidate/bin")
      elif [ -x "$candidate/installation/bin/node" ]; then
        found+=("$name $candidate/installation/bin")
      fi
    done
  done
  if [ "${#found[@]}" -gt 0 ]; then
    best=$(printf '%s\n' "${found[@]}" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    printf '%s' "${best#* }"
    return 0
  fi
  return 0
}

# A PATH prefix that pins ONLY the Node toolchain. A version-manager bin
# directory also holds every globally npm-installed CLI for that Node version,
# and the harnesses this repo launches (claude, codex, opencode, pi, grok) are
# commonly installed exactly that way, so putting that directory in front would
# silently repoint the command the spawn is about to launch at whichever copy
# happens to live under the pinned runtime - a failure that would look like
# anything except a PATH bug. fm-spawn.sh's crew_tool_path guarantees the host's
# own resolution ORDER is preserved and that seeding only ever adds reach; a
# directory holding exactly node, npm, npx, and corepack keeps that guarantee
# while still giving native modules the ABI they were installed against.
#
# A published prefix is IMMUTABLE. It is shared - the key is derived from the
# pinned runtime, so every spawn in this home that pins the same Node resolves to
# the same directory - and crew_tool_path bakes it into a launched lane's PATH
# for that lane's entire lifetime. Rewriting one would reach into a running
# crewmate's live PATH and unlink its binaries, which surfaces as
# `node: command not found` mid-validation with nothing pointing at provisioning.
# So a prefix is only ever CREATED, never rewritten, and the creation is claimed
# with a single mkdir: mkdir is atomic and fails when the name already exists, so
# there is no window between deciding the name is free and taking it. A spawn
# that loses that race validates and reuses the winner's directory.
# The key covers which toolchain entries exist, so two builds for the same key
# produce identical content.
#
# Immutability needs a repair path, or one prefix that stops validating - a
# binary removed from underneath it, a half-deleted state directory - would brick
# every later spawn pinning that runtime forever. A name that exists but does not
# validate is therefore STEPPED OVER, never rewritten: the next generation suffix
# is tried, so a lane still holding the stale directory keeps whatever it has
# while new spawns get a good prefix.
FM_PROVISION_NODE_TOOLCHAIN='node npm npx corepack'
FM_PROVISION_NODE_PREFIX_GENERATIONS=4

fm_provision_node_prefix_valid() {  # <prefix> <pinned-bin>
  local shim=$1 bin=$2 name
  [ -d "$shim" ] || return 1
  for name in $FM_PROVISION_NODE_TOOLCHAIN; do
    if [ -x "$bin/$name" ]; then
      [ "$(readlink "$shim/$name" 2>/dev/null)" = "$bin/$name" ] || return 1
      [ -x "$shim/$name" ] || return 1
    else
      [ ! -e "$shim/$name" ] || return 1
    fi
  done
  return 0
}

fm_provision_node_prefix_fill() {  # <prefix> <pinned-bin>
  local shim=$1 bin=$2 name
  for name in $FM_PROVISION_NODE_TOOLCHAIN; do
    [ -x "$bin/$name" ] || continue
    ln -s "$bin/$name" "$shim/$name" || return 1
  done
  fm_provision_node_prefix_valid "$shim" "$bin"
}

fm_provision_node_path_prefix() {  # <cache-dir> <pinned-bin>
  local cache=$1 bin=$2 key shim name root base generation=0
  key=$(
    printf '%s\n' "$bin"
    for name in $FM_PROVISION_NODE_TOOLCHAIN; do
      [ -x "$bin/$name" ] || continue
      printf 'entry=%s\n' "$name"
    done
  ) || return 1
  key=$(printf '%s' "$key" | fm_provision_sha256) || return 1
  case "$key" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) return 1 ;;
  esac
  root="$cache/node-toolchain"
  base="$root/${key:0:40}"
  mkdir -p "$root" || return 1
  while [ "$generation" -lt "$FM_PROVISION_NODE_PREFIX_GENERATIONS" ]; do
    shim=$base
    [ "$generation" -eq 0 ] || shim="$base.$generation"
    if mkdir "$shim" 2>/dev/null; then
      if fm_provision_node_prefix_fill "$shim" "$bin"; then
        printf '%s' "$shim"
        return 0
      fi
      # Nothing ever saw this directory valid, so removing the claim this call
      # just made cannot take a prefix out from under anyone.
      rm -rf "$shim"
      return 1
    fi
    if fm_provision_node_prefix_valid "$shim" "$bin"; then
      printf '%s' "$shim"
      return 0
    fi
    generation=$((generation + 1))
  done
  return 1
}

# --- fingerprint and cache --------------------------------------------------

# A component's fingerprint, or non-zero when it could not be computed over
# everything the component declares. A manifest that exists but cannot be read
# is the dangerous case: the digest of nothing is a well-formed digest, so
# emitting `manifest=<name>:` would produce a perfectly stable fingerprint that
# does not depend on that file's CONTENT at all - the next lease would recompute
# the same value after the file changed and hand the lane a confidently wrong
# cache hit. The rows are therefore built before anything is hashed, so a digest
# that is missing or empty refuses the whole fingerprint instead of being
# swallowed inside a pipeline's subshell.
fm_provision_fingerprint() {  # <worktree> <eco> <rel> <installer-id> <runtime-id>
  local wt=$1 eco=$2 rel=$3 installer=$4 runtime=$5 dir name digest manifests rc=0
  local -a rows=()
  dir=$(fm_provision_component_dir "$wt" "$rel")
  manifests=$(fm_provision_manifests "$wt" "$eco" "$rel") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  rows+=("schema=$FM_PROVISION_CACHE_SCHEMA")
  rows+=("ecosystem=$eco")
  rows+=("component=$rel")
  rows+=("installer=$installer")
  rows+=("runtime=$runtime")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    digest=$(fm_provision_sha256 < "$dir/$name") || return 1
    [ -n "$digest" ] || return 1
    rows+=("manifest=$name:$digest")
  done <<< "$manifests"
  printf '%s\n' "${rows[@]}" | fm_provision_sha256
}

fm_provision_record_path() {  # <cache-dir> <worktree> <eco> <rel>
  local cache=$1 wt=$2 eco=$3 rel=$4 key
  key=$(printf '%s\n%s\n%s\n' "$wt" "$eco" "$rel" | fm_provision_sha256)
  printf '%s/%s.record' "$cache" "${key:0:40}"
}

fm_provision_record_get() {  # <record> <key>
  local record=$1 key=$2
  [ -f "$record" ] || return 1
  LC_ALL=C sed -n "s/^$key=//p" "$record" | head -1
}

fm_provision_record_write() {  # <record> <eco> <rel> <fingerprint> <runtime> <installer> <environment>
  local record=$1 eco=$2 rel=$3 fingerprint=$4 runtime=$5 installer=$6 environment=$7 tmp
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_PROVISION_CACHE_SCHEMA"
    printf 'ecosystem=%s\n' "$eco"
    printf 'component=%s\n' "$rel"
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'runtime=%s\n' "$runtime"
    printf 'installer=%s\n' "$installer"
    printf 'environment=%s\n' "$environment"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$record"
}

# --- readiness probes -------------------------------------------------------

# A digest over the installed environment's observable state, or non-zero when
# that state could not be captured. Empty state refuses rather than hashing:
# the digest of nothing is a well-formed digest, so returning it would let a
# caller treat "captured nothing" as "captured this", which is exactly how an
# unprovisioned component would come to report itself cached.
fm_provision_environment_signature() {  # <worktree> <eco> <rel>
  local wt=$1 eco=$2 rel=$3 dir python state
  dir=$(fm_provision_component_dir "$wt" "$rel")
  case "$eco" in
    uv|pip)
      python="$dir/.venv/bin/python"
      [ -x "$python" ] || return 1
      state=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        "$python" -c '
import hashlib
import pathlib
import sys

venv = pathlib.Path(sys.argv[1])
site_dirs = sorted(path for path in venv.glob("lib*/python*/site-packages") if path.is_dir())
if not site_dirs:
    raise SystemExit(1)
paths = [venv, venv / "bin", venv / "bin" / "python", *site_dirs]
config = venv / "pyvenv.cfg"
if config.exists():
    paths.append(config)
rows = []
for path in paths:
    stat = path.stat()
    digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() and not path.is_symlink() else ""
    rows.append(f"{path.relative_to(venv)}\t{stat.st_dev}\t{stat.st_ino}\t{stat.st_mode}\t{stat.st_size}\t{stat.st_mtime_ns}\t{stat.st_ctime_ns}\t{digest}")
print("\n".join(rows))
' "$dir/.venv" 2>/dev/null) || return 1
      ;;
    npm|pnpm)
      state=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        python3 -c '
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
with (root / "package.json").open("rb") as fh:
    package = json.load(fh)
if not isinstance(package, dict):
    raise SystemExit(1)
declared = set()
for field in ("dependencies", "devDependencies"):
    values = package.get(field, {})
    if not isinstance(values, dict):
        raise SystemExit(1)
    declared.update(values)
modules_root = root / "node_modules"
paths = [modules_root]
bin_dir = modules_root / ".bin"
if bin_dir.exists():
    paths.append(bin_dir)
for name in sorted(declared):
    if not isinstance(name, str) or name in ("", ".", "..") or name.startswith("/"):
        raise SystemExit(1)
    package_dir = modules_root / name
    if not package_dir.is_dir() or not (package_dir / "package.json").is_file():
        raise SystemExit(1)
    paths.append(package_dir)
rows = []
for path in paths:
    stat = path.stat()
    if path == modules_root:
        # node_modules itself is the ONE path a lane writes into during ordinary
        # work: webpack, vite, eslint and babel all create node_modules/.cache,
        # and on APFS adding a single entry to a directory moves its mtime,
        # ctime and size. Hashing those here made every second spawn into a
        # healthy, unchanged worktree pay a full reinstall. Its identity
        # (dev/ino/mode) still proves the directory was not replaced. Every
        # other path keeps the volatile fields, because for a declared package
        # directory they are the only thing that notices a file deleted from
        # INSIDE it - the structural check above only proves the directory and
        # its package.json exist.
        rows.append(f"{path.relative_to(root)}\t{stat.st_dev}\t{stat.st_ino}\t{stat.st_mode}")
    else:
        rows.append(f"{path.relative_to(root)}\t{stat.st_dev}\t{stat.st_ino}\t{stat.st_mode}\t{stat.st_size}\t{stat.st_mtime_ns}\t{stat.st_ctime_ns}")
print("\n".join(rows))
' "$dir" 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  [ -n "$state" ] || return 1
  printf '%s' "$state" | fm_provision_sha256
}

# Tri-state: 0 every determinable requirement is installed, 1 a declared package
# is missing, 2 the declaration could not be verified. 2 is still a cache miss,
# but a distinguishable one, so the caller can say why it is reinstalling rather
# than reinstalling on every spawn forever with no explanation.
fm_provision_declared_packages_ready() {  # <worktree> <eco> <rel>
  local wt=$1 eco=$2 rel=$3 dir name rc=0
  dir=$(fm_provision_component_dir "$wt" "$rel")
  case "$eco" in
    uv) return 0 ;;
    pip) ;;
    *) return 2 ;;
  esac
  [ -x "$dir/.venv/bin/python" ] || return 1
  local -a requirements=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    requirements+=("$dir/$name")
  done < <(fm_provision_pip_requirements "$dir")
  [ "${#requirements[@]}" -gt 0 ] || return 2
  fm_provision_pip_parse ready "$dir" "$dir/.venv" "${requirements[@]}" \
    >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) return 2 ;;
  esac
}

# The installed environment must actually work, not merely exist. A pool slot
# keeps ignored directories across leases, and a previous agent may have removed
# or broken them; a fingerprint alone would then report a false cache hit.
#
# Sets FM_PROVISION_PROBE_NOTE for the caller: what `uv pip check` reported is
# recorded, never a verdict on the probe. That command verifies that installed
# metadata is mutually consistent, which a working environment is allowed to
# fail - a project using uv's [tool.uv] override-dependencies or
# constraint-dependencies installs a version some package's metadata calls
# incompatible ON PURPOSE - so refusing on it would block every spawn into an
# environment that installs, runs, and validates fine. The proofs kept as
# verdicts are the ones that mean unusable: an interpreter that is missing, not
# executable, does not run, or does not report the runtime recorded for it.
#
# A verdict is recorded ONLY from a check that actually ran. fm_provision_run_bounded
# reserves 124 for an expired bound, 125 for a host that cannot bound anything,
# 126 for a child whose status could not be determined, and 127 for a command
# that could not be executed; none of those means the check ran and found
# something, and reporting them as one would tell the lane a fact about its
# environment that was never established. They get their own token, which says
# the check could not be run - the same distinction this library already makes
# between a digest it computed and a digest it could not.
FM_PROVISION_PROBE_NOTE=
fm_provision_probe() {  # <worktree> <eco> <rel> <log> <runtime> <environment> <phase>
  local wt=$1 eco=$2 rel=$3 log=$4 runtime=$5 environment=$6 phase=$7 dir python actual current ready_rc=0 check_rc=0
  dir=$(fm_provision_component_dir "$wt" "$rel")
  FM_PROVISION_PROBE_NOTE=
  case "$eco" in
    uv|pip)
      python="$dir/.venv/bin/python"
      [ -x "$python" ] || return 1
      actual=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        "$python" -c 'import sys; sys.stdout.write("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) || return 1
      [ -n "$actual" ] && [ "$actual" = "$runtime" ] || return 1
      fm_provision_run_logged "$FM_PROVISION_PROBE_TIMEOUT" "$dir" "$log" \
        uv pip check --python "$python" || check_rc=$?
      # Exit 1 is the only code that means `uv pip check` RAN and found an
      # inconsistency. Everything else means no verdict was produced: the
      # bounded runner reserves 124/125/126/127 for an expired bound, no
      # bounding mechanism, an undeterminable child status, and a command that
      # could not execute, and uv's own CLI exits 2 on a usage error. Reporting
      # any of those as "not self-consistent" would tell the lane the check
      # found something when the check never answered - the same
      # something-from-nothing defect this file fails closed on elsewhere.
      case "$check_rc" in
        0) ;;
        1) FM_PROVISION_PROBE_NOTE=inconsistent-dependency-metadata ;;
        *) FM_PROVISION_PROBE_NOTE=unverified-dependency-metadata ;;
      esac
      ;;
    npm|pnpm)
      [ -d "$dir/node_modules" ] || return 1
      case "$eco" in
        npm) [ -f "$dir/node_modules/.package-lock.json" ] || return 1 ;;
        pnpm) [ -f "$dir/node_modules/.modules.yaml" ] || return 1 ;;
      esac
      actual=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        node -p 'process.versions.node' 2>/dev/null) || return 1
      [ -n "$actual" ] && [ "$actual" = "$runtime" ] || return 1
      ;;
    *) return 1 ;;
  esac
  if [ "$phase" = cache ]; then
    current=$(fm_provision_environment_signature "$wt" "$eco" "$rel") || return 1
    [ -n "$environment" ] && [ "$current" = "$environment" ] || return 1
    if [ "$eco" = pip ]; then
      fm_provision_declared_packages_ready "$wt" "$eco" "$rel" || ready_rc=$?
      if [ "$ready_rc" -eq 2 ]; then
        printf '[cache miss] %s declares requirements whose package identity could not be determined\n' "$rel" >> "$log"
        echo "fm-spawn: reinstalling $rel because its requirements could not be verified against the installed environment" >&2
      fi
      [ "$ready_rc" -eq 0 ] || return 1
    fi
  else
    [ -n "$environment" ] || return 1
  fi
  return 0
}

# --- installs ---------------------------------------------------------------

fm_provision_install() {  # <worktree> <eco> <rel> <log>
  local wt=$1 eco=$2 rel=$3 log=$4 dir name
  dir=$(fm_provision_component_dir "$wt" "$rel")
  case "$eco" in
    uv)
      # --frozen installs the lock exactly as committed and never rewrites it,
      # so provisioning cannot dirty the worktree the freshness proof and
      # teardown both require to stay clean. A uv workspace has exactly one
      # uv.lock and one .venv at its root, and a plain sync there installs only
      # the root package - a lane could not then run a member's checks - so a
      # declared workspace syncs every member. Non-workspace projects keep the
      # plain form, so they carry no uv-version floor for --all-packages.
      local workspace_info
      local -a sync_args=(sync --frozen)
      workspace_info=$(fm_provision_uv_workspace_info "$dir") || return
      if [ "${workspace_info%%$'\n'*}" = workspace ]; then
        sync_args+=(--all-packages)
      fi
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        env -u UV_NO_DEV -u UV_ONLY_DEV -u UV_NO_DEFAULT_GROUPS \
        -u UV_NO_GROUP -u UV_ONLY_GROUP uv "${sync_args[@]}" || return $?
      ;;
    pip)
      local -a args=(pip install --python .venv/bin/python)
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        uv venv --clear .venv || return $?
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        args+=(-r "$name")
      done < <(fm_provision_pip_requirements "$dir")
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        uv "${args[@]}" || return $?
      ;;
    npm)
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        npm ci --include=dev || return $?
      ;;
    pnpm)
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        pnpm install --frozen-lockfile --prod=false || return $?
      ;;
    *) return 1 ;;
  esac
  return 0
}

# The ignored directory an ecosystem installs into, relative to the worktree.
fm_provision_artifact_path() {  # <eco> <rel>
  local eco=$1 rel=$2 name
  case "$eco" in
    uv|pip) name=.venv ;;
    npm|pnpm) name=node_modules ;;
    *) return 1 ;;
  esac
  if [ "$rel" = . ]; then
    printf '/%s/' "$name"
  else
    printf '/%s/%s/' "$rel" "$name"
  fi
}

# --- the two decision points ------------------------------------------------
#
# Every non-success outcome goes through exactly one of these. Which one it is
# never depends on where in the flow it happened, only on what kind of thing it
# is: something provisioning could not have done here (gap) versus something it
# tried to do and could not finish (failure). Adding a new limit means picking
# one of these two functions, and the gap one cannot refuse a spawn.

# Say something in both places a lane can look: the spawn's stderr, which the
# operator sees, and the provisioning log, which outlives the spawn's scrollback.
# What was NOT provisioned has to be as loud as what was.
fm_provision_announce() {  # <log> <message>
  local log=$1 message=$2
  echo "$message" >&2
  if [ -n "$log" ] && [ -f "$log" ]; then
    printf '%s\n' "$message" >> "$log"
  fi
  return 0
}

# A capability gap. Announces, and returns the state string the caller records
# for the component, so a gap is never possible without also being reported - on
# stderr, in the log, and through the summary in the task's own metadata.
fm_provision_gap() {  # <log> <eco> <rel> <reason-token> <message>
  local log=$1 eco=$2 rel=$3 reason=$4 message=$5
  fm_provision_announce "$log" \
    "warning: leaving the $eco component in $rel unprovisioned: $message"
  printf 'skipped:%s' "$reason"
}

# Something reported ABOUT a component that was provisioned. Not a third
# non-success outcome: the component installed, runs, and counts as provisioned,
# and the note rides beside its state so the operator and the lane both learn
# what the installer's own consistency check said without a working environment
# being refused over it.
fm_provision_note() {  # <log> <eco> <rel> <note-token> <message>
  local log=$1 eco=$2 rel=$3 note=$4 message=$5
  fm_provision_announce "$log" \
    "warning: the $eco environment in $rel is provisioned, but $message"
  printf '%s' "$note"
}

# A capability gap covering the whole worktree, for a host that lacks a tool
# provisioning itself needs. Nothing is attempted and the spawn still launches.
fm_provision_unavailable() {  # <log> <reason-token> <message>
  local log=$1 reason=$2 message=$3
  fm_provision_announce "$log" "warning: worktree provisioning is unavailable on this host: $message"
  fm_provision_announce "$log" "         the lane launches unprovisioned, so it may not be able to run this project's own checks."
  FM_PROVISION_SUMMARY="unavailable:$reason"
  return 0
}

# The one provisioning surface the LANE can reach. stderr goes to the operator's
# terminal, and the provisioning log and provision= metadata both live in the
# firstmate home; a crewmate that hits a missing environment mid-validation can
# read none of them, so what provisioning declared would be announced to nobody
# who can act on it. This file sits at the root of the worktree the lane works
# in, and names every component and what happened to it.
#
# The path must ALREADY be ignored by the project, checked before the write, and
# the report is skipped when it is not: a report that dirtied a checkout the
# freshness proof and teardown both require to be clean would be a worse defect
# than a missing one, and a diagnostic that cannot be filed is never a reason to
# refuse a spawn. Note the consequence - a project that does not list
# .fm-provisioning.md in its own .gitignore gets no in-worktree report, and the
# warning says so. Firstmate does not add the entry itself, because writing an
# exclusion that git would honour means writing into the primary clone.
FM_PROVISION_REPORT_NAME=.fm-provisioning.md

# The report describes ONE lease, but a pool slot outlives the task that leased
# it: nothing in teardown or `treehouse return` deletes an excluded file, so a
# report left by the previous task would be read by the next lane as its own.
# Every entry into provisioning therefore clears it before deciding anything -
# including the entries that decide to provision nothing at all, which are
# exactly the ones that would otherwise inherit a stale "provisioned" claim.
# Removed rather than truncated, so a symlink planted at the path by whoever
# held the slot before is replaced instead of written through. Silent on
# failure: each caller decides whether a path it cannot clear is a refusal or a
# report it declines to write.
fm_provision_clear_report() {  # <worktree>
  local wt=$1 report
  report="$wt/$FM_PROVISION_REPORT_NAME"
  rm -f "$report" 2>/dev/null || :
  [ ! -e "$report" ] && [ ! -L "$report" ]
}

fm_provision_report_body() {  # <worktree>; reads "<eco>\t<rel>\t<state>[\t<note>]" on stdin
  local wt=$1 eco rel state note
  local -a done_lines=() gap_lines=()
  while IFS=$'\t' read -r eco rel state note; do
    [ -n "$eco" ] || continue
    case "$state" in
      installed|cached)
        if [ -n "${note:-}" ]; then
          done_lines+=("- $eco in $rel - $state, with one thing reported about it: $note")
        else
          done_lines+=("- $eco in $rel - $state")
        fi
        ;;
      skipped:*) gap_lines+=("- $eco in $rel - NOT provisioned: ${state#skipped:}") ;;
      *) gap_lines+=("- $eco in $rel - NOT provisioned: $state") ;;
    esac
  done
  printf '# firstmate worktree provisioning\n\n'
  printf 'firstmate provisioned this worktree (%s) before launching this lane.\n' "$wt"
  printf 'Anything listed as NOT provisioned was decided here, at launch. If a check\n'
  printf 'fails because that dependency environment is missing, provisioning declared\n'
  printf 'it - nothing broke later.\n'
  if [ "${#done_lines[@]}" -gt 0 ]; then
    printf '\n## provisioned\n\n'
    printf '%s\n' "${done_lines[@]}"
  fi
  if [ "${#gap_lines[@]}" -gt 0 ]; then
    printf '\n## not provisioned\n\n'
    printf '%s\n' "${gap_lines[@]}"
  fi
}

# The components are read from stdin, never from the caller's scope: a function
# that reached into fm_provision_worktree's own `components` local would, from
# any other call site or after that local is renamed, hit an unbound variable
# under `set -u` inside a command substitution and quietly write a report with
# no body at all.
fm_provision_report_unavailable() {  # <worktree> <log> <reason>; reads "<eco> <rel>" on stdin
  local wt=$1 log=$2 reason=$3 line count=0
  fm_provision_write_report "$wt" "$log" "$(
    {
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        count=$((count + 1))
        printf '%s\t%s\tskipped:%s\n' "${line%% *}" "${line#* }" "$reason"
      done
      # A gap that stopped provisioning BEFORE anything could be enumerated has
      # no components to name. Saying so is the point: a report carrying only
      # its own header would read like a worktree that needed nothing.
      [ "$count" -gt 0 ] \
        || printf 'every component\tthis worktree\tskipped:%s\n' "$reason"
    } | fm_provision_report_body "$wt"
  )"
}

fm_provision_write_report() {  # <worktree> <log> <body>
  local wt=$1 log=$2 body=$3 report
  report="$wt/$FM_PROVISION_REPORT_NAME"
  if declare -F fm_provision_register_exclude >/dev/null \
    && ! fm_provision_register_exclude "/$FM_PROVISION_REPORT_NAME"; then
    fm_provision_announce "$log" \
      "warning: the project does not ignore /$FM_PROVISION_REPORT_NAME, so this lane gets no in-worktree provisioning report - add it to the project's .gitignore to enable it"
    return 0
  fi
  if ! fm_provision_clear_report "$wt"; then
    fm_provision_announce "$log" \
      "warning: cannot replace what already occupies $report, so this lane gets no in-worktree provisioning report"
    return 0
  fi
  printf '%s\n' "$body" > "$report" || {
    fm_provision_announce "$log" \
      "warning: cannot write the in-worktree provisioning report at $report"
    return 0
  }
  return 0
}

# Whether the task this spawn is for names a component's directory. The brief is
# the one path signal a spawn actually has, so an over-budget worktree spends its
# budget on the components the task itself mentions before falling back to
# detection order - never on an alphabetical accident alone.
fm_provision_component_needed() {  # <needs-file> <relative-dir>
  local needs=$1 rel=$2
  [ -n "$needs" ] && [ -f "$needs" ] && [ -r "$needs" ] || return 1
  [ "$rel" != . ] || return 1
  LC_ALL=C grep -qF -- "$rel" "$needs" 2>/dev/null
}

# An attempt that failed. Refuses the spawn.
fm_provision_fail() {  # <message>
  echo "error: worktree provisioning failed: $1" >&2
  echo "       a lane launched here could not run this project's own checks, so the spawn is refused." >&2
  echo "       Disable provisioning for this home with config/worktree-provision=off, or for one spawn with --no-provision." >&2
  return 1
}

# Refuse before anything is scanned or run when a tunable is not a positive
# integer. Silently substituting a default here would defeat the bound the
# operator was trying to set: under the perl fallback an empty or zero timeout
# becomes "alarm 0", which cancels the alarm and removes the bound entirely.
fm_provision_validate_tunables() {
  local name value
  for name in FM_PROVISION_SCAN_DEPTH FM_PROVISION_MAX_COMPONENTS \
    FM_PROVISION_INSTALL_TIMEOUT FM_PROVISION_PROBE_TIMEOUT; do
    value=${!name}
    case "$value" in
      ''|*[!0-9]*) ;;
      *[1-9]*) continue ;;
    esac
    fm_provision_fail "$name must be a positive integer, got '$value'"
    return 1
  done
  return 0
}

# --- entry point ------------------------------------------------------------

# The provisioning log and the cache directory that outlives it. Both are needed
# by every path that has something to say, and a path that cannot open them has
# nowhere to say it, so failing to open either is a refusal.
fm_provision_open_log() {  # <cache-dir> <log> <worktree>
  local cache=$1 log=$2 wt=$3
  mkdir -p "$cache" || { fm_provision_fail "cannot create the provisioning cache directory $cache"; return 1; }
  : >> "$log" || { fm_provision_fail "cannot write the provisioning log $log"; return 1; }
  printf '=== provisioning %s at %s ===\n' "$wt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log"
}

# Provision every component the worktree declares that this provisioner can.
# Prints per-component progress to stderr, appends all installer output to
# <log>, and sets FM_PROVISION_SUMMARY (the compact task-metadata value) and
# FM_PROVISION_PATH_PREFIX (a PATH prefix pinning a declared Node runtime).
# Returns 0 on success, on a partial result whose gaps are recorded in the
# summary, or on a clean no-op; non-zero only when an attempt failed and the
# spawn must refuse. <needs-file>, when given, is the task's own brief: an
# over-budget worktree spends its budget on the components that file names
# before falling back to detection order.
fm_provision_worktree() {  # <worktree> <cache-dir> <log> [<needs-file>]
  local wt=$1 cache=$2 log=$3 needs=${4:-}
  local eco rel dir line scanned detected record fingerprint recorded runtime installer environment artifact
  local declared_major pinned_major='' pinned_bin='' pinned_prefix='' rc=0 state note
  local index=0 provisionable=0 budgeted=0 skipped=0 noted=0 unprovisioned='' unavailable=''
  local -a components=() states=() notes=() results=() order=() scan_lines=()

  FM_PROVISION_SUMMARY=none
  FM_PROVISION_PATH_PREFIX=

  fm_provision_validate_tunables || return 1
  [ -d "$wt" ] || { fm_provision_fail "worktree $wt is not a directory"; return 1; }
  fm_provision_clear_report "$wt" || {
    fm_provision_fail "cannot remove a previous lease's provisioning report at $wt/$FM_PROVISION_REPORT_NAME, so this lane would read it as a description of its own worktree"
    return 1
  }
  fm_provision_resolve_bound_kind

  rc=0
  scanned=$(fm_provision_scan "$wt") || rc=$?
  if [ "$rc" -eq 2 ]; then
    # The traversal outlived its bound, so no component was enumerated and none
    # can be named. That is work this provisioner could not do here, not an
    # attempt that failed, so it warns and launches like every other host gap.
    fm_provision_open_log "$cache" "$log" "$wt" || return 1
    fm_provision_unavailable "$log" scan-too-large \
      "scanning $wt for dependency manifests did not finish within its ${FM_PROVISION_PROBE_TIMEOUT}s bound, so no component could be enumerated, let alone provisioned"
    fm_provision_report_unavailable "$wt" "$log" scan-too-large < /dev/null
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    fm_provision_fail "cannot scan $wt for dependency manifests"
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    scan_lines+=("$line")
  done <<< "$scanned"

  if [ "${#scan_lines[@]}" -eq 0 ]; then
    return 0
  fi

  # Opened before anything is decided, so every capability gap below lands in the
  # log as well as on stderr. A worktree that declares nothing returns above and
  # never creates one.
  fm_provision_open_log "$cache" "$log" "$wt" || return 1

  # Host prerequisites, decided before a single component is classified, because
  # classification itself reads the project's package.json through python3 under
  # a bound: a host that has neither must reach this verdict first, or something
  # would have run on it after all. Provisioning was never going to work here, so
  # it warns and launches unprovisioned; refusing would make every spawn on such
  # a host impossible while buying nothing, and nothing has been mutated yet.
  # Classification still runs afterwards - it degrades to lockfile precedence
  # without running anything - so the lane's report can still name each component
  # it is not getting rather than only the host verdict.
  if [ "$FM_PROVISION_BOUND_KIND" = none ]; then
    unavailable=no-bounded-execution
    fm_provision_unavailable "$log" no-bounded-execution \
      "no bounded-execution mechanism (timeout, gtimeout, or perl) is available, so no install could be prevented from wedging the spawn"
  elif ! command -v python3 >/dev/null 2>&1; then
    unavailable=no-python3
    fm_provision_unavailable "$log" no-python3 \
      "python3 is not installed, so no component's declared manifests or installed-environment readiness could be resolved"
  fi

  detected=$(fm_provision_detect "$wt" "${scan_lines[@]}") || {
    fm_provision_fail "cannot scan $wt for dependency manifests"
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    components+=("$line")
    states+=(planned)
    notes+=('')
  done <<< "$detected"

  if [ "${#components[@]}" -eq 0 ]; then
    return 0
  fi
  if [ -n "$unavailable" ]; then
    printf '%s\n' "${components[@]}" \
      | fm_provision_report_unavailable "$wt" "$log" "$unavailable"
    return 0
  fi

  # Everything this provisioner will not install: package managers with no
  # verified install command here, JS components whose manager could not be
  # determined from what the project declares, Python projects declaring no
  # committed lock or requirements file, and directories the depth bound put out
  # of reach. Each is NAMED here rather than dropped, because a lane that
  # silently lacks the environment it needs to validate is the failure this
  # library exists to prevent.
  index=0
  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    case "$eco" in
      uv|pip|npm|pnpm) ;;
      js)
        states[index]=$(fm_provision_gap "$log" js "$rel" ambiguous-manager \
          "its package manager is not determined by package.json's packageManager field and it carries no single lockfile that names one")
        ;;
      python)
        states[index]=$(fm_provision_gap "$log" python "$rel" no-python-lockfile \
          "it declares a pyproject.toml but neither a uv.lock nor a requirements.txt, and this firstmate installs Python only from a committed declaration")
        ;;
      unscanned)
        states[index]=$(fm_provision_gap "$log" "$eco" "$rel" below-scan-depth \
          "its manifest lies deeper than the FM_PROVISION_SCAN_DEPTH limit of $FM_PROVISION_SCAN_DEPTH, so it was never classified or installed")
        ;;
      *)
        states[index]=$(fm_provision_gap "$log" "$eco" "$rel" unsupported-manager \
          "this firstmate has no verified $eco install command")
        ;;
    esac
    index=$((index + 1))
  done

  # An ambient UV_PROJECT_ENVIRONMENT would move uv's environment somewhere the
  # readiness probe cannot see, so an installed component could never be proven
  # and a cache hit would be a false one. That is an attempt we cannot make.
  index=0
  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    if [ "${states[$index]}" = planned ] && [ "$eco" = uv ] \
      && [ -n "${UV_PROJECT_ENVIRONMENT:-}" ] && [ "$UV_PROJECT_ENVIRONMENT" != .venv ]; then
      fm_provision_fail "UV_PROJECT_ENVIRONMENT is set to '$UV_PROJECT_ENVIRONMENT', so the environment for $rel would not be provable at $rel/.venv"
      return 1
    fi
    [ "${states[$index]}" != planned ] || provisionable=$((provisionable + 1))
    index=$((index + 1))
  done

  # The component budget bounds how much one spawn will install; the components
  # past it are left unprovisioned and reported, never installed silently and
  # never a reason to refuse the whole spawn. Which ones land past it is decided
  # by need before order: the components the task's own brief names go first, and
  # detection order only breaks the remaining tie, so an alphabetical accident
  # cannot quietly skip the service the lane was sent to work on.
  if [ "$provisionable" -gt "$FM_PROVISION_MAX_COMPONENTS" ]; then
    index=0
    for line in "${components[@]}"; do
      if [ "${states[$index]}" = planned ] \
        && fm_provision_component_needed "$needs" "${line#* }"; then
        order+=("$index")
      fi
      index=$((index + 1))
    done
    index=0
    for line in "${components[@]}"; do
      if [ "${states[$index]}" = planned ] \
        && ! fm_provision_list_has "$index" ${order[@]+"${order[@]}"}; then
        order+=("$index")
      fi
      index=$((index + 1))
    done
    for index in "${order[@]}"; do
      budgeted=$((budgeted + 1))
      [ "$budgeted" -gt "$FM_PROVISION_MAX_COMPONENTS" ] || continue
      line=${components[$index]}
      eco=${line%% *}
      rel=${line#* }
      states[index]=$(fm_provision_gap "$log" "$eco" "$rel" over-budget \
        "the worktree declares $provisionable provisionable components, above the FM_PROVISION_MAX_COMPONENTS budget of $FM_PROVISION_MAX_COMPONENTS")
    done
  fi

  # Resolve one Node runtime for the whole worktree before any JS install, so
  # every JS component installs its native modules against the runtime the
  # crewmate will later validate with. A project that declares nothing keeps
  # the ambient runtime. A pin no installed runtime can satisfy - including two
  # components that declare different majors - is a capability gap that leaves
  # the JS components unprovisioned rather than installing them against an ABI
  # the lane will not validate on.
  index=0
  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    if [ "${states[$index]}" = planned ]; then
      case "$eco" in
        npm|pnpm)
          dir=$(fm_provision_component_dir "$wt" "$rel")
          declared_major=$(fm_provision_declared_node_major "$dir")
          if [ -n "$declared_major" ]; then
            if [ -n "$pinned_major" ] && [ "$pinned_major" != "$declared_major" ]; then
              pinned_major=conflict
            elif [ "$pinned_major" != conflict ]; then
              pinned_major=$declared_major
            fi
          fi
          ;;
      esac
    fi
    index=$((index + 1))
  done
  if [ -n "$pinned_major" ] && [ "$pinned_major" != conflict ]; then
    runtime=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$wt" node -p 'process.versions.node' 2>/dev/null) || runtime=
    if [ -n "$runtime" ] && [ "${runtime%%.*}" = "$pinned_major" ]; then
      pinned_bin=
    else
      pinned_bin=$(fm_provision_find_node_bin "$pinned_major")
      if [ -z "$pinned_bin" ]; then
        pinned_major=unsatisfiable
      else
        pinned_prefix=$(fm_provision_node_path_prefix "$cache" "$pinned_bin") || pinned_prefix=
        if [ -z "$pinned_prefix" ]; then
          pinned_major=no-prefix
        else
          # Read by the sourcing caller (fm-spawn.sh's crew_tool_path).
          # shellcheck disable=SC2034
          FM_PROVISION_PATH_PREFIX=$pinned_prefix
          PATH="$pinned_prefix:$PATH"
          export PATH
          echo "fm-spawn: pinning Node $pinned_major from $pinned_bin for this worktree" >&2
        fi
      fi
    fi
  fi
  case "$pinned_major" in
    conflict|unsatisfiable|no-prefix)
      index=0
      for line in "${components[@]}"; do
        eco=${line%% *}
        rel=${line#* }
        if [ "${states[$index]}" = planned ]; then
          case "$eco" in
            npm|pnpm)
              case "$pinned_major" in
                conflict)
                  states[index]=$(fm_provision_gap "$log" "$eco" "$rel" conflicting-node \
                    "components under $wt declare different Node major versions, and no single runtime can serve both")
                  ;;
                unsatisfiable)
                  states[index]=$(fm_provision_gap "$log" "$eco" "$rel" node-not-found \
                    "this project declares a Node major that was not found on PATH or under the standard version-manager directories (\$NVM_DIR, \$FNM_DIR, \$VOLTA_HOME, ~/.asdf)")
                  ;;
                *)
                  states[index]=$(fm_provision_gap "$log" "$eco" "$rel" node-prefix-unavailable \
                    "no pinned Node toolchain directory could be established under $cache, so its dependencies cannot be installed against the runtime the lane would validate on")
                  ;;
              esac
              ;;
          esac
        fi
        index=$((index + 1))
      done
      ;;
  esac

  # The project ALREADY ignoring each install directory is a prerequisite, not a
  # courtesy, and it is checked for every planned component before any installer
  # runs: installing into a path git can see leaves the leased worktree dirty,
  # fails its returnable check on abort, and strands the workspace lease.
  index=0
  for line in "${components[@]}"; do
    if [ "${states[$index]}" = planned ]; then
      eco=${line%% *}
      rel=${line#* }
      artifact=$(fm_provision_artifact_path "$eco" "$rel") || {
        fm_provision_fail "the $eco component in $rel declares no ignored install directory to protect before provisioning"
        return 1
      }
      if declare -F fm_provision_register_exclude >/dev/null \
        && ! fm_provision_register_exclude "$artifact"; then
        fm_provision_fail "the project does not ignore $artifact, so installing there would leave the worktree dirty, fail its returnable check on abort, and strand the pool lease - add $artifact to the project's own .gitignore, or disable provisioning for this home with config/worktree-provision=off"
        return 1
      fi
    fi
    index=$((index + 1))
  done

  index=0
  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    dir=$(fm_provision_component_dir "$wt" "$rel")
    if [ "${states[$index]}" != planned ]; then
      index=$((index + 1))
      continue
    fi

    case "$eco" in
      uv|pip) installer=$(fm_provision_tool_version uv --version) || installer= ;;
      npm) installer=$(fm_provision_tool_version npm --version) || installer= ;;
      pnpm) installer=$(fm_provision_tool_version pnpm --version) || installer= ;;
    esac
    if [ -z "$installer" ]; then
      case "$eco" in
        uv|pip)
          states[index]=$(fm_provision_gap "$log" "$eco" "$rel" missing-installer \
            "firstmate provisions Python through uv, never pip or venv, and uv is not installed")
          ;;
        *)
          states[index]=$(fm_provision_gap "$log" "$eco" "$rel" missing-installer \
            "$eco is not installed")
          ;;
      esac
      index=$((index + 1))
      continue
    fi

    # The runtime identity a component is fingerprinted and probed against.
    # Node's is known before installing; a virtualenv's interpreter is an
    # OUTPUT of the install (uv resolves it from the project's own
    # .python-version or requires-python), so it is recorded afterwards and the
    # probe holds the environment to it.
    case "$eco" in
      npm|pnpm)
        runtime=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" node -p 'process.versions.node' 2>/dev/null) || runtime=
        if [ -z "$runtime" ]; then
          states[index]=$(fm_provision_gap "$log" "$eco" "$rel" node-not-found \
            "node did not run, so its dependencies cannot be installed against the runtime the lane would validate on")
          index=$((index + 1))
          continue
        fi
        ;;
      *) runtime= ;;
    esac

    record=$(fm_provision_record_path "$cache" "$wt" "$eco" "$rel")
    rc=0
    fingerprint=$(fm_provision_fingerprint "$wt" "$eco" "$rel" "$installer" "$runtime") || rc=$?
    if [ "$rc" -eq 2 ]; then
      states[index]=$(fm_provision_gap "$log" "$eco" "$rel" unresolved-manifests \
        "its declaration reaches more requirements files than this provisioner traverses, so no fingerprint it could compute would cover what the component actually installs")
      index=$((index + 1))
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      fm_provision_fail "cannot resolve the declared manifests for the $eco component in $rel"
      return 1
    fi
    recorded=$(fm_provision_record_get "$record" fingerprint 2>/dev/null || true)
    state=installed
    if [ -n "$recorded" ] && [ "$recorded" = "$fingerprint" ] \
      && [ "$(fm_provision_record_get "$record" schema 2>/dev/null || true)" = "$FM_PROVISION_CACHE_SCHEMA" ]; then
      local probe_runtime
      probe_runtime=$(fm_provision_record_get "$record" runtime 2>/dev/null || true)
      environment=$(fm_provision_record_get "$record" environment 2>/dev/null || true)
      if fm_provision_probe "$wt" "$eco" "$rel" "$log" "$probe_runtime" "$environment" cache; then
        state=cached
      fi
    fi

    if [ "$state" = installed ]; then
      echo "fm-spawn: provisioning $eco dependencies in $rel" >&2
      rc=0
      fm_provision_install "$wt" "$eco" "$rel" "$log" || rc=$?
      if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
          fm_provision_fail "the $eco install in $rel exceeded its ${FM_PROVISION_INSTALL_TIMEOUT}s bound"
        else
          fm_provision_fail "the $eco install in $rel exited $rc"
        fi
        return 1
      fi
      case "$eco" in
        uv|pip)
          runtime=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
            "$dir/.venv/bin/python" -c 'import sys; sys.stdout.write("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) || runtime=
          if [ -z "$runtime" ]; then
            fm_provision_fail "the $eco install in $rel left no working interpreter at $rel/.venv/bin/python"
            return 1
          fi
          ;;
      esac
      environment=$(fm_provision_environment_signature "$wt" "$eco" "$rel") || environment=
      if ! fm_provision_probe "$wt" "$eco" "$rel" "$log" "$runtime" "$environment" installed; then
        fm_provision_fail "the $eco environment in $rel is not usable after installing"
        return 1
      fi
      fm_provision_record_write "$record" "$eco" "$rel" "$fingerprint" "$runtime" "$installer" "$environment" \
        || { fm_provision_fail "cannot record the provisioning fingerprint at $record"; return 1; }
    fi

    # Whatever the probe that decided this component's state reported about it.
    # The environment is provisioned either way; this is the one thing a
    # successful component can still have to say.
    case "$FM_PROVISION_PROBE_NOTE" in
      inconsistent-dependency-metadata)
        notes[index]=$(fm_provision_note "$log" "$eco" "$rel" "$FM_PROVISION_PROBE_NOTE" \
          "uv pip check reports that its installed dependency metadata is not self-consistent, which a project pinning through uv's override-dependencies or constraint-dependencies does deliberately - the interpreter runs and the environment is usable, but a check that runs uv pip check will fail here")
        ;;
      unverified-dependency-metadata)
        notes[index]=$(fm_provision_note "$log" "$eco" "$rel" "$FM_PROVISION_PROBE_NOTE" \
          "uv pip check could not be run to completion here, so whether its installed dependency metadata is self-consistent is simply unknown - nothing was found wrong with it, and the interpreter runs and the environment is usable")
        ;;
    esac

    states[index]=$state
    index=$((index + 1))
  done

  index=0
  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    note=${notes[$index]}
    results+=("$eco:$rel=${states[$index]}${note:++$note}")
    case "${states[$index]}" in
      skipped:*)
        skipped=$((skipped + 1))
        unprovisioned="$unprovisioned $rel"
        ;;
    esac
    [ -z "$note" ] || noted=$((noted + 1))
    index=$((index + 1))
  done
  FM_PROVISION_SUMMARY=$(IFS=,; printf '%s' "${results[*]}")
  index=0
  fm_provision_write_report "$wt" "$log" "$(
    for line in "${components[@]}"; do
      printf '%s\t%s\t%s\t%s\n' "${line%% *}" "${line#* }" "${states[$index]}" "${notes[$index]}"
      index=$((index + 1))
    done | fm_provision_report_body "$wt"
  )"
  if [ "$skipped" -gt 0 ]; then
    # Named, not counted, and on a surface the LANE can reach: the report written
    # into the worktree above says the same thing, because stderr, the log, and
    # provision= metadata all live in the firstmate home where a crewmate that
    # hits a missing environment mid-validation cannot read any of them.
    fm_provision_announce "$log" \
      "warning: worktree provisioning left $skipped of ${#components[@]} components UNPROVISIONED:$unprovisioned"
    fm_provision_announce "$log" "warning: provisioning outcome per component - $FM_PROVISION_SUMMARY"
    fm_provision_announce "$log" "warning: the lane's own copy is at $wt/$FM_PROVISION_REPORT_NAME"
  elif [ "$noted" -gt 0 ]; then
    fm_provision_announce "$log" \
      "fm-spawn: worktree provisioned, with $noted of ${#components[@]} components carrying a reported problem - $FM_PROVISION_SUMMARY"
    fm_provision_announce "$log" "         the lane's own copy is at $wt/$FM_PROVISION_REPORT_NAME"
  else
    fm_provision_announce "$log" "fm-spawn: worktree provisioned - $FM_PROVISION_SUMMARY"
  fi
  return 0
}
