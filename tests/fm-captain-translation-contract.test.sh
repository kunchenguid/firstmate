#!/usr/bin/env bash
# Static regression tests for the captain-facing plain-English translation
# contract owned by AGENTS.md section 9.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
BOOTSTRAP="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
DECISION="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODEXAPP="$ROOT/.agents/skills/firstmate-codexapp/SKILL.md"
FMX="$ROOT/.agents/skills/fmx-respond/SKILL.md"
UPDATE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"
AHOY="$ROOT/.agents/skills/ahoy/SKILL.md"
RUNLIT="$ROOT/.agents/skills/runlit-lab-fix/SKILL.md"
README="$ROOT/README.md"

section_9() {
  awk '
    /^## 9\. Escalation and captain etiquette$/ { found = 1 }
    found && /^## 10\. / { exit }
    found { print }
  ' "$AGENTS"
}

test_section_9_owns_positive_translation_contract() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Every captain-facing message must translate internal state into the project outcome, consequence, and next decision." \
    "section 9 does not own the positive captain-facing translation contract"
  assert_contains "$contract" "Use the captain's nouns:" \
    "section 9 does not require captain-owned nouns"
  assert_contains "$contract" "When evidence uses an internal label, rewrite it before sending:" \
    "section 9 does not own the rewrite mapping list"
  pass "section 9 owns the positive captain-facing translation contract"
}

test_scout_remains_allowed_house_vocabulary() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation" \
    "section 9 does not preserve scout as allowed Firstmate vocabulary"
  assert_not_contains "$contract" "scout -> investigation" \
    "section 9 must not map scout to investigation"
  assert_not_contains "$contract" "scout, ship" \
    "section 9 must not add scout to the internal-vocabulary ban"
  assert_not_contains "$contract" "secondmate -> domain supervisor" \
    "section 9 must not map secondmate to domain supervisor"
  pass "scout remains allowed in private captain chat"
}

test_compressed_safety_labels_have_plain_renderings() {
  local contract
  contract=$(section_9)
  for phrase in \
    "fail-closed" \
    "fails closed" \
    "fail-open" \
    "fails open" \
    "fail loudly"; do
    assert_contains "$contract" "$phrase" "section 9 does not cover compressed safety label '$phrase'"
  done
  assert_contains "$contract" "stops safely when something goes wrong" \
    "fail-closed behavior lacks a concrete plain rendering"
  assert_contains "$contract" "refuses rather than proceeding" \
    "fail-closed behavior lacks refusal wording"
  assert_contains "$contract" "steps aside and lets work continue when the check cannot complete" \
    "fail-open behavior lacks a concrete plain rendering"
  pass "compressed safety labels require concrete plain renderings"
}

test_mapping_list_covers_high_risk_internal_families() {
  local contract
  contract=$(section_9)
  for phrase in \
    "worktree, checkout, primary checkout, or local-main -> local copy" \
    "teardown -> cleanup" \
    "wake, watcher, heartbeat, stale, signal, or check -> notification" \
    "hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision" \
    "done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result" \
    "brief -> instructions" \
    "crewmate -> worker" \
    "harness, backend, runtime, or adapter -> worker runtime or tool" \
    "status file, metadata, state, task id, or raw path -> durable record"; do
    assert_contains "$contract" "$phrase" "section 9 mapping list is missing '$phrase'"
  done
  pass "section 9 maps high-risk internal vocabulary families"
}

test_verbatim_internal_evidence_is_rejected_from_chat() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into captain chat." \
    "section 9 does not reject verbatim internal evidence in captain chat"
  assert_contains "$contract" "Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms" \
    "section 9 does not preserve private evidence precision"
  assert_contains "$contract" "the captain-facing chat summary that points to the report still follows this translation rule" \
    "section 9 does not keep chat summaries plain English"
  pass "captain chat rejects verbatim internal evidence while private reports stay precise"
}

