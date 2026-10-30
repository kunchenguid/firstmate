# shellcheck shell=bash
# Best-practices adapter mechanics.
# Usage: . bin/fm-best-practices-lib.sh   (the caller defines FM_ROOT; jq required)
#
# This file is the single owner of the closed sets an adapter is checked
# against (the eight facets, the worker positions, and the firstmate-side
# positions that make up the eleven-position flow), of the manifest check, of
# the per-harness pack read, and of how the brief's practice section is
# composed from an adapter's references. docs/best-practices-adapters.md owns
# the architecture and the off-limits list; bin/fm-best-practices.sh's header
# owns the commands; .agents/skills/best-practices-adapters/SKILL.md carries
# the catalog of packs in its routing object.
#
# Reads are read-only: they open a harness's registry or skills directory, or
# run its own list command, and never install, enable, disable, or edit
# anything. Committed settings and skills are read from the checkout given,
# which at spawn is the prepared worker copy, because its branch can differ from
# the clone's. Only a project-scope install's identity is the clone: a worktree
# maps back to it through its git common directory.

FM_BP_SCHEMA='best-practices-adapter-v1'
FM_BP_ROUTING_TAG='best-practices-adapter-routing-v1'
# The eight facets: places firstmate already composes text or acts.
FM_BP_FACETS="intake.question brief.practice brief.done launch.env scout.report handoff.review landing.post-merge cleanup.record"
# The worker positions in firstmate's own order; start and report never move.
FM_BP_WORKER_FLOW="start work verify deliver report"
# Every name an adapter may contribute at: the eight facets plus the worker
# positions, which together are the eleven flow positions (position 2 is
# brief.practice and brief.done composed together, and scout.report is a
# scout's deliver).
FM_BP_TARGETS="$FM_BP_FACETS start work verify deliver report"
# The names composed into the brief rather than loaded by the router.
FM_BP_WORKER_TARGETS="brief.practice brief.done start work verify deliver scout.report report"
# The firstmate-side positions a firstmate-side insert can sit before or after.
FM_BP_FIRSTMATE_POSITIONS="intake.question brief.practice brief.done launch.env handoff.review landing.post-merge cleanup.record"
# shellcheck disable=SC2034  # read by bin/fm-best-practices.sh's routing
FM_BP_CONFIDENCE_FLOOR=0.6

# GitHub owner/repo from a repository reference: a bare owner/repo[@ref], an
# https, ssh, or git URL on github.com, or git@github.com:owner/repo. Anything
# else, including another host, is null, so a look-alike never ties.
# shellcheck disable=SC2016  # a jq program, expanded by jq, not the shell
FM_BP_JQ_GH='
def fm_gh_repo:
  if type != "string" then null else
    (ascii_downcase | sub("^git\\+"; "")) as $u
    | (if ($u | test("^[a-z0-9][a-z0-9-]*/[a-z0-9._-]+(@[^/]*)?$")) then ($u | sub("@[^/]*$"; ""))
       elif ($u | test("^(https?|ssh|git)://([^@/]+@)?github\\.com[:/]")) then ($u | sub("^(https?|ssh|git)://([^@/]+@)?github\\.com[:/]"; ""))
       elif ($u | test("^git@github\\.com:")) then ($u | sub("^git@github\\.com:"; ""))
       else null end)
    | if . == null then null else (sub("[?#].*$"; "") | sub("/+$"; "") | sub("\\.git$"; "")) end
    | if . != null and test("^[a-z0-9][a-z0-9-]*/[a-z0-9._-]+$") then . else null end
  end;
def fm_src_repo:
  if type == "object" then
    (if .source == "github" then (.repo | fm_gh_repo)
     elif .source == "url" or .source == "git" then (.url | fm_gh_repo)
     else null end)
  else null end;
'

fm_bp_skill_dir() {
  printf '%s\n' "${FM_ROOT:?}/.agents/skills/best-practices-adapters"
}

