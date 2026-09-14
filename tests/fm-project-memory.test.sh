#!/usr/bin/env bash
# Behavior tests for bin/fm-project-memory.sh.
#
# The load-bearing guarantee is that scanning a source checkout leaves it byte
# for byte as it was: that directory is the captain's live working state and
# routinely holds uncommitted work, so the read-only property is asserted
# against a real repository rather than inferred from the script's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-memory)

git_q() { git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

# A home with a project clone and a separate source checkout that shares its
# history, which is the real shape: the same commit on both sides with the
# knowledge sitting outside git on one of them.
make_world() {  # <name>
  local name=$1 world="$TMP_ROOT/$1"
  mkdir -p "$world/home/config" "$world/home/data" "$world/home/projects"
  git_q init -q --bare "$world/upstream.git"
  git_q -C "$world/upstream.git" symbolic-ref HEAD refs/heads/main
  git_q init -q "$world/source"
  printf '# %s\n' "$name" >"$world/source/README.md"
  git_q -C "$world/source" add README.md
  git_q -C "$world/source" commit -qm initial
  git_q -C "$world/source" branch -M main
  git_q -C "$world/source" remote add origin "$world/upstream.git"
  git_q -C "$world/source" push -q -u origin main
  git_q clone -q "$world/upstream.git" "$world/home/projects/demo"
  printf '%s\n' "$world"
}

# Publish the source checkout's current main, so a fixture's setup commits are
# not themselves reported as work that never reached a remote.
publish() {  # <world>
  git_q -C "$1/source" push -q origin main
}

run_scan() {  # <world> [extra args...]
  local world=$1
  shift
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" scan demo "$@" 2>&1
}

# The recorded source checkout is the only thing a scan compares against.
record_source() {  # <world> [source set options...]
  local world=$1 out
  shift
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/source" "$@" 2>&1) ||
    fail "source set failed: $out"
}

# Portable mtime, the same Linux/macOS split bin/fm-supervision-lib.sh handles.
mtime_of() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# A fingerprint of everything the scan could plausibly disturb: every path in
# the working tree with its size, and every loose file in .git with its size and
# timestamp, so an index refresh the scan should never cause would show up here.
fingerprint() {  # <dir>
  (cd "$1" && find . -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r entry; do
    if [ -f "$entry" ] && [ ! -L "$entry" ]; then
      printf '%s f %s\n' "$entry" "$(wc -c <"$entry" | tr -d ' ')"
    else
      printf '%s other\n' "$entry"
    fi
  done)
  find "$1/.git" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r entry; do
    printf '%s %s %s\n' "${entry#"$1"/}" "$(wc -c <"$entry" | tr -d ' ')" "$(mtime_of "$entry")"
  done
}

# A source-canonical home is a folder the captain works in while firstmate has
# work going there, so "is anyone in there right now" has to be answerable
# before anything writes. Two independent signals, either one enough.
# Push every mtime in a fixture well into the past, so "nothing changed
# recently" is a fact about the fixture rather than a race with how fast the
# suite runs.
age_tree() {  # <dir>
  find "$1" -exec touch -t 202001010000.00 {} + 2>/dev/null || true
}

test_activity_reports_a_folder_nobody_is_touching_as_quiet() {
  local world out rc
  world=$(make_world quiet)
  age_tree "$world/source"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a folder nobody touched did not read as quiet"
  assert_contains "$out" "ACTIVITY: quiet" "the report did not say the folder was quiet"
  assert_contains "$out" "GIT_OPERATION: none" "the report did not clear the git signal"
  pass "fm-project-memory.sh: a folder nobody is touching reads as quiet"
}

test_activity_reports_a_recent_write_as_active() {
  local world out rc
  world=$(make_world busy)
  age_tree "$world/source"
  mkdir -p "$world/source/active/repro_weekday"
  printf 'his own test run\n' >"$world/source/active/repro_weekday/out.json"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a folder someone just wrote in did not read as active"
  assert_contains "$out" "ACTIVITY: active" "the report did not say the folder was in use"
  assert_contains "$out" "active/repro_weekday/out.json" "the report did not name what it saw change"
  pass "fm-project-memory.sh: a recent write reads as active and names the file"
}

test_activity_reports_a_git_operation_in_flight() {
  local world out rc gitdir
  world=$(make_world inflight)
  gitdir=$(git -C "$world/source" rev-parse --absolute-git-dir)
  : >"$gitdir/index.lock"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" --git-only 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a git operation in flight did not read as active"
  assert_contains "$out" "GIT_OPERATION: index-lock" "the in-flight git operation was not named"
  rm -f "$gitdir/index.lock"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" --git-only 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "the git-only signal stayed active after the operation ended"
  pass "fm-project-memory.sh: an in-flight git operation reads as active on its own"
}

test_scan_never_writes_to_the_source_checkout() {
  local world before after out
  world=$(make_world readonly)
  printf 'analysis\n' >"$world/source/docs-note.md"
  mkdir -p "$world/source/scratchdir"
  printf 'x\n' >"$world/source/scratchdir/thing.txt"
  printf 'edited\n' >>"$world/source/README.md"
  record_source "$world"
  before=$(fingerprint "$world/source")
  out=$(run_scan "$world")
  after=$(fingerprint "$world/source")
  [ "$before" = "$after" ] || fail "scan modified the source checkout"$'\n'"$out"
  assert_absent "$world/source/.git/index.lock" "scan left an index lock in the source checkout"
  pass "fm-project-memory.sh: scan leaves the source checkout byte-identical"
}

test_scan_reports_uncommitted_knowledge_and_excluded_agent_memory() {
  local world out
  world=$(make_world findings)
  printf 'audit of 500 conversations\n' >"$world/source/AGENTS.md"
  mkdir -p "$world/source/docs"
  printf 'findings\n' >"$world/source/docs/audit.md"
  printf 'CLAUDE.md\n.claude/\nherramientas/\n' >"$world/source/.gitignore"
  git_q -C "$world/source" add .gitignore
  git_q -C "$world/source" commit -qm ignore
  publish "$world"
  printf 'the fuller operational context\n' >"$world/source/CLAUDE.md"
  mkdir -p "$world/source/.claude" "$world/source/herramientas"
  printf '{}\n' >"$world/source/.claude/settings.json"
  printf 'tool\n' >"$world/source/herramientas/replay.py"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "AGENTS.md" "uncommitted AGENTS.md was not reported"
  assert_contains "$out" "docs/" "the uncommitted knowledge directory was not reported"
  assert_contains "$out" "CLAUDE.md (excluded by" "excluded agent memory was not reported"
  assert_contains "$out" ".claude/ (excluded by" "excluded agent-memory directory was not reported"
  assert_contains "$out" "herramientas/" "ignored directory holding material was not reported"
  assert_contains "$out" "VERDICT: divergent - knowledge did not travel" "a real knowledge gap did not read as divergent"
  pass "fm-project-memory.sh: scan reports uncommitted knowledge and excluded agent memory"
}

test_scan_reports_a_clean_project_as_parity() {
  local world out
  world=$(make_world clean)
  mkdir -p "$world/source/media"
  printf 'binary-ish\n' >"$world/source/media/clip.bin"
  printf 'media/\n' >"$world/source/.gitignore"
  git_q -C "$world/source" add .gitignore
  git_q -C "$world/source" commit -qm ignore
  publish "$world"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "VERDICT: parity" "a project whose knowledge travelled did not read as parity"
  assert_contains "$out" "media/" "ignored working material was not listed for context"
  pass "fm-project-memory.sh: working material alone reads as parity, not as a gap"
}

# A knowledge document the project's own ignore rules single out reaches no
# clone at all, and it is the one case no other pass sees: porcelain without
# --ignored never lists it, and the agent-memory scan only knows a fixed set of
# names. Reading that as parity is the worst answer this command can give -
# parity is the signal the intake uses to decide there is nothing to recover.
test_scan_reports_a_knowledge_file_the_project_ignores() {
  local world out
  world=$(make_world ignoredknowledge)
  mkdir -p "$world/source/docs"
  printf 'docs/*-internal.md\n' >"$world/source/.gitignore"
  printf 'the public readme\n' >"$world/source/docs/public.md"
  git_q -C "$world/source" add .gitignore docs/public.md
  git_q -C "$world/source" commit -qm docs
  publish "$world"
  printf 'the production audit of 500 conversations\n' >"$world/source/docs/audit-internal.md"
  printf 'the production bug findings\n' >"$world/source/docs/bugs-internal.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "IGNORED_KNOWLEDGE: 2" "the ignored knowledge documents were not reported"
  assert_contains "$out" "docs/audit-internal.md" "the report did not name the production audit"
  assert_contains "$out" "docs/bugs-internal.md" "the report did not name the bug findings"
  assert_not_contains "$out" "VERDICT: parity" "knowledge that stayed behind still read as parity"
  assert_contains "$out" "VERDICT: divergent" "the verdict did not call the leak what it is"
  assert_not_contains "$out" "KNOWLEDGE_GAP: 0" "the ignored knowledge documents did not count in the gap"
  pass "fm-project-memory.sh: a knowledge file the project ignores is reported and counts in the gap"
}

# The fold that keeps one ignored tree to one line has to keep holding: a
# node_modules/ that git expands into individual entries must not arrive as
# hundreds of ignored knowledge files.
test_documents_inside_an_ignored_tree_stay_folded_into_one_line() {
  local world out
  world=$(make_world foldedtree)
  mkdir -p "$world/source/terceros/pkg/docs"
  printf 'terceros/\n' >"$world/source/.gitignore"
  printf 'third-party readme\n' >"$world/source/terceros/pkg/README.md"
  printf 'third-party guide\n' >"$world/source/terceros/pkg/docs/guide.md"
  git_q -C "$world/source" add .gitignore
  git_q -C "$world/source" commit -qm ignore
  publish "$world"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "IGNORED_KNOWLEDGE: none" "a third-party tree was reported file by file as knowledge"
  assert_contains "$out" "terceros/" "the ignored tree was not listed for context"
  assert_contains "$out" "VERDICT: parity" "a third-party tree alone turned the verdict into a leak"
  pass "fm-project-memory.sh: documents inside an ignored tree stay folded into one line"
}

# An ignore rule naming a whole knowledge directory leaks exactly what a rule
# naming one document leaks. The classifier already knows `notes/` from
# `vendor/`, so the shape of the rule must not decide whether the verdict sees
# it: the one thing a false parity costs is the intake deciding there is
# nothing to recover.
test_an_ignored_knowledge_directory_counts_as_a_leak_not_as_material() {
  local world out
  world=$(make_world ignoreddir)
  mkdir -p "$world/source/notes" "$world/source/herramientas"
  printf 'notes/\nherramientas/\n' >"$world/source/.gitignore"
  git_q -C "$world/source" add .gitignore
  git_q -C "$world/source" commit -qm ignore
  publish "$world"
  printf 'the production audit of 500 conversations\n' >"$world/source/notes/audit.md"
  printf 'the production bug findings\n' >"$world/source/notes/bugs.md"
  printf 'tool\n' >"$world/source/herramientas/replay.py"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "IGNORED_KNOWLEDGE: 1" "the ignored knowledge directory was not reported as knowledge"
  assert_contains "$out" "notes/ (2 files)" "the report did not name the ignored knowledge directory"
  assert_not_contains "$out" "KNOWLEDGE_GAP: 0" "the ignored knowledge directory did not count in the gap"
  assert_not_contains "$out" "VERDICT: parity" "a whole knowledge directory left behind still read as parity"
  assert_contains "$out" "IGNORED_DIRS_WITH_MATERIAL: 1" "the ignored tooling directory stopped being working material"
  assert_contains "$out" "herramientas/" "the ignored tooling directory was not listed for context"
  pass "fm-project-memory.sh: an ignored knowledge directory counts as a leak, not as material"
}

# The captain names his files in Spanish. git C-quotes every non-ASCII path by
# default, and the quotes make an accented document fail every extension and
# directory test the classifier runs, so the scan would be blind to exactly the
# documents this capability exists for. Each accented path here has an ASCII
# twin that must land in the same category.
test_an_accented_path_is_classified_like_its_ascii_twin() {
  local world out
  world=$(make_world accented)
  mkdir -p "$world/source/docs"
  printf 'docs/*-interno.md\n' >"$world/source/.gitignore"
  printf 'the public one\n' >"$world/source/docs/publico.md"
  git_q -C "$world/source" add .gitignore docs/publico.md
  git_q -C "$world/source" commit -qm docs
  publish "$world"
  printf 'the simulator realism analysis\n' >"$world/source/docs/análisis-simulador.md"
  printf 'the plain twin\n' >"$world/source/docs/analisis-simulador.md"
  printf 'the production audit\n' >"$world/source/docs/auditoría-interno.md"
  printf 'the plain twin\n' >"$world/source/docs/auditoria-interno.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 2" "the accented analysis was not counted as knowledge beside its ASCII twin"
  assert_contains "$out" "docs/análisis-simulador.md" "the report did not name the accented document readably"
  assert_contains "$out" "IGNORED_KNOWLEDGE: 2" "the accented ignored audit was not counted beside its ASCII twin"
  assert_contains "$out" "docs/auditoría-interno.md" "the report did not name the accented ignored document readably"
  assert_not_contains "$out" '\303' "the report printed a C-quoted path instead of the real name"
  assert_not_contains "$out" "VERDICT: parity" "knowledge with accented names still read as parity"
  pass "fm-project-memory.sh: an accented path is classified like its ASCII twin"
}

# git folds a wholly untracked directory into one entry by default, and the
# classifier reading `informes/` never sees the audit inside it. The proof that
# the fold - not the content - was deciding: the same two documents counted in
# the gap as soon as an unrelated tracked file sat beside them.
test_an_untracked_knowledge_directory_is_classified_by_what_is_inside_it() {
  local world out
  world=$(make_world untrackeddir)
  mkdir -p "$world/source/informes"
  printf 'the production audit of 500 conversations\n' >"$world/source/informes/audit.md"
  printf 'the production bug findings\n' >"$world/source/informes/bugs.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 2" "the documents inside the untracked directory were never classified"
  assert_contains "$out" "informes/audit.md" "the report did not name the production audit"
  assert_contains "$out" "informes/bugs.md" "the report did not name the bug findings"
  assert_not_contains "$out" "KNOWLEDGE_GAP: 0" "an untracked knowledge directory did not count in the gap"
  assert_not_contains "$out" "VERDICT: parity" "a whole untracked knowledge directory still read as parity"
  pass "fm-project-memory.sh: an untracked knowledge directory is classified by what is inside it"
}

# A document does not stop being knowledge because its name looks like build
# output: a conversation dump under docs/ is exactly what this scan exists to
# find, and counted as scratch it would appear in no category at all.
test_a_knowledge_document_with_a_scratch_name_is_still_knowledge() {
  local world out
  world=$(make_world scratchname)
  mkdir -p "$world/source/docs"
  printf 'the conversation dump behind the audit\n' >"$world/source/docs/conversaciones.log"
  printf 'plain build noise\n' >"$world/source/run.log"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "docs/conversaciones.log" "a knowledge document with a scratch name was swallowed by scratch"
  assert_not_contains "$out" "KNOWLEDGE_GAP: 0" "the conversation dump did not count in the gap"
  assert_not_contains "$out" "run.log
" "ordinary build noise stopped being scratch"
  pass "fm-project-memory.sh: a knowledge document with a scratch name is still knowledge"
}

# A dependency's own README is the dependency's, not the captain's. Listing
# every untracked path one by one must not turn a node_modules/ the project has
# not ignored yet into a leak: a false `divergent` buries the real documents
# under files of no value, and the listing is capped.
test_documentation_inside_a_dependency_tree_is_not_project_knowledge() {
  local world out
  world=$(make_world deptree)
  mkdir -p "$world/source/node_modules/react" "$world/source/node_modules/lodash" "$world/source/docs"
  printf 'react readme\n' >"$world/source/node_modules/react/README.md"
  printf 'lodash readme\n' >"$world/source/node_modules/lodash/README.md"
  printf 'the production audit of 500 conversations\n' >"$world/source/docs/audit.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_not_contains "$out" "node_modules" "a dependency tree was listed as the project's own knowledge"
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 1" "the dependency READMEs were counted as project knowledge"
  assert_contains "$out" "docs/audit.md" "the captain's own document was not reported"
  pass "fm-project-memory.sh: documentation inside a dependency tree is not project knowledge"
}

# A vendored dependency tree is the dependency's, not the captain's, whether or
# not the project has got round to ignoring it. Counting it inflates the gap and
# fills the bounded listing with files of no value to him.
test_a_vendored_tree_is_not_project_knowledge() {
  local world out
  world=$(make_world vendored)
  mkdir -p "$world/source/vendor/github.com/pkg/errors" "$world/source/docs"
  printf 'third-party readme\n' >"$world/source/vendor/github.com/pkg/errors/README.md"
  printf 'module list\n' >"$world/source/vendor/modules.txt"
  printf 'the production audit of 500 conversations\n' >"$world/source/docs/audit.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_not_contains "$out" "vendor/" "a vendored tree was reported as the project's own knowledge"
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 1" "the vendored files were counted as project knowledge"
  assert_contains "$out" "docs/audit.md" "the captain's own document was not reported"
  pass "fm-project-memory.sh: a vendored tree is not project knowledge"
}

# Rule one on its own, with nothing to fold: everything fits, so the only thing
# under test is the order. A plain text file sorts first in every byte order
# there is, and it still has to come after the project's own knowledge surface.
test_the_listing_names_the_knowledge_surface_before_anything_else() {
  local world out at_text at_audit at_agents
  world=$(make_world valueorder)
  mkdir -p "$world/source/docs"
  printf 'loose notes\n' >"$world/source/.notas.txt"
  printf 'agent memory\n' >"$world/source/AGENTS.md"
  printf 'the production audit of 500 conversations\n' >"$world/source/docs/audit.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 3" "the count stopped being complete"
  assert_not_contains "$out" "more files)" "a listing that fits folded something anyway"
  at_text=$(printf '%s\n' "$out" | grep -n '\.notas\.txt' | head -1 | cut -d: -f1)
  at_audit=$(printf '%s\n' "$out" | grep -n 'docs/audit\.md' | head -1 | cut -d: -f1)
  at_agents=$(printf '%s\n' "$out" | grep -n '^    AGENTS\.md$' | head -1 | cut -d: -f1)
  [ -n "$at_text" ] && [ -n "$at_audit" ] && [ -n "$at_agents" ] ||
    fail "the listing did not name all three paths: $out"
  [ "$at_agents" -lt "$at_text" ] ||
    fail "a loose text file was listed ahead of the project's agent memory"
  [ "$at_audit" -lt "$at_text" ] ||
    fail "a loose text file was listed ahead of the production audit"
  pass "fm-project-memory.sh: the listing names the knowledge surface before anything else"
}

# How many names one directory is allowed to contribute, asserted here as the
# contract it is rather than re-derived from the fixtures below.
names_from() {  # <output> <directory prefix>
  printf '%s\n' "$1" | grep -c "^    $2" || true
}

# Rule two on its own, and the case the ordering cannot resolve: all three paths
# are knowledge of the same rank, the session logs sort first AND outnumber the
# cap. Only the fixed per-directory ceiling keeps the two documents visible.
test_no_single_directory_takes_every_listing_slot() {
  local world out i
  world=$(make_world onedirhog)
  mkdir -p "$world/source/.claude/history" "$world/source/docs"
  i=1
  while [ "$i" -le 60 ]; do
    printf '{"turn":%s}\n' "$i" >"$world/source/.claude/history/session-$i.jsonl"
    i=$((i + 1))
  done
  printf 'agent memory an earlier worker wrote\n' >"$world/source/AGENTS.md"
  printf 'the production audit of 500 conversations\n' >"$world/source/docs/audit.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 62" "the count stopped being complete"
  assert_equals "5" "$(names_from "$out" '\.claude/history/session-')" \
    "the crowded directory contributed more names than the ceiling allows"
  assert_contains "$out" "
    AGENTS.md" "a crowded directory of the same rank buried the project's agent memory"
  assert_contains "$out" "docs/audit.md" "a crowded directory of the same rank buried the production audit"
  assert_contains "$out" ".claude/history/ (55 more files)" \
    "the crowded directory did not give up its excess to one counted line"
  assert_contains "$out" "... and 55 more (55 of them knowledge)" \
    "the omission line did not say how much of what it hides is knowledge"
  pass "fm-project-memory.sh: no single directory takes every listing slot"
}

# The same rule where there are more directories than slots, which is the shape
# that used to have no ceiling at all: the listing runs out of room part way
# through, and the agent memory still has to be named rather than lost behind
# forty session logs.
test_more_directories_than_slots_still_names_the_agent_memory() {
  local world out i
  world=$(make_world manydirs)
  mkdir -p "$world/source/.claude/history"
  i=1
  while [ "$i" -le 60 ]; do
    printf '{"turn":%s}\n' "$i" >"$world/source/.claude/history/session-$i.jsonl"
    i=$((i + 1))
  done
  printf 'agent memory an earlier worker wrote\n' >"$world/source/AGENTS.md"
  i=1
  while [ "$i" -le 41 ]; do
    mkdir -p "$world/source/docs/area-$i"
    printf 'the findings for area %s\n' "$i" >"$world/source/docs/area-$i/nota.md"
    i=$((i + 1))
  done
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 102" "the count stopped being complete"
  assert_equals "5" "$(names_from "$out" '\.claude/history/session-')" \
    "the crowded directory took the listing while other directories waited"
  assert_contains "$out" "
    AGENTS.md" "the project's agent memory was lost behind a crowded directory"
  assert_contains "$out" "docs/area-1/nota.md" "no room was left for the documents behind the crowded directory"
  pass "fm-project-memory.sh: more directories than slots still names the agent memory"
}

# The shape the ceiling exists for in a Spanish-named project: the root holds
# the agent memory AND thirty reports, so a rule that reads a directory's best
# rank would let the root spend the listing and leave `informes/` with nothing
# but a count, though its documents are worth exactly as much.
test_a_directory_holding_agent_memory_does_not_take_another_directorys_names() {
  local world out i
  world=$(make_world mixedrank)
  mkdir -p "$world/source/docs" "$world/source/informes"
  printf 'agent memory an earlier worker wrote\n' >"$world/source/AGENTS.md"
  i=1
  while [ "$i" -le 30 ]; do
    printf 'report %s\n' "$i" >"$world/source/informe-$i.md"
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le 19 ]; do
    printf 'audit %s\n' "$i" >"$world/source/docs/audit-$i.md"
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le 25 ]; do
    printf 'analysis %s\n' "$i" >"$world/source/informes/analisis-$i.md"
    i=$((i + 1))
  done
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 75" "the count stopped being complete"
  assert_equals "5" "$(names_from "$out" 'informes/analisis-')" \
    "the directory holding the agent memory took the names owed to informes/"
  assert_equals "5" "$(names_from "$out" 'docs/audit-')" \
    "docs/ contributed a number of names the ceiling does not allow"
  assert_contains "$out" "
    AGENTS.md" "the project's agent memory was not named"
  assert_contains "$out" "informes/ (20 more files)" "informes/ did not give up its excess to one counted line"
  pass "fm-project-memory.sh: a directory holding agent memory does not take another directory's names"
}

