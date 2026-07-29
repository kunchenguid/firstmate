#!/usr/bin/env bash
# fm-private-material-check.sh - refuse private fleet material in tracked files.
#
# Usage:
#   bin/fm-private-material-check.sh [--root <repo>] [--home <fm-home>] [--history]
#
# The default scan covers tracked files in the working tree AND at HEAD, because
# a dirty checkout is not the surface a push publishes: a marker already
# committed but edited out locally would otherwise read as absent. --history adds
# past commit content AND commit metadata (author and committer identity,
# subject, body), because a pull request carries all of that into the target
# repository and a marker deleted at tip is still published forever.
#
# A CONTRIBUTOR IDENTITY IS NOT A LEAK
# The local account name and the forge owner of one of THIS repo's own remotes
# are published by construction the moment a pull request carries its own
# commits, so finding one in the AUTHOR or COMMITTER field is expected rather
# than a finding. It is reported once per marker as a NOTICE that still prints on
# an otherwise clean run, and it never sets failure or changes the exit code.
# The allowance is exactly that pair and nothing else. It still FAILS, hard, on:
# a project clone's forge owner, which is a private organisation by definition
# and the most sensitive name in the set; a registered project name; a secondmate
# id; an operator-declared marker; and any marker at all found anywhere other
# than the author or committer identity fields - a subject, a body, or a file.
# The allowlist is deliberately NOT the answer here, because it drops a name at
# derivation time - allowing the account name to quiet this would also blind the
# tip scan to machine-local /home/<account>/ paths, buying a green run by
# removing a real protection.
#
# WHY THIS EXISTS
# Firstmate is a toolbox and orchestration repo whose tracked surface is meant to
# be shareable: it must let a fleet orchestrate private repositories without the
# private ones leaking into the public one. Publishing is irreversible, so a
# one-time audit is not enough - a marker that reappears in the next file written
# must fail something. This is that something.
#
# THE CHECK MUST NOT BECOME THE LEAK
# Nothing here names a real project, owner, person, or device. Every marker is
# derived at RUNTIME from local, gitignored sources, so a public reader of this
# file learns nothing about the fleet that runs it.
#
# Marker sources, all local and gitignored (see --home):
#   projects/<name>/                     project clone directory names
#   data/projects.md                     registered project names
#   data/secondmates.md                  registered secondmate ids and the
#                                        project names in their "projects:" field
#   git remote owners                    of this repo and of each project clone
#   the local account name               catches machine-local home paths; used
#                                        only when data/ or projects/ is present,
#                                        so it never fakes a marker source
#   config/private-material-markers      one entry per line, compared whole, so
#                                        a multi-word name is one entry; for anything not
#                                        derivable (device serials, people)
#
# Suppression, also local and gitignored:
#   config/private-material-allow        one entry per line, compared whole; for an
#                                        identity that is legitimately public,
#                                        such as the upstream this repo forks.
#
# Matching is case-insensitive - at the tip, through history, and across commit
# metadata alike - and treats "-", "_", and a space as the same separator, so a
# registered id also matches its display-name spelling ("sm-thing" matches
# "SM THING"). Matches are word-bounded, so a marker inside a longer word does
# not fire.
#
# NOTHING IS SUPPRESSED SILENTLY
# A run that could not prove the surface clean must never read like one that did,
# because false confidence here is worse than no check at all. So every marker
# source is accounted for by name and count, and each of these is reported as a
# COVERAGE GAP line rather than passing unmentioned:
#   - a PARSED source that is present but yields no names, meaning format drift
#     or an unreadable file silently removed a whole class of names
#   - a derived name dropped as shorter than MIN_LEN or as a generic STOPWORD
#   - a project clone whose git remotes could not be read, or a remote URL whose
#     form yields no forge owner
#   - an account name that could not be read
# An ENUMERATED source - a directory glob, or the remotes of a repository - is
# different: zero there is an unambiguous "there are none", not a name that went
# missing, so it is reported with its count and no gap. A guard that always warns
# stops being read, and an unread guard is no guard.
# A run with any gap reports INCOMPLETE rather than OK, and a scan command that
# FAILS - as opposed to finding nothing - aborts instead of reading as clean.
# Operator-declared markers are never dropped: they bypass the length and
# stopword filters, because declaring a token is the strongest available
# statement that it is private.
# An allowlisted name is not a gap - it is a decision the operator recorded, not
# a name that went missing - but it is still printed as an "allowed:" line beside
# the source counts, including the implicit allowance of this repo's own
# directory name, so a clean run never hides which names were removed before the
# scan.
#
# WHAT THIS CANNOT CATCH - state this plainly rather than trusting a green run:
#   - Private strategy, delivery posture, or fleet-internal decisions written as
#     ordinary prose that names no marker token. A marker scan cannot read intent.
#   - A paraphrase of what the fleet builds that avoids every registered name.
#   - Anything whose name is not in the local operational dirs: a retired or
#     never-registered project, a customer, or a person not listed in the extra
#     markers file.
#   - Anything at all when no marker source is present. On a machine or CI runner
#     with no private dirs the run is VACUOUS: it reports SKIPPED.
#     A SKIPPED run is not evidence the surface is clean.
#   - Commits BETWEEN the merge-base and HEAD, in the default mode. It scans the
#     working tree and HEAD, so a marker added in one commit and removed in a
#     later commit on the same unpushed branch is in neither and passes, even
#     though pushing that branch publishes it. --history covers that range, so
#     run it before ANY push, not only before contributing to a third party.
#     Defining the scanned surface once as the push range would remove this
#     hole; until then the limit is stated here rather than left to be found.
#   - Anything inside a tracked BINARY file. The content scans skip them by
#     design (git grep -I, and a binary blob yields no patch text for git log
#     -G), so a marker in the metadata of a checked-in image or archive is never
#     read - and, unlike a filtered name, it raises no gap because the file is
#     never opened.
#   - The INDEX. The scanned surfaces are the working tree and HEAD, so a marker
#     staged with git add and then edited back out of the working tree is in
#     neither and passes, right up until the commit that publishes it.
# Human review of the diff remains the real control; this only makes the
# mechanical, repeatable part of it impossible to forget.
#
# EXIT CODES - a stated contract, so no caller has to parse the output text to
# learn whether this run proved anything. "I proved it clean", "I found a leak",
# and "I could not prove anything" are three different answers and never share a
# code, because a caller that reads exit 0 as clean would otherwise be right most
# of the time and catastrophically wrong the rest:
#   0  OK          every marker was scanned and none is present
#   1  FAILED      private material is in the scanned surface
#   2  ERROR       bad usage, or a scan command that could not complete
#   3  SKIPPED or INCOMPLETE - this run proved NOTHING about the surface
set -eu

