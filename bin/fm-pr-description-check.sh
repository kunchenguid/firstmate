#!/usr/bin/env bash
# Check a task's live pull request title and body before the PR is recorded or
# reported ready, so internal fleet wording, off-template descriptions, and
# denied third-party product names never reach a project repository's PR.
# bin/fm-pr-check.sh calls this before it records anything; a worker can run it
# directly, fix each reported line on the forge, and run it again.
#
# Scope: only a task whose project= is a clone directly under this home's
# projects directory ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE). A task on
# firstmate itself, or on any path outside that directory, is skipped because
# its PRs legitimately describe fleet roles. Only GitHub pull requests are read;
# a GitLab merge request or Gerrit change is skipped with a note.
#
# Checks, all against the live PR read from the GitHub REST API with `gh`, or
# with `gh-axi` when `gh` is absent or cannot read it:
#   1. Template: when the base repository has a PR template at a standard
#      single-file location (.github/, the root, or docs/, either name case) on
#      the base branch, every heading of the template's top level (its
#      shallowest heading level, ignoring headings inside code fences and HTML
#      comments) appears in the body as a heading with the same text, ignoring
#      case. No template means no check.
#   2. Title shape: when the PR head branch is `<type>/<KEY>-<NNN>-<description>`
#      (KEY two or more uppercase letters, NNN digits, such as
#      feat/DF-123-add-x), the title is `<type>(<KEY>-<NNN>): <description>` with
#      that ticket key; otherwise any conventional `<type>: <description>` or
#      `<type>(<scope>): <description>`. Types: feat fix hotfix refactor docs
#      test chore perf ci build style revert, optionally followed by `!`.
#   3. Internal wording, case-insensitive on whole words: captain, firstmate /
#      first mate, crewmate, second mate / secondmate, "task brief",
#      "per instruction", and no-mistakes (which covers the validation tool's PR
#      footer and its HTML attestation comment).
#   4. Denied product names: each non-blank, non-# line of the optional
#      gitignored config/pr-description-deny file is a literal term matched the
#      same way.
# Checks 3 and 4 read the title and body prose: inline code spans and fenced
# code blocks are exempt.
# Text the template itself ships (a whole template line found inside a body
# line, with checkbox state ignored) never counts toward checks 3 or 4.
#
# Output: one line per violation on stdout, naming `title` or `body line <n>`,
# then a summary on stderr. Exit 0 = passed or skipped (a `skipped:` line says
# why), 1 = violations or the PR could not be read (no verdict is never a pass),
# 2 = invalid request.
# Usage: fm-pr-description-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: fm-pr-description-check.sh <task-id> <pr-url>" >&2
  exit 2
fi
ID=$1
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$2"; then
  echo "error: invalid PR description check request" >&2
  exit 2
fi
URL=$FM_PR_URL

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)

physical() {  # <path> - the physical path when it exists, else the path itself
  if [ -d "$1" ]; then (cd -P -- "$1" && pwd); else printf '%s\n' "$1"; fi
}
PROJECTS_P=$(physical "$PROJECTS")
PROJECT_P=$(physical "$PROJECT")
case "$PROJECT_P" in
  "$PROJECTS_P"/*) PROJECT_NAME=${PROJECT_P#"$PROJECTS_P"/} ;;
  *) PROJECT_NAME= ;;
esac
case "$PROJECT_NAME" in
  ''|*/*)
    echo "skipped: $ID is not work on a project clone in this home"
    exit 0
    ;;
esac
if [ "$FM_PR_PROVIDER" != github ]; then
  echo "skipped: the PR description guard reads GitHub pull requests only"
  exit 0
fi

for tool in jq awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: checking the PR description requires $tool on PATH" >&2
    exit 1
  fi
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-description.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

# github_read <api-path> <jq-filter>: print the filtered record of a GitHub REST
# GET as compact JSON, read with gh and then gh-axi, like
# fm_pr_github_read_record. Returns 0 when read, 3 when the forge answered 404,
# and 1 when neither tool could read it, with each tool's reason in
# $WORK/gh.err. gh-axi clamps raw output at 4000 characters, so it reads the
# record in base64 slices of 700 characters until an empty slice.
github_read() {
  local path=$1 filter=$2 off=0 out chunk
  : > "$WORK/gh.err"
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh: not on PATH" >> "$WORK/gh.err"
  elif out=$(gh api --method GET "$path" --jq "$filter | tojson" 2>"$WORK/gh.out"); then
    printf '%s\n' "$out"
    return 0
  else
    printf 'gh: %s\n' "$(head -c 300 "$WORK/gh.out")" >> "$WORK/gh.err"
    ! grep -q 'HTTP 404' "$WORK/gh.out" || return 3
  fi
  if ! command -v gh-axi >/dev/null 2>&1; then
    echo "gh-axi: not on PATH" >> "$WORK/gh.err"
    return 1
  fi
  : > "$WORK/axi.json"
  while :; do
    if ! out=$(gh-axi api GET "/$path" --jq "\"x\" + ($filter | tojson | .[$off:$((off + 700))] | @base64)" 2>&1); then
      printf 'gh-axi: %s\n' "$(printf '%s' "$out" | head -c 300)" >> "$WORK/gh.err"
      case $out in *'HTTP 404'*) return 3 ;; esac
      return 1
    fi
    chunk=$(printf '%s\n' "$out" | awk '$1 == "body:" { b = $2 } $1 == "truncated:" { t = $2 } END { if (t == "false" && b ~ /^x/) print substr(b, 2); else exit 1 }') || {
      echo "gh-axi: unreadable response" >> "$WORK/gh.err"
      return 1
    }
    [ -n "$chunk" ] || break
    jq -jn --arg c "$chunk" '$c | @base64d' >> "$WORK/axi.json" || return 1
    off=$((off + 700))
  done
  cat "$WORK/axi.json"
}