test_outward_facing_skill_points_reference_section_9_owner() {
  assert_grep "using \`AGENTS.md\` section 9's captain-facing translation contract" "$BOOTSTRAP" \
    "bootstrap diagnostics do not reference section 9 at captain handoff"
  assert_grep "Acknowledge** in \`AGENTS.md\` section 9 language" "$AFK" \
    "afk acknowledgement does not reference section 9"
  assert_grep "Captain, away mode is active; I will batch routine updates" "$AFK" \
    "afk acknowledgement lacks a local plain-English example"
  assert_grep "as decisions from Bearings' Captain's Call section under \`AGENTS.md\` section 9" "$DECISION" \
    "decision relay does not reference section 9"
  assert_grep "using \`AGENTS.md\` section 9; do not mention metadata, harness, window, or worktree" "$RECOVERY" \
    "stuck-worker failure does not reference section 9"
  assert_grep "under \`AGENTS.md\` section 9 that the requested worker runtime is not verified yet" "$HARNESS" \
    "runtime fallback does not reference section 9"
  assert_grep "use firstmate's own verified runtime for current work" "$HARNESS" \
    "runtime fallback does not require the current-work fallback"
  assert_grep "Do not pause current work for that future-verification choice, and never launch an unverified adapter." "$HARNESS" \
    "runtime fallback permits waiting on future verification or launching an unverified adapter"
  assert_grep "translate status prefixes and return-channel evidence through \`AGENTS.md\` section 9" "$CODEXAPP" \
    "Codex Desktop result reporting does not reference section 9"
  assert_grep "It supplements \`AGENTS.md\` section 9; apply both, and this public-channel rule wins wherever it is stricter." "$FMX" \
    "X reply safety does not state that it supplements section 9"
  assert_grep "under \`AGENTS.md\` section 9 without firstmate's internal vocabulary" "$UPDATE" \
    "Firstmate update reporting does not reference section 9"
  assert_grep "using \`AGENTS.md\` section 9's captain-facing translation contract" "$RUNLIT" \
    "RunLit lab repair reporting does not reference section 9"
  pass "outward-facing skill handoffs point to the section 9 owner"
}

test_section_9_owner_is_not_duplicated_into_skills() {
  local duplicate_count file
  duplicate_count=0
  for file in "$BOOTSTRAP" "$AFK" "$DECISION" "$RECOVERY" "$HARNESS" "$CODEXAPP" "$UPDATE" "$RUNLIT"; do
    if grep -Fq "When evidence uses an internal label, rewrite it before sending:" "$file"; then
      duplicate_count=$((duplicate_count + 1))
    fi
  done
  [ "$duplicate_count" -eq 0 ] || fail "skills duplicated section 9's mapping owner"
  pass "skills cross-reference section 9 instead of duplicating the mapping list"
}

test_runlit_lab_fix_is_bounded_and_user_invocable() {
  local trigger_count

  assert_present "$RUNLIT" "RunLit lab repair skill is missing"
  assert_grep 'name: runlit-lab-fix' "$RUNLIT" "RunLit lab repair skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$RUNLIT" "RunLit lab repair skill is not user-invocable"
  assert_grep '  internal: true' "$RUNLIT" "RunLit lab repair skill is not internal"
  [ ! -e "$ROOT/skills/runlit-lab-fix" ] || fail "RunLit lab repair must not exist in the public installer-facing skills directory"
  trigger_count=$(grep -Fc 'load the `runlit-lab-fix` skill' "$AGENTS")
  [ "$trigger_count" -eq 1 ] || fail "runlit-lab-fix must have exactly one AGENTS.md trigger, found $trigger_count"
  assert_grep '| `/runlit-lab-fix`' "$README" "README built-in skills table does not list /runlit-lab-fix"
  pass "RunLit lab repair is internal, user-invocable, and precisely triggered"
}

# One line per kubectl command the skill prescribes, taken from its code spans
# and fenced blocks and excluding the "Hard boundaries" prohibition list, where
# naming a forbidden verb strengthens the contract instead of authorizing it.
# Whole commands, not a `kubectl <verb>` prefix: the guards below match a
# forbidden verb or a cluster-wide selector anywhere in the command, so no flag
# order and no `--context=default` pin can hide a mutation from them.
runlit_prescribed_kubectl() {
  awk '
    /^## Hard boundaries$/ { skipping = 1; next }
    skipping && /^## / { skipping = 0 }
    skipping { next }
    /^```/ { fence = !fence; next }
    fence { if ($0 ~ /kubectl/) print; next }
    {
      rest = $0
      while (match(rest, /`[^`]*`/)) {
        span = substr(rest, RSTART + 1, RLENGTH - 2)
        if (span ~ /kubectl/) print span
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$RUNLIT"
}

