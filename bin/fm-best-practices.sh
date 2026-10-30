#!/usr/bin/env bash
# fm-best-practices.sh - best-practices pack adapters: the catalog, the
# manifest check, the per-harness pack read, the add-time pack check, the
# spawn's version read, the brief's practice section, and routing through the
# typed-decision provider.
#
# Usage:
#   fm-best-practices.sh adapters
#   fm-best-practices.sh manifest-check [<owner>/<repo>]
#   fm-best-practices.sh read <owner>/<repo> --harness <name> --project <dir>
#   fm-best-practices.sh check <owner>/<repo> --harness <name> --project <dir>
#   fm-best-practices.sh version <owner>/<repo> --harness <name> --project <dir>
#   fm-best-practices.sh propose <project-dir>
#   fm-best-practices.sh fingerprints <owner>/<repo> [--source <tag>=<dir>]... [--write]
#   fm-best-practices.sh practice <owner>/<repo> --kind ship|scout [--mode <mode>] [--forge <forge>]
#   fm-best-practices.sh route <brief-file> [--project <name>]
#   fm-best-practices.sh intake <owner>/<repo> <ask-file> [--project <name>]
#
# adapters        the repositories this firstmate carries an adapter for, one
#                 per line, from the router skill's routing object.
# manifest-check  check one adapter, or every carried adapter, against the
#                 eleven flow positions: refuses any facet, position, or
#                 routing row outside them, a flow that moves start or report
#                 or places a step before start or after report, a replace or
#                 pair at start or report, a launch.env other than the two
#                 exports firstmate writes, a supported version that is not a
#                 tag, and a routing object that disagrees with the manifest.
#                 Prints one line per defect; exit 1 when any.
# read            what the harness's own registry or skills directory says about
#                 the pack for that project, as one JSON object: installed,
#                 enabled, enabled_source (user or project), version, id, where,
#                 supported (the harness is inside the adapter's runtime list),
#                 and proof (whether firstmate's read for it is proven live).
#                 Read-only; committed files are read from the checkout given,
#                 and a worker copy's path maps back to its clone only to
#                 identify a project-scope install.
# check           project-add step 8: the crew runtime is one both firstmate and
#                 the pack support, firstmate's read for it is proven live, and
#                 the pack is installed and enabled as a worker copy will see
#                 it. Prints status ok with the reviewed tag its content
#                 matches; status unreviewed, a fact rather than a refusal,
#                 naming the skills whose files match no reviewed text and the
#                 runtime's own label; or one problem with what was found and
#                 its remedy, exit 1. It never installs or enables anything.
# version         the spawn's read, one of three values: the reviewed tag the
#                 copy's content matches; "unreviewed: <skills and label>" for
#                 a loaded copy whose depended-on files match no reviewed text;
#                 or "missing: <why>" when there is no usable copy (not
#                 installed, disabled, the runtime outside the adapter's list,
#                 or a read not yet proven live). Exit 0 either way.
# propose         project-add step 4: proposes best-practices=<owner>/<repo>
#                 only when a carried pack is installed and enabled by what the
#                 project itself commits; a pack only installed on the machine,
#                 or enabled only in user settings, proposes nothing. Prints
#                 "propose: none" and the carried repositories otherwise.
# fingerprints    generate the manifest's fingerprints, never by hand: for each
#                 supported tag, a shallow clone of that tag of the pack's
#                 repository (its commit checked against the manifest), or the
#                 checkout --source names, and the SHA-256 of each SKILL.md the
#                 adapter's references name, line endings normalized to LF.
#                 Prints the JSON, or writes it into the manifest with --write.
# practice        the brief's practice section with no routing: the adapter's
#                 static behavior, its full table. bin/fm-brief.sh writes this.
# route           re-compose a filled brief's practice section through routing:
#                 rows read from facts (kind, mode, forge) are read in code, the
#                 Captain's intent's own words named by a row win in code, and
#                 every other row of the brief's composition goes to the typed-
#                 decision provider in ONE request carrying the brief's task
#                 sections as state. A confident answer narrows what is
#                 composed; low confidence, no key, a never-send match, an
#                 error, or a timeout keeps the row's fallback, the static
#                 behavior. Rewrites only the practice section, in place.
# intake          route an ask at intake.question: the captain's own words in
#                 <ask-file> win in code, and the rest go to the provider in one
#                 request. Prints each row's value and where it came from.
#
# route and intake print a "best-practices-route:" or "best-practices-intake:"
# block on stdout and exit 0 on every outcome, as bin/fm-dispatch-resolve.sh
# does; only a usage or configuration error exits 2. They share that tool's
# provider code (bin/fm-decision-provider-lib.sh): FM_DISPATCH_PROVIDER,
# FM_DISPATCH_MODEL, FM_DISPATCH_BASE_URL, FM_DISPATCH_API_KEY,
# TYPESAFE_API_KEY, OPENROUTER_API_KEY, OPENAI_API_KEY, and
# config/dispatch-never-send mean exactly what docs/configuration.md "Typed
# dispatch resolution" says, and the key never reaches argv or a child. Routing
# sends the System One request shape, so it works with typesafe, openrouter,
# and systemone, and with openai it sends nothing and composes the static text.
#
# docs/best-practices-adapters.md owns the architecture, the facets and
# positions, and the off-limits list; bin/fm-best-practices-lib.sh owns the
# mechanics.
set -u

