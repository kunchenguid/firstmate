#!/usr/bin/env bash
# Unit tests for bin/fm-quota-choose.sh.
# Drives the public argv interface with a mocked quota-axi JSON source.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-choose.XXXXXX")
FIXTURE="$LAB/quota.json"
MALFORMED="$LAB/malformed.json"
MULTI_JSON="$LAB/multi-json.json"
DUPLICATE="$LAB/duplicate.json"
OUT_OF_RANGE="$LAB/out-of-range.json"
INVALID_RUNWAY="$LAB/invalid-runway.json"
INVALID_AVAILABILITY="$LAB/invalid-availability.json"
EMPTY_SCOPE="$LAB/empty-scope.json"
WHITESPACE_PROVIDER="$LAB/whitespace-provider.json"
WHITESPACE_SCOPE="$LAB/whitespace-scope.json"
UNKNOWN_EXHAUSTED="$LAB/unknown-exhausted.json"
KNOWN_UNKNOWN="$LAB/known-unknown.json"
KNOWN_EMPTY="$LAB/known-empty.json"
SEMANTICS_MISMATCH="$LAB/semantics-mismatch.json"
PARTIAL="$LAB/partial.json"
NO_APPLICABLE="$LAB/no-applicable.json"
APPLICABLE_VETO="$LAB/applicable-veto.json"
MUSE_EXHAUSTED="$LAB/muse-exhausted.json"
MUSE_POSITIVE="$LAB/muse-positive.json"
AGY_EXHAUSTED="$LAB/agy-exhausted.json"
AGY_POSITIVE="$LAB/agy-positive.json"
TOON="$LAB/quota.toon"
RENDERER_TOON="$LAB/renderer-quota.toon"
EMPTY_TOON="$LAB/empty-quota.toon"
EMPTY_ARRAY_TOON="$LAB/empty-array-quota.toon"
INLINE_ATTENTION_TOON="$LAB/inline-attention-quota.toon"
WHITESPACE_ATTENTION_TOON="$LAB/whitespace-attention-quota.toon"
TRUNCATED_ZERO_TOON="$LAB/truncated-zero-quota.toon"
MALFORMED_ZERO_TOON="$LAB/malformed-zero-quota.toon"
LEADING_GARBAGE_TOON="$LAB/leading-garbage-quota.toon"
LEADING_GARBAGE_NONZERO_TOON="$LAB/leading-garbage-nonzero-quota.toon"
TRAILING_GARBAGE_NONZERO_TOON="$LAB/trailing-garbage-nonzero-quota.toon"
TRUNCATED_NONZERO_TOON="$LAB/truncated-nonzero-quota.toon"
MALFORMED_COUNTED_TOON="$LAB/malformed-counted-quota.toon"
UNKNOWN_EXHAUSTED_TOON="$LAB/unknown-exhausted-quota.toon"
TRAILING_EMPTY_TOON="$LAB/trailing-empty-quota.toon"
QUOTED_TOON="$LAB/quoted-quota.toon"
FAKEBIN="$LAB/fakebin"
CALLS="$LAB/calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN"

cat > "$FIXTURE" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "kimi",
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
      "provider": "codex",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "runway": { "status": "projected_exhaustion" }
          },
          {
            "scope": "model:codex_bengalfox",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
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
            "effectivePercentRemaining": 50,
            "runway": { "status": "through_reset" }
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
            "effectivePercentRemaining": 0.5,
            "runway": { "status": "through_reset" }
          },
          {
            "scope": "model:fable",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "cursor",
      "windows": [],
      "quotaSemantics": {
        "status": "unknown",
        "effectiveAvailability": []
      }
    }
  ]
}
JSON

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "${QUOTA_AXI_CALLS:?}"
if [ "${1:-}" = "--version" ]; then
  echo "quota-axi 0.1.29"
  exit 0
fi
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" "$FAKEBIN/quota-axi" --json > "$LAB/captured.json"

call_choose() {
  local output rc call_count
  output=$(QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
    PATH="$FAKEBIN:$PATH" "$BIN/fm-quota-choose.sh" "$@")
  rc=$?
  call_count=$(wc -l < "$CALLS" | tr -d '[:space:]')
  [ "$call_count" = 1 ] || fail "helper took an additional quota snapshot"
  printf '%s\n' "$output"
  return "$rc"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$1"
}

