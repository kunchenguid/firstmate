#!/usr/bin/env bash
# Public-interface regressions for Firstmate Grill Me discovery, expansion,
# collision safety, exact triggering, and the local plan-handoff boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null 2>&1 || { echo "skip: pi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-grill-me)
SKILL_ROOT="$ROOT/.agents/skills/firstmate-grill-me"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
HOME_DIR="$TMP_ROOT/home"

make_project() {
  local project=$1
  mkdir -p "$project/.agents/skills/firstmate-grill-me" "$PI_DIR" "$HOME_DIR"
  git init -q "$project"
  cp "$SKILL_ROOT/SKILL.md" "$project/.agents/skills/firstmate-grill-me/SKILL.md"
  git -C "$project" add .agents/skills/firstmate-grill-me/SKILL.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
}

run_rpc() {
  local project=$1 output=$2 error=$3
  shift 3
  printf '%s\n' '{"id":"commands","type":"get_commands"}' |
    (cd "$project" &&
      env HOME="$HOME_DIR" PI_CODING_AGENT_DIR="$PI_DIR" \
        pi --mode rpc --offline --no-session --no-context-files --no-extensions \
          --model openai-codex/gpt-5.6-sol "$@") \
      >"$output" 2>"$error" || return $?
}

commands_json() {
  local output=$1
  jq -c '.data.commands // []' "$output"
}

assert_grill_command() {
  local output=$1 expected_path=$2
  jq -e --arg expected_path "$expected_path" '
    [.data.commands[]? | select(.source == "skill" and .name == "skill:firstmate-grill-me")] as $matches
    | ($matches | length) == 1
    and $matches[0].sourceInfo.path == $expected_path
    and ($matches[0].description | contains("Interview mich"))
    and ($matches[0].description | contains("/skill:firstmate-grill-me"))
    and ($matches[0].description | contains("Interview me") | not)
    and ($matches[0].description | contains("Note-to-Note") | not)
  ' "$output" >/dev/null || fail "Pi did not expose the exact Firstmate Grill Me command and trigger description"
}

test_project_discovery_and_exact_trigger_surface() {
  local output="$TMP_ROOT/discovery.out" error="$TMP_ROOT/discovery.err"
  make_project "$PROJECT"
  run_rpc "$PROJECT" "$output" "$error" --approve \
    || fail "Pi RPC discovery failed: $(cat "$error")"
  assert_grill_command "$output" "$PROJECT/.agents/skills/firstmate-grill-me/SKILL.md"
  pass "trusted project discovery exposes the unique command and exact trigger without near-miss aliases"
}

test_trust_and_explicit_loading_boundaries() {
  local untrusted="$TMP_ROOT/untrusted.out" untrusted_err="$TMP_ROOT/untrusted.err"
  local explicit="$TMP_ROOT/explicit.out" explicit_err="$TMP_ROOT/explicit.err"
  run_rpc "$PROJECT" "$untrusted" "$untrusted_err" --no-approve \
    || fail "Pi untrusted discovery probe failed: $(cat "$untrusted_err")"
  jq -e --arg path "$PROJECT/.agents/skills/firstmate-grill-me/SKILL.md" '
    ([.data.commands[]? | select(.name == "skill:firstmate-grill-me" and .sourceInfo.path == $path)] | length) == 0
  ' "$untrusted" >/dev/null || fail "untrusted project resources were loaded without approval"

  run_rpc "$PROJECT" "$explicit" "$explicit_err" --no-approve --no-skills \
    --skill "$SKILL_ROOT" || fail "Pi explicit skill load failed: $(cat "$explicit_err")"
  assert_grill_command "$explicit" "$SKILL_ROOT/SKILL.md"
  pass "project trust is required for discovery while explicit skill loading remains available"
}

