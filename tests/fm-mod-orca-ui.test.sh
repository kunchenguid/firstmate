#!/usr/bin/env bash
# tests/fm-mod-orca-ui.test.sh - unit tests for bin/fm-mod-orca-ui.sh.
#
# The orca UI's profile file (profiles/local-default/orca-data.json) is the
# data source for its sidebar worktree list. firstmate's orca backend creates
# git worktrees that orca would normally consider "external" and hide under
# the externalWorktreeVisibility gate. fm-mod-orca-ui.sh writes a
# worktreeMeta entry that bypasses the gate. These tests exercise the JSON
# mutation contract without touching the real orca-data.json or the real
# daemon: every test copies a fixture to a temp file, runs the helper, and
# asserts on the copy. fmod is faked via PATH shim so the helper's parent-
# path resolution does not need a live daemon.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-mod-orca-ui.sh"

assert_present "$HELPER" "fm-mod-orca-ui.sh must exist"
[ -x "$HELPER" ] || fail "$HELPER must be executable"

# make_orca_data_fixture <path>: writes a known-good orca-data.json fixture
# with two registered repos so register / unregister tests have something to
# match against.
make_orca_data_fixture() {  # <path>
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JSON'
{
  "schemaVersion": 1,
  "repos": [
    { "id": "aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "path": "/tmp/repoA", "displayName": "repoA", "kind": "git" },
    { "id": "bbbb2222-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "path": "/tmp/repoB", "displayName": "repoB", "kind": "git" }
  ],
  "projects": [],
  "projectHostSetups": [],
  "worktreeMeta": {},
  "settings": { "externalWorktreeVisibility": "hide" }
}
JSON
}

# make_fakebin_fmod <dir> [list-json]: writes a fmod stub that logs
# invocations to <dir>/.fmod.log and returns [list-json] for the `list`
# subcommand. Other subcommands print a minimal JSON shell that keeps the
# helper happy.
make_fakebin_fmod() {  # <dir> [list-json]
  local dir=$1 list_json=${2:-'[]'}
  local fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/fmod" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list) printf '%s\\n' '$list_json' ;;
  info) printf '{"socket_exists":true,"token_exists":true,"daemon_reachable":true,"daemon_pong":{"pong":true}}\\n' ;;
  *) printf '{}' ;;
esac
SH
  chmod +x "$fb/fmod"
}

# Helper: run the helper with given env + args, return stdout on stdout
# and exit code via the wrapper (so we can keep going on non-fatal failures).
register() {
  local cfg=$1 wt=$2 parent=$3 instance_id=${4:-}
  mkdir -p "$wt"
  if [ -n "$instance_id" ]; then
    PATH="$FB/fakebin:/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" FM_ORCA_FMOD="$FB/fakebin/fmod" FM_ORCA_INSTANCE_ID="$instance_id" \
      "$HELPER" register "$wt" --parent-path "$parent"
  else
    PATH="$FB/fakebin:/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" FM_ORCA_FMOD="$FB/fakebin/fmod" \
      "$HELPER" register "$wt" --parent-path "$parent"
  fi
}

unregister_key() {
  local cfg=$1 key=$2
  PATH="$FB/fakebin:/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" FM_ORCA_FMOD="$FB/fakebin/fmod" \
    "$HELPER" unregister "$key"
}

TMP_ROOT=$(fm_test_tmproot fm-mod-orca-ui-tests)

# Common list-json used across tests.
LIST_REPO_A='[{"sessionId":"aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa::/tmp/repoA@@abc12345","isAlive":true,"shellState":"timed_out","pid":1,"cwd":"/tmp/repoA","cols":80,"rows":24}]'
LIST_REPO_AB='[{"sessionId":"aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa::/tmp/repoA@@abc12345","isAlive":true,"shellState":"timed_out","pid":1,"cwd":"/tmp/repoA","cols":80,"rows":24},{"sessionId":"bbbb2222-bbbb-bbbb-bbbb-bbbbbbbbbbbb::/tmp/repoB@@def67890","isAlive":true,"shellState":"timed_out","pid":2,"cwd":"/tmp/repoB","cols":80,"rows":24}]'

# ---------- list on empty fixture ----------
cfg=$TMP_ROOT/orca-data.json
FB=$(fm_test_tmproot fm-mod-orca-ui-fb)
make_orca_data_fixture "$cfg"
make_fakebin_fmod "$FB" "$LIST_REPO_A"
out=$(PATH="$FB/fakebin:/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" "$HELPER" list 2>&1)
expect_code 0 $? "list empty: exit 0"
[ -z "$out" ] || fail "list empty: stdout must be empty, got: $out"
pass "list empty"

