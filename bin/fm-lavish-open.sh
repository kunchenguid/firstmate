#!/usr/bin/env bash
# fm-lavish-open.sh - open a Lavish page in front of the captain and report
# whether the browser launch was refused.
#
# Usage: fm-lavish-open.sh <artifact.html> [--reopen]
#
# Every captain-facing Lavish page is opened through this command, by
# firstmate, secondmates and crew alike, and never by piping `lavish-axi
# <file>` through head or into /dev/null. It runs `lavish-axi <artifact>`
# (passing --reopen through), prints that first run's stdout and stderr
# unchanged, and then prints exactly one line:
#
#   browser-launch: ok        the launcher reported no failure
#   browser-launch: failed <url>
#                             every attempt reported a failed launch; the page
#                             is served but did not open, so hand the captain
#                             <url> in the status line or chat
#   browser-launch: skipped   lavish-axi refused a session the captain ended,
#                             so nothing was launched by design
#
# The exit status is lavish-axi's own. A nonzero exit prints no
# browser-launch line and is never retried.
#
# PERSISTENT ARTIFACTS ONLY. A page whose file lives in shared /tmp, an agent
# scratchpad, a pool worktree, or a `.lavish/` directory is lost on reboot or
# when the slot is returned, and the captain's open session then points at
# nothing. This command refuses such an artifact (exit 1, nothing launched) and
# names the home's persistent `data/` directory to write it under instead; an
# artifact already under that `data/` directory is always accepted. Set
# FM_LAVISH_ALLOW_EPHEMERAL=1 only for tests that open fixture pages.
#
# WHY. `lavish-axi <file>` exits 0 and prints `status: opened` even when the
# browser launch behind it failed; the only trace is a stderr line containing
# `browser launch failed`, which a truncating pipe or a stderr redirect hides.
# On WSL that launch is a Windows executable run through WSL interop, which
# needs WSL_INTEROP to name a live interop socket. Agent panes descend from a
# long-lived multiplexer server started outside any WSL login, so they inherit
# no WSL_INTEROP and fall back to the distribution's default socket, which can
# stop answering while per-login sockets keep working. So when a failure is
# reported and FM_LAVISH_INTEROP_DIR (default /run/WSL) holds interop sockets,
# the same open is run again with WSL_INTEROP set to each socket, newest first,
# until one attempt reports no failure. Re-running an open session only resumes
# it, and a retry happens only after a launch that reported failure, so a
# successful first launch never opens a second tab.
set -u

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

[ "$#" -ge 1 ] || usage
case "${1-}" in -h|--help) usage ;; esac
artifact=$1
shift
if [ "$#" -eq 1 ] && [ "$1" = --reopen ]; then
  :
elif [ "$#" -ne 0 ]; then
  usage
fi
[ -f "$artifact" ] || { printf 'error: artifact does not exist: %s\n' "$artifact" >&2; exit 1; }

# Resolve to the physical path: Lavish keys a session on it, and a symlink into
# /tmp must not smuggle an ephemeral file past the check.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}}
real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
  || { printf 'error: cannot resolve the artifact path: %s\n' "$artifact" >&2; exit 1; }
data_dir=$(CDPATH='' cd -- "$FM_HOME/data" 2>/dev/null && pwd -P || true)
ephemeral_reason() {  # <real-path>; prints why it is ephemeral, nonzero when it is not
  local path=$1 root
  for root in /tmp /var/tmp /dev/shm "${TMPDIR:-}"; do
    [ -n "$root" ] || continue
    root=${root%/}
    case "$path" in "$root"/*) printf 'under temporary directory %s' "$root"; return 0 ;; esac
  done
  case "$path" in
    */.lavish/*) printf 'inside a .lavish/ directory' ; return 0 ;;
    */scratchpad/*) printf 'inside an agent scratchpad'; return 0 ;;
    */.treehouse/*) printf 'inside a pool worktree'; return 0 ;;
  esac
  return 1
}
if [ "${FM_LAVISH_ALLOW_EPHEMERAL:-}" != 1 ]; then
  if [ -n "$data_dir" ] && case "$real" in "$data_dir"/*) true ;; *) false ;; esac; then
    :
  elif reason=$(ephemeral_reason "$real"); then
    printf 'error: refusing to open %s: it is %s and would be lost on reboot or slot return; write the page under %s/ and open it from there\n' \
      "$artifact" "$reason" "$FM_HOME/data" >&2
    exit 1
  fi
fi
command -v lavish-axi >/dev/null 2>&1 || { printf 'error: lavish-axi is not installed\n' >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/fm-lavish-open.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT

# One open attempt. Leaves stdout in $work/out and stderr in $work/err and
# returns lavish-axi's exit status.
open_once() {
  lavish-axi "$artifact" "$@" >"$work/out" 2>"$work/err"
}

launch_failed() { grep -qi 'browser launch failed' "$work/err"; }

# Interop sockets, newest first, one per physical socket, skipping the one the
# caller already used.
interop_candidates() {
  local dir=${FM_LAVISH_INTEROP_DIR:-/run/WSL}
  [ -d "$dir" ] || return 0
  perl -MCwd=realpath -e '
    my ($dir, $current) = @ARGV;
    my %seen;
    $seen{realpath($current) // $current} = 1 if length $current;
    my @socks;
    opendir(my $dh, $dir) or exit 0;
    for my $name (readdir $dh) {
      next unless $name =~ /_interop\z/;
      my $path = "$dir/$name";
      next unless -S $path;
      my $real = realpath($path) // next;
      next if $seen{$real}++;
      push @socks, [$path, (stat $real)[9]];
    }
    print "$_->[0]\n" for sort { $b->[1] <=> $a->[1] or $a->[0] cmp $b->[0] } @socks;
  ' "$dir" "${WSL_INTEROP-}"
}

rc=0
open_once "$@" || rc=$?
cat -- "$work/out"
cat -- "$work/err" >&2
[ "$rc" -eq 0 ] || exit "$rc"

if grep -Eq '^[[:space:]]*status:[[:space:]]*"?user-ended' "$work/out"; then
  printf 'browser-launch: skipped\n'
  exit 0
fi

url=$(sed -n 's/^[[:space:]]*url:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$work/out" | head -n 1)

if launch_failed; then
  while IFS= read -r socket; do
    WSL_INTEROP=$socket open_once "$@" || continue
    if ! launch_failed; then
      printf 'browser-launch: ok\n'
      exit 0
    fi
  done < <(interop_candidates)
  printf 'browser-launch: failed %s\n' "${url:-(no session url printed)}"
  exit 0
fi
printf 'browser-launch: ok\n'