if help=$("$BIN/fm-quota-choose.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq \
  "candidate order and every candidate's provider is the harness's primary family." \
  || fail "help omitted the multi-provider usage restriction"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders the complete header only"

# 1. First candidate with positive effective quota.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default --candidate codex:model:codex_bengalfox --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "first positive: expected 'claude claude-3-5-sonnet', got '$out'"
ok "first positive candidate wins"

# 2. Exhausted provider is skipped.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "exhausted skip: expected 'claude claude-3-5-sonnet', got '$out'"
ok "exhausted provider is skipped"

# 3. No candidates have positive quota.
if out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default 2>/dev/null); then
  fail "no positive: expected exit 1, got exit 0 with '$out'"
fi
[ "$out" = "none" ] || fail "no positive: expected 'none', got '$out'"
ok "no positive candidate returns none and exit 1"

# 4. Positional arguments work.
out=$(call_choose --snapshot "$LAB/captured.json" claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "positional: expected 'claude claude-3-5-sonnet', got '$out'"
ok "positional candidates work"

# 5. A model-specific exhausted scope bounds a healthy all-models scope.
if out=$(call_choose --snapshot "$LAB/captured.json" --candidate codex:model:codex_bengalfox 2>/dev/null); then
  fail "specific scope: expected exit 1, got exit 0 with '$out'"
fi
[ "$out" = "none" ] || fail "specific scope: expected 'none', got '$out'"
ok "specific model scope bounds generic quota"

out=$(call_choose --snapshot "$LAB/captured.json" --candidate codex:default)
[ "$out" = "codex default" ] || fail "default scope: expected provider-wide quota, got '$out'"
ok "default model uses provider-wide quota"

out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "fractional quota: expected positive candidate, got '$out'"
ok "fractional positive quota is eligible"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate bogus:model --candidate claude:claude-3-5-sonnet 2>&1); then
  fail "unknown harness unexpectedly selected a later candidate"
fi
[ "$err" = "error: unknown harness: bogus" ] || fail "unknown harness returned: $err"
ok "unknown harness fails closed"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate copilot:default 2>&1); then
  fail "trailing unsupported harness was hidden by an earlier selection"
fi
[ "$err" = "error: unknown harness: copilot" ] || fail "trailing unsupported harness returned: $err"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate 'claude:' 2>&1); then
  fail "trailing empty model was hidden by an earlier selection"
fi
[ "$err" = "error: invalid candidate: claude:" ] || fail "trailing empty model returned: $err"
ok "all candidates are validated before selection"

printf '{"schemaVersion":5,"providers":{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}}\n' > "$MALFORMED"
if err=$(call_choose --snapshot "$MALFORMED" --candidate claude:default 2>&1); then
  fail "malformed provider collection unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "malformed provider data returned: $err"
ok "malformed provider data fails closed"

printf '{"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n' > "$MULTI_JSON"
cat "$LAB/captured.json" >> "$MULTI_JSON"
if err=$(call_choose --snapshot "$MULTI_JSON" --candidate claude:default 2>&1); then
  fail "multiple JSON values unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "multiple JSON values returned: $err"
ok "multiple JSON values fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = []' \
  "$LAB/captured.json" > "$KNOWN_EMPTY"
if err=$(call_choose --snapshot "$KNOWN_EMPTY" --candidate claude:default 2>&1); then
  fail "known-empty quota unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "known-empty quota returned: $err"
ok "known-empty quota fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.status) = "unknown"' \
  "$LAB/captured.json" > "$SEMANTICS_MISMATCH"
if err=$(call_choose --snapshot "$SEMANTICS_MISMATCH" --candidate claude:default 2>&1); then
  fail "unknown semantics with known entries unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "semantics mismatch returned: $err"
ok "semantics and availability statuses must agree"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]' \
  "$LAB/captured.json" > "$UNKNOWN_EXHAUSTED"
if out=$(call_choose --snapshot "$UNKNOWN_EXHAUSTED" --candidate claude:default 2>/dev/null); then
  fail "unknown headroom with exhausted runway unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "unknown exhausted quota returned: $out"
ok "exhausted runway vetoes unknown headroom"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"all_models","status":"unknown","runway":{"status":"unknown"}}]' \
  "$LAB/captured.json" > "$KNOWN_UNKNOWN"
