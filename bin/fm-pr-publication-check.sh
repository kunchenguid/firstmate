#!/usr/bin/env bash
# Validate the complete public PR/MR body and exact head before readiness or
# ordinary merge monitoring.
#
# The responsible task worker runs "attest" only after reading the complete
# published body and judging that its Intent and outcome describe the whole PR.
# The command fetches fresh public bytes, rejects deterministic publication
# hazards, verifies any declared evidence, and atomically writes a private
# state/<task-id>.pr-publication receipt bound to that body and head.
#
# Firstmate and bin/fm-pr-check.sh run "verify" before reporting or monitoring.
# Verification fetches the public body again, repeats deterministic checks and
# evidence accessibility checks, and refuses body/head drift or a missing,
# malformed, or failed attestation receipt.
#
# Neither mode edits a PR. The original task worker remains correction owner and
# must update the body through the selected delivery path before attesting again.
#
# GitHub body readback uses gh-axi pr view --full and cross-checks it against one
# raw gh JSON snapshot containing the exact body and head; gh-axi's generic API
# view cannot bind them because it intentionally truncates long string fields.
# Ruby's YAML parser decodes the structured full view. GitLab readback uses
# glab's JSON output and requires jq so description, web_url, and sha are read
# without parsing presentation text.
#
# Usage:
#   fm-pr-publication-check.sh attest <task-id> <pr-url> \
#     --intent-outcome-complete \
#     --evidence <none-required|real-ui|nonvisual> \
#     [--evidence-url <exact-head repository URL>]...
#   fm-pr-publication-check.sh verify <task-id> <pr-url>
#   fm-pr-publication-check.sh --help
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

if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "error: task state directory is unavailable" >&2
  exit 1
fi
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

INTENT_ATTESTED=0
EVIDENCE_MODE=
EVIDENCE_URLS=()
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
elif [ "$#" -ne 0 ]; then
  echo "error: verify accepts no attestation arguments" >&2
  exit 2
fi

BODY_FILE=
SCAN_FILE=
FORGE_FILE=
AXI_FIELDS_FILE=
FIELDS_FILE=
RECEIPT_TMP=
INTENT_FILE=
OUTCOME_FILE=
cleanup() {
  [ -z "$BODY_FILE" ] || rm -f -- "$BODY_FILE"
  [ -z "$SCAN_FILE" ] || rm -f -- "$SCAN_FILE"
  [ -z "$FORGE_FILE" ] || rm -f -- "$FORGE_FILE"
  [ -z "$AXI_FIELDS_FILE" ] || rm -f -- "$AXI_FIELDS_FILE"
  [ -z "$FIELDS_FILE" ] || rm -f -- "$FIELDS_FILE"
  [ -z "$RECEIPT_TMP" ] || rm -f -- "$RECEIPT_TMP"
  [ -z "$INTENT_FILE" ] || rm -f -- "$INTENT_FILE"
  [ -z "$OUTCOME_FILE" ] || rm -f -- "$OUTCOME_FILE"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

umask 077
BODY_FILE=$(mktemp "$STATE/.fm-pr-publication-body.XXXXXX") || exit 1
SCAN_FILE=$(mktemp "$STATE/.fm-pr-publication-scan.XXXXXX") || exit 1
FORGE_FILE=$(mktemp "$STATE/.fm-pr-publication-forge.XXXXXX") || exit 1
AXI_FIELDS_FILE=$(mktemp "$STATE/.fm-pr-publication-axi-fields.XXXXXX") || exit 1
FIELDS_FILE=$(mktemp "$STATE/.fm-pr-publication-fields.XXXXXX") || exit 1

decode_base64_to_body() {
  local encoded=$1
  if printf '%s' "$encoded" | base64 --decode > "$BODY_FILE" 2>/dev/null; then
    return 0
  fi
  printf '%s' "$encoded" | base64 -D > "$BODY_FILE" 2>/dev/null
}

read_three_fields() {
  local file=$1 first second third extra
  exec 7< "$file" || return 1
  IFS= read -r first <&7 || { exec 7<&-; return 1; }
  IFS= read -r second <&7 || { exec 7<&-; return 1; }
  IFS= read -r third <&7 || { exec 7<&-; return 1; }
  if IFS= read -r extra <&7; then
    : "$extra"
    exec 7<&-
    return 1
  fi
  exec 7<&-
  FETCHED_URL=$first
  FETCHED_HEAD=$second
  FETCHED_BODY_BASE64=$third
}

fetch_github() {
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
  gh-axi pr view "$NUMBER" --full > "$FORGE_FILE" 2>/dev/null || {
    echo "error: could not fetch the complete GitHub PR body" >&2
    return 1
  }
  ruby -ryaml -rbase64 -e '
    view = YAML.safe_load(File.binread(ARGV[0]), permitted_classes: [], aliases: false)
    expected_number = Integer(ARGV[1], 10)
    view_pr = view.fetch("pull_request")
    abort unless Integer(view_pr.fetch("number").to_s, 10) == expected_number
    body = view_pr.fetch("body")
    abort unless body.is_a?(String)
    puts Base64.strict_encode64(body)
  ' "$FORGE_FILE" "$NUMBER" > "$AXI_FIELDS_FILE" 2>/dev/null || {
    echo "error: complete GitHub PR readback was incomplete or malformed" >&2
    return 1
  }
  AXI_BODY_BASE64=$(cat "$AXI_FIELDS_FILE")
  [ -n "$AXI_BODY_BASE64" ] && [ "$(wc -l < "$AXI_FIELDS_FILE" | tr -d '[:space:]')" = 1 ] || {
    echo "error: complete GitHub PR body could not be decoded exactly" >&2
    return 1
  }
  gh pr view "$URL" --json url,headRefOid,body \
    --jq '[.url,.headRefOid,(.body|@base64)] | .[]' > "$FIELDS_FILE" 2>/dev/null || {
    echo "error: could not fetch the complete GitHub PR body and head" >&2
    return 1
  }
  read_three_fields "$FIELDS_FILE" || {
    echo "error: GitHub PR readback was incomplete or malformed" >&2
    return 1
  }
  [ "$FETCHED_BODY_BASE64" = "$AXI_BODY_BASE64" ] || {
    echo "error: complete GitHub PR readbacks did not match" >&2
    return 1
  }
}