# The routing object, the JSON fenced in the router skill under its tag.
fm_bp_routing_json() {
  awk -v open="\`\`\`json $FM_BP_ROUTING_TAG" '
    $0 == open { inside = 1; next }
    inside && /^```[[:space:]]*$/ { exit }
    inside { print }
  ' "$(fm_bp_skill_dir)/SKILL.md"
}

# The repositories this firstmate carries an adapter for, one per line.
fm_bp_adapters() {
  fm_bp_routing_json | jq -r '.packs | keys[]' 2>/dev/null
}

fm_bp_token_shape() {  # <value>
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$'
}

fm_bp_manifest() {  # <owner/repo> -> manifest path
  printf '%s/references/%s/manifest.json\n' "$(fm_bp_skill_dir)" "$1"
}

# True when this firstmate carries an adapter for exactly that repository.
fm_bp_known() {  # <owner/repo>
  fm_bp_token_shape "$1" || return 1
  fm_bp_adapters | grep -qxF -- "$1" || return 1
  [ -f "$(fm_bp_manifest "$1")" ]
}

fm_bp_adapter_list_words() {
  fm_bp_adapters | paste -sd, - | sed 's/,/, /g'
}

fm_bp_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

fm_bp_realdir() {  # <dir>
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# The project a path belongs to, which identifies a project-scope install: a
# worker copy maps back to its clone through its git common directory; anything
# else is its own real path.
fm_bp_project_root() {  # <dir>
  local dir common
  dir=$(fm_bp_realdir "$1")
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    printf '%s\n' "$dir"
    return 0
  }
  case "$common" in
    */.git) fm_bp_realdir "${common%/.git}" ;;
    *) printf '%s\n' "$dir" ;;
  esac
}

# The top of the checkout a path sits in, whose HEAD holds what is committed.
fm_bp_checkout_root() {  # <dir>
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || fm_bp_realdir "$1"
}

# What the checkout commits at <path>; prints nothing and fails when it is not
# a repository or does not commit it.
fm_bp_committed_file() {  # <checkout> <path>
  git -C "$1" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 1
  git -C "$1" show "HEAD:$2" 2>/dev/null
}

# ---- reference blocks ---------------------------------------------------------
# A worker-side reference is a sequence of "## <id>" blocks; text before the
# first block is a note for maintainers and never composed.

fm_bp_blocks() {  # <file> -> block ids in order
  awk '/^## / { print substr($0, 4) }' "$1"
}

fm_bp_block_body() {  # <file> <id>
  awk -v id="$2" '
    /^##? / { inside = ($0 == "## " id); next }
    inside { lines[++n] = $0 }
    END {
      first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$1"
}

# {"<facet or insert id>": ["<block id>", ...]} for every worker-side
# contribution of a manifest, read from its references.
fm_bp_block_map() {  # <manifest>
  local manifest=$1 dir name ref map='{}' blocks
  dir=$(dirname "$manifest")
  while IFS=$'\t' read -r name ref; do
    [ -n "$name" ] || continue
    blocks='[]'
    if [ -f "$dir/$ref" ]; then
      blocks=$(fm_bp_blocks "$dir/$ref" | jq -Rnc '[inputs]')
    fi
    map=$(jq -c --arg k "$name" --argjson v "$blocks" '. + {($k): $v}' <<<"$map")
  done < <(jq -r --arg wt "$FM_BP_WORKER_TARGETS" '
    ($wt | split(" ")) as $w
    | ((.facets // {}) | to_entries[] | select(.key as $k | ($w | index($k)) != null and (.value.reference | type) == "string") | [.key, .value.reference]),
      ((.insert // [])[]? | select(.side == "worker" and (.reference | type) == "string") | [.id, .reference])
    | @tsv' "$manifest" 2>/dev/null)
  printf '%s\n' "$map"
}

# ---- manifest check -----------------------------------------------------------

# Print one "<repo>: <reason>" line per defect and fail when there is any. A
# manifest is refused for any facet or position outside the eleven, any flow
# that moves start or report or places a step before start or after report,
# any replace or pair at start or report, any launch.env other than the two
# firstmate-written exports, and any routing entry that disagrees with it.
fm_bp_manifest_check() {  # <owner/repo>
  local repo=$1 manifest dir verified blocks routing named errs ref f id seen=' ' block_errs=''
  manifest=$(fm_bp_manifest "$repo")
  dir=$(dirname "$manifest")
  if ! fm_bp_token_shape "$repo"; then
    printf '%s: not an <owner>/<repo> repository\n' "$repo"
    return 1
  fi
  if [ ! -f "$manifest" ]; then
    printf '%s: no manifest at %s\n' "$repo" "$manifest"
    return 1
  fi
  if ! jq -e 'type == "object"' "$manifest" >/dev/null 2>&1; then
    printf '%s: %s is not a JSON object\n' "$repo" "$manifest"
    return 1
  fi
  verified=$(fm_control_harnesses | paste -sd' ' -)
  blocks=$(fm_bp_block_map "$manifest")
  routing=$(fm_bp_routing_json | jq -c --arg r "$repo" '.packs[$r] // null' 2>/dev/null) || routing=null
  [ -n "$routing" ] || routing=null
  named=$(fm_bp_named_skills "$manifest" | jq -Rnc '[inputs]')
  errs=$(jq -r --arg repo "$repo" --arg schema "$FM_BP_SCHEMA" --arg targets "$FM_BP_TARGETS" \
    --arg wtargets "$FM_BP_WORKER_TARGETS" --arg fmpos "$FM_BP_FIRSTMATE_POSITIONS" \
    --arg verified "$verified" --arg wflow "$FM_BP_WORKER_FLOW" \
    --argjson blocks "$blocks" --argjson routing "$routing" --argjson named "$named" '
    def s($x): ($x | type) == "string" and ($x | length) > 0;
    def strs($x): ($x | type) == "array" and ($x | length) > 0 and all($x[]; s(.));
    def kinds_ok($x): strs($x) and all($x[]; . == "ship" or . == "scout");
    . as $m
    | ($targets | split(" ")) as $T
    | ($wtargets | split(" ")) as $W
    | ($fmpos | split(" ")) as $FP
    | ($verified | split(" ")) as $V
    | (($m.insert // []) | if type == "array" then . else [] end) as $ins
    | ([$ins[] | select(.side == "worker") | .id]) as $wins
    | ([$ins[] | .id]) as $insids
    | ([$blocks[][]]) as $allblocks
    | [
      (if $m.schema != $schema then "schema must be \($schema)" else empty end),
      (if $m.repository != $repo then "repository must be \($repo), the adapter directory it lives in" else empty end),
      (if s($m.plugin) | not then "plugin must name the pack'"'"'s plugin" else empty end),
      (if ($m.versions | type) != "array" or ($m.versions | length) == 0 then "versions must list at least one supported tag"
       else ($m.versions[] | select((.tag | type) != "string" or (.tag | test("^v?[0-9]+(\\.[0-9]+)+([-+][0-9A-Za-z.-]+)?$") | not))
         | "version \(.tag | tostring) is not a release tag; the supported list carries tags only") end),
      (if strs($m.skills) | not then "skills must list the pack'"'"'s skill names" else empty end),
      (if ($m.harnesses | type) != "object" or ($m.harnesses | length) == 0 then "harnesses must name at least one harness"
       else ($m.harnesses | to_entries[] | .key as $h | .value as $e |
         (if ($V | index($h)) == null then "harness \($h) is not one firstmate verifies" else empty end),
         (if (["plugin", "skills-dir"] | index($e.shape)) == null then "harness \($h) shape must be plugin or skills-dir" else empty end),
         (if $e.read != null and (["claude-plugin", "omp-plugin", "codex-config", "agy-plugin-list", "skills-dir"] | index($e.read)) == null then "harness \($h) read \($e.read | tostring) is not a read firstmate implements" else empty end),
         (if ($e.shape == "skills-dir") != ($e.read == "skills-dir") and $e.read != null then "harness \($h) shape and read disagree" else empty end),
         (if $e.read == "skills-dir" and ((($e.user_dirs // []) | type) != "array" or (($e.project_dirs // []) | type) != "array" or ((($e.user_dirs // []) + ($e.project_dirs // [])) | length) == 0) then "harness \($h) skills-dir read needs user_dirs or project_dirs" else empty end),
         (if ($e | has("switch")) and (($e.switch | type) != "object" or (s($e.switch.user_settings) | not) or (s($e.switch.project_settings) | not) or (strs($e.switch.disabled) | not)) then "harness \($h) switch needs user_settings, project_settings, and the disabled list'"'"'s key path" else empty end),
         (if s($e.install) | not then "harness \($h) needs the install command the pack documents" else empty end),
         (if ($e.proof | type) != "object" or (["proven", "unproven"] | index($e.proof.status)) == null then "harness \($h) proof.status must be proven or unproven"
          elif $e.proof.status == "proven" and ($e.read == null or (s($e.proof.date) | not) or (s($e.proof.evidence) | not)) then "harness \($h) is marked proven without a read, a date, and evidence"
          elif $e.proof.status == "unproven" and (s($e.proof.reason) | not) then "harness \($h) is unproven without a reason"
          elif ($e.proof | has("unproven_scopes")) and ((strs($e.proof.unproven_scopes) | not) or any($e.proof.unproven_scopes[]; . != "user" and . != "project") or (s($e.proof.unproven) | not)) then "harness \($h) unproven_scopes must list user or project, with the reason in unproven"
          else empty end)
       ) end),
      (if ($m.facets | type) != "object" then "facets must be an object"
       else ($m.facets | to_entries[] | .key as $f | .value as $e |
         if ($T | index($f)) == null then "facet \($f) is outside the eleven flow positions"
         else
           (if (["extend", "replace", "pair"] | index($e.action)) == null then "facet \($f) action must be extend, replace, or pair" else empty end),
           (if $e.action == "pair" and (["firstmate-first", "pack-first"] | index($e.order)) == null then "facet \($f) pair needs order firstmate-first or pack-first" else empty end),
           (if $e.action != "pair" and ($e | has("order")) then "facet \($f) order applies only to pair" else empty end),
           (if ($f == "start" or $f == "report") and $e.action != "extend" then "facet \($f) cannot be replaced or paired: the isolation check stays first and the done report stays last" else empty end),
           (if $f == "launch.env" then
              (if $e.action != "extend" or ($e | has("reference")) or ($e | has("kinds")) then "launch.env only extends, with the two exports firstmate writes; an adapter adds no switches" else empty end)
            elif s($e.reference) | not then "facet \($f) needs a reference"
            else empty end),
           (if ($W | index($f)) != null then
              (if kinds_ok($e.kinds) | not then "facet \($f) kinds must list ship, scout, or both" else empty end)
            elif ($e | has("kinds")) then "facet \($f) is firstmate-side and takes no kinds"
            else empty end),
           (if $f == "scout.report" and $e.kinds != ["scout"] then "facet scout.report applies to scouts only" else empty end),
           (if $f == "deliver" and (($e.kinds // []) | index("scout")) != null then "facet deliver is scout.report on a scout" else empty end)
         end
       ) end),
      (if ($m | has("insert")) and ($m.insert | type) != "array" then "insert must be an array" else empty end),
      ($insids | group_by(.) | map(select(length > 1) | .[0]) | .[] | "insert \(.) is declared twice"),
      ($ins[] |
        (if (s(.id) | not) or (.id | test("^[a-z][a-z0-9-]*$") | not) then "insert id \(.id | tostring) must be lowercase words joined by hyphens"
         elif (.id as $i | $T | index($i)) != null then "insert \(.id) reuses the name of an existing position"
         else empty end),
        (if s(.reference) | not then "insert \(.id | tostring) needs a reference" else empty end),
        (if .side == "worker" then
           (if kinds_ok(.kinds) | not then "insert \(.id) kinds must list ship, scout, or both" else empty end),
           (if has("before") or has("after") then "worker insert \(.id) takes its place from flow, not from before or after" else empty end)
         elif .side == "firstmate" then
           (if (has("before") and has("after")) or ((.before // .after) as $a | ($FP | index($a)) == null) then "firstmate insert \(.id) needs exactly one of before or after naming a firstmate-side position" else empty end)
         else "insert \(.id | tostring) side must be worker or firstmate" end)),
      (if ($m | has("flow")) | not then
         (if ($wins | length) > 0 then "flow must state where each worker insert runs" else empty end)
       elif ($m.flow | type) != "array" then "flow must be an array"
       else
         (($wflow | split(" ")) + $wins) as $need
         | (if ($m.flow | sort) != ($need | sort) then "flow must list start, work, verify, deliver, report, and each worker insert exactly once" else empty end),
           (if $m.flow[0] != "start" then "flow must keep start first; nothing runs before the isolation check" else empty end),
           (if $m.flow[-1] != "report" then "flow must keep report last; nothing runs after the done report" else empty end)
       end),
      (if ($m | has("routing")) and ($m.routing | type) != "array" then "routing must be an array" else empty end),
      ((($m.routing // []) | if type == "array" then . else [] end) | map(.id) | group_by(.) | map(select(length > 1) | .[0]) | .[] | "routing row \(.) is declared twice"),
      ((($m.routing // []) | if type == "array" then . else [] end)[] | . as $r | ($r.id | tostring) as $id |
        (($W + $wins) | index($r.facet) != null) as $worker_row |
        (if (s($r.id) | not) or ($r.id | test("^[a-z][a-z0-9-]*$") | not) then "routing row \($id) id must be lowercase words joined by hyphens" else empty end),
        (if (($T + $insids) | index($r.facet)) == null then "routing row \($id) facet \($r.facet | tostring) is outside the eleven flow positions and this adapter'"'"'s inserts"
         elif $r.facet == "launch.env" then "routing row \($id) cannot route launch.env, which carries no switches"
         else empty end),
        (if (["noul", "choice", "fact"] | index($r.type)) == null then "routing row \($id) type must be noul, choice, or fact" else empty end),
        (if $r.type != "fact" and (s($r.instructions) | not) then "routing row \($id) needs instructions" else empty end),
        (if $r.type == "fact" and (($r.gate | type) != "object" or ($r.gate | length) == 0) then "fact row \($id) needs a gate" else empty end),
        (if ($r | has("gate")) and (($r.gate | type) != "object" or any($r.gate | to_entries[]; (.key as $k | ["kind", "mode", "forge"] | index($k)) == null or (strs(.value) | not))) then "routing row \($id) gate keys must be kind, mode, or forge, each with a list" else empty end),
        (if $r.type == "noul" and ($r.fallback | type) != "boolean" then "noul row \($id) needs a true or false fallback" else empty end),
        (if $r.type == "choice" then
           (if ($r.options | type) != "object" or ($r.options | length) == 0 or any($r.options[]; s(.) | not) then "choice row \($id) needs options, each with a criterion"
            elif ($r.options | has("none")) then "choice row \($id) must not declare none; firstmate adds that option"
            elif ((($r.options | keys) + [($r.words // {})[]]) | index($r.fallback)) == null then "choice row \($id) fallback must be one of its options"
            else empty end)
         else empty end),
        (if ($r | has("min_confidence")) and (($r.min_confidence | type) != "number" or $r.min_confidence < 0 or $r.min_confidence > 1) then "routing row \($id) min_confidence must be from 0 through 1" else empty end),
        (if ($r | has("words")) and (($r.words | type) != "object" or any($r.words[]; if $r.type == "noul" then type != "boolean" else type != "string" end)) then "routing row \($id) words must map phrases to \(if $r.type == "noul" then "true or false" else "option names" end)" else empty end),
        (if $worker_row then
           (if $r.type == "choice" then
              (if ($r.selects | type) != "object" or any($r.selects[]; strs(.) | not) then "worker-side choice row \($id) selects must map options to blocks"
               else ($r.selects | to_entries[] | .key as $o | .value[] | select(. as $b | ($blocks[$r.facet] // []) | index($b) | not) | "routing row \($id) option \($o) selects \(.), which is not a block in the \($r.facet) reference") end)
            elif strs($r.selects) | not then "worker-side row \($id) must select at least one block"
            else ($r.selects[] | select(. as $b | ($blocks[$r.facet] // []) | index($b) | not) | "routing row \($id) selects \(.), which is not a block in the \($r.facet) reference") end),
           (($r.excludes // [])[] | select(. as $b | ($allblocks | index($b)) | not) | "routing row \($id) excludes \(.), which is not a block of this adapter")
         elif ($r | has("selects")) or ($r | has("excludes")) then "firstmate-side row \($id) selects no blocks; firstmate reads its value"
         else empty end)),
      (if ($m.fingerprints | type) != "object" then "fingerprints are missing; generate them with bin/fm-best-practices.sh fingerprints \($repo) --write"
       else
         ($m.fingerprints) as $f
         | (if ($f.skills | type) != "array" or ($f.skills | sort) != $named then "fingerprints.skills must be exactly the pack skills the adapter'"'"'s references name (\($named | join(", "))); regenerate with bin/fm-best-practices.sh fingerprints \($repo) --write" else empty end),
           (if ($f.tags | type) != "object" or ($f.tags | keys | sort) != ([($m.versions // [])[]?.tag] | sort) then "fingerprints.tags must hold exactly the supported tags; regenerate with bin/fm-best-practices.sh fingerprints \($repo) --write" else empty end),
           (($f.tags // {}) | if type == "object" then to_entries[] else empty end | .key as $t | .value as $v
             | if ($v | type) != "object" or ($v | keys | sort) != ((($f.skills // []) | if type == "array" then . else [] end) | sort) or any($v[]; type != "string" or (test("^[0-9a-f]{64}$") | not))
               then "fingerprints for \($t) must hash every fingerprinted skill as 64 lowercase hex characters" else empty end)
       end),
      (if $routing == null then "the router skill'"'"'s routing object carries no entry for \($repo)"
       else
         ({
           manifest: "references/\($repo)/manifest.json",
           facets: (($m.facets // {}) | with_entries(.value |= ({action} + (if has("order") then {order} else {} end) + (if has("reference") then {reference: "references/\($repo)/\(.reference)"} else {} end))))
         }
         + (if ($ins | length) > 0 then {inserted: ($ins | map({key: .id, value: (
             (if .side == "worker" then
                (.id as $i | ($m.flow // []) | index($i)) as $at
                | {before: (if $at == null then null else ($m.flow[$at + 1]) end)}
              elif has("before") then {before} else {after} end)
             + {reference: "references/\($repo)/\(.reference)"})}) | from_entries)} else {} end)
         + (if ($m | has("notes")) then {notes: "references/\($repo)/\($m.notes)"} else {} end)) as $expect
         | if $routing != $expect then "the router skill'"'"'s routing object disagrees with \($repo)'"'"'s manifest; it should read \($expect | tojson)" else empty end
       end)
    ] | .[] | "\($repo): \(.)"
  ' "$manifest" 2>&1) || errs="$repo: the manifest could not be checked: $errs"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ -f "$dir/$ref" ] || block_errs="$block_errs$repo: reference $ref does not exist"$'\n'
  done < <(jq -r '((.facets // {})[] | .reference // empty), ((.insert // [])[]? | .reference // empty), (.notes // empty)' "$manifest" 2>/dev/null)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! printf '%s' "$id" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      block_errs="$block_errs$repo: block \"$id\" must be lowercase words joined by hyphens"$'\n'
    fi
    case "$seen" in
      *" $id "*) block_errs="$block_errs$repo: block $id appears in more than one place"$'\n' ;;
    esac
    seen="$seen$id "
  done < <(jq -r '.[][]' <<<"$blocks")
  for f in $FM_BP_WORKER_TARGETS; do
    ref=$(jq -r --arg f "$f" '.facets[$f].reference // empty' "$manifest")
    [ -n "$ref" ] && [ -f "$dir/$ref" ] || continue
    [ -n "$(fm_bp_blocks "$dir/$ref")" ] || block_errs="$block_errs$repo: worker-side reference $ref has no ## blocks to compose"$'\n'
  done
  errs="$errs${errs:+$'\n'}${block_errs%$'\n'}"
  errs=${errs#$'\n'}
  [ -z "$errs" ] && return 0
  printf '%s\n' "$errs"
  return 1
}

# ---- harness reads --------------------------------------------------------------
# Each read prints one JSON object: installed, enabled, enabled_source (user or
# project), label (the runtime's own version label for the install, a hint
# only), id (the harness's own identity for the install), where (one human
# sentence naming what was read and found), and copy (where the installed
# files are: {"dir", "layout": "plugin"|"skills"} or, for a copy the project
# commits, {"git", "prefix"}), which the fingerprint reads.

fm_bp_result() {  # <installed> <enabled> <enabled-source> <label> <id> <where> [copy-json]
  jq -cn --argjson installed "$1" --argjson enabled "$2" --arg source "$3" --arg label "$4" --arg id "$5" --arg where "$6" \
    --argjson copy "${7:-null}" '
    {installed: $installed, enabled: $enabled,
     enabled_source: (if $source == "" then null else $source end),
     label: (if $label == "" then null else $label end),
     id: (if $id == "" then null else $id end), where: $where, copy: $copy}'
}

fm_bp_dir_copy() {  # <dir> <plugin|skills>
  jq -cn --arg d "$1" --arg l "$2" '{dir: $d, layout: $l}'
}

# A Claude Code enabledPlugins value: true or a version-constraint list
# enables, false disables, absence says nothing.
fm_bp_claude_enabled_value() {  # <settings-json-text> <key> -> on|off|none
  jq -r --arg k "$2" '
    try ((.enabledPlugins // {}) | if has($k) then .[$k] else null end) catch null
    | if . == true or type == "array" then "on" elif . == null then "none" else "off" end
  ' 2>/dev/null <<<"$1" || printf 'none\n'
}

# Claude Code: ~/.claude/plugins/installed_plugins.json keys each install as
# <name>@<marketplace>; the tie to the repository runs through the marketplace
# (known_marketplaces.json and its .claude-plugin/marketplace.json); user scope
# and a project-scope install for this project count, local scope does not;
# enablement is the user settings' enabledPlugins entry under the checkout's
# committed .claude/settings.json one, and settings.local.json is never read.
fm_bp_read_claude() {  # <repo> <plugin> <project-root> <checkout>
  local repo=$1 plugin=$2 proj=$3 checkout=$4 cdir installed known key market msrc loc mfile psrc mrepo lrepo
  local untied='' best='' best_rank=0 rank scope path ver ipath ver_user ver_proj copy_user copy_proj copy uval pval state src where installed_now best_candidate
  cdir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  installed="$cdir/plugins/installed_plugins.json"
  known="$cdir/plugins/known_marketplaces.json"
  lrepo=$(fm_bp_lower "$repo")
  if [ ! -f "$installed" ]; then
    fm_bp_result false false "" "" "" "no plugin registry at $installed"
    return 0
  fi
  uval=$(cat "$cdir/settings.json" 2>/dev/null) || uval='{}'
  pval=$(fm_bp_committed_file "$checkout" .claude/settings.json) || pval='{}'
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    market=${key#*@}
    msrc=$(jq -c --arg m "$market" '.[$m].source // null' "$known" 2>/dev/null) || msrc=null
    [ -n "$msrc" ] || msrc=null
    loc=$(jq -r --arg m "$market" '.[$m].installLocation // empty' "$known" 2>/dev/null) || loc=
    [ -n "$loc" ] || loc="$cdir/plugins/marketplaces/$market"
    mfile="$loc/.claude-plugin/marketplace.json"
    psrc=$(jq -c --arg p "$plugin" '[.plugins[]? | select(.name == $p) | .source] | first // null' "$mfile" 2>/dev/null) || psrc=null
    [ -n "$psrc" ] || psrc=null
    mrepo=$(jq -rn --argjson p "$psrc" --argjson ms "$msrc" "$FM_BP_JQ_GH"'
      (if ($p | type) == "string" then ($ms | fm_src_repo) else ($p | fm_src_repo) end) // empty' 2>/dev/null) || mrepo=
    if [ "$mrepo" != "$lrepo" ]; then
      untied="$untied${untied:+, }$key"
      continue
    fi
    ver_user='' ver_proj='' copy_user='' copy_proj=''
    while IFS=$'\t' read -r scope path ver ipath; do
      [ "$ver" = - ] && ver=unknown
      case "$scope" in
        user)
          if [ -z "$ver_user" ]; then
            ver_user=$ver
            [ "$ipath" = - ] || copy_user=$(fm_bp_dir_copy "$ipath" plugin)
          fi
          ;;
        project)
          if [ "$path" != - ] && [ "$(fm_bp_realdir "$path")" = "$proj" ]; then
            ver_proj=$ver
            [ "$ipath" = - ] || copy_proj=$(fm_bp_dir_copy "$ipath" plugin)
          fi
          ;;
      esac
    done < <(jq -r --arg k "$key" '.plugins[$k][]? | select(.scope == "user" or .scope == "project")
      | [.scope, (.projectPath // "-"), (.version // "-"), (.installPath // "-")] | @tsv' "$installed" 2>/dev/null)
    installed_now=false
    ver=${ver_proj:-$ver_user}
    if [ -n "$ver_proj" ]; then copy=${copy_proj:-null}; else copy=${copy_user:-null}; fi
    [ -n "$ver" ] && installed_now=true
    state=$(fm_bp_claude_enabled_value "$pval" "$key")
    src=project
    if [ "$state" = none ]; then
      state=$(fm_bp_claude_enabled_value "$uval" "$key")
      src=user
    fi
    if [ "$installed_now" = false ]; then
      rank=1
      where="$key ties to $repo but is not installed at user scope or at project scope for $proj; local-scope installs and other projects' installs do not count"
      best_candidate=$(fm_bp_result false false "" "" "$key" "$where")
    elif [ "$state" = on ]; then
      rank=3
      if [ "$src" = project ]; then where="$key is enabled by enabledPlugins in the project's committed .claude/settings.json"
      else where="$key is enabled by enabledPlugins in $cdir/settings.json"; fi
      best_candidate=$(fm_bp_result true true "$src" "$ver" "$key" "$where" "$copy")
    else
      rank=2
      if [ "$state" = off ] && [ "$src" = project ]; then where="$key is disabled by enabledPlugins in the project's committed .claude/settings.json"
      elif [ "$state" = off ]; then where="$key is disabled by enabledPlugins in $cdir/settings.json"
      else where="$key has no enabledPlugins entry in $cdir/settings.json or in the project's committed .claude/settings.json"; fi
      best_candidate=$(fm_bp_result true false "" "$ver" "$key" "$where" "$copy")
    fi
    if [ "$rank" -gt "$best_rank" ]; then
      best_rank=$rank
      best=$best_candidate
    fi
  done < <(jq -r --arg p "$plugin" '(.plugins // {}) | keys[] | select(startswith($p + "@"))' "$installed" 2>/dev/null)
  if [ -n "$best" ]; then
    printf '%s\n' "$best"
    return 0
  fi
  where="no installed plugin named $plugin resolves to $repo in $installed"
  [ -z "$untied" ] || where="$where; $untied resolves to another repository"
  fm_bp_result false false "" "" "" "$where"
}

# Codex: ~/.codex/config.toml carries [marketplaces.<name>] with source_type
# and source, and [plugins."<name>@<marketplace>"], whose own enabled wins
# over [plugins._default] enabled, which wins over Codex's default of enabled.
# The plugin counts as installed only when its own table is present and its
# copy is in plugins/cache/<marketplace>/<plugin>/<version>, as codex plugin
# list reports it. User level only.
fm_bp_read_codex() {  # <repo> <plugin>
  local repo=$1 plugin=$2 chome cfg table lrepo market key has_table enabled cache v ver
  chome=${CODEX_HOME:-$HOME/.codex}
  cfg="$chome/config.toml"
  lrepo=$(fm_bp_lower "$repo")
  if [ ! -f "$cfg" ]; then
    fm_bp_result false false "" "" "" "no Codex configuration at $cfg"
    return 0
  fi
  # One row per table header (key "-") and per key, so a table with no keys
  # still shows that it exists.
  table=$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      s = $0; sub(/^[[:space:]]*\[[[:space:]]*/, "", s); sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", s)
      sect = s; print sect "\t-\t-"; next
    }
    /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
      k = $0; sub(/^[[:space:]]*/, "", k); sub(/[[:space:]]*=.*$/, "", k)
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
      if (substr(v, 1, 1) == "\"") { v = substr(v, 2); i = index(v, "\""); if (i > 0) v = substr(v, 1, i - 1) }
      else { sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]+$/, "", v) }
      print (sect == "" ? "-" : sect) "\t" k "\t" (v == "" ? "-" : v)
    }
  ' "$cfg" | jq -Rnc '[inputs | split("\t") | {sect: .[0], key: .[1], value: .[2]}]') || table='[]'
  while IFS=$'\t' read -r market has_table enabled; do
    [ -n "$market" ] || continue
    key="$plugin@$market"
    cache="$chome/plugins/cache/$market/$plugin"
    v=
    if [ -d "$cache" ]; then
      v=$(find "$cache" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -V | tail -n 1)
    fi
    if [ "$has_table" != true ] || [ -z "$v" ]; then
      fm_bp_result false false "" "" "$key" "$key ties to $repo through [marketplaces.$market] in $cfg but is not installed: it needs both its [plugins.\"$key\"] table there and its copy under $cache"
      return 0
    fi
    ver=$(jq -r '.version // empty' "$cache/$v/.codex-plugin/plugin.json" 2>/dev/null) || ver=
    [ -n "$ver" ] || ver=$v
    if [ "$enabled" = false ]; then
      fm_bp_result true false "" "$ver" "$key" "$key is disabled in $cfg" "$(fm_bp_dir_copy "$cache/$v" plugin)"
    else
      fm_bp_result true true user "$ver" "$key" "$key is enabled in $cfg" "$(fm_bp_dir_copy "$cache/$v" plugin)"
    fi
    return 0
  done < <(jq -r --arg p "$plugin" --arg repo "$lrepo" "$FM_BP_JQ_GH"'
    def unq: if startswith("\"") and endswith("\"") and length > 1 then .[1:-1] else . end;
    def val($s; $k): ([.[] | select(.sect == $s and .key == $k) | .value] | last // "-");
    . as $t
    | ([$t[] | select(.sect | startswith("marketplaces.")) | .sect] | unique) as $msects
    | $msects[]
    | . as $ms
    | ($ms | ltrimstr("marketplaces.") | unq) as $name
    | select(($t | val($ms; "source_type")) != "local" and (($t | val($ms; "source")) | fm_gh_repo) == $repo)
    | ([$t[] | select((.sect | startswith("plugins.")) and (.sect | ltrimstr("plugins.") | unq) == ($p + "@" + $name))]) as $own
    | ([$own[] | select(.key == "enabled") | .value] | last) as $own_enabled
    | ($t | val("plugins._default"; "enabled")) as $default
    | [$name, (($own | length) > 0 | tostring),
       (if $own_enabled != null then $own_enabled elif $default != "-" then $default else "true" end)] | @tsv' <<<"$table" 2>/dev/null)
  fm_bp_result false false "" "" "" "no Codex marketplace in $cfg resolves to $repo"
}

# Oh My Pi: ~/.omp/plugins/installed_plugins.json keys each install as
# <name>@<marketplace>, as Claude Code does, and a project-scope install
# writes <project>/.omp/plugins/installed_plugins.json, whose enabled entry
# shadows it; an entry recording enabled false is skipped, so a disabled
# project install leaves the user install in force, and any other entry
# loads, as omp's own plugin discovery does. The tie runs through ~/.omp/marketplaces.json
# (sourceType and sourceUri) and the catalog copy it names. omp also loads
# Claude Code's installed plugins when its own registries name no install,
# which this read does not count, so it can only under-report a loaded pack.
fm_bp_read_omp() {  # <repo> <plugin> <checkout>
  local repo=$1 plugin=$2 checkout=$3 ohome markets lrepo reg_text scope key market msrc catalog psrc mrepo enabled ver ipath copy where disabled=''
  ohome="$HOME/.omp"
  markets="$ohome/marketplaces.json"
  lrepo=$(fm_bp_lower "$repo")
  for scope in project user; do
    if [ "$scope" = project ]; then
      reg_text=$(fm_bp_committed_file "$checkout" .omp/plugins/installed_plugins.json) || continue
    else
      reg_text=$(cat "$ohome/plugins/installed_plugins.json" 2>/dev/null) || continue
    fi
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      market=${key#*@}
      msrc=$(jq -c --arg m "$market" '[.marketplaces[]? | select(.name == $m)] | first // null
        | if . == null then null else {source: .sourceType, repo: .sourceUri, url: .sourceUri} end' "$markets" 2>/dev/null) || msrc=null
      [ -n "$msrc" ] || msrc=null
      catalog=$(jq -r --arg m "$market" '[.marketplaces[]? | select(.name == $m) | .catalogPath] | first // empty' "$markets" 2>/dev/null) || catalog=
      psrc=$(jq -c --arg p "$plugin" '[.plugins[]? | select(.name == $p) | .source] | first // null' "$catalog" 2>/dev/null) || psrc=null
      [ -n "$psrc" ] || psrc=null
      mrepo=$(jq -rn --argjson p "$psrc" --argjson ms "$msrc" "$FM_BP_JQ_GH"'
        (if ($p | type) == "string" then ($ms | fm_src_repo) else ($p | fm_src_repo) end) // empty' 2>/dev/null) || mrepo=
      [ "$mrepo" = "$lrepo" ] || continue
      enabled=$(jq -r --arg k "$key" '.plugins[$k][0].enabled != false' <<<"$reg_text")
      ver=$(jq -r --arg k "$key" '.plugins[$k][0].version // "unknown"' <<<"$reg_text")
      ipath=$(jq -r --arg k "$key" '.plugins[$k][0].installPath // empty' <<<"$reg_text")
      copy=null
      [ -z "$ipath" ] || copy=$(fm_bp_dir_copy "$ipath" plugin)
      if [ "$scope" = project ]; then where="$key is installed at project scope in the project's committed .omp/plugins/installed_plugins.json"
      else where="$key is installed in $ohome/plugins/installed_plugins.json"; fi
      if [ "$enabled" = true ]; then
        fm_bp_result true true "$scope" "$ver" "$key" "$where" "$copy"
        return 0
      fi
      [ -n "$disabled" ] || disabled=$(fm_bp_result true false "" "$ver" "$key" "$where, which records it disabled" "$copy")
    done < <(jq -r --arg p "$plugin" '(.plugins // {}) | keys[] | select(startswith($p + "@"))' <<<"$reg_text" 2>/dev/null)
  done
  if [ -n "$disabled" ]; then
    printf '%s\n' "$disabled"
    return 0
  fi
  fm_bp_result false false "" "" "" "no omp plugin registry for this project or in $ohome names a $plugin install that resolves to $repo"
}

# Antigravity: agy plugin list --json records name, enabled, version, source,
# and path, but no source repository, so the tie is the installed copy's own
# manifest repository field, the weaker tie.
fm_bp_read_agy() {  # <repo> <plugin>
  local repo=$1 plugin=$2 lrepo list entry path manifest_repo enabled version f
  lrepo=$(fm_bp_lower "$repo")
  if ! command -v agy >/dev/null 2>&1; then
    fm_bp_result false false "" "" "" "agy is not on PATH, so its plugin list cannot be read"
    return 0
  fi
  if ! list=$(fm_run_timed 30 agy plugin list --json 2>/dev/null) || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$list"; then
    fm_bp_result false false "" "" "" "agy plugin list --json did not return a plugin list"
    return 0
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    path=$(jq -r '.path // empty' <<<"$entry")
    manifest_repo=
    for f in .claude-plugin/plugin.json .codex-plugin/plugin.json plugin.json; do
      [ -n "$path" ] && [ -f "$path/$f" ] || continue
      manifest_repo=$(jq -r "$FM_BP_JQ_GH"'(.repository | if type == "object" then .url else . end) | fm_gh_repo // empty' "$path/$f" 2>/dev/null) || manifest_repo=
      [ -z "$manifest_repo" ] || break
    done
    [ "$manifest_repo" = "$lrepo" ] || continue
    enabled=$(jq -r '.enabled == true' <<<"$entry")
    version=$(jq -r '.version // empty' <<<"$entry")
    if [ "$enabled" = true ]; then
      fm_bp_result true true user "$version" "$plugin" "$plugin is enabled in agy plugin list --json, at $path" "$(fm_bp_dir_copy "$path" plugin)"
    else
      fm_bp_result true false "" "$version" "$plugin" "$plugin is disabled in agy plugin list --json, at $path" "$(fm_bp_dir_copy "$path" plugin)"
    fi
    return 0
  done < <(jq -c --arg p "$plugin" '.[] | select(.name == $p)' <<<"$list")
  fm_bp_result false false "" "" "" "agy plugin list --json lists no $plugin whose installed manifest names $repo as its repository"
}

# A skills directory: installed means every one of the pack's skills is where
# the harness loads them, at user level or committed in the project; enabled is
# presence, unless the harness's switch (the manifest's `switch`: a list of
# disabled skill names at one key path in a user settings file and the
# project's committed one) names any of the pack's skills; the version is a
# plugin.json the copy carries, never inferred.
fm_bp_read_skills_dir() {  # <repo> <plugin> <checkout> <harness-entry-json> <skills-json>
  local repo=$1 plugin=$2 checkout=$3 entry=$4 skills=$5 d dir listing missing s ver switch scope found='' disabled path user_file copy=null
  for scope in project user; do
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      missing=0
      if [ "$scope" = project ]; then
        listing=$(git -C "$checkout" ls-files -- "$d" 2>/dev/null) || listing=
        while IFS= read -r s; do
          printf '%s\n' "$listing" | grep -qxF "$d/$s/SKILL.md" || { missing=1; break; }
        done < <(jq -r '.[]' <<<"$skills")
        [ "$missing" -eq 0 ] || continue
        ver=$( { fm_bp_committed_file "$checkout" "$d/.claude-plugin/plugin.json" || fm_bp_committed_file "$checkout" "$d/plugin.json"; } \
          | jq -r --arg p "$plugin" 'select(.name == $p) | .version // empty' 2>/dev/null) || ver=
        found="the pack's skills are committed in the project at $d"
        copy=$(jq -cn --arg g "$checkout" --arg p "$d" '{git: $g, prefix: $p}')
      else
        dir=$(fm_bp_expand_home "$d")
        while IFS= read -r s; do
          [ -f "$dir/$s/SKILL.md" ] || { missing=1; break; }
        done < <(jq -r '.[]' <<<"$skills")
        [ "$missing" -eq 0 ] || continue
        ver=$(jq -r --arg p "$plugin" 'select(.name == $p) | .version // empty' "$dir/.claude-plugin/plugin.json" "$dir/plugin.json" 2>/dev/null | head -n 1) || ver=
        found="the pack's skills are in $dir"
        copy=$(fm_bp_dir_copy "$dir" skills)
      fi
      break 2
    done < <(jq -r --arg k "${scope}_dirs" '.[$k] // [] | .[]' <<<"$entry")
  done
  if [ -z "$found" ]; then
    fm_bp_result false false "" "" "" "no directory this harness loads skills from holds every one of the pack's skills"
    return 0
  fi
  switch=$(jq -c '.switch // null' <<<"$entry")
  if [ "$switch" != null ]; then
    path=$(jq -c '.disabled' <<<"$switch")
    user_file=$(fm_bp_expand_home "$(jq -r '.user_settings' <<<"$switch")")
    disabled=$( { cat "$user_file" 2>/dev/null; echo; fm_bp_committed_file "$checkout" "$(jq -r '.project_settings' <<<"$switch")"; } \
      | jq -rs --argjson path "$path" --argjson skills "$skills" '
          [.[] | objects | try getpath($path) catch null | select(type == "array") | .[] | strings]
          | map(select(. as $n | $skills | index($n) != null)) | unique | join(", ")' 2>/dev/null) || disabled=
    if [ -n "$disabled" ]; then
      fm_bp_result true false "" "$ver" "" "$found, but the harness's switch disables $disabled in $user_file or the project's committed $(jq -r '.project_settings' <<<"$switch")" "$copy"
      return 0
    fi
  fi
  fm_bp_result true true "$scope" "$ver" "" "$found" "$copy"
}

fm_bp_expand_home() {  # <path>: a leading ~/ is the user's home
  case "$1" in
    \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# ---- fingerprints -----------------------------------------------------------------
# The pack's version is read from its content: each skill the adapter's own
# references name has its SKILL.md hashed (SHA-256, line endings normalized to
# LF) and compared with the hashes generated from each reviewed tag
# (bin/fm-best-practices.sh fingerprints). The runtime's version label only
# picks which tag to try first.

# The pack's skills the adapter's facet and insert references name in
# backticks, one per line, sorted: the files the adapter depends on.
fm_bp_named_skills() {  # <manifest>
  local manifest=$1 dir
  dir=$(dirname "$manifest")
  jq -r '((.facets // {})[] | .reference // empty), ((.insert // [])[]? | .reference // empty)' "$manifest" 2>/dev/null |
    sort -u | while IFS= read -r ref; do
      # shellcheck disable=SC2016  # matches literal Markdown backticks
      [ -f "$dir/$ref" ] && grep -o '`[a-z0-9-]*`' "$dir/$ref"
    done | tr -d '`' | sort -u | grep -xF -f <(jq -r '.skills[]' "$manifest") || true
}

