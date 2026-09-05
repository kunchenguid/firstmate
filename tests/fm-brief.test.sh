#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"
BRIEF_PROJECTS="$TMP_ROOT/projects"

# Brief generation now resolves its named repo from the configured project root.
# These local-only fixtures carry a non-main default branch and a local origin
# so the generated command is tested against the actual delivery-path ref.
init_brief_project() {
  local name=$1 repo
  repo="$BRIEF_PROJECTS/$name"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M release
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" fetch --quiet origin
  git -C "$repo" remote set-head origin --auto >/dev/null
}

for brief_project in some-proj direct-proj local-proj never-registered firstmate foreign sample alpha; do
  init_brief_project "$brief_project"
done
export FM_PROJECTS_OVERRIDE="$BRIEF_PROJECTS"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "{FIRSTMATE_SPEC}" "$brief" "$id: brief missing the {FIRSTMATE_SPEC} placeholder"
    assert_grep "## Captain's intent" "$brief" "$id: brief missing Captain's intent subsection"
    assert_grep "## Firstmate spec" "$brief" "$id: brief missing Firstmate spec subsection"
    assert_grep 'never a bare number such as "PR 108"' "$brief" "$id: brief missing the full-PR-URL rule"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_base_freshness_check_is_resolved_and_mode_aware() {
  local home ship local_brief scout ship_setup local_setup scout_setup ship_dod local_dod scout_dod local_ahead
  home="$TMP_ROOT/base-freshness-home"
  mkdir -p "$home/data"

  printf '%s\n' 'local-only default moves ahead of origin' >> "$BRIEF_PROJECTS/local-proj/README.md"
  git -C "$BRIEF_PROJECTS/local-proj" add README.md
  git -C "$BRIEF_PROJECTS/local-proj" commit -qm 'local default advances'
  local_ahead=$(git -C "$BRIEF_PROJECTS/local-proj" rev-list --count origin/release..release)
  [ "$local_ahead" -gt 0 ] || fail "local-only fixture did not move its local default branch ahead of origin"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" base-pr direct-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "PR brief should scaffold with a resolved default branch"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" base-local local-proj --mode local-only >/dev/null 2>&1 \
    || fail "local-only brief should scaffold with a resolved local default branch"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" base-scout sample --scout >/dev/null 2>&1 \
    || fail "scout brief should scaffold with a resolved default branch"

  ship="$home/data/base-pr/brief.md"
  local_brief="$home/data/base-local/brief.md"
  scout="$home/data/base-scout/brief.md"
  ship_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$ship")
  local_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$local_brief")
  scout_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$scout")
  ship_dod=$(sed -n '/^# Definition of done$/,$p' "$ship")
  local_dod=$(sed -n '/^# Definition of done$/,$p' "$local_brief")
  scout_dod=$(sed -n '/^# Definition of done$/,$p' "$scout")

  assert_contains "$ship_setup" "1. **Verify isolation before anything else.**" \
    "ship brief did not number worktree isolation as the first safety step"
  assert_contains "$ship_setup" "2. **Check your base before starting work.**" \
    "ship brief did not number the base check as the second safety step"
  assert_contains "$ship_setup" "git rev-list --count \$(git merge-base HEAD 'refs/remotes/origin/release')..'refs/remotes/origin/release'" \
    "PR brief did not check the resolved remote default branch"
  assert_contains "$ship_setup" "Only \`0\` passes against the freshly fetched default branch \`origin/release\`." \
    "PR brief did not state the zero-only pass criterion"
  assert_contains "$ship_setup" 'git fetch origin --quiet' \
    "PR brief compared against the tracking ref without refreshing it first"
  assert_contains "$ship_setup" 'blocked: cannot fetch origin to verify base freshness' \
    "PR brief did not tell the worker to report blocked when the single fetch fails"
  assert_contains "$ship_setup" "3. Create your branch: \`git checkout -b fm/base-pr\`" \
    "ship brief did not number branch creation as the third safety step"
  assert_not_contains "$ship_setup" 'on a clean default branch' \
    "ship brief retained an unchecked clean-base assertion"
  assert_not_contains "$ship_setup" 'origin/main' \
    "PR brief hard-coded main instead of the resolved default branch"
  assert_not_contains "$ship_dod" 'git rev-list --count' \
    "PR brief put the freshness check in Definition of done instead of Setup"

  assert_contains "$local_setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/release')..'refs/heads/release'" \
    "local-only brief did not check its local default branch"
  assert_contains "$local_setup" "Only \`0\` passes against your local default branch \`release\`." \
    "local-only brief did not explain its local zero-only criterion"
  assert_not_contains "$local_setup" 'origin/release' \
    "local-only brief used the stale origin tracking ref instead of its local default branch"
  assert_not_contains "$local_setup" 'git fetch' \
    "local-only brief refreshed the network even though it lands in the local branch"
  assert_not_contains "$local_dod" 'git rev-list --count' \
    "local-only brief put the freshness check in Definition of done instead of Setup"

  assert_contains "$scout_setup" "1. **Check your base before starting work.**" \
    "scout brief did not make the base check its first numbered startup step"
  assert_contains "$scout_setup" "git rev-list --count \$(git merge-base HEAD 'refs/remotes/origin/release')..'refs/remotes/origin/release'" \
    "scout brief did not check the resolved default branch"
  assert_contains "$scout_setup" "Only \`0\` passes against the freshly fetched default branch \`origin/release\`." \
    "scout brief did not state the zero-only pass criterion"
  assert_contains "$scout_setup" 'git fetch origin --quiet' \
    "scout brief compared against the tracking ref without refreshing it first"
  assert_not_contains "$scout_setup" 'on a clean default branch' \
    "scout brief retained an unchecked clean-base assertion"
  assert_not_contains "$scout_dod" 'git rev-list --count' \
    "scout brief put the freshness check in Definition of done instead of Setup"
  pass "fm-brief.sh: startup base freshness is resolved, zero-only, and mode-aware"
}

