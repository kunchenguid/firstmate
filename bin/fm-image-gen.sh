#!/usr/bin/env bash
# fm-image-gen.sh - one hard-bounded image generation call to the Gemini API
# (Nano Banana family), for fleet creatives and illustration work.
#
# Why it exists rather than an agent calling curl itself: every call SPENDS THE
# CAPTAIN'S MONEY, and the four models differ in price by roughly 4x. A tool
# whose model is pinned, whose spend is logged, and whose credential can never
# reach a process list is the only shape that is safe to hand to an unattended
# worker. The safety envelope is enforced here deterministically:
#   - the API key is passed through a curl config on STDIN, never in argv and
#     never in the URL, so it cannot appear in `ps`, a shell history, or a log;
#   - the prompt is read from a file or stdin and reaches the request body only
#     through `jq --rawfile`, so quotes, `$`, backticks, and newlines in creative
#     text are data and can never become shell or JSON syntax;
#   - a hard positive timeout bounds the call, so a hung API cannot wedge a task;
#   - the model is verified against the API's own live catalogue before spending
#     anything, and an unavailable model FAILS LOUDLY rather than falling back.
#
# That last rule is paid for. `agy` silently downgraded any unrecognized model
# slug to its cheapest tier and warned only in the TUI, never headless, so a
# whole day of design work ran on the wrong model without a single visible sign.
# A generation tool that quietly substitutes a model is the same defect wearing
# a different name: here, a model this API does not list is an error.
#
# Output: the absolute path of each written image on stdout, one per line, plus
# one `cost=` line on stderr. The API key is never printed on either stream.
#
# Exit status: 0 on a written image, 2 on a usage error, 3 when the credential
# is missing or rejected, 4 when the model is unavailable, 5 on a timeout, 6
# when the API returned no image, 7 when the daily spend cap would be crossed,
# 8 when the API refused for quota or balance reasons (a fine key, an empty
# prepayment balance - the two are not the same failure and must not share a code).
#
# Usage:
#   fm-image-gen.sh --prompt-file <path> [--out <dir>] [--model <id>]
#   fm-image-gen.sh --prompt - [--out <dir>]        # prompt on stdin
#   fm-image-gen.sh --check-models                  # live catalogue, spends nothing
#
# Environment:
#   GEMINI_IMAGE_API_KEY   the credential. Read from the environment first, then
#                          from $FM_HOME/.env, which is captain-private and
#                          gitignored (AGENTS.md section "This repo is a shared
#                          template"). Never committed, never echoed.
#   FM_IMAGE_GEN_TIMEOUT   hard bound in seconds; positive integer, default 120.
#                          Image generation is slow; this is not the 20s a CLI
#                          probe uses.
#
# Daily cap: Google Cloud has no hard spending stop - a billing budget only
# SENDS AN ALERT and the spend continues past it. The only real brake on a
# runaway agent loop is local and before the call, so this tool keeps its own
# per-day ledger in state/image-gen-spend.tsv and refuses past
# config/image-daily-usd-cap (default $5/day) with exit 7.
#
# The cap is in DOLLARS rather than images because an image count silently
# changes meaning when the model changes: 200 images is ~$13 on flash and ~$48
# on pro at 4K. Prices used for the cap are deliberately conservative - the top
# of a model's range, and the dearest known rate for a model not in the table -
# so the cap errs toward underspending. Only images actually written are
# charged, so a refused or failed call never consumes budget.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Reused rather than reimplemented: fmx_env_get already handles `export` prefixes,
# surrounding quotes, and trailing CR. The library is pure functions with nothing
# outside them, so sourcing it has no side effects.
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

# Vertex AI in EXPRESS mode: authenticated by an API key, billed through the
# captain's subscription rather than AI Studio prepayment credits (which are
# empty and refuse even free-tier text). Verified working 2026-08-06.
#
# Do not "fix" the 401 you get from a metadata GET on this host by switching
# back to generativelanguage: express keys genuinely do not support metadata
# reads while they DO perform generation. That asymmetry cost an hour - a probe
# on the neighbouring endpoint said "keys not supported" and the real endpoint
# then worked. Probe the call you actually need, never its neighbour.
API_BASE="https://aiplatform.googleapis.com/v1/publishers/google/models"
CATALOGUE_BASE="https://generativelanguage.googleapis.com/v1beta/models"
DEFAULT_MODEL=gemini-3.1-flash-image