# ---------- register writes a worktreeMeta entry ----------
cfg=$TMP_ROOT/orca-data-register.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-register)
make_fakebin_fmod "$FB" "$LIST_REPO_A"
key=$(register "$cfg" /tmp/repoA/.fm-test-wt /tmp/repoA 00000000-0000-0000-0000-000000000001)
expect_code 0 $? "register: exit 0"
[ "$key" = "aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa::/tmp/repoA/.fm-test-wt" ] || fail "register: wrong key, got: $key"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
k = 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa::/tmp/repoA/.fm-test-wt'
assert k in d['worktreeMeta'], k
assert d['worktreeMeta'][k]['instanceId'] == '00000000-0000-0000-0000-000000000001', d['worktreeMeta'][k]
assert d['worktreeMeta'][k]['workspaceStatus'] == 'in-progress', d['worktreeMeta'][k]
" "$cfg" || fail "register: missing or wrong worktreeMeta entry"
pass "register"

# ---------- register idempotent ----------
cfg=$TMP_ROOT/orca-data-idem.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-idem)
make_fakebin_fmod "$FB" "$LIST_REPO_A"
register "$cfg" /tmp/repoA-idem /tmp/repoA 00000000-0000-0000-0000-000000000002 >/dev/null
register "$cfg" /tmp/repoA-idem /tmp/repoA 00000000-0000-0000-0000-000000000002 >/dev/null
n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["worktreeMeta"]))' "$cfg")
[ "$n" = "1" ] || fail "register idempotent: expected 1 entry, got $n"
pass "register idempotent"

# ---------- unregister removes ----------
cfg=$TMP_ROOT/orca-data-unregister.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-unregister)
make_fakebin_fmod "$FB" "$LIST_REPO_A"
register "$cfg" /tmp/repoA-to-remove /tmp/repoA 00000000-0000-0000-0000-000000000003 >/dev/null
n_before=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["worktreeMeta"]))' "$cfg")
[ "$n_before" = "1" ] || fail "unregister: pre count expected 1, got $n_before"
unregister_key "$cfg" "aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa::/tmp/repoA-to-remove" >/dev/null
n_after=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["worktreeMeta"]))' "$cfg")
[ "$n_after" = "0" ] || fail "unregister: post count expected 0, got $n_after"
pass "unregister"

# ---------- unregister missing key is idempotent ----------
cfg=$TMP_ROOT/orca-data-unregister-missing.json
make_orca_data_fixture "$cfg"
unregister_key "$cfg" "missing::key" >/dev/null 2>&1
expect_code 0 $? "unregister missing: exit 0"
pass "unregister missing"

# ---------- missing orca-data.json exits 2 ----------
PATH="/usr/bin:/bin" FM_ORCA_DATA_FILE="/nonexistent/orca-data.json" "$HELPER" list >/dev/null 2>&1
expect_code 2 $? "missing data file: exit 2"
pass "missing data file"

# ---------- unregistered parent exits 4 ----------
cfg=$TMP_ROOT/orca-data-orphan.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-orphan)
make_fakebin_fmod "$FB" "$LIST_REPO_A"
register "$cfg" /tmp/repoX-orphan /tmp/repoX 00000000-0000-0000-0000-0000000000aa >/dev/null 2>&1
expect_code 4 $? "unregistered parent: exit 4"
pass "unregistered parent"

# ---------- second repo register ----------
cfg=$TMP_ROOT/orca-data-b.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-b)
make_fakebin_fmod "$FB" "$LIST_REPO_AB"
register "$cfg" /tmp/repoB-wt /tmp/repoB 00000000-0000-0000-0000-000000000004 >/dev/null 2>&1
expect_code 0 $? "second repo: exit 0"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert any(k.startswith('bbbb2222-') for k in d['worktreeMeta']), d['worktreeMeta']
" "$cfg" || fail "second repo: bbbb prefix missing"
pass "second repo"

# ---------- --parent-key bypass skips fmod list ----------
cfg=$TMP_ROOT/orca-data-pk.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-pk)
make_fakebin_fmod "$FB" '[]'
mkdir -p /tmp/whatever
PATH="$FB/fakebin:/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" FM_ORCA_FMOD="$FB/fakebin/fmod" \
  "$HELPER" register /tmp/whatever --parent-key "bbbb2222-bbbb-bbbb-bbbb-bbbbbbbbbbbb::/tmp/repoB@@def" >/dev/null 2>&1
expect_code 0 $? "parent-key bypass: exit 0"
log="$FB/.fmod.log"
# We don't write a log in the fakebin helper, so this just confirms the
# registration succeeded with an empty fmod list. The real test is that no
# fmod call was needed at all (no exit-4 from a missing parent).
pass "parent-key bypass"

