#!/usr/bin/env bash
# fm-private-material-check.sh - refuse private fleet material in tracked files.
#
# Usage:
#   bin/fm-private-material-check.sh [--root <repo>] [--home <fm-home>] [--history]
#
# The default scan covers tracked files at the current tip. --history adds past
# commit content AND commit metadata (author and committer identity, subject,
# body), because a pull request carries all of that into the target repository
# and a marker deleted at tip is still published forever.
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
#   data/secondmates.md                  registered secondmate ids
#   git remote owners                    of this repo and of each project clone
#   the local account name               catches machine-local home paths; used
#                                        only when data/ or projects/ is present,
#                                        so it never fakes a marker source
#   config/private-material-markers      one token per line, for anything not
#                                        derivable (device serials, people)
#
# Suppression, also local and gitignored:
#   config/private-material-allow        one token per line; use it for an
#                                        identity that is legitimately public,
#                                        such as the upstream this repo forks.
#
# Matching is case-insensitive and treats "-", "_", and a space as the same
# separator, so a registered id also matches its display-name spelling
# ("sm-thing" matches "SM THING"). Matches are word-bounded, so a marker inside
# a longer word does not fire.
#
# WHAT THIS CANNOT CATCH - state this plainly rather than trusting a green run:
#   - Private strategy, delivery posture, or fleet-internal decisions written as
#     ordinary prose that names no marker token. A marker scan cannot read intent.
#   - A paraphrase of what the fleet builds that avoids every registered name.
#   - Anything whose name is not in the local operational dirs: a retired or
#     never-registered project, a customer, or a person not listed in the extra
#     markers file.
#   - Markers shorter than MIN_LEN, or filtered as generic (see STOPWORDS),
#     because matching them would be pure noise.
#   - Anything at all when no marker source is present. On a machine or CI runner
#     with no private dirs the run is VACUOUS: it reports SKIPPED and exits 0.
#     A SKIPPED run is not evidence the surface is clean.
# Human review of the diff remains the real control; this only makes the
# mechanical, repeatable part of it impossible to forget.
set -eu

MIN_LEN=3

# Generic tokens that would storm the scan if a project, account, or secondmate
# happened to be named one of them. A fleet that really owns one of these names
# must add it to config/private-material-markers to force it back in.
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
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

RAW_MARKERS=""
add_marker() {
  local m=$1
  m=$(printf '%s' "$m" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$m" ] || return 0
  RAW_MARKERS="$RAW_MARKERS
$(lower "$m")"
}

# 1. project clone directory names
if [ -d "$HOME_DIR/projects" ]; then
  for d in "$HOME_DIR/projects"/*; do
    [ -d "$d" ] || continue
    add_marker "$(basename "$d")"
  done
fi

# 2. registered project names: "- <name> [<mode>] - ..."
if [ -f "$HOME_DIR/data/projects.md" ]; then
  while IFS= read -r name; do add_marker "$name"; done < <(
    sed -n 's/^[[:space:]]*-[[:space:]]\{1,\}\([A-Za-z0-9._-]\{1,\}\)[[:space:]]\{1,\}\[.*/\1/p' \
      "$HOME_DIR/data/projects.md"
  )
fi

# 3. registered secondmate ids: "- <id> - ..."
if [ -f "$HOME_DIR/data/secondmates.md" ]; then
  while IFS= read -r name; do add_marker "$name"; done < <(
    sed -n 's/^[[:space:]]*-[[:space:]]\{1,\}\([A-Za-z0-9._-]\{1,\}\)[[:space:]]\{1,\}-[[:space:]].*/\1/p' \
      "$HOME_DIR/data/secondmates.md"
  )
fi

