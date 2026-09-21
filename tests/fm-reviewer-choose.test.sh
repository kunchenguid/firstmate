#!/usr/bin/env bash
# Regression tests for bin/fm-reviewer-choose.sh.
# Drives the public argv interface with fixture quota-axi JSON snapshots and a
# fake quota-axi that must never be called: selection reads one captured
# snapshot, so any live quota call is a failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-reviewer-choose.XXXXXX")
FIXTURE="$LAB/quota.json"
BAD_SCHEMA="$LAB/bad-schema.json"
MALFORMED="$LAB/malformed.json"
FAKEBIN="$LAB/fakebin"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN"

# Codex exhausted (the ticket's usage-limits case), Claude healthy after reset,
# Pi healthy. Grok is absent: unmodeled quota, ineligible under the chooser.
cat > "$FIXTURE" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "codex",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 62,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    },
    {
      "provider": "pi",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 40,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    }
  ]
}
JSON

cat > "$BAD_SCHEMA" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 4,
  "providers": []
}
JSON

printf 'not json\n' > "$MALFORMED"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'quota-axi must not be called by reviewer selection\n' >&2
exit 99
SH
chmod +x "$FAKEBIN/quota-axi"

call_choose() {
  PATH="$FAKEBIN:$PATH" "$BIN/fm-reviewer-choose.sh" "$@"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$1"
}

if help=$("$BIN/fm-reviewer-choose.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'reviewer: <harness> <model>' \
  || fail "help omitted the selection output contract"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders the complete header only"

# 1. First healthy candidate is selected with no skipped lines.
out=$(call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate claude:claude-opus-5 --candidate pi:openai-codex/gpt-6-astra)
[ "$out" = "reviewer: claude claude-opus-5" ] \
  || fail "healthy first: expected only the reviewer line, got '$out'"
ok "first healthy candidate is selected directly"

# 2. Quota-exhausted reviewer fails over to the next eligible candidate and
# the switch is recorded with its reason.
out=$(call_choose --author pi:openai-codex/gpt-6-astra --snapshot "$FIXTURE" \
  --candidate codex:gpt-6 --candidate claude:claude-opus-5)
expected="skipped: codex:gpt-6 quota-ineligible
reviewer: claude claude-opus-5"
[ "$out" = "$expected" ] || fail "failover: expected '$expected', got '$out'"
ok "exhausted reviewer fails over with a recorded switch"

# 3. The author is skipped even when quota-healthy; selection continues.
out=$(call_choose --author claude:claude-opus-5 --snapshot "$FIXTURE" \
  --candidate claude:claude-opus-5 --candidate pi:anthropic/claude-sonnet-5@claude)
expected="skipped: claude:claude-opus-5 author
reviewer: pi anthropic/claude-sonnet-5"
[ "$out" = "$expected" ] || fail "author skip: expected '$expected', got '$out'"
ok "author candidate is skipped for a non-author reviewer"

# 3b. The same underlying model reached through another harness is still the
# author: the docs/examples/crew-dispatch.json pair claude/claude-sonnet-5 and
# pi/anthropic/claude-sonnet-5 compares equal in both directions.
out=$(call_choose --author claude:claude-sonnet-5 --snapshot "$FIXTURE" \
  --candidate pi:anthropic/claude-sonnet-5 --candidate claude:claude-opus-5)
expected="skipped: pi:anthropic/claude-sonnet-5 author
reviewer: claude claude-opus-5"
[ "$out" = "$expected" ] || fail "cross-harness author: expected '$expected', got '$out'"
out=$(call_choose --author pi:anthropic/claude-sonnet-5 --snapshot "$FIXTURE" \
  --candidate claude:Claude-Sonnet-5@claude --candidate claude:claude-opus-5)
expected="skipped: claude:Claude-Sonnet-5@claude author
reviewer: claude claude-opus-5"
[ "$out" = "$expected" ] || fail "cross-harness author reverse: expected '$expected', got '$out'"
if out=$(call_choose --author claude:claude-sonnet-5 --snapshot "$FIXTURE" \
  --candidate pi:anthropic/claude-sonnet-5 2>/dev/null); then
  fail "cross-harness author: expected a park, got exit 0 with '$out'"
fi
ok "the non-author gate holds across harness spellings"

# 4. A leading model: scope prefix still counts as the same author.
out=$(call_choose --author codex:codex_bengalfox --snapshot "$FIXTURE" \
  --candidate codex:model:codex_bengalfox --candidate claude:claude-opus-5)
expected="skipped: codex:model:codex_bengalfox author
reviewer: claude claude-opus-5"
[ "$out" = "$expected" ] || fail "author normalization: expected '$expected', got '$out'"
ok "model scope prefix does not evade the non-author gate"

# 5. No eligible candidate parks with a truthful per-candidate diagnostic.
if out=$(call_choose --author claude:claude-opus-5 --snapshot "$FIXTURE" \
  --candidate codex:gpt-6 --candidate claude:claude-opus-5 2>/dev/null); then
  fail "park: expected exit 1, got exit 0 with '$out'"
fi
expected="skipped: codex:gpt-6 quota-ineligible
skipped: claude:claude-opus-5 author
park: no eligible reviewer (codex:gpt-6=quota-ineligible, claude:claude-opus-5=author)"
[ "$out" = "$expected" ] || fail "park: expected '$expected', got '$out'"
ok "exhausted field parks with a truthful diagnostic"

# 6. A reviewer that needs approval is skipped until approval is granted.
if out=$(call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate claude:claude-opus-5 --needs-approval claude:claude-opus-5 2>/dev/null); then
  fail "approval: expected exit 1, got exit 0 with '$out'"
fi
case "$out" in
  *"skipped: claude:claude-opus-5 needs-approval"*"park: no eligible reviewer"*) ;;
  *) fail "approval: expected a needs-approval park, got '$out'" ;;
