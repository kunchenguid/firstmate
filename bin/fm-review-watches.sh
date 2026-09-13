#!/usr/bin/env bash
# Install or retire the two colleague-PR watcher checks for a persistent home.
#
# Usage:
#   fm-review-watches.sh install <home> [scope]
#   fm-review-watches.sh retire <home>
#   fm-review-watches.sh --help
#
# install renders both checks with absolute snapshot paths owned by <home>, then
# binds them through fm-check-register.sh. When scope is supplied, installation
# is enabled only for a scope that owns colleague-PR reviews (prefix match).
# retire removes only these checks through fm-check-unregister.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-review-watches.sh install <home> [scope]
       fm-review-watches.sh retire <home>
       fm-review-watches.sh --help

install writes and registers reviewed-pr-watch.check.sh and
review-requests.check.sh in <home>/state. With a scope argument, it skips
homes whose scope does not own colleague-PR reviews.
EOF
}

die() { printf 'fm-review-watches: %s\n' "$1" >&2; exit 1; }

resolve_home() {
  local home=$1
  [ -d "$home" ] && [ ! -L "$home" ] || die "home is not a directory: $home"
  (CDPATH='' cd -- "$home" && pwd -P) || die "cannot resolve home: $home"
}

scope_owns_colleague_pr_reviews() {
  case "$1" in
    'Reviews of colleague PRs'*) return 0 ;;
  esac
  return 1
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

write_reviewed_watch() {
  local state=$1 destination=$2
  {
    printf '%s\n' '#!/bin/sh'
    printf 'SNAP=%s\n' "$(shell_quote "$state/reviewed-pr-watch.snapshot")"
    cat <<'EOF'
cur=$(gh-axi api graphql -f query='query{search(query:"repo:monalee-inc/artemis is:pr is:open reviewed-by:pedromuller-del -author:pedromuller-del",type:ISSUE,first:20){nodes{... on PullRequest{number headRefOid comments(last:100){nodes{body author{login __typename}}}}}}}' --jq '.data.search.nodes | map({n:.number,h:.headRefOid[0:8],c:([.comments.nodes[]|select(.author!=null and .author.__typename!="Bot" and .author.login!="pedromuller-del" and ((.body//"")|sub("^\\s+";"")|sub("\\s+$";"")|test("^/[A-Za-z][A-Za-z0-9_-]*$")|not))]|length)}) | sort_by(.n) | tostring' 2>/dev/null) || exit 0
[ -n "$cur" ] || exit 0
prev=$(cat "$SNAP" 2>/dev/null || printf '')
printf '%s' "$cur" > "$SNAP"
[ -n "$prev" ] || exit 0
[ "$cur" = "$prev" ] && exit 0

changed=$(python3 - "$cur" "$prev" <<'PY' 2>/dev/null
import ast, sys

def load(s):
    try:
        return {e["n"]: e for e in ast.literal_eval(s)}
    except Exception:
        return None

cur, prev = load(sys.argv[1]), load(sys.argv[2])
if cur is None or prev is None:
    sys.exit(1)
out = []
for n in sorted(set(cur) & set(prev)):
    c, p = cur[n], prev[n]
    if c.get("h") != p.get("h"):
        out.append(f"colleague PR {n} head moved {p.get('h')}->{c.get('h')}: re-review at the new head")
    elif c.get("c") != p.get("c"):
        out.append(f"colleague PR {n} got a human reply: re-review at the new head")
print("; ".join(out))
PY
) || exit 0
[ -n "$changed" ] || exit 0
echo "$changed"
EOF
  } > "$destination"
}

