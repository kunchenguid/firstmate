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

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

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

  for id_mode in "brief-nomistakes-a1:review-PR" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
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
    assert_grep "genuinely different authorized diagnostic or recovery path" "$brief" \
      "$id: brief missing evidence-based retry progression"
    assert_grep "blocked: {what remains, what you tried, and what is needed next}" "$brief" \
      "$id: brief missing concrete hard-block reporting"
    assert_grep "does not replace progress on the goal in your task brief" "$brief" \
      "$id: brief lets an empty inbox replace goal progress"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: review-PR/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# review-prod-only row is the conditional registry policy: it is never a task
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
unknown mode value|--mode nope|must be one of review-PR, direct-PR, local-only
conditional policy is not a task mode|--mode review-prod-only|resolve it to review-PR or direct-PR at intake
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
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode review-PR >/dev/null 2>&1 \
    || fail "explicit review-PR brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=review-PR" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "bin/fm-native-review.sh" "$brief" \
    "explicit review-PR brief did not render the native-review trigger"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's merge authority and never reaches the worker, and a scout
# carries no delivery contract. Each must refuse rather than accept and
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
ROWS
  pass "fm-brief.sh: --yolo and scout --mode are refused, never silently dropped"
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
    "local-only brief must not include the review-PR --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the review-PR --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# The generated review contract stays compact while naming its executable owner.
test_native_review_dod_wording() {
  local home id brief bytes
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode review-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "bin/fm-native-review.sh" "$brief" \
    "review-PR brief did not route review through its executable owner"
  assert_grep "immutable Captain intent and Firstmate acceptance" "$brief" \
    "review-PR brief did not require the task contract in review"
  assert_grep "complete final diff again" "$brief" \
    "review-PR brief did not require final re-review after corrections"
  bytes=$(wc -c < "$brief" | tr -d ' ')
  [ "$bytes" -lt 7000 ] || fail "review-PR brief did not remain bounded: $bytes bytes"
  assert_present "$ROOT/bin/fm-native-review.sh" \
    "the generated trigger points to no executable review owner"
  pass "fm-brief.sh: review-PR brief keeps a bounded native-review contract"
}

test_ask_user_escalation_format() {
  local home id brief mode other_id other_brief
  home="$TMP_ROOT/ask-user-home"
  mkdir -p "$home/data"
  id="brief-ask-user-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode review-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  assert_grep "Ask-user findings are never yours to answer" "$brief" \
    "review-PR brief did not preserve finding authority"
  assert_no_grep "nm-<run>-findings.txt" "$brief" \
    "generated brief duplicated the conditional ask-user wire format"

  other_id="brief-no-ask-user-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --scout >/dev/null 2>&1
  other_brief="$home/data/$other_id/brief.md"
  assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
    "scout brief received a review-PR-only decision case"

  for mode in direct-PR local-only; do
    other_id="brief-no-ask-user-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --mode "$mode" >/dev/null 2>&1
    other_brief="$home/data/$other_id/brief.md"
    assert_no_grep "nm-<run>-findings.txt" "$other_brief" \
      "$mode brief received a review-PR-only escalation format"
    assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
      "$mode brief received a review-PR-only decision case"
  done

  pass "fm-brief.sh: review-PR ask-user mechanics remain behind the precise skill trigger"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode review-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "follow \`$ROOT/bin/fm-ensure-agents-md.sh\`'s self-governance contract" "$brief" \
    "project-memory contract no longer defers to the ensure helper"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode review-PR --herdr-lab >/dev/null 2>&1
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
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode review-PR >/dev/null 2>&1
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
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode review-PR >/dev/null 2>&1
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




test_herdr_lab_contract_applies_to_scouts() {
  local home brief
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"
  pass "fm-brief.sh: Herdr lab contract covers scouts"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode review-PR >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
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

test_scout_loads_captain_hold_policy() {
  local home scout
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report" "$scout" \
    "scout brief did not cross-reference report completion"
  pass "fm-brief.sh: investigation completion loads the shared decision policy"
}

test_scout_uses_report_and_chat_without_visual_dependency() {
  local home brief
  home="$TMP_ROOT/scout-report-chat"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scout-report-chat alpha --scout >/dev/null \
    || fail "scout scaffold failed without a visual dependency"
  brief="$home/data/scout-report-chat/brief.md"
  assert_grep "Deliver findings through the durable report and ordinary chat" "$brief" \
    "scout brief did not select the supported report and chat surfaces"
  assert_no_grep "Lavish" "$brief" "scout brief retained the retired visual dependency"
  pass "fm-brief.sh: scouts use durable reports and ordinary chat"
}

# Scout paths still scaffold well-formed briefs.
test_scout_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "## Captain's intent" "$brief" "scout brief missing Captain's intent subsection"
  assert_grep "## Firstmate spec" "$brief" "scout brief missing Firstmate spec subsection"
  assert_grep "{FIRSTMATE_SPEC}" "$brief" "scout brief missing the spec placeholder"
  assert_grep "Report existence is not objective acceptance" "$brief" \
    "scout brief treats report existence as goal acceptance"
  assert_grep "archive completed research automatically after the unresolved-decision gate" "$brief" \
    "scout brief lost automatic accepted-research archival"
  pass "fm-brief: scout code path scaffolds a well-formed brief"
}

test_worker_role_scope() {
  local kind home brief
  home="$TMP_ROOT/worker-role"
  for kind in review-PR direct-PR local-only scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" arbitrary-project-name --scout >/dev/null || fail "scout scaffold failed"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" arbitrary-project-name --mode "$kind" >/dev/null || fail "$kind scaffold failed"
    fi
    brief="$home/data/$kind/brief.md"
    assert_no_grep '# Current worker role contract' "$brief" "$kind scaffolded a second owner of the role scope fm-spawn.sh delivers"
  done
  pass "fm-brief: scaffolds leave the worker role scope to the launch boundary"
}

test_worker_role_scope
test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_native_review_dod_wording
test_ask_user_escalation_format
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_documented_global_replace_leaves_the_herdr_gate_intact
test_herdr_lab_contract_applies_to_scouts
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_loads_captain_hold_policy
test_scout_scaffold
test_scout_uses_report_and_chat_without_visual_dependency