# The provider keys leave the public environment before any child process
# exists (bin/fm-decision-provider-lib.sh).
TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset OPENROUTER_API_KEY
OPENAI_API_KEY_PRIVATE=${OPENAI_API_KEY:-}
export -n OPENAI_API_KEY_PRIVATE 2>/dev/null || true
unset OPENAI_API_KEY
DISPATCH_API_KEY_PRIVATE=${FM_DISPATCH_API_KEY:-}
export -n DISPATCH_API_KEY_PRIVATE 2>/dev/null || true
unset FM_DISPATCH_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-decision-provider-lib.sh
. "$SCRIPT_DIR/fm-decision-provider-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-best-practices-lib.sh
. "$SCRIPT_DIR/fm-best-practices-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

command -v jq >/dev/null 2>&1 || die "jq required"

known_or_die() {  # <owner/repo>
  fm_bp_known "$1" || die "this firstmate carries no adapter for '$1'; it carries: $(fm_bp_adapter_list_words)"
}

# ---- argument parsing for the read-family commands ---------------------------------
HARNESS='' PROJECT_DIR=''
parse_read_args() {  # <command> <args...>
  local cmd=$1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) [ $# -ge 2 ] || die "--harness needs a value"; HARNESS=$2; shift 2 ;;
      --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT_DIR=$2; shift 2 ;;
      *) die "$cmd: unknown argument $1" ;;
    esac
  done
  [ -n "$HARNESS" ] || die "$cmd needs --harness <name>"
  [ -n "$PROJECT_DIR" ] || die "$cmd needs --project <dir>"
  [ -d "$PROJECT_DIR" ] || die "$cmd: project directory not found: $PROJECT_DIR"
}

proven_harnesses() {  # <owner/repo>
  jq -r '[.harnesses | to_entries[] | select(.value.proof.status == "proven") | .key] | join(", ")' "$(fm_bp_manifest "$1")"
}