# The default branch is data from a repository, but resolved briefs embed it in
# commands that workers execute. A shell-significant ref must therefore render
# as one shell word, not become a second command in the worker's shell.
# shellcheck disable=SC2016 # The fixture branch must contain the literal $IFS expansion attempt.
test_resolved_default_branch_is_shell_quoted_in_the_freshness_command() {
  local home unsafe marker marker_name setup freshness_command unsafe_branch
  home="$TMP_ROOT/shell-quoted-default-home"
  unsafe="$BRIEF_PROJECTS/shell-quoted-default"
  marker_name='branch-name-command-ran'
  marker="$unsafe/$marker_name"
  mkdir -p "$home/data"

  unsafe_branch="release;touch\$IFS\$9$marker_name"
  fm_git_init_commit "$unsafe"
  git -C "$unsafe" branch -M "$unsafe_branch"
  fm_git_add_origin "$unsafe" "$unsafe.origin.git"
  git -C "$unsafe" fetch --quiet origin
  git -C "$unsafe" remote set-head origin --auto >/dev/null

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" shell-quoted shell-quoted-default --mode direct-PR >/dev/null 2>&1 \
    || fail "a shell-significant default branch should scaffold successfully"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/shell-quoted/brief.md")
  freshness_command=$(printf '%s\n' "$setup" | sed -n 's/^   `\(git rev-list --count .*\)`$/\1/p')

  assert_contains "$freshness_command" "git rev-list --count \$(git merge-base HEAD 'refs/remotes/origin/$unsafe_branch')..'refs/remotes/origin/$unsafe_branch'" \
    "the resolved default branch was not shell-quoted in the freshness command"
  [ -n "$freshness_command" ] || fail "the resolved brief did not render a freshness command"
  (cd "$unsafe" && bash -c "$freshness_command") >/dev/null 2>&1 \
    || fail "the shell-quoted freshness command did not execute against its default branch"
  assert_absent "$marker" "the rendered default branch executed a shell command"
  pass "fm-brief.sh: resolved default branches are shell-quoted in freshness commands"
}

# Reads the first command the brief DELIMITS on a line of its own, the way the
# reading worker does: a markdown code span opens on a backtick run and closes on
# the first later run of the same length, and one padding space on each side is
# dropped. The tests below must not assume a one-backtick fence, or they would
# read past a broken span and pass on output no worker could run.
brief_delimited_command() {  # <setup-text> <command-prefix>
  perl - "$2" "$1" <<'PERL'
use strict;
use warnings;

my ($prefix, $text) = @ARGV;
for my $line (split /\n/, $text) {
  next unless $line =~ /^\s*(`+)(.*)$/;
  my ($fence, $rest) = ($1, $2);
  my $content;
  while ($rest =~ /(`+)/g) {
    next unless length($1) == length($fence);
    $content = substr($rest, 0, $-[1]);
    last;
  }
  next unless defined $content;
  $content = $1 if $content =~ /^ (.*) $/;
  next unless index($content, $prefix) == 0;
  print "$content\n";
  exit 0;
}
exit 1;
PERL
}

# git permits a backtick in a refname, and the brief is generated worker-facing
# output whose markdown code span is what tells the worker where the mandatory
# command ends. A fixed one-backtick fence closes on the ref's own backtick, so
# the worker is handed a truncated, unrunnable fragment of the freshness check
# while the scaffold still reports success - the check silently stops existing
# for that repo. Drive such a branch through the scaffold and run exactly what
# the brief delimits.
test_resolved_default_branch_survives_a_backtick_in_its_name() {
  local home backtick worktree setup freshness_command count branch
  home="$TMP_ROOT/backtick-default-home"
  backtick="$BRIEF_PROJECTS/backtick-default"
  worktree="$TMP_ROOT/backtick-default-worktree"
  branch='rel`ease'
  mkdir -p "$home/data"

  fm_git_init_commit "$backtick"
  git -C "$backtick" branch -M "$branch"
  fm_git_add_origin "$backtick" "$backtick.origin.git"
  git -C "$backtick" worktree add --quiet --detach "$worktree" HEAD
  printf '%s\n' 'the default branch advances' >> "$backtick/README.md"
  git -C "$backtick" add README.md
  git -C "$backtick" commit -qm 'default branch advances'
  printf '%s\n' 'the default branch advances again' >> "$backtick/README.md"
  git -C "$backtick" add README.md
  git -C "$backtick" commit -qm 'default branch advances again'
  git -C "$backtick" push --quiet origin "$branch"
  git -C "$backtick" fetch --quiet origin
  git -C "$backtick" remote set-head origin --auto >/dev/null

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" backtick-base backtick-default --mode direct-PR >/dev/null 2>&1 \
    || fail "a backtick in the default branch name must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/backtick-base/brief.md")
  freshness_command=$(brief_delimited_command "$setup" 'git rev-list --count ') \
    || fail "the brief delimited no complete freshness command for a backtick default branch"

  count=$(cd "$worktree" && eval "$freshness_command") \
    || fail "the delimited freshness command did not run against a backtick default branch"
  [ "$count" -eq 2 ] \
    || fail "the delimited command measured '$count' instead of 2 commits behind the default branch"
  pass "fm-brief.sh: a backtick in the default branch name still delimits a runnable command"
}

# The runtime twin of the test above. An unresolvable repo label leaves the base
# to be named by the WORKER at runtime, so the emitted command carries a
# `<default>` placeholder instead of a scaffold-quoted ref. git permits refnames
# holding `$`, backticks and `;`, so that placeholder must already sit inside
# single quotes: a worker substituting a shell-significant default branch into an
# unquoted argument would split the ref or run a second command instead of
# measuring its base.
# shellcheck disable=SC2016 # The fixture branch must contain the literal $IFS expansion attempt.
test_runtime_fallback_ref_stays_one_shell_word() {
  local home unsafe worktree marker marker_name setup count_cmd unsafe_branch count
  home="$TMP_ROOT/runtime-quoted-default-home"
  unsafe="$TMP_ROOT/runtime-shell-significant-default"
  worktree="$TMP_ROOT/runtime-shell-significant-worktree"
  marker_name='runtime-branch-name-command-ran'
  marker="$worktree/$marker_name"
  mkdir -p "$home/data"

  [ ! -d "$BRIEF_PROJECTS/no-such-unsafe-repo" ] || fail "fixture leak: no-such-unsafe-repo must not resolve"

  unsafe_branch="release;touch\$IFS\$9$marker_name"
  fm_git_init_commit "$unsafe"
  git -C "$unsafe" branch -M "$unsafe_branch"
  git -C "$unsafe" worktree add --quiet --detach "$worktree" HEAD
  printf '%s\n' 'the default branch advances' >> "$unsafe/README.md"
  git -C "$unsafe" add README.md
  git -C "$unsafe" commit -qm 'default branch advances'
  printf '%s\n' 'the default branch advances again' >> "$unsafe/README.md"
  git -C "$unsafe" add README.md
  git -C "$unsafe" commit -qm 'default branch advances again'

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" runtime-quoted no-such-unsafe-repo --mode local-only >/dev/null 2>&1 \
    || fail "an unresolvable local-only label must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/runtime-quoted/brief.md")
  count_cmd=$(printf '%s\n' "$setup" | sed -n 's/^   `\(git rev-list --count .*\)`$/\1/p' | head -1)
  [ -n "$count_cmd" ] || fail "the runtime fallback did not render a zero-count command"

  count=$(cd "$worktree" && bash -c "${count_cmd//<default>/$unsafe_branch}" 2>/dev/null) \
    || fail "the emitted runtime command did not execute against a shell-significant default branch"
  assert_absent "$marker" "the substituted default branch executed a shell command"
  [ "$count" = 2 ] \
    || fail "the emitted runtime command measured '$count' instead of 2 commits behind the default branch"
  pass "fm-brief.sh: runtime fallback refs stay one shell word when substituted"
}