usage() {
  cat <<'EOF'
fm-image-gen.sh - one hard-bounded image generation call to the Gemini API
(Nano Banana family). Every call spends money; there is no free tier for any
image model.

Usage:
  fm-image-gen.sh --prompt-file <path> [--out <dir>] [--model <id>]
  fm-image-gen.sh --prompt - [--out <dir>] [--model <id>]
  fm-image-gen.sh --check-models

Options:
  --prompt-file <path>  read the prompt from a file
  --prompt -            read the prompt from stdin
  --out <dir>           where to write the image (default: the current directory)
  --model <id>          override config/image-model for this call only
  --check-models        print the API's live image-model catalogue and exit;
                        spends nothing

The model comes from config/image-model, defaulting to gemini-3.1-flash-image
(Nano Banana 2). A model this API does not list is an ERROR, never a silent
downgrade to a cheaper one.

Exit status: 0 wrote an image, 2 usage, 3 credential, 4 model unavailable,
5 timeout, 6 no image in the response, 7 daily spend cap reached, 8 API quota
or prepayment balance exhausted (the key is fine - do not regenerate it).

The daily cap (config/image-daily-usd-cap, default $5/day) is counted in DOLLARS
and checked BEFORE the billable call. Google Cloud budgets only alert and never
stop spend, so this local brake is the one that actually holds.
EOF
}

die_usage() {
  printf 'fm-image-gen: %s\n' "$1" >&2
  printf 'usage: fm-image-gen.sh --prompt-file <path> [--out <dir>] [--model <id>]\n' >&2
  exit 2
}

die() {  # <exit-code> <message>
  printf 'fm-image-gen: %s\n' "$2" >&2
  exit "$1"
}

PROMPT_FILE=
OUT_DIR=.
MODEL_ARG=
CHECK_MODELS=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check-models) CHECK_MODELS=1; shift ;;
    --prompt-file)
      [ $# -ge 2 ] || die_usage "--prompt-file requires a path"
      PROMPT_FILE=$2; shift 2 ;;
    --prompt)
      [ $# -ge 2 ] || die_usage "--prompt requires a value"
      [ "$2" = "-" ] || die_usage "--prompt accepts only '-' (stdin); use --prompt-file for a file, so prompt text never enters argv"
      PROMPT_FILE=-; shift 2 ;;
    --out)
      [ $# -ge 2 ] || die_usage "--out requires a directory"
      OUT_DIR=$2; shift 2 ;;
    --model)
      [ $# -ge 2 ] || die_usage "--model requires an id"
      MODEL_ARG=$2; shift 2 ;;
    -*) die_usage "unknown option: $1" ;;
    *) die_usage "unexpected argument: $1 (the prompt is never passed in argv)" ;;
  esac
done

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die 2 "$tool is required but not on PATH"
done

# --- credential -------------------------------------------------------------
# Environment first so a caller can scope a different key to one call without
# writing it to disk; .env second as the durable home-local store.
API_KEY=${GEMINI_IMAGE_API_KEY:-}
if [ -z "$API_KEY" ]; then
  API_KEY=$(fmx_env_get GEMINI_IMAGE_API_KEY "$FM_HOME/.env")
fi
[ -n "$API_KEY" ] || die 3 "no GEMINI_IMAGE_API_KEY in the environment or $FM_HOME/.env"

# --- bounded execution ------------------------------------------------------
# Mirrors bin/fm-vendor-auth-probe.sh's run_timed so a macOS host without
# coreutils still gets a hard bound. Exit 124 means the bound was hit.
TIMEOUT=${FM_IMAGE_GEN_TIMEOUT:-120}
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=120 ;;
esac

run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}