# 4. forge OWNERS of this repo's remotes and of every project clone's remotes.
#    Owners only, never repository names: a repo name is usually this repo's own
#    name or a project name already covered above, and matching it would storm.
collect_remote_owners() {
  local dir=$1 url owner
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in
      /*|./*|../*|file://*) continue ;;
      *://*) url=${url#*://} ;;
      *:*/*) url=${url%%:*}/${url#*:} ;;
      *) continue ;;
    esac
    url=${url#*@}
    url=${url#*/}
    owner=${url%%/*}
    add_marker "$owner"
  done < <(git -C "$dir" config --get-regexp '^remote\..*\.url$' 2>/dev/null | cut -d' ' -f2-)
}
collect_remote_owners "$ROOT"
if [ -d "$HOME_DIR/projects" ]; then
  for d in "$HOME_DIR/projects"/*; do
    [ -d "$d" ] && collect_remote_owners "$d"
  done
fi

# 5. the local account name, which is what makes machine-local home paths legible.
#    Only when this really is an operational home: on a runner with no private
#    dirs the account name is noise, and adding it unconditionally would make
#    every run look like it had a marker source when it had none.
if [ -d "$HOME_DIR/data" ] || [ -d "$HOME_DIR/projects" ]; then
  add_marker "$(id -un 2>/dev/null || true)"
fi

# 6. operator-supplied markers that nothing can derive
if [ -f "$HOME_DIR/config/private-material-markers" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    add_marker "$line"
  done < "$HOME_DIR/config/private-material-markers"
fi

# Allowlist: identities that are legitimately public for this home.
ALLOW=" "
if [ -f "$HOME_DIR/config/private-material-allow" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] && ALLOW="$ALLOW$(lower "$line") "
  done < "$HOME_DIR/config/private-material-allow"
fi
# This repo's own directory name is never a marker: it names the tool, not a fleet.
ALLOW="$ALLOW$(lower "$(basename "$ROOT")") "
for w in $STOPWORDS; do ALLOW="$ALLOW$w "; done

MARKERS=""
seen=" "
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ "${#m}" -ge "$MIN_LEN" ] || continue
  case "$ALLOW" in *" $m "*) continue ;; esac
  case "$seen" in *" $m "*) continue ;; esac
  seen="$seen$m "
  MARKERS="$MARKERS$m
"
done < <(printf '%s\n' "$RAW_MARKERS" | sort -u)

if [ -z "$MARKERS" ]; then
  printf 'fm-private-material-check: SKIPPED - no private marker sources under %s\n' "$HOME_DIR"
  printf 'fm-private-material-check: a SKIPPED run proves nothing about the tracked surface.\n'
  exit 0
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

status=0
count=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  count=$((count + 1))
  pat=$(marker_pattern "$m")
  if hits=$(git -C "$ROOT" grep -n -I -i -E -- "$pat" -- ':!assets' 2>/dev/null) && [ -n "$hits" ]; then
    status=1
    printf '\nPRIVATE MATERIAL: marker "%s" appears in tracked files:\n' "$m"
    printf '%s\n' "$hits" | sed 's/^/  /'
  fi
  if [ "$SCAN_HISTORY" -eq 1 ]; then
    if hist=$(git -C "$ROOT" log --all --oneline -G"$pat" 2>/dev/null) && [ -n "$hist" ]; then
      status=1
      printf '\nPRIVATE MATERIAL IN HISTORY: marker "%s" appears in the content of:\n' "$m"
      printf '%s\n' "$hist" | sed 's/^/  /'
      history_remedy
    fi
    # Commit metadata travels with a pull request exactly like file content does,
    # and an author identity is the usual way a real name or an org email domain
    # reaches a third-party repository. Flatten each commit to one line so a
    # multi-line body cannot hide a marker from a line-oriented grep.
    if meta=$(git -C "$ROOT" log --all -z \
        --format='%h %an <%ae> %cn <%ce> %s %b' 2>/dev/null \
        | tr '\n' ' ' | tr '\0' '\n' | grep -i -E -- "$pat") && [ -n "$meta" ]; then
      status=1
      printf '\nPRIVATE MATERIAL IN COMMIT METADATA: marker "%s" appears in:\n' "$m"
      printf '%s\n' "$meta" | cut -c1-160 | sed 's/^/  /' | head -20
      history_remedy
    fi
  fi
done < <(printf '%s' "$MARKERS")

if [ "$status" -eq 0 ]; then
  printf 'fm-private-material-check: OK - %d marker(s) checked, none present in tracked files.\n' "$count"
  [ "$SCAN_HISTORY" -eq 1 ] && printf 'fm-private-material-check: history also clean for those markers.\n'
  printf 'fm-private-material-check: prose that names no marker is NOT covered; review the diff.\n'
else
  printf '\nfm-private-material-check: FAILED - private fleet material is in the tracked surface.\n' >&2
  printf 'Fix each hit, or record a legitimately public identity in %s\n' \
    "$HOME_DIR/config/private-material-allow" >&2
fi
exit "$status"