fm_bp_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# The normalized SHA-256 of standard input.
fm_bp_hash() {
  perl -pe 's/\r\n?/\n/g' | fm_bp_sha256
}

# {"<skill>": "<hash>" or null} for one copy, null where the skill's file is absent.
fm_bp_copy_hashes() {  # <copy-json> <skills-json>
  local copy=$1 skills=$2 s file h out='{}' git prefix dir layout
  git=$(jq -r '.git // empty' <<<"$copy")
  prefix=$(jq -r '.prefix // empty' <<<"$copy")
  dir=$(jq -r '.dir // empty' <<<"$copy")
  layout=$(jq -r '.layout // empty' <<<"$copy")
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    h=
    if [ -n "$git" ]; then
      if fm_bp_committed_file "$git" "$prefix/$s/SKILL.md" >/dev/null; then
        h=$(fm_bp_committed_file "$git" "$prefix/$s/SKILL.md" | fm_bp_hash)
      fi
    elif [ -n "$dir" ]; then
      if [ "$layout" = plugin ]; then file="$dir/skills/$s/SKILL.md"; else file="$dir/$s/SKILL.md"; fi
      [ -f "$file" ] && h=$(fm_bp_hash < "$file")
    fi
    out=$(jq -c --arg k "$s" --arg v "$h" '. + {($k): (if $v == "" then null else $v end)}' <<<"$out")
  done < <(jq -r '.[]' <<<"$skills")
  printf '%s\n' "$out"
}

