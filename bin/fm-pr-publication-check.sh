#!/usr/bin/env bash
# Validate the complete public PR/MR body and exact head before readiness or
# ordinary merge monitoring.
#
# The responsible task worker runs "attest" only after reading the complete
# published draft body and judging that its Intent and outcome describe the
# whole PR. The command fetches fresh public bytes, rejects deterministic
# publication hazards, verifies any declared evidence, atomically writes a
# private state/<task-id>.pr-publication receipt bound to that body and head,
# and marks the unchanged draft ready through the forge's supported mechanism.
#
# Firstmate and bin/fm-pr-check.sh run "verify" before reporting or monitoring.
# Verification fetches the public body again, repeats deterministic checks and
# evidence accessibility checks, and refuses body/head drift or a missing,
# malformed, or failed attestation receipt.
#
# Neither mode edits a PR body. Failures before the ready transition leave review
# state unchanged. A failed post-ready readback removes the invalid receipt and
# attempts draft rollback; if rollback also fails, both failures are reported and
# the PR or MR is explicitly identified as possibly still reviewable. The original
# task worker remains correction owner and must update the draft body through the
# selected delivery path before attesting again.
#
# GitHub body readback uses gh-axi pr view --full and cross-checks it against one
# raw gh JSON snapshot containing the exact body and head; gh-axi's generic API
# view cannot bind them because it intentionally truncates long string fields.
# Ruby's YAML parser decodes the structured full view. GitLab readback uses
# glab's JSON output and requires jq so description, web_url, and sha are read
# without parsing presentation text.
# GitHub evidence uses the authenticated Contents JSON response and accepts only
# type=file with a blob SHA. GitLab evidence likewise requires exact repository-
# file metadata with a blob ID and matching ref; its reviewer URL path is strictly
# percent-decoded once and API-encoded once. Malformed or still-escaped decoded
# paths are refused, and a directory is never evidence.
# Create GitHub PRs with gh-axi pr create --draft and GitLab MRs with glab mr
# create --draft. Successful attestation uses gh-axi pr ready or glab mr update
# --ready. After later drift, the responsible worker returns the change to draft
# with gh pr ready <url> --undo or glab mr update <number> -R <repo> --draft.
#
# Usage:
#   fm-pr-publication-check.sh attest <task-id> <pr-url> \
#     --intent-outcome-complete \
#     --evidence <none-required|real-ui|nonvisual> \
#     [--evidence-url <exact-head repository URL>]...
#   fm-pr-publication-check.sh verify <task-id> <pr-url> [--machine]
#   fm-pr-publication-check.sh --help
# Watcher-only --machine failures emit one exact "failure <class>" line. Classes
# are publication-invalid, tool-unavailable, forge-read-failed,
# forge-response-invalid, state-invalid, and request-invalid.
set -eu

LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 3 ]; then
  echo "error: invalid PR publication check request; run --help" >&2
  exit 2
fi

ACTION=$1
ID=$2
RAW_URL=$3
shift 3

case "$ACTION" in
  attest|verify) ;;
  *) echo "error: invalid PR publication check action; run --help" >&2; exit 2 ;;
esac

if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR publication check request" >&2
  exit 2
fi

URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
META="$STATE/$ID.meta"
RECEIPT="$STATE/$ID.pr-publication"

INTENT_ATTESTED=0
EVIDENCE_MODE=
EVIDENCE_URLS=()
MACHINE=0
if [ "$ACTION" = attest ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --intent-outcome-complete)
        [ "$INTENT_ATTESTED" -eq 0 ] || { echo "error: duplicate intent attestation" >&2; exit 2; }
        INTENT_ATTESTED=1
        shift
        ;;
      --evidence)
        [ "$#" -ge 2 ] && [ -z "$EVIDENCE_MODE" ] || { echo "error: invalid evidence attestation" >&2; exit 2; }
        EVIDENCE_MODE=$2
        shift 2
        ;;
      --evidence-url)
        [ "$#" -ge 2 ] || { echo "error: --evidence-url requires a value" >&2; exit 2; }
        EVIDENCE_URLS+=("$2")
        shift 2
        ;;
      *) echo "error: unknown PR publication attestation argument: $1" >&2; exit 2 ;;
    esac
  done
  [ "$INTENT_ATTESTED" -eq 1 ] || {
    echo "error: responsible worker must explicitly attest complete PR-level intent and outcome" >&2
    exit 1
  }
  case "$EVIDENCE_MODE" in
    none-required)
      [ "${#EVIDENCE_URLS[@]}" -eq 0 ] || {
        echo "error: none-required evidence attestation cannot include evidence URLs" >&2
        exit 2
      }
      ;;
    real-ui|nonvisual)
      [ "${#EVIDENCE_URLS[@]}" -gt 0 ] || {
        echo "error: evidence mode $EVIDENCE_MODE requires at least one exact-head evidence URL" >&2
        exit 1
      }
      ;;
    *) echo "error: --evidence must be none-required, real-ui, or nonvisual" >&2; exit 2 ;;
  esac
elif [ "$#" -eq 1 ] && [ "$1" = --machine ]; then
  MACHINE=1
  shift
elif [ "$#" -ne 0 ]; then
  echo "error: verify accepts no attestation arguments" >&2
  exit 2
fi

