#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot_into TMP_ROOT fm-prompt-exec
mkdir -p "$TMP_ROOT"

path_identity() {
  python3 -c 'import os, sys; value = os.stat(sys.argv[1], follow_symlinks=False); print(f"{value.st_dev}:{value.st_ino}")' "$1"
}

content_identity() {
  shasum -a 256 "$1" | awk '{print $1}'
}

test_prompt_transport_uses_one_native_multiline_argument() {
  local transport="$TMP_ROOT/transport" prompt capture="$TMP_ROOT/capture" script="$TMP_ROOT/capture.py" command parent_id file_id content_id
  mkdir "$transport"
  prompt="$transport/prompt"; capture="$TMP_ROOT/capture"
  printf 'prefix\nmiddle\nsuffix\n\n' > "$prompt"
  cat > "$script" <<'PY'
import os
import sys
if len(sys.argv) != 3:
    raise RuntimeError(f"expected one prompt argument, received {len(sys.argv) - 2}")
with open(sys.argv[1], "wb") as output:
    output.write(os.fsencode(sys.argv[2]))
PY
  command="exec python3 '$script' '$capture'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" "$command" \
    || fail "continuation prompt transport rejected a native multiline argument"
  cmp -s "$capture" <(printf 'prefix\nmiddle\nsuffix\n\n') \
    || fail "continuation prompt transport split or changed the native multiline argument"
  assert_absent "$prompt" "continuation prompt transport retained its consumed generation"
  assert_absent "$transport" "continuation prompt transport retained its private launch directory"
  pass "continuation prompt transport uses one provider-native multiline argument"
}

test_prompt_transport_rejects_non_argument_bytes() {
  local kind transport prompt marker output status parent_id file_id content_id
  for kind in nul invalid-utf8; do
    transport="$TMP_ROOT/$kind"; prompt="$transport/prompt"; marker="$TMP_ROOT/$kind-launched"; output="$TMP_ROOT/$kind.out"
    mkdir "$transport"
    if [ "$kind" = nul ]; then printf 'prefix\0suffix\n' > "$prompt"; else printf 'prefix\377suffix\n' > "$prompt"; fi
    parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
    if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" \
      "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "prompt transport accepted $kind bytes in a provider-native argument"
    assert_absent "$marker" "prompt transport launched after rejecting $kind bytes"
    assert_present "$prompt" "prompt transport consumed the rejected $kind source"
  done
  assert_contains "$(cat "$TMP_ROOT/nul.out")" "cannot contain NUL bytes" "NUL rejection was not actionable"
  assert_contains "$(cat "$TMP_ROOT/invalid-utf8.out")" "must be valid UTF-8" "invalid UTF-8 rejection was not actionable"
  pass "continuation prompt transport rejects bytes native arguments cannot preserve"
}

test_prompt_transport_rejects_replaced_generation() {
  local transport="$TMP_ROOT/replaced-file" prompt prior marker="$TMP_ROOT/replaced-launched" \
    output="$TMP_ROOT/replaced.out" status parent_id file_id content_id
  mkdir "$transport"; prompt="$transport/prompt"; prior="$transport/prior"
  printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  mv "$prompt" "$prior"; printf 'unowned replacement\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport consumed an unowned replacement generation"
  assert_absent "$marker" "prompt transport launched an unowned replacement generation"
  assert_contains "$(cat "$prompt")" "unowned replacement" "prompt transport changed the unowned replacement"
  pass "continuation prompt consumption requires its owned file generation"
}

test_prompt_transport_rejects_replaced_parent() {
  local transport="$TMP_ROOT/replaced-parent" moved="$TMP_ROOT/replaced-parent-owned" prompt marker="$TMP_ROOT/parent-launched" \
    output="$TMP_ROOT/parent.out" status parent_id file_id content_id
  mkdir "$transport"; prompt="$transport/prompt"; printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  mv "$transport" "$moved"; mkdir "$transport"; printf 'replacement parent bytes\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport repinned an unowned parent generation"
  assert_absent "$marker" "prompt transport launched from an unowned parent generation"
  assert_contains "$(cat "$prompt")" "replacement parent bytes" "prompt transport changed the replacement parent"
  pass "continuation prompt consumption requires its owned parent generation"
}

test_prompt_transport_rejects_in_place_mutation() {
  local transport="$TMP_ROOT/in-place" prompt marker="$TMP_ROOT/in-place-launched" output="$TMP_ROOT/in-place.out"
  local status parent_id file_id content_id
  mkdir "$transport"; prompt="$transport/prompt"; printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  printf 'mutated bytes!\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport consumed in-place-mutated bytes"
  assert_absent "$marker" "prompt transport launched in-place-mutated bytes"
  assert_contains "$(cat "$prompt")" "mutated bytes" "prompt transport changed the mutated source"
  pass "continuation prompt consumption verifies content identity"
}