# git's rev-parse precedence ranks `refs/tags/<name>` ABOVE `refs/heads/<name>`
# and `refs/remotes/<name>`, so a tag that merely shares the base branch's name
# wins the emitted command's ref lookup. The brief is generated worker-facing
# output and states `0` as its sole pass criterion, so an unqualified base ref
# lets a same-named tag certify a stale base as fresh - the exact failure this
# check exists to catch.
# shellcheck disable=SC2016 # The sed pattern must match the literal backticks the brief emits.
test_emitted_base_command_survives_a_same_named_tag() {
  local home local_repo local_worktree pr_repo pr_worktree setup freshness_command count shadowed
  home="$TMP_ROOT/tag-shadowed-home"
  local_repo="$BRIEF_PROJECTS/tag-shadowed-local"
  local_worktree="$TMP_ROOT/tag-shadowed-local-worktree"
  pr_repo="$BRIEF_PROJECTS/tag-shadowed-origin"
  pr_worktree="$TMP_ROOT/tag-shadowed-origin-worktree"
  mkdir -p "$home/data"

  fm_git_init_commit "$local_repo"
  git -C "$local_repo" branch -M release
  fm_git_add_origin "$local_repo" "$local_repo.origin.git"
  git -C "$local_repo" fetch --quiet origin
  git -C "$local_repo" remote set-head origin --auto >/dev/null
  git -C "$local_repo" tag stale-base
  git -C "$local_repo" tag release
  printf '%s\n' 'first' >> "$local_repo/README.md"
  git -C "$local_repo" add README.md
  git -C "$local_repo" commit -qm 'local default advances once'
  printf '%s\n' 'second' >> "$local_repo/README.md"
  git -C "$local_repo" add README.md
  git -C "$local_repo" commit -qm 'local default advances twice'
  git -C "$local_repo" worktree add --quiet --detach "$local_worktree" refs/tags/stale-base

  fm_git_init_commit "$pr_repo"
  git -C "$pr_repo" branch -M release
  fm_git_add_origin "$pr_repo" "$pr_repo.origin.git"
  git -C "$pr_repo" fetch --quiet origin
  git -C "$pr_repo" remote set-head origin --auto >/dev/null
  git -C "$pr_repo" tag stale-base
  git -C "$pr_repo" tag origin/release
  printf '%s\n' 'first' >> "$pr_repo/README.md"
  git -C "$pr_repo" add README.md
  git -C "$pr_repo" commit -qm 'remote default advances once'
  printf '%s\n' 'second' >> "$pr_repo/README.md"
  git -C "$pr_repo" add README.md
  git -C "$pr_repo" commit -qm 'remote default advances twice'
  git -C "$pr_repo" push --quiet origin release
  git -C "$pr_repo" fetch --quiet origin
  git -C "$pr_repo" worktree add --quiet --detach "$pr_worktree" refs/tags/stale-base

  shadowed=$(cd "$local_worktree" && git rev-list --count "$(git merge-base HEAD release)..release" 2>/dev/null)
  [ "$shadowed" -eq 0 ] || fail "the local fixture does not shadow its default branch with a same-named tag"
  shadowed=$(cd "$pr_worktree" && git rev-list --count "$(git merge-base HEAD origin/release)..origin/release" 2>/dev/null)
  [ "$shadowed" -eq 0 ] || fail "the PR fixture does not shadow its tracking ref with a same-named tag"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tag-local tag-shadowed-local --mode local-only >/dev/null 2>&1 \
    || fail "a tag-shadowed local default must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/tag-local/brief.md")
  freshness_command=$(printf '%s\n' "$setup" | sed -n 's/^   `\(git rev-list --count .*\)`$/\1/p' | head -1)
  [ -n "$freshness_command" ] || fail "the local-only brief emitted no base-freshness command"
  count=$(cd "$local_worktree" && eval "$freshness_command" 2>/dev/null) \
    || fail "the emitted local-only command failed against the tag-shadowed fixture"
  [ "$count" -eq 2 ] \
    || fail "the emitted local-only command reported $count against a same-named tag instead of 2 against the branch"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tag-pr tag-shadowed-origin --mode direct-PR >/dev/null 2>&1 \
    || fail "a tag-shadowed tracking ref must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/tag-pr/brief.md")
  freshness_command=$(printf '%s\n' "$setup" | sed -n 's/^   `\(git rev-list --count .*\)`$/\1/p' | head -1)
  [ -n "$freshness_command" ] || fail "the PR-path brief emitted no base-freshness command"
  count=$(cd "$pr_worktree" && eval "$freshness_command" 2>/dev/null) \
    || fail "the emitted PR-path command failed against the tag-shadowed fixture"
  [ "$count" -eq 2 ] \
    || fail "the emitted PR-path command reported $count against a same-named tag instead of 2 against the tracking ref"
  pass "fm-brief.sh: the emitted base command measures the real ref through a same-named tag"
}

