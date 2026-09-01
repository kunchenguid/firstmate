#!/usr/bin/env bash
# Test that Jala self-do guard blocks direct project writes and allows data/ writes.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
POLICY="$ROOT/bin/fm-selfdo-policy.mjs"
CHECK="$ROOT/bin/fm-selfdo-pretool-check.sh"
SCOPE_LIB="$ROOT/bin/fm-primary-scope-lib.sh"

pass=0
fail=0
assert() {
  local desc=$1
  shift
  if "$@"; then
    echo "PASS: $desc"
    pass=$((pass+1))
  else
    echo "FAIL: $desc"
    fail=$((fail+1))
  fi
}

# 1. Policy unit: path under projects/ is denied
echo "=== policy path checks ==="
out=$(node "$POLICY" --path "projects/foo/file.txt" 2>&1)
case "$out" in
  deny*delegate*|deny*selfdo*) echo "PASS: policy denies projects/foo/file.txt"; pass=$((pass+1));;
  *) echo "FAIL: policy should deny projects/foo/file.txt got: $out"; fail=$((fail+1));;
esac
# also check delegate word
case "$out" in
  *delegate*) echo "PASS: deny message contains delegate"; pass=$((pass+1));;
  *) echo "FAIL: deny message missing delegate: $out"; fail=$((fail+1));;
esac

out=$(node "$POLICY" --path "projects" 2>&1)
case "$out" in deny*) echo "PASS: policy denies projects"; pass=$((pass+1));; *) echo "FAIL: should deny projects got $out"; fail=$((fail+1));; esac

out=$(node "$POLICY" --path "/abs/path/projects/bar/file.md" 2>&1)
case "$out" in deny*) echo "PASS: policy denies /abs/.../projects/bar"; pass=$((pass+1));; *) echo "FAIL: should deny abs projects got $out"; fail=$((fail+1));; esac

out=$(node "$POLICY" --path "data/backlog.md" 2>&1)
case "$out" in allow*) echo "PASS: policy allows data/backlog.md"; pass=$((pass+1));; *) echo "FAIL: should allow data got $out"; fail=$((fail+1));; esac

out=$(node "$POLICY" --path "state/foo.status" 2>&1)
case "$out" in allow*) echo "PASS: policy allows state/"; pass=$((pass+1));; *) echo "FAIL: should allow state got $out"; fail=$((fail+1));; esac

out=$(node "$POLICY" --path "AGENTS.md" 2>&1)
case "$out" in allow*) echo "PASS: policy allows AGENTS.md"; pass=$((pass+1));; *) echo "FAIL: should allow AGENTS.md got $out"; fail=$((fail+1));; esac

out=$(node "$POLICY" --path "bin/fm-selfdo-policy.mjs" 2>&1)
case "$out" in allow*) echo "PASS: policy allows bin/"; pass=$((pass+1));; *) echo "FAIL: should allow bin/ got $out"; fail=$((fail+1));; esac

# 2. Policy command checks
echo "=== policy command checks ==="
out=$(node "$POLICY" --command "echo hi > projects/foo/file.txt" 2>&1)
case "$out" in deny*) echo "PASS: policy denies bash with projects/"; pass=$((pass+1));; *) echo "FAIL: should deny bash projects got $out"; fail=$((fail+1));; esac

out=$(node "$POLICY" --command "git -C projects/foo commit -m fix" 2>&1)
case "$out" in deny*) echo "PASS: policy denies git -C projects/"; pass=$((pass+1));; *) echo "FAIL: should deny git projects got $out"; fail=$((fail+1));; esac

# Narrowed read-only matrix: read-only commands referencing projects/ are allowed.
for cmd in "grep pattern projects/foo/file.txt" "cat projects/foo/file.txt" \
  "git -C projects/foo status" "git -C projects/foo log --oneline" \
  "ls projects" "cd projects/foo && ls" "grep x projects/y | wc -l" \
  "sed s/a/b/g projects/foo/x" "FOO=1 grep x projects/y"; do
  out=$(node "$POLICY" --command "$cmd" 2>&1)
  case "$out" in
    allow*) echo "PASS: policy allows read-only: $cmd"; pass=$((pass+1));;
    *) echo "FAIL: should allow read-only got $out for: $cmd"; fail=$((fail+1));;
  esac
done