test_prompt_transport_consumes_verified_snapshot_after_mutation() {
  local transport="$TMP_ROOT/post-hash" prompt="$TMP_ROOT/post-hash/prompt" expected="$TMP_ROOT/post-hash.expected"
  local capture="$TMP_ROOT/post-hash.capture" script="$TMP_ROOT/post-hash-capture.py"
  local ready="$TMP_ROOT/post-hash.ready" proceed="$TMP_ROOT/post-hash.proceed"
  local command parent_id file_id content_id pid
  mkdir "$transport"
  printf 'verified prefix\nverified suffix\n' > "$prompt"
  cp "$prompt" "$expected"
  cat > "$script" <<'PY'
import os
import sys
with open(sys.argv[1], "wb") as output:
    output.write(os.fsencode(sys.argv[2]))
PY
  command="exec python3 '$script' '$capture'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  FM_PROMPT_EXEC_TEST_READY="$ready" FM_PROMPT_EXEC_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" "$command" &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "prompt snapshot gate did not open"; }
  printf 'mutated after verification\n' > "$prompt"
  touch "$proceed"
  wait "$pid" || fail "prompt transport failed after its verified snapshot was captured"
  cmp -s "$capture" "$expected" || fail "prompt transport consumed bytes mutated after verification"
  assert_absent "$prompt" "prompt transport retained its consumed source after post-hash mutation"
  pass "continuation prompt transport consumes its immutable verified snapshot"
}

test_prompt_transport_keeps_provider_stdin_interactive() {
  local transport="$TMP_ROOT/interactive" prompt="$TMP_ROOT/interactive/prompt"
  local capture="$TMP_ROOT/interactive.capture" script="$TMP_ROOT/interactive.py"
  local command parent_id file_id content_id driver="$TMP_ROOT/interactive-driver.py"
  mkdir "$transport"
  printf 'initial\npacket' > "$prompt"
  cat > "$script" <<'PY'
import os, sys
def read_exact(size):
    chunks = []
    while size:
        chunk = os.read(0, size)
        if not chunk:
            raise RuntimeError("early EOF")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)
followup = read_exact(16)
with open(sys.argv[1], "wb") as output:
    output.write(b"tty=" + str(os.isatty(0)).encode() + b"\n")
    output.write(b"prompt=" + os.fsencode(sys.argv[2]) + b"\n")
    output.write(b"stdin=" + followup)
PY
  command="exec python3 '$script' '$capture'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  cat > "$driver" <<'PY'
import os, pty, subprocess, sys, time
master, slave = pty.openpty()
process = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
time.sleep(0.2)
os.write(master, b"later steering.\r")
status = process.wait(timeout=5)
os.close(master)
raise SystemExit(status)
PY
  python3 "$driver" python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" "$command" \
    || fail "continuation prompt transport did not preserve interactive provider stdin"
  cmp -s "$capture" <(printf 'tty=True\nprompt=initial\npacket\nstdin=later steering.\n') \
    || fail "continuation transport did not isolate its multiline prompt argument from interactive stdin"
  pass "continuation prompt transport leaves provider stdin interactive and unprimed"
}

test_prompt_transport_restores_inherited_terminal_state() {
  local transport="$TMP_ROOT/terminal-state" prompt="$TMP_ROOT/terminal-state/prompt"
  local driver="$TMP_ROOT/terminal-state-driver.py" command parent_id file_id content_id
  mkdir "$transport"
  printf 'packet' > "$prompt"
  cat > "$driver" <<'PY'
import fcntl, os, pty, subprocess, sys, termios
master, slave = pty.openpty()
before_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
before_termios = termios.tcgetattr(slave)
process = subprocess.run(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, close_fds=True, timeout=5)
after_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
after_termios = termios.tcgetattr(slave)
os.close(slave)
os.close(master)
if process.returncode != 0:
    raise SystemExit(process.returncode)
if after_flags != before_flags:
    raise RuntimeError("inherited stdin flags changed")
if after_termios != before_termios:
    raise RuntimeError("inherited stdin termios changed")
PY
  command="exec python3 -c 'pass'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  python3 "$driver" python3 "$ROOT/bin/fm-prompt-exec.py" \
    "$prompt" "$parent_id" "$file_id" "$content_id" "$command" \
    || fail "prompt transport did not restore inherited terminal state"
  pass "continuation prompt transport restores inherited stdin flags and termios"
}

test_prompt_transport_uses_one_native_multiline_argument
test_prompt_transport_rejects_non_argument_bytes
test_prompt_transport_rejects_replaced_generation
test_prompt_transport_rejects_replaced_parent
test_prompt_transport_rejects_in_place_mutation
test_prompt_transport_consumes_verified_snapshot_after_mutation
test_prompt_transport_keeps_provider_stdin_interactive
test_prompt_transport_restores_inherited_terminal_state
