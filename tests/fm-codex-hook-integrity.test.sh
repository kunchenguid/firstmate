#!/usr/bin/env bash
# Offline regression for Codex project-hook executable-root integrity.
#
# This models the trust declaration in a temporary fixture and exercises the
# registered Stop hook command as Codex invokes it. It never reads or changes
# the operator's real Codex configuration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-hook-integrity)
TRUSTED_ROOT="$TMP_ROOT/trusted"
WORKTREE_ROOT="$TMP_ROOT/worktree"
UNTRUSTED_ROOT="$TMP_ROOT/untrusted"
TRUST_MODEL="$TMP_ROOT/config.toml"
PAYLOAD='{"stop_hook_active":false,"session_id":"hook-integrity-test"}'

install_fixture() {
  mkdir -p "$TRUSTED_ROOT/.codex" "$TRUSTED_ROOT/bin"
  cp "$ROOT/.codex/hooks.json" "$TRUSTED_ROOT/.codex/hooks.json"
  : > "$TRUSTED_ROOT/AGENTS.md"
  cat > "$TRUSTED_ROOT/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'TRUSTED_PAYLOAD_EXECUTED\n'
cat >/dev/null
SH
  chmod +x "$TRUSTED_ROOT/bin/fm-turnend-guard.sh"
  git -C "$TRUSTED_ROOT" init -q
  git -C "$TRUSTED_ROOT" add .
  git -C "$TRUSTED_ROOT" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm fixture
  git -C "$TRUSTED_ROOT" worktree add -q -b worker "$WORKTREE_ROOT"
  cat > "$WORKTREE_ROOT/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'WORKTREE_PAYLOAD_EXECUTED\n'
cat >/dev/null
SH
  chmod +x "$WORKTREE_ROOT/bin/fm-turnend-guard.sh"
  mkdir -p "$UNTRUSTED_ROOT/bin"
  cat > "$UNTRUSTED_ROOT/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'UNTRUSTED_CWD_PAYLOAD_EXECUTED\n'
cat >/dev/null
SH
  chmod +x "$UNTRUSTED_ROOT/bin/fm-turnend-guard.sh"
}

run_hook() {
  local command=$1 cwd=$2 hook_root=${3:-} out status
  set +e
  out=$(printf '%s' "$PAYLOAD" | (
    cd "$cwd" || exit 1
    FM_CODEX_HOOK_ROOT="$hook_root" bash -c "$command"
  ) 2>&1)
  status=$?
  set -e
  printf '%s\t%s\n' "$status" "$out"
}

install_fixture
COMMAND=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$TRUSTED_ROOT/.codex/hooks.json")
[ -n "$COMMAND" ] || fail "Codex Stop hook command is missing"
declaration_hash=$(printf '%s' "$COMMAND" | shasum -a 256 | awk '{print $1}')
printf 'trusted_hash = "sha256:%s"\n' "$declaration_hash" > "$TRUST_MODEL"
trust_before=$(shasum -a 256 "$TRUST_MODEL" | awk '{print $1}')

# The unanchored invocation is the historical vulnerability: the trusted hook
# declaration remains identical while a linked worktree supplies the payload.
legacy_result=$(run_hook "$COMMAND" "$WORKTREE_ROOT")
legacy_status=${legacy_result%%$'\t'*}
legacy_output=${legacy_result#*$'\t'}
trust_after_legacy=$(shasum -a 256 "$TRUST_MODEL" | awk '{print $1}')
[ "$legacy_status" -eq 0 ] || fail "legacy hook did not execute the linked-worktree payload"
assert_contains "$legacy_output" "WORKTREE_PAYLOAD_EXECUTED" \
  "legacy hook did not expose the linked-worktree payload swap"
[ "$trust_before" = "$trust_after_legacy" ] || fail "modeled trust declaration changed during the payload swap"
printf 'evidence before: status=%s worktree_payload=EXECUTED modeled_trust_file_unchanged=yes\n' "$legacy_status"

# A spawned Codex worker carries the trusted hook root explicitly. The hook
# must select that root even though its process cwd is the linked worktree.
anchored_result=$(run_hook "$COMMAND" "$WORKTREE_ROOT" "$TRUSTED_ROOT")
anchored_status=${anchored_result%%$'\t'*}
anchored_output=${anchored_result#*$'\t'}
[ "$anchored_status" -eq 0 ] || fail "anchored hook did not preserve successful Stop execution"
assert_contains "$anchored_output" "TRUSTED_PAYLOAD_EXECUTED" \
  "anchored hook did not execute the trusted payload"
assert_not_contains "$anchored_output" "WORKTREE_PAYLOAD_EXECUTED" \
  "anchored hook executed the linked-worktree payload"
printf 'evidence after-worktree: status=%s worktree_payload=REFUSED trusted_payload=EXECUTED\n' "$anchored_status"

# The fixed root must also win over a wholly unrelated process cwd.
untrusted_result=$(run_hook "$COMMAND" "$UNTRUSTED_ROOT" "$TRUSTED_ROOT")
untrusted_status=${untrusted_result%%$'\t'*}
untrusted_output=${untrusted_result#*$'\t'}
[ "$untrusted_status" -eq 0 ] || fail "trusted hook did not run from an unrelated cwd"
assert_contains "$untrusted_output" "TRUSTED_PAYLOAD_EXECUTED" \
  "unrelated cwd displaced the trusted hook payload"
assert_not_contains "$untrusted_output" "UNTRUSTED_CWD_PAYLOAD_EXECUTED" \
  "unrelated cwd gained hook executable authority"

trust_final=$(shasum -a 256 "$TRUST_MODEL" | awk '{print $1}')
[ "$trust_before" = "$trust_final" ] || fail "modeled trust declaration changed during anchored invocations"
printf 'evidence trust model: file_sha256=%s unchanged=yes\n' "$trust_final"
printf 'NOT_VERIFIABLE: live Codex trust-dialog re-prompt count; this offline test models a stable declaration and never invokes Codex.\n'
pass "Codex trusted hook declarations cannot be retargeted to a worker-controlled payload root"
