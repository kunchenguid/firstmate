#!/usr/bin/env bash
# Live guard for bin/fm-pi-trust.sh: the record it writes is the one the
# INSTALLED Pi resolves its project trust from.
#
# A portable test can only pin the JSON writer; the vendor fact that this file,
# path, and key are what Pi reads comes from the vendor's own code and must be
# proven against the real installation. This guard drives Pi's own trust
# manager - the module its TUI calls before it renders "Trust project folder?" -
# against a disposable agent root, and asserts the decision flips from untrusted
# to trusted exactly because bin/fm-pi-trust.sh wrote the entry.
#
# Token-free and TTY-free: no model prompt is submitted and no dialog is
# answered. Disposable HOME and PI_CODING_AGENT_DIR only; it never reads or
# writes ~/.pi.
#
# Policy: default-on wherever the Pi package is installed (fm_live_gate).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRUST="$ROOT/bin/fm-pi-trust.sh"

fm_live_gate default-on FM_PI_TRUST_LIVE pi node npm

PI_BIN=$(command -v pi)
PI_VERSION=$("$PI_BIN" --version 2>&1) || PI_VERSION=unknown
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] \
  || fail "cannot locate the installed Pi package (looked under '$PI_PACKAGE_DIR'); the live guard needs the real @earendil-works/pi-coding-agent installation, set FM_PI_PACKAGE_DIR to override"
PKG_VERSION=$(node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).version)' "$PI_PACKAGE_DIR/package.json") \
  || fail "cannot read the installed Pi package version"
printf '# live pi version: %s (package %s)\n' "$PI_VERSION" "$PKG_VERSION"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-trust-live.XXXXXX") || fail "could not create a disposable lab"
cleanup() { rm -rf -- "$LAB"; }
trap cleanup EXIT
LAB_REAL=$(cd -P -- "$LAB" && pwd -P) || fail "could not resolve the disposable lab"

# A disposable project with one linked worktree that holds a trust-requiring
# resource, which every real task worktree of this repository does through
# .agents/skills.
PROJ="$LAB/project"
WT="$LAB/slot"
git init -q "$PROJ" || fail "could not initialize the lab project"
mkdir -p "$PROJ/.agents/skills/demo"
printf 'placeholder\n' > "$PROJ/.agents/skills/demo/SKILL.md"
git -C "$PROJ" add -A
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add -q "$WT" || fail "could not add the lab worktree"
WT_REAL=$(cd -P -- "$WT" && pwd -P)
AGENT="$LAB/agent"
mkdir -p "$AGENT" "$LAB/home"

# probe_trust <agent-dir> [seed-json]: ask Pi's own resolver about the lab
# worktree under one disposable agent root. An optional seed object is written
# as that root's trust store first, so each case proves how the INSTALLED
# package resolves the entries the script's own copy of the rule claims. Prints
# one JSON object; exits non-zero if the installed package no longer exposes the
# module this guard reads, so a layout change fails loudly naming the version
# instead of silently proving nothing.
probe_trust() {
  local agent=$1 seed=${2:-}
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$agent" HOME="$LAB/home" \
    PI_TRUST_SEED="$seed" \
    node --input-type=module - "$WT_REAL" "$PI_VERSION" <<'NODE'
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
const [cwd, version] = process.argv.slice(2);
const pkg = process.env.PI_PACKAGE_DIR;
const load = async (rel) => import(pathToFileURL(join(pkg, rel)).href);
let trustManager, projectTrust, config;
try {
  trustManager = await load("dist/core/trust-manager.js");
  projectTrust = await load("dist/core/project-trust.js");
  config = await load("dist/config.js");
} catch (err) {
  console.error(`installed Pi ${version} no longer exposes its trust manager at the expected path: ${err.message}`);
  process.exit(3);
}
const agentDir = config.getAgentDir();
const seed = process.env.PI_TRUST_SEED;
if (seed) {
  mkdirSync(agentDir, { recursive: true });
  writeFileSync(join(agentDir, "trust.json"), `${JSON.stringify(JSON.parse(seed), null, 2)}\n`);
}
const store = new trustManager.ProjectTrustStore(agentDir);
const resolved = await projectTrust.resolveProjectTrusted({
  cwd,
  trustStore: store,
  projectTrustContext: { hasUI: false },
});
process.stdout.write(
  JSON.stringify({
    agentDir,
    trustGating: trustManager.hasTrustRequiringProjectResources(cwd),
    decision: store.get(cwd),
    resolved,
  }),
);
NODE
}

# --- 1. Baseline: an unregistered worktree is untrusted ---------------------
BASE=
if ! BASE=$(probe_trust "$AGENT"); then
  fail "the installed Pi package could not be probed: $BASE"
