#!/usr/bin/env bash
# fm-pr-start-template.sh - head-bound task/spec fragments for known PR work.
# Usage:
#   fm-pr-start-template.sh render review <pr-url>
#   fm-pr-start-template.sh render follow-up <pr-url> <findings-file>
#   fm-pr-start-template.sh render conflict <pr-url>
#   fm-pr-start-template.sh verify <pr-url> <head-sha> [conflict]
#   fm-pr-start-template.sh drop <pr-url>
# render reads one forge snapshot, never starts work, and prints a fragment to
# fill an fm-brief.sh scaffold (review uses --scout --merge-review at dispatch;
# repairs use the project's agreed ship mode). Keep the printed PR start line
# at column one in that brief. The routed dispatcher verifies it before launch.
# Review heads must remain unchanged for FM_PR_START_DEBOUNCE_SECS (default 120)
# between observations; exit 75 means pending, not an error. Call on head events
# and once after the quiet window, not in a forge-polling loop. Every changed
# head resets the window. An emitted shape/head/findings combination is skipped
# until drop, even after worker cleanup. Do not drop to bypass the quiet window.
# Follow-up findings must be nonempty and carry `Reviewed head: <exact sha>`;
# conflict requires the forge's affirmative CONFLICTING verdict, not UNKNOWN.
# verify refuses closed/draft/stale heads and, when asked, non-conflicts.
# Workers must verify again before posting findings or pushing a repair; a
# changed head invalidates the task, not permission to review the newer head.
# State: $FM_HOME/state/pr-start-templates, private per-PR snapshot/dedupe data.
# FM_HOME, FM_STATE_OVERRIDE select the home; uses gh-axi and git on PATH.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
die() { printf 'pr-start-template: %s\n' "$*" >&2; exit 2; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 2 ] || die 'see --help'
verb=$1; shift
shape=
if [ "$verb" = render ]; then
  shape=$1; shift
  case "$shape" in review|follow-up|conflict) ;; *) die 'unknown shape' ;; esac
fi
url=${1:-}; shift || true
[[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$ ]] || die 'expected a full GitHub PR URL'
key=$(printf '%s' "$url" | git hash-object --stdin)
dir="$STATE/pr-start-templates/$key"
if [ "$verb" = drop ]; then
  [ "$#" -eq 0 ] || die 'drop takes only a URL'
  mkdir -p "$dir"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$dir/.lock" || die 'another template render owns this PR'
  rm -f -- "$dir/observed" "$dir"/review-* "$dir"/follow-up-* "$dir"/conflict-*
  fm_lock_release "$dir/.lock"
  exit 0
fi
case "$verb" in render|verify) ;; *) die 'unknown verb' ;; esac
slug=${url#https://github.com/}
owner=${slug%%/*}; slug=${slug#*/}
repo=${slug%%/*}; number=${url##*/}
snapshot=$(gh-axi api POST graphql --raw-field \
  "query=query{repository(owner:\"$owner\",name:\"$repo\"){pullRequest(number:$number){state isDraft headRefOid mergeable}}}" \
  --jq '.data.repository.pullRequest | ["pr-start", .state, (.isDraft | tostring), .headRefOid, .mergeable] | @tsv') || die 'forge snapshot unavailable'
read -r sentinel pr_state draft head mergeable extra <<< "$snapshot"
[ "$sentinel" = pr-start ] && [ -z "${extra:-}" ] && [ "$(printf '%s\n' "$snapshot" | wc -l)" -eq 1 ] || die 'invalid forge snapshot'
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || die 'invalid head'
[ "$pr_state" = OPEN ] && [ "$draft" = false ] || die 'PR is closed or draft'
if [ "$verb" = verify ]; then
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die 'verify needs the exact head and optional conflict'
  [ "$1" = "$head" ] || die 'superseded PR head; do not start or publish'
  if [ "$#" -eq 2 ]; then
    [ "$2" = conflict ] || die 'unknown verification constraint'
    [ "$mergeable" = CONFLICTING ] || die 'no confirmed merge conflict'
  fi
  printf 'verified: %s %s\n' "$url" "$head"
  exit 0
fi
findings='' fingerprint=none
if [ "$shape" = follow-up ]; then
  [ "$#" -eq 1 ] && [ -s "$1" ] && [ -f "$1" ] && [ ! -L "$1" ] || die 'follow-up needs a nonempty findings file'
  findings=$1
  grep -Fxq "Reviewed head: $head" "$findings" || die 'findings are not bound to the current head'
  fingerprint=$(git hash-object -- "$findings")
else
  [ "$#" -eq 0 ] || die 'unexpected render arguments'
fi
if [ "$shape" = conflict ]; then
  [ "$mergeable" = CONFLICTING ] || die 'no confirmed merge conflict'
fi
(umask 077; mkdir -p "$dir")
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
lock="$dir/.lock"
fm_lock_try_acquire "$lock" || die 'another template render owns this PR'
trap 'fm_lock_release "$lock"' EXIT
now=$(date +%s)
seen_head='' seen_epoch=0
if [ -f "$dir/observed" ] && [ ! -L "$dir/observed" ]; then
  read -r seen_head seen_epoch < "$dir/observed" || true
fi
case "$seen_epoch" in ''|*[!0-9]*) seen_epoch=0 ;; esac
if [ "$head" != "$seen_head" ]; then
  tmp=$(mktemp "$dir/.observed.XXXXXX")
  printf '%s %s\n' "$head" "$now" > "$tmp"
  mv -f -- "$tmp" "$dir/observed"
  seen_epoch=$now
