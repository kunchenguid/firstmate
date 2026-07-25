# Model routing verification

This record supports the exact Pi model identifiers used by the copyable crew dispatch example.
The dispatch procedure still rechecks the current authenticated discovery surface at intake because account entitlement and model catalogs are volatile.

## 2026-07-25 local verification

The installed client reported:

```text
$ pi --version
0.82.0
```

Pi listed the exact Anthropic implementation models and their current limits:

```text
$ pi --list-models anthropic/claude-opus-5 | awk 'NR == 1 || $2 == "claude-opus-5"'
provider   model                     context  max-out  thinking  images
anthropic  claude-opus-5             1M       128K     yes       yes
$ pi --list-models anthropic/claude-haiku-4-5-20251001 | awk 'NR == 1 || $2 == "claude-haiku-4-5-20251001"'
provider   model                      context  max-out  thinking  images
anthropic  claude-haiku-4-5-20251001  200K     64K      yes       yes
```

Pi listed the exact OpenAI backend and validation models:

```text
$ pi --list-models openai/gpt-5.5 | awk 'NR == 1 || $2 == "gpt-5.5"'
provider  model        context  max-out  thinking  images
openai    gpt-5.5      272K     128K     yes       yes
$ pi --list-models openai/gpt-5.6-sol | awk 'NR == 1 || $2 == "gpt-5.6-sol"'
provider  model        context  max-out  thinking  images
openai    gpt-5.6-sol  272K     128K     yes       yes
```

Each exact route also completed a live low-thinking request through Pi:

```text
$ pi --print --model anthropic/claude-opus-5 --thinking low 'Reply with exactly MODEL_OK.'
MODEL_OK
$ pi --print --model anthropic/claude-haiku-4-5-20251001 --thinking low 'Reply with exactly MODEL_OK.'
MODEL_OK
$ pi --print --model openai/gpt-5.5 --thinking low 'Reply with exactly MODEL_OK.'
Captain, MODEL_OK
$ pi --print --model openai/gpt-5.6-sol --thinking low 'Reply with exactly MODEL_OK.'
MODEL_OK
```

These probes establish the exact Pi provider/model identifiers for this environment on that date.
They do not authorize silently substituting an alias or a similarly named model after a later availability failure.
