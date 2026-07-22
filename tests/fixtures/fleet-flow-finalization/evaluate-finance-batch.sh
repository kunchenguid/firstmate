#!/usr/bin/env bash
# Deterministic evaluator for the fleet-flow-finalization unattended LAB batch.
# It accepts only one exact copied artifact as the workload side effect, then
# validates that artifact with the external finance-harness v2 installation.
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: evaluate-finance-batch.sh PROJECT INPUT OUTPUT TRUSTED_SOURCES MARKET_MARK" >&2
  exit 2
fi

PROJECT=$1
INPUT=$2
OUTPUT=$3
TRUSTED_SOURCES=$4
MARKET_MARK=$5
FINANCE_HARNESS_HOME=${FINANCE_HARNESS_HOME:-}

[ -n "$FINANCE_HARNESS_HOME" ] || { echo "error: FINANCE_HARNESS_HOME is required" >&2; exit 2; }
[ -x "$FINANCE_HARNESS_HOME/bin/finance-axi" ] || { echo "error: finance-axi is not executable" >&2; exit 2; }

project_real=$(cd "$PROJECT" && pwd -P)
input_real=$(cd "$(dirname "$INPUT")" && pwd -P)/$(basename "$INPUT")
output_real=$(cd "$(dirname "$OUTPUT")" && pwd -P)/$(basename "$OUTPUT")
trusted_real=$(cd "$(dirname "$TRUSTED_SOURCES")" && pwd -P)/$(basename "$TRUSTED_SOURCES")
market_real=$(cd "$(dirname "$MARKET_MARK")" && pwd -P)/$(basename "$MARKET_MARK")

for path in "$input_real" "$output_real" "$trusted_real" "$market_real"; do
  case "$path" in
    "$project_real"/*) ;;
    *) echo "error: evaluator input escaped the assigned project: $path" >&2; exit 2 ;;
  esac
done

cmp -s "$input_real" "$output_real" || { echo "error: output is not the exact approved artifact" >&2; exit 1; }

status=$(git -C "$project_real" status --porcelain --untracked-files=all)
[ "$status" = "?? out/result.json" ] || {
  echo "error: workload side effects differ from the one allowed output" >&2
  printf '%s\n' "$status" >&2
  exit 1
}

trusted_sha=$(shasum -a 256 "$trusted_real" | awk '{print $1}')
market_sha=$(shasum -a 256 "$market_real" | awk '{print $1}')
validation=$(
  "$FINANCE_HARNESS_HOME/bin/finance-axi" validate \
    --artifact "$output_real" \
    --profile valuation-extract \
    --contract-id example-valuation \
    --trusted-sources "$trusted_real" \
    --trusted-sources-sha256 "$trusted_sha" \
    --market-mark-input "$market_real" \
    --market-mark-input-sha256 "$market_sha" \
    --format json
)

printf '%s\n' "$validation" | jq -e '
  .ok == true
  and .profile == "valuation-extract"
  and .summary.errors == 0
  and .summary.warnings == 0
  and (.diagnostics | length) == 0
' >/dev/null

cat <<'EOF'
EVALUATOR=finance-harness-v2
artifact_cmp=pass
finance_ok=true
errors=0
warnings=0
side_effects=out/result.json
verdict=success
EOF