fi
printf '# baseline: %s\n' "$BASE"
node -e '
  const r = JSON.parse(process.argv[1]);
  if (r.trustGating !== true) { console.error("the lab worktree must hold a trust-requiring resource or this guard proves nothing"); process.exit(1); }
  if (r.decision !== null) { console.error("a fresh agent root must report no trust decision"); process.exit(1); }
  if (r.resolved !== false) { console.error("an unregistered worktree must resolve untrusted"); process.exit(1); }
' "$BASE" || fail "baseline verdict is wrong: $BASE"
pass "pi $PKG_VERSION: an unregistered task worktree resolves untrusted"

# --- 2. The real script registers that worktree -----------------------------
OUT=$(HOME="$LAB/home" "$TRUST" --agent-dir "$AGENT" "$WT" "$PROJ" 2>&1) \
  || fail "fm-pi-trust.sh failed: $OUT"
assert_contains "$OUT" "trusted:" "the registration did not report what it trusted"

# --- 3. Pi's own resolver now reports the same worktree trusted -------------
AFTER=
if ! AFTER=$(probe_trust "$AGENT"); then
  fail "the installed Pi package could not be probed after registration: $AFTER"
fi
printf '# after registration: %s\n' "$AFTER"
# shellcheck disable=SC2016 # the JS template literals are literal here
node -e '
  const [raw, wantStore] = process.argv.slice(1);
  const r = JSON.parse(raw);
  if (r.agentDir !== wantStore) { console.error(`Pi read agent root ${r.agentDir}, not the registered ${wantStore}`); process.exit(1); }
  if (r.decision !== true) { console.error("pi did not read the registered entry as trusted"); process.exit(1); }
  if (r.resolved !== true) { console.error("pi still resolves the worktree untrusted, so the dialog would still render"); process.exit(1); }
' "$AFTER" "$AGENT" || fail "verdict after registration is wrong: $AFTER"

# The entry must be keyed by the canonical path, exactly as Pi keys it.
KEYS=$(node -e 'process.stdout.write(Object.keys(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"))).join("\n"))' "$AGENT/trust.json")
[ "$KEYS" = "$WT_REAL" ] || fail "the store carries '$KEYS', not only the canonical worktree path '$WT_REAL'"
pass "pi $PKG_VERSION: the worktree fm-pi-trust.sh registered resolves trusted with no dialog"

# --- 4. The ancestor rule the script copies is Pi's own ---------------------
# bin/fm-pi-trust.sh skips the write for an inherited true, refuses an inherited
# false, and skips a nearer null entry. Those are only safe because the INSTALLED
# package resolves the same entries the same way, so each shape is driven through
# Pi's resolver on a fresh agent root.
probe_case() {  # <slug> <seed-json> <want-decision> <want-resolved> <description>
  local slug=$1 seed=$2 want_decision=$3 want_resolved=$4 description=$5 agent out
  agent="$LAB/agent-$slug"
  if ! out=$(probe_trust "$agent" "$seed"); then
    fail "the installed Pi package could not be probed for the $slug case: $out"
  fi
  printf '# %s: %s\n' "$slug" "$out"
  # shellcheck disable=SC2016 # the JS template literals are literal here
  node -e '
    const [raw, wantStore, wantDecision, wantResolved] = process.argv.slice(1);
    const r = JSON.parse(raw);
    if (r.agentDir !== wantStore) { console.error(`Pi read agent root ${r.agentDir}, not ${wantStore}`); process.exit(1); }
    if (r.trustGating !== true) { console.error("the probe cwd must hold a trust-requiring resource or this case proves nothing"); process.exit(1); }
    if (String(r.decision) !== wantDecision) { console.error(`pi read decision ${r.decision}, not ${wantDecision}`); process.exit(1); }
    if (String(r.resolved) !== wantResolved) { console.error(`pi resolved ${r.resolved}, not ${wantResolved}`); process.exit(1); }
  ' "$out" "$agent" "$want_decision" "$want_resolved" \
    || fail "the $slug verdict is wrong: $out"
  pass "pi $PKG_VERSION: $description"
}

probe_case ancestor-true "{\"$LAB_REAL\":true}" true true \
  "a trusted ancestor with no exact key resolves the worktree trusted"
probe_case ancestor-false "{\"$LAB_REAL\":false}" false false \
  "an inherited 'Do not trust' resolves untrusted with no dialog"
probe_case null-skips "{\"$WT_REAL\":null,\"$LAB_REAL\":true}" true true \
  "a nearer null entry is skipped and the trusted ancestor resolves"

echo "# all fm-pi-trust-live-e2e checks passed (5)"
