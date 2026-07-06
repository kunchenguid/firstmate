#!/usr/bin/env bash
# Behavior tests for bin/fm-ctx-hook.sh - the claude Stop-hook helper installed by
# fm-spawn.sh. Every turn it must do two independent things:
#   1. touch <turnend-file>  - the unchanged turn-end signal the watcher relies on;
#      this must happen even when context recording cannot (no jq, no transcript).
#   2. record the crewmate's context tokens to <context-file>, summed from the
#      transcript's LAST usage record as
#      input_tokens + cache_creation_input_tokens + cache_read_input_tokens.
# The Stop payload arrives as JSON on stdin carrying .transcript_path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-ctx-hook.sh"
TMP=$(fm_test_tmproot fm-ctx-hook)
mkdir -p "$TMP"

# fire <transcript-path-or-empty> -> sets TE/CTX to fresh paths and runs the hook
# with a synthetic Stop payload naming the transcript.
fire() {
  local tp=$1 payload
  TE="$TMP/turnend.$RANDOM"
  CTX="$TMP/context.$RANDOM"
  if [ -n "$tp" ]; then
    payload=$(printf '{"transcript_path":"%s"}' "$tp")
  else
    payload='{}'
  fi
  printf '%s' "$payload" | bash "$HOOK" "$TE" "$CTX"
}

# --- last usage record wins, formula sums the three input axes ----------------
tr1="$TMP/tr1.jsonl"
cat > "$tr1" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000,"output_tokens":77}}}
EOF
fire "$tr1"
assert_present "$TE" "turn-end file touched on a normal fire"
[ "$(cat "$CTX")" = 33000 ] || fail "context = last-record sum: got $(cat "$CTX"), want 33000"
pass "records last usage record's summed context (1000+2000+30000)"

# --- output_tokens is NOT counted (context = input side only) -----------------
tr2="$TMP/tr2.jsonl"
cat > "$tr2" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":999999}}}
EOF
fire "$tr2"
[ "$(cat "$CTX")" = 5 ] || fail "output_tokens must be excluded: got $(cat "$CTX"), want 5"
pass "excludes output_tokens from the context total"

# --- missing cache fields default to 0 ---------------------------------------
tr3="$TMP/tr3.jsonl"
cat > "$tr3" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":42}}}
EOF
fire "$tr3"
[ "$(cat "$CTX")" = 42 ] || fail "absent cache fields default to 0: got $(cat "$CTX"), want 42"
pass "treats absent cache_* fields as 0"

# --- no transcript_path: turn-end still fires, no context written ------------
fire ""
assert_present "$TE" "turn-end file touched even with no transcript_path"
assert_absent "$CTX" "no context file written when payload lacks transcript_path"
pass "no transcript_path: turn-end fires, context is not written"

# --- transcript_path points at a missing file -------------------------------
fire "$TMP/does-not-exist.jsonl"
assert_present "$TE" "turn-end file touched even when transcript file is missing"
assert_absent "$CTX" "no context file written when transcript file is missing"
pass "missing transcript file: turn-end fires, context is not written"

# --- transcript with no usage records at all --------------------------------
tr4="$TMP/tr4.jsonl"
cat > "$tr4" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"summary","summary":"nothing"}
EOF
fire "$tr4"
assert_present "$TE" "turn-end file touched even when transcript has no usage"
assert_absent "$CTX" "no context file written when transcript has no usage record"
pass "transcript with no usage record: turn-end fires, context is not written"

pass "fm-ctx-hook: all cases"
