#!/usr/bin/env bash
# Behavior tests for bin/fm-memory-migrate.sh.
#
# Builds a fixture OpenViking workspace (memories tree, sessions, internals)
# and drives migrate + verify end to end. No launchd, no network; the fixture
# lives entirely in the test temp root.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-migrate)
HOME_DIR="$TMP_ROOT/home"
SRC="$TMP_ROOT/ov-data"
STORE="$HOME_DIR/data/memories"
ARCHIVE="$HOME_DIR/data/memory-archive"
mkdir -p "$HOME_DIR/config" \
  "$SRC/user/default/memories/preferences" \
  "$SRC/user/default/memories/entities" \
  "$SRC/user/default/sessions" \
  "$SRC/user/default/wiki-layer" \
  "$SRC/resources" \
  "$SRC/_system/queue" \
  "$SRC/vectordb/context/store" \
  "$SRC/logs"
export FM_HOME=$HOME_DIR
unset FM_MEMORY_DIR FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_OV_HOME

printf '# tea\nThe captain drinks green tea\n' > "$SRC/user/default/memories/preferences/tea.md"
printf '# soul\nvalues brevity\n' > "$SRC/user/default/memories/soul.md"
printf '# acme\nAcme Corp is a client\n' > "$SRC/user/default/memories/entities/acme.md"
printf 'session transcript one\n' > "$SRC/user/default/sessions/s1.md"
printf 'session transcript two\n' > "$SRC/user/default/sessions/s2.md"
printf 'wiki layer page\n' > "$SRC/user/default/wiki-layer/w1.md"
printf 'shared resource\n' > "$SRC/resources/r1.md"
printf 'queue row bytes\n' > "$SRC/_system/queue/q.md"
printf 'vector blob\n' > "$SRC/vectordb/context/store/v.md"
printf 'noise\n' > "$SRC/_system/queue/not-markdown.bin"
printf 'server stdout\n' > "$SRC/logs/server.log"

MIG="$ROOT/bin/fm-memory-migrate.sh"

# --- dry-run writes nothing ---------------------------------------------------

out=$("$MIG" migrate --source "$SRC" --dry-run)
assert_contains "$out" '3 files' 'dry-run counts three memories'
assert_not_contains "$out" 'migrated:' 'dry-run performs no migration'
assert_absent "$STORE/preferences/tea.md" 'dry-run wrote a file'

# --- migrate: memories land, other markdown archives, internals skipped -------

out=$("$MIG" migrate --source "$SRC")
assert_contains "$out" 'all hashes verified' 'migrate reports verification'
assert_present "$STORE/preferences/tea.md" 'memory migrated into category dir'
assert_present "$STORE/soul.md" 'root memory migrated'
assert_present "$STORE/entities/acme.md" 'entity migrated'
assert_present "$ARCHIVE/user/default/sessions/s1.md" 'session archived'
assert_present "$ARCHIVE/user/default/wiki-layer/w1.md" 'wiki-layer archived'
assert_present "$ARCHIVE/resources/r1.md" 'resource archived'
assert_absent "$ARCHIVE/_system/queue/q.md" '_system markdown skipped'
assert_absent "$ARCHIVE/vectordb/context/store/v.md" 'vectordb markdown skipped'
assert_absent "$ARCHIVE/logs/server.log" 'logs skipped (not markdown anyway)'

# source is untouched
assert_present "$SRC/user/default/memories/preferences/tea.md" 'source memory still present'
assert_present "$SRC/_system/queue/q.md" 'source internals untouched'

# dest content is byte-identical to source
src_sum=$(shasum -a 256 "$SRC/user/default/memories/preferences/tea.md" | awk '{print $1}')
dst_sum=$(shasum -a 256 "$STORE/preferences/tea.md" | awk '{print $1}')
assert_equals "$src_sum" "$dst_sum" 'migrated file hash matches source'

