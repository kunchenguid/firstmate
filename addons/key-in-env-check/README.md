# key-in-env-check

Wakes Main when any running fleet process carries a provider API key in its environment. Born from BYOKit finding 13 live `pi` workers holding the OpenRouter key, inherited from a long-lived parent (the herdr server or the no-mistakes daemon).

## What it does

Every run it scans same-user processes under `/proc`, read-only:

- **Names for matching.** `/proc/<pid>/environ` is split on NUL and only the variable names are matched against the pattern list. A value is never printed, logged, written, or sent on the network. The e2e test plants canary values and greps everything the check wrote.
- **Matches names** against a pattern list: `*_API_KEY`, `*_API_TOKEN`, and `<PROVIDER>_*KEY|TOKEN|SECRET` for OPENROUTER, ANTHROPIC, OPENAI, MINIMAX, GOOGLE, GEMINI, XAI, MOONSHOT, ZAI, DEEPSEEK, MISTRAL, GROQ, COHERE, TOGETHER, FIREWORKS. Override with `FM_KEY_PATTERNS` (comma or space separated globs) or the home's `config/key-in-env-patterns`.
- **Attributes each hit** to a home and task: the process's cwd (or its nearest ancestor's) is matched against every home's `state/*.meta` `worktree=` record (homes: `~/firstmate` and `~/.treehouse/*/*/firstmate`); no match prints `unknown`.
- **Names the parent still exporting it:** the parent chain is walked to the topmost ancestor that holds the same variable.

Output: `state/key-in-env.incidents` (rewritten each run, empty when clean), one TSV line per process: `pid  home  task  variables  topmost-parent(pid)`. When a discovered `OPENROUTER_API_KEY` hashes the same as `~/.config/openrouter/api_key`, the check wakes once when a finding first appears, when a new key variable name appears, or when the process count grows by more than 25% since the last alert. When every discovered OpenRouter value hashes differently from that file (an old key), the finding is logged only on stderr with a `key revoked` note and never wakes, even on count jumps. It stays quiet for an unchanged current-key finding and resets the active finding after a clean scan. Its private `state/.key-in-env.alerted.json` stores only the last alerted count, variable names, and revoked flag. The Incidents view can read the incidents file directly.

When an `OPENROUTER_API_KEY` is present, the check reads the value transiently from `/proc` only to compare its sha256 to the sha256 of `~/.config/openrouter/api_key`. There is no network call and no liveness probe; OpenRouter key health belongs to BYOKit. Values and full hashes are never logged (a short hash prefix is allowed but unused). Other providers are not hashed.

It never kills, signals or changes anything.

## Install and test

`FM_HOME=<home> key-in-env-check/install.sh [--dry-run]` copies the check to `${XDG_DATA_HOME:-~/.local/share}/fm-key-in-env-check/` and registers `key-in-env-check` as a home watcher check. Remove with `uninstall.sh`. Test: `bash key-in-env-check/tests/key-in-env-check-e2e.sh` (uses a temp `HOME` and a fixture key file; never the real one).