if out=$(call_choose --snapshot "$KNOWN_UNKNOWN" --candidate claude:default 2>/dev/null); then
  fail "unknown headroom unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "unknown headroom returned: $out"
ok "unknown headroom is not positive quota"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.status) = "partial" |
    (.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) += [{"scope":"model:unmeasured","status":"unknown","runway":{"status":"unknown"}}]' \
  "$LAB/captured.json" > "$PARTIAL"
out=$(call_choose --snapshot "$PARTIAL" --candidate claude:default)
[ "$out" = "claude default" ] || fail "valid partial semantics were rejected: $out"
ok "partial semantics accept mixed availability"

out=$(call_choose --candidate claude:default < "$LAB/captured.json")
[ "$out" = "claude default" ] || fail "stdin snapshot returned '$out'"
ok "stdin snapshot is accepted"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate 'claude:' 2>&1); then
  fail "empty model candidate unexpectedly dispatched"
fi
[ "$err" = "error: invalid candidate: claude:" ] || fail "empty model candidate returned: $err"
ok "empty model candidate fails closed"

# A bare harness with no colon means the default model.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude)
[ "$out" = "claude default" ] || fail "bare harness: expected 'claude default', got '$out'"
ok "bare harness maps to default model"

cat > "$TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,all_models,20,-1,through_reset,high,weekly,2030-01-02T00:00:00Z
  claude,all_models,0.5,-1,through_reset,high,weekly,2030-01-02T00:00:00Z
exhaustion[0]:
attention[0]:
TOON
out=$(call_choose --snapshot "$TOON" --candidate claude:default)
[ "$out" = "claude default" ] || fail "default TOON snapshot returned '$out'"
ok "default TOON snapshot is accepted"

cat > "$RENDERER_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
exhaustion: []
attention: []
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
out=$(call_choose --snapshot "$RENDERER_TOON" --candidate claude:default)
[ "$out" = "claude default" ] || fail "renderer-shaped TOON snapshot returned: $out"
ok "renderer-shaped TOON snapshot is accepted"

printf 'garbage\n' > "$LEADING_GARBAGE_NONZERO_TOON"
cat "$TOON" >> "$LEADING_GARBAGE_NONZERO_TOON"
cat "$TOON" > "$TRAILING_GARBAGE_NONZERO_TOON"
printf 'garbage\n' >> "$TRAILING_GARBAGE_NONZERO_TOON"
sed '$d' "$TOON" > "$TRUNCATED_NONZERO_TOON"
for malformed_toon in \
  "$LEADING_GARBAGE_NONZERO_TOON" \
  "$TRAILING_GARBAGE_NONZERO_TOON" \
  "$TRUNCATED_NONZERO_TOON"; do
  if err=$(call_choose --snapshot "$malformed_toon" --candidate claude:default 2>&1); then
    fail "malformed nonzero TOON unexpectedly dispatched: $malformed_toon"
  fi
  [ "$err" = "error: invalid quota-axi snapshot" ] \
    || fail "malformed nonzero TOON returned: $err"
done
ok "malformed nonzero TOON envelopes fail closed"

cat > "$EMPTY_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
exhaustion[0]:
attention[0]:
TOON
if out=$(call_choose --snapshot "$EMPTY_TOON" --candidate claude:default 2>/dev/null); then
  fail "zero-row TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "zero-row TOON returned: $out"
ok "zero-row TOON has no positive quota"

cat > "$EMPTY_ARRAY_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models,error,"request failed, retry later",none
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$EMPTY_ARRAY_TOON" --candidate claude:default 2>/dev/null); then
  fail "empty-array TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "empty-array TOON returned: $out"
ok "empty-array TOON has no positive quota"

cat > "$INLINE_ATTENTION_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention: [{"provider":"claude","scope":"all_models","kind":"unmeasurable","detail":"unknown quota","remedy":"none"}]
TOON
if out=$(call_choose --snapshot "$INLINE_ATTENTION_TOON" --candidate claude:default 2>/dev/null); then
  fail "inline attention TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "inline attention TOON returned: $out"
ok "inline attention TOON has no positive quota"

cat > "$WHITESPACE_ATTENTION_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models ,unmeasurable,unknown quota,none
TOON
if err=$(call_choose --snapshot "$WHITESPACE_ATTENTION_TOON" --candidate claude:default 2>&1); then
  fail "whitespace attention scope unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "whitespace attention scope returned: $err"
