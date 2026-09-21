#!/usr/bin/env bash
# Behavior tests for bin/fm-memory.sh and bin/fm-memory-bm25.mjs.
#
# Drives the real CLI against a scratch home: writes, BM25 recall, index
# freshness, store-dir resolution order, and slug/category validation. No
# network, no OpenViking.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || fail "node is required for fm-memory tests"

TMP_ROOT=$(fm_test_tmproot fm-memory)
HOME_DIR="$TMP_ROOT/home"
STORE="$HOME_DIR/data/memories"
mkdir -p "$HOME_DIR/config"
export FM_HOME=$HOME_DIR
unset FM_MEMORY_DIR FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE

MEM="$ROOT/bin/fm-memory.sh"

# --- remember writes category/slug.md with frontmatter -----------------------

out=$("$MEM" remember --category entity 'Tea Kettle' 'the captain uses a steel kettle')
assert_equals 'entities/tea-kettle.md' "$out" 'remember prints relative path'
assert_present "$STORE/entities/tea-kettle.md" 'remember wrote the memory file'
assert_grep 'category: entities' "$STORE/entities/tea-kettle.md" 'category recorded'
assert_grep '# Tea Kettle' "$STORE/entities/tea-kettle.md" 'title recorded'

# default category is preferences; singular names normalize
"$MEM" remember 'quiet hours' 'no meetings before ten' >/dev/null
assert_present "$STORE/preferences/quiet-hours.md" 'default category preferences'
"$MEM" remember --category event 'launch day' 'fleet v2 went out' >/dev/null
assert_present "$STORE/events/launch-day.md" 'event normalizes to events'

# stdin body and --category . (store root)
printf 'from stdin body\n' | "$MEM" remember --category . 'Root Note' >/dev/null
assert_present "$STORE/root-note.md" 'root category writes at store root'
assert_grep 'from stdin body' "$STORE/root-note.md" 'stdin body recorded'

# rewrite preserves created date, updates updated
sed 's/^created:.*/created: 1999-01-01/' "$STORE/preferences/quiet-hours.md" > "$TMP_ROOT/quiet-hours.tmp"
mv "$TMP_ROOT/quiet-hours.tmp" "$STORE/preferences/quiet-hours.md"
"$MEM" remember 'quiet hours' 'no meetings before eleven' >/dev/null
created2=$(sed -n 's/^created:[[:space:]]*//p' "$STORE/preferences/quiet-hours.md" | head -n1)
assert_equals '1999-01-01' "$created2" 'rewrite preserves created'
assert_grep 'no meetings before eleven' "$STORE/preferences/quiet-hours.md" 'rewrite updates body'

# a migrated plain-markdown file whose body begins `created:` must not donate that prose
printf 'created: 1999-01-01 was when Acme started\nmore body\n' > "$STORE/preferences/acme.md"
"$MEM" remember 'acme' 'new body' >/dev/null
assert_grep "created: $(date +%F)" "$STORE/preferences/acme.md" 'body created: line is not reused as the frontmatter date'
assert_no_grep 'was when Acme started' "$STORE/preferences/acme.md" 'stale body date is discarded'

# --- recall ------------------------------------------------------------------

out=$("$MEM" recall 'steel kettle')
assert_contains "$out" 'entities/tea-kettle.md' 'recall finds the kettle memory'
assert_contains "$out" 'Tea Kettle' 'recall shows the title'

out=$("$MEM" recall 'updated')
assert_equals '' "$out" 'frontmatter metadata is not indexed'
out=$("$MEM" recall '2026')
assert_equals '' "$out" 'frontmatter dates are not indexed'

out=$("$MEM" recall -- 'steel kettle')
assert_contains "$out" 'entities/tea-kettle.md' 'recall -- <query> handles end-of-options'

"$MEM" remember 'algebra' 'linear algebra notes' >/dev/null
out=$("$MEM" recall 'algebra constructor')
assert_contains "$out" 'preferences/algebra.md' 'inherited term names do not drop matching documents'

out=$("$MEM" recall 'qqqzzz')
assert_equals '' "$out" 'recall prints nothing on zero hits'
"$MEM" recall 'qqqzzz' >/dev/null || fail 'zero-hit recall must exit 0'

rc=0; "$MEM" recall --limit 0 'steel kettle' >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'zero --limit is rejected'
rc=0; "$MEM" recall --limit abc 'steel kettle' >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'non-numeric --limit is rejected'

json=$("$MEM" recall --json 'steel kettle')
printf '%s' "$json" | grep -q '"path":"entities/tea-kettle.md"' \
  || fail "recall --json must carry the hit path, got: $json"

# ranking: the doc dense in the query term beats one that mentions it once
"$MEM" remember 'apples' 'apple apple apple orchard harvest' >/dev/null
"$MEM" remember 'misc' 'one apple and other things entirely unrelated words' >/dev/null
top=$("$MEM" recall --limit 1 'apple' | head -n1)
assert_contains "$top" 'preferences/apples.md' 'BM25 ranks the denser doc first'

# stale index self-rebuilds: edit on disk without remember, recall must see it
printf '# quiet hours\n\nno meetings before noon\n' >> "$STORE/preferences/quiet-hours.md"
out=$("$MEM" recall 'noon')
assert_contains "$out" 'quiet-hours.md' 'recall self-rebuilds a stale index'

# --- list / stats / reindex / dir --------------------------------------------

