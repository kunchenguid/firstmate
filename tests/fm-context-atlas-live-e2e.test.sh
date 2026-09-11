#!/usr/bin/env bash
# Real explicitly loaded Pi CLI with a token-free scripted provider. Measures
# public prompt/schema and navigation cost without credentials or network.
# Refresh: FM_CONTEXT_ATLAS_LIVE=1 bin/fm-test-run.sh tests/fm-context-atlas-live-e2e.test.sh
# Optional ATLAS_EVIDENCE_DIR retains the eight JSON metric records at that path.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CONTEXT_ATLAS_LIVE pi node git
TMP_ROOT=$(fm_test_tmproot fm-context-atlas-live)
trap fm_test_cleanup EXIT
mkdir -p "$TMP_ROOT/repo/src/payments" "$TMP_ROOT/agent"
git -C "$TMP_ROOT/repo" init -q
printf '%s\n' '// Refund policy' 'export const refundLimit = 42;' '// original read policy test' > "$TMP_ROOT/repo/src/payments/refund.ts"
for i in $(seq 1 60); do
  mkdir -p "$TMP_ROOT/repo/src/component-$i/internal"
  printf '%s\n' 'export const unrelated = true;' > "$TMP_ROOT/repo/src/component-$i/internal/implementation.ts"
done
version=$(pi --version)
for mode in baseline-broad baseline-focused baseline-tool atlas-read atlas-tool atlas-preserve baseline-default atlas-default; do
  tools=read,bash,edit,write,grep,find,ls,atlas
  case "$mode" in *-default) tools=read,bash,edit,write,atlas ;; esac
  extensions=()
  flags=()
  case "$mode" in
    atlas*)
      extensions=(-e "$ROOT/bin/context-atlas.ts")
      flags=(--atlas-read)
      [ "$mode" = atlas-preserve ] || flags+=(--atlas-defer)
      ;;
  esac
  (
    cd "$TMP_ROOT/repo"
    PI_CODING_AGENT_DIR="$TMP_ROOT/agent" PI_OFFLINE=1 PI_TELEMETRY=0 \
      ATLAS_CASE="$mode" ATLAS_REPORT="$TMP_ROOT/$mode.json" \
      pi --mode json --no-approve --no-session --no-context-files --no-extensions \
        --no-skills --no-prompt-templates --no-themes \
        "${extensions[@]}" -e "$ROOT/tests/assets/context-atlas-provider.ts" \
        --tools "$tools" \
        --model atlas-test/scripted "${flags[@]}" -- 'Read the refundLimit declaration.'
  ) > "$TMP_ROOT/$mode.log" 2>&1 || { tail -50 "$TMP_ROOT/$mode.log" >&2; fail "Pi $version: $mode failed"; }
  grep -Fq ATLAS_SMOKE_CORRECT "$TMP_ROOT/$mode.log" || { tail -50 "$TMP_ROOT/$mode.log" >&2; fail "Pi $version: $mode did not finish correctly"; }
done
node --input-type=module - "$TMP_ROOT" "$version" <<'JS'
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const [tmp,version]=process.argv.slice(2);
for(const mode of ['baseline-broad','baseline-focused','baseline-tool','atlas-read','atlas-tool','atlas-preserve','baseline-default','atlas-default']) {
  const r=JSON.parse(readFileSync(tmp+'/'+mode+'.json','utf8'));
  assert.equal(r.startup,true);assert.equal(r.correct,true);assert.equal(r.restored,true);
  if(mode==='atlas-tool')assert.equal(r.policyPreserved,true);
  console.log(JSON.stringify({mode,schemaBytes:r.schemaBytes[0],finalSchemaBytes:r.schemaBytes.at(-1),promptBytes:r.promptBytes[0],discoveryCalls:r.discoveryCalls,resultBytes:r.resultBytes,duplicateReads:r.duplicateReads,toolCalls:r.calls.length,latencyMs:r.latencyMs,correct:r.correct}));
}
console.log(`ok - Pi ${version}: exact Atlas candidate loaded, real tool calls correct, original read policy preserved, active tools restored, clean exit (offline scripted provider; no model tokens)`);
JS
if [ -n "${ATLAS_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$ATLAS_EVIDENCE_DIR"
  cp "$TMP_ROOT/"*.json "$ATLAS_EVIDENCE_DIR/"
fi