fi
debounce=${FM_PR_START_DEBOUNCE_SECS:-120}
case "$debounce" in ''|*[!0-9]*) die 'invalid debounce seconds' ;; esac
if [ "$shape" = review ] && [ "$((now - seen_epoch))" -lt "$debounce" ]; then
  printf 'pending: %s head %s needs %ss quiet\n' "$url" "$head" "$debounce"
  exit 75
fi
mark="$dir/$shape-$head-$fingerprint"
if [ -e "$mark" ]; then
  printf 'skip: template already emitted for %s %s %s\n' "$url" "$head" "$shape"
  exit 0
fi
# Noclobber makes the durable dedupe marker safe even against a symlink.
(umask 077; set -C; printf '%s\n' "$now" > "$mark") || die 'cannot record template emission'
printf 'PR task id: pr-%s-%s-%s-%s\n' "${shape:0:1}" "${key:0:12}" "${head:0:24}" "${fingerprint:0:12}"
printf 'PR start: %s %s %s\n' "$shape" "$url" "$head"
printf 'Work only on %s at exact head %s.\n' "$url" "$head"
# shellcheck disable=SC2016 # Backticks are literal Markdown, not shell commands.
printf 'Run `bash %s/fm-pr-start-template.sh verify %s %s%s` before work and before publishing.\n' "$SCRIPT_DIR" "$url" "$head" "$([ "$shape" != conflict ] || printf ' conflict')"
case "$shape" in
  review)
    printf 'Independently review that exact commit, not the moving branch tip; do not modify code, merge, or approve a different head.\n'
    # shellcheck disable=SC2016 # Literal Markdown in generated task instructions.
    printf 'Report actionable findings with file/line, severity, reproduction and `Reviewed head: %s`; explicitly report no findings when appropriate.\n' "$head"
    # shellcheck disable=SC2016 # Literal Markdown in generated task instructions.
    printf 'If authorized to submit a forge review, use `gh-axi pr review %s --match-head-commit %s` with the appropriate verdict/body flags; never submit an unbound review.\n' "$url" "$head"
    ;;
  follow-up)
    printf 'Address only the actionable review findings below; verify each with a regression test and report any rejected finding with evidence.\n'
    printf 'Do not merge, broaden scope, or overwrite another author\047s pushes; stop if the head changes.\n'
    printf '\n'
    # Keep findings as data, never shell input.
    while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line"; done < "$findings"
    ;;
  conflict)
    printf 'Repair the confirmed merge conflict against the current base, preserving both sides\047 intended behavior.\n'
    printf 'Reproduce the conflict first; if it is no longer real, stop without edits.\n'
    printf 'Run the affected tests, describe each resolution, and push only under the task\047s explicit existing-PR authority; never merge the PR or force-push.\n'
    ;;
esac