# Rule three on its own: the hidden count and the knowledge count have to be
# able to differ, or the line proves nothing. Working material is never
# knowledge, so its omission line has to say zero while the counts stay whole.
test_the_omission_line_counts_only_the_knowledge_it_hides() {
  local world out i
  world=$(make_world hiddencount)
  mkdir -p "$world/source/parts"
  i=1
  while [ "$i" -le 50 ]; do
    printf 'binary-ish\n' >"$world/source/parts/blob-$i.bin"
    i=$((i + 1))
  done
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_OTHER: 50" "the count stopped being complete"
  assert_contains "$out" "parts/ (45 more files)" "the overflow did not collapse into one counted line"
  assert_contains "$out" "... and 45 more (0 of them knowledge)" \
    "the omission line counted working material as knowledge"
  assert_contains "$out" "VERDICT: parity" "working material alone turned the verdict into a leak"
  pass "fm-project-memory.sh: the omission line counts only the knowledge it hides"
}

# The cross-rank shape of rule two: here the crowded directory is the LESS
# valuable one, so the ranking alone would already save the audit. Its own
# ceiling case lives in test_no_single_directory_takes_every_listing_slot.
test_a_crowded_directory_never_buries_the_captains_own_document() {
  local world out i
  world=$(make_world crowded)
  mkdir -p "$world/source/assets" "$world/source/docs"
  i=1
  while [ "$i" -le 45 ]; do
    printf 'caption\n' >"$world/source/assets/caption-$i.txt"
    i=$((i + 1))
  done
  printf 'the production audit of 500 conversations\n' >"$world/source/docs/audit.md"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 46" "the count stopped being complete"
  assert_contains "$out" "docs/audit.md" "a crowded directory buried the captain's own document"
  assert_contains "$out" "assets/ (40 more files)" "the overflow did not collapse into one counted line"
  pass "fm-project-memory.sh: a crowded directory never buries the captain's own document"
}