# manifest exists and verify passes standalone
manifest=$(find "$STORE/.migration" -name 'manifest-*.txt' | sort | tail -n1)
assert_present "$manifest" 'manifest written'
out=$("$MIG" verify)
assert_contains "$out" 'verified' 'standalone verify passes'
assert_contains "$out" '7/7' 'verify counts every exported file'

# migrated memories are searchable through fm-memory.sh
out=$("$ROOT/bin/fm-memory.sh" recall 'green tea')
assert_contains "$out" 'preferences/tea.md' 'migrated memory is recallable'

# --- verify detects loss ------------------------------------------------------

rm "$ARCHIVE/resources/r1.md"
rc=0; out=$("$MIG" verify 2>/dev/null) || rc=$?
expect_code 4 "$rc" 'verify fails when a file is missing'
assert_contains "$out" 'missing' 'verify reports the missing file'

# --- re-run is idempotent and heals -------------------------------------------

out=$("$MIG" migrate --source "$SRC")
assert_contains "$out" 'all hashes verified' 're-run re-verifies'
assert_present "$ARCHIVE/resources/r1.md" 're-run restores the missing file'

# --- resolved dest honors the documented config/memory-dir override ----------

ALT_STORE="$TMP_ROOT/alt-memories"
printf '%s\n' "$ALT_STORE" > "$HOME_DIR/config/memory-dir"
out=$("$MIG" migrate --source "$SRC")
assert_present "$ALT_STORE/preferences/tea.md" 'migrate targets the config/memory-dir store'
assert_contains "$out" 'all hashes verified' 'migrate verifies against the config store'
rm -f "$HOME_DIR/config/memory-dir"

# --- a trailing slash on --memories-dir must not duplicate memories ----------

TRAIL_STORE="$TMP_ROOT/trail-store"
TRAIL_ARCHIVE="$TMP_ROOT/trail-archive"
"$MIG" migrate --source "$SRC" --dest "$TRAIL_STORE" --archive "$TRAIL_ARCHIVE" \
  --memories-dir "$SRC/user/default/memories/" >/dev/null
assert_present "$TRAIL_STORE/preferences/tea.md" 'trailing-slash memories dir still copies memories'
assert_absent "$TRAIL_ARCHIVE/user/default/memories/preferences/tea.md" 'trailing-slash memories dir is not also archived'

# --- equivalent --dest spellings share one drift-guard key --------------------

SLASH_STORE="$TMP_ROOT/slash-store"
SLASH_ARCHIVE="$TMP_ROOT/slash-archive"
"$MIG" migrate --source "$SRC" --dest "$SLASH_STORE/" --archive "$SLASH_ARCHIVE" >/dev/null
printf '# tea\noperator edit via slash store\n' > "$SLASH_STORE/preferences/tea.md"
out=$("$MIG" migrate --source "$SRC" --dest "$SLASH_STORE" --archive "$SLASH_ARCHIVE")
assert_contains "$out" 'skipped-and-kept' 'trailing-slash dest reports the skip'
assert_grep 'operator edit via slash store' "$SLASH_STORE/preferences/tea.md" 'trailing-slash dest still honors the drift guard'

# --- relative and absolute --dest spellings share the drift guard -------------

(cd "$TMP_ROOT" && "$MIG" migrate --source "$SRC" --dest rel-store --archive rel-archive >/dev/null)
printf '# tea\nrelative spelling edit\n' > "$TMP_ROOT/rel-store/preferences/tea.md"
out=$("$MIG" migrate --source "$SRC" --dest "$TMP_ROOT/rel-store" --archive "$TMP_ROOT/rel-archive")
assert_contains "$out" 'skipped-and-kept' 'absolute re-run reports the skip'
assert_grep 'relative spelling edit' "$TMP_ROOT/rel-store/preferences/tea.md" 'relative and absolute dest spellings share the drift guard'

# --- a nonexistent leading component keeps one leading slash ------------------