# The repo positional is a caller-supplied label, not a path contract: firstmate
# names repos this scaffold has no local view of, so an unresolvable label must
# still produce a brief - and that brief must still carry the mandatory check
# with the base determined by the worker at runtime.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_unresolvable_repo_label_still_mandates_the_base_check() {
  local home ship scout ship_setup scout_setup
  home="$TMP_ROOT/unresolvable-repo-home"
  mkdir -p "$home/data"

  [ ! -d "$BRIEF_PROJECTS/no-such-repo" ] || fail "fixture leak: no-such-repo must not resolve"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" label-ship no-such-repo --mode no-mistakes >/dev/null 2>&1 \
    || fail "an unresolvable repo label must not fail the ship scaffold"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" label-scout no-such-repo --scout >/dev/null 2>&1 \
    || fail "an unresolvable repo label must not fail the scout scaffold"

  ship="$home/data/label-ship/brief.md"
  scout="$home/data/label-scout/brief.md"
  [ -f "$ship" ] || fail "no ship brief was written for an unresolvable repo label"
  [ -f "$scout" ] || fail "no scout brief was written for an unresolvable repo label"
  ship_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$ship")
  scout_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$scout")

  assert_contains "$ship_setup" "2. **Check your base before starting work.**" \
    "the runtime fallback lost its numbered place in the ship safety contract"
  assert_contains "$ship_setup" "git rev-list --count \$(git merge-base HEAD 'refs/remotes/origin/<default>')..'refs/remotes/origin/<default>'" \
    "the runtime fallback omitted the mandatory zero-count command"
  assert_contains "$ship_setup" 'blocked: cannot determine the default branch to verify base freshness' \
    "the runtime fallback did not require reporting blocked on an undeterminable base"
  assert_contains "$ship_setup" 'never skip, soften, or postpone it' \
    "the runtime fallback softened the mandatory check"
  assert_contains "$scout_setup" "git rev-list --count \$(git merge-base HEAD 'refs/remotes/origin/<default>')..'refs/remotes/origin/<default>'" \
    "the scout runtime fallback omitted the mandatory zero-count command"
  pass "fm-brief.sh: an unresolvable repo label still mandates the base check at runtime"
}

# A clone with no origin/HEAD that is stranded on a feature branch (the worktree
# tangle bin/fm-tangle-lib.sh detects) must never have that feature branch
# rendered as its own base - the brief would then certify a wrong base as fresh.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_missing_origin_head_never_relabels_the_current_branch() {
  local home stranded setup
  home="$TMP_ROOT/stranded-head-home"
  stranded="$BRIEF_PROJECTS/stranded"
  mkdir -p "$home/data"

  fm_git_init_commit "$stranded"
  git -C "$stranded" branch -M main
  git -C "$stranded" checkout -q -b fm/old-task
  [ "$(git -C "$stranded" symbolic-ref --short HEAD)" = "fm/old-task" ] \
    || fail "stranded fixture is not checked out on its feature branch"
  git -C "$stranded" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1 \
    && fail "stranded fixture unexpectedly has an origin/HEAD"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" stranded-local stranded --mode local-only >/dev/null 2>&1 \
    || fail "local-only brief should scaffold against a stranded clone"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/stranded-local/brief.md")

  assert_not_contains "$setup" 'fm/old-task' \
    "the checked-out feature branch was rendered as the local default branch"
  assert_contains "$setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/main')..'refs/heads/main'" \
    "the stranded clone did not fall back to its local default-branch ref"
  pass "fm-brief.sh: a missing origin/HEAD never relabels the current feature branch"
}

# `projects/` is a gitignored subdirectory of the firstmate checkout itself, so a
# directory that is merely INSIDE a work tree must never resolve: it would render
# the enclosing repo's default branch as an unrelated project's base - a
# confidently-wrong base with no error, the exact class this check exists to stop.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_non_root_directory_never_resolves_to_its_enclosing_repo() {
  local home enclosing setup
  home="$TMP_ROOT/non-root-home"
  enclosing="$TMP_ROOT/enclosing-checkout"
  mkdir -p "$home/data"

  fm_git_init_commit "$enclosing"
  git -C "$enclosing" branch -M trunk
  fm_git_add_origin "$enclosing" "$enclosing.origin.git"
  git -C "$enclosing" fetch --quiet origin
  git -C "$enclosing" remote set-head origin --auto >/dev/null
  mkdir -p "$enclosing/projects/webapp"
  [ "$(git -C "$enclosing/projects/webapp" rev-parse --show-toplevel)" = "$(cd "$enclosing" && pwd -P)" ] \
    || fail "fixture is not a plain directory inside the enclosing work tree"

  FM_PROJECTS_OVERRIDE="$enclosing/projects" FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" non-root webapp --mode direct-PR >/dev/null 2>&1 \
    || fail "a non-root project directory must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/non-root/brief.md")

  assert_not_contains "$setup" 'origin/trunk' \
    "a plain directory inside a work tree rendered the enclosing repo's default branch as its base"
  assert_contains "$setup" "git rev-list --count \$(git merge-base HEAD 'refs/remotes/origin/<default>')..'refs/remotes/origin/<default>'" \
    "a non-root project directory did not fall back to the runtime base check"
  pass "fm-brief.sh: a directory inside a work tree never resolves as that project's repo"
}

# origin/HEAD is the authority on the default branch NAME. When the clone has no
# local ref for it, no other branch may be presented as "your local default
# branch"; the strict runtime fallback must take over instead.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_absent_local_ref_for_origin_default_never_substitutes_another_branch() {
  local home diverged setup
  home="$TMP_ROOT/absent-local-ref-home"
  diverged="$BRIEF_PROJECTS/diverged"
  mkdir -p "$home/data"

  fm_git_init_commit "$diverged"
  git -C "$diverged" branch -M develop
  fm_git_add_origin "$diverged" "$diverged.origin.git"
  git -C "$diverged" fetch --quiet origin
  git -C "$diverged" remote set-head origin --auto >/dev/null
  git -C "$diverged" checkout -q -b main
  printf '%s\n' 'diverged' >> "$diverged/README.md"
  git -C "$diverged" add README.md
  git -C "$diverged" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'local main diverges from the default branch'
  git -C "$diverged" branch -D develop >/dev/null
  [ "$(git -C "$diverged" symbolic-ref --short refs/remotes/origin/HEAD)" = "origin/develop" ] \
    || fail "fixture origin/HEAD does not name develop"
  git -C "$diverged" rev-parse --verify --quiet refs/heads/develop >/dev/null 2>&1 \
    && fail "fixture still has a local develop ref"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" absent-ref diverged --mode local-only >/dev/null 2>&1 \
    || fail "an absent local ref for origin's default must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/absent-ref/brief.md")

  assert_not_contains "$setup" 'your local default branch `main`' \
    "a substitute branch was presented as the repository's local default branch"
  assert_contains "$setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/<default>')..'refs/heads/<default>'" \
    "an absent local ref for origin's default did not fall back to the runtime base check"
  assert_contains "$setup" 'blocked: cannot determine the default branch to verify base freshness' \
    "the runtime fallback dropped its blocked-and-stop requirement"
  assert_contains "$setup" 'Only when that ref is absent entirely' \
    "the runtime fallback did not gate the main/master guess on origin/HEAD being absent"
  assert_contains "$setup" 'Never substitute `main`, `master`, or whatever branch happens to be checked out' \
    "the runtime fallback did not forbid substituting a branch for a missing default"
  pass "fm-brief.sh: an absent local ref for origin's default never substitutes another branch"
}

