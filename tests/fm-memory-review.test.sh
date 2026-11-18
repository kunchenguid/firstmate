#!/usr/bin/env bash
# tests/fm-memory-review.test.sh - the Claude auto-memory review path.
#
# Covers store selection (only the home's own store is read, never a worktree's
# or clone's), the approve/skip/quit decisions, the learnings entry shape, quiet
# reruns through the reviewed record, re-asking an edited note, and the refusals
# (no explicit FM_HOME, task pane, non-primary home). All fixtures live under a temp root: no real
# home, no network, no model.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-review)
BIN="$ROOT/bin/fm-memory-review.sh"

# make_world <name>: a home plus a fake Claude config dir holding the home's store.
make_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/data" "$w/home/bin" "$w/claude"
  : >"$w/home/AGENTS.md"
  git init -q "$w/home"
  local real project store
  real=$(cd "$w/home" && pwd -P)
  project=$(printf '%s' "$real" | sed 's/[^A-Za-z0-9]/-/g')
  store="$w/claude/projects/$project/memory"
  mkdir -p "$store"
  printf '%s\n' "$w"
}

store_of() {
  local real project
  real=$(cd "$1/home" && pwd -P)
  project=$(printf '%s' "$real" | sed 's/[^A-Za-z0-9]/-/g')
  printf '%s/claude/projects/%s/memory\n' "$1" "$project"
}

run() { # run <world> <stdin> [args...]
  local w=$1 input=$2
  shift 2
  printf '%s' "$input" | FM_HOME="$w/home" CLAUDE_CONFIG_DIR="$w/claude" "$BIN" "$@" 2>&1
}

write_note() { # write_note <store> <file> <name> <type> <body>
  printf -- '---\nname: %s\ndescription: about %s\ntype: %s\n---\n\n%s\n' \
    "$3" "$3" "$4" "$5" >"$1/$2"
}

# --- list shows only .md notes, never the index or a symlink -----------------

w=$(make_world list)
store=$(store_of "$w")
write_note "$store" prefers-short.md prefers-short feedback "Likes short answers."
write_note "$store" other.md other project "Another note."
printf -- '- [x](x.md)\n' >"$store/MEMORY.md"
printf 'not a note\n' >"$store/readme.txt"
ln -s "$w/home/data" "$store/linked.md"
out=$(run "$w" "" list) || fail "list failed"
assert_contains "$out" "/other.md" "list names a note"
assert_contains "$out" "/prefers-short.md" "list names the other note"
assert_not_contains "$out" "MEMORY.md" "the index is not an item"
assert_not_contains "$out" "readme.txt" "non-md files are not items"
assert_not_contains "$out" "linked.md" "symlinks are not followed"
assert_absent "$w/home/data/learnings.md" "list writes nothing"
pass "list names only regular topic notes and writes nothing"

# --- approve one, skip one: entry shape, record, untouched sources -----------

before=$(cat "$store/other.md" "$store/prefers-short.md" | shasum -a 256)
out=$(run "$w" $'y\nn\n') || fail "review failed"
assert_contains "$out" "filed in data/learnings.md" "first note reported filed"
assert_contains "$out" "skipped" "second note reported skipped"
assert_present "$w/home/data/learnings.md" "learnings file created"
assert_grep "## other" "$w/home/data/learnings.md" "approved note becomes a heading"
assert_grep "Another note." "$w/home/data/learnings.md" "approved body is filed"
assert_grep "Source: Claude auto memory $store/other.md (type: project)" \
  "$w/home/data/learnings.md" "provenance names the source file and type"
assert_no_grep "Likes short answers." "$w/home/data/learnings.md" "skipped body is not filed"
grep -Eq '<!--a:[0-9]{4}-[0-9]{2}-[0-9]{2}-->$' "$w/home/data/learnings.md" \
  || fail "entry carries a dated aging marker"
assert_equals "2" "$(wc -l <"$w/home/data/claude-memory-reviewed.tsv" | tr -d ' ')" "two decisions recorded"
assert_grep "$(printf '\tfiled\t')" "$w/home/data/claude-memory-reviewed.tsv" "filed decision recorded"
assert_grep "$(printf '\tskipped\t')" "$w/home/data/claude-memory-reviewed.tsv" "skipped decision recorded"
assert_equals "$before" "$(cat "$store/other.md" "$store/prefers-short.md" | shasum -a 256)" \
  "Claude's files are untouched"
assert_absent "$w/home/data/captain.md" "captain.md is never created"
assert_absent "$w/home/data/captain-shared.md" "captain-shared.md is never created"
pass "approve files an entry with provenance, skip is recorded, sources untouched"

# --- rerun is quiet; an edited note is asked again ---------------------------

out=$(run "$w" "") || fail "rerun failed"
assert_contains "$out" "no unreviewed Claude memory notes" "rerun reports nothing to review"
assert_not_contains "$out" "File as a learning" "rerun asks nothing"
printf 'Changed text.\n' >>"$store/other.md"
out=$(run "$w" $'y\n') || fail "rerun after edit failed"
assert_contains "$out" "other.md" "an edited note is shown again"
assert_contains "$out" "filed in data/learnings.md" "edited note can be filed"
pass "reruns are quiet and an edited note is asked again"