write_requests_watch() {
  local state=$1 destination=$2
  {
    printf '%s\n' '#!/bin/sh'
    printf 'SNAP=%s\n' "$(shell_quote "$state/review-requests.snapshot")"
    cat <<'EOF'
candidates=$(gh-axi api "/search/issues?q=repo:monalee-inc/artemis+is:pr+is:open+-is:draft+review-requested:pedromuller-del&per_page=100" --jq '[.items[].number] | sort | join(" ")' 2>/dev/null) || exit 0

cur=""
for n in $candidates; do
  case "$n" in ''|*[!0-9]*) continue ;; esac
  gh-axi api "/repos/monalee-inc/artemis/pulls/$n/requested_reviewers" \
    --jq '[.users[].login] | index("pedromuller-del") // empty' 2>/dev/null | grep -q . || continue
  cur="$cur $n"
done
cur=$(printf '%s' "$cur" | sed 's/^ //')
[ -n "$cur" ] || cur="none"

prev=$(cat "$SNAP" 2>/dev/null || printf '')
printf '%s' "$cur" > "$SNAP"
[ -n "$prev" ] || exit 0
[ "$cur" = "$prev" ] && exit 0
[ "$cur" = "none" ] && exit 0

added=""
for n in $cur; do
  case " $prev " in *" $n "*) ;; *) added="${added}${added:+; }review requested on PR $n: start a round" ;; esac
done
[ -n "$added" ] || exit 0
echo "$added"
EOF
  } > "$destination"
}

install_watches() {
  local requested=$1 scope=${2-} home state device stage register id
  if [ -n "$scope" ] && ! scope_owns_colleague_pr_reviews "$scope"; then
    printf 'skipped: scope does not own colleague-PR reviews\n'
    return 0
  fi
  home=$(resolve_home "$requested")
  state="$home/state"
  [ -d "$state" ] && [ ! -L "$state" ] || die "state is not a directory: $state"
  device=$(fm_pr_file_device "$state") || die "cannot inspect state device: $state"
  for id in reviewed-pr-watch review-requests; do
    fm_pr_regular_destination_on_device_or_absent "$state/$id.check.sh" "$device" \
      || die "unsafe check destination: $state/$id.check.sh"
  done

  stage=$(mktemp -d "$state/.fm-review-watches.XXXXXX") || die "cannot create staging directory"
  trap 'rm -rf -- "${stage:-}"' EXIT HUP INT TERM
  write_reviewed_watch "$state" "$stage/reviewed-pr-watch.check.sh"
  write_requests_watch "$state" "$stage/review-requests.check.sh"
  chmod 0700 "$stage"/*.check.sh || die "cannot set check permissions"
  mv -f -- "$stage/reviewed-pr-watch.check.sh" "$state/reviewed-pr-watch.check.sh" \
    || die "cannot install reviewed-pr-watch.check.sh"
  mv -f -- "$stage/review-requests.check.sh" "$state/review-requests.check.sh" \
    || die "cannot install review-requests.check.sh"

  register="$home/bin/fm-check-register.sh"
  [ -x "$register" ] || register="$SCRIPT_DIR/fm-check-register.sh"
  for id in reviewed-pr-watch review-requests; do
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$register" "$id" >/dev/null \
      || die "could not register $id"
  done
  trap - EXIT HUP INT TERM
  rm -rf -- "$stage"
  printf 'installed: state/reviewed-pr-watch.check.sh state/review-requests.check.sh\n'
}

retire_watches() {
  local requested=$1 home state register id
  home=$(resolve_home "$requested")
  state="$home/state"
  [ -d "$state" ] && [ ! -L "$state" ] || die "state is not a directory: $state"
  register="$home/bin/fm-check-unregister.sh"
  [ -x "$register" ] || register="$SCRIPT_DIR/fm-check-unregister.sh"
  for id in reviewed-pr-watch review-requests; do
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$register" "$id" >/dev/null \
      || die "could not retire $id"
  done
  printf 'retired: state/reviewed-pr-watch.check.sh state/review-requests.check.sh\n'
}

case "${1:-}" in
  install)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
    install_watches "$2" "${3-}"
    ;;
  retire)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    retire_watches "$2"
    ;;
  -h|--help)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