test_scratch_is_counted_but_never_listed() {
  local world out
  world=$(make_world scratch)
  mkdir -p "$world/source/node_modules/pkg"
  printf 'x\n' >"$world/source/node_modules/pkg/index.js"
  printf 'noise\n' >"$world/source/run.log"
  record_source "$world"
  out=$(run_scan "$world")
  assert_not_contains "$out" "run.log" "scratch was listed in the report"
  assert_contains "$out" "SCRATCH_IGNORED_FROM_REPORT: " "scratch was not counted"
  pass "fm-project-memory.sh: scratch is counted and never listed"
}

test_unpushed_commits_are_reported() {
  local world out
  world=$(make_world unpushed)
  printf 'more\n' >>"$world/source/README.md"
  git_q -C "$world/source" commit -qam "local only work"
  record_source "$world"
  out=$(run_scan "$world")
  assert_contains "$out" "UNPUSHED_COMMITS: 1" "a commit that reached no remote was not reported"
  assert_contains "$out" "local only work" "the unpushed commit subject was not listed"
  pass "fm-project-memory.sh: commits that reached no remote are reported"
}

test_source_canonical_divergence_is_not_reported_as_a_leak() {
  local world out
  world=$(make_world canonical)
  printf 'knowledge\n' >"$world/source/notes.md"
  record_source "$world" --canonical source
  out=$(run_scan "$world")
  assert_contains "$out" "HOME_KIND: source" "the recorded knowledge home was not reported"
  assert_contains "$out" "VERDICT: source-canonical" "a source-canonical project read as an ordinary leak"
  assert_not_contains "$out" "VERDICT: divergent" "a source-canonical project was reported as divergent"
  pass "fm-project-memory.sh: a source-canonical project's divergence is not a leak"
}

