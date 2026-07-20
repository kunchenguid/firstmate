#!/usr/bin/env bash
# Refresh Tim's Lindy open-work picture into data/lindy/open-work-backlog.md.
# The generated section is replaced in-place between stable markers; any
# hand-written Markdown outside those markers is preserved.
#
# Sources:
#   - authored GitHub PRs via gh-axi pr list
#   - review-requested GitHub PRs via gh-axi search prs
#   - optional team review requests from FM_GH_TEAMS (comma/space-separated
#     team slugs, e.g. "reliability,platform"; "lindy-ai/reliability" is also
#     accepted)
#   - optional Linear hook from FM_LINEAR_CMD
#   - optional Slack hook from FM_SLACK_CMD
#
# Hook commands must print one open-work item per line, already human-readable.
# When a hook is unset or fails, the source is shown as skipped; no data is
# invented.
# Usage: fm-backlog-pull.sh [--output <path>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

GH_REPO="${FM_GH_REPO:-lindy-ai/lindy}"
GH_OWNER="${FM_GH_OWNER:-lindy-ai}"
GH_USER="${FM_GH_USER:-twaldin}"
GH_LIMIT="${FM_GH_LIMIT:-1000}"
OUT="${FM_BACKLOG_PULL_OUT:-$DATA/lindy/open-work-backlog.md}"
NOW="${FM_BACKLOG_PULL_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

START_MARKER="<!-- fm-backlog-pull:generated:start -->"
END_MARKER="<!-- fm-backlog-pull:generated:end -->"

usage() {
  cat >&2 <<EOF
usage: fm-backlog-pull.sh [--output <path>]

Environment:
  FM_GH_REPO           GitHub repo for authored PRs (default: lindy-ai/lindy)
  FM_GH_OWNER          GitHub owner for review-requested search (default: lindy-ai)
  FM_GH_USER           GitHub username to query (default: twaldin)
  FM_GH_LIMIT          gh-axi result limit (default: 1000)
  FM_GH_TEAMS          comma/space-separated team slugs for team review requests
  FM_LINEAR_CMD        optional command hook that prints Linear items, one per line
  FM_SLACK_CMD         optional command hook that prints Slack items, one per line
  FM_BACKLOG_PULL_OUT  output Markdown path (default: data/lindy/open-work-backlog.md)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      [ $# -ge 2 ] || { usage; exit 1; }
      OUT=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-backlog-pull.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

STATUS_FILE="$TMP/status.md"
SECTIONS_FILE="$TMP/sections.list"
: > "$STATUS_FILE"
: > "$SECTIONS_FILE"

first_line() {
  sed -n '1s/[[:space:]]\{1,\}/ /g;1p' "$1"
}

count_items() {
  grep -c '^- ' "$1" 2>/dev/null || true
}

section_path() {
  printf '%s/%s.md\n' "$TMP" "$1"
}

slugify() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//'
}

remember_section() {
  local title=$1 path=$2
  printf '%s\t%s\n' "$title" "$path" >> "$SECTIONS_FILE"
}

add_status() {
  local source=$1 status=$2
  printf -- '- %s: %s\n' "$source" "$status" >> "$STATUS_FILE"
}

parse_gh_axi_items() {
  local raw=$1 out=$2
  awk -v repo="$GH_REPO" '
    function unquote(s) {
      if (s ~ /^".*"$/) {
        sub(/^"/, "", s)
        sub(/"$/, "", s)
        gsub(/""/, "\"", s)
      }
      return s
    }
    function emit(num, title, state, url) {
      if (url == "") {
        url = "https://github.com/" repo "/pull/" num
      }
      printf "- #%s | %s | %s | %s\n", num, unquote(title), state, url
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line !~ /^[0-9]+,/) next
      num = line
      sub(/,.*/, "", num)
      rest = line
      sub(/^[0-9]+,/, "", rest)
      pos = 0
      state = ""
      split("open closed merged", states, " ")
      for (i = 1; i <= 3; i++) {
        marker = "," states[i] ","
        p = index(rest, marker)
        if (p > 0 && (pos == 0 || p < pos)) {
          pos = p
          state = states[i]
        }
      }
      if (pos == 0) next
      title = substr(rest, 1, pos - 1)
      tail = substr(rest, pos + length(state) + 2)
      url = ""
      n = split(tail, parts, ",")
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^https?:\/\//) {
          url = parts[i]
          break
        }
      }
      emit(num, title, state, url)
    }
  ' "$raw" > "$out"
}

run_gh_source() {
  local title=$1 slug raw err items count reason
  shift
  slug=$(slugify "$title")
  raw="$TMP/$slug.raw"
  err="$TMP/$slug.err"
  items=$(section_path "$slug")

  if ! command -v gh-axi >/dev/null 2>&1; then
    : > "$items"
    add_status "$title" "skipped: gh-axi is not on PATH"
    remember_section "$title" "$items"
    return 0
  fi

  if "$@" > "$raw" 2> "$err"; then
    parse_gh_axi_items "$raw" "$items"
    count=$(count_items "$items")
    add_status "$title" "ok: $count item(s)"
  else
    : > "$items"
    reason=$(first_line "$err")
    [ -n "$reason" ] || reason=$(first_line "$raw")
    [ -n "$reason" ] || reason="command failed"
    add_status "$title" "skipped: $reason"
  fi

  remember_section "$title" "$items"
}

