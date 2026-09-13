#!/usr/bin/env bash
# Behavioral coverage for the read-only memory doctor.
#
# Drives bin/fm-memory-doctor.sh against synthetic local and registered remote
# fixtures. The remote command fixture fails the test if diagnosis invokes it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (dispatch contradiction check)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-memory-doctor)
DOCTOR="${FM_MEMORY_DOCTOR_BIN:-$ROOT/bin/fm-memory-doctor.sh}"

path_metadata() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

metadata = os.lstat(sys.argv[1])
print(
    f"{stat.S_IMODE(metadata.st_mode):o} "
    f"{metadata.st_mtime_ns} {metadata.st_ino} {metadata.st_ctime_ns}"
)
PY
}

fingerprint() {
  local root=$1 metadata
  (
    cd "$root" || exit 1
    find . \( -type f -o -type d -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      metadata=$(path_metadata "$path") || exit 1
      if [ -L "$path" ]; then
        printf 'l %s %s -> %s\n' "$path" "$metadata" "$(readlink "$path")"
      elif [ -d "$path" ]; then
        printf 'd %s %s\n' "$path" "$metadata"
      else
        printf 'f %s %s ' "$path" "$metadata"
        wc -c < "$path" | tr -d '[:space:]'
        printf ' '
        if command -v sha256sum >/dev/null 2>&1; then
          sha256sum "$path" | awk '{print $1}'
        else
          shasum -a 256 "$path" | awk '{print $1}'
        fi
      fi
    done
  )
}

write_budget() {
  printf '7500\n' > "$1/config/startup-memory-budget"
}

write_shared() {
  cat > "$1/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes; they must not be edited there.
The main firstmate owns this file; route replies through marked status or a document pointer.
EOF
}

make_home() {
  local home=$1
  mkdir -p "$home/config" "$home/data" "$home/state"
  write_budget "$home"
  printf 'Keep replies short.\n' > "$home/data/captain.md"
  write_shared "$home"
  printf 'No extra learnings.\n' > "$home/data/learnings.md"
}

install_on_stub() {
  local dest=$1
  cat > "$dest" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${FM_FAKE_ON_CALLS:?}"
printf 'remote command boundary must not be invoked\n' >&2
exit 97
SH
  chmod +x "$dest"
}

run_doctor() {
  local home=$1
  shift
  FM_HOME="$home" \
  FM_ON_BIN="$TMP_ROOT/fake-on" \
  FM_FAKE_ON_CALLS="$TMP_ROOT/fake-on.calls" \
    "$DOCTOR" "$@"
}

run_doctor_with_dirs() {
  local home=$1 config=$2 data=$3 state=$4
  shift 4
  FM_HOME="$home" \
  FM_CONFIG_OVERRIDE="$config" \
  FM_DATA_OVERRIDE="$data" \
  FM_STATE_OVERRIDE="$state" \
  FM_ON_BIN="$TMP_ROOT/fake-on" \
  FM_FAKE_ON_CALLS="$TMP_ROOT/fake-on.calls" \
    "$DOCTOR" "$@"
}

assert_no_writes() {
  local before=$1 after=$2 label=$3
  [ "$before" = "$after" ] || fail "$label: doctor wrote to an inspected fixture"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
}

# --- missing absence probes --------------------------------------------------

DIAGNOSTIC_FIXTURE="$TMP_ROOT/diagnostic-fixture"
make_home "$DIAGNOSTIC_FIXTURE"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf '%s\n' 'Read-only checks may inspect `state/public-followup/` and `state/slack-inbox/`.' > "$DIAGNOSTIC_FIXTURE/data/captain.md"
out=$(run_doctor "$DIAGNOSTIC_FIXTURE" --home-local 2>"$TMP_ROOT/err.diagnostic-fixture") && rc=0 || rc=$?
expect_code 0 "$rc" "read-only diagnostics must succeed"
if grep -F -q 'command not found' "$TMP_ROOT/err.diagnostic-fixture"; then
  fail "read-only diagnostics emitted an undefined-command error: $(cat "$TMP_ROOT/err.diagnostic-fixture")"
fi
pass "read-only diagnostics have no undefined-command errors"

POINTER_PLACEHOLDER_FIXTURE="$TMP_ROOT/pointer-placeholder-fixture"
make_home "$POINTER_PLACEHOLDER_FIXTURE"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf '%s\n' 'Template: `data/<task>/room-join.txt`. Real path: `data/missing-literal.md`. Cross-segment: `data/a<b/c>d.md`.' > "$POINTER_PLACEHOLDER_FIXTURE/data/captain-shared.md"
out=$(run_doctor "$POINTER_PLACEHOLDER_FIXTURE" --home-local 2>"$TMP_ROOT/err.pointer-placeholder") && rc=0 || rc=$?
expect_code 1 "$rc" "real missing pointers must remain threatening"
assert_contains "$out" 'data/missing-literal.md' "real missing pointer evidence is missing"
assert_contains "$out" 'data/a<b/c>d.md' "angle brackets spanning path segments were incorrectly ignored"
if printf '%s\n' "$out" | grep -F -q 'data/<task>/room-join.txt'; then
  fail "angle-bracket template was treated as a missing pointer: $out"
fi
pass "angle-bracket templates are ignored while literal pointer gaps remain"

# --- all-green --------------------------------------------------------------

PRIMARY="$TMP_ROOT/primary"
LOCAL_SM="$TMP_ROOT/local-sm"
REMOTE_OK="$TMP_ROOT/remotes/ios-ok"
mkdir -p "$TMP_ROOT/remotes"
make_home "$PRIMARY"
make_home "$LOCAL_SM"
make_home "$REMOTE_OK"
printf -- '- demo [direct-PR] - demo project (added 2026-06-22)\n' > "$PRIMARY/data/projects.md"
cat > "$PRIMARY/data/secondmates.md" <<EOF
- reviews - reviews domain (home: $LOCAL_SM; scope: review work; projects: demo; added 2026-08-02)
- ios-ok - ios domain (host: remote-mac; root: /tmp/fm-memory-doctor-remote-root; home: /tmp/fm-memory-doctor-remote-home; scope: ios work; projects: demo; added 2026-08-02)
EOF
install_on_stub "$TMP_ROOT/fake-on"
rm -f "$TMP_ROOT/fake-on.calls"

before=$(fingerprint "$PRIMARY"; fingerprint "$LOCAL_SM"; fingerprint "$REMOTE_OK")
out=$(run_doctor "$PRIMARY" 2>"$TMP_ROOT/err.green") && rc=0 || rc=$?
after=$(fingerprint "$PRIMARY"; fingerprint "$LOCAL_SM"; fingerprint "$REMOTE_OK")
assert_no_writes "$before" "$after" "all-green"
expect_code 0 "$rc" "all-green exit"
assert_contains "$out" 'check budget primary=PASS' "all-green missing primary budget PASS"
assert_contains "$out" 'check budget reviews=PASS' "all-green missing local secondmate budget PASS"
assert_contains "$out" 'check budget ios-ok=UNKNOWN' "registered remote missing budget UNKNOWN"
assert_contains "$out" 'check pointers primary=PASS' "all-green missing pointers PASS"
assert_contains "$out" 'check staleness primary=PASS' "all-green missing staleness PASS"
assert_contains "$out" 'check contradictions primary=PASS' "all-green missing contradictions PASS"
assert_contains "$out" 'check inherited-hash reviews=PASS' "all-green missing local hash PASS"
assert_contains "$out" 'check inherited-hash ios-ok=UNKNOWN' "registered remote missing inherited-hash UNKNOWN"
assert_contains "$out" 'check project-notes primary=PASS' "all-green missing project-notes PASS"
assert_contains "$out" 'summary pass=' "all-green missing summary"
assert_contains "$out" 'threatening=0' "all-green should have no threatening gaps"
out2=$(run_doctor "$PRIMARY" 2>/dev/null) || true
[ "$out" = "$out2" ] || fail "all-green output was not stable across two runs"
[ ! -e "$TMP_ROOT/fake-on.calls" ] || fail "registered remote diagnosis invoked a staging command boundary"
pass "local green output, remote UNKNOWN, stable ordering, and no fixture writes"

# --- real-home-shaped valid pointers ----------------------------------------
#
# Representative Firstmate memory names globs, optional local files that are
# allowed to be absent, and tracked owners that do exist. The old pointer
# check treated that valid shape as seven threatening misses.

REALHOME="$TMP_ROOT/real-home"
make_home "$REALHOME"
rm -f "$REALHOME/data/learnings.md"
cat > "$REALHOME/data/captain.md" <<'EOF'
Keep replies short.
Typical pointers: `data/*.md`, `config/crew-dispatch.json`, `config/crew-harness`, `config/backend`, `state/.afk`, `state/.trace-context-effective`, `data/learnings.md`, and `config/x-mode.env`.
Standing owners: `data/captain.md` and `docs/configuration.md`.
EOF
before=$(fingerprint "$REALHOME")
out=$(run_doctor "$REALHOME" 2>"$TMP_ROOT/err.realhome") && rc=0 || rc=$?
after=$(fingerprint "$REALHOME")
assert_no_writes "$before" "$after" "real-home-pointers"
expect_code 0 "$rc" "real-home-shaped valid pointers must not be threatening"
assert_contains "$out" 'check pointers primary=PASS' "real-home valid pointers missing PASS"
case "$out" in
  *'check pointers primary=GAP'*) fail "real-home valid pointers were treated as a GAP: $out" ;;
esac
pass "real-home-shaped valid pointers pass"

# --- valid pointer shapes still report a real miss --------------------------
#
# The valid-shape fixture above does not distinguish a doctor that ignores
# every pointer miss whenever captain.md mentions a glob. Pairing the same
# valid tokens with one concrete missing path keeps the glob and optional
# absents non-threatening while still requiring that real miss.

REALMISS="$TMP_ROOT/real-miss"
make_home "$REALMISS"
rm -f "$REALMISS/data/learnings.md"
cat > "$REALMISS/data/captain.md" <<'EOF'
Keep replies short.
Typical pointers: `data/*.md`, `config/crew-dispatch.json`, `config/crew-harness`, `config/backend`, `state/.afk`, `data/learnings.md`, and `config/x-mode.env`.
Standing owners: `data/captain.md` and `docs/configuration.md`.
See `data/missing-real-target.md` for the standing rule.
EOF
before=$(fingerprint "$REALMISS")
out=$(run_doctor "$REALMISS" 2>"$TMP_ROOT/err.realmiss") && rc=0 || rc=$?
after=$(fingerprint "$REALMISS")
assert_no_writes "$before" "$after" "real-home-miss"
expect_code 1 "$rc" "a real miss beside valid pointer shapes must be threatening"
assert_contains "$out" 'check pointers primary=GAP' "real miss beside valid shapes missing GAP"
assert_contains "$out" 'data/missing-real-target.md' "real miss beside valid shapes missing evidence path"
if printf '%s\n' "$out" | grep -F -q -- 'data/*.md'; then
  fail "glob pointer was treated as a broken path: $out"
fi
if printf '%s\n' "$out" | grep -F -q -- 'config/crew-dispatch.json'; then
  fail "optional absent pointer was treated as a broken path: $out"
fi
pass "a real miss beside valid pointer shapes is a threatening GAP"

# --- broken pointer ---------------------------------------------------------

