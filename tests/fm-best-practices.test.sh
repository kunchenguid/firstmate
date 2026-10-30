#!/usr/bin/env bash
# Behavior tests for best-practices pack adapters: the registry token
# (bin/fm-project-mode.sh --best-practices), the manifest check, the per-harness
# pack read, the add-time propose and check, the brief's practice section
# (bin/fm-brief.sh --best-practices), routing through the typed-decision
# provider (bin/fm-best-practices.sh route and intake), and the spawn's
# registry agreement, exports, and notice (bin/fm-spawn.sh).
#
# Every harness record here is a fixture under a throwaway HOME, every
# provider call goes to a fake curl that records argv, the request body, the
# fd 3 header, and whether a key reached its environment, and no case touches
# the network or the operator's real harness configuration.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BP="$ROOT/bin/fm-best-practices.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
PACK=addyosmani/agent-skills
MANIFEST="$ROOT/.agents/skills/best-practices-adapters/references/$PACK/manifest.json"
TMP_ROOT=$(fm_test_tmproot fm-best-practices)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CURL_LOG="$TMP_ROOT/curl-log"
mkdir -p "$CURL_LOG"
unset TYPESAFE_API_KEY OPENROUTER_API_KEY FM_DISPATCH_PROVIDER FM_DISPATCH_MODEL CLAUDE_CONFIG_DIR CODEX_HOME

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv, the request body, the fd 3 header, and whether a key
# reached its environment, then answers with FAKE_CURL_RESPONSE and
# FAKE_CURL_HTTP.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'secret-present\n' > "$FAKE_CURL_LOG/env"
else
  printf 'clean\n' > "$FAKE_CURL_LOG/env"
fi
out=''
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -H)
      if [ "$2" = @/dev/fd/3 ]; then cat <&3 > "$FAKE_CURL_LOG/header"; fi
      args+=("$1" "$2"); shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
printf '%s\n' "${args[@]}" > "$FAKE_CURL_LOG/argv"
cat > "$FAKE_CURL_LOG/body"
cp "$FAKE_CURL_RESPONSE" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

# ---- fixtures ---------------------------------------------------------------------

# A fixture release of the pack, and a fixture code root whose manifest carries
# fingerprints generated from it by the real generator, so the read tests can
# install a copy that matches a reviewed tag and edit one that does not.
FIX_PACK="$TMP_ROOT/fixture-pack-0.6.14"
while IFS= read -r s; do
  mkdir -p "$FIX_PACK/skills/$s"
  printf -- '---\nname: %s\ndescription: fixture text for %s at 0.6.14\n---\n' "$s" "$s" > "$FIX_PACK/skills/$s/SKILL.md"
done < <(jq -r '.skills[]' "$MANIFEST")
FIX_ROOT="$TMP_ROOT/fixture-root"
mkdir -p "$FIX_ROOT/.agents/skills"
cp -R "$ROOT/.agents/skills/best-practices-adapters" "$FIX_ROOT/.agents/skills/"
FM_ROOT_OVERRIDE="$FIX_ROOT" "$BP" fingerprints "$PACK" --source "0.6.14=$FIX_PACK" --write >/dev/null ||
  fail "could not generate the fixture fingerprints"

pack_copy() {  # <dest> <plugin|skills>: a copy of the fixture release in that layout
  if [ "$2" = plugin ]; then
    mkdir -p "$1/skills"
    cp -R "$FIX_PACK/skills/." "$1/skills/"
  else
    mkdir -p "$1"
    cp -R "$FIX_PACK/skills/." "$1/"
  fi
}

# A throwaway user home holding a Claude Code plugin registry for the pack.
# claude_home <dir> <marketplace-plugin-source-json> [<known-marketplace-source-json>]
claude_home() {
  local home=$1 psrc=$2 msrc=${3:-'{"source":"github","repo":"addyosmani/agent-skills"}'} m="$1/.claude/plugins/marketplaces/addy-agent-skills"
  mkdir -p "$m/.claude-plugin"
  jq -n --argjson s "$psrc" '{name: "addy-agent-skills", plugins: [{name: "agent-skills", source: $s, version: "0.6.14"}]}' > "$m/.claude-plugin/marketplace.json"
  jq -n --argjson s "$msrc" --arg loc "$m" '{"addy-agent-skills": {source: $s, installLocation: $loc}}' > "$home/.claude/plugins/known_marketplaces.json"
  printf '{"version": 2, "plugins": {}}\n' > "$home/.claude/plugins/installed_plugins.json"
  printf '{}\n' > "$home/.claude/settings.json"
}

# claude_install <home> <scope> <label> [project-path] [install-path]
claude_install() {
  local home=$1 scope=$2 version=$3 project=${4:-} ipath=${5:-$FIX_PACK} file="$1/.claude/plugins/installed_plugins.json" tmp
  tmp=$(mktemp)
  jq --arg s "$scope" --arg v "$version" --arg p "$project" --arg i "$ipath" '
    .plugins["agent-skills@addy-agent-skills"] += [{scope: $s, version: $v, installPath: $i} + (if $p == "" then {} else {projectPath: $p} end)]' "$file" > "$tmp"
  mv "$tmp" "$file"
}

claude_user_enable() {  # <home> <json-value>
  jq -n --argjson v "$2" '{enabledPlugins: {"agent-skills@addy-agent-skills": $v}}' > "$1/.claude/settings.json"
}

commit_file() {  # <repo> <path> <content>
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -f "$2"
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "add $2"
}

fresh_case() {  # <name> -> "<home>|<project>"
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home"
  fm_git_init_commit "$dir/project" >/dev/null
  printf '%s\n' "$dir/home|$dir/project"
}

run_bp() {  # <home> <args...>
  local home=$1
  shift
  HOME="$home" PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/fm-home" FM_ROOT_OVERRIDE="$FIX_ROOT" "$BP" "$@"
}

field() {  # <json> <key>
  jq -r --arg k "$2" '.[$k] | tostring' <<<"$1"
}

tree_sum() {  # <dir>: a content fingerprint, to prove reads write nothing
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cat | cksum)
}

mutated_root() {  # <name> <jq-filter> -> a code root whose manifest is mutated
  local root="$TMP_ROOT/roots/$1" m
  mkdir -p "$root/.agents/skills"
  cp -R "$ROOT/.agents/skills/best-practices-adapters" "$root/.agents/skills/"
  m="$root/.agents/skills/best-practices-adapters/references/$PACK/manifest.json"
  jq "$2" "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  printf '%s\n' "$root"
}

manifest_refusal() {  # <name> <jq-filter> <expected-fragment>
  local root out status
  root=$(mutated_root "$1" "$2")
  out=$(FM_ROOT_OVERRIDE="$root" "$BP" manifest-check "$PACK" 2>&1)
  status=$?
  expect_code 1 "$status" "manifest-check accepted $1"
  assert_contains "$out" "$3" "manifest-check did not name why $1 is refused"
}

# ---- tests ------------------------------------------------------------------------

