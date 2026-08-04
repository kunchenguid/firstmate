#!/usr/bin/env bash
# Render one durable Lavish decision, assert its answering machinery before it
# can be surfaced, open it in a dedicated headed Chrome profile, and arm a
# one-shot watcher check for its durable browser-profile record with optional
# download corroboration.
#
# Usage:
#   fm-lavish-board.sh <decision-id> [--home <path>] [--downloads <path>]
#
# Internal watcher entry point:
#   fm-lavish-board.sh --check <decision-id> --home <path> --session <name>
#     --downloads <path> --state <path> --opened-at <milliseconds>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SUBMIT_MARKER='LAVISH-SUBMIT v2'
LAVISH_BIN=${FM_LAVISH_BIN:-$REPO_ROOT/tools/lavish/src/cli.mjs}

usage() {
  cat <<'USAGE'
Usage: fm-lavish-board.sh <decision-id> [--home <path>] [--downloads <path>]

Render a self-contained Lavish board, open it in a headed dedicated Chrome
profile, and arm a watcher check that captures the verified LAVISH-SUBMIT v2
browser-profile record first and accepts a matching download as corroboration.
The helper refuses before arming pickup or opening Chrome when the rendered
page lacks radio choices, annotation inputs, or its schema-version-2 submit
path.
USAGE
}

fail() {
  printf 'fm-lavish-board: %s\n' "$*" >&2
  exit 2
}

validate_id() {
  local value=$1
  [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] \
    || fail 'decision id must be a lowercase slug of at most 64 characters'
}

resolve_home() {
  local requested=$1
  [ -d "$requested" ] && [ ! -L "$requested" ] \
    || fail "unsafe or missing home: $requested"
  (cd "$requested" && pwd -P)
}

resolve_downloads() {
  local requested=$1
  [ -d "$requested" ] && [ ! -L "$requested" ] \
    || fail "unsafe or missing downloads directory: $requested"
  (cd "$requested" && pwd -P)
}

isolated_chrome() {
  local session=$1
  local profile=$2
  local headed=$3
  shift 3
  (
    unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT
    unset CHROME_DEVTOOLS_AXI_BROWSER_URL
    unset CHROME_DEVTOOLS_AXI_CHROME_ARGS
    unset CHROME_DEVTOOLS_AXI_PORT
    unset CHROME_DEVTOOLS_AXI_WS_HEADERS
    export CHROME_DEVTOOLS_AXI_SESSION="$session"
    export CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile"
    if [ "$headed" = 1 ]; then
      export CHROME_DEVTOOLS_AXI_HEADED=1
    else
      unset CHROME_DEVTOOLS_AXI_HEADED
    fi
    chrome-devtools-axi "$@"
  )
}

