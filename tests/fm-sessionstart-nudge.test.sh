#!/usr/bin/env bash
# Behavior and tracked-registration tests for the native session-start nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-nudge)
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
NUDGE_TEXT="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."
fm_operational_input_encode session-start "$NUDGE_TEXT" NUDGE_LINE \
  || fail "could not construct expected session-start nudge"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out prefix_hex status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a3 ] || fail "genuine primary nudge lost its U+2063 operational marker: $prefix_hex"
  pass "fm-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.fm-secondmate-home"
  expect_silent_zero "gate common-dir nudge" env FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$root" fm/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_secondmate_primary_nudges() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked secondmate nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked secondmate printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a marked linked secondmate home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran" fakebin
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  fakebin=$(fm_fakebin "$root/fake")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=
field=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -p) pid=\$2; shift 2 ;;
    -o) field=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  "$$:comm=") printf '%s\n' claude ;;
  "$$:args=") printf '%s\n' claude ;;
  *:ppid=) printf '%s\n' "$$" ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  expect_silent_zero "owned lock nudge" env PATH="$fakebin:/usr/bin:/bin" \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: a lock holder in process ancestry is already run"
}

test_codex_thread_identity_is_silent_without_lock_ancestry() {
  local root="$TMP_ROOT/codex-thread-owned" fakebin holder out status=0
  local thread_id=019fb044-acd6-7c20-97a2-f3e227def5d2
  local other_thread_id=019fb041-9ca2-76c1-a272-358bd63dfe7a
  make_primary "$root"
  fakebin=$(fm_fakebin "$root/fake")
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" > "$root/state/.lock"
  printf '%s:%s\n' "$holder" "$thread_id" > "$root/state/.lock.codex-thread"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=
field=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -p) pid=\$2; shift 2 ;;
    -o) field=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  "$holder:comm=") printf '%s\n' codex ;;
  "$holder:args=") printf '%s\n' codex ;;
  *:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(CODEX_THREAD_ID="$thread_id" PATH="$fakebin:/usr/bin:/bin" \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE" 2>&1) \
    || status=$?
  expect_code 0 "$status" "Codex thread-owned nudge"
  [ -z "$out" ] || fail "matching Codex thread identity must stay silent without lock ancestry: $out"

  out=$(CODEX_THREAD_ID="$other_thread_id" PATH="$fakebin:/usr/bin:/bin" \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE" 2>&1) \
    || status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 0 "$status" "mismatched Codex thread nudge"
  [ "$out" = "$NUDGE_LINE" ] \
    || fail "mismatched Codex thread identity did not fail closed to a nudge: $out"
  pass "fm-sessionstart-nudge: Codex thread identity replaces ancestry without admitting another thread"
}

test_opencode_plugin_delivers_exact_nudge_once() {
  local root="$TMP_ROOT/opencode-primary" out status=0
  make_primary "$root"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$root/bin/"
  chmod +x "$root/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    WORKTREE="$root" EXPECTED="$NUDGE_LINE" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimarySessionstartNudge({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = {
  type: "session.created",
  properties: { sessionID: "session-nudge-test", info: { id: "session-nudge-test" } },
};
await hooks.event({ event });
await hooks.event({ event });
if (prompts.length !== 1) throw new Error(`expected one prompt, got ${prompts.length}`);
if (prompts[0] !== process.env.EXPECTED) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
  ) || status=$?
  expect_code 0 "$status" "OpenCode exact nudge delivery"
  [ -z "$out" ] || fail "OpenCode exact nudge delivery printed output: $out"
  pass "OpenCode session.created delivers the exact wrapper nudge once per session"
}

test_genuine_primary_nudges
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_secondmate_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_codex_thread_identity_is_silent_without_lock_ancestry
test_opencode_plugin_delivers_exact_nudge_once