test_registry_token_is_parsed_by_project_mode_alone() {
  local data="$TMP_ROOT/registry" out status flag
  mkdir -p "$data"
  cat > "$data/projects.md" <<'EOF'
- alpha [local-only best-practices=addyosmani/agent-skills] - local (added 2026-10-29)
- beta [best-practices=addyosmani/agent-skills +yolo direct-PR branch=fix/ forge=forgejo] - first (added 2026-10-29)
- gamma [no-mistakes best-practices=obra/superpowers] - unknown pack (added 2026-10-29)
- delta [no-mistakes best-practices=] - empty (added 2026-10-29)
- eps [no-mistakes best-practices=agent-skills] - plugin name, not a repository (added 2026-10-29)
- zeta [no-mistakes best-practices=addyosmani/agent-skills best-practices=addyosmani/agent-skills] - twice (added 2026-10-29)
- plain [no-mistakes] - no token (added 2026-10-29)
EOF
  assert_equals "$PACK" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --best-practices alpha 2>&1)" "local-only did not compose with the pack"
  assert_equals "local-only off" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" alpha 2>&1)" "the token changed the two-word posture"
  assert_equals "$PACK" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --best-practices beta 2>&1)" "an order-independent token was not read"
  assert_equals "direct-PR on" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" beta 2>&1)" "a leading token was read as the mode"
  assert_equals "forgejo" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --forge beta 2>&1)" "the token disturbed the forge binding"
  assert_equals "fix/" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --branch-prefix beta 2>&1)" "the token disturbed the branch prefix"
  assert_equals "none" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --best-practices plain 2>&1)" "a project without the token is not none"
  assert_equals "none" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --best-practices missing 2>/dev/null)" "an unregistered project is not none"
  assert_equals "none" "$(FM_DATA_OVERRIDE="$TMP_ROOT/no-registry" "$PROJECT_MODE" --best-practices plain 2>/dev/null)" "an absent registry is not none"
  for flag in gamma:unknown delta:malformed eps:malformed zeta:"more than one"; do
    out=$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --best-practices "${flag%%:*}" 2>/dev/null)
    status=$?
    expect_code 3 "$status" "${flag%%:*} was not refused"
    assert_equals "" "$out" "a refused token still handed the caller a pack"
    out=$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --best-practices "${flag%%:*}" 2>&1 >/dev/null)
    assert_contains "$out" "${flag#*:}" "the ${flag%%:*} refusal does not say why"
  done
  out=$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" --best-practices gamma 2>&1 >/dev/null)
  assert_contains "$out" "carries adapters for: $PACK" "the unknown-pack refusal does not name the carried packs"
  assert_equals "no-mistakes off" "$(FM_DATA_OVERRIDE="$data" "$PROJECT_MODE" gamma 2>&1)" "an unknown pack disturbed the posture output"
  pass "fm-project-mode: best-practices= is one order-independent pack per project, refused unless carried, and changes no other output"
}

test_manifest_check_holds_the_off_limits_boundary() {
  local out
  out=$("$BP" manifest-check 2>&1) || fail "the shipped adapter does not pass its own check: $out"
  assert_contains "$out" "manifest-check: ok" "manifest-check did not report the shipped adapter clean"
  manifest_refusal facet-outside '.facets.deploy = {action: "extend", reference: "notes.md"}' "facet deploy is outside the eleven flow positions"
  manifest_refusal start-moved '.flow = ["reproduce", "start", "work", "verify", "deliver", "report"]' "flow must keep start first"
  manifest_refusal after-report '.flow = ["start", "work", "verify", "deliver", "report", "reproduce"]' "flow must keep report last"
  manifest_refusal stage-dropped '.flow = ["start", "reproduce", "work", "deliver", "report"]' "exactly once"
  manifest_refusal replace-start '.facets.start = {action: "replace", reference: "work.md", kinds: ["ship"]}' "facet start cannot be replaced or paired"
  manifest_refusal pair-report '.facets.report = {action: "pair", order: "pack-first", reference: "work.md", kinds: ["ship"]}' "facet report cannot be replaced or paired"
  manifest_refusal switches '.facets["launch.env"] = {action: "replace"}' "an adapter adds no switches"
  manifest_refusal commit-pin '.versions = [{tag: "aeac41d4"}]' "the supported list carries tags only"
  manifest_refusal row-outside '.routing += [{id: "deploy", facet: "deploy", type: "noul", instructions: "x", fallback: true, selects: ["floor"]}]' "routing row deploy facet deploy is outside"
  manifest_refusal row-missing-block '.routing[2].selects = ["no-such-block"]' "selects no-such-block, which is not a block"
  manifest_refusal unverified-harness '.harnesses.copilot = .harnesses.claude' "harness copilot is not one firstmate verifies"
  manifest_refusal unearned-proof '.harnesses.cursor.read = null | .harnesses.cursor.proof = {status: "proven", date: "2026-10-29", evidence: "none"}' "harness cursor is marked proven without a read"
  manifest_refusal bad-scope '.harnesses.cursor.proof.unproven_scopes = ["global"]' "harness cursor unproven_scopes must list user or project"
  manifest_refusal bad-switch '.harnesses.gemini.switch = {user_settings: "~/.gemini/settings.json"}' "harness gemini switch needs"
  manifest_refusal routing-drift '.facets["brief.done"].action = "replace"' "routing object disagrees"
  manifest_refusal no-fingerprints 'del(.fingerprints)' "fingerprints are missing"
  manifest_refusal fingerprint-scope '.fingerprints.skills |= .[1:]' "fingerprints.skills must be exactly the pack skills the adapter's references name"
  manifest_refusal fingerprint-tags '.versions += [{tag: "0.6.15"}]' "fingerprints.tags must hold exactly the supported tags"
  manifest_refusal fingerprint-hash '.fingerprints.tags["0.6.14"]["interview-me"] = "not-a-hash"' "must hash every fingerprinted skill as 64 lowercase hex characters"
  pass "manifest-check: refuses anything outside the eleven positions, a moved start or report, a replace at either, launch switches, untagged versions, unread proofs, routing drift, and fingerprints that do not cover exactly the named skills and supported tags"
}

test_claude_read_follows_the_registry_marketplace_and_settings() {
  local rec home proj before r out
  rec=$(fresh_case claude-read)
  IFS='|' read -r home proj <<<"$rec"
  claude_home "$home" '{"source":"github","repo":"addyosmani/agent-skills"}'
  out=$(run_bp "$home" check "$PACK" --harness claude --project "$proj")
  expect_code 1 $? "a pack with no install passed the check"
  assert_contains "$out" "problem: not-installed" "no install is not reported as not installed"
  assert_contains "$out" "claude plugin install agent-skills@addy-agent-skills" "the not-installed remedy does not name the install command"

  claude_install "$home" local 0.6.14 "$proj"
  r=$(run_bp "$home" read "$PACK" --harness claude --project "$proj")
  assert_equals false "$(field "$r" installed)" "a local-scope install was counted"

  claude_install "$home" user 0.6.14
  claude_user_enable "$home" false
  before=$(tree_sum "$home")
  out=$(run_bp "$home" check "$PACK" --harness claude --project "$proj")
  expect_code 1 $? "a disabled pack passed the check"
  assert_contains "$out" "problem: not-enabled" "a disabled pack is not reported as not enabled"
  assert_contains "$out" "disabled by enabledPlugins in $home/.claude/settings.json" "the check does not say where the pack is disabled"
  assert_contains "$out" "claude plugin enable agent-skills@addy-agent-skills --scope user" "the not-enabled remedy does not name the enable command"
  assert_equals "$before" "$(tree_sum "$home")" "the read changed the harness's own files"
  assert_contains "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "missing: installed but not enabled" "a disabled pack did not read as missing"

  mkdir -p "$proj/.claude"
  printf '{"enabledPlugins": {"agent-skills@addy-agent-skills": true}}\n' > "$proj/.claude/settings.local.json"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness claude --project "$proj")" enabled)" "a gitignored settings.local.json enabled the pack"
  printf '{"enabledPlugins": {"agent-skills@addy-agent-skills": true}}\n' > "$proj/.claude/settings.json"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness claude --project "$proj")" enabled)" "an uncommitted project settings file enabled the pack"
  commit_file "$proj" .claude/settings.json '{"enabledPlugins": {"agent-skills@addy-agent-skills": ["^0.6.0"]}}'
  r=$(run_bp "$home" read "$PACK" --harness claude --project "$proj")
  assert_equals true "$(field "$r" enabled)" "a committed version-constraint list did not enable the pack over the user's false"
  assert_equals project "$(field "$r" enabled_source)" "the project's committed enablement was not credited to the project"
  out=$(run_bp "$home" check "$PACK" --harness claude --project "$proj")
  expect_code 0 $? "an installed, enabled, supported pack failed the check: $out"
  assert_contains "$out" "status: ok" "the passing check did not say ok"
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "the version read did not report the reviewed tag the copy matches"

  git -C "$proj" worktree add -q -b copy "$TMP_ROOT/claude-read/copy"
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness claude --project "$TMP_ROOT/claude-read/copy")" "a worker copy did not map back to its project"

  claude_install "$home" project a5f0b176381e "$proj"
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "an untagged label overrode content that matches the reviewed tag"
  pass "claude read: ties the install through its marketplace, counts user and this project's scope, reads committed settings over user settings, never writes"
}

