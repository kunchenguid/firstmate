#!/usr/bin/env bash
# Behavior tests for fm-backlog-pull.sh.
#
# The refresh must preserve hand-written Markdown outside its generated section,
# report every source status explicitly, use fake gh-axi fixtures for the two
# GitHub source families, and skip Linear/Slack hooks cleanly when they are not
# configured.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-pull-tests)

make_fake_gh_axi() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  'pr list --repo lindy-ai/lindy --author twaldin --state open --limit 1000')
    cat <<'EOF'
count: 2
pull_requests[2]{number,title,state,author,draft,review}:
  101,"feat: add backlog, pull refresh",open,twaldin,no,required
  102,fix: keep generated section stable,open,twaldin,no,approved
EOF
    ;;
  'search prs review-requested:twaldin --state open --owner lindy-ai --limit 1000')
    cat <<'EOF'
count: 1
prs[1]{number,title,state,author}:
  201,review me,open,alice,no,required
EOF
    ;;
  'search prs team-review-requested:lindy-ai/reliability --state open --owner lindy-ai --limit 1000')
    cat <<'EOF'
count: 1
prs[1]{number,title,state,author}:
  301,team reliability review,open,bob,no,required
EOF
    ;;
  'search prs team-review-requested:lindy-ai/platform --state open --owner lindy-ai --limit 1000')
    cat <<'EOF'
count: 0
prs: []
EOF
    ;;
  *)
    echo "unexpected gh-axi args: $args" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

make_hook() {
  local path=$1 body=$2
  cat > "$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$body'
EOF
  chmod +x "$path"
}

run_pull() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" \
    FM_BACKLOG_PULL_NOW="2026-07-05T12:34:56Z" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-backlog-pull.sh" "$@"
}

test_refreshes_github_and_skips_unconfigured_sources() {
  local case_dir home fakebin out doc
  case_dir="$TMP_ROOT/basic"
  home="$case_dir/home"
  mkdir -p "$home"
  fakebin=$(make_fake_gh_axi "$case_dir/fake")

  out=$(run_pull "$home" "$fakebin")
  doc="$home/data/lindy/open-work-backlog.md"

  assert_contains "$out" "wrote $doc" "script did not report output path"
  assert_grep "<!-- fm-backlog-pull:generated:start -->" "$doc" "generated start marker missing"
  assert_grep "Generated: 2026-07-05T12:34:56Z" "$doc" "timestamp not written"
  assert_grep "- Authored PRs: ok: 2 item(s)" "$doc" "authored status missing"
  assert_grep "- Review-requested PRs: ok: 1 item(s)" "$doc" "review-requested status missing"
  assert_grep "- Team review-requested PRs: skipped: FM_GH_TEAMS is unset" "$doc" "team skip status missing"
  assert_grep "- Linear tickets: skipped: FM_LINEAR_CMD is unset" "$doc" "Linear skip status missing"
  assert_grep "- Slack mentions: skipped: FM_SLACK_CMD is unset" "$doc" "Slack skip status missing"
  assert_grep "- #101 | feat: add backlog, pull refresh | open | https://github.com/lindy-ai/lindy/pull/101" "$doc" \
    "quoted comma title was not normalized"
  assert_grep "- #201 | review me | open | https://github.com/lindy-ai/lindy/pull/201" "$doc" \
    "review-requested item missing"
  pass "fm-backlog-pull writes GitHub sources and explicit skip statuses"
}

test_team_hooks_and_manual_content_preserved() {
  local case_dir home fakebin doc linear slack
  case_dir="$TMP_ROOT/team-hooks"
  home="$case_dir/home"
  doc="$home/data/lindy/open-work-backlog.md"
  mkdir -p "$(dirname "$doc")"
  fakebin=$(make_fake_gh_axi "$case_dir/fake")
  linear="$case_dir/linear-hook"
  slack="$case_dir/slack-hook"
  make_hook "$linear" "REL-1 | Active ticket | In Progress | https://linear.example/REL-1"
  make_hook "$slack" "slack://mention/1 | Need reply | open | https://slack.example/m1"

  cat > "$doc" <<'EOF'
# Manual Heading

Keep this human note.

<!-- fm-backlog-pull:generated:start -->
old generated content
<!-- fm-backlog-pull:generated:end -->

Keep this tail note.
EOF

  FM_GH_TEAMS="reliability,platform" \
    FM_LINEAR_CMD="$linear" \
    FM_SLACK_CMD="$slack" \
    run_pull "$home" "$fakebin" >/dev/null

  assert_grep "Keep this human note." "$doc" "manual leading content was not preserved"
  assert_grep "Keep this tail note." "$doc" "manual trailing content was not preserved"
  assert_no_grep "old generated content" "$doc" "old generated section was not replaced"
  assert_grep "- Team review-requested: reliability: ok: 1 item(s)" "$doc" "team reliability status missing"
  assert_grep "- Team review-requested: platform: ok: 0 item(s)" "$doc" "team platform empty status missing"
  assert_grep "- #301 | team reliability review | open | https://github.com/lindy-ai/lindy/pull/301" "$doc" \
    "team review item missing"
  assert_grep "- Linear tickets: ok: 1 item(s)" "$doc" "Linear hook status missing"
  assert_grep "- REL-1 | Active ticket | In Progress | https://linear.example/REL-1" "$doc" \
    "Linear hook item missing"
  assert_grep "- Slack mentions: ok: 1 item(s)" "$doc" "Slack hook status missing"
  assert_grep "- slack://mention/1 | Need reply | open | https://slack.example/m1" "$doc" \
    "Slack hook item missing"
  pass "fm-backlog-pull preserves manual content and includes teams/hooks"
}

test_github_failure_degrades_per_source() {
  local case_dir home fakebin doc
  case_dir="$TMP_ROOT/failure"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pr list '*)
    echo "auth failed" >&2
    exit 1
    ;;
  'search prs review-requested:twaldin '*)
    cat <<'EOF'
count: 1
prs[1]{number,title,state,author}:
  401,still parsed,open,alice,no,required
EOF
    ;;
  *)
    echo "unexpected gh-axi args: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/gh-axi"

  run_pull "$home" "$fakebin" >/dev/null
  doc="$home/data/lindy/open-work-backlog.md"

  assert_grep "- Authored PRs: skipped: auth failed" "$doc" "authored failure was not reported"
  assert_grep "- Review-requested PRs: ok: 1 item(s)" "$doc" "healthy source was not preserved after failure"
  assert_grep "- #401 | still parsed | open | https://github.com/lindy-ai/lindy/pull/401" "$doc" \
    "healthy source item missing after another source failed"
  pass "fm-backlog-pull degrades per GitHub source"
}

test_refreshes_github_and_skips_unconfigured_sources
test_team_hooks_and_manual_content_preserved
test_github_failure_degrades_per_source