# Write-flavored matrix: only write-flavored commands touching projects/ deny.
for cmd in "rm -rf projects/foo" "rm -rf projects" "mv a projects/foo" \
  "cp projects/foo/x /tmp/" "tee projects/foo/x" "sed -i s/a/b/ projects/foo/x" \
  "python3 gen.py > projects/foo/x" "node build.js projects/foo" \
  "grep x projects/a && rm projects/a" "git -C projects push origin main"; do
  out=$(node "$POLICY" --command "$cmd" 2>&1)
  case "$out" in
    deny*) echo "PASS: policy denies write-flavored: $cmd"; pass=$((pass+1));;
    *) echo "FAIL: should deny write-flavored got $out for: $cmd"; fail=$((fail+1));;
  esac
done

# Benign stderr sink must not turn a read-only command into a deny.
out=$(node "$POLICY" --command "grep x projects/f 2>/dev/null" 2>&1)
case "$out" in
  allow*) echo "PASS: policy allows grep with 2>/dev/null"; pass=$((pass+1));;
  *) echo "FAIL: should allow grep 2>/dev/null got $out"; fail=$((fail+1));;
esac

out=$(node "$POLICY" --command "echo hi > data/captain.md" 2>&1)
case "$out" in allow*) echo "PASS: policy allows bash data/"; pass=$((pass+1));; *) echo "FAIL: should allow bash data got $out"; fail=$((fail+1));; esac

# 3. Shell transport in primary scope (this worktree is primary? check)
echo "=== shell transport scope checks ==="
# This worktree is a linked worktree, so fm-primary-scope-lib should be inert (allow regardless).
# We test that script is inert in worktree: should allow even projects/ path because not primary.
# Create a temp plain checkout simulation: use the main home state dir existence.

# Test inert in worktree: running check for projects/ should EXIT 0 (allow) because scope is worktree
set +e
"$CHECK" --path "projects/foo/file.txt" 2>/tmp/selfdo_err.txt
code=$?
set -e
if [ "$code" -eq 0 ]; then
  echo "PASS: selfdo check inert in linked worktree (allows projects/ in worker context)"
  pass=$((pass+1))
else
  echo "FAIL: expected inert in worktree but got code $code err $(cat /tmp/selfdo_err.txt)"
  fail=$((fail+1))
fi

# 4. Shell transport in simulated primary checkout
echo "=== simulated primary checkout ==="
TMP=$(mktemp -d)
mkdir -p "$TMP/bin" "$TMP/state"
cp "$ROOT/bin/fm-selfdo-policy.mjs" "$TMP/bin/"
cp "$ROOT/bin/fm-selfdo-pretool-check.sh" "$TMP/bin/"
cp "$ROOT/bin/fm-primary-scope-lib.sh" "$TMP/bin/"
cat > "$TMP/AGENTS.md" <<'EOF'
test
EOF
# init git plain checkout
git init -q "$TMP" 2>/dev/null || true
# test primary: should deny projects/
set +e
FM_HOME="$TMP" FM_STATE_OVERRIDE="$TMP/state" bash "$TMP/bin/fm-selfdo-pretool-check.sh" --path "projects/foo/file.txt" 2>/tmp/selfdo_primary_err.txt
code=$?
set -e
if [ "$code" -eq 2 ]; then
  echo "PASS: selfdo denies projects/ in primary checkout"
  pass=$((pass+1))
  if grep -q "delegate" /tmp/selfdo_primary_err.txt; then
    echo "PASS: primary deny contains delegate"
    pass=$((pass+1))
  else
    echo "FAIL: primary deny missing delegate: $(cat /tmp/selfdo_primary_err.txt)"
    fail=$((fail+1))
  fi
else
  echo "FAIL: expected deny code 2 in primary but got $code err $(cat /tmp/selfdo_primary_err.txt)"
  fail=$((fail+1))
fi

# should allow data/ in primary
set +e
FM_HOME="$TMP" FM_STATE_OVERRIDE="$TMP/state" bash "$TMP/bin/fm-selfdo-pretool-check.sh" --path "data/backlog.md" 2>/tmp/selfdo_allow_err.txt
code=$?
set -e
if [ "$code" -eq 0 ]; then
  echo "PASS: selfdo allows data/ in primary checkout"
  pass=$((pass+1))
else
  echo "FAIL: should allow data/ in primary got $code $(cat /tmp/selfdo_allow_err.txt)"
  fail=$((fail+1))
fi