BODY_FILE=
SCAN_FILE=
FORGE_FILE=
AXI_FIELDS_FILE=
FIELDS_FILE=
URLS_FILE=
EVIDENCE_FILE=
DECODE_TARGET=
RECEIPT_TMP=
INTENT_FILE=
OUTCOME_FILE=
cleanup() {
  local path cleanup_status=0
  for path in "$BODY_FILE" "$SCAN_FILE" "$FORGE_FILE" "$AXI_FIELDS_FILE" \
    "$FIELDS_FILE" "$URLS_FILE" "$EVIDENCE_FILE" "$DECODE_TARGET" \
    "$RECEIPT_TMP" "$INTENT_FILE" "$OUTCOME_FILE"; do
    [ -z "$path" ] && continue
    if ! rm -f -- "$path"; then
      cleanup_status=1
    fi
  done
  return "$cleanup_status"
}
FAILURE_CLASS=request-invalid
SUCCESS_RESULT=
finish() {
  local status=$? cleanup_status=0 result_class=$FAILURE_CLASS
  trap - EXIT
  if ! cleanup; then
    cleanup_status=1
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    echo "error: private PR publication scratch cleanup failed" >&2
    if [ "$status" -eq 0 ]; then
      status=1
      result_class=state-invalid
    fi
  fi
  if [ "$status" -eq 0 ]; then
    [ -z "$SUCCESS_RESULT" ] || printf '%s\n' "$SUCCESS_RESULT"
  elif [ "$MACHINE" -eq 1 ]; then
    printf 'failure %s\n' "$result_class"
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM

scratch_create() {
  local variable=$1 template=$2 path
  FAILURE_CLASS=state-invalid
  path=$(mktemp "$STATE/$template") || return 1
  printf -v "$variable" '%s' "$path"
}

scratch_store_text() {
  local destination=$1 content=$2
  FAILURE_CLASS=state-invalid
  printf '%s\n' "$content" > "$destination"
}

FAILURE_CLASS=state-invalid
if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "error: task state directory is unavailable" >&2
  exit 1
fi
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

umask 077
scratch_create BODY_FILE .fm-pr-publication-body.XXXXXX || exit 1
scratch_create SCAN_FILE .fm-pr-publication-scan.XXXXXX || exit 1
scratch_create FORGE_FILE .fm-pr-publication-forge.XXXXXX || exit 1
scratch_create AXI_FIELDS_FILE .fm-pr-publication-axi-fields.XXXXXX || exit 1
scratch_create FIELDS_FILE .fm-pr-publication-fields.XXXXXX || exit 1
scratch_create URLS_FILE .fm-pr-publication-urls.XXXXXX || exit 1
scratch_create EVIDENCE_FILE .fm-pr-publication-evidence.XXXXXX || exit 1

decode_base64_to_body() {
  local encoded=$1
  if printf '%s' "$encoded" | base64 --decode > "$BODY_FILE" 2>/dev/null; then
    return 0
  fi
  printf '%s' "$encoded" | base64 -D > "$BODY_FILE" 2>/dev/null
}

base64_value_valid() {
  local encoded=$1
  if printf '%s' "$encoded" | base64 --decode >/dev/null 2>&1; then
    return 0
  fi
  printf '%s' "$encoded" | base64 -D >/dev/null 2>&1
}

decode_gitlab_web_path() {
  ruby -e '
    input = ARGV.fetch(0).b
    bytes = []
    index = 0
    while index < input.bytesize
      byte = input.getbyte(index)
      if byte == 37
        exit 2 if index + 2 >= input.bytesize
        hex = input.byteslice(index + 1, 2)
        exit 2 unless hex.match?(/\A[0-9A-Fa-f]{2}\z/)
        bytes << hex.to_i(16)
        index += 3
      else
        bytes << byte
        index += 1
      end
    end
    decoded = bytes.pack("C*")
    exit 3 if decoded.empty? || decoded.bytes.any? { |value| value < 32 || value == 127 }
    exit 4 if decoded.match?(/%[0-9A-Fa-f]{2}/)
    decoded.force_encoding(Encoding::UTF_8)
    exit 5 unless decoded.valid_encoding?
    STDOUT.write(decoded)
  ' "$1"
}

read_four_fields() {
  local file=$1 first second third fourth extra
  exec 7< "$file" || return 1
  IFS= read -r first <&7 || { exec 7<&-; return 1; }
  IFS= read -r second <&7 || { exec 7<&-; return 1; }
  IFS= read -r third <&7 || { exec 7<&-; return 1; }
  IFS= read -r fourth <&7 || { exec 7<&-; return 1; }
  if IFS= read -r extra <&7; then
    : "$extra"
    exec 7<&-
    return 1
  fi
  exec 7<&-
  FETCHED_URL=$first
  FETCHED_HEAD=$second
  FETCHED_BODY_BASE64=$third
  FETCHED_DRAFT=$fourth
}

task_worktree() {
  local line value count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree=*)
        count=$((count + 1))
        value=${line#worktree=}
        ;;
    esac
  done < "$META"
  [ "$count" -eq 1 ] && [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

github_worktree_valid() {
  local worktree=$1 slug expected
  FAILURE_CLASS=state-invalid
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  [ "$(git -C "$worktree" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
  FAILURE_CLASS=forge-read-failed
  slug=$(cd "$worktree" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 1
  FAILURE_CLASS=state-invalid
  expected=$(printf '%s' "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]')
  [ "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" = "$expected" ]
}

fetch_github() {
  local worktree forge_response axi_fields fields
  FAILURE_CLASS=tool-unavailable
  command -v gh-axi >/dev/null 2>&1 || {
    echo "error: GitHub publication readback requires gh-axi on PATH" >&2
    return 1
  }
  command -v ruby >/dev/null 2>&1 || {
    echo "error: GitHub publication readback requires Ruby for structured gh-axi output" >&2
    return 1
  }
  command -v gh >/dev/null 2>&1 || {
    echo "error: GitHub publication readback requires gh for an exact body/head snapshot" >&2
    return 1
  }
  FAILURE_CLASS=state-invalid
  worktree=$(task_worktree) || {
    echo "error: task metadata lacks one exact worktree for GitHub publication readback" >&2
    return 1
  }
  github_worktree_valid "$worktree" || {
    echo "error: task worktree does not match the GitHub PR repository" >&2
    return 1
  }
  FAILURE_CLASS=forge-read-failed
  forge_response=$(cd "$worktree" && gh-axi pr view "$NUMBER" --full 2>/dev/null) || {
    echo "error: could not fetch the complete GitHub PR body" >&2
    return 1
  }
  scratch_store_text "$FORGE_FILE" "$forge_response" || {
    echo "error: complete GitHub PR readback could not be stored in private task state" >&2
    return 1
  }
  FAILURE_CLASS=forge-response-invalid
  axi_fields=$(ruby -ryaml -rbase64 -e '
    view = YAML.safe_load(File.binread(ARGV[0]), permitted_classes: [], aliases: false)
    expected_number = Integer(ARGV[1], 10)
    view_pr = view.fetch("pull_request")
    abort unless Integer(view_pr.fetch("number").to_s, 10) == expected_number
    body = view_pr.fetch("body")
    abort unless body.is_a?(String)
    puts Base64.strict_encode64(body)
  ' "$FORGE_FILE" "$NUMBER" 2>/dev/null) || {
    echo "error: complete GitHub PR readback was incomplete or malformed" >&2
    return 1
  }
  scratch_store_text "$AXI_FIELDS_FILE" "$axi_fields" || {
    echo "error: complete GitHub PR fields could not be stored in private task state" >&2
    return 1
  }
  FAILURE_CLASS=state-invalid
  AXI_BODY_BASE64=$(cat "$AXI_FIELDS_FILE") || {
    echo "error: complete GitHub PR fields could not be read from private task state" >&2
    return 1
  }
  AXI_FIELD_LINES=$(wc -l < "$AXI_FIELDS_FILE") || {
    echo "error: complete GitHub PR fields could not be measured in private task state" >&2
    return 1
  }
  AXI_FIELD_LINES=${AXI_FIELD_LINES//[[:space:]]/}
  FAILURE_CLASS=forge-response-invalid
  [ -n "$AXI_BODY_BASE64" ] && [ "$AXI_FIELD_LINES" = 1 ] || {
    echo "error: complete GitHub PR body could not be decoded exactly" >&2
    return 1
  }
  FAILURE_CLASS=forge-read-failed
  fields=$(gh pr view "$URL" --json url,headRefOid,body,isDraft \
    --jq '[.url,.headRefOid,(.body|@base64),(.isDraft|tostring)] | .[]' 2>/dev/null) || {
    echo "error: could not fetch the complete GitHub PR body and head" >&2
    return 1
  }
  scratch_store_text "$FIELDS_FILE" "$fields" || {
    echo "error: complete GitHub PR body and head could not be stored in private task state" >&2
    return 1
  }
  FAILURE_CLASS=forge-response-invalid
  read_four_fields "$FIELDS_FILE" || {
    echo "error: GitHub PR readback was incomplete or malformed" >&2
    return 1
  }
  [ "$FETCHED_BODY_BASE64" = "$AXI_BODY_BASE64" ] || {
    echo "error: complete GitHub PR readbacks did not match" >&2
    return 1
  }
}

fetch_gitlab() {
  local forge_response fields
  FAILURE_CLASS=tool-unavailable
  command -v glab >/dev/null 2>&1 || {
    echo "error: GitLab publication readback requires glab on PATH" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: GitLab publication readback requires jq for exact JSON fields" >&2
    return 1
  }
  FAILURE_CLASS=forge-read-failed
  forge_response=$(glab mr view "$NUMBER" -R "https://$HOST/$PROJECT_PATH" -F json 2>/dev/null) || {
    echo "error: could not fetch the complete GitLab MR body and head" >&2
    return 1
  }
  scratch_store_text "$FORGE_FILE" "$forge_response" || {
    echo "error: complete GitLab MR readback could not be stored in private task state" >&2
    return 1
  }
  FAILURE_CLASS=forge-response-invalid
  fields=$(jq -er '[.web_url,.sha,((.description // "")|@base64),(.draft|tostring)] | .[]' \
    "$FORGE_FILE" 2>/dev/null) || {
      echo "error: GitLab MR JSON lacks exact web_url, sha, or description fields" >&2
      return 1
    }
  scratch_store_text "$FIELDS_FILE" "$fields" || {
    echo "error: complete GitLab MR fields could not be stored in private task state" >&2
    return 1
  }
  FAILURE_CLASS=forge-response-invalid
  read_four_fields "$FIELDS_FILE" || {
    echo "error: GitLab MR readback was incomplete or malformed" >&2
    return 1
  }
}

set_review_state() {
  local state=$1 worktree
  case "$PROVIDER:$state" in
    github:ready)
      worktree=$(task_worktree) && github_worktree_valid "$worktree" || return 1
      (cd "$worktree" && gh-axi pr ready "$NUMBER") >/dev/null 2>&1
      ;;
    github:draft)
      gh pr ready "$URL" --undo >/dev/null 2>&1
      ;;
    gitlab:ready)
      glab mr update "$NUMBER" -R "https://$HOST/$PROJECT_PATH" --ready --yes >/dev/null 2>&1
      ;;
    gitlab:draft)
      glab mr update "$NUMBER" -R "https://$HOST/$PROJECT_PATH" --draft --yes >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

case "$PROVIDER" in
  github) fetch_github || exit 1 ;;
  gitlab) fetch_gitlab || exit 1 ;;
  *) echo "error: unsupported forge for PR publication checking" >&2; exit 1 ;;
esac

FAILURE_CLASS=forge-response-invalid
if [ "$FETCHED_URL" != "$URL" ] || ! fm_pr_head_valid "$FETCHED_HEAD"; then
  echo "error: forge readback did not match the exact PR identity and head" >&2
  exit 1
fi
case "$FETCHED_DRAFT" in true|false) ;; *) echo "error: forge readback did not include exact draft state" >&2; exit 1 ;; esac
FAILURE_CLASS=publication-invalid
if [ "$ACTION" = attest ] && [ "$FETCHED_DRAFT" != true ]; then
  echo "error: publication attestation requires a draft PR or MR" >&2
  exit 1
