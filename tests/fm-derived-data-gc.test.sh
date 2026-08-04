#!/usr/bin/env bash
# Tests for bin/fm-derived-data-gc.sh, the Xcode DerivedData garbage collector
# that fm-teardown.sh runs after a task worktree is removed.
#
# Matrix:
#   (a) --worktree removes a dir whose WorkspacePath lives under the (removed)
#       worktree
#   (b) --worktree never removes a dir whose WorkspacePath still exists on disk
#   (c) --worktree does not match sibling paths that merely share a string
#       prefix ($wt vs $wt-extra)
#   (d) --worktree never removes no-plist dirs, even aged ones
#   (e) --orphans removes a dir whose WorkspacePath no longer exists
#   (f) --orphans keeps a dir whose WorkspacePath still exists
#   (g) --orphans without --include-no-plist keeps no-plist dirs, even aged ones
#   (h) --orphans --include-no-plist keeps fresh no-plist dirs (age gate)
#   (i) --orphans --include-no-plist removes no-plist dirs older than 48h
#   (j) protected *.noindex caches are never removed, even aged and plist-less
#   (k) --dry-run reports but removes nothing
#   (l) a missing DerivedData root is a quiet no-op
#   (m) no mode is a usage error (exit 2)
#   (n) a plist without a WorkspacePath key counts as no-plist (age gate applies)
#   (o) the mtime probe survives a GNU stat that answers `-f` on stdout and still
#       fails, instead of concatenating that text with the fallback epoch
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The helper verifies WorkspacePath through plutil; without it the script
# itself refuses to delete anything, so there is nothing to test.
command -v plutil >/dev/null 2>&1 || { echo "skip: plutil not found (DerivedData GC is macOS-only)"; exit 0; }

GC="$ROOT/bin/fm-derived-data-gc.sh"
TMP_ROOT=$(fm_test_tmproot fm-derived-data-gc-tests)
DD="$TMP_ROOT/DerivedData"
WS="$TMP_ROOT/workspaces"
mkdir -p "$DD" "$WS"

write_plist() {
  local dir=$1 ws_path=$2
  mkdir -p "$dir"
  cat > "$dir/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>$ws_path</string>
</dict>
</plist>
EOF
}

age_dir() {
  # Backdate a directory's mtime well beyond the default 48h gate.
  touch -t 202001010000 "$1"
}

run_gc() {
  FM_DERIVED_DATA_ROOT="$DD" "$GC" "$@"
}

# --- fixtures ---------------------------------------------------------------
# Removed worktree wt1 (never created on disk) with a matching DerivedData dir.
write_plist "$DD/App-aaa" "$WS/wt1/App.xcodeproj"
# Live worktree wt2 whose DerivedData dir must survive even when named.
mkdir -p "$WS/wt2/App.xcodeproj"
write_plist "$DD/App-bbb" "$WS/wt2/App.xcodeproj"
# Sibling path sharing only a string prefix with wt1.
write_plist "$DD/App-ccc" "$WS/wt1-extra/App.xcodeproj"
# Orphan plist dir (workspace never existed).
write_plist "$DD/App-ddd" "$WS/gone/App.xcodeproj"
# No-plist dirs: one fresh, one aged.
mkdir -p "$DD/App-fresh" "$DD/App-aged"
age_dir "$DD/App-aged"
# Aged plist dir missing the WorkspacePath key (unreadable-as-WorkspacePath).
mkdir -p "$DD/App-nokey"
cat > "$DD/App-nokey/info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Name</key>
	<string>App</string>
</dict>
</plist>
EOF
age_dir "$DD/App-nokey"
# Protected shared caches, aged and plist-less: must survive everything.
mkdir -p "$DD/ModuleCache.noindex" "$DD/CompilationCache.noindex" \
  "$DD/SDKStatCaches.noindex" "$DD/SymbolCache.noindex" "$DD/OtherCache.noindex"
age_dir "$DD/ModuleCache.noindex"
age_dir "$DD/CompilationCache.noindex"
age_dir "$DD/SDKStatCaches.noindex"
age_dir "$DD/SymbolCache.noindex"
age_dir "$DD/OtherCache.noindex"

# (m) no mode is a usage error.
set +e
run_gc > "$TMP_ROOT/usage-out" 2>&1
rc=$?
set -e
expect_code 2 "$rc" "no mode"
pass "no mode is a usage error"

# (l) missing DerivedData root is a quiet no-op.
out=$(FM_DERIVED_DATA_ROOT="$TMP_ROOT/no-such-root" "$GC" --orphans)
expect_code 0 "$?" "missing root exit"
[ -z "$out" ] || fail "missing root printed output: $out"
pass "missing DerivedData root is a quiet no-op"

# (k) dry-run reports but removes nothing.
out=$(run_gc --worktree "$WS/wt1" --dry-run)
assert_contains "$out" "would remove: $DD/App-aaa" "dry-run should report App-aaa"
assert_present "$DD/App-aaa" "dry-run removed App-aaa"
pass "--dry-run reports but removes nothing"