test_collision_safety_and_local_handoff_boundary() {
  local public_dir="$PROJECT/.agents/skills/grill-me"
  local collision_root="$TMP_ROOT/collision"
  local one="$collision_root/one" two="$collision_root/two"
  local output="$TMP_ROOT/collision.out" error="$TMP_ROOT/collision.err"
  local commands

  mkdir -p "$public_dir" "$one" "$two"
  cat > "$public_dir/SKILL.md" <<'MD'
---
name: grill-me
description: External public Grill Me fixture.
---
MD
  cat > "$one/SKILL.md" <<'MD'
---
name: firstmate-grill-me
description: First collision fixture wins.
---
MD
  cat > "$two/SKILL.md" <<'MD'
---
name: firstmate-grill-me
description: Second collision fixture loses.
---
MD

  run_rpc "$PROJECT" "$output" "$error" --approve \
    || fail "Pi collision coexistence probe failed: $(cat "$error")"
  commands=$(commands_json "$output")
  printf '%s\n' "$commands" | jq -e '
    ([.[] | select(.name == "skill:grill-me")] | length) == 1
    and ([.[] | select(.name == "skill:firstmate-grill-me")] | length) == 1
  ' >/dev/null || fail "public grill-me fixture displaced or duplicated the unique Firstmate command"
  jq -e --arg path "$PROJECT/.agents/skills/firstmate-grill-me/SKILL.md" '
    any(.data.commands[]?; .name == "skill:firstmate-grill-me" and .sourceInfo.path == $path)
    and (any(.data.commands[]?; .name == "skill:note-to-node") | not)
  ' "$output" >/dev/null || fail "the local note-to-node stage was advertised as a Pi skill or the Firstmate path was not selected"

  run_rpc "$PROJECT" "$output" "$error" --no-approve --no-skills \
    --skill "$one" --skill "$two" \
    || fail "Pi same-name collision probe failed: $(cat "$error")"
  jq -e '
    ([.data.commands[]? | select(.name == "skill:firstmate-grill-me")] | length) == 1
    and ([.data.commands[]? | select(.name == "skill:firstmate-grill-me")][0].description
      | contains("First collision fixture wins."))
  ' "$output" >/dev/null || fail "Pi did not retain the first explicit skill on collision"
  pass "public Grill Me coexistence and same-name collision behavior preserve the local owner"
}

write_provider_fixture() {
  cat > "$TMP_ROOT/grill-provider.ts" <<'TS'
import { writeFileSync } from "node:fs";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

export default function (pi: any): void {
  pi.on("before_agent_start", (event: any) => {
    const skills = Array.isArray(event.systemPromptOptions?.skills)
      ? event.systemPromptOptions.skills
      : [];
    const prompt = typeof event.prompt === "string" ? event.prompt : "";
    const capture = process.env.FM_GRILL_CAPTURE;
    if (capture) {
      writeFileSync(capture, JSON.stringify({
        expanded: prompt.startsWith('<skill name="firstmate-grill-me"'),
        args: prompt.endsWith("--depth quick --questions one-at-a-time TEST_TOPIC"),
        registered: skills.some((skill: any) => skill?.name === "firstmate-grill-me"),
        rawCommandAbsent: !prompt.startsWith("/skill:"),
        handoffAfterConfirmation: prompt.includes("After explicit plan confirmation"),
        handoffBeforeLocalStage: prompt.includes("Grill Me runs before that existing local stage"),
        planShape: prompt.includes("GRILL_ME_PLAN v1"),
        planOnly: prompt.includes("PLAN ONLY: this packet does not authorize implementation"),
        lavishAfterConfirmation: prompt.includes("local Lavish plan view after the same confirmation"),
        ownerBoundaries: prompt.includes("existing local method retains its own input format"),
        retainedEvidencePreflight: prompt.includes("Before building questions or preparing any handoff, reconcile retained local evidence"),
        retainedEvidenceDisclosure: prompt.includes("Before reading any retained content beyond metadata, state the active provider and model and whether the route is local or hosted"),
        retainedEvidenceMetadataOnly: prompt.includes("Start with a metadata-only inventory of paths, ref names, worktree identities, report and brief identifiers, record kinds, owners, timestamps, and dirty or clean state; do not read payloads or values during this inventory"),
        retainedEvidenceRedaction: prompt.includes("After that disclosure, read only the minimum redacted content needed")
          && prompt.includes("If safe redaction is impossible, stop that reconciliation branch and route it to the existing protected owner"),
        disclosurePrecedesNonPublicContext: prompt.indexOf("Before reading any retained content beyond metadata") >= 0
          && prompt.indexOf("Before reading any retained content beyond metadata") < prompt.indexOf("Before accepting non-public context"),
        retainedEvidenceInventory: prompt.includes("current tracked files and working state")
          && prompt.includes("all local Git refs and history including preserved task branches")
          && prompt.includes("all Treehouse worktrees and their retained uncommitted files, whether or not they are registered")
          && prompt.includes("private reports and briefs")
          && prompt.includes("durable Firstmate records"),
        missingEvidenceStopsHandoff: prompt.includes("stop the handoff, and report the missing local source instead of substituting a new owner"),
        credentialRouting: prompt.includes("Route a needed credential or login to the captain under `AGENTS.md` section 9")
          && prompt.includes("load `harness-adapters`")
          && prompt.includes("load `quota-array-dispatch`"),
        noLegacyCredentialBrokerRouting: !prompt.includes("Route protected values and credential questions to the existing `credential-broker` owner"),
        improvementResidual: prompt.includes("Route the candidate's durable record through `captain-hold-lifecycle`")
          && prompt.includes("record a `RESIDUAL` owned by `captain-hold-lifecycle`, report it to the captain, and stop that branch"),
        noUnownedImprovementOwner: !prompt.includes("Use the existing improvement owner and its bounded notification path"),
        noLocalCommand: !prompt.includes("/skill:note-to-node"),
        noExternalWrites: prompt.includes("external writes, public sharing, deployment, activation, and publication are not performed"),
      }));
    }
  });

  pi.registerProvider("grill-test", {
    baseUrl: "http://127.0.0.1:9/unused",
    apiKey: "test-only",
    api: "grill-test-api",
    models: [{
      id: "deterministic",
      name: "Deterministic Grill Me public-interface fixture",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 8192,
      maxTokens: 256,
    }],
    streamSimple(model: any): any {
      const text = "GRILL_ME_PUBLIC_INTERFACE_OK";
      const stream = createAssistantMessageEventStream();
      const output: any = {
        role: "assistant",
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.now(),
      };
      queueMicrotask(() => {
        stream.push({ type: "start", partial: output });
        const block = { type: "text", text };
        output.content.push(block);
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      });
      return stream;
    },
  });
}
TS
}

