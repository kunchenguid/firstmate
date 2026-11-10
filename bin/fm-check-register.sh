#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id>
# Registration also normalizes the check to mode 0700, so a freshly written
# 0600 check cannot be left armed but unregistered (the watcher refuses any
# check that is not mode 0700 with a matching trust record); every refusal
# names the reason on stderr.
# Retire with fm-check-unregister.sh <id>; do not hand-compose an rm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

ID=$1
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$(fm_pr_file_device "$CHECK")" = "$STATE_DEVICE" ] && [ "$(fm_pr_file_link_count "$CHECK")" = 1 ] \
  || { echo "error: custom check state/$ID.check.sh must be a single-link file on the state device; not registered, the watcher will refuse it" >&2; exit 1; }
TMP=
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$(fm_pr_file_mode "$CHECK")" != 700 ]; then
  if ! perl -MFile::Temp -MFcntl=O_RDONLY,O_NOFOLLOW -e '
    my ($tmp, $cleanup);
    END { unlink $tmp if $cleanup && defined $tmp; }
    $cleanup = 1;
    $SIG{HUP} = sub { exit 129; };
    $SIG{INT} = sub { exit 130; };
    $SIG{TERM} = sub { exit 143; };
    my ($out, $name) = File::Temp::tempfile(
      ".fm-custom-check.XXXXXX", DIR => $ARGV[1], UNLINK => 0, PERMS => 0700,
    );
    $tmp = $name;
    sysopen(my $in, $ARGV[0], O_RDONLY | O_NOFOLLOW) or exit 1;
    binmode $in or exit 1;
    binmode $out or exit 1;
    my $previous = select($out);
    $| = 1;
    select($previous);
    while (1) {
      my $length = read($in, my $bytes, 8192);
      defined $length or exit 1;
      last if !$length;
      print {$out} $bytes or exit 1;
    }
    close $in or exit 1;
    my @file = stat($out);
    my @path = lstat($tmp);
    @file && @path && $file[0] == $path[0] && $file[1] == $path[1] && $path[3] == 1 or exit 1;
    rename $tmp, $ARGV[0] or exit 1;
    close $out or exit 1;
    $cleanup = 0;
  ' "$CHECK" "$STATE"; then
    echo "error: could not set mode 0700 on state/$ID.check.sh; not registered, the watcher will refuse it" >&2
    exit 1
  fi
fi
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check state/$ID.check.sh is not a private mode-0700 file; not registered, the watcher will refuse it" >&2; exit 1; }
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(perl -MFile::Temp -e '
  my ($tmp, $cleanup);
  END { unlink $tmp if $cleanup && defined $tmp; }
  $cleanup = 1;
  $SIG{HUP} = sub { exit 129; };
  $SIG{INT} = sub { exit 130; };
  $SIG{TERM} = sub { exit 143; };
  my ($out, $name) = File::Temp::tempfile(
    ".fm-custom-check-trust.XXXXXX", DIR => $ARGV[0], UNLINK => 0, PERMS => 0600,
  );
  $tmp = $name;
  print {$out} "fm-custom-check-v1\n$ARGV[1]\n" or exit 1;
  close $out or exit 1;
  $cleanup = 0;
  print STDOUT $tmp or exit 1;
' "$STATE" "$HASH") || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