MIN_LEN=3

# Generic tokens that would storm the scan if a project, account, or secondmate
# happened to be named one of them. A fleet that really owns one of these names
# must add it to config/private-material-markers to force it back in; a derived
# name dropped here is always named in a COVERAGE GAP line, so the suppression
# is never invisible.
STOPWORDS="main master api web app core src bin lib doc docs data home user users
admin root dev test tests tmp temp work repo repos git github gitlab build dist
node http https com org net local shared common util utils new old the and for
firstmate treehouse herdr zellij orca cmux tmux claude codex opencode grok kimi
anthropic openai vercel supabase"

ROOT=""
HOME_DIR=""
SCAN_HISTORY=0

die() { printf 'fm-private-material-check: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT=$2; shift 2 ;;
    --home) [ $# -ge 2 ] || die "--home needs a value"; HOME_DIR=$2; shift 2 ;;
    --history) SCAN_HISTORY=1; shift ;;
    # Print the header block and stop at the first non-comment line, so the help
    # never spills code and never needs re-tuning when the header grows.
    -h|--help) sed -n '2,${/^#/!q; s/^# \{0,1\}//; p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
[ -d "$ROOT/.git" ] || git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "not a git repository: $ROOT"

# FM_HOME selects the private operational home; fall back to the repo root,
# which is where a primary checkout keeps its own data/ and projects/.
if [ -z "$HOME_DIR" ]; then
  HOME_DIR=${FM_HOME:-$ROOT}
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-private-material-check.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
ERRLOG="$TMPD/err"
: > "$ERRLOG"

NL='
'

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# --- source accounting -------------------------------------------------------
# Every declared source is reported by name, and anything that silently narrows
# coverage becomes a gap. A gap never fails the run on its own, but it does stop
# the run from claiming a clean result.

