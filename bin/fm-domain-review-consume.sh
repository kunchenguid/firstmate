#!/usr/bin/env bash
# Validate one exact-head domain-review handoff through an explicitly selected
# external consumer, then enforce Firstmate's repository and worktree binding.
# Usage: fm-domain-review-consume.sh --consumer <executable> \
#          --handoff <provider-artifact> --repo <exact-clean-product-worktree> \
#          --repository <expected-identity>
#
# The external consumer owns its provider-specific schemas, artifact integrity,
# evidence, findings, and invalidation rules. It is invoked as:
#   <consumer> consume <handoff> --repo <repo> --repository <identity>
# On acceptance it must print one JSON object using the neutral
# firstmate-domain-review-consumption.v1 protocol documented in
# docs/consumed-domain-review.md. Firstmate independently verifies the exact
# clean repository root, expected repository identity, and current HEAD, then
# emits only the protocol's allowlisted delivery fields. Provider-private fields
# are never forwarded.
#
# Nonzero consumer exits and output are preserved. Exit 13 means the selected
# consumer, accepted result, repository binding, or clean exact-head binding was
# incompatible with this extension point.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail_usage() {
  echo "error: $*" >&2
  usage >&2
  exit 64
}

CONSUMER=
HANDOFF=
REPO=
REPOSITORY=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --consumer|--handoff|--repo|--repository)
      [ "$#" -ge 2 ] || fail_usage "$1 requires a value"
      case "$1" in
        --consumer) CONSUMER=$2 ;;
        --handoff) HANDOFF=$2 ;;
        --repo) REPO=$2 ;;
        --repository) REPOSITORY=$2 ;;
      esac
      shift 2
      ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
done

[ -n "$CONSUMER" ] || fail_usage "--consumer is required"
[ -n "$HANDOFF" ] || fail_usage "--handoff is required"
[ -n "$REPO" ] || fail_usage "--repo is required"
[ -n "$REPOSITORY" ] || fail_usage "--repository is required"
[ -f "$CONSUMER" ] && [ ! -L "$CONSUMER" ] && [ -x "$CONSUMER" ] || {
  echo "error: domain-review consumer must be an executable regular non-symlink file: $CONSUMER" >&2
  exit 13
}
[ -f "$HANDOFF" ] && [ ! -L "$HANDOFF" ] || {
  echo "error: domain-review handoff must be a regular non-symlink file: $HANDOFF" >&2
  exit 13
}
case "$REPOSITORY" in
  *$'\n'*|*$'\r'*) echo "error: repository identity must be one line" >&2; exit 13 ;;
esac

CONSUMER_DIR=$(CDPATH='' cd -- "$(dirname -- "$CONSUMER")" 2>/dev/null && pwd -P) || {
  echo "error: domain-review consumer directory cannot be resolved: $CONSUMER" >&2
  exit 13
}
CONSUMER="$CONSUMER_DIR/$(basename -- "$CONSUMER")"
HANDOFF_DIR=$(CDPATH='' cd -- "$(dirname -- "$HANDOFF")" 2>/dev/null && pwd -P) || {
  echo "error: domain-review handoff directory cannot be resolved: $HANDOFF" >&2
  exit 13
}
HANDOFF="$HANDOFF_DIR/$(basename -- "$HANDOFF")"
REPO=$(CDPATH='' cd -- "$REPO" 2>/dev/null && pwd -P) || {
  echo "error: product worktree cannot be resolved: $REPO" >&2
  exit 13
}
REPO_TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: product worktree is not a git repository: $REPO" >&2
  exit 13
}
[ "$REPO_TOP" = "$REPO" ] || {
  echo "error: --repo must name the exact product worktree root: $REPO" >&2
  exit 13
}
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
  echo "error: product worktree must be clean before domain-review consumption" >&2
  exit 13
fi
PRODUCT_HEAD=$(git -C "$REPO" rev-parse HEAD 2>/dev/null) || {
  echo "error: product HEAD cannot be resolved" >&2
  exit 13
}

RESULT=$(mktemp "${TMPDIR:-/tmp}/fm-domain-review-consume.XXXXXX") || exit 13
NORMALIZED=$(mktemp "${TMPDIR:-/tmp}/fm-domain-review-normalized.XXXXXX") || {
  rm -f -- "$RESULT"
  exit 13
}
trap 'rm -f "$RESULT" "$NORMALIZED"' EXIT HUP INT TERM

"$CONSUMER" consume "$HANDOFF" --repo "$REPO" --repository "$REPOSITORY" > "$RESULT"
CONSUMER_STATUS=$?
if [ "$CONSUMER_STATUS" -ne 0 ]; then
  cat "$RESULT"
  exit "$CONSUMER_STATUS"
fi

node - "$RESULT" "$REPOSITORY" "$PRODUCT_HEAD" "$NORMALIZED" <<'NODE'
const fs = require('node:fs')

const [, , resultPath, expectedRepository, productHead, normalizedPath] = process.argv

function fail(message) {
  console.error(`error: accepted domain-review handoff is incompatible: ${message}`)
  process.exit(13)
}

let result
try {
  result = JSON.parse(fs.readFileSync(resultPath, 'utf8'))
} catch (error) {
  fail(`consumer result is not valid JSON: ${error.message}`)
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.length === 0 || /[\r\n]/.test(value)) fail(`${label} is missing or multiline`)
  return value
}

function requireDigest(value, label, lengths) {
  requireString(value, label)
  if (!lengths.includes(value.length) || !/^[0-9a-f]+$/.test(value)) fail(`${label} is not a lowercase hexadecimal digest`)
  return value
}

if (result.schema_version !== 'firstmate-domain-review-consumption.v1') fail('unsupported consumer-result version')
if (result.ok !== true || result.status !== 'accepted') fail('consumer exited successfully without an accepted result')
if (result.review_strategy !== 'consume-existing-exact-head-domain-review') fail('unsupported review strategy')
if (result.independent_review_required !== false) fail('consumer result requests an independent review')
if (requireString(result.repository, 'repository identity') !== expectedRepository) {
  fail(`repository identity ${JSON.stringify(result.repository)} does not match expected ${JSON.stringify(expectedRepository)}`)
}
if (requireDigest(result.product_head_sha, 'product HEAD', [40, 64]) !== productHead) {
  fail('accepted product HEAD does not match the exact product worktree')
}

const normalized = {
  ok: true,
  schema_version: 'firstmate-domain-review-consumption.v1',
  status: 'accepted',
  receipt_sha256: requireDigest(result.receipt_sha256, 'receipt digest', [64]),
  product_head_sha: result.product_head_sha,
  diff_sha256: requireDigest(result.diff_sha256, 'diff digest', [64]),
  review_mode: requireString(result.review_mode, 'review mode'),
  quality_label: requireString(result.quality_label, 'quality label'),
  review_strategy: result.review_strategy,
  independent_review_required: false
}

fs.writeFileSync(normalizedPath, `${JSON.stringify(normalized, null, 2)}\n`)
NODE
NODE_STATUS=$?
[ "$NODE_STATUS" -eq 0 ] || exit "$NODE_STATUS"

cat "$NORMALIZED"
