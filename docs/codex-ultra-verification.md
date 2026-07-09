# Codex gpt-5.6-sol ultra verification

Observed on 2026-07-09 with `codex-cli 0.144.0`.

Commands:

```sh
codex --version
jq -c '.models[] | select(.slug == "gpt-5.6-sol") | {slug,display_name,supported_reasoning_levels}' ~/.codex/models_cache.json
tmp_dir=$(mktemp -d /tmp/fm-codex-ultra-launch.XXXXXX)
codex --strict-config -a never -s read-only -m gpt-5.6-sol -c 'model_reasoning_effort="ultra"' exec --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check -C "$tmp_dir" 'Reply with exactly ULTRA_OK. Do not call tools.'
rc=$?
rm -rf "$tmp_dir"
printf 'exit_status=%s\n' "$rc"
```

Relevant non-sensitive output:

```text
codex-cli 0.144.0
{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","supported_reasoning_levels":[{"effort":"low","description":"Fast responses with lighter reasoning"},{"effort":"medium","description":"Balances speed and reasoning for everyday tasks"},{"effort":"high","description":"Greater reasoning depth for complex problems"},{"effort":"xhigh","description":"Extra high reasoning depth for complex problems"},{"effort":"max","description":"Maximum reasoning depth for the hardest problems"},{"effort":"ultra","description":"Maximum reasoning with automatic task delegation"}]}
OpenAI Codex v0.144.0
workdir: /tmp/fm-codex-ultra-launch.dAV12v
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: ultra
reasoning summaries: none
codex
ULTRA_OK
exit_status=0
```