SOURCES=""
GAPS=""
GAP_COUNT=0

gap() {
  GAPS="${GAPS}COVERAGE GAP: $1${NL}"
  GAP_COUNT=$((GAP_COUNT + 1))
}

report_absent() { SOURCES="${SOURCES}  $1: absent${NL}"; }

# A parsed source yields names by matching a format, so zero means the format
# drifted or the file could not be read: a whole class of names went unscanned.
report_source() {
  SOURCES="${SOURCES}  $1: $2 name(s)${NL}"
  [ "$2" -gt 0 ] || gap "$1 is present but yielded no names, so nothing from it was scanned"
}

# An enumerated source lists what exists, so zero means there is nothing to
# enumerate - a fresh home with no clones yet, or a repository with no remotes.
# Nothing was missed, so nothing is reported as missed.
report_enumerated() { SOURCES="${SOURCES}  $1: $2 name(s)${NL}"; }

DERIVED=""
DECLARED=""
SRC_COUNT=0

# Names a published commit carries by construction: the account that authors
# commits in this checkout, and the forge owners of THIS repo's own remotes -
# the places a pull request from here actually goes. A project clone's forge
# owner is deliberately excluded: it is a private organisation by definition and
# has no business riding into this repo's published history, in an identity
# field or anywhere else. Tracked separately from DERIVED because it changes how
# an author or committer field is judged, and nothing else.
IDENT_ORIGIN="$NL"

add_ident_origin() {
  local m
  m=$(trim "$1")
  [ -n "$m" ] || return 0
  IDENT_ORIGIN="${IDENT_ORIGIN}$(lower "$m")${NL}"
}

add_derived() {
  local m
  m=$(trim "$1")
  [ -n "$m" ] || return 0
  DERIVED="${DERIVED}$(lower "$m")${NL}"
  SRC_COUNT=$((SRC_COUNT + 1))
}

add_declared() {
  local m
  m=$(trim "$1")
  [ -n "$m" ] || return 0
  DECLARED="${DECLARED}$(lower "$m")${NL}"
  SRC_COUNT=$((SRC_COUNT + 1))
}

# Read an operator-edited config file: strip comments and blanks, and keep the
# final line even when the file has no trailing newline, which is routine in a
# hand-edited file and would otherwise drop a whole marker.
read_config_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(trim "$line")
    case "$line" in ''|\#*) continue ;; esac
    printf '%s\n' "$line"
  done < "$1"
}

# 1. project clone directory names
if [ -d "$HOME_DIR/projects" ]; then
  SRC_COUNT=0
  for d in "$HOME_DIR/projects"/*; do
    [ -d "$d" ] || continue
    add_derived "$(basename "$d")"
  done
  report_enumerated "projects/ clone directories" "$SRC_COUNT"
else
  report_absent "projects/ clone directories"
fi

# 2. registered project names. Both registry forms are current: the delivery-mode
#    form "- <name> [<mode>] - ..." and the legacy bracketless "- <name> - ...".
if [ -f "$HOME_DIR/data/projects.md" ]; then
  SRC_COUNT=0
  while IFS= read -r name; do add_derived "$name"; done < <(
    sed -n 's/^[[:space:]]*-[[:space:]]\{1,\}\([A-Za-z0-9._-]\{1,\}\)[[:space:]]\{1,\}[[-].*/\1/p' \
      "$HOME_DIR/data/projects.md"
  )
  report_source "data/projects.md" "$SRC_COUNT"
else
  report_absent "data/projects.md"
fi

# 3. registered secondmate ids ("- <id> - ...") plus the project names in each
#    entry's "projects:" field, which are the only record of a project cloned
#    solely in a secondmate home.
if [ -f "$HOME_DIR/data/secondmates.md" ]; then
  SRC_COUNT=0
  while IFS= read -r name; do add_derived "$name"; done < <(
    sed -n 's/^[[:space:]]*-[[:space:]]\{1,\}\([A-Za-z0-9._-]\{1,\}\)[[:space:]]\{1,\}[[-].*/\1/p' \
      "$HOME_DIR/data/secondmates.md"
  )
  while IFS= read -r name; do add_derived "$name"; done < <(
    sed -n 's/.*[Pp]rojects:[[:space:]]*\([^;)]*\).*/\1/p' "$HOME_DIR/data/secondmates.md" \
      | tr ',' '\n'
  )
  report_source "data/secondmates.md" "$SRC_COUNT"