test_absent_source_record_is_a_normal_reported_state() {
  local world out rc
  world=$(make_world norecord)
  out=$(run_scan "$world")
  rc=$?
  expect_code 0 "$rc" "an absent source record failed instead of reporting"
  assert_contains "$out" "SOURCE: none recorded" "an absent source record was not reported as such"
  assert_contains "$out" "VERDICT: unknown" "an absent source record did not read as unknown"
  pass "fm-project-memory.sh: an absent source record is reported, not an error"
}

test_source_record_round_trips_and_home_resolves() {
  local world out
  world=$(make_world record)
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/source" --canonical source 2>&1) ||
    fail "source set failed: $out"
  out=$(run_scan "$world")
  assert_contains "$out" "HOME_KIND: source" "the recorded knowledge home did not round-trip"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" home demo 2>&1)
  [ "$out" = "$(cd "$world/source" && pwd -P)" ] ||
    fail "home did not resolve to the canonical source checkout: $out"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/source" 2>&1)
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" home demo 2>&1)
  [ "$out" = "$(cd "$world/home/projects/demo" && pwd -P)" ] ||
    fail "home did not fall back to the clone for a repo-canonical project: $out"
  pass "fm-project-memory.sh: the source record round-trips and home resolves both kinds"
}

test_source_clear_forgets_the_record() {
  local world out
  world=$(make_world clear)
  record_source "$world" --canonical source
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source clear demo 2>&1) || fail "source clear failed: $out"
  out=$(run_scan "$world")
  assert_contains "$out" "SOURCE: none recorded" "the cleared record was still read"
  pass "fm-project-memory.sh: source clear forgets the record"
}

