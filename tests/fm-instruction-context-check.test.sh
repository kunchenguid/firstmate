#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

protected='FLEET_FIRSTMATE_INSTRUCTIONS_START FM-HARD-1 FM-HARD-2 FM-HARD-3 FM-HARD-4 FM-HARD-5 FM-SESSION-START FM-LOCK-REFUSAL FM-CAPTAIN-PRECEDENCE FLEET_FIRSTMATE_INSTRUCTIONS_END'

write_fixture() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, text = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump([{"role": "user", "content": [{"type": "input_text", "text": text}]}], handle)
PY
}

expect_red() {
  expected=$1
  shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    echo "not ok - expected failure containing: $expected" >&2
    exit 1
  fi
  grep -F "$expected" "$TMP/err" >/dev/null || {
    cat "$TMP/err" >&2
    echo "not ok - missing failure text: $expected" >&2
    exit 1
  }
}

write_fixture "$TMP/valid.json" "$protected"
printf '%s' "$protected" >"$TMP/AGENTS.md"
mkdir "$TMP/bin"
cat >"$TMP/bin/codex" <<'SH'
#!/bin/sh
[ "$1" = debug ] && [ "$2" = prompt-input ] || exit 2
cat "$FM_PROMPT_FIXTURE"
SH
chmod +x "$TMP/bin/codex"

FM_PROMPT_FIXTURE="$TMP/valid.json" CODEX_BIN="$TMP/bin/codex" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --budget 20 --agents-md "$TMP/AGENTS.md" >/dev/null

write_fixture "$TMP/missing-end.json" "${protected% FLEET_FIRSTMATE_INSTRUCTIONS_END}"
expect_red "missing FLEET_FIRSTMATE_INSTRUCTIONS_END" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --input-json "$TMP/missing-end.json" --budget 20 --agents-md "$TMP/AGENTS.md"

write_fixture "$TMP/missing-rule.json" "${protected/ FM-HARD-3/}"
expect_red "missing FM-HARD-3" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --input-json "$TMP/missing-rule.json" --budget 20 --agents-md "$TMP/AGENTS.md"

expect_red "exceeds budget 1" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --input-json "$TMP/valid.json" --budget 1 --agents-md "$TMP/AGENTS.md"

python3 - "$TMP/valid.json" "$TMP/duplicate.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
payload.append(payload[0])
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
expect_red "found 2" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --input-json "$TMP/duplicate.json" --budget 20 --agents-md "$TMP/AGENTS.md"

printf 'not json\n' >"$TMP/invalid.json"
expect_red "cannot read Codex prompt input" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --input-json "$TMP/invalid.json" --budget 20 --agents-md "$TMP/AGENTS.md"

reordered="FLEET_FIRSTMATE_INSTRUCTIONS_START FM-HARD-1 FM-HARD-2 FM-SESSION-START FM-HARD-3 FM-HARD-4 FM-HARD-5 FM-LOCK-REFUSAL FM-CAPTAIN-PRECEDENCE FLEET_FIRSTMATE_INSTRUCTIONS_END"
write_fixture "$TMP/reordered.json" "$reordered"
expect_red "out of order" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --input-json "$TMP/reordered.json" --budget 20 --agents-md "$TMP/AGENTS.md"

# Same markers, same order, as fm-instruction-context-check.py's presence/order
# checks alone would accept -- but the substantive text between FM-HARD-2 and
# FM-HARD-3 that AGENTS.md actually carries was silently dropped in transit.
printf '%s' "${protected/ FM-HARD-3/ the safety boundary text for FM-HARD-3 FM-HARD-3}" >"$TMP/AGENTS-richer.md"
expect_red "do not match AGENTS.md verbatim" \
  python3 "$ROOT/bin/fm-instruction-context-check.py" --input-json "$TMP/valid.json" --budget 20 --agents-md "$TMP/AGENTS-richer.md"

echo "ok - instruction context check exercises live command and red paths"