else
  report_absent "data/secondmates.md"
fi

# 4. forge OWNERS of this repo's remotes and of every project clone's remotes.
#    Owners only, never repository names: a repo name is usually this repo's own
#    name or a project name already covered above, and matching it would storm.
#    A directory whose remotes cannot be read is a gap, not a silent zero, and so
#    is a remote URL this parser cannot resolve to an owner: dropping one quietly
#    would leave a forge owner unscanned while the run still read as covered.
#    <publishes> marks the repository whose remotes this repo actually pushes to;
#    only those owners are published by construction, so only they relax an
#    identity field. A project clone passes 0 and its owner stays a hard failure.
collect_remote_owners() {
  local dir=$1 label=$2 publishes=$3 line key url rest path owner rc urls
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    gap "$label is not a git repository, so its forge owners could not be read"
    return 0
  fi
  # Capture git's own status: piping first would report the pipe's last command.
  urls=$(git -C "$dir" config --get-regexp '^remote\..*\.url$' 2>"$ERRLOG") && rc=0 || rc=$?
  if [ "$rc" -gt 1 ]; then
    gap "$label: reading git remotes failed (exit $rc: $(tr '\n' ' ' < "$ERRLOG")), so its forge owners are unscanned"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%% *}
    url=${line#* }
    case "$url" in
      # A local path names no forge owner and never will; that is not a gap.
      /*|./*|../*|file://*) continue ;;
      *://*) rest=${url#*://} ;;
      # scp-style "user@host:path"; the path may or may not carry an owner.
      *:*) rest=${url%%:*}/${url#*:} ;;
      *) gap "$label: $key has an unrecognised URL form, so its forge owner is unscanned"
         continue ;;
    esac
    # Any credentials live in the userinfo, which precedes the first "/", so
    # taking the path after the host drops them without a separate strip.
    case "$rest" in
      */*) path=${rest#*/} ;;
      *) path="" ;;
    esac
    case "$path" in
      */*) owner=${path%%/*} ;;
      # No owner component: an owner-less host path, or scp-style with a bare
      # repository. Deriving the repository name here would be wrong, so say so.
      *) gap "$label: $key has no forge-owner component, so no owner was derived from it"
         continue ;;
    esac
    add_derived "$owner"
    if [ "$publishes" -eq 1 ]; then
      add_ident_origin "$owner"
    fi
  done <<EOF
$urls
EOF
}
SRC_COUNT=0
collect_remote_owners "$ROOT" "this repo" 1
if [ -d "$HOME_DIR/projects" ]; then
  for d in "$HOME_DIR/projects"/*; do
    [ -d "$d" ] && collect_remote_owners "$d" "project clone $(basename "$d")" 0
  done
fi
report_enumerated "git remote owners" "$SRC_COUNT"

# 5. the local account name, which is what makes machine-local home paths legible.
#    Only when this really is an operational home: on a runner with no private
#    dirs the account name is noise, and adding it unconditionally would make
#    every run look like it had a marker source when it had none.
if [ -d "$HOME_DIR/data" ] || [ -d "$HOME_DIR/projects" ]; then
  SRC_COUNT=0
  if acct=$(id -un 2>"$ERRLOG") && [ -n "$acct" ]; then
    add_derived "$acct"
    add_ident_origin "$acct"
    report_source "the local account name" "$SRC_COUNT"
  else
    SOURCES="${SOURCES}  the local account name: unreadable${NL}"
    gap "the local account name could not be read, so machine-local home paths are unscanned"
  fi
else
  report_absent "the local account name"
fi

# 6. operator-supplied markers that nothing can derive
MARKERS_FILE="$HOME_DIR/config/private-material-markers"
if [ -f "$MARKERS_FILE" ]; then
  SRC_COUNT=0
  while IFS= read -r line; do add_declared "$line"; done < <(read_config_lines "$MARKERS_FILE")
  report_source "config/private-material-markers" "$SRC_COUNT"
else
  report_absent "config/private-material-markers"
fi

# Allowlist: identities that are legitimately public for this home. Entries are
# newline-delimited and compared whole, so a multi-word entry never also allows
# its interior words as standalone markers.
ALLOW_CONFIG="$NL"
ALLOW_FILE="$HOME_DIR/config/private-material-allow"
if [ -f "$ALLOW_FILE" ]; then
  while IFS= read -r line; do
    ALLOW_CONFIG="${ALLOW_CONFIG}$(lower "$line")${NL}"
  done < <(read_config_lines "$ALLOW_FILE")
fi
# This repo's own directory name is never a marker: it names the tool, not a
# fleet. Kept apart from the config entries so an "allowed:" line can say which
# of the two removed the name.
ALLOW="${ALLOW_CONFIG}$(lower "$(basename "$ROOT")")${NL}"

# An allowlisted name is a recorded decision rather than a coverage gap, but it
# still narrows what was scanned, so it is accounted for by name and source.
ALLOWED=""
allowed_note() { ALLOWED="${ALLOWED}  allowed: \"$1\" ($2)${NL}"; }

STOPWORD_SET=" $(printf '%s' "$STOPWORDS" | tr '\n' ' ') "

MARKERS=""
SEEN="$NL"
keep_marker() {
  case "$SEEN" in *"$NL$1$NL"*) return 0 ;; esac
  SEEN="${SEEN}$1${NL}"
  MARKERS="${MARKERS}$1${NL}"
}

# Operator-declared markers first, and unconditionally: the length and stopword
# filters exist to keep DERIVED noise out, not to overrule an explicit "this is
# private". A token in both config files is an operator contradiction, so keep
# it and say so rather than resolving it silently toward publication.
while IFS= read -r m; do
  [ -n "$m" ] || continue
  case "$ALLOW" in
    *"$NL$m$NL"*)
      gap "\"$m\" is declared in config/private-material-markers and also allowed in config/private-material-allow; keeping it as a marker" ;;
  esac
  keep_marker "$m"
done < <(printf '%s' "$DECLARED" | sort -u)

while IFS= read -r m; do
  [ -n "$m" ] || continue
  case "$SEEN" in *"$NL$m$NL"*) continue ;; esac
  case "$ALLOW" in
    *"$NL$m$NL"*)
      case "$ALLOW_CONFIG" in
        *"$NL$m$NL"*) allowed_note "$m" "config/private-material-allow" ;;
        *) allowed_note "$m" "this repo's own directory name" ;;
      esac
      continue ;;
  esac
  if [ "${#m}" -lt "$MIN_LEN" ]; then
    gap "derived name \"$m\" is shorter than $MIN_LEN characters and was NOT scanned"
    continue
  fi
  case "$STOPWORD_SET" in
    *" $m "*)
      gap "derived name \"$m\" is filtered as generic and was NOT scanned; declare it in config/private-material-markers to force it in"
      continue ;;
  esac
  keep_marker "$m"
done < <(printf '%s' "$DERIVED" | sort -u)

printf 'fm-private-material-check: marker sources under %s:\n' "$HOME_DIR"
printf '%s' "$SOURCES"
[ -z "$ALLOWED" ] || printf '%s' "$ALLOWED"
[ "$GAP_COUNT" -eq 0 ] || printf '%s' "$GAPS"

if [ -z "$MARKERS" ]; then
  if [ "$GAP_COUNT" -gt 0 ]; then
    printf 'fm-private-material-check: SKIPPED - every name found under %s was filtered out (see the gaps above).\n' "$HOME_DIR"
  else
    printf 'fm-private-material-check: SKIPPED - no private marker sources under %s\n' "$HOME_DIR"
  fi
  printf 'fm-private-material-check: a SKIPPED run proves nothing about the tracked surface.\n'
  exit 3
fi

# Build a word-bounded, separator-insensitive pattern for one marker.
marker_pattern() {
  local m=$1 esc
  esc=$(printf '%s' "$m" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')
  # any run of "-", "_" or space in the marker matches any of them, or nothing
  esc=$(printf '%s' "$esc" | sed 's/[-_ ]\{1,\}/[-_ ]?/g')
  printf '(^|[^A-Za-z0-9])%s([^A-Za-z0-9]|$)' "$esc"
}

history_remedy() {
  printf '  (remedy differs from a tip fix: published history cannot be unpublished by a\n'
  printf '   later commit, so this needs a rewrite or a squashed re-publish - the\n'
  printf '   captain'"'"'s call, not this script'"'"'s)\n'
}

# A scan command that fails is not a scan that found nothing. Treat any status
# beyond "matched" / "did not match" as fatal, with the tool's own diagnostic.
scan_failed() {
  printf '\nfm-private-material-check: %s failed (exit %s):\n' "$2" "$1" >&2
  sed 's/^/  /' "$ERRLOG" >&2
  printf 'fm-private-material-check: ABORTED - the scan could not complete, so this run proves nothing.\n' >&2
  exit 2
}

# Commit metadata travels with a pull request exactly like file content does,
# and an author identity is the usual way a real name or an org email domain
# reaches a third-party repository. Flatten each commit to one line so a
# multi-line body cannot hide a marker from a line-oriented grep. Built once,
# before the marker loop, so a failure here is caught before any marker is
# reported clean.
# Identity and message are collected separately because they are judged
# differently: an author or committer field carries whoever pushes, while a
# subject or body is authored text that can carry anything.
META_IDENT="$TMPD/meta-identity"
META_MSG="$TMPD/meta-message"
TIPHITS="$TMPD/tip"
# A repository with no commits has no committed surface to scan; that is not a
# gap, because nothing has been published from it.
HAVE_HEAD=0
git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1 && HAVE_HEAD=1
if [ "$SCAN_HISTORY" -eq 1 ]; then
  git -C "$ROOT" log --all -z --format='%h %an <%ae> %cn <%ce>' \
    >"$TMPD/ident.raw" 2>"$ERRLOG" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || scan_failed "$rc" "reading commit identities"
  tr '\n' ' ' < "$TMPD/ident.raw" | tr '\0' '\n' > "$META_IDENT"
  git -C "$ROOT" log --all -z --format='%h %s %b' \
    >"$TMPD/msg.raw" 2>"$ERRLOG" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || scan_failed "$rc" "reading commit messages"
  tr '\n' ' ' < "$TMPD/msg.raw" | tr '\0' '\n' > "$META_MSG"
fi

# The account that writes commits here, and the forge owners of this repo's own
# remotes, ride along on every published commit, so seeing one in an identity
# field is expected. Nothing else qualifies - a project clone's owner is not in
# IDENT_ORIGIN and so lands in the failing branch below. An operator-declared
# marker never qualifies either: declaring a token is the strongest available
# statement that it must not be published anywhere.
is_expected_identity() {
  case "$NL$DECLARED" in *"$NL$1$NL"*) return 1 ;; esac
  case "$IDENT_ORIGIN" in *"$NL$1$NL"*) return 0 ;; esac
  return 1
}
NOTICES=""

status=0
count=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  count=$((count + 1))
  pat=$(marker_pattern "$m")
  hits=$(git -C "$ROOT" grep -n -I -i -E -e "$pat" 2>"$ERRLOG") && rc=0 || rc=$?
  [ "$rc" -le 1 ] || scan_failed "$rc" "scanning tracked files for marker \"$m\""
  if [ -n "$hits" ]; then
    status=1
    printf '\nPRIVATE MATERIAL: marker "%s" appears in tracked files:\n' "$m"
    printf '%s\n' "$hits" | sed 's/^/  /'
  fi
  # git grep reads the working tree, so on a dirty checkout it is not reading
  # what a push would publish. Scan HEAD too, and report only what the working
  # tree did not already show, so the committed-only case cannot pass silently.
  if [ "$HAVE_HEAD" -eq 1 ]; then
    headhits=$(git -C "$ROOT" grep -n -I -i -E -e "$pat" HEAD 2>"$ERRLOG") && rc=0 || rc=$?
    [ "$rc" -le 1 ] || scan_failed "$rc" "scanning the committed tree for marker \"$m\""
    # Dedup on path plus content, never on path:line:content: any working-tree
    # edit shifts line numbers, and comparing the whole string would then
    # re-report an already reported hit as committed-only. That label is what
    # tells the operator whether a tip fix is enough, so it must not lie.
    printf '%s\n' "$hits" | sed 's/^\([^:]*\):[0-9]\{1,\}:/\1:/' > "$TIPHITS" 2>"$ERRLOG" \
      || scan_failed 2 "recording working-tree hits for marker \"$m\""
    headhits=$(printf '%s\n' "$headhits" | sed 's/^HEAD://' \
      | awk -v keys="$TIPHITS" '
          BEGIN { while ((getline k < keys) > 0) seen[k] = 1 }
          { p = $0; sub(/:.*/, "", p)
            c = $0; sub(/^[^:]*:[0-9]+:/, "", c)
            if (!((p ":" c) in seen)) print }') && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || scan_failed "$rc" "de-duplicating committed hits for marker \"$m\""
    if [ -n "$headhits" ]; then
      status=1
      printf '\nPRIVATE MATERIAL AT HEAD: marker "%s" is committed, beyond what the working tree shows:\n' "$m"
      printf '%s\n' "$headhits" | sed 's/^/  /'
    fi
  fi
  if [ "$SCAN_HISTORY" -eq 1 ]; then
    # -i is required here: markers are lowercased, and git log -G is
    # case-sensitive by default, so without it the history scan would miss
    # exactly the spellings the tip scan catches.
    hist=$(git -C "$ROOT" log --all -i --oneline -G"$pat" 2>"$ERRLOG") && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || scan_failed "$rc" "scanning history for marker \"$m\""
    if [ -n "$hist" ]; then
      status=1
      printf '\nPRIVATE MATERIAL IN HISTORY: marker "%s" appears in the content of:\n' "$m"
      printf '%s\n' "$hist" | sed 's/^/  /'
      history_remedy
    fi
    meta=$(grep -i -E -- "$pat" "$META_MSG" 2>"$ERRLOG") && rc=0 || rc=$?
    [ "$rc" -le 1 ] || scan_failed "$rc" "scanning commit messages for marker \"$m\""
    if [ -n "$meta" ]; then
      status=1
      printf '\nPRIVATE MATERIAL IN COMMIT METADATA: marker "%s" appears in the subject or body of:\n' "$m"
      printf '%s\n' "$meta" | cut -c1-160 | sed 's/^/  /' | head -20
      history_remedy
    fi
    ident=$(grep -i -E -- "$pat" "$META_IDENT" 2>"$ERRLOG") && rc=0 || rc=$?
    [ "$rc" -le 1 ] || scan_failed "$rc" "scanning commit identities for marker \"$m\""
    if [ -n "$ident" ]; then
      if is_expected_identity "$m"; then
        ident_n=$(printf '%s\n' "$ident" | wc -l | tr -d '[:space:]')
        NOTICES="${NOTICES}NOTICE: marker \"$m\" appears in the author or committer identity of $ident_n commit(s). A contributor identity is published by construction, so this is expected and is NOT a failure; it is reported so the run never hides it.${NL}"
      else
        status=1
        printf '\nPRIVATE MATERIAL IN COMMIT METADATA: marker "%s" appears in the author or committer identity of:\n' "$m"
        printf '%s\n' "$ident" | cut -c1-160 | sed 's/^/  /' | head -20
        history_remedy
      fi
    fi
  fi
done < <(printf '%s' "$MARKERS")

[ -z "$NOTICES" ] || printf '\n%s' "$NOTICES"

if [ "$status" -eq 0 ]; then
  if [ "$GAP_COUNT" -gt 0 ]; then
    status=3
    printf 'fm-private-material-check: INCOMPLETE - %d marker(s) checked with no hits, but %d coverage gap(s) above mean this run did NOT prove the tracked surface clean.\n' \
      "$count" "$GAP_COUNT"
  else
    printf 'fm-private-material-check: OK - %d marker(s) checked, none present in tracked files.\n' "$count"
    [ "$SCAN_HISTORY" -eq 1 ] && printf 'fm-private-material-check: history also clean for those markers.\n'
  fi
  printf 'fm-private-material-check: prose that names no marker is NOT covered; review the diff.\n'
else
  printf '\nfm-private-material-check: FAILED - private fleet material is in the tracked surface.\n' >&2
  printf 'Fix each hit, or record a legitimately public identity in %s\n' \
    "$ALLOW_FILE" >&2
fi
exit "$status"
