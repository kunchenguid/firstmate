#!/usr/bin/env bash
# fm-browser.sh - compact, redacted act-and-verify steps over chrome-devtools-axi.
#
# Usage:
#   fm-browser.sh route run <host>/<route> [--var <name=value>]... [--from <step-id>] [--session <name>]
#   fm-browser.sh step --click <target> [--within <target>] [--expect <target>] [--record <host>/<route>]
#   fm-browser.sh step --fill <target> --value <text> [--expect <target>] [--record <host>/<route> --record-var <name>]
#   fm-browser.sh step --select <target> --option <label> [--expect <target>] [--record <host>/<route>]
#   fm-browser.sh step --press <key> [--expect <target>] [--record <host>/<route>]
#   fm-browser.sh step --press <key> --expect-gone <target>
#   fm-browser.sh step --press <key> --expect-url-path <path>
#   fm-browser.sh step --press <key> --expect-title <substring>
#
# A target is role=label (exact) or role~label (substring). Labels compare with
# case and whitespace normalized; multiple matches are reported as ambiguous.
# Action roles are button, link, textbox, searchbox, combobox, checkbox, radio,
# menuitem, tab, option, switch, and listbox.
# --within scopes an action target to descendants of one matching accessibility
# container. --expect checks for an appearing target; --expect-gone checks that
# a target disappears; --expect-url-path compares only the current URL path;
# --expect-title checks for a title substring. At most one expectation is allowed.
# --value supplies fill text; --option supplies a combobox option label; --press
# sends a key to the currently focused element. --timeout sets the expectation
# deadline in milliseconds (default 5000, max 120000).
# Use --session or CHROME_DEVTOOLS_AXI_SESSION; the default session is refused,
# and auto-connect, remote browser URLs, custom ports, and custom profiles are cleared.
# Output is one compact JSON object with step, ok, verified, appeared, gone, and ms fields.
# `ok` means the action succeeded and any supplied expectation held afterward;
# `verified` is true only when an explicit expectation held after the action.
# Appeared and gone contain at most 12 redacted role|label pairs total. A failed
# target match returns TARGET_NOT_FOUND; multiple matches return AMBIGUOUS_TARGET.
# Snapshots, page text, titles, field values, browser errors, and URLs never pass
# through to stdout or stderr.
# Routes are private version-1 JSON files under $FM_HOME/data/browser-routes/<host>/<route>.json.
# Route execution validates host and start path, runs all steps in one browser run, and stops at confirmation, handoff, or failure.
# --var supplies route variables; secret-like variable names and values are refused. --from resumes at the named step.
# --record appends a step only after its explicit expectation verifies; recorded fills require --record-var and store a ${var} placeholder.
# Route output is compact JSON with ok and completed, plus error and step on a stop, or handoff.step and handoff.say on handoff.
# `--help` owns the public command and output contract.

set -euo pipefail

usage() {
  awk 'BEGIN { printing = 0 } /^# Usage:/ { printing = 1 } printing && /^#( |$)/ { sub(/^# ?/, ""); print; next } printing { exit }' "$0"
}

fail() {
  printf 'fm-browser: %s\n' "$1" >&2
  exit "${2:-2}"
}

if [ "${1:-}" = '--help' ] || [ "${1:-}" = '-h' ]; then
  usage
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ENGINE="$ROOT/bin/fm-browser-engine.mjs"
command -v node >/dev/null 2>&1 || fail 'node is required'