test_claude_read_ties_by_repository_not_plugin_name() {
  local rec home proj r
  rec=$(fresh_case claude-tie)
  IFS='|' read -r home proj <<<"$rec"
  claude_home "$home" '{"source":"url","url":"https://github.com/addyosmani/agent-skills.git"}'
  claude_install "$home" user 0.6.14
  claude_user_enable "$home" true
  assert_equals true "$(field "$(run_bp "$home" read "$PACK" --harness claude --project "$proj")" enabled)" "a git url source did not tie"
  claude_home "$home" '"./"'
  claude_install "$home" user 0.6.14
  claude_user_enable "$home" true
  assert_equals true "$(field "$(run_bp "$home" read "$PACK" --harness claude --project "$proj")" installed)" "a relative source did not tie through its marketplace's own repository"
  claude_home "$home" '"./"' '{"source":"github","repo":"obra/superpowers"}'
  claude_install "$home" user 0.6.14
  claude_user_enable "$home" true
  r=$(run_bp "$home" read "$PACK" --harness claude --project "$proj")
  assert_equals false "$(field "$r" installed)" "a same-named plugin from another repository was taken for the pack"
  assert_contains "$(field "$r" where)" "resolves to another repository" "the read does not say the same-named plugin resolves elsewhere"
  claude_home "$home" '{"source":"url","url":"https://github.com.evil.example/addyosmani/agent-skills.git"}'
  claude_install "$home" user 0.6.14
  claude_user_enable "$home" true
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness claude --project "$proj")" installed)" "a look-alike host tied to the pack"
  pass "claude read: the tie is the repository the marketplace resolves to, by github repo, git url, or relative path, never the plugin name or a look-alike host"
}

codex_config() {  # <home> <plugin-tables>: the git marketplace record plus the given tables
  mkdir -p "$1/.codex"
  printf '%s\n%s\n' '[marketplaces.agent-skills]
source_type = "git"
source = "https://github.com/addyosmani/agent-skills.git"

[marketplaces.local-copy]
source_type = "local"
source = "addyosmani/agent-skills"' "$2" > "$1/.codex/config.toml"
}

test_codex_read_follows_the_plugin_table_and_its_cache() {
  local rec home proj cache r out
  rec=$(fresh_case codex-read)
  IFS='|' read -r home proj <<<"$rec"
  cache="$home/.codex/plugins/cache/agent-skills/agent-skills/0.6.14"
  pack_copy "$cache" plugin
  mkdir -p "$cache/.codex-plugin"
  printf '{"name": "agent-skills", "version": "0.6.14"}\n' > "$cache/.codex-plugin/plugin.json"
  codex_config "$home" ''
  r=$(run_bp "$home" read "$PACK" --harness codex --project "$proj")
  assert_equals false "$(field "$r" installed)" "a cached copy with no plugin table was read as installed"
  codex_config "$home" '[plugins."agent-skills@agent-skills"]'
  r=$(run_bp "$home" read "$PACK" --harness codex --project "$proj")
  assert_equals "true true 0.6.14 agent-skills@agent-skills" "$(jq -r '"\(.installed) \(.enabled) \(.version) \(.id)"' <<<"$r")" "a plugin table with no enabled key was not read as Codex's default of enabled"
  codex_config "$home" '[plugins._default]
enabled = false

[plugins."agent-skills@agent-skills"]'
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness codex --project "$proj")" enabled)" "_default false did not disable a plugin with no enabled key"
  codex_config "$home" '[plugins._default]
enabled = false

[plugins."agent-skills@agent-skills"]
enabled = true'
  out=$(run_bp "$home" check "$PACK" --harness codex --project "$proj")
  expect_code 0 $? "the plugin's own enabled did not override _default: $out"
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness codex --project "$proj")" "the codex version read did not report the cached tag"
  rm -rf "$home/.codex/plugins/cache/agent-skills"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness codex --project "$proj")" installed)" "a plugin table with no cached copy was read as installed"
  pass "codex read: installed needs the plugin's table and its cached copy; its own enabled beats _default, which beats Codex's default of enabled"
}

omp_home() {  # <home>: an omp marketplace record and catalog for the pack
  local o="$1/.omp"
  mkdir -p "$o/plugins/cache/marketplaces/addy-agent-skills"
  printf '{"name": "addy-agent-skills", "plugins": [{"name": "agent-skills", "source": {"source": "github", "repo": "addyosmani/agent-skills"}}]}\n' \
    > "$o/plugins/cache/marketplaces/addy-agent-skills/marketplace.json"
  jq -n --arg c "$o/plugins/cache/marketplaces/addy-agent-skills/marketplace.json" \
    '{version: 1, marketplaces: [{name: "addy-agent-skills", sourceType: "github", sourceUri: "addyosmani/agent-skills", catalogPath: $c}]}' > "$o/marketplaces.json"
}

omp_registry() {  # <file> <scope> <enabled-json-or-empty>
  mkdir -p "$(dirname "$1")"
  jq -n --arg s "$2" --arg e "$3" --arg i "$FIX_PACK" '{version: 2, plugins: {"agent-skills@addy-agent-skills": [
    {scope: $s, installPath: $i, version: "0.6.14"} + (if $e == "" then {} else {enabled: ($e == "true")} end)]}}' > "$1"
}

test_omp_read_follows_its_registries_and_shadowing() {
  local rec home proj r
  rec=$(fresh_case omp-read)
  IFS='|' read -r home proj <<<"$rec"
  omp_home "$home"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness omp --project "$proj")" installed)" "omp read a pack nothing installed"
  omp_registry "$home/.omp/plugins/installed_plugins.json" user ''
  r=$(run_bp "$home" read "$PACK" --harness omp --project "$proj")
  assert_equals "true true user" "$(jq -r '"\(.installed) \(.enabled) \(.enabled_source)"' <<<"$r")" "a user install with no enabled key was not read as enabled"
  omp_registry "$proj/.omp/plugins/installed_plugins.json" project false
  assert_equals user "$(field "$(run_bp "$home" read "$PACK" --harness omp --project "$proj")" enabled_source)" "an uncommitted project registry was read"
  git -C "$proj" add .omp && git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm omp
  assert_equals "true user" "$(jq -r '"\(.enabled) \(.enabled_source)"' <<<"$(run_bp "$home" read "$PACK" --harness omp --project "$proj")")" "a disabled project install shadowed the enabled user install"
  omp_registry "$home/.omp/plugins/installed_plugins.json" user false
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness omp --project "$proj")" enabled)" "an install disabled everywhere read as enabled"
  commit_file "$proj" .omp/plugins/installed_plugins.json "$(jq -n --arg i "$FIX_PACK" '{version: 2, plugins: {"agent-skills@addy-agent-skills": [{scope: "project", installPath: $i, version: "0.6.14"}]}}')"
  assert_equals "true project" "$(jq -r '"\(.enabled) \(.enabled_source)"' <<<"$(run_bp "$home" read "$PACK" --harness omp --project "$proj")")" "an enabled committed project install did not shadow the disabled user one"
  pass "omp read: an enabled committed project install shadows the user install, and an entry recording enabled false is skipped"
}

