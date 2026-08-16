#!/usr/bin/env bash
# Focused contract and real-Pi startup checks for the single-host Pi activator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP="$ROOT/bin/fm-host-setup.sh"
LAB=$(fm_test_tmproot fm-host-setup)
PI_DIR="$LAB/pi-home"
HOST="$LAB/host"
FM_HOME_DIR="$LAB/firstmate-home"
FAKE_HOME="$LAB/user-home"
OUTSIDE="$LAB/outside"

mkdir -p "$HOST" "$FM_HOME_DIR" "$FAKE_HOME" "$OUTSIDE"
printf '# Host policy\n\nHOST_POLICY_SENTINEL\n' >"$HOST/AGENTS.md"

run_setup() {
	env -u FM_ROOT_OVERRIDE -u FM_HOME -u FM_HOST_ROOT -u FM_BACKEND \
		PI_CODING_AGENT_DIR="$PI_DIR" HOME="$FAKE_HOME" "$SETUP" "$@"
}

assert_present "$SETUP" "bin/fm-host-setup.sh is missing"
[ -x "$SETUP" ] || fail "fm-host-setup.sh must be executable"

before=$(find "$HOST" -mindepth 1 -maxdepth 3 -print | sort)
install_out=$(run_setup install "$HOST" --home "$FM_HOME_DIR" --backend herdr)
after=$(find "$HOST" -mindepth 1 -maxdepth 3 -print | sort)
[ "$before" = "$after" ] || fail "install edited the host repository"
ACTIVATOR="$PI_DIR/extensions/fm-firstmate-host.ts"
assert_present "$ACTIVATOR" "install did not create the Pi activator under PI_CODING_AGENT_DIR"
assert_grep '// firstmate-host-activator managed-v1' "$ACTIVATOR" "activator ownership marker is missing"
assert_contains "$install_out" "worker backend: herdr" "install did not report the configured backend"
cp "$ACTIVATOR" "$LAB/activator.before"
second_out=$(run_setup install "$HOST" --home "$FM_HOME_DIR" --backend herdr)
cmp -s "$LAB/activator.before" "$ACTIVATOR" || fail "idempotent install changed the activator"
assert_contains "$second_out" "unchanged" "idempotent install did not report unchanged"
status_out=$(run_setup status)
assert_contains "$status_out" "host: $(cd "$HOST" && pwd -P)" "status did not report the physical host"
assert_contains "$status_out" "firstmate home: $(cd "$FM_HOME_DIR" && pwd -P)" "status did not report the FirstMate home"
pass "install is host-read-only, PI_CODING_AGENT_DIR-aware, and idempotent"

WORKER_TARGET="$LAB/worker-target"
mkdir -p "$WORKER_TARGET" "$FM_HOME_DIR/state"
node --experimental-strip-types --input-type=module - "$ACTIVATOR" "$HOST" "$WORKER_TARGET" \
	"$(cd "$ROOT" && pwd -P)" "$(cd "$FM_HOME_DIR" && pwd -P)" <<'JS'
import { pathToFileURL } from "node:url";
const [activator, host, target, root, home] = process.argv.slice(2);
process.chdir(host);
Object.assign(process.env, {
  FM_ROOT_OVERRIDE: root,
  FM_HOME: home,
  FM_HOST_ROOT: host,
  FM_BACKEND: "herdr",
  FM_TARGET_WORKTREE: target,
});
const events = [];
const pi = { on: (event) => events.push(event) };
await (await import(pathToFileURL(activator).href)).default(pi);
if (events.length) throw new Error(`host worker registered supervisor events: ${events.join(", ")}`);
JS
assert_absent "$FM_HOME_DIR/state/.pi-turnend-extension-loaded" "host worker loaded the guard extension"
assert_absent "$FM_HOME_DIR/state/.pi-watch-extension-loaded" "host worker loaded the watch extension"
pass "host-root Pi workers do not load FirstMate supervisor policy or extensions"

CONFLICT_PI="$LAB/conflict-pi"
set +e
conflict_out=$(FM_HOME="$LAB/conflict" PI_CODING_AGENT_DIR="$CONFLICT_PI" HOME="$FAKE_HOME" \
	"$SETUP" install "$HOST" --home "$FM_HOME_DIR" --backend herdr 2>&1)
conflict_status=$?
set -e
[ "$conflict_status" -ne 0 ] || fail "install accepted a conflicting ambient FM_HOME"
assert_contains "$conflict_out" "FM_HOME is already set to a conflicting value" "ambient conflict error is unclear"
assert_absent "$CONFLICT_PI/extensions/fm-firstmate-host.ts" "ambient conflict wrote an activator"