ok "TOON attention identities fail closed"

cat > "$TRUNCATED_ZERO_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
TOON
if err=$(call_choose --snapshot "$TRUNCATED_ZERO_TOON" --candidate claude:default 2>&1); then
  fail "truncated zero-row TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "truncated zero-row TOON returned: $err"
ok "truncated zero-row TOON fails closed"

cat > "$MALFORMED_ZERO_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
garbage
TOON
if err=$(call_choose --snapshot "$MALFORMED_ZERO_TOON" --candidate claude:default 2>&1); then
  fail "malformed zero-row TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "malformed zero-row TOON returned: $err"
ok "malformed zero-row TOON fails closed"

cat > "$LEADING_GARBAGE_TOON" <<'TOON'
garbage
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
exhaustion[0]:
attention[0]:
TOON
if err=$(call_choose --snapshot "$LEADING_GARBAGE_TOON" --candidate claude:default 2>&1); then
  fail "zero-row TOON with leading garbage unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "leading garbage TOON returned: $err"
ok "zero-row TOON rejects leading garbage"

cat > "$MALFORMED_COUNTED_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
exhaustion[1]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  garbage
attention[0]:
TOON
if err=$(call_choose --snapshot "$MALFORMED_COUNTED_TOON" --candidate claude:default 2>&1); then
  fail "malformed counted TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "malformed counted TOON returned: $err"
ok "counted TOON rows require every declared field"

cat > "$UNKNOWN_EXHAUSTED_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models,headroom_unknown,"weekly · exhausted_now limited by weekly",none
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$UNKNOWN_EXHAUSTED_TOON" --candidate claude:default 2>/dev/null); then
  fail "TOON unknown headroom exhaustion unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "TOON unknown headroom exhaustion returned: $out"
ok "TOON conversion preserves unknown-headroom exhaustion"

cat > "$TRAILING_EMPTY_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z",
exhaustion[0]:
attention[0]:
TOON
if err=$(call_choose --snapshot "$TRAILING_EMPTY_TOON" --candidate claude:default 2>&1); then
  fail "TOON row with trailing empty field unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "trailing empty TOON field returned: $err"
ok "trailing empty TOON fields fail closed"

cat > "$QUOTED_TOON" <<'TOON'
bin: quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
  claude,"model:fable",0,-1,exhausted_now,high,weekly,"2030-01-02T00:00:00Z"
exhaustion[0]:
attention[0]:
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$QUOTED_TOON" --candidate claude:fable 2>/dev/null); then
  fail "quoted exhausted model scope unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "quoted exhausted model scope returned: $out"
ok "quoted TOON scope vetoes dispatch"

if out=$(call_choose --snapshot "$LAB/captured.json" --candidate cursor:default 2>/dev/null); then
  fail "provider-level unknown quota unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "provider-level unknown quota returned: $out"
ok "provider-level unknown quota is not positive"

jq '.providers += [{"provider":"meta","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":25,"runway":{"status":"through_reset"}}]}}]' \
  "$LAB/captured.json" > "$MUSE_POSITIVE"
out=$(call_choose --snapshot "$MUSE_POSITIVE" --candidate muse:default)
[ "$out" = "muse default" ] || fail "supported Muse candidate returned: $out"
ok "Muse candidate is accepted"

jq '.providers += [{"provider":"meta","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]' \
  "$LAB/captured.json" > "$MUSE_EXHAUSTED"
if out=$(call_choose --snapshot "$MUSE_EXHAUSTED" --candidate muse:default 2>/dev/null); then
  fail "Muse candidate dispatched with exhausted Meta quota"
fi
[ "$out" = "none" ] || fail "exhausted Meta quota returned: $out"
ok "Muse uses Meta quota"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate copilot:default 2>&1); then
  fail "unsupported harness unexpectedly dispatched"
fi
[ "$err" = "error: unknown harness: copilot" ] || fail "unsupported harness returned: $err"
ok "unsupported harness is rejected"

# agy is a verified crewmate adapter and quota-axi reports it as its own
# provider family, so a candidate on it must route on that family's quota
# rather than abort the whole ordered list.
jq '.providers += [{"provider":"agy","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":25,"runway":{"status":"through_reset"}}]}}]' \
  "$LAB/captured.json" > "$AGY_POSITIVE"