FOREIGN="/fm-nm-$$-nonexistent/memories"
out=$("$MIG" migrate --source "$SRC" --dest "$FOREIGN" --archive "$TMP_ROOT/abs-archive" --dry-run)
dest_line=$(printf '%s\n' "$out" | sed -n 's/^dest: //p')
assert_equals "$FOREIGN" "$dest_line" 'nonexistent leading component keeps one leading slash'

# --- re-run preserves store edits and reports them as skipped-and-kept --------

printf '# tea\nThe captain switched to oolong in the new store\n' > "$STORE/preferences/tea.md"
out=$("$MIG" migrate --source "$SRC")
assert_contains "$out" 'skipped-and-kept' 're-run reports skipped-and-kept files'
assert_contains "$out" "$STORE/preferences/tea.md" 're-run names the skipped destination'
assert_not_contains "$out" 'all hashes verified' 're-run does not claim blanket verification'
assert_grep 'switched to oolong' "$STORE/preferences/tea.md" 'store edit survived the re-run'

out=$("$MIG" migrate --source "$SRC")
assert_grep 'switched to oolong' "$STORE/preferences/tea.md" 'store edit still survives a later re-run'

# --- a failed copy leaves no recorded hash and is never silently overwritten ---

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
REAL_CP=$(command -v cp)
cat > "$FAKEBIN/cp" <<SH
#!/usr/bin/env bash
"$REAL_CP" "\$@" || exit \$?
dest=''
for a in "\$@"; do dest=\$a; done
case "\$dest" in */tea.md) printf 'corrupted bytes\n' > "\$dest" ;; esac
exit 0
SH
chmod +x "$FAKEBIN/cp"

CORRUPT_STORE="$TMP_ROOT/corrupt-store"
CORRUPT_ARCHIVE="$TMP_ROOT/corrupt-archive"
rc=0; PATH="$FAKEBIN:$PATH" "$MIG" migrate --source "$SRC" --dest "$CORRUPT_STORE" --archive "$CORRUPT_ARCHIVE" >/dev/null 2>&1 || rc=$?
expect_code 4 "$rc" 'a corrupted copy fails the run'

out=$("$MIG" migrate --source "$SRC" --dest "$CORRUPT_STORE" --archive "$CORRUPT_ARCHIVE")
assert_contains "$out" 'skipped-and-kept' 'a destination with no recorded hash is reported as skipped-and-kept'
assert_contains "$out" "$CORRUPT_STORE/preferences/tea.md" 'the unrecorded corrupt destination is named'
assert_not_contains "$out" 'all hashes verified' 'the re-run does not claim blanket verification over a kept destination'
assert_grep 'corrupted bytes' "$CORRUPT_STORE/preferences/tea.md" 'a destination with no recorded hash is never overwritten'

# --- a manifest without a row for an existing destination protects it --------

NOROW_STORE="$TMP_ROOT/norow-store"
NOROW_ARCHIVE="$TMP_ROOT/norow-archive"
NOROW_SRC="$TMP_ROOT/norow-src"
mkdir -p "$NOROW_STORE/preferences" "$NOROW_SRC/user/default/memories/preferences"
printf '# tea\ngreen tea\n' > "$NOROW_SRC/user/default/memories/preferences/tea.md"
printf '# oolong\noperator wrote this first\n' > "$NOROW_STORE/preferences/oolong.md"
"$MIG" migrate --source "$NOROW_SRC" --dest "$NOROW_STORE" --archive "$NOROW_ARCHIVE" >/dev/null
printf '# oolong\nOpenViking copy\n' > "$NOROW_SRC/user/default/memories/preferences/oolong.md"
out=$("$MIG" migrate --source "$NOROW_SRC" --dest "$NOROW_STORE" --archive "$NOROW_ARCHIVE")
assert_contains "$out" 'skipped-and-kept' 'a manifest without a row for the destination reports the skip'
assert_contains "$out" "$NOROW_STORE/preferences/oolong.md" 'the destination missing a manifest row is named'
assert_grep 'operator wrote this first' "$NOROW_STORE/preferences/oolong.md" 'an operator memory with no recorded hash survives the re-run'
assert_not_contains "$out" 'all hashes verified' 'the re-run does not claim blanket verification'
assert_present "$NOROW_STORE/preferences/tea.md" 'already-exported memories stay in place'