# The same body with every code span and fenced block stripped, so a kubectl
# command written as bare prose - which the extractor above would never see -
# still has to answer to a guard.
runlit_uncoded_prose() {
  awk '
    /^## Hard boundaries$/ { skipping = 1; next }
    skipping && /^## / { skipping = 0 }
    skipping { next }
    /^```/ { fence = !fence; next }
    fence { next }
    { gsub(/`[^`]*`/, " "); print }
  ' "$RUNLIT"
}

# Standalone-word match so `replicasets` never reads as `set` and
# `--field-selector` never reads as `select`.
runlit_kubectl_mentions() {
  printf '%s\n' "$1" | grep -Eq -- "(^|[^[:alnum:]_-])$2([^[:alnum:]_-]|\$)"
}

test_runlit_lab_fix_owns_safe_repair_contract() {
  for phrase in \
    'kubectl config current-context' \
    'kubectl config view --minify --context=default -o jsonpath="{.clusters[0].cluster.server}"' \
    'lab API server documented in `scripts/k3s/CLUSTER-STATE.md`' \
    'Do not accept a context name as proof of cluster identity' \
    'is no defense against a changed `KUBECONFIG`' \
    "the home's \`data/projects.md\` registry names" \
    'require only that the worktree'"'"'s base is the project'"'"'s default branch' \
    'Prove currency by comparing the checkout'"'"'s base against the live remote default-branch commit' \
    'never compare the task-branch HEAD' \
    'never as the proof itself' \
    'Do not label an unavailable storefront or backend health URL as a monitoring gap' \
    'Never run `git fetch`, or any other state-changing git command, under `projects/`' \
    'Do not open a `kubectl port-forward` or `kubectl proxy` tunnel' \
    'external read-only URLs that `scripts/k3s/CLUSTER-STATE.md` documents' \
    'record that one service'"'"'s target and alert state as unavailable' \
    'never report an unavailable check as healthy, and never report it as a failed check either' \
    'Do not call monitoring or alerting healthy on an unavailable check' \
    'kubectl --context=default get replicasets -n online-boutique -l app=recommendationservice' \
    'Never widen it into a full revision or ReplicaSet template dump' \
    'kubectl --context=default get nodes -o wide' \
    'kubectl --context=default get pods -n online-boutique -o wide' \
    'kubectl --context=default get deployments -n online-boutique' \
    'kubectl --context=default get events -n online-boutique --field-selector type=Warning' \
    'Prometheus and Alertmanager' \
    'storefront and backend' \
    'kubectl --context=default rollout undo deployment/recommendationservice -n online-boutique --to-revision=<verified revision>' \
    'Never run an unqualified undo' \
    'kubectl --context=default rollout status deployment/recommendationservice -n online-boutique --timeout=60s' \
    'scripts/k3s/CLUSTER-STATE.md' \
    'scripts/k3s/README.md' \
    'docs/dogfood/oom-crashloop-validation.md' \
    'scripts/k3s/demo-chaos.sh' \
    'stop before any cluster access or mutation and escalate to the captain' \
    'Do not delete the old pod to manufacture a passing result.' \
    'Do not touch production.' \
    'Do not touch Coolify.' \
    'Do not touch the private Postgres rollout.' \
    'Mac mini worker runtime' \
    'Do not touch Proxmox, the NAS, DNS, network configuration, provider accounts, or project code.' \
    'Do not suppress, inhibit, or silence alerts unless the captain separately asks for that action.' \
    'Never print kubeconfig contents' \
    'exact proposed command, target resources, expected effect, rollback plan, and blast radius' \
    'data/runlit-lab-fix-<UTC timestamp>.md'; do
    assert_grep "$phrase" "$RUNLIT" "RunLit lab repair contract is missing '$phrase'"
  done
  assert_no_grep '$FM_HOME/data/' "$RUNLIT" "RunLit lab repair evidence path expands FM_HOME literally instead of resolving the effective home"
  pass "RunLit lab repair owns one guarded mutation and the required evidence and safety boundaries"
}