fi
if [ "$ACTION" = verify ] && [ "$FETCHED_DRAFT" != false ]; then
  echo "error: publication verification requires a ready PR or MR" >&2
  exit 1
fi
FAILURE_CLASS=forge-response-invalid
base64_value_valid "$FETCHED_BODY_BASE64" || {
  echo "error: forge body bytes could not be decoded exactly" >&2
  exit 1
}
FAILURE_CLASS=state-invalid
decode_base64_to_body "$FETCHED_BODY_BASE64" || {
  echo "error: forge body bytes could not be stored in private task state" >&2
  exit 1
}
BODY_BYTES=$(wc -c < "$BODY_FILE") || {
  echo "error: fetched PR body could not be measured in private task state" >&2
  exit 1
}
BODY_BYTES=${BODY_BYTES//[[:space:]]/}
BODY_SHA256=$(fm_pr_sha256 "$BODY_FILE") || {
  echo "error: could not hash the fetched PR body" >&2
  exit 1
}
[[ "$BODY_BYTES" =~ ^[0-9]+$ ]] && [[ "$BODY_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "error: fetched PR body metadata was invalid" >&2
  exit 1
}

FAILURE_CLASS=publication-invalid

# Remove public HTTP(S) URLs before local-path scanning so an ordinary URL path
# such as https://docs.example/home/user is not mistaken for a local home path.
FAILURE_CLASS=state-invalid
sed -E 's#https?://[^[:space:])>]+##g' "$BODY_FILE" > "$SCAN_FILE" || {
  echo "error: fetched PR body could not be scanned in private task state" >&2
  exit 1
}
FAILURE_CLASS=publication-invalid

reject_match() {
  local category=$1 pattern=$2 file=${3:-$SCAN_FILE} match line match_status
  if match=$(grep -Enim 1 -- "$pattern" "$file" 2>/dev/null); then
    :
  else
    match_status=$?
    if [ "$match_status" -eq 1 ]; then
      return 0
    fi
    FAILURE_CLASS=state-invalid
    echo "error: private PR publication scratch could not be read" >&2
    return 1
  fi
  FAILURE_CLASS=publication-invalid
  line=${match%%:*}
  echo "error: PR publication check rejected $category at body line $line" >&2
  echo "error: the responsible task worker must correct the public body through its selected delivery path and attest again" >&2
  return 1
}

basic_token_is_placeholder() {
  local lowered
  lowered=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    redacted|masked|removed|placeholder|example|sample|dummy|token|credential|credentials|\
      redacted[-._~]*|masked[-._~]*|removed[-._~]*|placeholder[-._~]*|\
      basic_token|basic-token|basic.token|basic~token|basic_credential|basic-credential|basic.credential|basic~credential)
      return 0
      ;;
  esac
  return 1
}

reject_basic_authorization() {
  local candidates line token
  FAILURE_CLASS=state-invalid
  candidates=$(awk '
    {
      remaining=$0
      lower=tolower(remaining)
      while (match(lower, /authorization[[:space:]]*:[[:space:]]*basic[[:space:]]+/)) {
        value_start=RSTART + RLENGTH
        value=substr(remaining, value_start)
        if (match(value, /^[A-Za-z0-9._~+\/=-]+/)) {
          token=substr(value, RSTART, RLENGTH)
          print NR "\t" token
        }
        remaining=substr(remaining, value_start)
        lower=tolower(remaining)
      }
    }
  ' "$BODY_FILE") || {
    echo "error: private PR publication scratch could not be read" >&2
    return 1
  }
  FAILURE_CLASS=publication-invalid
  [ -n "$candidates" ] || return 0
  while IFS=$'\t' read -r line token; do
    basic_token_is_placeholder "$token" && continue
    echo "error: PR publication check rejected an Authorization Basic credential at body line $line" >&2
    echo "error: the responsible task worker must correct the public body through its selected delivery path and attest again" >&2
    return 1
  done <<< "$candidates"
  return 0
}

reject_match "an absolute Unix home path" '/(Users|home)/[^/[:space:])]+/|/root/' || exit 1
reject_match "an absolute Unix temporary path" '/((private/)?var/folders|((private/)?var/)?tmp)/' || exit 1
reject_match "a Windows user or temporary path" '(^|[^A-Za-z0-9])([A-Za-z]:\\Users\\[^\\[:space:]]+\\|[A-Za-z]:\\([^\\[:space:]]*\\)?[Tt]emp\\)' || exit 1
reject_match "a Windows UNC path" '(^|[^\\])\\\\[^\\[:space:]]+\\[^\\[:space:]]+' || exit 1
reject_match "a Windows local-drive evidence path" '((evidence|proof|artifact|screenshot).*[A-Za-z]:\\|[A-Za-z]:\\.*(evidence|proof|artifact|screenshot))' "$BODY_FILE" || exit 1
reject_match "a local file reference" 'local[[:space:]_-]*file[[:space:]]*:|file://' || exit 1
reject_match "a no-mistakes temporary evidence or worktree reference" 'no-mistakes-evidence|\.no-mistakes/(worktrees|runs|logs)|no-mistakes[\\/]worktrees' || exit 1
reject_match "local-only evidence" '(evidence|proof|artifact|screenshot)[[:space:]]+(is[[:space:]]+)?(available|stored|saved|kept)[[:space:]]+(only[[:space:]]+)?locally|local[[:space:]_-]+evidence' || exit 1
reject_match "a private host reference" 'https?://(localhost|127\.0\.0\.1|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)([:/]|$)' "$BODY_FILE" || exit 1
reject_match "private task, run, worker, or supervision narration" '(task|run|worker|supervision)[ _-]*(id|status|transcript)[[:space:]]*:|captain([^A-Za-z]+s)?[[:space:]]+(authorization|approval|instruction)|authorized[[:space:]]+by[[:space:]]+(the[[:space:]]+)?captain|firstmate[[:space:]]+(told|instructed)|crewmate[[:space:]]+(said|reported)' || exit 1
reject_match "a raw generated pipeline-agent transcript" '"?(user_findings_json|findings_json|step_rounds|step_results|tool_call_id)"?[[:space:]]*:|"findings"[[:space:]]*:[[:space:]]*\[|begin[[:space:]_-]+agent[[:space:]_-]+transcript|pipeline-agent[[:space:]_-]+transcript' || exit 1
reject_match "a private-key block" '-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----' "$BODY_FILE" || exit 1
reject_match "a credential-shaped token" '(AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{24,})' "$BODY_FILE" || exit 1
reject_match "an assigned secret value" '(api[_ -]?key|access[_ -]?token|password|client[_ -]?secret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/=_-]{16,}' "$BODY_FILE" || exit 1
reject_match "an Authorization Bearer credential" 'authorization[[:space:]]*:[[:space:]]*bearer[[:space:]]+[A-Za-z0-9._~+/-]{12,}={0,2}' "$BODY_FILE" || exit 1
reject_basic_authorization || exit 1
reject_match "a standalone JWT-shaped credential" '(^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{16,}([^A-Za-z0-9_-]|$)' "$BODY_FILE" || exit 1

extract_section() {
  local kind=$1 output=$2
  awk -v wanted="$kind" '
    BEGIN { in_section=0; found=0 }
    {
      lower=tolower($0)
      if (wanted == "intent" && lower ~ /^##[[:space:]]+(pr[ -]level[[:space:]]+)?intent[[:space:]]*$/) {
        in_section=1; found=1; next
      }
      if (wanted == "outcome" && lower ~ /^##[[:space:]]+(what changed|outcome|result|changes)[[:space:]]*$/) {
        in_section=1; found=1; next
      }
      if (in_section && $0 ~ /^##?[[:space:]]+/) exit
      if (in_section) print
    }
    END { if (!found) exit 3 }
  ' "$BODY_FILE" > "$output"
}

scratch_create INTENT_FILE .fm-pr-publication-intent.XXXXXX || exit 1
scratch_create OUTCOME_FILE .fm-pr-publication-outcome.XXXXXX || exit 1

FAILURE_CLASS=state-invalid
if extract_section intent "$INTENT_FILE"; then
  :
else
  section_status=$?
  if [ "$section_status" -eq 3 ]; then
    FAILURE_CLASS=publication-invalid
    echo "error: PR body must contain a reviewer-facing ## Intent section" >&2
  else
    echo "error: PR intent could not be stored in private task state" >&2
  fi
  exit 1
fi
if extract_section outcome "$OUTCOME_FILE"; then
  :
else
  section_status=$?
  if [ "$section_status" -eq 3 ]; then
    FAILURE_CLASS=publication-invalid
    echo "error: PR body must contain a reviewer-facing ## What Changed, ## Outcome, ## Result, or ## Changes section" >&2
  else
    echo "error: PR outcome could not be stored in private task state" >&2
  fi
  exit 1
fi
if grep -q '[^[:space:]]' "$INTENT_FILE"; then
  intent_status=0
else
  intent_status=$?
fi
if grep -q '[^[:space:]]' "$OUTCOME_FILE"; then
  outcome_status=0
else
  outcome_status=$?
fi
if [ "$intent_status" -gt 1 ] || [ "$outcome_status" -gt 1 ]; then
  echo "error: PR intent or outcome could not be read from private task state" >&2
  exit 1
fi
FAILURE_CLASS=publication-invalid
if [ "$intent_status" -eq 1 ] || [ "$outcome_status" -eq 1 ]; then
  echo "error: PR intent and outcome sections must both contain reviewer-facing content" >&2
  exit 1
fi
reject_match "operational rather than PR-level intent framing" '(successor|current)[[:space:]_-]+(run|task|attempt)|latest[[:space:]_-]+commit|last[[:space:]_-]+commit|this[[:space:]_-]+round|recovered[[:space:]_-]+branch|captain([^A-Za-z]+s)?[[:space:]]+(authorization|approval)|authorized[[:space:]]+by[[:space:]]+(the[[:space:]]+)?captain' || exit 1

FAILURE_CLASS=state-invalid
if ! (set -o pipefail; awk '
  {
    rest=$0
    while (match(rest, /https?:\/\/[^[:space:]<>()\[\]"`\047]+/)) {
      token=substr(rest, RSTART, RLENGTH)
      sub(/[.,;:!?]+$/, "", token)
      print token
      rest=substr(rest, RSTART + RLENGTH)
    }
  }
' "$BODY_FILE" | LC_ALL=C sort -u > "$URLS_FILE"); then
  echo "error: public PR links could not be stored in private task state" >&2
  exit 1
fi
FAILURE_CLASS=publication-invalid

verify_evidence_url() {
  local evidence_url=$1 base evidence_path fragment encoded_project encoded_path response_status evidence_response link_status
  FAILURE_CLASS=state-invalid
  if grep -Fxq -- "$evidence_url" "$URLS_FILE"; then
    :
  else
    link_status=$?
    if [ "$link_status" -gt 1 ]; then
      echo "error: public PR links could not be read from private task state" >&2
    else
      FAILURE_CLASS=publication-invalid
      echo "error: declared evidence URL is absent from the fetched public body" >&2
    fi
    return 1
  fi
  FAILURE_CLASS=publication-invalid
  case "$PROVIDER" in
    github)
      base="https://github.com/$PROJECT_PATH/blob/$FETCHED_HEAD/"
      case "$evidence_url" in
        "$base"*) ;;
        *) echo "error: GitHub evidence must be a same-repository blob URL pinned to the exact PR head" >&2; return 1 ;;
      esac
      evidence_path=${evidence_url#"$base"}
      case "$evidence_path" in
        *'#'*)
          fragment=${evidence_path#*#}
          evidence_path=${evidence_path%%#*}
          [[ "$fragment" =~ ^L[0-9]+(-L[0-9]+)?$ ]] || {
            echo "error: GitHub evidence has an unsupported fragment" >&2
            return 1
          }
          ;;
      esac
      case "$evidence_path" in
        ''|*'?'*)
          case "$evidence_path" in *'?raw=1') evidence_path=${evidence_path%'?raw=1'} ;; *) return 1 ;; esac
          ;;
      esac
      [ -n "$evidence_path" ] || return 1
      if [ "$EVIDENCE_MODE" = real-ui ]; then
        case "$evidence_path" in
          *[Ii]llustration*|*[Mm]ockup*|*[Cc]oncept*|*[Gg]enerated*|*[Aa][Ii]-[Ii]mage*)
            echo "error: a custom illustration or mockup cannot attest real UI behavior" >&2
            return 1
            ;;
        esac
      fi
      FAILURE_CLASS=tool-unavailable
      command -v gh >/dev/null 2>&1 || {
        echo "error: GitHub evidence verification requires gh on PATH" >&2
        return 1
      }
      command -v ruby >/dev/null 2>&1 || {
        echo "error: GitHub evidence verification requires Ruby for the Contents response" >&2
        return 1
      }
      FAILURE_CLASS=forge-read-failed
      evidence_response=$(gh api "/repos/$PROJECT_PATH/contents/$evidence_path?ref=$FETCHED_HEAD" \
        --header 'Accept: application/vnd.github.object+json' 2>/dev/null) || {
        echo "error: GitHub evidence is not authenticated-accessible at the exact PR head" >&2
        return 1
      }
      scratch_store_text "$EVIDENCE_FILE" "$evidence_response" || {
        echo "error: GitHub evidence response could not be stored in private task state" >&2
        return 1
      }
      FAILURE_CLASS=forge-response-invalid
      if ruby -rjson -e '
        begin
          response = JSON.parse(File.binread(ARGV[0]))
        rescue JSON::ParserError
          exit 2
        end
        exit 3 unless response.is_a?(Hash) && response["type"] == "file" &&
          response["sha"].is_a?(String) && response["sha"].match?(/\A[0-9a-f]{40}([0-9a-f]{24})?\z/)
      ' "$EVIDENCE_FILE" 2>/dev/null; then
        :
      else
        response_status=$?
        if [ "$response_status" -eq 2 ]; then
          FAILURE_CLASS=forge-response-invalid
          echo "error: GitHub Contents response was malformed" >&2
        else
          FAILURE_CLASS=publication-invalid
          echo "error: GitHub evidence URL does not identify a file/blob at the exact PR head" >&2
        fi
        return 1
      fi
      FAILURE_CLASS=publication-invalid
      ;;
    gitlab)
      base="https://$HOST/$PROJECT_PATH/-/blob/$FETCHED_HEAD/"
      case "$evidence_url" in
        "$base"*) ;;
        *) echo "error: GitLab evidence must be a same-project blob URL pinned to the exact MR head" >&2; return 1 ;;
      esac
      evidence_path=${evidence_url#"$base"}
      case "$evidence_path" in
        *'#'*)
          fragment=${evidence_path#*#}
          evidence_path=${evidence_path%%#*}
          [[ "$fragment" =~ ^L[0-9]+(-L[0-9]+)?$ ]] || {
            echo "error: GitLab evidence has an unsupported fragment" >&2
            return 1
          }
          ;;
      esac
      case "$evidence_path" in ''|*'?'*) return 1 ;; esac
      FAILURE_CLASS=tool-unavailable
      command -v ruby >/dev/null 2>&1 || {
        echo "error: GitLab evidence verification requires Ruby for strict web-path decoding" >&2
        return 1
      }
      evidence_path=$(decode_gitlab_web_path "$evidence_path" 2>/dev/null) || {
        FAILURE_CLASS=publication-invalid
        echo "error: GitLab evidence has a malformed or ambiguously encoded repository path" >&2
        return 1
      }
      if [ "$EVIDENCE_MODE" = real-ui ]; then
        case "$evidence_path" in
          *[Ii]llustration*|*[Mm]ockup*|*[Cc]oncept*|*[Gg]enerated*|*[Aa][Ii]-[Ii]mage*)
            echo "error: a custom illustration or mockup cannot attest real UI behavior" >&2
            return 1
            ;;
        esac
      fi
      FAILURE_CLASS=tool-unavailable
      command -v glab >/dev/null 2>&1 || return 1
      command -v jq >/dev/null 2>&1 || return 1
      FAILURE_CLASS=state-invalid
      encoded_project=$(jq -rn --arg value "$PROJECT_PATH" '$value|@uri') || return 1
      encoded_path=$(jq -rn --arg value "$evidence_path" '$value|@uri') || return 1
      FAILURE_CLASS=forge-read-failed
      evidence_response=$(glab api --hostname "$HOST" \
        "projects/$encoded_project/repository/files/$encoded_path?ref=$FETCHED_HEAD" 2>/dev/null) || {
        echo "error: GitLab evidence is not authenticated-accessible at the exact MR head" >&2
        return 1
      }
      scratch_store_text "$EVIDENCE_FILE" "$evidence_response" || {
        echo "error: GitLab evidence response could not be stored in private task state" >&2
        return 1
      }
      FAILURE_CLASS=forge-response-invalid
      if jq -er --arg evidence_path "$evidence_path" --arg head "$FETCHED_HEAD" \
        'type == "object" and .file_path == $evidence_path and .ref == $head and
          (.blob_id | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))' \
        "$EVIDENCE_FILE" >/dev/null 2>&1; then
        :
      else
        response_status=$?
        if [ "$response_status" -eq 4 ]; then
          FAILURE_CLASS=forge-response-invalid
          echo "error: GitLab repository-file response was malformed" >&2
        else
          FAILURE_CLASS=publication-invalid
          echo "error: GitLab evidence URL does not identify a file/blob at the exact MR head" >&2
        fi
        return 1
      fi
      FAILURE_CLASS=publication-invalid
      ;;
  esac
}

