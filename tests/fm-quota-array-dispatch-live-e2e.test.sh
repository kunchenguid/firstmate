#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-array-dispatch skill.
#
# This drives the public Pi skill-loading interface against a fake quota-axi
# executable rather than parsing instruction source bytes or recreating the
# selector in test code.
set -u

if [ "${FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E=1 to run the credentialed Pi dispatch-selection regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
[ -f "$OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/quota.json"
CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != --json ] || [ "$#" -ne 1 ]; then
  printf 'unexpected quota-axi invocation: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

write_fixture() {
  cat > "$FIXTURE"
}

run_case() {
  local label=$1 expected=$2 prompt=$3 out calls required
  shift 3
  : > "$CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "$calls" = "--json" ] || fail "$label: skill did not use one quota-axi --json snapshot: $calls"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || fail "$label: expected accounting line $required, got: $out"
  done
  printf '%s\n' "$out"
  printf 'ok - %s\n' "$label"
}

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 80,
          "pace": { "status": "ahead", "reservePercentPoints": -1, "burnMultiple": 1.1 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 80,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -2 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 14400,
              "projectedExhaustedAt": "2030-01-01T04:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -1, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 20,
          "pace": { "status": "ahead", "reservePercentPoints": -40, "burnMultiple": 2.4 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": 3.5 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 10800,
              "projectedExhaustedAt": "2030-01-01T03:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -40, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "higher spendPriority beats more headroom and a less-negative reserve" \
  "SELECTED=codex" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Both candidates have known runway that supports that horizon. Rank by selection.spendPriority as the primary quota-perspective factor; do not prefer Claude for higher headroom or a less-negative reserve. Return exact lines FACT=claude|headroom=80|spendPriority=-2|runway_seconds=14400|reserve=-1 and FACT=codex|headroom=20|spendPriority=3.5|runway_seconds=10800|reserve=-40 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=80|spendPriority=-2|runway_seconds=14400|reserve=-1" \
  "FACT=codex|headroom=20|spendPriority=3.5|runway_seconds=10800|reserve=-40"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 55,
          "pace": { "status": "unknown", "reason": "missing_cycle" }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 55,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "unknown", "unmeasurableWindowIds": ["weekly"] },
            "runway": { "status": "unknown", "unmeasurableWindowIds": ["weekly"] },
            "pace": { "status": "unknown", "unknownWindowIds": ["weekly"] }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 45,
          "pace": { "status": "behind", "reservePercentPoints": 10, "burnMultiple": 0.8 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 45,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": 1.2 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 14400,
              "projectedExhaustedAt": "2030-01-01T04:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "behind", "worstReservePercentPoints": 10, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "unmeasurable runway stays eligible and is accounted for explicitly" \
  "DECISION=CODEX" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has higher known headroom but explicitly unmeasurable runway and unknown spendPriority, while Codex has lower known headroom, known spendPriority, and established runway that supports completion. Claude remains eligible and its uncertainty must be disclosed. Return exact lines FACT=claude|eligible=yes|headroom=55|runway=unknown|spendPriority=unknown|unmeasurable=weekly and FACT=codex|eligible=yes|headroom=45|spendPriority=1.2|runway_seconds=14400|supports_horizon=yes, then an exact final line DECISION=CODEX. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|eligible=yes|headroom=55|runway=unknown|spendPriority=unknown|unmeasurable=weekly" \
  "FACT=codex|eligible=yes|headroom=45|spendPriority=1.2|runway_seconds=14400|supports_horizon=yes"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 1,
          "pace": { "status": "behind", "reservePercentPoints": 2, "burnMultiple": 0.9 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 1,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -4 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 10800,
              "projectedExhaustedAt": "2030-01-01T03:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "behind", "worstReservePercentPoints": 2, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 80,
          "pace": { "status": "behind", "reservePercentPoints": 20, "burnMultiple": 0.6 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 80,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": 4.5 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 28800,
              "projectedExhaustedAt": "2030-01-01T08:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "behind", "worstReservePercentPoints": 20, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "required strongest reasoning class is not downgraded for quota" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile that meets the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class and cannot meet the requirement. Do not select Codex for higher spendPriority, headroom, or runway. Return exact lines FACT=claude|reasoning=required|headroom=1|spendPriority=-4|runway_seconds=10800 and FACT=codex|reasoning=weaker|headroom=80|spendPriority=4.5|runway_seconds=28800, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|reasoning=required|headroom=1|spendPriority=-4|runway_seconds=10800" \
  "FACT=codex|reasoning=weaker|headroom=80|spendPriority=4.5|runway_seconds=28800"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 90,
          "pace": { "status": "ahead", "reservePercentPoints": -5, "burnMultiple": 1.4 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 90,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": 5 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 600,
              "projectedExhaustedAt": "2030-01-01T00:10:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -5, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 15,
          "pace": { "status": "ahead", "reservePercentPoints": -30, "burnMultiple": 2.1 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 15,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": 0.1 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 14400,
              "projectedExhaustedAt": "2030-01-01T04:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -30, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "runway versus completion horizon remains a hard gate over spendPriority" \
  "SELECTED=codex" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has higher spendPriority but known runway of 600 seconds that does not reach that horizon. Codex has lower spendPriority and known runway that supports completion. The runway-versus-horizon gate is hard and spendPriority cannot override it. Return exact lines FACT=claude|spendPriority=5|runway_seconds=600|supports_horizon=no and FACT=codex|spendPriority=0.1|runway_seconds=14400|supports_horizon=yes to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|spendPriority=5|runway_seconds=600|supports_horizon=no" \
  "FACT=codex|spendPriority=0.1|runway_seconds=14400|supports_horizon=yes"

echo "# all quota-array-dispatch live behavior tests passed"