# The key travels in a curl config read from STDIN. It never appears in argv, so
# it cannot be recovered from `ps` by any other process on this machine, and it
# never enters the URL, so it cannot land in an access log or a redirect.
curl_keyed() {  # <curl-args...>
  printf 'header = "x-goog-api-key: %s"\n' "$API_KEY" \
    | run_timed "$TIMEOUT" curl --silent --show-error --config - "$@"
}

# --- live model catalogue ---------------------------------------------------
# The API's own answer, not a remembered list. Verified 2026-08-06 that the four
# Nano Banana models exist on VERTEX; this surface is generativelanguage, whose
# ids are confirmed here at runtime rather than assumed.
list_image_models() {
  curl_keyed "$CATALOGUE_BASE" 2>/dev/null \
    | jq -r '.models[]? | select((.supportedGenerationMethods // []) | index("generateContent"))
             | select(.name | test("image"))
             | .name | sub("^models/"; "")' 2>/dev/null
}

if [ "$CHECK_MODELS" -eq 1 ]; then
  models=$(list_image_models)
  if [ -z "$models" ]; then
    die 3 "the API returned no image models - the key may be invalid, or generativelanguage.googleapis.com may not be enabled on the project"
  fi
  printf '%s\n' "$models"
  exit 0
fi

# --- prompt -----------------------------------------------------------------
[ -n "$PROMPT_FILE" ] || die_usage "a prompt is required (--prompt-file <path> or --prompt -)"

PROMPT_TMP=
cleanup() { [ -z "$PROMPT_TMP" ] || rm -f "$PROMPT_TMP"; }
trap cleanup EXIT

if [ "$PROMPT_FILE" = "-" ]; then
  PROMPT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-image-gen.prompt.XXXXXX") || die 2 "could not create a temporary file"
  cat > "$PROMPT_TMP"
  PROMPT_FILE=$PROMPT_TMP
fi
[ -f "$PROMPT_FILE" ] || die 2 "no prompt file at $PROMPT_FILE"
[ -s "$PROMPT_FILE" ] || die 2 "the prompt file is empty: $PROMPT_FILE"

# --- model ------------------------------------------------------------------
MODEL=$MODEL_ARG
if [ -z "$MODEL" ] && [ -f "$CONFIG/image-model" ]; then
  MODEL=$(tr -d '[:space:]' < "$CONFIG/image-model")
fi
[ -n "$MODEL" ] || MODEL=$DEFAULT_MODEL

# Image models recorded from a live catalogue read on 2026-08-06. This list is
# the FALLBACK, used only when the catalogue cannot be read - an express-mode key
# is refused by the metadata endpoint even though it generates fine, so on that
# key there is no catalogue to consult.
RECORDED_MODELS='gemini-2.5-flash-image
gemini-3-pro-image
gemini-3-pro-image-preview
gemini-3.1-flash-image
gemini-3.1-flash-image-preview
gemini-3.1-flash-lite-image'

AVAILABLE=$(list_image_models)
CATALOGUE_SOURCE=live
if [ -z "$AVAILABLE" ]; then
  # Not fatal, and deliberately not silent: an unreadable catalogue is a weaker
  # check, and the caller is told so rather than being left to assume the model
  # was verified against the API.
  AVAILABLE=$RECORDED_MODELS
  CATALOGUE_SOURCE=recorded
  printf 'fm-image-gen: NOTE - the live model catalogue is unreadable with this key (normal for an express-mode key); checking against the list recorded 2026-08-06 instead\n' >&2
fi

if ! printf '%s\n' "$AVAILABLE" | grep -Fxq "$MODEL"; then
  printf 'fm-image-gen: model %s is not in the %s model list\n' "$MODEL" "$CATALOGUE_SOURCE" >&2
  printf 'fm-image-gen: known image models:\n' >&2
  printf '%s\n' "$AVAILABLE" | sed 's/^/  /' >&2
  printf 'fm-image-gen: refusing to substitute a different model - a silent downgrade is what made agy unusable\n' >&2
  exit 4
fi

# --- daily cap --------------------------------------------------------------
# Checked BEFORE the billable call. Google Cloud budgets only alert; they never
# stop spend. This is the only brake that actually stops a runaway loop, so it
# lives here, in front of the request, rather than in a dashboard.
LEDGER="$STATE/image-gen-spend.tsv"

