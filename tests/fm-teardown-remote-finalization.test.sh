#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-finalization)
for shape in matching mismatched published publish-failure; do
  home="$TMP_ROOT/$shape"
  mkdir -p "$home/state" "$home/data" "$home/config"
  touch "$home/config/fleet-ledger"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf -- '- mate - Test mate. (host: remote; root: /remote/root; home: /remote/home; scope: tests; projects: ; added 2026-10-28)\n' > "$home/data/secondmates.md"
  [ "$shape" != published ] || : > "$home/data/secondmates.md"
  host=remote
  [ "$shape" != mismatched ] || host=another
  jq -n --arg h "$host" '{task:"mate", home:"/remote/home", generation:"g1", backend:"herdr", target:"endpoint", destroyed:true, exit_code:0, local_finalization:{host:$h,root:"/remote/root"}}' > "$home/state/.seat-retirement-mate.json"
  if [ "$shape" = publish-failure ]; then
    real_mv=$(command -v mv)
    mkdir -p "$home/fakebin"
    cat > "$home/fakebin/mv" <<'MV'
#!/usr/bin/env bash
for arg in "$@"; do last=$arg; done
[ "$last" != "$FM_TEST_REG" ] || exit 1
exec "$FM_TEST_REAL_MV" "$@"
MV
    chmod +x "$home/fakebin/mv"
    rc=0
    FM_TEST_REAL_MV="$real_mv" FM_TEST_REG="$home/data/secondmates.md" PATH="$home/fakebin:$PATH" FM_HOME="$home" bash "$ROOT/bin/fm-teardown.sh" mate > "$home/fail.out" 2> "$home/fail.err" || rc=$?
    expect_code 1 "$rc" "registry publication failure must be reported"
    assert_present "$home/state/.seat-retirement-mate.json" "publication failure lost recovery evidence"
    assert_grep '- mate ' "$home/data/secondmates.md" "publication failure lost its route"
  fi
  rc=0
  FM_HOME="$home" bash "$ROOT/bin/fm-teardown.sh" mate > "$home/out" 2> "$home/err" || rc=$?
  if [ "$shape" = mismatched ]; then
    [ "$rc" -ne 0 ] || fail "mismatched retirement evidence was accepted"
    assert_present "$home/state/.seat-retirement-mate.json" "mismatched evidence was removed"
    assert_grep '- mate ' "$home/data/secondmates.md" "mismatched route was removed"
  else
    expect_code 0 "$rc" "metadata-free finalization: $(cat "$home/err")"
    jq -se 'any(.[]; .event == "task.cleaned_up" or .type == "task.cleaned_up")' "$home/state/fleet-ledger.jsonl" >/dev/null || fail "metadata-free recovery missed its ledger cleanup"
    assert_absent "$home/state/.seat-retirement-mate.json" "finalization evidence was not retired"
    assert_no_grep '- mate ' "$home/data/secondmates.md" "finalization retained the route"
  fi
done
pass "remote finalization recovers without metadata and rejects mismatched routes"