# (a) worktree mode removes the dir whose WorkspacePath is under the worktree.
out=$(run_gc --worktree "$WS/wt1")
assert_contains "$out" "removed: $DD/App-aaa" "worktree GC should remove App-aaa"
assert_absent "$DD/App-aaa" "App-aaa should be removed"
# (c) sibling string-prefix path survives.
assert_present "$DD/App-ccc" "App-ccc (wt1-extra) must not match worktree wt1"
pass "--worktree removes dirs under the worktree and respects prefix boundaries"

# (b) worktree mode never removes a dir whose WorkspacePath still exists.
out=$(run_gc --worktree "$WS/wt2")
assert_not_contains "$out" "App-bbb" "App-bbb has a live WorkspacePath and must not be reported removed"
assert_present "$DD/App-bbb" "App-bbb has a live WorkspacePath and must survive"
pass "--worktree never removes a dir whose WorkspacePath still exists"

# (d) worktree mode never removes no-plist dirs, even aged ones.
run_gc --worktree "$WS/wt1" > /dev/null
assert_present "$DD/App-aged" "worktree mode must never touch no-plist dirs"
pass "--worktree never removes no-plist dirs"

# (g) orphans without --include-no-plist keeps no-plist dirs, even aged ones.
out=$(run_gc --orphans)
# (e) orphans removes the dir whose WorkspacePath no longer exists.
assert_contains "$out" "removed: $DD/App-ddd" "orphans GC should remove App-ddd"
assert_absent "$DD/App-ddd" "App-ddd should be removed"
# App-ccc's workspace wt1-extra also never existed, so it is an orphan too.
assert_absent "$DD/App-ccc" "App-ccc (orphan) should be removed by orphans GC"
# (f) orphans keeps the live-workspace dir.
assert_present "$DD/App-bbb" "App-bbb (live) must survive orphans GC"
assert_present "$DD/App-fresh" "fresh no-plist dir must survive without --include-no-plist"
assert_present "$DD/App-aged" "aged no-plist dir must survive without --include-no-plist"
assert_present "$DD/App-nokey" "no-WorkspacePath-key dir must survive without --include-no-plist"
pass "--orphans removes dead-workspace dirs and keeps no-plist dirs without the flag"

# (h)+(i) age gate on --include-no-plist.
out=$(run_gc --orphans --include-no-plist)
assert_present "$DD/App-fresh" "fresh no-plist dir must survive the age gate"
assert_absent "$DD/App-aged" "aged no-plist dir should be removed with --include-no-plist"
# (n) plist without a WorkspacePath key counts as no-plist.
assert_absent "$DD/App-nokey" "plist without WorkspacePath counts as no-plist and ages out"
pass "--include-no-plist removes only no-plist dirs older than the age gate"

# (j) protected caches survived every run above.
assert_present "$DD/ModuleCache.noindex" "ModuleCache.noindex must never be removed"
assert_present "$DD/CompilationCache.noindex" "CompilationCache.noindex must never be removed"
assert_present "$DD/SDKStatCaches.noindex" "SDKStatCaches.noindex must never be removed"
assert_present "$DD/SymbolCache.noindex" "SymbolCache.noindex must never be removed"
assert_present "$DD/OtherCache.noindex" "any *.noindex entry must never be removed"
pass "protected *.noindex caches are never removed"

# (o) mtime probe under GNU stat.
# GNU coreutils stat has no BSD-style `-f <format>`: it reads `-f` as "print
# filesystem status" and treats `%m` as a file operand, so it writes a
# multi-line filesystem summary for the real operand to STDOUT and still exits
# non-zero. A probe that pipes that failure into a `||` fallback captures the
# summary text concatenated with the fallback epoch, and the age arithmetic then
# aborts the whole run under `set -u` with "File: unbound variable".
# This stub reproduces that stat flavor on any host, so the case is a real
# regression guard on macOS rather than something only Linux CI would catch.
GNU_STAT_ROOT=$(fm_test_tmproot fm-derived-data-gc-gnustat)
GNU_DD="$GNU_STAT_ROOT/DerivedData"
mkdir -p "$GNU_DD/App-aged-gnu"
age_dir "$GNU_DD/App-aged-gnu"
FAKEBIN=$(fm_fakebin "$GNU_STAT_ROOT")
cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
# GNU-coreutils stat emulation, narrowed to the two probes the GC issues.
case "$1" in
  -c)
    [ "$2" = "%Y" ] || exit 1
    # Fixed epoch (2020-01-01), far past any age gate the tests use.
    printf '%s\n' 1577836800
    exit 0
    ;;
  -f)
    printf "stat: cannot read file system information for '%%m': No such file or directory\n" >&2
    printf '  File: "%s"\n    ID: 0        Namelen: 255     Type: apfs\n' "$3"
    exit 1
    ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/stat"

set +e
out=$(PATH="$FAKEBIN:$PATH" FM_DERIVED_DATA_ROOT="$GNU_DD" \
  "$GC" --orphans --include-no-plist 2>&1)
rc=$?
set -e
expect_code 0 "$rc" "GNU-stat mtime probe should not abort the run"
assert_not_contains "$out" "unbound variable" \
  "GNU stat's filesystem summary must not reach the age arithmetic"
assert_absent "$GNU_DD/App-aged-gnu" \
  "aged no-plist dir should still be removed under GNU stat"
pass "mtime probe tolerates a GNU stat that answers -f on stdout and fails"