# A source-canonical home that is not mounted right now (the Windows disk
# behind /mnt/c is down) must never be answered with the clone: the clone is a
# stale mirror, and a caller handed it in silence would read an old catalog as
# current or report a folder as quiet that it never looked at.
test_an_unreachable_canonical_home_is_refused_not_replaced_by_the_clone() {
  local world out rc recorded
  world=$(make_world unreachable)
  record_source "$world" --canonical source
  recorded=$(cd "$world/source" && pwd -P)
  # The record holds the resolved path of the checkout; the directory itself is
  # now missing, exactly as an unmounted disk would leave it.
  rm -rf -- "$world/source"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" home demo 2>/dev/null) && rc=0 || rc=$?
  expect_code 4 "$rc" "home answered an unreachable canonical home with something other than exit 4"
  [ "$out" = "$recorded" ] || fail "home did not print the recorded path of the unreachable home: $out"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" home demo 2>&1 >/dev/null)
  assert_contains "$out" "not reachable" "home did not say the canonical home is unreachable"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity demo 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "activity read the clone instead of failing on an unreachable canonical home"
  assert_not_contains "$out" "ACTIVITY:" "activity reported a reading it could not have taken"
  assert_contains "$out" "not reachable" "activity did not say the canonical home is unreachable"
  pass "fm-project-memory.sh: an unreachable canonical home is refused rather than replaced by the clone"
}