test_runlit_lab_fix_prescribes_no_mutating_or_cluster_wide_kubectl() {
  local prescribed verb line
  prescribed=$(runlit_prescribed_kubectl)
  assert_contains "$prescribed" 'kubectl --context=default get nodes -o wide' \
    "the prescribed kubectl commands could not be extracted, so the guards below are dead"
  for verb in delete apply patch create replace edit set scale autoscale expose annotate label taint drain cordon uncordon \
    exec attach cp proxy port-forward debug; do
    if runlit_kubectl_mentions "$prescribed" "$verb"; then
      fail "RunLit lab repair skill prescribes a forbidden 'kubectl $verb' command"
    fi
  done
  if printf '%s\n' "$prescribed" | grep -Eq 'rollout[[:space:]]+restart'; then
    fail "RunLit lab repair skill prescribes a rollout restart"
  fi
  if runlit_kubectl_mentions "$prescribed" '-A' || runlit_kubectl_mentions "$prescribed" '--all-namespaces'; then
    fail "RunLit lab repair skill prescribes a cluster-wide read"
  fi
  # Every prescribed request-issuing command must carry the pin; only the local
  # `kubectl config` reads, which touch no cluster, are exempt.
  while IFS= read -r line; do
    case "$line" in
      *'kubectl config'*) continue ;;
      *kubectl*) : ;;
      *) continue ;;
    esac
    case "$line" in
      *'--context=default'*) : ;;
      *) fail "RunLit lab repair skill prescribes an unpinned cluster command: $line" ;;
    esac
  done <<< "$prescribed"
  # A real command written outside a code span would bypass the extractor above.
  if printf '%s\n' "$(runlit_uncoded_prose)" | grep -Eq 'kubectl[[:space:]]+(-|/|(get|config|auth|rollout|delete|apply|patch|create|replace|edit|set|scale|exec|cp|drain|cordon|uncordon|label|annotate|taint|port-forward|proxy|attach|debug|top|logs|describe|wait|expose|autoscale)([^[:alnum:]_-]|$))'; then
    fail "RunLit lab repair skill writes a kubectl command outside a code span, where the command guards cannot see it"
  fi
  pass "RunLit lab repair prescribes no mutating or cluster-wide kubectl command in any flag order"
}