BROKEN="$TMP_ROOT/broken"
make_home "$BROKEN"
cat > "$BROKEN/data/captain.md" <<'EOF'
See `data/missing-target.md` for the standing rule.
Ambiguous mention of README.md should stay unclassified.
EOF
before=$(fingerprint "$BROKEN")
out=$(run_doctor "$BROKEN" 2>"$TMP_ROOT/err.ptr") && rc=0 || rc=$?
after=$(fingerprint "$BROKEN")
assert_no_writes "$before" "$after" "broken-pointer"
expect_code 1 "$rc" "broken pointer should be a threatening GAP"
assert_contains "$out" 'check pointers primary=GAP' "broken pointer missing GAP"
assert_contains "$out" 'data/missing-target.md' "broken pointer missing evidence path"
case "$out" in
  *'check pointers primary=GAP'*README.md*) fail "ambiguous README.md was treated as a broken pointer" ;;
esac
pass "one broken pointer is a threatening GAP; ambiguous text stays unclassified"

# --- inherited hash mismatch ------------------------------------------------

HASHP="$TMP_ROOT/hash-primary"
HASHSM="$TMP_ROOT/hash-sm"
make_home "$HASHP"
make_home "$HASHSM"
printf 'divergent inherited bytes\n' > "$HASHSM/data/captain-shared.md"
cat > "$HASHP/data/secondmates.md" <<EOF
- reviews - reviews domain (home: $HASHSM; scope: review work; projects: demo; added 2026-08-02)
EOF
before=$(fingerprint "$HASHP"; fingerprint "$HASHSM")
out=$(run_doctor "$HASHP" 2>"$TMP_ROOT/err.hash") && rc=0 || rc=$?
after=$(fingerprint "$HASHP"; fingerprint "$HASHSM")
assert_no_writes "$before" "$after" "hash-mismatch"
expect_code 1 "$rc" "hash mismatch should be a threatening GAP"
assert_contains "$out" 'check inherited-hash reviews=GAP' "hash mismatch missing GAP"
assert_contains "$out" 'data/captain-shared.md' "hash mismatch missing inherited path"
pass "one inherited hash mismatch is a threatening GAP"

# --- session-scoped inherited drift -----------------------------------------

SESSIONP="$TMP_ROOT/session-primary"
SESSIONSM="$TMP_ROOT/session-sm"
make_home "$SESSIONP"
make_home "$SESSIONSM"
printf 'enabled\n' > "$SESSIONP/config/trace-context"
cat > "$SESSIONP/data/secondmates.md" <<EOF
- reviews - reviews domain (home: $SESSIONSM; scope: review work; projects: demo; added 2026-08-02)
EOF
before=$(fingerprint "$SESSIONP"; fingerprint "$SESSIONSM")
out=$(run_doctor "$SESSIONP" 2>"$TMP_ROOT/err.session-scoped") && rc=0 || rc=$?
after=$(fingerprint "$SESSIONP"; fingerprint "$SESSIONSM")
assert_no_writes "$before" "$after" "session-scoped-drift"
expect_code 0 "$rc" "session-scoped inherited drift must not be threatening"
assert_contains "$out" 'check inherited-hash reviews=PASS' "session-scoped inherited drift produced a GAP"
pass "session-scoped inherited drift remains authorized"

# --- unreadable inherited parent --------------------------------------------

HASH_UNREADABLE_PRIMARY="$TMP_ROOT/hash-unreadable-primary"
HASH_UNREADABLE_SM="$TMP_ROOT/hash-unreadable-sm"
make_home "$HASH_UNREADABLE_PRIMARY"
make_home "$HASH_UNREADABLE_SM"
cat > "$HASH_UNREADABLE_PRIMARY/data/secondmates.md" <<EOF
- reviews - reviews domain (home: $HASH_UNREADABLE_SM; scope: review work; projects: demo; added 2026-08-02)
EOF
chmod 000 "$HASH_UNREADABLE_SM/config"
out=$(run_doctor "$HASH_UNREADABLE_PRIMARY" 2>"$TMP_ROOT/err.hash-unreadable") && rc=0 || rc=$?
chmod 700 "$HASH_UNREADABLE_SM/config"
expect_code 0 "$rc" "unreadable inherited parent must remain nonblocking"
assert_contains "$out" 'check inherited-hash reviews=UNKNOWN' "unreadable inherited parent was classified as absent"
assert_contains "$out" 'config/crew-dispatch.json is unreadable' "unreadable inherited parent missing inherited path"
pass "unreadable inherited parents propagate UNKNOWN"

# --- remote UNKNOWN without staging -----------------------------------------

REMOTE_UNKNOWN="$TMP_ROOT/remote-unknown"
make_home "$REMOTE_UNKNOWN"
cat > "$REMOTE_UNKNOWN/data/secondmates.md" <<EOF
- ios-down - ios domain (host: remote-mac; root: /tmp/fm-memory-doctor-remote-root; home: /tmp/fm-memory-doctor-remote-home; scope: ios work; projects: demo; added 2026-08-02)
EOF
rm -f "$TMP_ROOT/fake-on.calls"
before=$(fingerprint "$REMOTE_UNKNOWN")
out=$(run_doctor "$REMOTE_UNKNOWN" 2>"$TMP_ROOT/err.remote-unknown") && rc=0 || rc=$?
after=$(fingerprint "$REMOTE_UNKNOWN")
assert_no_writes "$before" "$after" "remote-unknown"
expect_code 0 "$rc" "unavailable read-only remote inspection must not fail delivery"
for check in budget pointers staleness contradictions inherited-hash project-notes; do
  assert_contains "$out" "check $check ios-down=UNKNOWN" "registered remote missing $check UNKNOWN"
done
assert_contains "$out" 'no read-only non-staging boundary' "registered remote missing exact UNKNOWN cause"
assert_contains "$out" 'threatening=0' "remote UNKNOWN must not be threatening"
[ ! -e "$TMP_ROOT/fake-on.calls" ] || fail "registered remote diagnosis invoked a staging command boundary"
pass "registered remote checks stay UNKNOWN without invoking a staging boundary"

# --- documented dispatch fallback is not a contradiction --------------------

FALLBACK="$TMP_ROOT/fallback"
make_home "$FALLBACK"
printf 'claude\n' > "$FALLBACK/config/crew-harness"
printf '%s\n' '{"default":{"harness":"codex"}}' > "$FALLBACK/config/crew-dispatch.json"
printf 'rule.default_harness=codex\n' > "$FALLBACK/data/captain.md"
before=$(fingerprint "$FALLBACK")
out=$(run_doctor "$FALLBACK" 2>"$TMP_ROOT/err.fallback") && rc=0 || rc=$?
after=$(fingerprint "$FALLBACK")
assert_no_writes "$before" "$after" "dispatch-fallback"
expect_code 0 "$rc" "documented dispatch fallback must not be threatening"
assert_contains "$out" 'check contradictions primary=PASS' "documented fallback missing PASS"
pass "documented dispatch default remains a valid fallback when it differs from crew-harness"

# --- contradictory dispatch statement still fails ---------------------------

CONTRA="$TMP_ROOT/contra"
make_home "$CONTRA"
printf 'claude\n' > "$CONTRA/config/crew-harness"
printf '%s\n' '{"default":{"harness":"codex"}}' > "$CONTRA/config/crew-dispatch.json"
printf 'rule.default_harness=kimi\n' > "$CONTRA/data/captain.md"
before=$(fingerprint "$CONTRA")
out=$(run_doctor "$CONTRA" 2>"$TMP_ROOT/err.contra") && rc=0 || rc=$?
after=$(fingerprint "$CONTRA")
assert_no_writes "$before" "$after" "contradiction"
expect_code 1 "$rc" "mechanical contradiction should be a threatening GAP"
assert_contains "$out" 'check contradictions primary=GAP' "contradiction missing GAP"
assert_contains "$out" 'rule.default_harness' "contradiction missing comparable key"
pass "one dispatch statement outside the configured fallback set is a threatening GAP"

# --- stale active-project note ----------------------------------------------

STALE="$TMP_ROOT/stale"
make_home "$STALE"
printf -- '- demo [direct-PR] - demo project (added 2026-06-22)\n' > "$STALE/data/projects.md"
printf 'Standing notes for demo.\n' > "$STALE/data/demo-notes.md"
python3 -c 'import os, sys, time; p=sys.argv[1]; t=time.time()-40*86400; os.utime(p, (t, t))' \
  "$STALE/data/demo-notes.md"
mkdir -p "$STALE/state"
fm_write_meta "$STALE/state/demo-task.meta" "project=demo" "kind=ship" "window=firstmate:demo-task"
before=$(fingerprint "$STALE")
out=$(run_doctor "$STALE" 2>"$TMP_ROOT/err.stale") && rc=0 || rc=$?
after=$(fingerprint "$STALE")
assert_no_writes "$before" "$after" "stale-note"
expect_code 0 "$rc" "stale project notes must not fail delivery"
assert_contains "$out" 'check project-notes primary=GAP' "stale note missing GAP"
assert_contains "$out" 'data/demo-notes.md' "stale note missing path"
pass "one stale active-project note is a non-threatening GAP"

# --- installed-version claims never execute tools ---------------------------

INERT="$TMP_ROOT/inert"
INERT_BIN="$TMP_ROOT/inert-bin"
make_home "$INERT"
mkdir -p "$INERT_BIN"
cat > "$INERT_BIN/stateful-tool" <<EOF
#!/usr/bin/env bash
printf 'called\n' > "$INERT/tool-called"
EOF
chmod +x "$INERT_BIN/stateful-tool"
printf 'installed: stateful-tool 9.9.9\n' > "$INERT/data/captain.md"
before=$(fingerprint "$INERT")
out=$(PATH="$INERT_BIN:$PATH" run_doctor "$INERT" 2>"$TMP_ROOT/err.inert") && rc=0 || rc=$?
after=$(fingerprint "$INERT")
assert_no_writes "$before" "$after" "installed-version-inert"
expect_code 0 "$rc" "unverified installed-version claim must remain nonblocking"
assert_contains "$out" 'check staleness primary=UNKNOWN' "installed-version claim missing UNKNOWN"
assert_contains "$out" 'installed-version-unverified:stateful-tool:9.9.9' "installed-version claim missing inert metadata result"
[ ! -e "$INERT/tool-called" ] || fail "installed-version claim executed the named tool"
pass "installed-version claims use inert executable metadata"

# --- effective primary directories ------------------------------------------

OVERRIDE_HOME="$TMP_ROOT/override-home"
OVERRIDE_ROOT="$TMP_ROOT/override-dirs"
OVERRIDE_CONFIG="$OVERRIDE_ROOT/config"
OVERRIDE_DATA="$OVERRIDE_ROOT/data"
OVERRIDE_STATE="$OVERRIDE_ROOT/state"
OVERRIDE_SM="$TMP_ROOT/override-sm"
make_home "$OVERRIDE_HOME"
make_home "$OVERRIDE_SM"
mkdir -p "$OVERRIDE_CONFIG" "$OVERRIDE_DATA" "$OVERRIDE_STATE"
printf '1\n' > "$OVERRIDE_CONFIG/startup-memory-budget"
cat > "$OVERRIDE_DATA/captain.md" <<'EOF'
See `data/override-missing.md` for the standing rule.
EOF
write_shared "$OVERRIDE_ROOT"
printf 'No extra learnings.\n' > "$OVERRIDE_DATA/learnings.md"
printf -- '- demo [direct-PR] - demo project (added 2026-06-22)\n' > "$OVERRIDE_DATA/projects.md"
printf 'Standing notes for demo.\n' > "$OVERRIDE_DATA/demo-notes.md"
python3 -c 'import os, sys, time; p=sys.argv[1]; t=time.time()-40*86400; os.utime(p, (t, t))' \
  "$OVERRIDE_DATA/demo-notes.md"
