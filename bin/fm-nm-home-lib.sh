#!/usr/bin/env bash
# fm-nm-home-lib.sh - the single owner of per-project no-mistakes home routing:
# how config/no-mistakes-homes is parsed, which no-mistakes home (NM_HOME) a
# project's no-mistakes ship launches under, and the launch-time checks on
# that home. bin/fm-nm-run-lib.sh owns how the home that owns a checkout's
# gate is derived.
#
# docs/configuration.md "No-mistakes home routing" owns the operator-facing
# contract. Sourced by bin/fm-spawn.sh.
#
# no-mistakes keeps its config, gate repos, daemon, and run state under one
# root, NM_HOME (default ~/.no-mistakes), and its daemon launches pipeline
# agents with the daemon's own environment, never the pushing worker's. So the
# Claude account a pipeline spends is chosen by the root's own config.yaml -
# agent_path_override.claude naming an executable that runs Claude under one
# account - and a worker reaches that root only when NM_HOME names it.
#
# config/no-mistakes-homes is opt-in. Each non-blank, non-# line is
#   <project> <absolute NM_HOME>
# where <project> is the registered project name (the clone's basename). An
# absent file, or a project with no line, keeps today's launch byte for byte:
# no NM_HOME is set and the worker uses the default root. A present file must
# parse, and a mapped project's root must pass every check below, or the
# no-mistakes ship refuses before any endpoint exists; nothing falls back to
# the default root once a project has declared one.
#
# The checks on a mapped root, in order:
#   - it is an existing readable, searchable directory holding config.yaml;
#   - config.yaml sets agent_path_override.claude in block form to an absolute
#     path of an executable regular file (the account wrapper); a shell alias
#     is not executable and cannot be named there;
#   - the wrapper answers `auth status` with exit 0 when run with only HOME,
#     PATH, TMPDIR, USER, and LOGNAME in its environment, the way the daemon
#     runs it, so a credential in the caller cannot answer for it;
#   - the project's own gate, when it already has one, sits under that root.
#     no-mistakes resolves a push by the gate's location and its init refuses
#     to repoint a gate remote another root created, so a mismatch would fail
#     at the worker's first pipeline step instead of here.
# Firstmate never edits config.yaml, initializes a repository, starts or
# restarts a daemon, copies credentials, or changes a login.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-nm-run-lib.sh"

FM_NM_HOME_CHECK_SECONDS=${FM_NM_HOME_CHECK_SECONDS:-30}

# fm_nm_home_lookup <config-dir> <project>
# Prints the root config/no-mistakes-homes maps <project> to, or nothing when
# the file is absent or names no such project. On a malformed file prints one
# error naming the line and returns 1.
fm_nm_home_lookup() {
  local file="$1/no-mistakes-homes" project=$2
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/no-mistakes-homes must be a readable regular file: $file" >&2
    return 1
  fi
  perl -e '
    my ($file, $project) = @ARGV;
    open(my $fh, "<", $file) or exit 1;
    my ($found, %seen);
    while (my $line = <$fh>) {
      chomp $line;
      next if $line =~ /\A\s*(#.*)?\z/;
      if ($line !~ /\A([A-Za-z0-9][A-Za-z0-9._-]*)[ \t]+(\/[^\x00-\x1f\x7f \t]*)[ \t]*\z/) {
        print STDERR "error: config/no-mistakes-homes line $. must be <project> <absolute NM_HOME>: $file\n";
        exit 1;
      }
      if ($seen{$1}++) {
        print STDERR "error: config/no-mistakes-homes maps project $1 more than once: $file\n";
        exit 1;
      }
      $found = $2 if $1 eq $project;
    }
    print "$found\n" if defined $found;
  ' -- "$file" "$project"
}

# fm_nm_home_claude_wrapper <root>
# Prints agent_path_override.claude from <root>/config.yaml when it is set in
# block form; prints nothing otherwise. Comments and quotes are stripped.
fm_nm_home_claude_wrapper() {
  perl -e '
    open(my $fh, "<", $ARGV[0]) or exit 0;
    my $in;
    while (my $line = <$fh>) {
      chomp $line;
      next if $line =~ /\A\s*(#.*)?\z/;
      if ($line =~ /\A\S/) {
        $in = $line =~ /\Aagent_path_override:\s*(#.*)?\z/;
        next;
      }
      next unless $in;
      if ($line =~ /\A\s+claude:\s*(.*?)\s*\z/) {
        my $v = $1;
        $v =~ s/\s+#.*\z//;
        $v = $1 if $v =~ /\A"(.*)"\z/ || $v =~ /\A\x27(.*)\x27\z/;
        print "$v\n";
        exit 0;
      }
    }
  ' -- "$1/config.yaml"
}

# fm_nm_home_select <config-dir> <project> <project-dir>
# The whole launch-time decision. Prints nothing for an unmapped project, so
# the caller keeps today's launch unchanged. For a mapped one prints the root
# after every check in the header passes. On refusal prints one error and
# returns 1.
fm_nm_home_select() {
  local config=$1 project=$2 dir=$3 root wrapper gate name
  root=$(fm_nm_home_lookup "$config" "$project") || return 1
  [ -n "$root" ] || return 0
  root=${root%/}
  if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ] || [ ! -f "$root/config.yaml" ]; then
    echo "error: config/no-mistakes-homes routes $project to $root, which is not a readable no-mistakes home holding config.yaml; create it (NM_HOME=$root no-mistakes doctor) and set agent_path_override.claude, or change the mapping" >&2
    return 1
  fi
  wrapper=$(fm_nm_home_claude_wrapper "$root")
  case "$wrapper" in
  /*) ;;
  *)
    echo "error: config/no-mistakes-homes routes $project to $root, whose config.yaml does not set agent_path_override.claude (block form) to an absolute path; name the account's executable wrapper there" >&2
    return 1
    ;;
  esac
  if [ ! -f "$wrapper" ] || [ ! -x "$wrapper" ]; then
    echo "error: config/no-mistakes-homes routes $project to $root, whose agent_path_override.claude $wrapper is not an executable file; a shell alias cannot be named there" >&2
    return 1
  fi
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  if ! fm_run_timed "$FM_NM_HOME_CHECK_SECONDS" "${clean[@]}" "$wrapper" auth status >/dev/null 2>&1 </dev/null; then
    echo "error: config/no-mistakes-homes routes $project to $root, whose Claude account wrapper $wrapper is not signed in ($wrapper auth status); sign that account in, or change the mapping" >&2
    return 1
  fi
  if ! gate=$(fm_nm_home_gate_root "$dir"); then
    echo "error: config/no-mistakes-homes routes $project to $root, but $dir has a no-mistakes remote that is not a managed gate path; inspect it with git -C $dir remote -v" >&2
    return 1
  fi
  if [ -n "$gate" ] && [ "$(cd "$gate" 2>/dev/null && pwd -P)" != "$(cd "$root" && pwd -P)" ]; then
    echo "error: config/no-mistakes-homes routes $project to $root, but its gate is registered under $gate; move the gate only when no run is active (git -C $dir remote remove no-mistakes, then NM_HOME=$root no-mistakes init), or change the mapping" >&2
    return 1
  fi
  printf '%s\n' "$root"
}