UNMANAGED_PI="$LAB/unmanaged-pi"
mkdir -p "$UNMANAGED_PI/extensions"
printf 'export default function () {}\n' >"$UNMANAGED_PI/extensions/fm-firstmate-host.ts"
set +e
unmanaged_out=$(env -u FM_ROOT_OVERRIDE -u FM_HOME -u FM_HOST_ROOT -u FM_BACKEND \
	PI_CODING_AGENT_DIR="$UNMANAGED_PI" HOME="$FAKE_HOME" \
	"$SETUP" install "$HOST" --home "$FM_HOME_DIR" 2>&1)
unmanaged_status=$?
set -e
[ "$unmanaged_status" -ne 0 ] || fail "install overwrote an unmanaged extension"
assert_contains "$unmanaged_out" "refusing to overwrite unmanaged" "unmanaged install refusal is unclear"
assert_grep 'export default function () {}' "$UNMANAGED_PI/extensions/fm-firstmate-host.ts" \
	"unmanaged extension content changed"
pass "install refuses ambient FM conflicts and unmanaged files"

mkdir -p "$HOST/private-home"
for overlap_home in "$HOST/private-home" "$LAB"; do
	OVERLAP_PI="$LAB/overlap-pi-$(basename "$overlap_home")"
	set +e
	overlap_out=$(env -u FM_ROOT_OVERRIDE -u FM_HOME -u FM_HOST_ROOT -u FM_BACKEND \
		PI_CODING_AGENT_DIR="$OVERLAP_PI" HOME="$FAKE_HOME" \
		"$SETUP" install "$HOST" --home "$overlap_home" --backend herdr 2>&1)
	overlap_status=$?
	set -e
	[ "$overlap_status" -ne 0 ] || fail "install accepted host and FirstMate home overlap"
	assert_contains "$overlap_out" "must not overlap FM_HOME" "host/home overlap refusal is unclear"
	assert_absent "$OVERLAP_PI/extensions/fm-firstmate-host.ts" "host/home overlap wrote an activator"
done
pass "install rejects physical ancestor and descendant host/home overlap"

if command -v pi >/dev/null 2>&1; then
	mkdir -p "$HOST/.pi/extensions" "$HOST/.agents/skills/host-skill" "$FM_HOME_DIR/state"
	cat >"$HOST/.agents/skills/host-skill/SKILL.md" <<'SKILL'
---
name: host-skill
description: Host fixture skill.
---