test_agy_and_skills_dir_reads() {
  local rec home proj r out plugdir s
  rec=$(fresh_case other-reads)
  IFS='|' read -r home proj <<<"$rec"
  plugdir="$home/.gemini/config/plugins/agent-skills"
  pack_copy "$plugdir" plugin
  mkdir -p "$plugdir/.claude-plugin"
  printf '{"name": "agent-skills", "version": "0.6.14", "repository": "https://github.com/addyosmani/agent-skills"}\n' > "$plugdir/.claude-plugin/plugin.json"
  cat > "$FAKEBIN/agy" <<'SH'
#!/usr/bin/env bash
[ "$*" = "plugin list --json" ] || exit 2
jq -n --argjson enabled "${FAKE_AGY_ENABLED:-true}" --arg version "${FAKE_AGY_VERSION:-0.6.14}" --arg path "$FAKE_AGY_PATH" \
  '[{name: "agent-skills", enabled: $enabled, version: $version, source: "antigravity", path: $path}]'
SH
  export FAKE_AGY_PATH="$plugdir"
  chmod +x "$FAKEBIN/agy"
  out=$(run_bp "$home" check "$PACK" --harness agy --project "$proj")
  expect_code 0 $? "an enabled supported agy plugin failed the check: $out"
  printf 'a local edit\n' >> "$plugdir/skills/doubt-driven-development/SKILL.md"
  out=$(FAKE_AGY_VERSION=0.6.7 run_bp "$home" check "$PACK" --harness agy --project "$proj")
  expect_code 0 $? "an unreviewed copy was refused rather than reported: $out"
  assert_contains "$out" "status: unreviewed" "an edited agy copy was not reported unreviewed"
  assert_contains "$out" "doubt-driven-development differs from the reviewed 0.6.14 text (runtime label 0.6.7)" "the unreviewed report does not name the edited skill and the runtime's label"
  pack_copy "$plugdir" plugin
  out=$(FAKE_AGY_ENABLED=false run_bp "$home" check "$PACK" --harness agy --project "$proj")
  assert_contains "$out" "problem: not-enabled" "a disabled agy plugin was not reported"
  printf '{"name": "agent-skills", "version": "0.6.14", "repository": "https://github.com/obra/superpowers"}\n' > "$plugdir/.claude-plugin/plugin.json"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness agy --project "$proj")" installed)" "an agy plugin whose manifest names another repository was taken for the pack"
  rm -f "$FAKEBIN/agy"

  pack_copy "$home/.gemini/skills" skills
  r=$(run_bp "$home" read "$PACK" --harness gemini --project "$proj")
  assert_equals "true true user null 0.6.14" "$(jq -r '"\(.installed) \(.enabled) \(.enabled_source) \(.label) \(.version)"' <<<"$r")" "a skills directory with no version record was not matched to its reviewed tag by content"
  out=$(run_bp "$home" check "$PACK" --harness gemini --project "$proj")
  expect_code 0 $? "a skills directory matching the reviewed tag failed the check: $out"
  assert_contains "$out" "version 0.6.14" "the passing check does not name the reviewed tag"
  printf '{"skills": {"disabled": ["interview-me"]}}\n' > "$home/.gemini/settings.json"
  r=$(run_bp "$home" read "$PACK" --harness gemini --project "$proj")
  assert_equals false "$(field "$r" enabled)" "a pack skill Gemini's switch disables was read as enabled"
  assert_contains "$(field "$r" where)" "disables interview-me" "the read does not name the disabled skill"
  rm -f "$home/.gemini/settings.json"
  commit_file "$proj" .gemini/settings.json '{"skills": {"disabled": ["security-and-hardening"]}}'
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness gemini --project "$proj")" enabled)" "the project's committed switch was not read"
  rm -rf "$home/.gemini/skills/interview-me"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness gemini --project "$proj")" installed)" "a partial skills copy was taken for the pack"
  pack_copy "$home/.commandcode/skills" skills
  assert_equals true "$(field "$(run_bp "$home" read "$PACK" --harness commandcode --project "$proj")" enabled)" "a full Command Code copy was not read as enabled"
  printf '{"disabledSkills": ["idea-refine"]}\n' > "$home/.commandcode/settings.json"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness commandcode --project "$proj")" enabled)" "Command Code's disabledSkills switch was not read"
  pack_copy "$home/.cursor/skills" skills
  out=$(run_bp "$home" check "$PACK" --harness cursor --project "$proj")
  assert_contains "$out" "problem: read-unproven" "a user-level Cursor copy, a scope its proof excludes, was claimed"
  assert_contains "$out" "user-level ~/.cursor/skills read" "the unproven scope does not say why"
  assert_contains "$(run_bp "$home" version "$PACK" --harness cursor --project "$proj")" "missing: firstmate's read of cursor is not yet proven live" "an unproven scope reported a version"
  mkdir -p "$proj/.cursor"
  cp -R "$home/.cursor/skills" "$proj/.cursor/"
  git -C "$proj" add .cursor && git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm cursor
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness cursor --project "$proj")" "a committed project-level Cursor copy, the proven scope, was not read by its content"
  for h in pi pi-signed; do
    out=$(run_bp "$home" check "$PACK" --harness "$h" --project "$proj")
    assert_contains "$out" "problem: read-unproven" "$h, a harness the pack documents an install for, was not reported unproven"
    assert_contains "$out" "pi install git:github.com/addyosmani/agent-skills" "the unproven $h read does not name the pack's install path"
    assert_contains "$(run_bp "$home" version "$PACK" --harness "$h" --project "$proj")" "missing: firstmate's read of $h is not yet proven live" "an unproven $h read reported a version"
  done
  out=$(run_bp "$home" check "$PACK" --harness grok --project "$proj")
  assert_contains "$out" "problem: runtime-unsupported" "a harness the pack does not ship for passed"
  assert_contains "$out" "the pack ships no install path for grok" "the unsupported runtime does not name the missing side"
  assert_contains "$out" "claude, codex" "the unsupported runtime does not name the harnesses both support"
  assert_contains "$(run_bp "$home" check "$PACK" --harness copilot --project "$proj")" "firstmate has not verified copilot" "an unverified harness was not named as firstmate's missing side"
  pass "agy and skills-directory reads follow their own records and switches, and unproven or unsupported runtimes are named, never claimed"
}

