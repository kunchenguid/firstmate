# Pi skill-catalog verification

Audience: maintainer verification.

This record preserves the full-prompt measurement for hiding Firstmate's 15 agent-only skills from Pi's automatic model catalog.
The required portable path in `tests/fm-pi-skill-catalog.test.sh` parses every Firstmate skill's YAML front matter and enforces the exact 15-hidden and 5-visible metadata partition before checking whether Pi is installed.
When Pi is installed, that same regression continues through Pi's extension and RPC interfaces to enforce the behavioral contract; otherwise it reports that behavioral portion as skipped after the portable contract passes.
This record owns the version-scoped byte evidence and its refresh method.

## Full-prompt audit

The audit was run on 2026-08-30 with Pi 0.84.0 on macOS against public base `c731c36c381ea0886fa5aabf6a3be761534d3f30` and audited implementation head `40f8af8e96e4aace58d5f765bc478b68f368593d`.
Both captures used the same clean disposable checkout path, the same installed Pi configuration, and the normal discovered project context and skill catalog.
The only source difference was the task head.
Pi's command context exposed the complete generated system prompt without starting an agent turn or making a provider request.
The captured prompt bytes are authoritative for the reviewed implementation head and later descendants that change only this verification record, which Pi does not discover as prompt context.

Create this test-only hook in `.tmp-skill-catalog-audit/capture-system-prompt.ts` inside the disposable checkout:

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";

export default function (pi: ExtensionAPI) {
  pi.registerCommand("fm-capture-full-prompt", {
    description: "Capture Pi's complete generated system prompt",
    handler: async (_args, ctx) => {
      const prompt = ctx.getSystemPrompt();
      const catalog = prompt.match(/<available_skills>[\s\S]*?<\/available_skills>/)?.[0];
      writeFileSync(
        process.env.FM_PI_PROMPT_CAPTURE!,
        JSON.stringify({
          prompt,
          bytes: Buffer.byteLength(prompt, "utf8"),
          skills: ctx.getSystemPromptOptions().skills,
          catalogSkills: catalog?.match(/<skill>/g)?.length ?? 0,
        }),
      );
    },
  });
}
```

Run these commands from the clean disposable checkout that contains the test-only hook.
Keeping the checkout path fixed matters because Pi includes each skill's absolute location in the generated catalog.

```sh
BASE=c731c36c381ea0886fa5aabf6a3be761534d3f30
TASK_HEAD=40f8af8e96e4aace58d5f765bc478b68f368593d
AUDIT_DIR="$PWD/.tmp-skill-catalog-audit"
capture_prompt() {
  label=$1
  printf '%s\n' \
    '{"id":"capture","type":"prompt","message":"/fm-capture-full-prompt"}' \
    | PI_OFFLINE=1 \
      FM_PI_PROMPT_CAPTURE="$AUDIT_DIR/$label.json" \
      pi --mode rpc --approve --no-session --no-extensions \
        -e "$AUDIT_DIR/capture-system-prompt.ts" \
        --no-prompt-templates --no-themes \
        --model openai-codex/gpt-5.6-sol --thinking low \
        >"$AUDIT_DIR/$label.rpc" \
        2>"$AUDIT_DIR/$label.stderr"
  jq '{bytes, loadedSkills:(.skills | length), catalogSkills}' "$AUDIT_DIR/$label.json"
}
git switch --detach "$BASE"
capture_prompt before
git switch --detach "$TASK_HEAD"
capture_prompt after
```

The raw bounded output was:

```text
base=c731c36c381ea0886fa5aabf6a3be761534d3f30
head=40f8af8e96e4aace58d5f765bc478b68f368593d
pi=0.84.0
before={"bytes":93016,"loadedSkills":29,"catalogSkills":29}
after={"bytes":83520,"loadedSkills":29,"catalogSkills":14}
saved=9496
providerRequests=0
```

The 29 loaded skills comprised all 20 Firstmate skills and nine installed global skills in both captures.
After the change, the automatic catalog retained those nine global skills plus the five captain-invocable Firstmate skills, while all 29 skill records remained loaded.
The focused behavioral regression separately confirms that Pi retains all 20 Firstmate skill commands.
The measured reduction was 9,496 UTF-8 bytes in Pi's complete generated system prompt.