# `git symbolic-ref --short` abbreviates only while the result is unambiguous: a
# clone that also holds a ref literally named `origin/<default>` gets
# `remotes/origin/<default>` back instead. Reading the default branch through
# that abbreviation turned a resolvable default into "no authority exists at
# all" and silently substituted the local `main` - the exact wrong-base failure
# this check exists to catch.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_ambiguous_origin_head_still_resolves_the_real_default_branch() {
  local home ambiguous setup rules
  home="$TMP_ROOT/ambiguous-origin-head-home"
  ambiguous="$BRIEF_PROJECTS/ambiguous-origin-head"
  mkdir -p "$home/data"

  fm_git_init_commit "$ambiguous"
  git -C "$ambiguous" branch -M develop
  fm_git_add_origin "$ambiguous" "$ambiguous.origin.git"
  git -C "$ambiguous" fetch --quiet origin
  git -C "$ambiguous" remote set-head origin --auto >/dev/null
  git -C "$ambiguous" branch main
  git -C "$ambiguous" tag origin/develop
  [ "$(git -C "$ambiguous" symbolic-ref --quiet --short refs/remotes/origin/HEAD)" = 'remotes/origin/develop' ] \
    || fail "fixture did not make the --short abbreviation of origin/HEAD ambiguous"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ambiguous-head ambiguous-origin-head --mode local-only >/dev/null 2>&1 \
    || fail "an ambiguous origin/HEAD abbreviation must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/ambiguous-head/brief.md")
  rules=$(sed -n '/^# Rules$/,/^# Firstmate instruction inbox$/p' "$home/data/ambiguous-head/brief.md")

  assert_contains "$setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/develop')..'refs/heads/develop'" \
    "an ambiguous origin/HEAD abbreviation stopped the brief measuring against the real default branch"
  assert_contains "$setup" 'Only `0` passes against your local default branch `develop`.' \
    "the brief did not name the real default branch in its zero-only criterion"
  assert_not_contains "$setup" 'your local default branch `main`' \
    "an ambiguous origin/HEAD abbreviation substituted main for the real default branch"
  assert_not_contains "$setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/<default>')..'refs/heads/<default>'" \
    "a resolvable default branch was deferred to the runtime fallback"
  assert_contains "$rules" 'firstmate handles the merge into local `develop`' \
    "Rule 1 named a branch other than the real default"
  assert_not_contains "$rules" 'merge into local `main`' \
    "Rule 1 substituted main for the real default branch"
  pass "fm-brief.sh: an ambiguous origin/HEAD abbreviation still resolves the real default branch"
}

# The runtime local-default rule is generated worker-facing output that a
# crewmate executes verbatim, so it is held to the same standard as the
# scaffold-side resolution. Reading origin/HEAD through the ambiguity-dependent
# `--short` form and then confirming a bare `<default>` let the remote-tracking
# ref satisfy a guard meant to prove a LOCAL branch exists, so a local-only
# worker measured zero against origin while its local default was ahead.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_runtime_local_default_rule_resolves_a_local_branch_not_a_tracking_ref() {
  local home stale worktree setup symbolic_cmd strip_prefix verify_cmd count_cmd
  local head_ref resolved_default count tracking_ref
  tracking_ref='remotes/origin/develop'
  home="$TMP_ROOT/runtime-local-rule-home"
  stale="$BRIEF_PROJECTS/stale-local-default"
  worktree="$TMP_ROOT/stale-local-default-worktree"
  mkdir -p "$home/data"

  [ ! -d "$BRIEF_PROJECTS/unresolvable-stale" ] || fail "fixture leak: unresolvable-stale must not resolve"

  fm_git_init_commit "$stale"
  git -C "$stale" branch -M develop
  fm_git_add_origin "$stale" "$stale.origin.git"
  git -C "$stale" fetch --quiet origin
  git -C "$stale" remote set-head origin --auto >/dev/null
  git -C "$stale" tag origin/develop
  printf '%s\n' 'the local default advances' >> "$stale/README.md"
  git -C "$stale" add README.md
  git -C "$stale" commit -qm 'local develop advances'
  printf '%s\n' 'the local default advances again' >> "$stale/README.md"
  git -C "$stale" add README.md
  git -C "$stale" commit -qm 'local develop advances again'
  git -C "$stale" worktree add --quiet --detach "$worktree" refs/remotes/origin/develop
  [ "$(git -C "$stale" symbolic-ref --quiet --short refs/remotes/origin/HEAD)" = 'remotes/origin/develop' ] \
    || fail "fixture did not make the --short abbreviation of origin/HEAD ambiguous"
  [ "$(git -C "$worktree" rev-list --count "$(git -C "$worktree" merge-base HEAD develop)..develop")" -eq 2 ] \
    || fail "fixture worktree is not two commits behind its local default branch"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" runtime-local unresolvable-stale --mode local-only >/dev/null 2>&1 \
    || fail "an unresolvable local-only label must not fail the scaffold"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/runtime-local/brief.md")

  symbolic_cmd=$(printf '%s\n' "$setup" | sed -n 's/^.*Read `\(git symbolic-ref [^`]*\)`.*$/\1/p' | head -1)
  strip_prefix=$(printf '%s\n' "$setup" | sed -n 's/^.*with the leading `\([^`]*\)` dropped.*$/\1/p' | head -1)
  verify_cmd=$(printf '%s\n' "$setup" | sed -n 's/^.*exists with `\(git rev-parse --verify [^`]*\)`.*$/\1/p' | head -1)
  count_cmd=$(printf '%s\n' "$setup" | sed -n 's/^   `\(git rev-list --count .*\)`$/\1/p' | head -1)
  [ -n "$symbolic_cmd" ] || fail "the runtime rule stopped telling the worker how to read origin/HEAD"
  [ -n "$strip_prefix" ] || fail "the runtime rule stopped naming the prefix to strip from origin/HEAD"
  [ -n "$verify_cmd" ] || fail "the runtime rule stopped telling the worker how to confirm the local branch"
  [ -n "$count_cmd" ] || fail "the runtime rule stopped emitting its zero-count command"

  head_ref=$(cd "$worktree" && eval "$symbolic_cmd") \
    || fail "the emitted origin/HEAD read failed against the fixture"
  resolved_default=${head_ref#"$strip_prefix"}
  [ "$resolved_default" = develop ] \
    || fail "the emitted rule resolved \`$resolved_default\` instead of the real default branch develop"
  (cd "$worktree" && eval "${verify_cmd//<default>/$resolved_default}" >/dev/null 2>&1) \
    || fail "the emitted confirmation rejected the real local default branch"
  (cd "$worktree" && eval "${verify_cmd//<default>/$tracking_ref}" >/dev/null 2>&1) \
    && fail "the emitted confirmation accepted a remote-tracking ref as the local default branch"

  count=$(cd "$worktree" && eval "${count_cmd//<default>/$resolved_default}") \
    || fail "the emitted zero-count command failed against the fixture"
  [ "$count" -eq 2 ] \
    || fail "the emitted check measured $count against the local default branch instead of 2"
  pass "fm-brief.sh: the runtime local-default rule resolves a local branch, never a tracking ref"
}