test_source_set_refuses_the_homes_own_clone() {
  local world out rc
  world=$(make_world refuse)
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/home/projects/demo" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "recording this home's own clone as the source checkout was accepted"
  assert_contains "$out" "own clone" "the refusal did not name the cause"
  pass "fm-project-memory.sh: this home's own clone is refused as a source checkout"
}

test_scan_is_bounded_by_limit() {
  local world out
  world=$(make_world bounded)
  mkdir -p "$world/source/docs"
  printf 'index\n' >"$world/source/docs/index.md"
  git_q -C "$world/source" add docs/index.md
  git_q -C "$world/source" commit -qm docs
  publish "$world"
  local i=0
  while [ "$i" -lt 12 ]; do
    printf 'note %s\n' "$i" >"$world/source/docs/note-$i.md"
    i=$((i + 1))
  done
  record_source "$world"
  out=$(run_scan "$world" --limit 3)
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 12" "the complete count was not reported"
  assert_contains "$out" "docs/note-0.md" "a bounded listing returned no document name at all"
  assert_equals "3" "$(names_from "$out" 'docs/note-')" "the listing printed past its limit"
  assert_contains "$out" "... and 9 more (9 of them knowledge)" \
    "the omission line did not say how much of what it hides is knowledge"

  # When the overflow is spread across directories there is nothing to collapse,
  # so the omission line carries it - and says how much of what it hides is
  # knowledge, which is what decides whether to re-run with a larger limit.
  world=$(make_world boundedspread)
  local d=0
  while [ "$d" -lt 6 ]; do
    mkdir -p "$world/source/area-$d"
    printf 'finding %s\n' "$d" >"$world/source/area-$d/notes.md"
    d=$((d + 1))
  done
  record_source "$world"
  out=$(run_scan "$world" --limit 3)
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 6" "the complete count was not reported"
  assert_contains "$out" "... and 3 more (3 of them knowledge)" \
    "the omission line did not say how much of what it hides is knowledge"
  pass "fm-project-memory.sh: counts stay complete while listings stay bounded"
}