# Host skill
SKILL
	cat >"$HOST/.pi/extensions/host-probe.ts" <<'TS'
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.registerCommand("host-probe", {
    description: "Write the host activation probe",
    handler: async (_args, ctx) => {
      const options = ctx.getSystemPromptOptions();
      writeFileSync(process.env.HOST_PROBE_OUT!, JSON.stringify({
        cwd: ctx.cwd,
        contextFiles: options.contextFiles?.map((file) => file.path) ?? [],
        skills: options.skills?.map((skill) => skill.name) ?? [],
        env: Object.fromEntries(["FM_ROOT_OVERRIDE", "FM_HOME", "FM_HOST_ROOT", "FM_BACKEND"].map((name) => [name, process.env[name]])),
      }));
    },
  });
}
TS
	PROBE="$LAB/host-probe.json"
	RPC_OUT="$LAB/pi-rpc.out"
	RPC_ERR="$LAB/pi-rpc.err"
	(
		cd "$HOST" || exit 1
		printf '%s\n' '{"type":"prompt","message":"/host-probe"}' '{"type":"get_commands"}' |
			env -u FM_ROOT_OVERRIDE -u FM_HOME -u FM_HOST_ROOT -u FM_BACKEND \
				PI_CODING_AGENT_DIR="$PI_DIR" HOME="$FAKE_HOME" PI_OFFLINE=1 HOST_PROBE_OUT="$PROBE" \
				pi --approve --mode rpc --no-session >"$RPC_OUT" 2>"$RPC_ERR"
	) || fail "real Pi RPC host activation failed: $(cat "$RPC_ERR")"
	assert_present "$PROBE" "host lifecycle extension did not run"
	assert_present "$FM_HOME_DIR/state/.pi-turnend-extension-loaded" "FirstMate guard extension did not load"
	assert_present "$FM_HOME_DIR/state/.pi-watch-extension-loaded" "FirstMate watch extension did not load"
	assert_grep 'FirstMate active' "$RPC_OUT" "FirstMate-active status indicator was not emitted"
	assert_grep 'skill:afk' "$RPC_OUT" "FirstMate internal skills were not discovered"
	assert_grep 'skill:host-skill' "$RPC_OUT" "host skill discovery was replaced"
	node -e '
    const fs = require("fs");
    const [probePath, host, root, home] = process.argv.slice(1);
    const p = JSON.parse(fs.readFileSync(probePath, "utf8"));
    if (p.cwd !== host) throw new Error("cwd mismatch: " + p.cwd);
    if (!p.contextFiles.includes(host + "/AGENTS.md")) throw new Error("host AGENTS.md missing");
    if (!p.skills.includes("afk") || !p.skills.includes("host-skill")) throw new Error("skill sets did not compose");
    if (p.env.FM_ROOT_OVERRIDE !== root || p.env.FM_HOME !== home || p.env.FM_HOST_ROOT !== host || p.env.FM_BACKEND !== "herdr") {
      throw new Error("environment mismatch: " + JSON.stringify(p.env));
    }
  ' "$PROBE" "$(cd "$HOST" && pwd -P)" "$(cd "$ROOT" && pwd -P)" "$(cd "$FM_HOME_DIR" && pwd -P)" ||
		fail "real Pi host activation probe failed"

	RUNTIME_OVERLAP_PI="$LAB/runtime-overlap-pi"
	mkdir -p "$RUNTIME_OVERLAP_PI/extensions"
	node -e '
    const fs = require("fs");
    const [source, target, home, host] = process.argv.slice(1);
    fs.writeFileSync(target, fs.readFileSync(source, "utf8").replaceAll(JSON.stringify(home), JSON.stringify(host)));
  ' "$ACTIVATOR" "$RUNTIME_OVERLAP_PI/extensions/fm-firstmate-host.ts" \
		"$(cd "$FM_HOME_DIR" && pwd -P)" "$(cd "$HOST" && pwd -P)"
	RUNTIME_OVERLAP_OUT="$LAB/runtime-overlap.out"
	RUNTIME_OVERLAP_ERR="$LAB/runtime-overlap.err"
	(
		cd "$HOST" || exit 1
		printf '%s\n' '{"type":"get_commands"}' |
			env -u FM_ROOT_OVERRIDE -u FM_HOME -u FM_HOST_ROOT -u FM_BACKEND \
				PI_CODING_AGENT_DIR="$RUNTIME_OVERLAP_PI" HOME="$FAKE_HOME" PI_OFFLINE=1 \
				pi --mode rpc --no-session >"$RUNTIME_OVERLAP_OUT" 2>"$RUNTIME_OVERLAP_ERR"
	) || fail "real Pi runtime-overlap refusal failed: $(cat "$RUNTIME_OVERLAP_ERR")"
	assert_grep 'FirstMate inactive' "$RUNTIME_OVERLAP_OUT" "runtime overlap did not leave FirstMate inactive"
	assert_grep 'must not overlap FM_HOME' "$RUNTIME_OVERLAP_ERR" "runtime overlap refusal was unclear"
	assert_absent "$HOST/state/.pi-turnend-extension-loaded" "runtime overlap loaded the guard into the host"
	assert_absent "$HOST/state/.pi-watch-extension-loaded" "runtime overlap loaded the watcher into the host"

	rm -f "$FM_HOME_DIR/state/.pi-turnend-extension-loaded" "$FM_HOME_DIR/state/.pi-watch-extension-loaded"
	OUTSIDE_OUT="$LAB/pi-outside.out"
	(
		cd "$OUTSIDE" || exit 1
		printf '%s\n' '{"type":"get_commands"}' |
			env -u FM_ROOT_OVERRIDE -u FM_HOME -u FM_HOST_ROOT -u FM_BACKEND \
				PI_CODING_AGENT_DIR="$PI_DIR" HOME="$FAKE_HOME" PI_OFFLINE=1 \
				pi --mode rpc --no-session >"$OUTSIDE_OUT" 2>/dev/null
	) || fail "real Pi outside-host dormancy probe failed"
	assert_no_grep 'FirstMate active' "$OUTSIDE_OUT" "activator was not dormant outside the configured host"
	assert_no_grep 'skill:afk' "$OUTSIDE_OUT" "activator exposed FirstMate skills outside the configured host"
	assert_absent "$FM_HOME_DIR/state/.pi-turnend-extension-loaded" "guard extension loaded outside the configured host"
	assert_absent "$FM_HOME_DIR/state/.pi-watch-extension-loaded" "watch extension loaded outside the configured host"
	pass "real Pi preserves host resources, loads FirstMate resources, and stays dormant elsewhere"
else
	printf 'skip: pi not found for real host activator startup probe\n'
fi

printf 'keep\n' >"$PI_DIR/extensions/unrelated.ts"
uninstall_out=$(run_setup uninstall)
assert_contains "$uninstall_out" "removed" "uninstall did not report removal"
assert_absent "$ACTIVATOR" "uninstall left the owned activator"
assert_present "$PI_DIR/extensions/unrelated.ts" "uninstall removed an unrelated Pi extension"
run_setup uninstall >/dev/null || fail "repeated uninstall was not idempotent"
pass "uninstall removes only its owned file"