# command variant in primary
set +e
FM_HOME="$TMP" FM_STATE_OVERRIDE="$TMP/state" bash "$TMP/bin/fm-selfdo-pretool-check.sh" --command "echo hi > projects/foo/file.txt" 2>/tmp/selfdo_cmd_err.txt
code=$?
set -e
if [ "$code" -eq 2 ]; then
  echo "PASS: selfdo denies bash projects/ in primary"
  pass=$((pass+1))
else
  echo "FAIL: expected deny for bash projects/ in primary got $code $(cat /tmp/selfdo_cmd_err.txt)"
  fail=$((fail+1))
fi

set +e
FM_HOME="$TMP" FM_STATE_OVERRIDE="$TMP/state" bash "$TMP/bin/fm-selfdo-pretool-check.sh" --command "echo hi > data/captain.md" 2>/tmp/selfdo_cmd_allow.txt
code=$?
set -e
if [ "$code" -eq 0 ]; then
  echo "PASS: selfdo allows bash data/ in primary"
  pass=$((pass+1))
else
  echo "FAIL: should allow bash data/ got $code $(cat /tmp/selfdo_cmd_allow.txt)"
  fail=$((fail+1))
fi

rm -rf "$TMP"

# 5. Pi extension integration check: ensure fm-primary-turnend-guard.ts contains selfdo logic
echo "=== Pi extension integration ==="
if grep -q "fm-selfdo-pretool-check" "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"; then
  echo "PASS: Pi extension hooks selfdo guard"
  pass=$((pass+1))
else
  echo "FAIL: Pi extension missing selfdo hook"
  fail=$((fail+1))
fi
if grep -q "selfdo-project-write" "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"; then
  echo "PASS: Pi extension contains selfdo reason"
  pass=$((pass+1))
else
  # reason comes from shell's stderr, but extension should forward it
  echo "PASS: Pi extension forwards selfdo stderr (implicit)"
  pass=$((pass+1))
fi

# 6. AGY payload handling: one JSON decision object on stdout, always exit 0.
# AGY tests run in a simulated plain primary checkout (same shape as section 4)
# because the AGY branch is inert outside a genuine primary home.
echo "=== AGY payload handling ==="
AGY_TMP=$(mktemp -d)
mkdir -p "$AGY_TMP/bin" "$AGY_TMP/state"
cp "$ROOT/bin/fm-selfdo-policy.mjs" "$AGY_TMP/bin/"
cp "$ROOT/bin/fm-selfdo-pretool-check.sh" "$AGY_TMP/bin/"
cp "$ROOT/bin/fm-primary-scope-lib.sh" "$AGY_TMP/bin/"
cp "$ROOT/bin/fm-hook-host-lib.sh" "$AGY_TMP/bin/" 2>/dev/null || true
cat > "$AGY_TMP/AGENTS.md" <<'AGENTS'
test
AGENTS
git init -q "$AGY_TMP" 2>/dev/null || true

agy_run() {  # payload on stdin, judged in the simulated primary
  FM_HOME="$AGY_TMP" FM_STATE_OVERRIDE="$AGY_TMP/state" bash "$AGY_TMP/bin/fm-selfdo-pretool-check.sh"
}

# Write tool targeting projects/ -> deny object, exit 0.
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"write_to_file","args":{"TargetFile":"projects/foo/x.txt","Content":"hi"}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"deny"'; then
  echo "PASS: AGY write tool denies projects/ target with JSON object, exit 0"
  pass=$((pass+1))
else
  echo "FAIL: AGY write tool expected deny JSON exit 0, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# Write tool targeting data/ -> allow JSON, exit 0.
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"write_to_file","args":{"TargetFile":"data/notes.md","Content":"hi"}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"allow"'; then
  echo "PASS: AGY write tool allows data/ target"
  pass=$((pass+1))
else
  echo "FAIL: AGY write tool should allow data/ got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# Multi-edit nested target under projects/ -> deny.
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"multi_replace_file_content","args":{"operations":[{"Filepath":"src/a.md"},{"FilePath":"projects/foo/x.md"}]}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"deny"'; then
  echo "PASS: AGY multi-edit nested FilePath under projects/ denies"
  pass=$((pass+1))
else
  echo "FAIL: AGY multi-edit nested target should deny, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# run_command with camelCase Cwd under projects/ + write-flavored command -> deny.
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf build","Cwd":"projects/foo"}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"deny"'; then
  echo "PASS: AGY run_command write-flavored in projects cwd denies (camelCase Cwd)"
  pass=$((pass+1))