# The generated brief must not contradict itself: a local-only task whose Setup
# rebases onto `release` cannot tell the worker firstmate merges into `main`.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_local_only_rule_names_the_resolved_default_branch() {
  local home rules setup
  home="$TMP_ROOT/local-rule-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" rule-local local-proj --mode local-only >/dev/null 2>&1 \
    || fail "local-only brief should scaffold against the release-default fixture"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/rule-local/brief.md")
  rules=$(sed -n '/^# Rules$/,/^# Firstmate instruction inbox$/p' "$home/data/rule-local/brief.md")

  assert_contains "$setup" "rebase onto \`'refs/heads/release'\`" \
    "the rebase target the worker executes is not the fully-qualified, shell-quoted local default ref"
  assert_contains "$setup" 'Only `0` passes against your local default branch `release`.' \
    "the descriptive line stopped naming the default branch by its short readable name"
  assert_contains "$rules" 'firstmate handles the merge into local `release`' \
    "Rule 1 named a branch other than the resolved local default"
  assert_not_contains "$rules" 'merge into local `main`' \
    "Rule 1 kept the hard-coded main that contradicts the resolved Setup base"
  pass "fm-brief.sh: local-only Rule 1 names the resolved local default branch"
}

# A scout lands nowhere - its deliverable is a report and it may never push. When
# it falls back to a local comparison it must be told WHY (origin's default could
# not be resolved), never that its task "lands locally".
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_scout_local_fallback_uses_kind_neutral_wording() {
  local home remoteless setup
  home="$TMP_ROOT/scout-neutral-home"
  remoteless="$BRIEF_PROJECTS/remoteless"
  mkdir -p "$home/data"

  fm_git_init_commit "$remoteless"
  git -C "$remoteless" branch -M main
  [ -z "$(git -C "$remoteless" remote)" ] || fail "remoteless fixture unexpectedly has a remote"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" neutral-scout remoteless --scout >/dev/null 2>&1 \
    || fail "scout brief should scaffold against a remoteless clone"
  setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/neutral-scout/brief.md")

  assert_contains "$setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/main')..'refs/heads/main'" \
    "the scout local fallback did not measure against the local default branch"
  assert_not_contains "$setup" 'This task lands locally' \
    "the scout brief claimed its task lands locally"
  assert_contains "$setup" "Origin's default branch could not be resolved, so do not fetch" \
    "the scout local fallback did not explain why it skips the network refresh"
  pass "fm-brief.sh: a scout local fallback explains itself without claiming it lands locally"
}

# A scout's runtime fallback must mirror the policy the same scaffold applies
# when the label DOES resolve: prefer a verified origin default, degrade to a
# verified local default with no network refresh, and block only if neither can
# be established. An origin-only fallback would strand a scout in a remote-less
# clone before it does any research.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_unresolved_scout_fallback_degrades_to_a_local_default() {
  local home scout_setup ship_setup
  home="$TMP_ROOT/unresolved-scout-fallback-home"
  mkdir -p "$home/data"

  [ ! -d "$BRIEF_PROJECTS/comms" ] || fail "fixture leak: comms must not resolve"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fallback-scout comms --scout >/dev/null 2>&1 \
    || fail "an unresolvable scout label must not fail the scaffold"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fallback-ship comms --mode direct-PR >/dev/null 2>&1 \
    || fail "an unresolvable PR-path label must not fail the scaffold"
  scout_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/fallback-scout/brief.md")
  ship_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/fallback-ship/brief.md")

  assert_contains "$scout_setup" 'git fetch origin --quiet' \
    "the scout fallback dropped the single fetch that precedes its origin comparison"
  assert_contains "$scout_setup" "git rev-list --count \$(git merge-base HEAD 'refs/remotes/origin/<default>')..'refs/remotes/origin/<default>'" \
    "the scout fallback lost its origin-first zero-count command"
  assert_contains "$scout_setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/<default>')..'refs/heads/<default>'" \
    "the scout fallback never degrades to a local default when origin cannot be established"
  assert_contains "$scout_setup" 'If no usable origin default remains after that single fetch' \
    "the scout fallback did not gate its local degradation on origin being unusable after the fetch"
  assert_contains "$scout_setup" 'NO further network refresh' \
    "the scout local degradation did not forbid an additional network refresh"
  assert_contains "$scout_setup" 'blocked: cannot determine the default branch to verify base freshness' \
    "the scout fallback dropped its block-and-stop requirement"
  assert_not_contains "$scout_setup" 'This task lands locally' \
    "the scout fallback claimed the task lands locally"

  assert_not_contains "$ship_setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/<default>')..'refs/heads/<default>'" \
    "a PR-path fallback degraded to a local base instead of requiring origin"
  pass "fm-brief.sh: an unresolved scout fallback degrades to a local default before blocking"
}

