#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-compaction.sh.
# Fixture-driven. No case touches the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-jev-compaction.sh"
FIXTURE_TRACE="$ROOT/tests/fixtures/jev-compaction/trace.jsonl"
FIXTURE_SCORES="$ROOT/tests/fixtures/jev-compaction/scores.json"

if [ ! -x "$SCRIPT" ]; then
  chmod +x "$SCRIPT"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-compaction-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
export FM_HOME="$HOME_DIR"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

unset FM_JEV_COMPACTION FM_JEV_COMPACTION_THRESHOLD || true

# 1. Default off: no park dir, exit 0 even with a missing trace.
if ! FM_HOME="$HOME_DIR" "$SCRIPT" --task t --trace "$TMP/missing.jsonl"; then
  fail "default off should exit 0"
fi
if [ -e "$HOME_DIR/state/t/trace-park" ]; then
  fail "default off must not create a park dir"
fi
pass "default off is a no-op"

# 2. Explicit off wins over the presence-flag file.
: > "$HOME_DIR/config/jev-compaction"
if ! FM_JEV_COMPACTION=off "$SCRIPT" --task t --trace "$FIXTURE_TRACE" --scores "$FIXTURE_SCORES"; then
  fail "FM_JEV_COMPACTION=off should exit 0"
fi
if [ -e "$HOME_DIR/state/t/trace-park" ]; then
  fail "explicit off must not park"
fi
pass "FM_JEV_COMPACTION=off no-ops even with config/jev-compaction"

rm -f "$HOME_DIR/config/jev-compaction"

# 3. Opt-in via env: park only the trailing low-value run (s4, s5). Keep s2.
OUT="$TMP/compacted.jsonl"
PARK="$TMP/park-suffix"
FM_JEV_COMPACTION=on "$SCRIPT" \
  --task demo \
  --trace "$FIXTURE_TRACE" \
  --scores "$FIXTURE_SCORES" \
  --park-dir "$PARK" \
  --out "$OUT" || fail "opt-in suffix park should succeed"

if [ ! -f "$PARK/index.jsonl" ]; then
  fail "expected park index"
fi
parked_ids="$(jq -rs 'map(.id) | join(",")' "$PARK/index.jsonl")"
[ "$parked_ids" = "s4,s5" ] || fail "default park should be trailing s4,s5, got $parked_ids"

kept_ids="$(jq -rs 'map(.id) | join(",")' "$OUT")"
[ "$kept_ids" = "s1,s2,s3" ] || fail "kept ids should be s1,s2,s3, got $kept_ids"

head -n 3 "$FIXTURE_TRACE" > "$TMP/prefix.jsonl"
head -n 3 "$OUT" > "$TMP/out-prefix.jsonl"
if ! cmp -s "$TMP/prefix.jsonl" "$TMP/out-prefix.jsonl"; then
  fail "live prompt prefix must be byte-identical"
fi
if grep -q '"id":"s2"' "$PARK/index.jsonl"; then
  fail "must not park middle s2 by default (KV cache)"
fi
pass "suffix park keeps prefix and middle s2"

# 4. --cache-busted may park the middle low-value segment too.
OUT2="$TMP/compacted-busted.jsonl"
PARK2="$TMP/park-busted"
FM_JEV_COMPACTION=on "$SCRIPT" \
  --task demo \
  --trace "$FIXTURE_TRACE" \
  --scores "$FIXTURE_SCORES" \
  --park-dir "$PARK2" \
  --out "$OUT2" \
  --cache-busted || fail "cache-busted park should succeed"

busted_ids="$(jq -rs 'map(.id) | join(",")' "$PARK2/index.jsonl")"
[ "$busted_ids" = "s2,s4,s5" ] || fail "cache-busted should park s2,s4,s5, got $busted_ids"
kept_busted="$(jq -rs 'map(.id) | join(",")' "$OUT2")"
[ "$kept_busted" = "s1,s3" ] || fail "cache-busted kept should be s1,s3, got $kept_busted"
pass "cache-busted parks middle low-value segments"

# 5. Presence-flag file enables without FM_JEV_COMPACTION.
: > "$HOME_DIR/config/jev-compaction"
unset FM_JEV_COMPACTION || true
PARK3="$HOME_DIR/state/flag/trace-park"
FM_HOME="$HOME_DIR" "$SCRIPT" \
  --task flag \
  --trace "$FIXTURE_TRACE" \
  --scores "$FIXTURE_SCORES" \
  --out "$TMP/from-flag.jsonl" || fail "config/jev-compaction should enable"
[ -f "$PARK3/index.jsonl" ] || fail "presence flag should park under state/<id>/trace-park"
pass "config/jev-compaction presence flag enables"

printf 'all tests passed\n'