# ---------- atomic write preserves other top-level fields ----------
cfg=$TMP_ROOT/orca-data-preserves.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-preserves)
make_fakebin_fmod "$FB" "$LIST_REPO_A"
register "$cfg" /tmp/repoA-preserve /tmp/repoA 00000000-0000-0000-0000-000000000005 >/dev/null
python3 - "$cfg" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
assert d['schemaVersion'] == 1, 'schemaVersion lost'
assert len(d['repos']) == 2, 'repos lost'
assert d['repos'][0]['path'] == '/tmp/repoA', 'repo path mutated'
assert d['settings']['externalWorktreeVisibility'] == 'hide', 'settings lost'
PY
expect_code 0 $? "atomic preserves fields"
pass "atomic preserves"

# ---------- list / show reflect register/unregister ----------
cfg=$TMP_ROOT/orca-data-ls.json
make_orca_data_fixture "$cfg"
FB=$(fm_test_tmproot fm-mod-orca-ui-fb-ls)
make_fakebin_fmod "$FB" "$LIST_REPO_A"
register "$cfg" /tmp/repoA-ls /tmp/repoA 00000000-0000-0000-0000-000000000006 >/dev/null
out=$(PATH="/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" "$HELPER" list 2>&1)
case "$out" in
  *"aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa::/tmp/repoA-ls"*) pass "list shows registered entry" ;;
  *) fail "list did not show registered entry, got: $out" ;;
esac
out2=$(PATH="/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" "$HELPER" show "aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa::/tmp/repoA-ls" 2>&1)
case "$out2" in
  *"instanceId"*) pass "show prints instanceId" ;;
  *) fail "show did not print instanceId, got: $out2" ;;
esac

# ---------- help / unknown command ----------
PATH="/usr/bin:/bin" FM_ORCA_DATA_FILE="/tmp/no-such" "$HELPER" --help >/dev/null 2>&1
expect_code 0 $? "--help: exit 0"
PATH="/usr/bin:/bin" FM_ORCA_DATA_FILE="/tmp/no-such" "$HELPER" nonsense >/dev/null 2>&1
expect_code 1 $? "nonsense command: exit 1"
pass "help and unknown"

printf 'ALL OK\n'

# ---------- two concurrent register calls do not collide ----------
# The review found a real bug here: prior versions of atomic_write_orca_data
# wrote to a hardcoded path + '.tmp' from inside the python heredoc, so
# two concurrent callers (e.g. main home + a secondmate home spawning in
# parallel) would both truncate each other's in-flight content. This test
# runs register twice concurrently against the same fixture and asserts
# both worktreeMeta entries land; a serial path+rename race would leave one
# missing. Each caller mints its own tmp name via mktemp now.
cfg=$TMP_ROOT/orca-data-concurrent.json
make_orca_data_fixture "$cfg"
fb=$(fm_test_tmproot fm-mod-orca-ui-fb-concurrent)
make_fakebin_fmod "$fb" "$LIST_REPO_A"
mkdir -p /tmp/repoA-conc-A /tmp/repoA-conc-B
PATH="$fb/fakebin:/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" FM_ORCA_FMOD="$fb/fakebin/fmod" FM_ORCA_INSTANCE_ID="00000000-0000-0000-0000-00000000000a" \
  "$HELPER" register /tmp/repoA-conc-A --parent-path /tmp/repoA >/tmp/conc-A.out 2>/tmp/conc-A.err &
PID_A=$!
PATH="$fb/fakebin:/usr/bin:/bin" FM_ORCA_DATA_FILE="$cfg" FM_ORCA_FMOD="$fb/fakebin/fmod" FM_ORCA_INSTANCE_ID="00000000-0000-0000-0000-00000000000b" \
  "$HELPER" register /tmp/repoA-conc-B --parent-path /tmp/repoA >/tmp/conc-B.out 2>/tmp/conc-B.err &
PID_B=$!
wait "$PID_A"
expect_code 0 $? "concurrent A: exit 0"
wait "$PID_B"
expect_code 0 $? "concurrent B: exit 0"
n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["worktreeMeta"]))' "$cfg")
[ "$n" = "2" ] || fail "concurrent register: expected 2 entries, got $n"
pass "concurrent register does not collide"

# ---------- orphan tmp files are not left behind ----------
# After successful writes the tmp file mktemp'd in the helper should not
# linger next to orca-data.json. The helper uses mktemp + os.replace which
# leaves no .tmp filename behind, so a leftover file would indicate a
# rename failed mid-write.
leftover=$(ls "$cfg.tmp".* 2>/dev/null | wc -l)
[ "$leftover" = "0" ] || fail "atomic_write left $leftover orphan tmp file(s) in $cfg's directory"
pass "atomic_write leaves no orphan tmp file"
