---
name: playwright-qa
description: Run deterministic headless UI test cases against a web app with exact-viewport screenshot evidence, and harden them into committed Playwright specs a project re-runs in CI. Use when asked to QA a UI, verify a page or flow renders and behaves, check how a change looks at real screen sizes, produce visual proof a UI works, or add UI tests to a project.
user-invocable: false
metadata:
  internal: true
---

# playwright-qa

The fleet's standing capability for deterministic UI test cases: click/fill/assert against a web app, headless and isolated, with exact-viewport screenshots as evidence, hardened into committed Playwright TypeScript specs that the project re-runs in CI.

Load this when a task asks you to QA a UI, verify a page or flow works, check how something looks at real screen sizes, produce visual proof, or add UI tests to a project.

## The non-negotiable safety rules

1. **Headless and isolated, always.** Playwright launches its own bundled Chromium in a fresh, throwaway context. It never attaches to the captain's real Chrome, never touches their profile, cookies, or logged-in sessions. Do not add `channel: 'chrome'` against the captain's profile, a persistent `userDataDir` pointing at their real Chrome, or any connect-over-CDP to a running browser. The scaffolded config is already headless and isolated - keep it that way.
2. **Evidence must exist before "verified".** A visual deliverable is only verified when the screenshot and the spec both exist and the spec passed. The failure this prevents is calling a UI "done" without ever looking at it. When you report a visual result, the answer to "did the agent actually check what this looks like for me?" must be YES, with the screenshot and passing spec as proof. Never claim a UI renders or a flow works from reading code alone.
3. **Screenshots are exact-viewport.** Run at the named viewports so the evidence is deterministic and comparable across releases. The defaults are `desktop-1857x933` (1857x933) and `laptop-1440x900` (1440x900).

## When to use this vs chrome-devtools-axi

These are two layers, and the fleet keeps both.

- **playwright-qa (this skill)** drives deterministic test cases: click/fill/assert, exact-viewport visual-regression screenshots, and committed `*.spec.ts` that re-run in CI. Use it for repeatable UI checks and any visual deliverable that must stay verified every release.
- **chrome-devtools-axi** is the viewer and diagnostician: ad-hoc inspection, performance tracing, Web Vitals, network and console debugging. Use it to find out *why* something broke, not to assert that a flow works.

Rule of thumb from the research: "chrome-devtools tells you why it broke; Playwright drives the flow." Full reasoning and sources: `data/axi-vs-mcp-evaluation-v1/inputs/chrome-tool-research-2026-07-22.md`. Do not duplicate that analysis - read it if you need the evidence.

## Workflow

### 1. Scaffold the harness into the project worktree

Run the scaffold, which drops a headless `playwright.config.ts`, an example spec, a `qa/screenshots/` evidence dir, and a `qa/.gitignore` into the worktree. It installs nothing.

```sh
bin/fm-playwright-scaffold.sh --dir <project-worktree>
```

Custom viewports when a brief needs them: `--viewports "name:WIDTHxHEIGHT,..."`. It keeps existing files unless you pass `--force`, so a re-run is a safe no-op. See `bin/fm-playwright-scaffold.sh --help` for the exact flags.

### 2. Install Playwright into the project (not into firstmate)

Playwright is a project dependency. Install it in the target worktree, never in the firstmate repo:

```sh
cd <project-worktree>
npm install -D @playwright/test
npx playwright install chromium
```

Add `@playwright/test` to the project's own `devDependencies` and keep `node_modules/` gitignored.

### 3. Write the spec from the QA brief

Turn each acceptance criterion in the brief into a Playwright assertion. Prefer role- and text-based locators (`getByRole`, `getByText`, `getByLabel`) over brittle CSS or XPath - they read like the brief and survive markup churn. Point the run at the app with `QA_BASE_URL` (a dev server, a preview URL, or a `file://` URL for a static page).

The pattern - render assert, interaction, result assert, exact-viewport screenshot - is shown in `example/qa/specs/demo.spec.ts`. Screenshot to `qa/screenshots/<case>-${testInfo.project.name}.png` so every viewport produces its own named evidence file.

### 4. Run headless at every viewport

```sh
cd <project-worktree>
npx playwright test                          # all viewports
npx playwright test --project=laptop-1440x900  # one viewport
```

Each named project runs the specs at its exact viewport. Screenshots land in `qa/screenshots/`. Run artifacts (traces, videos, the HTML report) go to the gitignored `qa/results/`.

### 5. Harden into committed CI tests

Commit `qa/specs/*.spec.ts` and the `qa/screenshots/*.png` evidence. The specs are now regression tests: the project's CI re-runs them every release, and the committed screenshots are the baseline for "how it should look". A reproduced UI bug becomes a spec that fails until it is fixed, then guards against regression.

If the project has no CI step running Playwright yet, add one (a `playwright test` job on pull requests) so the harness actually re-runs - a spec nobody runs is not a regression test.

## Runnable proof

`example/` is a complete, working instance of this harness: a static page, the scaffolded config, a demo spec that renders, clicks, asserts, and screenshots, and the committed evidence at both default viewports. `cd example && npm install -D @playwright/test && npx playwright install chromium && npx playwright test` reproduces it. Read `example/README.md` first.
