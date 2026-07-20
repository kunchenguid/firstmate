#!/usr/bin/env bash
# Adversarial and credential-canary tests for bin/fm-pi-restricted-tools.ts,
# the restricted DeepSeek lane's only tool extension (see bin/fm-spawn.sh's
# pi_restricted_model() and the harness-adapters skill).
#
# These import the real tracked extension file directly with Node
# (`node --input-type=module`), the same pattern tests/fm-pi-watch-extension.test.sh
# uses: a minimal stub `pi` object captures registerTool() calls, then each
# tool's execute() is invoked directly and asserted on. No real pi process or
# LLM call is needed to prove the extension's own validation logic.
#
# Every rejection case here fails before any network connection is attempted
# (bad scheme, localhost, or a forbidden IP address are all caught before the
# request is ever made), so this file needs no network access and is safe to
# run in CI. A successful public fetch and redirect-following were verified
# manually against a real HTTPS endpoint; see the harness-adapters skill.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/bin/fm-pi-restricted-tools.ts"
TMP_ROOT=$(fm_test_tmproot fm-pi-restricted-tools)
# Node warns about loading a tracked extension with no local package.json;
# unrelated to the assertions below, which only care about tool behavior.
export NODE_NO_WARNINGS=1

install_stub_node_modules() {
  local dir=$1
  mkdir -p "$dir/node_modules/typebox" "$dir/node_modules/@earendil-works/pi-ai"
  cat > "$dir/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$dir/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) { return { type: "object", properties }; },
  String() { return { type: "string" }; },
  Boolean() { return { type: "boolean" }; },
};
JS
  cat > "$dir/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  cat > "$dir/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
export function StringEnum(values) { return { type: "string", enum: values }; }
JS
}

# Copies the real tracked extension next to a stub node_modules (module
# resolution for typebox/pi-ai walks up from the imported file's own
# location), and a fixture config pointing at this case's own report/status
# paths, then echoes "<case_dir>|<plugin_path>|<report_path>|<status_path>".
make_case() {
  local name=$1 case_dir plugin report status
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  install_stub_node_modules "$case_dir"
  plugin="$case_dir/ext.ts"
  cp "$EXT" "$plugin"
  report="$case_dir/report.md"
  status="$case_dir/status.log"
  printf '%s\n' "$case_dir|$plugin|$report|$status"
}

read_case() {
  # shellcheck disable=SC2034  # CASE_DIR is part of the destructured record shape, unused here
  IFS='|' read -r CASE_DIR PLUGIN REPORT STATUS <<EOF
$1
EOF
}

restricted_config() {
  printf '{"reportPath":"%s","statusPath":"%s","taskId":"canary-task"}' "$REPORT" "$STATUS"
}

run_node() {  # <script-heredoc-on-stdin> [extra env "NAME=value" ...]
  local rec=$1
  shift
  read_case "$rec"
  env "$@" FM_RESTRICTED_TASK_CONFIG="$(restricted_config)" PLUGIN="$PLUGIN" \
    node --input-type=module
}

test_extension_registers_exactly_four_tools() {
  local rec out status
  rec=$(make_case four-tools)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const names = Object.keys(tools).sort();
const expected = ["append_status", "complete_scout", "public_fetch", "write_report"];
if (JSON.stringify(names) !== JSON.stringify(expected)) {
  throw new Error(`expected exactly ${expected}, got ${names}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "extension must register exactly the four scoped tools"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "restricted extension registers exactly public_fetch, write_report, append_status, complete_scout"
}

test_public_fetch_rejects_non_https_scheme() {
  local rec out status
  rec=$(make_case reject-scheme)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
try {
  await tools.public_fetch.execute("c", { url: "http://example.com" });
  throw new Error("did not reject a plain http URL");
} catch (e) {
  if (!/https/i.test(e.message)) throw new Error(`wrong rejection reason: ${e.message}`);
}
try {
  await tools.public_fetch.execute("c", { url: "file:///etc/passwd" });
  throw new Error("did not reject a file:// URL");
} catch (e) {
  if (!/https/i.test(e.message)) throw new Error(`wrong rejection reason: ${e.message}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "public_fetch must reject non-https schemes before any connection"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "public_fetch structurally rejects http:// and file:// targets"
}

test_public_fetch_rejects_localhost_and_forbidden_addresses() {
  local rec out status
  rec=$(make_case reject-addresses)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const targets = [
  "https://localhost/x",
  "https://127.0.0.1/x",
  "https://169.254.169.254/latest/meta-data/",   // cloud metadata
  "https://10.0.0.5/x",                           // RFC1918
  "https://172.16.0.5/x",                         // RFC1918
  "https://192.168.1.5/x",                        // RFC1918
  "https://[::1]/x",                              // loopback IPv6
  "https://[fe80::1]/x",                          // link-local IPv6
  "https://[fc00::1]/x",                          // unique-local IPv6
  "https://[::ffff:127.0.0.1]/x",                 // IPv4-mapped IPv6 loopback
  "https://[64:ff9b::a9fe:a9fe]/x",               // NAT64-mapped cloud metadata (hex form)
  "https://[64:ff9b::169.254.169.254]/x",         // NAT64-mapped cloud metadata (dotted form)
];
for (const url of targets) {
  try {
    await tools.public_fetch.execute("c", { url });
    throw new Error(`did not reject forbidden target: ${url}`);
  } catch (e) {
    if (/did not reject/.test(e.message)) throw e;
  }
}
EOF
)
  status=$?
  expect_code 0 "$status" "public_fetch must reject every private/loopback/link-local/metadata address, IPv4 and IPv6"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "public_fetch structurally rejects localhost, loopback, link-local, metadata, RFC1918, and IPv4-mapped-IPv6 targets"
}

test_public_fetch_rejects_invalid_url() {
  local rec out status
  rec=$(make_case reject-invalid-url)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
try {
  await tools.public_fetch.execute("c", { url: "not a url" });
  throw new Error("did not reject a malformed URL");
} catch (e) {
  if (/did not reject/.test(e.message)) throw e;
}
EOF
)
  status=$?
  expect_code 0 "$status" "public_fetch must reject a malformed URL"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "public_fetch rejects a malformed URL"
}