cmd_check() {
  local repo=$1 r problem='' found remedy='' install enable tags reason
  r=$(fm_bp_read "$repo" "$HARNESS" "$PROJECT_DIR")
  field() { jq -r --arg k "$1" '.[$k] // empty | tostring' <<<"$r"; }
  found=$(field where)
  install=$(jq -r --arg h "$HARNESS" '.harnesses[$h].install // empty' "$(fm_bp_manifest "$repo")")
  enable=$(jq -r --arg h "$HARNESS" '.harnesses[$h].enable // empty' "$(fm_bp_manifest "$repo")")
  tags=$(jq -r '.versions | map(.tag) | join(", ")' "$(fm_bp_manifest "$repo")")
  if [ "$(field supported)" != true ]; then
    problem='runtime-unsupported'
    remedy="the crew runtime $HARNESS is not one both firstmate and the pack support; the harnesses both support are $(jq -r '.supported_harnesses | join(", ")' <<<"$r"); dispatch this project on one of them or drop the token"
  elif [ "$(field proof)" != proven ]; then
    problem='read-unproven'
    reason=$(field proof_reason)
    remedy="firstmate's read of $HARNESS is not yet proven live ($reason), so the adapter cannot confirm the pack; harnesses with a proven read: $(proven_harnesses "$repo")"
  elif [ "$(field installed)" != true ]; then
    problem='not-installed'
    remedy="install it: $install"
  elif [ "$(field enabled)" != true ]; then
    problem='not-enabled'
    remedy="enable it where it is disabled${enable:+: $enable}"
  fi
  printf 'best-practices-check:\n'
  printf '  repository: %s\n  harness: %s\n  project: %s\n' "$repo" "$HARNESS" "$(fm_bp_project_root "$PROJECT_DIR")"
  if [ -z "$problem" ] && [ "$(field version)" = unreviewed ]; then
    # A fact, never a refusal: the pack is loaded and the adapter applies.
    printf '  status: unreviewed\n  found: %s\n  unreviewed: %s\n  supported: %s\n' "$found" "$(unreviewed_detail "$r")" "$tags"
    return 0
  fi
  if [ -z "$problem" ]; then
    printf '  status: ok\n  found: %s, version %s\n' "$found" "$(field version)"
    return 0
  fi
  printf '  status: problem\n  problem: %s\n  found: %s\n  remedy: %s\n' "$problem" "$found" "$remedy"
  return 1
}

# One sentence naming what an unreviewed copy differs in, against the
# reviewed tag, with the runtime's own label as a hint.
unreviewed_detail() {  # <read-json>
  jq -r '.fingerprint as $f
    | ([if ($f.differing | length) > 0 then "\($f.differing | join(", ")) \(if ($f.differing | length) == 1 then "differs" else "differ" end) from" else empty end,
        if ($f.missing | length) > 0 then "\($f.missing | join(", ")) \(if ($f.missing | length) == 1 then "is" else "are" end) absent from" else empty end] | join(" and "))
      + " the reviewed \($f.tag) text"
      + (if $f.label != null then " (runtime label \($f.label))" else "" end)' <<<"$1"
}

cmd_version() {
  local repo=$1 r
  r=$(fm_bp_read "$repo" "$HARNESS" "$PROJECT_DIR")
  if [ "$(jq -r '.supported == true and .proof == "proven" and .installed == true and .enabled == true and .version == "unreviewed"' <<<"$r")" = true ]; then
    printf 'unreviewed: %s\n' "$(unreviewed_detail "$r")"
    return 0
  fi
  jq -r '
    if .supported != true then "missing: \(.where); the pack has no install path firstmate can read for \(.harness)"
    elif .proof != "proven" then "missing: firstmate'"'"'s read of \(.harness) is not yet proven live, so the pack cannot be confirmed loaded"
    elif .installed == true and .enabled == true then .version
    elif .installed != true then "missing: not installed; \(.where)"
    else "missing: installed but not enabled; \(.where)" end' <<<"$r"
}