fm_write_meta "$OVERRIDE_STATE/demo-task.meta" "project=demo" "kind=ship" "window=firstmate:demo-task"
cat > "$OVERRIDE_DATA/secondmates.md" <<EOF
- override-sm - review domain (home: $OVERRIDE_SM; scope: review work; projects: demo; added 2026-08-02)
EOF
before=$(fingerprint "$OVERRIDE_HOME"; fingerprint "$OVERRIDE_CONFIG"; fingerprint "$OVERRIDE_DATA"; fingerprint "$OVERRIDE_STATE"; fingerprint "$OVERRIDE_SM")
out=$(run_doctor_with_dirs "$OVERRIDE_HOME" "$OVERRIDE_CONFIG" "$OVERRIDE_DATA" "$OVERRIDE_STATE" \
  2>"$TMP_ROOT/err.override") && rc=0 || rc=$?
after=$(fingerprint "$OVERRIDE_HOME"; fingerprint "$OVERRIDE_CONFIG"; fingerprint "$OVERRIDE_DATA"; fingerprint "$OVERRIDE_STATE"; fingerprint "$OVERRIDE_SM")
assert_no_writes "$before" "$after" "effective-primary-directories"
expect_code 1 "$rc" "effective primary directory gaps must be threatening"
assert_contains "$out" 'check budget primary=GAP' "primary config override was not inspected"
assert_contains "$out" 'check pointers primary=GAP' "primary data override was not inspected"
assert_contains "$out" 'data/override-missing.md' "primary data override missing pointer evidence"
assert_contains "$out" 'check project-notes primary=GAP' "primary state override was not inspected"
assert_contains "$out" 'check budget override-sm=PASS' "secondmate must retain its default config directory"
assert_contains "$out" 'check pointers override-sm=PASS' "secondmate must retain its default data directory"
pass "primary overrides and secondmate default directories are preserved"

# --- dangling pointer --------------------------------------------------------

DANGLING="$TMP_ROOT/dangling"
make_home "$DANGLING"
ln -s "$DANGLING/data/absent-target.md" "$DANGLING/data/dangling.md"
cat > "$DANGLING/data/captain.md" <<'EOF'
See `data/dangling.md` for the standing rule.
EOF
before=$(fingerprint "$DANGLING")
out=$(run_doctor "$DANGLING" 2>"$TMP_ROOT/err.dangling") && rc=0 || rc=$?
after=$(fingerprint "$DANGLING")
assert_no_writes "$before" "$after" "dangling-pointer"
expect_code 1 "$rc" "dangling pointer must be threatening"
assert_contains "$out" 'check pointers primary=GAP' "dangling pointer missing GAP"
assert_contains "$out" 'data/dangling.md' "dangling pointer missing evidence"
pass "dangling symlinks are broken pointers"

# --- inaccessible and unsafe pointer targets --------------------------------

UNREADABLE_POINTER="$TMP_ROOT/unreadable-pointer"
make_home "$UNREADABLE_POINTER"
printf 'Unreadable target.\n' > "$UNREADABLE_POINTER/data/unreadable-target.md"
cat > "$UNREADABLE_POINTER/data/captain.md" <<'EOF'
See `data/unreadable-target.md`.
EOF
chmod 000 "$UNREADABLE_POINTER/data/unreadable-target.md"
out=$(run_doctor "$UNREADABLE_POINTER" 2>"$TMP_ROOT/err.unreadable-pointer") && rc=0 || rc=$?
chmod 600 "$UNREADABLE_POINTER/data/unreadable-target.md"
expect_code 0 "$rc" "an unreadable pointer target must remain nonblocking"
assert_contains "$out" 'check pointers primary=UNKNOWN' "unreadable pointer target did not produce UNKNOWN"
assert_contains "$out" 'data/unreadable-target.md' "unreadable pointer target missing evidence"

HIDDEN_SYMLINK_POINTER="$TMP_ROOT/hidden-symlink-pointer"
make_home "$HIDDEN_SYMLINK_POINTER"
mkdir -p "$HIDDEN_SYMLINK_POINTER/private"
printf 'Hidden target.\n' > "$HIDDEN_SYMLINK_POINTER/private/target.md"
ln -s "$HIDDEN_SYMLINK_POINTER/private/target.md" "$HIDDEN_SYMLINK_POINTER/data/hidden-target.md"
cat > "$HIDDEN_SYMLINK_POINTER/data/captain.md" <<'EOF'
See `data/hidden-target.md`.
EOF
chmod 000 "$HIDDEN_SYMLINK_POINTER/private"
out=$(run_doctor "$HIDDEN_SYMLINK_POINTER" 2>"$TMP_ROOT/err.hidden-symlink-pointer") && rc=0 || rc=$?
chmod 700 "$HIDDEN_SYMLINK_POINTER/private"
expect_code 0 "$rc" "a symlink to an inaccessible target must remain nonblocking"
assert_contains "$out" 'check pointers primary=UNKNOWN' "inaccessible symlink target was classified as dangling"
assert_contains "$out" 'data/hidden-target.md' "inaccessible symlink target missing evidence"

UNSAFE_POINTER="$TMP_ROOT/unsafe-pointer"
make_home "$UNSAFE_POINTER"
mkfifo "$UNSAFE_POINTER/data/unsafe-target"
cat > "$UNSAFE_POINTER/data/captain.md" <<'EOF'
See `data/unsafe-target`.
EOF
out=$(run_doctor "$UNSAFE_POINTER" 2>"$TMP_ROOT/err.unsafe-pointer") && rc=0 || rc=$?
expect_code 0 "$rc" "an unsafe pointer target must remain nonblocking"
assert_contains "$out" 'check pointers primary=UNKNOWN' "unsafe pointer target did not produce UNKNOWN"
assert_contains "$out" 'data/unsafe-target' "unsafe pointer target missing evidence"
pass "inaccessible and unsafe pointer targets propagate UNKNOWN"

# --- project metadata match is line-exact -----------------------------------

PREFIX="$TMP_ROOT/project-prefix"
make_home "$PREFIX"
printf -- '- demo [direct-PR] - demo project (added 2026-06-22)\n' > "$PREFIX/data/projects.md"
printf 'Standing notes for demo.\n' > "$PREFIX/data/demo-notes.md"
python3 -c 'import os, sys, time; p=sys.argv[1]; t=time.time()-40*86400; os.utime(p, (t, t))' \
  "$PREFIX/data/demo-notes.md"
fm_write_meta "$PREFIX/state/demo-v2.meta" "project=demo-v2" "kind=ship" "window=firstmate:demo-v2"
before=$(fingerprint "$PREFIX")
out=$(run_doctor "$PREFIX" 2>"$TMP_ROOT/err.prefix") && rc=0 || rc=$?
after=$(fingerprint "$PREFIX")
assert_no_writes "$before" "$after" "project-prefix"
expect_code 0 "$rc" "a different project slug must not activate stale notes"
assert_contains "$out" 'check project-notes primary=PASS' "project metadata prefix produced a false stale-note GAP"
pass "project metadata matching is line-exact"

# --- unreadable memory input -------------------------------------------------

UNREADABLE="$TMP_ROOT/unreadable"
make_home "$UNREADABLE"
printf 'rule.reply_style=short\n' > "$UNREADABLE/data/captain.md"
chmod 000 "$UNREADABLE/data/captain.md"
out=$(run_doctor "$UNREADABLE" 2>"$TMP_ROOT/err.unreadable") && rc=0 || rc=$?
chmod 600 "$UNREADABLE/data/captain.md"
expect_code 0 "$rc" "unreadable memory input must remain nonblocking"
assert_contains "$out" 'check pointers primary=UNKNOWN' "unreadable input falsely passed pointers"
assert_contains "$out" 'check staleness primary=UNKNOWN' "unreadable input falsely passed staleness"
assert_contains "$out" 'check contradictions primary=UNKNOWN' "unreadable input falsely passed contradictions"
assert_contains "$out" 'check project-notes primary=UNKNOWN' "unreadable input falsely passed project-notes"
assert_contains "$out" "$UNREADABLE/data/captain.md" "unreadable input missing file-specific cause"
pass "unreadable memory input propagates UNKNOWN with its path"

# --- unreadable memory directory --------------------------------------------

UNREADABLE_DIR="$TMP_ROOT/unreadable-dir"
make_home "$UNREADABLE_DIR"
chmod 000 "$UNREADABLE_DIR/data"
out=$(run_doctor "$UNREADABLE_DIR" 2>"$TMP_ROOT/err.unreadable-dir") && rc=0 || rc=$?
chmod 700 "$UNREADABLE_DIR/data"
expect_code 0 "$rc" "unreadable memory directory must remain nonblocking"
for check in budget pointers staleness contradictions project-notes; do
  assert_contains "$out" "check $check primary=UNKNOWN" "unreadable memory directory falsely passed $check"
done
assert_contains "$out" 'check inherited-hash none=UNKNOWN' "unreadable registry directory falsely passed inherited-hash"
assert_contains "$out" "$UNREADABLE_DIR/data" "unreadable memory directory missing exact cause"
pass "unreadable memory directories propagate UNKNOWN to every consumer"

# --- unreadable project note -------------------------------------------------

UNREADABLE_NOTE="$TMP_ROOT/unreadable-note"
make_home "$UNREADABLE_NOTE"
printf 'Standing notes for demo.\n' > "$UNREADABLE_NOTE/data/demo-notes.md"
chmod 000 "$UNREADABLE_NOTE/data/demo-notes.md"
out=$(run_doctor "$UNREADABLE_NOTE" 2>"$TMP_ROOT/err.unreadable-note") && rc=0 || rc=$?
chmod 600 "$UNREADABLE_NOTE/data/demo-notes.md"
expect_code 0 "$rc" "unreadable project note must remain nonblocking"
assert_contains "$out" 'check project-notes primary=UNKNOWN' "unreadable project note falsely passed project-notes"
assert_contains "$out" "$UNREADABLE_NOTE/data/demo-notes.md" "unreadable project note missing exact cause"
pass "unreadable project notes propagate UNKNOWN"

# --- Markdown link fragments -------------------------------------------------

FRAGMENT="$TMP_ROOT/fragment"
make_home "$FRAGMENT"
printf 'See [startup memory budget](docs/configuration.md#startup-memory-budget).\n' > "$FRAGMENT/data/captain.md"
out=$(run_doctor "$FRAGMENT" 2>"$TMP_ROOT/err.fragment") && rc=0 || rc=$?
expect_code 0 "$rc" "a fragment on an existing local Markdown link must resolve"
assert_contains "$out" 'check pointers primary=PASS' "Markdown link fragment produced a false pointer GAP"
pass "local Markdown link fragments resolve without losing original evidence"

# --- Markdown link destinations ---------------------------------------------

LINK_DESTINATIONS="$TMP_ROOT/link-destinations"
make_home "$LINK_DESTINATIONS"
cat > "$LINK_DESTINATIONS/data/captain.md" <<'EOF'
See [titled rule](data/missing-titled.md "standing rule"), [angle rule](<data/missing-angle.md> "standing angle"), and [filtered rule](data/missing-query.md?view=compact).
EOF
out=$(run_doctor "$LINK_DESTINATIONS" 2>"$TMP_ROOT/err.link-destinations") && rc=0 || rc=$?
expect_code 1 "$rc" "missing Markdown destinations with titles and queries must be threatening"
assert_contains "$out" 'check pointers primary=GAP' "Markdown destinations with metadata were not checked"
assert_contains "$out" 'data/missing-titled.md "standing rule"' "titled Markdown link lost original evidence"
assert_contains "$out" '<data/missing-angle.md> "standing angle"' "titled angle Markdown link lost original evidence"
assert_contains "$out" 'data/missing-query.md?view=compact' "query-bearing Markdown link lost original evidence"
pass "Markdown destinations are parsed separately from retained evidence"