fetch_gitlab() {
  command -v glab >/dev/null 2>&1 || {
    echo "error: GitLab publication readback requires glab on PATH" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: GitLab publication readback requires jq for exact JSON fields" >&2
    return 1
  }
  glab mr view "$NUMBER" -R "https://$HOST/$PROJECT_PATH" -F json > "$FORGE_FILE" 2>/dev/null || {
    echo "error: could not fetch the complete GitLab MR body and head" >&2
    return 1
  }
  jq -er '[.web_url,.sha,((.description // "")|@base64)] | .[]' "$FORGE_FILE" \
    > "$FIELDS_FILE" 2>/dev/null || {
      echo "error: GitLab MR JSON lacks exact web_url, sha, or description fields" >&2
      return 1
    }
  read_three_fields "$FIELDS_FILE" || {
    echo "error: GitLab MR readback was incomplete or malformed" >&2
    return 1
  }
}

case "$PROVIDER" in
  github) fetch_github || exit 1 ;;
  gitlab) fetch_gitlab || exit 1 ;;
  *) echo "error: unsupported forge for PR publication checking" >&2; exit 1 ;;
esac

if [ "$FETCHED_URL" != "$URL" ] || ! fm_pr_head_valid "$FETCHED_HEAD"; then
  echo "error: forge readback did not match the exact PR identity and head" >&2
  exit 1
fi
decode_base64_to_body "$FETCHED_BODY_BASE64" || {
  echo "error: forge body bytes could not be decoded exactly" >&2
  exit 1
}