# Generate the fingerprints from each supported tag's own release: a shallow
# clone of the tag (or a --source checkout), the tag's commit checked against
# the manifest, and the normalized SHA-256 of each named skill's SKILL.md.
cmd_fingerprints() {
  local repo=$1 write=$2 manifest named tags tag src commit head s h out='{}' tmp fp
  shift 2
  manifest=$(fm_bp_manifest "$repo")
  named=$(fm_bp_named_skills "$manifest" | jq -Rnc '[inputs]')
  [ "$(jq 'length' <<<"$named")" -gt 0 ] || die "the adapter's references name none of the pack's skills"
  tags=$(jq -r '.versions[].tag' "$manifest")
  tmp=$(mktemp -d) || die "mktemp failed"
  ROUTE_TMP=$tmp
  trap route_cleanup EXIT
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    src=''
    for s in "$@"; do
      case "$s" in "$tag="*) src=${s#"$tag="} ;; esac
    done
    if [ -z "$src" ]; then
      src="$tmp/$tag"
      git clone -q --depth 1 --branch "$tag" "https://github.com/$repo.git" "$src" 2>/dev/null ||
        die "could not fetch tag $tag of https://github.com/$repo"
      commit=$(jq -r --arg t "$tag" '.versions[] | select(.tag == $t) | .commit // empty' "$manifest")
      head=$(git -C "$src" rev-parse HEAD)
      case "$head" in
        "$commit"*) ;;
        *) die "tag $tag of $repo is commit $head, not the commit $commit the manifest records" ;;
      esac
    fi
    while IFS= read -r s; do
      [ -f "$src/skills/$s/SKILL.md" ] || die "tag $tag carries no skills/$s/SKILL.md"
      h=$(fm_bp_hash < "$src/skills/$s/SKILL.md")
      out=$(jq -c --arg t "$tag" --arg k "$s" --arg v "$h" '.[$t] += {($k): $v}' <<<"$out")
    done < <(jq -r '.[]' <<<"$named")
  done <<<"$tags"
  fp=$(jq -n --argjson skills "$named" --argjson tags "$out" '{skills: $skills, tags: $tags}')
  if [ "$write" -eq 1 ]; then
    jq --argjson fp "$fp" '.fingerprints = $fp' "$manifest" > "$tmp/manifest.json" || die "could not write $manifest"
    mv "$tmp/manifest.json" "$manifest" || die "could not write $manifest"
    echo "fingerprints: wrote $(jq '.skills | length' <<<"$fp") skills for $(jq -r '.tags | keys | join(", ")' <<<"$fp") into $manifest"
  else
    jq . <<<"$fp"
  fi
}

cmd_propose() {
  local project=$1 repo h r reason proposals=''
  [ -d "$project" ] || die "propose: project directory not found: $project"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    # Codex and Antigravity record user-level state only, which never proposes.
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      r=$(fm_bp_read "$repo" "$h" "$project")
      [ "$(jq -r '.installed == true and .enabled == true and .enabled_source == "project"' <<<"$r")" = true ] || continue
      reason="$h: $(jq -r '.where' <<<"$r")"
      [ "$(jq -r '.proof' <<<"$r")" = proven ] || reason="$reason; firstmate's read of $h is not yet proven live"
      proposals="$proposals  propose: best-practices=$repo ($reason)"$'\n'
      break
    done < <(jq -r '.harnesses | to_entries[] | select(.value.read == "claude-plugin" or .value.read == "omp-plugin" or .value.read == "skills-dir") | .key' "$(fm_bp_manifest "$repo")")
  done < <(fm_bp_adapters)
  printf 'best-practices-propose:\n  project: %s\n' "$(fm_bp_project_root "$project")"
  if [ -n "$proposals" ]; then
    printf '%s' "$proposals"
  else
    printf '  propose: none\n  carried: %s\n' "$(fm_bp_adapter_list_words)"
  fi
}

# ---- routing ----------------------------------------------------------------------

ROUTE_LABEL=''
ROUTE_TMP=''
route_cleanup() { [ -z "$ROUTE_TMP" ] || rm -rf "$ROUTE_TMP"; }