RC=0
PR_JSON=$(github_read "repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" \
  '{title, body, headRefName: .head.ref, baseRefName: .base.ref}') || RC=$?
if [ "$RC" != 0 ]; then
  echo "error: could not read $URL from GitHub with gh or gh-axi: $(tr '\n' ' ' < "$WORK/gh.err")" >&2
  exit 1
fi
if ! printf '%s' "$PR_JSON" | jq -e 'type == "object" and (.title | type == "string")' >/dev/null 2>&1; then
  echo "error: GitHub returned an unreadable record for $URL" >&2
  exit 1
fi
printf '%s' "$PR_JSON" | jq -r '.title' | tr -d '\r' > "$WORK/title"
printf '%s' "$PR_JSON" | jq -r '.body // ""' | tr -d '\r' > "$WORK/body"
TITLE=$(cat "$WORK/title")
HEAD_REF=$(printf '%s' "$PR_JSON" | jq -r '.headRefName // ""')
BASE_REF=$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // ""')
if [ -z "$BASE_REF" ]; then
  echo "error: GitHub did not report the base branch of $URL" >&2
  exit 1
fi
BASE_REF_Q=$(jq -rn --arg r "$BASE_REF" '$r | @uri')

# The first template found in GitHub's own lookup order wins. Only a 404 means
# absent; any other read failure stops the check rather than skipping it.
: > "$WORK/template"
for dir in .github/ '' docs/; do
  for name in PULL_REQUEST_TEMPLATE.md pull_request_template.md; do
    RC=0
    TEMPLATE_JSON=$(github_read "repos/$FM_PR_PATH/contents/$dir$name?ref=$BASE_REF_Q" '{type, content}') || RC=$?
    if [ "$RC" = 0 ]; then
      if printf '%s' "$TEMPLATE_JSON" | jq -e 'type == "object" and .type == "file"' >/dev/null 2>&1; then
        if ! printf '%s' "$TEMPLATE_JSON" | jq -r '.content | gsub("\\s"; "") | @base64d' | tr -d '\r' > "$WORK/template"; then
          echo "error: could not decode the PR template $dir$name of $FM_PR_PATH" >&2
          exit 1
        fi
        break 2
      fi
    elif [ "$RC" != 3 ]; then
      echo "error: could not read the PR template $dir$name of $FM_PR_PATH with gh or gh-axi: $(tr '\n' ' ' < "$WORK/gh.err")" >&2
      exit 1
    fi
  done
done

DENY="$CONFIG/pr-description-deny"
: > "$WORK/deny"
if [ -e "$DENY" ]; then
  if [ ! -f "$DENY" ] || [ ! -r "$DENY" ]; then
    echo "error: $DENY is not a readable file" >&2
    exit 1
  fi
  tr -d '\r' < "$DENY" > "$WORK/deny"
fi

: > "$WORK/violations"

# Check 2: title shape.
TYPES='(feat|fix|hotfix|refactor|docs|test|chore|perf|ci|build|style|revert)'
BRANCH_KEY=$(printf '%s\n' "$HEAD_REF" | sed -nE "s#^$TYPES/([A-Z]{2,}-[0-9]+)-.+#\\2#p")
if [ -n "$BRANCH_KEY" ]; then
  TITLE_RE="^$TYPES\\($BRANCH_KEY\\)!?: [^ ]"
  TITLE_SHAPE="<type>($BRANCH_KEY): <description>"
else
  TITLE_RE="^$TYPES(\\([^()]+\\))?!?: [^ ]"
  TITLE_SHAPE="<type>: <description> or <type>(<scope>): <description>"
fi
if ! printf '%s\n' "$TITLE" | grep -qE "$TITLE_RE"; then
  printf 'title: does not match %s (type is one of feat fix hotfix refactor docs test chore perf ci build style revert): %s\n' \
    "$TITLE_SHAPE" "$TITLE" >> "$WORK/violations"
fi