# --- q stops without recording; EOF stops; other input leaves for later ------

w=$(make_world quit)
store=$(store_of "$w")
write_note "$store" a.md a user "A."
write_note "$store" b.md b user "B."
out=$(run "$w" $'q\n') || fail "quit failed"
assert_absent "$w/home/data/claude-memory-reviewed.tsv" "quit records nothing"
out=$(run "$w" "") || fail "eof failed"
assert_absent "$w/home/data/claude-memory-reviewed.tsv" "end of input records nothing"
out=$(run "$w" $'maybe\nmaybe\n') || fail "later failed"
assert_contains "$out" "left for the next run" "unrecognized answer leaves the note"
assert_absent "$w/home/data/claude-memory-reviewed.tsv" "leaving records nothing"
assert_absent "$w/home/data/learnings.md" "nothing filed without a yes"
pass "quit, end of input and unclear answers record nothing"

# --- a note without frontmatter is still reviewable ---------------------------

w=$(make_world plain)
store=$(store_of "$w")
printf 'Just a line.\n' >"$store/loose.md"
run "$w" $'y\n' >/dev/null || fail "plain review failed"
assert_grep "## loose" "$w/home/data/learnings.md" "heading falls back to the file name"
assert_grep "(type: unknown)" "$w/home/data/learnings.md" "missing type is stated"
pass "a note without frontmatter is filed under its file name"

# --- an existing learnings file is appended to, never rewritten ---------------

w=$(make_world append)
store=$(store_of "$w")
write_note "$store" n.md n feedback "New fact."
printf '# Learnings\n\nOld entry. <!--a:2026-01-01-->\n' >"$w/home/data/learnings.md"
run "$w" $'y\n' >/dev/null || fail "append review failed"
assert_grep "Old entry. <!--a:2026-01-01-->" "$w/home/data/learnings.md" "existing text is kept"
assert_grep "New fact." "$w/home/data/learnings.md" "new text is appended"
pass "an existing learnings file keeps its content"

# --- other stores are never read ----------------------------------------------

w=$(make_world scope)
store=$(store_of "$w")
other="$w/claude/projects/-some-worktree-of-home/memory"
mkdir -p "$other"
write_note "$other" worker.md worker user "Worker-written."
out=$(run "$w" "" list) || fail "scope list failed"
assert_not_contains "$out" "worker.md" "a different repository's store is not listed"
out=$(run "$w" "" --memory-dir "$other" list) || fail "explicit dir failed"
assert_contains "$out" "worker.md" "--memory-dir reads exactly the named directory"
pass "only the home's own store is read unless a directory is named"

# --- missing directory is a quiet no-op ---------------------------------------

w="$TMP_ROOT/nostore"
mkdir -p "$w/home/data" "$w/home/bin"; : >"$w/home/AGENTS.md"; git init -q "$w/home"
out=$(FM_HOME="$w/home" CLAUDE_CONFIG_DIR="$w/claude" "$BIN" 2>&1) || fail "missing dir should exit 0"
assert_contains "$out" "nothing to review" "missing store reported plainly"
pass "a missing Claude memory directory is a no-op"

# --- refusals ------------------------------------------------------------------

w=$(make_world refuse)
code=0
out=$(env -u FM_HOME CLAUDE_CONFIG_DIR="$w/claude" "$BIN" 2>&1 </dev/null) || code=$?
expect_code 1 "$code" "no FM_HOME"
assert_contains "$out" "FM_HOME must be set" "explicit home required"
code=0
out=$(FM_TASK_ID=t1 FM_HOME="$w/home" CLAUDE_CONFIG_DIR="$w/claude" "$BIN" 2>&1 </dev/null) || code=$?
expect_code 1 "$code" "task pane"
assert_contains "$out" "task pane" "a worker pane is refused"
code=0
out=$(FM_HOME="$w/home" "$BIN" --bogus 2>&1 </dev/null) || code=$?
expect_code 1 "$code" "bad argument"
mkdir -p "$w/clone/bin"
git init -q "$w/clone"
code=0
out=$(FM_HOME="$w/clone" CLAUDE_CONFIG_DIR="$w/claude" "$BIN" 2>&1 </dev/null) || code=$?
expect_code 1 "$code" "project clone"
assert_contains "$out" "not a primary home" "a project clone is refused"
mkdir -p "$w/plain"
code=0
out=$(FM_HOME="$w/plain" CLAUDE_CONFIG_DIR="$w/claude" "$BIN" 2>&1 </dev/null) || code=$?
expect_code 1 "$code" "non-home dir"
assert_contains "$out" "not a primary home" "a non-home directory is refused"
pass "missing FM_HOME, a task pane, a bad argument and non-primary homes are refused"