BODY_BYTES=$(wc -c < "$BODY_FILE" | tr -d '[:space:]')
BODY_SHA256=$(fm_pr_sha256 "$BODY_FILE") || {
  echo "error: could not hash the fetched PR body" >&2
  exit 1
}
[[ "$BODY_BYTES" =~ ^[0-9]+$ ]] && [[ "$BODY_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 1

# Remove public HTTP(S) URLs before local-path scanning so an ordinary URL path
# such as https://docs.example/home/user is not mistaken for a local home path.
sed -E 's#https?://[^[:space:])>]+##g' "$BODY_FILE" > "$SCAN_FILE" || exit 1

reject_match() {
  local category=$1 pattern=$2 file=${3:-$SCAN_FILE} match line
  match=$(grep -Eni -- "$pattern" "$file" 2>/dev/null | head -1 || true)
  [ -z "$match" ] && return 0
  line=${match%%:*}
  echo "error: PR publication check rejected $category at body line $line" >&2
  echo "error: the responsible task worker must correct the public body through its selected delivery path and attest again" >&2
  return 1
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

INTENT_FILE=$(mktemp "$STATE/.fm-pr-publication-intent.XXXXXX") || exit 1
OUTCOME_FILE=$(mktemp "$STATE/.fm-pr-publication-outcome.XXXXXX") || exit 1

extract_section intent "$INTENT_FILE" || {
  echo "error: PR body must contain a reviewer-facing ## Intent section" >&2
  exit 1
}
extract_section outcome "$OUTCOME_FILE" || {
  echo "error: PR body must contain a reviewer-facing ## What Changed, ## Outcome, ## Result, or ## Changes section" >&2
  exit 1
}
if ! grep -q '[^[:space:]]' "$INTENT_FILE" || ! grep -q '[^[:space:]]' "$OUTCOME_FILE"; then
  echo "error: PR intent and outcome sections must both contain reviewer-facing content" >&2
  exit 1
fi
reject_match "operational rather than PR-level intent framing" '(successor|current)[[:space:]_-]+(run|task|attempt)|latest[[:space:]_-]+commit|last[[:space:]_-]+commit|this[[:space:]_-]+round|recovered[[:space:]_-]+branch|captain([^A-Za-z]+s)?[[:space:]]+(authorization|approval)|authorized[[:space:]]+by[[:space:]]+(the[[:space:]]+)?captain' || exit 1

verify_evidence_url() {
  local evidence_url=$1 base evidence_path fragment encoded_project encoded_path
  grep -Fq -- "$evidence_url" "$BODY_FILE" || {
    echo "error: declared evidence URL is absent from the fetched public body" >&2
    return 1
  }
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
      command -v gh-axi >/dev/null 2>&1 || {
        echo "error: GitHub evidence verification requires gh-axi on PATH" >&2
        return 1
      }
      gh-axi api HEAD "/repos/$PROJECT_PATH/contents/$evidence_path?ref=$FETCHED_HEAD" >/dev/null 2>&1 || {
        echo "error: GitHub evidence is not authenticated-accessible at the exact PR head" >&2
        return 1
      }
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
      if [ "$EVIDENCE_MODE" = real-ui ]; then
        case "$evidence_path" in
          *[Ii]llustration*|*[Mm]ockup*|*[Cc]oncept*|*[Gg]enerated*|*[Aa][Ii]-[Ii]mage*)
            echo "error: a custom illustration or mockup cannot attest real UI behavior" >&2
            return 1
            ;;
        esac
      fi
      encoded_project=$(jq -rn --arg value "$PROJECT_PATH" '$value|@uri') || return 1
      encoded_path=$(jq -rn --arg value "$evidence_path" '$value|@uri') || return 1
      glab api --hostname "$HOST" "projects/$encoded_project/repository/files/$encoded_path?ref=$FETCHED_HEAD" >/dev/null 2>&1 || {
        echo "error: GitLab evidence is not authenticated-accessible at the exact MR head" >&2
        return 1
      }
      ;;
  esac
}

RECEIPT_MODE=
RECEIPT_URLS=()
parse_receipt() {
  local file=$1 line expected_count index=0
  local version task_id provider url head body_bytes body_sha privacy links attestation evidence_mode evidence_count
  exec 8< "$file" || return 1
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

if [ "$ACTION" = verify ]; then
  STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
  fm_pr_private_file_valid "$RECEIPT" 600 "$STATE_DEVICE" || {
    echo "error: a private PR publication attestation receipt is required before readiness or monitoring" >&2
    exit 1
  }
  parse_receipt "$RECEIPT" || {
    echo "error: PR publication receipt is malformed or does not match the fresh public body and head" >&2
    exit 1
  }
  EVIDENCE_MODE=$RECEIPT_MODE
  EVIDENCE_URLS=()
  for encoded_url in "${RECEIPT_URLS[@]+"${RECEIPT_URLS[@]}"}"; do
    decode_target=$(mktemp "$STATE/.fm-pr-publication-url.XXXXXX") || exit 1
    if ! { printf '%s' "$encoded_url" | base64 --decode > "$decode_target" 2>/dev/null \
      || printf '%s' "$encoded_url" | base64 -D > "$decode_target" 2>/dev/null; }; then
      rm -f -- "$decode_target"
      echo "error: PR publication receipt contains malformed evidence data" >&2
      exit 1
    fi
    decoded_url=$(cat "$decode_target")
    rm -f -- "$decode_target"
    [ -n "$decoded_url" ] || exit 1
    EVIDENCE_URLS+=("$decoded_url")
  done
fi

for evidence_url in "${EVIDENCE_URLS[@]+"${EVIDENCE_URLS[@]}"}"; do
  verify_evidence_url "$evidence_url" || exit 1
done

if [ "$ACTION" = attest ]; then
  STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
  fm_pr_regular_destination_on_device_or_absent "$RECEIPT" "$STATE_DEVICE" || {
    echo "error: PR publication receipt destination is unsafe" >&2
    exit 1
  }
  RECEIPT_TMP=$(mktemp "$STATE/.fm-pr-publication-receipt.XXXXXX") || exit 1
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
  printf 'attested %s %s %s\n' "$FETCHED_HEAD" "$BODY_BYTES" "$BODY_SHA256"
else
  printf 'verified %s %s %s\n' "$FETCHED_HEAD" "$BODY_BYTES" "$BODY_SHA256"
fi