RECEIPT_MODE=
RECEIPT_URLS=()
parse_receipt() {
  local file=$1 line expected_count index=0
  local version task_id provider url head body_bytes body_sha privacy links attestation evidence_mode evidence_count
  FAILURE_CLASS=state-invalid
  exec 8< "$file" || return 1
  FAILURE_CLASS=publication-invalid
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r task_id <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r head <&8 || { exec 8<&-; return 1; }
  IFS= read -r body_bytes <&8 || { exec 8<&-; return 1; }
  IFS= read -r body_sha <&8 || { exec 8<&-; return 1; }
  IFS= read -r privacy <&8 || { exec 8<&-; return 1; }
  IFS= read -r links <&8 || { exec 8<&-; return 1; }
  IFS= read -r attestation <&8 || { exec 8<&-; return 1; }
  IFS= read -r evidence_mode <&8 || { exec 8<&-; return 1; }
  IFS= read -r evidence_count <&8 || { exec 8<&-; return 1; }
  [ "$version" = fm-pr-publication-v1 ] || { exec 8<&-; return 1; }
  [ "$task_id" = "task_id=$ID" ] || { exec 8<&-; return 1; }
  [ "$provider" = "provider=$PROVIDER" ] || { exec 8<&-; return 1; }
  [ "$url" = "url=$URL" ] || { exec 8<&-; return 1; }
  [ "$head" = "head=$FETCHED_HEAD" ] || { exec 8<&-; return 1; }
  [ "$body_bytes" = "body_bytes=$BODY_BYTES" ] || { exec 8<&-; return 1; }
  [ "$body_sha" = "body_sha256=$BODY_SHA256" ] || { exec 8<&-; return 1; }
  [ "$privacy" = privacy=pass ] && [ "$links" = links=pass ] \
    && [ "$attestation" = attestation=agent-explicit ] || { exec 8<&-; return 1; }
  RECEIPT_MODE=${evidence_mode#evidence_mode=}
  [ "$evidence_mode" = "evidence_mode=$RECEIPT_MODE" ] || { exec 8<&-; return 1; }
  expected_count=${evidence_count#evidence_count=}
  [ "$evidence_count" = "evidence_count=$expected_count" ] \
    && [[ "$expected_count" =~ ^[0-9]+$ ]] || { exec 8<&-; return 1; }
  RECEIPT_URLS=()
  while [ "$index" -lt "$expected_count" ]; do
    IFS= read -r line <&8 || { exec 8<&-; return 1; }
    case "$line" in evidence_url_base64=*) ;; *) exec 8<&-; return 1 ;; esac
    RECEIPT_URLS+=("${line#evidence_url_base64=}")
    index=$((index + 1))
  done
  if IFS= read -r line <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  case "$RECEIPT_MODE" in
    none-required) [ "$expected_count" -eq 0 ] ;;
    real-ui|nonvisual) [ "$expected_count" -gt 0 ] ;;
    *) return 1 ;;
  esac
}