test_read_takes_committed_files_from_the_checkout_given() {
  local rec home proj copy r s
  rec=$(fresh_case checkout-read)
  IFS='|' read -r home proj <<<"$rec"
  copy="$TMP_ROOT/checkout-read/copy"
  git -C "$proj" worktree add -q -b copy "$copy"

  # A project-scope install is identified by the clone, while the setting that
  # enables it is committed only on the worker's branch.
  claude_home "$home" '{"source":"github","repo":"addyosmani/agent-skills"}'
  claude_install "$home" project 0.6.14 "$proj"
  commit_file "$copy" .claude/settings.json '{"enabledPlugins": {"agent-skills@addy-agent-skills": true}}'
  r=$(run_bp "$home" read "$PACK" --harness claude --project "$copy")
  assert_equals "true true project" "$(jq -r '"\(.installed) \(.enabled) \(.enabled_source)"' <<<"$r")" "the worker branch's settings were not read, or its install was not identified by the clone"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness claude --project "$proj")" enabled)" "the clone read settings only the worker branch commits"

  omp_home "$home"
  omp_registry "$home/.omp/plugins/installed_plugins.json" user false
  commit_file "$copy" .omp/plugins/installed_plugins.json "$(jq -n --arg i "$FIX_PACK" '{version: 2, plugins: {"agent-skills@addy-agent-skills": [{scope: "project", installPath: $i, version: "0.6.14"}]}}')"
  assert_equals "true project" "$(jq -r '"\(.enabled) \(.enabled_source)"' <<<"$(run_bp "$home" read "$PACK" --harness omp --project "$copy")")" "the worker branch's omp registry was not read"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness omp --project "$proj")" enabled)" "the clone read an omp registry only the worker branch commits"

  mkdir -p "$copy/.cursor" "$proj/.cursor"
  pack_copy "$copy/.cursor/skills" skills
  pack_copy "$proj/.cursor/skills" skills
  printf 'an edit on the clone\n' >> "$proj/.cursor/skills/interview-me/SKILL.md"
  for s in "$copy" "$proj"; do
    git -C "$s" add -f .cursor
    git -C "$s" -c user.name=t -c user.email=t@example.invalid commit -qm cursor
  done
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness cursor --project "$copy")" "the worker branch's skill content was not the content hashed"
  assert_contains "$(run_bp "$home" version "$PACK" --harness cursor --project "$proj")" "unreviewed: interview-me differs" "the clone's own edit was not read from the clone"

  pack_copy "$home/.gemini/skills" skills
  commit_file "$proj" .gemini/settings.json '{"skills": {"disabled": ["interview-me"]}}'
  assert_equals true "$(field "$(run_bp "$home" read "$PACK" --harness gemini --project "$copy")" enabled)" "a switch only the clone commits disabled the worker's pack"
  assert_equals false "$(field "$(run_bp "$home" read "$PACK" --harness gemini --project "$proj")" enabled)" "the clone's committed switch was not read"
  pass "read: settings, registries, switches, and skills come from the checkout given, and the clone only identifies a project-scope install"
}

test_propose_reads_only_what_the_project_commits() {
  local rec home proj out
  rec=$(fresh_case propose)
  IFS='|' read -r home proj <<<"$rec"
  claude_home "$home" '{"source":"github","repo":"addyosmani/agent-skills"}'
  claude_install "$home" user 0.6.14
  out=$(run_bp "$home" propose "$proj")
  assert_contains "$out" "propose: none" "a pack only installed on the machine was proposed"
  assert_contains "$out" "carried: $PACK" "propose none does not name the carried packs"
  claude_user_enable "$home" true
  assert_contains "$(run_bp "$home" propose "$proj")" "propose: none" "a pack enabled only in user settings was proposed"
  commit_file "$proj" .claude/settings.json '{"enabledPlugins": {"agent-skills@addy-agent-skills": true}}'
  out=$(run_bp "$home" propose "$proj")
  assert_contains "$out" "propose: best-practices=$PACK (claude:" "a pack the project's committed settings enable was not proposed"
  assert_contains "$out" "the project's committed .claude/settings.json" "the proposal does not say what the project commits"
  pass "propose: only a pack enabled by what the project itself commits is proposed"
}

test_brief_composes_the_practice_section_after_the_include() {
  local home="$TMP_ROOT/brief-home" b plain out
  mkdir -p "$home/config"
  printf 'Standing home addition.\n' > "$home/config/brief-include.md"
  FM_HOME="$home" "$BRIEF" s1 demo --mode local-only --best-practices "$PACK" >/dev/null || fail "a local-only brief with a pack did not scaffold"
  b="$home/data/s1/brief.md"
  assert_grep "Delivery contract: mode=local-only best-practices=$PACK" "$b" "the ship contract line does not carry the pack"
  [ "$(grep -n '^# ' "$b" | tail -n 2 | cut -d: -f2- | paste -sd'|' -)" = "# Home brief additions|# Best practices: $PACK" ] ||
    fail "the practice section is not the last section, after the home include"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'If `FM_BEST_PRACTICES_VERSION` reads `missing`' "$b" "the practice section lacks the firstmate-owned missing line"
  assert_grep 'Every section above, the home brief additions included, takes precedence' "$b" "the practice section does not rank itself below the brief"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep '## Step `reproduce` (inserted before `work`)' "$b" "the inserted reproduce step is missing"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Run the work in this order: `start`, `reproduce`, `work`, `verify`, `deliver`, `report`.' "$b" "an inserting adapter did not state the whole order"
  assert_no_grep 'doubt-driven-development`'"'"'s in-flight doubt cycle' "$b" "the doubt cycle reached a local-only brief"
  FM_HOME="$home" "$BRIEF" s2 demo --mode no-mistakes --best-practices "$PACK" >/dev/null || fail "a no-mistakes brief with a pack did not scaffold"
  assert_grep "in-flight doubt cycle" "$home/data/s2/brief.md" "the doubt cycle is missing from a no-mistakes brief"
  FM_HOME="$home" "$BRIEF" s3 demo --scout --best-practices "$PACK" >/dev/null || fail "a scout brief with a pack did not scaffold"
  b="$home/data/s3/brief.md"
  assert_grep "Delivery contract: kind=scout best-practices=$PACK" "$b" "the scout does not carry the pack on a contract line"
  assert_grep "## Report (pairs with firstmate's report, firstmate's first)" "$b" "the scout report pair is missing"
  assert_no_grep "## Done summary" "$b" "a ship-only facet reached the scout"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Run the work in this order: `start`, `reproduce`, `work`, `verify`, `scout.report`, `report`.' "$b" "the scout's flow does not name its report position"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_no_grep '`deliver`' "$b" "a scout brief names a deliver step it does not have"
  FM_HOME="$home" "$BRIEF" s4 demo --mode direct-PR >/dev/null
  FM_HOME="$home" "$BRIEF" s5 demo --mode direct-PR --best-practices none >/dev/null
  plain=$(sed 's/s4/ID/g' "$home/data/s4/brief.md")
  [ "$plain" = "$(sed 's/s5/ID/g' "$home/data/s5/brief.md")" ] || fail "--best-practices none changed the brief"
  assert_no_grep "best-practices=" "$home/data/s4/brief.md" "a brief without a pack carries a pack token"
  assert_no_grep "# Best practices" "$home/data/s4/brief.md" "a brief without a pack carries a practice section"
  out=$(FM_HOME="$home" "$BRIEF" s6 demo --mode direct-PR --best-practices obra/superpowers 2>&1)
  expect_code 1 $? "a pack with no adapter scaffolded"
  assert_contains "$out" "carries no adapter" "the unknown-pack refusal does not say why"
  assert_absent "$home/data/s6" "the refused scaffold left files behind"
  out=$(FM_HOME="$home" "$BRIEF" s7 --secondmate p1 --best-practices "$PACK" 2>&1)
  expect_code 1 $? "a secondmate charter took a pack"
  pass "fm-brief: the pack rides the contract line and its practice section lands last, ranked below every other section"
}

route_case() {  # <name> <kind-flags...> -> brief path
  local name=$1 home="$TMP_ROOT/route-home"
  shift
  mkdir -p "$home"
  FM_HOME="$home" "$BRIEF" "$name" demo "$@" --best-practices "$PACK" >/dev/null || fail "could not scaffold $name"
  printf '%s\n' "$home/data/$name/brief.md"
}