esac
out=$(call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate codex:gpt-6 --candidate claude:claude-opus-5 \
  --needs-approval claude:claude-opus-5 --approved claude:claude-opus-5)
expected="skipped: codex:gpt-6 quota-ineligible
reviewer: claude claude-opus-5"
[ "$out" = "$expected" ] || fail "approval grant: expected '$expected', got '$out'"
ok "approval gate holds without approval and releases with it"

# 7. The record file captures selections and parks.
RECORD="$LAB/switches.log"
: > "$RECORD"
call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate codex:gpt-6 --candidate claude:claude-opus-5 \
  --record "$RECORD" >/dev/null
call_choose --author claude:claude-opus-5 --snapshot "$FIXTURE" \
  --candidate codex:gpt-6 --candidate claude:claude-opus-5 \
  --record "$RECORD" >/dev/null 2>&1 || true
[ "$(wc -l < "$RECORD" | tr -d '[:space:]')" = 2 ] || fail "record: expected two lines, got '$(cat "$RECORD")'"
grep -Eq '^reviewer-choose [0-9]+ selected claude claude-opus-5 skipped codex:gpt-6=quota-ineligible$' "$RECORD" \
  || fail "record: missing selection line in '$(cat "$RECORD")'"
grep -Eq '^reviewer-choose [0-9]+ parked skipped codex:gpt-6=quota-ineligible, claude:claude-opus-5=author$' "$RECORD" \
  || fail "record: missing park line in '$(cat "$RECORD")'"
ok "switch record captures selections and parks"

# 7b. A declared provider is measured against that provider's row, not the
# harness's primary family: with the pi row healthy and the codex row
# exhausted, pi:openai-codex/gpt-6-astra@codex is quota-ineligible.
out=$(call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate pi:openai-codex/gpt-6-astra@codex --candidate claude:claude-opus-5)
expected="skipped: pi:openai-codex/gpt-6-astra@codex quota-ineligible
reviewer: claude claude-opus-5"
[ "$out" = "$expected" ] || fail "declared provider: expected '$expected', got '$out'"
out=$(call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate pi:openai-codex/gpt-6-astra@pi)
[ "$out" = "reviewer: pi openai-codex/gpt-6-astra" ] \
  || fail "declared primary provider: expected selection, got '$out'"