# The scout runtime fallback must not block where the same scaffold's resolved
# path degrades. A clone whose origin/HEAD names a branch with a pruned or
# never-fetched tracking ref is the case: the single permitted fetch is what
# restores that ref, so verification must follow it, and the local degradation
# must name the branch origin/HEAD points at rather than only main/master.
# shellcheck disable=SC2016 # Literal brief text: the backticks and $(...) must stay unexpanded.
test_scout_fallback_fetches_before_verifying_and_degrades_like_the_resolved_path() {
  local home pruned resolved_setup unresolved_setup fetch_line verify_line
  home="$TMP_ROOT/scout-pruned-home"
  pruned="$BRIEF_PROJECTS/pruned"
  mkdir -p "$home/data"

  fm_git_init_commit "$pruned"
  git -C "$pruned" branch -M develop
  fm_git_add_origin "$pruned" "$pruned.origin.git"
  git -C "$pruned" fetch --quiet origin
  git -C "$pruned" remote set-head origin --auto >/dev/null
  git -C "$pruned" update-ref -d refs/remotes/origin/develop
  [ "$(git -C "$pruned" symbolic-ref --short refs/remotes/origin/HEAD)" = "origin/develop" ] \
    || fail "fixture origin/HEAD does not name develop"
  git -C "$pruned" rev-parse --verify --quiet refs/heads/develop >/dev/null \
    || fail "fixture lost its local develop branch"
  git -C "$pruned" rev-parse --verify --quiet refs/remotes/origin/develop >/dev/null 2>&1 \
    && fail "fixture still has the origin/develop tracking ref"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pruned-resolved pruned --scout >/dev/null 2>&1 \
    || fail "a resolvable scout label must scaffold against a pruned tracking ref"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pruned-unresolved comms --scout >/dev/null 2>&1 \
    || fail "an unresolvable scout label must scaffold against the same state"
  resolved_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/pruned-resolved/brief.md")
  unresolved_setup=$(sed -n '/^# Setup$/,/^# Rules$/p' "$home/data/pruned-unresolved/brief.md")

  assert_contains "$resolved_setup" "git rev-list --count \$(git merge-base HEAD 'refs/heads/develop')..'refs/heads/develop'" \
    "the resolved scout path stopped degrading to the local default branch"

  fetch_line=$(printf '%s\n' "$unresolved_setup" | grep -n -F -m1 'git fetch origin --quiet' | cut -d: -f1)
  verify_line=$(printf '%s\n' "$unresolved_setup" | grep -n -F -m1 "git rev-parse --verify 'refs/remotes/origin/<default>'" | cut -d: -f1)
  [ -n "$fetch_line" ] || fail "the scout fallback dropped its single fetch"
  [ -n "$verify_line" ] || fail "the scout fallback dropped its origin tracking-ref verification"
  [ "$fetch_line" -lt "$verify_line" ] \
    || fail "the scout fallback verifies origin/<default> before the fetch that would create it"

  assert_contains "$unresolved_setup" 'that ref with the leading `refs/remotes/origin/` dropped IS `<default>`' \
    "the scout local degradation does not name the branch origin/HEAD points at"
  assert_contains "$unresolved_setup" 'Only when that ref is absent entirely may `<default>` be the local `main` or `master`' \
    "the scout local degradation offered main/master without gating on an absent origin/HEAD"
  assert_not_contains "$unresolved_setup" 'This task lands locally' \
    "the scout fallback claimed the task lands locally"
  pass "fm-brief.sh: the scout fallback fetches before verifying and degrades like its resolved path"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's merge authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$brief" \
    "no-mistakes DOD must require --intent to be the Captain's intent subsection"
  assert_grep "plus any later words the captain actually said" "$brief" \
    "no-mistakes DOD must allow later captain words in --intent"
  assert_grep "Do not include \`## Firstmate spec\`" "$brief" \
    "no-mistakes DOD must keep Firstmate spec out of --intent"
  assert_grep "or your own decisions and tradeoffs" "$brief" \
    "no-mistakes DOD must keep worker tradeoffs out of --intent"
  assert_grep "This replaces the no-mistakes skill's advice to enrich \`--intent\`" "$brief" \
    "no-mistakes DOD must override the external skill's enrich-with-decisions guidance"
  # A bare reference cannot preserve the captain's ask, so the rendered DOD states
  # the self-sufficiency rule and requires referenced material to be resolved into
  # its substance.
  assert_grep "The \`--intent\` string you pass must be self-sufficient" "$brief" \
    "no-mistakes DOD must require a self-sufficient --intent string"
  assert_grep "write the substance of the referenced items into \`--intent\`" "$brief" \
    "no-mistakes DOD must tell the worker to resolve report, decision, and PR references into substance"

  # The --yes ban is a fleet-wide prohibition, not a preference, and it must not
  # claim an enforcement the tool does not provide: this is instruction only.
  assert_grep "NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide." "$brief" \
    "no-mistakes DOD must state the --yes ban as a prohibition"
  assert_grep "answering your own ask-user finding is a hard rule violation" "$brief" \
    "no-mistakes DOD must say why --yes is banned"
  assert_no_grep "Avoid \`--yes\`" "$brief" \
    "no-mistakes DOD still states the --yes ban as a preference"
  assert_no_grep "no-mistakes refuses" "$brief" \
    "no-mistakes DOD must not claim the tool itself refuses --yes"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose and bans --yes outright"
}