# The cap is in DOLLARS, not images, because an image-count cap silently changes
# meaning when the model changes: 200 images is $13 on flash and $48 on pro 4K.
# Money is what the captain actually cares about, so money is what is counted.
DAILY_USD_CAP=5
if [ -f "$CONFIG/image-daily-usd-cap" ]; then
  cap_raw=$(tr -d '[:space:]' < "$CONFIG/image-daily-usd-cap")
  case "$cap_raw" in
    ''|*[!0-9.]*|*.*.*) : ;;   # a non-numeric cap is not a cap; keep the safe default
    *) DAILY_USD_CAP=$cap_raw ;;
  esac
fi

# Deliberately CONSERVATIVE: where a model has a price range, the highest is
# used, so the cap can never be overshot by picking the expensive resolution.
# An unknown model is charged at the dearest known rate rather than free.
price_per_image() {  # <model>
  case "$1" in
    gemini-3-pro-image*)           printf '0.240' ;;   # 4K rate; 1K-2K is 0.134
    gemini-3.1-flash-lite-image*)  printf '0.034' ;;
    gemini-3.1-flash-image*)       printf '0.067' ;;
    gemini-2.5-flash-image*)       printf '0.039' ;;
    *)                             printf '0.240' ;;
  esac
}

TODAY=$(date -u +%Y-%m-%d)
SPENT_TODAY=0
if [ -f "$LEDGER" ]; then
  SPENT_TODAY=$(awk -F'\t' -v d="$TODAY" '$1 == d { s += $4 } END { printf "%.4f", s + 0 }' "$LEDGER" 2>/dev/null)
  case "$SPENT_TODAY" in ''|*[!0-9.]*) SPENT_TODAY=0 ;; esac
fi

UNIT_PRICE=$(price_per_image "$MODEL")
if awk -v s="$SPENT_TODAY" -v u="$UNIT_PRICE" -v c="$DAILY_USD_CAP" 'BEGIN { exit !(c > 0 && s + u > c) }'; then
  printf 'fm-image-gen: daily spend cap would be exceeded - $%s already spent today (UTC), this call adds ~$%s, cap is $%s\n' \
    "$SPENT_TODAY" "$UNIT_PRICE" "$DAILY_USD_CAP" >&2
  printf 'fm-image-gen: refusing to spend more. Raise config/image-daily-usd-cap deliberately, or wait for the day to roll over.\n' >&2
  printf 'fm-image-gen: ledger: %s\n' "$LEDGER" >&2
  exit 7
fi

# --- request ----------------------------------------------------------------
# --rawfile makes the prompt a JSON string value, whatever it contains. Creative
# briefs carry quotes, apostrophes, `$`, and newlines routinely; none of it can
# become syntax here.
#
# responseModalities MUST list both TEXT and IMAGE. Google's own quickstart is
# explicit that "image-only output is not supported with these models", and an
# ["IMAGE"] request is rejected - so asking only for what we want would fail
# every call while looking like the tighter, more correct request. The reader
# below already selects the inlineData part, so the accompanying text costs
# nothing.
BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-image-gen.body.XXXXXX") || die 2 "could not create a temporary file"
RESP_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-image-gen.resp.XXXXXX") || die 2 "could not create a temporary file"
cleanup() {
  [ -z "$PROMPT_TMP" ] || rm -f "$PROMPT_TMP"
  rm -f "$BODY_TMP" "$RESP_TMP"
}

jq -n --rawfile prompt "$PROMPT_FILE" \
  '{contents: [{role: "user", parts: [{text: $prompt}]}], generationConfig: {responseModalities: ["TEXT", "IMAGE"]}}' \
  > "$BODY_TMP" || die 2 "could not build the request body"

mkdir -p "$OUT_DIR" || die 2 "could not create the output directory: $OUT_DIR"

curl_keyed --header 'Content-Type: application/json' \
  --data-binary "@$BODY_TMP" \
  --output "$RESP_TMP" \
  "$API_BASE/$MODEL:generateContent"