# --- a first migrate never overwrites a memory the operator wrote first -------

FRESH_STORE="$TMP_ROOT/fresh-store"
FRESH_ARCHIVE="$TMP_ROOT/fresh-archive"
mkdir -p "$FRESH_STORE/preferences"
printf '# tea\noperator wrote this first\n' > "$FRESH_STORE/preferences/tea.md"
out=$("$MIG" migrate --source "$SRC" --dest "$FRESH_STORE" --archive "$FRESH_ARCHIVE")
assert_contains "$out" 'skipped-and-kept' 'first migrate reports the kept operator memory'
assert_contains "$out" 'not written by this migration' 'first migrate names the foreign destination'
assert_grep 'operator wrote this first' "$FRESH_STORE/preferences/tea.md" 'operator memory survived the first migrate'
assert_present "$FRESH_STORE/soul.md" 'non-conflicting memories still migrated'

out=$("$MIG" migrate --source "$SRC" --dest "$FRESH_STORE" --archive "$FRESH_ARCHIVE")
assert_grep 'operator wrote this first' "$FRESH_STORE/preferences/tea.md" 'operator memory survives a second migrate too'

# --- an unhashable source fails the run instead of recording an empty-hash skip ---

UNHASH_STORE="$TMP_ROOT/unhash-store"
UNHASH_ARCHIVE="$TMP_ROOT/unhash-archive"
UNHASH_SRC="$TMP_ROOT/unhash-src"
mkdir -p "$UNHASH_STORE/preferences" "$UNHASH_SRC/user/default/memories/preferences"
printf '# tea\noperator wrote this\n' > "$UNHASH_STORE/preferences/tea.md"
printf '# tea\nOV copy\n' > "$UNHASH_SRC/user/default/memories/preferences/tea.md"
chmod 000 "$UNHASH_SRC/user/default/memories/preferences/tea.md"
if [ -r "$UNHASH_SRC/user/default/memories/preferences/tea.md" ]; then
  chmod 644 "$UNHASH_SRC/user/default/memories/preferences/tea.md"
  pass 'unhashable-source check skipped because permissions cannot deny reads'
else
  rc=0; out=$("$MIG" migrate --source "$UNHASH_SRC" --dest "$UNHASH_STORE" --archive "$UNHASH_ARCHIVE" 2>&1) || rc=$?
  chmod 644 "$UNHASH_SRC/user/default/memories/preferences/tea.md"
  expect_code 4 "$rc" 'an unhashable source exits 4 instead of claiming a foreign skip'
  assert_not_contains "$out" 'skipped-and-kept' 'an unhashable source is not reported as skipped-and-kept'
  assert_not_contains "$out" 'all hashes verified' 'an unhashable source is never reported as verified'
  assert_grep 'operator wrote this' "$UNHASH_STORE/preferences/tea.md" 'the failed run left the operator memory untouched'
fi

# --- an unresolvable destination prefix fails loudly instead of retargeting -----

LOCKED_DEST="$TMP_ROOT/locked-dest"
mkdir -p "$LOCKED_DEST/store"
chmod 000 "$LOCKED_DEST"
if [ -x "$LOCKED_DEST" ]; then
  chmod 755 "$LOCKED_DEST"
  pass 'unresolvable-dest check skipped because permissions cannot deny reads'