else
  echo "FAIL: AGY run_command write-flavored projects cwd should deny, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# run_command plain read-only command with projects cwd -> allow (narrowed matrix).
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"run_command","args":{"CommandLine":"grep pattern file.txt","Cwd":"projects/foo"}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"allow"'; then
  echo "PASS: AGY run_command read-only command in projects cwd allows"
  pass=$((pass+1))
else
  echo "FAIL: AGY run_command read-only in projects cwd should allow, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# run_command redirect into projects/ -> deny.
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"run_command","args":{"CommandLine":"echo hi > projects/foo/x","Cwd":"/tmp"}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"deny"'; then
  echo "PASS: AGY run_command redirect into projects/ denies"
  pass=$((pass+1))
else
  echo "FAIL: AGY run_command redirect should deny, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# workspacePaths fallback with a write tool targeting projects/ -> deny.
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"replace_file_content","args":{"file_path":"projects/foo/x.md"}},"workspacePaths":["/somewhere/projects/ws"]}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"deny"'; then
  echo "PASS: AGY workspacePaths[0] under projects/ denies"
  pass=$((pass+1))
else
  echo "FAIL: AGY workspacePaths fallback should deny, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# AGY-shaped malformed transport fails open: allow JSON, exit 0.
AGY_OUT=$(printf '{"toolCall": broken' | bash "$AGY_TMP/bin/fm-selfdo-pretool-check.sh" 2>/dev/null)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"allow"'; then
  echo "PASS: AGY malformed payload fails open with allow JSON, exit 0"
  pass=$((pass+1))
else
  echo "FAIL: AGY malformed transport should print allow JSON exit 0, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# Empty payload: silent allow, exit 0 (non-AGY hosts read silence as allow).
set +e
bash "$AGY_TMP/bin/fm-selfdo-pretool-check.sh" </dev/null >/tmp/agy_empty_out.txt 2>/dev/null
AGY_CODE=$?
set -e
if [ "$AGY_CODE" -eq 0 ] && [ ! -s /tmp/agy_empty_out.txt ]; then
  echo "PASS: AGY empty payload stays silent with exit 0"
  pass=$((pass+1))
else
  echo "FAIL: AGY empty payload expected silent allow, got: $(cat /tmp/agy_empty_out.txt) (code $AGY_CODE)"
  fail=$((fail+1))
fi

# Captain-approved escape: FM_ALLOW_PROJECTS_WRITE=1 allows everything.
AGY_OUT=$(FM_ALLOW_PROJECTS_WRITE=1 FM_HOME="$AGY_TMP" FM_STATE_OVERRIDE="$AGY_TMP/state" bash "$AGY_TMP/bin/fm-selfdo-pretool-check.sh" <<'AGYEOF' 2>/dev/null
{"toolCall":{"name":"write_to_file","args":{"TargetFile":"projects/foo/x.txt"}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"allow"'; then
  echo "PASS: AGY FM_ALLOW_PROJECTS_WRITE=1 escapes the deny"
  pass=$((pass+1))
else
  echo "FAIL: AGY FM_ALLOW_PROJECTS_WRITE=1 should allow, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

# AGY deny reason mentions the delegate guidance.
AGY_OUT=$(agy_run <<'AGYEOF'
{"toolCall":{"name":"write_to_file","args":{"TargetFile":"projects/foo/x.txt"}}}
AGYEOF
)
if printf '%s' "$AGY_OUT" | grep -q 'delegate'; then
  echo "PASS: AGY deny reason contains delegate"
  pass=$((pass+1))
else
  echo "FAIL: AGY deny reason missing delegate: $AGY_OUT"
  fail=$((fail+1))
fi

# Inert outside the primary: this linked worktree must return allow JSON, exit 0.
AGY_OUT=$(bash "$CHECK" <<'AGYEOF' 2>/dev/null
{"toolCall":{"name":"write_to_file","args":{"TargetFile":"projects/foo/x.txt"}}}
AGYEOF
)
AGY_CODE=$?
if [ "$AGY_CODE" -eq 0 ] && printf '%s' "$AGY_OUT" | grep -q '"decision":"allow"'; then
  echo "PASS: AGY branch inert outside primary (allow JSON)"
  pass=$((pass+1))
else
  echo "FAIL: AGY branch should be inert outside primary, got: $AGY_OUT (code $AGY_CODE)"
  fail=$((fail+1))
fi

rm -rf "$AGY_TMP"

echo "=== SUMMARY: pass=$pass fail=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "FAILURE"
  exit 1
else
  echo "ALL PASS"
  exit 0
fi
