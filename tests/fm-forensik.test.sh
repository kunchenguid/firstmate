#!/usr/bin/env bash
# tests/fm-forensik.test.sh - the daily forensics must extract deterministically,
# select only the target date's transcripts, mark the candidate stage honestly,
# and never touch the lesson ledger:
#
#   1. Only transcripts touched on the target date enter extraktion.tsv, with
#      correct per-file message/wake/error counts.
#   2. forensik.md line 1 carries the one-line verdict with the real totals.
#   3. Without FM_FORENSIK_LESEN the candidates file says the reading pass did
#      not run, and still carries the HYPOTHESE stage marker.
#   4. The lesson ledger stays byte-identical.
#
# Isolation: throwaway FM_HOME and transcript root. Nothing reads the real accounts.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
ROOT="$TMP/projects"
mkdir -p "$HOME_A/data/forensik-2026-08" "$ROOT/p1"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

DATUM="2026-08-20"
cat > "$ROOT/p1/im-fenster.jsonl" <<'EOF'
{"type":"user","message":{"content":"hallo"}}
{"type":"assistant","message":{"content":"aye"}}
{"type":"user","message":{"content":"Stop hook feedback: signal"}}
{"type":"assistant","message":{"content":"ok"},"is_error":true}
EOF
touch -d "$DATUM 12:00" "$ROOT/p1/im-fenster.jsonl"
printf '{"type":"user","message":{"content":"alt"}}\n' > "$ROOT/p1/zu-alt.jsonl"
touch -d "2026-08-10 12:00" "$ROOT/p1/zu-alt.jsonl"
printf '# Lehren-Ledger Sentinel\n' > "$HOME_A/data/forensik-2026-08/lehren-ledger.md"
ledger_before="$(cat "$HOME_A/data/forensik-2026-08/lehren-ledger.md")"

FM_HOME="$HOME_A" FM_FORENSIK_ROOTS="$ROOT" "$REPO/bin/fm-forensik.sh" run --datum "$DATUM" >/dev/null \
  || fail "forensik run must succeed"
OUT="$HOME_A/data/tagesschluss/$DATUM"

# --- 1. date selection and counts -----------------------------------------
grep -q 'im-fenster.jsonl' "$OUT/extraktion.tsv" && ok "the in-window transcript is extracted" \
  || fail "the in-window transcript must be extracted"
grep -q 'zu-alt.jsonl' "$OUT/extraktion.tsv" && fail "an out-of-window transcript must be skipped" \
  || ok "the out-of-window transcript is skipped"
row="$(grep 'im-fenster.jsonl' "$OUT/extraktion.tsv")"
echo "$row" | awk -F'\t' '{exit !($2==4 && $3==2 && $4==2 && $5==1 && $6==1)}' \
  && ok "lines/user/assistant/wake/error counts are exact (4/2/2/1/1)" \
  || fail "extraction counts wrong: $row"

# --- 2. verdict line -------------------------------------------------------
head -1 "$OUT/forensik.md" | grep -q '^1 sessions, 4 messages, 1 wake deliveries, 1 error-marked lines' \
  && ok "forensik.md line 1 carries the real totals" \
  || fail "verdict line wrong: $(head -1 "$OUT/forensik.md")"
grep -q 'NOT decision-capable' "$OUT/forensik.md" \
  && ok "judge status is honestly marked not decision-capable" \
  || fail "the judge status marker is missing"
grep -q '^Record divergence' "$OUT/forensik.md" \
  && ok "the record-divergence guard reports into the day's forensics" \
  || fail "forensik.md must carry a Record divergence line (silent day: 'none.')"

# --- 3. candidate stage ----------------------------------------------------
grep -q 'STUFE: HYPOTHESE' "$OUT/lehren-kandidaten.md" \
  && ok "candidates carry the hypothesis stage marker" \
  || fail "candidates must carry the hypothesis stage marker"
grep -q 'nicht gefahren' "$OUT/lehren-kandidaten.md" \
  && ok "the skipped reading pass is recorded, not hidden" \
  || fail "a skipped reading pass must be recorded"

# --- 4. the ledger is untouched -------------------------------------------
[ "$(cat "$HOME_A/data/forensik-2026-08/lehren-ledger.md")" = "$ledger_before" ] \
  && ok "the lesson ledger stays byte-identical" \
  || fail "forensik must never write the lesson ledger"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-forensik.test.sh: all checks passed"
  exit 0
fi
echo "fm-forensik.test.sh: $FAILS check(s) FAILED"
exit 1