if [ "${1:-}" = 'route' ]; then
  shift
  [ "${1:-}" = 'run' ] || fail 'expected route run; run --help for usage'
  shift
  ROUTE_ID=${1:-}
  [ -n "$ROUTE_ID" ] || fail 'route run needs <host>/<route>'
  shift
  [[ "$ROUTE_ID" =~ ^([a-z0-9.-]+)/([a-z0-9][a-z0-9_-]*)$ ]] || fail 'invalid route id'
  ROUTE_HOST=${BASH_REMATCH[1]}
  [ "$ROUTE_HOST" != '.' ] && [ "$ROUTE_HOST" != '..' ] || fail 'invalid route host'
  ROUTE_NAME=${BASH_REMATCH[2]}
  ROUTE_ROOT=${FM_HOME:-$ROOT}/data/browser-routes
  ROUTE_FILE="$ROUTE_ROOT/$ROUTE_HOST/$ROUTE_NAME.json"
  [[ ! -L "$ROUTE_ROOT" && ! -L "$ROUTE_ROOT/$ROUTE_HOST" && ! -L "$ROUTE_FILE" ]] || fail 'route path cannot contain symbolic links'
  [ -f "$ROUTE_FILE" ] || fail 'route file not found'
  ROUTE_VARS='{}'
  ROUTE_FROM=''
  SESSION=${CHROME_DEVTOOLS_AXI_SESSION:-}
  SESSION_SET=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --var)
        [ "$#" -ge 2 ] || fail '--var needs name=value'
        [[ "$2" =~ ^([A-Za-z][A-Za-z0-9_-]*)=(.*)$ ]] || fail 'invalid --var; use name=value'
        VAR_NAME=${BASH_REMATCH[1]}
        VAR_VALUE=${BASH_REMATCH[2]}
        ROUTE_VARS=$(FM_BROWSER_VARS="$ROUTE_VARS" FM_BROWSER_VAR_NAME="$VAR_NAME" FM_BROWSER_VAR_VALUE="$VAR_VALUE" node --input-type=module -e 'const v=JSON.parse(process.env.FM_BROWSER_VARS); if (Object.hasOwn(v, process.env.FM_BROWSER_VAR_NAME)) process.exit(2); v[process.env.FM_BROWSER_VAR_NAME]=process.env.FM_BROWSER_VAR_VALUE; process.stdout.write(JSON.stringify(v))') || fail 'duplicate or invalid route variable'
        shift 2
        ;;
      --from)
        [ "$#" -ge 2 ] || fail '--from needs a step id'
        [ -z "$ROUTE_FROM" ] || fail '--from may be used once'
        [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 'invalid --from step id'
        ROUTE_FROM=$2
        shift 2
        ;;
      --session)
        [ "$#" -ge 2 ] || fail '--session needs a name'
        [ "$SESSION_SET" -eq 0 ] || fail 'session may be selected once'
        SESSION=$2
        SESSION_SET=1
        shift 2
        ;;
      *) fail 'unknown route option; run --help for usage' ;;
    esac
  done
  [ -n "$SESSION" ] || fail 'a named isolated session is required with --session or CHROME_DEVTOOLS_AXI_SESSION'
  [[ "$SESSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail 'invalid session name'
  [ "$SESSION" != 'default' ] || fail 'the default browser session is not allowed'
  PARAMS_JSON=$(FM_BROWSER_ENGINE="$ENGINE" FM_BROWSER_ROUTE_FILE="$ROUTE_FILE" FM_BROWSER_ROUTE_VARS="$ROUTE_VARS" FM_BROWSER_ROUTE_FROM="$ROUTE_FROM" FM_BROWSER_ROUTE_HOST="$ROUTE_HOST" FM_BROWSER_ROUTE_NAME="$ROUTE_NAME" node --input-type=module 2>/dev/null <<'NODE'
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));
try {
  const route = engine.validateRoute(JSON.parse(readFileSync(process.env.FM_BROWSER_ROUTE_FILE, 'utf8')));
  if (route.host !== process.env.FM_BROWSER_ROUTE_HOST || route.route !== process.env.FM_BROWSER_ROUTE_NAME) process.exit(2);
  process.stdout.write(JSON.stringify({ mode: 'route', route, vars: JSON.parse(process.env.FM_BROWSER_ROUTE_VARS), from: process.env.FM_BROWSER_ROUTE_FROM || null }));
} catch { process.exit(2); }
NODE
  ) || fail 'route file or variables are invalid'
  command -v chrome-devtools-axi >/dev/null 2>&1 || fail 'chrome-devtools-axi is required'
  umask 077
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-route.XXXXXX") || fail 'cannot create a private temporary directory' 1
  RAW_OUTPUT="$TMP_DIR/output"
  RAW_ERROR="$TMP_DIR/error"
  cleanup() { rm -rf "$TMP_DIR"; }
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL \
    CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
    CHROME_DEVTOOLS_AXI_PORT CHROME_DEVTOOLS_AXI_CHROME_ARGS
  export CHROME_DEVTOOLS_AXI_SESSION="$SESSION"
  if ! { printf 'const PARAMS = %s;\n' "$PARAMS_JSON"; cat "$ENGINE"; } | chrome-devtools-axi run >"$RAW_OUTPUT" 2>"$RAW_ERROR"; then
    fail 'chrome-devtools-axi run failed' 1
  fi
  FM_BROWSER_RAW_OUTPUT="$RAW_OUTPUT" FM_BROWSER_ROUTE_FILE="$ROUTE_FILE" node --input-type=module 2>/dev/null <<'NODE'