test_command_expansion_public_interface() {
  local output="$TMP_ROOT/expansion.out"
  local error="$TMP_ROOT/expansion.err"
  local capture="$TMP_ROOT/expansion.json"
  local provider="$TMP_ROOT/grill-provider.ts"
  write_provider_fixture
  output=$(
    cd "$PROJECT" &&
      env HOME="$HOME_DIR" PI_CODING_AGENT_DIR="$PI_DIR" FM_GRILL_CAPTURE="$capture" \
        pi --print --offline --no-session --no-context-files --no-skills \
          --no-extensions --no-tools --api-key test-only -e "$provider" \
          --skill "$SKILL_ROOT" \
          --model grill-test/deterministic \
          "/skill:firstmate-grill-me --depth quick --questions one-at-a-time TEST_TOPIC"
  ) 2>"$error" || fail "Pi deterministic command probe failed: $(cat "$error")"
  assert_contains "$output" "GRILL_ME_PUBLIC_INTERFACE_OK" \
    "the explicit skill command did not reach the public Pi prompt path"
  [ -s "$capture" ] || fail "Pi did not emit the public before_agent_start expansion record"
  jq -e '.expanded and .args and .registered and .rawCommandAbsent
    and .handoffAfterConfirmation and .handoffBeforeLocalStage and .planShape
    and .planOnly and .lavishAfterConfirmation and .ownerBoundaries
    and .retainedEvidencePreflight and .retainedEvidenceInventory
    and .retainedEvidenceDisclosure and .retainedEvidenceMetadataOnly
    and .retainedEvidenceRedaction and .disclosurePrecedesNonPublicContext
    and .missingEvidenceStopsHandoff and .credentialRouting and .noLegacyCredentialBrokerRouting
    and .improvementResidual and .noUnownedImprovementOwner
    and .noLocalCommand and .noExternalWrites' "$capture" >/dev/null \
    || fail "Pi did not expand the explicit skill command with the plan-only local handoff boundary"
  pass "explicit command expansion reaches the public Pi lifecycle with arguments and handoff boundaries intact"
}

test_project_discovery_and_exact_trigger_surface
test_trust_and_explicit_loading_boundaries
test_collision_safety_and_local_handoff_boundary
test_command_expansion_public_interface
