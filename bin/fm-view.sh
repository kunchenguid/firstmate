#!/usr/bin/env bash
# fm-view.sh - run a primary harness with its working directory at the launch
# directory, while that directory presents Firstmate's instruction, hook, and
# skill surface exactly as the install root does. One mechanism for every
# harness: a per-session Linux user+mount namespace. Nothing is written to the
# launch directory, and the host (the captain's editor, other terminals,
# workers, CI) keeps seeing the real directory.
#
# Usage:
#   fm-view.sh probe [--install <root> --launch <dir> [--home <home>]]
#       Exit 0 when this host can build the view (and, with --launch, when that
#       directory may be viewed); otherwise print ONE line naming the concrete
#       reason on stdout and exit 1. bin/firstmate owns what a refusal means
#       (launch-mode selection, docs/configuration.md "Launch modes").
#   fm-view.sh run --install <root> --launch <dir> [--] <cmd> [args...]
#       Run <cmd> inside the view with cwd = <dir>, exporting FM_VIEW=1,
#       FM_VIEW_ROOT=<dir>, FM_LAUNCH_REAL (a read-only alias of the real
#       launch tree), and FM_LAUNCH_REAL_RW (a writable alias, reserved for a
#       concrete captain-approved project operation under AGENTS.md hard rule
#       1). Both aliases exist only inside the session.
#   fm-view.sh shadowed <real-launch-dir>
#       Print "<name><TAB><how>" for every real top-level entry the view does
#       not present at its own path (how = folded, merged, firstmate, or hidden).
#
# View of <dir> inside the namespace:
#   AGENTS.md          composed, read-only: Firstmate's AGENTS.md, then a
#                      launch-directory header, then the launch directory's own
#                      AGENTS.md, AGENTS.override.md, CLAUDE.md, CLAUDE.local.md
#                      and .claude/CLAUDE.md (a CLAUDE.md that is only an
#                      @AGENTS.md pointer is skipped)
#   CLAUDE.md          Firstmate's CLAUDE.md (the @AGENTS.md pointer)
#   bin/ docs/         Firstmate's; merged one level with a same-named project
#                      directory (Firstmate wins an exact-name collision)
#   .agents/ .claude/ .codex/ .cursor/ .grok/ .opencode/ .pi/ .omp/
#                      Firstmate's, read-only, as at the install root
#   AGENTS.override.md CLAUDE.local.md .mcp.json opencode.json opencode.jsonc
#                      hidden: each would override or extend the supervisor
#                      (the two instruction files load only through AGENTS.md)
#   .firstmate/        the project's own home, read-write
#   everything else    the project's real entries, read-only
# Git always runs against the REAL tree at the same path: a shim bound over the
# git binary re-enters a nested namespace, so status stays clean and no view
# file can be added. A keeper (the namespace's root process) re-syncs the view
# every FM_VIEW_POLL seconds (default 2) so top-level entries created,
# replaced, or removed outside the session appear here too; directory contents
# are always live. Top-level names holding a tab or newline are not presented.
#
# Runtime files live in $XDG_RUNTIME_DIR/firstmate-view.<pid> (else
# ${TMPDIR:-/tmp}), never under the launch directory or the home. Host-side
# cleanup removes named files only and never recurses, because a mount that
# failed to detach still exposes the real tree underneath.
# FM_VIEW_KEEP_LOG=1 keeps the keeper log beside the runtime dir.
# The keeper's RUN, INSTALL, INSTALL_SRC, LAUNCH, REALRW, and GIT_REAL arrive
# through the environment cmd_run sets, and the composed text names variables
# for the reader to expand, never this shell.
# shellcheck disable=SC2153,SC2016
set -eu

# The one owner of the view's layout; `shadowed` and the keeper both read it.
FM_DIRS="bin docs .agents .claude .codex .cursor .grok .opencode .pi .omp"
MERGE_DIRS="bin docs"
HIDE="AGENTS.override.md CLAUDE.local.md .mcp.json opencode.json opencode.jsonc"
RW_ENTRIES=".firstmate"
INSTR_FILES="AGENTS.md AGENTS.override.md CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md"
POLL=${FM_VIEW_POLL:-2}
case "$POLL" in '' | *[!0-9.]*) POLL=2 ;; esac