# Evaluate the provider's answers for <rows-json> into
# {"<row>": {"value": ..., "source": ...}}, or fail when the response does not
# answer every row in the shape its type requires.
route_answers() {  # <rows-json> <response-file>
  jq -ec --argjson rows "$1" --arg floor "$FM_BP_CONFIDENCE_FLOOR" '
    . as $resp
    | ($floor | tonumber) as $global
    | def floor($r): ($r.min_confidence // $global);
      def opts($r): (($r.options | keys) + ["none"] | sort);
      def valid($r; $a):
        if $r.type == "noul" then ($a.noul | type) == "number" and $a.noul >= 0 and $a.noul <= 1
        else ($a.choice | type) == "string" and (opts($r) | index($a.choice)) != null
          and ($a.confidence | type) == "number" and $a.confidence >= 0 and $a.confidence <= 1
          and ($a.probabilities | type) == "object" and (($a.probabilities | keys | sort) == opts($r))
          and all($a.probabilities[]; type == "number" and . >= 0 and . <= 1)
          and (([$a.probabilities[]] | add) as $t | $t >= 0.99 and $t <= 1.01)
        end;
    if all($rows[]; valid(.; $resp.answers[.id])) | not then error("response does not answer every row")
    else
      [ $rows[] | . as $r | ($resp.answers[$r.id]) as $a
        | {key: $r.id, value: (
            if $r.type == "noul" then
              ($a.noul) as $p
              | if $p >= floor($r) then {value: true, source: "routed p=\($p)"}
                elif $p <= (1 - floor($r)) then {value: false, source: "routed p=\($p)"}
                else {value: $r.fallback, source: "fallback: p=\($p) is inside the \(floor($r)) floor"} end
            else
              ($a.choice) as $c
              | (if ($r | has("min_confidence")) then
                   (if $a.probabilities[$c] >= $r.min_confidence then {pick: $c}
                    else ([$a.probabilities | to_entries[] | select(.key != $c and .value >= $r.min_confidence)] | sort_by(-.value)) as $ok
                      | if ($ok | length) == 0 then {pick: null, why: "no option clears \($r.min_confidence)"}
                        elif ($ok | length) > 1 and $ok[0].value == $ok[1].value then {pick: null, why: "runner-up tie"}
                        else {pick: $ok[0].key, runner: true} end
                    end)
                 elif $a.confidence >= $global then {pick: $c}
                 else {pick: null, why: "confidence \($a.confidence) below \($global)"} end) as $g
              | if $g.pick == null then {value: $r.fallback, source: "fallback: \($g.why)"}
                elif $g.pick == "none" then {value: $r.fallback, source: "fallback: no listed option applies"}
                else {value: $g.pick, source: "routed \(if $g.runner then "runner-up " else "" end)confidence \($a.confidence)"} end
            end)} ]
      | from_entries
    end' "$2" 2>/dev/null
}

# Ask the provider every row in <rows-json> in one request with <state-json>.
# Prints the answers object on stdout, or nothing when routing is off or
# failed, with ROUTE_STATUS and ROUTE_REASON set and the evidence lines in
# ROUTE_EVIDENCE.
ROUTE_STATUS='' ROUTE_REASON='' ROUTE_EVIDENCE=''
route_ask() {  # <rows-json> <state-json> <subject> -> sets ROUTE_ANSWERS
  local rows=$1 state=$2 subject=$3 request gate_rc=0 err_file
  ROUTE_ANSWERS='{}'
  if [ "$(jq 'length' <<<"$rows")" -eq 0 ]; then
    ROUTE_STATUS=static ROUTE_REASON="no row needs routing"
    return 0
  fi
  err_file="$ROUTE_TMP/gate.err"
  fm_decision_gate "$ROUTE_LABEL" "$FM_HOME" 2>"$err_file" || gate_rc=$?
  case "$gate_rc" in
    0) ;;
    1) ROUTE_STATUS=off ROUTE_REASON=$(sed -n "s/^$ROUTE_LABEL: off (\(.*\))\$/\1/p" "$err_file" | head -n 1); cat "$err_file" >&2; return 0 ;;
    *) die "$FM_DECISION_ERROR" ;;
  esac
  # Routing asks several Choice and Noul questions in the System One shape;
  # OpenAI's Decisions API takes another shape, which only the dispatch
  # resolver's single Choice is mapped to, so routing sends nothing there.
  if [ "$FM_DECISION_PROVIDER" = openai ]; then
    ROUTE_STATUS=off ROUTE_REASON="adapter routing speaks the System One request shape, which FM_DISPATCH_PROVIDER=openai does not take; nothing sent"
    echo "$ROUTE_LABEL: off ($ROUTE_REASON)" >&2
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { ROUTE_STATUS=error ROUTE_REASON="curl not installed"; return 0; }
  request=$(jq -n --arg model "$FM_DECISION_MODEL" --argjson state "$state" --argjson rows "$rows" '
    {model: $model, state: $state,
     questions: ($rows | map({key: .id, value: (
       if .type == "noul" then {type: "noul", instructions: .instructions}
       else {type: "choice", instructions: .instructions,
             criteria: (.options + {none: "None of the listed options applies."})} end)}) | from_entries)}')
  if ! fm_decision_never_send "$ROUTE_LABEL" "$subject" "$request" "$CONFIG/dispatch-never-send" "$ROUTE_TMP/send.txt" 2>"$err_file"; then
    ROUTE_STATUS=off ROUTE_REASON=$(sed -n "s/^$ROUTE_LABEL: off (\(.*\))\$/\1/p" "$err_file" | head -n 1)
    cat "$err_file" >&2
    return 0
  fi
  fm_decision_post "$request" "$ROUTE_TMP/response.json"
  if [ "$FM_DECISION_HTTP" != 200 ]; then
    ROUTE_STATUS=error ROUTE_REASON=$(fm_decision_http_reason "$ROUTE_TMP/response.json")
    echo "$ROUTE_LABEL: error ($ROUTE_REASON)" >&2
    return 0
  fi
  if ! ROUTE_ANSWERS=$(route_answers "$rows" "$ROUTE_TMP/response.json"); then
    ROUTE_ANSWERS='{}'
    ROUTE_STATUS=error ROUTE_REASON="response does not answer every row in its type's shape"
    echo "$ROUTE_LABEL: error ($ROUTE_REASON)" >&2
    return 0
  fi
  ROUTE_STATUS=routed ROUTE_REASON=''
  ROUTE_EVIDENCE=$(jq -r --argjson lat "$FM_DECISION_LAT_MS" '
    def show($v): ($v // "-") | tostring | gsub("[\t\r\n]"; " ");
    "  model: \(show(.model))   latency_ms: \($lat)   tokens: \(show(.usage.input_tokens))/\(show(.usage.output_tokens))"' "$ROUTE_TMP/response.json")
}

# Rows whose value comes from the requester's own words, matched in code,
# case-insensitively and as whole words, in <text>; the first phrase found wins.
route_words() {  # <rows-json> <text>
  jq -c --arg text "$2" '
    ($text | ascii_downcase) as $t
    | [ .[] | . as $r
        | ([($r.words // {}) | to_entries[] | select((.key | ascii_downcase | gsub("(?<c>[^[:alnum:] ])"; "\\\(.c)")) as $k | $t | test("(?<!\\w)\($k)(?!\\w)"))] | first) as $w
        | select($w != null)
        | {key: $r.id, value: {value: $w.value, source: "words \"\($w.key)\""}} ]
    | from_entries' <<<"$1"
}

print_rows() {  # <values-json>
  jq -r 'to_entries[] | "  row: \(.key) = \(.value.value | tostring) (\(.value.source))"' <<<"$1"
}

cmd_route() {
  local brief=$1 project=$2 contract repo kind mode forge manifest intent sections rows words ask_rows state values new_file out_file
  [ -r "$brief" ] || die "brief file not readable: $brief"
  ROUTE_LABEL='best-practices-route'
  contract=$(grep -m 1 '^Delivery contract: ' "$brief" || true)
  repo=$(printf '%s\n' "$contract" | sed -n 's/^Delivery contract: .*[[:space:]]best-practices=\([^ ]*\).*$/\1/p')
  if [ -z "$repo" ]; then
    printf '%s:\n  status: off\n  reason: the brief registers no best-practices pack\n' "$ROUTE_LABEL"
    return 0
  fi
  known_or_die "$repo"
  fm_brief_heading_present "$brief" "# Best practices: $repo" || die "$brief has no '# Best practices: $repo' section; re-scaffold it with bin/fm-brief.sh --best-practices $repo"
  case "$contract" in
    *' kind=scout'*) kind=scout mode='' ;;
    'Delivery contract: mode='*) kind=ship mode=$(printf '%s\n' "$contract" | sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p') ;;
    *) die "$brief carries a Delivery contract line naming neither a ship mode nor kind=scout" ;;
  esac
  forge=$(printf '%s\n' "$contract" | sed -n 's/^Delivery contract: .*[[:space:]]forge=\([^ ]*\).*$/\1/p')
  [ -n "$forge" ] || forge=none
  manifest=$(fm_bp_manifest "$repo")
  intent=$(fm_brief_task_heading_body "$brief" "## Captain's intent")
  sections=$(for h in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$brief" "$h" || continue
    printf '%s\n%s\n\n' "$h" "$(fm_brief_task_heading_body "$brief" "$h")"
  done)
  [ "$kind" = scout ] && sections="Brief kind: scout (report only)"$'\n\n'"$sections"
  # The noul and choice rows this composition applies: rows of a worker-side
  # facet or insert that composes for this kind, whose gate passes.
  rows=$(jq -c --arg kind "$kind" --arg mode "$mode" --arg forge "$forge" --arg wt "$FM_BP_WORKER_TARGETS" '
    . as $m
    | {kind: $kind, mode: $mode, forge: $forge} as $facts
    | ([($wt | split(" "))[] | select((($m.facets[.] // null) != null) and ((($m.facets[.].kinds // []) | index($kind)) != null))]
       + [($m.insert // [])[] | select(.side == "worker" and ((.kinds // []) | index($kind)) != null) | .id]) as $live
    | [($m.routing // [])[] | select(.type != "fact" and (.facet as $fc | $live | index($fc)) != null)
       | select(all((.gate // {}) | to_entries[]; $facts[.key] as $fact | (.value | index($fact)) != null))]' "$manifest")
  words=$(route_words "$rows" "$intent")
  ask_rows=$(jq -c --argjson words "$words" '[.[] | select(.id as $i | $words | has($i) | not)]' <<<"$rows")
  state=$(jq -n --arg project "$project" --arg brief "$sections" '{task: {project: $project, brief: $brief}}')
  ROUTE_TMP=$(mktemp -d) || die "mktemp failed"
  trap route_cleanup EXIT
  route_ask "$ask_rows" "$state" "brief text"
  values=$(jq -c --argjson words "$words" '. + $words' <<<"$ROUTE_ANSWERS")
  new_file="$ROUTE_TMP/section.md"
  fm_bp_compose "$repo" "$kind" "$mode" "$forge" "$values" > "$new_file" || die "could not compose the practice section for $repo"
  out_file="$(dirname "$brief")/.$(basename "$brief").route.$$"
  fm_brief_heading_replace "$brief" "# Best practices: $repo" "$new_file" > "$out_file" || { rm -f "$out_file"; die "could not rewrite $brief"; }
  mv "$out_file" "$brief" || { rm -f "$out_file"; die "could not rewrite $brief"; }
  printf '%s:\n  status: %s\n  repository: %s\n' "$ROUTE_LABEL" "$ROUTE_STATUS" "$repo"
  [ -z "$ROUTE_REASON" ] || printf '  reason: %s\n' "$ROUTE_REASON"
  [ -z "$ROUTE_EVIDENCE" ] || printf '%s\n' "$ROUTE_EVIDENCE"
  print_rows "$(fm_bp_row_values "$manifest" "$kind" "$mode" "$forge" "$values")"
  printf '  section: recomposed in %s\n' "$brief"
}

cmd_intake() {
  local repo=$1 ask_file=$2 project=$3 manifest ask rows words ask_rows state values
  known_or_die "$repo"
  [ -r "$ask_file" ] || die "ask file not readable: $ask_file"
  ROUTE_LABEL='best-practices-intake'
  manifest=$(fm_bp_manifest "$repo")
  ask=$(cat "$ask_file")
  rows=$(jq -c '[(.routing // [])[] | select(.facet == "intake.question" and .type != "fact")]' "$manifest")
  words=$(route_words "$rows" "$ask")
  ask_rows=$(jq -c --argjson words "$words" '[.[] | select(.id as $i | $words | has($i) | not)]' <<<"$rows")
  state=$(jq -n --arg project "$project" --arg ask "$ask" '{task: {project: $project, ask: $ask}}')
  ROUTE_TMP=$(mktemp -d) || die "mktemp failed"
  trap route_cleanup EXIT
  route_ask "$ask_rows" "$state" "ask text"
  values=$(jq -c --argjson words "$words" --argjson rows "$rows" --argjson answers "$ROUTE_ANSWERS" '
    ([$rows[] | {key: .id, value: {value: .fallback, source: "fallback"}}] | from_entries) + $answers + $words' <<<'null')
  printf '%s:\n  status: %s\n  repository: %s\n' "$ROUTE_LABEL" "$ROUTE_STATUS" "$repo"
  [ -z "$ROUTE_REASON" ] || printf '  reason: %s\n' "$ROUTE_REASON"
  [ -z "$ROUTE_EVIDENCE" ] || printf '%s\n' "$ROUTE_EVIDENCE"
  print_rows "$values"
  printf '  reference: %s\n' "$(fm_bp_skill_dir)/$(fm_bp_routing_json | jq -r --arg r "$repo" '.packs[$r].facets["intake.question"].reference // empty')"
}

# ---- dispatch ----------------------------------------------------------------------

CMD=${1:-}
[ $# -eq 0 ] || shift
case "$CMD" in
  -h|--help|'') usage; [ -n "$CMD" ] || exit 2; exit 0 ;;
  adapters)
    [ $# -eq 0 ] || die "adapters takes no arguments"
    fm_bp_adapters
    ;;
  manifest-check)
    rc=0
    if [ $# -ge 1 ]; then
      fm_bp_manifest_check "$1" || rc=1
    else
      while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        fm_bp_manifest_check "$repo" || rc=1
      done < <(fm_bp_adapters)
    fi
    [ "$rc" -ne 0 ] || echo "manifest-check: ok"
    exit "$rc"
    ;;
  read|check|version)
    [ $# -ge 1 ] || die "$CMD needs <owner>/<repo>"
    REPO=$1
    shift
    known_or_die "$REPO"
    parse_read_args "$CMD" "$@"
    case "$CMD" in
      read) fm_bp_read "$REPO" "$HARNESS" "$PROJECT_DIR" | jq . ;;
      check) cmd_check "$REPO" || exit 1 ;;
      version) cmd_version "$REPO" ;;
    esac
    ;;
  propose)
    [ $# -eq 1 ] || die "propose needs exactly <project-dir>"
    cmd_propose "$1"
    ;;
  fingerprints)
    [ $# -ge 1 ] || die "fingerprints needs <owner>/<repo>"
    REPO=$1
    shift
    known_or_die "$REPO"
    WRITE=0
    SOURCES=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --write) WRITE=1; shift ;;
        --source) [ $# -ge 2 ] || die "--source needs <tag>=<dir>"; SOURCES+=("$2"); shift 2 ;;
        *) die "fingerprints: unknown argument $1" ;;
      esac
    done
    cmd_fingerprints "$REPO" "$WRITE" ${SOURCES[@]+"${SOURCES[@]}"}
    ;;
  practice)
    [ $# -ge 1 ] || die "practice needs <owner>/<repo>"
    REPO=$1
    shift
    known_or_die "$REPO"
    KIND='' MODE='' FORGE=none
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) [ $# -ge 2 ] || die "--kind needs a value"; KIND=$2; shift 2 ;;
        --mode) [ $# -ge 2 ] || die "--mode needs a value"; MODE=$2; shift 2 ;;
        --forge) [ $# -ge 2 ] || die "--forge needs a value"; FORGE=$2; shift 2 ;;
        *) die "practice: unknown argument $1" ;;
      esac
    done
    case "$KIND" in ship|scout) ;; *) die "practice needs --kind ship or --kind scout" ;; esac
    fm_bp_compose "$REPO" "$KIND" "$MODE" "$FORGE"
    ;;
  route)
    [ $# -ge 1 ] || die "route needs <brief-file>"
    BRIEF_FILE=$1
    shift
    ROUTE_PROJECT=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) [ $# -ge 2 ] || die "--project needs a value"; ROUTE_PROJECT=$2; shift 2 ;;
        *) die "route: unknown argument $1" ;;
      esac
    done
    cmd_route "$BRIEF_FILE" "$ROUTE_PROJECT"
    ;;
  intake)
    [ $# -ge 2 ] || die "intake needs <owner>/<repo> <ask-file>"
    REPO=$1 ASK_FILE=$2
    shift 2
    ROUTE_PROJECT=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) [ $# -ge 2 ] || die "--project needs a value"; ROUTE_PROJECT=$2; shift 2 ;;
        *) die "intake: unknown argument $1" ;;
      esac
    done
    cmd_intake "$REPO" "$ASK_FILE" "$ROUTE_PROJECT"
    ;;
  *) die "unknown command '$CMD' (see --help)" ;;
esac