fail_after_ready() {
  local message=$1 rollback_status=0 receipt_status=0
  set_review_state draft || rollback_status=$?
  rm -f -- "$RECEIPT" || receipt_status=$?
  echo "error: $message" >&2
  if [ "$rollback_status" -ne 0 ]; then
    echo "error: draft rollback also failed with exit $rollback_status; the PR or MR may remain reviewable without a valid publication receipt" >&2
  fi
  if [ "$receipt_status" -ne 0 ]; then
    echo "error: invalid publication receipt removal also failed with exit $receipt_status" >&2
  fi
  exit 1
}

if [ "$ACTION" = verify ]; then
  if [ ! -e "$RECEIPT" ] && [ ! -L "$RECEIPT" ]; then
    FAILURE_CLASS=publication-invalid
    echo "error: a private PR publication attestation receipt is required before readiness or monitoring" >&2
    exit 1
  fi
  FAILURE_CLASS=state-invalid
  STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
  fm_pr_private_file_valid "$RECEIPT" 600 "$STATE_DEVICE" || {
    echo "error: private PR publication receipt state is unsafe or unavailable" >&2
    exit 1
  }
  FAILURE_CLASS=publication-invalid
  parse_receipt "$RECEIPT" || {
    echo "error: PR publication receipt is malformed or does not match the fresh public body and head" >&2
    exit 1
  }
  EVIDENCE_MODE=$RECEIPT_MODE
  EVIDENCE_URLS=()
  for encoded_url in "${RECEIPT_URLS[@]+"${RECEIPT_URLS[@]}"}"; do
    scratch_create DECODE_TARGET .fm-pr-publication-url.XXXXXX || exit 1
    FAILURE_CLASS=publication-invalid
    if ! base64_value_valid "$encoded_url"; then
      echo "error: PR publication receipt contains malformed evidence data" >&2
      exit 1
    fi
    FAILURE_CLASS=state-invalid
    if ! { printf '%s' "$encoded_url" | base64 --decode > "$DECODE_TARGET" 2>/dev/null \
      || printf '%s' "$encoded_url" | base64 -D > "$DECODE_TARGET" 2>/dev/null; }; then
      echo "error: evidence URL could not be decoded into private task state" >&2
      exit 1
    fi
    decoded_url=$(cat "$DECODE_TARGET") || exit 1
    rm -f -- "$DECODE_TARGET" || exit 1
    DECODE_TARGET=
    FAILURE_CLASS=publication-invalid
    [ -n "$decoded_url" ] || {
      echo "error: PR publication receipt contains empty evidence data" >&2
      exit 1
    }
    EVIDENCE_URLS+=("$decoded_url")
  done