die() { echo "fm-view: $*" >&2; exit 1; }
inlist() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# path_within <path> <dir>: true when <path> is <dir> or lies under it.
path_within() {
  [ "$1" = "$2" ] && return 0
  [ "$2" = / ] && return 0
  case "$1" in "$2"/*) return 0 ;; esac
  return 1
}

# compose_agents <install> <real-launch> <launch-path> <out>: rewrite <out> in
# place (same inode, so an existing bind of it stays coherent).
compose_agents() {
  local install=$1 real=$2 launch=$3 out=$4 f body tmp
  tmp=$(mktemp "$out.XXXXXX")
  {
    cat "$install/AGENTS.md"
    printf '\n\n---\n\n# Launch directory instructions\n\n'
    printf 'This session runs with its working directory at %s, presented through a Firstmate view.\n' "$launch"
    printf 'The Firstmate contract above governs this session; the instructions below are the launch directory'"'"'s own and describe the project for you and for the workers that change it.\n'
    printf 'Where they conflict with the contract above, the contract wins.\n'
    printf 'Firstmate'"'"'s own bin/, docs/, and harness directories shadow same-named project paths in this view; the real project tree is readable at $FM_LAUNCH_REAL.\n'
    printf 'The launch directory is read-only in this session, which enforces hard rule 1; only its .firstmate/ home is writable.\n'
    printf 'A concrete captain-approved project operation under hard rule 1 writes through $FM_LAUNCH_REAL_RW, the same tree at a writable path; git works normally at the launch path.\n'
    for f in $INSTR_FILES; do
      [ -f "$real/$f" ] || continue
      body=$(grep -v -E '^[[:space:]]*(<!--.*-->)?[[:space:]]*$' "$real/$f" || true)
      [ "$body" = "@AGENTS.md" ] && continue
      printf '\n## %s/%s\n\n' "$launch" "$f"
      cat "$real/$f"
    done
  } > "$tmp"
  cat "$tmp" > "$out"
  rm -f -- "$tmp"
}

# ---------------------------------------------------------------- probe

# probe_host: print nothing and succeed when this host can build a view;
# otherwise print one reason line and fail.
probe_host() {
  local os tool err uid gid restrict
  os=$(uname -s 2>/dev/null || echo unknown)
  if [ "$os" != Linux ]; then
    echo "this host runs $os; the per-session view needs Linux user and mount namespaces"
    return 1
  fi
  for tool in unshare mount umount mountpoint stat git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found; the per-session view needs util-linux and git"; return 1; }
  done
  uid=$(id -u) gid=$(id -g)
  # One namespace exercises everything the view uses: an unprivileged
  # user+mount namespace with a tmpfs mount (the keeper), a nested one (the git
  # shim), and --map-user/--map-group (util-linux 2.38+, the harness drop).
  if ! err=$(unshare --user --map-root-user --mount -- sh -c '
      d=$(mktemp -d) || exit 1
      mount -t tmpfs fm-view-probe "$d" || exit 1
      unshare --user --map-root-user --mount -- true || { echo "nested namespace refused" >&2; exit 1; }
      unshare --user --map-user="$1" --map-group="$2" -- true || { echo "unshare lacks --map-user (util-linux 2.38+ needed)" >&2; exit 1; }
    ' fm-view-probe "$uid" "$gid" 2>&1 >/dev/null); then
    err=$(printf '%s\n' "$err" | sed -n '1p')
    restrict=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true)
    if [ "$restrict" = 1 ]; then
      echo "this host refuses unprivileged user namespaces (kernel.apparmor_restrict_unprivileged_userns=1): ${err:-no detail}"
    else
      echo "this host refuses an unprivileged user+mount namespace: ${err:-no detail}"
    fi
    return 1
  fi
}

# probe_root <install> <launch> [home]: reasons a specific launch directory may
# not be viewed even on a capable host.
probe_root() {
  local install=$1 launch=$2 home=${3:-} home_dir='' run_base
  install=$(cd "$install" 2>/dev/null && pwd -P) || { echo "install root does not exist: $1"; return 1; }
  launch=$(cd "$launch" 2>/dev/null && pwd -P) || { echo "launch directory does not exist: $2"; return 1; }
  [ -f "$install/AGENTS.md" ] && [ -d "$install/bin" ] || { echo "$install is not a Firstmate install root"; return 1; }
  if path_within "$launch" "$install"; then
    echo "the launch directory $launch is inside the Firstmate install root"
    return 1
  fi
  if [ -n "${FM_VIEW:-}" ]; then
    echo "this launch is already inside a Firstmate view"
    return 1
  fi
  if [ -n "${HOME:-}" ]; then
    home_dir=$(cd "$HOME" 2>/dev/null && pwd -P) || home_dir=$HOME
    if path_within "$home_dir" "$launch"; then
      echo "the launch directory $launch contains your home directory, whose harness configuration must stay writable"
      return 1
    fi
  fi
  run_base=$(runtime_base)
  run_base=$(cd "$run_base" 2>/dev/null && pwd -P) || run_base=
  if [ -n "$run_base" ] && path_within "$run_base" "$launch"; then
    echo "the launch directory $launch contains the view runtime directory $run_base"
    return 1
  fi
  if [ -n "$home" ]; then
    home=$(cd "$home" 2>/dev/null && pwd -P) || home=
    if [ -n "$home" ] && path_within "$home" "$launch" && ! path_within "$home" "$launch/.firstmate"; then
      echo "the Firstmate home $home lies inside the launch directory but outside its .firstmate/, and the view presents the project read-only"
      return 1
    fi
  fi
}

runtime_base() {
  local base=${XDG_RUNTIME_DIR:-}
  if [ -z "$base" ] || [ ! -d "$base" ] || [ ! -w "$base" ]; then
    base=${TMPDIR:-/tmp}
  fi
  printf '%s\n' "${base%/}"
}

cmd_probe() {
  local install='' launch='' home=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --install) install=${2:-}; shift 2 || die "--install needs a value" ;;
      --launch) launch=${2:-}; shift 2 || die "--launch needs a value" ;;
      --home) home=${2:-}; shift 2 || die "--home needs a value" ;;
      *) die "unknown probe argument: $1" ;;
    esac
  done
  if [ -n "$launch" ] || [ -n "$install" ]; then
    [ -n "$launch" ] && [ -n "$install" ] || die "probe needs both --install and --launch"
    probe_root "$install" "$launch" "$home" || return 1
  fi
  probe_host
}

# ---------------------------------------------------------------- shadowed

cmd_shadowed() {
  local real=${1:?usage: fm-view.sh shadowed <real-launch-dir>} name
  for name in AGENTS.md CLAUDE.md $HIDE; do
    [ -e "$real/$name" ] || [ -L "$real/$name" ] || continue
    case "$name" in
      AGENTS.md | CLAUDE.md | AGENTS.override.md | CLAUDE.local.md) printf '%s\tfolded\n' "$name" ;;
      *) printf '%s\thidden\n' "$name" ;;
    esac
  done
  for name in $FM_DIRS; do
    [ -e "$real/$name" ] || [ -L "$real/$name" ] || continue
    if inlist "$name" "$MERGE_DIRS" && [ -d "$real/$name" ] && [ ! -L "$real/$name" ]; then
      printf '%s\tmerged\n' "$name"
    else
      printf '%s\tfirstmate\n' "$name"
    fi
  done
}

# ---------------------------------------------------------------- keeper side
# Runs as root of the new user namespace: capabilities over this private mount
# namespace only; the host uid on disk is unchanged.

sig() { # sig <path>: identity used to detect replacement
  stat -c '%F:%d:%i' -- "$1" 2>/dev/null || echo missing
}

mp_rw() { mount -o remount,bind,rw -- "$1" 2>/dev/null || true; }
mp_ro() { mount -o remount,bind,ro -- "$1" 2>/dev/null || true; }

drop_entry() { # drop_entry <mountpoint>
  # Never recursive: a mountpoint that failed to detach still exposes the
  # real tree underneath, so only an empty dir or a lone file/link is removed.
  local mp=$1
  while mountpoint -q -- "$mp" 2>/dev/null; do
    umount -l -- "$mp" || { echo "fm-view: cannot detach $mp; left in place" >&2; return 1; }
  done
  if [ -L "$mp" ] || [ -f "$mp" ]; then
    rm -f -- "$mp"
  elif [ -d "$mp" ]; then
    rmdir -- "$mp"
  fi
}

put_entry() { # put_entry <kind> <source> <mountpoint> <ro|rw>
  local kind=$1 src=$2 mp=$3 mode=$4
  case "$kind" in
    link) ln -s -- "$(readlink -- "$src")" "$mp" ;;
    fmlink) ln -s -- "$src" "$mp" ;;
    dir)
      mkdir -p -- "$mp"
      mount --rbind -- "$src" "$mp"
      [ "$mode" = rw ] || mount -o remount,bind,ro -- "$mp"
      ;;
    file)
      : > "$mp"
      mount --bind -- "$src" "$mp"
      [ "$mode" = rw ] || mount -o remount,bind,ro -- "$mp"
      ;;
    merged)
      mkdir -p -- "$mp"
      mount -t tmpfs -o mode=0755,size=1m fm-view-merged "$mp"
      ;;
  esac
}

# entry_kind <path>: link, dir, file, or nothing for a vanished entry.
entry_kind() {
  if [ -L "$1" ]; then echo link
  elif [ -d "$1" ]; then echo dir
  elif [ -e "$1" ]; then echo file
  fi
}

# desired_top: print "name<TAB>kind<TAB>source<TAB>mode" for the view root.
desired_top() {
  local name kind mode
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in *$'\t'*) continue ;; esac
    inlist "$name" "AGENTS.md CLAUDE.md $HIDE" && continue
    if inlist "$name" "$FM_DIRS" && [ -e "$INSTALL_SRC/$name" ]; then
      if inlist "$name" "$MERGE_DIRS" && [ -d "$REALRW/$name" ] && [ ! -L "$REALRW/$name" ]; then
        printf '%s\tmerged\t%s\trw\n' "$name" "$REALRW/$name"
      fi
      continue
    fi
    kind=$(entry_kind "$REALRW/$name")
    [ -n "$kind" ] || continue
    if inlist "$name" "$RW_ENTRIES"; then mode=rw; else mode=ro; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$kind" "$REALRW/$name" "$mode"
  done < <(ls -A -- "$REALRW")
  for name in $FM_DIRS; do
    [ -e "$INSTALL_SRC/$name" ] || continue
    if inlist "$name" "$MERGE_DIRS" && [ -d "$REALRW/$name" ] && [ ! -L "$REALRW/$name" ]; then continue; fi
    printf '%s\tdir\t%s\tro\n' "$name" "$INSTALL_SRC/$name"
  done
  printf 'AGENTS.md\tfile\t%s\tro\n' "$RUN/AGENTS.md"
  printf 'CLAUDE.md\tfile\t%s\tro\n' "$RUN/CLAUDE.md"
}

# desired_merged <name>: Firstmate entries as symlinks into the read-only
# install alias (coherent), project entries as read-only binds; Firstmate wins an exact-name
# collision.
desired_merged() {
  local name=$1 e kind
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in *$'\t'*) continue ;; esac
    printf '%s\tfmlink\t%s\tro\n' "$e" "$INSTALL_SRC/$name/$e"
  done < <(ls -A -- "$INSTALL_SRC/$name")
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in *$'\t'*) continue ;; esac
    { [ -e "$INSTALL_SRC/$name/$e" ] || [ -L "$INSTALL_SRC/$name/$e" ]; } && continue
    kind=$(entry_kind "$REALRW/$name/$e")
    [ -n "$kind" ] || continue
    printf '%s\t%s\t%s\tro\n' "$e" "$kind" "$REALRW/$name/$e"
  done < <(ls -A -- "$REALRW/$name")
}

# sync_level <view-dir> <state-file> <desired-fn> [fn-args...]: converge one
# synthetic directory on its desired entry list. Records name, kind, source,
# mode, and the source identity; a changed identity (a replaced file) is
# re-bound.
sync_level() {
  local dir=$1 statef=$2 fn=$3 want name kind src mode id cur changed=0
  shift 3
  want=$("$fn" "$@" | while IFS=$'\t' read -r name kind src mode; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$src" "$mode" "$(sig "$src")"
  done | sort)
  cur=$(cat "$statef" 2>/dev/null || true)
  [ "$want" = "$cur" ] && return 0
  mp_rw "$dir"
  # Drop entries that vanished or changed.
  while IFS=$'\t' read -r name kind src mode id; do
    [ -n "$name" ] || continue
    printf '%s\n' "$want" | grep -qxF -- "$(printf '%s\t%s\t%s\t%s\t%s' "$name" "$kind" "$src" "$mode" "$id")" && continue
    drop_entry "$dir/$name" || true
    changed=1
  done <<< "$cur"
  # Add entries that are new or changed.
  while IFS=$'\t' read -r name kind src mode id; do
    [ -n "$name" ] || continue
    printf '%s\n' "$cur" | grep -qxF -- "$(printf '%s\t%s\t%s\t%s\t%s' "$name" "$kind" "$src" "$mode" "$id")" && continue
    put_entry "$kind" "$src" "$dir/$name" "$mode" || echo "fm-view: could not present $dir/$name" >&2
    [ "$kind" = merged ] && rm -f -- "$RUN/state/merged.$name"
    changed=1
  done <<< "$want"
  mp_ro "$dir"
  printf '%s\n' "$want" > "$statef"
  [ "$changed" -eq 0 ] || echo "$(date +%T) synced $dir" >> "$RUN/keeper.log"
}

sync_all() {
  local name srcsig
  sync_level "$LAUNCH" "$RUN/state/top" desired_top
  for name in $MERGE_DIRS; do
    [ -d "$REALRW/$name" ] && [ ! -L "$REALRW/$name" ] && [ -e "$INSTALL_SRC/$name" ] || continue
    sync_level "$LAUNCH/$name" "$RUN/state/merged.$name" desired_merged "$name"
  done
  # Recompose when either instruction source changed.
  srcsig="$(sig "$INSTALL_SRC/AGENTS.md") $(stat -c %Y:%s "$INSTALL_SRC/AGENTS.md" 2>/dev/null || true)"
  for name in $INSTR_FILES; do
    srcsig="$srcsig $(sig "$REALRW/$name") $(stat -c %Y:%s "$REALRW/$name" 2>/dev/null || true)"
  done
  if [ "$srcsig" != "$(cat "$RUN/state/compose" 2>/dev/null || true)" ]; then
    compose_agents "$INSTALL_SRC" "$REALRW" "$LAUNCH" "$RUN/AGENTS.md"
    printf '%s\n' "$srcsig" > "$RUN/state/compose"
  fi
}

keeper() {
  # Arguments arrive through the environment set by cmd_run.
  local poller rc=0
  mkdir -p "$RUN/state" "$RUN/rw" "$RUN/ro" "$RUN/install"
  : > "$RUN/git.real"
  # 1. Aliases of the REAL launch tree and install root, taken before the view
  #    covers the launch path (the install root may lie inside it).
  mount --rbind -- "$LAUNCH" "$RUN/rw"
  mount --rbind -- "$LAUNCH" "$RUN/ro"
  mount -o remount,bind,ro -- "$RUN/ro"
  mount --rbind -- "$INSTALL" "$RUN/install"
  mount -o remount,bind,ro -- "$RUN/install"
  # 2. The git shim over the real git binary (every exec of git in the view).
  mount --bind -- "$GIT_REAL" "$RUN/git.real"
  mount --bind -- "$RUN/git-shim" "$GIT_REAL"
  # 3. The synthetic view root.
  mount -t tmpfs -o mode=0755,size=4m fm-view "$LAUNCH"
  mount -o remount,bind,ro -- "$LAUNCH"
  sync_all
  (
    trap 'exit 0' TERM
    while sleep "$POLL"; do sync_all 2>>"$RUN/keeper.log" || true; done
  ) &
  poller=$!
  # 4. The harness: back to the caller's uid, no capabilities.
  cd -- "$LAUNCH"
  unset RUN INSTALL INSTALL_SRC LAUNCH REALRW GIT_REAL HOST_UID_KEEPER HOST_GID_KEEPER
  unshare --user --map-user="$FM_VIEW_UID" --map-group="$FM_VIEW_GID" -- "$@" || rc=$?
  kill "$poller" 2>/dev/null || true
  wait "$poller" 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------- host side

# cleanup_run <run>: host-side cleanup of a session's own runtime dir, named
# files only.
cleanup_run() {
  local run=$1
  rm -f -- "$run/state/top" "$run/state/compose" "$run/state"/merged.* "$run/AGENTS.md" \
    "$run/CLAUDE.md" "$run/git-shim" "$run/git.real"
  if [ -n "${FM_VIEW_KEEP_LOG:-}" ] && [ -s "$run/keeper.log" ]; then
    mv -- "$run/keeper.log" "$run.keeper.log"
  fi
  rm -f -- "$run/keeper.log"
  rmdir -- "$run/state" "$run/rw" "$run/ro" "$run/install" "$run" 2>/dev/null || true
}

cmd_run() {
  local install='' launch_dir='' reason git_real unshare_bin run rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --install) install=${2:-}; shift 2 || die "--install needs a value" ;;
      --launch) launch_dir=${2:-}; shift 2 || die "--launch needs a value" ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || die "usage: fm-view.sh run --install <root> --launch <dir> [--] <cmd> [args...]"
  [ -n "$install" ] && [ -n "$launch_dir" ] || die "run needs --install and --launch"
  if ! reason=$(cmd_probe --install "$install" --launch "$launch_dir" --home "${FM_HOME:-}"); then
    die "cannot build the view: $reason"
  fi
  install=$(cd "$install" && pwd -P)
  launch_dir=$(cd "$launch_dir" && pwd -P)
  git_real=$(readlink -f -- "$(command -v git)") || die "git not found"
  unshare_bin=$(command -v unshare)
  run="$(runtime_base)/firstmate-view.$$"
  [ ! -e "$run" ] || die "runtime dir already exists: $run"
  mkdir -m 700 -- "$run"
  # A closed terminal hangs up this process too: clean up before dying.
  # shellcheck disable=SC2064 # $run is local: expand now, while it is set.
  trap "cleanup_run $(printf %q "$run"); exit 129" HUP
  # shellcheck disable=SC2064
  trap "cleanup_run $(printf %q "$run"); exit 130" INT
  # shellcheck disable=SC2064
  trap "cleanup_run $(printf %q "$run"); exit 143" TERM
  mkdir -- "$run/state"
  compose_agents "$install" "$launch_dir" "$launch_dir" "$run/AGENTS.md"
  cp -- "$install/CLAUDE.md" "$run/CLAUDE.md"
  cat > "$run/git-shim" <<SHIM
#!/bin/sh
# fm-view git shim: run the real git with the REAL launch tree at its own path.
# The cwd is re-resolved by path after the remount, because a cwd inherited
# across unshare still points at the view's mount, not the real tree.
cwd=\$(pwd -P 2>/dev/null) || cwd=/
exec "$unshare_bin" --user --map-root-user --mount -- /bin/sh -c '
  mount --rbind "\$1" "\$2" && mount --bind "\$3" "\$4" || { echo "fm-view: git shim could not enter the real tree" >&2; exit 128; }
  cd -- "\$5" 2>/dev/null || true
  shift 5
  exec "$unshare_bin" --user --map-user="\$FM_VIEW_UID" --map-group="\$FM_VIEW_GID" -- "$git_real" "\$@"
' fm-view-git "$run/rw" "$launch_dir" "$run/git.real" "$git_real" "\$cwd" "\$@"
SHIM
  chmod 755 "$run/git-shim"
  RUN=$run INSTALL=$install INSTALL_SRC=$run/install LAUNCH=$launch_dir REALRW=$run/rw GIT_REAL=$git_real \
  FM_VIEW_UID=$(id -u) FM_VIEW_GID=$(id -g) \
  FM_VIEW=1 FM_VIEW_ROOT=$launch_dir FM_LAUNCH_REAL=$run/ro FM_LAUNCH_REAL_RW=$run/rw \
    "$unshare_bin" --user --map-root-user --mount --propagation private -- "$0" __keeper "$@" || rc=$?
  trap - HUP INT TERM
  cleanup_run "$run"
  return "$rc"
}

case "${1:-}" in
  probe) shift; cmd_probe "$@" ;;
  run) shift; cmd_run "$@" ;;
  shadowed) shift; cmd_shadowed "$@" ;;
  __keeper) shift; keeper "$@" ;;
  -h | --help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-view.sh probe|run|shadowed ..." >&2; exit 1 ;;
esac
