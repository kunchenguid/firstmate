#!/usr/bin/env bash
# Deterministic evaluator for the fleet-flow-finalization unattended LAB batch.
# It accepts only one exact copied artifact as the workload side effect, then
# validates that artifact with the external finance-harness v2 installation.
set -euo pipefail

usage() {
  echo "usage: evaluate-finance-batch.sh PROJECT INPUT OUTPUT TRUSTED_SOURCES MARKET_MARK EXPECTED_REVISION" >&2
  exit 2
}

fail_usage() {
  echo "error: $1" >&2
  exit 2
}

canonical_dir() {
  [ -d "$1" ] || fail_usage "directory does not exist: $1"
  (cd "$1" && pwd -P)
}

canonical_file() {
  [ -f "$1" ] || fail_usage "regular file is required: $1"
  local path
  path=$(perl -MCwd=abs_path -e '
    my $path = abs_path($ARGV[0]);
    defined $path or exit 1;
    print "$path\n";
  ' "$1") || fail_usage "could not resolve file: $1"
  [ -f "$path" ] || fail_usage "regular file is required: $path"
  printf '%s\n' "$path"
}

require_fixture_file() {
  local path
  path=$(canonical_file "$1")
  case "$path" in
    "$PROJECT_REAL"/*) printf '%s\n' "$path" ;;
    *) fail_usage "evaluator input escaped the assigned project: $path" ;;
  esac
}

assert_output_and_manifest() {
  local head status
  cmp -s "$INPUT_REAL" "$OUTPUT_REAL" \
    || { echo "error: output is not the exact approved artifact" >&2; exit 1; }
  head=$(git -C "$PROJECT_REAL" rev-parse --verify 'HEAD^{commit}')
  [ "$head" = "$EXPECTED_REVISION_REAL" ] \
    || { echo "error: repository HEAD differs from the expected revision" >&2; exit 1; }
  git -C "$PROJECT_REAL" diff --quiet "$EXPECTED_REVISION_REAL" -- \
    || { echo "error: tracked files differ from the expected revision" >&2; exit 1; }
  # Writes to gitignored paths and metadata-only changes are accepted by this bounded check.
  status=$(git -C "$PROJECT_REAL" status --porcelain --untracked-files=all)
  [ "$status" = "?? out/result.json" ] || {
    echo "error: workload side effects differ from the one allowed output" >&2
    printf '%s\n' "$status" >&2
    exit 1
  }
}

[ "$#" -eq 6 ] || usage
PROJECT_REAL=$(canonical_dir "$1")
INPUT_REAL=$(require_fixture_file "$2")
OUTPUT_REAL=$(require_fixture_file "$3")
TRUSTED_REAL=$(require_fixture_file "$4")
MARKET_REAL=$(require_fixture_file "$5")
EXPECTED_REVISION=$6

GIT_WORKTREE_REAL=$(canonical_dir "$(git -C "$PROJECT_REAL" rev-parse --show-toplevel)")
[ "$PROJECT_REAL" = "$GIT_WORKTREE_REAL" ] \
  || fail_usage "PROJECT must be the Git worktree root"
[ "$OUTPUT_REAL" = "$PROJECT_REAL/out/result.json" ] \
  || fail_usage "output must resolve to PROJECT/out/result.json"
[ ! "$INPUT_REAL" -ef "$OUTPUT_REAL" ] \
  || fail_usage "input and output must not alias the same file"
OBJECT_FORMAT=$(git -C "$PROJECT_REAL" rev-parse --show-object-format) \
  || fail_usage "could not determine repository object format"
case "$OBJECT_FORMAT" in
  sha1) OID_LENGTH=40 ;;
  sha256) OID_LENGTH=64 ;;
  *) fail_usage "unsupported repository object format: $OBJECT_FORMAT" ;;
esac
[[ "$EXPECTED_REVISION" =~ ^[0-9a-fA-F]+$ ]] \
  && [ "${#EXPECTED_REVISION}" -eq "$OID_LENGTH" ] \
  || fail_usage "expected revision must be a full commit OID"
EXPECTED_REVISION=$(printf '%s' "$EXPECTED_REVISION" | tr '[:upper:]' '[:lower:]')
EXPECTED_REVISION_REAL=$(git -C "$PROJECT_REAL" rev-parse --verify "${EXPECTED_REVISION}^{commit}") \
  || fail_usage "expected revision does not resolve to a commit"
[ "$EXPECTED_REVISION" = "$EXPECTED_REVISION_REAL" ] \
  || fail_usage "expected revision must name the resolved commit directly"

FINANCE_HARNESS_HOME=${FINANCE_HARNESS_HOME:-}
[ -n "$FINANCE_HARNESS_HOME" ] || fail_usage "FINANCE_HARNESS_HOME is required"
[ -x "$FINANCE_HARNESS_HOME/bin/finance-axi" ] || fail_usage "finance-axi is not executable"

assert_output_and_manifest

trusted_sha=$(shasum -a 256 "$TRUSTED_REAL" | awk '{print $1}')
market_sha=$(shasum -a 256 "$MARKET_REAL" | awk '{print $1}')
validation=$(
  "$FINANCE_HARNESS_HOME/bin/finance-axi" validate \
    --artifact "$OUTPUT_REAL" \
    --profile valuation-extract \
    --contract-id example-valuation \
    --trusted-sources "$TRUSTED_REAL" \
    --trusted-sources-sha256 "$trusted_sha" \
    --market-mark-input "$MARKET_REAL" \
    --market-mark-input-sha256 "$market_sha" \
    --format json
)

printf '%s\n' "$validation" | jq -e -s '
  length == 1
  and (.[0] | type == "object")
  and (.[0] | has("ok") and (.ok | type == "boolean") and .ok == true)
  and (.[0] | has("profile") and (.profile | type == "string") and .profile == "valuation-extract")
  and (.[0] | has("summary") and (.summary | type == "object"))
  and (.[0].summary | has("errors") and (.errors | type == "number") and .errors == 0)
  and (.[0].summary | has("warnings") and (.warnings | type == "number") and .warnings == 0)
  and (.[0] | has("diagnostics") and (.diagnostics | type == "array") and (.diagnostics | length) == 0)
' >/dev/null

assert_output_and_manifest

cat <<'EOF'
EVALUATOR=finance-harness-v2
artifact_cmp=pass
finance_ok=true
errors=0
warnings=0
side_effects=out/result.json
verdict=success
EOF