import { readFileSync, writeFileSync, renameSync, lstatSync } from 'node:fs';
const raw = readFileSync(process.env.FM_BROWSER_RAW_OUTPUT, 'utf8').trim();
if (!raw || raw.length > 65536) process.exit(1);
try {
  const result = JSON.parse(raw);
  if (result.ok === true && Array.isArray(result.heals) && result.heals.length) {
    const file = process.env.FM_BROWSER_ROUTE_FILE;
    if (lstatSync(file).isSymbolicLink()) process.exit(1);
    const route = JSON.parse(readFileSync(file, 'utf8'));
    for (const heal of result.heals) {
      const step = route.steps.find((entry) => entry.id === heal.step);
      if (!step || step.confirm === true) process.exit(1);
      const from = step.target.label;
      step.target.label = heal.to;
      route.heal_log.push({ step: heal.step, from, to: heal.to, by: 'local', confidence: heal.confidence, date: new Date().toISOString() });
    }
    const temp = `${file}.${process.pid}.tmp`;
    writeFileSync(temp, `${JSON.stringify(route, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    renameSync(temp, file);
  }
  const safe = { ok: result.ok === true, completed: Array.isArray(result.completed) ? result.completed.slice(0, 100) : [] };
  for (const key of ['error', 'step']) if (typeof result[key] === 'string') safe[key] = result[key];
  if (result.handoff && typeof result.handoff === 'object') safe.handoff = { step: result.handoff.step, say: String(result.handoff.say ?? '').slice(0, 500) };
  process.stdout.write(`${JSON.stringify(safe)}\n`);
} catch { process.exit(1); }
NODE
  exit $?
fi

[ "${1:-}" = 'step' ] || fail 'expected step or route; run --help for usage'
shift

ACTION=''
TARGET=''
WITHIN=''
WITHIN_SET=0
VALUE=''
OPTION=''
KEY=''
TIMEOUT=''
SESSION=${CHROME_DEVTOOLS_AXI_SESSION:-}
SESSION_SET=0
EXPECT_KIND=''
EXPECT_VALUE=''
HAS_VALUE=0
HAS_OPTION=0
RECORD_ID=''
RECORD_VAR=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --click | --fill | --select | --press)
      [ -z "$ACTION" ] || fail 'choose exactly one action'
      ACTION=${1#--}
      [ "$#" -ge 2 ] || fail 'action needs a value'
      case "$ACTION" in
        click | fill | select) TARGET=$2 ;;
        press) KEY=$2 ;;
      esac
      shift 2
      ;;
    --within)
      [ "$#" -ge 2 ] || fail '--within needs a target'
      [ "$WITHIN_SET" -eq 0 ] || fail '--within may be used once'
      WITHIN=$2
      WITHIN_SET=1
      [[ "$WITHIN" =~ [^[:space:]] ]] || fail '--within needs a non-empty target'
      shift 2
      ;;
    --value)
      [ "$#" -ge 2 ] || fail '--value needs text'
      [ "$HAS_VALUE" -eq 0 ] || fail '--value may be used once'
      VALUE=$2
      HAS_VALUE=1
      shift 2
      ;;
    --option)
      [ "$#" -ge 2 ] || fail '--option needs a label'
      [ "$HAS_OPTION" -eq 0 ] || fail '--option may be used once'
      OPTION=$2
      HAS_OPTION=1
      shift 2
      ;;
    --expect | --expect-gone | --expect-url-path | --expect-title)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      [ -z "$EXPECT_KIND" ] || fail 'choose at most one expectation'
      case "$1" in
        --expect) EXPECT_KIND=appears ;;
        --expect-gone) EXPECT_KIND=gone ;;
        --expect-url-path) EXPECT_KIND=url-path ;;
        --expect-title) EXPECT_KIND=title ;;
      esac
      EXPECT_VALUE=$2
      shift 2
      ;;
    --record)
      [ "$#" -ge 2 ] || fail '--record needs <host>/<route>'
      [ -z "$RECORD_ID" ] || fail '--record may be used once'
      RECORD_ID=$2
      shift 2
      ;;
    --record-var)
      [ "$#" -ge 2 ] || fail '--record-var needs a variable name'
      [ -z "$RECORD_VAR" ] || fail '--record-var may be used once'
      RECORD_VAR=$2
      [[ "$RECORD_VAR" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || fail 'invalid --record-var name'
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || fail '--timeout needs milliseconds'
      [ -z "$TIMEOUT" ] || fail '--timeout may be used once'
      TIMEOUT=$2
      shift 2
      ;;
    --session)
      [ "$#" -ge 2 ] || fail '--session needs a name'
      [ "$SESSION_SET" -eq 0 ] || fail 'session may be selected once'
      SESSION=$2
      SESSION_SET=1
      shift 2
      ;;
    *) fail 'unknown option; run --help for usage' ;;
  esac
done

[ -n "$ACTION" ] || fail 'an action is required'
if [ -n "$RECORD_ID" ]; then
  [[ "$RECORD_ID" =~ ^([a-z0-9.-]+)/([a-z0-9][a-z0-9_-]*)$ ]] || fail 'invalid --record route id'
  RECORD_HOST=${BASH_REMATCH[1]}
  [ "$RECORD_HOST" != '.' ] && [ "$RECORD_HOST" != '..' ] || fail 'invalid route host'
  RECORD_NAME=${BASH_REMATCH[2]}
  [ "$ACTION" != 'fill' ] || [ -n "$RECORD_VAR" ] || fail 'recording a fill requires --record-var to avoid storing a value'
  [ -n "$EXPECT_KIND" ] || fail '--record requires an explicit expectation so only verified steps are saved'
  [ ! -L "${FM_HOME:-$ROOT}/data/browser-routes" ] || fail 'route storage cannot be a symbolic link'
  [ -z "$RECORD_VAR" ] || [ "$ACTION" = 'fill' ] || fail '--record-var is only valid with --fill'
  [ -z "$RECORD_VAR" ] || [[ "$RECORD_VAR" != *[Ss]ecret* && "$RECORD_VAR" != *[Tt]oken* && "$RECORD_VAR" != *[Pp]ass* && "$RECORD_VAR" != *[Kk]ey* ]] || fail 'secret-like route variable names are not allowed'
else
  [ -z "$RECORD_VAR" ] || fail '--record-var requires --record'
fi
[ -n "$SESSION" ] || fail 'a named isolated session is required with --session or CHROME_DEVTOOLS_AXI_SESSION'
[[ "$SESSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail 'invalid session name'
[ "$SESSION" != 'default' ] || fail 'the default browser session is not allowed'

if [ "$ACTION" = 'fill' ]; then
  [ "$HAS_VALUE" -eq 1 ] || fail '--fill requires --value'
elif [ "$HAS_VALUE" -eq 0 ]; then
  :
else
  fail '--value is only valid with --fill'
fi
if [ "$ACTION" = 'select' ]; then
  [ "$HAS_OPTION" -eq 1 ] || fail '--select requires --option'
elif [ "$HAS_OPTION" -eq 0 ]; then
  :
else
  fail '--option is only valid with --select'
fi
[ "$ACTION" != 'press' ] || [ -z "$WITHIN" ] || fail '--within cannot be used with --press'
[ -z "$TIMEOUT" ] || [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || fail '--timeout must be a positive integer'

PARAMS_JSON=$(
  FM_BROWSER_ENGINE="$ENGINE" \
  FM_BROWSER_ACTION="$ACTION" \
  FM_BROWSER_TARGET="$TARGET" \
  FM_BROWSER_WITHIN="$WITHIN" \
  FM_BROWSER_VALUE="$VALUE" \
  FM_BROWSER_HAS_VALUE="$HAS_VALUE" \
  FM_BROWSER_OPTION="$OPTION" \
  FM_BROWSER_HAS_OPTION="$HAS_OPTION" \
  FM_BROWSER_KEY="$KEY" \
  FM_BROWSER_TIMEOUT="$TIMEOUT" \
  FM_BROWSER_EXPECT_KIND="$EXPECT_KIND" \
  FM_BROWSER_EXPECT_VALUE="$EXPECT_VALUE" \
  FM_BROWSER_RECORD_HOST="${RECORD_HOST:-}" \
  FM_BROWSER_RECORD_NAME="${RECORD_NAME:-}" \
  FM_BROWSER_RECORD_VAR="$RECORD_VAR" \
    node --input-type=module 2>/dev/null <<'NODE'
import { pathToFileURL } from "node:url";
const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));
const params = { action: process.env.FM_BROWSER_ACTION };
for (const [key, envKey] of [["target", "FM_BROWSER_TARGET"], ["within", "FM_BROWSER_WITHIN"], ["key", "FM_BROWSER_KEY"]]) {
  if (process.env[envKey]) params[key] = process.env[envKey];
}
if (process.env.FM_BROWSER_HAS_VALUE === "1") params.value = process.env.FM_BROWSER_VALUE;
if (process.env.FM_BROWSER_HAS_OPTION === "1") params.option = process.env.FM_BROWSER_OPTION;
if (process.env.FM_BROWSER_TIMEOUT) params.timeoutMs = Number(process.env.FM_BROWSER_TIMEOUT);
if (process.env.FM_BROWSER_EXPECT_KIND) {
  const kind = process.env.FM_BROWSER_EXPECT_KIND;
  const value = process.env.FM_BROWSER_EXPECT_VALUE;
  params.expectation = kind === "url-path" ? { kind, path: value } :
    { kind, selector: kind === "title" ? `title~${value}` : value };
}
if (process.env.FM_BROWSER_RECORD_HOST) {
  const selector = (text) => {
    const match = text.match(/^([a-z][a-z0-9-]*)(=|~)(.+)$/i);
    return match ? { role: match[1].toLowerCase(), label: match[3].trim() } : null;
  };
  const expectation = !process.env.FM_BROWSER_EXPECT_KIND ? null :
    process.env.FM_BROWSER_EXPECT_KIND === "url-path" ? { url_path: process.env.FM_BROWSER_EXPECT_VALUE } :
    { [process.env.FM_BROWSER_EXPECT_KIND === "appears" ? "appears" : process.env.FM_BROWSER_EXPECT_KIND === "gone" ? "gone" : "title"]:
      selector(process.env.FM_BROWSER_EXPECT_VALUE.includes("~") ? process.env.FM_BROWSER_EXPECT_VALUE : `${process.env.FM_BROWSER_EXPECT_KIND === "title" ? "title~" : ""}${process.env.FM_BROWSER_EXPECT_VALUE}`) };
  const target = params.target ? selector(params.target) : null;
  if (params.within) target.within = selector(params.within);
  const step = { id: `${params.action}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`, do: params.action };
  if (params.timeoutMs) step.timeoutMs = params.timeoutMs;
  if (target) step.target = target;
  if (params.action === "press") step.key = params.key;
  if (params.action === "fill") { step.value = "${" + process.env.FM_BROWSER_RECORD_VAR + "}"; }
  if (params.action === "select") step.option = params.option;
  if (expectation) step.expect = expectation;
  params.record = { host: process.env.FM_BROWSER_RECORD_HOST, route: process.env.FM_BROWSER_RECORD_NAME,
    variable: process.env.FM_BROWSER_RECORD_VAR || null, step };
}
try {
  engine.validateParams(params);
  process.stdout.write(JSON.stringify(params));
} catch {
  process.exitCode = 2;
}
NODE
) || fail 'invalid step arguments'

command -v chrome-devtools-axi >/dev/null 2>&1 || fail 'chrome-devtools-axi is required'

umask 077
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-step.XXXXXX") || fail 'cannot create a private temporary directory' 1
RAW_OUTPUT="$TMP_DIR/output"
RAW_ERROR="$TMP_DIR/error"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Never inherit a connection to a user's browser, a shared bridge port, or a
# persistent profile. A named session launches its own isolated browser.
unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL \
  CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
  CHROME_DEVTOOLS_AXI_PORT CHROME_DEVTOOLS_AXI_CHROME_ARGS
export CHROME_DEVTOOLS_AXI_SESSION="$SESSION"

if ! {
  printf 'const PARAMS = %s;\n' "$PARAMS_JSON"
  cat "$ENGINE"
} | chrome-devtools-axi run >"$RAW_OUTPUT" 2>"$RAW_ERROR"; then
  fail 'chrome-devtools-axi run failed' 1
fi

SAFE_OUTPUT=$(
  FM_BROWSER_ENGINE="$ENGINE" FM_BROWSER_RAW_OUTPUT="$RAW_OUTPUT" FM_BROWSER_HOME="${FM_HOME:-$ROOT}" \
    node --input-type=module 2>/dev/null <<'NODE'
import { readFileSync, writeFileSync, renameSync, mkdirSync, lstatSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
const raw = readFileSync(process.env.FM_BROWSER_RAW_OUTPUT, "utf8").trim();
if (!raw || raw.length > 65536) process.exit(2);
try {
  const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));
  const envelope = JSON.parse(raw);
  const result = envelope?.result ?? envelope;
  if (!result || typeof result !== "object" || Array.isArray(result)) process.exit(2);
  if (envelope?.record && result.ok && result.verified) {
    const record = envelope.record;
    if (record.currentHost !== record.host) process.exit(2);
    const base = path.join(process.env.FM_BROWSER_HOME, "data", "browser-routes");
    const dir = path.join(base, record.host);
    const file = path.join(dir, `${record.route}.json`);
    for (const target of [base, dir, file]) {
      try { if (lstatSync(target).isSymbolicLink()) process.exit(2); } catch (error) { if (error.code !== "ENOENT") throw error; }
    }
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    let route;
    try { route = JSON.parse(readFileSync(file, "utf8")); }
    catch (error) {
      if (error.code !== "ENOENT") throw error;
      route = { version: 1, host: record.host, route: record.route, start: { url_path: record.path }, vars: {}, steps: [], heal_log: [] };
    }
    if (route.host !== record.host || route.route !== record.route) process.exit(2);
    if (record.variable) route.vars[record.variable] = { required: true };
    const safeRouteText = (value) => {
      const text = String(value);
      const opaque = [...text.matchAll(/[A-Za-z0-9_+/.=-]{24,}/g)].some(([token]) => /[A-Za-z]/.test(token) && /\d/.test(token));
      if (opaque || /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|(?:sk-or-|github_pat_|ghp_|cfut_)|https?:\/\/|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|\d{6,}/i.test(text)) process.exit(2);
      return text.slice(0, 96);
    };
    const cleanTarget = (target) => {
      if (target) target.label = safeRouteText(target.label);
      return target;
    };
    cleanTarget(record.step.target);
    cleanTarget(record.step.target?.within);
    if (record.step.expect) for (const [kind, value] of Object.entries(record.step.expect)) if (kind !== 'url_path') cleanTarget(value);
    if (typeof record.step.option === 'string') record.step.option = safeRouteText(record.step.option);
    route.steps.push(record.step);
    engine.validateRoute(route);
    const temp = `${file}.${process.pid}.tmp`;
    writeFileSync(temp, `${JSON.stringify(route, null, 2)}\n`, { mode: 0o600, flag: "wx" });
    renameSync(temp, file);
  }
  process.stdout.write(JSON.stringify(engine.sanitizeResult(result)));
} catch {
  process.exit(2);
}
NODE
) || fail 'chrome-devtools-axi returned no safe step result or route recording failed' 1
printf '%s\n' "$SAFE_OUTPUT"
