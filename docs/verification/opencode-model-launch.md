# Verification: the opencode model axis on the interactive launch

Active empirical facts for how Firstmate selects the model on an OpenCode crewmate or scout launch.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/opencode.md`](../../.agents/skills/harness-adapters/references/harness/opencode.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Verified | 2026-10-10 |
| Host | this host, `opencode` at `/home/pikos/.opencode/bin/opencode` |
| OpenCode version | 2.0.26 (`opencode --version` prints `opencode v2.0.26`) |
| Scope | the interactive launch `opencode --prompt ...` that `bin/fm-spawn.sh` builds |
| Out of scope | `opencode run`, the headless mode, which is not the path Firstmate integrates with |

## OpenCode v2 removed `--model` from the interactive launch

```sh
opencode --help
```

The `FLAGS` block lists only `--standalone`, `--server`, `--auto`, `--continue/-c`, `--session/-s`, and `--prompt`.
There is no `--model`.
A launch that carries one dies immediately:

```sh
opencode --model opencode/space-bunny-free --prompt "hi"
```

```text
ERROR
  Unrecognized flag: --model in command opencode
```

That command exits 1.

`opencode run --help` does still list `--model, -m string`, documented as "Model to use in the format provider/model#variant".
`run` is the headless launch mode, so its flag says nothing about the interactive path.

`bin/fm-spawn.sh` therefore omits `--model` for this harness, and the model axis rides the worktree's own config instead.

## Dropping the flag alone does not keep the configured model

An unpinned run in a fresh directory started on a model that was neither the configured one nor the host's last-used TUI selection:

```sh
mkdir -p /tmp/opencode/ctrl && cd /tmp/opencode/ctrl
opencode run --format json "Reply with exactly: CTRL"
opencode session export ses_ed9611906ffexHU2IZ78pp38rC
```

Every assistant message in that session recorded `{"id":"claude-haiku-5-5","providerID":"opencode-go"}`.
Removing the flag is therefore not sufficient on its own, which is why Firstmate pins the model explicitly.

## The supported v2 pin is the worktree's own config

`OPENCODE_CONFIG_CONTENT` cannot carry the model.
It does not appear as a configuration source at all under 2.0.26, for the `model` key or for `permission` or for `agent`:

```sh
cd /tmp/opencode/envtest
OPENCODE_CONFIG_CONTENT='{"model":"opencode/space-bunny-free"}' opencode debug config
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode debug config
OPENCODE_CONFIG_CONTENT='{"agent":{"build":{"model":"opencode/space-bunny-free","variant":"high"}}}' opencode debug config
```

All three print only the global document and its directory, with no overlay entry.

A worktree-level `.opencode/opencode.json` carrying the `model` key is read, and normalized to the provider/model pair:

```sh
mkdir -p /tmp/opencode/modeltest/.opencode
printf '%s\n' '{"$schema":"https://opencode.ai/config.json","model":"opencode/space-bunny-free"}' \
  > /tmp/opencode/modeltest/.opencode/opencode.json
cd /tmp/opencode/modeltest && opencode debug config
```

```json
{
    "type": "document",
    "path": "/tmp/opencode/modeltest/.opencode/opencode.json",
    "info": {
        "$schema": "https://opencode.ai/config.json",
        "model": {
            "providerID": "opencode",
            "model": "space-bunny-free"
        }
    }
}
```

### The pin does not shadow the operator's global config

`opencode debug config` reports the global document and the project document as separate merged sources rather than one replacing the other.
The operator's `local-llm` provider block stayed available with the pin in place:

```sh
cd /tmp/opencode/pintest && opencode models
```

```text
local-llm/gemma-4
local-llm/qwen3.8-27b-gguf
opencode-go/qwen3.7-plus
opencode-go/qwen3.8-flash
opencode-go/qwen3.8-max
opencode-go/space-bunny
opencode/space-bunny-free
```

The same two `local-llm` entries appear in an unpinned directory, so the pin added no shadowing.

### The pin selects the model for a real run

Pinned to a deliberately distinctive model so a positive result could not come from the host default:

```sh
mkdir -p /tmp/opencode/pintest/.opencode
printf '%s\n' '{"$schema":"https://opencode.ai/config.json","model":"opencode-go/space-bunny"}' \
  > /tmp/opencode/pintest/.opencode/opencode.json
cd /tmp/opencode/pintest
opencode run --format json "Reply with exactly: PINOK"
opencode session export ses_ed9613a9bffe5jN7gAvuSjLfeD
```

The run replied `PINOK`, and every assistant message in that session recorded `{"providerID":"opencode-go","id":"space-bunny"}`.
The pin decided the model.

## Live interactive launch on the captain's model

A real interactive launch, carrying only the worktree config that `write_opencode_worktree_config` generates and no `--model` flag:

```sh
mkdir -p /tmp/opencode/live/.opencode && cd /tmp/opencode/live && git init -q .
printf '{"model":"opencode/space-bunny-free"}\n' > .opencode/opencode.json
opencode --prompt "Reply with exactly: LAUNCHOK"
opencode session list
opencode session export ses_ed9561729ffePLcUkrw6wJRADT
```

Every assistant message in that session recorded `{"providerID":"opencode","id":"space-bunny-free"}`, and the session replied `LAUNCHOK`.
The interactive launch started and ran on `opencode/space-bunny-free` from the worktree pin alone.

The same receipt was read from a real Firstmate worker session on this host on the same date: its export recorded `{"id":"space-bunny-free","providerID":"opencode","variant":"default"}`.

## What this record does not establish

The busy-state and turn-end plugin contract is separate evidence owned by [supervision.md](supervision.md); nothing here changes or re-verifies it.

Only 2.0.26 on this host was measured.
`opencode run` was used to read a session's recorded model cheaply; the guarantee claimed here is for the interactive launch, which was exercised directly.

Measurements on 2.0.26 confirmed that `./opencode.json` is lower precedence than `.opencode/opencode.json`, `OPENCODE_CONFIG` and `OPENCODE_CONFIG_DIR` are ignored, and `.opencode/opencode.jsonc` is not read.
No alternate config path was found that can override the tracked file without changing it.

The [OpenCode harness reference](../../.agents/skills/harness-adapters/references/harness/opencode.md#operating-facts) owns Firstmate's preserve-and-merge, default-restoration, permission, effort, and refusal policy; [`tests/fm-spawn-dispatch-profile.test.sh`](../../tests/fm-spawn-dispatch-profile.test.sh) covers that policy independently of these model-selection measurements.