BALANCED_LINKS="$TMP_ROOT/balanced-links"
make_home "$BALANCED_LINKS"
printf 'Balanced link target.\n' > "$BALANCED_LINKS/data/design(v2).md"
printf 'Escaped link target.\n' > "$BALANCED_LINKS/data/design(v3).md"
printf 'Escaped angle target.\n' > "$BALANCED_LINKS/data/design>v4.md"
cat > "$BALANCED_LINKS/data/captain.md" <<'EOF'
See [balanced notes](data/design(v2).md), [escaped notes](data/design\(v3\).md), and [angle notes](<data/design\>v4.md> "angle title").
EOF
out=$(run_doctor "$BALANCED_LINKS" 2>"$TMP_ROOT/err.balanced-links") && rc=0 || rc=$?
expect_code 0 "$rc" "balanced and escaped Markdown destinations must resolve"
assert_contains "$out" 'check pointers primary=PASS' "balanced or escaped Markdown destination produced a false GAP"
pass "balanced and escaped Markdown destinations resolve"

# --- dangling optional pointer ----------------------------------------------

OPTIONAL_DANGLING="$TMP_ROOT/optional-dangling"
make_home "$OPTIONAL_DANGLING"
ln -s "$OPTIONAL_DANGLING/config/missing-crew-harness" "$OPTIONAL_DANGLING/config/crew-harness"
cat > "$OPTIONAL_DANGLING/data/captain.md" <<'EOF'
Harness selection may use `config/crew-harness`.
EOF
out=$(run_doctor "$OPTIONAL_DANGLING" 2>"$TMP_ROOT/err.optional-dangling") && rc=0 || rc=$?
expect_code 1 "$rc" "a dangling optional pointer must be threatening"
assert_contains "$out" 'check pointers primary=GAP' "dangling optional pointer missing GAP"
assert_contains "$out" 'config/crew-harness' "dangling optional pointer missing evidence"
pass "dangling optional paths do not receive the absent-path exception"

# --- backlog section ownership ----------------------------------------------

BACKLOG_SECTION="$TMP_ROOT/backlog-section"
make_home "$BACKLOG_SECTION"
printf -- '- demo [direct-PR] - demo project (added 2026-06-22)\n' > "$BACKLOG_SECTION/data/projects.md"
printf 'Standing notes for demo.\n' > "$BACKLOG_SECTION/data/demo-notes.md"
python3 -c 'import os, sys, time; p=sys.argv[1]; t=time.time()-40*86400; os.utime(p, (t, t))' \
  "$BACKLOG_SECTION/data/demo-notes.md"
cat > "$BACKLOG_SECTION/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] demo-task - Demo queued work (repo: demo) (kind: ship) (since 2026-08-02)

## Done
EOF
out=$(run_doctor "$BACKLOG_SECTION" 2>"$TMP_ROOT/err.backlog-queued") && rc=0 || rc=$?
expect_code 0 "$rc" "queued work must not activate stale project notes"
assert_contains "$out" 'check project-notes primary=PASS' "queued backlog row produced a false stale-note GAP"
cat > "$BACKLOG_SECTION/data/backlog.md" <<'EOF'
## In flight
- [ ] demo-task - Demo active work (repo: demo) (kind: ship) (since 2026-08-02)

## Queued

## Done
EOF
out=$(run_doctor "$BACKLOG_SECTION" 2>"$TMP_ROOT/err.backlog-in-flight") && rc=0 || rc=$?
expect_code 0 "$rc" "stale active notes remain non-threatening"
assert_contains "$out" 'check project-notes primary=GAP' "In flight backlog row did not activate stale notes"
pass "only In flight backlog work activates stale project notes"

ACTIVE_WITHOUT_REGISTRY="$TMP_ROOT/active-without-registry"
make_home "$ACTIVE_WITHOUT_REGISTRY"
printf 'Standing notes for demo.\n' > "$ACTIVE_WITHOUT_REGISTRY/data/demo-notes.md"
printf 'project=demo\n' > "$ACTIVE_WITHOUT_REGISTRY/state/demo.meta"
python3 -c 'import os, sys, time; p=sys.argv[1]; t=time.time()-40*86400; os.utime(p, (t, t))' \
  "$ACTIVE_WITHOUT_REGISTRY/data/demo-notes.md"
out=$(run_doctor "$ACTIVE_WITHOUT_REGISTRY" 2>"$TMP_ROOT/err.active-without-registry") && rc=0 || rc=$?
expect_code 0 "$rc" "stale active notes remain non-threatening without a project registry"
assert_contains "$out" 'check project-notes primary=GAP' "independently proven activity was suppressed without a project registry"
pass "independently proven project activity activates stale notes"

# --- hidden effective roots -------------------------------------------------

HIDDEN_ROOT_HOME="$TMP_ROOT/hidden-root-home"
HIDDEN_ROOT_SM="$TMP_ROOT/hidden-root-sm"
HIDDEN_ROOT_PARENT="$TMP_ROOT/hidden-root-parent"
make_home "$HIDDEN_ROOT_HOME"
make_home "$HIDDEN_ROOT_SM"
mkdir -p "$HIDDEN_ROOT_PARENT/config"
printf '7500\n' > "$HIDDEN_ROOT_PARENT/config/startup-memory-budget"
cat > "$HIDDEN_ROOT_HOME/data/secondmates.md" <<EOF
- hidden-sm - review domain (home: $HIDDEN_ROOT_SM; scope: review work; projects: demo; added 2026-08-02)
EOF
chmod 000 "$HIDDEN_ROOT_PARENT"
out=$(run_doctor_with_dirs "$HIDDEN_ROOT_HOME" "$HIDDEN_ROOT_PARENT/config" \
  "$HIDDEN_ROOT_HOME/data" "$HIDDEN_ROOT_HOME/state" 2>"$TMP_ROOT/err.hidden-root") && rc=0 || rc=$?
chmod 700 "$HIDDEN_ROOT_PARENT"
expect_code 0 "$rc" "a hidden effective config root must remain nonblocking"
assert_contains "$out" 'check inherited-hash hidden-sm=UNKNOWN' "hidden effective config root was classified as absent"
assert_contains "$out" 'config/crew-dispatch.json is unreadable' "hidden effective config root missing inherited evidence"
pass "hidden effective roots propagate UNKNOWN before absence classification"

# --- hidden state override ---------------------------------------------------

HIDDEN_STATE_HOME="$TMP_ROOT/hidden-state-home"
HIDDEN_STATE_PARENT="$TMP_ROOT/hidden-state-parent"
make_home "$HIDDEN_STATE_HOME"
printf -- '- demo [direct-PR] - demo project (added 2026-06-22)\n' > "$HIDDEN_STATE_HOME/data/projects.md"
printf 'Standing notes for demo.\n' > "$HIDDEN_STATE_HOME/data/demo-notes.md"
python3 -c 'import os, sys, time; p=sys.argv[1]; t=time.time()-40*86400; os.utime(p, (t, t))' \
  "$HIDDEN_STATE_HOME/data/demo-notes.md"
mkdir -p "$HIDDEN_STATE_PARENT/state"
fm_write_meta "$HIDDEN_STATE_PARENT/state/demo-task.meta" "project=demo" "kind=ship" "window=firstmate:demo-task"
chmod 000 "$HIDDEN_STATE_PARENT"
out=$(run_doctor_with_dirs "$HIDDEN_STATE_HOME" "$HIDDEN_STATE_HOME/config" \
  "$HIDDEN_STATE_HOME/data" "$HIDDEN_STATE_PARENT/state" --home-local \
  2>"$TMP_ROOT/err.hidden-state") && rc=0 || rc=$?
chmod 700 "$HIDDEN_STATE_PARENT"
expect_code 0 "$rc" "a hidden state override must remain nonblocking"
assert_contains "$out" 'check project-notes primary=UNKNOWN' "hidden state override falsely passed project notes"
assert_contains "$out" "$HIDDEN_STATE_PARENT/state" "hidden state override missing exact evidence"
pass "hidden state overrides propagate UNKNOWN"

# --- literal hash paths ------------------------------------------------------

