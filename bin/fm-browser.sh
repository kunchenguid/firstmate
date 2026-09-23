#!/usr/bin/env bash
# fm-browser.sh - compact, redacted act-and-verify steps over chrome-devtools-axi.
#
# Usage:
#   fm-browser.sh step --click <target> [--within <target>] [--expect <target>]
#   fm-browser.sh step --fill <target> --value <text> [--expect <target>]
#   fm-browser.sh step --select <target> --option <label> [--expect <target>]
#   fm-browser.sh step --press <key> [--expect <target>]
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
[ "${1:-}" = 'step' ] || fail 'expected step; run --help for usage'
shift

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ENGINE="$ROOT/bin/fm-browser-engine.mjs"
command -v node >/dev/null 2>&1 || fail 'node is required'

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
  FM_BROWSER_ENGINE="$ENGINE" FM_BROWSER_RAW_OUTPUT="$RAW_OUTPUT" \
    node --input-type=module 2>/dev/null <<'NODE'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const raw = readFileSync(process.env.FM_BROWSER_RAW_OUTPUT, "utf8").trim();
if (!raw || raw.length > 65536) process.exit(2);
try {
  const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));
  const result = JSON.parse(raw);
  if (!result || typeof result !== "object" || Array.isArray(result)) process.exit(2);
  process.stdout.write(JSON.stringify(engine.sanitizeResult(result)));
} catch {
  process.exit(2);
}
NODE
) || fail 'chrome-devtools-axi returned no safe step result' 1
printf '%s\n' "$SAFE_OUTPUT"