# The verdict for one copy: {"status": "match", "tag"} when every depended-on
# file matches a reviewed tag (the runtime's label when it is one, otherwise
# the newest that matches); {"status": "unreviewed", "tag": <nearest>,
# "differing": [...], "missing": [...], "label"} when any differs or is
# absent; {"status": "absent"} when the copy holds none of them. Exact hashes
# only, never a fuzzy match.
fm_bp_fingerprint() {  # <manifest> <copy-json> <label>
  local manifest=$1 copy=$2 label=$3 fps hashes
  fps=$(jq -c '.fingerprints' "$manifest")
  if [ "$copy" = null ] || [ -z "$copy" ]; then
    hashes=$(jq -c '.skills | map({key: ., value: null}) | from_entries' <<<"$fps")
  else
    hashes=$(fm_bp_copy_hashes "$copy" "$(jq -c '.skills' <<<"$fps")")
  fi
  jq -cn --argjson fp "$fps" --argjson h "$hashes" --arg label "$label" '
    def vkey: ltrimstr("v") | split(".") | map(tonumber? // 0);
    ($fp.skills) as $skills
    | ([$fp.tags | keys[]] | sort_by(vkey) | reverse) as $tags
    | def differing($t): [$skills[] | select($h[.] != $fp.tags[$t][.])];
    if all($skills[]; $h[.] == null) then {status: "absent"}
    elif ($fp.tags | has($label)) and (differing($label) | length) == 0 then {status: "match", tag: $label}
    else
      ([$tags[] | select(differing(.) | length == 0)]) as $matches
      | if ($matches | length) > 0 then {status: "match", tag: $matches[0]}
        else
          ([$tags[] | {tag: ., d: differing(.)}] | min_by(.d | length)) as $near
          | {status: "unreviewed", tag: $near.tag,
             differing: [$near.d[] | select($h[.] != null)],
             missing: [$near.d[] | select($h[.] == null)],
             label: (if $label == "" then null else $label end)}
        end
    end'
}

# The read for one pack on one harness, against one project, as one JSON
# object: the harness-specific result plus whether the harness is inside the
# adapter's runtime list, which side is missing when it is not, and whether
# firstmate's read for it is proven live.
fm_bp_read() {  # <owner/repo> <harness> <project-dir>
  local repo=$1 harness=$2 project=$3 manifest plugin entry proj checkout read side r
  manifest=$(fm_bp_manifest "$repo")
  plugin=$(jq -r '.plugin' "$manifest")
  entry=$(jq -c --arg h "$harness" '.harnesses[$h] // null' "$manifest")
  if [ "$entry" = null ]; then
    side=pack
    fm_control_harness_supported "$harness" || side=firstmate
    jq -cn --arg repo "$repo" --arg h "$harness" --arg side "$side" --argjson both "$(jq -c '.harnesses | keys' "$manifest")" '
      {repository: $repo, harness: $h, supported: false, unsupported_side: $side, supported_harnesses: $both,
       installed: false, enabled: false, enabled_source: null, label: null, version: null, id: null,
       where: (if $side == "firstmate" then "firstmate has not verified \($h)" else "the pack ships no install path for \($h)" end)}'
    return 0
  fi
  proj=$(fm_bp_project_root "$project")
  checkout=$(fm_bp_checkout_root "$project")
  read=$(jq -r '.read // empty' <<<"$entry")
  case "$read" in
    claude-plugin) r=$(fm_bp_read_claude "$repo" "$plugin" "$proj" "$checkout") ;;
    omp-plugin) r=$(fm_bp_read_omp "$repo" "$plugin" "$checkout") ;;
    codex-config) r=$(fm_bp_read_codex "$repo" "$plugin") ;;
    agy-plugin-list) r=$(fm_bp_read_agy "$repo" "$plugin") ;;
    skills-dir) r=$(fm_bp_read_skills_dir "$repo" "$plugin" "$checkout" "$entry" "$(jq -c '.skills' "$manifest")") ;;
    *) r=$(fm_bp_result false false "" "" "" "no read is implemented for $harness") ;;
  esac
  # The version is the pack's content, not the runtime's label: the files the
  # adapter depends on are fingerprinted (fm_bp_fingerprint), and a copy that
  # holds none of them is no usable copy at all.
  local fp=null
  if [ "$(jq -r '.installed' <<<"$r")" = true ]; then
    fp=$(fm_bp_fingerprint "$manifest" "$(jq -c '.copy' <<<"$r")" "$(jq -r '.label // empty' <<<"$r")")
    if [ "$(jq -r '.status' <<<"$fp")" = absent ]; then
      r=$(jq -c '.installed = false | .enabled = false | .enabled_source = null
        | .where += "; but its copy holds none of the skill files the adapter depends on"' <<<"$r")
      fp=null
    fi
  fi
  # A proof can exclude one scope (proof.unproven_scopes): a pack found only
  # there is reported unproven, so it is never claimed.
  jq -c --arg repo "$repo" --arg h "$harness" --argjson e "$entry" --argjson fp "$fp" --argjson tags "$(jq -c '[.versions[].tag]' "$manifest")" '
    ((.enabled_source // "") as $src | ($e.proof.unproven_scopes // []) | index($src) != null) as $scope_unproven
    | (if $scope_unproven then "unproven" else $e.proof.status end) as $proof
    | . + {repository: $repo, harness: $h, supported: true, shape: $e.shape, read: $e.read,
         proof: $proof,
         proof_reason: (if $proof != "unproven" then null elif $scope_unproven then $e.proof.unproven else $e.proof.reason end),
         supported_versions: $tags,
         fingerprint: $fp,
         version: (if $fp == null then null elif $fp.status == "match" then $fp.tag else "unreviewed" end),
         version_supported: ($fp != null and $fp.status == "match")}' <<<"$r"
}

# ---- composition ----------------------------------------------------------------

# The rows that apply to a brief composition for <kind> and the value each
# takes, as {"<row id>": {"value": ..., "source": "..."}}. A fact row's value is its gate;
# a noul or choice row whose gate fails is false; otherwise the routed answer in
# <answers-json> wins, and with none the row's own fallback stands, which is
# the adapter's static behavior.
fm_bp_row_values() {  # <manifest> <kind> <mode> <forge> <answers-json>
  jq -c --arg kind "$2" --arg mode "$3" --arg forge "$4" --argjson answers "$5" --arg wt "$FM_BP_WORKER_TARGETS" '
    . as $m
    | ([($wt | split(" "))[] | . as $n | select(($m.facets[$n].kinds // []) | index($kind) != null)]
       + [($m.insert // [])[] | select(.side == "worker" and ((.kinds // []) | index($kind)) != null) | .id]) as $worker
    | {kind: $kind, mode: $mode, forge: $forge} as $facts
    | def gate_ok($r): all(($r.gate // {}) | to_entries[]; $facts[.key] as $fact | (.value | index($fact)) != null);
    [ ($m.routing // [])[] | select(.facet as $fc | ($worker | index($fc)) != null) | . as $r
      | {key: $r.id, value: (
          if $r.type == "fact" then {value: gate_ok($r), source: "fact \(($r.gate | to_entries | map("\(.key)=\($facts[.key])") | join(" ")))"}
          elif gate_ok($r) | not then {value: (if $r.type == "noul" then false else null end), source: "gate"}
          elif $answers | has($r.id) then $answers[$r.id]
          else {value: $r.fallback, source: "fallback"} end)} ]
    | from_entries' "$1"
}

# How a section heading names what the adapter does at that place.
fm_bp_action_phrase() {  # <action-code> <noun>
  case "$1" in
    replace) printf "stands in for firstmate's %s" "$2" ;;
    pair-pack-first) printf "pairs with firstmate's %s, the pack's first" "$2" ;;
    pair-firstmate-first) printf "pairs with firstmate's %s, firstmate's first" "$2" ;;
    *) printf "extends firstmate's %s" "$2" ;;
  esac
}

# Print the practice section for a ship or scout brief. <answers-json> holds
# routed values by row id ({} composes the adapter's static behavior, its full
# table). Facts: <kind> ship|scout, <mode> the ship's delivery mode or empty,
# <forge> the ship's forge or none.
fm_bp_compose() {  # <owner/repo> <kind> <mode> <forge> [answers-json]
  local repo=$1 kind=$2 mode=$3 forge=$4 answers=${5:-'{}'} manifest dir values plan tag a b c
  manifest=$(fm_bp_manifest "$repo")
  dir=$(dirname "$manifest")
  values=$(fm_bp_row_values "$manifest" "$kind" "$mode" "$forge" "$answers") || return 1
  plan=$(jq -r --arg kind "$kind" --argjson values "$values" --argjson blocks "$(fm_bp_block_map "$manifest")" \
    --arg wflow "$FM_BP_WORKER_FLOW" '
    . as $m
    | ($m.routing // []) as $rows
    | [$rows[] | select(.id as $i | $values | has($i))] as $applied
    | def row_blocks($r):
        if ($r.selects | type) == "object" then
          ($values[$r.id].value) as $v | ($r.selects[($v // "") | tostring] // [])
        elif $values[$r.id].value == true then ($r.selects // [])
        else [] end;
    ([$rows[] | (.selects // []) | if type == "object" then .[][] else .[] end] | unique) as $routed
    | ([$applied[] | row_blocks(.)[]] | unique) as $chosen
    | ([$applied[] | select(row_blocks(.) | length > 0) | (.excludes // [])[]] | unique) as $excluded
    | def included($b): (($routed | index($b)) == null or ($chosen | index($b)) != null) and ($excluded | index($b)) == null;
    def kinds_ok($e): (($e.kinds // ["ship", "scout"]) | index($kind)) != null;
    def blocks_of($name): [($blocks[$name] // [])[] | select(included(.))];
    def action_code($e): if $e.action == "pair" then "pair-\($e.order)" else $e.action end;
    ($m.facets // {}) as $f
    | ([($m.insert // [])[] | select(.side == "worker" and kinds_ok(.) and (blocks_of(.id) | length) > 0) | .id]) as $live_ins
    | ([($m.flow // ($wflow | split(" ")))[] | select(. as $p | (($m.insert // []) | map(.id) | index($p)) == null or ($live_ins | index($p)) != null)]) as $flow
    | ($flow | map(if . == "deliver" and $kind == "scout" then "scout.report" else . end)) as $steps
    | (if $flow != ($wflow | split(" ")) then "flow\t\($steps | map("`\(.)`") | join(", "))" else empty end),
      ((["brief.practice"] + $steps + ["brief.done"])[] as $name
       | if ($f | has($name)) and $name != "launch.env" and kinds_ok($f[$name]) then
           (blocks_of($name)) as $bl
           | if ($bl | length) == 0 then empty
             else ("pos\t\($name)\t\(action_code($f[$name]))\t\($f[$name].reference)", ($bl[] | "block\t\(.)"))
             end
         elif ($live_ins | index($name)) != null then
           ([($m.insert // [])[] | select(.id == $name)] | first) as $e
           | ($steps | index($name)) as $at
           | ("pos\t\($name)\tinsert:\($steps[$at + 1])\t\($e.reference)", (blocks_of($name)[] | "block\t\(.)"))
         else empty end)
  ' "$manifest") || return 1
  printf '# Best practices: %s\n' "$repo"
  # shellcheck disable=SC2016  # backticks are literal Markdown in the brief
  printf 'This project follows the best-practices pack `%s` through the adapter firstmate maintains for it.\n' "$repo"
  printf 'Every section above, the home brief additions included, takes precedence over anything in this section that conflicts.\n'
  # shellcheck disable=SC2016  # backticks are literal Markdown in the brief
  printf 'If `FM_BEST_PRACTICES_VERSION` reads `missing` in your environment, the pack is not loaded: follow firstmate'"'"'s defaults instead of this section, and say so in your done summary.\n'
  # shellcheck disable=SC2016  # backticks are literal Markdown in the brief
  printf 'If it reads `unreviewed`, a skill this section depends on differs from the text firstmate reviewed: follow this section anyway, and name the skills the "Pack read at launch" section of your instructions lists as unreviewed in your done summary.\n'
  # shellcheck disable=SC2016  # backticks are literal Markdown in the brief
  printf 'Otherwise it names the reviewed tag: name the pack and that tag in your done summary.\n'
  printf 'The pack'"'"'s skills load from your runtime'"'"'s own install of it; this section names them and copies none of them.\n'
  local current_ref=''
  while IFS=$'\t' read -r tag a b c; do
    case "$tag" in
      flow)
        printf '\n## Flow\n'
        printf 'Run the work in this order: %s.\n' "$a"
        # shellcheck disable=SC2016  # backticks are literal Markdown in the brief
        printf '`start`, your Setup'"'"'s isolation check, stays first and `report`, your done line, stays last, whatever any step below says.\n'
        ;;
      pos)
        current_ref="$dir/$c"
        case "$a:$b" in
          brief.practice:*) printf '\n## Practice (%s)\n' "$(fm_bp_action_phrase "$b" practice)" ;;
          brief.done:*) printf '\n## Done summary (%s)\n' "$(fm_bp_action_phrase "$b" "Definition of done")" ;;
          scout.report:*) printf '\n## Report (%s)\n' "$(fm_bp_action_phrase "$b" report)" ;;
          *:insert:*)
            # shellcheck disable=SC2016  # backticks are literal Markdown in the brief
            printf '\n## Step `%s` (inserted before `%s`)\n' "$a" "${b#insert:}" ;;
          *)
            # shellcheck disable=SC2016  # backticks are literal Markdown in the brief
            printf '\n## Step `%s` (%s)\n' "$a" "$(fm_bp_action_phrase "$b" "\`$a\` step")" ;;
        esac
        ;;
      block)
        fm_bp_block_body "$current_ref" "$a"
        ;;
    esac
  done <<<"$plan"
}
