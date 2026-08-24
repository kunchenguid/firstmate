#!/usr/bin/env bash
# Regression tests for remote secondmate pending-reply cleanup in fm-teardown.sh.
set -u

export FM_GATE_REFUSE_BYPASS=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  [ -z "${TMP_ROOT:-}" ] || rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-remote-pending.XXXXXX")

make_case() {
  local id=$1 fake="$TMP_ROOT/$1"
  local sibling
  mkdir -p "$fake/bin" "$fake/data" "$fake/state/pending-replies"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  for sibling in \
    fm-backend.sh \
    fm-classify-lib.sh \
    fm-control-lib.sh \
    fm-gate-refuse-lib.sh \
    fm-lock-lib.sh \
    fm-nm-run-lib.sh \
    fm-pr-lib.sh \
    fm-public-followup-lib.sh \
    fm-secondmate-parent-lib.sh \
    fm-secondmate-registry-lib.sh \
    fm-timeout-lib.sh \
    fm-wake-lib.sh \
    fm-x-lib.sh; do
    ln -s "$ROOT/bin/$sibling" "$fake/bin/$sibling"
  done
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake/bin/fm-procevent-remote-reply.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh" "$fake/bin/fm-on.sh" \
    "$fake/bin/fm-procevent-remote-reply.sh"
  cat > "$fake/state/$id.meta" <<EOF
kind=secondmate
remote_host=remote.example
remote_root=/srv/firstmate
home=/srv/firstmate-homes/$id
EOF
  printf -- '- %s - test route (host: remote.example; root: /srv/firstmate; home: /srv/firstmate-homes/%s; scope: tests; projects: none; added 2026-08-24)\n' \
    "$id" "$id" > "$fake/data/secondmates.md"
  printf '%s\n' "$fake"
}

run_teardown() {
  local fake=$1 id=$2
  local out="$fake/teardown.out" err="$fake/teardown.err"
  env FM_HOME="$fake" FM_ROOT_OVERRIDE="$fake" \
    bash "$fake/bin/fm-teardown.sh" "$id" > "$out" 2> "$err"
}

test_cleanup_succeeds_with_only_unrelated_records() {
  local id=none fake
  fake=$(make_case "$id")
  printf 'task_id=other\nphase=captured\n' > "$fake/state/pending-replies/only-unrelated"

  run_teardown "$fake" "$id" \
    || fail "remote teardown failed when no pending-reply records matched: $(cat "$fake/teardown.err")"
  [ -e "$fake/state/pending-replies/only-unrelated" ] \
    || fail "remote teardown removed another task's only pending-reply record"
  [ ! -e "$fake/state/$id.meta" ] \
    || fail "successful no-match teardown retained task metadata"
  pass "remote pending-reply cleanup succeeds when only unrelated records exist"
}

test_cleanup_deletes_only_target_records() {
  local id=mixed fake
  fake=$(make_case "$id")
  printf 'task_id=%s\nphase=resolved\n' "$id" > "$fake/state/pending-replies/001-target"
  printf 'task_id=other\nphase=captured\n' > "$fake/state/pending-replies/zzz-unrelated"

  run_teardown "$fake" "$id" \
    || fail "remote teardown inherited the unrelated record status: $(cat "$fake/teardown.err")"
  [ ! -e "$fake/state/pending-replies/001-target" ] \
    || fail "remote teardown retained its target pending-reply record"
  [ -e "$fake/state/pending-replies/zzz-unrelated" ] \
    || fail "remote teardown removed another task's pending-reply record"
  [ ! -e "$fake/state/$id.meta" ] \
    || fail "successful mixed-record teardown retained task metadata"
  pass "remote pending-reply cleanup deletes only target task records"
}

test_cleanup_refuses_non_regular_entry() {
  local id=unsafe fake
  fake=$(make_case "$id")
  mkdir "$fake/state/pending-replies/non-regular"

  if run_teardown "$fake" "$id"; then
    fail "remote teardown accepted a non-regular pending-reply entry"
  fi
  [ -d "$fake/state/pending-replies/non-regular" ] \
    || fail "refused cleanup removed the unsafe pending-reply entry"
  [ -e "$fake/state/$id.meta" ] \
    || fail "refused cleanup removed task metadata"
  grep -F -- "- $id " "$fake/data/secondmates.md" >/dev/null \
    || fail "refused cleanup removed the registry route"
  pass "remote pending-reply cleanup refuses a non-regular entry"
}

test_cleanup_succeeds_with_only_unrelated_records
test_cleanup_deletes_only_target_records
test_cleanup_refuses_non_regular_entry
