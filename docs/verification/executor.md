# Verification: executor launch flags

Audience: maintainer verification.

This record holds the active empirical evidence for the non-interactive one-shot launch forms `bin/fm-spawn.sh --executor` uses (its header owns the launch contract; [`configuration.md`](../configuration.md) "Executor launch" owns the operator-facing summary).
The flags are vendor-emitted facts, so each adapter's own `--help` is the source and `tests/fm-executor-headless-flags-live-e2e.test.sh` is the token-free default-on guard that re-checks them on every host where an adapter is installed.
It asserts the flag tokens each template passes and nothing else, so a vendor rewording of the help prose quoted below leaves it green:

```sh
bin/fm-test-run.sh tests/fm-executor-headless-flags-live-e2e.test.sh
```

The portable regression `tests/fm-spawn-executor.test.sh` pins the templates themselves against a fake pane and needs no harness.
No prompt was submitted to any model in establishing this record; firstmate runs the first live executor itself after the feature lands.

## claude

Verified on 2026-09-17 with Claude Code 2.1.274 on Linux.

```sh
claude --version
claude --help | grep -E -- '-p, --print|--output-format|--dangerously-skip-permissions|--permission-mode|--model <model>|--effort <level>|--settings <file-or-json>'
```

Observed output:

```text
2.1.274 (Claude Code)
  --dangerously-skip-permissions        Bypass all permission checks.
  --effort <level>                      Effort level for the current session
  --model <model>                       Model for the current session. Provide
  --output-format <format>              Output format (only works with --print):
  --permission-mode <mode>              Permission mode to use for the session
  -p, --print                           Print response and exit (useful for
  --settings <file-or-json>             Path to a settings JSON file or a JSON
```

The help text for `-p` states that the workspace trust dialog is skipped in non-interactive mode, so the spawn-time trust pre-registration is harmless rather than load-bearing for an executor.
The template passes the same permission flag `config/claude-permission-mode` selects for interactive launches, the same attribution-off `--settings` JSON, `--model` and `--effort` when set, `--output-format text` so the pane stays readable after exit, and the encoded brief as the positional prompt; the `--append-system-prompt` task channel is omitted because a one-shot has no inbox to trust.

## codex

Verified on 2026-09-17 with codex-cli 0.153.4 on Linux.

```sh
codex --version
codex exec --help | grep -E -- 'Run Codex non-interactively|-m, --model|-c, --config|--disable <FEATURE>|--dangerously-bypass-approvals-and-sandbox'
```

Observed output:

```text
codex-cli 0.153.4
Run Codex non-interactively
  -c, --config <key=value>
      --disable <FEATURE>
  -m, --model <MODEL>
      --dangerously-bypass-approvals-and-sandbox
```

The template passes `--dangerously-bypass-approvals-and-sandbox` and `--disable hooks` exactly as the crewmate launch does, `--model` and `-c model_reasoning_effort=...` under the interactive form's record-and-omit rule, and the encoded brief as the positional prompt.
No `notify=` program is passed: an executor's turn end is the pane shell's exit marker, not a hook.

## opencode

Verified on 2026-09-17 with opencode 1.18.29 on Linux.

```sh
opencode --version
opencode run --help | grep -E -- '^opencode run|-m, --model|--variant|--auto'
```

Observed output:

```text
1.18.29
opencode run [message..]
  -m, --model        model to use in the format of provider/model                           [string]
      --variant      model variant (provider-specific reasoning effort, e.g., high, max, minimal)
      --auto         auto-approve permissions that are not explicitly denied (dangerous!)
```

The template passes the same `OPENCODE_CONFIG_CONTENT` allow-all permission configuration the interactive launch uses, `--model` when set, and the encoded brief as the positional message.
`--variant` is provider-specific and has no verified mapping onto the shared effort vocabulary, so effort stays recorded in task meta and omitted from the launch, as the interactive form already does; `--auto` is not used because the permission configuration already covers approvals on the verified interactive path.

## Not verified

- Every other adapter: `pi`, `pi-signed`, `omp`, `grok`, `kimi`, `cursor`, `gemini`, `muse`, `rovo`, and `agy` have no verified headless one-shot form here, so `bin/fm-spawn.sh --executor` refuses them by name; a raw launch command remains the escape hatch.
- Live end-to-end: no executor was launched against a real model while establishing this record.