out=$(call_choose --snapshot "$AGY_POSITIVE" --candidate agy:default)
[ "$out" = "agy default" ] || fail "supported agy candidate returned: $out"
ok "agy candidate is accepted"

jq '.providers += [{"provider":"agy","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]' \
  "$LAB/captured.json" > "$AGY_EXHAUSTED"
if out=$(call_choose --snapshot "$AGY_EXHAUSTED" --candidate agy:default 2>/dev/null); then
  fail "agy candidate dispatched with exhausted agy quota"
fi
[ "$out" = "none" ] || fail "exhausted agy quota returned: $out"
ok "agy uses its own provider quota"

jq '.providers += [.providers[] | select(.provider == "claude")]' "$LAB/captured.json" > "$DUPLICATE"
if err=$(call_choose --snapshot "$DUPLICATE" --candidate claude:default 2>&1); then
  fail "duplicate provider snapshot unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "duplicate provider returned: $err"
ok "duplicate providers fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].scope) = ""' \
  "$LAB/captured.json" > "$EMPTY_SCOPE"
if err=$(call_choose --snapshot "$EMPTY_SCOPE" --candidate claude:default 2>&1); then
  fail "empty quota scope unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "empty quota scope returned: $err"
ok "empty quota scopes fail closed"

jq '(.providers[] | select(.provider == "claude").provider) = " claude" |
    (.providers[] | select(.provider == " claude").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 0 |
    (.providers[] | select(.provider == " claude").quotaSemantics.effectiveAvailability[0].runway.status) = "exhausted_now"' \
  "$LAB/captured.json" > "$WHITESPACE_PROVIDER"
if err=$(call_choose --snapshot "$WHITESPACE_PROVIDER" --candidate claude:default 2>&1); then
  fail "whitespace provider identity unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "whitespace provider returned: $err"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].scope) = "all_models "' \
  "$LAB/captured.json" > "$WHITESPACE_SCOPE"
if err=$(call_choose --snapshot "$WHITESPACE_SCOPE" --candidate claude:default 2>&1); then
  fail "whitespace scope identity unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "whitespace scope returned: $err"
ok "whitespace quota identities fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 150' "$LAB/captured.json" > "$OUT_OF_RANGE"
if err=$(call_choose --snapshot "$OUT_OF_RANGE" --candidate claude:default 2>&1); then
  fail "out-of-range quota unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "out-of-range quota returned: $err"
ok "out-of-range quota fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].runway.status) = "invalid"' "$LAB/captured.json" > "$INVALID_RUNWAY"
if err=$(call_choose --snapshot "$INVALID_RUNWAY" --candidate claude:default 2>&1); then
  fail "invalid runway status unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "invalid runway status returned: $err"
ok "invalid runway status fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"model:other","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]' \
  "$LAB/captured.json" > "$NO_APPLICABLE"
if out=$(call_choose --snapshot "$NO_APPLICABLE" --candidate claude:fable 2>/dev/null); then
  fail "candidate without applicable quota unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "missing applicable quota returned: $out"
ok "missing applicable quota is not positive"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [
      {"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"exhausted_now"}},
      {"scope":"model:foo","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}
    ]' "$LAB/captured.json" > "$APPLICABLE_VETO"
if out=$(call_choose --snapshot "$APPLICABLE_VETO" --candidate claude:foo 2>/dev/null); then
  fail "provider-wide exhausted scope did not veto the candidate"
fi
[ "$out" = "none" ] || fail "applicable exhausted scope returned: $out"
ok "any exhausted applicable scope vetoes dispatch"

if out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:fable 2>/dev/null); then
  fail "exact named model exhaustion unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "exact named model returned '$out'"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:fable-2)
[ "$out" = "claude fable-2" ] || fail "named model scope overmatched fable-2: $out"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
[ "$out" = "claude default" ] || fail "named model scope overmatched default: $out"
ok "named model quota matches exact identity only"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[1].status) = "typo"' "$LAB/captured.json" > "$INVALID_AVAILABILITY"
if err=$(call_choose --snapshot "$INVALID_AVAILABILITY" --candidate claude:default 2>&1); then
  fail "invalid availability status unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "invalid availability status returned: $err"
ok "invalid availability status fails closed"

[ "$(wc -l < "$CALLS" | tr -d '[:space:]')" = 1 ] || fail "helper took an additional quota snapshot"
ok "helper reuses the captured quota snapshot"

printf '# all fm-quota-choose tests passed\n'