LITERAL_HASH="$TMP_ROOT/literal-hash"
make_home "$LITERAL_HASH"
printf 'Literal hash filename.\n' > "$LITERAL_HASH/data/foo#bar.md"
cat > "$LITERAL_HASH/data/captain.md" <<'EOF'
See `data/foo#bar.md` and [startup memory budget](docs/configuration.md#startup-memory-budget).
EOF
out=$(run_doctor "$LITERAL_HASH" 2>"$TMP_ROOT/err.literal-hash") && rc=0 || rc=$?
expect_code 0 "$rc" "literal hash paths and Markdown fragments must both resolve"
assert_contains "$out" 'check pointers primary=PASS' "literal backtick hash path was treated as a fragment"
pass "pointer provenance preserves literal hashes and strips link fragments"

# --- memory facts precede configured default comparison ---------------------

FACT_CONFLICT="$TMP_ROOT/fact-conflict"
make_home "$FACT_CONFLICT"
printf 'claude\n' > "$FACT_CONFLICT/config/crew-harness"
printf '%s\n' '{"default":{"harness":"codex"}}' > "$FACT_CONFLICT/config/crew-dispatch.json"
printf 'rule.default_harness=codex\n' > "$FACT_CONFLICT/data/captain.md"
printf 'rule.default_harness=claude\n' > "$FACT_CONFLICT/data/learnings.md"
out=$(run_doctor "$FACT_CONFLICT" 2>"$TMP_ROOT/err.fact-conflict") && rc=0 || rc=$?
expect_code 1 "$rc" "conflicting memory facts must be threatening"
assert_contains "$out" 'check contradictions primary=GAP' "configured values hid conflicting memory facts"
assert_contains "$out" 'rule.default_harness' "memory-fact conflict missing evidence"
pass "memory facts conflict before configured-default comparison"

# --- configured dispatch precedence -----------------------------------------

DISPATCH_PRECEDENCE="$TMP_ROOT/dispatch-precedence"
make_home "$DISPATCH_PRECEDENCE"
printf 'claude\n' > "$DISPATCH_PRECEDENCE/config/crew-harness"
printf '%s\n' '{"default":{"harness":"codex"}}' > "$DISPATCH_PRECEDENCE/config/crew-dispatch.json"
printf 'rule.default_harness=claude\n' > "$DISPATCH_PRECEDENCE/data/captain.md"
out=$(run_doctor "$DISPATCH_PRECEDENCE" 2>"$TMP_ROOT/err.dispatch-precedence") && rc=0 || rc=$?
expect_code 1 "$rc" "dispatch default must precede the static harness"
assert_contains "$out" 'configured-effective=codex' "dispatch precedence gap missing effective default"
pass "configured dispatch default precedes static crew harness"

# --- unresolved and unreadable static harness -------------------------------

STATIC_DEFAULT="$TMP_ROOT/static-default"
make_home "$STATIC_DEFAULT"
printf 'default\n' > "$STATIC_DEFAULT/config/crew-harness"
printf 'rule.default_harness=claude\n' > "$STATIC_DEFAULT/data/captain.md"
out=$(run_doctor "$STATIC_DEFAULT" 2>"$TMP_ROOT/err.static-default") && rc=0 || rc=$?
expect_code 0 "$rc" "session-dependent static harness must remain nonblocking"
assert_contains "$out" 'check contradictions primary=UNKNOWN' "literal default static harness produced a verdict"

STATIC_UNREADABLE="$TMP_ROOT/static-unreadable"
make_home "$STATIC_UNREADABLE"
printf 'claude\n' > "$STATIC_UNREADABLE/config/crew-harness"
printf 'rule.default_harness=claude\n' > "$STATIC_UNREADABLE/data/captain.md"
chmod 000 "$STATIC_UNREADABLE/config/crew-harness"
out=$(run_doctor "$STATIC_UNREADABLE" 2>"$TMP_ROOT/err.static-unreadable") && rc=0 || rc=$?
chmod 600 "$STATIC_UNREADABLE/config/crew-harness"
expect_code 0 "$rc" "unreadable static harness must remain nonblocking"
assert_contains "$out" 'check contradictions primary=UNKNOWN' "unreadable static harness falsely passed contradictions"
assert_contains "$out" 'static crew harness is unreadable' "unreadable static harness missing cause"
pass "unresolved and unreadable harness configuration propagates UNKNOWN"

# --- hidden pointer target ---------------------------------------------------

HIDDEN_POINTER="$TMP_ROOT/hidden-pointer"
make_home "$HIDDEN_POINTER"
printf 'Required configuration.\n' > "$HIDDEN_POINTER/config/required.md"
cat > "$HIDDEN_POINTER/data/captain.md" <<'EOF'
See `config/required.md`.
EOF
chmod 000 "$HIDDEN_POINTER/config"
out=$(run_doctor "$HIDDEN_POINTER" 2>"$TMP_ROOT/err.hidden-pointer") && rc=0 || rc=$?
chmod 700 "$HIDDEN_POINTER/config"
expect_code 0 "$rc" "a hidden pointer target must remain nonblocking"
assert_contains "$out" 'check pointers primary=UNKNOWN' "hidden pointer target became a threatening missing-path gap"
assert_contains "$out" 'config/required.md' "hidden pointer target missing evidence"
pass "hidden pointer targets propagate UNKNOWN"

# --- unreadable active-secondmate registry ----------------------------------

UNREADABLE_REGISTRY="$TMP_ROOT/unreadable-registry"
make_home "$UNREADABLE_REGISTRY"
printf 'active_secondmate: reviews\n' > "$UNREADABLE_REGISTRY/data/captain.md"
printf -- '- reviews - review domain (home: /tmp/reviews; scope: review work; projects: demo; added 2026-08-02)\n' \
  > "$UNREADABLE_REGISTRY/data/secondmates.md"
chmod 000 "$UNREADABLE_REGISTRY/data/secondmates.md"
out=$(run_doctor "$UNREADABLE_REGISTRY" 2>"$TMP_ROOT/err.unreadable-registry") && rc=0 || rc=$?
chmod 600 "$UNREADABLE_REGISTRY/data/secondmates.md"
expect_code 0 "$rc" "unreadable registry must remain nonblocking"
assert_contains "$out" 'check staleness primary=UNKNOWN' "unreadable registry made an active secondmate look retired"
assert_contains "$out" 'secondmates.md is unreadable' "unreadable registry missing cause"
pass "unreadable active-secondmate registries propagate UNKNOWN"

# --- project slug literal matching ------------------------------------------

DOTTED_SLUG="$TMP_ROOT/dotted-slug"
make_home "$DOTTED_SLUG"
printf 'Standing notes for demo.\n' > "$DOTTED_SLUG/data/demo-notes.md"
python3 -c 'import os, sys, time; p=sys.argv[1]; t=time.time()-40*86400; os.utime(p, (t, t))' \
  "$DOTTED_SLUG/data/demo-notes.md"
fm_write_meta "$DOTTED_SLUG/state/demo-v2.meta" "project=demo.v2" "kind=ship" "window=firstmate:demo-v2"
out=$(run_doctor "$DOTTED_SLUG" 2>"$TMP_ROOT/err.dotted-slug") && rc=0 || rc=$?
expect_code 0 "$rc" "a dotted activity slug must not match another project's notes"
assert_contains "$out" 'check project-notes primary=PASS' "dotted activity slug produced a false active-note gap"
pass "project activity metadata compares slugs literally"

# --- unsafe memory candidates -----------------------------------------------

UNSAFE_MEMORY="$TMP_ROOT/unsafe-memory"
make_home "$UNSAFE_MEMORY"
ln -s "$UNSAFE_MEMORY/data/captain.md" "$UNSAFE_MEMORY/data/model-routing.md"
out=$(run_doctor "$UNSAFE_MEMORY" 2>"$TMP_ROOT/err.unsafe-memory") && rc=0 || rc=$?
expect_code 0 "$rc" "unsafe memory candidates must remain nonblocking"
for check in pointers staleness contradictions project-notes; do
  assert_contains "$out" "check $check primary=UNKNOWN" "unsafe memory candidate falsely passed $check"
done
assert_contains "$out" 'memory input is unsafe' "unsafe memory candidate missing exact cause"
assert_contains "$out" "$UNSAFE_MEMORY/data/model-routing.md" "unsafe memory candidate missing path"
pass "unsafe existing memory candidates propagate UNKNOWN"

# --- canonical dispatch validation ------------------------------------------

INVALID_DISPATCH="$TMP_ROOT/invalid-dispatch"
make_home "$INVALID_DISPATCH"
printf '%s\n' '{"rules":"bad","default":{"harness":"codex"}}' > "$INVALID_DISPATCH/config/crew-dispatch.json"
printf 'rule.default_harness=codex\n' > "$INVALID_DISPATCH/data/captain.md"
out=$(run_doctor "$INVALID_DISPATCH" 2>"$TMP_ROOT/err.invalid-dispatch") && rc=0 || rc=$?
expect_code 0 "$rc" "invalid dispatch config must remain nonblocking"
assert_contains "$out" 'check contradictions primary=UNKNOWN' "invalid dispatch config falsely passed contradictions"
assert_contains "$out" 'rules must be an array' "invalid dispatch config missing canonical validation cause"
pass "dispatch contradictions reuse canonical configuration validation"

# --- registry binding validation --------------------------------------------

INVALID_REGISTRY="$TMP_ROOT/invalid-registry"
make_home "$INVALID_REGISTRY"
printf 'active_secondmate: relative-sm\n' > "$INVALID_REGISTRY/data/captain.md"
printf -- '- relative-sm - review domain (home: relative-sm; scope: review work; projects: demo; added 2026-08-02)\n' \
  > "$INVALID_REGISTRY/data/secondmates.md"
out=$(run_doctor "$INVALID_REGISTRY" 2>"$TMP_ROOT/err.invalid-registry") && rc=0 || rc=$?
expect_code 0 "$rc" "invalid registry bindings must remain nonblocking"
assert_contains "$out" 'check staleness primary=UNKNOWN' "invalid registry binding made an active secondmate look retired"
assert_contains "$out" 'check inherited-hash none=UNKNOWN' "invalid registry binding falsely reported no secondmates"
assert_contains "$out" 'unsafe non-absolute secondmate home' "invalid registry binding missing exact cause"
case "$out" in
  *' relative-sm='*) fail "invalid relative registry binding was traversed: $out" ;;
esac
pass "fleet traversal rejects invalid registry bindings"

# --- verified gaps outrank incomplete evidence ------------------------------

MIXED_POINTER="$TMP_ROOT/mixed-pointer"
make_home "$MIXED_POINTER"
printf 'Unreadable target.\n' > "$MIXED_POINTER/data/unreadable-target.md"
cat > "$MIXED_POINTER/data/captain.md" <<'EOF'
See `data/unreadable-target.md` and `data/proven-missing.md`.
EOF
chmod 000 "$MIXED_POINTER/data/unreadable-target.md"
out=$(run_doctor "$MIXED_POINTER" 2>"$TMP_ROOT/err.mixed-pointer") && rc=0 || rc=$?
chmod 600 "$MIXED_POINTER/data/unreadable-target.md"
expect_code 1 "$rc" "a proven pointer gap must outrank an unreadable target"
assert_contains "$out" 'check pointers primary=GAP' "an unreadable target hid a proven pointer gap"
assert_contains "$out" 'data/proven-missing.md' "mixed pointer evidence lost the proven missing target"

MIXED_CONTRADICTION="$TMP_ROOT/mixed-contradiction"
make_home "$MIXED_CONTRADICTION"
printf 'claude\n' > "$MIXED_CONTRADICTION/config/crew-harness"
printf 'rule.default_harness=codex\n' > "$MIXED_CONTRADICTION/data/captain.md"
chmod 000 "$MIXED_CONTRADICTION/data/learnings.md"
out=$(run_doctor "$MIXED_CONTRADICTION" 2>"$TMP_ROOT/err.mixed-contradiction") && rc=0 || rc=$?
chmod 600 "$MIXED_CONTRADICTION/data/learnings.md"
expect_code 1 "$rc" "a proven contradiction must outrank an unreadable memory file"
assert_contains "$out" 'check contradictions primary=GAP' "an unreadable memory file hid a proven contradiction"

MIXED_HASH_PRIMARY="$TMP_ROOT/mixed-hash-primary"
MIXED_HASH_SM="$TMP_ROOT/mixed-hash-sm"
make_home "$MIXED_HASH_PRIMARY"
make_home "$MIXED_HASH_SM"
printf '{}\n' > "$MIXED_HASH_SM/config/crew-dispatch.json"
chmod 000 "$MIXED_HASH_SM/config/crew-dispatch.json"
printf 'Divergent shared memory.\n' > "$MIXED_HASH_SM/data/captain-shared.md"
cat > "$MIXED_HASH_PRIMARY/data/secondmates.md" <<EOF
- mixed-hash - review domain (home: $MIXED_HASH_SM; scope: review work; projects: demo; added 2026-08-02)
EOF
out=$(run_doctor "$MIXED_HASH_PRIMARY" 2>"$TMP_ROOT/err.mixed-hash") && rc=0 || rc=$?
chmod 600 "$MIXED_HASH_SM/config/crew-dispatch.json"
expect_code 1 "$rc" "a proven inherited mismatch must outrank an unreadable inherited file"
assert_contains "$out" 'check inherited-hash mixed-hash=GAP' "an unreadable inherited file hid a proven hash mismatch"
assert_contains "$out" 'data/captain-shared.md' "mixed inherited evidence lost the proven mismatch"
pass "verified gaps outrank incomplete evidence"

# --- context-aware absent home paths ----------------------------------------

