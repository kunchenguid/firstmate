#!/usr/bin/env bash
# Token-free live guard: exercise Calm against the installed omp tool registry and its
# real renderers, so the harness-dependent verdict (omp draws hidden rows empty while
# Calm is on, and restores stock rendering while off or exporting) is proven end to end.
# Default-on wherever omp is installed; it submits no model prompt and exits from
# session_start before any credentialed call. docs/calm.md owns the behavior contract.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CALM_OMP_LIVE omp
TMP_ROOT=$(fm_test_tmproot fm-calm-omp-extension)
trap fm_test_cleanup EXIT
home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/.omp/extensions/lib" "$home/.pi/extensions/lib"
printf 'on\n' >"$home/config/calm"
cp "$ROOT/.omp/extensions/fm-calm.ts" "$home/.omp/extensions/"
cp "$ROOT/.omp/extensions/lib/"fm-calm-*.ts "$home/.omp/extensions/lib/"
# The Pi tree owns the shared visibility core, the operational-input classifier, and the
# standard-ANSI working-ship painter and sprite; the omp extension imports them directly.
cp "$ROOT/.pi/extensions/lib/"*.ts "$home/.pi/extensions/lib/"
cat >"$home/.omp/extensions/lib/reporter.ts" <<'EOF'
import assert from "node:assert/strict";
import * as omp from "@oh-my-pi/pi-coding-agent";
import { setCalmPresentation, setCalmStockExportRendering } from "./fm-calm-visibility.ts";
import installCalm from "../fm-calm.ts";
export default function (pi) {
  installCalm(pi);
  installCalm(pi); // Reloading must refresh policy without stacking wrappers.
  pi.on("session_start", () => {
    try {
      for (const name of ["read", "bash", "edit", "write", "grep", "glob"]) {
        const tool = pi.getAllTools().find((t) => t.name === name);
        assert.equal(tool.sourceInfo.source, "builtin", `${name} must remain native`);
        setCalmPresentation(false);
        const args = { path: "/tmp/probe.txt", command: "printf hello", pattern: "hello", content: "hello", input: "" };
        const row = new omp.ToolExecutionComponent(name, args, {}, undefined, { requestRender() {}, requestComponentRender() {} });
        row.updateResult({ content: [{ type: "text", text: "hello" }] }, false);
        const normal = row.render(100);
        assert(normal.some((line) => line.trim()), `${name} visible while off`);
        setCalmPresentation(true);
        row.setExpanded(true);
        assert.deepEqual(row.render(100), [], `${name} hidden without blank rows`);
        setCalmStockExportRendering(true);
        row.setExpanded(false);
        assert.deepEqual(row.render(100), normal, `${name} export restores stock rendering`);
        setCalmStockExportRendering(false);
        setCalmPresentation(false);
        row.setExpanded(true);
        row.setExpanded(false);
        assert.deepEqual(row.render(100), normal, `${name} off restores stock rendering`);
        row.dispose();
        console.log(`PASS ${name}: native ownership, hide, export, restore`);
      }
      const group = new omp.ReadToolGroupComponent();
      group.updateArgs({ path: "probe.txt" }, "read-1");
      setCalmPresentation(false);
      const normal = group.render(100);
      assert(normal.some((line) => line.trim()));
      setCalmPresentation(true);
      assert.deepEqual(group.render(100), []);
      setCalmPresentation(false);
      assert.deepEqual(group.render(100), normal);
      console.log("PASS grouped read: hide and restore");
      process.exit(0);
    } catch (e) {
      console.error(e);
      process.exit(1);
    }
  });
}
EOF
printf 'omp runtime: '
omp --version
# Exit from session_start, before any prompt or credentialed model call.
if ! (cd "$home" && FM_HOME="$home" omp --mode rpc --no-session --no-extensions \
    -e "$home/.omp/extensions/lib/reporter.ts" </dev/null) \
    >"$TMP_ROOT/result" 2>&1; then
  cat "$TMP_ROOT/result"
  fail "omp Calm native renderer regression failed"
fi
cat "$TMP_ROOT/result"
grep -q '^PASS grouped read:' "$TMP_ROOT/result" || fail "omp reporter did not finish"
pass "omp Calm hides native tool rows and restores stock rendering on the installed omp"