else
  rc=0; out=$("$MIG" migrate --source "$SRC" --dest "$LOCKED_DEST/store" --archive "$TMP_ROOT/locked-archive" --dry-run 2>&1) || rc=$?
  chmod 755 "$LOCKED_DEST"
  expect_code 2 "$rc" 'an unresolvable dest prefix exits 2'
  assert_contains "$out" 'cannot resolve directory' 'an unresolvable dest prefix is named'
  assert_not_contains "$out" 'dest: /store' 'an unresolvable dest prefix does not retarget the store'
fi

# --- an output dir inside the source is refused before anything is written ---

rc=0; out=$("$MIG" migrate --source "$SRC" --dest "$STORE" --archive "$SRC/memory-archive" 2>&1) || rc=$?
expect_code 2 "$rc" 'an archive inside the source is refused'
assert_absent "$SRC/memory-archive" 'the refused archive wrote nothing into the source'

rc=0; out=$("$MIG" migrate --source "$SRC" --dest "$SRC/store" --archive "$ARCHIVE" --dry-run 2>&1) || rc=$?
expect_code 2 "$rc" 'a dest inside the source is refused'

rc=0; out=$("$MIG" migrate --source "$SRC" --dest "$SRC" --archive "$ARCHIVE" --dry-run 2>&1) || rc=$?
expect_code 2 "$rc" 'a dest equal to the source is refused'

SIBLING_ARCHIVE="$TMP_ROOT/ov-data-archive"
out=$("$MIG" migrate --source "$SRC" --dest "$STORE" --archive "$SIBLING_ARCHIVE" --dry-run)
assert_contains "$out" "archive: $SIBLING_ARCHIVE" 'a sibling archive name is not mistaken for the source'

# --- a .. tail cannot smuggle an output back inside the source ---------------

rc=0; out=$("$MIG" migrate --source "$SRC" --dest "$TMP_ROOT/ov-data-sib/../ov-data/store" --archive "$ARCHIVE" 2>&1) || rc=$?
expect_code 2 "$rc" 'a dest resolving into the source through a .. tail is refused'
assert_absent "$SRC/store" 'the refused dest wrote nothing into the source'
assert_absent "$TMP_ROOT/ov-data-sib" 'the refused dest did not create its missing component'

rc=0; out=$("$MIG" migrate --source "$SRC" --dest "$STORE" --archive "$TMP_ROOT/ov-data-sib/../ov-data/archive" --dry-run 2>&1) || rc=$?
expect_code 2 "$rc" 'an archive resolving into the source through a .. tail is refused'

out=$("$MIG" migrate --source "$SRC" --dest "$TMP_ROOT/ov-data-sib/../outside-store" --archive "$ARCHIVE" --dry-run)
assert_contains "$out" "dest: $TMP_ROOT/outside-store" 'a .. tail outside the source is collapsed, not refused'

# --- a source without canonical probes fails instead of guessing ----------------

STRAY_SRC="$TMP_ROOT/stray-src"
mkdir -p "$STRAY_SRC/deep/nested/memories"
printf '# stray\nnot the payload\n' > "$STRAY_SRC/deep/nested/memories/stray.md"
rc=0; out=$("$MIG" migrate --source "$STRAY_SRC" 2>&1) || rc=$?
expect_code 3 "$rc" 'a stray memories dir is not auto-accepted'
assert_contains "$out" 'pass --memories-dir' 'the miss error names the explicit escape'

# --- error paths ----------------------------------------------------------------

rc=0; "$MIG" migrate --source "$TMP_ROOT/no-such" >/dev/null 2>&1 || rc=$?
expect_code 3 "$rc" 'missing source'

empty_src="$TMP_ROOT/empty-src"; mkdir -p "$empty_src"
rc=0; "$MIG" migrate --source "$empty_src" >/dev/null 2>&1 || rc=$?
expect_code 3 "$rc" 'no memories tree found'

rc=0; "$MIG" migrate --bogus >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'unknown option'

pass 'fm-memory-migrate behavior suite'