test_runlit_lab_fix_carries_unavailable_outcome_into_verification() {
  local verification
  verification=$(awk '
    /^## Verification$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$RUNLIT")
  assert_contains "$verification" 'unavailable, which is neither passed nor failed' \
    "the Verification section does not carry the assessment's unavailable outcome, so an unreachable check has to be forced into pass or fail"
  assert_contains "$verification" 'do not call monitoring or alerting healthy on that evidence' \
    "the Verification section lets a missing or unreachable monitoring URL read as healthy"
  assert_contains "$verification" 'name the checks that actually ran and passed, name each unavailable check for what it was' \
    "the Verification verdict has no narrower conclusion, so an unavailable check forces a false not-healthy or a silent deviation"
  assert_contains "$verification" 'record app-health verification as unavailable' \
    "an unreachable storefront or backend health URL has no app-health label of its own"
  assert_contains "$verification" 'never as an application-level repair verified with a monitoring gap' \
    "the Verification verdict can still report an unavailable app health check as a monitoring gap"
  assert_no_grep 'unverified' "$RUNLIT" \
    "RunLit lab repair mixes 'unverified' into the 'unavailable' outcome vocabulary"
  pass "RunLit lab repair carries the unavailable outcome from assessment into the verification verdict"
}

test_runlit_lab_fix_reproves_cluster_identity_before_mutating() {
  local remediation
  remediation=$(awk '
    /^## Whitelisted remediation$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$RUNLIT")
  assert_contains "$remediation" 'kubectl config view --minify --context=default -o jsonpath="{.clusters[0].cluster.server}"' \
    "the rollback does not re-prove the lab API server immediately before mutating"
  assert_contains "$remediation" 'rollout history deployment/recommendationservice -n online-boutique' \
    "the rollback does not re-read rollout history immediately before mutating"
  assert_not_contains "$remediation" 'kubectl config current-context' \
    "the pre-mutation recheck relies on the ambient context name, which proves nothing once every command pins --context"
  pass "RunLit lab repair re-proves cluster identity and revision immediately before the one mutation"
}

test_ahoy_is_an_internal_user_invocable_skill() {
  assert_present "$AHOY" "ahoy skill is missing"
  assert_grep 'name: ahoy' "$AHOY" "ahoy skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$AHOY" "ahoy skill is not user-invocable"
  assert_grep '  internal: true' "$AHOY" "ahoy skill is not internal"
  [ ! -e "$ROOT/skills/ahoy" ] || fail "ahoy must not exist in the public installer-facing skills directory"
  pass "ahoy is internal, user-invocable, and absent from public skills"
}

test_ahoy_readme_uses_cross_harness_convention() {
  assert_grep 'Claude and grok use the slash form shown here; codex uses the same names with `$`' "$README" \
    "README lost the cross-harness slash and dollar convention"
  assert_grep '| `/ahoy`' "$README" "README built-in skills table does not list /ahoy"
  pass "README lists ahoy under the shared cross-harness invocation convention"
}

test_ahoy_owns_only_the_visible_session_recap() {
  assert_grep '[`../bearings/SKILL.md`](../bearings/SKILL.md)' "$AHOY" \
    "first-message fallback does not delegate to Bearings by relative pointer"
  assert_grep 'If no prior real captain message exists' "$AHOY" \
    "ahoy does not limit Bearings fallback to the first real captain message"
  assert_grep 'A captain boundary is an ordinary user-role message unless it matches one of the narrow operational exclusions below.' "$AHOY" \
    "ahoy lacks an explicit captain-authored boundary rule"
  assert_grep 'Exclude messages that begin with the current U+2063 `FIRSTMATE_OP:` injection prefix.' "$AHOY" \
    "ahoy does not exclude current marked operational injections"
  assert_grep 'Exclude legacy bare-marker away-mode injections only when U+2063 is immediately followed by `Supervisor escalate (`.' "$AHOY" \
    "ahoy does not narrowly exclude the legacy away-mode injection shape"
  assert_grep 'Exclude the exact legacy unmarked session-start payload ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``' "$AHOY" \
    "ahoy does not exclude the legacy unmarked session-start payload"
  assert_grep 'quotes or embeds a current operational message after ordinary captain text' "$AHOY" \
    "ahoy lacks quoted-current near-miss protection"
  assert_grep 'Apply the current exclusion only when U+2063 `FIRSTMATE_OP:` begins at the first character of the whole message' "$AHOY" \
    "ahoy does not pin the current-prefix whole-message boundary"
  assert_grep 'contains ASCII `FIRSTMATE_OP:` without a leading U+2063' "$AHOY" \
    "ahoy lacks ASCII-only near-miss protection"
  assert_grep 'Apply the legacy startup exclusion as a literal whole-message match: ``Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` is a captain boundary.' "$AHOY" \
    "ahoy does not pin the altered-startup behavioral near miss"
  assert_grep 'System, developer, tool, watcher, guard, away-mode, and other injected operational messages are not captain messages.' "$AHOY" \
    "ahoy incorrectly treats synthetic operational messages as captain messages"
  assert_grep 'The normal recap branch is session-history-only.' "$AHOY" \
    "later ahoy invocation is not explicitly session-history-only"
  assert_grep 'Do not call Bearings, shell commands, fleet snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes.' "$AHOY" \
    "normal recap does not prohibit fresh fleet, file, and tool reads"
  assert_grep 'do not guess current live state beyond the last visible event' "$AHOY" \
    "normal recap may falsely claim a live snapshot"
  assert_grep 'If context compaction makes the prior boundary unavailable' "$AHOY" \
    "ahoy does not disclose an unavailable compacted boundary"
  assert_grep 'summarize only visibly supported events' "$AHOY" \
    "compacted fallback may invent unsupported events"
  assert_no_grep 'fm-bearings-snapshot.sh' "$AHOY" \
    "ahoy copied Bearings gathering mechanics instead of referencing its owner"
  assert_no_grep "Captain's Call" "$AHOY" \
    "ahoy copied Bearings response contract instead of referencing its owner"
  pass "ahoy delegates first-message fallback and keeps later recaps visible-session-only"
}

test_ahoy_user_role_injections_share_one_marker() {
  local daemon grok_guard opencode_guard opencode_watch pi_guard pi_watch owner sessionstart spawn
  daemon=$(cat "$ROOT/bin/fm-supervise-daemon.sh")
  grok_guard=$(cat "$ROOT/bin/fm-turnend-guard-grok.sh")
  opencode_guard=$(cat "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js")
  opencode_watch=$(cat "$ROOT/.opencode/plugins/fm-primary-watch-arm.js")
  pi_guard=$(cat "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts")
  pi_watch=$(cat "$ROOT/.pi/extensions/fm-primary-pi-watch.ts")
  owner=$(cat "$ROOT/bin/fm-operational-input.sh")
  sessionstart=$(cat "$ROOT/bin/fm-sessionstart-nudge.sh")
  spawn=$(cat "$ROOT/bin/fm-spawn.sh")

  assert_contains "$owner" 'FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "' \
    "canonical owner lost the landed Ahoy prefix"
  assert_contains "$sessionstart" 'fm_operational_input_encode session-start' \
    "session-start does not use the canonical typed constructor"
  assert_contains "$daemon" 'fm_operational_input_encode away-supervisor' \
    "away-mode does not use the canonical typed constructor"
  assert_contains "$grok_guard" 'fm_operational_input_encode turn-end-guard' \
    "Grok guard does not use the canonical typed constructor"
  assert_contains "$opencode_guard" 'encodeFirstmateOperationalInput(' \
    "OpenCode guard does not use the cross-language constructor"
  assert_contains "$opencode_guard" '"turn-end-guard"' \
    "OpenCode guard does not retain its exact current kind"
  assert_contains "$opencode_watch" 'encodeFirstmateOperationalInput(paths.root, "watcher"' \
    "OpenCode watcher does not retain its exact current kind"
  assert_contains "$pi_guard" 'encodeFirstmateOperationalInput(' \
    "Pi guard does not use the cross-language constructor"
  assert_contains "$pi_guard" '"turn-end-guard"' \
    "Pi guard does not retain its exact current kind"
  assert_contains "$pi_watch" '"watcher"' \
    "Pi watcher does not retain its exact current kind"
  assert_contains "$spawn" 'encode launch-brief' \
    "cross-harness launches do not use the canonical launch-instruction kind"
  for producer in "$daemon" "$grok_guard" "$opencode_guard" "$opencode_watch" "$pi_guard" "$pi_watch" "$sessionstart" "$spawn"; do
    assert_not_contains "$producer" 'FIRSTMATE_OP: ' \
      "a current producer copied the canonical marker grammar"
  done
  pass "ahoy: one canonical owner constructs typed operational input for every Firstmate-controlled user-role producer"
}

test_section_9_owns_positive_translation_contract
test_scout_remains_allowed_house_vocabulary
test_compressed_safety_labels_have_plain_renderings
test_mapping_list_covers_high_risk_internal_families
test_verbatim_internal_evidence_is_rejected_from_chat
test_outward_facing_skill_points_reference_section_9_owner
test_section_9_owner_is_not_duplicated_into_skills
test_runlit_lab_fix_is_bounded_and_user_invocable
test_runlit_lab_fix_owns_safe_repair_contract
test_runlit_lab_fix_prescribes_no_mutating_or_cluster_wide_kubectl
test_runlit_lab_fix_carries_unavailable_outcome_into_verification
test_runlit_lab_fix_reproves_cluster_identity_before_mutating
test_ahoy_is_an_internal_user_invocable_skill
test_ahoy_readme_uses_cross_harness_convention
test_ahoy_owns_only_the_visible_session_recap
test_ahoy_user_role_injections_share_one_marker