assert_answerable_board() {
  local board_path=$1
  node - "$board_path" <<'NODE'
const fs = require('node:fs');

let html;
try {
  html = fs.readFileSync(process.argv[2], 'utf8');
} catch (error) {
  process.stderr.write(`could not read generated HTML: ${error.message}\n`);
  process.exit(1);
}

const tags = (name) => html.match(new RegExp(`<${name}\\b[^>]*>`, 'gis')) ?? [];
const hasAttribute = (tag, name, value = undefined) => {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*(["'])(.*?)\\1`, 'is'));
  if (match === null) return value === undefined && new RegExp(`\\b${name}(?:\\s|>|$)`, 'i').test(tag);
  return value === undefined || match[2].toLowerCase() === value.toLowerCase();
};
const hasClass = (tag, className) => {
  const match = tag.match(/\bclass\s*=\s*(["'])(.*?)\1/is);
  return match !== null && match[2].split(/\s+/).includes(className);
};

const radios = tags('input').filter((tag) => hasAttribute(tag, 'type', 'radio'));
const optionNotes = tags('textarea').filter((tag) => hasAttribute(tag, 'data-option-comment'));
const questionNotes = tags('textarea').filter((tag) => hasAttribute(tag, 'data-question-note'));
const questions = tags('section').filter((tag) => hasClass(tag, 'question'));
const submit = tags('button').some((tag) => hasAttribute(tag, 'id', 'submit-button'));
const missing = [];

if (radios.length === 0) missing.push('radio choices');
if (optionNotes.length === 0) missing.push('per-option annotation inputs');
if (radios.length !== optionNotes.length) {
  missing.push(`one per-option annotation for each radio (${optionNotes.length}/${radios.length})`);
}
if (questionNotes.length === 0) missing.push('per-question annotation inputs');
if (questions.length === 0 || questionNotes.length !== questions.length) {
  missing.push(`one per-question annotation for each question (${questionNotes.length}/${questions.length})`);
}
if (!submit) missing.push('submit button');
if (!/\bschema_version\s*:\s*2\b/.test(html)) missing.push('schema_version 2 payload');
if (!/querySelector\(\s*['"]#submit-button['"]\s*\)\.addEventListener\(\s*['"]click['"]/.test(html)) {
  missing.push('submit click handler');
}
if (!/JSON\.stringify\(\s*payload\b/.test(html)) missing.push('JSON payload serialization');
if (!/new Blob\(\s*\[\s*payloadJson\s*\]/.test(html)) missing.push('JSON download');
if (!/window\.__lavishPayload\s*=\s*payload\b/.test(html)) missing.push('pickup payload publication');

if (missing.length > 0) {
  process.stderr.write(`missing ${missing.join(', ')}\n`);
  process.exit(1);
}
NODE
}

write_evaluation_payload() {  # <evaluation-output> <target> <decision-id> <home-marker>
  local evaluation=$1 target=$2 decision_id=$3 home_marker=$4 result_line
  result_line=$(printf '%s\n' "$evaluation" | sed -n 's/^result: //p' | sed -n '1p')
  [ -n "$result_line" ] || return 1
  printf '%s\n' "$result_line" | node -e '
    const fs = require("node:fs");
    const raw = fs.readFileSync(0, "utf8").trim();
    const target = process.argv[1];
    const marker = process.argv[2];
    const decisionId = process.argv[3];
    const homeMarker = process.argv[4];
    let snapshot = raw;
    try {
      for (let depth = 0; depth < 4 && typeof snapshot === "string"; depth += 1) {
        snapshot = JSON.parse(snapshot);
      }
      let payload = snapshot?.payload ?? null;
      let markerMatches = snapshot?.title === marker;
      if (snapshot?.durable_record != null) {
        let durable = snapshot.durable_record;
        if (typeof durable === "string") durable = JSON.parse(durable);
        if (durable?.marker !== marker || durable?.payload == null) process.exit(3);
        payload = durable.payload;
        markerMatches = true;
      }
      if (
        !markerMatches
        || payload?.decision_id !== decisionId
        || payload?.home_marker !== homeMarker
      ) process.exit(3);
      fs.writeFileSync(target, JSON.stringify(payload) + "\n", { mode: 0o600 });
    } catch {
      process.exit(4);
    }
  ' "$target" "$SUBMIT_MARKER" "$decision_id" "$home_marker"
}

collect_submission() {
  local decision_id=$1
  local home=$2
  local payload_path=$3
  local collected intake_out

  collected=$("$LAVISH_BIN" collect "$decision_id" --home "$home" --payload "$payload_path" 2>&1) || {
    printf 'lavish-submit-error: collect failed for %s from %s: %s\n' \
      "$decision_id" "$payload_path" "$collected"
    return 1
  }
  [ -z "$collected" ] || printf '%s\n' "$collected"

  intake_out=$(LAVISH_SCAN_HOME_DOWNLOADS=0 "$LAVISH_BIN" intake --home "$home" 2>&1) || {
    printf 'lavish-submit-error: intake failed for %s after collect: %s\n' \
      "$decision_id" "$intake_out"
    return 1
  }
  [ -z "$intake_out" ] || printf '%s\n' "$intake_out"
}

check_submission() {
  local decision_id=$1
  local home=$2
  local state_dir=$3
  local session=$4
  local downloads=$5
  local opened_at=$6
  local payload_path="$state_dir/lavish-board-$decision_id.payload.json"
  local check_path="$state_dir/lavish-board-$decision_id.check.sh"
  local profile_path="$state_dir/lavish-board-$decision_id.chrome-profile"
  local html_path="$state_dir/lavish-board-$decision_id.html"
  local downloaded_path evaluation temporary board_url

  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || exit 0
  [ -d "$profile_path" ] && [ ! -L "$profile_path" ] || exit 0
  [ -f "$html_path" ] && [ ! -L "$html_path" ] || exit 0

  if ! downloaded_path=$(node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const directory = process.argv[1];
    const decisionId = process.argv[2];
    const openedAt = Number(process.argv[3]);
    const homeMarker = process.argv[4];
    const pattern = new RegExp(
      "^lavish-answer-" + decisionId + "(?: \\(\\d+\\))?\\.json$",
    );
    const candidates = [];
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (!entry.isFile() || !pattern.test(entry.name)) continue;
      const candidate = path.join(directory, entry.name);
      const info = fs.statSync(candidate);
      if (info.mtimeMs < openedAt) continue;
      try {
        const payload = JSON.parse(fs.readFileSync(candidate, "utf8"));
        if (
          payload?.decision_id !== decisionId
          || payload?.home_marker !== homeMarker
        ) continue;
      } catch {
        continue;
      }
      candidates.push({ candidate, mtimeMs: info.mtimeMs });
    }
    candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
    if (candidates[0]) process.stdout.write(candidates[0].candidate);
  ' "$downloads" "$decision_id" "$opened_at" "$home" 2>/dev/null); then
    printf 'lavish-submit-error: download scan failed for %s in %s\n' \
      "$decision_id" "$downloads"
    return 1
  fi

  temporary=$(mktemp "$state_dir/.lavish-board-$decision_id.payload.XXXXXX")
  evaluation=$(isolated_chrome "$session" "$profile_path" 0 eval \
    'JSON.stringify({title: document.title, payload: window.__lavishPayload ?? null, durable_record: typeof window.__lavishStorageKey === "string" ? localStorage.getItem(window.__lavishStorageKey) : null})' \
    2>/dev/null) || evaluation=
  if [ -n "$evaluation" ]; then
    if write_evaluation_payload "$evaluation" "$temporary" "$decision_id" "$home"; then
      mv "$temporary" "$payload_path"
    else
      rm -f "$temporary"
      exit 0
    fi
  else
    rm -f "$temporary"
    board_url=$(node -e \
      'const { pathToFileURL } = require("node:url"); console.log(pathToFileURL(process.argv[1]).href);' \
      "$html_path")
    isolated_chrome "$session" "$profile_path" 0 open "$board_url" >/dev/null 2>&1 \
      || exit 0
    evaluation=$(isolated_chrome "$session" "$profile_path" 0 eval \
      'JSON.stringify({title: document.title, payload: window.__lavishPayload ?? null, durable_record: typeof window.__lavishStorageKey === "string" ? localStorage.getItem(window.__lavishStorageKey) : null})' \
      2>/dev/null) || {
        isolated_chrome "$session" "$profile_path" 0 stop >/dev/null 2>&1 || true
        exit 0
      }
    temporary=$(mktemp "$state_dir/.lavish-board-$decision_id.payload.XXXXXX")
    if write_evaluation_payload "$evaluation" "$temporary" "$decision_id" "$home"; then
      mv "$temporary" "$payload_path"
    else
      rm -f "$temporary"
      isolated_chrome "$session" "$profile_path" 0 stop >/dev/null 2>&1 || true
      exit 0
    fi
  fi

  if [ -n "$downloaded_path" ]; then
    temporary=$(mktemp "$state_dir/.lavish-board-$decision_id.payload.XXXXXX")
    if cp "$downloaded_path" "$temporary" \
      && chmod 600 "$temporary" \
      && node -e '
        const fs = require("node:fs");
        const { isDeepStrictEqual } = require("node:util");
        const downloaded = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const durable = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
        if (!isDeepStrictEqual(downloaded, durable)) process.exit(3);
      ' "$temporary" "$payload_path"; then
      mv "$temporary" "$payload_path"
    else
      rm -f "$temporary"
    fi
  fi

  collect_submission "$decision_id" "$home" "$payload_path" || return
  rm -f "$check_path"
  isolated_chrome "$session" "$profile_path" 0 stop >/dev/null 2>&1 || true
  printf 'lavish-submit: %s %s\n' "$decision_id" "$payload_path"
}

MODE=board
if [ "${1:-}" = '--check' ]; then
  MODE=check
  shift
fi

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
DECISION_ID=$1
shift
validate_id "$DECISION_ID"

HOME_ARG=${FM_HOME:-$REPO_ROOT}
SESSION=
DOWNLOADS_ARG=${LAVISH_DOWNLOADS_DIR:-${HOME:+$HOME/Downloads}}
STATE_ARG=${FM_STATE_OVERRIDE:-}
OPENED_AT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -gt 1 ] || fail '--home requires a path'
      HOME_ARG=$2
      shift 2
      ;;
    --downloads)
      [ "$#" -gt 1 ] || fail '--downloads requires a path'
      DOWNLOADS_ARG=$2
      shift 2
      ;;
    --session)
      [ "$MODE" = check ] || fail '--session is internal to the watcher check'
      [ "$#" -gt 1 ] || fail '--session requires a name'
      SESSION=$2
      shift 2
      ;;
    --state)
      [ "$MODE" = check ] || fail '--state is internal to the watcher check'
      [ "$#" -gt 1 ] || fail '--state requires a path'
      STATE_ARG=$2
      shift 2
      ;;
    --opened-at)
      [ "$MODE" = check ] || fail '--opened-at is internal to the watcher check'
      [ "$#" -gt 1 ] || fail '--opened-at requires milliseconds since epoch'
      [[ "$2" =~ ^[0-9]+$ ]] || fail '--opened-at must be milliseconds since epoch'
      OPENED_AT=$2
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

HOME_PATH=$(resolve_home "$HOME_ARG")
[ -n "$DOWNLOADS_ARG" ] || fail 'could not resolve a Downloads directory; pass --downloads'
DOWNLOADS_PATH=$(resolve_downloads "$DOWNLOADS_ARG")
STATE_ARG=${STATE_ARG:-$HOME_PATH/state}
mkdir -p "$STATE_ARG"
[ -d "$STATE_ARG" ] && [ ! -L "$STATE_ARG" ] \
  || fail "unsafe state directory: $STATE_ARG"
STATE_DIR=$(cd "$STATE_ARG" && pwd -P)
FM_STATE_OVERRIDE=$STATE_DIR
export FM_STATE_OVERRIDE

if [ "$MODE" = check ]; then
  [ -n "$SESSION" ] || fail '--session is required in check mode'
  [ -n "$OPENED_AT" ] || fail '--opened-at is required in check mode'
  check_submission \
    "$DECISION_ID" "$HOME_PATH" "$STATE_DIR" "$SESSION" "$DOWNLOADS_PATH" "$OPENED_AT"
  exit 0
fi

[ -x "$LAVISH_BIN" ] || fail "Lavish fork CLI is not executable: $LAVISH_BIN"
command -v chrome-devtools-axi >/dev/null 2>&1 \
  || fail 'chrome-devtools-axi is not installed'
command -v node >/dev/null 2>&1 || fail 'node is not installed'

umask 077

HOME_DIGEST=$(printf '%s' "$HOME_PATH" | shasum -a 256 | awk '{print substr($1,1,12)}')
SESSION="lavish-${DECISION_ID:0:36}-$HOME_DIGEST"
HTML_PATH="$STATE_DIR/lavish-board-$DECISION_ID.html"
PAYLOAD_PATH="$STATE_DIR/lavish-board-$DECISION_ID.payload.json"
PROFILE_PATH="$STATE_DIR/lavish-board-$DECISION_ID.chrome-profile"
CHECK_PATH="$STATE_DIR/lavish-board-$DECISION_ID.check.sh"
OPENED_AT=$(node -e 'process.stdout.write(String(Date.now()))')

rm -f "$CHECK_PATH"
"$LAVISH_BIN" board "$DECISION_ID" --home "$HOME_PATH" --out "$HTML_PATH"
ANSWERABILITY_ERROR=
if ! ANSWERABILITY_ERROR=$(assert_answerable_board "$HTML_PATH" 2>&1); then
  rm -f "$HTML_PATH"
  fail "refusing to surface an unanswerable board: $ANSWERABILITY_ERROR"
fi

rm -f "$PAYLOAD_PATH"
mkdir -p "$PROFILE_PATH"
[ -d "$PROFILE_PATH" ] && [ ! -L "$PROFILE_PATH" ] \
  || fail "unsafe Chrome profile directory: $PROFILE_PATH"
CHECK_TMP=$(mktemp "$STATE_DIR/.lavish-board-$DECISION_ID.check.XXXXXX")
{
  printf '#!/usr/bin/env bash\n'
  printf 'exec env FM_STATE_OVERRIDE=%q %q --check %q --home %q --state %q --session %q --downloads %q --opened-at %q\n' \
    "$STATE_DIR" "$SCRIPT_DIR/fm-lavish-board.sh" "$DECISION_ID" "$HOME_PATH" \
    "$STATE_DIR" "$SESSION" "$DOWNLOADS_PATH" "$OPENED_AT"
} > "$CHECK_TMP"
chmod 700 "$CHECK_TMP"
mv "$CHECK_TMP" "$CHECK_PATH"

BOARD_URL=$(node -e \
  'const { pathToFileURL } = require("node:url"); console.log(pathToFileURL(process.argv[1]).href);' \
  "$HTML_PATH")
if ! isolated_chrome "$SESSION" "$PROFILE_PATH" 1 open "$BOARD_URL"; then
  rm -f "$CHECK_PATH"
  fail 'could not open the isolated Chrome session'
fi

printf 'Opened Lavish board %s in isolated Chrome session %s.\n' \
  "$DECISION_ID" "$SESSION"
printf 'Armed submission check: %s\n' "$CHECK_PATH"