PRIMARY_CONTEXT_PATHS="$TMP_ROOT/primary-context-paths"
make_home "$PRIMARY_CONTEXT_PATHS"
cat > "$PRIMARY_CONTEXT_PATHS/data/captain.md" <<'EOF'
Primary-only and lazy paths may be absent: `data/charter.md`, `state/x-context/`, `state/x-inbox/`, `state/x-outbox/`, `state/public-followup/`, `state/procevent/`, `state/procevent-inbox/`, `state/slack-inbox/`, `state/slack-ack-pending/`, `state/slack-acked/`, `state/slack-offered/`, `state/slack-refused/`, `state/slack-decision-bindings/`, `state/slack-poll.cursor`, and `state/pending-replies/`.
EOF
out=$(FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/empty-procevent-claims" \
  run_doctor "$PRIMARY_CONTEXT_PATHS" --home-local \
  2>"$TMP_ROOT/err.primary-context-paths") && rc=0 || rc=$?
expect_code 0 "$rc" "primary-only and lazy absent paths must not be threatening in a primary home"
assert_contains "$out" 'check pointers primary=PASS' "owner-defined lazy state paths produced a pointer gap"

SLACK_ACTIVE="$TMP_ROOT/slack-active"
make_home "$SLACK_ACTIVE"
printf 'FM_SLACK_BOT_TOKEN=fixture-token\n' > "$SLACK_ACTIVE/.env"
printf 'C1234567890\n' > "$SLACK_ACTIVE/config/slack-captain-channel"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf 'The configured Slack transport may use `state/slack-inbox/`, `state/slack-ack-pending/`, `state/slack-acked/`, `state/slack-offered/`, `state/slack-refused/`, `state/slack-decision-bindings/`, and `state/slack-poll.cursor`.\n' > "$SLACK_ACTIVE/data/captain.md"
out=$(run_doctor "$SLACK_ACTIVE" --home-local 2>"$TMP_ROOT/err.slack-active") && rc=0 || rc=$?
expect_code 0 "$rc" "an active Slack home without message history must remain fail-open"
assert_contains "$out" 'check pointers primary=UNKNOWN' \
  "active Slack state without durable message evidence was incorrectly optional or deleted"

SLACK_DELETED="$TMP_ROOT/slack-deleted"
make_home "$SLACK_DELETED"
mkdir -m 700 "$SLACK_DELETED/state/slack-offered"
printf '1786735224.690829\n' > "$SLACK_DELETED/state/slack-offered/1786735224.690829"
chmod 600 "$SLACK_DELETED/state/slack-offered/1786735224.690829"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf 'An offered Slack message requires `state/slack-inbox/`.\n' > "$SLACK_DELETED/data/captain.md"
out=$(run_doctor "$SLACK_DELETED" --home-local 2>"$TMP_ROOT/err.slack-deleted") && rc=0 || rc=$?
expect_code 1 "$rc" "deleting an inbox after durable Slack activity must be threatening"
assert_contains "$out" 'check pointers primary=GAP' \
  "durable Slack activity did not require its inbox"

PENDING_ACTIVE="$TMP_ROOT/pending-active"
make_home "$PENDING_ACTIVE"
fm_write_meta "$PENDING_ACTIVE/state/secondmate.meta" "kind=secondmate" "window=firstmate:secondmate"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf 'Secondmate requests may use `state/pending-replies/`.\n' > "$PENDING_ACTIVE/data/captain.md"
out=$(run_doctor "$PENDING_ACTIVE" --home-local 2>"$TMP_ROOT/err.pending-active") && rc=0 || rc=$?
expect_code 0 "$rc" "a secondmate home without persisted request evidence must remain fail-open"
assert_contains "$out" 'check pointers primary=UNKNOWN' \
  "possible pending-reply state was incorrectly optional or deleted"

PENDING_DELETED="$TMP_ROOT/pending-deleted"
make_home "$PENDING_DELETED"
printf 'pending-reply-missed: task=secondmate pending-reply-id=abcdef0123456789 request=review\n' \
  > "$PENDING_DELETED/state/secondmate.status"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf 'A recorded missed report requires `state/pending-replies/`.\n' \
  > "$PENDING_DELETED/data/captain.md"
out=$(run_doctor "$PENDING_DELETED" --home-local 2>"$TMP_ROOT/err.pending-deleted") && rc=0 || rc=$?
expect_code 1 "$rc" "deleting pending-reply records after durable owner evidence must be threatening"
assert_contains "$out" 'check pointers primary=GAP' \
  "durable pending-reply evidence did not require its record directory"
pass "Slack inbox and pending replies follow their owner state"

mkdir -p "$TMP_ROOT/no-relay-bin"
cat > "$TMP_ROOT/no-relay-bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'called\n' > "${FM_TASKS_AXI_CALLS:?}"
exit 97
SH
chmod +x "$TMP_ROOT/no-relay-bin/tasks-axi"
rm -f "$TMP_ROOT/no-relay-tasks-axi.calls"
out=$(PATH="$TMP_ROOT/no-relay-bin:$PATH" FM_TASKS_AXI_CALLS="$TMP_ROOT/no-relay-tasks-axi.calls" \
  FMX_PAIRING_TOKEN='' run_doctor "$PRIMARY_CONTEXT_PATHS" --home-local \
  2>"$TMP_ROOT/err.primary-context-no-relay") && rc=0 || rc=$?
expect_code 0 "$rc" "relay-disabled lazy paths must remain non-threatening"
assert_absent "$TMP_ROOT/no-relay-tasks-axi.calls" \
  "relay-disabled public-followup absence inspection must not invoke tasks-axi"

mkdir -p "$TMP_ROOT/hanging-query-bin"
cat > "$TMP_ROOT/hanging-query-bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
: > "${FM_TASKS_AXI_CALLED:?}"
if IFS= read -r line; then
  printf '%s\n' "$line" > "${FM_TASKS_AXI_STDIN:?}"
fi
sleep 30
SH
chmod +x "$TMP_ROOT/hanging-query-bin/tasks-axi"
rm -f "$TMP_ROOT/hanging-query.called" "$TMP_ROOT/hanging-query.stdin"
before=$(fingerprint "$PRIMARY_CONTEXT_PATHS")
started=$(date +%s)
out=$(printf 'caller input must stay unread\n' | \
  PATH="$TMP_ROOT/hanging-query-bin:$PATH" \
  FM_TASKS_AXI_CALLED="$TMP_ROOT/hanging-query.called" \
  FM_TASKS_AXI_STDIN="$TMP_ROOT/hanging-query.stdin" \
  FM_PF_ABSENCE_QUERY_TIMEOUT=1 FMX_PAIRING_TOKEN=fixture-token \
  run_doctor "$PRIMARY_CONTEXT_PATHS" --home-local \
  2>"$TMP_ROOT/err.primary-context-hanging-query") && rc=0 || rc=$?
elapsed=$(($(date +%s) - started))
after=$(fingerprint "$PRIMARY_CONTEXT_PATHS")
assert_no_writes "$before" "$after" "hanging-public-followup-query"
expect_code 0 "$rc" "an unavailable public-followup owner query must remain fail-open"
[ "$elapsed" -le 4 ] || fail "public-followup absence inspection exceeded its bound (${elapsed}s)"
assert_present "$TMP_ROOT/hanging-query.called" \
  "active public-followup absence inspection did not invoke its owner query"
assert_absent "$TMP_ROOT/hanging-query.stdin" \
  "public-followup absence inspection left caller stdin attached"
assert_contains "$out" 'check pointers primary=UNKNOWN' \
  "a timed-out public-followup owner query did not propagate UNKNOWN"
pass "public-followup absence inspection closes stdin and remains bounded"

PROCEVENT_ACTIVE="$TMP_ROOT/procevent-active"
PROCEVENT_CLAIMS="$TMP_ROOT/procevent-active-claims"
make_home "$PROCEVENT_ACTIVE"
mkdir -p "$PROCEVENT_ACTIVE/state/procevent" "$PROCEVENT_CLAIMS"
printf 'lavish\n' > "$PROCEVENT_ACTIVE/state/procevent/review.source"
cat > "$PROCEVENT_ACTIVE/data/captain.md" <<'EOF'
An active source may not have published `state/procevent-inbox/` yet.
EOF
out=$(FM_PROCEVENT_CLAIM_ROOT="$PROCEVENT_CLAIMS" \
  run_doctor "$PROCEVENT_ACTIVE" --home-local \
  2>"$TMP_ROOT/err.procevent-active") && rc=0 || rc=$?
expect_code 0 "$rc" "an active source with no published result must remain fail-open"
assert_contains "$out" 'check pointers primary=UNKNOWN' \
  "active process-event state was incorrectly classified as optional or deleted"

PROCEVENT_DELETED_REGISTRY="$TMP_ROOT/procevent-deleted-registry"
PROCEVENT_DELETED_CLAIMS="$TMP_ROOT/procevent-deleted-registry-claims"
make_home "$PROCEVENT_DELETED_REGISTRY"
mkdir -p "$PROCEVENT_DELETED_CLAIMS"
printf '%s\n999999\ntoken\nidentity\n%s\n1:1\nactive\n' \
  "$PROCEVENT_DELETED_REGISTRY" "$PROCEVENT_DELETED_REGISTRY/state/procevent" \
  > "$PROCEVENT_DELETED_CLAIMS/review.claim"
cat > "$PROCEVENT_DELETED_REGISTRY/data/captain.md" <<'EOF'
The owned registration uses `state/procevent/`.
EOF
out=$(FM_PROCEVENT_CLAIM_ROOT="$PROCEVENT_DELETED_CLAIMS" \
  run_doctor "$PROCEVENT_DELETED_REGISTRY" --home-local \
  2>"$TMP_ROOT/err.procevent-deleted-registry") && rc=0 || rc=$?
expect_code 1 "$rc" "deleting a claimed process-event registry must be threatening"
assert_contains "$out" 'check pointers primary=GAP' \
  "a live owner claim did not require its process-event registry"

PROCEVENT_DELETED_INBOX="$TMP_ROOT/procevent-deleted-inbox"
make_home "$PROCEVENT_DELETED_INBOX"
printf '1\t1\tcheck\tprocevent:review:1\tcheck: procevent lavish review 1\n' \
  > "$PROCEVENT_DELETED_INBOX/state/.wake-queue"
cat > "$PROCEVENT_DELETED_INBOX/data/captain.md" <<'EOF'
A published capture uses `state/procevent-inbox/`.
EOF
out=$(FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/empty-procevent-claims" \
  run_doctor "$PROCEVENT_DELETED_INBOX" --home-local \
  2>"$TMP_ROOT/err.procevent-deleted-inbox") && rc=0 || rc=$?
expect_code 1 "$rc" "deleting an inbox named by a durable wake must be threatening"
assert_contains "$out" 'check pointers primary=GAP' \
  "durable publication state did not require its process-event inbox"
pass "process-event path absence follows registration and publication owner state"

ACTIVE_X_PATHS="$TMP_ROOT/active-x-paths"
make_home "$ACTIVE_X_PATHS"
cat > "$ACTIVE_X_PATHS/data/captain.md" <<'EOF'
An active relay home may have owned state at `state/x-context/`, `state/x-inbox/`, and `state/x-outbox/`.
EOF
before=$(fingerprint "$ACTIVE_X_PATHS")
out=$(FMX_PAIRING_TOKEN=fixture-token run_doctor "$ACTIVE_X_PATHS" --home-local \
  2>"$TMP_ROOT/err.active-x-paths") && rc=0 || rc=$?
after=$(fingerprint "$ACTIVE_X_PATHS")
assert_no_writes "$before" "$after" "active-x-paths"
expect_code 0 "$rc" "unresolved active X path absence must remain fail-open"
assert_contains "$out" 'check pointers primary=UNKNOWN' \
  "active X path absence was incorrectly accepted as optional"
assert_contains "$out" 'state/x-context/' "active X path UNKNOWN lost its evidence"

UNREADABLE_RELAY_ENV="$TMP_ROOT/unreadable-relay-env"
make_home "$UNREADABLE_RELAY_ENV"
printf 'FMX_PAIRING_TOKEN=fixture-token\n' > "$UNREADABLE_RELAY_ENV/.env"
chmod 000 "$UNREADABLE_RELAY_ENV/.env"
cat > "$UNREADABLE_RELAY_ENV/data/captain.md" <<'EOF'
Relay-owned state may use `state/x-inbox/` and `state/public-followup/`.
EOF
rm -f "$TMP_ROOT/unreadable-relay-tasks-axi.calls"
out=$(PATH="$TMP_ROOT/no-relay-bin:$PATH" FM_TASKS_AXI_CALLS="$TMP_ROOT/unreadable-relay-tasks-axi.calls" \
  run_doctor "$UNREADABLE_RELAY_ENV" --home-local \
  2>"$TMP_ROOT/err.unreadable-relay-env") && rc=0 || rc=$?
chmod 600 "$UNREADABLE_RELAY_ENV/.env"
expect_code 0 "$rc" "unreadable relay configuration must remain fail-open"
assert_contains "$out" 'check pointers primary=UNKNOWN' \
  "unreadable relay configuration was treated as inactive"
assert_contains "$out" 'state/x-inbox/' "unreadable X activation lost its UNKNOWN evidence"
assert_contains "$out" 'state/public-followup/' \
  "unreadable public-followup activation lost its UNKNOWN evidence"
assert_absent "$TMP_ROOT/unreadable-relay-tasks-axi.calls" \
  "unreadable relay configuration invoked the public-followup owner query"
pass "unreadable relay activation state propagates UNKNOWN"

SECONDARY_CONTEXT_PRIMARY="$TMP_ROOT/secondary-context-primary"
SECONDARY_CONTEXT_SM="$TMP_ROOT/secondary-context-sm"
make_home "$SECONDARY_CONTEXT_PRIMARY"
make_home "$SECONDARY_CONTEXT_SM"
cat > "$SECONDARY_CONTEXT_SM/data/captain.md" <<'EOF'
A secondmate requires `data/charter.md`; `state/x-context/`, `state/x-inbox/`, `state/x-outbox/`, and `state/public-followup/` remain lazy.
EOF
cat > "$SECONDARY_CONTEXT_PRIMARY/data/secondmates.md" <<EOF
- context-sm - review domain (home: $SECONDARY_CONTEXT_SM; scope: review work; projects: demo; added 2026-08-02)
EOF
out=$(run_doctor "$SECONDARY_CONTEXT_PRIMARY" 2>"$TMP_ROOT/err.secondary-context-paths") && rc=0 || rc=$?
expect_code 1 "$rc" "an absent secondmate charter must remain a threatening pointer gap"
assert_contains "$out" 'check pointers context-sm=GAP' "primary charter semantics leaked into a secondmate home"
assert_contains "$out" 'data/charter.md' "secondmate charter gap lost its evidence"
case "$out" in
  *'check pointers context-sm=GAP'*'state/x-context/'*) fail "lazy x-context absence became a secondmate pointer gap" ;;
  *'check pointers context-sm=GAP'*'state/x-inbox/'*) fail "lazy x-inbox absence became a secondmate pointer gap" ;;
  *'check pointers context-sm=GAP'*'state/x-outbox/'*) fail "lazy x-outbox absence became a secondmate pointer gap" ;;
  *'check pointers context-sm=GAP'*'state/public-followup/'*) fail "lazy public-followup absence became a secondmate pointer gap" ;;