fi

FAILURE_CLASS=publication-invalid
for evidence_url in "${EVIDENCE_URLS[@]+"${EVIDENCE_URLS[@]}"}"; do
  verify_evidence_url "$evidence_url" || exit 1
done

if [ "$ACTION" = attest ]; then
  ATTESTED_HEAD=$FETCHED_HEAD
  ATTESTED_BODY_BYTES=$BODY_BYTES
  ATTESTED_BODY_SHA256=$BODY_SHA256
  FAILURE_CLASS=state-invalid
  STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
  fm_pr_regular_destination_on_device_or_absent "$RECEIPT" "$STATE_DEVICE" || {
    echo "error: PR publication receipt destination is unsafe" >&2
    exit 1
  }
  scratch_create RECEIPT_TMP .fm-pr-publication-receipt.XXXXXX || exit 1
  {
    printf '%s\n' fm-pr-publication-v1
    printf 'task_id=%s\n' "$ID"
    printf 'provider=%s\n' "$PROVIDER"
    printf 'url=%s\n' "$URL"
    printf 'head=%s\n' "$FETCHED_HEAD"
    printf 'body_bytes=%s\n' "$BODY_BYTES"
    printf 'body_sha256=%s\n' "$BODY_SHA256"
    printf '%s\n' privacy=pass links=pass attestation=agent-explicit
    printf 'evidence_mode=%s\n' "$EVIDENCE_MODE"
    printf 'evidence_count=%s\n' "${#EVIDENCE_URLS[@]}"
    for evidence_url in "${EVIDENCE_URLS[@]+"${EVIDENCE_URLS[@]}"}"; do
      printf 'evidence_url_base64='
      printf '%s' "$evidence_url" | base64 | tr -d '\n'
      printf '\n'
    done
  } > "$RECEIPT_TMP" || exit 1
  chmod 0600 "$RECEIPT_TMP" || exit 1
  fm_pr_private_file_valid "$RECEIPT_TMP" 600 "$STATE_DEVICE" || exit 1
  fm_pr_regular_destination_on_device_or_absent "$RECEIPT" "$STATE_DEVICE" || exit 1
  mv -f -- "$RECEIPT_TMP" "$RECEIPT" || exit 1
  RECEIPT_TMP=
  fm_pr_private_file_valid "$RECEIPT" 600 "$STATE_DEVICE" || exit 1
  parse_receipt "$RECEIPT" || exit 1
  FAILURE_CLASS=forge-read-failed
  if ! set_review_state ready; then
    rm -f -- "$RECEIPT"
    echo "error: publication passed but the forge could not mark the draft ready" >&2
    exit 1
  fi
  READY_READBACK_FAILED=0
  case "$PROVIDER" in
    github) fetch_github || READY_READBACK_FAILED=1 ;;
    gitlab) fetch_gitlab || READY_READBACK_FAILED=1 ;;
  esac
  if [ "${READY_READBACK_FAILED:-0}" -ne 0 ] || [ "$FETCHED_URL" != "$URL" ] \
    || [ "$FETCHED_HEAD" != "$ATTESTED_HEAD" ] || [ "$FETCHED_DRAFT" != false ]; then
    fail_after_ready "ready-state readback did not preserve the attested PR identity and head"
  fi
  FAILURE_CLASS=forge-response-invalid
  if ! base64_value_valid "$FETCHED_BODY_BASE64"; then
    fail_after_ready "ready-state readback returned malformed public body bytes"
  fi
  FAILURE_CLASS=state-invalid
  if ! decode_base64_to_body "$FETCHED_BODY_BASE64"; then
    fail_after_ready "ready-state public body could not be stored in private task state"
  fi
  READY_BODY_BYTES=$(wc -c < "$BODY_FILE") || {
    fail_after_ready "ready-state public body could not be measured in private task state"
  }
  READY_BODY_BYTES=${READY_BODY_BYTES//[[:space:]]/}
  READY_BODY_SHA256=$(fm_pr_sha256 "$BODY_FILE") || {
    fail_after_ready "ready-state public body could not be hashed in private task state"
  }
  if [ "$READY_BODY_BYTES" != "$ATTESTED_BODY_BYTES" ] \
    || [ "$READY_BODY_SHA256" != "$ATTESTED_BODY_SHA256" ]; then
    FAILURE_CLASS=publication-invalid
    fail_after_ready "public body drifted while the draft was being marked ready"
  fi
  SUCCESS_RESULT="attested $ATTESTED_HEAD $ATTESTED_BODY_BYTES $ATTESTED_BODY_SHA256"
else
  SUCCESS_RESULT="verified $FETCHED_HEAD $BODY_BYTES $BODY_SHA256"
fi