test_scan_never_writes_to_the_source_checkout
test_scan_reports_uncommitted_knowledge_and_excluded_agent_memory
test_scan_reports_a_clean_project_as_parity
test_scan_reports_a_knowledge_file_the_project_ignores
test_documents_inside_an_ignored_tree_stay_folded_into_one_line
test_an_ignored_knowledge_directory_counts_as_a_leak_not_as_material
test_an_accented_path_is_classified_like_its_ascii_twin
test_an_untracked_knowledge_directory_is_classified_by_what_is_inside_it
test_a_knowledge_document_with_a_scratch_name_is_still_knowledge
test_documentation_inside_a_dependency_tree_is_not_project_knowledge
test_a_vendored_tree_is_not_project_knowledge
test_the_listing_names_the_knowledge_surface_before_anything_else
test_no_single_directory_takes_every_listing_slot
test_more_directories_than_slots_still_names_the_agent_memory
test_a_directory_holding_agent_memory_does_not_take_another_directorys_names
test_the_omission_line_counts_only_the_knowledge_it_hides
test_a_crowded_directory_never_buries_the_captains_own_document
test_scratch_is_counted_but_never_listed
test_unpushed_commits_are_reported
test_source_canonical_divergence_is_not_reported_as_a_leak
test_absent_source_record_is_a_normal_reported_state
test_source_record_round_trips_and_home_resolves
test_source_clear_forgets_the_record
test_an_unreachable_canonical_home_is_refused_not_replaced_by_the_clone
test_source_set_refuses_the_homes_own_clone
test_scan_is_bounded_by_limit
test_activity_reports_a_folder_nobody_is_touching_as_quiet
test_activity_reports_a_recent_write_as_active
test_activity_reports_a_git_operation_in_flight