out=$("$MEM" list)
assert_contains "$out" 'entities/tea-kettle.md' 'list shows memory paths'
assert_not_contains "$out" '.index.json' 'list hides the index cache'

out=$("$MEM" dir)
assert_equals "$STORE" "$out" 'dir resolves to FM_HOME data/memories'

out=$("$MEM" stats)
assert_contains "$out" "dir: $STORE" 'stats prints dir'
assert_contains "$out" 'documents:' 'stats prints document count'

out=$("$MEM" reindex)
assert_contains "$out" 'indexed' 'reindex reports'
assert_present "$STORE/.index.json" 'reindex writes the index cache'

rc=0; node "$ROOT/bin/fm-memory-bm25.mjs" build --dir "$STORE" --index "$TMP_ROOT/custom.json" >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'the removed --index option is rejected'
assert_absent "$TMP_ROOT/custom.json" 'rejected --index wrote no index'

# an unreadable file must keep the index stale instead of falsely fresh
LOCKED="$STORE/preferences/locked.md"
printf '# locked\nsecret word zyxwvu\n' > "$LOCKED"
chmod 000 "$LOCKED"
if [ -r "$LOCKED" ]; then
  chmod 644 "$LOCKED"
  pass 'unreadable-file staleness skipped because permissions cannot deny reads'
else
  "$MEM" reindex >/dev/null
  out=$("$MEM" stats)
  assert_contains "$out" 'index: stale' 'unreadable file keeps the index stale'
  chmod 644 "$LOCKED"
  out=$("$MEM" recall 'zyxwvu')
  assert_contains "$out" 'preferences/locked.md' 'restored readable file becomes searchable'
fi

# an unreadable directory is recorded as skipped, not silently dropped
LOCKED_DIR="$STORE/preferences/locked"
mkdir -p "$LOCKED_DIR"
printf '# hidden\nsecret word qqqvvv\n' > "$LOCKED_DIR/hidden.md"
chmod 000 "$LOCKED_DIR"
if [ -x "$LOCKED_DIR" ]; then
  chmod 755 "$LOCKED_DIR"
  pass 'unreadable-directory check skipped because permissions cannot deny reads'
else
  out=$("$MEM" reindex)
  assert_contains "$out" 'skipped 1 unreadable director' 'unreadable directory is reported at build'
  chmod 755 "$LOCKED_DIR"
  "$MEM" reindex >/dev/null
  out=$("$MEM" recall 'qqqvvv')
  assert_contains "$out" 'preferences/locked/hidden.md' 'restored directory becomes searchable'
fi

# list is the plain unfiltered listing: it rejects a prefix argument
rc=0; "$MEM" list entities >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'list rejects a prefix argument'

# an unwritable store surfaces the documented usage exit instead of a crash
rm -f "$STORE/.index.json"
chmod 555 "$STORE"
if [ -w "$STORE" ]; then
  chmod 755 "$STORE"
  pass 'unwritable-store write exit skipped because permissions cannot deny writes'
else
  rc=0; "$MEM" recall 'steel kettle' >/dev/null 2>&1 || rc=$?
  chmod 755 "$STORE"
  expect_code 2 "$rc" 'unwritable index exits 2'
fi

# --- resolution order ---------------------------------------------------------

ALT="$TMP_ROOT/alt-store"
printf '%s\n' "$ALT" > "$HOME_DIR/config/memory-dir"
out=$("$MEM" dir)
assert_equals "$ALT" "$out" 'config/memory-dir wins over default'
out=$(FM_MEMORY_DIR="$TMP_ROOT/env-store" "$MEM" dir)
assert_equals "$TMP_ROOT/env-store" "$out" 'FM_MEMORY_DIR wins over config file'

# --- validation ---------------------------------------------------------------

rc=0; "$MEM" remember --category 'bad_cat!' 'x' 'y' >/dev/null 2>&1 || rc=$?
expect_code 3 "$rc" 'invalid category'
rc=0; "$MEM" remember '!!!' 'y' </dev/null >/dev/null 2>&1 || rc=$?
expect_code 3 "$rc" 'topic with no usable characters'
rc=0; "$MEM" remember 'no-body-topic' </dev/null >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'missing body'
rc=0; "$MEM" recall </dev/null >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'missing query'
rc=0; "$MEM" bogus-cmd >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'unknown command'

# options left after the body must fail loudly instead of being stored as the fact
rc=0; "$MEM" remember 'trailing cat' 'the real fact' --category entity >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'trailing --category after the body is rejected'
assert_absent "$ALT/preferences/trailing-cat.md" 'rejected trailing --category wrote nothing'
assert_absent "$ALT/entities/trailing-cat.md" 'rejected trailing --category did not reach entities'
rc=0; "$MEM" remember 'from-file-topic' --from-file "$TMP_ROOT/fact.txt" >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" '--from-file is rejected'
assert_absent "$ALT/preferences/from-file-topic.md" 'rejected --from-file wrote nothing'

# single-dash body tokens and -- escaped bodies are not stale shim options
"$MEM" remember -- 'dash topic' -5C degrees outside >/dev/null
assert_grep '-5C degrees outside' "$ALT/preferences/dash-topic.md" '-- escaped single-dash body token is stored'
"$MEM" remember 'flag note' remember to pass -v for verbose >/dev/null
assert_grep 'pass -v for verbose' "$ALT/preferences/flag-note.md" 'unquoted single-dash token stays in the body'

pass 'fm-memory behavior suite'