if call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate pi:anthropic/claude-sonnet-5@Claude >/dev/null 2>&1; then
  fail "malformed provider unexpectedly succeeded"
fi
ok "a declared provider selects the quota row that is probed"

# 7c. Unmeasurable quota is disclosed uncertainty, never an abort: a supported
# harness with no quota-axi mapping stays eligible behind measured candidates.
out=$(call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate codex:gpt-6 --candidate gemini:gemini-3-pro --candidate claude:claude-opus-5)
expected="skipped: codex:gpt-6 quota-ineligible
deferred: gemini:gemini-3-pro quota-unmeasured (harness gemini has no quota-axi provider mapping)
reviewer: claude claude-opus-5"
[ "$out" = "$expected" ] || fail "unmodeled harness: expected '$expected', got '$out'"
UNMEASURED_RECORD="$LAB/unmeasured.log"
: > "$UNMEASURED_RECORD"
out=$(call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate codex:gpt-6 --candidate pi:xai/grok-4-fast@xai --candidate gemini:gemini-3-pro \
  --record "$UNMEASURED_RECORD")
expected="skipped: codex:gpt-6 quota-ineligible
deferred: pi:xai/grok-4-fast@xai quota-unmeasured (provider xai has no quota-axi provider mapping)
deferred: gemini:gemini-3-pro quota-unmeasured (harness gemini has no quota-axi provider mapping)
unmeasured: pi:xai/grok-4-fast@xai provider xai has no quota-axi provider mapping
reviewer: pi xai/grok-4-fast"
[ "$out" = "$expected" ] || fail "unmeasured fallback: expected '$expected', got '$out'"
grep -Eq '^reviewer-choose [0-9]+ selected pi xai/grok-4-fast unmeasured pi:xai/grok-4-fast@xai skipped codex:gpt-6=quota-ineligible$' "$UNMEASURED_RECORD" \
  || fail "unmeasured record: got '$(cat "$UNMEASURED_RECORD")'"
ok "unmeasured quota defers a candidate without aborting selection"

# 8. Snapshots arrive on stdin as well as by file.
out=$(call_choose --author grok:grok-4 --candidate claude:claude-opus-5 < "$FIXTURE")
[ "$out" = "reviewer: claude claude-opus-5" ] \
  || fail "stdin snapshot: expected selection, got '$out'"
ok "stdin snapshot resolves the same reviewer"

# 9. Usage errors exit 2, never a park.
if call_choose --snapshot "$FIXTURE" --candidate claude:claude-opus-5 >/dev/null 2>&1; then
  fail "missing author unexpectedly succeeded"
fi
if call_choose --author grok:grok-4 --snapshot "$FIXTURE" >/dev/null 2>&1; then
  fail "missing candidates unexpectedly succeeded"
fi
if call_choose --author grok:grok-4 --snapshot "$FIXTURE" \
  --candidate frobnicate:model-x >/dev/null 2>&1; then
  fail "unknown harness unexpectedly succeeded"
fi
call_choose --author grok:grok-4 --snapshot "$FIXTURE" claude:claude-opus-5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "positional candidate exited $rc instead of 2"
ok "usage errors fail closed with exit 2"

# 10. A rejected snapshot is an error, never a quiet park.
err=$(call_choose --author grok:grok-4 --snapshot "$BAD_SCHEMA" \
  --candidate claude:claude-opus-5 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "bad schema unexpectedly succeeded with '$err'"
[ "$rc" -eq 2 ] || fail "bad schema exited $rc instead of 2"
case "$err" in
  *"error: quota snapshot rejected"*) ;;
  *) fail "bad schema reported '$err' instead of a snapshot error" ;;
esac
if call_choose --author grok:grok-4 --snapshot "$MALFORMED" \
  --candidate claude:claude-opus-5 >/dev/null 2>&1; then
  fail "malformed snapshot unexpectedly succeeded"
fi
ok "rejected snapshots abort as errors, not parks"