fill() {  # <brief> <intent> <spec>
  local content
  content=$(cat "$1")
  content=${content//'{TASK}'/$2}
  content=${content//'{FIRSTMATE_SPEC}'/$3}
  printf '%s\n' "$content" > "$1"
}

run_route() {  # <response-file> <http> <args...>
  local resp=$1 http=$2
  shift 2
  rm -f "$CURL_LOG"/*
  FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_RESPONSE="$resp" FAKE_CURL_HTTP="$http" \
    PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/route-fm-home" FM_CONFIG_OVERRIDE="$TMP_ROOT/route-fm-home/config" "$BP" "$@"
}

narrowing_response() {  # <file>: a confident bug fix with every optional row answered no, frontend unsure
  jq -n '{model: "jev-1.13.0", usage: {input_tokens: 600, output_tokens: 40},
    answers: {"bug-fix": {type: "noul", noul: 0.97}, trivial: {type: "noul", noul: 0.02},
      security: {type: "noul", noul: 0.03}, performance: {type: "noul", noul: 0.04}, api: {type: "noul", noul: 0.1},
      observability: {type: "noul", noul: 0.05}, deprecation: {type: "noul", noul: 0.02}, frontend: {type: "noul", noul: 0.55},
      browser: {type: "noul", noul: 0.02}, "ci-cd": {type: "noul", noul: 0.01}, refactor: {type: "noul", noul: 0.05},
      "source-driven": {type: "noul", noul: 0.03}, "source-citations": {type: "noul", noul: 0.03}, risky: {type: "noul", noul: 0.04}}}' > "$1"
}

test_route_narrows_through_the_shared_provider_code() {
  local b before_head out resp="$TMP_ROOT/route-response.json" questions
  mkdir -p "$TMP_ROOT/route-fm-home/config"
  b=$(route_case r1 --mode no-mistakes)
  fill "$b" "The pager skips a page when the count is exact." "Fix the off-by-one in pager.sh."
  before_head=$(sed '/^# Best practices: /,$d' "$b")
  out=$(run_route "$resp" 200 route "$b" 2>/dev/null)
  assert_contains "$out" "status: off" "routing ran with no key"
  [ ! -e "$CURL_LOG/argv" ] || fail "routing with no key made a network call"
  assert_grep "security-and-hardening" "$b" "the static fallback dropped a routed row"

  narrowing_response "$resp"
  out=$(TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 200 route "$b" --project demo)
  assert_contains "$out" "status: routed" "a confident answer did not route"
  assert_contains "$out" "row: frontend = true (fallback: p=0.55 is inside the 0.6 floor)" "an unconfident row did not keep its fallback"
  assert_contains "$out" "row: doubt = true (fact mode=no-mistakes)" "the fact row was not read in code"
  assert_grep "## Step \`reproduce\`" "$b" "a confident bug fix lost the reproduce step"
  assert_no_grep "security-and-hardening" "$b" "a confident no did not narrow the section"
  assert_no_grep "The rollback plan names its trigger" "$b" "a confident not-risky change kept the rollout plans"
  assert_grep "frontend-ui-engineering" "$b" "an unconfident row was narrowed away"
  [ "$before_head" = "$(sed '/^# Best practices: /,$d' "$b")" ] || fail "routing changed the brief outside its practice section"
  assert_equals clean "$(cat "$CURL_LOG/env")" "the key reached curl's environment"
  assert_not_contains "$(cat "$CURL_LOG/argv")" "ts-secret-key" "the key reached curl's argv"
  assert_contains "$(cat "$CURL_LOG/header")" "Bearer ts-secret-key" "the key did not reach curl through fd 3"
  assert_contains "$(cat "$CURL_LOG/argv")" "https://api.typesafe.ai/v1/systemone" "routing did not use the resolver's provider"
  assert_contains "$(jq -r '.state.task.brief' "$CURL_LOG/body")" "The pager skips a page" "the request did not carry the task sections"
  assert_not_contains "$(jq -r '.state.task.brief' "$CURL_LOG/body")" "Delivery contract" "the request carried the brief's boilerplate"
  questions=$(jq -c '.questions | keys' "$CURL_LOG/body")
  assert_equals '["api","browser","bug-fix","ci-cd","deprecation","frontend","observability","performance","refactor","risky","security","source-citations","source-driven","trivial"]' "$questions" "the request did not carry exactly this composition's rows in one request"
  assert_equals noul "$(jq -r '.questions["bug-fix"].type' "$CURL_LOG/body")" "a yes-or-no row was not asked as a Noul"
  cp "$b" "$TMP_ROOT/route-once"
  TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 200 route "$b" >/dev/null
  cmp -s "$b" "$TMP_ROOT/route-once" || fail "routing the same brief twice was not idempotent"

  printf 'Pager\n' > "$TMP_ROOT/route-fm-home/config/dispatch-never-send"
  out=$(TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 200 route "$b" 2>&1)
  assert_contains "$out" "brief text matches $TMP_ROOT/route-fm-home/config/dispatch-never-send line 1; nothing sent" "a never-send match was sent"
  [ ! -e "$CURL_LOG/argv" ] || fail "a never-send match reached curl"
  assert_grep "security-and-hardening" "$b" "a withheld request did not fall back to the full table"
  rm -f "$TMP_ROOT/route-fm-home/config/dispatch-never-send"

  out=$(TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 500 route "$b" 2>/dev/null)
  assert_contains "$out" "status: error" "an HTTP failure was not an error outcome"
  assert_grep "security-and-hardening" "$b" "an HTTP failure did not fall back to the full table"
  printf '{"answers": {"bug-fix": {"noul": "yes"}}}\n' > "$TMP_ROOT/bad-response.json"
  out=$(TYPESAFE_API_KEY=ts-secret-key run_route "$TMP_ROOT/bad-response.json" 200 route "$b" 2>/dev/null)
  assert_contains "$out" "status: error" "a malformed answer was trusted"

  rm -f "$CURL_LOG"/*
  out=$(FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=oa-secret-key run_route "$resp" 200 route "$b" 2>&1)
  assert_contains "$out" "status: off" "routing sent a System One request to OpenAI's Decisions API"
  assert_contains "$out" "FM_DISPATCH_PROVIDER=openai does not take" "the openai refusal does not say why"
  [ ! -e "$CURL_LOG/argv" ] || fail "routing reached curl under the openai provider"
  out=$(FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=local FM_DISPATCH_BASE_URL=http://127.0.0.1:8080/ run_route "$resp" 200 route "$b" 2>/dev/null)
  assert_contains "$out" "status: routed" "routing did not use a keyless systemone host"
  assert_contains "$(cat "$CURL_LOG/argv")" "http://127.0.0.1:8080/v1/systemone" "routing did not post to the systemone endpoint"
  [ ! -e "$CURL_LOG/header" ] || fail "a keyless systemone request carried an Authorization header"

  b=$(route_case r2 --scout)
  fill "$b" "Ideate on a search page for the docs." "Research only."
  out=$(run_route "$resp" 200 route "$b" 2>/dev/null)
  assert_contains "$out" 'row: idea-report = true (words "ideate")' "the requester's own words did not win in code"
  assert_grep "idea-refine" "$b" "the one-pager shape is missing for an idea"
  assert_no_grep "Add a spec and plan in the pack's shape" "$b" "the one-pager did not replace the spec shape"
  pass "route: one request through the resolver's provider code narrows only on confidence, reads facts and words in code, and falls back on no key, never-send, or error"
}

test_route_rewrites_the_real_section_past_fenced_examples() {
  local b out resp="$TMP_ROOT/fence-response.json" head="# Best practices: $PACK" spec
  mkdir -p "$TMP_ROOT/route-fm-home/config"
  narrowing_response "$resp"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  spec=$(printf '%s\n' 'Fix the pager, as these examples show.' '````markdown' '```' '````' '' '~~~markdown' "$head" '~~~')
  b=$(route_case fence-1 --mode no-mistakes)
  fill "$b" "The pager skips a page when the count is exact." "$spec"
  out=$(TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 200 route "$b")
  assert_contains "$out" "status: routed" "a brief with fenced examples did not route"
  assert_no_grep "security-and-hardening" "$b" "a backtick example inside a longer fence hid the real section from the rewrite"
  assert_equals 2 "$(grep -cxF "$head" "$b")" "the tilde-fenced example was not left as written"
  assert_grep "Fix the pager, as these examples show." "$b" "the rewrite changed the task sections"

  printf '\n~~~\n# Not a section\n~~~\n\n# Later section\nKept.\n' >> "$b"
  TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 200 route "$b" >/dev/null
  assert_no_grep "# Not a section" "$b" "a fenced line ended the practice section early"
  assert_grep "# Later section" "$b" "the rewrite took the section after the practice section"
  assert_grep "Kept." "$b" "the rewrite took the body of the section after the practice section"

  b=$(route_case fence-2 --mode no-mistakes)
  sed -i.bak '/^# Best practices: /,$d' "$b"
  printf '~~~\n%s\n~~~\n' "$head" >> "$b"
  out=$(run_route "$resp" 200 route "$b" 2>&1)
  expect_code 2 $? "a heading only inside a fence was taken for the practice section"
  assert_contains "$out" "has no '$head' section" "the refusal does not name the missing section"
  pass "route: the rewrite follows the brief reader's fence rules, so examples never hide, replace, or cut the real section"
}

test_intake_tier_routing() {
  local ask="$TMP_ROOT/ask.txt" out resp="$TMP_ROOT/intake-response.json"
  mkdir -p "$TMP_ROOT/route-fm-home/config"
  printf 'Build a billing system for us.\n' > "$ask"
  out=$(run_route "$resp" 200 intake "$PACK" "$ask" 2>/dev/null)
  assert_contains "$out" "row: tier = tier-2 (fallback)" "no key did not fall back to the one question of today"
  printf 'Grill me on this billing system.\n' > "$ask"
  out=$(run_route "$resp" 200 intake "$PACK" "$ask" 2>/dev/null)
  assert_contains "$out" 'row: tier = tier-4 (words "grill me")' "the captain's own words did not win"
  printf 'Add interview metrics to the candidate page and update the grill menu.\n' > "$ask"
  out=$(run_route "$resp" 200 intake "$PACK" "$ask" 2>/dev/null)
  assert_contains "$out" "row: tier = tier-2 (fallback)" "a phrase inside a longer word was taken as the captain's words"
  printf 'Build a billing system for us.\n' > "$ask"
  jq -n '{answers: {tier: {type: "choice", choice: "tier-3", confidence: 0.9, probabilities: {"tier-1": 0.02, "tier-2": 0.05, "tier-3": 0.9, none: 0.03}}, idea: {type: "noul", noul: 0.1}}}' > "$resp"
  out=$(TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 200 intake "$PACK" "$ask")
  assert_contains "$out" "row: tier = tier-3 (routed confidence 0.9)" "a confident tier was not taken"
  assert_contains "$out" "row: idea = false" "a confident not-an-idea was not taken"
  assert_equals choice "$(jq -r '.questions.tier.type' "$CURL_LOG/body")" "the tier was not asked as a Choice"
  assert_equals '["none","tier-1","tier-2","tier-3"]' "$(jq -c '.questions.tier.criteria | keys' "$CURL_LOG/body")" "the tier Choice lacks its fixed none option"
  jq -n '{answers: {tier: {type: "choice", choice: "tier-3", confidence: 0.4, probabilities: {"tier-1": 0.3, "tier-2": 0.3, "tier-3": 0.35, none: 0.05}}, idea: {type: "noul", noul: 0.5}}}' > "$resp"
  out=$(TYPESAFE_API_KEY=ts-secret-key run_route "$resp" 200 intake "$PACK" "$ask")
  assert_contains "$out" "row: tier = tier-2 (fallback: confidence 0.4 below 0.6)" "a low-confidence tier was taken"
  pass "intake: the tier is one Choice with a none option, the captain's words win, and anything short of confidence keeps one question"
}

spawn_case() {  # <name> <registry-line-suffix> -> "<home>|<proj>|<wt>|<fakebin>|<launchlog>"
  local dir="$TMP_ROOT/spawn-$1" home proj wt fakebin
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$1"
  printf -- '- project [local-only%s] - fixture (added 2026-10-29)\n' "$2" > "$home/data/projects.md"
  mkdir -p "$home/user-home/.claude/plugins"
  claude_home "$home/user-home" '{"source":"github","repo":"addyosmani/agent-skills"}'
  claude_install "$home/user-home" user 0.6.14
  printf '%s\n' "$home|$proj|$wt|$fakebin|$dir/launch.log"
}

spawn_brief() {  # <home> <id> [--best-practices <pack>]
  FM_HOME="$1" "$BRIEF" "$2" project --mode local-only "${@:3}" >/dev/null || fail "could not scaffold $2"
  fill "$1/data/$2/brief.md" "Exercise the pack exports." "Launch only."
}

run_case_spawn() {  # <home> <wt> <fakebin> <launchlog> <id> <proj>
  : > "$4"
  FM_FAKE_LAUNCH_LOG="$4" fm_test_run_spawn "$1" "$2" "$3" "$5" "$6" claude --mode local-only --yolo off
}

test_spawn_agrees_with_the_registry_and_exports_the_pack() {
  local rec home proj wt fakebin log out launch
  rec=$(spawn_case agree " best-practices=$PACK")
  IFS='|' read -r home proj wt fakebin log <<<"$rec"
  spawn_brief "$home" bp-none
  if out=$(run_case_spawn "$home" "$wt" "$fakebin" "$log" bp-none "$proj"); then
    fail "a brief without the registered pack launched"
  fi
  assert_contains "$out" "best-practices mismatch for bp-none" "the drift refusal does not name the mismatch"
  assert_contains "$out" "--best-practices $PACK" "the drift refusal does not print a re-scaffold that carries the pack"
  assert_absent "$home/state/bp-none.meta" "the refused spawn recorded a task"

  claude_user_enable "$home/user-home" true
  spawn_brief "$home" bp-on --best-practices "$PACK"
  out=$(run_case_spawn "$home" "$wt" "$fakebin" "$log" bp-on "$proj")
  expect_code 0 $? "an agreeing brief did not launch: $out"
  # The spawn reads the shipped manifest, whose fingerprints come from the real
  # 0.6.14 release, so the fixture copy is a loaded pack with unreviewed text.
  launch=$(cat "$log")
  assert_contains "$launch" "export FM_BEST_PRACTICES='$PACK';" "the launch does not export the pack"
  assert_contains "$launch" "export FM_BEST_PRACTICES_VERSION='unreviewed';" "a loaded copy that matches no reviewed text did not export unreviewed"
  assert_not_contains "$out" "FM_BEST_PRACTICES_VERSION=missing" "a loaded pack was reported missing"
  [ "$(printf '%s\n' "$out" | grep -c 'FM_BEST_PRACTICES_VERSION=unreviewed')" -eq 1 ] || fail "the unreviewed pack did not print exactly one notice: $out"
  assert_contains "$out" "interview-me" "the unreviewed notice does not name the differing skills"
  assert_contains "$out" "(runtime label 0.6.14)" "the unreviewed notice does not give the runtime's label as a hint"
  assert_grep "# Pack read at launch" "$home/data/bp-on/launch-brief.md" "the launch brief does not list the unreviewed skills for the worker"
  assert_no_grep "# Pack read at launch" "$home/data/bp-on/brief.md" "the launch-time list was written into the authored brief"

  claude_user_enable "$home/user-home" false
  spawn_brief "$home" bp-off --best-practices "$PACK"
  out=$(run_case_spawn "$home" "$wt" "$fakebin" "$log" bp-off "$proj")
  expect_code 0 $? "a disabled pack blocked the launch: $out"
  assert_contains "$(cat "$log")" "export FM_BEST_PRACTICES_VERSION='missing';" "a disabled pack did not export missing"
  [ "$(printf '%s\n' "$out" | grep -c 'FM_BEST_PRACTICES_VERSION=missing')" -eq 1 ] || fail "the missing pack did not print exactly one notice: $out"

  rec=$(spawn_case plain "")
  IFS='|' read -r home proj wt fakebin log <<<"$rec"
  spawn_brief "$home" bp-plain
  out=$(run_case_spawn "$home" "$wt" "$fakebin" "$log" bp-plain "$proj")
  expect_code 0 $? "a project without a pack did not launch: $out"
  assert_not_contains "$(cat "$log")" "FM_BEST_PRACTICES" "a project without a pack exported one"
  spawn_brief "$home" bp-extra --best-practices "$PACK"
  if out=$(run_case_spawn "$home" "$wt" "$fakebin" "$log" bp-extra "$proj"); then
    fail "a brief naming a pack the registry does not launched"
  fi
  assert_contains "$out" "best-practices mismatch for bp-extra" "the reverse drift was not refused"

  rec=$(spawn_case unknown " best-practices=obra/superpowers")
  IFS='|' read -r home proj wt fakebin log <<<"$rec"
  spawn_brief "$home" bp-unknown
  if out=$(run_case_spawn "$home" "$wt" "$fakebin" "$log" bp-unknown "$proj"); then
    fail "a registered pack with no adapter launched"
  fi
  assert_contains "$out" "unknown best-practices pack" "the parser's refusal did not reach the operator"
  pass "fm-spawn: the brief must carry the registered pack, the launch exports it with unreviewed or missing as the read finds it, and each launches with one notice"
}

test_spawn_reads_the_worker_copy_at_its_launch_commit() {
  local rec home proj wt fakebin log out upstream
  rec=$(spawn_case behind-origin " best-practices=$PACK")
  IFS='|' read -r home proj wt fakebin log <<<"$rec"
  # Origin has moved past the clone: only origin's tip, which the spawn resets
  # the worker copy to, commits the setting that enables the pack.
  upstream="$TMP_ROOT/spawn-behind-origin/upstream"
  git clone -q "$proj.origin.git" "$upstream"
  commit_file "$upstream" .claude/settings.json '{"enabledPlugins": {"agent-skills@addy-agent-skills": true}}'
  git -C "$upstream" push -q origin HEAD
  spawn_brief "$home" bp-behind --best-practices "$PACK"
  out=$(run_case_spawn "$home" "$wt" "$fakebin" "$log" bp-behind "$proj")
  expect_code 0 $? "a worker copy ahead of the clone did not launch: $out"
  assert_absent "$proj/.claude/settings.json" "the clone was moved, so it no longer stands behind the worker copy"
  assert_contains "$(git -C "$wt" show HEAD:.claude/settings.json)" "agent-skills@addy-agent-skills" "the worker copy did not reach origin's tip"
  assert_contains "$(cat "$log")" "export FM_BEST_PRACTICES_VERSION='unreviewed';" "the read did not see what the worker copy commits at launch"
  assert_not_contains "$out" "FM_BEST_PRACTICES_VERSION=missing" "the pack the worker copy enables was reported missing"
  assert_grep "# Pack read at launch" "$home/data/bp-behind/launch-brief.md" "the launch brief does not carry the read made from the worker copy"
  pass "fm-spawn: the pack read sees the worker copy at its launch commit, not the clone"
}

test_fingerprints_read_the_content_not_the_label() {
  local rec home proj copy out r crlf s
  rec=$(fresh_case fingerprints)
  IFS='|' read -r home proj <<<"$rec"
  crlf="$TMP_ROOT/fixture-pack-crlf"
  mkdir -p "$crlf/skills"
  for s in $(jq -r '.fingerprints.skills[]' "$FIX_ROOT/.agents/skills/best-practices-adapters/references/$PACK/manifest.json"); do
    mkdir -p "$crlf/skills/$s"
    perl -pe 's/\n/\r\n/' "$FIX_PACK/skills/$s/SKILL.md" > "$crlf/skills/$s/SKILL.md"
  done
  assert_equals "$(jq -c '.fingerprints' "$FIX_ROOT/.agents/skills/best-practices-adapters/references/$PACK/manifest.json")" \
    "$(FM_ROOT_OVERRIDE="$FIX_ROOT" "$BP" fingerprints "$PACK" --source "0.6.14=$crlf" | jq -c .)" "CRLF line endings changed the generated fingerprints"
  rm -f "$crlf/skills/interview-me/SKILL.md"
  out=$(FM_ROOT_OVERRIDE="$FIX_ROOT" "$BP" fingerprints "$PACK" --source "0.6.14=$crlf" 2>&1)
  expect_code 2 $? "the generator accepted a release missing a skill the adapter names"
  assert_contains "$out" "carries no skills/interview-me/SKILL.md" "the generator does not name the missing skill"

  claude_home "$home" '{"source":"github","repo":"addyosmani/agent-skills"}'
  claude_user_enable "$home" true
  copy="$TMP_ROOT/fingerprints/copy"
  pack_copy "$copy" plugin
  claude_install "$home" user 0.6.13 "" "$copy"
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "a copy whose content matches 0.6.14 was read by its 0.6.13 label"
  perl -pi -e 's/\n/\r\n/' "$copy/skills/idea-refine/SKILL.md"
  assert_equals 0.6.14 "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "a copy with CRLF line endings did not match"
  printf 'a local edit\n' >> "$copy/skills/interview-me/SKILL.md"
  out=$(run_bp "$home" check "$PACK" --harness claude --project "$proj")
  expect_code 0 $? "an unreviewed copy was refused rather than reported as a fact: $out"
  assert_contains "$out" "status: unreviewed" "an edited copy was not reported unreviewed"
  assert_contains "$out" "unreviewed: interview-me differs from the reviewed 0.6.14 text (runtime label 0.6.13)" "the unreviewed report does not name the edited skill, the tag, and the label"
  assert_equals "unreviewed: interview-me differs from the reviewed 0.6.14 text (runtime label 0.6.13)" \
    "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "the spawn's read of an edited copy is not unreviewed with its skills"
  rm -rf "$copy/skills/source-driven-development"
  assert_contains "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "source-driven-development is absent from the reviewed 0.6.14 text" \
    "a depended-on skill missing from the copy was not named"
  rm -rf "$copy/skills"
  mkdir -p "$copy/skills"
  r=$(run_bp "$home" read "$PACK" --harness claude --project "$proj")
  assert_equals "false null" "$(jq -r '"\(.installed) \(.version)"' <<<"$r")" "a copy holding none of the depended-on files was taken for a usable pack"
  assert_contains "$(run_bp "$home" version "$PACK" --harness claude --project "$proj")" "missing: not installed" "a copy holding none of the depended-on files did not read as missing"
  pass "fingerprints: generated from a tag with line endings normalized, a copy reads as the reviewed tag its content matches whatever its label, an edit or a missing skill is unreviewed and named, and an empty copy is missing"
}

fm_test_run \
  test_registry_token_is_parsed_by_project_mode_alone \
  test_manifest_check_holds_the_off_limits_boundary \
  test_claude_read_follows_the_registry_marketplace_and_settings \
  test_claude_read_ties_by_repository_not_plugin_name \
  test_codex_read_follows_the_plugin_table_and_its_cache \
  test_omp_read_follows_its_registries_and_shadowing \
  test_agy_and_skills_dir_reads \
  test_fingerprints_read_the_content_not_the_label \
  test_read_takes_committed_files_from_the_checkout_given \
  test_propose_reads_only_what_the_project_commits \
  test_brief_composes_the_practice_section_after_the_include \
  test_route_narrows_through_the_shared_provider_code \
  test_route_rewrites_the_real_section_past_fenced_examples \
  test_intake_tier_routing \
  test_spawn_agrees_with_the_registry_and_exports_the_pack \
  test_spawn_reads_the_worker_copy_at_its_launch_commit