test_ask_user_escalation_format() {
  local home id brief mode other_id other_brief
  home="$TMP_ROOT/ask-user-home"
  mkdir -p "$home/data"
  id="brief-ask-user-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # A no-mistakes ask-user gate must escalate its ask-user findings as one status
  # event plus one verbatim findings snapshot file, using that same shape even
  # for a single finding, never paraphrased into the status line.
  assert_grep "escalate all ask-user findings as one event plus one snapshot file" "$brief" \
    "ship rule 6 lost the one-event-plus-snapshot-file ask-user contract"
  assert_grep "using that same shape even when the gate holds only a single ask-user finding" "$brief" \
    "ship rule 6 must require the same shape for a single finding"
  assert_grep "write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority)" "$brief" \
    "ship rule 6 must limit the verbatim axi slice to ask-user findings"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks and the key/findings/file tokens must stay literal
  assert_grep 'needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='"$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must render the exact needs-decision ask-user status line"
  assert_grep "$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must point the snapshot file under this task's own data directory"
  assert_grep "The status line only points at the file; it never restates or summarizes a finding's content." "$brief" \
    "ship rule 6 must forbid paraphrasing ask-user findings into the status line"

  # The DOD's own ask-user paragraph must point back at rule 6's format
  # (one-owner rule) rather than restating or bare-citing it.
  assert_grep "escalate to firstmate using rule 6's ask-user format" "$brief" \
    "no-mistakes DOD ask-user paragraph must point at rule 6's format instead of a bare citation"
  assert_no_grep "escalate to firstmate (rule 6) and stop." "$brief" \
    "no-mistakes DOD ask-user paragraph still uses the old bare rule-6 pointer"

  other_id="brief-no-ask-user-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --scout >/dev/null 2>&1
  other_brief="$home/data/$other_id/brief.md"
  assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
    "scout brief received a no-mistakes-only decision case"

  for mode in direct-PR local-only; do
    other_id="brief-no-ask-user-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --mode "$mode" >/dev/null 2>&1
    other_brief="$home/data/$other_id/brief.md"
    assert_no_grep "nm-<run>-findings.txt" "$other_brief" \
      "$mode brief received a no-mistakes-only escalation format"
    assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
      "$mode brief received a no-mistakes-only decision case"
  done

  pass "fm-brief.sh: no-mistakes ask-user findings use one event plus a verbatim snapshot"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# Regression (issue #2575): AGENTS.md section 11 and this script's own help tell
# firstmate to fill `{TASK}` and `{FIRSTMATE_SPEC}`. The unguarded Herdr gate used
# to quote `{TASK}` in its own prose, so that documented global replace spliced
# the whole task body into the middle of the gate's sentence - silently
# destroying the one contract that exists precisely because the scaffold cannot
# see the task text. Each placeholder must exist only at its genuine fill site,
# so the documented fill leaves the gate intact and each body appears once.
test_documented_global_replace_leaves_the_herdr_gate_intact() {
  local home id brief kind count content filled body spec
  home="$TMP_ROOT/task-fill-site-home"
  mkdir -p "$home/data"
  body='Restart the herdr session, then profile it'
  spec='Use the isolated lab helper for every lifecycle call'
  for kind in ship scout; do
    id="brief-fill-site-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind brief was not scaffolded"
    count=$(grep -c -F '{TASK}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {TASK} fill site, found $count"
    count=$(grep -c -F '{FIRSTMATE_SPEC}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {FIRSTMATE_SPEC} fill site, found $count"
    content=$(cat "$brief")
    filled=${content//'{TASK}'/$body}
    filled=${filled//'{FIRSTMATE_SPEC}'/$spec}
    count=$(printf '%s\n' "$filled" | grep -c -F "$body")
    [ "$count" = 1 ] \
      || fail "$kind brief: the documented {TASK} replace duplicated the intent body $count times"
    count=$(printf '%s\n' "$filled" | grep -c -F "$spec")
    [ "$count" = 1 ] \
      || fail "$kind brief: the {FIRSTMATE_SPEC} replace duplicated the spec body $count times"
    printf '%s\n' "$filled" | grep -qF 'this scaffold cannot inspect the task text' \
      || fail "$kind brief: the Herdr safety gate did not survive the documented fill"
  done
  pass "fm-brief.sh: the documented {TASK} and {FIRSTMATE_SPEC} fills cannot corrupt the Herdr safety gate"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep '# The captain and the parent channel' "$brief" \
    "secondmate charter lost the parent-channel section"
  assert_grep 'Nobody reads this chat' "$brief" \
    "secondmate charter no longer says the chat is unread"
  assert_grep 'in this home it IS the captain' "$brief" \
    "secondmate charter no longer names the parent channel as the captain"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'bin/fm-secondmate-report.sh <verb> <corr_id> <note>' "$brief" \
    "secondmate charter lost the mechanical helper invocation"
  assert_grep 'do not pass a status path' "$brief" \
    "secondmate charter still tells the mate to pass a hand path to the helper"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, work ready for review, or work you landed' "$brief" \
    "secondmate charter lost decisions, blockers, failures, ready outcomes, or landed work"
  # Under standing merge authority nothing is ever "ready for review", so the
  # landed merge is the trigger a charter without this line silently omits.
  assert_grep 'a merge you performed yourself under standing merge authority and one the captain merged on the forge' "$brief" \
    "secondmate charter did not name a landed merge as a reporting trigger"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`captain-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared captain-call policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "you may host the Lavish review loop yourself" "$brief" \
    "scout brief must mention the option to host a Lavish review loop"
  assert_grep "## Captain's intent" "$brief" "scout brief missing Captain's intent subsection"
  assert_grep "## Firstmate spec" "$brief" "scout brief missing Firstmate spec subsection"
  assert_grep "{FIRSTMATE_SPEC}" "$brief" "scout brief missing the spec placeholder"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  assert_no_grep "## Captain's intent" "$brief" \
    "secondmate charter must not grow ship/scout Task subsections"
  assert_no_grep "{FIRSTMATE_SPEC}" "$brief" \
    "secondmate charter must not carry the Firstmate spec placeholder"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_base_freshness_check_is_resolved_and_mode_aware
test_resolved_default_branch_is_shell_quoted_in_the_freshness_command
test_resolved_default_branch_survives_a_backtick_in_its_name
test_runtime_fallback_ref_stays_one_shell_word
test_emitted_base_command_survives_a_same_named_tag
test_unresolvable_repo_label_still_mandates_the_base_check
test_missing_origin_head_never_relabels_the_current_branch
test_non_root_directory_never_resolves_to_its_enclosing_repo
test_absent_local_ref_for_origin_default_never_substitutes_another_branch
test_ambiguous_origin_head_still_resolves_the_real_default_branch
test_runtime_local_default_rule_resolves_a_local_branch_not_a_tracking_ref
test_local_only_rule_names_the_resolved_default_branch
test_scout_local_fallback_uses_kind_neutral_wording
test_unresolved_scout_fallback_degrades_to_a_local_default
test_scout_fallback_fetches_before_verifying_and_degrades_like_the_resolved_path
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ask_user_escalation_format
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_documented_global_replace_leaves_the_herdr_gate_intact
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