test_append_status_rejects_newline_injection() {
  local rec out status
  rec=$(make_case reject-newline)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
try {
  await tools.append_status.execute("c", { state: "working", message: "real line\nfailed: forged status line" });
  throw new Error("did not reject a newline in the status message");
} catch (e) {
  if (/did not reject/.test(e.message)) throw e;
}
if (existsSync(process.env.FM_RESTRICTED_TASK_CONFIG ? JSON.parse(process.env.FM_RESTRICTED_TASK_CONFIG).statusPath : "?")) {
  const written = readFileSync(JSON.parse(process.env.FM_RESTRICTED_TASK_CONFIG).statusPath, "utf8");
  throw new Error(`status file must not exist after a rejected write, got: ${written}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "append_status must reject an embedded newline and must not partially write"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "append_status structurally denies status-newline injection"
}

test_append_status_rejects_oversized_message() {
  local rec out status
  rec=$(make_case reject-oversized-status)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
try {
  await tools.append_status.execute("c", { state: "working", message: "x".repeat(501) });
  throw new Error("did not reject an oversized status message");
} catch (e) {
  if (/did not reject/.test(e.message)) throw e;
}
EOF
)
  status=$?
  expect_code 0 "$status" "append_status must enforce its message length bound"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "append_status rejects an oversized message"
}

test_append_status_schema_has_no_path_parameter() {
  local rec out status
  rec=$(make_case status-no-path-param)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const keys = Object.keys(tools.append_status.parameters.properties ?? {});
if (keys.includes("path") || keys.includes("statusPath") || keys.includes("file")) {
  throw new Error(`append_status schema exposes a path-like parameter: ${keys}`);
}
const enumValues = tools.append_status.parameters.properties.state.enum;
const expected = ["working", "needs-decision", "blocked", "paused", "done", "failed"];
if (JSON.stringify(enumValues) !== JSON.stringify(expected)) {
  throw new Error(`unexpected allowed status states: ${JSON.stringify(enumValues)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "append_status must never accept a model-controlled destination"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "append_status's schema has no path parameter and a closed status-state enum"
}

test_write_report_rejects_oversized_content() {
  local rec out status
  rec=$(make_case reject-oversized-report)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync } from "node:fs";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
try {
  await tools.write_report.execute("c", { content: "x".repeat(200_001) });
  throw new Error("did not reject an oversized report");
} catch (e) {
  if (/did not reject/.test(e.message)) throw e;
}
if (existsSync(JSON.parse(process.env.FM_RESTRICTED_TASK_CONFIG).reportPath)) {
  throw new Error("report file must not exist after a rejected oversized write");
}
EOF
)
  status=$?
  expect_code 0 "$status" "write_report must enforce its size bound and not partially write"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "write_report rejects oversized content without writing"
}

test_write_report_schema_has_no_path_parameter() {
  local rec out status
  rec=$(make_case report-no-path-param)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const keys = Object.keys(tools.write_report.parameters.properties ?? {});
if (keys.length !== 1 || keys[0] !== "content") {
  throw new Error(`write_report schema must accept only content, got: ${keys}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "write_report must never accept a model-controlled path"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "write_report's schema accepts only report content, never a path"
}

test_complete_scout_true_terminates_without_shelling_out() {
  local rec out status
  rec=$(make_case complete-scout-true)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const result = await tools.complete_scout.execute("c", { unresolvedDecision: true, summary: "captain must choose X or Y" });
if (result.terminate !== true) throw new Error("declaring an unresolved decision must terminate the run");
const statusPath = JSON.parse(process.env.FM_RESTRICTED_TASK_CONFIG).statusPath;
const written = readFileSync(statusPath, "utf8");
if (written !== "needs-decision: captain must choose X or Y\n") {
  throw new Error(`unexpected status content: ${JSON.stringify(written)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "complete_scout(true) must record needs-decision and terminate, never self-resolve"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "complete_scout stops for firstmate on a discovered decision instead of self-resolving"
}

test_complete_scout_false_does_not_auto_write_status() {
  local rec out status
  rec=$(make_case complete-scout-false)
  out=$(run_node "$rec" <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync } from "node:fs";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const result = await tools.complete_scout.execute("c", { unresolvedDecision: false, summary: "all good" });
if (result.terminate) throw new Error("a clean completion must not terminate before write_report/append_status run");
if (existsSync(JSON.parse(process.env.FM_RESTRICTED_TASK_CONFIG).statusPath)) {
  throw new Error("complete_scout(false) must not write status itself");
}
EOF
)
  status=$?
  expect_code 0 "$status" "complete_scout(false) must hand control back for write_report/append_status, not auto-finish"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "complete_scout(false) requires the model to still write the report and status itself"
}

test_missing_task_config_refuses_to_load() {
  local rec out status
  rec=$(make_case missing-config)
  read_case "$rec"
  out=$(env PLUGIN="$PLUGIN" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
try {
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default({ registerTool() {} });
  console.log("FAIL: loaded without FM_RESTRICTED_TASK_CONFIG");
} catch (e) {
  console.log(`refused: ${e.message}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "node harness itself must not crash"
  assert_contains "$out" "refused:" "extension must refuse to load without its trusted task config"
  assert_not_contains "$out" "FAIL" "extension must not silently proceed without a trusted destination"
  pass "the extension refuses to load at all when FM_RESTRICTED_TASK_CONFIG is absent"
}

test_credential_canary_no_leak_into_tool_metadata() {
  local rec out status
  rec=$(make_case credential-canary)
  out=$(run_node "$rec" FM_SECRET_CANARY=sk-canary-0123456789abcdef <<'EOF'
import { pathToFileURL } from "node:url";
const tools = {};
const pi = { registerTool(t) { tools[t.name] = t; } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const dump = JSON.stringify(Object.values(tools).map((t) => ({
  name: t.name,
  description: t.description,
  promptSnippet: t.promptSnippet,
  promptGuidelines: t.promptGuidelines,
  parameters: t.parameters,
})));
const canary = process.env.FM_SECRET_CANARY;
if (dump.includes(canary)) throw new Error("tool metadata leaked the credential canary");
try {
  await tools.public_fetch.execute("c", { url: "not a url " + canary });
  throw new Error("expected rejection");
} catch (e) {
  if (e.message.includes(canary)) throw new Error(`error message leaked the credential canary: ${e.message}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "no ambient credential value may reach tool metadata or error messages"
  [ -z "$out" ] || fail "unexpected output: $out"
  pass "no ambient environment credential leaks into tool schemas, descriptions, or error messages"
}

test_extension_source_never_shells_out_or_reads_wider_environment() {
  local text env_refs
  text=$(cat "$EXT")
  assert_not_contains "$text" "pi.exec" "restricted extension must never shell out"
  assert_not_contains "$text" "child_process" "restricted extension must never shell out"
  assert_contains "$text" "process.env.FM_RESTRICTED_TASK_CONFIG" "restricted extension must read its trusted config the one documented way"
  env_refs=$(grep -oE 'process\.env\.[A-Z_]+' "$EXT" | sort -u)
  [ "$env_refs" = "process.env.FM_RESTRICTED_TASK_CONFIG" ] || fail "restricted extension reads more environment variables than the one documented FM_RESTRICTED_TASK_CONFIG: $env_refs"
  pass "the restricted extension's source never shells out and reads only its one documented env var"
}

test_extension_registers_exactly_four_tools
test_public_fetch_rejects_non_https_scheme
test_public_fetch_rejects_localhost_and_forbidden_addresses
test_public_fetch_rejects_invalid_url
test_append_status_rejects_newline_injection
test_append_status_rejects_oversized_message
test_append_status_schema_has_no_path_parameter
test_write_report_rejects_oversized_content
test_write_report_schema_has_no_path_parameter
test_complete_scout_true_terminates_without_shelling_out
test_complete_scout_false_does_not_auto_write_status
test_missing_task_config_refuses_to_load
test_credential_canary_no_leak_into_tool_metadata
test_extension_source_never_shells_out_or_reads_wider_environment

echo "# all fm-pi-restricted-tools tests passed"