# Checks 1, 3, and 4 read the title, body, template, and deny list together.
if ! awk -v title_file="$WORK/title" -v body_file="$WORK/body" \
  -v template_file="$WORK/template" -v deny_file="$WORK/deny" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function norm(s) { s = tolower(s); gsub(/\[[xX]\]/, "[ ]", s); gsub(/[ \t]+/, " ", s); return trim(s) }
  function isword(c) { return c ~ /[a-z0-9_]/ }
  function shown(s) { s = trim(s); return length(s) > 120 ? substr(s, 1, 117) "..." : s }
  function blanks(n,   out) { out = ""; while (length(out) < n) out = out " "; return out }
  # Replace every whole template line found in s with spaces of the same length.
  function exempt(s,   k, t, i) {
    for (k = 1; k <= ntpl; k++) {
      t = tpl[k]
      while ((i = index(s, t)) > 0) s = substr(s, 1, i - 1) blanks(length(t)) substr(s, i + length(t))
    }
    return s
  }
  # First whole-word term of list (n entries) found in s, or "".
  function hit(s, list, n,   k, t, off, i, start, b, a) {
    for (k = 1; k <= n; k++) {
      t = list[k]; off = 0
      while ((i = index(substr(s, off + 1), t)) > 0) {
        start = off + i
        b = start > 1 ? substr(s, start - 1, 1) : ""
        a = substr(s, start + length(t), 1)
        if (!isword(b) && !isword(a)) return t
        off = start
      }
    }
    return ""
  }
  function heading(line,   m, h) {
    if (!match(line, /^ ? ? ?#+[ \t]/)) return ""
    h = trim(line); m = 0
    while (substr(h, m + 1, 1) == "#") m++
    if (m > 6) return ""
    h = trim(substr(h, m + 1)); sub(/[ \t]+#+$/, "", h); sub(/^#+$/, "", h)
    return m SUBSEP tolower(trim(h))
  }
  function report(where, what, text) { printf "%s: %s: %s\n", where, what, shown(text) }
  function check(where, raw, in_code,   s, t) {
    if (in_code) return
    s = raw; gsub(/`+[^`]*`+/, " ", s); s = exempt(norm(s))
    t = hit(s, vocab, nvocab)
    if (t != "") report(where, "internal wording \"" t "\"", raw)
    if (ndeny == 0) return
    t = hit(s, deny, ndeny)
    if (t != "") report(where, "denied product name \"" t "\"", raw)
  }
  BEGIN {
    nvocab = split("captain|captains|firstmate|firstmates|first mate|first mates|first-mate|crewmate|crewmates|crew mate|crew-mate|second mate|second mates|second-mate|secondmate|secondmates|task brief|task briefs|per instruction|per instructions|no-mistakes", vocab, "|")
    ndeny = 0
    while ((getline line < deny_file) > 0) {
      line = norm(line)
      if (line != "" && substr(line, 1, 1) != "#") deny[++ndeny] = line
    }
    ntpl = 0; fence = 0; comment = 0; top = 7
    while ((getline line < template_file) > 0) {
      # Only a template line that itself holds a checked term can exempt text,
      # so generic lines such as "---" never blank part of a body line.
      t = norm(line)
      if (t != "" && (hit(t, vocab, nvocab) != "" || (ndeny && hit(t, deny, ndeny) != ""))) tpl[++ntpl] = t
      if (line ~ /^ ? ? ?(```|~~~)/) { fence = !fence; continue }
      if (fence) continue
      if (comment) { if (index(line, "-->")) comment = 0; continue }
      if (index(line, "<!--") && !index(substr(line, index(line, "<!--")), "-->")) { comment = 1; continue }
      h = heading(line)
      if (h == "") continue
      split(h, parts, SUBSEP)
      nhead++; hlevel[nhead] = parts[1] + 0; htext[nhead] = parts[2]; hraw[nhead] = trim(line)
      if (parts[1] + 0 < top) top = parts[1] + 0
    }
    if ((getline line < title_file) > 0) check("title", line, 0)
    n = 0; fence = 0; comment = 0
    while ((getline line < body_file) > 0) {
      n++
      if (line ~ /^ ? ? ?(```|~~~)/) { fence = !fence; check("body line " n, line, 1); continue }
      check("body line " n, line, fence)
      if (fence) continue
      # A heading hidden in an HTML comment is invisible, so it does not count.
      if (comment) { if (index(line, "-->")) comment = 0; continue }
      if (index(line, "<!--") && !index(substr(line, index(line, "<!--")), "-->")) { comment = 1; continue }
      h = heading(line)
      if (h != "") { split(h, parts, SUBSEP); seen[parts[2]] = 1 }
    }
    for (k = 1; k <= nhead; k++) {
      if (hlevel[k] == top && !(htext[k] in seen)) report("body", "missing template heading", hraw[k])
    }
  }' >> "$WORK/violations"; then
  echo "error: could not scan the description of $URL" >&2
  exit 1
fi

if [ -s "$WORK/violations" ]; then
  cat "$WORK/violations"
  echo "error: $URL description fails the PR description guard ($(wc -l < "$WORK/violations" | tr -d ' ') problem(s) above); edit the PR title or body on GitHub and run bin/fm-pr-description-check.sh $ID $URL again" >&2
  exit 1
fi
echo "passed: $URL description"
