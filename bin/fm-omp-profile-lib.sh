#!/usr/bin/env bash
# fm-omp-profile-lib.sh - the single owner of the opt-in per-secondmate omp
# profile pin: which launch reads it, how the pin file is parsed, and the
# refusals.
#
# docs/configuration.md "Per-secondmate omp profile" owns the operator-facing
# contract. Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# The pin is config/secondmate-accounts/<id>/omp-profile in the launching
# (primary) home. Only a local secondmate's own omp agent reads it: ships,
# scouts, other harnesses, and remote secondmates never do, and there is no
# home-wide fallback file. It names an omp profile (`omp --profile <name>`,
# omp's own isolated auth, sessions, settings, and caches); it is independent
# of the worker account pin in bin/fm-worker-account-lib.sh, which pins a
# runner's credential root rather than an omp profile.
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must hold one profile name
# matching omp's own rule (omp 18.4.3: ^[a-z0-9][a-z0-9._-]{0,63}$, never
# ending in ".", never a Windows reserved device name with or without an
# extension), with an optional final newline; anything else refuses
# before any endpoint, worktree, or record exists, and nothing falls back to
# the ambient profile once the file exists. A raw omp launch command runs
# verbatim and cannot receive the flag, so a pinned mate refuses it.

# fm_omp_profile_read <file>
# Prints the profile name for a valid pin. Parses bytes before the shell can
# drop NULs or trailing newlines. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_omp_profile_read() {
  perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    $body =~ /\A([a-z0-9][a-z0-9._-]{0,63})\n?\z/ or exit 6;
    my $name = $1;
    $name =~ /\.\z/ and exit 6;
    $name =~ /\A(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|\z)/ and exit 6;
    print $name;
  ' -- "$1"
}

# fm_omp_profile_select <harness> <config-dir> <secondmate-id> [<raw-command>]
# The whole launch-time decision. Prints nothing when no pin applies: a harness
# other than omp, an empty secondmate id (a ship or scout), or an absent file.
# Prints the profile name for a pinned local secondmate. On refusal prints one
# error naming the file and returns 1. bin/fm-spawn.sh runs it before any
# endpoint exists, and bin/fm-control.sh before a relaunch stops the live
# agent.
fm_omp_profile_select() {
  local harness=$1 config=$2 mate=${3:-} raw=${4:-} cfg name rc
  [ "$harness" = omp ] && [ -n "$mate" ] || return 0
  cfg="$config/secondmate-accounts/$mate/omp-profile"
  name=$(fm_omp_profile_read "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: $cfg must be a readable regular file" >&2
    return 1
    ;;
  *)
    echo "error: $cfg must hold one omp profile name on a single line, matching ^[a-z0-9][a-z0-9._-]{0,63}\$, not ending in '.', and not a Windows reserved device name (con, prn, aux, nul, com0-9, lpt0-9, alone or with an extension), with no other lines or control characters" >&2
    return 1
    ;;
  esac
  if [ -n "$raw" ]; then
    echo "error: $cfg pins secondmate $mate to omp profile $name, and a raw omp launch command runs verbatim, so it cannot carry --profile; launch with --harness omp instead, or remove $cfg" >&2
    return 1
  fi
  printf '%s\n' "$name"
}