rc=$?
[ "$rc" -ne 124 ] || die 5 "the API did not answer within ${TIMEOUT}s"
[ "$rc" -eq 0 ] || die 3 "the request failed (curl exit $rc)"

# An API error body is JSON with .error; surface its message, which never
# contains the key.
if jq -e '.error' "$RESP_TMP" >/dev/null 2>&1; then
  msg=$(jq -r '.error.message // "unknown error"' "$RESP_TMP" 2>/dev/null)
  status=$(jq -r '.error.status // "?"' "$RESP_TMP" 2>/dev/null)
  # A depleted balance or a hit rate limit is NOT a credential fault, and
  # reporting it as one sends the captain to regenerate a perfectly good key.
  # Verified 2026-08-06: this surface bills from AI Studio PREPAYMENT credits
  # rather than drawing on the Cloud billing account directly, so an empty
  # balance answers RESOURCE_EXHAUSTED even with billing enabled on the project.
  if [ "$status" = "RESOURCE_EXHAUSTED" ]; then
    printf 'fm-image-gen: the API refused for quota or balance reasons, not credentials: %s\n' "$msg" >&2
    printf 'fm-image-gen: the key is fine - do not regenerate it. Top up prepayment credits or wait out the rate limit.\n' >&2
    exit 8
  fi
  die 3 "API error ($status): $msg"
fi

# The extension follows the mimeType the API actually returned, never a guess.
# This surface returns image/jpeg by default, and writing a JPEG into a .png
# filename is the same class of quiet mismatch as substituting a model: every
# downstream tool then trusts a name that lies about the bytes.
ext_for_mime() {  # <mime>
  case "$1" in
    image/jpeg|image/jpg) printf 'jpg' ;;
    image/png)            printf 'png' ;;
    image/webp)           printf 'webp' ;;
    *)
      printf 'fm-image-gen: NOTE - unrecognized image mimeType %s; writing .bin\n' "${1:-none}" >&2
      printf 'bin' ;;
  esac
}

count=0
while IFS=$'\t' read -r mime b64; do
  [ -n "$b64" ] || continue
  count=$((count + 1))
  out="$OUT_DIR/creative-$(date +%Y%m%d-%H%M%S)-$count.$(ext_for_mime "$mime")"
  printf '%s' "$b64" | base64 --decode > "$out" 2>/dev/null || die 6 "could not decode the returned image data"
  [ -s "$out" ] || die 6 "the decoded image is empty"
  printf '%s\n' "$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
done < <(jq -r '.candidates[]?.content.parts[]? | select(.inlineData)
                | [(.inlineData.mimeType // ""), .inlineData.data] | @tsv' "$RESP_TMP" 2>/dev/null)

if [ "$count" -eq 0 ]; then
  # A text-only answer usually means the prompt was refused or the model was
  # asked for the wrong modality. Show the text so the caller can act.
  text=$(jq -r '[.candidates[]?.content.parts[]?.text] | join(" ") | .[0:400]' "$RESP_TMP" 2>/dev/null)
  [ -z "$text" ] || printf 'fm-image-gen: the model answered with text instead of an image: %s\n' "$text" >&2
  die 6 "the response carried no image"
fi

# Recorded only for images actually written, so a failed or refused call never
# consumes the cap. The fourth column is the dollar figure the cap sums; ledger
# lines written before the cap moved to dollars carry no fourth field and are
# read as zero rather than breaking the sum.
CALL_USD=$(awk -v n="$count" -v u="$UNIT_PRICE" 'BEGIN { printf "%.4f", n * u }')
mkdir -p "$STATE" 2>/dev/null || true
printf '%s\t%s\t%d\t%s\n' "$TODAY" "$MODEL" "$count" "$CALL_USD" >> "$LEDGER" 2>/dev/null || true

TOTAL_USD=$(awk -v s="$SPENT_TODAY" -v c="$CALL_USD" 'BEGIN { printf "%.4f", s + c }')
printf 'cost= model=%s images=%d usd=%s today=$%s/$%s\n' \
  "$MODEL" "$count" "$CALL_USD" "$TOTAL_USD" "$DAILY_USD_CAP" >&2