esac
pass "absent home paths respect primary and secondmate context"

PUBLIC_FOLLOWUP_DELETED="$TMP_ROOT/public-followup-deleted"
make_home "$PUBLIC_FOLLOWUP_DELETED"
command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required for public-followup pointer coverage"
printf 'FMX_PAIRING_TOKEN=fixture-token\n' > "$PUBLIC_FOLLOWUP_DELETED/.env"
jq -n '{request_id:"req-doctor", platform:"x",
  context_binding:{version:"ctx1", value:"ctx1_req-doctor"},
  public_safe_summary:"verify promised final state",
  received_at:"2026-08-01T10:00:00Z",
  followup_expires_at:"2099-08-08T10:00:00Z",
  reservation_expires_at:"2099-08-08T10:00:00Z"}' > "$PUBLIC_FOLLOWUP_DELETED/request.json"
jq -n '{type:"pr-merged", project:"firstmate",
  required_deliverables:["pr_url"], completion_policy:"all-required"}' \
  > "$PUBLIC_FOLLOWUP_DELETED/expected.json"
jq -n '{relation_id:"rel-doctor", work_ref:{home_id:"main", task_id:"doctor-work"},
  role:"fulfills", required:true, generation:1}' > "$PUBLIC_FOLLOWUP_DELETED/relation.json"
(
  cd "$PUBLIC_FOLLOWUP_DELETED" || exit 1
  tasks-axi public-followup add pf-doctor \
    --request-context-file request.json --purpose promised-final \
    --expected-final-file expected.json --expires-at 2099-08-08T10:00:00Z >/dev/null \
    && tasks-axi public-followup bind-work pf-doctor --relation-file relation.json >/dev/null
) || fail "could not create the public-followup pointer fixture"
FM_HOME="$PUBLIC_FOLLOWUP_DELETED" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-public-followup.sh" register pf-doctor --relation rel-doctor \
    --work-home main --work-id doctor-work --generation 1 >/dev/null \
  || fail "could not register the public-followup pointer fixture"
assert_present "$PUBLIC_FOLLOWUP_DELETED/state/public-followup/registry/pf-doctor" \
  "public-followup registration did not create its private transport"
rm -rf "$PUBLIC_FOLLOWUP_DELETED/state/public-followup"
cat > "$PUBLIC_FOLLOWUP_DELETED/data/captain.md" <<'EOF'
The registered promised final uses `state/public-followup/`.
EOF
before=$(fingerprint "$PUBLIC_FOLLOWUP_DELETED")
out=$(run_doctor "$PUBLIC_FOLLOWUP_DELETED" 2>"$TMP_ROOT/err.public-followup-deleted") && rc=0 || rc=$?
after=$(fingerprint "$PUBLIC_FOLLOWUP_DELETED")
assert_no_writes "$before" "$after" "deleted-public-followup"
expect_code 1 "$rc" "deleting transport for a live public commitment must be threatening"
assert_contains "$out" 'check pointers primary=GAP' "deleted live public-followup transport missing pointer GAP"
assert_contains "$out" 'state/public-followup/' "deleted live public-followup transport lost its evidence"
pass "public-followup absence follows live typed commitment state"

# --- primary-home-only pointers in secondmate homes -------------------------

SECONDARY_PRIMARY_ONLY="$TMP_ROOT/secondary-primary-only"
make_home "$SECONDARY_PRIMARY_ONLY"
printf 'shipwright-reviewer\n' > "$SECONDARY_PRIMARY_ONLY/.fm-secondmate-home"
cat > "$SECONDARY_PRIMARY_ONLY/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Directory map: `data/tooling-limits.md` in the PRIMARY home only.
Archives in `data/entities/retired-2026-08-24/` in the PRIMARY home only.
EOF
before=$(fingerprint "$SECONDARY_PRIMARY_ONLY")
out=$(run_doctor "$SECONDARY_PRIMARY_ONLY" --home-local 2>"$TMP_ROOT/err.secondary-primary-only") && rc=0 || rc=$?
after=$(fingerprint "$SECONDARY_PRIMARY_ONLY")
assert_no_writes "$before" "$after" "secondary-primary-only"
expect_code 0 "$rc" "primary-home-only pointers must not be threatening in a secondmate home"
assert_contains "$out" 'check pointers primary=PASS' \
  "primary-home-only pointers produced a threatening GAP in a secondmate home"
case "$out" in
  *'data/tooling-limits.md'*) fail "primary-home-only tooling-limits path was treated as missing: $out" ;;
  *'data/entities/retired-2026-08-24/'*) fail "primary-home-only entities archive was treated as missing: $out" ;;
esac

PRIMARY_PRIMARY_ONLY="$TMP_ROOT/primary-primary-only"
make_home "$PRIMARY_PRIMARY_ONLY"
cat > "$PRIMARY_PRIMARY_ONLY/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Directory map: `data/tooling-limits.md` in the PRIMARY home only.
Archives in `data/entities/retired-2026-08-24/` in the PRIMARY home only.
EOF
out=$(run_doctor "$PRIMARY_PRIMARY_ONLY" --home-local 2>"$TMP_ROOT/err.primary-primary-only") && rc=0 || rc=$?
expect_code 1 "$rc" "primary-home-only pointers must remain required in a primary home"
assert_contains "$out" 'check pointers primary=GAP' \
  "primary home did not require declared primary-only pointers"
assert_contains "$out" 'data/tooling-limits.md' \
  "primary-home-only tooling-limits gap lost its evidence"
assert_contains "$out" 'data/entities/retired-2026-08-24/' \
  "primary-home-only entities archive gap lost its evidence"
pass "primary-home-only pointers are out of scope in secondmate homes only"

SECONDARY_PRIMARY_ONLY_LINK="$TMP_ROOT/secondary-primary-only-link"
make_home "$SECONDARY_PRIMARY_ONLY_LINK"
printf 'shipwright-reviewer\n' > "$SECONDARY_PRIMARY_ONLY_LINK/.fm-secondmate-home"
cat > "$SECONDARY_PRIMARY_ONLY_LINK/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Directory map: [tooling limits](data/tooling-limits.md) in the PRIMARY home only.
EOF
out=$(run_doctor "$SECONDARY_PRIMARY_ONLY_LINK" --home-local 2>"$TMP_ROOT/err.secondary-primary-only-link") && rc=0 || rc=$?
expect_code 0 "$rc" "Markdown primary-home-only links must be optional in a secondmate home"
assert_contains "$out" 'check pointers primary=PASS' \
  "Markdown primary-home-only link produced a threatening GAP"
pass "Markdown primary-home-only links follow the secondmate exception"

OVERRIDE_DATA="$TMP_ROOT/secondary-primary-only-override-data"
mkdir -p "$OVERRIDE_DATA"
cat > "$OVERRIDE_DATA/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Directory map: `data/tooling-limits.md` in the PRIMARY home only.
EOF
out=$(run_doctor_with_dirs "$SECONDARY_PRIMARY_ONLY" "$SECONDARY_PRIMARY_ONLY/config" "$OVERRIDE_DATA" "$SECONDARY_PRIMARY_ONLY/state" --home-local 2>"$TMP_ROOT/err.secondary-primary-only-override") && rc=0 || rc=$?
expect_code 0 "$rc" "primary-home-only declarations must use the effective data root"
assert_contains "$out" 'check pointers primary=PASS' \
  "effective data root was ignored for primary-home-only declarations"
pass "primary-home-only declarations use the effective data root"

SECONDARY_PRIMARY_ONLY_FRAGMENT="$TMP_ROOT/secondary-primary-only-fragment"
make_home "$SECONDARY_PRIMARY_ONLY_FRAGMENT"
printf 'shipwright-reviewer\n' > "$SECONDARY_PRIMARY_ONLY_FRAGMENT/.fm-secondmate-home"
printf '%s\n' 'Pointer: [tooling limits](data/tooling-limits.md#section).' > "$SECONDARY_PRIMARY_ONLY_FRAGMENT/data/captain.md"
cat > "$SECONDARY_PRIMARY_ONLY_FRAGMENT/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Directory map: `data/tooling-limits.md` in the PRIMARY home only.
EOF
out=$(run_doctor "$SECONDARY_PRIMARY_ONLY_FRAGMENT" --home-local 2>"$TMP_ROOT/err.secondary-primary-only-fragment") && rc=0 || rc=$?
expect_code 0 "$rc" "fragment-bearing primary-home-only pointers must be optional in a secondmate home"
assert_contains "$out" 'check pointers primary=PASS' \
  "fragment-bearing primary-home-only pointer produced a threatening GAP"