run_hook_source() {
  local title=$1 env_name=$2 cmd raw err items count reason slug
  slug=$(slugify "$title")
  raw="$TMP/$slug.raw"
  err="$TMP/$slug.err"
  items=$(section_path "$slug")
  cmd=$(eval "printf '%s' \"\${$env_name:-}\"")

  if [ -z "$cmd" ]; then
    : > "$items"
    add_status "$title" "skipped: $env_name is unset"
    remember_section "$title" "$items"
    return 0
  fi

  if sh -c "$cmd" > "$raw" 2> "$err"; then
    sed '/^[[:space:]]*$/d; s/^[[:space:]]*/- /' "$raw" > "$items"
    count=$(count_items "$items")
    add_status "$title" "ok: $count item(s)"
  else
    : > "$items"
    reason=$(first_line "$err")
    [ -n "$reason" ] || reason=$(first_line "$raw")
    [ -n "$reason" ] || reason="command failed"
    add_status "$title" "skipped: $env_name failed: $reason"
  fi

  remember_section "$title" "$items"
}

team_query() {
  local team=$1
  case "$team" in
    */*) printf 'team-review-requested:%s\n' "$team" ;;
    *) printf 'team-review-requested:%s/%s\n' "$GH_OWNER" "$team" ;;
  esac
}

run_all_sources() {
  local team query any_team items
  run_gh_source "Authored PRs" \
    gh-axi pr list --repo "$GH_REPO" --author "$GH_USER" --state open --limit "$GH_LIMIT"
  run_gh_source "Review-requested PRs" \
    gh-axi search prs "review-requested:$GH_USER" --state open --owner "$GH_OWNER" --limit "$GH_LIMIT"

  any_team=no
  if [ -n "${FM_GH_TEAMS:-}" ]; then
    while IFS= read -r team; do
      [ -n "$team" ] || continue
      any_team=yes
      query=$(team_query "$team")
      run_gh_source "Team review-requested: $team" \
        gh-axi search prs "$query" --state open --owner "$GH_OWNER" --limit "$GH_LIMIT"
    done <<EOF
$(printf '%s\n' "$FM_GH_TEAMS" | tr ',;' '  ' | tr ' ' '\n')
EOF
  fi
  if [ "$any_team" = no ]; then
    items=$(section_path team-review-requests)
    : > "$items"
    add_status "Team review-requested PRs" "skipped: FM_GH_TEAMS is unset"
    remember_section "Team review-requested PRs" "$items"
  fi

  run_hook_source "Linear tickets" FM_LINEAR_CMD
  run_hook_source "Slack mentions" FM_SLACK_CMD
}

write_generated_section() {
  local generated=$1 title path
  {
    printf '%s\n' "$START_MARKER"
    printf '## Generated Open-Work Refresh\n\n'
    printf 'Generated: %s\n\n' "$NOW"
    printf 'Repo: %s; owner: %s; user: %s.\n\n' "$GH_REPO" "$GH_OWNER" "$GH_USER"
    printf '### Source Status\n\n'
    cat "$STATUS_FILE"
    printf '\n'

    while IFS="$(printf '\t')" read -r title path; do
      [ -n "$title" ] || continue
      printf '### %s\n\n' "$title"
      if [ -s "$path" ]; then
        cat "$path"
      else
        printf '_No items._\n'
      fi
      printf '\n'
    done < "$SECTIONS_FILE"

    printf '%s\n' "$END_MARKER"
  } > "$generated"
}

replace_generated_section() {
  local generated=$1 merged=$2 out_dir
  out_dir=$(dirname "$OUT")
  mkdir -p "$out_dir"

  if [ -f "$OUT" ] && grep -Fxq "$START_MARKER" "$OUT" && grep -Fxq "$END_MARKER" "$OUT"; then
    awk -v start="$START_MARKER" -v end="$END_MARKER" -v gen="$generated" '
      $0 == start {
        while ((getline line < gen) > 0) print line
        close(gen)
        skip = 1
        next
      }
      $0 == end {
        skip = 0
        next
      }
      !skip { print }
    ' "$OUT" > "$merged"
  elif [ -f "$OUT" ]; then
    {
      cat "$OUT"
      printf '\n'
      cat "$generated"
    } > "$merged"
  else
    {
      printf '# Lindy Open Work Backlog\n\n'
      cat "$generated"
    } > "$merged"
  fi

  mv "$merged" "$OUT"
}

run_all_sources
GENERATED="$TMP/generated.md"
MERGED="$TMP/merged.md"
write_generated_section "$GENERATED"
replace_generated_section "$GENERATED" "$MERGED"
printf 'wrote %s\n' "$OUT"
