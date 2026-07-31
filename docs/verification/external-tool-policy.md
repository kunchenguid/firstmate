# Ship external-tool policy verification

This record supports the current guarantees in [`../external-tool-policy.md`](../external-tool-policy.md).
It records active verification facts, not incident chronology.

## Environment

Verification date: 2026-07-31.

Installed harness discovery returned:

```text
claude: 2.1.220
codex: codex-cli 0.144.6
opencode: 1.18.4
pi: 0.83.0
cursor-agent: 2026.07.23-e383d2b
pi-signed: unavailable on PATH
grok: unavailable on PATH
kimi: unavailable on PATH
```

The unavailable binaries are not represented as live validation.
The pi-signed adapter uses the same generated extension as Pi and retains a separate launch-identity assertion in the automated suite.
The Grok adapter executes its generated global hook script and native deny response in an isolated fake home.
Kimi and Cursor are refusal axes, not claimed enforcement axes.

## Harness review

The command was:

```sh
tests/fm-external-tool-policy.test.sh
```

The suite executed the generated Claude and Codex hook commands, imported and called the generated OpenCode plugin, imported and called both Pi identity extensions, and executed the generated Grok global hook with its registered task token.
Each interceptable harness denied `npx playwright install chromium` before the requested command could run.
Pi and pi-signed also allowed the native `agent_browser` fallback from the brief policy.
A protected Pi scout recorded enforcement and promoted in place, while an unprotected raw-adapter scout remained a scout and promotion refused.
Kimi and raw Cursor ship selections refused before the fake runtime endpoint received any command.

The harness applicability review is:

| Harness | Enforcement evidence | Applicability result |
| --- | --- | --- |
| Claude | Generated `PreToolUse` command executed through the Claude payload and response shape | Applicable and passing. |
| Codex | Generated project hook executed through the Codex payload; launch included `--dangerously-bypass-hook-trust` | Applicable and passing. |
| OpenCode | Generated `tool.execute.before` plugin imported and invoked | Applicable and passing. |
| Pi | Generated `tool_call` extension imported and invoked | Applicable and passing. |
| pi-signed | The same generated `tool_call` extension was invoked from a distinct pi-signed spawn identity | Applicable and passing without a live pi-signed binary. |
| Grok | Generated global hook executed with a private registration token and produced `decision=deny` | Applicable and passing without a live Grok binary. |
| Kimi | Spawn refusal occurred before any fake endpoint call | Enforcement is not applicable because reliable interception is unverified; refusal is passing. |
| Cursor | Installed CLI help exposed `--plugin-dir` but no verified Firstmate before-tool adapter; raw launch refusal occurred before any fake endpoint call | Enforcement is not applicable because Cursor is unverified; refusal is passing. |

## Backend review

The backend review inspected the five adapters listed by `FM_BACKEND_SPAWN` in `bin/fm-backend.sh`: `tmux`, `herdr`, `zellij`, `orca`, and `cmux`.
Each backend resolves or creates the isolated task worktree before returning to the shared `bin/fm-spawn.sh` handoff.
The shared handoff installs the harness policy adapter before the first `spawn_send_literal` and Enter submission.
No backend has a separate policy copy or a path that launches the worker before that handoff.

The backend applicability review is:

| Backend | Worktree or endpoint role | Applicability result |
| --- | --- | --- |
| tmux | Session provider | Applicable through the shared pre-launch handoff. |
| herdr | Session provider | Applicable through the shared pre-launch handoff. |
| zellij | Session provider | Applicable through the shared pre-launch handoff. |
| orca | Worktree and terminal provider | Applicable after Orca returns the isolated worktree and before harness submission. |
| cmux | Session provider | Applicable through the shared pre-launch handoff. |

Existing backend behavior remains covered by `tests/fm-backend.test.sh` and the backend-specific suites.
Raw launch commands in backend-only E2E tests now run as scouts because an unverified raw adapter can no longer represent a ship.

## Command matrix

The targeted matrix covered:

```text
npx playwright install chromium
npm exec -- playwright install chromium
pnpm dlx playwright install chromium
yarn dlx @playwright/test install chromium
./node_modules/.bin/playwright install chromium
bash -lc 'npx playwright install chromium'
npx playwright install chromium | tee install.log
npx playwright install chromium >install.log 2>&1
npm install --save-dev @playwright/test
python -m playwright install chromium
python -c 'from playwright.sync_api import sync_playwright'
node node_modules/playwright/cli.js install chromium
node -e 'require("puppeteer").launch()'
agent-browser open http://localhost:3000
apt-get install chromium
```

Every denied row returned `external-tool-denied` and named Playwright or the requested browser tool, the brief policy, and the authorized `chrome-devtools-axi` and `agent_browser` alternatives.

Allowed rows covered:

```text
chrome-devtools-axi open http://localhost:3000
native agent_browser
npm test
pnpm lint
npm run build
npm run dev -- --host 127.0.0.1
npm install typescript
printf '%s\n' 'npx playwright install chromium'
```

## Repository checks

The required validation commands are:

```sh
tests/fm-external-tool-policy.test.sh
tests/fm-brief.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-grok-harness.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-backend.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-secondmate-harness.test.sh
tests/fm-teardown.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-test-run.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

Every listed command completed with exit status 0 on 2026-07-31.
The external-tool suite reported every denied and allowed matrix row as `ok`, all six interceptable harness adapters as passing, protected and refused scout-promotion cases as passing, and the Kimi, Cursor, and missing-policy pre-endpoint refusals as passing.
The watcher-arm suite retained its complete prior shell-classification matrix after the shared execution-tree walker was exported.
The backend, spawn, supervision-adapter, secondmate, and cleanup suites retained their existing passing behavior.
`bin/fm-lint.sh` reported the pinned ShellCheck 0.11.0 line and no finding.
`bin/fm-doc-audience-check.sh` reported `ok surfaces=61 local_links=169`.