pass "fragment-bearing primary-home-only pointers follow the secondmate exception"

SECONDARY_LITERAL_PRIMARY_ONLY_DECL="$TMP_ROOT/secondary-literal-primary-only-decl"
make_home "$SECONDARY_LITERAL_PRIMARY_ONLY_DECL"
printf 'shipwright-reviewer\n' > "$SECONDARY_LITERAL_PRIMARY_ONLY_DECL/.fm-secondmate-home"
cat > "$SECONDARY_LITERAL_PRIMARY_ONLY_DECL/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Archives in `data/literal#hash.md` in the PRIMARY home only.
EOF
out=$(run_doctor "$SECONDARY_LITERAL_PRIMARY_ONLY_DECL" --home-local 2>"$TMP_ROOT/err.secondary-literal-primary-only-decl") && rc=0 || rc=$?
expect_code 0 "$rc" "primary-home-only backtick paths with literal # must be optional in secondmate homes"
assert_contains "$out" 'check pointers primary=PASS' \
  "literal-hash primary-home-only declaration produced a threatening GAP"
case "$out" in
  *'data/literal#hash.md'*) fail "literal-hash primary-home-only declaration was still treated as missing: $out" ;;
esac
pass "primary-home-only backtick declarations preserve literal hash paths"

SECONDARY_LITERAL_HASH="$TMP_ROOT/secondary-literal-hash"
make_home "$SECONDARY_LITERAL_HASH"
printf 'shipwright-reviewer\n' > "$SECONDARY_LITERAL_HASH/.fm-secondmate-home"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf '%s\n' 'The local literal filename is `data/literal#hash.md`.' > "$SECONDARY_LITERAL_HASH/data/captain.md"
cat > "$SECONDARY_LITERAL_HASH/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
The primary-only directory is `data/literal` in the PRIMARY home only.
EOF
out=$(run_doctor "$SECONDARY_LITERAL_HASH" --home-local 2>"$TMP_ROOT/err.secondary-literal-hash") && rc=0 || rc=$?
expect_code 1 "$rc" "literal hash filenames must not match a different primary-only path"
assert_contains "$out" 'check pointers primary=GAP' \
  "literal hash filename was treated as a primary-only path"
assert_contains "$out" 'data/literal#hash.md' \
  "literal hash pointer gap lost its evidence"
pass "literal hash filenames remain distinct from Markdown fragments"

SECONDARY_MIXED_PRIMARY_ONLY="$TMP_ROOT/secondary-mixed-primary-only"
make_home "$SECONDARY_MIXED_PRIMARY_ONLY"
printf 'shipwright-reviewer\n' > "$SECONDARY_MIXED_PRIMARY_ONLY/.fm-secondmate-home"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf '%s\n' 'The PRIMARY home owns `data/primary.md`; every home must retain `data/local-required.md`; only the primary copy is authoritative.' > "$SECONDARY_MIXED_PRIMARY_ONLY/data/captain-shared.md"
out=$(run_doctor "$SECONDARY_MIXED_PRIMARY_ONLY" --home-local 2>"$TMP_ROOT/err.secondary-mixed-primary-only") && rc=0 || rc=$?
expect_code 1 "$rc" "mixed declarations must preserve local pointer gaps"
assert_contains "$out" 'data/local-required.md' \
  "mixed declaration overmatched a local pointer"
pass "mixed declarations scope the primary-only exception to one pointer"

SECONDARY_ADJACENT_PRIMARY_ONLY="$TMP_ROOT/secondary-adjacent-primary-only"
make_home "$SECONDARY_ADJACENT_PRIMARY_ONLY"
printf 'shipwright-reviewer\n' > "$SECONDARY_ADJACENT_PRIMARY_ONLY/.fm-secondmate-home"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf '%s\n' 'Pointer: `data/primary-only.md` in the PRIMARY home only: `data/local-required.md`' > "$SECONDARY_ADJACENT_PRIMARY_ONLY/data/captain-shared.md"
out=$(run_doctor "$SECONDARY_ADJACENT_PRIMARY_ONLY" --home-local 2>"$TMP_ROOT/err.secondary-adjacent-primary-only") && rc=0 || rc=$?
expect_code 1 "$rc" "an adjacent local pointer must not inherit a preceding primary-only declaration"
assert_contains "$out" 'data/local-required.md' \
  "adjacent local pointer was suppressed by a primary-only declaration"
case "$out" in
  *'data/primary-only.md'*) fail "the preceding primary-only pointer lost its exception: $out" ;;
esac
pass "adjacent primary-only declarations do not overmatch the next pointer"

SECONDARY_PRIMARY_ONLY_PREFIX="$TMP_ROOT/secondary-primary-only-prefix"
make_home "$SECONDARY_PRIMARY_ONLY_PREFIX"
printf 'shipwright-reviewer\n' > "$SECONDARY_PRIMARY_ONLY_PREFIX/.fm-secondmate-home"
cat > "$SECONDARY_PRIMARY_ONLY_PREFIX/data/captain-shared.md" <<'EOF'
PRIMARY home only: `data/tooling-limits.md`.
PRIMARY home only `data/entities/retired-2026-08-24/`.
Pointer: `config/primary-only.json` (PRIMARY-home-only).
EOF
out=$(run_doctor "$SECONDARY_PRIMARY_ONLY_PREFIX" --home-local 2>"$TMP_ROOT/err.secondary-primary-only-prefix") && rc=0 || rc=$?
expect_code 0 "$rc" "prefix primary-home-only declarations must be optional in a secondmate home"
assert_contains "$out" 'check pointers primary=PASS' \
  "prefix primary-home-only declaration produced a threatening GAP"
pass "prefix primary-home-only declarations remain supported"

OWNER_PRECEDENCE="$TMP_ROOT/owner-precedence"
OWNER_PRECEDENCE_BIN="$TMP_ROOT/owner-precedence-bin"
make_home "$OWNER_PRECEDENCE"
printf 'shipwright-reviewer\n' > "$OWNER_PRECEDENCE/.fm-secondmate-home"
printf 'FMX_PAIRING_TOKEN=fixture-token\n' > "$OWNER_PRECEDENCE/.env"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf '%s\n' 'The PRIMARY home owns `state/public-followup/` in the PRIMARY home only.' > "$OWNER_PRECEDENCE/data/captain-shared.md"
mkdir -p "$OWNER_PRECEDENCE_BIN"
cat > "$OWNER_PRECEDENCE_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"public_followups":[{"id":"loop","state":"open","public_followup":{"delivery":{"state":"pending"}}}]}'
SH
chmod +x "$OWNER_PRECEDENCE_BIN/tasks-axi"
out=$(PATH="$OWNER_PRECEDENCE_BIN:$PATH" run_doctor "$OWNER_PRECEDENCE" --home-local 2>"$TMP_ROOT/err.owner-precedence") && rc=0 || rc=$?
expect_code 1 "$rc" "active owner state must remain authoritative over primary-only declarations"
assert_contains "$out" 'check pointers primary=GAP' \
  "primary-only declaration hid an active owner gap"
assert_contains "$out" 'state/public-followup/' \
  "active owner gap lost its pointer evidence"
pass "owner-specific absence checks precede primary-only exceptions"

REGISTRY_PRIMARY="$TMP_ROOT/registry-primary"
REGISTRY_UNMARKED="$TMP_ROOT/registry-unmarked"
make_home "$REGISTRY_PRIMARY"
make_home "$REGISTRY_UNMARKED"
# shellcheck disable=SC2016 # Literal backticks are pointer fixtures and must remain unexpanded.
printf '%s\n' 'Directory map: `data/tooling-limits.md` in the PRIMARY home only.' > "$REGISTRY_UNMARKED/data/captain-shared.md"
printf '%s\n' "- stale - review domain (home: $REGISTRY_UNMARKED; scope: review work; projects: demo; added 2026-08-02)" > "$REGISTRY_PRIMARY/data/secondmates.md"
out=$(run_doctor "$REGISTRY_PRIMARY" 2>"$TMP_ROOT/err.registry-unmarked") && rc=0 || rc=$?
expect_code 1 "$rc" "an unmarked registry home must retain primary pointer checks"
assert_contains "$out" 'check pointers stale=GAP' \
  "an unmarked registry home was treated as a valid secondmate"
assert_contains "$out" 'data/tooling-limits.md' \
  "the unmarked registry home gap lost its evidence"
pass "registry homes require a validated secondmate marker"

PRIMARY_SYMLINK_MARKER="$TMP_ROOT/primary-symlink-marker"
make_home "$PRIMARY_SYMLINK_MARKER"
printf 'shipwright-reviewer\n' > "$PRIMARY_SYMLINK_MARKER/.fm-secondmate-home-target"
ln -s .fm-secondmate-home-target "$PRIMARY_SYMLINK_MARKER/.fm-secondmate-home"
cat > "$PRIMARY_SYMLINK_MARKER/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Directory map: `data/tooling-limits.md` in the PRIMARY home only.
EOF
out=$(run_doctor "$PRIMARY_SYMLINK_MARKER" --home-local 2>"$TMP_ROOT/err.primary-symlink-marker") && rc=0 || rc=$?
expect_code 1 "$rc" "a symlink marker must not suppress primary pointer gaps"
assert_contains "$out" 'check pointers primary=GAP' \
  "a symlink marker was treated as a valid secondmate marker"
pass "unsafe marker state fails closed as primary"

PRIMARY_INVALID_MARKER="$TMP_ROOT/primary-invalid-marker"
make_home "$PRIMARY_INVALID_MARKER"
printf '%s\n' 'invalid/id' > "$PRIMARY_INVALID_MARKER/.fm-secondmate-home"
cat > "$PRIMARY_INVALID_MARKER/data/captain-shared.md" <<'EOF'
Shared captain preferences are main-authoritative and read-only in secondmate homes.
Directory map: `data/tooling-limits.md` in the PRIMARY home only.
EOF
out=$(run_doctor "$PRIMARY_INVALID_MARKER" --home-local 2>"$TMP_ROOT/err.primary-invalid-marker") && rc=0 || rc=$?
expect_code 1 "$rc" "an invalid marker must not suppress primary pointer gaps"
assert_contains "$out" 'check pointers primary=GAP' \
  "an invalid marker was treated as a valid secondmate marker"
pass "invalid marker state fails closed as primary"

# --- canonical optional home paths ------------------------------------------

OPTIONAL_PATHS="$TMP_ROOT/optional-paths"
make_home "$OPTIONAL_PATHS"
rm "$OPTIONAL_PATHS/data/captain.md"
cat > "$OPTIONAL_PATHS/data/learnings.md" <<'EOF'
Optional stores may be absent: `data/backlog.md`, `data/captain.md`, `data/projects.md`, `config/model-catalog.json`, `config/auto-quota-drain.json`, `data/done-archive.md`, `data/quota-cooldowns.json`, and `data/routing-outcomes.jsonl`.
EOF
out=$(run_doctor "$OPTIONAL_PATHS" 2>"$TMP_ROOT/err.optional-paths") && rc=0 || rc=$?
expect_code 0 "$rc" "absent optional home paths must not be threatening"
assert_contains "$out" 'check pointers primary=PASS' "absent optional home paths produced a pointer gap"
pass "canonical optional home paths remain non-threatening when absent"

# --- delivery-first exit matrix already covered above -----------------------

pass "delivery-first exit: UNKNOWN and stow-class GAP step aside; threatening GAP exits 1"
echo "# fm-memory-doctor.test.sh: all assertions passed"
